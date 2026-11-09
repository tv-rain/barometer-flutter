#if BAROMETER_UMBRELLA
  // Umbrella mode: the facade inside the host-supplied umbrella framework (see the podspec).
  import BarometerUmbrella
#else
  import Barometer
#endif
import Foundation

/// The only file that names gomobile-generated types: the `barometermobile` facade.
///
/// The types come from the standalone `Barometer.xcframework` or, in umbrella mode, from
/// the host-supplied umbrella framework. Naming a type makes the plugin link against the framework
/// without calling into Go; constructing a facade value does.
enum BarometerBinding {
  static let clientType: BarometermobileClient.Type = BarometermobileClient.self

  /// The facade `Records` callback backed by `store`.
  static func records(_ store: RecordStore) -> BarometermobileRecordsProtocol {
    StoreRecords(store)
  }

  /// Creates a facade client with the Apple adapters over `store` and the trusted local
  /// document `trust`, which must come from `TrustDocument`. It starts the network path monitor
  /// and performs no other work; nothing is measured until the lifecycle calls. The linkage key
  /// store of the store's scope is installed (`AppleLinkageKeys`); it creates no key until linkage
  /// needs one, and clearing deletes its key and sentinel. `device` reads the battery state for
  /// the `Device` port; tests replace it, the plugin uses `AppleDevice`.
  static func newClient(
    store: RecordStore, trust: Data,
    device: @escaping (Int64) -> BatterySnapshot = { AppleDevice().state(timeoutMillis: $0) }
  ) throws -> BarometerClient {
    let network = AppleNetwork()
    let keys = AppleLinkageKeys(store)
    let adapters = BarometermobileAdapters()
    adapters.records = StoreRecords(store)
    adapters.clock = ClockCallback(AppleClock())
    adapters.network = NetworkCallback(network)
    adapters.consent = ConsentCallback(AppleConsent())
    adapters.device = DeviceCallback(device)
    adapters.timeZone = TimeZoneCallback(AppleTimeZone())
    adapters.resolver = ResolverCallback(AppleResolver())
    adapters.linkageKeys = LinkageCallback(keys)
    var error: NSError?
    guard let facade = BarometermobileNewClient(adapters, trust, &error), error == nil else {
      network.close()
      keys.close()
      throw BarometerError(error)
    }
    return BarometerClient(facade: facade, network: network, keys: keys)
  }
}

/// A facade error, carrying only the facade's error code: the facade's errors are bare codes
/// such as `trust_invalid`, which gomobile reports as the error's description.
struct BarometerError: Error, Equatable {
  let code: String

  init(_ error: Error?) {
    code = (error as NSError?)?.localizedDescription ?? ""
  }
}

/// A facade client and the adapter resources it owns. `close()` closes the client, which cancels
/// its active runs, then cancels the network monitor and stops the linkage key store; close the
/// record store after this.
final class BarometerClient {
  private let facade: BarometermobileClient
  private let network: AppleNetwork
  private let keys: AppleLinkageKeys

  fileprivate init(facade: BarometermobileClient, network: AppleNetwork, keys: AppleLinkageKeys) {
    self.facade = facade
    self.network = network
    self.keys = keys
  }

  func close() throws {
    defer {
      network.close()
      keys.close()
    }
    try call { try facade.close() }
  }

  /// Reports to the network adapter whether the operating system is about to suspend the
  /// application's work; see `AppleNetwork.setSuspended`.
  func setSuspended(_ suspended: Bool) { network.setSuspended(suspended) }

  /// The network adapter's current state, for tests.
  func accessState(timeoutMillis: Int64) throws -> AccessSnapshot {
    try network.access(timeoutMillis: timeoutMillis)
  }

  func initialize(_ configJSON: String) throws { try call { try facade.initialize(configJSON) } }

  func installEmbeddedTask(issuer: String, task: Data) throws -> String {
    try string { facade.installEmbeddedTask(issuer, taskJSON: task, error: $0) }
  }

  func installRemoteTask(_ signedPackage: Data) throws -> String {
    try string { facade.installRemoteTask(signedPackage, error: $0) }
  }

  func admitTask(_ taskJSON: String, sourceRef: String) throws -> String {
    try string { facade.admitTask(taskJSON, sourceRef: sourceRef, error: $0) }
  }

  func startRun(_ taskHandle: String) throws -> String {
    try string { facade.startRun(taskHandle, error: $0) }
  }

  func runState(_ runHandle: String) throws -> String {
    try string { facade.runState(runHandle, error: $0) }
  }

  func cancelRun(_ runHandle: String) throws { try call { try facade.cancelRun(runHandle) } }

  func nextBundle() throws -> String { try string { facade.nextBundle($0) } }

  func acknowledgeBundle(_ bundleID: String) throws {
    try call { try facade.acknowledgeBundle(bundleID) }
  }

  func setProxy(_ proxyJSON: String) throws { try call { try facade.setProxy(proxyJSON) } }

  func clearProxy() throws { try call { try facade.clearProxy() } }

  func clearMeasurementData() throws { try call { try facade.clearMeasurementData() } }

  private func call(_ body: () throws -> Void) throws {
    do {
      try body()
    } catch {
      throw BarometerError(error)
    }
  }

  private func string(_ body: (NSErrorPointer) -> String) throws -> String {
    var error: NSError?
    let value = body(&error)
    if let error { throw BarometerError(error) }
    return value
  }
}

private final class ClockCallback: NSObject, BarometermobileClockProtocol {
  private let clock: AppleClock

