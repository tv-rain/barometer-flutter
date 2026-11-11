package com.tvrain.barometer_flutter

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The two values the native glue reads from the trusted local document (`policy.generation` and
 * the embedded issuer) against the facade itself, on the emulator: for each synthetic document,
 * the host reads a value exactly when the facade accepts the document, and the same value.
 * Rejected documents leave no client, store, admission or bundle through the channel host.
 * Nothing contacts the network.
 */
@RunWith(AndroidJUnit4::class)
class StrictJsonDeviceTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext

    private fun scopeDir() = File(context.noBackupFilesDir, "barometer/${RecordStore.DEFAULT_SCOPE}")

    @Before
    fun setUp() {
        scopeDir().deleteRecursively()
    }

    @After
    fun tearDown() {
        scopeDir().deleteRecursively()
    }

    @Volatile
    private var document: ByteArray = ByteArray(0)

    private val valid: ByteArray = DeviceTestDocuments.trustDocument("TCP-01", DeviceTestDocuments.TCP_TUPLE)

    private fun edited(document: ByteArray, old: String, new: String): ByteArray {
        val text = String(document, Charsets.UTF_8)
        assertTrue(old, text.contains(old))
        return text.replaceFirst(old, new).toByteArray()
    }

    /** Whether the facade accepts [trust], through the production binding over a fresh store. */
    private fun facadeAccepts(trust: ByteArray): Boolean {
        val store = RecordStore.open(context)
        try {
            val client = try {
                BarometerBinding.newClient(context, store, trust)
            } catch (e: Exception) {
                return false
            }
            client.close()
            return true
        } finally {
            store.close()
            scopeDir().deleteRecursively()
        }
    }

    private val g = "\"generation\":2"

    /** Documents with the expected host generation; null means the facade must reject too. */
    private fun generationCases(): List<Triple<String, ByteArray, Long?>> {
        val cases = mutableListOf(
            Triple("valid", valid, 2L),
            Triple("escaped name", edited(valid, g, "\"gener\\u0061tion\":2"), 2L),
            Triple("largest", edited(valid, g, "\"generation\":9223372036854775807"), Long.MAX_VALUE),
            Triple("equal duplicate", edited(valid, g, "$g,$g"), null),
            Triple("conflicting duplicate", edited(valid, g, "$g,\"generation\":3"), null),
            Triple("escaped duplicate", edited(valid, g, "$g,\"gener\\u0061tion\":3"), null),
            Triple("case variant only", edited(valid, g, "\"Generation\":2"), null),
            Triple("duplicate elsewhere", edited(valid, "\"format\"", "\"format\":\"barometer-trust/1\",\"format\""), null),
            Triple("byte-order mark", byteArrayOf(0xef.toByte(), 0xbb.toByte(), 0xbf.toByte()) + valid, null),
            Triple("trailing value", valid + "{}".toByteArray(), null),
            Triple("lone surrogate", edited(valid, "\"synthetic\"", "\"synthetic\\ud800\""), null),
            Triple("control character", edited(valid, "\"synthetic\"", "\"synthetic\u0001\""), null),
            Triple("too deep", edited(valid, "\"synthetic\"", "[[[[[[[[\"x\"]]]]]]]]"), null),
            Triple("invalid UTF-8", valid.copyOf().also { it[it.indexOf('y'.code.toByte())] = 0xff.toByte() }, null),
        )
        for ((name, token) in listOf(
            "minus zero" to "-0", "zero" to "0", "negative" to "-2", "fraction" to "2.0", "exponent" to "2e0",
            "scaled" to "0.2e1", "quoted" to "\"2\"", "overflow" to "9223372036854775808",
            "unsigned overflow" to "18446744073709551617",
        )) {
            cases.add(Triple(name, edited(valid, g, "\"generation\":$token"), null))
        }
        return cases
    }

    @Test
    fun generationAgreesWithTheFacade() {
        for ((name, document, expected) in generationCases()) {
            val host = HostPolicy.generation(document)
            assertEquals(name, expected, host)
            assertEquals(name, host != null, facadeAccepts(document))
        }
        // An unknown member is never read as the generation; the facade rejects the document.
        val unknown = edited(valid, g, "$g,\"Generation\":3")
        assertEquals(2L, HostPolicy.generation(unknown))
        assertFalse(facadeAccepts(unknown))
    }

    @Test
    fun embeddedIssuerAgreesWithTheFacade() {
        val id = "\"issuer_id\":\"${DeviceTestDocuments.ISSUER}\""
        val escaped = edited(valid, id, "\"issuer_\\u0069d\":\"embedded-\\u0069ssuer\"")
        val repeated = edited(valid, id, "$id,\"issuer_id\":\"other-issuer\"")
        assertEquals(DeviceTestDocuments.ISSUER, TrustDocument.embeddedIssuer(valid))
        assertEquals(DeviceTestDocuments.ISSUER, TrustDocument.embeddedIssuer(escaped))
        assertTrue(facadeAccepts(escaped))
        assertNull(TrustDocument.embeddedIssuer(repeated))
        assertFalse(facadeAccepts(repeated))
    }

    @Test
    fun rejectedDocumentsLeaveNoSideEffect() {
        document = valid
        val host = BarometerHost(context, HostPolicy { document })
        val channel = ChannelCaller(host)
        val expired = mapOf("source" to "embedded", "name" to "expired")
        try {
            for ((name, rejected, expected) in generationCases()) {
                if (expected != null) continue
                document = rejected
                assertEquals(name, "trust_invalid", channel.initialize("{}"))
                assertEquals(name, "not_initialized", channel.code("admitTask", expired))
                assertEquals(name, "not_initialized", channel.code("nextBundle"))
                assertFalse(name, scopeDir().exists())
            }
            // With the valid document the embedded task passes delivery binding and provenance
            // with the issuer the host read, then fails a later admission step. Escaped spellings
            // of the generation and the issuer select the same values: the outcome is the same.
            document = valid
            assertNull(channel.initialize("{}"))
            val plain = channel.code("admitTask", expired)
            assertTrue(plain, plain != null && plain.startsWith("task_"))
            assertNotEquals("task_source_unauthenticated", plain)
            assertNull(channel.code("close"))
            document = edited(
                edited(valid, g, "\"gener\\u0061tion\":3"),
                "\"issuer_id\":\"${DeviceTestDocuments.ISSUER}\"",
                "\"issuer_\\u0069d\":\"${DeviceTestDocuments.ISSUER}\"",
            )
            assertNull(channel.initialize("{}"))
            assertEquals(plain, channel.code("admitTask", expired))
        } finally {
            channel.code("close")
            host.detach()
        }
    }
}
