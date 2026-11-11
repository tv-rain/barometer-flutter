import Flutter
import Foundation
import XCTest

@testable import barometer_flutter

/// Admission classes, execution states, byte accounting and task context values of the Go
/// specification findings, through the channel host against the facade with the production
/// Apple adapters. Every task is a signed remote package of a synthetic issuer, so any task content
/// can be admitted through the channel. The answers checked are the ones Dart receives: the
/// channel error code, and the exact bundle bytes `nextBundle` returns.
///
/// Runs take the proxy path through loopback proxies that never contact a target, so nothing
/// leaves the simulator. No result is printed.
final class FindingAdoptionTests: XCTestCase {
  private static let scope = "finding-adoption-test"

  private var base: URL!
  private var channel: ChannelCaller!
  private var proxies: [() -> Void] = []
  private let now = Date()
  private let signer = try! TestSigner(keyID: "finding-key", issuerID: TestDocuments.remoteIssuer, label: 0x41)

  override func setUpWithError() throws {
    base = FileManager.default.temporaryDirectory
      .appendingPathComponent("finding-adoption-\(UUID().uuidString)", isDirectory: true)
    let document = try self.document()
    let storesBase = base.appendingPathComponent("stores", isDirectory: true)
    let host = BarometerHost(
      policy: HostPolicy { document },
      openStore: { try RecordStore.open(base: storesBase, scope: Self.scope, isMainThread: { Thread.isMainThread }) },
      background: FakeBackgroundTasks())
    channel = ChannelCaller(host)
  }

  override func tearDownWithError() throws {
    _ = channel.code("close")
    channel.host.detach()
    proxies.reversed().forEach { $0() }
    try? FileManager.default.removeItem(at: base)
  }

  /// TCP-01 to 1.1.1.1:443 and NET-01 permitted for the deployment and both issuers, DNS-01 for
  /// the deployment only, the test proxies' connection code approved, and the remote issuer's key.
  private func document() throws -> Data {
    let tests = try TestDocuments.editPolicy(try TestDocuments.trustDocument()) { policy in
      var permissions = try XCTUnwrap(policy["permissions"] as? [String: Any])
      permissions["tests"] = (permissions["tests"] as? [Any] ?? []) + [Self.ref("NET-01"), Self.ref("DNS-01")]
      policy["permissions"] = permissions
      var issuers = try XCTUnwrap(policy["issuers"] as? [[String: Any]])
      var issuer = try XCTUnwrap(issuers.first?["permissions"] as? [String: Any])
      issuer["tests"] = (issuer["tests"] as? [Any] ?? []) + [Self.ref("NET-01")]
      issuers[0]["permissions"] = issuer
      policy["issuers"] = issuers
    }
    return try TestDocuments.withRemoteIssuer(
      tests,
      keys: [signer.keyRecord(notBefore: now.addingTimeInterval(-3600), notAfter: now.addingTimeInterval(86_400))])
  }

  private static func ref(_ test: String) -> [String: Any] { ["id": test, "version": "0.1.0"] }

  /// A task as an object, for the cases to change before signing.
  private func task(
    _ id: String, proxy: Bool = false, test: String = "TCP-01", input: [String: Any] = TestDocuments.tcpInput
  ) throws -> [String: Any] {
    let text = try TestDocuments.runTask(id, proxy: proxy, test: test, input: input)
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
  }

  private func admit(_ task: [String: Any]) throws -> ChannelCaller.Outcome {
    channel.admitRemote(try signer.sign(Data(try TestDocuments.json(task).utf8), issuedAt: now.addingTimeInterval(-60)))
  }

