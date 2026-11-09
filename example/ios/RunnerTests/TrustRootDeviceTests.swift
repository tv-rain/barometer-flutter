import Darwin
import Foundation
import Network
import Security
import XCTest

@testable import barometer_flutter

/// The trust roots of the Go library inside the application process, through the facade.
///
/// The case runs TLS-01 twice on one client: directly to `8.8.8.8:443` with server name
/// `dns.google`, which Go's system roots must verify, and on the proxy path through a loopback
/// CONNECT proxy in this process that answers the handshake itself with a leaf for the same name
/// issued by a synthetic CA. Only the reported `certificate_validation` is checked; no result is
/// printed.
///
/// `scripts/ios-trust-root-check.sh` generates the synthetic CA and leaf at run time and passes
/// them through the environment, so no key is committed: `BAROMETER_TRUST_IDENTITY` is the leaf
/// and its key as base64 PKCS #12 under `BAROMETER_TRUST_IDENTITY_PASSWORD`, and
/// `BAROMETER_TRUST_SCENARIO` names the state of the device's trust store:
///
/// - `none`: the synthetic CA is not installed. The leaf is rejected.
/// - `profile-untrusted`: the CA is installed by a configuration profile and full trust for it is
///   off in Settings. The leaf is rejected.
/// - `profile-trusted`: the same profile with full trust on. The platform verifier accepts the
///   leaf, and so does Go.
///
/// Without the environment the test is skipped.
final class TrustRootDeviceTests: XCTestCase {
  private static let scope = "trust-root-device-test"
  private static let address = "8.8.8.8"
  private static let serverName = "dns.google"

  private var base: URL!
  private var store: RecordStore?
  private var client: BarometerClient?
  private var proxy: InterceptingProxy?

  override func setUpWithError() throws {
    base = FileManager.default.temporaryDirectory
      .appendingPathComponent("trust-root-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDownWithError() throws {
    runOffMain {
      try? self.client?.close()
      try? self.store?.close()
    }
    proxy?.close()
    try? FileManager.default.removeItem(at: base)
  }

  func testRootSetFollowsThePlatformTrustStore() throws {
    let env = ProcessInfo.processInfo.environment
    guard let scenario = env["BAROMETER_TRUST_SCENARIO"],
      let encoded = env["BAROMETER_TRUST_IDENTITY"],
      let password = env["BAROMETER_TRUST_IDENTITY_PASSWORD"]
    else {
      throw XCTSkip("run by scripts/ios-trust-root-check.sh")
    }
    let intercepted: String
    switch scenario {
    case "none", "profile-untrusted": intercepted = "untrusted"
    case "profile-trusted": intercepted = "trusted"
    default: throw XCTSkip("unknown BAROMETER_TRUST_SCENARIO")
    }
    let identity = try Self.identity(try XCTUnwrap(Data(base64Encoded: encoded)), password: password)
    let proxy = try InterceptingProxy(identity: identity, target: "\(Self.address):443")
    self.proxy = proxy

    runOffMain {
      let tuple: [String: Any] = [
        "address": Self.address, "port": 443, "scheme": "tls", "tls_server_name": Self.serverName,
      ]
      let input: [String: Any] = ["ip_address": Self.address, "port": 443, "server_name": Self.serverName]
      let store = try RecordStore.open(base: self.base, scope: Self.scope, isMainThread: { Thread.isMainThread })
      self.store = store
      let client = try BarometerBinding.newClient(
        store: store, trust: try TestDocuments.trustDocument(test: "TLS-01", tuple: tuple))
      self.client = client
      try client.initialize(try TestDocuments.json(["proxy": proxy.config()]))

      let direct = try TestDocuments.runTask("trust-direct", test: "TLS-01", input: input)
      XCTAssertEqual(try self.validation(client, direct), "trusted", "direct")
      XCTAssertEqual(proxy.connects, 0)
      let viaProxy = try TestDocuments.runTask("trust-proxy", proxy: true, test: "TLS-01", input: input)
      XCTAssertEqual(try self.validation(client, viaProxy), intercepted, "intercepted (\(scenario))")
      XCTAssertEqual(proxy.connects, 1)
    }
  }

  /// Runs `task` and returns the `certificate_validation` of its TLS handshake observation.
  private func validation(_ client: BarometerClient, _ task: String) throws -> String {
    let ref = try client.installEmbeddedTask(issuer: TestDocuments.issuer, task: Data(task.utf8))
    let run = try client.startRun(try client.admitTask(task, sourceRef: ref))
    let deadline = Date().addingTimeInterval(60)
    while try client.runState(run) != "terminal" {
      if Date() > deadline { throw AdapterUnavailableError() }
      Thread.sleep(forTimeInterval: 0.01)
    }
    let raw = try client.nextBundle()
    let bundle = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    try client.acknowledgeBundle(try XCTUnwrap(bundle["bundle_id"] as? String))
    let result = try TestDocuments.firstResult(raw)
    let execution = try XCTUnwrap(result["execution"] as? [String: Any])
    XCTAssertEqual(execution["state"] as? String, "completed", "\(execution["reason"] ?? "")")
    let measurement = try XCTUnwrap(result["measurement"] as? [String: Any])
    for o in try XCTUnwrap(measurement["observations"] as? [[String: Any]]) where o["type"] as? String == "tls_handshake" {
      return try XCTUnwrap((o["details"] as? [String: Any])?["certificate_validation"] as? String)
    }
    throw AdapterUnavailableError()
  }

  private static func identity(_ pkcs12: Data, password: String) throws -> SecIdentity {
    var items: CFArray?
    let status = SecPKCS12Import(
      pkcs12 as CFData, [kSecImportExportPassphrase as String: password] as CFDictionary, &items)
    XCTAssertEqual(status, errSecSuccess, "PKCS #12 import")
    let first = try XCTUnwrap((items as? [[String: Any]])?.first)
    let identity = try XCTUnwrap(first[kSecImportItemIdentity as String])
    return identity as! SecIdentity
  }
}

/// A loopback CONNECT proxy that never contacts the requested target: it accepts the tunnel for
/// `target` and splices it to a loopback TLS listener that answers the handshake with the
/// synthetic leaf.
private final class InterceptingProxy {
  private let fd: Int32
  let port: Int
  private let target: String
  private let tls: NWListener
  private let tlsPort: UInt16
  private let queue: DispatchQueue
  private let lock = NSLock()
  private var count = 0
  private var sockets: [Int32] = []
  private var connections: [NWConnection] = []
  private var closed = false

