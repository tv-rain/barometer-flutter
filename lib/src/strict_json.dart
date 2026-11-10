import 'dart:convert';
import 'dart:typed_data';

/// Bounds of one strict decoding: the complete input in bytes, the nesting
/// depth counting the root as 1, and the number of values.
final class StrictJsonLimits {
  const StrictJsonLimits({
    required this.maxBytes,
    required this.maxDepth,
    required this.maxNodes,
  });

  final int maxBytes;
  final int maxDepth;
  final int maxNodes;
}

/// The bounds of a stored Result Bundle, as the Go library re-reads it.
const bundleLimits = StrictJsonLimits(
  maxBytes: 262144,
  maxDepth: 18,
  maxNodes: 262144,
);

/// Decodes [input] as one strict JSON value with the rules of the Go
/// library's shared decoder: valid UTF-8 without a byte-order mark, exactly
/// one value with only JSON whitespace around it, no lone surrogate escape,
/// unique member names after unescaping, and every number a canonical
/// integer (no sign on zero, fraction or exponent) within 64-bit signed
/// range, which Go's models require of every number they accept.
///
/// Objects decode to insertion-ordered `Map<String, Object?>`, arrays to
/// `List<Object?>`, numbers to `int`. Any other input throws a
/// [FormatException] that carries no part of it.
Object? decodeStrictJson(Uint8List input, StrictJsonLimits limits) {
  if (input.length > limits.maxBytes) throw const FormatException('bounds');
  // Checked on the bytes, so that no decoder leniency (overlong forms,
  // encoded surrogates) applies. Dart's decoder drops a leading byte-order
  // mark, which is not JSON whitespace.
  _checkUtf8(input);
  if (input.length >= 3 &&
      input[0] == 0xef &&
      input[1] == 0xbb &&
      input[2] == 0xbf) {
    throw const FormatException('syntax');
  }
  final text = utf8.decode(input);
  return _StrictParser(text, limits).parse();
}

void _checkUtf8(Uint8List b) {
  var i = 0;
  while (i < b.length) {
    final c = b[i];
    if (c < 0x80) {
      i++;
      continue;
    }
    int need;
    int min;
    if (c >= 0xc2 && c <= 0xdf) {
      need = 1;
      min = 0x80;
    } else if (c >= 0xe0 && c <= 0xef) {
      need = 2;
      min = 0x800;
    } else if (c >= 0xf0 && c <= 0xf4) {
      need = 3;
      min = 0x10000;
    } else {
      throw const FormatException('text');
    }
    if (i + need >= b.length) throw const FormatException('text');
    var cp = c & (0x3f >> need);
    for (var k = 1; k <= need; k++) {
      final x = b[i + k];
      if (x & 0xc0 != 0x80) throw const FormatException('text');
      cp = (cp << 6) | (x & 0x3f);
    }
    if (cp < min || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) {
      throw const FormatException('text');
    }
    i += need + 1;
  }
}

final class _StrictParser {
  _StrictParser(this.s, this.limits);

  final String s;
  final StrictJsonLimits limits;
  int pos = 0;
  int nodes = 0;

  static final _int64Max = BigInt.parse('9223372036854775807');
  static final _int64Min = BigInt.parse('-9223372036854775808');

  Object? parse() {
    _space();
    final v = _value(1);
    _space();
    if (pos != s.length) throw const FormatException('syntax');
    return v;
  }

  void _space() {
    while (pos < s.length) {
      final c = s.codeUnitAt(pos);
      if (c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d) {
        pos++;
      } else {
        return;
      }
    }
  }

  bool _take(int c) {
    if (pos < s.length && s.codeUnitAt(pos) == c) {
      pos++;
      return true;
    }
    return false;
  }

