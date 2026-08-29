import 'package:flutter_test/flutter_test.dart';
import 'package:syncode_web/main.dart';

void main() {
  testWidgets('SyncodeApp smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const SyncodeApp());
    expect(find.text('Selecionar Pasta'), findsOneWidget);
  });
}
