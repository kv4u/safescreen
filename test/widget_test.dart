import 'package:flutter_test/flutter_test.dart';
import 'package:safe_screen/main.dart';

void main() {
  testWidgets('SafeScreenApp renders without crashing', (tester) async {
    await tester.pumpWidget(const SafeScreenApp());
    expect(find.byType(SafeScreenApp), findsOneWidget);
  });
}
