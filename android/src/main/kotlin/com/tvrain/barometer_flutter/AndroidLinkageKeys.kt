package com.tvrain.barometer_flutter

import android.annotation.TargetApi
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.Closeable
import java.io.File
import java.io.FileOutputStream
import java.security.KeyStore
import java.util.concurrent.CancellationException
import java.util.concurrent.ExecutionException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.FutureTask
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey

/**
 * The Android backend of the facade's `LinkageKeyStore` port for one storage scope: an
 * HMAC-SHA-256 key in Android Keystore, created on first use, that never leaves it.
 *
 * The key is application-scoped and non-exportable; derivation runs inside Keystore. No
 * StrongBox or hardware backing is required, so on an emulator the key is software-backed.
 * Android Keystore holds HMAC keys from API 23, so [open] returns null before it and linkage
 * stays disabled.
 *
 * A reinstall sentinel, a small non-secret file in the scope's directory under
 * [android.content.Context.getNoBackupFilesDir], marks the key as belonging to the current
 * state. It is written before a key is created, and a key found without it, for example after
 * an interrupted deletion, is deleted before use and replaced only when a derivation needs one.
 * [delete] removes the key, then the sentinel, and creates nothing.
 *
 * Calls run on one serial worker thread, in arrival order, and the caller waits at most its
 * `timeoutMillis`. A call still queued at its deadline is withdrawn and never runs; a running
 * call finishes before any later one starts. Either way the caller gets an error, so a
 * derivation abandoned before a deletion cannot recreate the key after it. After [close]
 * nothing runs.
 */
@TargetApi(23)
internal class AndroidLinkageKeys private constructor(
    private val alias: String,
    private val sentinel: File,
) : Closeable {
    private val worker: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "barometer-linkage").apply { isDaemon = true }
    }
    private val state = Any()

    @Volatile
    private var closed = false

    /** Returns HMAC-SHA-256 of [message] under the scope's key, creating the key if needed. */
    fun deriveHmacSha256(message: ByteArray, timeoutMillis: Long): ByteArray {
        val copy = message.copyOf()
        return serial(timeoutMillis) {
            val keys = keyStore()
            if (!sentinel.exists()) {
                // A key without the sentinel is orphaned: it is never used.
                if (keys.containsAlias(alias)) keys.deleteEntry(alias)
                writeSentinel()
            }
            val key = keys.getKey(alias, null) as? SecretKey ?: generate()
            val mac = Mac.getInstance(MAC).apply { init(key) }.doFinal(copy)
            if (mac.size != MAC_BYTES) throw AdapterUnavailableException()
            mac
        }
    }

    /** Deletes the key and the sentinel; deleting absent ones succeeds. */
    fun delete(timeoutMillis: Long): Unit = serial(timeoutMillis) {
        val keys = keyStore()
        if (keys.containsAlias(alias)) keys.deleteEntry(alias)
        if (keys.containsAlias(alias)) throw AdapterUnavailableException()
        if (!sentinel.delete() && sentinel.exists()) throw AdapterUnavailableException()
    }

    /** Stops the worker; queued calls and every later call fail without taking effect. */
    override fun close() {
        synchronized(state) {
            closed = true
            worker.shutdown()
        }
    }

    private fun <T> serial(timeoutMillis: Long, op: () -> T): T {
        if (timeoutMillis < 1 || timeoutMillis > RecordStore.MAX_TIMEOUT_MILLIS) {
            throw AdapterUnavailableException()
        }
        val task = FutureTask {
            if (closed) throw AdapterUnavailableException()
            op()
        }
        synchronized(state) {
            if (closed) throw AdapterUnavailableException()
            try {
                worker.execute(task)
            } catch (e: RejectedExecutionException) {
                throw AdapterUnavailableException()
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
        throw AdapterUnavailableException()
    }

    private fun generate(): SecretKey {
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_HMAC_SHA256, PROVIDER)
        generator.init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN).build())
        return generator.generateKey()
    }

    /** Writes the sentinel through a temporary file and a rename, then syncs it. */
    private fun writeSentinel() {
        val dir = sentinel.parentFile ?: throw AdapterUnavailableException()
        if (!dir.isDirectory && !dir.mkdirs()) throw AdapterUnavailableException()
        val temp = File(dir, ".tmp-" + sentinel.name)
        try {
            FileOutputStream(temp).use { out ->
                out.write(SENTINEL_CONTENT)
                out.flush()
                out.fd.sync()
            }
            if (!temp.renameTo(sentinel)) throw AdapterUnavailableException()
        } catch (e: Exception) {
            temp.delete()
            throw AdapterUnavailableException()
        }
    }

    companion object {
        private const val PROVIDER = "AndroidKeyStore"
        private const val MAC = "HmacSHA256"
        private const val MAC_BYTES = 32
        private const val ALIAS_PREFIX = "barometer-linkage-"
        private const val SENTINEL = "linkage-sentinel"
        private val SENTINEL_CONTENT = "barometer-linkage-sentinel/1\n".toByteArray()

        /**
         * The key store of the scope whose directory is [scopeDir], or null before API 23,
         * where Android Keystore holds no HMAC key.
         */
        fun open(scopeDir: File): AndroidLinkageKeys? {
            if (Build.VERSION.SDK_INT < 23) return null
            return AndroidLinkageKeys(alias(scopeDir), File(scopeDir, SENTINEL))
        }

        /** The Keystore alias of the scope whose directory is [scopeDir]. */
        fun alias(scopeDir: File): String = ALIAS_PREFIX + scopeDir.name

        /** The sentinel file of the scope whose directory is [scopeDir]. */
        fun sentinel(scopeDir: File): File = File(scopeDir, SENTINEL)

        private fun keyStore(): KeyStore = KeyStore.getInstance(PROVIDER).apply { load(null) }
    }
}