  private func admitted(_ task: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws -> String {
    let outcome = try admit(task)
    XCTAssertNil(outcome.code, task["task_id"] as? String ?? "", file: file, line: line)
    return try XCTUnwrap(outcome.value as? String, file: file, line: line)
  }

  /// Reads the oldest pending bundle's bytes twice and acknowledges it.
  private func takeBytes() throws -> Data {
    let first = try XCTUnwrap(channel.call("nextBundle").value as? FlutterStandardTypedData).data
    // Without an acknowledgement the same bundle is returned again, byte for byte.
    XCTAssertEqual(first, try XCTUnwrap(channel.call("nextBundle").value as? FlutterStandardTypedData).data)
    let bundle = try XCTUnwrap(try JSONSerialization.jsonObject(with: first) as? [String: Any])
    XCTAssertNil(channel.code("acknowledgeBundle", ["id": try XCTUnwrap(bundle["bundle_id"] as? String)]))
    return first
  }

  /// Runs `task` to its end through the channel and returns the first result of its bundle.
  private func run(_ task: String) throws -> [String: Any] {
    // The first start after initialize can find the run not yet due while the adapters take
    // their first readings; wait for that, for at most ten seconds.
    var started = channel.call("startRun", ["task": task])
    let deadline = Date().addingTimeInterval(10)
    while started.code == "run_not_due" && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
      started = channel.call("startRun", ["task": task])
    }
    XCTAssertNil(started.code, "startRun")
    let run = try XCTUnwrap(started.value as? String)
    XCTAssertTrue(waitUntil(60) { channel.state(run) == "terminal" })
    return try result(try takeBytes())
  }

  private func result(_ bytes: Data) throws -> [String: Any] {
    let bundle = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    return try XCTUnwrap((bundle["results"] as? [[String: Any]])?.first)
  }

  private func execution(_ result: [String: Any]) -> [String: Any] { result["execution"] as? [String: Any] ?? [:] }

  private func window(_ zone: String) -> [String: Any] {
    ["timezone": zone, "ranges": [["start": "00:00", "end": "23:59"]]]
  }

  func testAdmissionClassesReachTheChannelUnchanged() throws {
    XCTAssertNil(channel.initialize("{}"))
    var cases: [(String, [String: Any], String?)] = []
    cases.append(("admitted", try task("class-admitted"), nil))
    // GO-SPEC-ISSUE-008: the step-4 row (an unregistered test version) is task_unsupported.
    var version = try task("class-version")
    version["test_version"] = "0.2.0"
    cases.append(("unregistered version", version, "task_unsupported"))
    cases.append(("long task_id", try task(String(repeating: "x", count: 129)), "task_limit_exceeded"))
    var limit = try task("class-limit")
    limit["execution"] = ["limits": ["max_connections": 13]]
    cases.append(("limit above the policy", limit, "task_limit_exceeded"))
    var expired = try task("class-expired")
    expired["schedule"] = ["not_after": TestDocuments.utc(now.addingTimeInterval(-60))]
    cases.append(("expired", expired, "task_expired"))
    cases.append(
      ("test not permitted for the issuer", try task("class-issuer", test: "DNS-01", input: [:]),
       "task_issuer_not_authorized"))
    cases.append(
      ("unregistered target", try task("class-target", input: ["ip_address": "1.0.0.1", "port": 443]),
       "target_not_registered"))
    // GO-SPEC-ISSUE-007: an empty risk_factors for medium risk, and a timezone other than local,
    // are rejected; the valid forms are admitted.
    var riskEmpty = try task("class-risk-empty")
    riskEmpty["safety"] = ["risk_level": "medium", "requires_user_consent": false, "risk_factors": [Any]()]
    cases.append(("medium risk without factors", riskEmpty, "task_schema_invalid"))
    var riskFactor = try task("class-risk-factor")
    riskFactor["safety"] = [
      "risk_level": "medium", "requires_user_consent": false,
      "risk_factors": [["type": "network_observability", "level": "medium"]],
    ]
    cases.append(("medium risk with a factor", riskFactor, nil))
    for (zone, expected) in [("UTC", "task_schema_invalid"), ("local", nil)] as [(String, String?)] {
      var timed = try task("class-tz-\(zone.lowercased())")
      var schedule = try XCTUnwrap(timed["schedule"] as? [String: Any])
      schedule["time_window"] = window(zone)
      timed["schedule"] = schedule
      cases.append(("timezone \(zone)", timed, expected))
    }
    // GO-SPEC-ISSUE-009: a test HTTP CONNECT cannot carry is task_schema_invalid on the proxy
    // path; the same task is admitted on the direct path.
    cases.append(
      ("NET-01 on the proxy path", try task("class-net01-proxy", proxy: true, test: "NET-01", input: [:]),
       "task_schema_invalid"))
    cases.append(("NET-01 direct", try task("class-net01", test: "NET-01", input: [:]), nil))
    for (name, task, expected) in cases {
      let outcome = try admit(task)
      XCTAssertEqual(outcome.code, expected, name)
      if expected == nil { XCTAssertFalse((outcome.value as? String ?? "").isEmpty, name) }
    }
    // The same task_id with other bytes, after the first was admitted.
    var other = try task("class-admitted")
    other["schedule"] = ["not_after": TestDocuments.utc(now.addingTimeInterval(43_200))]
    XCTAssertEqual(try admit(other).code, "task_id_conflict")
    // An unsigned package.
    XCTAssertEqual(channel.admitRemote(Data("{}".utf8)).code, "task_source_unauthenticated")
  }

