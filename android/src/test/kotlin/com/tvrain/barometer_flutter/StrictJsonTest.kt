package com.tvrain.barometer_flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Test

/**
 * Host tests of the strict JSON reader and of the two values the native glue reads from the
 * trusted local document, against the Go library's shared decoder rules. Synthetic input only.
 */
class StrictJsonTest {
    private val limits = StrictJson.Limits(maxBytes = 4096, maxDepth = 4, maxNodes = 32)

    private fun rejects(input: ByteArray, limits: StrictJson.Limits = this.limits) {
        try {
            StrictJson.decode(input, limits)
            fail("accepted ${String(input, Charsets.ISO_8859_1)}")
        } catch (e: StrictJsonException) {
            assertEquals("invalid_json", e.message)
        }
    }

    private fun rejects(input: String) = rejects(input.toByteArray())

    private fun decode(input: String): Any? = StrictJson.decode(input.toByteArray(), limits)

    @Test
    fun namesAreUniqueAfterUnescaping() {
        rejects("""{"a":1,"a":1}""")
        rejects("""{"a":1,"a":2}""")
        rejects("""{"a":1,"\u0061":2}""")
        rejects("""{"\/":1,"/":2}""")
        rejects("""{"o":{"a":1,"a":2}}""")
        rejects("""[{"a":1,"a":2}]""")
        // Escaped spellings are the same name; case variants and other normal forms are not.
        assertEquals(mapOf("a" to "b"), decode("""{"\u0061":"\u0062"}"""))
        assertEquals(mapOf("a" to 1L, "A" to 2L), (decode("""{"a":1,"A":2}""") as Map<*, *>).mapValues { StrictJson.integer(it.value, 0, 9) })
        assertEquals(2, (decode("{\"\u00e9\":1,\"e\u0301\":2}") as Map<*, *>).size)
        assertEquals(listOf(mapOf("a" to null), mapOf("a" to null)), decode("""[{"a":null},{"a":null}]"""))
    }

    @Test
    fun framingAndText() {
        rejects(byteArrayOf(0xef.toByte(), 0xbb.toByte(), 0xbf.toByte()) + "{}".toByteArray())
        rejects("{}{}")
        rejects("{} x")
        rejects("{,}")
        rejects("""{"a":1,}""")
        rejects("[1,]")
        rejects("")
        rejects("{'a':1}")
        rejects("""{"a":NaN}""")
        rejects("""{"a":Infinity}""")
        rejects("""{"a":tru}""")
        rejects("{\u000c}")
        rejects("\"a\u0001\"")
        rejects("{\"a\u0000\":1}")
        rejects("\"\\ud800\"")
        rejects("\"\\udc00\"")
        rejects("\"\\ud800\\u0041\"")
        rejects("\"\\x41\"")
        rejects("\"\\u00g0\"")
        rejects("\"abc")
        val quoted = { bytes: ByteArray -> "\"".toByteArray() + bytes + "\"".toByteArray() }
        rejects(quoted(byteArrayOf(0xff.toByte())))
        rejects(quoted(byteArrayOf(0xc0.toByte(), 0xaf.toByte())))
        rejects(quoted(byteArrayOf(0xed.toByte(), 0xa0.toByte(), 0x80.toByte())))
        rejects(quoted(byteArrayOf(0xe2.toByte(), 0x82.toByte())))
        rejects(quoted(byteArrayOf(0xf4.toByte(), 0x90.toByte(), 0x80.toByte(), 0x80.toByte())))
        assertEquals("\u00e9", StrictJson.decode(quoted(byteArrayOf(0xc3.toByte(), 0xa9.toByte())), limits))
        assertEquals("\ud83d\ude00", decode("\"\\ud83d\\ude00\""))
        assertEquals("\u0000\"\\/\b\u000c\n\r\t", decode("\"\\u0000\\\"\\\\\\/\\b\\f\\n\\r\\t\""))
        assertEquals("\ufffd", decode("\"\ufffd\""))
        assertEquals(mapOf<String, Any?>(), decode(" \t\r\n{ }\n"))
        assertEquals(listOf(true, false, null), decode("[true,false,null]"))
    }

