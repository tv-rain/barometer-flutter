import Foundation
import XCTest

@testable import barometer_flutter

/// The strict JSON reader of the native glue against the Go library's shared decoder rules, and
/// the two values the glue reads from the trusted local document (`policy.generation` and the
/// embedded issuer) against the facade itself: for each synthetic document, the host reads a value
/// exactly when the facade accepts the document, and the same value. Rejected documents leave no
/// client, store, admission or bundle through the channel host. Nothing contacts the network.
final class StrictJSONTests: XCTestCase {
  private static let scope = "strict-json-test"
  private let limits = StrictJSON.Limits(maxBytes: 4096, maxDepth: 4, maxNodes: 32)

  private var base: URL!
  private var hosts: [BarometerHost] = []

  override func setUpWithError() throws {
    base = FileManager.default.temporaryDirectory
      .appendingPathComponent("strict-json-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDownWithError() throws {
    for host in hosts {
      _ = ChannelCaller(host).code("close")
      host.detach()
    }
    hosts.removeAll()
    try? FileManager.default.removeItem(at: base)
  }

  // MARK: - Reader

  private func decode(_ text: String) throws -> StrictJSON.Value {
    try StrictJSON.decode(Data(text.utf8), limits: limits)
  }

  private func rejects(_ input: Data, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(
      try StrictJSON.decode(input, limits: limits), String(decoding: input, as: UTF8.self), file: file, line: line)
  }

  private func rejects(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
    rejects(Data(text.utf8), file: file, line: line)
  }

  private func string(_ value: StrictJSON.Value?) -> String? {
    value?.bytes.map { String(decoding: $0, as: UTF8.self) }
  }

  func testNamesAreUniqueAfterUnescaping() throws {
    rejects(#"{"a":1,"a":1}"#)
    rejects(#"{"a":1,"a":2}"#)
    rejects(#"{"a":1,"a":2}"#)
    rejects(#"{"\/":1,"/":2}"#)
    rejects(#"{"o":{"a":1,"a":2}}"#)
    rejects(#"[{"a":1,"a":2}]"#)
    // Escaped spellings are the same name; case variants are not.
    XCTAssertEqual(string(try decode(#"{"a":"b"}"#)["a"]), "b")
    let cased = try decode(#"{"a":1,"A":2}"#)
    XCTAssertEqual(cased["a"]?.integer(in: 0...9), 1)
    XCTAssertEqual(cased["A"]?.integer(in: 0...9), 2)
    // Canonically equivalent names are different names, as in Go; Swift's String equality
    // would merge them.
    let forms = try decode("{\"\u{e9}\":1,\"e\u{301}\":2}")
    XCTAssertEqual(forms["\u{e9}"]?.integer(in: 0...9), 1)
    if case .object(let o) = forms { XCTAssertEqual(o.members.count, 2) } else { XCTFail("not an object") }
    XCTAssertEqual(try decode(#"[{"a":null},{"a":null}]"#).array?.count, 2)
  }

  func testFramingAndText() throws {
    rejects(Data([0xef, 0xbb, 0xbf]) + Data("{}".utf8))
    for text in [
      "{}{}", "{} x", "{,}", #"{"a":1,}"#, "[1,]", "", "{'a':1}", #"{"a":NaN}"#, #"{"a":Infinity}"#,
      #"{"a":tru}"#, "{\u{0c}}", "\"a\u{01}\"", "{\"a\u{00}\":1}", #""\ud800""#, #""\udc00""#,
      #""\ud800A""#, #""\x41""#, #""\u00g0""#, "\"abc",
    ] {
      rejects(text)
    }
    func quoted(_ bytes: [UInt8]) -> Data { Data([0x22] + bytes + [0x22]) }
    for bytes: [UInt8] in [[0xff], [0xc0, 0xaf], [0xed, 0xa0, 0x80], [0xe2, 0x82], [0xf4, 0x90, 0x80, 0x80]] {
      rejects(quoted(bytes))
    }
    XCTAssertEqual(string(try StrictJSON.decode(quoted([0xc3, 0xa9]), limits: limits)), "\u{e9}")
    XCTAssertEqual(string(try decode(#""😀""#)), "\u{1F600}")
    XCTAssertEqual(string(try decode(#""\u0000\"\\\/\b\f\n\r\t""#)), "\u{0}\"\\/\u{8}\u{c}\n\r\t")
    XCTAssertEqual(string(try decode("\"\u{fffd}\"")), "\u{fffd}")
    if case .object(let o) = try decode(" \t\r\n{ }\n") { XCTAssertTrue(o.members.isEmpty) } else { XCTFail("not an object") }
    XCTAssertEqual(try decode("[true,false,null]").array?.count, 3)
  }

  func testIntegersHaveOneSpelling() throws {
    func integer(_ token: String, _ range: ClosedRange<Int64> = Int64.min...Int64.max) throws -> Int64? {
      try decode(token).integer(in: range)
    }
    XCTAssertEqual(try integer("0"), 0)
    XCTAssertEqual(try integer("-1"), -1)
    XCTAssertEqual(try integer("9007199254740993"), 9_007_199_254_740_993)
    XCTAssertEqual(try integer("9223372036854775807"), Int64.max)
    XCTAssertEqual(try integer("-9223372036854775808"), Int64.min)
    for token in ["-0", "1.0", "1e0", "1E0", "1e+0", "0.5e1", "10e-1", "9223372036854775808", "-9223372036854775809"] {
      XCTAssertNil(try integer(token), token)
    }
    XCTAssertNil(try integer("0", 1...9))
    XCTAssertNil(try integer("8", 0...7))
    XCTAssertNil(try decode(#""1""#).integer(in: 0...9))
    XCTAssertNil(try decode("true").integer(in: 0...9))
    for token in ["01", "+1", "-", "1.", ".5", "1e", "0x1", "- 1"] { rejects(token) }
  }

  func testBoundsAreTheCallers() throws {
    rejects("[[[[[]]]]]")
    XCTAssertNotNil(try decode("[[[[]]]]").array)
    rejects("[" + String(repeating: "0,", count: 31) + "0]")
    XCTAssertEqual(try decode("[" + String(repeating: "0,", count: 30) + "0]").array?.count, 31)
    let padded = "\"" + String(repeating: "a", count: 4094) + "\""
    XCTAssertEqual(try decode(padded).bytes?.count, 4094)
    rejects(padded + " ")
  }

  // MARK: - Trusted local document against the facade

  private func edited(_ document: Data, _ old: String, _ new: String) throws -> Data {
    let text = String(decoding: document, as: UTF8.self)
    let range = try XCTUnwrap(text.range(of: old), old)
    return Data(text.replacingCharacters(in: range, with: new).utf8)
  }

  /// Whether the facade accepts `trust`, through the production binding over a fresh store.
  private func facadeAccepts(_ trust: Data) throws -> Bool {
    let store = try RecordStore.open(base: base, scope: Self.scope, isMainThread: { Thread.isMainThread })
    defer { try? store.close() }
    guard let client = try? BarometerBinding.newClient(store: store, trust: trust) else { return false }
    try client.close()
    return true
  }

  /// Documents with the expected host generation; nil means the host reads none and the facade
  /// must reject the document too.
  private func generationCases(_ valid: Data) throws -> [(String, Data, Int64?)] {
    let g = #""generation":2"#
    var cases: [(String, Data, Int64?)] = [
      ("valid", valid, 2),
      ("escaped name", try edited(valid, g, #""generation":2"#), 2),
      ("largest", try edited(valid, g, #""generation":9223372036854775807"#), Int64.max),
      ("equal duplicate", try edited(valid, g, g + "," + g), nil),
      ("conflicting duplicate", try edited(valid, g, g + #","generation":3"#), nil),
      ("escaped duplicate", try edited(valid, g, g + #","generation":3"#), nil),
      ("case variant only", try edited(valid, g, #""Generation":2"#), nil),
      ("duplicate elsewhere", try edited(valid, #""format""#, #""format":"barometer-trust/1","format""#), nil),
      ("byte-order mark", Data([0xef, 0xbb, 0xbf]) + valid, nil),
      ("trailing value", valid + Data("{}".utf8), nil),
      ("lone surrogate", try edited(valid, #""synthetic""#, #""synthetic\ud800""#), nil),
      ("control character", try edited(valid, #""synthetic""#, "\"synthetic\u{01}\""), nil),
      ("too deep", try edited(valid, #""synthetic""#, "[[[[[[[[\"x\"]]]]]]]]"), nil),
    ]
    for (name, token) in [
      ("minus zero", "-0"), ("zero", "0"), ("negative", "-2"), ("fraction", "2.0"), ("exponent", "2e0"),
      ("scaled", "0.2e1"), ("quoted", #""2""#), ("overflow", "9223372036854775808"),
      ("unsigned overflow", "18446744073709551617"),
    ] {
      cases.append((name, try edited(valid, g, #""generation":"# + token), nil))
    }
    var invalid = valid
    invalid[try XCTUnwrap(invalid.firstIndex(of: UInt8(ascii: "y")))] = 0xff
    cases.append(("invalid UTF-8", invalid, nil))
    return cases
  }

  func testGenerationAgreesWithTheFacade() throws {
    let valid = try TestDocuments.trustDocument()
    let cases = try generationCases(valid)
    runOffMain {
      for (name, document, expected) in cases {
        let host = HostPolicy.generation(document)
        XCTAssertEqual(host, expected, name)
        XCTAssertEqual(try self.facadeAccepts(document), host != nil, name)
      }
      // An unknown member is never read as the generation; the facade rejects the document.
      let unknown = try self.edited(valid, #""generation":2"#, #""generation":2,"Generation":3"#)
      XCTAssertEqual(HostPolicy.generation(unknown), 2)
      XCTAssertFalse(try self.facadeAccepts(unknown))
    }
  }

  func testEmbeddedIssuerAgreesWithTheFacade() throws {
    let valid = try TestDocuments.trustDocument()
    let id = #""issuer_id":"embedded-issuer""#
    let escaped = try edited(valid, id, #""issuer_id":"embedded-issuer""#)
    let repeated = try edited(valid, id, id + #","issuer_id":"other-issuer""#)
    runOffMain {
      XCTAssertEqual(TrustDocument.embeddedIssuer(valid), TestDocuments.issuer)
      XCTAssertEqual(TrustDocument.embeddedIssuer(escaped), TestDocuments.issuer)
      XCTAssertTrue(try self.facadeAccepts(escaped))
      XCTAssertNil(TrustDocument.embeddedIssuer(repeated))
      XCTAssertFalse(try self.facadeAccepts(repeated))
    }
  }

  // MARK: - Through the channel host

  private func makeHost(_ policy: HostPolicy, bundle: Bundle) -> ChannelCaller {
    let storesBase = base.appendingPathComponent("stores", isDirectory: true)
    let host = BarometerHost(
      bundle: bundle, policy: policy,
      openStore: { try RecordStore.open(base: storesBase, scope: Self.scope, isMainThread: { Thread.isMainThread }) },
      background: FakeBackgroundTasks())
    hosts.append(host)
    return ChannelCaller(host)
  }

  func testRejectedDocumentsLeaveNoSideEffect() throws {
    let valid = try TestDocuments.trustDocument()
    let task = try TestDocuments.runTask("strict-json-1")
    let bundle = try TestDocuments.bundle(
      at: base.appendingPathComponent("bundle", isDirectory: true), trust: valid, tasks: ["task": task])
    let box = DocumentBox()
    let channel = makeHost(HostPolicy { box.document }, bundle: bundle)
    let stores = base.appendingPathComponent("stores", isDirectory: true)
    for (name, document, expected) in try generationCases(valid) where expected == nil {
      box.document = document
      XCTAssertEqual(channel.initialize("{}"), "trust_invalid", name)
      XCTAssertEqual(channel.admitEmbedded("task").code, "not_initialized", name)
      XCTAssertEqual(channel.code("nextBundle"), "not_initialized", name)
      XCTAssertFalse(FileManager.default.fileExists(atPath: stores.path), name)
    }
    // The escaped spellings select the same generation and embedded issuer as Go: the task is
    // installed with the issuer the host read and admitted by Go.
    let escaped = try edited(
      try edited(valid, #""generation":2"#, #""generation":2"#), #""issuer_id":"embedded-issuer""#,
      #""issuer_id":"embedded-issuer""#)
    box.document = escaped
    XCTAssertNil(channel.initialize("{}"))
    let admitted = channel.admitEmbedded("task")
    XCTAssertNil(admitted.code)
    XCTAssertFalse((admitted.value as? String ?? "").isEmpty)
  }
}
