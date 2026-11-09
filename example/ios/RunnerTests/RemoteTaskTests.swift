import CryptoKit
import Foundation
import XCTest

@testable import barometer_flutter

/// Signed remote task acceptance in the native library through the channel host: a package
/// signed with a synthetic Ed25519 key of the trusted local policy is installed with
/// `InstallRemoteTask` and admitted, and packages signed with a wrong key, with altered task bytes
/// or under an expired key are rejected as `task_source_unauthenticated`. The keys derive from
/// fixed public test seeds. Only admission runs; nothing contacts the network.
final class RemoteTaskTests: XCTestCase {
  private static let scope = "remote-task-test"

  private var base: URL!
  private var channel: ChannelCaller!
  private let now = Date()
  private let trusted = try! TestSigner(keyID: "remote-key-1", issuerID: TestDocuments.remoteIssuer, label: 0x31)
  private let expired = try! TestSigner(
    keyID: "remote-key-expired", issuerID: TestDocuments.remoteIssuer, label: 0x32)

  override func setUpWithError() throws {
    base = FileManager.default.temporaryDirectory
      .appendingPathComponent("remote-task-\(UUID().uuidString)", isDirectory: true)
    let document = try TestDocuments.withRemoteIssuer(
      try TestDocuments.trustDocument(),
      keys: [
        trusted.keyRecord(notBefore: now.addingTimeInterval(-3600), notAfter: now.addingTimeInterval(86_400)),
        expired.keyRecord(notBefore: now.addingTimeInterval(-7200), notAfter: now.addingTimeInterval(-3600)),
      ])
    let storesBase = base.appendingPathComponent("stores", isDirectory: true)
    let host = BarometerHost(
      policy: HostPolicy { document },
      openStore: { try RecordStore.open(base: storesBase, scope: Self.scope, isMainThread: { Thread.isMainThread }) },
      background: FakeBackgroundTasks())
    channel = ChannelCaller(host)
    XCTAssertNil(channel.initialize("{}"))
  }

  override func tearDownWithError() throws {
    _ = channel.code("close")
    channel.host.detach()
    try? FileManager.default.removeItem(at: base)
  }

  private func task(_ id: String) throws -> Data { Data(try TestDocuments.runTask(id).utf8) }

  private func hex(_ s: String) -> Data {
    var out = Data()
    var index = s.startIndex
    while index < s.endIndex {
      let next = s.index(index, offsetBy: 2)
      out.append(UInt8(s[index..<next], radix: 16)!)
      index = next
    }
    return out
  }

  func testSignerMatchesTheRfc8032Vector() throws {
    // RFC 8032 section 7.1, test 1: the empty message. CryptoKit may randomize its own
    // signatures, so the published signature is verified instead of compared.
    let signer = try TestSigner(
      keyID: "rfc", issuerID: "rfc", seed: hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"))
    XCTAssertEqual(signer.publicKey, hex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"))
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: signer.publicKey)
    let signature = hex(
      "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"
    )
    XCTAssertTrue(key.isValidSignature(signature, for: Data()))
  }

  func testASignedPackageIsAcceptedAndForgeriesAreRejected() throws {
    let issued = now.addingTimeInterval(-60)
    let package = try trusted.sign(try task("remote-accepted"), issuedAt: issued)
    let accepted = channel.admitRemote(package)
    XCTAssertNil(accepted.code)
    XCTAssertFalse((accepted.value as? String ?? "").isEmpty)

    // The same key ID and issuer with another seed: the signature does not verify.
    let impostor = try TestSigner(keyID: trusted.keyID, issuerID: trusted.issuerID, label: 0x77)
    XCTAssertEqual(
      channel.admitRemote(try impostor.sign(try task("remote-wrong-key"), issuedAt: issued)).code,
      "task_source_unauthenticated")

    // Task bytes changed after signing.
    let altered = try trusted.sign(try task("remote-altered"), issuedAt: issued) { bytes in
      var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
      object["task_id"] = "remote-altered-2"
      return Data(try TestDocuments.json(object).utf8)
    }
    XCTAssertEqual(channel.admitRemote(altered).code, "task_source_unauthenticated")

    // A key whose validity ended an hour ago, for a package issued while it was valid.
    let late = try expired.sign(try task("remote-expired-key"), issuedAt: now.addingTimeInterval(-5400))
    XCTAssertEqual(channel.admitRemote(late).code, "task_source_unauthenticated")

    // The accepted package admits again as an exact redelivery.
    XCTAssertNil(channel.admitRemote(package).code)
  }
}
