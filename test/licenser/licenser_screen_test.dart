import 'package:coursepack_generator/licenser/licenser_screen.dart';
import 'package:coursepack_file_io/coursepack_file_io.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeFileIo implements FileIo {
  @override
  Future<String?> pickTextFile() async => null;

  @override
  Future<String?> saveTextFile({
    required String filename,
    required String text,
  }) async =>
      'file:///$filename';
}

void main() {
  testWidgets('licence generator shows the issue form by default',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: LicenserScreen(fileIo: _FakeFileIo())),
    );
    await tester.pumpAndSettle();

    expect(find.text('CoursePack · Licence Generator'), findsOneWidget);
    expect(find.text('Issue a licence'), findsOneWidget);
    expect(find.text('Student name *'), findsOneWidget);
    expect(find.text('Device code *'), findsOneWidget);
    // The save button sits below the fold in a lazy ListView; scroll to it.
    await tester.drag(find.byType(ListView), const Offset(0.0, -800.0));
    await tester.pumpAndSettle();
    expect(find.text('Issue and save .lic'), findsOneWidget);
  });

  testWidgets('navigates to the keys tab and shows both loaders',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: LicenserScreen(fileIo: _FakeFileIo())),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Keys'));
    await tester.pumpAndSettle();

    expect(find.text('Signing key'), findsOneWidget);
    expect(find.text('Open private key (.pem)'), findsOneWidget);
    // 'Course keys' and its button sit below the fold in a lazy ListView.
    await tester.drag(find.byType(ListView), const Offset(0.0, -600.0));
    await tester.pumpAndSettle();
    expect(find.text('Course keys'), findsOneWidget);
    expect(find.text('Open course_keys.json'), findsOneWidget);
  });

  testWidgets('shows the load-key guidance before anything is loaded',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: LicenserScreen(fileIo: _FakeFileIo())),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Load your signing key and course keys to begin.'),
      findsOneWidget,
    );
  });
}
