import Foundation
import Darwin
import Network

/// Coarse access state for the facade's `Network` port. Every field is one of the fixed values
/// the facade accepts; nothing here is an address, name, SSID, BSSID, operator, subscriber,
/// interface or other identifier.
struct AccessSnapshot: Equatable {
  let generation: Int64
  let networkType: String
  let vpn: String
  let ipv4: String
  let ipv6: String
  let validated: String
  let captivePortal: String
  let suspended: String
}

/// The Apple `Network` adapter: coarse access state and access-network generation from
/// `NWPathMonitor` and the host's suspension report, and a single-shot change watch.
///
/// The generation starts at 1 and increases whenever the path's coarse state (status, type,
/// IPv4, IPv6, VPN) or its primary interface and gateways differ from the last ones observed,
/// either by a path update or by `access()`, and whenever the suspension state changes. The
/// interface and gateways are compared inside this class only and never leave it.
///
/// - VPN: `detected` when the primary interface of a satisfied path has the type `other`, which
///   is how `NWPath` reports a tunnel interface; `not_detected` when it is Wi-Fi, cellular,
///   wired Ethernet or loopback; `unknown` without a satisfied path. Only the interface type is
///   read, never its name, so a tunnel that is not the default path (a split tunnel) is not
///   detected.
/// - Validation and captive portal: always `unknown`. iOS has no public source: `NWPath` does
///   not report validation, and the captive-network state is visible only to a hotspot helper
///   with a restricted entitlement.
/// - Suspension: `suspended` after the host reports, through `setSuspended(true)`, that the
///   background time of an active run expired, `active` otherwise. Backgrounding alone is not
///   suspension.
///
/// CoreTelephony is not used: the radio technology is not part of the access state, and its
/// carrier values are identifiers the context contract forbids.
///
/// The monitor starts on construction and is cancelled by `close()`; construct it only when a
/// client is created.
final class AppleNetwork {
  static let wifi = "wifi"
  static let cellular = "cellular"
  static let ethernet = "ethernet"
  static let other = "other"
  static let yes = "yes"
  static let no = "no"
  static let detected = "detected"
  static let notDetected = "not_detected"
  static let suspended = "suspended"
  static let active = "active"

  /// Any text the facade does not accept is unknown; this one is used on purpose.
  static let unknown = "unknown"

  /// How long `access()` waits for the monitor's first path, within its deadline.
  private static let firstPathMillis: Int64 = 1_000

  /// The coarse state of a path and the values that tell access networks apart; the interface
  /// and gateway values never leave this class.
  struct Coarse: Equatable {
    let type: String
    let ipv4: String
    let ipv6: String
    let vpn: String
    let interface: String?
    let gateways: [String]

    static let none = Coarse(type: unknown, ipv4: no, ipv6: no, vpn: unknown, interface: nil, gateways: [])

    init(type: String, ipv4: String, ipv6: String, vpn: String, interface: String?, gateways: [String]) {
      self.type = type
      self.ipv4 = ipv4
      self.ipv6 = ipv6
      self.vpn = vpn
      self.interface = interface
      self.gateways = gateways
    }

    init(_ path: NWPath) {
      guard path.status == .satisfied else {
        self = .none
        return
      }
      let type: String
      if path.usesInterfaceType(.wifi) {
        type = AppleNetwork.wifi
      } else if path.usesInterfaceType(.cellular) {
        type = AppleNetwork.cellular
      } else if path.usesInterfaceType(.wiredEthernet) {
        type = AppleNetwork.ethernet
      } else {
        type = AppleNetwork.other
      }
      let first = path.availableInterfaces.first
      let own = first.map { AppleNetwork.families(of: $0.name) } ?? (ipv4: false, ipv6: false)
      self.init(
        type: type, ipv4: path.supportsIPv4 || own.ipv4 ? AppleNetwork.yes : AppleNetwork.no,
        ipv6: path.supportsIPv6 || own.ipv6 ? AppleNetwork.yes : AppleNetwork.no,
        vpn: AppleNetwork.vpn(satisfied: true, primary: first?.type),
        interface: first.map { "\($0.type)/\($0.name)/\($0.index)" },
        gateways: path.gateways.map { "\($0)" }.sorted())
    }
  }

