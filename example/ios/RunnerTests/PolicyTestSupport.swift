import CryptoKit
import Darwin
import Flutter
import Foundation
import XCTest

@testable import barometer_flutter

extension TestDocuments {
  /// The issuer of signed remote tasks, added by `withRemoteIssuer`.
  static let remoteIssuer = "remote-issuer"

  /// `document` with `change` applied to its parsed root object.
  static func edit(_ document: Data, _ change: (inout [String: Any]) throws -> Void) throws -> Data {
    var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: document) as? [String: Any])
    try change(&root)
    return Data(try json(root).utf8)
  }

  /// `document` with `change` applied to its `policy` object.
  static func editPolicy(_ document: Data, _ change: (inout [String: Any]) throws -> Void) throws -> Data {
    try edit(document) { root in
      var policy = try XCTUnwrap(root["policy"] as? [String: Any])
      try change(&policy)
      root["policy"] = policy
    }
  }

  /// `document` with policy generation `generation`.
  static func withGeneration(_ document: Data, _ generation: Int64) throws -> Data {
    try editPolicy(document) { $0["generation"] = generation }
  }

  /// `document` with `remoteIssuer`, permitted like the embedded issuer, and the trusted `keys`.
  /// The embedded issuer stays the only issuer without a key.
  static func withRemoteIssuer(_ document: Data, keys: [[String: Any]]) throws -> Data {
    try editPolicy(document) { policy in
      var issuers = try XCTUnwrap(policy["issuers"] as? [[String: Any]])
      let permissions = try XCTUnwrap(issuers.first?["permissions"])
      issuers.append(["issuer_id": remoteIssuer, "permissions": permissions])
      policy["issuers"] = issuers
      policy["keys"] = (policy["keys"] as? [Any] ?? []) + keys.map { $0 as Any }
    }
  }

  /// `document` without the registration, in the policy and in every issuer's permissions.
  static func withoutRegistration(_ document: Data) throws -> Data {
    try editPolicy(document) { policy in
      policy["targets"] = [Any]()
      var permissions = try XCTUnwrap(policy["permissions"] as? [String: Any])
      permissions["registration_ids"] = [Any]()
      policy["permissions"] = permissions
      let issuers = try XCTUnwrap(policy["issuers"] as? [[String: Any]])
      policy["issuers"] = try issuers.map { issuer -> [String: Any] in
        var copy = issuer
        var p = try XCTUnwrap(copy["permissions"] as? [String: Any])
        p["registration_ids"] = [Any]()
        copy["permissions"] = p
        return copy
      }
    }
  }

  /// A TCP-01 task for the proxy path or the default path, as a JSON object, so tests can add
  /// members before serializing it.
  static func taskObject(_ id: String, proxy: Bool = false) throws -> [String: Any] {
    try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(runTask(id, proxy: proxy).utf8)) as? [String: Any])
  }
}

/// Builds synthetic signed remote task packages. Each key derives from a fixed public test seed
/// (byte `i` of the seed is `label ^ i`, as in the Go test kit), so it is not a deployment key and
/// confers no authority outside these tests. CryptoKit signs; the native library verifies.
struct TestSigner {
  let keyID: String
  let issuerID: String
  private let key: Curve25519.Signing.PrivateKey

  init(keyID: String, issuerID: String, seed: Data) throws {
    self.keyID = keyID
    self.issuerID = issuerID
    key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
  }

  /// A signer whose seed derives from the one-byte `label`.
  init(keyID: String, issuerID: String, label: UInt8) throws {
    try self.init(keyID: keyID, issuerID: issuerID, seed: Data((0..<32).map { label ^ UInt8($0) }))
  }

  /// The 32-byte public key.
  var publicKey: Data { key.publicKey.rawRepresentation }

  /// The trusted key record of the policy, valid from `notBefore` to `notAfter`.
  func keyRecord(notBefore: Date, notAfter: Date) -> [String: Any] {
    [
      "key_id": keyID, "issuer_id": issuerID, "public_key": publicKey.base64EncodedString(),
      "not_before": TestDocuments.utc(notBefore), "not_after": TestDocuments.utc(notAfter),
    ]
  }

  /// A package of `task` issued at `issuedAt`; `alter` changes the task member after signing.
  func sign(_ task: Data, issuedAt: Date, alter: (Data) throws -> Data = { $0 }) throws -> Data {
    let issued = TestDocuments.utc(issuedAt)
    let signature = try key.signature(for: Self.message(keyID, issuerID, issued, task))
    return Data(
      try TestDocuments.json([
        "issuer_id": issuerID, "key_id": keyID, "issued_at": issued,
        "task": Self.url(try alter(task)), "signature": Self.url(signature),
      ]).utf8)
  }

  /// M of the signed-task message construction: each part prefixed by its 4-byte big-endian
  /// length.
  static func message(_ keyID: String, _ issuerID: String, _ issuedAt: String, _ task: Data) -> Data {
    var out = Data()
    for part in [Data("barometer-signed-task-v1".utf8), Data(keyID.utf8), Data(issuerID.utf8), Data(issuedAt.utf8), task] {
      var length = UInt32(part.count).bigEndian
      out.append(Data(bytes: &length, count: 4))
      out.append(part)
    }
    return out
  }

