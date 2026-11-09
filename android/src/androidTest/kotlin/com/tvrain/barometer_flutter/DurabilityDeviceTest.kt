package com.tvrain.barometer_flutter

import android.app.ActivityManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Build
import android.os.IBinder
import android.os.Process
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.security.KeyStore
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Durability across a process kill: [DurabilityService] leaves a pending bundle, replay records
 * and run-ledger entries in its scope and is killed while an attempt is active. The next
 * process opens the scope and finds the same oldest pending bundle, byte for byte, both
 * completed tasks not due again, and a task that reuses a stored identifier with other content
 * still rejected, as the killed process found it; clearing then removes everything. Nothing contacts the network: every attempt runs on the proxy path through a
 * loopback proxy in the test application. No result is printed.
 */
@RunWith(AndroidJUnit4::class)
class DurabilityDeviceTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val scopeDir = File(context.noBackupFilesDir, "barometer/${DurabilityService.SCOPE}")
    private val closeables = mutableListOf<AutoCloseable>()

    @Before
    fun setUp() = cleanUp()

    @After
    fun tearDown() {
        closeables.asReversed().forEach { runCatching { it.close() } }
        cleanUp()
    }

    private fun cleanUp() {
        servicePid()?.let { Process.killProcess(it) }
        scopeDir.deleteRecursively()
        DurabilityService.stateFile(context).delete()
        if (Build.VERSION.SDK_INT >= 23) {
            KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(AndroidLinkageKeys.alias(scopeDir))
        }
    }

    @Test
    fun stateSurvivesAProcessKillDuringARun() {
        val stateFile = DurabilityService.stateFile(context)
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, service: IBinder) {}
            override fun onServiceDisconnected(name: ComponentName) {}
        }
        assertTrue(context.bindService(Intent(context, DurabilityService::class.java), connection, Context.BIND_AUTO_CREATE))
        assertTrue("no active attempt", DeviceShell.await(60) { stateFile.exists() })
        val before = JSONObject(stateFile.readText())
        assertEquals("task_id_conflict", before.getString("conflict"))
        val pid = servicePid()!!
        context.unbindService(connection)
        Process.killProcess(pid)
        assertTrue("service did not exit", DeviceShell.await(20) { servicePid() == null })

        val store = awaitOpen()
        closeables.add(store)
        val owner = BarometerBinding.newClient(context, store, before.getString("trust").toByteArray())
        closeables.add(owner)
        val client = owner.facade
        val proxy = AnsweringProxy().also { closeables.add(it) }
        client.initialize(DurabilityService.config(proxy.config()))

        assertEquals(before.getString("bundle_sha256"), DurabilityService.sha256(client.nextBundle()))
        // Both tasks are admitted again as exact redeliveries, and the run ledger keeps their
        // completed runs: neither the one-time task nor the repeating one is due. Without the
        // stored entries a new client would start both.
        for (task in listOf("once", "repeating")) {
            assertEquals(task, "run_not_due", DurabilityService.code {
                client.startRun(DurabilityService.admit(client, before.getString(task)))
            })
        }
        assertEquals("task_id_conflict", DurabilityService.code {
            DurabilityService.admit(client, DurabilityService.conflicting(before.getString("once")))
        })

        client.clearMeasurementData()
        assertEquals(emptyList<String>(), File(scopeDir, "records").list()!!.toList())
        assertFalse(AndroidLinkageKeys.sentinel(scopeDir).exists())
        client.initialize("{}")
        assertEquals("", client.nextBundle())
    }

    /** Opens the scope off the main thread, waiting up to the lifecycle deadline for its owner. */
    private fun awaitOpen(): RecordStore {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
        while (true) {
            try {
                return RecordStore.open(context, DurabilityService.SCOPE)
            } catch (e: RecordStoreException) {
                if (System.nanoTime() > deadline) fail("the scope was not released")
                Thread.sleep(50)
            }
        }
    }

    private fun servicePid(): Int? {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        return am.runningAppProcesses?.firstOrNull { it.processName.endsWith(":durability") }?.pid
    }
}
