package com.tvrain.barometer_flutter

import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.IBinder
import java.io.File

/**
 * Test-only service in the `:runner` process. It owns the test scope, starts a TCP-01 attempt
 * on the proxy path through a loopback proxy that never answers, writes `active` to
 * [progressFile] once the attempt is waiting on the proxy, and keeps it active until its process
 * is killed.
 */
class RunnerService : Service() {
    override fun onBind(intent: Intent): IBinder {
        Thread({ run() }, "runner").apply { isDaemon = true }.start()
        return Binder()
    }

    private fun run() {
        val proxy = StallingProxy()
        val store = RecordStore.open(this, SCOPE)
        val owner = BarometerBinding.newClient(this, store, trust())
        val client = owner.facade
        client.initialize(DeviceTestDocuments.linkedConfig(proxy))
        val task = DeviceTestDocuments.runTask("runner-active", "TCP-01", DeviceTestDocuments.TCP_INPUT, "proxy")
        val ref = client.installEmbeddedTask(DeviceTestDocuments.ISSUER, task.toByteArray())
        val run = client.startRun(client.admitTask(task, ref))
        while (proxy.connects.get() == 0) Thread.sleep(10)
        if (client.runState(run) == "active") progressFile(this).writeText("active")
        Thread.sleep(Long.MAX_VALUE)
    }

    companion object {
        const val SCOPE = "runner-test"

        fun trust(): ByteArray = DeviceTestDocuments.trustDocument(
            "TCP-01", DeviceTestDocuments.TCP_TUPLE,
            listOf(DeviceTestDocuments.CONNECTION_CODE), listOf(DeviceTestDocuments.LINKAGE_SCOPE),
        )

        fun progressFile(context: android.content.Context) = File(context.filesDir, "runner-progress")
    }
}
