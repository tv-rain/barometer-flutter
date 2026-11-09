import Flutter
import Foundation

/// A failure raised by the host with a fixed code.
struct HostCodeError: Error {
  let code: String
}

/// Owns the native client of one Flutter engine and runs the channel calls against it.
///
/// Nothing happens at construction: the worker queue is created by the first call, and the record
/// store and facade client are created by `initialize`, which reads the trusted local document
/// from the application bundle. `close` closes the client, then the store. Every facade call runs
/// on a worker thread, never on the main thread, and its answer is delivered on the main queue.
///
/// A failed `initialize` keeps the client it created, so the host can retry it or recover with
/// `clearMeasurementData` after `clearing_incomplete`. A `close` that fails keeps the client too,
/// so it can be retried.
///
/// Active runs are bounded by the application lifecycle. A run started through `startRun` is
/// wrapped in a background task, which ends once no started run is still active as far as the
/// host knows: a run leaves that set when `runState` reports it `terminal`, when it is cancelled
/// and when the client is cleared or closed. If the task expires, the operating system is about
/// to suspend the application: the host reports suspension to the network adapter, which ends
/// active attempts as `platform_suspended`, cancels every run it tracks, so the attempt is
/// recorded as `cancelled_by_host` if the suspension did not end it first, and ends the task.
/// The next started run begins a new task and reports the network active again. Backgrounding
/// alone is not suspension. An engine detach closes the client, which cancels active runs
/// within the lifecycle deadline.
final class BarometerHost {
  /// A call's outcome: `success` with the result, or `error` with a code.
  struct Reply {
    let success: (Any?) -> Void
    let error: (String) -> Void
  }

  /// The bundle subdirectory of embedded tasks in the application bundle.
  static let tasksDirectory = "barometer/tasks"

  private static let workerCount = 4
  private static let errClosed = "client_closed"
  private static let errNotInitialized = "not_initialized"
  private static let errDelivery = "delivery_unavailable"
  private static let errTrust = "trust_invalid"
  private static let errStorage = "storage_unavailable"
  private static let terminal = "terminal"

  /// How long an expired background task waits for the cancellations before it ends anyway.
  static let expiryBoundMillis = 2_000

  private let bundle: Bundle
  private let openStore: () throws -> RecordStore
  private let lock = NSLock()
  private var workers: OperationQueue?
  private var detached = false
  private var store: RecordStore?
  private var client: BarometerClient?
  private var embeddedIssuer: String?

  private let background: BackgroundTasks
  /// Guards the fields below, apart from `lock`, so an expiring task never waits for a lifecycle
  /// call.
  private let runLock = NSLock()
  private var runs = Set<String>()
  private var starting = 0
  private var runClient: BarometerClient?
  private var task: (token: Int, id: Int?)?
  private var nextToken = 0

  /// `bundle` holds the trusted local document and the embedded tasks; `openStore` opens the
  /// record store; `background` grants background time to active runs. Tests replace them; the
  /// plugin uses the application bundle, the `default` scope and `UIApplication`.
  init(
    bundle: Bundle = .main, openStore: @escaping () throws -> RecordStore = { try RecordStore.open() },
    background: BackgroundTasks = AppleBackgroundTasks()
  ) {
    self.bundle = bundle
    self.openStore = openStore
    self.background = background
  }

  /// Parses and dispatches one channel call; returns false for an unknown method.
  func handle(_ method: String, _ arguments: Any?, _ reply: Reply) -> Bool {
    let call: ChannelCall
    do {
      guard let parsed = try ChannelContract.parse(method, arguments) else { return false }
      call = parsed
    } catch {
      reply.error(ChannelContract.invalidArguments)
      return true
    }
    guard let queue = queue() else {
      reply.error(Self.errClosed)
      return true
    }
    queue.addOperation { [self] in
      let outcome: Result<Any?, Error>
      do {
        outcome = .success(try perform(call))
      } catch {
        outcome = .failure(error)
      }
      DispatchQueue.main.async {
        switch outcome {
        case .success(let value): reply.success(value)
        case .failure(let error): reply.error(ChannelContract.code(error))
        }
      }
    }
    return true
  }

  /// Closes the client on a worker after the engine detaches. Later calls fail with
  /// `client_closed`; calls already queued still run.
  func detach() {
    lock.lock()
    detached = true
    let queue = workers
    lock.unlock()
    queue?.addOperation { [self] in try? closeClient() }
  }

  private func queue() -> OperationQueue? {
    lock.lock()
    defer { lock.unlock() }
    if detached { return nil }
    if let workers { return workers }
    let created = OperationQueue()
    created.name = "barometer-channel"
    created.maxConcurrentOperationCount = Self.workerCount
    created.qualityOfService = .utility
    workers = created
    return created
  }

