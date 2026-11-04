import 'package:flutter/material.dart';

void main() {
  runApp(const ExampleApp());
}

/// Builds with the plugin linked. The skeleton has no API to call.
class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(
        body: Center(child: Text('barometer_flutter skeleton: no API yet')),
      ),
    );
  }
}
