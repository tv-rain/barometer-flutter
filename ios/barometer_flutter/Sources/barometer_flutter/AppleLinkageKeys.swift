import CryptoKit
import Darwin
import Foundation
import Security

/// The Apple backend of the facade's `LinkageKeyStore` port for one storage scope: a random
/// 32-byte HMAC-SHA-256 key kept as a Keychain item, created on first use.
///
/// The item is a generic password of the service `barometer-linkage` whose account is the scope
/// name. It is stored with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so it can be read
/// by a run in the background after the first unlock and never migrates to another device
/// through a backup, and with `kSecAttrSynchronizable` false, so iCloud Keychain never copies it.
/// No access group is named, so the item goes to the application's default access group, which
/// is private to the application unless the host shares its first keychain access group. The
/// Keychain cannot compute an HMAC with a generic password, so the key is read into memory for
/// each derivation and dropped afterwards. If the item cannot be stored with these attributes
/// the derivation fails, and linkage with it; the key is never kept anywhere else.
///
/// A reinstall sentinel, a small non-secret file in the scope's directory under Application
/// Support, excluded from backup, marks the key as belonging to the current installation.
/// Keychain items survive uninstalling the application, but the sandbox container does not, so
/// a key found without the sentinel belongs to an earlier installation or a restored container:
/// it is deleted before use and replaced only when a derivation needs a key. The sentinel is
/// written before a key is created. A key that is not exactly 32 bytes, or not stored with the
/// attributes above, is invalid and replaced the same way. `delete` removes the key, then the
/// sentinel, and creates nothing.
///
/// Calls run on one serial queue, in arrival order, and the caller waits at most its
/// `timeoutMillis`. A call still queued at its deadline is withdrawn and never runs; a running
/// call finishes before any later one starts. Either way the caller gets an error, so a
/// derivation abandoned before a deletion cannot recreate the key after it. After `close()`
/// nothing runs.
final class AppleLinkageKeys {
  static let service = "barometer-linkage"
  static let sentinelName = "linkage-sentinel"
  private static let keyBytes = 32
  private static let sentinelContent = Data("barometer-linkage-sentinel/1\n".utf8)

  let account: String
  let sentinel: URL
  private let queue = DispatchQueue(label: "barometer-linkage")
  private let state = NSLock()
  private var closed = false

  /// The key store of the scope `scope` whose directory is `scopeDirectory`.
  init(scopeDirectory: URL, scope: String) {
    account = scope
    sentinel = scopeDirectory.appendingPathComponent(Self.sentinelName, isDirectory: false)
  }

  /// The key store of the record store's scope.
  convenience init(_ store: RecordStore) {
    self.init(scopeDirectory: store.scopeDirectory, scope: store.scope)
  }

  /// Returns HMAC-SHA-256 of `message` under the scope's key, creating the key if needed.
  func deriveHmacSha256(_ message: Data, timeoutMillis: Int64) throws -> Data {
    let copy = Data(message)
    return try serial(timeoutMillis) {
      if !self.sentinelExists() {
        // A key without the sentinel is orphaned: it is never used.
        try self.deleteItem()
        try self.writeSentinel()
      }
      var key = try self.readKey()
      if key == nil {
        key = try self.createKey()
      }
      guard let key else { throw AdapterUnavailableError() }
      let mac = Data(HMAC<SHA256>.authenticationCode(for: copy, using: SymmetricKey(data: key)))
      if mac.count != Self.keyBytes { throw AdapterUnavailableError() }
      return mac
    }
  }

  /// Deletes the key and the sentinel; deleting absent ones succeeds.
  func delete(timeoutMillis: Int64) throws {
    try serial(timeoutMillis) {
      try self.deleteItem()
      if try self.itemExists() { throw AdapterUnavailableError() }
      if Darwin.unlink(self.sentinel.path) != 0 && errno != ENOENT { throw AdapterUnavailableError() }
    }
  }

  /// Stops the store; queued calls and every later call fail without taking effect.
  func close() {
    state.lock()
    closed = true
    state.unlock()
  }

  private var isClosed: Bool {
    state.lock()
    defer { state.unlock() }
    return closed
  }

