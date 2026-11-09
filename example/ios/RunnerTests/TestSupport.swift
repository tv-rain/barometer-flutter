import Darwin
import Foundation
import Security
import XCTest

@testable import barometer_flutter

/// Synthetic tasks and trusted local documents shared by the lifecycle, clear-data and linkage
/// tests.
enum TestDocuments {
  static let issuer = "embedded-issuer"

  /// The connection code approved for the loopback proxy of the tests.
  static let connectionCode = "synthetic_proxy"

  /// A synthetic linkage scope.
  static let linkageScope = "org.example.barometer.test"

  static let tcpTuple: [String: Any] = ["address": "1.1.1.1", "port": 443, "scheme": "tcp"]
  static let tcpInput: [String: Any] = ["ip_address": "1.1.1.1", "port": 443]

  static func json(_ object: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
  }

  static func utc(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    return f.string(from: date)
  }

  /// `Initialize` configuration with rotating linkage under `linkageScope` and `proxyPort`.
  static func linkedConfig(proxyPort: Int? = nil) throws -> String {
    var config: [String: Any] = [
      "result_linkage": [
        "mode": "rotating_installation", "scope": linkageScope, "rotation_period_seconds": 604800,
      ]
    ]
    if let proxyPort {
      config["proxy"] = ["host": "127.0.0.1", "port": proxyPort, "connection_code": connectionCode]
    }
    return try json(config)
  }

  /// A one-time embedded TCP-01 task; `proxy` selects the proxy path.
  static func runTask(_ id: String, proxy: Bool = false) throws -> String {
    var execution: [String: Any] = ["limits": [String: Any]()]
    if proxy { execution["network_path"] = "proxy" }
    return try json([
      "schema_version": "0.1.0", "task_id": id, "test_id": "TCP-01", "test_version": "0.1.0",
      "input": tcpInput, "options": [String: Any](),
      "schedule": ["not_after": utc(Date().addingTimeInterval(86_400))],
      "execution": execution,
      "safety": ["risk_level": "low", "requires_user_consent": false],
    ])
  }

  /// A synthetic `barometer-trust/1` document permitting TCP-01 to 1.1.1.1:443 on both paths
  /// for the deployment and the embedded issuer, with the test proxy's connection code and the
  /// linkage scope approved. It is built when the test runs because the registration expires
  /// 48 hours later.
  static func trustDocument() throws -> Data {
    let testRef: [String: Any] = ["id": "TCP-01", "version": "0.1.0"]
    let paths: [String: Any] = ["direct": true, "proxy": true]
    let registration: [String: Any] = [
      "id": "reg-a", "test": testRef, "role": "measurement", "tuple": tcpTuple, "paths": paths,
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
        "endpoints": [Any](), "connection_codes": [connectionCode], "linkage_scopes": [linkageScope],
        "allow_linkage": true,
      ],
      "context_approvals": [
        "connection_codes": [Any](), "classification_versions": [Any](), "country_codes": [Any](),
        "region_codes": [Any](),
      ],
    ]
    return Data(try json(document).utf8)
  }

  /// A directory laid out like an application bundle's Barometer resources: `barometer/trust.json`
  /// and `barometer/tasks/<name>.json` for each of `tasks`.
  static func bundle(at dir: URL, trust: Data, tasks: [String: String]) throws -> Bundle {
    let tasksDir = dir.appendingPathComponent("barometer/tasks", isDirectory: true)
    try FileManager.default.createDirectory(at: tasksDir, withIntermediateDirectories: true)
    try trust.write(to: dir.appendingPathComponent("barometer/trust.json"))
    for (name, task) in tasks {
      try Data(task.utf8).write(to: tasksDir.appendingPathComponent("\(name).json"))
    }
    return try XCTUnwrap(Bundle(url: dir))
  }

  /// The first result of a bundle's JSON text.
  static func firstResult(_ raw: String) throws -> [String: Any] {
    let bundle = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    let results = try XCTUnwrap(bundle["results"] as? [[String: Any]])
    return try XCTUnwrap(results.first)
  }
}

