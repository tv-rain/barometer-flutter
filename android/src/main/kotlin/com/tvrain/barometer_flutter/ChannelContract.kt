package com.tvrain.barometer_flutter

/**
 * The method-channel contract: the only values Dart can send to the native client.
 *
 * Every argument is a JSON text, opaque handle string, bundle identifier, embedded task name
 * or signed package bytes. None is a trust input: no call carries a local policy, approval,
 * trust root, issuer association or adapter, and [parse] rejects any argument map whose keys
 * are not exactly the ones listed for its method, so such a value cannot be smuggled in.
 * Unknown methods parse to null and are reported as not implemented.
 */
internal sealed class ChannelCall {
    data class Initialize(val config: String) : ChannelCall()
    data class AdmitEmbedded(val name: String) : ChannelCall()
    class AdmitRemote(val signedPackage: ByteArray) : ChannelCall()
    data class StartRun(val task: String) : ChannelCall()
    data class RunState(val run: String) : ChannelCall()
    data class CancelRun(val run: String) : ChannelCall()
    object NextBundle : ChannelCall()
    data class AcknowledgeBundle(val id: String) : ChannelCall()
    data class SetProxy(val proxy: String) : ChannelCall()
    object ClearProxy : ChannelCall()
    object ClearMeasurementData : ChannelCall()
    object Close : ChannelCall()
}

/** A malformed channel call. The Dart API never sends one. */
internal class InvalidArgumentsException : Exception(ChannelContract.INVALID_ARGUMENTS)

internal object ChannelContract {
    const val CHANNEL = "com.tvrain.barometer_flutter/client"

    /** Native-only error codes; every other code is the facade's. */
    const val INVALID_ARGUMENTS = "invalid_arguments"
    const val NATIVE_ERROR = "native_error"

    /** Bound of a JSON text argument; the facade's own envelopes are smaller. */
    const val MAX_JSON_CHARS = 65_536

    /** Bound of a handle or bundle identifier. */
    const val MAX_ID_CHARS = 256

    /** `task.MaxDeliveryBytes`: the facade's receive bound for task and package bytes. */
    const val MAX_DELIVERY_BYTES = 131_072

    /** An embedded task name: no separator or dot, so it cannot leave `barometer/tasks/`. */
    val TASK_NAME = Regex("[a-z0-9][a-z0-9_-]{0,63}")

    /** Parses [method] with [arguments], or returns null for an unknown method. */
    fun parse(method: String, arguments: Any?): ChannelCall? = when (method) {
        "initialize" -> ChannelCall.Initialize(json(only(arguments, "config"), "config"))
        "admitTask" -> admit(arguments)
        "startRun" -> ChannelCall.StartRun(id(only(arguments, "task"), "task"))
        "runState" -> ChannelCall.RunState(id(only(arguments, "run"), "run"))
        "cancelRun" -> ChannelCall.CancelRun(id(only(arguments, "run"), "run"))
        "nextBundle" -> none(arguments, ChannelCall.NextBundle)
        "acknowledgeBundle" -> ChannelCall.AcknowledgeBundle(id(only(arguments, "id"), "id"))
        "setProxy" -> ChannelCall.SetProxy(json(only(arguments, "proxy"), "proxy"))
        "clearProxy" -> none(arguments, ChannelCall.ClearProxy)
        "clearMeasurementData" -> none(arguments, ChannelCall.ClearMeasurementData)
        "close" -> none(arguments, ChannelCall.Close)
        else -> null
    }

    private fun admit(arguments: Any?): ChannelCall {
        val map = arguments as? Map<*, *> ?: throw InvalidArgumentsException()
        return when (map["source"]) {
            "embedded" -> {
                val name = only(arguments, "source", "name")["name"] as? String
                if (name == null || !TASK_NAME.matches(name)) throw InvalidArgumentsException()
                ChannelCall.AdmitEmbedded(name)
            }
            "remote" -> {
                val bytes = only(arguments, "source", "package")["package"] as? ByteArray
                if (bytes == null || bytes.isEmpty() || bytes.size > MAX_DELIVERY_BYTES) {
                    throw InvalidArgumentsException()
                }
                ChannelCall.AdmitRemote(bytes.copyOf())
            }
            else -> throw InvalidArgumentsException()
        }
    }

    /** Requires a map whose keys are exactly [keys]. */
    private fun only(arguments: Any?, vararg keys: String): Map<*, *> {
        val map = arguments as? Map<*, *> ?: throw InvalidArgumentsException()
        if (map.keys != keys.toSet()) throw InvalidArgumentsException()
        return map
    }

    private fun <T> none(arguments: Any?, call: T): T {
        if (arguments != null) throw InvalidArgumentsException()
        return call
    }

    private fun json(map: Map<*, *>, key: String): String {
        val s = map[key] as? String ?: throw InvalidArgumentsException()
        if (s.isEmpty() || s.length > MAX_JSON_CHARS) throw InvalidArgumentsException()
        return s
    }

    private fun id(map: Map<*, *>, key: String): String {
        val s = map[key] as? String ?: throw InvalidArgumentsException()
        if (s.isEmpty() || s.length > MAX_ID_CHARS) throw InvalidArgumentsException()
        return s
    }
}
