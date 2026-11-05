package com.tvrain.barometer_flutter

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
        host = BarometerHost(binding.applicationContext)
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
}