  func testExecutionStatesAndByteAccountingReachTheChannelUnchanged() throws {
    let answering = try AnsweringProxy()
    proxies.append { answering.close() }
    XCTAssertNil(channel.initialize(try TestDocuments.json(["proxy": answering.config()])))

    // GO-SPEC-ISSUE-005: the CONNECT exchange is not counted, and TCP-01 writes and reads no test
    // bytes, so the smallest byte limits complete although the proxy exchanged more bytes than
    // that.
    var smallest = try task("state-smallest-limits", proxy: true)
    smallest["execution"] = [
      "network_path": "proxy", "limits": ["max_bytes_sent": 1, "max_bytes_received": 1, "max_connections": 1],
    ]
    let completed = try run(try admitted(smallest))
    XCTAssertEqual(execution(completed)["state"] as? String, "completed")
    XCTAssertNil(execution(completed)["reason"])
    XCTAssertNotNil(completed["network_context"])
    XCTAssertNotNil(completed["measurement"])
    XCTAssertEqual(answering.targets, ["1.1.1.1:443"])

    // Without a proxy, a proxy-path attempt starts no test (GO-SPEC-ISSUE-004 case 1): it is
    // not_run, and its result carries no Network Context (REQ-RESULT-0053).
    XCTAssertNil(channel.code("clearProxy"))
    let notRun = try run(try admitted(try task("state-no-proxy", proxy: true)))
    XCTAssertEqual(execution(notRun)["state"] as? String, "not_run")
    XCTAssertFalse((execution(notRun)["reason"] as? String ?? "").isEmpty)
    XCTAssertNil(notRun["network_context"])
    XCTAssertNil(notRun["measurement"])
    XCTAssertEqual(answering.targets.count, 1)

    // GO-SPEC-ISSUE-013 and GO-SPEC-ISSUE-004 case 4: iOS has no network-validation source, so
    // the adapter reports validation as unknown, which never satisfies require_validated. The
    // start gate holds the run back: it is not due, and nothing is contacted or recorded.
    var validated = try task("state-require-validated", proxy: true)
    validated["execution"] = ["network_path": "proxy", "limits": [String: Any](), "network": ["require_validated": true]]
    XCTAssertNil(channel.code("setProxy", ["proxy": try TestDocuments.json(answering.config())]))
    let gated = try admitted(validated)
    XCTAssertEqual(channel.code("startRun", ["task": gated]), "run_not_due")
    XCTAssertNil(channel.call("nextBundle").value)
    XCTAssertEqual(answering.targets.count, 1)

    // Cancelled after the test started at its first dial (case 1): incomplete with the host's
    // reason and Network Context, and no measurement.
    let stalling = try StallingProxy()
    proxies.append { stalling.close() }
    let stallingConfig: [String: Any] = [
      "host": "127.0.0.1", "port": stalling.port, "connection_code": TestDocuments.connectionCode,
    ]
    XCTAssertNil(channel.code("setProxy", ["proxy": try TestDocuments.json(stallingConfig)]))
    let run = try XCTUnwrap(
      channel.call("startRun", ["task": try admitted(try task("state-cancelled", proxy: true))]).value as? String)
    XCTAssertTrue(waitUntil(10) { stalling.connects == 1 }, "proxy not reached")
    XCTAssertNil(channel.code("cancelRun", ["run": run]))
    XCTAssertTrue(waitUntil(60) { channel.state(run) == "terminal" })
    let incomplete = try result(try takeBytes())
    XCTAssertEqual(execution(incomplete)["state"] as? String, "incomplete")
    XCTAssertEqual(execution(incomplete)["reason"] as? String, "cancelled_by_host")
    XCTAssertNotNil(incomplete["network_context"])
    XCTAssertNil(incomplete["measurement"])
  }
}
