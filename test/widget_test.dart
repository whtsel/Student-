import 'package:coursepack/crypto/course_pack_crypto.dart';
import 'package:coursepack/licence/device_code_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('first launch shows the computed device code and activation steps',
      (tester) async {
    const components = 'test-only:synthetic-device';
    await tester.pumpWidget(
      MaterialApp(
        home: DeviceCodeScreen(readComponents: () async => components),
      ),
    );
    await tester.pumpAndSettle();

    final expected = CoursePackCrypto.formatFingerprint(
      await CoursePackCrypto.computeFingerprint(components),
    );
    expect(find.text('Send this code to your instructor'), findsOneWidget);
    expect(find.text(expected), findsOneWidget);
    expect(find.text('Copy code'), findsOneWidget);
    expect(find.text('You have pushed the button this many times:'), findsNothing);
  });
}
