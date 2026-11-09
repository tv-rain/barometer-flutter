package com.tvrain.barometer_flutter

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Instrumented tests of the Android adapters through the facade, with synthetic configuration
 * only. TCP-01 contacts 1.1.1.1:443 once and DNS-01 resolves example.org once through the
 * platform resolver; the tests check the lifecycle and the result shape, never the outcome,
 * and print no result.
 */
@RunWith(AndroidJUnit4::class)
class AdapterDeviceTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val testAssets = InstrumentationRegistry.getInstrumentation().context.assets
    private val closeables = mutableListOf<AutoCloseable>()

    private fun scopeDir() = File(context.noBackupFilesDir, "barometer/$SCOPE")

    @Before
    fun setUp() {
        scopeDir().deleteRecursively()
    }

    @After
    fun tearDown() {
        closeables.asReversed().forEach { runCatching { it.close() } }
        scopeDir().deleteRecursively()
    }

    private fun newClient(trust: ByteArray): BarometerClient {
        val store = RecordStore.open(context, SCOPE).also { closeables.add(it) }
        return BarometerBinding.newClient(context, store, trust).also { closeables.add(it) }
    }

    private fun code(e: Exception) = e.message ?: ""

    @Test
    fun adaptersReturnCoarseValues() {
        val now = AndroidClock(context.contentResolver).nowUnixMillis()
        assertTrue(Math.abs(now - System.currentTimeMillis()) < 60_000)
        assertEquals("absent", AndroidConsent().status())
        val battery = AndroidDevice(context).state()
        assertTrue(!battery.percentKnown || battery.percent in 0..100)
        val zone = AndroidTimeZone().identifier()
        assertTrue(zone, zone.isNotEmpty() && zone != "Local")

        AndroidNetwork(context).use { network ->
            val s = network.access()
            assertTrue(s.generation >= 1)
            assertTrue(s.networkType, s.networkType in setOf("wifi", "cellular", "ethernet", "other", "unknown"))
            for (v in listOf(s.ipv4, s.ipv6)) assertTrue(v, v in setOf("yes", "no", "unknown"))
            assertTrue(s.vpn, s.vpn in setOf("detected", "not_detected", "unknown"))
            for (v in listOf(s.validated, s.captivePortal)) assertTrue(v, v in setOf("yes", "no", "unknown"))
            assertTrue(s.suspended, s.suspended in setOf("suspended", "active", "unknown"))
        }
    }

    @Test
    fun watchFiresOnceForAStaleGenerationAndNeverAfterStop() {
        AndroidNetwork(context).use { network ->
            val gen = network.access().generation
            val fired = AtomicInteger()
            val latch = CountDownLatch(1)
            network.watch(gen - 1) { fired.incrementAndGet(); latch.countDown() }
            assertTrue(latch.await(1, TimeUnit.SECONDS))
            val stopped = network.watch(gen - 1) { fired.incrementAndGet() }
            network.stopWatch(stopped)
            val current = network.watch(network.access().generation) { fired.incrementAndGet() }
            network.stopWatch(current)
            Thread.sleep(200)
            assertTrue(fired.get() in 1..2)
            try {
                network.watch(-1) {}
                fail("negative generation was accepted")
            } catch (e: AdapterUnavailableException) {
            }
        }
    }

    @Test
    fun trustDocumentFromThePackageInitializes() {
        val trust = TrustDocument.read(testAssets)
        val client = newClient(trust).facade
        client.initialize("{}")
        try {
            client.initialize("{}")
            fail("second initialize succeeded")
        } catch (e: Exception) {
            assertEquals("already_initialized", code(e))
        }
        assertEquals("", client.nextBundle())
        client.clearMeasurementData()
        client.initialize("{}")
    }

    @Test
    fun invalidTrustIsRejected() {
        val store = RecordStore.open(context, SCOPE).also { closeables.add(it) }
        try {
            BarometerBinding.newClient(context, store, "{}".toByteArray()).close()
            fail("an invalid trust document was accepted")
        } catch (e: Exception) {
            assertEquals("trust_invalid", code(e))
        }
        try {
            TrustDocument.read(testAssets, "barometer/missing.json")
            fail("a missing document was read")
        } catch (e: AdapterUnavailableException) {
        }
    }

    @Test
    fun tcp01RunsThroughTheFacade() {
        val tuple = JSONObject().put("address", TCP_ADDRESS).put("port", 443).put("scheme", "tcp")
        val client = newClient(DeviceTestDocuments.trustDocument("TCP-01", tuple))
        client.facade.initialize("{}")
        val input = JSONObject().put("ip_address", TCP_ADDRESS).put("port", 443)
        val (result, raw) = runOne(client, DeviceTestDocuments.runTask("tcp-device-1", "TCP-01", input))
        assertResult(result, raw, "tcp_connect", listOf(TCP_ADDRESS))
        assertTrue(scopeDir().walk().any { it.isFile && it.parentFile?.name == "records" })
    }

    @Test
    fun dns01RunsThroughTheNativeResolver() {
        val tuple = JSONObject().put("hostname", DNS_NAME)
        val client = newClient(DeviceTestDocuments.trustDocument("DNS-01", tuple))
        client.facade.initialize("{}")
        val input = JSONObject().put("hostname", DNS_NAME).put("record_type", "A")
        val (result, raw) = runOne(client, DeviceTestDocuments.runTask("dns-device-1", "DNS-01", input))
        assertResult(result, raw, "dns_query", listOf(DNS_NAME))
        val outcome = result.getJSONObject("measurement").getString("outcome")
        assertTrue(outcome in setOf("resolved", "no_data", "resolver_error"))
    }

    private fun assertResult(result: JSONObject, raw: String, observation: String, canaries: List<String>) {
        val execution = result.getJSONObject("execution")
        assertEquals(execution.optString("reason"), "completed", execution.getString("state"))
        val measurement = result.getJSONObject("measurement")
        val observations = measurement.getJSONArray("observations")
        assertEquals(1, observations.length())
        assertEquals(observation, observations.getJSONObject(0).getString("type"))
        val implementation = result.getJSONObject("implementation")
        assertEquals("android", implementation.getString("platform"))
        assertEquals("0.1.0", implementation.getString("library_version"))
        for (c in canaries) assertFalse("result retained a target", raw.contains(c))
    }

    /** Installs, admits and runs [task], returns its result from the bundle, then acknowledges. */
    private fun runOne(owner: BarometerClient, task: String): Pair<JSONObject, String> {
        val client = owner.facade
        val ref = client.installEmbeddedTask(DeviceTestDocuments.ISSUER, task.toByteArray())
        val handle = client.admitTask(task, ref)
        val run = client.startRun(handle)
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(30)
        while (client.runState(run) != "terminal") {
            if (System.nanoTime() > deadline) fail("run did not become terminal")
            Thread.sleep(10)
        }
        val raw = client.nextBundle()
        assertTrue("no bundle", raw.isNotEmpty())
        val bundle = JSONObject(raw)
        val results = bundle.getJSONArray("results")
        assertEquals(1, results.length())
        client.acknowledgeBundle(bundle.getString("bundle_id"))
        assertEquals("", client.nextBundle())
        return results.getJSONObject(0) to raw
    }

    companion object {
        private const val SCOPE = "adapter-device-test"
        private const val TCP_ADDRESS = "1.1.1.1"
        private const val DNS_NAME = "example.org"
    }
}
