import 'dart:io';
import 'dart:typed_data';

import 'package:coursepack_crypto/course_pack_crypto.dart';
import 'package:coursepack_player/player/course_pack_validator.dart';
import 'package:coursepack_player/player/decrypted_video.dart';
import 'package:flutter_test/flutter_test.dart';

/// Helper: encrypt [plaintext] with [key] and write it to a temp `.enc`
/// file, returning the path.
Future<String> writeEncFile(Uint8List plaintext, Uint8List key) async {
  final crypto = CoursePackCrypto();
  final fileNonce = Uint8List.fromList(List<int>.generate(12, (_) => 0xAB));
  final fileId = Uint8List.fromList(List<int>.generate(8, (_) => 0x12));
  final enc = await crypto.encryptBytes(
    plaintext: plaintext,
    key: key,
    fileNonce: fileNonce,
    fileId: fileId,
  );
  final file = Directory.systemTemp.createTempSync('cp-enc-', extension: '.enc');
  file.writeAsBytesSync(enc);
  return file.path;
}

void main() {
  const plaintext =
      'the quick brown fox jumps over the lazy dog — CoursePack playback test';
  final key = Uint8List.fromList(
    List<int>.generate(32, (int i) => (i * 7 + 3) % 256),
  );

  group('CoursePackValidator', () {
    test('accepts a valid CoursePack .enc file', () async {
      final path = await writeEncFile(
        Uint8List.fromList(plaintext.codeUnits),
        key,
      );
      final result = CoursePackValidator().check(path);
      expect(result.ok, isTrue, reason: result.message);
      expect(result.header, isNotNull);
      expect(result.header!.plaintextSize, plaintext.length);
    });

    test('rejects a plain (non-CoursePack) file', () async {
      final file =
          Directory.systemTemp.createTempSync('cp-plain-', extension: '.txt');
      file.writeAsBytesSync(Uint8List.fromList(plaintext.codeUnits));
      final result = CoursePackValidator().check(file.path);
      expect(result.ok, isFalse);
      expect(result.message, contains('CoursePack'));
    });

    test('rejects a truncated file', () async {
      final path = await writeEncFile(
        Uint8List.fromList(plaintext.codeUnits),
        key,
      );
      final bytes = File(path).readAsBytesSync();
      File(path).writeAsBytesSync(bytes.sublist(0, 10));
      final result = CoursePackValidator().check(path);
      expect(result.ok, isFalse);
    });

    test('rejects a file that is missing entirely', () {
      final result = CoursePackValidator().check('/no/such/file.enc');
      expect(result.ok, isFalse);
    });
  });

  group('DecryptedVideo', () {
    test('decrypts a .enc file back to the original plaintext', () async {
      final encPath = await writeEncFile(
        Uint8List.fromList(plaintext.codeUnits),
        key,
      );

      final result = await DecryptedVideo()
          .decryptToTempFile(encPath, key);

      final decrypted = File(result.tempPath).readAsBytesSync();
      expect(
        String.fromCharCodes(decrypted),
        plaintext,
        reason: 'decrypted plaintext must match the original',
      );

      // Clean up the temp files.
      deleteTempFile(result.tempPath);
      File(encPath).deleteSync();
    });

    test('throws CoursePackError when decrypting with the wrong key',
        () async {
      final encPath = await writeEncFile(
        Uint8List.fromList(plaintext.codeUnits),
        key,
      );
      final wrongKey =
          Uint8List.fromList(List<int>.generate(32, (_) => 0x42));

      expect(
        () => DecryptedVideo().decryptToTempFile(encPath, wrongKey),
        throwsA(isA<CoursePackError>()),
        reason: 'a wrong key must fail GCM tag verification',
      );

      File(encPath).deleteSync();
    });

    test('cleans up the temp file when decryption fails', () async {
      final encPath = await writeEncFile(
        Uint8List.fromList(plaintext.codeUnits),
        key,
      );
      final wrongKey =
          Uint8List.fromList(List<int>.generate(32, (_) => 0x42));
      try {
        await DecryptedVideo().decryptToTempFile(encPath, wrongKey);
        fail('expected decryption to throw');
      } on CoursePackError {
        // expected
      }
      File(encPath).deleteSync();
    });
  });
}
