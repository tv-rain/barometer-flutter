package com.tvrain.barometer_flutter

import android.app.ActivityManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Build
import android.os.IBinder
import android.os.Looper
import android.os.Process
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.security.KeyStore
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The end of the plugin's lifecycle: an engine detach closes the client and releases the scope,
 * and a process killed during an attempt leaves a scope that the next process opens,
 * initializes and clears. The attempt waits on a loopback proxy that never answers; nothing
 * contacts the network.
 */
@RunWith(AndroidJUnit4::class)
class LifecycleDeviceTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext

    private fun scopeDir(scope: String) = File(context.noBackupFilesDir, "barometer/$scope")

    @Before
    fun setUp() {
        scopeDir(RecordStore.DEFAULT_SCOPE).deleteRecursively()
        scopeDir(RunnerService.SCOPE).deleteRecursively()
        RunnerService.progressFile(context).delete()
    }

    @After
    fun tearDown() {
        runnerPid()?.let { Process.killProcess(it) }
        scopeDir(RecordStore.DEFAULT_SCOPE).deleteRecursively()
        scopeDir(RunnerService.SCOPE).deleteRecursively()
        RunnerService.progressFile(context).delete()
        if (Build.VERSION.SDK_INT >= 23) {
            KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
                .deleteEntry(AndroidLinkageKeys.alias(scopeDir(RunnerService.SCOPE)))
        }
    }

    @Test
    fun detachClosesTheClientAndReleasesTheScope() {
        val host = BarometerHost(context)
        val latch = CountDownLatch(1)
        var failure: String? = "unanswered"
        host.handle("initialize", mapOf("config" to "{}"), object : BarometerHost.Reply {
            override fun success(value: Any?) {
                failure = null
                latch.countDown()
            }

            override fun error(code: String) {
                failure = code
                latch.countDown()
            }
        })
        assertTrue(latch.await(30, TimeUnit.SECONDS))
        assertNull(failure)
        // The host's client owns the default scope.
        assertFails { RecordStore.open(context, RecordStore.DEFAULT_SCOPE) }

        host.detach()
        val store = awaitOpen(RecordStore.DEFAULT_SCOPE)
        store.close()
        val closed = CountDownLatch(1)
        var closedWith: String? = null
        val handled = host.handle("nextBundle", null, object : BarometerHost.Reply {
            override fun success(value: Any?) = closed.countDown()
            override fun error(code: String) {
                closedWith = code
                closed.countDown()
            }
        })
        assertTrue(handled)
        assertTrue(closed.await(5, TimeUnit.SECONDS))
        assertEquals("client_closed", closedWith)
    }

    @Test
    fun aProcessKilledDuringAnAttemptLeavesAUsableScope() {
        val progress = RunnerService.progressFile(context)
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, service: IBinder) {}
            override fun onServiceDisconnected(name: ComponentName) {}
        }
        assertTrue(context.bindService(Intent(context, RunnerService::class.java), connection, Context.BIND_AUTO_CREATE))
        assertTrue("no active attempt", DeviceShell.await(30) { progress.exists() && progress.readText() == "active" })
        assertFails { RecordStore.open(context, RunnerService.SCOPE) }
        val pid = runnerPid()!!
        context.unbindService(connection)
        Process.killProcess(pid)
        assertTrue("runner did not exit", DeviceShell.await(20) { runnerPid() == null })

        val store = awaitOpen(RunnerService.SCOPE)
        val owner = BarometerBinding.newClient(context, store, RunnerService.trust())
        try {
            val client = owner.facade
            client.initialize(DeviceTestDocuments.linkedConfig())
            // The killed attempt left no running state; any bundle it left is well formed.
            val raw = client.nextBundle()
            if (raw.isNotEmpty()) JSONObject(raw).getJSONArray("results")
            client.clearMeasurementData()
            assertEquals(emptyList<String>(), File(scopeDir(RunnerService.SCOPE), "records").list()!!.toList())
            assertFalse(AndroidLinkageKeys.sentinel(scopeDir(RunnerService.SCOPE)).exists())
            client.initialize("{}")
            assertEquals("", client.nextBundle())
        } finally {
            owner.close()
            store.close()
        }
    }

    /** Opens [scope] off the main thread, waiting up to the lifecycle deadline for its owner. */
    private fun awaitOpen(scope: String): RecordStore {
        assertFalse(Looper.myLooper() == Looper.getMainLooper())
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
        while (true) {
            try {
                return RecordStore.open(context, scope)
            } catch (e: RecordStoreException) {
                if (System.nanoTime() > deadline) fail("scope $scope was not released")
                Thread.sleep(50)
            }
        }
    }

    private fun assertFails(op: () -> Unit) {
        try {
            op()
        } catch (e: Exception) {
            return
        }
        fail("expected a failure")
    }

    private fun runnerPid(): Int? {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        return am.runningAppProcesses?.firstOrNull { it.processName.endsWith(":runner") }?.pid
    }
}
