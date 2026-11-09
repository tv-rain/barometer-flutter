import CryptoKit
import Foundation
import XCTest

@testable import barometer_flutter

/// The Keychain linkage key store on a simulator: derivation, protection attributes, deletion,
/// the reinstall sentinel truth table and interrupted deletion. No derived value is printed.
final class LinkageKeysTests: XCTestCase {
  private static let scope = "linkage-test"
  private static let message = Data("barometer-linkage-test".utf8)

  private var base: URL!
  private var keys: AppleLinkageKeys!

  override func setUpWithError() throws {
    base = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkage-\(UUID().uuidString)", isDirectory: true)
    KeychainProbe.remove(Self.scope)
    keys = AppleLinkageKeys(scopeDirectory: base.appendingPathComponent(Self.scope), scope: Self.scope)
  }

  override func tearDownWithError() throws {
    keys.close()
    KeychainProbe.remove(Self.scope)
    try? FileManager.default.removeItem(at: base)
  }

  private var sentinelExists: Bool { FileManager.default.fileExists(atPath: keys.sentinel.path) }

  private func derive() throws -> Data { try keys.deriveHmacSha256(Self.message, timeoutMillis: 5_000) }

  func testDerivationCreatesAProtectedKeyOnFirstUse() throws {
    XCTAssertFalse(KeychainProbe.exists(Self.scope))
    XCTAssertFalse(sentinelExists)
    let mac = try derive()
    XCTAssertEqual(mac.count, 32)
    XCTAssertEqual(try derive(), mac)
    XCTAssertNotEqual(try keys.deriveHmacSha256(Data("other".utf8), timeoutMillis: 5_000), mac)
    XCTAssertEqual(try keys.deriveHmacSha256(Data(), timeoutMillis: 5_000).count, 32)

    let item = try XCTUnwrap(KeychainProbe.item(Self.scope))
    XCTAssertEqual(item[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    XCTAssertEqual((item[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue ?? false, false)
    let key = try XCTUnwrap(item[kSecValueData as String] as? Data)
    XCTAssertEqual(key.count, 32)
    XCTAssertEqual(Data(HMAC<SHA256>.authenticationCode(for: Self.message, using: SymmetricKey(data: key))), mac)

    // The sentinel is a non-secret file in the scope directory, excluded from backup.
    XCTAssertTrue(sentinelExists)
    XCTAssertEqual(try Data(contentsOf: keys.sentinel), Data("barometer-linkage-sentinel/1\n".utf8))
    XCTAssertEqual(try keys.sentinel.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
  }

  func testDeleteRemovesTheKeyAndSentinelAndCreatesNothing() throws {
    try keys.delete(timeoutMillis: 5_000)
    let first = try derive()
    try keys.delete(timeoutMillis: 5_000)
    XCTAssertFalse(KeychainProbe.exists(Self.scope))
    XCTAssertFalse(sentinelExists)
    try keys.delete(timeoutMillis: 5_000)
    XCTAssertFalse(KeychainProbe.exists(Self.scope))
    XCTAssertNotEqual(try derive(), first)
  }

  func testAKeyWithoutTheSentinelIsReplaced() throws {
    // A reinstall or a restored container: the Keychain item survived, the sentinel did not.
    let first = try derive()
    try FileManager.default.removeItem(at: keys.sentinel)
    let second = try derive()
    XCTAssertNotEqual(second, first)
    XCTAssertTrue(sentinelExists)
    XCTAssertEqual(try derive(), second)

    // A surviving key and no sentinel, as after a reinstall before any derivation.
    keys.close()
    let earlier = try XCTUnwrap(KeychainProbe.key(Self.scope))
    try FileManager.default.removeItem(at: base)
    keys = AppleLinkageKeys(scopeDirectory: base.appendingPathComponent(Self.scope), scope: Self.scope)
    let third = try derive()
    XCTAssertNotEqual(third, second)
    XCTAssertNotEqual(KeychainProbe.key(Self.scope), earlier)
  }

  func testAMissingOrInvalidKeyIsReplaced() throws {
    let first = try derive()
    KeychainProbe.remove(Self.scope)
    let second = try derive()
    XCTAssertNotEqual(second, first)

    XCTAssertEqual(KeychainProbe.store(Self.scope, Data(repeating: 7, count: 16)), errSecSuccess)
    let third = try derive()
    XCTAssertNotEqual(third, second)
    XCTAssertEqual(KeychainProbe.key(Self.scope)?.count, 32)
    XCTAssertEqual(try derive(), third)
  }

  func testAnInterruptedDeleteFailsAndALaterOneCompletes() throws {
    _ = try derive()
    try FileManager.default.removeItem(at: keys.sentinel)
    try FileManager.default.createDirectory(
      at: keys.sentinel.appendingPathComponent("blocker"), withIntermediateDirectories: true)
    XCTAssertThrowsError(try keys.delete(timeoutMillis: 5_000))
    XCTAssertFalse(KeychainProbe.exists(Self.scope))
    // A derivation cannot recreate a key while the sentinel's place is taken.
    XCTAssertThrowsError(try derive())
    XCTAssertFalse(KeychainProbe.exists(Self.scope))
    try FileManager.default.removeItem(at: keys.sentinel)
    try keys.delete(timeoutMillis: 5_000)
    XCTAssertFalse(sentinelExists)
  }

  func testDeadlinesAndCloseAreEnforced() throws {
    XCTAssertThrowsError(try keys.deriveHmacSha256(Self.message, timeoutMillis: 0))
    XCTAssertThrowsError(try keys.deriveHmacSha256(Self.message, timeoutMillis: 30_001))
    XCTAssertThrowsError(try keys.delete(timeoutMillis: 0))
    keys.close()
    XCTAssertThrowsError(try derive())
    XCTAssertThrowsError(try keys.delete(timeoutMillis: 5_000))
    XCTAssertFalse(KeychainProbe.exists(Self.scope))
    XCTAssertFalse(sentinelExists)
  }
}

/// The linkage key and the records across uninstall and reinstall on a simulator, driven by
/// `scripts/ios-reinstall-check.sh`, which runs `testReinstallSeed`, uninstalls the application
/// and runs `testReinstallVerify`. Both are skipped unless `BAROMETER_REINSTALL` names them.
///
/// The seed runs TCP-01 to 1.1.1.1:443 once with rotating linkage in the production location
/// (Application Support), which leaves records, a pending bundle, the Keychain key and the
/// sentinel, and prints `keyFingerprint=`, the SHA-256 of the key's HMAC of a fixed synthetic
/// message; no result and no derived value is printed. The verification checks that no
/// Barometer file survived, that initializing creates no key, and that the first derivation
/// gives another fingerprint than `BAROMETER_PREVIOUS_KEY`, so the earlier key is not used
/// again. It reports whether the Keychain item itself survived the uninstall.
final class ReinstallTests: XCTestCase {
  private static let scope = "reinstall-test"
  private static let message = Data("barometer-reinstall-check".utf8)
  private let phase = ProcessInfo.processInfo.environment["BAROMETER_REINSTALL"]

  private func fingerprint(_ store: RecordStore) throws -> String {
    let keys = AppleLinkageKeys(store)
    defer { keys.close() }
    let mac = try keys.deriveHmacSha256(Self.message, timeoutMillis: 5_000)
    return SHA256.hash(data: mac).map { String(format: "%02x", $0) }.joined()
  }

  private func scopeDir() throws -> URL {
    try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
      .appendingPathComponent("barometer/\(Self.scope)", isDirectory: true)
  }

  func testReinstallSeed() throws {
    try XCTSkipUnless(phase == "seed")
    KeychainProbe.remove(Self.scope)
    try? FileManager.default.removeItem(at: try scopeDir())
    runOffMain {
      let store = try RecordStore.open(scope: Self.scope)
      defer { try? store.close() }
      let client = try BarometerBinding.newClient(store: store, trust: try TestDocuments.trustDocument())
      defer { try? client.close() }
      try client.initialize(try TestDocuments.linkedConfig())
      let task = try TestDocuments.runTask("reinstall-seed")
      let ref = try client.installEmbeddedTask(issuer: TestDocuments.issuer, task: Data(task.utf8))
      let run = try client.startRun(try client.admitTask(task, sourceRef: ref))
      let deadline = Date().addingTimeInterval(30)
      while try client.runState(run) != "terminal" {
        if Date() > deadline { throw AdapterUnavailableError() }
        Thread.sleep(forTimeInterval: 0.01)
      }
      // The bundle stays pending.
      XCTAssertFalse(try client.nextBundle().isEmpty)
      XCTAssertTrue(KeychainProbe.exists(Self.scope), "the run created no key")
      print("keyFingerprint=\(try self.fingerprint(store))")
    }
    let records = try scopeDir().appendingPathComponent("records")
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: records.path).isEmpty)
  }

  func testReinstallVerify() throws {
    try XCTSkipUnless(phase == "verify")
    let previous = try XCTUnwrap(ProcessInfo.processInfo.environment["BAROMETER_PREVIOUS_KEY"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: try scopeDir().path), "Barometer files survived")
    let keyBefore = KeychainProbe.exists(Self.scope)
    print("keychainItemSurvived=\(keyBefore)")
    runOffMain {
      let store = try RecordStore.open(scope: Self.scope)
      defer { try? store.close() }
      let client = try BarometerBinding.newClient(store: store, trust: try TestDocuments.trustDocument())
      try client.initialize(try TestDocuments.linkedConfig())
      // Only emptiness is compared, so no result reaches the log.
      XCTAssertTrue(try client.nextBundle().isEmpty, "a pending bundle survived")
      XCTAssertEqual(KeychainProbe.exists(Self.scope), keyBefore, "initializing changed the key")
      try client.close()
      XCTAssertNotEqual(try self.fingerprint(store), previous, "the earlier key was used again")
      XCTAssertTrue(FileManager.default.fileExists(atPath: try self.scopeDir().appendingPathComponent("linkage-sentinel").path))
      let keys = AppleLinkageKeys(store)
      try keys.delete(timeoutMillis: 5_000)
      keys.close()
    }
    KeychainProbe.remove(Self.scope)
    try? FileManager.default.removeItem(at: try scopeDir())
  }
}
