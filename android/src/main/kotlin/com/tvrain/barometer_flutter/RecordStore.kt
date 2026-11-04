package com.tvrain.barometer_flutter

import android.content.Context
import android.os.Looper
import java.io.Closeable
import java.io.File
import java.io.FileInputStream
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.channels.FileChannel
import java.nio.channels.FileLock
import java.util.concurrent.CancellationException
import java.util.concurrent.ExecutionException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.FutureTask
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/**
 * Reported for every record-store failure. It carries no detail: the facade maps any native
 * error to "unavailable", and no record key, value or path leaves the store in an error.
 */
internal class RecordStoreException : Exception("record storage unavailable")

/**
 * The Android backend of the facade's `Records` port for one storage scope.
 *
 * Records are files in an application-private directory under [Context.getNoBackupFilesDir],
 * which Android excludes from cloud backup and device-to-device transfer; nothing here
 * synchronizes, reads the clock or works in the background. One file holds one record and is
 * named by its key, `"<class>-<64 lowercase hex digits>"`. A put writes a temporary file and
 * renames it over the record, so after a process kill either the earlier value or the new one
 * is stored, never a mixture. Durability across power loss and a full disk is not claimed.
 *
 * Every call runs on one serial worker thread, in arrival order, and the caller waits at most
 * its `timeoutMillis`. A call still queued at its deadline is withdrawn and never runs; a call
 * already running finishes before any later call starts. Either way the caller gets an error,
 * so an uncertain outcome is never reported as success, and an abandoned write cannot land
 * after a later delete (clearing) or [close]. The facade hands calls over in the order Go
 * issues them, so arrival order is issue order. While a clearing marker (class 4) is stored,
 * puts of the other classes are refused.
 *
 * A storage scope has one owner at a time, across threads and processes: a second [open] of a
 * scope that is open fails. Calls, [open] and [close] must not be made on the UI thread; they
 * fail there instead of blocking it.
 */
