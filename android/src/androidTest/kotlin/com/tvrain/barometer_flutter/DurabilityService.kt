package com.tvrain.barometer_flutter

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Binder
import android.os.IBinder
import java.io.File
import java.security.MessageDigest
import org.json.JSONObject

/**
 * Test-only service in the `:durability` process. It owns the test scope with a facade client
 * and leaves state of every kind that must survive a process kill, then keeps an attempt
 * active until its process is killed:
 *
 * - a one-time task and a repeating task (at most two runs, six hours apart), each run once to
 *   completion on the proxy path through a loopback proxy that answers CONNECT without
 *   contacting the target, so their replay records, run-ledger entries and pending bundle are
 *   stored;
 * - before the kill, the check the test repeats after it: a task that reuses the one-time
 *   task's identifier with other content, which its replay record rejects;
 * - a third task whose attempt waits on a loopback proxy that never answers.
 *
 * Everything the test needs afterwards goes to [stateFile]: the trusted local document, the
 * tasks, the SHA-256 of the oldest pending bundle and the codes seen. `active` is written last.
 */
class DurabilityService : Service() {
    override fun onBind(intent: Intent): IBinder {
        Thread({ run() }, "durability").apply { isDaemon = true }.start()
        return Binder()
    }

    private fun run() {
        val answering = AnsweringProxy()
        val stalling = StallingProxy()
        val trust = trust()
        val store = RecordStore.open(this, SCOPE)
        val owner = BarometerBinding.newClient(this, store, trust)
        val client = owner.facade
        client.initialize(config(answering.config()))

        val once = DeviceTestDocuments.runTask("durability-once", "TCP-01", DeviceTestDocuments.TCP_INPUT, "proxy")
        val repeating = repeatingTask("durability-repeating")
        awaitTerminal(client, client.startRun(admit(client, once)))
        awaitTerminal(client, client.startRun(admit(client, repeating)))
        val bundle = client.nextBundle()

        val state = JSONObject()
            .put("trust", String(trust)).put("once", once).put("repeating", repeating)
            .put("bundle_sha256", sha256(bundle))
            .put("conflict", code { admit(client, conflicting(once)) })

        client.setProxy(stalling.config().toString())
        val active = client.startRun(
            admit(client, DeviceTestDocuments.runTask("durability-active", "TCP-01", DeviceTestDocuments.TCP_INPUT, "proxy")),
        )
        while (stalling.connects.get() == 0) Thread.sleep(10)
        if (client.runState(active) == "active") stateFile(this).writeText(state.put("active", true).toString())
        Thread.sleep(Long.MAX_VALUE)
    }

    companion object {
        const val SCOPE = "durability-test"

        fun trust(): ByteArray = DeviceTestDocuments.trustDocument(
            "TCP-01", DeviceTestDocuments.TCP_TUPLE,
            listOf(DeviceTestDocuments.CONNECTION_CODE), listOf(DeviceTestDocuments.LINKAGE_SCOPE),
        )

        /** Rotating linkage with the loopback proxy [proxy]. */
        fun config(proxy: JSONObject): String =
            JSONObject(DeviceTestDocuments.linkedConfig()).put("proxy", proxy).toString()

        fun stateFile(context: Context) = File(context.filesDir, "durability-state")

        /** A TCP-01 task on the proxy path with at most two runs, six hours apart. */
        fun repeatingTask(id: String): String {
            val task = JSONObject(DeviceTestDocuments.runTask(id, "TCP-01", DeviceTestDocuments.TCP_INPUT, "proxy"))
            task.getJSONObject("schedule")
                .put("repeat", JSONObject().put("mode", "interval").put("interval", 21600).put("jitter", 300))
                .put("limits", JSONObject().put("max_runs", 2))
            return task.toString()
        }

        /** [task] with the same identifier and an expiry one hour earlier. */
        fun conflicting(task: String): String {
            val root = JSONObject(task)
            val schedule = root.getJSONObject("schedule")
            val format = java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", java.util.Locale.US)
                .apply { timeZone = java.util.TimeZone.getTimeZone("UTC") }
            val notAfter = format.parse(schedule.getString("not_after"))!!.time - 3_600_000L
            schedule.put("not_after", format.format(java.util.Date(notAfter)))
            return root.toString()
        }

        fun admit(client: barometermobile.Client, task: String): String =
            client.admitTask(task, client.installEmbeddedTask(DeviceTestDocuments.ISSUER, task.toByteArray()))

        fun awaitTerminal(client: barometermobile.Client, run: String) {
            val deadline = System.nanoTime() + 30_000_000_000L
            while (client.runState(run) != "terminal") {
                check(System.nanoTime() < deadline) { "run did not become terminal" }
                Thread.sleep(10)
            }
        }

        fun code(op: () -> Unit): String = try {
            op()
            "ok"
        } catch (e: Exception) {
            e.message ?: "error"
        }

        fun sha256(text: String): String =
            MessageDigest.getInstance("SHA-256").digest(text.toByteArray()).joinToString("") { "%02x".format(it) }
    }
}
