import CryptoKit
import Foundation
import XCTest

@testable import barometer_flutter

/// The host policy adapter: its generation gate with synthetic documents, the host rows of the
/// local policy lifecycle through the channel host, and the release-review input of the embedded
/// one-time exception taken from the trusted local document. Tasks arrive as signed remote
/// packages or embedded bundle resources; the replaced run waits on a loopback proxy that never
/// answers. Nothing contacts the network.
final class HostPolicyTests: XCTestCase {
  private static let scope = "host-policy-test"

  private var base: URL!
  private var proxy: StallingProxy!
  private var background: FakeBackgroundTasks!
  private var hosts: [BarometerHost] = []
  private let signer = try! TestSigner(keyID: "remote-key-1", issuerID: TestDocuments.remoteIssuer, label: 0x31)

  override func setUpWithError() throws {
    base = FileManager.default.temporaryDirectory
      .appendingPathComponent("host-policy-\(UUID().uuidString)", isDirectory: true)
    proxy = try StallingProxy()
    background = FakeBackgroundTasks()
  }

  override func tearDownWithError() throws {
    for host in hosts {
      _ = ChannelCaller(host).code("close")
      host.detach()
    }
    hosts.removeAll()
    proxy.close()
    try? FileManager.default.removeItem(at: base)
  }

  private func makeHost(_ policy: HostPolicy, bundle: Bundle = .main) -> ChannelCaller {
    let storesBase = base.appendingPathComponent("stores", isDirectory: true)
    let host = BarometerHost(
      bundle: bundle, policy: policy,
      openStore: { try RecordStore.open(base: storesBase, scope: Self.scope, isMainThread: { Thread.isMainThread }) },
      background: background)
    hosts.append(host)
    return ChannelCaller(host)
  }

  // MARK: - Generation gate