internal class RecordStore private constructor(
    private val records: File,
    private val ownerKey: String,
    private val lockChannel: FileChannel,
    private val lock: FileLock,
    private val isUiThread: () -> Boolean,
) : Closeable {
    private val worker: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "barometer-records").apply { isDaemon = true }
    }
    private val state = Any()

    @Volatile
    private var closed = false

    /** Clearing-class keys stored, read only on the worker thread. */
    private val markers = HashSet<String>()

    /** Returns a copy of the value stored for [key], or null when none is stored. */
    fun get(key: String, timeoutMillis: Long): ByteArray? {
        checkKey(key)
        return serial(timeoutMillis) { read(File(records, key)) }
    }

    /** Atomically stores [value] for [key], replacing any earlier value. */
    fun put(key: String, value: ByteArray, timeoutMillis: Long) {
        val cls = checkKey(key)
        if (value.size > MAX_RECORD_VALUE) throw RecordStoreException()
        val copy = value.copyOf()
        serial(timeoutMillis) {
            if (cls != CLEARING_CLASS && markers.isNotEmpty()) throw RecordStoreException()
            try {
                write(key, copy)
            } finally {
                if (cls == CLEARING_CLASS) refreshMarker(key)
            }
        }
    }

    /** Atomically removes [key]; removing an absent key succeeds. */
    fun delete(key: String, timeoutMillis: Long) {
        val cls = checkKey(key)
        serial(timeoutMillis) {
            try {
                val file = File(records, key)
                if (!file.delete() && file.exists()) throw RecordStoreException()
            } finally {
                if (cls == CLEARING_CLASS) refreshMarker(key)
            }
        }
    }

    /** Returns every stored key of [cls], in any order, including unreadable records. */
    fun list(cls: Long, timeoutMillis: Long): List<String> {
        if (cls < 1 || cls > CLEARING_CLASS) throw RecordStoreException()
        return serial(timeoutMillis) { keys(cls) }
    }

    /**
     * Closes the store and releases the scope. Calls queued behind the running one fail without
     * taking effect, and so does every later call. If the running call does not finish within
     * the close bound, the scope stays owned and this throws, so no other owner can start while
     * that call may still land. Repeated close succeeds once the scope is released.
     */
    override fun close() {
        if (isUiThread()) throw RecordStoreException()
        synchronized(state) {
            closed = true
            worker.shutdown()
        }
        val finished = try {
            worker.awaitTermination(CLOSE_BOUND_MILLIS, TimeUnit.MILLISECONDS)
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
        if (!finished) throw RecordStoreException()
        release()
    }

    /**
     * Runs [op] on the worker thread after every earlier call and waits at most [timeoutMillis].
     * Internal so tests can hold the worker.
     */
    internal fun <T> serial(timeoutMillis: Long, op: () -> T): T {
        if (timeoutMillis < 1 || timeoutMillis > MAX_TIMEOUT_MILLIS || isUiThread()) {
            throw RecordStoreException()
        }
        val task = FutureTask {
            if (closed) throw RecordStoreException()
            op()
        }
        synchronized(state) {
            if (closed) throw RecordStoreException()
            try {
                worker.execute(task)
            } catch (e: RejectedExecutionException) {
                throw RecordStoreException()
            }
        }
        try {
            return task.get(timeoutMillis, TimeUnit.MILLISECONDS)
        } catch (e: TimeoutException) {
            task.cancel(false)
        } catch (e: InterruptedException) {
            task.cancel(false)
            Thread.currentThread().interrupt()
        } catch (e: ExecutionException) {
            // The call failed; its outcome is uncertain.
        } catch (e: CancellationException) {
            // Not reached: only this method cancels the task.
        }
        throw RecordStoreException()
    }

    private fun read(file: File): ByteArray? {
        val stream = try {
            FileInputStream(file)
        } catch (e: FileNotFoundException) {
            if (!file.exists() && records.isDirectory) return null
            throw RecordStoreException()
        }
        return stream.use { input ->
            val size = input.channel.size()
            if (size > MAX_RECORD_VALUE) throw RecordStoreException()
            val out = ByteArray(size.toInt())
            var n = 0
            while (n < out.size) {
                val r = input.read(out, n, out.size - n)
                if (r < 0) throw RecordStoreException()
                n += r
            }
            if (input.read() >= 0) throw RecordStoreException()
            out
        }
    }

    private fun write(key: String, value: ByteArray) {
        val temp = File(records, TEMP_PREFIX + key)
        try {
            FileOutputStream(temp).use { out ->
                out.write(value)
                out.flush()
                out.fd.sync()
            }
            if (!temp.renameTo(File(records, key))) throw RecordStoreException()
        } catch (e: Exception) {
            temp.delete()
            throw RecordStoreException()
        }
    }

    private fun refreshMarker(key: String) {
        if (File(records, key).exists()) markers.add(key) else markers.remove(key)
    }

    private fun keys(cls: Long): List<String> {
        val names = records.list() ?: throw RecordStoreException()
        val prefix = "$cls-"
        return names.filter { it.startsWith(prefix) && isKey(it) }
    }

    private fun release() {
        synchronized(owners) {
            if (!owners.contains(ownerKey)) return
            try {
                lock.release()
            } catch (e: Exception) {
                // Closing the channel below releases the lock as well.
            }
            try {
                lockChannel.close()
            } catch (e: Exception) {
                // The process ending releases it.
            }
            owners.remove(ownerKey)
        }
    }

    private fun initialize() {
        val names = records.list() ?: throw RecordStoreException()
        for (name in names) {
            // A temporary file is a write a process kill interrupted before its rename.
            if (name.startsWith(TEMP_PREFIX) && !File(records, name).delete()) {
                throw RecordStoreException()
            }
        }
        markers.addAll(keys(CLEARING_CLASS))
    }

    companion object {
        /** `persistence.MaxRecordValue`: one encoded Result Bundle plus the store header. */
        const val MAX_RECORD_VALUE = 262144 + 64

        /** The facade's largest callback deadline. */
        const val MAX_TIMEOUT_MILLIS = 30_000L

        /** The storage scope the plugin uses. */
        const val DEFAULT_SCOPE = "default"

        private const val CLEARING_CLASS = 4L
        private const val CLOSE_BOUND_MILLIS = 5_000L
        private const val TEMP_PREFIX = ".tmp-"
        private val SCOPE = Regex("[a-z0-9][a-z0-9_-]{0,63}")

        /** Canonical scope directories open in this process. */
        private val owners = HashSet<String>()

        /** Opens [scope] in the application's no-backup directory. */
        fun open(context: Context, scope: String = DEFAULT_SCOPE): RecordStore =
            open(File(context.noBackupFilesDir, "barometer"), scope) {
                Looper.myLooper() == Looper.getMainLooper()
            }

        /** Opens [scope] under [base]. Tests pass a temporary directory. */
        internal fun open(base: File, scope: String, isUiThread: () -> Boolean): RecordStore {
            if (isUiThread() || !SCOPE.matches(scope)) throw RecordStoreException()
            val dir = File(base, scope)
            val records = File(dir, "records")
            if (!records.isDirectory && !records.mkdirs()) throw RecordStoreException()
            val ownerKey = try {
                dir.canonicalPath
            } catch (e: Exception) {
                throw RecordStoreException()
            }
            synchronized(owners) {
                if (owners.contains(ownerKey)) throw RecordStoreException()
                var channel: FileChannel? = null
                try {
                    channel = RandomAccessFile(File(dir, "owner.lock"), "rw").channel
                    // Null while another process owns the scope.
                    val lock = channel.tryLock() ?: throw RecordStoreException()
                    val store = RecordStore(records, ownerKey, channel, lock, isUiThread)
                    owners.add(ownerKey)
                    try {
                        store.initialize()
                    } catch (e: Exception) {
                        store.worker.shutdown()
                        store.release()
                        throw e
                    }
                    return store
                } catch (e: Exception) {
                    if (!owners.contains(ownerKey)) channel?.close()
                    throw RecordStoreException()
                }
            }
        }

        private fun isKey(name: String): Boolean {
            if (name.length != 66 || name[1] != '-' || name[0] !in '1'..'4') return false
            for (i in 2 until name.length) {
                val c = name[i]
                if (c !in '0'..'9' && c !in 'a'..'f') return false
            }
            return true
        }

        /** Returns the class of [key] or throws when it is not a record key. */
        private fun checkKey(key: String): Long {
            if (!isKey(key)) throw RecordStoreException()
            return (key[0] - '0').toLong()
        }
    }
}