    @Test
    fun integersHaveOneSpelling() {
        fun integer(token: String, min: Long = Long.MIN_VALUE, max: Long = Long.MAX_VALUE) =
            StrictJson.integer(decode(token), min, max)
        assertEquals(0L, integer("0"))
        assertEquals(-1L, integer("-1"))
        assertEquals(9_007_199_254_740_993L, integer("9007199254740993"))
        assertEquals(Long.MAX_VALUE, integer("9223372036854775807"))
        assertEquals(Long.MIN_VALUE, integer("-9223372036854775808"))
        for (token in listOf("-0", "1.0", "1e0", "1E0", "1e+0", "0.5e1", "10e-1", "9223372036854775808", "-9223372036854775809")) {
            assertNull(token, integer(token))
        }
        assertNull(integer("0", min = 1))
        assertNull(integer("8", max = 7))
        assertNull(StrictJson.integer("1", 0, 9))
        assertNull(StrictJson.integer(true, 0, 9))
        for (token in listOf("01", "+1", "-", "1.", ".5", "1e", "0x1", "- 1")) rejects(token)
    }

    @Test
    fun boundsAreTheCallers() {
        rejects("[[[[[]]]]]")
        decode("[[[[]]]]")
        rejects("[" + "0,".repeat(31) + "0]")
        decode("[" + "0,".repeat(30) + "0]")
        val padded = "\"" + "a".repeat(4094) + "\""
        assertEquals(4094, (decode(padded) as String).length)
        rejects("$padded ")
    }

    private val base = """{"format":"barometer-trust/1","policy":{"generation":7,"keys":[{"issuer_id":"remote"}],"issuers":[{"issuer_id":"remote"},{"issuer_id":"local"}]}}"""

    private fun edited(old: String, new: String): ByteArray {
        check(base.contains(old)) { old }
        return base.replaceFirst(old, new).toByteArray()
    }

    @Test
    fun generationAgreesWithTheFacade() {
        assertEquals(7L, HostPolicy.generation(base.toByteArray()))
        assertEquals(7L, HostPolicy.generation(edited("\"generation\"", "\"gener\\u0061tion\"")))
        assertEquals(Long.MAX_VALUE, HostPolicy.generation(edited("7", "9223372036854775807")))
        // An unknown member is not read; the facade rejects the document.
        assertEquals(7L, HostPolicy.generation(edited("\"generation\":7", "\"generation\":7,\"Generation\":8")))
        val rejected = listOf(
            edited("\"generation\":7", "\"generation\":7,\"generation\":7"),
            edited("\"generation\":7", "\"generation\":7,\"generation\":8"),
            edited("\"generation\":7", "\"generation\":7,\"gener\\u0061tion\":8"),
            edited("\"generation\":7", "\"Generation\":7"),
            edited("\"format\"", "\"format\":\"x\",\"format\""),
            edited("\"remote\"}]", "\"remote\",\"issuer_id\":\"local\"}]"),
            edited("7", "-0"), edited("7", "0"), edited("7", "-7"), edited("7", "7.0"),
            edited("7", "7e0"), edited("7", "0.7e1"), edited("7", "\"7\""),
            edited("7", "9223372036854775808"), edited("7", "18446744073709551617"),
            byteArrayOf(0xef.toByte(), 0xbb.toByte(), 0xbf.toByte()) + base.toByteArray(),
            (base + "{}").toByteArray(),
            edited("\"local\"", "\"loc\\ud800\""),
            edited("\"local\"", "\"loc\u0001\""),
            base.toByteArray().also { it[it.indexOf('l'.code.toByte())] = 0xff.toByte() },
            edited("\"local\"", "[[[[[[\"x\"]]]]]]"),
        )
        for (document in rejected) assertNull(String(document, Charsets.ISO_8859_1), HostPolicy.generation(document))
        // Depth 10, the facade's bound, is accepted; the string above was at depth 11.
        assertEquals(7L, HostPolicy.generation(edited("\"local\"", "[[[[[\"x\"]]]]]")))
    }

    @Test
    fun embeddedIssuerAgreesWithTheFacade() {
        assertEquals("local", TrustDocument.embeddedIssuer(base.toByteArray()))
        assertEquals("local", TrustDocument.embeddedIssuer(edited("{\"issuer_id\":\"local\"}", "{\"issuer_\\u0069d\":\"l\\u006fcal\"}")))
        // A repeated name selects no issuer, where org.json would take the last one.
        assertNull(TrustDocument.embeddedIssuer(edited("{\"issuer_id\":\"local\"}", "{\"issuer_id\":\"local\",\"issuer_id\":\"other\"}")))
        assertNull(TrustDocument.embeddedIssuer(edited("{\"issuer_id\":\"remote\"}]", "{\"issuer_id\":\"remote\",\"issuer_\\u0069d\":\"local\"}]")))
        assertNull(TrustDocument.embeddedIssuer(edited("\"keys\"", "\"keys\":[],\"keys\"")))
    }
}
