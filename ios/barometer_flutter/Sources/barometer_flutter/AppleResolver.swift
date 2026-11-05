import Darwin
import Foundation

/// Ordinary per-name platform lookup for the facade's `SystemResolver` port, through
/// `getaddrinfo`. The lookup runs on its own thread and the caller waits at most its
/// `timeoutMillis`; a lookup still running at the deadline is abandoned, and its answer is
/// discarded. At most four lookups run at once; a further one fails. Any lookup failure,
/// including an unknown name, is an error, which the facade records as DNS-01
/// `resolver_error`, as on Android. An answer with no address of the requested family is empty.
/// Addresses are returned in canonical text without zone, and scoped IPv6 addresses are dropped.
final class AppleResolver {
  private static let maxLookups = 4

  private let lookup: (String, Int32) throws -> [[UInt8]]
  private let slots = DispatchSemaphore(value: maxLookups)

  init(lookup: @escaping (String, Int32) throws -> [[UInt8]] = AppleResolver.getaddrinfoLookup) {
    self.lookup = lookup
  }

  func lookupNetIP(network: String, host: String, timeoutMillis: Int64) throws -> [String] {
    let family: Int32
    switch network {
    case "ip": family = AF_UNSPEC
    case "ip4": family = AF_INET
    case "ip6": family = AF_INET6
    default: throw AdapterUnavailableError()
    }
    let name = host.hasSuffix(".") ? String(host.dropLast()) : host
    if name.isEmpty || timeoutMillis < 1 || Self.isLiteral(name) { throw AdapterUnavailableError() }
    if slots.wait(timeout: .now()) == .timedOut { throw AdapterUnavailableError() }

    let done = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var answer: Result<[[UInt8]], Error>?
    let lookup = self.lookup
    let slots = self.slots
    let worker = Thread {
      let result = Result { try lookup(name, family) }
      lock.lock()
      answer = result
      lock.unlock()
      slots.signal()
      done.signal()
    }
    worker.name = "barometer-resolver"
    worker.start()

    let wait = min(timeoutMillis, Int64(Int32.max))
    if done.wait(timeout: .now() + .milliseconds(Int(wait))) == .timedOut {
      throw AdapterUnavailableError()
    }
    lock.lock()
    let result = answer
    lock.unlock()
    guard case .success(let raw)? = result else { throw AdapterUnavailableError() }
    var seen = Set<String>()
    var out: [String] = []
    for bytes in raw {
      guard let text = Self.canonical(bytes) else { continue }
      if seen.insert(text).inserted { out.append(text) }
    }
    return out
  }

  /// A literal would be returned without any lookup, so it is not a name to resolve.
  static func isLiteral(_ name: String) -> Bool {
    name.contains(":") || name.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") }
  }

  /// Canonical address text: dotted IPv4 for 4 bytes, RFC 5952 IPv6 for 16 bytes.
  static func canonical(_ bytes: [UInt8]) -> String? {
    switch bytes.count {
    case 4: return bytes.map(String.init).joined(separator: ".")
    case 16: return canonicalIPv6(bytes)
    default: return nil
    }
  }

  static func canonicalIPv6(_ bytes: [UInt8]) -> String {
    precondition(bytes.count == 16)
    let groups = (0..<8).map { (Int(bytes[2 * $0]) << 8) | Int(bytes[2 * $0 + 1]) }
    var bestStart = -1
    var bestLen = 0
    var i = 0
    while i < 8 {
      if groups[i] == 0 {
        var j = i
        while j < 8 && groups[j] == 0 { j += 1 }
        if j - i > bestLen {
          bestStart = i
          bestLen = j - i
        }
        i = j
      } else {
        i += 1
      }
    }
    if bestLen < 2 { bestStart = -1 }
    var out = ""
    i = 0
    while i < 8 {
      if i == bestStart {
        out += "::"
        i += bestLen
        continue
      }
      if !out.isEmpty && !out.hasSuffix(":") { out += ":" }
      out += String(groups[i], radix: 16)
      i += 1
    }
    return out
  }

  /// One `getaddrinfo` call for stream sockets of `family`. Returns the raw address bytes,
  /// leaving out scoped IPv6 addresses.
  static func getaddrinfoLookup(_ name: String, _ family: Int32) throws -> [[UInt8]] {
    var hints = addrinfo()
    hints.ai_family = family
    hints.ai_socktype = SOCK_STREAM
    var list: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(name, nil, &hints, &list) == 0 else { throw AdapterUnavailableError() }
    defer { freeaddrinfo(list) }
    var out: [[UInt8]] = []
    var node = list
    while let ai = node?.pointee {
      if let sa = ai.ai_addr {
        switch Int32(sa.pointee.sa_family) {
        case AF_INET:
          sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
            var addr = sin.pointee.sin_addr
            out.append(withUnsafeBytes(of: &addr) { Array($0) })
          }
        case AF_INET6:
          sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
            if sin6.pointee.sin6_scope_id == 0 {
              var addr = sin6.pointee.sin6_addr
              out.append(withUnsafeBytes(of: &addr) { Array($0) })
            }
          }
        default:
          break
        }
      }
      node = ai.ai_next
    }
    return out
  }
}
