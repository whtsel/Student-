import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:coursepack_crypto/course_pack_crypto.dart';
import 'package:coursepack_licence/ed25519_keys.dart';
import 'package:coursepack_licence/licence_model.dart';
import 'package:test/test.dart';

/// The canonical JSON bytes Python produced for the reference licence payload,
/// captured from `tools/make_licence.py`. The Dart canonical encoder must
/// reproduce these bytes exactly or the signature will not match.
const String _expectedCanonicalHex =
    '7b22636f757273655f6964223a2238383739374133453744313644383643222c22636f757273'
    '655f7469746c65223a225374617469737469637320323031222c22657870697265735f6174223a'
    '22323032372d30362d3330222c226670223a2241314232433344344535463637373838222c2269'
    '73737565645f6174223a22323032362d31312d32375430333a31363a33372b30303a3030222c22'
    '6c65637475726573223a5b7b226475726174696f6e5f73223a3831322e352c2266696c65223a22'
    '4c30312e656e63222c226964223a224c3031222c226b6579223a2241514944424155474277674a'
    '4367734d4451345045413d3d222c227469746c65223a2257656c636f6d6520616e6420636f7572'
    '7365206f75746c696e65227d2c7b226475726174696f6e5f73223a313236342e302c2266696c65'
    '223a224c30322e656e63222c226964223a224c3032222c226b6579223a22424155474277674a43'
    '67734d44513450454249534156513d3d222c227469746c65223a22576861742073746174697374'
    '6963732061637475616c6c79206973227d5d2c226c69635f6964223a224c49432d384243394345'
    '222c226e616d65223a22416d61204d656e736168222c2270686f6e65223a223032343030303030'
    '3030222c2276223a317d';

const String _expectedSignature =
    'Qer0t3JV0FpsMTtcWqx2Iz2eaU6yxbKQFz2taWOUPVoKUwF8dj7IS4DDqpPc5GtQlx1'
    '02l5LxjTbzmAmDBoyAw==';

String _readFixtureText(String name) => File('test/fixtures/$name').readAsStringSync();

String _bytesToHex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

Map<String, dynamic> _referenceDoc() =>
    jsonDecode(_readFixtureText('python_reference.lic')) as Map<String, dynamic>;

Map<String, dynamic> _referencePayload() =>
    _referenceDoc()['payload'] as Map<String, dynamic>;

