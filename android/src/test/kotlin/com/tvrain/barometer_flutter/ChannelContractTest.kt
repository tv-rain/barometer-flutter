package com.tvrain.barometer_flutter

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Host tests of the method-channel argument validation, with synthetic values only. */
class ChannelContractTest {
    private fun rejected(method: String, arguments: Any?) {
        try {
            ChannelContract.parse(method, arguments)
            fail("$method accepted $arguments")
        } catch (e: InvalidArgumentsException) {
            assertEquals("invalid_arguments", e.message)
        }
    }

    @Test
    fun everyCallParses() {
        assertEquals(ChannelCall.Initialize("{}"), ChannelContract.parse("initialize", mapOf("config" to "{}")))
        assertEquals(
            ChannelCall.AdmitEmbedded("tcp-01_a"),
            ChannelContract.parse("admitTask", mapOf("source" to "embedded", "name" to "tcp-01_a")),
        )
        val pkg = byteArrayOf(1, 2, 3)
        val remote = ChannelContract.parse("admitTask", mapOf("source" to "remote", "package" to pkg))
        assertArrayEquals(pkg, (remote as ChannelCall.AdmitRemote).signedPackage)
        pkg[0] = 9
        assertEquals(1, remote.signedPackage[0].toInt())
        assertEquals(ChannelCall.StartRun("T.a"), ChannelContract.parse("startRun", mapOf("task" to "T.a")))
        assertEquals(ChannelCall.RunState("R.a"), ChannelContract.parse("runState", mapOf("run" to "R.a")))
        assertEquals(ChannelCall.CancelRun("R.a"), ChannelContract.parse("cancelRun", mapOf("run" to "R.a")))
        assertEquals(ChannelCall.NextBundle, ChannelContract.parse("nextBundle", null))
        assertEquals(ChannelCall.AcknowledgeBundle("b"), ChannelContract.parse("acknowledgeBundle", mapOf("id" to "b")))
        assertEquals(ChannelCall.SetProxy("{}"), ChannelContract.parse("setProxy", mapOf("proxy" to "{}")))
        assertEquals(ChannelCall.ClearProxy, ChannelContract.parse("clearProxy", null))
        assertEquals(ChannelCall.ClearMeasurementData, ChannelContract.parse("clearMeasurementData", null))
        assertEquals(ChannelCall.Close, ChannelContract.parse("close", null))
    }

    @Test
    fun noCallInstallsATrustInput() {
        for (method in listOf(
            "installPolicy", "installTrust", "installEmbeddedTask", "installRemoteTask",
            "setIssuer", "setApprovals", "setAdapters", "replacePolicy", "newClient",
        )) {
            assertNull(method, ChannelContract.parse(method, mapOf("document" to "{}")))
        }
    }

    @Test
    fun extraArgumentsAreRejected() {
        val trust = mapOf(
            "trust" to "{}", "policy" to "{}", "issuer" to "embedded-issuer", "issuer_id" to "x",
            "approvals" to "{}", "keys" to "[]", "sourceRef" to "ref", "adapters" to "{}",
        )
        for ((key, value) in trust) {
            rejected("initialize", mapOf("config" to "{}", key to value))
            rejected("admitTask", mapOf("source" to "embedded", "name" to "a", key to value))
            rejected("admitTask", mapOf("source" to "remote", "package" to byteArrayOf(1), key to value))
            rejected("startRun", mapOf("task" to "T.a", key to value))
            rejected("setProxy", mapOf("proxy" to "{}", key to value))
            rejected("nextBundle", mapOf(key to value))
            rejected("close", mapOf(key to value))
        }
    }

    @Test
    fun malformedArgumentsAreRejected() {
        rejected("initialize", null)
        rejected("initialize", "{}")
        rejected("initialize", mapOf("config" to mapOf("proxy" to null)))
        rejected("initialize", mapOf("config" to ""))
        rejected("initialize", mapOf("config" to "x".repeat(ChannelContract.MAX_JSON_CHARS + 1)))
        rejected("initialize", emptyMap<String, Any>())
        rejected("startRun", mapOf("task" to 1))
        rejected("startRun", mapOf("task" to "x".repeat(ChannelContract.MAX_ID_CHARS + 1)))
        rejected("runState", mapOf("task" to "R.a"))
        rejected("cancelRun", mapOf("run" to ""))
        rejected("acknowledgeBundle", mapOf("id" to null))
        rejected("clearProxy", emptyMap<String, Any>())
        rejected("admitTask", null)
        rejected("admitTask", mapOf("source" to "local", "name" to "a"))
        rejected("admitTask", mapOf("name" to "a"))
        rejected("admitTask", mapOf("source" to "remote", "package" to "text"))
        rejected("admitTask", mapOf("source" to "remote", "package" to ByteArray(0)))
        rejected("admitTask", mapOf("source" to "remote", "package" to ByteArray(ChannelContract.MAX_DELIVERY_BYTES + 1)))
        rejected("admitTask", mapOf("source" to "embedded", "package" to byteArrayOf(1)))
    }

    @Test
    fun embeddedNamesStayInTheTaskDirectory() {
        for (name in listOf(
            "", "../trust", "..", "a/b", "a.json", "A", "-a", "_a", "a b", "a\u0000", "x".repeat(65), "tâche",
        )) {
            rejected("admitTask", mapOf("source" to "embedded", "name" to name))
        }
        assertTrue(ChannelContract.TASK_NAME.matches("x".repeat(64)))
    }

    @Test
    fun onlyCheckedCodesCross() {
        assertEquals("task_source_unauthenticated", BarometerHost.code(Exception("task_source_unauthenticated")))
        assertEquals("native_error", BarometerHost.code(Exception("a detail with spaces")))
        assertEquals("native_error", BarometerHost.code(Exception()))
        assertEquals("native_error", BarometerHost.code(IllegalStateException("not_initialized")))
        assertEquals("native_error", BarometerHost.code(OutOfMemoryError("oom")))
    }

    @Test
    fun embeddedIssuerIsTheOneKeylessIssuer() {
        fun doc(issuers: List<String>, keyed: List<String>): ByteArray {
            val i = issuers.joinToString(",") { """{"issuer_id":"$it","permissions":{}}""" }
            val k = keyed.joinToString(",") { """{"key_id":"k-$it","issuer_id":"$it"}""" }
            return """{"format":"barometer-trust/1","policy":{"issuers":[$i],"keys":[$k]}}""".toByteArray()
        }
        assertEquals("embedded-issuer", TrustDocument.embeddedIssuer(doc(listOf("embedded-issuer"), emptyList())))
        assertEquals("local", TrustDocument.embeddedIssuer(doc(listOf("remote", "local"), listOf("remote"))))
        assertNull(TrustDocument.embeddedIssuer(doc(listOf("a", "b"), emptyList())))
        assertNull(TrustDocument.embeddedIssuer(doc(listOf("remote"), listOf("remote"))))
        assertNull(TrustDocument.embeddedIssuer(doc(emptyList(), emptyList())))
        assertNull(TrustDocument.embeddedIssuer("{}".toByteArray()))
        assertNull(TrustDocument.embeddedIssuer("not json".toByteArray()))
    }
}
