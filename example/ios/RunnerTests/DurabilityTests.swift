import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import barometer_flutter

/// Durability across a process kill during a run, in two phases that
/// `scripts/ios-record-store-kill-test.sh` drives in separate test processes, as Android's
/// `DurabilityDeviceTest` does with a service process:
///
/// - `testDurabilityRun` owns the test scope with a facade client and leaves state of every kind
///   that must survive: a one-time task and a repeating task (at most two runs, six hours apart),
///   each run once to completion on the proxy path through a loopback proxy that answers CONNECT
///   without contacting the target, so their replay records, run-ledger entries and pending
///   bundle are stored; it checks that a task reusing the one-time task's identifier with other
///   content is rejected; and it starts a third attempt that waits on a loopback proxy that never
///   answers. With that attempt active it writes what the next phase needs and kills its own
///   process with `SIGKILL`.
/// - `testDurabilityVerify`, in a new process, opens the scope and finds the same oldest pending
///   bundle, byte for byte by SHA-256; both completed tasks, admitted again as exact
///   redeliveries, are not due, because the run ledger kept their runs; the conflicting task is
///   still rejected, because the replay record kept the identifier. Clearing then removes every
///   record, the Keychain key and the sentinel.
///
/// Both phases are skipped unless the script runs them. Nothing contacts the network and no
/// result is printed.
final class DurabilityTests: XCTestCase {
  private static let scope = "durability-test"

  private var phase: String? { ProcessInfo.processInfo.environment["BAROMETER_DURABILITY_TEST"] }

  private var support: URL {
    get throws {
      try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }
  }

  private var scopeDir: URL {
    get throws { try support.appendingPathComponent("barometer/\(Self.scope)", isDirectory: true) }
  }

  private var stateFile: URL {
    get throws { try support.appendingPathComponent("durability-state.json") }
  }

  private func code(_ body: () throws -> Void) -> String {
    do {
      try body()
      return "ok"
    } catch let e as BarometerError {
      return e.code
    } catch {
      return "\(type(of: error))"
    }
  }

  private static func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private func admit(_ client: BarometerClient, _ task: String) throws -> String {
    let ref = try client.installEmbeddedTask(issuer: TestDocuments.issuer, task: Data(task.utf8))
    return try client.admitTask(task, sourceRef: ref)
  }

  private func awaitTerminal(_ client: BarometerClient, _ run: String) throws {
    let deadline = Date().addingTimeInterval(30)
    while try client.runState(run) != "terminal" {
      if Date() > deadline { throw AdapterUnavailableError() }
      Thread.sleep(forTimeInterval: 0.01)
    }
  }