void main() {
  group('Python reference licence (cross-language)', () {
    late SigningKey key;
    late Uint8List publicKey;

    setUpAll(() async {
      final seed = CoursePackCrypto.decodeBase64(
        _readFixtureText('python_reference_seed.b64').trim(),
      );
      key = await Ed25519Keys.fromSeed(seed);
      publicKey = Uint8List.fromList(
        CoursePackCrypto.decodeBase64(
          _readFixtureText('python_reference_pub.b64').trim(),
        ),
      );
    });

    test('public key matches the fixture', () {
      expect(CoursePackCrypto.encodeBase64(key.publicKey),
          _readFixtureText('python_reference_pub.b64').trim());
    });

    test('canonical JSON bytes match Python byte for byte', () {
      final canonical = CoursePackCrypto.canonicalJsonBytes(_referencePayload());
      expect(
        _bytesToHex(canonical),
        _expectedCanonicalHex,
        reason: 'Dart canonical JSON must equal Python canonical_json',
      );
    });

    test('Dart signing reproduces the Python signature exactly', () async {
      final signature = await LicenceGenerator(key: key, course: _dummyCourse())
          .signPayload(_referencePayload());
      expect(signature, _expectedSignature,
          reason: 'Ed25519 is deterministic; Dart must match Python');
    });

    test('Dart verifies the Python signature', () async {
      final crypto = CoursePackCrypto();
      final valid = await crypto.verifyEd25519(
        publicKey: publicKey,
        message: CoursePackCrypto.canonicalJsonBytes(_referencePayload()),
        signature: CoursePackCrypto.decodeBase64(_expectedSignature),
      );
      expect(valid, isTrue);
    });

    test('pretty JSON output is byte-identical to the Python file', () {
      final doc = _referenceDoc();
      expect(toPrettyJson(doc), _readFixtureText('python_reference.lic'));
    });

    test('checker accepts the reference licence', () async {
      final result = await LicenceChecker(publicKey: publicKey)
          .check(_readFixtureText('python_reference.lic'));
      expect(result.ok, isTrue);
      expect(result.studentName, 'Ama Mensah');
      expect(result.licId, 'LIC-8BC9CE');
      expect(result.lectures, hasLength(2));
    });

    test('checker rejects a tampered payload', () async {
      final doc = Map<String, dynamic>.from(_referenceDoc());
      final payload = Map<String, dynamic>.from(_referencePayload());
      payload['name'] = 'Someone Else';
      doc['payload'] = payload;
      final result = await LicenceChecker(publicKey: publicKey)
          .check(jsonEncode(doc));
      expect(result.ok, isFalse);
      expect(result.message, contains('modified'));
    });

    test('checker rejects a licence signed by a different key', () async {
      final otherSeed = CoursePackCrypto.decodeBase64(
        _readFixtureText('python_reference_seed.b64').trim(),
      );
      // Flip one byte to simulate a different key while keeping the shape.
      otherSeed[0] ^= 0x01;
      final other = await Ed25519Keys.fromSeed(otherSeed);
      final result = await LicenceChecker(publicKey: other.publicKey)
          .check(_readFixtureText('python_reference.lic'));
      expect(result.ok, isFalse);
    });

    test('checker flags a device-code mismatch', () async {
      final result = await LicenceChecker(publicKey: publicKey)
          .check(_readFixtureText('python_reference.lic'),
              expectedFp: 'FFFF-FFFF-FFFF-FFFF');
      expect(result.ok, isFalse);
      expect(result.fingerprintMismatch, isTrue);
    });
  });

  group('licence generation', () {
    late SigningKey key;
    late CourseKeys course;

    setUpAll(() async {
      key = await Ed25519Keys.fromSeed(
        List<int>.generate(32, (index) => index),
      );
      course = _dummyCourse();
    });

    test('builds a payload matching make_licence.py', () {
      final payload = LicenceGenerator(key: key, course: course).buildPayload(
        name: 'Ama Mensah',
        fingerprint: 'a1b2-c3d4-e5f6-7788',
        phone: '0240000000',
        expiresAt: '2027-06-30',
      );

      expect(payload['v'], coursePackFormatVersion);
      expect(payload['course_id'], course.courseId);
      expect(payload['course_title'], course.title);
      expect(payload['name'], 'Ama Mensah');
      expect(payload['phone'], '0240000000');
      expect(payload['fp'], 'A1B2C3D4E5F67788');
      expect(payload['expires_at'], '2027-06-30');
      expect(payload['lic_id'], isA<String>());
      expect(payload['lic_id'], startsWith('LIC-'));
      final lectures = payload['lectures'] as List;
      expect(lectures, hasLength(2));
      expect(lectures.first['id'], 'L01');
      expect(lectures.first['duration_s'], 812.5);
    });

    test('omits expiry when none is given', () {
      final payload = LicenceGenerator(key: key, course: course).buildPayload(
        name: 'Kofi',
        fingerprint: 'A1B2C3D4E5F67788',
      );
      expect(payload['expires_at'], isNull);
    });

    test('issues a licence that verifies and writes the expected filename',
        () async {
      final issued = await LicenceGenerator(key: key, course: course).issue(
        name: 'Ama Mensah',
        fingerprint: 'A1B2-C3D4-E5F6-7788',
        phone: '0240000000',
      );
      expect(issued.filename, 'ama-mensah.lic');

      final crypto = CoursePackCrypto();
      final valid = await crypto.verifyEd25519(
        publicKey: key.publicKey,
        message: CoursePackCrypto.canonicalJsonBytes(issued.payload),
        signature: CoursePackCrypto.decodeBase64(issued.signature),
      );
      expect(valid, isTrue);

      final result = await LicenceChecker(publicKey: key.publicKey)
          .check(issued.toJsonText());
      expect(result.ok, isTrue);
    });

    test('selects only the requested lectures', () async {
      final issued = await LicenceGenerator(key: key, course: course).issue(
        name: 'Ama Mensah',
        fingerprint: 'A1B2C3D4E5F67788',
        lectureIds: <String>['L02'],
      );
      final lectures = issued.payload['lectures'] as List;
      expect(lectures, hasLength(1));
      expect(lectures.first['id'], 'L02');
    });

    test('slug matches make_licence.py', () {
      expect(LicenceGenerator.slug('Ama Mensah'), 'ama-mensah');
      expect(LicenceGenerator.slug('  Owusu-Yaw  '), 'owusu-yaw');
      expect(LicenceGenerator.slug('***'), 'student');
    });

    test('rejects a fingerprint that is too short', () {
      expect(
        () => LicenceGenerator(key: key, course: course).buildPayload(
          name: 'Kofi',
          fingerprint: 'xyz',
        ),
        throwsA(isA<CoursePackError>()),
      );
    });
  });

  group('licence checking', () {
    late SigningKey key;

    setUpAll(() async {
      key = await Ed25519Keys.fromSeed(
        List<int>.generate(32, (index) => index + 1),
      );
    });

    Future<LicenceCheckResult> _check(
      Map<String, dynamic> payload, {
      String? expectedFp,
    }) async {
      final text = jsonEncode(<String, Object?>{
        'payload': payload,
        'sig': await LicenceGenerator(key: key, course: _dummyCourse())
            .signPayload(payload),
      });
      return LicenceChecker(publicKey: key.publicKey).check(text,
          expectedFp: expectedFp);
    }

    test('flags an expired licence', () async {
      final result = await _check(
        LicenceGenerator(key: key, course: _dummyCourse()).buildPayload(
          name: 'Kofi',
          fingerprint: 'A1B2C3D4E5F67788',
          expiresAt: '2000-01-01',
        ),
      );
      expect(result.ok, isFalse);
      expect(result.expired, isTrue);
      expect(result.message, contains('expired'));
    });

    test('accepts a non-expiring licence', () async {
      final result = await _check(
        LicenceGenerator(key: key, course: _dummyCourse()).buildPayload(
          name: 'Kofi',
          fingerprint: 'A1B2C3D4E5F67788',
        ),
      );
      expect(result.ok, isTrue);
      expect(result.expiresAt, '');
    });

    test('rejects unreadable JSON', () async {
      final result = await LicenceChecker(publicKey: key.publicKey)
          .check('not json at all');
      expect(result.ok, isFalse);
      expect(result.message, contains('not readable'));
    });

    test('rejects a payload missing the signature', () async {
      final result = await LicenceChecker(publicKey: key.publicKey)
          .check(jsonEncode(<String, Object?>{'payload': <String, Object>{}}));
      expect(result.ok, isFalse);
    });

    test('validates expiry date format', () {
      expect(LicenceChecker.isValidExpiry('2027-06-30'), isTrue);
      expect(LicenceChecker.isValidExpiry('30/06/2027'), isFalse);
      expect(LicenceChecker.isValidExpiry('2027-6-30'), isFalse);
    });
  });

  group('course keys parsing', () {
    test('parses course_keys.json', () {
      final course = CourseKeys.parse(jsonEncode(_dummyCourseJson()));
      expect(course.courseId, '88797A3E7D16D86C');
      expect(course.title, 'Statistics 201');
      expect(course.lectures, hasLength(2));
      expect(course.lectures.first.key, 'AQIDBAUGBwgJCgsMDQ4PEA==');
    });

    test('rejects an unsupported version', () {
      final json = Map<String, dynamic>.from(_dummyCourseJson());
      json['v'] = 2;
      expect(
        () => CourseKeys.fromJson(json),
        throwsA(isA<CoursePackError>()),
      );
    });
  });
}

Map<String, dynamic> _dummyCourseJson() => <String, dynamic>{
      'v': 1,
      'course_id': '88797A3E7D16D86C',
      'title': 'Statistics 201',
      'created_at': '2026-11-26T23:12:10+00:00',
      'lectures': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'L01',
          'title': 'Welcome and course outline',
          'file': 'L01.enc',
          'duration_s': 812.5,
          'key': 'AQIDBAUGBwgJCgsMDQ4PEA==',
        },
        <String, dynamic>{
          'id': 'L02',
          'title': 'What statistics actually is',
          'file': 'L02.enc',
          'duration_s': 1264.0,
          'key': 'BAUGBwgJCgsMDQ4PEBISAVQ==',
        },
      ],
    };

CourseKeys _dummyCourse() => CourseKeys.fromJson(_dummyCourseJson());
