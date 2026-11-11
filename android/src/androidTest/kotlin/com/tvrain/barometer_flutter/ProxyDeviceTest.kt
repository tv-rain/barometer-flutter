package com.tvrain.barometer_flutter

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * `SetProxy` and `ClearProxy` through the facade with the production Android adapters, against
 * loopback test proxies that never contact a target: a configured proxy carries a proxy-path
 * TCP-01 attempt; an unapproved or malformed configuration is `proxy_rejected` and keeps the
 * previous proxy; clearing it leaves proxy-path runs without a proxy; and a proxy generation
 * whose cancelled attempt cannot store its result within the cleanup bound, because the record
 * store is held, returns `cleanup_incomplete` and blocks the client until it is closed. The
 * last test makes the same calls through the channel host and checks the codes Dart receives.
 * No result is printed.
 */
@RunWith(AndroidJUnit4::class)
class ProxyDeviceTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val closeables = mutableListOf<AutoCloseable>()
    private val scopeDir = File(context.noBackupFilesDir, "barometer/$SCOPE")
    private lateinit var store: RecordStore

    @Before
    fun setUp() {
        scopeDir.deleteRecursively()
        DeviceShell.awaitSettledNetwork(context)
    }

    @After
    fun tearDown() {
        closeables.asReversed().forEach { runCatching { it.close() } }
        scopeDir.deleteRecursively()
    }

    private fun newClient(): BarometerClient {
        store = RecordStore.open(context, SCOPE).also { closeables.add(it) }
        val trust = DeviceTestDocuments.trustDocument(
            "TCP-01", DeviceTestDocuments.TCP_TUPLE, listOf(DeviceTestDocuments.CONNECTION_CODE),
        )
        return BarometerBinding.newClient(context, store, trust).also { closeables.add(it) }
    }

    private fun start(owner: BarometerClient, id: String): String {
        val client = owner.facade
        val task = DeviceTestDocuments.runTask(id, "TCP-01", DeviceTestDocuments.TCP_INPUT, "proxy")
        val ref = client.installEmbeddedTask(DeviceTestDocuments.ISSUER, task.toByteArray())
        return client.startRun(client.admitTask(task, ref))
    }

    /** Runs a proxy-path task to its end and returns its execution object. */
    private fun run(owner: BarometerClient, id: String): JSONObject {
        val run = start(owner, id)
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(60)
        while (owner.facade.runState(run) != "terminal") {
            assertTrue("run did not become terminal", System.nanoTime() < deadline)
            Thread.sleep(10)
        }
        val bundle = JSONObject(owner.facade.nextBundle())
        owner.facade.acknowledgeBundle(bundle.getString("bundle_id"))
        return bundle.getJSONArray("results").getJSONObject(0).getJSONObject("execution")
    }

    private fun code(op: () -> Unit): String? = try {
        op()
        null
    } catch (e: Exception) {
        e.message
    }

    @Test
    fun setAndClearProxyThroughTheFacade() {
        val working = AnsweringProxy().also { closeables.add(it) }
        val owner = newClient()
        val client = owner.facade
        client.initialize("{}")

        client.setProxy(working.config().toString())
        assertEquals("completed", run(owner, "proxy-working").getString("state"))
        assertEquals(listOf("1.1.1.1:443"), working.targets.toList())

        // Rejected configurations change nothing: the working proxy still carries the next run.
        val unapproved = working.config("unapproved_code").toString()
        assertEquals("proxy_rejected", code { client.setProxy(unapproved) })
        assertEquals("proxy_rejected", code { client.setProxy("{\"host\":\"127.0.0.1\"}") })
        assertEquals("proxy_rejected", code { client.setProxy(JSONObject().put("host", "127.0.0.1").put("port", 0).put("connection_code", DeviceTestDocuments.CONNECTION_CODE).toString()) })
        assertEquals("completed", run(owner, "proxy-kept").getString("state"))
        assertEquals(2, working.targets.size)

        // Cleared: a proxy-path run does not start any proxy connection; clearing repeats.
        client.clearProxy()
        client.clearProxy()
        val cleared = run(owner, "proxy-cleared")
        assertEquals("not_run", cleared.getString("state"))
        assertEquals(2, working.targets.size)

        // Set again after clearing.
        client.setProxy(working.config().toString())
        assertEquals("completed", run(owner, "proxy-again").getString("state"))
        assertEquals(3, working.targets.size)
    }

    @Test
    fun aGenerationThatCannotDrainIsCleanupIncomplete() {
        for (clear in listOf(false, true)) {
            val stalling = StallingProxy().also { closeables.add(it) }
            val working = AnsweringProxy().also { closeables.add(it) }
            val owner = newClient()
            val client = owner.facade
            client.initialize(JSONObject().put("proxy", stalling.config()).toString())
            val active = start(owner, "drain-$clear")
            assertTrue("proxy not reached", DeviceShell.await(10) { stalling.connects.get() == 1 })
            assertEquals("active", client.runState(active))

            // Hold the record store so the cancelled attempt cannot store its result in time.
            val held = CountDownLatch(1)
            val release = CountDownLatch(1)
            val holder = Thread {
                runCatching { store.serial(30_000) { held.countDown(); release.await(20, TimeUnit.SECONDS) } }
            }.apply { start() }
            assertTrue(held.await(10, TimeUnit.SECONDS))
            val started = System.nanoTime()
            val outcome = code { if (clear) client.clearProxy() else client.setProxy(working.config().toString()) }
            val waited = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)
            assertEquals("cleanup_incomplete", outcome)
            assertTrue("returned after $waited ms", waited in 1_500..10_000)
            // The client stays blocked: no replacement was installed.
            assertEquals("cleanup_incomplete", code { client.clearProxy() })
            assertEquals(0, working.targets.size)

            release.countDown()
            holder.join(10_000)
            owner.close()
            closeables.remove(owner)
            closeables.remove(store)
            store.close()
        }
    }

    /**
     * The proxy codes through the channel host, as Dart receives them: `setProxy` returns
     * `proxy_rejected` for an unapproved connection code, a proxy object carrying a context
     * endpoint and one without a port, and the initial proxy stays configured; with an attempt
     * waiting on it and the host's record store held, `setProxy` and `clearProxy` return
     * `cleanup_incomplete`; `close` succeeds once the store is released.
     */
    @Test
    fun proxyCodesReachTheChannel() {
        val now = System.currentTimeMillis()
        val signer = TestSigner("proxy-key", DeviceTestDocuments.REMOTE_ISSUER, 0x43)
        val document = DeviceTestDocuments.withRemoteIssuer(
            DeviceTestDocuments.trustDocument(
                "TCP-01", DeviceTestDocuments.TCP_TUPLE, listOf(DeviceTestDocuments.CONNECTION_CODE),
            ),
            signer.key(now - 3_600_000L, now + 86_400_000L),
        )
        val host = BarometerHost(context, HostPolicy { document }) {
            RecordStore.open(context, SCOPE).also { store = it }
        }
        val channel = ChannelCaller(host)
        val stalling = StallingProxy().also { closeables.add(it) }
        val working = AnsweringProxy().also { closeables.add(it) }
        try {
            assertNull(channel.initialize(JSONObject().put("proxy", stalling.config()).toString()))
            val rejected = listOf(
                working.config("unapproved_code"),
                working.config().put("primary_endpoint", "https://9.9.9.9/network-context"),
                JSONObject().put("host", "127.0.0.1").put("connection_code", DeviceTestDocuments.CONNECTION_CODE),
            )
            for (proxy in rejected) {
                assertEquals(proxy.toString(), "proxy_rejected", channel.code("setProxy", mapOf("proxy" to proxy.toString())))
            }

            // The initial proxy is kept: the next proxy-path attempt reaches it and waits there.
            val task = DeviceTestDocuments.runTask("channel-drain", "TCP-01", DeviceTestDocuments.TCP_INPUT, "proxy")
            val admitted = channel.admitRemote(signer.sign(task.toByteArray(), now - 60_000L))
            assertNull(admitted.code)
            val run = channel.value("startRun", mapOf("task" to admitted.value)) as String
            assertTrue("proxy not reached", DeviceShell.await(10) { stalling.connects.get() == 1 })
            assertEquals(mapOf("state" to "active"), channel.value("runState", mapOf("run" to run)))

            // Hold the host's record store so the cancelled attempt cannot store its result in time.
            val held = CountDownLatch(1)
            val release = CountDownLatch(1)
            val holder = Thread {
                runCatching { store.serial(30_000) { held.countDown(); release.await(20, TimeUnit.SECONDS) } }
            }.apply { start() }
            assertTrue(held.await(10, TimeUnit.SECONDS))
            assertEquals("cleanup_incomplete", channel.code("setProxy", mapOf("proxy" to working.config().toString())))
            assertEquals("cleanup_incomplete", channel.code("clearProxy"))
            assertEquals(0, working.targets.size)

            release.countDown()
            holder.join(10_000)
            assertNull(channel.code("close"))
        } finally {
            host.detach()
        }
    }

    companion object {
        private const val SCOPE = "proxy-device-test"
    }
}
