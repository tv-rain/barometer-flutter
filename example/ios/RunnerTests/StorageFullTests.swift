import Darwin
import Foundation
import XCTest

@testable import barometer_flutter

/// Writes fail closed on a full disk, and clearing still removes every record class and the
/// linkage key. Run by `scripts/ios-storage-full-check.sh` on a simulator whose application data
/// container is mounted from a size-limited disk image, never on a device: the test fills the
/// volume that holds only the application's container. Skipped otherwise.
///
/// It stores a completed run's records, a pending bundle, the Keychain linkage key and the
/// sentinel, admits a second task, and then fills the volume with a filler file in the
/// application's temporary directory until a one-byte write fails. On the full volume a new task
/// is rejected, the admitted task cannot start, the stored records are unchanged and no
/// temporary file is left behind; clearing returns within 10 seconds and leaves no record, no
/// Keychain key and no sentinel. The first run contacts `1.1.1.1:443` directly so that linkage
/// derives the Keychain key; every other attempt would take the proxy path through a loopback
/// proxy that never contacts the target. No result is printed.
final class StorageFullTests: XCTestCase {
  private static let scope = "storage-full-test"

  private var filler: URL { FileManager.default.temporaryDirectory.appendingPathComponent("storage-full-filler") }

  private var scopeDir: URL {
    get throws {
      try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
      ).appendingPathComponent("barometer/\(Self.scope)", isDirectory: true)
    }
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

  private func admit(_ client: BarometerClient, _ task: String) throws -> String {
    let ref = try client.installEmbeddedTask(issuer: TestDocuments.issuer, task: Data(task.utf8))
    return try client.admitTask(task, sourceRef: ref)
  }

  /// Every record file of the scope by name, with its contents.
  private func records() throws -> [String: Data] {
    let dir = try scopeDir.appendingPathComponent("records")
    var out: [String: Data] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
      out[name] = try Data(contentsOf: dir.appendingPathComponent(name))
    }
    return out
  }

  /// Whether a new 4 KiB file still fits on the volume of the application's container.
  private func fits() -> Bool {
    let probe = FileManager.default.temporaryDirectory.appendingPathComponent("storage-full-probe")
    defer { unlink(probe.path) }
    let fd = open(probe.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    if fd < 0 { return false }
    let block = [UInt8](repeating: 0, count: 4096)
    let n = block.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    let synced = n == block.count && fsync(fd) == 0
    return Darwin.close(fd) == 0 && synced
  }

  /// Fills the volume: appends to the filler in shrinking chunks until even one byte no longer
  /// fits, and repeats while a new 4 KiB file still fits, because the system can free space
  /// meanwhile.
  private func fill() throws {
    for _ in 0..<5 {
      try append()
      if !fits() { return }
    }
  }

  private func append() throws {
    let fd = open(filler.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    guard fd >= 0 else { throw AdapterUnavailableError() }
    defer { Darwin.close(fd) }
    var chunk = 64 << 20
    let zeros = [UInt8](repeating: 0, count: chunk)
    while chunk > 0 {
      let n = zeros.withUnsafeBytes { write(fd, $0.baseAddress, chunk) }
      if n == chunk { continue }
      if n < 0 && errno != ENOSPC { throw AdapterUnavailableError() }
      chunk /= 2
    }
    fsync(fd)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: filler)
  }

  func testWritesFailClosedAndClearingCompletesOnAFullDisk() throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["BAROMETER_STORAGE_FULL_TEST"] == "1",
      "run by scripts/ios-storage-full-check.sh on a simulator")
    #if !targetEnvironment(simulator)
      throw XCTSkip("simulators only")
    #endif
    try? FileManager.default.removeItem(at: try scopeDir)
    KeychainProbe.remove(Self.scope)
    let proxy = try AnsweringProxy()
    defer { proxy.close() }
    runOffMain(timeout: 600) {
      let store = try RecordStore.open(scope: Self.scope)
      defer { try? store.close() }
      let client = try BarometerBinding.newClient(store: store, trust: try TestDocuments.trustDocument())
      defer { try? client.close() }
      try client.initialize(try TestDocuments.linkedConfig(proxyPort: proxy.port))
      // A direct-path run to 1.1.1.1:443, so that linkage derives the Keychain key.
      let run = try client.startRun(try self.admit(client, try TestDocuments.runTask("full-first")))
      let deadline = Date().addingTimeInterval(60)
      while try client.runState(run) != "terminal" {
        if Date() > deadline { throw AdapterUnavailableError() }
        Thread.sleep(forTimeInterval: 0.01)
      }
      XCTAssertNotEqual(try client.nextBundle(), "", "no pending bundle")
      let admitted = try self.admit(client, try TestDocuments.runTask("full-admitted", proxy: true))
      XCTAssertTrue(KeychainProbe.exists(Self.scope))
      let sentinel = try self.scopeDir.appendingPathComponent(AppleLinkageKeys.sentinelName)
      XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
      let before = try self.records()
      let connects = proxy.targets.count

      try self.fill()
      XCTAssertFalse(self.fits(), "the volume is not full")
      // A new task needs a replay record, and a run needs a run-ledger entry; neither fits.
      XCTAssertEqual(
        self.code { _ = try self.admit(client, try TestDocuments.runTask("full-new", proxy: true)) },
        "task_trust_unavailable")
      XCTAssertEqual(self.code { _ = try client.startRun(admitted) }, "run_not_due")
      XCTAssertEqual(try self.records(), before, "a stored record changed")
      XCTAssertEqual(proxy.targets.count, connects, "a run started on the full volume")

      let started = Date()
      try client.clearMeasurementData()
      XCTAssertLessThan(Date().timeIntervalSince(started), 10)
      XCTAssertEqual(try self.records().keys.sorted(), [])
      XCTAssertFalse(KeychainProbe.exists(Self.scope))
      XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
    }
    try? FileManager.default.removeItem(at: filler)
  }
}