  init(_ clock: AppleClock) {
    self.clock = clock
  }

  func nowUnixMillis(_ timeoutMillis: Int64, ret0_: UnsafeMutablePointer<Int64>?) throws {
    guard let ret0_ else { throw AdapterUnavailableError() }
    ret0_.pointee = try clock.nowUnixMillis()
  }
}

private final class ConsentCallback: NSObject, BarometermobileConsentProtocol {
  private let consent: AppleConsent

  init(_ consent: AppleConsent) {
    self.consent = consent
  }

  func status(_ timeoutMillis: Int64, error: NSErrorPointer) -> String {
    consent.status()
  }
}

private final class DeviceCallback: NSObject, BarometermobileDeviceProtocol {
  private let device: (Int64) -> BatterySnapshot

  init(_ device: @escaping (Int64) -> BatterySnapshot) {
    self.device = device
  }

  func state(_ timeoutMillis: Int64) throws -> BarometermobileDeviceState {
    let s = device(timeoutMillis)
    guard
      let state = BarometermobileNewDeviceState(s.percent, s.percentKnown, s.charging, s.chargingKnown)
    else { throw AdapterUnavailableError() }
    return state
  }
}

private final class TimeZoneCallback: NSObject, BarometermobileTimeZoneProtocol {
  private let zone: AppleTimeZone

  init(_ zone: AppleTimeZone) {
    self.zone = zone
  }

  /// A failure is reported through `error`, and the returned text is then ignored.
  func identifier(_ timeoutMillis: Int64, error: NSErrorPointer) -> String {
    guard let id = try? zone.identifier() else {
      error?.pointee = NSError(domain: "barometer", code: 1)
      return ""
    }
    return id
  }
}

private final class ResolverCallback: NSObject, BarometermobileSystemResolverProtocol {
  private let resolver: AppleResolver

  init(_ resolver: AppleResolver) {
    self.resolver = resolver
  }

  func lookupNetIP(_ network: String?, host: String?, timeoutMillis: Int64) throws
    -> BarometermobileStringList
  {
    guard let network, let host, let list = BarometermobileNewStringList() else {
      throw AdapterUnavailableError()
    }
    for address in try resolver.lookupNetIP(network: network, host: host, timeoutMillis: timeoutMillis) {
      list.add(address)
    }
    return list
  }
}

private final class NetworkCallback: NSObject, BarometermobileNetworkProtocol {
  private let network: AppleNetwork

  init(_ network: AppleNetwork) {
    self.network = network
  }

  func access(_ timeoutMillis: Int64) throws -> BarometermobileAccessState {
    let s = try network.access(timeoutMillis: timeoutMillis)
    guard
      let state = BarometermobileNewAccessState(
        s.generation, s.networkType, s.vpn, s.ipv4, s.ipv6, s.validated, s.captivePortal,
        s.suspended)
    else { throw AdapterUnavailableError() }
    return state
  }

  func watch(
    _ generation: Int64, observer: (any BarometermobileNetworkObserverProtocol)?,
    ret0_: UnsafeMutablePointer<Int64>?
  ) throws {
    guard let observer, let ret0_ else { throw AdapterUnavailableError() }
    ret0_.pointee = try network.watch(generation) { observer.changed() }
  }

  func stopWatch(_ watchID: Int64) {
    network.stopWatch(watchID)
  }
}

/// Adapts `RecordStore` to the facade callback. Every failure surfaces as the store's
/// detail-free error, which the facade reports as unavailable.
private final class StoreRecords: NSObject, BarometermobileRecordsProtocol {
  private let store: RecordStore

  init(_ store: RecordStore) {
    self.store = store
  }

  /// A key the store does not hold is the facade's absent value: Swift cannot return nil here
  /// without throwing, and the facade reads a nil return as unavailable.
  func get(_ key: String?, timeoutMillis: Int64) throws -> BarometermobileRecordValue {
    guard let key else { throw RecordStoreError() }
    let value: BarometermobileRecordValue?
    if let data = try store.get(key, timeoutMillis: timeoutMillis) {
      value = BarometermobileNewRecordValue(data)
    } else {
      value = BarometermobileNewAbsentRecordValue()
    }
    guard let value else { throw RecordStoreError() }
    return value
  }

  func put(_ key: String?, value: Data?, timeoutMillis: Int64) throws {
    guard let key else { throw RecordStoreError() }
    try store.put(key, value ?? Data(), timeoutMillis: timeoutMillis)
  }

  func delete(_ key: String?, timeoutMillis: Int64) throws {
    guard let key else { throw RecordStoreError() }
    try store.delete(key, timeoutMillis: timeoutMillis)
  }

  func list(_ class: Int64, timeoutMillis: Int64) throws -> BarometermobileStringList {
    let keys = try store.list(`class`, timeoutMillis: timeoutMillis)
    guard let list = BarometermobileNewStringList() else { throw RecordStoreError() }
    for key in keys { list.add(key) }
    return list
  }
}

private final class LinkageCallback: NSObject, BarometermobileLinkageKeyStoreProtocol {
  private let keys: AppleLinkageKeys

  init(_ keys: AppleLinkageKeys) {
    self.keys = keys
  }

  func deriveHMACSHA256(_ message: Data?, timeoutMillis: Int64) throws -> Data {
    try keys.deriveHmacSha256(message ?? Data(), timeoutMillis: timeoutMillis)
  }

  func delete(_ timeoutMillis: Int64) throws {
    try keys.delete(timeoutMillis: timeoutMillis)
  }
}
