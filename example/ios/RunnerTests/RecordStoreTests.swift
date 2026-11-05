import Foundation
import XCTest

@testable import barometer_flutter

/// Simulator tests of `RecordStore` and its facade adapter, with synthetic values only.
final class RecordStoreTests: XCTestCase {
  private var base: URL!
  private var opened: [RecordStore] = []
  private let background = DispatchQueue(label: "record-store-tests", attributes: .concurrent)

  override func setUpWithError() throws {
    base = FileManager.default.temporaryDirectory
      .appendingPathComponent("record-store-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDownWithError() throws {
    for s in opened { try? s.close() }
    opened.removeAll()
    try? FileManager.default.removeItem(at: base)
  }

  private func open(_ scope: String = "test", main: @escaping () -> Bool = { false }) throws
    -> RecordStore
  {
    let s = try RecordStore.open(base: base, scope: scope, isMainThread: main)
    opened.append(s)
    return s
  }

  private func key(_ cls: Int, _ n: Int) -> String {
    "\(cls)-" + String(repeating: "0", count: 64 - String(n, radix: 16).count) + String(n, radix: 16)
  }

  private var recordsDir: URL { base.appendingPathComponent("test/records", isDirectory: true) }

  private func recordFiles() throws -> Set<String> {
    Set(try FileManager.default.contentsOfDirectory(atPath: recordsDir.path))
  }

  /// Runs `body` off the main thread and returns a wait for its result.
  private func inBackground<T>(_ body: @escaping () throws -> T) -> () -> Result<T, Error> {
    let done = DispatchSemaphore(value: 0)
    var result: Result<T, Error>!
    background.async {
      result = Result { try body() }
      done.signal()
    }
    return {
      XCTAssertEqual(done.wait(timeout: .now() + 20), .success)
      return result
    }
  }

  /// Holds the store's queue until the returned semaphore is signalled.
  private func hold(_ s: RecordStore, _ timeoutMillis: Int64 = 10_000) -> DispatchSemaphore {
    let held = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    background.async {
      _ = try? s.serial(timeoutMillis) {
        held.signal()
        release.wait()
      }
    }
    XCTAssertEqual(held.wait(timeout: .now() + 5), .success)
    return release
  }

  private func millis(since start: DispatchTime) -> UInt64 {
    (DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
  }

  func testStoresReplacesAndDeletes() throws {
    let s = try open()
    XCTAssertNil(try s.get(key(1, 1), timeoutMillis: 1000))
    try s.put(key(1, 1), Data([1, 2]), timeoutMillis: 1000)
    XCTAssertEqual(try s.get(key(1, 1), timeoutMillis: 1000), Data([1, 2]))
    try s.put(key(1, 1), Data([3]), timeoutMillis: 1000)
    XCTAssertEqual(try s.get(key(1, 1), timeoutMillis: 1000), Data([3]))
    try s.put(key(1, 2), Data(), timeoutMillis: 1000)
    XCTAssertEqual(try s.get(key(1, 2), timeoutMillis: 1000), Data())
    try s.delete(key(1, 1), timeoutMillis: 1000)
    try s.delete(key(1, 1), timeoutMillis: 1000)  // deleting an absent key succeeds
    XCTAssertNil(try s.get(key(1, 1), timeoutMillis: 1000))
    XCTAssertEqual(try recordFiles(), [key(1, 2)])
  }

  func testListsOnlyTheRequestedClass() throws {
    let s = try open()
    for cls in 1...4 { try s.put(key(cls, cls), Data([UInt8(cls)]), timeoutMillis: 1000) }
    try s.delete(key(4, 4), timeoutMillis: 1000)
    try s.put(key(2, 9), Data([9]), timeoutMillis: 1000)
    // A stray file that is not a record key is never listed.
    try Data([0]).write(to: recordsDir.appendingPathComponent("2-stray"))
    XCTAssertEqual(Set(try s.list(2, timeoutMillis: 1000)), [key(2, 2), key(2, 9)])
    XCTAssertEqual(try s.list(1, timeoutMillis: 1000), [key(1, 1)])
    XCTAssertEqual(try s.list(4, timeoutMillis: 1000), [])
  }

  func testRejectsInvalidInput() throws {
    let s = try open()
    let zeros = String(repeating: "0", count: 64)
    let z63 = String(zeros.dropLast())
    let z61 = String(zeros.dropLast(3))
    let upper = String(repeating: "A", count: 64)
    let bads: [String] = [
      "", "0-\(zeros)", "5-\(zeros)", "1-\(z63)", "1-\(upper)", "1_\(zeros)", "1-../\(z61)",
      "11-\(z63)", "1-\(z63)é",
    ]
    for bad in bads {
      XCTAssertThrowsError(try s.get(bad, timeoutMillis: 1000))
      XCTAssertThrowsError(try s.put(bad, Data(), timeoutMillis: 1000))
      XCTAssertThrowsError(try s.delete(bad, timeoutMillis: 1000))
    }
    XCTAssertThrowsError(try s.list(0, timeoutMillis: 1000))
    XCTAssertThrowsError(try s.list(5, timeoutMillis: 1000))
    XCTAssertThrowsError(
      try s.put(key(3, 1), Data(count: RecordStore.maxRecordValue + 1), timeoutMillis: 1000))
    try s.put(key(3, 1), Data(count: RecordStore.maxRecordValue), timeoutMillis: 1000)
    for t: Int64 in [0, -1, RecordStore.maxTimeoutMillis + 1] {
      XCTAssertThrowsError(try s.get(key(1, 1), timeoutMillis: t))
    }
    for scope in ["", "A", "../x", "a/b", "-a", String(repeating: "x", count: 65)] {
      XCTAssertThrowsError(try RecordStore.open(base: base, scope: scope, isMainThread: { false }))
    }
  }

  func testAnOversizedStoredValueIsUnavailable() throws {
    let s = try open()
    try Data(count: RecordStore.maxRecordValue + 1)
      .write(to: recordsDir.appendingPathComponent(key(3, 1)))
    XCTAssertThrowsError(try s.get(key(3, 1), timeoutMillis: 1000))
  }

  func testSurvivesReopenAndRemovesInterruptedWrites() throws {
    let first = try open()
    try first.put(key(1, 1), Data([5]), timeoutMillis: 1000)
    try first.close()
    // A write a process kill interrupted before its rename.
    try Data([6, 6]).write(to: recordsDir.appendingPathComponent(".tmp-" + key(1, 1)))
    let s = try open()
    XCTAssertEqual(try s.get(key(1, 1), timeoutMillis: 1000), Data([5]))
    XCTAssertEqual(try recordFiles(), [key(1, 1)])
  }

  func testOneOwnerPerScope() throws {
    let s = try open()
    XCTAssertThrowsError(try open())
    // The owner lock is a flock, which also refuses another process's descriptor.
    let lockPath = base.appendingPathComponent("test/owner.lock").path
    let other = Darwin.open(lockPath, O_RDWR)
    XCTAssertGreaterThanOrEqual(other, 0)
    defer { Darwin.close(other) }
    XCTAssertNotEqual(flock(other, LOCK_EX | LOCK_NB), 0)
    try open("other").close()
    try s.close()
    try s.close()  // repeated close succeeds
    XCTAssertEqual(flock(other, LOCK_EX | LOCK_NB), 0)
    flock(other, LOCK_UN)
    try open().put(key(1, 1), Data([1]), timeoutMillis: 1000)
  }

  func testAStaleCloseDoesNotReleaseANewOwner() throws {
    let s = try open()
    try s.close()
    let next = try open()
    try s.close()
    XCTAssertThrowsError(try open())
    try next.put(key(1, 1), Data([1]), timeoutMillis: 1000)
  }

  func testRefusesTheMainThread() throws {
    XCTAssertTrue(Thread.isMainThread)
    XCTAssertThrowsError(try RecordStore.open(scope: "main-thread-test"))
    XCTAssertThrowsError(try open(main: { true }))
    let opening = inBackground { try self.open(main: { Thread.isMainThread }) }
    let real = try opening().get()
    XCTAssertThrowsError(try real.get(key(1, 1), timeoutMillis: 1000))
    XCTAssertThrowsError(try real.put(key(1, 1), Data([1]), timeoutMillis: 1000))
    XCTAssertThrowsError(try real.delete(key(1, 1), timeoutMillis: 1000))
    XCTAssertThrowsError(try real.list(1, timeoutMillis: 1000))
    XCTAssertThrowsError(try real.close())
    let off = inBackground { try real.get(self.key(1, 1), timeoutMillis: 1000) }
    XCTAssertNil(try off().get())
  }

  func testACallPastItsDeadlineFailsWithinIt() throws {
    let s = try open()
    let release = hold(s)
    let start = DispatchTime.now()
    XCTAssertThrowsError(try s.get(key(1, 1), timeoutMillis: 100))
    let waited = millis(since: start)
    XCTAssertTrue((100...1000).contains(waited), "waited \(waited) ms")
    release.signal()
    XCTAssertNil(try s.get(key(1, 1), timeoutMillis: 1000))
  }

  func testAQueuedWriteAbandonedAtItsDeadlineNeverLands() throws {
    let s = try open()
    let release = hold(s)
    XCTAssertThrowsError(try s.put(key(1, 1), Data([1]), timeoutMillis: 50))
    let cleared = inBackground { try s.delete(self.key(1, 1), timeoutMillis: 5000) }
    release.signal()
    XCTAssertNoThrow(try cleared().get())
    XCTAssertNil(try s.get(key(1, 1), timeoutMillis: 1000))
    XCTAssertEqual(try s.list(1, timeoutMillis: 1000), [])
  }

  func testARunningWriteAbandonedAtItsDeadlineLandsBeforeALaterClear() throws {
    let s = try open()
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let k = key(2, 1)
    let file = recordsDir.appendingPathComponent(k)
    // A write that starts, stalls past its caller's deadline and then lands.
    let write = inBackground {
      try s.serial(200) {
        started.signal()
        release.wait()
        try Data([1]).write(to: file)
      }
    }
    started.wait()
    let delete = inBackground { try s.delete(k, timeoutMillis: 5000) }
    Thread.sleep(forTimeInterval: 0.3)
    release.signal()
    XCTAssertThrowsError(try write().get(), "an abandoned call must report an error") {
      XCTAssertTrue($0 is RecordStoreError)
    }
    XCTAssertNoThrow(try delete().get())
    XCTAssertNil(try s.get(k, timeoutMillis: 1000))
  }

  func testCloseWithdrawsQueuedCallsAndRejectsLaterOnes() throws {
    let s = try open()
    let release = hold(s)
    let queued = inBackground { try s.put(self.key(1, 1), Data([1]), timeoutMillis: 10_000) }
    Thread.sleep(forTimeInterval: 0.05)
    let closing = inBackground { try s.close() }
    Thread.sleep(forTimeInterval: 0.05)
    release.signal()
    XCTAssertNoThrow(try closing().get())
    XCTAssertThrowsError(try queued().get(), "a call queued behind close must fail")
    XCTAssertThrowsError(try s.get(key(1, 1), timeoutMillis: 1000))
    XCTAssertNil(try open().get(key(1, 1), timeoutMillis: 1000))
  }

  func testAStalledCallKeepsTheScopeOwnedAfterClose() throws {
    let s = try open()
    let release = hold(s, 30_000)
    XCTAssertThrowsError(try s.close())  // the close bound is 5 s
    XCTAssertThrowsError(try open())
    release.signal()
    try s.close()
    try open().close()
  }

  func testAClearingMarkerBlocksOtherWrites() throws {
    let s = try open()
    let marker = key(4, 1)
    try s.put(key(1, 1), Data([1]), timeoutMillis: 1000)
    try s.put(marker, Data([1, 4]), timeoutMillis: 1000)
    for cls in 1...3 { XCTAssertThrowsError(try s.put(key(cls, 2), Data([1]), timeoutMillis: 1000)) }
    try s.put(key(4, 2), Data([1]), timeoutMillis: 1000)
    try s.delete(key(1, 1), timeoutMillis: 1000)
    try s.delete(key(4, 2), timeoutMillis: 1000)
    XCTAssertThrowsError(try s.put(key(1, 1), Data([1]), timeoutMillis: 1000))
    try s.delete(marker, timeoutMillis: 1000)
    try s.put(key(1, 1), Data([1]), timeoutMillis: 1000)
    try s.close()
    // A marker left by an interrupted clear still blocks after reopening.
    try Data([9]).write(to: recordsDir.appendingPathComponent(marker))
    XCTAssertThrowsError(try open().put(key(2, 1), Data([1]), timeoutMillis: 1000))
  }

  func testTheFacadeAdapterStoresListsAndClearsEveryClass() throws {
    let s = try open()
    let records = BarometerBinding.records(s)
    // An absent key is the facade's opaque absent value, never nil.
    XCTAssertNotNil(try records.get(key(1, 1), timeoutMillis: 1000))
    for cls in 1...3 {
      for n in 1...3 {
        try records.put(key(cls, n), value: Data([UInt8(cls), UInt8(n)]), timeoutMillis: 1000)
      }
    }
    XCTAssertNotNil(try records.get(key(2, 2), timeoutMillis: 1000))
    XCTAssertEqual(try s.get(key(2, 2), timeoutMillis: 1000), Data([2, 2]))
    XCTAssertNotNil(try records.list(3, timeoutMillis: 1000))
    XCTAssertThrowsError(try records.get("1-x", timeoutMillis: 1000))
    XCTAssertThrowsError(try records.get(nil, timeoutMillis: 1000))
    XCTAssertThrowsError(try records.list(9, timeoutMillis: 1000))

    // The facade's clearing sequence over the adapter: marker, classes newest first, marker last.
    let marker = key(4, 1)
    try records.put(marker, value: Data([1, 4]), timeoutMillis: 1000)
    XCTAssertThrowsError(try records.put(key(1, 9), value: Data([1]), timeoutMillis: 1000))
    for cls: Int64 in [3, 2, 1] {
      for k in try s.list(cls, timeoutMillis: 1000) { try records.delete(k, timeoutMillis: 1000) }
      XCTAssertEqual(try s.list(cls, timeoutMillis: 1000), [])
    }
    try records.delete(marker, timeoutMillis: 1000)
    for cls: Int64 in 1...4 { XCTAssertEqual(try s.list(cls, timeoutMillis: 1000), []) }
    XCTAssertEqual(try recordFiles(), [])
  }

  func testRecordsAreApplicationPrivateAndExcludedFromBackup() throws {
    let scope = "location-test"
    let support = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let dir = support.appendingPathComponent("barometer/\(scope)", isDirectory: true)
    try? FileManager.default.removeItem(at: dir)
    let store = inBackground { try RecordStore.open(scope: scope) }
    let s = try store().get()
    opened.append(s)
    let write = inBackground { try s.put(self.key(1, 1), Data([1]), timeoutMillis: 1000) }
    try write().get()

    let file = dir.appendingPathComponent("records/" + key(1, 1))
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
    let resolved = file.resolvingSymlinksInPath().path
    XCTAssertTrue(resolved.hasPrefix(home + "/Library/Application Support/barometer/"), resolved)
    XCTAssertFalse(resolved.contains("/Shared/AppGroup/"), resolved)
    for url in [
      support.appendingPathComponent("barometer", isDirectory: true), dir,
      dir.appendingPathComponent("records", isDirectory: true),
    ] {
      XCTAssertEqual(
        try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true,
        url.lastPathComponent)
    }
    let close = inBackground { try s.close() }
    try close().get()
    try FileManager.default.removeItem(at: dir)
  }
}

/// The process-kill check. `scripts/ios-record-store-kill-test.sh` runs `testKillWriter` with
/// `BAROMETER_KILL_TEST=write`, which SIGKILLs its own test process in the middle of large
/// writes, and then `testKillVerify` with `BAROMETER_KILL_TEST=verify` in a new process.
/// Both are skipped in an ordinary test run.
final class RecordStoreKillTests: XCTestCase {
  private static let scope = "kill-test"
  private static let fixed = "1-" + String(repeating: "ab", count: 32)
  private static let churn = "3-" + String(repeating: "cd", count: 32)
  private static let fixedValue = Data((0..<1024).map { UInt8($0 & 0xFF) })
  private static let churnSize = RecordStore.maxRecordValue

  private var mode: String? { ProcessInfo.processInfo.environment["BAROMETER_KILL_TEST"] }

  private func scopeDir() throws -> URL {
    try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ).appendingPathComponent("barometer/\(Self.scope)", isDirectory: true)
  }

  func testKillWriter() throws {
    try XCTSkipUnless(mode == "write", "run by scripts/ios-record-store-kill-test.sh")
    try? FileManager.default.removeItem(at: try scopeDir())
    let target = Int(ProcessInfo.processInfo.environment["BAROMETER_KILL_AFTER"] ?? "") ?? 5
    let progress = NSLock()
    var written = 0
    let ready = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      do {
        let store = try RecordStore.open(scope: Self.scope)
        try store.put(Self.fixed, Self.fixedValue, timeoutMillis: 5000)
        var n = 0
        while true {
          let fill = UInt8(n % 2 == 0 ? 0x41 : 0x42)
          try store.put(Self.churn, Data(repeating: fill, count: Self.churnSize), timeoutMillis: 5000)
          n += 1
          progress.lock()
          written = n
          progress.unlock()
          if n == target { ready.signal() }
        }
      } catch {
        ready.signal()
      }
    }
    XCTAssertEqual(ready.wait(timeout: .now() + 60), .success)
    progress.lock()
    let done = written
    progress.unlock()
    XCTAssertGreaterThanOrEqual(done, target, "the writer failed")
    // Land at an arbitrary point of the next writes.
    Thread.sleep(forTimeInterval: Double.random(in: 0...0.02))
    kill(getpid(), SIGKILL)
  }