  private func document(_ generation: String, owner: String = "a") -> Data {
    Data(#"{"format":"barometer-trust/1","policy":{"generation":\#(generation),"owner":"\#(owner)"}}"#.utf8)
  }

  private func rejected(
    _ policy: HostPolicy, _ next: HostPolicy.Document, active: HostPolicy.Document?, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(try policy.check(next, active: active), "generation \(next.generation)", file: file, line: line) {
      XCTAssertEqual(($0 as? HostCodeError)?.code, "policy_rejected", file: file, line: line)
    }
  }

  func testGenerationIsAPositiveInteger() {
    XCTAssertEqual(HostPolicy.generation(document("2")), 2)
    XCTAssertEqual(HostPolicy.generation(document("9007199254740993")), 9_007_199_254_740_993)
    for bad in ["0", "-1", "2.5", "\"2\"", "null", "true", "[2]", "18446744073709551617"] {
      XCTAssertNil(HostPolicy.generation(document(bad)), bad)
    }
    XCTAssertNil(HostPolicy.generation(Data("{}".utf8)))
    XCTAssertNil(HostPolicy.generation(Data("not json".utf8)))
    XCTAssertNil(HostPolicy.generation(Data("[]".utf8)))
  }

  func testUnreadableDocumentsAreTrustInvalid() {
    let sources: [() throws -> Data] = [{ throw AdapterUnavailableError() }, { self.document("1.5") }]
    for source in sources {
      XCTAssertThrowsError(try HostPolicy(source: source).read()) {
        XCTAssertEqual(($0 as? HostCodeError)?.code, "trust_invalid")
      }
    }
  }

  func testOnlyAStrictlyGreaterGenerationReplaces() throws {
    let box = DocumentBox()
    box.document = document("2")
    let policy = HostPolicy { box.document }
    let two = try policy.read()
    try policy.check(two, active: nil)
    policy.activated(two)

    box.document = document("1")
    rejected(policy, try policy.read(), active: two)
    rejected(policy, try policy.read(), active: nil)
    box.document = document("2", owner: "b")
    rejected(policy, try policy.read(), active: two)
    rejected(policy, try policy.read(), active: nil)

    // The same bytes reopen after close; while a client is open they are no replacement.
    box.document = document("2")
    try policy.check(try policy.read(), active: nil)

    box.document = document("3")
    let three = try policy.read()
    try policy.check(three, active: two)
    policy.activated(three)
    box.document = document("2")
    rejected(policy, try policy.read(), active: three)
    rejected(policy, try policy.read(), active: nil)
    // Activating a lower document never lowers the floor.
    policy.activated(two)
    rejected(policy, two, active: nil)
    try policy.check(three, active: nil)
  }

  // MARK: - Policy replacement through the channel host

  /// A generation `generation` document that permits TCP-01 to the registered target with
  /// `owner`, or without the registration.
  private func policyDocument(_ generation: Int64, owner: String = "synthetic", registered: Bool = true) throws
    -> Data
  {
    let now = Date()
    let remote = try TestDocuments.withRemoteIssuer(
      try TestDocuments.trustDocument(),
      keys: [signer.keyRecord(notBefore: now.addingTimeInterval(-3600), notAfter: now.addingTimeInterval(86_400))])
    let owned = try TestDocuments.editPolicy(try TestDocuments.withGeneration(remote, generation)) { policy in
      var targets = try XCTUnwrap(policy["targets"] as? [[String: Any]])
      targets[0]["owner"] = owner
      policy["targets"] = targets
    }
    return registered ? owned : try TestDocuments.withoutRegistration(owned)
  }

  private func remotePackage(_ id: String, proxy: Bool = false) throws -> Data {
    try signer.sign(Data(try TestDocuments.runTask(id, proxy: proxy).utf8), issuedAt: Date().addingTimeInterval(-60))
  }

  private func proxyConfig() throws -> String {
    try TestDocuments.json(["proxy": ["host": "127.0.0.1", "port": proxy.port, "connection_code": TestDocuments.connectionCode]])
  }

  func testReplacementCancelsRunsAndRejectsRollback() throws {
    let box = DocumentBox()
    let policy = HostPolicy { box.document }
    var channel = makeHost(policy)
    // Each document is built once: a rebuilt one differs in its validity times.
    let generation2 = try policyDocument(2)
    let generation3 = try policyDocument(3, registered: false)
    box.document = generation2
    XCTAssertNil(channel.initialize(try proxyConfig()))
    // The same document again is no replacement.
    XCTAssertEqual(channel.initialize(try proxyConfig()), "already_initialized")

    let running = try remotePackage("replace-running", proxy: true)
    let admitted = channel.admitRemote(running)
    let runningTask = try XCTUnwrap(admitted.value as? String, admitted.code ?? "")
    let started = channel.call("startRun", ["task": runningTask])
    let run = try XCTUnwrap(started.value as? String, started.code ?? "")
    XCTAssertTrue(waitUntil(10) { proxy.connects == 1 }, "proxy not reached")
    XCTAssertEqual(channel.state(run), "active")
    XCTAssertEqual(background.open, 1)
    let idle = channel.admitRemote(try remotePackage("replace-idle", proxy: true))
    let idleTask = try XCTUnwrap(idle.value as? String, idle.code ?? "")

    // Rejected updates leave generation 2, its run and its handles in place.
    let updates: [(Data, String)] = [
      (try policyDocument(1), "policy_rejected"),
      (try policyDocument(2, owner: "synthetic-other"), "policy_rejected"),
      (try TestDocuments.edit(try policyDocument(3)) { $0["unknown_member"] = true }, "trust_invalid"),
      (Data(#"{"policy":{"generation":4}}"#.utf8), "trust_invalid"),
    ]
    for (rejected, code) in updates {
      box.document = rejected
      XCTAssertEqual(channel.initialize(try proxyConfig()), code)
      XCTAssertEqual(channel.state(run), "active")
    }

    // Generation 3 removes the registration: reinitialization cancels the run and the
    // generation-2 handles no longer resolve.
    box.document = generation3
    XCTAssertNil(channel.initialize(try proxyConfig()))
    XCTAssertEqual(channel.state(run), "handle_unavailable")
    XCTAssertEqual(channel.code("startRun", ["task": idleTask]), "handle_unavailable")
    XCTAssertEqual(channel.code("startRun", ["task": runningTask]), "handle_unavailable")
    XCTAssertEqual(background.open, 0, "the replaced run kept its background task")
    let bundle = try XCTUnwrap(try channel.takeBundle(), "no result for the cancelled run")
    let result = try XCTUnwrap((bundle["results"] as? [[String: Any]])?.first)
    XCTAssertEqual((result["execution"] as? [String: Any])?["reason"] as? String, "cancelled_by_host")
    XCTAssertNil(try channel.takeBundle())
    // No attempt continues or starts under the removed registration.
    XCTAssertEqual(channel.admitRemote(running).code, "target_not_registered")
    XCTAssertEqual(channel.admitRemote(try remotePackage("replace-new", proxy: true)).code, "target_not_registered")
    XCTAssertEqual(proxy.connects, 1)

    // A rollback after the replacement is rejected, and generation 3 stays active.
    box.document = generation2
    XCTAssertEqual(channel.initialize(try proxyConfig()), "policy_rejected")
    box.document = generation3
    XCTAssertEqual(channel.initialize(try proxyConfig()), "already_initialized")

    // After close, and for another engine of the process, the floor still holds.
    XCTAssertNil(channel.code("close"))
    box.document = generation2
    XCTAssertEqual(channel.initialize("{}"), "policy_rejected")
    channel.host.detach()
    channel = makeHost(policy)
    XCTAssertEqual(channel.initialize("{}"), "policy_rejected")
    box.document = generation3
    XCTAssertNil(channel.initialize("{}"))
    box.document = try policyDocument(4)
    XCTAssertNil(channel.initialize("{}"))
    // Generation 4 restores the registration: a new package is admitted under it.
    XCTAssertNil(channel.admitRemote(try remotePackage("replace-restored")).code)
  }

  // MARK: - Release review of the embedded one-time exception

  func testReleaseReviewComesFromTheTrustedDocument() throws {
    func oneTime(_ id: String) throws -> String {
      var task = try TestDocuments.taskObject(id)
      task["schedule"] = ["repeat": ["mode": "none"], "limits": ["max_runs": 1]]
      return try TestDocuments.json(task)
    }
    let reviewed = try oneTime("reviewed-once")
    let unreviewed = try oneTime("unreviewed-once")
    let digest = SHA256.hash(data: Data(reviewed.utf8)).map { String(format: "%02x", $0) }.joined()
    let listing = try TestDocuments.editPolicy(try TestDocuments.trustDocument()) {
      $0["release_reviewed_tasks"] = [["issuer_id": TestDocuments.issuer, "task_sha256": digest]]
    }
    let bundle = try TestDocuments.bundle(
      at: base.appendingPathComponent("bundle", isDirectory: true), trust: listing,
      tasks: ["reviewed": reviewed, "unreviewed": unreviewed])

    let channel = makeHost(HostPolicy(bundle: bundle), bundle: bundle)
    XCTAssertNil(channel.initialize("{}"))
    let admitted = channel.admitEmbedded("reviewed")
    XCTAssertNil(admitted.code)
    XCTAssertFalse((admitted.value as? String ?? "").isEmpty)
    XCTAssertEqual(channel.admitEmbedded("unreviewed").code, "task_schema_invalid")
    XCTAssertNil(channel.code("close"))

    // Without the listing in the document the same bytes have no exception.
    let plain = makeHost(HostPolicy { try TestDocuments.trustDocument() }, bundle: bundle)
    XCTAssertNil(plain.initialize("{}"))
    XCTAssertEqual(plain.admitEmbedded("reviewed").code, "task_schema_invalid")
  }
}
