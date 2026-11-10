import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:barometer_flutter_example/main.dart';

/// Runs the example's embedded TCP-01 and DNS-01 tasks from Dart through the
/// plugin, on an emulator or simulator, by pressing the example's buttons.
///
/// TCP-01 contacts 1.1.1.1:443 once and DNS-01 resolves example.org once. The
/// test checks the lifecycle and the result shape, never the outcome, and
/// prints no result.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // When the test runs from an XCTest (ios/RunnerTests/IntegrationTests.m), the test host turns
  // accessibility on while the test runs, and the semantics handle that adds would be reported
  // as left open at its end. The test does not use semantics.
  binding.platformDispatcher.semanticsEnabledTestValue = false;

  final platform = Platform.isAndroid ? 'android' : 'ios';

  Future<String> runTask(WidgetTester tester, String name) async {
    await tester.tap(find.byKey(ValueKey('run-$name')));
    await tester.pump();
    final status = find.byKey(const ValueKey('status'));
    final deadline = DateTime.now().add(const Duration(seconds: 120));
    while (true) {
      final text = tester.widget<Text>(status).data!;
      if (!text.startsWith('running')) return text;
      if (DateTime.now().isAfter(deadline)) fail('$name did not finish');
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await tester.pump();
    }
  }

  String report(WidgetTester tester, String name) =>
      tester.widget<Text>(find.byKey(ValueKey('report-$name'))).data!;

  testWidgets('runs TCP-01 and DNS-01 from Dart', (tester) async {
    await tester.pumpWidget(const ExampleApp());
    await tester.pumpAndSettle();
    expect(find.text('idle'), findsOneWidget);

    expect(await runTask(tester, 'tcp-01'), 'done tcp-01');
    expect(
      report(tester, 'tcp-01'),
      'tcp-01: results=1 execution=completed observations=tcp_connect '
      'platform=$platform pending_after_ack=no',
    );

    expect(await runTask(tester, 'dns-01'), 'done dns-01');
    expect(
      report(tester, 'dns-01'),
      'dns-01: results=1 execution=completed observations=dns_query '
      'platform=$platform pending_after_ack=no',
    );
  });
}
