import Foundation
import UIKit
import XCTest

@testable import barometer_flutter

/// Network changes on a device's real interfaces, while a person switches Wi-Fi, airplane mode
/// or a VPN. Skipped unless `BAROMETER_NETWORK_CHANGE_TEST` is `<wait-seconds>,<window-seconds>`:
/// the test waits up to the first number of seconds for the first change and then observes for
/// the second number of seconds.
///
/// Throughout, the `Network` adapter's coarse access state is read every 250 ms, and a facade
/// client keeps one proxy-path TCP-01 attempt active at a time on a loopback proxy that never
/// answers, so every attempt ends either at its deadline or because the access generation
/// changed. The test checks that the access state holds only the fixed values, that the
/// generation advanced, and that an attempt active across a change ended with `network_changed`.
/// It prints the sequence of coarse states (network type, VPN, address families) and the
/// attempts' execution states and reasons, nothing else; no target is contacted.
final class NetworkChangeDeviceTests: XCTestCase {
  private static let scope = "network-change-test"

  private struct Coarse: Equatable, CustomStringConvertible {
    let type: String
    let vpn: String
    let ipv4: String
    let ipv6: String
    var description: String { "type=\(type) vpn=\(vpn) ipv4=\(ipv4) ipv6=\(ipv6)" }
  }

  func testObservesNetworkChanges() throws {
    let spec = ProcessInfo.processInfo.environment["BAROMETER_NETWORK_CHANGE_TEST"] ?? ""
    let parts = spec.split(separator: ",").compactMap { TimeInterval($0) }
    try XCTSkipUnless(parts.count == 2, "set BAROMETER_NETWORK_CHANGE_TEST=<wait>,<window> on a device")
    let (wait, window) = (parts[0], parts[1])
    UIApplication.shared.isIdleTimerDisabled = true
    defer { UIApplication.shared.isIdleTimerDisabled = false }

    let types: Set<String> = ["wifi", "cellular", "ethernet", "other", "unknown"]
    let tristate: Set<String> = ["yes", "no", "unknown"]
    let vpns: Set<String> = ["detected", "not_detected", "unknown"]
    let network = AppleNetwork()
    defer { network.close() }
    let proxy = try StallingProxy()
    defer { proxy.close() }
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("network-change-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let lock = NSLock()
    var stop = false
    var attempts: [String] = []
    var observeFailure: Error?
    let attemptsDone = DispatchSemaphore(value: 0)
    // One attempt at a time on the never-answering proxy, until the observation ends.
    Thread.detachNewThread {
      do {
        let store = try RecordStore.open(base: base, scope: Self.scope, isMainThread: { Thread.isMainThread })
        defer { try? store.close() }
        let client = try BarometerBinding.newClient(store: store, trust: try TestDocuments.trustDocument())
        defer { try? client.close() }
        try client.initialize(
          try TestDocuments.json([
            "proxy": ["host": "127.0.0.1", "port": proxy.port, "connection_code": TestDocuments.connectionCode]
          ]))
        var n = 0
        while true {
          lock.lock()
          let done = stop
          lock.unlock()
          if done { break }
          n += 1
          let task = try TestDocuments.runTask("network-change-\(n)", proxy: true)
          let ref = try client.installEmbeddedTask(issuer: TestDocuments.issuer, task: Data(task.utf8))
          let run = try client.startRun(try client.admitTask(task, sourceRef: ref))
          while try client.runState(run) != "terminal" { Thread.sleep(forTimeInterval: 0.05) }
          let raw = try client.nextBundle()
          let bundle = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
          try client.acknowledgeBundle(try XCTUnwrap(bundle["bundle_id"] as? String))
          let execution = try TestDocuments.firstResult(raw)["execution"] as? [String: Any]
          let line = "\(execution?["state"] ?? "?")/\(execution?["reason"] ?? "-")"
          lock.lock()
          attempts.append(line)
          lock.unlock()
        }
      } catch {
        observeFailure = error
      }
      attemptsDone.signal()
    }

    var states: [Coarse] = []
    var generations: [Int64] = []
    func sample() throws -> Bool {
      var snapshot: AccessSnapshot?
      var failure: Error?
      let read = DispatchSemaphore(value: 0)
      DispatchQueue.global().async {
        do { snapshot = try network.access(timeoutMillis: 2000) } catch { failure = error }
        read.signal()
      }
      read.wait()
      if let failure { throw failure }
      let s = try XCTUnwrap(snapshot)
      XCTAssertTrue(types.contains(s.networkType))
      XCTAssertTrue(vpns.contains(s.vpn))
      XCTAssertTrue(tristate.contains(s.ipv4) && tristate.contains(s.ipv6))
      XCTAssertEqual(s.validated, "unknown")
      XCTAssertEqual(s.captivePortal, "unknown")
      let coarse = Coarse(type: s.networkType, vpn: s.vpn, ipv4: s.ipv4, ipv6: s.ipv6)
      let changed = generations.last.map { $0 != s.generation } ?? true
      if changed {
        generations.append(s.generation)
        states.append(coarse)
        print("network change: generation +\(s.generation - generations[0]) \(coarse)")
      }
      return changed && generations.count > 1
    }

    _ = try sample()
    let waitUntil = Date().addingTimeInterval(wait)
    var started = false
    while Date() < waitUntil {
      if try sample() {
        started = true
        break
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    XCTAssertTrue(started, "no network change within \(Int(wait)) s")
    let windowEnd = Date().addingTimeInterval(started ? window : 0)
    while Date() < windowEnd {
      _ = try sample()
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    lock.lock()
    stop = true
    lock.unlock()
    proxy.close()
    XCTAssertEqual(attemptsDone.wait(timeout: .now() + 90), .success)
    if let observeFailure { throw observeFailure }
    lock.lock()
    let ended = attempts
    lock.unlock()
    print("network change: \(generations.count - 1) generation changes; attempts \(ended.joined(separator: " "))")
    XCTAssertGreaterThan(generations.count, 1)
    XCTAssertTrue(ended.contains { $0.hasSuffix("/network_changed") }, "no attempt ended with network_changed")
  }
}
