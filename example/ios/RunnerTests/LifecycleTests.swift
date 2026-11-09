import Flutter
import Foundation
import Network
import XCTest

@testable import barometer_flutter

/// The network signals, the lifecycle bound of active runs and the clear-data rows on a
/// simulator. Active attempts wait on a loopback proxy that never answers; the linked runs
/// contact 1.1.1.1:443 once each. No result is printed.
final class LifecycleTests: XCTestCase {
  private static let scope = "lifecycle-test"

  private var base: URL!
  private var proxy: StallingProxy!
  private var host: BarometerHost?
  private var background: FakeBackgroundTasks!
  private var stores: [RecordStore] = []
  private var clients: [BarometerClient] = []

  override func setUpWithError() throws {
    base = FileManager.default.temporaryDirectory
      .appendingPathComponent("lifecycle-\(UUID().uuidString)", isDirectory: true)
    proxy = try StallingProxy()
    background = FakeBackgroundTasks()
    KeychainProbe.remove(Self.scope)
  }

  override func tearDownWithError() throws {
    host?.detach()
    runOffMain {
      for c in self.clients.reversed() { try? c.close() }
      for s in self.stores.reversed() { try? s.close() }
    }
    clients.removeAll()
    stores.removeAll()
    proxy.close()
    KeychainProbe.remove(Self.scope)
    try? FileManager.default.removeItem(at: base)
  }

  private var scopeDir: URL { base.appendingPathComponent("stores/\(Self.scope)", isDirectory: true) }
  private var sentinel: URL { scopeDir.appendingPathComponent(AppleLinkageKeys.sentinelName) }

