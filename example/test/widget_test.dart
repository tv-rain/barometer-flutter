import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:barometer_flutter_example/main.dart';

const _channel = MethodChannel('com.tvrain.barometer_flutter/client');

void main() {
  late List<MethodCall> calls;
  late Future<Object?>? Function(MethodCall call) answer;

  setUp(() {
    calls = [];
    answer = (_) async => null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) {
          calls.add(call);
          return answer(call);
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  testWidgets('makes no Barometer call at launch', (tester) async {
    await tester.pumpWidget(const ExampleApp());
    await tester.pumpAndSettle();

    expect(find.text('idle'), findsOneWidget);
    expect(find.text('Run tcp-01'), findsOneWidget);
    expect(find.text('Run dns-01'), findsOneWidget);
    expect(calls, isEmpty);
  });

  testWidgets('a button runs the lifecycle through the channel', (
    tester,
  ) async {
    var states = 0;
    var pending = true;
    answer = (call) async => switch (call.method) {
      'admitTask' => 'task-1',
      'startRun' => 'run-1',
      'runState' => {'state': ++states < 2 ? 'active' : 'terminal'},
      'nextBundle' when pending => Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'bundle_id': 'b-1',
            'results': [
              {
                'execution': {'state': 'completed'},
                'measurement': {
                  'observations': [
                    {'type': 'tcp_connect'},
                  ],
                },
                'implementation': {'platform': 'android'},
              },
            ],
          }),
        ),
      ),
      'acknowledgeBundle' => () {
        pending = false;
        return null;
      }(),
      _ => null,
    };

    await tester.pumpWidget(const ExampleApp());
    await tester.runAsync(() async {
      await tester.tap(find.text('Run tcp-01'));
      for (
        var i = 0;
        i < 50 && find.text('done tcp-01').evaluate().isEmpty;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }
    });
    await tester.pump();

    expect(find.text('done tcp-01'), findsOneWidget);
    expect(
      find.text(
        'tcp-01: results=1 execution=completed observations=tcp_connect '
        'platform=android pending_after_ack=no',
      ),
      findsOneWidget,
    );
    expect(calls.map((c) => c.method), [
      'initialize',
      'admitTask',
      'startRun',
      'runState',
      'runState',
      'nextBundle',
      'acknowledgeBundle',
      'nextBundle',
    ]);
    expect(calls[1].arguments, {'source': 'embedded', 'name': 'tcp-01'});
    expect(calls[6].arguments, {'id': 'b-1'});
  });
}
