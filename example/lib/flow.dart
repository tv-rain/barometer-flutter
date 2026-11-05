import 'dart:async';

import 'package:barometer_flutter/barometer_flutter.dart';

/// What one run of an embedded task produced: lifecycle and result shape only,
/// never the measurement outcome.
class FlowReport {
  const FlowReport({
    required this.polls,
    required this.results,
    required this.executionState,
    required this.observationTypes,
    required this.platform,
    required this.pendingAfterAcknowledge,
  });

  /// How many `runState` calls returned before the run was terminal.
  final int polls;

  /// The number of results in the bundle.
  final int results;

  /// The `execution.state` of the first result, such as `completed`.
  final String executionState;

  /// The observation types of the first result, such as `tcp_connect`.
  final List<String> observationTypes;

  /// The `implementation.platform` of the first result.
  final String platform;

  /// Whether another bundle was still pending after the acknowledgement.
  final bool pendingAfterAcknowledge;

  @override
  String toString() =>
      'results=$results execution=$executionState '
      'observations=${observationTypes.join(',')} platform=$platform '
      'pending_after_ack=${pendingAfterAcknowledge ? 'yes' : 'no'}';
}

/// Runs the embedded task [name] through [client]: initializes Barometer if
/// it is not yet, admits the task, starts a run, polls `runState` until the
/// run is terminal, then reads and acknowledges the oldest pending bundle.
///
/// [log] receives one line per step. A run still active after [timeout] is
/// cancelled and a [TimeoutException] is thrown; a Barometer failure throws
/// its [BarometerException].
Future<FlowReport> runEmbeddedTask(
  BarometerClient client,
  String name, {
  void Function(String line)? log,
  Duration pollInterval = const Duration(milliseconds: 200),
  Duration timeout = const Duration(seconds: 90),
}) async {
  void say(String line) => log?.call(line);

  try {
    await client.initialize(const {});
    say('initialized');
  } on BarometerException catch (e) {
    if (e.code != 'already_initialized') rethrow;
    say('already initialized');
  }

  final task = await client.admitTask(embeddedTask(name));
  say('admitted $name');
  final run = await client.startRun(task);
  say('run started');

  final deadline = DateTime.now().add(timeout);
  var polls = 0;
  while (true) {
    final state = await client.runState(run);
    polls++;
    if (state['state'] == 'terminal') break;
    if (DateTime.now().isAfter(deadline)) {
      await client.cancelRun(run);
      throw TimeoutException('run did not become terminal', timeout);
    }
    await Future<void>.delayed(pollInterval);
  }
  say('run terminal after $polls polls');

  final bundle = await client.nextBundle();
  if (bundle == null) throw StateError('no bundle is pending');
  final json = bundle.toJson();
  final results = (json['results'] as List<Object?>?) ?? const [];
  if (results.isEmpty) throw StateError('the bundle has no result');
  final first = results.first as Map<String, Object?>;
  final execution = first['execution'] as Map<String, Object?>?;
  final measurement = first['measurement'] as Map<String, Object?>?;
  final implementation = first['implementation'] as Map<String, Object?>?;
  final observations =
      (measurement?['observations'] as List<Object?>?) ?? const [];
  say('bundle read: ${results.length} result(s)');

  await client.acknowledgeBundle(bundle.id);
  say('bundle acknowledged');
  final pending = await client.nextBundle();

  return FlowReport(
    polls: polls,
    results: results.length,
    executionState: '${execution?['state']}',
    observationTypes: [
      for (final o in observations) '${(o as Map<String, Object?>)['type']}',
    ],
    platform: '${implementation?['platform']}',
    pendingAfterAcknowledge: pending != null,
  );
}
