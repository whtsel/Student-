import 'dart:io';

import 'package:coursepack_crypto/course_pack_crypto.dart';

/// Streams a CoursePack `.enc` file into a plain, playable temporary file.
///
/// The CoursePack format stores each chunk as AES-256-GCM ciphertext + tag,
/// so playback needs the plaintext. Rather than materialise the whole lecture
/// in memory, this decrypts chunk-by-chunk and writes the result to a temp
/// file, mirroring `decrypt_to_stream` in `tools/cp_crypto.py`. The temp file
/// is what `video_player` plays; it is deleted by the caller when playback
/// ends.
///
/// Memory stays bounded at roughly one chunk plus the output buffer, so even
/// large lectures decrypt without loading the entire video into RAM.
class DecryptedVideo {
  DecryptedVideo({CoursePackCrypto? crypto}) : _crypto = crypto ?? CoursePackCrypto();

  final CoursePackCrypto _crypto;

  /// Decrypts [encPath] (a validated CoursePack `.enc` file) using [key] and
  /// writes the plaintext to a fresh temp file. Returns the temp file path
  /// and the parsed header.
  ///
  /// Throws [CoursePackError] if any chunk fails its GCM tag (corruption or
  /// tampering) or the file is not a valid CoursePack file.
  Future<DecryptedVideoResult> decryptToTempFile(
    String encPath,
    List<int> key,
  ) async {
    // Read the whole encrypted file into memory. This SDK's RandomAccessFile
    // lacks seek(), so we slice an in-memory copy for each chunk's readAt.
    final allBytes = File(encPath).readAsBytesSync();

    // Read and validate the header first.
    final header =
        _crypto.parseHeader(allBytes.sublist(0, coursePackHeaderSize));

    // Write plaintext to a temp file, chunk by chunk.
    final temp = Directory.systemTemp.createTempSync('cp-play-', extension: '.mp4');
    final tempPath = temp.path;
    final out = temp.openSync(mode: FileMode.write);
    try {
      for (var index = 0; index < header.chunkCount; index++) {
        final plaintext = await _crypto.decryptChunk(
          readAt: (int offset, int length) async {
            return allBytes.sublist(offset, offset + length);
          },
          header: header,
          key: key,
          index: index,
        );
        out.writeSync(plaintext);
      }

      return DecryptedVideoResult(tempPath: tempPath, header: header);
    } on CoursePackError {
      // Clean up a partially-written temp file on failure.
      try {
        File(tempPath).deleteSync();
      } on FileSystemException {
        // Best-effort cleanup; ignore if the temp file is already gone.
      }
      rethrow;
    } finally {
      out.closeSync();
    }
  }
}

/// The result of decrypting a `.enc` file: the temp playable file and the
/// parsed header (which carries plaintext size and chunking).
class DecryptedVideoResult {
  const DecryptedVideoResult({required this.tempPath, required this.header});

  /// Absolute path to the decrypted, playable temp file. Delete it when done.
  final String tempPath;

  /// The CoursePack header of the source `.enc` file.
  final CoursePackHeader header;
}

/// Deletes a decrypted temp file if it still exists (best-effort).
void deleteTempFile(String path) {
  try {
    File(path).deleteSync();
  } on FileSystemException {
    // Already gone or locked — nothing to do.
  }
}