  /// The VPN signal of a path from its status and the type of its primary interface: a tunnel
  /// interface has the type `other`. A satisfied path without a primary interface is unknown.
  static func vpn(satisfied: Bool, primary: NWInterface.InterfaceType?) -> String {
    guard satisfied, let primary else { return unknown }
    switch primary {
    case .other: return detected
    case .wifi, .cellular, .wiredEthernet, .loopback: return notDetected
    @unknown default: return unknown
    }
  }

  /// Whether the interface `name` holds an IPv4 address, and an IPv6 address that is neither
  /// link-local nor loopback, like the Android adapter's link addresses. It complements
  /// `NWPath.supportsIPv4` and `supportsIPv6`, which the simulator reports as false on a
  /// satisfied path. The addresses are only tested and never leave this function.
  static func families(of name: String) -> (ipv4: Bool, ipv6: Bool) {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return (false, false) }
    defer { freeifaddrs(list) }
    var ipv4 = false
    var ipv6 = false
    var node = list
    while let entry = node?.pointee {
      node = entry.ifa_next
      guard let sa = entry.ifa_addr, String(cString: entry.ifa_name) == name else { continue }
      switch Int32(sa.pointee.sa_family) {
      case AF_INET:
        let first = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
          UInt8(truncatingIfNeeded: UInt32(bigEndian: $0.pointee.sin_addr.s_addr) >> 24)
        }
        let second = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
          UInt8(truncatingIfNeeded: UInt32(bigEndian: $0.pointee.sin_addr.s_addr) >> 16)
        }
        // 169.254.0.0/16 is self-assigned and 127.0.0.0/8 loopback.
        if first != 127 && !(first == 169 && second == 254) { ipv4 = true }
      case AF_INET6:
        let bytes = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 -> [UInt8] in
          var addr = sin6.pointee.sin6_addr
          return withUnsafeBytes(of: &addr) { Array($0) }
        }
        let linkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
        let loopback = bytes[0..<15].allSatisfy { $0 == 0 } && bytes[15] == 1
        if !linkLocal && !loopback { ipv6 = true }
      default:
        break
      }
    }
    return (ipv4, ipv6)
  }

  private final class Watch {
    let generation: Int64
    let observer: () -> Void
    private let lock = NSLock()
    private var active = true

    init(generation: Int64, observer: @escaping () -> Void) {
      self.generation = generation
      self.observer = observer
    }

    /// Returns true once, for the first caller, and false after `stop()`.
    func take() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      let was = active
      active = false
      return was
    }

    func stop() { _ = take() }
  }

  private let monitor: NWPathMonitor
  private let monitorQueue = DispatchQueue(label: "barometer-network-monitor")
  private let dispatcher = DispatchQueue(label: "barometer-network")
  private let currentPath: () -> NWPath?
  private let firstPath = DispatchSemaphore(value: 0)

  /// Guards every field below.
  private let lock = NSLock()
  private var watches: [Int64: Watch] = [:]
  private var nextWatchID: Int64 = 0
  private var generation: Int64 = 1
  private var last: Coarse?
  private var suspendedNow = false
  private var lastSuspended = false
  private var started = false
  private var closed = false

  init() {
    let monitor = NWPathMonitor()
    self.monitor = monitor
    self.currentPath = { [weak monitor] in monitor?.currentPath }
    monitor.pathUpdateHandler = { [weak self] path in self?.update(path) }
    monitor.start(queue: monitorQueue)
  }

  deinit {
    close()
  }

  /// Returns the current coarse access state. Before the monitor's first path it waits for it
  /// for at most one second within `timeoutMillis`, then reports what is known.
  func access(timeoutMillis: Int64) throws -> AccessSnapshot {
    lock.lock()
    let isClosed = closed
    let isStarted = started
    lock.unlock()
    if isClosed { throw AdapterUnavailableError() }
    if !isStarted && !Thread.isMainThread {
      let wait = max(0, min(timeoutMillis, Self.firstPathMillis))
      if firstPath.wait(timeout: .now() + .milliseconds(Int(wait))) == .success { firstPath.signal() }
    }
    let now = currentPath().map(Coarse.init) ?? .none
    let (gen, suspended) = observe(now)
    return AccessSnapshot(
      generation: gen, networkType: now.type, vpn: now.vpn, ipv4: now.ipv4, ipv6: now.ipv6,
      validated: Self.unknown, captivePortal: Self.unknown,
      suspended: suspended ? Self.suspended : Self.active)
  }

  /// Records whether the operating system is about to suspend the application's work, as the
  /// host learns it from an expiring background task. A change advances the generation and fires
  /// due watches.
  func setSuspended(_ suspended: Bool) {
    lock.lock()
    suspendedNow = suspended
    let now = last
    lock.unlock()
    // Before the first observation the generation stays at 1; the state is read at once then.
    if let now { _ = observe(now) }
  }

  /// Registers a single-shot watch: `observer` runs once, on this adapter's own queue, when the
  /// generation differs from `generation`, at once if it already does. Returns promptly.
  func watch(_ generation: Int64, _ observer: @escaping () -> Void) throws -> Int64 {
    if generation < 0 { throw AdapterUnavailableError() }
    let w = Watch(generation: generation, observer: observer)
    lock.lock()
    if closed {
      lock.unlock()
      throw AdapterUnavailableError()
    }
    nextWatchID += 1
    let id = nextWatchID
    let due = generation != self.generation
    if !due { watches[id] = w }
    lock.unlock()
    if due { dispatch(w) }
    return id
  }

  /// Stops a watch; its observer never runs afterwards. Never blocks.
  func stopWatch(_ id: Int64) {
    lock.lock()
    let w = watches.removeValue(forKey: id)
    lock.unlock()
    w?.stop()
  }

  /// Cancels the monitor and stops every watch.
  func close() {
    lock.lock()
    if closed {
      lock.unlock()
      return
    }
    closed = true
    let stopped = Array(watches.values)
    watches.removeAll()
    lock.unlock()
    stopped.forEach { $0.stop() }
    monitor.pathUpdateHandler = nil
    monitor.cancel()
  }

  /// Records `coarse` as a path update would, without reading the path; for tests.
  func record(_ coarse: Coarse) { _ = observe(coarse) }

  /// The current generation, without observing the path; for tests.
  var currentGeneration: Int64 {
    lock.lock()
    defer { lock.unlock() }
    return generation
  }

  private func update(_ path: NWPath) {
    lock.lock()
    let first = !started
    started = true
    lock.unlock()
    if first { firstPath.signal() }
    _ = observe(Coarse(path))
  }

  /// Records `now` and the suspension state, advancing the generation and firing due watches if
  /// either changed. Returns the generation and the suspension state it belongs to.
  private func observe(_ now: Coarse) -> (Int64, Bool) {
    lock.lock()
    let suspended = suspendedNow
    if now != last || suspended != lastSuspended {
      if last != nil { generation += 1 }
      last = now
      lastSuspended = suspended
    }
    let gen = generation
    let dueIDs = watches.filter { $0.value.generation != gen }.map { $0.key }
    let due = dueIDs.compactMap { watches.removeValue(forKey: $0) }
    lock.unlock()
    due.forEach { dispatch($0) }
    return (gen, suspended)
  }

  private func dispatch(_ w: Watch) {
    dispatcher.async {
      if w.take() { w.observer() }
    }
  }
}