  private func serial<T>(_ timeoutMillis: Int64, _ op: @escaping () throws -> T) throws -> T {
    if timeoutMillis < 1 || timeoutMillis > RecordStore.maxTimeoutMillis {
      throw AdapterUnavailableError()
    }
    let call = Call<T>()
    state.lock()
    if closed {
      state.unlock()
      throw AdapterUnavailableError()
    }
    queue.async {
      call.run {
        if self.isClosed { throw AdapterUnavailableError() }
        return try op()
      }
    }
    state.unlock()
    switch call.wait(timeoutMillis) {
    case .success(let value)?: return value
    // A failed call's outcome is uncertain; a timed-out one is withdrawn or still running.
    case .failure?, nil: throw AdapterUnavailableError()
    }
  }

  // MARK: - Keychain

  /// The query of this scope's item, synchronizable or not, so that a copy stored with other
  /// attributes is found and replaced too.
  private var itemQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
    ]
  }

  private func itemExists() throws -> Bool {
    var query = itemQuery
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    switch SecItemCopyMatching(query as CFDictionary, nil) {
    case errSecSuccess: return true
    case errSecItemNotFound: return false
    default: throw AdapterUnavailableError()
    }
  }

  private func deleteItem() throws {
    let status = SecItemDelete(itemQuery as CFDictionary)
    if status != errSecSuccess && status != errSecItemNotFound { throw AdapterUnavailableError() }
  }

  /// Returns the stored key, or nil when there is none. An invalid item, or more than one, is
  /// deleted.
  private func readKey() throws -> Data? {
    // The attributes of every match first: data cannot be returned for more than one item.
    var query = itemQuery
    query[kSecMatchLimit as String] = kSecMatchLimitAll
    query[kSecReturnAttributes as String] = true
    var found: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &found)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let items = found as? [[String: Any]] else {
      throw AdapterUnavailableError()
    }
    if items.count == 1, let item = items.first, Self.hasProtection(item) {
      var one = itemQuery
      one[kSecAttrSynchronizable as String] = kCFBooleanFalse
      one[kSecMatchLimit as String] = kSecMatchLimitOne
      one[kSecReturnData as String] = true
      var data: CFTypeRef?
      let read = SecItemCopyMatching(one as CFDictionary, &data)
      if read == errSecSuccess, let key = data as? Data, key.count == Self.keyBytes { return key }
      if read != errSecSuccess && read != errSecItemNotFound { throw AdapterUnavailableError() }
    }
    try deleteItem()
    return nil
  }

  /// Whether an item is stored this device only, after first unlock, and not synchronizable.
  private static func hasProtection(_ item: [String: Any]) -> Bool {
    let accessible = item[kSecAttrAccessible as String] as? String
    let synchronizable = (item[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue ?? false
    return accessible == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String) && !synchronizable
  }

  private func createKey() throws -> Data {
    var bytes = [UInt8](repeating: 0, count: Self.keyBytes)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw AdapterUnavailableError()
    }
    let key = Data(bytes)
    bytes.withUnsafeMutableBytes { _ = memset($0.baseAddress!, 0, $0.count) }
    let attributes: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: account,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
      kSecValueData as String: key,
    ]
    guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
      throw AdapterUnavailableError()
    }
    return key
  }

  // MARK: - Sentinel

  private func sentinelExists() -> Bool {
    var info = stat()
    return Darwin.lstat(sentinel.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
  }

  /// Writes the sentinel through a temporary file, synced and excluded from backup, and a rename.
  private func writeSentinel() throws {
    let dir = sentinel.deletingLastPathComponent()
    let temp = dir.appendingPathComponent(".tmp-" + Self.sentinelName, isDirectory: false)
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let fd = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
      if fd < 0 { throw AdapterUnavailableError() }
      let written = Self.sentinelContent.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
      let synced = fsync(fd) == 0
      if Darwin.close(fd) != 0 || !synced || written != Self.sentinelContent.count {
        throw AdapterUnavailableError()
      }
      var url = temp
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try url.setResourceValues(values)
      if Darwin.rename(temp.path, sentinel.path) != 0 { throw AdapterUnavailableError() }
    } catch {
      Darwin.unlink(temp.path)
      throw AdapterUnavailableError()
    }
  }
}
