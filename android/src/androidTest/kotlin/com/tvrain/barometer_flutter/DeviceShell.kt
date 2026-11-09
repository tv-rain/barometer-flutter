package com.tvrain.barometer_flutter

import android.os.ParcelFileDescriptor
import androidx.test.platform.app.InstrumentationRegistry

/**
 * Runs emulator shell commands as the shell user through the instrumentation, for tests that
 * change the emulator's connectivity or power state. Only emulators run these tests.
 */
internal object DeviceShell {
    /** Runs [command] and returns its standard output. */
    fun run(command: String): String {
        val fd = InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(command)
        return ParcelFileDescriptor.AutoCloseInputStream(fd).use { String(it.readBytes()) }
    }

    /** Polls [condition] every 100 ms for at most [seconds] seconds. */
    fun await(seconds: Long, condition: () -> Boolean): Boolean {
        val deadline = System.nanoTime() + seconds * 1_000_000_000L
        while (System.nanoTime() < deadline) {
            if (condition()) return true
            Thread.sleep(100)
        }
        return condition()
    }

    /**
     * Waits until the access network has kept one generation for [quietSeconds], at most
     * [seconds], so an attempt that must stay active is not ended by `network_changed` while an
     * earlier test's connectivity change settles.
     */
    fun awaitSettledNetwork(context: android.content.Context, quietSeconds: Long = 5, seconds: Long = 60) {
        AndroidNetwork(context.applicationContext).use { network ->
            val deadline = System.nanoTime() + seconds * 1_000_000_000L
            var last = network.access().generation
            var since = System.nanoTime()
            while (System.nanoTime() < deadline) {
                Thread.sleep(200)
                val now = network.access().generation
                if (now != last) {
                    last = now
                    since = System.nanoTime()
                } else if (System.nanoTime() - since >= quietSeconds * 1_000_000_000L) {
                    return
                }
            }
        }
    }
}
