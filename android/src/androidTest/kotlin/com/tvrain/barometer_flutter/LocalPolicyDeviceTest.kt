package com.tvrain.barometer_flutter

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.concurrent.TimeUnit
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The local restriction inputs of the trusted local document on the emulator, through the
 * facade with the production Android adapters. The `device` member gates runs on the battery
 * state the Android device adapter reads, which the test sets with `dumpsys battery` and then
 * resets. The `network_context` member keeps Network Context acquisition off a path it does not
 * list, while the same configuration without it acquires there. Attempts take the proxy path
 * through a loopback proxy that never contacts a target or the context endpoint, so the
 * endpoint's public address (`9.9.9.9`) is only ever named in a CONNECT request to that proxy,
 * which refuses it. No result is printed.
 */
@RunWith(AndroidJUnit4::class)
class LocalPolicyDeviceTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val closeables = mutableListOf<AutoCloseable>()
    private val scopeDir = File(context.noBackupFilesDir, "barometer/$SCOPE")

    @Before
    fun setUp() {
        scopeDir.deleteRecursively()
    }

    @After
    fun tearDown() {
        DeviceShell.run("dumpsys battery reset")
        closeables.asReversed().forEach { runCatching { it.close() } }
        scopeDir.deleteRecursively()
    }

    private fun document(change: (JSONObject) -> Unit = {}): ByteArray {
        val base = DeviceTestDocuments.trustDocument(
            "TCP-01", DeviceTestDocuments.TCP_TUPLE, listOf(DeviceTestDocuments.CONNECTION_CODE),
        )
        return DeviceTestDocuments.edit(base) { root ->
            root.getJSONObject("configuration_approvals").put("endpoints", JSONArray().put(ENDPOINT))
            root.getJSONObject("context_approvals")
                .put("connection_codes", JSONArray().put(DeviceTestDocuments.CONNECTION_CODE))
            change(root.getJSONObject("policy"))
        }
    }

    private fun newClient(trust: ByteArray, proxy: AnsweringProxy): BarometerClient {
        scopeDir.deleteRecursively()
        val store = RecordStore.open(context, SCOPE).also { closeables.add(it) }
        val owner = BarometerBinding.newClient(context, store, trust).also { closeables.add(it) }
        owner.facade.initialize(
            JSONObject().put("proxy", proxy.config())
                .put("network_context", JSONObject().put("primary_endpoint", ENDPOINT)).toString(),
        )
        return owner
    }

    private fun closeClient() {
        closeables.asReversed().forEach { runCatching { it.close() } }
        closeables.clear()
    }

    private fun admit(owner: BarometerClient, id: String, requiresContext: Boolean = false): String {
        val client = owner.facade
        val task = JSONObject(DeviceTestDocuments.runTask(id, "TCP-01", DeviceTestDocuments.TCP_INPUT, "proxy"))
        if (requiresContext) {
            task.getJSONObject("execution").put(
                "network",
                JSONObject().put("context", JSONObject().put("required_fields", JSONArray().put("country_code"))),
            )
        }
        val bytes = task.toString()
        return client.admitTask(bytes, client.installEmbeddedTask(DeviceTestDocuments.ISSUER, bytes.toByteArray()))
    }

    /** Runs [task] to its end and returns its result. */
    private fun run(owner: BarometerClient, task: String): JSONObject {
        val run = owner.facade.startRun(task)
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(60)
        while (owner.facade.runState(run) != "terminal") {
            assertTrue("run did not become terminal", System.nanoTime() < deadline)
            Thread.sleep(10)
        }
        val bundle = JSONObject(owner.facade.nextBundle())
        owner.facade.acknowledgeBundle(bundle.getString("bundle_id"))
        return bundle.getJSONArray("results").getJSONObject(0)
    }

    private fun code(op: () -> Unit): String? = try {
        op()
        null
    } catch (e: Exception) {
        e.message
    }

    private fun battery(level: Int, charging: Boolean) {
        DeviceShell.run("dumpsys battery set level $level")
        DeviceShell.run("dumpsys battery set ac ${if (charging) 1 else 0}")
        DeviceShell.run("dumpsys battery set usb 0")
        DeviceShell.run("dumpsys battery set wireless 0")
        DeviceShell.run("dumpsys battery set status ${if (charging) 2 else 3}")
        // The adapter reads the sticky battery broadcast, which follows shortly.
        Thread.sleep(1_000)
    }

    @Test
    fun deviceConstraintsGateRuns() {
        val proxy = AnsweringProxy().also { closeables.add(it) }
        val owner = newClient(
            document { it.put("device", JSONObject().put("minimum_battery_percent", 50).put("charging_only", true)) },
            proxy,
        )
        val task = admit(owner, "device-gated")

        battery(level = 80, charging = false)
        assertEquals("run_not_due", code { owner.facade.startRun(task) })
        battery(level = 40, charging = true)
        assertEquals("run_not_due", code { owner.facade.startRun(task) })
        assertTrue(proxy.targets.isEmpty())
        battery(level = 80, charging = true)
        assertEquals("completed", run(owner, task).getJSONObject("execution").getString("state"))

        // Without the member, the same battery state does not gate the task.
        closeClient()
        val free = AnsweringProxy().also { closeables.add(it) }
        val control = newClient(document(), free)
        battery(level = 40, charging = false)
        assertEquals("completed", run(control, admit(control, "device-free")).getJSONObject("execution").getString("state"))
    }

    @Test
    fun contextEligibilityKeepsAcquisitionOffUnlistedPaths() {
        val proxy = AnsweringProxy().also { closeables.add(it) }
        val owner = newClient(
            document {
                it.put(
                    "network_context",
                    JSONObject().put("paths", JSONObject().put("direct", true).put("proxy", false))
                        .put("endpoints", JSONArray().put(ENDPOINT)),
                )
            },
            proxy,
        )
        val plain = run(owner, admit(owner, "context-plain"))
        assertEquals("completed", plain.getJSONObject("execution").getString("state"))
        assertEquals("unavailable", plain.getJSONObject("network_context").getJSONObject("egress").getString("status"))
        val required = run(owner, admit(owner, "context-required", requiresContext = true))
        assertEquals("not_run", required.getJSONObject("execution").getString("state"))
        assertEquals("network_context_unavailable", required.getJSONObject("execution").getString("reason"))
        assertFalse(proxy.targets.contains(ENDPOINT_TARGET))

        // Without the member, the same configuration asks the endpoint through the proxy.
        closeClient()
        val open = AnsweringProxy().also { closeables.add(it) }
        val control = newClient(document(), open)
        run(control, admit(control, "context-control"))
        assertTrue(open.targets.contains(ENDPOINT_TARGET))
    }

    companion object {
        private const val SCOPE = "local-policy-device-test"
        private const val ENDPOINT = "https://9.9.9.9/network-context"
        private const val ENDPOINT_TARGET = "9.9.9.9:443"
    }
}
