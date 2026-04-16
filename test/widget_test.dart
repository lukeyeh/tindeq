import 'package:flutter_test/flutter_test.dart';

import 'package:tindeq_load_app/main.dart';

void main() {
  testWidgets('App renders home screen', (WidgetTester tester) async {
    await tester.pumpWidget(const TindeqApp());
    expect(find.text('Tindeq Progressor'), findsOneWidget);
    expect(find.text('kg'), findsOneWidget);
  });
}
