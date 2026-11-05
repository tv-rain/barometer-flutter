import Flutter

/// Registers the method channel of the Dart `BarometerClient`. Registration only sets the
/// handler: it calls into no native library, opens no storage and starts no Barometer work. The
/// native client is created by the first `initialize` call (`BarometerHost`).
public class BarometerFlutterPlugin: NSObject, FlutterPlugin {
  private var host: BarometerHost?
  private var channel: FlutterMethodChannel?

  init(host: BarometerHost) {
    self.host = host
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: ChannelContract.channel, binaryMessenger: registrar.messenger())
    let instance = BarometerFlutterPlugin(host: BarometerHost())
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    channel?.setMethodCallHandler(nil)
    channel = nil
    host?.detach()
    host = nil
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let reply = BarometerHost.Reply(
      success: { result($0) },
      error: { result(FlutterError(code: $0, message: nil, details: nil)) })
    guard let host else {
      reply.error("client_closed")
      return
    }
    if !host.handle(call.method, call.arguments, reply) {
      result(FlutterMethodNotImplemented)
    }
  }
}
