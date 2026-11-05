import Foundation

/// Reported for every record-store failure. It carries no detail: the facade maps any native
/// error to "unavailable", and no record key, value or path leaves the store in an error.
struct RecordStoreError: Error {}

/// The Apple backend of the facade's `Records` port for one storage scope.
///
/// Records are files in an application-private directory under the application's Application
/// Support directory, never in a shared or group container. The `barometer`, scope and records
/// directories are marked `isExcludedFromBackup`, which keeps them and their contents out of
/// iCloud and device backups; Application Support is not synchronized by iCloud Drive. Nothing
/// here synchronizes, reads the clock or works in the background. One file holds one record and
/// is named by its key, `"<class>-<64 lowercase hex digits>"`. A put writes a temporary file and
/// renames it over the record, so after a process kill either the earlier value or the new one
/// is stored, never a mixture. Durability across power loss and a full disk is not claimed.
///
/// Every call runs on one serial dispatch queue, in arrival order, and the caller waits at most
/// its `timeoutMillis`. A call still queued at its deadline is withdrawn and never runs; a call
/// already running finishes before any later call starts. Either way the caller gets an error,
/// so an uncertain outcome is never reported as success, and an abandoned write cannot land
/// after a later delete (clearing) or `close()`. The facade hands calls over in the order Go
/// issues them, so arrival order is issue order. While a clearing marker (class 4) is stored,
/// puts of the other classes are refused.
///
/// A storage scope has one owner at a time, across threads and processes: a second `open` of a
/// scope that is open fails. Calls, `open` and `close` must not be made on the main thread; they
/// fail there instead of blocking it.
final class RecordStore {
  /// `persistence.MaxRecordValue`: one encoded Result Bundle plus the store header.
  static let maxRecordValue = 262_144 + 64

  /// The facade's largest callback deadline.
  static let maxTimeoutMillis: Int64 = 30_000

  /// The storage scope the plugin uses.
  static let defaultScope = "default"

  private static let clearingClass: Int64 = 4
  private static let closeBoundMillis = 5_000
  private static let tempPrefix = ".tmp-"

  /// Canonical scope directories open in this process, guarded by `ownersLock`.
  private static var owners = Set<String>()
  private static let ownersLock = NSLock()

  private let records: String
  private let ownerKey: String
  private let lockFD: Int32
  private let isMainThread: () -> Bool
  private let queue = DispatchQueue(label: "barometer-records")

  /// Guards `closed` and `released`.
  private let state = NSLock()
  private var closed = false
  private var released = false

  /// Clearing-class keys stored, used only on `queue` once `open` returns.
  private var markers = Set<String>()

  private init(records: String, ownerKey: String, lockFD: Int32, isMainThread: @escaping () -> Bool) {
    self.records = records
    self.ownerKey = ownerKey
    self.lockFD = lockFD
    self.isMainThread = isMainThread
  }

  /// Returns a copy of the value stored for `key`, or nil when none is stored.
  func get(_ key: String, timeoutMillis: Int64) throws -> Data? {
    _ = try Self.checkKey(key)
    return try serial(timeoutMillis) { try self.read(key) }
  }

  /// Atomically stores `value` for `key`, replacing any earlier value.
  func put(_ key: String, _ value: Data, timeoutMillis: Int64) throws {
    let cls = try Self.checkKey(key)
    if value.count > Self.maxRecordValue { throw RecordStoreError() }
    let copy = Data(value)
    try serial(timeoutMillis) {
      if cls != Self.clearingClass && !self.markers.isEmpty { throw RecordStoreError() }
      defer { if cls == Self.clearingClass { self.refreshMarker(key) } }
      try self.write(key, copy)
    }
  }

  /// Atomically removes `key`; removing an absent key succeeds.
  func delete(_ key: String, timeoutMillis: Int64) throws {
    let cls = try Self.checkKey(key)
    try serial(timeoutMillis) {
      defer { if cls == Self.clearingClass { self.refreshMarker(key) } }
      if unlink(self.path(key)) != 0 && errno != ENOENT { throw RecordStoreError() }
    }
  }

  /// Returns every stored key of `cls`, in any order, including unreadable records.
  func list(_ cls: Int64, timeoutMillis: Int64) throws -> [String] {
    if cls < 1 || cls > Self.clearingClass { throw RecordStoreError() }
    return try serial(timeoutMillis) { try self.keys(cls) }
  }

