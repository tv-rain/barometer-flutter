package com.tvrain.barometer_flutter

import android.content.Context
import android.os.Looper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Instrumented tests of the channel host against the facade, with the test package's trusted
 * local document and a synthetic expired task. They contact no network.
 */
@RunWith(AndroidJUnit4::class)
class ChannelDeviceTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private lateinit var host: BarometerHost

    private fun scopeDir() = File(context.noBackupFilesDir, "barometer/${RecordStore.DEFAULT_SCOPE}")

    @Before
    fun setUp() {
        scopeDir().deleteRecursively()
        host = BarometerHost(context)
    }

    @After
    fun tearDown() {
        call("close")
        host.detach()
        scopeDir().deleteRecursively()
    }

    /** The outcome of one call: a value or an error code, answered on the main looper. */
    private data class Outcome(val value: Any?, val code: String?)

    private fun call(method: String, arguments: Any? = null): Outcome {
        val latch = CountDownLatch(1)
        var outcome: Outcome? = null
        var onMain = false
        val handled = host.handle(method, arguments, object : BarometerHost.Reply {
            override fun success(value: Any?) {
                onMain = Looper.myLooper() == Looper.getMainLooper()
                outcome = Outcome(value, null)
                latch.countDown()
            }

            override fun error(code: String) {
                outcome = Outcome(null, code)
                latch.countDown()
            }
        })
        assertTrue(method, handled)
        assertTrue(method, latch.await(30, TimeUnit.SECONDS))
        // Validation errors are answered on the calling thread; facade answers on the main looper.
        val answered = outcome!!
        assertTrue("$method answered off the main looper", answered.code != null || onMain)
        return answered
    }

    private fun code(method: String, arguments: Any? = null) = call(method, arguments).code

    @Test
    fun nothingIsCreatedBeforeInitialize() {
        assertEquals("not_initialized", code("startRun", mapOf("task" to "T.x")))
        assertEquals("not_initialized", code("nextBundle"))
        assertEquals("not_initialized", code("clearMeasurementData"))
        assertFalse(File(scopeDir(), "records").exists())
        assertNull(code("close"))
    }

    @Test
    fun lifecycleRunsThroughTheChannel() {
        assertNull(code("initialize", mapOf("config" to "{}")))
        assertTrue(File(scopeDir(), "records").isDirectory)
        assertEquals("already_initialized", code("initialize", mapOf("config" to "{}")))
        assertNull(call("nextBundle").value)
        assertEquals("handle_unavailable", code("runState", mapOf("run" to "R.unknown")))
        assertEquals("handle_unavailable", code("startRun", mapOf("task" to "T.unknown")))
        assertEquals("bundle_unavailable", code("acknowledgeBundle", mapOf("id" to "unknown")))
        assertNull(code("clearMeasurementData"))
        assertNull(code("initialize", mapOf("config" to "{}")))
        assertNull(code("close"))
        assertNull(code("close"))
        assertEquals("not_initialized", code("nextBundle"))
        assertNull(code("initialize", mapOf("config" to "{}")))
    }

    @Test
    fun tasksAreInstalledNativelyAndAdmittedByGo() {
        assertNull(code("initialize", mapOf("config" to "{}")))
        val missing = mapOf("source" to "embedded", "name" to "missing")
        assertEquals("delivery_unavailable", code("admitTask", missing))
        // The expired task passes the delivery binding and provenance with the document's
        // embedded issuer, then fails a later admission step.
        val expired = code("admitTask", mapOf("source" to "embedded", "name" to "expired"))
        assertTrue(expired, expired != null && expired.startsWith("task_"))
        assertTrue(expired, expired != "task_source_unauthenticated")
        // An unsigned package is installed as a remote record and refused by verification.
        val remote = mapOf("source" to "remote", "package" to "{}".toByteArray())
        assertEquals("task_source_unauthenticated", code("admitTask", remote))
    }

    @Test
    fun trustInputsAreRefused() {
        assertEquals("invalid_arguments", code("initialize", mapOf("config" to "{}", "trust" to "{}")))
        assertEquals(
            "invalid_arguments",
            code("admitTask", mapOf("source" to "embedded", "name" to "expired", "issuer" to "x")),
        )
        assertEquals("invalid_arguments", code("admitTask", mapOf("source" to "embedded", "name" to "../trust")))
        assertFalse(host.handle("installPolicy", mapOf("policy" to "{}"), object : BarometerHost.Reply {
            override fun success(value: Any?) = throw AssertionError()
            override fun error(code: String) = throw AssertionError()
        }))
    }
}
