import 'dart:convert';

import 'package:flutter/services.dart';

/// The method channel between [BarometerClient] and the native plugin.
const MethodChannel _channel = MethodChannel(
  'com.tvrain.barometer_flutter/client',
);

/// A failed Barometer call.
///
/// [code] is the code string of the Barometer facade, such as
/// `not_initialized` or `task_source_unauthenticated`, or one of the native
/// codes listed in the README. It carries no other detail.
class BarometerException implements Exception {
  const BarometerException(this.code);

  final String code;

  @override
  String toString() => 'BarometerException($code)';
}

/// An opaque handle to an admitted task, valid for one client generation.
final class TaskHandle {
  const TaskHandle._(this._value);

  final String _value;

  @override
  bool operator ==(Object other) =>
      other is TaskHandle && other._value == _value;

  @override
  int get hashCode => _value.hashCode;

  @override
  String toString() => 'TaskHandle';
}

/// An opaque handle to a started run, valid for one client generation.
final class RunHandle {
  const RunHandle._(this._value);

  final String _value;

  @override
  bool operator ==(Object other) =>
      other is RunHandle && other._value == _value;

  @override
  int get hashCode => _value.hashCode;

  @override
  String toString() => 'RunHandle';
}

/// A pending Result Bundle returned by [BarometerClient.nextBundle].
final class Bundle {
  Bundle._(this.id, this.bytes);

  /// The bundle identifier to pass to [BarometerClient.acknowledgeBundle].
  final String id;

  /// The exact UTF-8 JSON bytes of the bundle, as Barometer stored them.
  /// Transport these bytes unchanged.
  final Uint8List bytes;

  /// The bundle decoded as a JSON map.
  Map<String, Object?> toJson() =>
      jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;

  @override
  String toString() => 'Bundle';
}

/// Where [BarometerClient.admitTask] takes a task from: [embeddedTask] or
/// [installRemoteTask].
sealed class TaskSource {
  const TaskSource._();
}

final class _EmbeddedTask extends TaskSource {
  const _EmbeddedTask(this.name) : super._();

  final String name;
}

final class _RemoteTask extends TaskSource {
  const _RemoteTask(this.signedPackage) : super._();

  final Uint8List signedPackage;
}

/// A task shipped with the application as the asset
/// `barometer/tasks/<name>.json`.
///
/// The native layer reads the asset and installs it with the embedded issuer
/// of the trusted local document; Dart supplies only the name. A name is 1 to
/// 64 characters of lowercase ASCII letters, digits, `_` and `-`, starting with
/// a letter or digit.
TaskSource embeddedTask(String name) => _EmbeddedTask(name);

/// A signed remote task package, passed unchanged to the native layer, which
/// installs it as a remote delivery record.
///
/// The package carries no authority: Barometer verifies its signature against
/// the issuer keys of the trusted local policy when the task is admitted.
TaskSource installRemoteTask(Uint8List signedPackage) =>
    _RemoteTask(Uint8List.fromList(signedPackage));

/// The Barometer lifecycle client.
///
/// Constructing it does nothing: no channel call, native library load,
/// storage access or measurement. The native client is created by
/// [initialize] and released by [close]. Every call runs off the UI thread on
/// the native side. A failure throws [BarometerException].
///
/// The native client belongs to the Flutter engine, so every
/// [BarometerClient] of one engine drives the same native client.
class BarometerClient {
  BarometerClient();

  /// Creates the native client if needed and initializes it with the host
  /// configuration [config] (`proxy`, `network_context`, `result_linkage`).
  ///
  /// After `clearing_incomplete`, call [clearMeasurementData] to recover.
  Future<void> initialize(Map<String, Object?> config) async {
    await _call<void>('initialize', {'config': _encode(config)});
  }

  /// Installs [source] and admits its task. Returns a handle only when the
  /// task is accepted; a rejection throws its admission code.
  Future<TaskHandle> admitTask(TaskSource source) async {
    final arguments = switch (source) {
      _EmbeddedTask(:final name) => {'source': 'embedded', 'name': name},
      _RemoteTask(:final signedPackage) => {
        'source': 'remote',
        'package': signedPackage,
      },
    };
    return TaskHandle._(await _value<String>('admitTask', arguments));
  }

  /// Starts a run of an admitted task.
  Future<RunHandle> startRun(TaskHandle task) async =>
      RunHandle._(await _value<String>('startRun', {'task': task._value}));

  /// The run's polling state: `{'state': 'active'}` until its work has
  /// finished, then `{'state': 'terminal'}`.
  Future<Map<String, Object?>> runState(RunHandle run) async {
    final state = await _value<Map<Object?, Object?>>('runState', {
      'run': run._value,
    });
    return state.cast<String, Object?>();
  }

  /// Cancels a run and waits for its cleanup, within Barometer's bound.
  Future<void> cancelRun(RunHandle run) =>
      _call<void>('cancelRun', {'run': run._value});

  /// The oldest pending Result Bundle, or null when none is pending.
  Future<Bundle?> nextBundle() async {
    final bytes = await _call<Uint8List>('nextBundle');
    if (bytes == null) return null;
    final Object? id;
    try {
      id =
          (jsonDecode(utf8.decode(bytes)) as Map<String, Object?>)['bundle_id'];
    } on Object {
      throw const BarometerException('native_error');
    }
    if (id is! String) throw const BarometerException('native_error');
    return Bundle._(id, bytes);
  }

  /// Deletes the bundle [id] once the host has delivered it durably.
  Future<void> acknowledgeBundle(String id) =>
      _call<void>('acknowledgeBundle', {'id': id});

  /// Replaces the proxy configuration with the closed proxy object [proxy].
  Future<void> setProxy(Map<String, Object?> proxy) async {
    await _call<void>('setProxy', {'proxy': _encode(proxy)});
  }

  /// Removes the proxy configuration.
  Future<void> clearProxy() => _call<void>('clearProxy');

  /// Deletes Barometer's measurement data and leaves the client
  /// uninitialized. It uploads nothing.
  Future<void> clearMeasurementData() => _call<void>('clearMeasurementData');

  /// Closes the native client and its storage. Without a native client it
  /// succeeds.
  Future<void> close() => _call<void>('close');

  static String _encode(Map<String, Object?> value) {
    try {
      return jsonEncode(value);
    } on JsonUnsupportedObjectError {
      throw const BarometerException('invalid_arguments');
    }
  }

  static Future<T?> _call<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (e) {
      throw BarometerException(e.code);
    }
  }

  static Future<T> _value<T>(String method, Object? arguments) async {
    final value = await _call<T>(method, arguments);
    if (value == null) throw const BarometerException('native_error');
    return value;
  }
}