  /// Closes the store and releases the scope. Calls queued behind the running one fail without
  /// taking effect, and so does every later call. If the running call does not finish within
  /// the close bound, the scope stays owned and this throws, so no other owner can start while
  /// that call may still land. Repeated close succeeds once the scope is released.
  func close() throws {
    if isMainThread() { throw RecordStoreError() }
    state.lock()
    closed = true
    let done = released
    state.unlock()
    if done { return }
    let drained = DispatchSemaphore(value: 0)
    queue.async { drained.signal() }
    if drained.wait(timeout: .now() + .milliseconds(Self.closeBoundMillis)) == .timedOut {
      throw RecordStoreError()
    }
    release()
  }

  /// Runs `op` on the queue after every earlier call and waits at most `timeoutMillis`.
  /// Internal so tests can hold the queue.
  func serial<T>(_ timeoutMillis: Int64, _ op: @escaping () throws -> T) throws -> T {
    if timeoutMillis < 1 || timeoutMillis > Self.maxTimeoutMillis || isMainThread() {
      throw RecordStoreError()
    }
    let call = Call<T>()
    state.lock()
    if closed {
      state.unlock()
      throw RecordStoreError()
    }
    queue.async {
      call.run {
        if self.isClosed { throw RecordStoreError() }
        return try op()
      }
    }
    state.unlock()
    switch call.wait(timeoutMillis) {
    case .success(let value)?: return value
    // A failed call's outcome is uncertain; a timed-out one is withdrawn or still running.
    case .failure?, nil: throw RecordStoreError()
    }
  }

  private var isClosed: Bool {
    state.lock()
    defer { state.unlock() }
    return closed
  }

  private func path(_ name: String) -> String { records + "/" + name }