/// Reads and removes the linkage key item of a scope, as the tests need to.
enum KeychainProbe {
  private static func query(_ scope: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: AppleLinkageKeys.service,
      kSecAttrAccount as String: scope,
      kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
    ]
  }

  /// The item's attributes and data, or nil when there is none.
  static func item(_ scope: String) -> [String: Any]? {
    var q = query(scope)
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    q[kSecReturnAttributes as String] = true
    q[kSecReturnData as String] = true
    var result: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
    return result as? [String: Any]
  }

  static func exists(_ scope: String) -> Bool { item(scope) != nil }

  static func key(_ scope: String) -> Data? { item(scope)?[kSecValueData as String] as? Data }

  static func remove(_ scope: String) {
    SecItemDelete(query(scope) as CFDictionary)
  }

  /// Stores `data` as the scope's item with the production attributes.
  static func store(_ scope: String, _ data: Data) -> OSStatus {
    remove(scope)
    var q = query(scope)
    q[kSecAttrSynchronizable as String] = kCFBooleanFalse
    q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    q[kSecValueData as String] = data
    return SecItemAdd(q as CFDictionary, nil)
  }
}

/// Background tasks under test control: `expire()` runs the expiration handler of the current
/// task on the main thread, as the system does.
final class FakeBackgroundTasks: BackgroundTasks {
  private let lock = NSLock()
  private var handlers: [Int: () -> Void] = [:]
  private var nextID = 0
  private(set) var begun = 0
  private(set) var ended: [Int] = []

  func begin(expiration: @escaping () -> Void) -> Int? {
    lock.lock()
    defer { lock.unlock() }
    nextID += 1
    begun += 1
    handlers[nextID] = expiration
    return nextID
  }

  func end(_ id: Int) {
    lock.lock()
    defer { lock.unlock() }
    precondition(handlers.removeValue(forKey: id) != nil, "a task was ended twice or never begun")
    ended.append(id)
  }

  /// Background tasks begun and not yet ended.
  var open: Int {
    lock.lock()
    defer { lock.unlock() }
    return handlers.count
  }

  var beganCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return begun
  }

  /// Runs the expiration handler of every open task; call it on the main thread.
  func expire() {
    lock.lock()
    let current = Array(handlers.values)
    lock.unlock()
    current.forEach { $0() }
  }
}

/// A loopback CONNECT proxy that never contacts the requested target and never answers: it reads
/// the request and holds the connection open, so an attempt on the proxy path stays active until
/// it is cancelled or its deadline passes.
final class StallingProxy {
  private let fd: Int32
  let port: Int
  private let lock = NSLock()
  private var held: [Int32] = []
  private var count = 0
  private var closed = false

  init() throws {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    guard sock >= 0 else { throw AdapterUnavailableError() }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0, listen(sock, 4) == 0 else {
      Darwin.close(sock)
      throw AdapterUnavailableError()
    }
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
    }
    fd = sock
    port = Int(UInt16(bigEndian: addr.sin_port))
    let listener = fd
    Thread.detachNewThread { [weak self] in
      while true {
        let client = accept(listener, nil, nil)
        if client < 0 { return }
        guard let self else {
          Darwin.close(client)
          return
        }
        self.hold(client)
        Thread.detachNewThread { self.readRequest(client) }
      }
    }
  }

  /// CONNECT requests received.
  var connects: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  private func hold(_ client: Int32) {
    lock.lock()
    defer { lock.unlock() }
    if closed {
      Darwin.close(client)
    } else {
      held.append(client)
    }
  }

  private func readRequest(_ client: Int32) {
    var header = [UInt8]()
    var byte: UInt8 = 0
    while header.count < 8192 {
      if read(client, &byte, 1) != 1 { return }
      header.append(byte)
      if header.suffix(4) == [13, 10, 13, 10] { break }
    }
    if header.starts(with: Array("CONNECT ".utf8)) {
      lock.lock()
      count += 1
      lock.unlock()
    }
    // No answer: the socket stays open until the client gives up or the proxy closes.
  }

  func close() {
    lock.lock()
    if closed {
      lock.unlock()
      return
    }
    closed = true
    let sockets = held
    held.removeAll()
    lock.unlock()
    shutdown(fd, SHUT_RDWR)
    Darwin.close(fd)
    sockets.forEach {
      shutdown($0, SHUT_RDWR)
      Darwin.close($0)
    }
  }
}

extension XCTestCase {
  /// Runs `body` on a background queue while the main run loop keeps serving, and rethrows.
  func runOffMain(timeout: TimeInterval = 90, _ body: @escaping () throws -> Void) {
    let done = expectation(description: "background")
    var failure: Error?
    DispatchQueue.global().async {
      do { try body() } catch { failure = error }
      done.fulfill()
    }
    wait(for: [done], timeout: timeout)
    if let failure { XCTFail("\(failure)") }
  }

  /// Waits on the main run loop until `condition` holds or `seconds` pass.
  func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
      if Date() > deadline { return false }
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    return true
  }
}
