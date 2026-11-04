package com.tvrain.barometer_flutter

import android.app.ActivityManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import android.os.Process
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Instrumented tests of [RecordStore] and its facade adapter, with synthetic values only. */
@RunWith(AndroidJUnit4::class)
class RecordStoreDeviceTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val background = Executors.newCachedThreadPool()
    private val opened = mutableListOf<RecordStore>()

    private fun scopeDir(scope: String) = File(context.noBackupFilesDir, "barometer/$scope")

    @Before
    fun setUp() {
        scopeDir(SCOPE).deleteRecursively()
        scopeDir(WriterService.SCOPE).deleteRecursively()
    }

    @After
    fun tearDown() {
        background.shutdownNow()
        opened.forEach { runCatching { it.close() } }
    }

    private fun open(scope: String = SCOPE) = RecordStore.open(context, scope).also { opened.add(it) }

    private fun key(cls: Int, n: Int) = "$cls-" + "%064x".format(n)

    private fun assertFails(block: () -> Unit) {
        try {
            block()
            fail("expected an error")
        } catch (e: Exception) {
            // Any exception is the store's detail-free failure.
        }
    }

    private fun hold(s: RecordStore): CountDownLatch {
        val held = CountDownLatch(1)
        val release = CountDownLatch(1)
        background.submit { runCatching { s.serial(10_000) { held.countDown(); release.await() } } }
        assertTrue(held.await(5, TimeUnit.SECONDS))
        return release
    }

    @Test
    fun recordsLiveInTheNoBackupDirectory() {
        val s = open()
        s.put(key(1, 1), byteArrayOf(1), 1000)
        val file = File(scopeDir(SCOPE), "records/" + key(1, 1))
        assertTrue(file.isFile)
        assertTrue(file.canonicalPath.startsWith(context.noBackupFilesDir.canonicalPath + "/"))
        assertTrue(!file.canonicalPath.startsWith(context.filesDir.canonicalPath + "/"))
    }

    @Test
    fun writesAreAtomicUnderProcessKillAndSurviveRestart() {
        val progress = WriterService.progressFile(context)
        repeat(5) { round ->
            progress.delete()
            val connection = object : ServiceConnection {
                override fun onServiceConnected(name: ComponentName, service: IBinder) {}
                override fun onServiceDisconnected(name: ComponentName) {}
            }
            assertTrue(context.bindService(Intent(context, WriterService::class.java), connection, Context.BIND_AUTO_CREATE))
            val target = 3L + round * 7
            waitUntil("writer progress") { (progress.takeIf { it.exists() }?.readText()?.toLongOrNull() ?: 0) >= target }
            // The writer process owns the scope, so this process cannot open it.
            assertFails { RecordStore.open(context, WriterService.SCOPE) }
            val pid = writerPid()
            assertNotNull(pid)
            context.unbindService(connection)
            Process.killProcess(pid!!)
            waitUntil("writer exit") { writerPid() == null }

            val s = RecordStore.open(context, WriterService.SCOPE)
            try {
                assertArrayEquals(WriterService.FIXED_VALUE, s.get(WriterService.FIXED, 5000))
                val churn = s.get(WriterService.CHURN, 5000)!!
                assertEquals(WriterService.CHURN_SIZE, churn.size)
                val fill = churn[0]
                assertTrue(fill == 'A'.code.toByte() || fill == 'B'.code.toByte())
                assertTrue("a mixed value", churn.all { it == fill })
                val names = File(scopeDir(WriterService.SCOPE), "records").list()!!.toSet()
                assertEquals(setOf(WriterService.FIXED, WriterService.CHURN), names)
            } finally {
                s.close()
            }
        }
    }

    @Test
    fun oneOwnerPerScopeInProcess() {
        val s = open()
        assertFails { RecordStore.open(context, SCOPE) }
        s.close()
        open().close()
    }

    @Test
    fun deadlinesHoldAndAbandonedWritesStayBehindClearing() {
        val s = open()
        val release = hold(s)
        val start = System.nanoTime()
        assertFails { s.put(key(2, 1), byteArrayOf(1), 100) }
        val waited = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start)
        assertTrue("waited $waited ms", waited in 100..1500)
        val cleared = background.submit { s.delete(key(2, 1), 5000) }
        release.countDown()
        cleared.get()
        assertNull(s.get(key(2, 1), 1000))
    }

    @Test
    fun closeWithdrawsQueuedWrites() {
        val s = open()
        val release = hold(s)
        val queued = background.submit { s.put(key(1, 1), byteArrayOf(1), 10_000) }
        Thread.sleep(100)
        val closing = background.submit { s.close() }
        Thread.sleep(100)
        release.countDown()
        closing.get()
        assertFails { queued.get() }
        assertNull(open().get(key(1, 1), 1000))
    }

    @Test
    fun theUiThreadIsRefused() {
        val s = open()
        var failed = false
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            failed = runCatching { s.get(key(1, 1), 1000) }.isFailure &&
                runCatching { RecordStore.open(context, "ui-test") }.isFailure
        }
        assertTrue(failed)
    }

    @Test
    fun theFacadeAdapterStoresListsAndClearsEveryClass() {
        val s = open()
        val records = BarometerBinding.records(s)
        assertNull(records.get(key(1, 1), 1000))
        for (cls in 1..3) for (n in 1..3) records.put(key(cls, n), byteArrayOf(cls.toByte(), n.toByte()), 1000)
        assertNotNull(records.get(key(2, 2), 1000))
        assertArrayEquals(byteArrayOf(2, 2), s.get(key(2, 2), 1000))
        assertNotNull(records.list(3, 1000))
        assertFails { records.get("1-x", 1000) }
        assertFails { records.list(9, 1000) }

        // The facade's clearing sequence over the adapter.
        val marker = key(4, 1)
        records.put(marker, byteArrayOf(1, 4), 1000)
        assertFails { records.put(key(1, 9), byteArrayOf(1), 1000) }
        for (cls in 3 downTo 1) {
            s.list(cls.toLong(), 1000).forEach { records.delete(it, 1000) }
        }
        records.delete(marker, 1000)
        for (cls in 1..4) assertEquals(emptyList<String>(), s.list(cls.toLong(), 1000))
        assertEquals(0, File(scopeDir(SCOPE), "records").list()!!.size)
    }

    private fun writerPid(): Int? {
        // The class-typed getSystemService is API 23; this one also runs on API 21.
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        return am.runningAppProcesses?.firstOrNull { it.processName.endsWith(":writer") }?.pid
    }

    private fun waitUntil(what: String, condition: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(20)
        while (!condition()) {
            if (System.nanoTime() > deadline) fail("timed out waiting for $what")
            Thread.sleep(20)
        }
    }

    private companion object {
        const val SCOPE = "device-test"
    }
}
