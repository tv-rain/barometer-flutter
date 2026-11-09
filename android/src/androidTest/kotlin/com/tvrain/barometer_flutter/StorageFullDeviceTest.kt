package com.tvrain.barometer_flutter

import android.content.Context
import android.os.Build
import android.os.StatFs
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.security.KeyStore
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * A full data partition: with records, a pending bundle and the linkage key stored, the test
 * fills the emulator's data partition with a filler file until a write fails with `ENOSPC`.
 * Barometer writes then fail closed: a new task is not admitted, an admitted one starts no
 * run, the stored records and the pending bundle are unchanged and no temporary file is left
 * behind. Clearing still deletes every record, the
 * Keystore key and the sentinel while the partition is full. The filler is removed afterwards.
 * Nothing contacts the network: attempts run on the proxy path through a loopback proxy in the
 * test application. No result is printed.
 */
@RunWith(AndroidJUnit4::class)
class StorageFullDeviceTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val scopeDir = File(context.noBackupFilesDir, "barometer/$SCOPE")
    private val filler = File(context.filesDir, "storage-full-filler")
    private val closeables = mutableListOf<AutoCloseable>()

    private fun records(): List<String> = File(scopeDir, "records").list()!!.sorted()

    private fun keyExists(): Boolean = Build.VERSION.SDK_INT >= 23 &&
        KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.containsAlias(AndroidLinkageKeys.alias(scopeDir))

    @Before
    fun setUp() = cleanUp()

    @After
    fun tearDown() {
        filler.delete()
        closeables.asReversed().forEach { runCatching { it.close() } }
        cleanUp()
    }

    private fun cleanUp() {
        filler.delete()
        scopeDir.deleteRecursively()
        if (Build.VERSION.SDK_INT >= 23) {
            KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(AndroidLinkageKeys.alias(scopeDir))
        }
    }

    @Test
    fun writesFailClosedAndClearingSucceedsOnAFullPartition() {
        val proxy = AnsweringProxy().also { closeables.add(it) }
        val store = RecordStore.open(context, SCOPE).also { closeables.add(it) }
        val owner = BarometerBinding.newClient(context, store, DurabilityService.trust()).also { closeables.add(it) }
        val client = owner.facade
        client.initialize(DurabilityService.config(proxy.config()))
        val task = DeviceTestDocuments.runTask("storage-full-pending", "TCP-01", DeviceTestDocuments.TCP_INPUT, "proxy")
        DurabilityService.awaitTerminal(client, client.startRun(DurabilityService.admit(client, task)))
        val bundle = client.nextBundle()
        assertNotEquals("", bundle)
        val admitted = DurabilityService.admit(
            client, DeviceTestDocuments.runTask("storage-full-admitted", "TCP-01", DeviceTestDocuments.TCP_INPUT, "proxy"),
        )
        val stored = records()
        assertTrue(stored.isNotEmpty())
        assertEquals(Build.VERSION.SDK_INT >= 23, keyExists())

        fill()
        assertEquals("the partition is not full", 0L, StatFs(filler.parent).availableBytes)

        // A new task's replay record cannot be stored, so it is not admitted; a task admitted
        // before the partition filled cannot reserve a run in the ledger, so none starts.
        val next = DeviceTestDocuments.runTask("storage-full-new", "TCP-01", DeviceTestDocuments.TCP_INPUT, "proxy")
        assertEquals("task_trust_unavailable", DurabilityService.code { DurabilityService.admit(client, next) })
        assertEquals("run_not_due", DurabilityService.code { client.startRun(admitted) })
        assertEquals(stored, records())
        assertEquals(bundle, client.nextBundle())

        assertEquals("the partition was freed during the test", 0L, StatFs(filler.parent).availableBytes)
        val started = System.nanoTime()
        client.clearMeasurementData()
        assertTrue(TimeUnit.NANOSECONDS.toSeconds(System.nanoTime() - started) < 10)
        assertEquals(emptyList<String>(), records())
        assertFalse(keyExists())
        assertFalse(AndroidLinkageKeys.sentinel(scopeDir).exists())

        assertTrue(filler.delete())
        client.initialize("{}")
        assertEquals("", client.nextBundle())
    }

    /**
     * Allocates the free space of the data partition to [filler] without writing it, in ever
     * smaller extents until not even one block can be allocated, then appends single bytes to
     * the last block until a write fails with `ENOSPC`. Only the final block is written, so
     * filling the emulator's partition does not write gigabytes to the host disk.
     */
    private fun fill() {
        FileOutputStream(filler).use { out ->
            var offset = 0L
            var chunk = 1L shl 30
            while (chunk >= BLOCK) {
                try {
                    Os.posix_fallocate(out.fd, offset, chunk)
                    offset += chunk
                } catch (e: ErrnoException) {
                    if (e.errno != OsConstants.ENOSPC) throw e
                    chunk /= 2
                }
            }
        }
        val single = ByteArray(1)
        try {
            FileOutputStream(filler, true).use { out ->
                repeat(2 * BLOCK.toInt()) {
                    out.write(single)
                    out.fd.sync()
                }
            }
        } catch (e: IOException) {
            // ENOSPC: not even one more byte fits.
        }
    }

    companion object {
        private const val SCOPE = "storage-full-device-test"

        /** The smallest allocation tried: one ext4 block. */
        private const val BLOCK = 4096L
    }
}
