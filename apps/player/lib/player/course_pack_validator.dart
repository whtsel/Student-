import 'dart:io';

import 'package:coursepack_crypto/course_pack_crypto.dart';

/// Outcome of validating a candidate video file as a CoursePack `.enc` file.
class ValidationResult {
  const ValidationResult({
    required this.ok,
    required this.message,
    this.header,
  });

  /// `true` only when the file is a well-formed CoursePack v1 `.enc` file.
  final bool ok;

  /// A human-readable reason, whether the file is accepted or rejected.
  final String message;

  /// The parsed header, present only when [ok] is true.
  final CoursePackHeader? header;

  static const ValidationResult notCoursePack = ValidationResult(
    ok: false,
    message: 'This is not a CoursePack encrypted video. '
        'Only .enc files produced by the CoursePack encrypter can be played.',
  );
}

/// Validates that a file is a CoursePack `.enc` file and returns its header.
///
/// The users app must only play CoursePack encrypted video. This validator
/// is the gate: it reads the 64-byte header, checks the `CRS1` magic, the
/// format version and the chunk-size bounds, and rejects anything else
/// (plain videos, truncated files, other formats) with a clear message.
///
/// It performs no decryption — only structural validation — so it is cheap
/// and safe to run before committing to playback.
class CoursePackValidator {
  CoursePackValidator({CoursePackCrypto? crypto}) : _crypto = crypto ?? CoursePackCrypto();

  final CoursePackCrypto _crypto;

  /// Reads the first [CoursePackCrypto.coursePackHeaderSize] bytes of the file
  /// at [path] and validates them as a CoursePack header.
  ///
  /// Throws [CoursePackError] for any structural problem; callers that want a
  /// soft result can catch it and treat it as a rejection.
  CoursePackHeader validateFile(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw CoursePackError('file not found: $path');
    }
    final raf = file.openSync();
    try {
      final headerBytes = raf.readSync(CoursePackCrypto.coursePackHeaderSize);
      if (headerBytes.length < CoursePackCrypto.coursePackHeaderSize) {
        throw const CoursePackError(
          'file is shorter than a CoursePack header — not a .enc file',
        );
      }
      return _crypto.parseHeader(headerBytes);
    } finally {
      raf.closeSync();
    }
  }

  /// Soft wrapper around [validateFile] that never throws — returns a
  /// [ValidationResult] describing whether the file is a valid CoursePack
  /// `.enc` file. Use this from the UI so a bad pick shows a friendly message
  /// instead of crashing.
  ValidationResult check(String path) {
    try {
      final header = validateFile(path);
      return ValidationResult(
        ok: true,
        message: 'CoursePack video ready (${header.plaintextSize} bytes, '
            'chunk ${header.chunkLog2}).',
        header: header,
      );
    } on CoursePackError catch (e) {
      return ValidationResult(ok: false, message: e.message);
    } on FileSystemException catch (e) {
      return ValidationResult(ok: false, message: e.message);
    } catch (e) {
      return ValidationResult(ok: false, message: 'Could not read file: $e');
    }
  }

  /// Convenience: validate in-memory bytes (used by tests).
  CoursePackHeader validateBytes(List<int> bytes) {
    return _crypto.parseHeader(bytes);
  }
}
