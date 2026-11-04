import 'package:flutter_test/flutter_test.dart';

import 'package:barometer_flutter_example/main.dart';

void main() {
  testWidgets('shows the skeleton notice', (WidgetTester tester) async {
    await tester.pumpWidget(const ExampleApp());

    expect(find.text('barometer_flutter skeleton: no API yet'), findsOneWidget);
  });
}
