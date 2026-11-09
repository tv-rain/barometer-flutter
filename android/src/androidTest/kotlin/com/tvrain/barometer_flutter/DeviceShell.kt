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
}