  private func perform(_ call: ChannelCall) throws -> Any? {
    switch call {
    case .initialize(let config):
      try openClient().initialize(config)
      return nil
    case .close:
      try closeClient()
      return nil
    default:
      break
    }
    lock.lock()
    let current = client
    let issuer = embeddedIssuer
    lock.unlock()
    guard let facade = current else { throw HostCodeError(code: Self.errNotInitialized) }
    switch call {
    case .admitEmbedded(let name):
      guard let issuer,
        let url = bundle.url(forResource: name, withExtension: "json", subdirectory: Self.tasksDirectory),
        let task = readResource(url, max: ChannelContract.maxDeliveryBytes)
      else { throw HostCodeError(code: Self.errDelivery) }
      let ref = try facade.installEmbeddedTask(issuer: issuer, task: task)
      return try facade.admitTask(String(decoding: task, as: UTF8.self), sourceRef: ref)
    case .admitRemote(let signedPackage):
      // Go compares these exact bytes with the installed record and verifies the signature;
      // bytes that are not UTF-8 do not survive the string and are rejected.
      let ref = try facade.installRemoteTask(signedPackage)
      return try facade.admitTask(String(decoding: signedPackage, as: UTF8.self), sourceRef: ref)
    case .startRun(let task):
      beginRun(facade)
      do {
        let run = try facade.startRun(task)
        endRun(started: run)
        return run
      } catch {
        endRun(started: nil)
        throw error
      }
    case .runState(let run):
      let state = try facade.runState(run)
      if state == Self.terminal { untrack([run]) }
      return ["state": state]
    case .cancelRun(let run):
      try facade.cancelRun(run)
      untrack([run])
    case .nextBundle:
      let pending = try facade.nextBundle()
      return pending.isEmpty ? nil : FlutterStandardTypedData(bytes: Data(pending.utf8))
    case .acknowledgeBundle(let id):
      try facade.acknowledgeBundle(id)
    case .setProxy(let proxy):
      try facade.setProxy(proxy)
    case .clearProxy:
      try facade.clearProxy()
    case .clearMeasurementData:
      // Clearing cancels every active run, even when it then fails.
      defer { untrackAll() }
      try facade.clearMeasurementData()
    case .initialize, .close:
      break
    }
    return nil
  }

  /// Returns the client, creating the store and client on first use.
  private func openClient() throws -> BarometerClient {
    lock.lock()
    defer { lock.unlock() }
    if let client { return client }
    let trust: Data
    do {
      trust = try TrustDocument.read(bundle: bundle)
    } catch {
      throw HostCodeError(code: Self.errTrust)
    }
    let records: RecordStore
    do {
      records = try openStore()
    } catch {
      throw HostCodeError(code: Self.errStorage)
    }
    let created: BarometerClient
    do {
      created = try BarometerBinding.newClient(store: records, trust: trust)
    } catch {
      try? records.close()
      throw error
    }
    store = records
    client = created
    embeddedIssuer = TrustDocument.embeddedIssuer(trust)
    return created
  }

  /// Closes the client, then the store. Without a client it succeeds.
  private func closeClient() throws {
    lock.lock()
    defer { lock.unlock() }
    if client != nil { untrackAll() }
    try client?.close()
    client = nil
    embeddedIssuer = nil
    do {
      try store?.close()
    } catch {
      throw HostCodeError(code: Self.errStorage)
    }
    store = nil
  }

  // MARK: - Background time of active runs

  /// Called before a run starts: reports the network active and begins a background task unless
  /// one is running.
  private func beginRun(_ client: BarometerClient) {
    runLock.lock()
    starting += 1
    runClient = client
    let needed = task == nil
    var token = 0
    if needed {
      nextToken += 1
      token = nextToken
      task = (token, nil)
    }
    runLock.unlock()
    client.setSuspended(false)
    guard needed else { return }
    let id = background.begin { [weak self] in self?.expire(token) }
    runLock.lock()
    if let current = task, current.token == token {
      task = (token, id)
      runLock.unlock()
      return
    }
    // The task expired before `begin` returned; end it now.
    runLock.unlock()
    if let id { background.end(id) }
  }

  /// Called after a run start returned, with the run when it started.
  private func endRun(started run: String?) {
    runLock.lock()
    starting -= 1
    if let run { runs.insert(run) }
    let ended = idleTaskLocked()
    runLock.unlock()
    if let ended { background.end(ended) }
  }

  private func untrack(_ ended: [String]) {
    runLock.lock()
    ended.forEach { runs.remove($0) }
    let id = idleTaskLocked()
    runLock.unlock()
    if let id { background.end(id) }
  }

  private func untrackAll() {
    runLock.lock()
    runs.removeAll()
    let id = idleTaskLocked()
    runLock.unlock()
    if let id { background.end(id) }
  }

  /// With `runLock` held: forgets the task when no run is active or starting, and returns its
  /// system identifier to end.
  private func idleTaskLocked() -> Int? {
    guard runs.isEmpty, starting == 0, let current = task else { return nil }
    task = nil
    if current.id == nil { return nil }
    return current.id
  }

  /// The expiration handler of the task `token`: reports suspension, cancels the tracked runs on
  /// a worker and ends the task when they return or after `expiryBoundMillis`, whichever is
  /// first.
  private func expire(_ token: Int) {
    runLock.lock()
    guard let current = task, current.token == token else {
      runLock.unlock()
      return
    }
    task = nil
    let cancelled = Array(runs)
    runs.removeAll()
    let client = runClient
    runLock.unlock()
    client?.setSuspended(true)
    let ended = Ended()
    let end = { [background] in
      if ended.take(), let id = current.id { background.end(id) }
    }
    DispatchQueue.global(qos: .userInitiated).async {
      for run in cancelled { try? client?.cancelRun(run) }
      end()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.expiryBoundMillis)) { end() }
  }
}

/// True for the first caller of `take()` only.
private final class Ended {
  private let lock = NSLock()
  private var done = false

  func take() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let first = !done
    done = true
    return first
  }
}
