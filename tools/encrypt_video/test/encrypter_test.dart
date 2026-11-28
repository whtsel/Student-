import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:coursepack_crypto/course_pack_crypto.dart';
import 'package:coursepack_licence/ed25519_keys.dart';
import 'package:coursepack_encrypter/encrypter.dart';
import 'package:test/test.dart';

/// A fixed 32-byte seed so the test is deterministic. It is a test-only
/// vector — never a real signing key.
final Uint8List _testSeed =
    Uint8List.fromList(List.generate(32, (i) => (i * 7 + 13) % 256));

void main() {
  group('CourseEncrypter', () {
    late Directory tmp;
    late SigningKey signingKey;

    setUpAll(() async {
      tmp = Directory.systemTemp.createTempSync('cp-enc-test');
      signingKey = await Ed25519Keys.fromSeed(_testSeed);
    });

    tearDownAll() {
      tmp.deleteSync(recursive: true);
    }

    /// Write a small synthetic "video" file (not a real video — just bytes
    /// the encrypter will chunk and encrypt).
    File _writeSource(String name, int size) {
      final path = '${tmp.path}/$name';
      final f = File(path)..createSync();
      final data = List<int>.generate(size, (i) => (i * 31 + 7) % 256);
      f.writeAsBytesSync(data);
      return f;
    }

    test('encrypts a folder of videos and round-trips through the crypto core',
        () async {
      // Two synthetic sources of different sizes to exercise chunking.
      _writeSource('01-intro.mp4', 5000);
      _writeSource('02-lecture.mp4', 12000);

      final outDir = '${tmp.path}/dist';
      final secretsDir = '${tmp.path}/secrets';

      final result = await CourseEncrypter().encrypt(
        input: tmp.path,
        outDir: outDir,
        secretsDir: secretsDir,
        title: 'Test Course',
        signingKey: signingKey,
        chunkLog2: 12, // 4 KiB chunks so both files span multiple chunks
      );

      expect(result.lectures.length, 2);
      expect(result.courseId.length, 16);
      expect(result.lectures[0].id, 'L01');
      expect(result.lectures[1].id, 'L02');
      expect(result.lectures[0].title, 'intro');
      expect(result.lectures[1].title, 'lecture');

      // The manifest and keys files exist.
      expect(File('$outDir/manifest.json').existsSync(), isTrue);
      expect(File('$outDir/manifest.sig').existsSync(), isTrue);
      expect(File('$secretsDir/course_keys.json').existsSync(), isTrue);

      // Each .enc file must decrypt back to its original plaintext.
      for (final lecture in result.lectures) {
        final encPath = '$outDir/${lecture.file}';
        final key = CoursePackCrypto.decodeBase64(lecture.contentKeyBase64);
        expect(key.length, coursePackKeySize);

        final encFile = File(encPath);
        final headerBytes = encFile.openSync().readSync(coursePackHeaderSize);
        final header = CoursePackCrypto().parseHeader(headerBytes);
        expect(header.plaintextSize, lecture.plaintextSize);
        expect(header.chunkLog2, 12);

        // Decrypt the whole file chunk-by-chunk and compare to the source.
        final readAt = (int offset, int length) async {
          final raf = encFile.openSync();
          raf.seek(offset);
          final bytes = raf.readSync(length);
          raf.closeSync();
          return bytes;
        };
        final plaintext = await CoursePackCrypto().decryptRange(
          readAt: readAt,
          header: header,
          key: key,
          start: 0,
          end: header.plaintextSize,
        );

        final sourceName = lecture.file == 'L01.enc' ? '01-intro.mp4' : '02-lecture.mp4';
        final original = File('${tmp.path}/$sourceName').readAsBytesSync();
        expect(plaintext, original);
      }
    });

    test('manifest is signed and the signature verifies against the public key',
        () async {
      _writeSource('01-only.mp4', 3000);
      final outDir = '${tmp.path}/dist2';
      final secretsDir = '${tmp.path}/secrets2';

      final result = await CourseEncrypter().encrypt(
        input: '${tmp.path}/01-only.mp4',
        outDir: outDir,
        secretsDir: secretsDir,
        title: 'Signed Course',
        signingKey: signingKey,
        chunkLog2: 12,
      );

      final manifestJson = File('$outDir/manifest.json').readAsStringSync();
      final manifest = jsonDecode(manifestJson) as Map<String, dynamic>;
      expect(manifest['v'], coursePackFormatVersion);
      expect(manifest['course_id'], result.courseId);
      expect(manifest['title'], 'Signed Course');
      expect(manifest['lectures'], isA<List>());

      // The stored signature must verify over the canonical JSON manifest.
      final sigB64 = File('$outDir/manifest.sig').readAsStringSync().trim();
      final canonical = CoursePackCrypto.canonicalJsonBytes(manifest);
      final ok = await CoursePackCrypto().verifyEd25519(
        publicKey: signingKey.publicKey,
        message: canonical,
        signature: CoursePackCrypto.decodeBase64(sigB64),
      );
      expect(ok, isTrue);

      // The keys file must carry a per-lecture content key, not the signing key.
      final keysJson = File('$secretsDir/course_keys.json').readAsStringSync();
      final keys = jsonDecode(keysJson) as Map<String, dynamic>;
      expect(keys['course_id'], result.courseId);
      final keyLectures = keys['lectures'] as List;
      expect(keyLectures.length, 1);
      final entry = keyLectures.first as Map<String, dynamic>;
      expect(entry['key'], isA<String>());
      expect(CoursePackCrypto.decodeBase64(entry['key'] as String).length,
          coursePackKeySize);
    });

    test('rejects a non-existent input path', () async {
      expect(
        () => CourseEncrypter().encrypt(
          input: '${tmp.path}/does-not-exist',
          outDir: '${tmp.path}/dist3',
          secretsDir: '${tmp.path}/secrets3',
          title: 'x',
          signingKey: signingKey,
        ),
        throwsA(isA<CoursePackError>()),
      );
    });
  });
}
