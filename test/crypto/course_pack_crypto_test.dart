import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:coursepack/crypto/course_pack_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final crypto = CoursePackCrypto();
  final key = List<int>.generate(32, (index) => index);
  final nonce = List<int>.generate(16, (index) => index);
  final fileId = List<int>.generate(16, (index) => index + 16);
  final plaintext = List<int>.generate(5000, (index) => index % 251);

  group('Python reference fixture', () {
    late Uint8List fixture;
    late CoursePackHeader header;

    setUpAll(() async {
      fixture = await File('test/fixtures/python_reference.enc').readAsBytes();
      header = crypto.parseHeader(fixture);
    });

    test('Dart encryption matches Python output byte for byte', () async {
      final encoded = await crypto.encryptBytes(
        plaintext: plaintext,
        key: key,
        fileNonce: nonce,
        fileId: fileId,
        chunkLog2: 12,
      );

      expect(encoded, orderedEquals(fixture));
      expect(header.chunkSize, 4096);
      expect(header.chunkCount, 2);
      expect(header.totalCiphertextSize, fixture.length);
    });

    test('decrypts every byte and a cross-chunk range', () async {
      Future<List<int>> readAt(int offset, int length) async =>
          fixture.sublist(offset, offset + length);

      final all = await crypto.decryptRange(
        readAt: readAt,
        header: header,
        key: key,
        start: 0,
        end: plaintext.length,
      );
      expect(all, orderedEquals(plaintext));

      final range = await crypto.decryptRange(
        readAt: readAt,
        header: header,
        key: key,
        start: 4090,
        end: 4110,
      );
      expect(range, orderedEquals(plaintext.sublist(4090, 4110)));
    });

    test('detects modified ciphertext', () async {
      final damaged = Uint8List.fromList(fixture);
      damaged[coursePackHeaderSize + 20] ^= 1;

      await expectLater(
        crypto.decryptChunk(
          readAt: (offset, length) async => damaged.sublist(offset, offset + length),
          header: header,
          key: key,
          index: 0,
        ),
        throwsA(isA<CoursePackError>()),
      );
    });

    test('verifies all tags without returning plaintext', () async {
      await expectLater(
        crypto.verifyFile(
          readAt: (offset, length) async => fixture.sublist(offset, offset + length),
          header: header,
          key: key,
        ),
        completes,
      );
    });
  });

  group('wire-format validation', () {
    test('rejects bad magic, version, chunk size, reserved bytes and short data', () {
      final valid = crypto.buildHeader(
        fileNonce: nonce,
        plaintextSize: 5000,
        fileId: fileId,
        chunkLog2: 12,
      );

      final badMagic = Uint8List.fromList(valid)..[0] = 0;
      expect(() => crypto.parseHeader(badMagic), throwsA(isA<CoursePackError>()));

      final badVersion = Uint8List.fromList(valid)..[4] = 2;
      expect(() => crypto.parseHeader(badVersion), throwsA(isA<CoursePackError>()));

      final badChunkSize = Uint8List.fromList(valid);
      badChunkSize[6] = 0;
      badChunkSize[7] = 2;
      expect(() => crypto.parseHeader(badChunkSize), throwsA(isA<CoursePackError>()));

      final badReserved = Uint8List.fromList(valid)..[63] = 1;
      expect(() => crypto.parseHeader(badReserved), throwsA(isA<CoursePackError>()));
      expect(() => crypto.parseHeader(Uint8List(10)), throwsA(isA<CoursePackError>()));
    });

    test('supports empty files and the normative byte-size formula', () async {
      final encrypted = await crypto.encryptBytes(
        plaintext: const <int>[],
        key: key,
        fileNonce: nonce,
        fileId: fileId,
        chunkLog2: 12,
      );
      final header = crypto.parseHeader(encrypted);
      expect(header.chunkCount, 0);
      expect(header.totalCiphertextSize, coursePackHeaderSize);
      expect(encrypted.length, coursePackHeaderSize);
      expect(
        await crypto.decryptRange(
          readAt: (offset, length) async => encrypted.sublist(offset, offset + length),
          header: header,
          key: key,
          start: 0,
          end: 0,
        ),
        isEmpty,
      );
    });
  });

  group('metadata crypto helpers', () {
    test('canonical JSON sorts keys and preserves non-ASCII text', () {
      expect(
        utf8.decode(CoursePackCrypto.canonicalJsonBytes(<String, Object>{'b': 1, 'a': 'é'})),
        '{"a":"é","b":1}',
      );
    });

    test('verifies the Python Ed25519 reference signature', () async {
      final publicKey = base64.decode('A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=');
      final signature = base64.decode(
        'wMS+z7qogLaesnhdqumuYrUOwNFpE6rdXBQA5JyML5aa7bZgft7Ps6yGwZ3kipSlPED/klIRWuKIixHlShOWCw==',
      );
      final canonical = CoursePackCrypto.canonicalJsonBytes(<String, Object>{'b': 1, 'a': 'é'});

      expect(
        await crypto.verifyEd25519(
          publicKey: publicKey,
          message: canonical,
          signature: signature,
        ),
        isTrue,
      );
      expect(
        await crypto.verifyEd25519(
          publicKey: publicKey,
          message: utf8.encode('tampered'),
          signature: signature,
        ),
        isFalse,
      );
    });

    test('fingerprints normalize, format and hash the specified salt', () async {
      expect(
        CoursePackCrypto.normalizeFingerprint('a1b2-c3d4-e5f6-7788'),
        'A1B2C3D4E5F67788',
      );
      expect(
        CoursePackCrypto.formatFingerprint('A1B2C3D4E5F67788'),
        'A1B2-C3D4-E5F6-7788',
      );
      expect(
        await CoursePackCrypto.computeFingerprint(
          'android:9774d56d682e549c|app-id:com.coursepack.app|cert:3a7f|build:google/sdk_gphone64',
        ),
        'B2669436691BBD69',
      );
      expect(
        () => CoursePackCrypto.normalizeFingerprint('not-a-code'),
        throwsA(isA<CoursePackError>()),
      );
    });
  });
}