  private func records() -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: scopeDir.appendingPathComponent("records").path)) ?? []
  }

  private func openStore() throws -> RecordStore {
    try RecordStore.open(
      base: base.appendingPathComponent("stores", isDirectory: true), scope: Self.scope,
      isMainThread: { Thread.isMainThread })
  }

  private func newClient() throws -> BarometerClient {
    let store = try openStore()
    stores.append(store)
    let client = try BarometerBinding.newClient(store: store, trust: try TestDocuments.trustDocument())
    clients.append(client)
    return client
  }

  private func code(_ body: () throws -> Void) -> String? {
    do {
      try body()
      return nil
    } catch let e as BarometerError {
      return e.code
    } catch {
      return "\(type(of: error))"
    }
  }

  private func start(_ client: BarometerClient, _ id: String, proxy: Bool = false) throws -> String {
    let task = try TestDocuments.runTask(id, proxy: proxy)
    let ref = try client.installEmbeddedTask(issuer: TestDocuments.issuer, task: Data(task.utf8))
    return try client.startRun(try client.admitTask(task, sourceRef: ref))
  }

  private func awaitTerminal(_ client: BarometerClient, _ run: String) throws {
    let deadline = Date().addingTimeInterval(30)
    while try client.runState(run) != "terminal" {
      if Date() > deadline { throw AdapterUnavailableError() }
      Thread.sleep(forTimeInterval: 0.01)
    }
  }

  private func awaitProxy(_ connects: Int) throws {
    let deadline = Date().addingTimeInterval(10)
    while proxy.connects < connects {
      if Date() > deadline { throw AdapterUnavailableError() }
      Thread.sleep(forTimeInterval: 0.01)
    }
  }

  // MARK: - Network signals

  func testVpnSignalMapsTheInterfaceType() {
    XCTAssertEqual(AppleNetwork.vpn(satisfied: true, primary: .other), "detected")
    for type in [NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet, .loopback] {
      XCTAssertEqual(AppleNetwork.vpn(satisfied: true, primary: type), "not_detected", "\(type)")
    }
    XCTAssertEqual(AppleNetwork.vpn(satisfied: true, primary: nil), "unknown")
    XCTAssertEqual(AppleNetwork.vpn(satisfied: false, primary: .other), "unknown")
  }

  func testEverySignalChangeAdvancesTheGeneration() throws {
    let network = AppleNetwork()
    defer { network.close() }
    var first: AccessSnapshot?
    runOffMain { first = try network.access(timeoutMillis: 2000) }
    let s = try XCTUnwrap(first)
    XCTAssertEqual(s.suspended, "active")
    XCTAssertEqual(s.validated, "unknown")
    XCTAssertEqual(s.captivePortal, "unknown")
    XCTAssertTrue(["detected", "not_detected", "unknown"].contains(s.vpn), s.vpn)

    func fires(_ change: () -> Void) throws -> Int64 {
      let before = network.currentGeneration
      let fired = expectation(description: "watch fires")
      _ = try network.watch(before) { fired.fulfill() }
      change()
      wait(for: [fired], timeout: 2)
      XCTAssertGreaterThan(network.currentGeneration, before)
      return network.currentGeneration
    }
    let wifi = AppleNetwork.Coarse(
      type: "wifi", ipv4: "yes", ipv6: "no", vpn: "not_detected", interface: "a", gateways: [])
    let tunnel = AppleNetwork.Coarse(
      type: "wifi", ipv4: "yes", ipv6: "no", vpn: "detected", interface: "b", gateways: [])
    _ = try fires { network.record(wifi) }
    _ = try fires { network.record(tunnel) }
    _ = try fires { network.record(wifi) }
    _ = try fires { network.record(.none) }
    // The same state again does not change the generation.
    let same = network.currentGeneration
    network.record(.none)
    XCTAssertEqual(network.currentGeneration, same)

    _ = try fires { network.setSuspended(true) }
    var suspended: AccessSnapshot?
    runOffMain { suspended = try network.access(timeoutMillis: 2000) }
    XCTAssertEqual(suspended?.suspended, "suspended")
    let held = network.currentGeneration
    network.setSuspended(true)
    XCTAssertEqual(network.currentGeneration, held)
    _ = try fires { network.setSuspended(false) }
    var resumed: AccessSnapshot?
    runOffMain { resumed = try network.access(timeoutMillis: 2000) }
    XCTAssertEqual(resumed?.suspended, "active")

    // Every field is a fixed value; nothing else, such as an interface name, can be carried.
    for snapshot in [s, suspended, resumed].compactMap({ $0 }) {
      let values = Mirror(reflecting: snapshot).children.compactMap { $0.value as? String }
      let allowed: Set<String> = [
        "wifi", "cellular", "ethernet", "other", "unknown", "yes", "no", "detected", "not_detected",
        "suspended", "active",
      ]
      XCTAssertTrue(Set(values).isSubset(of: allowed), "\(values)")
    }
  }

  // MARK: - Lifecycle through the channel host

  private func makeHost() throws -> BarometerHost {
    let bundle = try TestDocuments.bundle(
      at: base.appendingPathComponent("bundle", isDirectory: true), trust: try TestDocuments.trustDocument(),
      tasks: [
        "stall": try TestDocuments.runTask("lifecycle-stall", proxy: true),
        "stall-again": try TestDocuments.runTask("lifecycle-stall-again", proxy: true),
      ])
    let storesBase = base.appendingPathComponent("stores", isDirectory: true)
    let made = BarometerHost(
      bundle: bundle, policy: HostPolicy(bundle: bundle),
      openStore: { try RecordStore.open(base: storesBase, scope: Self.scope, isMainThread: { Thread.isMainThread }) },
      background: background)
    host = made
    return made
  }

  private struct Outcome {
    let value: Any?
    let code: String?
  }

  private func call(_ host: BarometerHost, _ method: String, _ arguments: Any? = nil) -> Outcome {
    let done = expectation(description: method)
    var outcome: Outcome?
    XCTAssertTrue(
      host.handle(
        method, arguments,
        BarometerHost.Reply(
          success: {
            outcome = Outcome(value: $0, code: nil)
            done.fulfill()
          },
          error: {
            outcome = Outcome(value: nil, code: $0)
            done.fulfill()
          })))
    wait(for: [done], timeout: 30)
    return outcome ?? Outcome(value: nil, code: "timeout")
  }

  /// Initializes `host` with the proxy and starts the stalling task; returns its run handle once
  /// the attempt is waiting on the proxy.
  private func startStalledRun(_ host: BarometerHost, connects: Int = 1) throws -> String {
    XCTAssertNil(call(host, "initialize", ["config": try TestDocuments.linkedConfig(proxyPort: proxy.port)]).code)
    return try startAnother(host, "stall", connects: connects)
  }

  private func startAnother(_ host: BarometerHost, _ name: String, connects: Int) throws -> String {
    let admitted = call(host, "admitTask", ["source": "embedded", "name": name])
    let task = try XCTUnwrap(admitted.value as? String, admitted.code ?? "")
    let started = call(host, "startRun", ["task": task])
    let run = try XCTUnwrap(started.value as? String, started.code ?? "")
    XCTAssertTrue(waitUntil(10) { proxy.connects >= connects }, "proxy not reached")
    XCTAssertEqual((call(host, "runState", ["run": run]).value as? [String: Any])?["state"] as? String, "active")
    return run
  }

  private func runState(_ host: BarometerHost, _ run: String) -> String? {
    let outcome = call(host, "runState", ["run": run])
    return (outcome.value as? [String: Any])?["state"] as? String ?? outcome.code
  }

  func testRunsHoldABackgroundTaskUntilTheyEnd() throws {
    let host = try makeHost()
    let run = try startStalledRun(host)
    XCTAssertEqual(background.beganCount, 1)
    XCTAssertEqual(background.open, 1)
    XCTAssertNil(call(host, "cancelRun", ["run": run]).code)
    XCTAssertEqual(runState(host, run), "terminal")
    XCTAssertEqual(background.open, 0)
    XCTAssertNil(call(host, "close").code)
  }

  func testBackgroundExpiryDuringARunSuspendsAndCancelsIt() throws {
    let host = try makeHost()
    let run = try startStalledRun(host)
    XCTAssertEqual(background.open, 1)

    let started = Date()
    background.expire()
    XCTAssertTrue(waitUntil(Double(BarometerHost.expiryBoundMillis) / 1000 + 1) { background.open == 0 })
    XCTAssertTrue(waitUntil(10) { runState(host, run) == "terminal" }, "the run was not ended")
    XCTAssertLessThan(Date().timeIntervalSince(started), 10)

    let pending = call(host, "nextBundle")
    let bytes = try XCTUnwrap(pending.value as? FlutterStandardTypedData, pending.code ?? "no bundle")
    let result = try TestDocuments.firstResult(String(decoding: bytes.data, as: UTF8.self))
    let execution = try XCTUnwrap(result["execution"] as? [String: Any])
    // The suspension ends the attempt, or the host's cancellation does if it comes first.
    let reason = execution["reason"] as? String ?? ""
    XCTAssertTrue(["platform_suspended", "cancelled_by_host"].contains(reason), reason)

    // The next run begins a new task with the network reported active again.
    let next = try startAnother(host, "stall-again", connects: 2)
    XCTAssertEqual(background.beganCount, 2)
    XCTAssertEqual(background.open, 1)
    XCTAssertNil(call(host, "cancelRun", ["run": next]).code)
    XCTAssertEqual(background.open, 0)
    XCTAssertNil(call(host, "close").code)
  }

  func testEngineDetachDuringARunCancelsItWithinTheLifecycleDeadline() throws {
    let host = try makeHost()
    let run = try startStalledRun(host)
    let started = Date()
    host.detach()
    self.host = nil
    XCTAssertEqual(call(host, "runState", ["run": run]).code, "client_closed")

    // The scope is released once the client and store are closed.
    var reopened: RecordStore?
    runOffMain {
      let deadline = Date().addingTimeInterval(10)
      while reopened == nil {
        reopened = try? self.openStore()
        if reopened == nil {
          if Date() > deadline { throw AdapterUnavailableError() }
          Thread.sleep(forTimeInterval: 0.05)
        }
      }
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    XCTAssertEqual(background.open, 0)
    let store = try XCTUnwrap(reopened)
    stores.append(store)

    // The cancelled attempt is recorded as cancelled_by_host in the scope.
    runOffMain {
      let client = try BarometerBinding.newClient(store: store, trust: try TestDocuments.trustDocument())
      self.clients.append(client)
      try client.initialize(try TestDocuments.linkedConfig(proxyPort: self.proxy.port))
      let raw = try client.nextBundle()
      XCTAssertFalse(raw.isEmpty, "no result for the cancelled attempt")
      let execution = try TestDocuments.firstResult(raw)["execution"] as? [String: Any]
      XCTAssertEqual(execution?["reason"] as? String, "cancelled_by_host")
    }
  }

  // MARK: - Clear-data rows

  func testClearingDeletesEverythingAndCreatesNoReplacementKey() throws {
    runOffMain {
      let client = try self.newClient()
      try client.initialize(try TestDocuments.linkedConfig(proxyPort: self.proxy.port))

      try self.awaitTerminal(client, try self.start(client, "clear-acknowledged"))
      let raw = try client.nextBundle()
      let acknowledged = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
      try client.acknowledgeBundle(try XCTUnwrap(acknowledged["bundle_id"] as? String))
      try self.awaitTerminal(client, try self.start(client, "clear-pending"))

      let linkage = try XCTUnwrap(acknowledged["linkage"] as? [String: Any], "no linkage")
      XCTAssertEqual(linkage["mode"] as? String, "rotating_installation")
      XCTAssertEqual((linkage["token"] as? String)?.count, 43)
      XCTAssertTrue(KeychainProbe.exists(Self.scope))
      XCTAssertTrue(FileManager.default.fileExists(atPath: self.sentinel.path))

      let active = try self.start(client, "clear-active", proxy: true)
      try self.awaitProxy(1)
      XCTAssertEqual(try client.runState(active), "active")
      XCTAssertFalse(self.records().isEmpty)

      let started = Date()
      try client.clearMeasurementData()
      XCTAssertLessThan(Date().timeIntervalSince(started), 10)
      // Clearing ends uninitialized, so the run handle is gone with the generation.
      XCTAssertEqual(self.code { _ = try client.runState(active) }, "not_initialized")
      XCTAssertEqual(self.records(), [])
      XCTAssertFalse(KeychainProbe.exists(Self.scope))
      XCTAssertFalse(FileManager.default.fileExists(atPath: self.sentinel.path))

      // Clearing is repeatable, and a new generation creates no key until linkage needs one.
      try client.clearMeasurementData()
      try client.initialize(try TestDocuments.linkedConfig(proxyPort: self.proxy.port))
      XCTAssertEqual(try client.nextBundle(), "")
      XCTAssertFalse(KeychainProbe.exists(Self.scope))
      XCTAssertFalse(FileManager.default.fileExists(atPath: self.sentinel.path))
    }
  }

  func testAnInterruptedClearIsIncompleteUntilCompleted() throws {
    runOffMain {
      let client = try self.newClient()
      try client.initialize(try TestDocuments.linkedConfig())
      try self.awaitTerminal(client, try self.start(client, "interrupted-pending"))
      XCTAssertFalse(self.records().isEmpty)
      XCTAssertTrue(KeychainProbe.exists(Self.scope))
      // A directory in place of the sentinel cannot be unlinked as a file.
      try FileManager.default.removeItem(at: self.sentinel)
      try FileManager.default.createDirectory(
        at: self.sentinel.appendingPathComponent("blocker"), withIntermediateDirectories: true)

      XCTAssertEqual(self.code { try client.clearMeasurementData() }, "clearing_incomplete")
      XCTAssertEqual(self.code { try client.initialize("{}") }, "clearing_incomplete")
      try FileManager.default.removeItem(at: self.sentinel)
      try client.clearMeasurementData()
      XCTAssertEqual(self.records(), [])
      XCTAssertFalse(KeychainProbe.exists(Self.scope))
      XCTAssertFalse(FileManager.default.fileExists(atPath: self.sentinel.path))
      try client.initialize("{}")
      XCTAssertEqual(try client.nextBundle(), "")
    }
  }
}