  private static func url(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

/// A loopback CONNECT proxy that never contacts any target. It answers `200` to a CONNECT for one
/// of `open`, then holds the tunnel until the client closes it, so a TCP-01 attempt on the proxy
/// path completes without leaving the simulator; any other CONNECT gets `502` and is closed. It
/// records every CONNECT target it receives.
final class AnsweringProxy {
  private let fd: Int32
  let port: Int
  private let open: Set<String>
  private let lock = NSLock()
  private var held: [Int32] = []
  private var received: [String] = []
  private var closed = false

  init(open: Set<String> = ["1.1.1.1:443"]) throws {
    self.open = open
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    guard sock >= 0 else { throw AdapterUnavailableError() }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0, listen(sock, 8) == 0 else {
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
        guard let self, self.hold(client) else {
          Darwin.close(client)
          return
        }
        Thread.detachNewThread { self.serve(client) }
      }
    }
  }

  /// The CONNECT targets received, in order.
  var targets: [String] {
    lock.lock()
    defer { lock.unlock() }
    return received
  }

  /// The `proxy` member of a configuration for this proxy with `code`.
  func config(code: String = TestDocuments.connectionCode) -> [String: Any] {
    ["host": "127.0.0.1", "port": port, "connection_code": code]
  }

  private func hold(_ client: Int32) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if closed { return false }
    held.append(client)
    return true
  }

  private func serve(_ client: Int32) {
    var header = [UInt8]()
    var byte: UInt8 = 0
    while !(header.count >= 4 && header.suffix(4) == [13, 10, 13, 10]) {
      if header.count > 8192 || read(client, &byte, 1) != 1 { return }
      header.append(byte)
    }
    let line = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n")[0].split(separator: " ")
    guard line.count == 3, line[0] == "CONNECT" else { return }
    let target = String(line[1])
    lock.lock()
    received.append(target)
    lock.unlock()
    if !open.contains(target) {
      write(client, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
      shutdown(client, SHUT_RDWR)
      return
    }
    write(client, "HTTP/1.1 200 Connection established\r\n\r\n")
    // The tunnel leads nowhere: discard what arrives until the client closes it.
    var sink = [UInt8](repeating: 0, count: 4096)
    while read(client, &sink, sink.count) > 0 {}
  }

  private func write(_ client: Int32, _ text: String) {
    let bytes = Array(text.utf8)
    _ = bytes.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
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

/// Makes channel calls on a `BarometerHost` from the main thread and spins the main run loop
/// until each answer arrives, as the Dart side waits for it.
final class ChannelCaller {
  /// The outcome of one call: a value or an error code.
  struct Outcome {
    let value: Any?
    let code: String?
  }

  let host: BarometerHost

  init(_ host: BarometerHost) {
    self.host = host
  }

  func call(_ method: String, _ arguments: Any? = nil, file: StaticString = #filePath, line: UInt = #line)
    -> Outcome
  {
    var outcome: Outcome?
    let handled = host.handle(
      method, arguments,
      BarometerHost.Reply(
        success: { outcome = Outcome(value: $0, code: nil) }, error: { outcome = Outcome(value: nil, code: $0) }))
    XCTAssertTrue(handled, method, file: file, line: line)
    let deadline = Date().addingTimeInterval(60)
    while outcome == nil && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    return outcome ?? Outcome(value: nil, code: "timeout")
  }

  /// The error code of a call, or nil when it succeeded.
  func code(_ method: String, _ arguments: Any? = nil, file: StaticString = #filePath, line: UInt = #line)
    -> String?
  {
    call(method, arguments, file: file, line: line).code
  }

  func initialize(_ config: String, file: StaticString = #filePath, line: UInt = #line) -> String? {
    code("initialize", ["config": config], file: file, line: line)
  }

  func admitRemote(_ signedPackage: Data, file: StaticString = #filePath, line: UInt = #line) -> Outcome {
    call(
      "admitTask", ["source": "remote", "package": FlutterStandardTypedData(bytes: signedPackage)], file: file,
      line: line)
  }

  func admitEmbedded(_ name: String, file: StaticString = #filePath, line: UInt = #line) -> Outcome {
    call("admitTask", ["source": "embedded", "name": name], file: file, line: line)
  }

  /// The run's state, or the error code.
  func state(_ run: String) -> String? {
    let outcome = call("runState", ["run": run])
    return (outcome.value as? [String: Any])?["state"] as? String ?? outcome.code
  }

  /// Reads and acknowledges the oldest pending bundle, or returns nil when none is pending.
  func takeBundle() throws -> [String: Any]? {
    let next = call("nextBundle")
    XCTAssertNil(next.code)
    guard let data = (next.value as? FlutterStandardTypedData)?.data else { return nil }
    let bundle = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertNil(code("acknowledgeBundle", ["id": try XCTUnwrap(bundle["bundle_id"] as? String)]))
    return bundle
  }
}

/// A trusted local document that tests change between `initialize` calls.
final class DocumentBox {
  private let lock = NSLock()
  private var bytes = Data()

  var document: Data {
    get {
      lock.lock()
      defer { lock.unlock() }
      return bytes
    }
    set {
      lock.lock()
      bytes = newValue
      lock.unlock()
    }
  }
}
