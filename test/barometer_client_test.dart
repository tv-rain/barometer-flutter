import 'dart:convert';

import 'package:barometer_flutter/barometer_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('com.tvrain.barometer_flutter/client');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];
  var answers = <String, Object? Function(MethodCall)>{};

  setUp(() {
    calls.clear();
    answers = {};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          final answer = answers[call.method];
          return answer == null ? null : answer(call);
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test('construction does no work', () {
    BarometerClient();
    BarometerClient();
    embeddedTask('tcp');
    installRemoteTask(Uint8List(1));
    expect(calls, isEmpty);
  });

  test('initialize sends the configuration as JSON text', () async {
    await BarometerClient().initialize({
      'proxy': null,
      'result_linkage': {'mode': 'disabled'},
    });
    expect(calls.single.method, 'initialize');
    final arguments = calls.single.arguments as Map;
    expect(arguments.keys, ['config']);
    expect(jsonDecode(arguments['config'] as String), {
      'proxy': null,
      'result_linkage': {'mode': 'disabled'},
    });
  });

  test('admitTask sends an embedded task name only', () async {
    answers['admitTask'] = (_) => 'T.embedded';
    final handle = await BarometerClient().admitTask(embeddedTask('tcp-01'));
    expect(calls.single.method, 'admitTask');
    expect(calls.single.arguments, {'source': 'embedded', 'name': 'tcp-01'});
    expect(handle.toString(), 'TaskHandle');
  });

  test('admitTask sends a copy of the exact package bytes', () async {
    answers['admitTask'] = (_) => 'T.remote';
    final package = Uint8List.fromList(utf8.encode('{"key_id":"k"}'));
    final source = installRemoteTask(package);
    package[0] = 0;
    await BarometerClient().admitTask(source);
    final arguments = calls.single.arguments as Map;
    expect(arguments.keys, unorderedEquals(['source', 'package']));
    expect(arguments['source'], 'remote');
    expect(arguments['package'], utf8.encode('{"key_id":"k"}'));
  });

  test('handles round-trip as opaque values', () async {
    answers['admitTask'] = (_) => 'T.a';
    answers['startRun'] = (_) => 'R.a';
    answers['runState'] = (_) => {'state': 'active'};
    final client = BarometerClient();
    final task = await client.admitTask(embeddedTask('a'));
    final run = await client.startRun(task);
    expect(await client.runState(run), {'state': 'active'});
    await client.cancelRun(run);
    expect(calls.map((c) => c.method), [
      'admitTask',
      'startRun',
      'runState',
      'cancelRun',
    ]);
    expect(calls[1].arguments, {'task': 'T.a'});
    expect(calls[2].arguments, {'run': 'R.a'});
    expect(calls[3].arguments, {'run': 'R.a'});
    expect(run.toString(), 'RunHandle');
  });

  test('nextBundle returns the exact bytes and the identifier', () async {
    final raw = Uint8List.fromList(
      utf8.encode('{"bundle_id":"b1","results":[1.0]}'),
    );
    answers['nextBundle'] = (_) => raw;
    final bundle = await BarometerClient().nextBundle();
    expect(bundle!.id, 'b1');
    expect(bundle.bytes, raw);
    expect(bundle.toJson()['results'], [1.0]);
    expect(calls.single.arguments, isNull);
  });

  test('nextBundle returns null when none is pending', () async {
    expect(await BarometerClient().nextBundle(), isNull);
  });

  test('nextBundle rejects a bundle without an identifier', () async {
    answers['nextBundle'] = (_) => Uint8List.fromList(utf8.encode('{}'));
    await expectLater(
      BarometerClient().nextBundle(),
      throwsA(_code('native_error')),
    );
  });

  test('the remaining calls send their arguments', () async {
    final client = BarometerClient();
    await client.acknowledgeBundle('b1');
    await client.setProxy({'scheme': 'socks5'});
    await client.clearProxy();
    await client.clearMeasurementData();
    await client.close();
    expect(calls.map((c) => c.method), [
      'acknowledgeBundle',
      'setProxy',
      'clearProxy',
      'clearMeasurementData',
      'close',
    ]);
    expect(calls[0].arguments, {'id': 'b1'});
    expect(jsonDecode((calls[1].arguments as Map)['proxy'] as String), {
      'scheme': 'socks5',
    });
    expect(calls.skip(2).map((c) => c.arguments), everyElement(isNull));
  });

  test('platform errors surface as BarometerException with the code', () async {
    answers['admitTask'] = (_) => 'T.x';
    answers['startRun'] = (_) => 'R.x';
    final client = BarometerClient();
    final task = await client.admitTask(embeddedTask('x'));
    final run = await client.startRun(task);
    for (final method in [
      'initialize',
      'admitTask',
      'startRun',
      'runState',
      'cancelRun',
      'nextBundle',
      'acknowledgeBundle',
      'setProxy',
      'clearProxy',
      'clearMeasurementData',
      'close',
    ]) {
      answers[method] = (_) =>
          throw PlatformException(code: 'code_$method', message: 'detail');
    }
    final attempts = <String, Future<Object?> Function()>{
      'initialize': () => client.initialize({}),
      'admitTask': () => client.admitTask(embeddedTask('a')),
      'startRun': () => client.startRun(task),
      'runState': () => client.runState(run),
      'cancelRun': () => client.cancelRun(run),
      'nextBundle': () => client.nextBundle(),
      'acknowledgeBundle': () => client.acknowledgeBundle('b'),
      'setProxy': () => client.setProxy({}),
      'clearProxy': () => client.clearProxy(),
      'clearMeasurementData': () => client.clearMeasurementData(),
      'close': () => client.close(),
    };
    for (final MapEntry(:key, :value) in attempts.entries) {
      await expectLater(value(), throwsA(_code('code_$key')), reason: key);
    }
  });

  test('a value that is not JSON fails before the channel', () async {
    await expectLater(
      BarometerClient().initialize({'x': Object()}),
      throwsA(_code('invalid_arguments')),
    );
    expect(calls, isEmpty);
  });

  test('a missing handle is a native error', () async {
    await expectLater(
      BarometerClient().admitTask(embeddedTask('a')),
      throwsA(_code('native_error')),
    );
  });
}

Matcher _code(String code) =>
    isA<BarometerException>().having((e) => e.code, 'code', code);
