import Foundation

/// A strict JSON reader for the values the native glue interprets itself, with the rules of the Go
/// library's shared decoder: valid UTF-8 without a byte-order mark, exactly one value with only
/// JSON whitespace around it, no lone surrogate escape, no raw control character in a string,
/// unique member names after unescaping, and the complete-input, depth and value bounds of the
/// caller. Unlike `JSONSerialization`, it never selects one of several members with the same name
/// and never reads a number in another spelling.
///
/// Names and strings are compared by their exact Unicode scalars, as Go compares them, never by
/// Swift's canonical equivalence: `"\u{e9}"` and `"e\u{301}"` are different names.
enum StrictJSON {
  struct Limits {
    let maxBytes: Int
    let maxDepth: Int
    let maxNodes: Int
  }

  /// The bounds of the Go library's trusted-document decoding.
  static let trustDocument = Limits(maxBytes: 1 << 20, maxDepth: 10, maxNodes: 1 << 17)

  /// Strict JSON rejection, with no detail.
  struct Invalid: Error {}

  indirect enum Value {
    case object(Object)
    case array([Value])
    /// The string's exact UTF-8 bytes.
    case string([UInt8])
    case bool(Bool)
    case null
    /// A number with its exact token text.
    case number(String)

    /// The member `name` of an object, or nil.
    subscript(_ name: String) -> Value? {
      if case .object(let o) = self { return o.members[Array(name.utf8)] }
      return nil
    }

    var array: [Value]? {
      if case .array(let a) = self { return a }
      return nil
    }

    /// The exact UTF-8 bytes of a string.
    var bytes: [UInt8]? {
      if case .string(let s) = self { return s }
      return nil
    }

    /// The value of a number spelled as a canonical integer (an optional minus, no leading zero,
    /// no `-0`, fraction or exponent) within `range`; otherwise nil.
    func integer(in range: ClosedRange<Int64>) -> Int64? {
      guard case .number(let text) = self, StrictJSON.canonicalInteger(text), let n = Int64(text), range.contains(n)
      else { return nil }
      return n
    }
  }

  struct Object {
    /// Members by the UTF-8 bytes of their decoded names.
    var members: [[UInt8]: Value] = [:]
  }

  /// Decodes `input` or throws `Invalid`.
  static func decode(_ input: Data, limits: Limits) throws -> Value {
    guard input.count <= limits.maxBytes else { throw Invalid() }
    let bytes = [UInt8](input)
    try checkUTF8(bytes)
    var parser = Parser(b: bytes, limits: limits)
    return try parser.parse()
  }

  static func canonicalInteger(_ s: String) -> Bool {
    if s == "0" { return true }
    var digits = Substring(s)
    if digits.first == "-" { digits = digits.dropFirst() }
    guard let first = digits.first, ("1"..."9").contains(first) else { return false }
    return digits.allSatisfy { ("0"..."9").contains($0) }
  }

  private static func checkUTF8(_ b: [UInt8]) throws {
    var i = 0
    while i < b.count {
      let c = Int(b[i])
      if c < 0x80 {
        i += 1
        continue
      }
      let need: Int
      let min: Int
      switch c {
      case 0xc2...0xdf: (need, min) = (1, 0x80)
      case 0xe0...0xef: (need, min) = (2, 0x800)
      case 0xf0...0xf4: (need, min) = (3, 0x10000)
      default: throw Invalid()
      }
      guard i + need < b.count else { throw Invalid() }
      var cp = c & (0x3f >> need)
      for k in 1...need {
        let x = Int(b[i + k])
        guard x & 0xc0 == 0x80 else { throw Invalid() }
        cp = (cp << 6) | (x & 0x3f)
      }
      guard cp >= min, cp <= 0x10ffff, !(0xd800...0xdfff).contains(cp) else { throw Invalid() }
      i += need + 1
    }
  }

  private struct Parser {
    let b: [UInt8]
    let limits: Limits
    var pos = 0
    var nodes = 0

    mutating func parse() throws -> Value {
      space()
      let v = try value(depth: 1)
      space()
      guard pos == b.count else { throw Invalid() }
      return v
    }

    private var at: UInt8? { pos < b.count ? b[pos] : nil }

    private mutating func space() {
      while let c = at, c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d { pos += 1 }
    }

    private mutating func take(_ c: UInt8) -> Bool {
      guard at == c else { return false }
      pos += 1
      return true
    }