  func testKillVerify() throws {
    try XCTSkipUnless(mode == "verify", "run by scripts/ios-record-store-kill-test.sh")
    let opened = DispatchSemaphore(value: 0)
    var outcome: Result<(Data?, Data?, [String]), Error>!
    DispatchQueue.global().async {
      outcome = Result {
        let s = try RecordStore.open(scope: Self.scope)
        defer { try? s.close() }
        let names = try FileManager.default.contentsOfDirectory(
          atPath: try self.scopeDir().appendingPathComponent("records").path)
        return (
          try s.get(Self.fixed, timeoutMillis: 5000), try s.get(Self.churn, timeoutMillis: 5000),
          names
        )
      }
      opened.signal()
    }
    XCTAssertEqual(opened.wait(timeout: .now() + 30), .success)
    let (fixed, churn, names) = try outcome.get()
    XCTAssertEqual(fixed, Self.fixedValue)
    let value = try XCTUnwrap(churn)
    XCTAssertEqual(value.count, Self.churnSize)
    let fill = value.first
    XCTAssertTrue(fill == 0x41 || fill == 0x42)
    XCTAssertTrue(value.allSatisfy { $0 == fill }, "a mixed value")
    // Opening removed any interrupted temporary file.
    XCTAssertEqual(Set(names), [Self.fixed, Self.churn])
  }
}
