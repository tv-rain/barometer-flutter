import Flutter
import Foundation

/// One parsed method-channel call: the only values Dart can send to the native client.
///
/// Every argument is a JSON text, opaque handle string, bundle identifier, embedded task name or
/// signed package bytes. None is a trust input: no call carries a local policy, approval, trust
/// root, issuer association or adapter, and `ChannelContract.parse` rejects any argument map
/// whose keys are not exactly the ones listed for its method, so such a value cannot be smuggled
/// in. Unknown methods parse to nil and are reported as not implemented.
enum ChannelCall: Equatable {
  case initialize(config: String)
  case admitEmbedded(name: String)
  case admitRemote(signedPackage: Data)
  case startRun(task: String)
  case runState(run: String)
  case cancelRun(run: String)
  case nextBundle
  case acknowledgeBundle(id: String)
  case setProxy(proxy: String)
  case clearProxy
  case clearMeasurementData
  case close
}

/// A malformed channel call. The Dart API never sends one.
struct InvalidArgumentsError: Error {}

/// The channel contract shared with the Kotlin handler; the README documents it.
enum ChannelContract {
  static let channel = "com.tvrain.barometer_flutter/client"

  /// Native-only error codes; every other code is the facade's.
  static let invalidArguments = "invalid_arguments"
  static let nativeError = "native_error"

  /// Bound of a JSON text argument, in UTF-16 code units as Dart and Kotlin count them; the
  /// facade's own envelopes are smaller.
  static let maxJSONChars = 65_536

  /// Bound of a handle or bundle identifier, in UTF-16 code units.
  static let maxIDChars = 256

  /// `task.MaxDeliveryBytes`: the facade's receive bound for task and package bytes.
  static let maxDeliveryBytes = 131_072

  /// Parses `method` with `arguments`, or returns nil for an unknown method.
  static func parse(_ method: String, _ arguments: Any?) throws -> ChannelCall? {
    switch method {
    case "initialize": return .initialize(config: try json(only(arguments, "config"), "config"))
    case "admitTask": return try admit(arguments)
    case "startRun": return .startRun(task: try id(only(arguments, "task"), "task"))
    case "runState": return .runState(run: try id(only(arguments, "run"), "run"))
    case "cancelRun": return .cancelRun(run: try id(only(arguments, "run"), "run"))
    case "nextBundle": return try none(arguments, .nextBundle)
    case "acknowledgeBundle": return .acknowledgeBundle(id: try id(only(arguments, "id"), "id"))
    case "setProxy": return .setProxy(proxy: try json(only(arguments, "proxy"), "proxy"))
    case "clearProxy": return try none(arguments, .clearProxy)
    case "clearMeasurementData": return try none(arguments, .clearMeasurementData)
    case "close": return try none(arguments, .close)
    default: return nil
    }
  }

  /// Whether `name` is an embedded task name: 1 to 64 lowercase ASCII letters, digits, `_` and
  /// `-`, starting with a letter or digit. It has no separator or dot, so it cannot leave
  /// `barometer/tasks/`.
  static func isTaskName(_ name: String) -> Bool {
    let bytes = Array(name.utf8)
    guard (1...64).contains(bytes.count) else { return false }
    for (i, c) in bytes.enumerated() {
      let letterOrDigit = (0x61...0x7a).contains(c) || (0x30...0x39).contains(c)
      if letterOrDigit || (i > 0 && (c == 0x5f || c == 0x2d)) { continue }
      return false
    }
    return true
  }

  /// The code sent to Dart for `error`. Facade errors and the host's fixed codes cross when they
  /// are bare codes; any other failure, whose description might carry detail, becomes
  /// `native_error`.
  static func code(_ error: Error) -> String {
    let code: String?
    switch error {
    case let e as BarometerError: code = e.code
    case let e as HostCodeError: code = e.code
    case is InvalidArgumentsError: code = invalidArguments
    default: code = nil
    }
    guard let code, isCode(code) else { return nativeError }
    return code
  }

  /// `[a-z][a-z0-9_]{0,63}`.
  private static func isCode(_ s: String) -> Bool {
    let bytes = Array(s.utf8)
    guard (1...64).contains(bytes.count), (0x61...0x7a).contains(bytes[0]) else { return false }
    return bytes.allSatisfy { (0x61...0x7a).contains($0) || (0x30...0x39).contains($0) || $0 == 0x5f }
  }

  private static func admit(_ arguments: Any?) throws -> ChannelCall {
    guard let map = arguments as? [AnyHashable: Any] else { throw InvalidArgumentsError() }
    switch map["source"] as? String {
    case "embedded":
      guard let name = try only(arguments, "source", "name")["name"] as? String, isTaskName(name)
      else { throw InvalidArgumentsError() }
      return .admitEmbedded(name: name)
    case "remote":
      guard let typed = try only(arguments, "source", "package")["package"] as? FlutterStandardTypedData,
        typed.type == .uInt8, !typed.data.isEmpty, typed.data.count <= maxDeliveryBytes
      else { throw InvalidArgumentsError() }
      return .admitRemote(signedPackage: Data(typed.data))
    default:
      throw InvalidArgumentsError()
    }
  }

  /// Requires a map whose keys are exactly `keys`.
  private static func only(_ arguments: Any?, _ keys: String...) throws -> [AnyHashable: Any] {
    guard let map = arguments as? [AnyHashable: Any] else { throw InvalidArgumentsError() }
    let names = map.keys.compactMap { $0.base as? String }
    guard names.count == map.count, Set(names) == Set(keys) else { throw InvalidArgumentsError() }
    return map
  }

  private static func none(_ arguments: Any?, _ call: ChannelCall) throws -> ChannelCall {
    guard arguments == nil || arguments is NSNull else { throw InvalidArgumentsError() }
    return call
  }

  private static func json(_ map: [AnyHashable: Any], _ key: String) throws -> String {
    try string(map, key, max: maxJSONChars)
  }

  private static func id(_ map: [AnyHashable: Any], _ key: String) throws -> String {
    try string(map, key, max: maxIDChars)
  }

  private static func string(_ map: [AnyHashable: Any], _ key: String, max: Int) throws -> String {
    guard let s = map[key] as? String, !s.isEmpty, s.utf16.count <= max else {
      throw InvalidArgumentsError()
    }
    return s
  }
}
