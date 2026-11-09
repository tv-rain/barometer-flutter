import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:barometer_flutter/barometer_flutter.dart';
import 'package:barometer_flutter_example/flow.dart';

/// Whether the build carries the synthetic fixture tasks
/// (`-P barometerExampleAssets=barometer-fixtures`) and the emulator was
/// prepared with `scripts/android-measurement-fixtures.sh start`. Without it
/// the test is skipped.
const fixtures = bool.fromEnvironment('BAROMETER_MEASUREMENT_FIXTURES');

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

/// Runs the nine registered measurements from Dart through the plugin, each
/// as a synthetic one-time embedded task, against the host fixtures of
/// `scripts/measurement_fixtures.py`. Every task names only the fixture
/// address, which the emulator redirects to the host. The test prints no
/// result.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('runs the nine registered measurements against the fixtures', (
    tester,
  ) async {
    final client = BarometerClient();
    for (final MapEntry(key: name, value: (types, outcome))
        in expected.entries) {
      final report = await runEmbeddedTask(client, name);
      expect(
        report.toString(),
        'results=1 execution=completed observations=$types '
        'platform=android pending_after_ack=no',
        reason: name,
      );
      expect(report.outcome, outcome, reason: name);
    }
    await client.close();
  }, skip: !fixtures);
}
