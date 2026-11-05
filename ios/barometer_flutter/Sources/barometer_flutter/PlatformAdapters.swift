import Foundation
import UIKit

/// Reported for every adapter failure. Like `RecordStoreError` it carries no detail: the facade
/// maps any native error to "unavailable" or "unsatisfied", and its text never crosses.
struct AdapterUnavailableError: Error {}

/// Trusted wall-clock time for the facade's `Clock` port.
///
/// iOS sets the wall clock from the network by default ("Set Automatically") and offers no
/// public API that reports whether that setting is on, so the system wall clock is used as
/// trusted time and manual time cannot be detected. A time that is not positive is unavailable;
/// there is no fallback.
struct AppleClock {
  private let wallClock: () -> Date

  init(wallClock: @escaping () -> Date = Date.init) {
    self.wallClock = wallClock
  }

  func nowUnixMillis() throws -> Int64 {
    try Self.trusted(wallClock())
  }

  static func trusted(_ now: Date) throws -> Int64 {
    let millis = (now.timeIntervalSince1970 * 1000).rounded(.down)
    guard millis.isFinite, millis > 0, millis < Double(Int64.max) else {
      throw AdapterUnavailableError()
    }
    return Int64(millis)
  }
}

/// Consent status for the facade's `Consent` port. No host consent source exists yet, so the
/// status is always `absent`: a measurement that requires consent never runs. The query carries
/// no task value and the answer no user, account, device or consent-record identifier.
struct AppleConsent {
  static let absent = "absent"

  func status() -> String { Self.absent }
}

/// Coarse battery and charging state, each with a known flag.
struct BatterySnapshot: Equatable {
  let percent: Int64
  let percentKnown: Bool
  let charging: Bool
  let chargingKnown: Bool
}

/// Coarse battery and charging state for the facade's `Device` port, from `UIDevice`.
///
/// `UIDevice` reports the battery only while battery monitoring is on, and is read on the main
/// thread. A reading turns monitoring on, reads the level and state and restores the earlier
/// monitoring setting, all on the main queue; the calling thread waits at most `timeoutMillis`
/// and reports an unknown state if the main queue does not answer in time. Callbacks never run
/// on the main thread, so this cannot deadlock. Only the level and the charging state are read.
struct AppleDevice {
  static let unknown = BatterySnapshot(percent: 0, percentKnown: false, charging: false, chargingKnown: false)

  func state(timeoutMillis: Int64) -> BatterySnapshot {
    if Thread.isMainThread { return Self.unknown }
    let done = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var reading: BatterySnapshot?
    DispatchQueue.main.async {
      let device = UIDevice.current
      let wasMonitoring = device.isBatteryMonitoringEnabled
      device.isBatteryMonitoringEnabled = true
      let snapshot = Self.snapshot(level: device.batteryLevel, state: device.batteryState)
      device.isBatteryMonitoringEnabled = wasMonitoring
      lock.lock()
      reading = snapshot
      lock.unlock()
      done.signal()
    }
    let wait = max(1, min(timeoutMillis, Int64(RecordStore.maxTimeoutMillis)))
    if done.wait(timeout: .now() + .milliseconds(Int(wait))) == .timedOut { return Self.unknown }
    lock.lock()
    defer { lock.unlock() }
    return reading ?? Self.unknown
  }

  static func snapshot(level: Float, state: UIDevice.BatteryState) -> BatterySnapshot {
    let percentKnown = level.isFinite && level >= 0 && level <= 1
    let percent = percentKnown ? Int64((level * 100).rounded()) : 0
    let charging = state == .charging || state == .full
    let chargingKnown = charging || state == .unplugged
    return BatterySnapshot(
      percent: percent, percentKnown: percentKnown, charging: charging, chargingKnown: chargingKnown)
  }
}

/// The device's IANA time-zone identifier for the facade's `TimeZone` port.
struct AppleTimeZone {
  func identifier() throws -> String {
    let id = TimeZone.current.identifier
    if id.isEmpty { throw AdapterUnavailableError() }
    return id
  }
}