  /// A TCP-01 task on the proxy path with at most two runs, six hours apart.
  private static func repeatingTask(_ id: String) throws -> String {
    let base = try TestDocuments.runTask(id, proxy: true)
    var task = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(base.utf8)) as? [String: Any])
    var schedule = try XCTUnwrap(task["schedule"] as? [String: Any])
    schedule["repeat"] = ["mode": "interval", "interval": 21600, "jitter": 300]
    schedule["limits"] = ["max_runs": 2]
    task["schedule"] = schedule
    return try TestDocuments.json(task)
  }

  /// `task` with the same identifier and an expiry one hour earlier.
  private static func conflicting(_ task: String) throws -> String {
    var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(task.utf8)) as? [String: Any])
    var schedule = try XCTUnwrap(root["schedule"] as? [String: Any])
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    let notAfter = try XCTUnwrap(f.date(from: try XCTUnwrap(schedule["not_after"] as? String)))
    schedule["not_after"] = TestDocuments.utc(notAfter.addingTimeInterval(-3600))
    root["schedule"] = schedule
    return try TestDocuments.json(root)
  }

  private func cleanUp() throws {
    try? FileManager.default.removeItem(at: try scopeDir)
    try? FileManager.default.removeItem(at: try stateFile)
    KeychainProbe.remove(Self.scope)
  }

  func testDurabilityRun() throws {
    try XCTSkipUnless(phase == "run", "run by scripts/ios-record-store-kill-test.sh")
    try cleanUp()
    let answering = try AnsweringProxy()
    let stalling = try StallingProxy()
    let trust = try TestDocuments.trustDocument()
    let written = DispatchSemaphore(value: 0)
    var failure: Error?
    Thread.detachNewThread {
      do {
        let store = try RecordStore.open(scope: Self.scope)
        let client = try BarometerBinding.newClient(store: store, trust: trust)
        try client.initialize(try TestDocuments.linkedConfig(proxyPort: answering.port))
        let once = try TestDocuments.runTask("durability-once", proxy: true)
        let repeating = try Self.repeatingTask("durability-repeating")
        try self.awaitTerminal(client, try client.startRun(try self.admit(client, once)))
        try self.awaitTerminal(client, try client.startRun(try self.admit(client, repeating)))
        let bundle = try client.nextBundle()
        var state: [String: Any] = [
          "trust": trust.base64EncodedString(), "once": once, "repeating": repeating,
          "bundle_sha256": Self.sha256(bundle),
          "conflict": self.code { _ = try self.admit(client, try Self.conflicting(once)) },
        ]
        try client.setProxy(
          try TestDocuments.json([
            "host": "127.0.0.1", "port": stalling.port, "connection_code": TestDocuments.connectionCode,
          ]))
        let active = try client.startRun(
          try self.admit(client, try TestDocuments.runTask("durability-active", proxy: true)))
        let deadline = Date().addingTimeInterval(30)
        while stalling.connects == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        state["active"] = try client.runState(active) == "active"
        try Data(try TestDocuments.json(state).utf8).write(to: try self.stateFile, options: .atomic)
      } catch {
        failure = error
      }
      written.signal()
    }
    XCTAssertEqual(written.wait(timeout: .now() + 90), .success)
    if let failure { throw failure }
    let state = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(contentsOf: try stateFile)) as? [String: Any])
    XCTAssertEqual(state["conflict"] as? String, "task_id_conflict")
    XCTAssertEqual(state["active"] as? Bool, true, "no active attempt")
    kill(getpid(), SIGKILL)
  }

  func testDurabilityVerify() throws {
    try XCTSkipUnless(phase == "verify", "run by scripts/ios-record-store-kill-test.sh")
    let before = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(contentsOf: try stateFile)) as? [String: Any])
    let trust = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(before["trust"] as? String)))
    let once = try XCTUnwrap(before["once"] as? String)
    let repeating = try XCTUnwrap(before["repeating"] as? String)
    let proxy = try AnsweringProxy()
    defer { proxy.close() }
    runOffMain {
      let store = try RecordStore.open(scope: Self.scope)
      defer { try? store.close() }
      let client = try BarometerBinding.newClient(store: store, trust: trust)
      defer { try? client.close() }
      try client.initialize(try TestDocuments.linkedConfig(proxyPort: proxy.port))

      XCTAssertEqual(Self.sha256(try client.nextBundle()), before["bundle_sha256"] as? String)
      // Both tasks are admitted again as exact redeliveries, and the run ledger keeps their
      // completed runs: neither the one-time task nor the repeating one is due. Without the
      // stored entries a new client would start both.
      for (name, task) in [("once", once), ("repeating", repeating)] {
        XCTAssertEqual(self.code { _ = try client.startRun(try self.admit(client, task)) }, "run_not_due", name)
      }
      XCTAssertEqual(self.code { _ = try self.admit(client, try Self.conflicting(once)) }, "task_id_conflict")
      XCTAssertTrue(proxy.targets.isEmpty, "a task ran again")
      XCTAssertTrue(KeychainProbe.exists(Self.scope))

      try client.clearMeasurementData()
      let records = try FileManager.default.contentsOfDirectory(
        atPath: try self.scopeDir.appendingPathComponent("records").path)
      XCTAssertEqual(records, [])
      XCTAssertFalse(KeychainProbe.exists(Self.scope))
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: try self.scopeDir.appendingPathComponent(AppleLinkageKeys.sentinelName).path))
      try client.initialize("{}")
      XCTAssertEqual(try client.nextBundle(), "")
    }
    try cleanUp()
  }
}
