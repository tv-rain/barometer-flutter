import Foundation
import UIKit
import XCTest

@testable import barometer_flutter

/// Simulator tests of the Apple adapters through the facade, with synthetic configuration only.
/// TCP-01 contacts 1.1.1.1:443 once and DNS-01 resolves example.org once through the platform
/// resolver; the tests check the lifecycle and the result shape, never the outcome, and print no
/// result. Facade calls run off the main thread, as the plugin will make them.
final class AdapterTests: XCTestCase {
  private static let scope = "adapter-test"
  private static let issuer = "embedded-issuer"
  private static let tcpAddress = "1.1.1.1"
  private static let dnsName = "example.org"

  private var base: URL!
  private var stores: [RecordStore] = []
  private var clients: [BarometerClient] = []

  override func setUpWithError() throws {
    base = FileManager.default.temporaryDirectory
      .appendingPathComponent("adapter-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDownWithError() throws {
    offMain {
      for c in self.clients.reversed() { try? c.close() }
      for s in self.stores.reversed() { try? s.close() }
    }
    clients.removeAll()
    stores.removeAll()
    try? FileManager.default.removeItem(at: base)
  }

  /// Runs `body` on a background queue while the main run loop keeps serving, and rethrows.
  private func offMain(timeout: TimeInterval = 60, _ body: @escaping () throws -> Void) {
    let done = expectation(description: "background")
    var failure: Error?
    DispatchQueue.global().async {
      do { try body() } catch { failure = error }
      done.fulfill()
    }
    wait(for: [done], timeout: timeout)
    if let failure { XCTFail("\(failure)") }
  }

  private var scopeDir: URL { base.appendingPathComponent(Self.scope, isDirectory: true) }

  private func openStore() throws -> RecordStore {
    let s = try RecordStore.open(base: base, scope: Self.scope, isMainThread: { Thread.isMainThread })
    stores.append(s)
    return s
  }

  private func newClient(_ trust: Data) throws -> BarometerClient {
    let c = try BarometerBinding.newClient(store: try openStore(), trust: trust)
    clients.append(c)
    return c
  }

  private func code(_ body: () throws -> Void) -> String {
    do {
      try body()
      return ""
    } catch let e as BarometerError {
      return e.code
    } catch {
      return "\(type(of: error))"
    }
  }

  func testAdaptersReturnCoarseValues() throws {
    let now = try AppleClock().nowUnixMillis()
    XCTAssertLessThan(abs(now - Int64(Date().timeIntervalSince1970 * 1000)), 60_000)
    XCTAssertThrowsError(try AppleClock(wallClock: { Date(timeIntervalSince1970: 0) }).nowUnixMillis())
    XCTAssertThrowsError(try AppleClock(wallClock: { Date(timeIntervalSince1970: -1) }).nowUnixMillis())
    XCTAssertEqual(AppleConsent().status(), "absent")
    let zone = try AppleTimeZone().identifier()
    XCTAssertFalse(zone.isEmpty)
    XCTAssertNotNil(TimeZone(identifier: zone))

    XCTAssertEqual(
      AppleDevice.snapshot(level: 0.5, state: .charging),
      BatterySnapshot(percent: 50, percentKnown: true, charging: true, chargingKnown: true))
    XCTAssertEqual(
      AppleDevice.snapshot(level: 1, state: .full),
      BatterySnapshot(percent: 100, percentKnown: true, charging: true, chargingKnown: true))
    XCTAssertEqual(
      AppleDevice.snapshot(level: 0.2, state: .unplugged),
      BatterySnapshot(percent: 20, percentKnown: true, charging: false, chargingKnown: true))
    XCTAssertEqual(AppleDevice.snapshot(level: -1, state: .unknown), AppleDevice.unknown)
    // The main thread is never blocked: a reading there is unknown.
    XCTAssertEqual(AppleDevice().state(timeoutMillis: 1000), AppleDevice.unknown)
    let wasMonitoring = UIDevice.current.isBatteryMonitoringEnabled
    var battery: BatterySnapshot?
    offMain { battery = AppleDevice().state(timeoutMillis: 5000) }
    if let b = battery { XCTAssertTrue(!b.percentKnown || (0...100).contains(b.percent)) }
    XCTAssertEqual(UIDevice.current.isBatteryMonitoringEnabled, wasMonitoring)

    let network = AppleNetwork()
    defer { network.close() }
    var state: AccessSnapshot?
    offMain { state = try network.access(timeoutMillis: 2000) }
    let s = try XCTUnwrap(state)
    XCTAssertGreaterThanOrEqual(s.generation, 1)
    XCTAssertTrue(["wifi", "cellular", "ethernet", "other", "unknown"].contains(s.networkType))
    for v in [s.ipv4, s.ipv6] { XCTAssertTrue(["yes", "no", "unknown"].contains(v), v) }
    XCTAssertTrue(["detected", "not_detected", "unknown"].contains(s.vpn), s.vpn)
    XCTAssertEqual(s.validated, "unknown")
    XCTAssertEqual(s.captivePortal, "unknown")
    XCTAssertEqual(s.suspended, "active")
    // Every field is a fixed value; nothing else, such as an interface name, can be carried.
    let values = Mirror(reflecting: s).children.compactMap { $0.value as? String }
    let allowed: Set<String> = [
      "wifi", "cellular", "ethernet", "other", "unknown", "yes", "no", "detected", "not_detected", "active",
    ]
    XCTAssertTrue(Set(values).isSubset(of: allowed), "\(values)")
    network.close()
    XCTAssertThrowsError(try network.access(timeoutMillis: 100))
    XCTAssertThrowsError(try network.watch(s.generation) {})
  }

  func testWatchFiresOnceForAStaleGenerationAndNeverAfterStop() throws {
    let network = AppleNetwork()
    defer { network.close() }
    var gen: Int64 = 0
    offMain { gen = try network.access(timeoutMillis: 2000).generation }
    let lock = NSLock()
    var fired = 0
    let first = expectation(description: "stale watch fires")
    _ = try network.watch(gen - 1) {
      lock.lock()
      fired += 1
      lock.unlock()
      first.fulfill()
    }
    wait(for: [first], timeout: 1)
    let stopped = try network.watch(gen - 1) {
      lock.lock()
      fired += 1
      lock.unlock()
    }
    network.stopWatch(stopped)
    var current: Int64 = 0
    offMain { current = try network.access(timeoutMillis: 2000).generation }
    let pending = try network.watch(current) {
      lock.lock()
      fired += 1
      lock.unlock()
    }
    network.stopWatch(pending)
    network.stopWatch(pending)
    Thread.sleep(forTimeInterval: 0.2)
    lock.lock()
    XCTAssertTrue((1...2).contains(fired), "\(fired)")
    lock.unlock()
    XCTAssertThrowsError(try network.watch(-1) {})
  }

  func testResolverBoundsInputAndFormatsAddresses() throws {
    let resolver = AppleResolver { _, _ in
      [[192, 0, 2, 1], [192, 0, 2, 1], [0x20, 0x01, 0x0d, 0xb8] + Array(repeating: 0, count: 11) + [1], [1, 2]]
    }
    XCTAssertEqual(
      try resolver.lookupNetIP(network: "ip", host: "name.test.", timeoutMillis: 1000),
      ["192.0.2.1", "2001:db8::1"])
    for (network, host, timeout) in [
      ("tcp", "name.test", Int64(1000)), ("ip", "", 1000), ("ip", ".", 1000), ("ip", "192.0.2.1", 1000),
      ("ip6", "2001:db8::1", 1000), ("ip", "name.test", 0),
    ] {
      XCTAssertThrowsError(try resolver.lookupNetIP(network: network, host: host, timeoutMillis: timeout))
    }
    let failing = AppleResolver { _, _ in throw AdapterUnavailableError() }
    XCTAssertThrowsError(try failing.lookupNetIP(network: "ip", host: "name.test", timeoutMillis: 1000))

    let release = DispatchSemaphore(value: 0)
    let stalled = AppleResolver { _, _ in
      release.wait()
      return []
    }
    let start = Date()
    XCTAssertThrowsError(try stalled.lookupNetIP(network: "ip", host: "name.test", timeoutMillis: 100))
    XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    for _ in 0..<3 {
      XCTAssertThrowsError(try stalled.lookupNetIP(network: "ip", host: "name.test", timeoutMillis: 10))
    }
    // All four lookups are still running, so a fifth fails at once.
    XCTAssertThrowsError(try stalled.lookupNetIP(network: "ip", host: "name.test", timeoutMillis: 1000))
    for _ in 0..<4 { release.signal() }

    XCTAssertEqual(AppleResolver.canonicalIPv6(Array(repeating: 0, count: 16)), "::")
    XCTAssertEqual(
      AppleResolver.canonicalIPv6([0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1]),
      "2001:db8:0:1::1")
    XCTAssertEqual(
      AppleResolver.canonicalIPv6([0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1]),
      "2001:db8:0:1:1:1:1:1")
  }

  func testTrustDocumentFromTheBundleInitializes() throws {
    let trust = try TrustDocument.read(bundle: Bundle(for: Self.self))
    XCTAssertThrowsError(try TrustDocument.read(bundle: Bundle(for: Self.self), name: "missing"))
    XCTAssertThrowsError(try TrustDocument.read(bundle: Bundle(for: XCTestCase.self)))
    offMain {
      let client = try self.newClient(trust)
      try client.initialize("{}")
      XCTAssertEqual(self.code { try client.initialize("{}") }, "already_initialized")
      XCTAssertEqual(try client.nextBundle(), "")
      try client.clearMeasurementData()
      try client.initialize("{}")
    }
  }

  func testInvalidTrustIsRejected() throws {
    offMain {
      let store = try self.openStore()
      XCTAssertEqual(
        self.code { _ = try BarometerBinding.newClient(store: store, trust: Data("{}".utf8)) },
        "trust_invalid")
    }
  }

  func testTcp01RunsThroughTheFacade() throws {
    let tuple: [String: Any] = ["address": Self.tcpAddress, "port": 443, "scheme": "tcp"]
    let input: [String: Any] = ["ip_address": Self.tcpAddress, "port": 443]
    offMain {
      let client = try self.newClient(try Self.trustDocument("TCP-01", tuple))
      try client.initialize("{}")
      let (result, raw) = try self.runOne(client, Self.runTask("tcp-sim-1", "TCP-01", input))
      try self.assertResult(result, raw, "tcp_connect", [Self.tcpAddress])
    }
    let records = scopeDir.appendingPathComponent("records", isDirectory: true)
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: records.path).isEmpty)
  }

  func testDns01RunsThroughTheNativeResolver() throws {
    let input: [String: Any] = ["hostname": Self.dnsName, "record_type": "A"]
    offMain {
      let client = try self.newClient(try Self.trustDocument("DNS-01", ["hostname": Self.dnsName]))
      try client.initialize("{}")
      let (result, raw) = try self.runOne(client, Self.runTask("dns-sim-1", "DNS-01", input))
      try self.assertResult(result, raw, "dns_query", [Self.dnsName])
      let measurement = result["measurement"] as? [String: Any]
      let outcome = measurement?["outcome"] as? String ?? ""
      XCTAssertTrue(["resolved", "no_data", "resolver_error"].contains(outcome))
    }
  }

  private func assertResult(_ result: [String: Any], _ raw: String, _ observation: String, _ canaries: [String])
    throws
  {
    let execution = try XCTUnwrap(result["execution"] as? [String: Any])
    XCTAssertEqual(execution["state"] as? String, "completed", "\(execution["reason"] ?? "")")
    let measurement = try XCTUnwrap(result["measurement"] as? [String: Any])
    let observations = try XCTUnwrap(measurement["observations"] as? [[String: Any]])
    XCTAssertEqual(observations.count, 1)
    XCTAssertEqual(observations.first?["type"] as? String, observation)
    let implementation = try XCTUnwrap(result["implementation"] as? [String: Any])
    XCTAssertEqual(implementation["platform"] as? String, "ios")
    XCTAssertEqual(implementation["library_version"] as? String, "0.1.0")
    for c in canaries { XCTAssertFalse(raw.contains(c), "result retained a target") }
  }

  /// Installs, admits and runs `task`, returns its result from the bundle, then acknowledges.
  private func runOne(_ client: BarometerClient, _ task: String) throws -> ([String: Any], String) {
    let ref = try client.installEmbeddedTask(issuer: Self.issuer, task: Data(task.utf8))
    let handle = try client.admitTask(task, sourceRef: ref)
    let run = try client.startRun(handle)
    let deadline = Date().addingTimeInterval(30)
    while try client.runState(run) != "terminal" {
      if Date() > deadline {
        XCTFail("run did not become terminal")
        break
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
    let raw = try client.nextBundle()
    XCTAssertFalse(raw.isEmpty, "no bundle")
    let bundle = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    let results = try XCTUnwrap(bundle["results"] as? [[String: Any]])
    XCTAssertEqual(results.count, 1)
    try client.acknowledgeBundle(try XCTUnwrap(bundle["bundle_id"] as? String))
    XCTAssertEqual(try client.nextBundle(), "")
    return (try XCTUnwrap(results.first), raw)
  }

  private static func utc(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    return f.string(from: date)
  }

  private static func json(_ object: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
  }

  private static func runTask(_ id: String, _ test: String, _ input: [String: Any]) throws -> String {
    try json([
      "schema_version": "0.1.0", "task_id": id, "test_id": test, "test_version": "0.1.0",
      "input": input, "options": [String: Any](),
      "schedule": ["not_after": utc(Date().addingTimeInterval(86_400))],
      "execution": ["limits": [String: Any]()],
      "safety": ["risk_level": "low", "requires_user_consent": false],
    ])
  }

  /// A synthetic `barometer-trust/1` document permitting `test` against one registered target
  /// for the deployment and the embedded issuer. It is built when the test runs because the
  /// registration expires 48 hours later.
  private static func trustDocument(_ test: String, _ tuple: [String: Any]) throws -> Data {
    let testRef: [String: Any] = ["id": test, "version": "0.1.0"]
    let paths: [String: Any] = ["direct": true, "proxy": true]
    let registration: [String: Any] = [
      "id": "reg-a", "test": testRef, "role": "measurement", "tuple": tuple, "paths": paths,
      "baseline_risk": "low", "owner": "synthetic", "purpose": "synthetic", "review_generation": 1,
      "expires_at": utc(Date().addingTimeInterval(48 * 3600)), "redirect_ids": [Any](),
    ]
    let limits: [String: Any] = [
      "attempt": ["duration_ms": 60000, "bytes_sent": 65536, "bytes_received": 262144, "connections": 12],
      "max_runs": 28, "max_attempts": 2, "max_validity_seconds": 604800,
      "min_repeat_interval_seconds": 21600, "min_repeat_jitter_seconds": 300,
      "min_retry_delay_ms": 30000, "max_retry_delay_ms": 600000, "max_retry_jitter_ms": 60000,
      "max_result_bytes": 65536, "max_bundle_bytes": 262144, "max_results_per_bundle": 16,
      "max_pending_bundles": 32, "max_pending_bytes": 4194304, "max_retention_seconds": 86400,
    ]
    let permissions: [String: Any] = [
      "tests": [testRef], "registration_ids": ["reg-a"], "paths": paths, "max_risk": "high",
      "require_consent": false, "allow_medium_risk": true, "allow_composite": false,
      "allow_unknown_risk": true, "label_namespaces": [Any](), "limits": limits,
    ]
    let policy: [String: Any] = [
      "generation": 2, "permissions": permissions,
      "issuers": [["issuer_id": issuer, "permissions": permissions]],
      "targets": [registration], "keys": [Any](),
    ]
    let document: [String: Any] = [
      "format": "barometer-trust/1", "policy": policy,
      "configuration_approvals": [
        "endpoints": [Any](), "connection_codes": [Any](), "linkage_scopes": [Any](), "allow_linkage": false,
      ],
      "context_approvals": [
        "connection_codes": [Any](), "classification_versions": [Any](), "country_codes": [Any](),
        "region_codes": [Any](),
      ],
    ]
    return Data(try json(document).utf8)
  }
}
