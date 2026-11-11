package com.tvrain.barometer_flutter

/** Strict JSON rejection, with no detail. */
internal class StrictJsonException : Exception("invalid_json")

/**
 * A strict JSON reader for the values the native glue interprets itself, with the rules of the Go
 * library's shared decoder: valid UTF-8 without a byte-order mark, exactly one value with only
 * JSON whitespace around it, no lone surrogate escape, no raw control character in a string,
 * unique member names after unescaping, and the complete-input, depth and value bounds of the
 * caller. Unlike `org.json`, it never selects one of several members with the same name and
 * never reads a number in another spelling.
 *
 * Objects decode to insertion-ordered maps, arrays to lists, strings to [String], `true` and
 * `false` to [Boolean], `null` to null and numbers to [Number] with their exact text; [integer]
 * reads a number as Go reads an integer field.
 */
internal object StrictJson {
    /** A number with its exact token text. */
    class Number(val text: String)

    /** Bounds of one decoding, as in Go's `jsondecode.Limits`. */
    class Limits(val maxBytes: Int, val maxDepth: Int, val maxNodes: Int)

    /** The bounds of the Go library's trusted-document decoding. */
    val TRUST_DOCUMENT = Limits(maxBytes = 1 shl 20, maxDepth = 10, maxNodes = 1 shl 17)

    /** Decodes [input] or throws [StrictJsonException]. */
    fun decode(input: ByteArray, limits: Limits): Any? {
        if (input.size > limits.maxBytes) throw StrictJsonException()
        checkUtf8(input)
        return Parser(input, limits).parse()
    }

    /**
     * The value of [value] when it is a [Number] spelled as a canonical integer (an optional
     * minus, no leading zero, no `-0`, fraction or exponent) within [min]..[max]; otherwise null.
     */
    fun integer(value: Any?, min: Long, max: Long): Long? {
        val text = (value as? Number)?.text ?: return null
        if (!canonicalInteger(text)) return null
        val n = text.toLongOrNull() ?: return null
        return n.takeIf { it in min..max }
    }

    private fun canonicalInteger(s: String): Boolean {
        if (s == "0") return true
        var i = if (s.startsWith("-")) 1 else 0
        if (i >= s.length || s[i] !in '1'..'9') return false
        i++
        while (i < s.length) if (s[i++] !in '0'..'9') return false
        return true
    }

    private fun checkUtf8(b: ByteArray) {
        var i = 0
        while (i < b.size) {
            val c = b[i].toInt() and 0xff
            if (c < 0x80) {
                i++
                continue
            }
            val need: Int
            val min: Int
            when (c) {
                in 0xc2..0xdf -> { need = 1; min = 0x80 }
                in 0xe0..0xef -> { need = 2; min = 0x800 }
                in 0xf0..0xf4 -> { need = 3; min = 0x10000 }
                else -> throw StrictJsonException()
            }
            if (i + need >= b.size) throw StrictJsonException()
            var cp = c and (0x3f shr need)
            for (k in 1..need) {
                val x = b[i + k].toInt() and 0xff
                if (x and 0xc0 != 0x80) throw StrictJsonException()
                cp = (cp shl 6) or (x and 0x3f)
            }
            if (cp < min || cp > 0x10ffff || cp in 0xd800..0xdfff) throw StrictJsonException()
            i += need + 1
        }
    }

    private class Parser(private val b: ByteArray, private val limits: Limits) {
        private var pos = 0
        private var nodes = 0

        fun parse(): Any? {
            space()
            val v = value(1)
            space()
            if (pos != b.size) throw StrictJsonException()
            return v
        }

        private fun at(): Int = if (pos < b.size) b[pos].toInt() and 0xff else -1

        private fun space() {
            while (true) {
                when (at()) {
                    0x20, 0x09, 0x0a, 0x0d -> pos++
                    else -> return
                }
            }
        }

        private fun take(c: Int): Boolean {
            if (at() != c) return false
            pos++
            return true
        }

