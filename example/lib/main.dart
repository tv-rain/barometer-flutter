import 'package:barometer_flutter/barometer_flutter.dart';
import 'package:flutter/material.dart';

import 'flow.dart';

void main() {
  runApp(const ExampleApp());
}

/// The embedded tasks the example ships, as `barometer/tasks/<name>.json`.
const exampleTasks = ['tcp-01', 'dns-01'];

/// Runs the example's embedded TCP-01 and DNS-01 tasks from Dart.
///
/// Nothing runs at launch: Barometer is initialized and a task runs only when
/// a button is pressed. The page shows the lifecycle steps and the result
/// shape, never the measurement outcome.
class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(title: 'Barometer example', home: ExamplePage());
  }
}

class ExamplePage extends StatefulWidget {
  const ExamplePage({super.key});

  @override
  State<ExamplePage> createState() => _ExamplePageState();
}

class _ExamplePageState extends State<ExamplePage> {
  // Construction makes no channel call and loads nothing.
  final _client = BarometerClient();
  final _log = <String>[];
  final _reports = <String, String>{};
  String _status = 'idle';
  bool _running = false;

  Future<void> _run(String name) async {
    setState(() {
      _running = true;
      _status = 'running $name';
      _log.clear();
    });
    String status;
    try {
      final report = await runEmbeddedTask(
        _client,
        name,
        log: (line) {
          if (mounted) setState(() => _log.add(line));
        },
      );
      _reports[name] = report.toString();
      status = 'done $name';
    } on BarometerException catch (e) {
      status = 'failed $name: ${e.code}';
    } on Exception catch (e) {
      status = 'failed $name: ${e.runtimeType}';
    } on StateError catch (e) {
      status = 'failed $name: ${e.message}';
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _status = status;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Barometer example')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Runs a synthetic embedded task from Dart. Nothing runs until you '
            'press a button.',
          ),
          const SizedBox(height: 12),
          for (final name in exampleTasks)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ElevatedButton(
                key: ValueKey('run-$name'),
                onPressed: _running ? null : () => _run(name),
                child: Text('Run $name'),
              ),
            ),
          const SizedBox(height: 12),
          Text(_status, key: const ValueKey('status')),
          for (final line in _log) Text(line),
          const SizedBox(height: 12),
          for (final entry in _reports.entries)
            Text(
              '${entry.key}: ${entry.value}',
              key: ValueKey('report-${entry.key}'),
            ),
        ],
      ),
    );
  }
}