  init(identity: SecIdentity, target: String) throws {
    self.target = target
    let queue = DispatchQueue(label: "trust-root-tls")
    self.queue = queue
    let options = NWProtocolTLS.Options()
    sec_protocol_options_set_local_identity(
      options.securityProtocolOptions, try XCTUnwrap(sec_identity_create(identity)))
    let parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    tls = try NWListener(using: parameters)
    let ready = DispatchSemaphore(value: 0)
    tls.stateUpdateHandler = { state in
      if case .ready = state { ready.signal() }
    }
    var held: (NWConnection) -> Void = { _ in }
    tls.newConnectionHandler = { held($0) }
    tls.start(queue: queue)
    guard ready.wait(timeout: .now() + 10) == .success, let listening = tls.port?.rawValue else {
      tls.cancel()
      throw AdapterUnavailableError()
    }
    tlsPort = listening

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
      tls.cancel()
      throw AdapterUnavailableError()
    }
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
    }
    fd = sock
    port = Int(UInt16(bigEndian: addr.sin_port))

    // The TLS side answers the handshake and then waits for the client to close.
    held = { [weak self] connection in
      guard let self else { return connection.cancel() }
      self.lock.lock()
      self.connections.append(connection)
      self.lock.unlock()
      connection.start(queue: self.queue)
      connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in connection.cancel() }
    }
    let listener = fd
    Thread.detachNewThread { [weak self] in
      while true {
        let client = accept(listener, nil, nil)
        if client < 0 { return }
        guard let self, self.track(client) else {
          Darwin.close(client)
          return
        }
        Thread.detachNewThread { self.serve(client) }
      }
    }
  }

  /// CONNECT requests for the target that were tunneled.
  var connects: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func config() -> [String: Any] {
    ["host": "127.0.0.1", "port": port, "connection_code": TestDocuments.connectionCode]
  }

  private func track(_ socket: Int32) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if closed { return false }
    sockets.append(socket)
    return true
  }

  private func serve(_ client: Int32) {
    var header = [UInt8]()
    var byte: UInt8 = 0
    while !(header.count >= 4 && header.suffix(4) == [13, 10, 13, 10]) {
      if header.count > 8192 || read(client, &byte, 1) != 1 { return }
      header.append(byte)
    }
    guard String(decoding: header, as: UTF8.self).hasPrefix("CONNECT \(target) ") else {
      shutdown(client, SHUT_RDWR)
      return
    }
    let upstream = socket(AF_INET, SOCK_STREAM, 0)
    guard upstream >= 0, track(upstream) else { return }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = tlsPort.bigEndian
    let connected = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(upstream, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard connected == 0 else {
      shutdown(client, SHUT_RDWR)
      return
    }
    lock.lock()
    count += 1
    lock.unlock()
    let reply = Array("HTTP/1.1 200 Connection established\r\n\r\n".utf8)
    guard write(client, reply, reply.count) == reply.count else { return }
    Thread.detachNewThread { Self.pump(from: upstream, to: client) }
    Self.pump(from: client, to: upstream)
  }

  /// Copies bytes until either side closes, then shuts both down.
  private static func pump(from source: Int32, to sink: Int32) {
    var buffer = [UInt8](repeating: 0, count: 16384)
    while true {
      let n = read(source, &buffer, buffer.count)
      if n <= 0 || write(sink, buffer, n) != n { break }
    }
    shutdown(source, SHUT_RDWR)
    shutdown(sink, SHUT_RDWR)
  }

  func close() {
    lock.lock()
    if closed {
      lock.unlock()
      return
    }
    closed = true
    let open = sockets
    let tlsConnections = connections
    sockets.removeAll()
    connections.removeAll()
    lock.unlock()
    shutdown(fd, SHUT_RDWR)
    Darwin.close(fd)
    open.forEach {
      shutdown($0, SHUT_RDWR)
      Darwin.close($0)
    }
    tlsConnections.forEach { $0.cancel() }
    tls.cancel()
  }
}
