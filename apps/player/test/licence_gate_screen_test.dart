import 'dart:typed_data';

import 'package:coursepack_crypto/course_pack_crypto.dart';
import 'package:coursepack_file_io/coursepack_file_io.dart';
import 'package:coursepack_licence/ed25519_keys.dart';
import 'package:coursepack_licence/licence_model.dart';
import 'package:coursepack_player/licence/licence_gate_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// A [FileIo] that returns a fixed text payload (or null) without touching
/// the real system picker.
class _FakeFileIo implements FileIo {
  _FakeFileIo({this.text = null});

  String? text;

  @override
  Future<String?> pickTextFile() async => text;

  @override
  Future<String?> saveTextFile({
    required String filename,
    required String text,
  }) async =>
      null;

  @override
  Future<String?> pickFilePath() async => null;
}

/// Builds a CourseKeys with two lectures, each with a distinct content key.
CourseKeys _course() {
  return CourseKeys(
    version: coursePackFormatVersion,
    courseId: '88797A35D16D86C2',
    title: 'Statistics 201',
    createdAt: '2026-01-01T00:00:00+00:00',
    lectures: const <CourseKeyEntry>[
      CourseKeyEntry(
        id: 'L01',
        title: 'Welcom and course outline',
        file: 'L01.enc',
        key: 'QU9DBAGUBwgJCgsMDQ4PEA==',
        durationS: 812.5,
      ),
      CourseKeyEntry(
        id: 'L02',
        title: 'What statistics actually is',
        file: 'L02.enc',
        key: 'BAUGUBwgJCgsMDQ4PEBISAVAQ==',
        durationS: 1264.0,
      ),
    ],
  );
}

Future<(Uint8List pub, String licText)> _issueLicence(String fingerprint) async {
  final seed = CoursePackCrypto.decodeBase64('AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA');
  final key = await Ed25519Keys.fromSeed(seed);
  final issued = await LicenceGenerator(key: key, course: _course()).issue(
    name: 'Ama Mensah',
    fingerprint: fingerprint,
    expiresAt: '2027-06-30',
  );
  return (Uint8List.fromList(key.publicKey), issued.toJsonText());
}

Future<String> _rawFpFor(String components) =>
    CoursePackCrypto.computeFingerprint(components);

void main() {
  const components = 'device-part-1|device-part-2';

  testWidgets('shows the device code on first build', (WidgetTester tester) async {
    final rawFp = await _rawFpFor(components);
    final deviceCode = CoursePackCrypto.formatFingerprint(rawFp);
    await tester.pumpWidget(
      LicenceGateScreen(
        readComponents: () async => components,
        sellerPublicKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      ),
    );
    await tester.pumpAndSettle();
    // The fingerprint is computed from the components; it must be shown.
    expect(find.text(deviceCode), findsOneWidget);
  });

  testWidgets('accepts a valid, correctly-signed and device-bound licence',
      (WidgetTester tester) async {
    final rawFp = await _rawFpFor(components);
    final (pub, licText) = await _issueLicence(rawFp);
    final pubB64 = CoursePackCrypto.encodeBase64(pub);

    await tester.pumpWidget(
      LicenceGateScreen(
        readComponents: () async => components,
        sellerPublicKey: pubB64,
        fileIo: _FakeFileIo(text: licText),
      ),
    );
    await tester.pumpAndSettle();

    // The licence verifies; the "Open course" button should appear.
    expect(find.text('Open course'), findsOneWidget);
  });

  testWidgets('rejects a licence bound to a different device',
      (WidgetTester tester) async {
    final (pub, licText) = await _issueLicence('FFFFFFFFFFFFFFFF');
    final pubB64 = CoursePackCrypto.encodeBase64(pub);

    await tester.pumpWidget(
      LicenceGateScreen(
        readComponents: () async => components,
        sellerPublicKey: pubB64,
        fileIo: _FakeFileIo(text: licText),
      ),
    );
    await tester.pumpAndSettle();

    // Fingerprint mismatch → no "Open course" button, and a rejection shown.
    expect(find.text('Open course'), findsNothing);
    expect(find.textContaining('fingerprint'), findsWidgets);
  });

  testWidgets('rejects a tampered licence', (WidgetTester tester) async {
    final rawFp = await _rawFpFor(components);
    final (pub, licText) = await _issueLicence(rawFp);
    final pubB64 = CoursePackCrypto.encodeBase64(pub);

    // Tamper with the student name after signing.
    final tampered = licText.replaceAll('Ama Mensah', 'Someone Else');

    await tester.pumpWidget(
      LicenceGateScreen(
        readComponents: () async => components,
        sellerPublicKey: pubB64,
        fileIo: _FakeFileIo(text: tampered),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Open course'), findsNothing);
    expect(find.textContaining('modified'), findsWidgets);
  });

  testWidgets('does nothing when the picker is cancelled',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      LicenceGateScreen(
        readComponents: () async => components,
        sellerPublicKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        fileIo: _FakeFileIo(text: null),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open licence (.lic)'));
    await tester.pumpAndSettle();

    expect(find.text('Open course'), findsNothing);
  });
}
