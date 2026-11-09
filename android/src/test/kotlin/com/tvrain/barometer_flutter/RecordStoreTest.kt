package com.tvrain.barometer_flutter

import java.io.File
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

/** Host tests of [RecordStore] over a temporary directory, with synthetic keys and values. */
class RecordStoreTest {
    private lateinit var base: File
    private val opened = mutableListOf<RecordStore>()
    private val background = Executors.newCachedThreadPool()

    @Before
    fun setUp() {
        base = Files.createTempDirectory("records").toFile()
    }

    @After
    fun tearDown() {
        background.shutdownNow()
        opened.forEach { runCatching { it.close() } }
        base.deleteRecursively()
    }

    private fun open(scope: String = "test", ui: () -> Boolean = { false }): RecordStore =
        RecordStore.open(base, scope, ui).also { opened.add(it) }

    private fun key(cls: Int, n: Int) = "$cls-" + "%064x".format(n)

    private fun recordFiles() = File(base, "test/records").list()!!.toList()

    /** Occupies the worker of [s] until the returned latch is released. */
    private fun hold(s: RecordStore, timeoutMillis: Long = 10_000): CountDownLatch {
        val held = CountDownLatch(1)
        val release = CountDownLatch(1)
        background.submit { runCatching { s.serial(timeoutMillis) { held.countDown(); release.await() } } }
        assertTrue(held.await(5, TimeUnit.SECONDS))
        return release
    }

    private fun assertFails(block: () -> Unit) {
        try {
            block()
            fail("expected RecordStoreException")
        } catch (e: RecordStoreException) {
            assertEquals("record storage unavailable", e.message)
        }
    }

    @Test
    fun storesReplacesAndDeletes() {
        val s = open()
        val k = key(1, 1)
        assertNull(s.get(k, 1000))
        s.put(k, byteArrayOf(1, 2, 3), 1000)
        assertArrayEquals(byteArrayOf(1, 2, 3), s.get(k, 1000))
        s.put(k, byteArrayOf(9), 1000)
        assertArrayEquals(byteArrayOf(9), s.get(k, 1000))
        s.delete(k, 1000)
        assertNull(s.get(k, 1000))
        s.delete(k, 1000) // absent delete succeeds
        assertEquals(emptyList<String>(), recordFiles())
    }

    @Test
    fun aClearingMarkerTakesTheReserveAndReleasesItWhenDeleted() {
        val s = open()
        val reserve = File(base, "test/clearing.reserve")
        assertEquals(65_536L, reserve.length())
        assertTrue(reserve.readBytes().all { it == 0.toByte() })
        val marker = key(4, 1)
        s.put(marker, byteArrayOf(1), 1000)
        assertTrue(!reserve.exists())
        s.delete(marker, 1000)
        assertEquals(65_536L, reserve.length())
        // A store opened while a marker is stored keeps no reserve until the marker is gone.
        s.put(marker, byteArrayOf(1), 1000)
        s.close()
        opened.remove(s)
        val reopened = open()
        assertTrue(!reserve.exists())
        reopened.delete(marker, 1000)
        assertEquals(65_536L, reserve.length())
        assertEquals(emptyList<String>(), recordFiles())
    }

    @Test
    fun getReturnsACopyAndPutCopiesItsInput() {
        val s = open()
        val k = key(2, 1)
        val value = byteArrayOf(1, 2)
        s.put(k, value, 1000)
        value[0] = 7
        val got = s.get(k, 1000)!!
        got[1] = 7
        assertArrayEquals(byteArrayOf(1, 2), s.get(k, 1000))
    }

    @Test
    fun listsOnlyTheRequestedClass() {
        val s = open()
        for (cls in 1..4) for (n in 1..cls) s.put(key(cls, n), byteArrayOf(cls.toByte()), 1000)
        File(base, "test/records/stray").writeText("x")
        File(base, "test/records/1-" + "A".repeat(64)).writeText("x")
        for (cls in 1..4) {
            assertEquals((1..cls).map { key(cls, it) }.toSet(), s.list(cls.toLong(), 1000).toSet())
        }
    }

    @Test
    fun rejectsInvalidInput() {
        val s = open()
        for (bad in listOf("", "0-" + "0".repeat(64), "5-" + "0".repeat(64), "1-" + "0".repeat(63),
            "1-" + "A".repeat(64), "1_" + "0".repeat(64), "1-../" + "0".repeat(61), "11-" + "0".repeat(63))) {
            assertFails { s.get(bad, 1000) }
            assertFails { s.put(bad, byteArrayOf(), 1000) }
            assertFails { s.delete(bad, 1000) }
        }
        assertFails { s.list(0, 1000) }
        assertFails { s.list(5, 1000) }
        assertFails { s.put(key(3, 1), ByteArray(RecordStore.MAX_RECORD_VALUE + 1), 1000) }
        s.put(key(3, 1), ByteArray(RecordStore.MAX_RECORD_VALUE), 1000)
        for (t in listOf(0L, -1L, RecordStore.MAX_TIMEOUT_MILLIS + 1)) assertFails { s.get(key(1, 1), t) }
        for (scope in listOf("", "A", "../x", "a/b", "x".repeat(65))) {
            assertFails { RecordStore.open(base, scope) { false } }
        }
    }

    @Test
    fun anOversizedStoredValueIsUnavailable() {
        val s = open()
        File(base, "test/records/" + key(3, 1)).writeBytes(ByteArray(RecordStore.MAX_RECORD_VALUE + 1))
        assertFails { s.get(key(3, 1), 1000) }
    }

