package com.tvrain.barometer_flutter

import android.content.Context
import android.os.Handler
import android.os.Looper
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/**
 * Owns the native client of one Flutter engine and runs the channel calls against it.
 *
 * Nothing happens at construction: the worker threads start with the first call, and the
 * record store and facade client are created by `initialize`, which reads the trusted local
 * document from the application package. `close` closes the client, then the store. Every
 * facade call runs on a worker thread, never on the UI thread, and its answer is posted back
 * to the main looper.
 *
 * A failed `initialize` keeps the client it created, so the host can retry it or recover with
 * `clearMeasurementData` after `clearing_incomplete`. A `close` that fails keeps the client
 * too, so it can be retried.
 */
internal class BarometerHost(private val context: Context) {
    /** A call's outcome, delivered on the main looper. */
    interface Reply {
        fun success(value: Any?)
        fun error(code: String)
    }

    private val lock = Any()
    private val main = Handler(Looper.getMainLooper())
    private var workers: ThreadPoolExecutor? = null
    private var detached = false
    private var store: RecordStore? = null
    private var client: BarometerClient? = null
    private var embeddedIssuer: String? = null

    /** Parses and dispatches one channel call; returns false for an unknown method. */
    fun handle(method: String, arguments: Any?, reply: Reply): Boolean {
        val call = try {
            ChannelContract.parse(method, arguments) ?: return false
        } catch (e: InvalidArgumentsException) {
            reply.error(ChannelContract.INVALID_ARGUMENTS)
            return true
        }
        val pool = workers() ?: run {
            reply.error(ERR_CLOSED)
            return true
        }
        try {
            pool.execute {
                val outcome = try {
                    Result.success(perform(call))
                } catch (e: Throwable) {
                    Result.failure(e)
                }
                main.post {
                    outcome.fold(reply::success) { reply.error(code(it)) }
                }
            }
        } catch (e: RejectedExecutionException) {
            reply.error(ERR_CLOSED)
        }
        return true
    }

    /** Closes the client on a worker after the engine detaches, and stops the workers. */
    fun detach() {
        val pool = synchronized(lock) {
            detached = true
            workers
        } ?: return
        try {
            pool.execute { runCatching { closeClient() } }
        } catch (e: RejectedExecutionException) {
        }
        pool.shutdown()
    }

    private fun workers(): ThreadPoolExecutor? = synchronized(lock) {
        if (detached) return null
        workers ?: ThreadPoolExecutor(
            WORKERS, WORKERS, 30, TimeUnit.SECONDS, LinkedBlockingQueue(),
        ) { r -> Thread(r, "barometer-channel").apply { isDaemon = true } }
            .apply { allowCoreThreadTimeOut(true) }
            .also { workers = it }
    }

    private fun perform(call: ChannelCall): Any? {
        when (call) {
            is ChannelCall.Initialize -> {
                openClient().facade.initialize(call.config)
                return null
            }
            ChannelCall.Close -> {
                closeClient()
                return null
            }
            else -> {}
        }
        val facade = synchronized(lock) { client }?.facade ?: throw CodeException(ERR_NOT_INITIALIZED)
        return when (call) {
            is ChannelCall.AdmitEmbedded -> {
                val issuer = synchronized(lock) { embeddedIssuer } ?: throw CodeException(ERR_DELIVERY)
                val bytes = readAsset(context.assets, "$TASKS_DIR/${call.name}.json", ChannelContract.MAX_DELIVERY_BYTES)
                    ?: throw CodeException(ERR_DELIVERY)
                val ref = facade.installEmbeddedTask(issuer, bytes)
                facade.admitTask(String(bytes, Charsets.UTF_8), ref)
            }
            is ChannelCall.AdmitRemote -> {
                // Go compares these exact bytes with the installed record and verifies the
                // signature; bytes that are not UTF-8 do not survive the string and are rejected.
                val ref = facade.installRemoteTask(call.signedPackage)
                facade.admitTask(String(call.signedPackage, Charsets.UTF_8), ref)
            }
            is ChannelCall.StartRun -> facade.startRun(call.task)
            is ChannelCall.RunState -> mapOf("state" to facade.runState(call.run))
            is ChannelCall.CancelRun -> facade.cancelRun(call.run).let { null }
            ChannelCall.NextBundle -> facade.nextBundle().takeIf { it.isNotEmpty() }?.toByteArray(Charsets.UTF_8)
            is ChannelCall.AcknowledgeBundle -> facade.acknowledgeBundle(call.id).let { null }
            is ChannelCall.SetProxy -> facade.setProxy(call.proxy).let { null }
            ChannelCall.ClearProxy -> facade.clearProxy().let { null }
            ChannelCall.ClearMeasurementData -> facade.clearMeasurementData().let { null }
            is ChannelCall.Initialize, ChannelCall.Close -> null
        }
    }

    /** Returns the client, creating the store and client on first use. */
    private fun openClient(): BarometerClient = synchronized(lock) {
        client?.let { return it }
        val trust = try {
            TrustDocument.read(context.assets)
        } catch (e: AdapterUnavailableException) {
            throw CodeException(ERR_TRUST)
        }
        val records = try {
            RecordStore.open(context)
        } catch (e: RecordStoreException) {
            throw CodeException(ERR_STORAGE)
        }
        val created = try {
            BarometerBinding.newClient(context, records, trust)
        } catch (e: Exception) {
            runCatching { records.close() }
            throw e
        }
        store = records
        client = created
        embeddedIssuer = TrustDocument.embeddedIssuer(trust)
        created
    }

    /** Closes the client, then the store. Without a client it succeeds. */
    private fun closeClient() = synchronized(lock) {
        client?.close()
        client = null
        embeddedIssuer = null
        try {
            store?.close()
        } catch (e: RecordStoreException) {
            throw CodeException(ERR_STORAGE)
        }
        store = null
    }

    /** A failure raised here with a fixed code. */
    private class CodeException(code: String) : Exception(code)

    companion object {
        /** The asset directory of embedded tasks in the application package. */
        const val TASKS_DIR = "barometer/tasks"

        private const val WORKERS = 4
        private const val ERR_CLOSED = "client_closed"
        private const val ERR_NOT_INITIALIZED = "not_initialized"
        private const val ERR_DELIVERY = "delivery_unavailable"
        private const val ERR_TRUST = "trust_invalid"
        private const val ERR_STORAGE = "storage_unavailable"

        private val CODE = Regex("[a-z][a-z0-9_]{0,63}")

        /**
         * The code of [e]. The facade's errors are checked exceptions whose message is only a
         * code; any other failure, whose message might carry detail, becomes
         * [ChannelContract.NATIVE_ERROR].
         */
        fun code(e: Throwable): String {
            val message = e.message
            val coded = e !is RuntimeException && e !is Error && message != null && CODE.matches(message)
            return if (coded) message!! else ChannelContract.NATIVE_ERROR
        }
    }
}
