import Foundation
import XCTest

@testable import barometer_flutter

/// The local restriction inputs of the trusted local document, through the facade with the Apple
/// adapters. The `device` member gates runs on the battery state of the `Device` port: the
/// simulator's or device's own `UIDevice` reading and battery states the test sets through the
/// port's source. The `network_context` member keeps Network Context acquisition off a path it
/// does not list, while the same configuration without it acquires there. Attempts take the proxy
/// path through a loopback proxy that never contacts a target or the context endpoint, so the
/// endpoint's public address (`9.9.9.9`) is only ever named in a CONNECT request to that proxy,
/// which refuses it. No result is printed.
final class LocalPolicyTests: XCTestCase {
  private static let scope = "local-policy-test"
  private static let endpoint = "https://9.9.9.9/network-context"
  private static let endpointTarget = "9.9.9.9:443"

  private var base: URL!
  private var proxies: [AnsweringProxy] = []
  private var stores: [RecordStore] = []
  private var clients: [BarometerClient] = []

  override func setUpWithError() throws {
    base = FileManager.default.temporaryDirectory
      .appendingPathComponent("local-policy-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDownWithError() throws {
    runOffMain { self.closeClients() }
    proxies.forEach { $0.close() }
    try? FileManager.default.removeItem(at: base)
  }

  private func closeClients() {
    for c in clients.reversed() { try? c.close() }
    for s in stores.reversed() { try? s.close() }
    clients.removeAll()
    stores.removeAll()
  }

  private func newProxy() throws -> AnsweringProxy {
    let proxy = try AnsweringProxy()
    proxies.append(proxy)
    return proxy
  }

  private func document(_ change: (inout [String: Any]) throws -> Void = { _ in }) throws -> Data {
    let approved = try TestDocuments.edit(try TestDocuments.trustDocument()) { root in
      var configuration = try XCTUnwrap(root["configuration_approvals"] as? [String: Any])
      configuration["endpoints"] = [Self.endpoint]
      root["configuration_approvals"] = configuration
      var context = try XCTUnwrap(root["context_approvals"] as? [String: Any])
      context["connection_codes"] = [TestDocuments.connectionCode]
      root["context_approvals"] = context
    }
    return try TestDocuments.editPolicy(approved, change)
  }

  /// A new client over a fresh scope, initialized with `proxy` and the context endpoint; call it
  /// off the main thread.
  private func newClient(
    _ trust: Data, _ proxy: AnsweringProxy, device: ((Int64) -> BatterySnapshot)? = nil
  ) throws -> BarometerClient {
    let store = try RecordStore.open(
      base: base.appendingPathComponent("stores-\(clients.count)", isDirectory: true), scope: Self.scope,
      isMainThread: { Thread.isMainThread })
    stores.append(store)
    let client = try BarometerBinding.newClient(
      store: store, trust: trust, device: device ?? { AppleDevice().state(timeoutMillis: $0) })
    clients.append(client)
    try client.initialize(
      try TestDocuments.json(["proxy": proxy.config(), "network_context": ["primary_endpoint": Self.endpoint]]))
    return client
  }

  private func admit(_ client: BarometerClient, _ id: String, requiresContext: Bool = false) throws -> String {
    var task = try TestDocuments.taskObject(id, proxy: true)
    if requiresContext {
      var execution = try XCTUnwrap(task["execution"] as? [String: Any])
      execution["network"] = ["context": ["required_fields": ["country_code"]]]
      task["execution"] = execution
    }
    let json = try TestDocuments.json(task)
    let ref = try client.installEmbeddedTask(issuer: TestDocuments.issuer, task: Data(json.utf8))
    return try client.admitTask(json, sourceRef: ref)
  }

  /// Runs `task` to its end and returns its result.
  private func run(_ client: BarometerClient, _ task: String) throws -> [String: Any] {
    let run = try client.startRun(task)
    let deadline = Date().addingTimeInterval(60)
    while try client.runState(run) != "terminal" {
      if Date() > deadline { throw AdapterUnavailableError() }
      Thread.sleep(forTimeInterval: 0.01)
    }
    let raw = try client.nextBundle()
    let bundle = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    try client.acknowledgeBundle(try XCTUnwrap(bundle["bundle_id"] as? String))
    return try TestDocuments.firstResult(raw)
  }

  private func state(_ result: [String: Any]) -> String? {
    (result["execution"] as? [String: Any])?["state"] as? String
  }

  private func code(_ body: () throws -> Void) -> String? {
    do {
      try body()
      return nil
    } catch let e as BarometerError {
      return e.code
    } catch {
      return "\(type(of: error))"
    }
  }

  func testDeviceConstraintsGateRuns() throws {
    let proxy = try newProxy()
    let control = try newProxy()
    let production = try newProxy()
    let constrained = try document {
      $0["device"] = ["minimum_battery_percent": 50, "charging_only": true]
    }
    let free = try document()
    // The simulator's or device's own battery reading, recorded only as known or unknown.
    var reading = AppleDevice.unknown
    runOffMain { reading = AppleDevice().state(timeoutMillis: 2000) }
    let battery = Battery()
    runOffMain {
      // With the production device source, the run proceeds only if the simulator or device
      // reports a battery state that meets the constraint; an unknown state never does. A run
      // that proceeds is completed and acknowledged, so it leaves no bundle behind.
      let own = try self.newClient(constrained, production)
      let ownTask = try self.admit(own, "device-own")
      let meets = reading.percentKnown && reading.percent >= 50 && reading.chargingKnown && reading.charging
      if meets {
        XCTAssertEqual(self.state(try self.run(own, ownTask)), "completed")
      } else {
        XCTAssertEqual(self.code { _ = try own.startRun(ownTask) }, "run_not_due")
      }
      self.closeClients()

      let client = try self.newClient(constrained, proxy) { _ in battery.value }
      let task = try self.admit(client, "device-gated")
      battery.value = BatterySnapshot(percent: 80, percentKnown: true, charging: false, chargingKnown: true)
      XCTAssertEqual(self.code { _ = try client.startRun(task) }, "run_not_due")
      battery.value = BatterySnapshot(percent: 40, percentKnown: true, charging: true, chargingKnown: true)
      XCTAssertEqual(self.code { _ = try client.startRun(task) }, "run_not_due")
      battery.value = BatterySnapshot(percent: 80, percentKnown: false, charging: true, chargingKnown: true)
      XCTAssertEqual(self.code { _ = try client.startRun(task) }, "run_not_due")
      XCTAssertTrue(proxy.targets.isEmpty)
      battery.value = BatterySnapshot(percent: 80, percentKnown: true, charging: true, chargingKnown: true)
      XCTAssertEqual(self.state(try self.run(client, task)), "completed")
      self.closeClients()

      // Without the member, the same battery state does not gate the task.
      battery.value = BatterySnapshot(percent: 40, percentKnown: true, charging: false, chargingKnown: true)
      let unconstrained = try self.newClient(free, control) { _ in battery.value }
      XCTAssertEqual(self.state(try self.run(unconstrained, try self.admit(unconstrained, "device-free"))), "completed")
    }
    print("own battery: percent \(reading.percentKnown ? "known" : "unknown"), charging \(reading.chargingKnown ? "known" : "unknown")")
  }

  func testContextEligibilityKeepsAcquisitionOffUnlistedPaths() throws {
    let proxy = try newProxy()
    let open = try newProxy()
    let limited = try document {
      $0["network_context"] = ["paths": ["direct": true, "proxy": false], "endpoints": [Self.endpoint]]
    }
    let control = try document()
    runOffMain {
      let client = try self.newClient(limited, proxy)
      let plain = try self.run(client, try self.admit(client, "context-plain"))
      XCTAssertEqual(self.state(plain), "completed")
      let egress = ((plain["network_context"] as? [String: Any])?["egress"] as? [String: Any])?["status"] as? String
      XCTAssertEqual(egress, "unavailable")
      let required = try self.run(client, try self.admit(client, "context-required", requiresContext: true))
      XCTAssertEqual(self.state(required), "not_run")
      XCTAssertEqual((required["execution"] as? [String: Any])?["reason"] as? String, "network_context_unavailable")
      XCTAssertFalse(proxy.targets.contains(Self.endpointTarget))
      self.closeClients()

      // Without the member, the same configuration asks the endpoint through the proxy.
      let unlimited = try self.newClient(control, open)
      _ = try self.run(unlimited, try self.admit(unlimited, "context-control"))
      XCTAssertTrue(open.targets.contains(Self.endpointTarget), "\(open.targets)")
    }
  }
}

/// A battery state the test changes while the client reads it.
private final class Battery {
  private let lock = NSLock()
  private var current = AppleDevice.unknown

  var value: BatterySnapshot {
    get {
      lock.lock()
      defer { lock.unlock() }
      return current
    }
    set {
      lock.lock()
      current = newValue
      lock.unlock()
    }
  }
}