    private mutating func value(depth: Int) throws -> Value {
      guard depth <= limits.maxDepth, nodes < limits.maxNodes else { throw Invalid() }
      nodes += 1
      switch at {
      case UInt8(ascii: "{"): return try object(depth: depth)
      case UInt8(ascii: "["): return try array(depth: depth)
      case UInt8(ascii: "\""): return .string(try string())
      case UInt8(ascii: "t"): return try literal("true", .bool(true))
      case UInt8(ascii: "f"): return try literal("false", .bool(false))
      case UInt8(ascii: "n"): return try literal("null", .null)
      default: return try number()
      }
    }

    private mutating func object(depth: Int) throws -> Value {
      pos += 1
      var o = Object()
      space()
      if take(UInt8(ascii: "}")) { return .object(o) }
      repeat {
        space()
        let name = try string()
        guard o.members[name] == nil else { throw Invalid() }
        space()
        guard take(UInt8(ascii: ":")) else { throw Invalid() }
        space()
        o.members[name] = try value(depth: depth + 1)
        space()
      } while take(UInt8(ascii: ","))
      guard take(UInt8(ascii: "}")) else { throw Invalid() }
      return .object(o)
    }

    private mutating func array(depth: Int) throws -> Value {
      pos += 1
      var elements: [Value] = []
      space()
      if take(UInt8(ascii: "]")) { return .array(elements) }
      repeat {
        space()
        elements.append(try value(depth: depth + 1))
        space()
      } while take(UInt8(ascii: ","))
      guard take(UInt8(ascii: "]")) else { throw Invalid() }
      return .array(elements)
    }

    private mutating func literal(_ word: String, _ result: Value) throws -> Value {
      for c in word.utf8 where !take(c) { throw Invalid() }
      return result
    }

    private mutating func digit() -> Bool {
      guard let c = at, (0x30...0x39).contains(c) else { return false }
      pos += 1
      return true
    }

    private mutating func number() throws -> Value {
      let start = pos
      _ = take(UInt8(ascii: "-"))
      if !take(UInt8(ascii: "0")) {
        guard let c = at, (0x31...0x39).contains(c) else { throw Invalid() }
        pos += 1
        while digit() {}
      }
      if take(UInt8(ascii: ".")) {
        guard digit() else { throw Invalid() }
        while digit() {}
      }
      if take(UInt8(ascii: "e")) || take(UInt8(ascii: "E")) {
        if !take(UInt8(ascii: "+")) { _ = take(UInt8(ascii: "-")) }
        guard digit() else { throw Invalid() }
        while digit() {}
      }
      return .number(String(decoding: b[start..<pos], as: UTF8.self))
    }

    private mutating func hex4() throws -> UInt32 {
      guard b.count - pos >= 4 else { throw Invalid() }
      var x: UInt32 = 0
      for _ in 0..<4 {
        let c = b[pos]
        pos += 1
        let n: UInt8
        switch c {
        case 0x30...0x39: n = c - 0x30
        case 0x61...0x66: n = c - 0x61 + 10
        case 0x41...0x46: n = c - 0x41 + 10
        default: throw Invalid()
        }
        x = x * 16 + UInt32(n)
      }
      return x
    }

    /// The decoded string as UTF-8 bytes.
    private mutating func string() throws -> [UInt8] {
      guard take(UInt8(ascii: "\"")) else { throw Invalid() }
      var out: [UInt8] = []
      while pos < b.count {
        let c = b[pos]
        pos += 1
        if c == UInt8(ascii: "\"") { return out }
        guard c >= 0x20 else { throw Invalid() }
        guard c == UInt8(ascii: "\\") else {
          out.append(c)
          continue
        }
        guard pos < b.count else { throw Invalid() }
        let e = b[pos]
        pos += 1
        switch e {
        case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(e)
        case UInt8(ascii: "b"): out.append(0x08)
        case UInt8(ascii: "f"): out.append(0x0c)
        case UInt8(ascii: "n"): out.append(0x0a)
        case UInt8(ascii: "r"): out.append(0x0d)
        case UInt8(ascii: "t"): out.append(0x09)
        case UInt8(ascii: "u"):
          var scalar = try hex4()
          if (0xdc00...0xdfff).contains(scalar) { throw Invalid() }
          if (0xd800...0xdbff).contains(scalar) {
            guard take(UInt8(ascii: "\\")), take(UInt8(ascii: "u")) else { throw Invalid() }
            let low = try hex4()
            guard (0xdc00...0xdfff).contains(low) else { throw Invalid() }
            scalar = 0x10000 + ((scalar - 0xd800) << 10) + (low - 0xdc00)
          }
          guard let u = Unicode.Scalar(scalar) else { throw Invalid() }
          out.append(contentsOf: Array(String(Character(u)).utf8))
        default: throw Invalid()
        }
      }
      throw Invalid()
    }
  }
}