  private func read(_ key: String) throws -> Data? {
    let fd = Darwin.open(path(key), O_RDONLY | O_CLOEXEC)
    if fd < 0 {
      if errno == ENOENT && Self.isDirectory(records) { return nil }
      throw RecordStoreError()
    }
    defer { Darwin.close(fd) }
    var info = stat()
    if fstat(fd, &info) != 0 || info.st_size < 0 || info.st_size > Self.maxRecordValue {
      throw RecordStoreError()
    }
    var out = [UInt8](repeating: 0, count: Int(info.st_size))
    var n = 0
    while n < out.count {
      let r = out.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + n, $0.count - n) }
      if r < 0 && errno == EINTR { continue }
      if r <= 0 { throw RecordStoreError() }
      n += r
    }
    // The file grew after fstat: not a value this store wrote whole.
    var extra: UInt8 = 0
    if Darwin.read(fd, &extra, 1) != 0 { throw RecordStoreError() }
    return Data(out)
  }

  private func write(_ key: String, _ value: Data) throws {
    let temp = path(Self.tempPrefix + key)
    let fd = Darwin.open(temp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
    if fd < 0 { throw RecordStoreError() }
    var ok = value.withUnsafeBytes { bytes -> Bool in
      var n = 0
      while n < bytes.count {
        let w = Darwin.write(fd, bytes.baseAddress! + n, bytes.count - n)
        if w < 0 && errno == EINTR { continue }
        if w <= 0 { return false }
        n += w
      }
      return true
    }
    ok = ok && fsync(fd) == 0
    ok = Darwin.close(fd) == 0 && ok
    ok = ok && rename(temp, path(key)) == 0
    if !ok {
      unlink(temp)
      throw RecordStoreError()
    }
  }

  private func refreshMarker(_ key: String) {
    if access(path(key), F_OK) == 0 { markers.insert(key) } else { markers.remove(key) }
  }

  private func names() throws -> [String] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: records) else {
      throw RecordStoreError()
    }
    return names
  }

  private func keys(_ cls: Int64) throws -> [String] {
    let prefix = "\(cls)-"
    return try names().filter { $0.hasPrefix(prefix) && Self.isKey($0) }
  }

  private func release() {
    state.lock()
    defer { state.unlock() }
    if released { return }
    released = true
    // Closing the descriptor releases the flock.
    Darwin.close(lockFD)
    Self.ownersLock.lock()
    Self.owners.remove(ownerKey)
    Self.ownersLock.unlock()
  }

  private func initialize() throws {
    for name in try names() where name.hasPrefix(Self.tempPrefix) {
      // A temporary file is a write a process kill interrupted before its rename.
      if unlink(path(name)) != 0 && errno != ENOENT { throw RecordStoreError() }
    }
    markers = Set(try keys(Self.clearingClass))
  }

  /// Opens `scope` under the application's Application Support directory.
  static func open(scope: String = defaultScope) throws -> RecordStore {
    if Thread.isMainThread { throw RecordStoreError() }
    guard
      let support = try? FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    else { throw RecordStoreError() }
    return try open(
      base: support.appendingPathComponent("barometer", isDirectory: true), scope: scope,
      isMainThread: { Thread.isMainThread })
  }

  /// Opens `scope` under `base`. Tests pass their own base or main-thread check.
  static func open(base: URL, scope: String, isMainThread: @escaping () -> Bool) throws
    -> RecordStore
  {
    if isMainThread() || !isScope(scope) { throw RecordStoreError() }
    let dir = base.appendingPathComponent(scope, isDirectory: true)
    let recordsDir = dir.appendingPathComponent("records", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: recordsDir, withIntermediateDirectories: true)
      for url in [base, dir, recordsDir] { try excludeFromBackup(url) }
    } catch {
      throw RecordStoreError()
    }
    let ownerKey = dir.resolvingSymlinksInPath().standardizedFileURL.path
    ownersLock.lock()
    defer { ownersLock.unlock() }
    if owners.contains(ownerKey) { throw RecordStoreError() }
    let fd = Darwin.open(ownerKey + "/owner.lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    if fd < 0 { throw RecordStoreError() }
    // Fails while another process owns the scope.
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
      Darwin.close(fd)
      throw RecordStoreError()
    }
    let store = RecordStore(
      records: ownerKey + "/records", ownerKey: ownerKey, lockFD: fd, isMainThread: isMainThread)
    do {
      try store.initialize()
    } catch {
      store.released = true
      Darwin.close(fd)
      throw RecordStoreError()
    }
    owners.insert(ownerKey)
    return store
  }

  private static func excludeFromBackup(_ url: URL) throws {
    var url = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)
  }

  private static func isDirectory(_ path: String) -> Bool {
    var dir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
  }

  /// `[a-z0-9][a-z0-9_-]{0,63}`
  private static func isScope(_ scope: String) -> Bool {
    let b = Array(scope.utf8)
    if b.isEmpty || b.count > 64 { return false }
    for (i, c) in b.enumerated() {
      let alnum = (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39)
      if !alnum && (i == 0 || (c != 0x5F && c != 0x2D)) { return false }
    }
    return true
  }

  private static func isKey(_ name: String) -> Bool {
    let b = Array(name.utf8)
    if b.count != 66 || b[1] != 0x2D || b[0] < 0x31 || b[0] > 0x34 { return false }
    for c in b[2...] where !((c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66)) {
      return false
    }
    return true
  }

  /// Returns the class of `key` or throws when it is not a record key.
  private static func checkKey(_ key: String) throws -> Int64 {
    if !isKey(key) { throw RecordStoreError() }
    return Int64(key.utf8.first! - 0x30)
  }
}

/// One call handed to the queue. It runs at most once, and not at all once withdrawn.
private final class Call<T> {
  private let lock = NSLock()
  private let done = DispatchSemaphore(value: 0)
  private var started = false
  private var withdrawn = false
  private var result: Result<T, Error>?

  func run(_ body: () throws -> T) {
    lock.lock()
    if withdrawn {
      lock.unlock()
      return
    }
    started = true
    lock.unlock()
    let r = Result { try body() }
    lock.lock()
    result = r
    lock.unlock()
    done.signal()
  }

  /// Returns the result, or nil when the deadline passed first; a call that has not started by
  /// then is withdrawn.
  func wait(_ timeoutMillis: Int64) -> Result<T, Error>? {
    let timedOut = done.wait(timeout: .now() + .milliseconds(Int(timeoutMillis))) == .timedOut
    lock.lock()
    defer { lock.unlock() }
    if timedOut {
      if !started { withdrawn = true }
      return nil
    }
    return result
  }
}
