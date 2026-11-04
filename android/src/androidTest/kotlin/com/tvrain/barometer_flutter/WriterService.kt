package com.tvrain.barometer_flutter

import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.IBinder
import java.io.File

/**
 * Test-only service in the `:writer` process. It owns the test scope, stores [FIXED] once and
 * then replaces [CHURN] with large values filled with one byte, alternating 'A' and 'B', until
 * its process is killed. Each completed write count goes to [progressFile].
 */
class WriterService : Service() {
    override fun onBind(intent: Intent): IBinder {
        Thread({ write() }, "writer").apply { isDaemon = true }.start()
        return Binder()
    }

    private fun write() {
        val store = RecordStore.open(this, SCOPE)
        store.put(FIXED, FIXED_VALUE, 5_000)
        var n = 0L
        while (true) {
            val fill = if (n % 2 == 0L) 'A'.code.toByte() else 'B'.code.toByte()
            store.put(CHURN, ByteArray(CHURN_SIZE) { fill }, 5_000)
            n++
            progressFile(this).writeText(n.toString())
        }
    }

    companion object {
        const val SCOPE = "writer-test"
        const val CHURN_SIZE = RecordStore.MAX_RECORD_VALUE
        val FIXED = "1-" + "ab".repeat(32)
        val CHURN = "3-" + "cd".repeat(32)
        val FIXED_VALUE = ByteArray(1024) { it.toByte() }

        fun progressFile(context: android.content.Context) = File(context.filesDir, "writer-progress")
    }
}