    @Test
    fun survivesReopenAndRemovesInterruptedWrites() {
        open().apply {
            put(key(1, 1), byteArrayOf(5), 1000)
            close()
        }
        // A write a process kill interrupted before its rename.
        File(base, "test/records/.tmp-" + key(1, 1)).writeBytes(byteArrayOf(6, 6))
        val s = open()
        assertArrayEquals(byteArrayOf(5), s.get(key(1, 1), 1000))
        assertEquals(listOf(key(1, 1)), recordFiles())
    }

    @Test
    fun oneOwnerPerScope() {
        val s = open()
        assertFails { open() }
        open("other").close()
        s.close()
        s.close() // repeated close succeeds
        open().put(key(1, 1), byteArrayOf(1), 1000)
    }

    @Test
    fun refusesTheUiThread() {
        assertFails { open(ui = { true }) }
        var ui = false
        val s = open { ui }
        ui = true
        assertFails { s.get(key(1, 1), 1000) }
        assertFails { s.put(key(1, 1), byteArrayOf(1), 1000) }
        assertFails { s.close() }
        ui = false
        assertNull(s.get(key(1, 1), 1000))
    }

    @Test
    fun aCallPastItsDeadlineFailsWithinIt() {
        val s = open()
        val hold = hold(s)
        val start = System.nanoTime()
        assertFails { s.get(key(1, 1), 100) }
        val waited = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start)
        assertTrue("waited $waited ms", waited in 100..1000)
        hold.countDown()
        assertNull(s.get(key(1, 1), 1000))
    }

    @Test
    fun aQueuedWriteAbandonedAtItsDeadlineNeverLands() {
        val s = open()
        val hold = hold(s)
        assertFails { s.put(key(1, 1), byteArrayOf(1), 50) }
        val cleared = background.submit { s.delete(key(1, 1), 5000) }
        hold.countDown()
        cleared.get()
        assertNull(s.get(key(1, 1), 1000))
        assertEquals(emptyList<String>(), s.list(1, 1000))
    }

    @Test
    fun aRunningWriteAbandonedAtItsDeadlineLandsBeforeALaterClear() {
        val s = open()
        val started = CountDownLatch(1)
        val hold = CountDownLatch(1)
        val k = key(2, 1)
        // A write that starts, stalls past its caller's deadline and then lands.
        val write = background.submit {
            s.serial(200) {
                started.countDown()
                hold.await()
                File(base, "test/records/$k").writeBytes(byteArrayOf(1))
            }
        }
        started.await()
        val delete = background.submit { s.delete(k, 5000) }
        Thread.sleep(300)
        hold.countDown()
        try {
            write.get()
            fail("an abandoned call must report an error")
        } catch (e: java.util.concurrent.ExecutionException) {
            assertTrue(e.cause is RecordStoreException)
        }
        delete.get()
        assertNull(s.get(k, 1000))
    }

    @Test
    fun closeWithdrawsQueuedCallsAndRejectsLaterOnes() {
        val s = open()
        val hold = hold(s)
        val queued = background.submit { s.put(key(1, 1), byteArrayOf(1), 10_000) }
        Thread.sleep(50)
        val closing = background.submit { s.close() }
        Thread.sleep(50)
        hold.countDown()
        closing.get()
        try {
            queued.get()
            fail("a call queued behind close must fail")
        } catch (e: java.util.concurrent.ExecutionException) {
            assertTrue(e.cause is RecordStoreException)
        }
        assertFails { s.get(key(1, 1), 1000) }
        assertNull(open().get(key(1, 1), 1000))
    }

    @Test
    fun aStalledCallKeepsTheScopeOwnedAfterClose() {
        val s = open()
        val hold = hold(s, 30_000)
        assertFails { s.close() } // the close bound is 5 s
        assertFails { open() }
        hold.countDown()
        s.close()
        open().close()
    }

    @Test
    fun aClearingMarkerBlocksOtherWrites() {
        val s = open()
        val marker = key(4, 1)
        s.put(key(1, 1), byteArrayOf(1), 1000)
        s.put(marker, byteArrayOf(1, 4), 1000)
        for (cls in 1..3) assertFails { s.put(key(cls, 2), byteArrayOf(1), 1000) }
        s.put(key(4, 2), byteArrayOf(1), 1000)
        s.delete(key(1, 1), 1000)
        s.delete(key(4, 2), 1000)
        assertFails { s.put(key(1, 1), byteArrayOf(1), 1000) }
        s.delete(marker, 1000)
        s.put(key(1, 1), byteArrayOf(1), 1000)
        s.close()
        // A marker left by an interrupted clear still blocks after reopening.
        File(base, "test/records/" + marker).writeBytes(byteArrayOf(9))
        assertFails { open().put(key(2, 1), byteArrayOf(1), 1000) }
    }

    @Test
    fun clearingRemovesEveryClass() {
        val s = open()
        for (cls in 1..3) for (n in 1..3) s.put(key(cls, n), byteArrayOf(cls.toByte()), 1000)
        // The facade's clearing sequence: marker, classes newest first, confirm, marker last.
        val marker = key(4, 1)
        s.put(marker, byteArrayOf(1, 4), 1000)
        for (cls in 3 downTo 1) {
            s.list(cls.toLong(), 1000).forEach { s.delete(it, 1000) }
            assertEquals(emptyList<String>(), s.list(cls.toLong(), 1000))
        }
        s.delete(marker, 1000)
        for (cls in 1..4) assertEquals(emptyList<String>(), s.list(cls.toLong(), 1000))
        assertEquals(emptyList<String>(), recordFiles())
    }
}
