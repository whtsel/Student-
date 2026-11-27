import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const int coursePackFormatVersion = 1;
const int coursePackHeaderSize = 64;
const int coursePackTagSize = 16;
const int coursePackKeySize = 32;
const int defaultChunkLog2 = 20;
const int minChunkLog2 = 12;
const int maxChunkLog2 = 24;
const List<int> _magic = <int>[0x43, 0x52, 0x53, 0x31]; // ASCII CRS1

class CoursePackError implements Exception {
  const CoursePackError(this.message);

  final String message;

  @override
  String toString() => 'CoursePackError: $message';
}

/// Parsed, validated 64-byte CoursePack v1 header.
class CoursePackHeader {
  CoursePackHeader({
    required this.version,
    required this.chunkLog2,
    required List<int> fileNonce,
    required this.plaintextSize,
    required List<int> fileId,
  })  : fileNonce = Uint8List.fromList(fileNonce),
        fileId = Uint8List.fromList(fileId);

  final int version;
  final int chunkLog2;
  final Uint8List fileNonce;
  final int plaintextSize;
  final Uint8List fileId;

  int get chunkSize => 1 << chunkLog2;

  int get chunkCount =>
      plaintextSize == 0 ? 0 : (plaintextSize + chunkSize - 1) ~/ chunkSize;

  int get totalCiphertextSize =>
      coursePackHeaderSize + plaintextSize + chunkCount * coursePackTagSize;
}

/// Port of the wire-format and cryptographic helpers in `tools/cp_crypto.py`.
///
/// This class handles ciphertext only. Callers must not materialize an entire
/// lecture as plaintext; use [decryptRange] to decrypt just the requested
/// byte interval from a random-access source.
class CoursePackCrypto {
  CoursePackCrypto({AesGcm? aead}) : _aead = aead ?? AesGcm.with256bits();

  final AesGcm _aead;

  Uint8List buildHeader({
    required List<int> fileNonce,
    required int plaintextSize,
    required List<int> fileId,
    int chunkLog2 = defaultChunkLog2,
  }) {
    if (fileNonce.length != 16) {
      throw const CoursePackError('file_nonce must be 16 bytes');
    }
    if (fileId.length != 16) {
      throw const CoursePackError('file_id must be 16 bytes');
    }
    _validateChunkLog2(chunkLog2);
    if (plaintextSize < 0) {
      throw const CoursePackError('negative plaintext size');
    }

    final header = Uint8List(coursePackHeaderSize);
    header.setRange(0, 4, _magic);
    header[4] = coursePackFormatVersion;
    header[5] = 0;
    final data = ByteData.sublistView(header);
    data.setUint16(6, chunkLog2, Endian.big);
    header.setRange(8, 24, fileNonce);
    data.setUint64(24, plaintextSize, Endian.big);
    header.setRange(32, 48, fileId);
    // Bytes 48..63 are reserved and must stay zero.
    return header;
  }

  CoursePackHeader parseHeader(List<int> bytes) {
    if (bytes.length < coursePackHeaderSize) {
      throw const CoursePackError('file shorter than header');
    }
    for (var i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) {
        throw const CoursePackError('bad magic — not a CoursePack file');
      }
    }
    final version = bytes[4];
    if (version != coursePackFormatVersion) {
      throw CoursePackError('unsupported format version $version');
    }
    final headerBytes = Uint8List.fromList(bytes.take(coursePackHeaderSize).toList());
    final data = ByteData.sublistView(headerBytes);
    final chunkLog2 = data.getUint16(6, Endian.big);
    _validateChunkLog2(chunkLog2);
    if (headerBytes.sublist(48, 64).any((byte) => byte != 0)) {
      throw const CoursePackError('reserved header bytes must be zero');
    }

