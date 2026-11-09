package com.tvrain.barometer_flutter

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertTrue

/** Makes channel calls on a [BarometerHost] and waits for their answers, as the Dart side does. */
internal class ChannelCaller(private val host: BarometerHost) {
    /** The outcome of one call: a value or an error code. */
    data class Outcome(val value: Any?, val code: String?)

    fun call(method: String, arguments: Any? = null): Outcome {
        val latch = CountDownLatch(1)
        var outcome: Outcome? = null
        val handled = host.handle(method, arguments, object : BarometerHost.Reply {
            override fun success(value: Any?) {
                outcome = Outcome(value, null)
                latch.countDown()
            }

            override fun error(code: String) {
                outcome = Outcome(null, code)
                latch.countDown()
            }
        })
        assertTrue(method, handled)
        assertTrue(method, latch.await(60, TimeUnit.SECONDS))
        return outcome!!
    }

    /** The error code of a call, or null when it succeeded. */
    fun code(method: String, arguments: Any? = null): String? = call(method, arguments).code

    /** The value of a call that must succeed. */
    fun value(method: String, arguments: Any? = null): Any? {
        val outcome = call(method, arguments)
        assertTrue("$method failed with ${outcome.code}", outcome.code == null)
        return outcome.value
    }

    fun initialize(config: String): String? = code("initialize", mapOf("config" to config))

    fun admitRemote(signedPackage: ByteArray): Outcome =
        call("admitTask", mapOf("source" to "remote", "package" to signedPackage))

    /** Waits until the run is terminal. */
    fun awaitTerminal(run: String) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(60)
        while ((value("runState", mapOf("run" to run)) as Map<*, *>)["state"] != "terminal") {
            assertTrue("run did not become terminal", System.nanoTime() < deadline)
            Thread.sleep(20)
        }
    }

    /** Reads and acknowledges the oldest pending bundle, or returns null when none is pending. */
    fun takeBundle(): org.json.JSONObject? {
        val bytes = value("nextBundle") as ByteArray? ?: return null
        val bundle = org.json.JSONObject(String(bytes))
        value("acknowledgeBundle", mapOf("id" to bundle.getString("bundle_id")))
        return bundle
    }
}
