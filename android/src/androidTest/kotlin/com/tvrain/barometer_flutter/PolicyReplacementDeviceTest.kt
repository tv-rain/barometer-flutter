package com.tvrain.barometer_flutter

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The host rows of the local policy lifecycle through the channel host and the host policy
 * adapter: a replacement document is activated only by reinitialization with a strictly greater
 * generation, cancels the active run and invalidates the previous generation's handles, and a
 * rollback, an equal generation with other content and an invalid document leave the active
 * policy, its run and its handles in place. Tasks arrive as signed remote packages; the run waits
 * on a loopback proxy that never answers. Nothing contacts the network.
 */
@RunWith(AndroidJUnit4::class)
class PolicyReplacementDeviceTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val closeables = mutableListOf<AutoCloseable>()
    private val signer = TestSigner("remote-key-1", DeviceTestDocuments.REMOTE_ISSUER, 0x31)

    @Volatile
    private var document: ByteArray = ByteArray(0)
    private val policy = HostPolicy { document }
    private lateinit var host: BarometerHost
    private lateinit var channel: ChannelCaller

    private fun scopeDir() = File(context.noBackupFilesDir, "barometer/${RecordStore.DEFAULT_SCOPE}")

    @Before
    fun setUp() {
        scopeDir().deleteRecursively()
        DeviceShell.awaitSettledNetwork(context)
        host = BarometerHost(context, policy)
        channel = ChannelCaller(host)
    }

    @After
    fun tearDown() {
        channel.code("close")
        host.detach()
        closeables.asReversed().forEach { runCatching { it.close() } }
        scopeDir().deleteRecursively()
    }

    /** A generation [generation] document that permits TCP-01 to the registered target, with [owner]. */
    private fun policyDocument(generation: Long, owner: String = "synthetic", registered: Boolean = true): ByteArray {
        val now = System.currentTimeMillis()
        val base = DeviceTestDocuments.trustDocument(
            "TCP-01", DeviceTestDocuments.TCP_TUPLE, listOf(DeviceTestDocuments.CONNECTION_CODE),
        )
        val remote = DeviceTestDocuments.withRemoteIssuer(base, signer.key(now - 3_600_000L, now + 86_400_000L))
        return DeviceTestDocuments.edit(DeviceTestDocuments.withGeneration(remote, generation)) { root ->
            val policy = root.getJSONObject("policy")
            policy.getJSONArray("targets").getJSONObject(0).put("owner", owner)
            if (!registered) {
                // Generation 3 removes the registration from the policy and every issuer.
                policy.put("targets", JSONArray())
                policy.getJSONObject("permissions").put("registration_ids", JSONArray())
                val issuers = policy.getJSONArray("issuers")
                for (i in 0 until issuers.length()) {
                    issuers.getJSONObject(i).getJSONObject("permissions").put("registration_ids", JSONArray())
                }
            }
        }
    }

    private fun remotePackage(id: String, path: String? = null): ByteArray {
        val task = DeviceTestDocuments.runTask(id, "TCP-01", DeviceTestDocuments.TCP_INPUT, path)
        return signer.sign(task.toByteArray(), System.currentTimeMillis() - 60_000L)
    }

    private fun proxyConfig(proxy: StallingProxy) = JSONObject().put("proxy", proxy.config()).toString()

    private fun state(run: String): String? {
        val outcome = channel.call("runState", mapOf("run" to run))
        return outcome.code ?: (outcome.value as Map<*, *>)["state"] as String
    }

    @Test
    fun replacementCancelsRunsAndRejectsRollback() {
        val proxy = StallingProxy().also { closeables.add(it) }
        // Each document is built once: a rebuilt one differs in its validity times.
        val generation2 = policyDocument(2)
        val generation3 = policyDocument(3, registered = false)
        document = generation2
        assertNull(channel.initialize(proxyConfig(proxy)))
        // The same document again is no replacement.
        assertEquals("already_initialized", channel.initialize(proxyConfig(proxy)))

        val running = remotePackage("replace-running", "proxy")
        val runningTask = channel.admitRemote(running).value as String
        val run = channel.value("startRun", mapOf("task" to runningTask)) as String
        assertTrue("proxy not reached", DeviceShell.await(10) { proxy.connects.get() == 1 })
        assertEquals("active", state(run))
        val idleTask = channel.admitRemote(remotePackage("replace-idle", "proxy")).value as String

        // Rejected updates leave generation 2, its run and its handles in place.
        for ((rejected, code) in listOf(
            policyDocument(1) to "policy_rejected",
            policyDocument(2, owner = "synthetic-other") to "policy_rejected",
            DeviceTestDocuments.edit(policyDocument(3)) { it.put("unknown_member", true) } to "trust_invalid",
            "{\"policy\":{\"generation\":4}}".toByteArray() to "trust_invalid",
        )) {
            document = rejected
            assertEquals(code, channel.initialize(proxyConfig(proxy)))
            assertEquals("active", state(run))
        }

        // Generation 3 removes the registration: reinitialization cancels the run and the
        // generation-2 handles no longer resolve.
        document = generation3
        assertNull(channel.initialize(proxyConfig(proxy)))
        assertEquals("handle_unavailable", state(run))
        assertEquals("handle_unavailable", channel.code("startRun", mapOf("task" to idleTask)))
        assertEquals("handle_unavailable", channel.code("startRun", mapOf("task" to runningTask)))
        val bundle = channel.takeBundle()
        assertNotNull("no result for the cancelled run", bundle)
        val execution = bundle!!.getJSONArray("results").getJSONObject(0).getJSONObject("execution")
        assertEquals("cancelled_by_host", execution.optString("reason"))
        assertNull(channel.takeBundle())
        // No attempt continues or starts under the removed registration.
        assertEquals("target_not_registered", channel.admitRemote(running).code)
        assertEquals("target_not_registered", channel.admitRemote(remotePackage("replace-new", "proxy")).code)
        assertEquals(1, proxy.connects.get())

        // A rollback after the replacement is rejected, and generation 3 stays active.
        document = generation2
        assertEquals("policy_rejected", channel.initialize(proxyConfig(proxy)))
        document = generation3
        assertEquals("already_initialized", channel.initialize(proxyConfig(proxy)))

        // After close, and for another engine of the process, the floor still holds.
        assertNull(channel.code("close"))
        document = generation2
        assertEquals("policy_rejected", channel.initialize("{}"))
        host.detach()
        host = BarometerHost(context, policy)
        channel = ChannelCaller(host)
        assertEquals("policy_rejected", channel.initialize("{}"))
        document = generation3
        assertNull(channel.initialize("{}"))
        document = policyDocument(4)
        assertNull(channel.initialize("{}"))
        // Generation 4 restores the registration: a new package is admitted under it.
        assertTrue(channel.admitRemote(remotePackage("replace-restored")).code == null)
    }
}
