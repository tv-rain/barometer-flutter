import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:barometer_flutter/barometer_flutter.dart';
import 'package:barometer_flutter_example/flow.dart';

/// Whether the build carries the synthetic fixture tasks and the host fixtures
/// run: on Android `-P barometerExampleAssets=barometer-fixtures` and
/// `scripts/android-measurement-fixtures.sh start`, on iOS
/// `BAROMETER_EXAMPLE_ASSETS=barometer-fixtures` with the fixture address from
/// `scripts/ios-measurement-fixtures.sh start`. Without it the test is
/// skipped.
const fixtures = bool.fromEnvironment('BAROMETER_MEASUREMENT_FIXTURES');

/// With `BAROMETER_FIXTURE_CHECK=shape` the test checks only the lifecycle and
/// result shape of each task (one completed result from this platform, no
/// pending bundle after the acknowledgement), not its observation types or
/// outcome. It is for a device that cannot reach the host fixtures.
const shapeOnly = String.fromEnvironment('BAROMETER_FIXTURE_CHECK') == 'shape';

/// The observation types and outcome each fixture task must produce. The
/// fixtures answer every request as registered, so each measurement reaches
/// its successful outcome; these are synthetic values, not measurement data.
const expected = {
  'tcp-01': ('tcp_connect', 'connected'),
  'dns-01': ('dns_query', 'resolved'),
  'dns-03': ('tcp_connect,tls_handshake,http_exchange,dns_query', 'response'),
  'dns-04': ('tcp_connect,tls_handshake,dns_query', 'response'),
  'tls-01': ('tcp_connect,tls_handshake', 'handshake_succeeded'),
  'http-01': ('tcp_connect,tls_handshake,http_exchange', 'expected_response'),
  'net-01': ('', 'snapshot'),
  'net-03': ('tcp_connect,http_exchange', 'validated'),
  'net-05': ('', 'completed'),
};

/// iOS has no public network-validation source, so the access state reports
/// validation as `unknown`, and NET-05 stops before its first step with
/// `inconclusive` there.
const iosOutcomes = {'net-05': 'inconclusive'};

/// Runs the nine registered measurements from Dart through the plugin, each
/// as a synthetic one-time embedded task, against the host fixtures of
/// `scripts/measurement_fixtures.py`. Every task names only the fixture
/// address, which the emulator redirects to the host and which on iOS is the
/// host's own address. The test prints no result.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final platform = Platform.isAndroid ? 'android' : 'ios';

  testWidgets('runs the nine registered measurements against the fixtures', (
    tester,
  ) async {
    final client = BarometerClient();
    for (final MapEntry(key: name, value: (types, outcome))
        in expected.entries) {
      final report = await runEmbeddedTask(client, name);
      if (shapeOnly) {
        expect(
          '${report.results} ${report.executionState} ${report.platform} '
              '${report.pendingAfterAcknowledge}',
          '1 completed $platform false',
          reason: name,
        );
        continue;
      }
      expect(
        report.toString(),
        'results=1 execution=completed observations=$types '
        'platform=$platform pending_after_ack=no',
        reason: name,
      );
      final want = Platform.isIOS ? iosOutcomes[name] ?? outcome : outcome;
      expect(report.outcome, want, reason: name);
    }
    await client.close();
  }, skip: !fixtures);
}
