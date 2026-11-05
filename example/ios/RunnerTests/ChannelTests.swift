import Flutter
import Foundation
import XCTest

@testable import barometer_flutter

/// Tests of the method-channel argument validation and of the channel host against the facade,
/// with the test bundle's trusted local document, a synthetic expired task and synthetic values
/// only. They contact no network.
final class ChannelTests: XCTestCase {
  private static let scope = "channel-test"

  private var base: URL!
  private var host: BarometerHost!
  private let mainCalls = MainCallCounter()

  override func setUpWithError() throws {
    base = FileManager.default.temporaryDirectory
      .appendingPathComponent("channel-\(UUID().uuidString)", isDirectory: true)
    let base = self.base!
    let counter = mainCalls
    host = BarometerHost(bundle: Bundle(for: Self.self)) {
      try RecordStore.open(base: base, scope: Self.scope) {
        let main = Thread.isMainThread
        if main { counter.increment() }
        return main
      }
    }
  }

  override func tearDownWithError() throws {
    _ = call("close")
    host.detach()
    XCTAssertEqual(mainCalls.value, 0, "a store call ran on the main thread")
    try? FileManager.default.removeItem(at: base)
  }

  // MARK: - Argument validation

  private func rejected(_ method: String, _ arguments: Any?, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try ChannelContract.parse(method, arguments), "\(method)", file: file, line: line) {
      XCTAssertTrue($0 is InvalidArgumentsError, file: file, line: line)
      XCTAssertEqual(ChannelContract.code($0), "invalid_arguments", file: file, line: line)
    }
  }

  private func bytes(_ data: Data) -> FlutterStandardTypedData { FlutterStandardTypedData(bytes: data) }

  func testEveryCallParses() throws {
    XCTAssertEqual(try ChannelContract.parse("initialize", ["config": "{}"]), .initialize(config: "{}"))
    XCTAssertEqual(
      try ChannelContract.parse("admitTask", ["source": "embedded", "name": "tcp-01_a"]),
      .admitEmbedded(name: "tcp-01_a"))
    XCTAssertEqual(
      try ChannelContract.parse("admitTask", ["source": "remote", "package": bytes(Data([1, 2, 3]))]),
      .admitRemote(signedPackage: Data([1, 2, 3])))
    XCTAssertEqual(try ChannelContract.parse("startRun", ["task": "T.a"]), .startRun(task: "T.a"))
    XCTAssertEqual(try ChannelContract.parse("runState", ["run": "R.a"]), .runState(run: "R.a"))
    XCTAssertEqual(try ChannelContract.parse("cancelRun", ["run": "R.a"]), .cancelRun(run: "R.a"))
    XCTAssertEqual(try ChannelContract.parse("nextBundle", nil), .nextBundle)
    XCTAssertEqual(try ChannelContract.parse("nextBundle", NSNull()), .nextBundle)
    XCTAssertEqual(try ChannelContract.parse("acknowledgeBundle", ["id": "b"]), .acknowledgeBundle(id: "b"))
    XCTAssertEqual(try ChannelContract.parse("setProxy", ["proxy": "{}"]), .setProxy(proxy: "{}"))
    XCTAssertEqual(try ChannelContract.parse("clearProxy", nil), .clearProxy)
    XCTAssertEqual(try ChannelContract.parse("clearMeasurementData", nil), .clearMeasurementData)
    XCTAssertEqual(try ChannelContract.parse("close", nil), .close)
    // The codec hands over Foundation types.
    let dictionary: NSDictionary = [NSString(string: "task"): NSString(string: "T.b")]
    XCTAssertEqual(try ChannelContract.parse("startRun", dictionary), .startRun(task: "T.b"))
  }

  func testNoCallInstallsATrustInput() throws {
    for method in [
      "installPolicy", "installTrust", "installEmbeddedTask", "installRemoteTask",
      "setIssuer", "setApprovals", "setAdapters", "replacePolicy", "newClient",
    ] {
      XCTAssertNil(try ChannelContract.parse(method, ["document": "{}"]), method)
    }
  }

  func testExtraArgumentsAreRejected() {
    let trust: [String: Any] = [
      "trust": "{}", "policy": "{}", "issuer": "embedded-issuer", "issuer_id": "x",
      "approvals": "{}", "keys": "[]", "sourceRef": "ref", "adapters": "{}",
    ]
    for (key, value) in trust {
      rejected("initialize", ["config": "{}", key: value])
      rejected("admitTask", ["source": "embedded", "name": "a", key: value])
      rejected("admitTask", ["source": "remote", "package": bytes(Data([1])), key: value])
      rejected("startRun", ["task": "T.a", key: value])
      rejected("setProxy", ["proxy": "{}", key: value])
      rejected("nextBundle", [key: value])
      rejected("close", [key: value])
    }
    rejected("startRun", [AnyHashable("task"): "T.a", AnyHashable(1): "x"])
  }

  func testMalformedArgumentsAreRejected() {
    rejected("initialize", nil)
    rejected("initialize", "{}")
    rejected("initialize", ["config": ["proxy": NSNull()]])
    rejected("initialize", ["config": ""])
    rejected("initialize", ["config": String(repeating: "x", count: ChannelContract.maxJSONChars + 1)])
    // Bounds count UTF-16 code units, as Dart and Kotlin do.
    rejected("initialize", ["config": String(repeating: "\u{1F600}", count: ChannelContract.maxJSONChars / 2 + 1)])
    rejected("initialize", [String: Any]())
    rejected("startRun", ["task": 1])
    rejected("startRun", ["task": String(repeating: "x", count: ChannelContract.maxIDChars + 1)])
    rejected("runState", ["task": "R.a"])
    rejected("cancelRun", ["run": ""])
    rejected("acknowledgeBundle", ["id": NSNull()])
    rejected("clearProxy", [String: Any]())
    rejected("admitTask", nil)
    rejected("admitTask", ["source": "local", "name": "a"])
    rejected("admitTask", ["name": "a"])
    rejected("admitTask", ["source": "remote", "package": "text"])
    rejected("admitTask", ["source": "remote", "package": Data([1])])
    rejected("admitTask", ["source": "remote", "package": bytes(Data())])
    rejected("admitTask", ["source": "remote", "package": bytes(Data(count: ChannelContract.maxDeliveryBytes + 1))])
    rejected("admitTask", ["source": "remote", "package": FlutterStandardTypedData(int32: Data(count: 4))])
    rejected("admitTask", ["source": "embedded", "package": bytes(Data([1]))])
  }

  func testEmbeddedNamesStayInTheTaskDirectory() {
    for name in ["", "../trust", "..", "a/b", "a.json", "A", "-a", "_a", "a b", "a\u{0}", String(repeating: "x", count: 65), "tâche"] {
      rejected("admitTask", ["source": "embedded", "name": name])
    }
    XCTAssertTrue(ChannelContract.isTaskName(String(repeating: "x", count: 64)))
    XCTAssertTrue(ChannelContract.isTaskName("0a_-"))
  }

  func testOnlyCheckedCodesCross() {
    let facade = NSError(domain: "go", code: 1, userInfo: [NSLocalizedDescriptionKey: "task_source_unauthenticated"])
    XCTAssertEqual(ChannelContract.code(BarometerError(facade)), "task_source_unauthenticated")
    let detail = NSError(domain: "go", code: 1, userInfo: [NSLocalizedDescriptionKey: "a detail with spaces"])
    XCTAssertEqual(ChannelContract.code(BarometerError(detail)), "native_error")
    XCTAssertEqual(ChannelContract.code(BarometerError(nil)), "native_error")
    XCTAssertEqual(ChannelContract.code(HostCodeError(code: "not_initialized")), "not_initialized")
    XCTAssertEqual(ChannelContract.code(RecordStoreError()), "native_error")
    XCTAssertEqual(ChannelContract.code(AdapterUnavailableError()), "native_error")
    XCTAssertEqual(ChannelContract.code(facade), "native_error")
  }

  func testEmbeddedIssuerIsTheOneKeylessIssuer() {
    func doc(_ issuers: [String], _ keyed: [String]) -> Data {
      let i = issuers.map { #"{"issuer_id":"\#($0)","permissions":{}}"# }.joined(separator: ",")
      let k = keyed.map { #"{"key_id":"k-\#($0)","issuer_id":"\#($0)"}"# }.joined(separator: ",")
      return Data(#"{"format":"barometer-trust/1","policy":{"issuers":[\#(i)],"keys":[\#(k)]}}"#.utf8)
    }
    XCTAssertEqual(TrustDocument.embeddedIssuer(doc(["embedded-issuer"], [])), "embedded-issuer")
    XCTAssertEqual(TrustDocument.embeddedIssuer(doc(["remote", "local"], ["remote"])), "local")
    XCTAssertNil(TrustDocument.embeddedIssuer(doc(["a", "b"], [])))
    XCTAssertNil(TrustDocument.embeddedIssuer(doc(["remote"], ["remote"])))
    XCTAssertNil(TrustDocument.embeddedIssuer(doc([], [])))
    XCTAssertNil(TrustDocument.embeddedIssuer(Data("{}".utf8)))
    XCTAssertNil(TrustDocument.embeddedIssuer(Data("not json".utf8)))
  }

  // MARK: - Call routing through the host and the facade

  /// The outcome of one call: a value or an error code.
  private struct Outcome {
    let value: Any?
    let code: String?
  }

  private func call(_ method: String, _ arguments: Any? = nil, file: StaticString = #filePath, line: UInt = #line)
    -> Outcome
  {
    let done = expectation(description: method)
    var outcome: Outcome?
    let handled = host.handle(
      method, arguments,
      BarometerHost.Reply(
        success: {
          XCTAssertTrue(Thread.isMainThread, "\(method) answered off the main thread", file: file, line: line)
          outcome = Outcome(value: $0, code: nil)
          done.fulfill()
        },
        error: {
          XCTAssertTrue(Thread.isMainThread, "\(method) answered off the main thread", file: file, line: line)
          outcome = Outcome(value: nil, code: $0)
          done.fulfill()
        }))
    XCTAssertTrue(handled, method, file: file, line: line)
    wait(for: [done], timeout: 30)
    return outcome ?? Outcome(value: nil, code: "timeout")
  }

  private func code(_ method: String, _ arguments: Any? = nil, file: StaticString = #filePath, line: UInt = #line)
    -> String?
  {
    call(method, arguments, file: file, line: line).code
  }

  private var recordsDir: URL {
    base.appendingPathComponent(Self.scope, isDirectory: true).appendingPathComponent("records", isDirectory: true)
  }

  func testNothingIsCreatedBeforeInitialize() {
    XCTAssertEqual(code("startRun", ["task": "T.x"]), "not_initialized")
    XCTAssertEqual(code("nextBundle"), "not_initialized")
    XCTAssertEqual(code("clearMeasurementData"), "not_initialized")
    XCTAssertEqual(code("setProxy", ["proxy": "{}"]), "not_initialized")
    XCTAssertFalse(FileManager.default.fileExists(atPath: recordsDir.path))
    XCTAssertNil(code("close"))
  }

  func testLifecycleRunsThroughTheChannel() {
    XCTAssertNil(code("initialize", ["config": "{}"]))
    var isDirectory: ObjCBool = false
    XCTAssertTrue(FileManager.default.fileExists(atPath: recordsDir.path, isDirectory: &isDirectory))
    XCTAssertTrue(isDirectory.boolValue)
    XCTAssertEqual(code("initialize", ["config": "{}"]), "already_initialized")
    let next = call("nextBundle")
    XCTAssertNil(next.code)
    XCTAssertNil(next.value)
    XCTAssertEqual(code("runState", ["run": "R.unknown"]), "handle_unavailable")
    XCTAssertEqual(code("cancelRun", ["run": "R.unknown"]), "handle_unavailable")
    XCTAssertEqual(code("startRun", ["task": "T.unknown"]), "handle_unavailable")
    XCTAssertEqual(code("acknowledgeBundle", ["id": "unknown"]), "bundle_unavailable")
    XCTAssertNil(code("clearProxy"))
    XCTAssertNil(code("clearMeasurementData"))
    XCTAssertNil(code("initialize", ["config": "{}"]))
    XCTAssertNil(code("close"))
    XCTAssertNil(code("close"))
    XCTAssertEqual(code("nextBundle"), "not_initialized")
    XCTAssertNil(code("initialize", ["config": "{}"]))
  }

  func testTasksAreInstalledNativelyAndAdmittedByGo() {
    XCTAssertNil(code("initialize", ["config": "{}"]))
    XCTAssertEqual(code("admitTask", ["source": "embedded", "name": "missing"]), "delivery_unavailable")
    // The expired task passes the delivery binding and provenance with the document's embedded
    // issuer, then fails a later admission step.
    let expired = code("admitTask", ["source": "embedded", "name": "expired"])
    XCTAssertTrue(expired?.hasPrefix("task_") == true, expired ?? "nil")
    XCTAssertNotEqual(expired, "task_source_unauthenticated")
    // An unsigned package is installed as a remote record and refused by verification.
    let remote: [String: Any] = ["source": "remote", "package": bytes(Data("{}".utf8))]
    XCTAssertEqual(code("admitTask", remote), "task_source_unauthenticated")
  }

  func testTrustInputsAreRefused() {
    XCTAssertEqual(code("initialize", ["config": "{}", "trust": "{}"]), "invalid_arguments")
    XCTAssertEqual(
      code("admitTask", ["source": "embedded", "name": "expired", "issuer": "x"]), "invalid_arguments")
    XCTAssertEqual(code("admitTask", ["source": "embedded", "name": "../trust"]), "invalid_arguments")
    let reply = BarometerHost.Reply(success: { _ in XCTFail("answered") }, error: { _ in XCTFail("answered") })
    XCTAssertFalse(host.handle("installPolicy", ["policy": "{}"], reply))
  }

  func testMissingTrustDocumentIsTrustInvalid() {
    let base = self.base!
    let bare = BarometerHost(bundle: Bundle(for: XCTestCase.self)) {
      try RecordStore.open(base: base, scope: "bare", isMainThread: { Thread.isMainThread })
    }
    let done = expectation(description: "initialize")
    var result: String?
    _ = bare.handle(
      "initialize", ["config": "{}"],
      BarometerHost.Reply(success: { _ in done.fulfill() }, error: { result = $0; done.fulfill() }))
    wait(for: [done], timeout: 30)
    XCTAssertEqual(result, "trust_invalid")
    bare.detach()
  }

  func testDetachedHostRefusesCalls() {
    XCTAssertNil(code("initialize", ["config": "{}"]))
    host.detach()
    XCTAssertEqual(code("nextBundle"), "client_closed")
    XCTAssertEqual(code("initialize", ["config": "{}"]), "client_closed")
  }

  func testPluginRoutesUnknownMethodsAsNotImplemented() {
    let plugin = BarometerFlutterPlugin(host: host)
    let done = expectation(description: "unknown")
    plugin.handle(FlutterMethodCall(methodName: "installPolicy", arguments: ["policy": "{}"])) {
      XCTAssertTrue(($0 as AnyObject?) === (FlutterMethodNotImplemented as AnyObject))
      done.fulfill()
    }
    let invalid = expectation(description: "invalid")
    plugin.handle(FlutterMethodCall(methodName: "startRun", arguments: ["task": "T.a", "issuer": "x"])) {
      XCTAssertEqual(($0 as? FlutterError)?.code, "invalid_arguments")
      XCTAssertNil(($0 as? FlutterError)?.message)
      XCTAssertNil(($0 as? FlutterError)?.details)
      invalid.fulfill()
    }
    let facade = expectation(description: "facade")
    plugin.handle(FlutterMethodCall(methodName: "nextBundle", arguments: nil)) {
      XCTAssertEqual(($0 as? FlutterError)?.code, "not_initialized")
      facade.fulfill()
    }
    wait(for: [done, invalid, facade], timeout: 30)
  }
}

/// Counts store calls made on the main thread, from any thread.
private final class MainCallCounter {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }
}