        private fun value(depth: Int): Any? {
            if (depth > limits.maxDepth || nodes >= limits.maxNodes) throw StrictJsonException()
            nodes++
            return when (at()) {
                '{'.code -> obj(depth)
                '['.code -> array(depth)
                '"'.code -> string()
                't'.code -> literal("true", true)
                'f'.code -> literal("false", false)
                'n'.code -> literal("null", null)
                else -> number()
            }
        }

        private fun obj(depth: Int): Map<String, Any?> {
            pos++
            val members = LinkedHashMap<String, Any?>()
            space()
            if (take('}'.code)) return members
            do {
                space()
                val name = string()
                if (members.containsKey(name)) throw StrictJsonException()
                space()
                if (!take(':'.code)) throw StrictJsonException()
                space()
                members[name] = value(depth + 1)
                space()
            } while (take(','.code))
            if (!take('}'.code)) throw StrictJsonException()
            return members
        }

        private fun array(depth: Int): List<Any?> {
            pos++
            val elements = ArrayList<Any?>()
            space()
            if (take(']'.code)) return elements
            do {
                space()
                elements.add(value(depth + 1))
                space()
            } while (take(','.code))
            if (!take(']'.code)) throw StrictJsonException()
            return elements
        }

        private fun literal(word: String, result: Any?): Any? {
            for (ch in word) if (!take(ch.code)) throw StrictJsonException()
            return result
        }

        private fun digit(): Boolean = if (at() in '0'.code..'9'.code) { pos++; true } else false

        private fun number(): Number {
            val start = pos
            take('-'.code)
            if (!take('0'.code)) {
                if (at() !in '1'.code..'9'.code) throw StrictJsonException()
                pos++
                while (digit()) {}
            }
            if (take('.'.code)) {
                if (!digit()) throw StrictJsonException()
                while (digit()) {}
            }
            if (take('e'.code) || take('E'.code)) {
                if (!take('+'.code)) take('-'.code)
                if (!digit()) throw StrictJsonException()
                while (digit()) {}
            }
            return Number(String(b, start, pos - start, Charsets.US_ASCII))
        }

        private fun hex4(): Int {
            if (b.size - pos < 4) throw StrictJsonException()
            var x = 0
            repeat(4) {
                val c = b[pos++].toInt() and 0xff
                val n = when (c) {
                    in '0'.code..'9'.code -> c - '0'.code
                    in 'a'.code..'f'.code -> c - 'a'.code + 10
                    in 'A'.code..'F'.code -> c - 'A'.code + 10
                    else -> throw StrictJsonException()
                }
                x = x * 16 + n
            }
            return x
        }

        private fun string(): String {
            if (!take('"'.code)) throw StrictJsonException()
            val out = StringBuilder()
            var run = pos
            while (pos < b.size) {
                val c = b[pos].toInt() and 0xff
                if (c == '"'.code) {
                    out.append(String(b, run, pos - run, Charsets.UTF_8))
                    pos++
                    return out.toString()
                }
                if (c < 0x20) throw StrictJsonException()
                if (c != '\\'.code) {
                    pos++
                    continue
                }
                // The input is valid UTF-8, so a raw run ends on a character boundary here.
                out.append(String(b, run, pos - run, Charsets.UTF_8))
                pos++
                if (pos >= b.size) throw StrictJsonException()
                when (b[pos++].toInt() and 0xff) {
                    '"'.code -> out.append('"')
                    '\\'.code -> out.append('\\')
                    '/'.code -> out.append('/')
                    'b'.code -> out.append('\b')
                    'f'.code -> out.append('\u000c')
                    'n'.code -> out.append('\n')
                    'r'.code -> out.append('\r')
                    't'.code -> out.append('\t')
                    'u'.code -> {
                        val x = hex4()
                        if (x in 0xdc00..0xdfff) throw StrictJsonException()
                        out.append(x.toChar())
                        if (x in 0xd800..0xdbff) {
                            if (!take('\\'.code) || !take('u'.code)) throw StrictJsonException()
                            val y = hex4()
                            if (y !in 0xdc00..0xdfff) throw StrictJsonException()
                            out.append(y.toChar())
                        }
                    }
                    else -> throw StrictJsonException()
                }
                run = pos
            }
            throw StrictJsonException()
        }
    }
}