    return CoursePackHeader(
      version: version,
      chunkLog2: chunkLog2,
      fileNonce: headerBytes.sublist(8, 24),
      plaintextSize: data.getUint64(24, Endian.big),
      fileId: headerBytes.sublist(32, 48),
    );
  }

  Uint8List chunkNonce(List<int> fileNonce, int index) {
    if (fileNonce.length < 8) {
      throw const CoursePackError('file_nonce must contain at least 8 bytes');
    }
    if (index < 0 || index > 0xFFFFFFFF) {
      throw const CoursePackError('chunk index out of range');
    }
    final nonce = Uint8List(12);
    nonce.setRange(0, 8, fileNonce.take(8));
    ByteData.sublistView(nonce).setUint32(8, index, Endian.big);
    return nonce;
  }

  int chunkCiphertextOffset(int index, int chunkSize) {
    if (index < 0 || chunkSize <= 0) {
      throw const CoursePackError('invalid chunk index or size');
    }
    return coursePackHeaderSize + index * (chunkSize + coursePackTagSize);
  }

  int plaintextChunkLength(CoursePackHeader header, int index) {
    if (index < 0 || index >= header.chunkCount) {
      throw const CoursePackError('chunk index out of range');
    }
    if (index == header.chunkCount - 1) {
      return header.plaintextSize - index * header.chunkSize;
    }
    return header.chunkSize;
  }

  /// Encrypt one chunk. The returned bytes are ciphertext followed by its
  /// 16-byte GCM tag, matching Python's `AESGCM.encrypt` output.
  Future<Uint8List> encryptChunk({
    required List<int> plaintext,
    required List<int> key,
    required List<int> fileNonce,
    required int index,
  }) async {
    _validateKey(key);
    final box = await _aead.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: chunkNonce(fileNonce, index),
      aad: const <int>[],
    );
    return Uint8List.fromList(<int>[...box.cipherText, ...box.mac.bytes]);
  }

  /// Encrypt a deterministic in-memory file. Intended for tests and small
  /// metadata payloads; production course encryption remains in Python.
  Future<Uint8List> encryptBytes({
    required List<int> plaintext,
    required List<int> key,
    required List<int> fileNonce,
    required List<int> fileId,
    int chunkLog2 = defaultChunkLog2,
  }) async {
    _validateKey(key);
    final header = buildHeader(
      fileNonce: fileNonce,
      plaintextSize: plaintext.length,
      fileId: fileId,
      chunkLog2: chunkLog2,
    );
    final chunkSize = 1 << chunkLog2;
    final output = BytesBuilder(copy: false)..add(header);
    final count = plaintext.isEmpty ? 0 : (plaintext.length + chunkSize - 1) ~/ chunkSize;
    for (var index = 0; index < count; index++) {
      final start = index * chunkSize;
      final end = math.min(start + chunkSize, plaintext.length);
      output.add(await encryptChunk(
        plaintext: plaintext.sublist(start, end),
        key: key,
        fileNonce: fileNonce,
        index: index,
      ));
    }
    return output.takeBytes();
  }

  Future<Uint8List> decryptChunk({
    required Future<List<int>> Function(int offset, int length) readAt,
    required CoursePackHeader header,
    required List<int> key,
    required int index,
  }) async {
    _validateKey(key);
    final plaintextLength = plaintextChunkLength(header, index);
    final offset = chunkCiphertextOffset(index, header.chunkSize);
    final want = plaintextLength + coursePackTagSize;
    final blob = await readAt(offset, want);
    if (blob.length != want) {
      throw CoursePackError('truncated ciphertext at chunk $index');
    }

    try {
      final cipherEnd = blob.length - coursePackTagSize;
      final box = SecretBox(
        blob.sublist(0, cipherEnd),
        nonce: chunkNonce(header.fileNonce, index),
        mac: Mac(blob.sublist(cipherEnd)),
      );
      return Uint8List.fromList(await _aead.decrypt(box, secretKey: SecretKey(key)));
    } on CoursePackError {
      rethrow;
    } catch (_) {
      throw CoursePackError(
        'integrity failure at chunk $index — file corrupt or tampered',
      );
    }
  }

  /// Decrypt plaintext bytes in [start, end), touching only overlapping chunks.
  Future<Uint8List> decryptRange({
    required Future<List<int>> Function(int offset, int length) readAt,
    required CoursePackHeader header,
    required List<int> key,
    required int start,
    required int end,
  }) async {
    if (start < 0 || end < start || end > header.plaintextSize) {
      throw CoursePackError('bad range [$start, $end)');
    }
    if (start == end) return Uint8List(0);

    final first = start ~/ header.chunkSize;
    final last = (end - 1) ~/ header.chunkSize;
    final output = BytesBuilder(copy: false);
    for (var index = first; index <= last; index++) {
      final plaintext = await decryptChunk(
        readAt: readAt,
        header: header,
        key: key,
        index: index,
      );
      final chunkStart = index * header.chunkSize;
      final low = math.max(start, chunkStart) - chunkStart;
      final high = math.min(end, chunkStart + plaintext.length) - chunkStart;
      output.add(plaintext.sublist(low, high));
    }
    return output.takeBytes();
  }

  /// Verify all GCM tags without retaining the plaintext in memory.
  Future<void> verifyFile({
    required Future<List<int>> Function(int offset, int length) readAt,
    required CoursePackHeader header,
    required List<int> key,
  }) async {
    for (var index = 0; index < header.chunkCount; index++) {
      await decryptChunk(
        readAt: readAt,
        header: header,
        key: key,
        index: index,
      );
    }
  }

  Future<Uint8List> sha256(List<int> bytes) async =>
      Uint8List.fromList((await Sha256().hash(bytes)).bytes);

  Future<bool> verifyEd25519({
    required List<int> publicKey,
    required List<int> message,
    required List<int> signature,
  }) async {
    if (publicKey.length != 32 || signature.length != 64) return false;
    final key = SimplePublicKey(publicKey, type: KeyPairType.ed25519);
    return Ed25519().verify(
      message,
      signature: Signature(signature),
      publicKey: key,
    );
  }

  static Uint8List canonicalJsonBytes(Object? value) =>
      Uint8List.fromList(utf8.encode(jsonEncode(_sortJson(value))));

  static String encodeBase64(List<int> bytes) => base64.encode(bytes);

  static Uint8List decodeBase64(String text) {
    try {
      return Uint8List.fromList(base64.decode(text));
    } on FormatException {
      throw const CoursePackError('invalid base64');
    }
  }

  static String normalizeFingerprint(String text) {
    final cleaned = text.toUpperCase().replaceAll(RegExp('[^0-9A-F]'), '');
    if (cleaned.length < 16) {
      throw CoursePackError(
        'fingerprint must contain at least 16 hex characters, got ${cleaned.length}',
      );
    }
    return cleaned.substring(0, 16);
  }

  static String formatFingerprint(String text) {
    final normalized = normalizeFingerprint(text);
    return '${normalized.substring(0, 4)}-'
        '${normalized.substring(4, 8)}-'
        '${normalized.substring(8, 12)}-'
        '${normalized.substring(12, 16)}';
  }

  static Future<String> computeFingerprint(String platformComponentString) async {
    final prefix = utf8.encode('CoursePack-v1|');
    final components = utf8.encode(platformComponentString);
    final bytes = Uint8List(prefix.length + components.length)
      ..setRange(0, prefix.length, prefix)
      ..setRange(prefix.length, prefix.length + components.length, components);
    final digest = (await Sha256().hash(bytes)).bytes;
    final hex = digest.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
    return hex.substring(0, 16);
  }

  static Object? _sortJson(Object? value) {
    if (value is Map) {
      final keys = value.keys.toList();
      if (keys.any((key) => key is! String)) {
        throw const CoursePackError('canonical JSON object keys must be strings');
      }
      keys.sort((a, b) => (a as String).compareTo(b as String));
      return <String, Object?>{
        for (final key in keys.cast<String>()) key: _sortJson(value[key]),
      };
    }
    if (value is List) return value.map(_sortJson).toList(growable: false);
    if (value == null || value is String || value is num || value is bool) return value;
    throw CoursePackError('unsupported canonical JSON value: ${value.runtimeType}');
  }

  static void _validateChunkLog2(int chunkLog2) {
    if (chunkLog2 < minChunkLog2 || chunkLog2 > maxChunkLog2) {
      throw CoursePackError('chunk_log2 out of range: $chunkLog2');
    }
  }

  static void _validateKey(List<int> key) {
    if (key.length != coursePackKeySize) {
      throw const CoursePackError('content key must be 32 bytes');
    }
  }
}
