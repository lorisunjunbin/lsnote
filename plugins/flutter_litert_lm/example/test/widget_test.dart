import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_litert_lm_example/main.dart';

void main() {
  testWidgets('Model picker renders', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();
    expect(find.text('Flutter Lite LM'), findsOneWidget);
  });
}