  Object? _value(int depth) {
    if (depth > limits.maxDepth || nodes >= limits.maxNodes) {
      throw const FormatException('bounds');
    }
    nodes++;
    if (pos >= s.length) throw const FormatException('syntax');
    switch (s.codeUnitAt(pos)) {
      case 0x7b: // {
        pos++;
        final members = <String, Object?>{};
        _space();
        if (_take(0x7d)) return members;
        while (true) {
          final name = _string();
          if (members.containsKey(name)) {
            throw const FormatException('duplicate');
          }
          _space();
          if (!_take(0x3a)) throw const FormatException('syntax');
          _space();
          members[name] = _value(depth + 1);
          _space();
          if (_take(0x7d)) return members;
          if (!_take(0x2c)) throw const FormatException('syntax');
          _space();
        }
      case 0x5b: // [
        pos++;
        final elements = <Object?>[];
        _space();
        if (_take(0x5d)) return elements;
        while (true) {
          elements.add(_value(depth + 1));
          _space();
          if (_take(0x5d)) return elements;
          if (!_take(0x2c)) throw const FormatException('syntax');
          _space();
        }
      case 0x22: // "
        return _string();
      case 0x74:
        _literal('true');
        return true;
      case 0x66:
        _literal('false');
        return false;
      case 0x6e:
        _literal('null');
        return null;
      default:
        return _number();
    }
  }

  void _literal(String word) {
    if (!s.startsWith(word, pos)) throw const FormatException('syntax');
    pos += word.length;
  }

  bool _digit() {
    if (pos < s.length) {
      final c = s.codeUnitAt(pos);
      if (c >= 0x30 && c <= 0x39) {
        pos++;
        return true;
      }
    }
    return false;
  }

  int _number() {
    final start = pos;
    _take(0x2d);
    if (!_take(0x30)) {
      if (pos >= s.length) throw const FormatException('syntax');
      final c = s.codeUnitAt(pos);
      if (c < 0x31 || c > 0x39) throw const FormatException('syntax');
      pos++;
      while (_digit()) {}
    }
    var integer = true;
    if (_take(0x2e)) {
      integer = false;
      if (!_digit()) throw const FormatException('syntax');
      while (_digit()) {}
    }
    if (_take(0x65) || _take(0x45)) {
      integer = false;
      if (!_take(0x2b)) _take(0x2d);
      if (!_digit()) throw const FormatException('syntax');
      while (_digit()) {}
    }
    final token = s.substring(start, pos);
    if (!integer || token == '-0') throw const FormatException('integer');
    final value = BigInt.parse(token);
    if (value > _int64Max || value < _int64Min) {
      throw const FormatException('range');
    }
    return value.toInt();
  }

  int _hex4() {
    if (s.length - pos < 4) throw const FormatException('text');
    var x = 0;
    for (var i = 0; i < 4; i++) {
      final c = s.codeUnitAt(pos++);
      int n;
      if (c >= 0x30 && c <= 0x39) {
        n = c - 0x30;
      } else if (c >= 0x61 && c <= 0x66) {
        n = c - 0x61 + 10;
      } else if (c >= 0x41 && c <= 0x46) {
        n = c - 0x41 + 10;
      } else {
        throw const FormatException('text');
      }
      x = x * 16 + n;
    }
    return x;
  }

  String _string() {
    if (!_take(0x22)) throw const FormatException('syntax');
    final out = StringBuffer();
    while (pos < s.length) {
      final c = s.codeUnitAt(pos++);
      if (c == 0x22) return out.toString();
      if (c < 0x20) throw const FormatException('text');
      if (c != 0x5c) {
        out.writeCharCode(c);
        continue;
      }
      if (pos >= s.length) throw const FormatException('text');
      final e = s.codeUnitAt(pos++);
      switch (e) {
        case 0x22 || 0x5c || 0x2f:
          out.writeCharCode(e);
        case 0x62:
          out.writeCharCode(0x08);
        case 0x66:
          out.writeCharCode(0x0c);
        case 0x6e:
          out.writeCharCode(0x0a);
        case 0x72:
          out.writeCharCode(0x0d);
        case 0x74:
          out.writeCharCode(0x09);
        case 0x75:
          final x = _hex4();
          if (x >= 0xdc00 && x <= 0xdfff) throw const FormatException('text');
          if (x >= 0xd800 && x <= 0xdbff) {
            if (!_take(0x5c) || !_take(0x75)) {
              throw const FormatException('text');
            }
            final y = _hex4();
            if (y < 0xdc00 || y > 0xdfff) throw const FormatException('text');
            out.writeCharCode(0x10000 + ((x - 0xd800) << 10) + (y - 0xdc00));
          } else {
            out.writeCharCode(x);
          }
        default:
          throw const FormatException('text');
      }
    }
    throw const FormatException('syntax');
  }
}
