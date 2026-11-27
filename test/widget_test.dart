import 'package:coursepack/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('bootstrap screen shows the CoursePack name without demo data',
      (tester) async {
    await tester.pumpWidget(const CoursePackApp());

    expect(find.text('CoursePack'), findsOneWidget);
    expect(find.text('You have pushed the button this many times:'), findsNothing);
  });
}
