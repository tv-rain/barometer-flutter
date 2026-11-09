package com.tvrain.barometer_flutter

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Registers the method channel of the Dart `BarometerClient`. Registration only sets the
 * handler: it loads no native library, opens no storage and starts no Barometer work. The
 * native client is created by the first `initialize` call ([BarometerHost]).
 */
class BarometerFlutterPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var host: BarometerHost? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        host = BarometerHost(binding.applicationContext, hostPolicy(binding.applicationContext))
        channel = MethodChannel(binding.binaryMessenger, ChannelContract.CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        host?.detach()
        host = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val reply = object : BarometerHost.Reply {
            override fun success(value: Any?) = result.success(value)
            override fun error(code: String) = result.error(code, null, null)
        }
        val handled = host?.handle(call.method, call.arguments, reply) ?: run {
            reply.error("client_closed")
            true
        }
        if (!handled) result.notImplemented()
    }

    companion object {
        private val ASSET_PATH = Regex("[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}(/[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}){0,7}")

        @Volatile
        private var trustAsset: String = TrustDocument.ASSET

        private var policy: HostPolicy? = null

        /**
         * Sets the application asset that holds the trusted local document, by default
         * `barometer/trust.json`. Only the host application's native code calls this, before
         * the engine registers the plugin, for example in `Application.onCreate`; Dart cannot.
         * The asset must ship in the application package with the release.
         *
         * The document is read at each `initialize`. A document that differs from the active
         * one is a policy replacement: it is activated only when its `policy_generation` is
         * strictly greater than every generation activated in this process, and then by
         * reinitialization, which closes the active client, cancelling its runs and
         * invalidating its handles. A lower or equal generation fails with `policy_rejected`.
         *
         * @throws IllegalArgumentException when [path] is not a relative asset path of plain
         * segments.
         */
        @JvmStatic
        fun setTrustAsset(path: String) {
            require(ASSET_PATH.matches(path)) { "invalid asset path" }
            trustAsset = path
        }

        /** The process's host policy adapter over the registered asset. */
        @Synchronized
        internal fun hostPolicy(context: Context): HostPolicy = policy ?: run {
            val assets = context.applicationContext.assets
            HostPolicy { TrustDocument.read(assets, trustAsset) }.also { policy = it }
        }
    }
}
