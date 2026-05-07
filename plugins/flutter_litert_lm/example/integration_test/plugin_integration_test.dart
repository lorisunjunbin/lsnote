// Integration test for the example app. Real LLM inference needs a model
// file on disk and several gigabytes of RAM, so this test only verifies
// that the example app boots far enough to render the model picker — the
// actual download/load/chat flow is exercised manually from the example
// UI on real hardware.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:flutter_litert_lm_example/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Example app boots into the model picker', (tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();
    expect(find.text('Flutter Lite LM'), findsOneWidget);
  });
}
