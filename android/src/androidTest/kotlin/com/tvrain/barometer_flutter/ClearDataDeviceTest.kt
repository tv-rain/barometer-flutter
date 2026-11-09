package com.tvrain.barometer_flutter

import android.content.Context
import android.os.Build
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.security.KeyStore
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The native rows of the clear-data contract through the facade with the production Android
 * adapters: with rotating linkage, an acknowledged and a pending bundle and an active attempt,
 * `clearMeasurementData` cancels the attempt, deletes every record, the Keystore key and the
 * sentinel, and creates no replacement key until linkage is next needed; an interrupted
 * deletion is reported as `clearing_incomplete` and completed by a later clear. TCP-01 contacts
 * 1.1.1.1:443; the active attempt waits on a loopback proxy that never answers. No result is
 * printed.
 */
@RunWith(AndroidJUnit4::class)
class ClearDataDeviceTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val closeables = mutableListOf<AutoCloseable>()
    private val scopeDir = File(context.noBackupFilesDir, "barometer/$SCOPE")
    private val alias = AndroidLinkageKeys.alias(scopeDir)
    private val sentinel = AndroidLinkageKeys.sentinel(scopeDir)

    private fun keyExists(): Boolean =
        Build.VERSION.SDK_INT >= 23 && KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.containsAlias(alias)

    private fun records(): List<String> = File(scopeDir, "records").list()?.toList() ?: emptyList()

    @Before
    fun setUp() {
        scopeDir.deleteRecursively()
        if (Build.VERSION.SDK_INT >= 23) KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(alias)
    }

    @After
    fun tearDown() {
        closeables.asReversed().forEach { runCatching { it.close() } }
        if (Build.VERSION.SDK_INT >= 23) KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(alias)
        scopeDir.deleteRecursively()
    }

    private fun newClient(): BarometerClient {
        val store = RecordStore.open(context, SCOPE).also { closeables.add(it) }
        val trust = DeviceTestDocuments.trustDocument(
            "TCP-01", DeviceTestDocuments.TCP_TUPLE,
            listOf(DeviceTestDocuments.CONNECTION_CODE), listOf(DeviceTestDocuments.LINKAGE_SCOPE),
        )
        return BarometerBinding.newClient(context, store, trust).also { closeables.add(it) }
    }

    private fun start(owner: BarometerClient, id: String, path: String? = null): String {
        val client = owner.facade
        val task = DeviceTestDocuments.runTask(id, "TCP-01", DeviceTestDocuments.TCP_INPUT, path)
        val ref = client.installEmbeddedTask(DeviceTestDocuments.ISSUER, task.toByteArray())
        return client.startRun(client.admitTask(task, ref))
    }

    private fun awaitTerminal(owner: BarometerClient, run: String) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(30)
        while (owner.facade.runState(run) != "terminal") {
            assertTrue("run did not become terminal", System.nanoTime() < deadline)
            Thread.sleep(10)
        }
    }

    private fun code(op: () -> Unit): String? = try {
        op()
        null
    } catch (e: Exception) {
        e.message
    }

    @Test
    fun clearingDeletesEverythingAndCreatesNoReplacementKey() {
        val proxy = StallingProxy().also { closeables.add(it) }
        val owner = newClient()
        val client = owner.facade
        client.initialize(DeviceTestDocuments.linkedConfig(proxy))

        awaitTerminal(owner, start(owner, "clear-acknowledged"))
        val acknowledged = JSONObject(client.nextBundle())
        client.acknowledgeBundle(acknowledged.getString("bundle_id"))
        awaitTerminal(owner, start(owner, "clear-pending"))

        if (Build.VERSION.SDK_INT >= 23) {
            val linkage = acknowledged.getJSONObject("linkage")
            assertEquals("rotating_installation", linkage.getString("mode"))
            assertEquals(43, linkage.getString("token").length)
            assertTrue(keyExists())
            assertTrue(sentinel.isFile)
        } else {
            // No key store before API 23: linkage stays disabled.
            assertFalse(acknowledged.has("linkage"))
        }

        val active = start(owner, "clear-active", "proxy")
        assertTrue("proxy not reached", DeviceShell.await(10) { proxy.connects.get() == 1 })
        assertEquals("active", client.runState(active))
        assertTrue(records().isNotEmpty())

        val started = System.nanoTime()
        client.clearMeasurementData()
        assertTrue(TimeUnit.NANOSECONDS.toSeconds(System.nanoTime() - started) < 10)
        // Clearing ends uninitialized, so the run handle is gone with the generation.
        assertEquals("not_initialized", code { client.runState(active) })
        assertEquals(emptyList<String>(), records())
        assertFalse(keyExists())
        assertFalse(sentinel.exists())

        // Clearing is repeatable, and a new generation creates no key until linkage needs one.
        client.clearMeasurementData()
        client.initialize(DeviceTestDocuments.linkedConfig(proxy))
        assertEquals("", client.nextBundle())
        assertFalse(keyExists())
        assertFalse(sentinel.exists())
    }

    @Test
    fun anInterruptedClearIsIncompleteUntilCompleted() {
        assumeTrue("no key store before API 23", Build.VERSION.SDK_INT >= 23)
        val owner = newClient()
        val client = owner.facade
        client.initialize(DeviceTestDocuments.linkedConfig())
        awaitTerminal(owner, start(owner, "interrupted-pending"))
        assertTrue(records().isNotEmpty())
        assertTrue(keyExists())
        // A directory in place of the sentinel cannot be deleted as a file.
        assertTrue(sentinel.delete())
        assertTrue(File(sentinel, "blocker").mkdirs())

        assertEquals("clearing_incomplete", code { client.clearMeasurementData() })
        assertEquals("clearing_incomplete", code { client.initialize("{}") })
        assertTrue(sentinel.deleteRecursively())
        client.clearMeasurementData()
        assertEquals(emptyList<String>(), records())
        assertFalse(keyExists())
        assertFalse(sentinel.exists())
        client.initialize("{}")
        assertEquals("", client.nextBundle())
    }

    @Test
    fun closingCancelsAnActiveAttempt() {
        val proxy = StallingProxy().also { closeables.add(it) }
        val owner = newClient()
        owner.facade.initialize(DeviceTestDocuments.linkedConfig(proxy))
        val active = start(owner, "close-active", "proxy")
        assertTrue("proxy not reached", DeviceShell.await(10) { proxy.connects.get() == 1 })
        assertEquals("active", owner.facade.runState(active))
        val started = System.nanoTime()
        owner.close()
        assertTrue(TimeUnit.NANOSECONDS.toSeconds(System.nanoTime() - started) < 10)
        closeables.remove(owner)
        try {
            owner.facade.runState(active)
            fail("a closed client answered")
        } catch (e: Exception) {
        }

        // The cancelled attempt is recorded as cancelled_by_host in the scope.
        closeables.removeAt(closeables.lastIndex).close()
        val reopened = newClient()
        reopened.facade.initialize(DeviceTestDocuments.linkedConfig(proxy))
        val raw = reopened.facade.nextBundle()
        assertTrue("no result for the cancelled attempt", raw.isNotEmpty())
        val execution = JSONObject(raw).getJSONArray("results").getJSONObject(0).getJSONObject("execution")
        assertEquals("cancelled_by_host", execution.optString("reason"))
    }

    companion object {
        private const val SCOPE = "clear-data-device-test"
    }
}
