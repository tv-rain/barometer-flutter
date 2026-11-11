package com.tvrain.barometer_flutter

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Admission classes, execution states, byte accounting and task context values of the Go
 * specification findings, through the channel host against the facade with the production
 * Android adapters. Every task is a signed remote package of a synthetic issuer, so any task
 * content can be admitted through the channel. The answers checked are the ones Dart receives:
 * the channel error code, and the exact bundle bytes `nextBundle` returns.
 *
 * Runs take the proxy path through loopback proxies that never contact a target, so nothing
 * leaves the emulator. No result is printed.
 */
@RunWith(AndroidJUnit4::class)
class FindingAdoptionDeviceTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val now = System.currentTimeMillis()
    private val signer = TestSigner("finding-key", DeviceTestDocuments.REMOTE_ISSUER, 0x41)
    private val closeables = mutableListOf<AutoCloseable>()
    private lateinit var host: BarometerHost
    private lateinit var channel: ChannelCaller

    private fun scopeDir() = File(context.noBackupFilesDir, "barometer/${RecordStore.DEFAULT_SCOPE}")

    @Before
    fun setUp() {
        scopeDir().deleteRecursively()
        DeviceShell.awaitSettledNetwork(context)
        host = BarometerHost(context, HostPolicy { document() })
        channel = ChannelCaller(host)
    }

    @After
    fun tearDown() {
        channel.code("close")
        host.detach()
        closeables.asReversed().forEach { runCatching { it.close() } }
        scopeDir().deleteRecursively()
    }

    /**
     * TCP-01 to 1.1.1.1:443 and NET-01 permitted for the deployment and both issuers, DNS-01
     * for the deployment only, the test proxies' connection code approved, and the remote
     * issuer's key.
     */
    private fun document(): ByteArray {
        val base = DeviceTestDocuments.trustDocument(
            "TCP-01", DeviceTestDocuments.TCP_TUPLE, listOf(DeviceTestDocuments.CONNECTION_CODE),
        )
        val tests = DeviceTestDocuments.edit(base) { root ->
            val policy = root.getJSONObject("policy")
            policy.getJSONObject("permissions").getJSONArray("tests").put(ref("NET-01")).put(ref("DNS-01"))
            policy.getJSONArray("issuers").getJSONObject(0).getJSONObject("permissions")
                .getJSONArray("tests").put(ref("NET-01"))
        }
        return DeviceTestDocuments.withRemoteIssuer(tests, signer.key(now - 3_600_000L, now + 86_400_000L))
    }

    private fun ref(test: String) = JSONObject().put("id", test).put("version", "0.1.0")

    /** A TCP-01 task on [path] as an object, for the cases to change before signing. */
    private fun task(id: String, path: String? = null): JSONObject =
        JSONObject(DeviceTestDocuments.runTask(id, "TCP-01", DeviceTestDocuments.TCP_INPUT, path))

    private fun admit(task: JSONObject): ChannelCaller.Outcome =
        channel.admitRemote(signer.sign(task.toString().toByteArray(), now - 60_000L))

    private fun admitted(task: JSONObject): String {
        val outcome = admit(task)
        assertNull(task.getString("task_id"), outcome.code)
        return outcome.value as String
    }

    /** Runs [task] to its end through the channel and returns the exact bundle bytes. */
    private fun runToBundle(task: String): ByteArray {
        val run = channel.value("startRun", mapOf("task" to task)) as String
        channel.awaitTerminal(run)
        return takeBytes()
    }

    /** Reads the oldest pending bundle's bytes twice and acknowledges it. */
    private fun takeBytes(): ByteArray {
        val bytes = channel.value("nextBundle") as ByteArray
        // Without an acknowledgement the same bundle is returned again, byte for byte.
        assertArrayEquals(bytes, channel.value("nextBundle") as ByteArray)
        val id = JSONObject(String(bytes, Charsets.UTF_8)).getString("bundle_id")
        assertNull(channel.code("acknowledgeBundle", mapOf("id" to id)))
        return bytes
    }

    private fun result(bytes: ByteArray): JSONObject =
        JSONObject(String(bytes, Charsets.UTF_8)).getJSONArray("results").getJSONObject(0)

    @Test
    fun admissionClassesReachTheChannelUnchanged() {
        assertNull(channel.initialize("{}"))
        val cases = linkedMapOf<String, Pair<JSONObject, String?>>()
        cases["admitted"] = task("class-admitted") to null
        // GO-SPEC-ISSUE-008: the step-4 row (an unregistered test version) is task_unsupported.
        cases["unregistered version"] = task("class-version").put("test_version", "0.2.0") to "task_unsupported"
        cases["long task_id"] = task("x".repeat(129)) to "task_limit_exceeded"
        cases["limit above the policy"] = task("class-limit").apply {
            getJSONObject("execution").put("limits", JSONObject().put("max_connections", 13))
        } to "task_limit_exceeded"
        cases["expired"] = task("class-expired").apply {
            getJSONObject("schedule").put("not_after", TestSigner.utc(now - 60_000L))
        } to "task_expired"
        cases["test not permitted for the issuer"] =
            JSONObject(DeviceTestDocuments.runTask("class-issuer", "DNS-01", JSONObject())) to "task_issuer_not_authorized"
        cases["unregistered target"] = JSONObject(
            DeviceTestDocuments.runTask("class-target", "TCP-01", JSONObject().put("ip_address", "1.0.0.1").put("port", 443)),
        ) to "target_not_registered"
        // GO-SPEC-ISSUE-007: an empty risk_factors for medium risk, and a timezone other
        // than local, are rejected; the valid forms are admitted.
        cases["medium risk without factors"] = task("class-risk-empty").apply {
            put("safety", JSONObject().put("risk_level", "medium").put("requires_user_consent", false).put("risk_factors", JSONArray()))
        } to "task_schema_invalid"
        cases["medium risk with a factor"] = task("class-risk-factor").apply {
            put(
                "safety",
                JSONObject().put("risk_level", "medium").put("requires_user_consent", false)
                    .put("risk_factors", JSONArray().put(JSONObject().put("type", "network_observability").put("level", "medium"))),
            )
        } to null
        cases["timezone UTC"] = task("class-tz-utc").apply { getJSONObject("schedule").put("time_window", window("UTC")) } to "task_schema_invalid"
        cases["timezone local"] = task("class-tz-local").apply { getJSONObject("schedule").put("time_window", window("local")) } to null
        // GO-SPEC-ISSUE-009: a test HTTP CONNECT cannot carry is task_schema_invalid on the
        // proxy path; the same task is admitted on the direct path.
        cases["NET-01 on the proxy path"] =
            JSONObject(DeviceTestDocuments.runTask("class-net01-proxy", "NET-01", JSONObject(), "proxy")) to "task_schema_invalid"
        cases["NET-01 direct"] = JSONObject(DeviceTestDocuments.runTask("class-net01", "NET-01", JSONObject())) to null
        for ((name, case) in cases) {
            val outcome = admit(case.first)
            assertEquals(name, case.second, outcome.code)
            if (case.second == null) assertTrue(name, (outcome.value as String).isNotEmpty())
        }
        // The same task_id with other bytes, after the first was admitted.
        val other = task("class-admitted").apply {
            getJSONObject("schedule").put("not_after", TestSigner.utc(now + 43_200_000L))
        }
        assertEquals("task_id_conflict", admit(other).code)
        // An unsigned package.
        assertEquals("task_source_unauthenticated", channel.admitRemote("{}".toByteArray()).code)
    }

    private fun window(zone: String) = JSONObject().put("timezone", zone)
        .put("ranges", JSONArray().put(JSONObject().put("start", "00:00").put("end", "23:59")))

    @Test
    fun executionStatesAndByteAccountingReachTheChannelUnchanged() {
        val answering = AnsweringProxy().also { closeables.add(it) }
        assertNull(channel.initialize(JSONObject().put("proxy", answering.config()).toString()))

        // GO-SPEC-ISSUE-005: the CONNECT exchange is not counted, and TCP-01 writes and reads
        // no test bytes, so the smallest byte limits complete although the proxy exchanged
        // more bytes than that.
        val smallest = task("state-smallest-limits", "proxy").apply {
            getJSONObject("execution").put(
                "limits", JSONObject().put("max_bytes_sent", 1).put("max_bytes_received", 1).put("max_connections", 1),
            )
        }
        val completed = result(runToBundle(admitted(smallest)))
        assertEquals("completed", completed.getJSONObject("execution").getString("state"))
        assertFalse(completed.getJSONObject("execution").has("reason"))
        assertTrue(completed.has("network_context"))
        assertTrue(completed.has("measurement"))
        assertEquals(listOf("1.1.1.1:443"), answering.targets.toList())

        // Without a proxy, a proxy-path attempt starts no test (GO-SPEC-ISSUE-004 case 1): it is
        // not_run, and its result carries no Network Context (REQ-RESULT-0053).
        assertNull(channel.code("clearProxy"))
        val notRun = result(runToBundle(admitted(task("state-no-proxy", "proxy"))))
        assertEquals("not_run", notRun.getJSONObject("execution").getString("state"))
        assertTrue(notRun.getJSONObject("execution").getString("reason").isNotEmpty())
        assertFalse(notRun.has("network_context"))
        assertFalse(notRun.has("measurement"))
        assertEquals(1, answering.targets.size)

        // Cancelled after the test started at its first dial (case 1): incomplete with the
        // host's reason and Network Context, and no measurement.
        val stalling = StallingProxy().also { closeables.add(it) }
        assertNull(channel.code("setProxy", mapOf("proxy" to stalling.config().toString())))
        val run = channel.value("startRun", mapOf("task" to admitted(task("state-cancelled", "proxy")))) as String
        assertTrue("proxy not reached", DeviceShell.await(10) { stalling.connects.get() == 1 })
        assertNull(channel.code("cancelRun", mapOf("run" to run)))
        channel.awaitTerminal(run)
        val incomplete = result(takeBytes())
        assertEquals("incomplete", incomplete.getJSONObject("execution").getString("state"))
        assertEquals("cancelled_by_host", incomplete.getJSONObject("execution").getString("reason"))
        assertTrue(incomplete.has("network_context"))
        assertFalse(incomplete.has("measurement"))
    }
}
