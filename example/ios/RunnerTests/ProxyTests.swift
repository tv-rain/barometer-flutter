import Foundation
import XCTest

@testable import barometer_flutter

/// `SetProxy` and `ClearProxy` through the facade with the Apple adapters, against loopback test
/// proxies that never contact a target: a configured proxy carries a proxy-path TCP-01 attempt;
/// an unapproved or malformed configuration is `proxy_rejected` and keeps the previous proxy;
/// clearing it leaves proxy-path runs without a proxy; and a proxy generation whose cancelled
/// attempt cannot store its result within the cleanup bound, because the record store is held,
/// returns `cleanup_incomplete` and blocks the client until it is closed. The last test makes the
/// same calls through the channel host and checks the codes Dart receives. No result is printed.
final class ProxyTests: XCTestCase {
  private static let scope = "proxy-test"

  private var base: URL!
  private var stores: [RecordStore] = []
  private var clients: [BarometerClient] = []
  private var answering: [AnsweringProxy] = []
  private var stalling: [StallingProxy] = []

  override func setUpWithError() throws {
    base = FileManager.default.temporaryDirectory
      .appendingPathComponent("proxy-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDownWithError() throws {
    runOffMain {
      for c in self.clients.reversed() { try? c.close() }
      for s in self.stores.reversed() { try? s.close() }
    }
    answering.forEach { $0.close() }
    stalling.forEach { $0.close() }
    try? FileManager.default.removeItem(at: base)
  }

  /// A new client over a fresh scope and its store; call it off the main thread.
  private func newClient() throws -> (BarometerClient, RecordStore) {
    let store = try RecordStore.open(
      base: base.appendingPathComponent("stores-\(stores.count)", isDirectory: true), scope: Self.scope,
      isMainThread: { Thread.isMainThread })
    stores.append(store)
    let client = try BarometerBinding.newClient(store: store, trust: try TestDocuments.trustDocument())
    clients.append(client)
    return (client, store)
  }

  private func start(_ client: BarometerClient, _ id: String) throws -> String {
    let task = try TestDocuments.runTask(id, proxy: true)
    let ref = try client.installEmbeddedTask(issuer: TestDocuments.issuer, task: Data(task.utf8))
    return try client.startRun(try client.admitTask(task, sourceRef: ref))
  }

  /// Runs a proxy-path task to its end and returns its execution state.
  private func run(_ client: BarometerClient, _ id: String) throws -> String? {
    let run = try start(client, id)
    let deadline = Date().addingTimeInterval(60)
    while try client.runState(run) != "terminal" {
      if Date() > deadline { throw AdapterUnavailableError() }
      Thread.sleep(forTimeInterval: 0.01)
    }
    let raw = try client.nextBundle()
    let bundle = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    try client.acknowledgeBundle(try XCTUnwrap(bundle["bundle_id"] as? String))
    return (try TestDocuments.firstResult(raw)["execution"] as? [String: Any])?["state"] as? String
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

  func testSetAndClearProxyThroughTheFacade() throws {
    let working = try AnsweringProxy()
    answering.append(working)
    runOffMain {
      let (client, _) = try self.newClient()
      try client.initialize("{}")

      try client.setProxy(try TestDocuments.json(working.config()))
      XCTAssertEqual(try self.run(client, "proxy-working"), "completed")
      XCTAssertEqual(working.targets, ["1.1.1.1:443"])

      // Rejected configurations change nothing: the working proxy still carries the next run.
      let unapproved = try TestDocuments.json(working.config(code: "unapproved_code"))
      XCTAssertEqual(self.code { try client.setProxy(unapproved) }, "proxy_rejected")
      XCTAssertEqual(self.code { try client.setProxy(#"{"host":"127.0.0.1"}"#) }, "proxy_rejected")
      let portZero = try TestDocuments.json(
        ["host": "127.0.0.1", "port": 0, "connection_code": TestDocuments.connectionCode])
      XCTAssertEqual(self.code { try client.setProxy(portZero) }, "proxy_rejected")
      XCTAssertEqual(try self.run(client, "proxy-kept"), "completed")
      XCTAssertEqual(working.targets.count, 2)

      // Cleared: a proxy-path run starts no proxy connection; clearing repeats.
      try client.clearProxy()
      try client.clearProxy()
      XCTAssertEqual(try self.run(client, "proxy-cleared"), "not_run")
      XCTAssertEqual(working.targets.count, 2)

      // Set again after clearing.
      try client.setProxy(try TestDocuments.json(working.config()))
      XCTAssertEqual(try self.run(client, "proxy-again"), "completed")
      XCTAssertEqual(working.targets.count, 3)
    }
  }

  func testAGenerationThatCannotDrainIsCleanupIncomplete() throws {
    for clear in [false, true] {
      let stall = try StallingProxy()
      stalling.append(stall)
      let working = try AnsweringProxy()
      answering.append(working)
      runOffMain {
        let (client, store) = try self.newClient()
        try client.initialize(
          try TestDocuments.json([
            "proxy": ["host": "127.0.0.1", "port": stall.port, "connection_code": TestDocuments.connectionCode]
          ]))
        let active = try self.start(client, "drain-\(clear)")
        let reached = Date().addingTimeInterval(10)
        while stall.connects < 1 && Date() < reached { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(stall.connects, 1, "proxy not reached")
        XCTAssertEqual(try client.runState(active), "active")

        // Hold the record store so the cancelled attempt cannot store its result in time.
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let holderDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
          _ = try? store.serial(30_000) {
            held.signal()
            _ = release.wait(timeout: .now() + 20)
          }
          holderDone.signal()
        }
        XCTAssertEqual(held.wait(timeout: .now() + 10), .success)
        let started = Date()
        let replacement = try TestDocuments.json(working.config())
        let outcome = self.code { if clear { try client.clearProxy() } else { try client.setProxy(replacement) } }
        let waited = Date().timeIntervalSince(started)
        XCTAssertEqual(outcome, "cleanup_incomplete")
        XCTAssertTrue((1.5...10).contains(waited), "returned after \(waited) s")
        // The client stays blocked: no replacement was installed.
        XCTAssertEqual(self.code { try client.clearProxy() }, "cleanup_incomplete")
        XCTAssertTrue(working.targets.isEmpty)

        release.signal()
        XCTAssertEqual(holderDone.wait(timeout: .now() + 10), .success)
        try client.close()
        try store.close()
        self.clients.removeAll { $0 === client }
        self.stores.removeAll { $0 === store }
      }
    }
  }

  /// The proxy codes through the channel host, as Dart receives them: `setProxy` returns
  /// `proxy_rejected` for an unapproved connection code, a proxy object carrying a context
  /// endpoint and one without a port, and the initial proxy stays configured; with an attempt
  /// waiting on it and the host's record store held, `setProxy` and `clearProxy` return
  /// `cleanup_incomplete`; `close` succeeds once the store is released.
  func testProxyCodesReachTheChannel() throws {
    let now = Date()
    let signer = try TestSigner(keyID: "proxy-key", issuerID: TestDocuments.remoteIssuer, label: 0x43)
    let document = try TestDocuments.withRemoteIssuer(
      try TestDocuments.trustDocument(),
      keys: [signer.keyRecord(notBefore: now.addingTimeInterval(-3600), notAfter: now.addingTimeInterval(86_400))])
    let storesBase = base.appendingPathComponent("channel-stores", isDirectory: true)
    var opened: RecordStore?
    let host = BarometerHost(
      policy: HostPolicy { document },
      openStore: {
        let store = try RecordStore.open(base: storesBase, scope: Self.scope, isMainThread: { Thread.isMainThread })
        opened = store
        return store
      },
      background: FakeBackgroundTasks())
    defer { host.detach() }
    let channel = ChannelCaller(host)
    let stall = try StallingProxy()
    stalling.append(stall)
    let working = try AnsweringProxy()
    answering.append(working)

    let initial: [String: Any] = [
      "host": "127.0.0.1", "port": stall.port, "connection_code": TestDocuments.connectionCode,
    ]
    XCTAssertNil(channel.initialize(try TestDocuments.json(["proxy": initial])))
    var withEndpoint = working.config()
    withEndpoint["primary_endpoint"] = "https://9.9.9.9/network-context"
    let rejected: [[String: Any]] = [
      working.config(code: "unapproved_code"),
      withEndpoint,
      ["host": "127.0.0.1", "connection_code": TestDocuments.connectionCode],
    ]
    for proxy in rejected {
      let text = try TestDocuments.json(proxy)
      XCTAssertEqual(channel.code("setProxy", ["proxy": text]), "proxy_rejected", text)
    }

    // The initial proxy is kept: the next proxy-path attempt reaches it and waits there. The
    // first start after initialize can find the run not yet due while the adapters take their
    // first readings; wait for that, for at most ten seconds.
    let task = try TestDocuments.runTask("channel-drain", proxy: true)
    let admitted = channel.admitRemote(try signer.sign(Data(task.utf8), issuedAt: now.addingTimeInterval(-60)))
    XCTAssertNil(admitted.code)
    let handle = try XCTUnwrap(admitted.value as? String)
    var started = channel.call("startRun", ["task": handle])
    let due = Date().addingTimeInterval(10)
    while started.code == "run_not_due" && Date() < due {
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
      started = channel.call("startRun", ["task": handle])
    }
    let run = try XCTUnwrap(started.value as? String, started.code ?? "")
    XCTAssertTrue(waitUntil(10) { stall.connects == 1 }, "proxy not reached")
    XCTAssertEqual(channel.state(run), "active")

    // Hold the host's record store so the cancelled attempt cannot store its result in time.
    let store = try XCTUnwrap(opened)
    let held = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let holderDone = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      _ = try? store.serial(30_000) {
        held.signal()
        _ = release.wait(timeout: .now() + 20)
      }
      holderDone.signal()
    }
    XCTAssertEqual(held.wait(timeout: .now() + 10), .success)
    XCTAssertEqual(
      channel.code("setProxy", ["proxy": try TestDocuments.json(working.config())]), "cleanup_incomplete")
    XCTAssertEqual(channel.code("clearProxy"), "cleanup_incomplete")
    XCTAssertTrue(working.targets.isEmpty)

    release.signal()
    XCTAssertEqual(holderDone.wait(timeout: .now() + 10), .success)
    XCTAssertNil(channel.code("close"))
  }
}
