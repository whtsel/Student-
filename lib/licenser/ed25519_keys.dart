import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../crypto/course_pack_crypto.dart';

/// Raised when a signing key cannot be parsed or derived.
class KeyImportException implements Exception {
  const KeyImportException(this.message);

  final String message;

  @override
  String toString() => 'KeyImportException: $message';
}

/// A ready-to-use Ed25519 signing key: the 32-byte seed, the key pair the
/// `cryptography` package derives from it, and the compressed public key.
class SigningKey {
  const SigningKey({
    required this.seed,
    required this.keyPair,
    required this.publicKey,
  });

  final Uint8List seed;
  final SimpleKeyPair keyPair;
  final Uint8List publicKey;

  String get publicKeyBase64 => CoursePackCrypto.encodeBase64(publicKey);

  String get seedHex =>
      seed.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

/// Imports the seller's Ed25519 signing key from the artefacts produced by
/// `tools/make_keys.py`: a PKCS#8 PEM file, or a raw 32-byte seed.
class Ed25519Keys {
  Ed25519Keys._();

  /// Reads a PKCS#8 PEM private key and returns its 32-byte seed.
  static Uint8List seedFromPem(String pem) {
    // Strip the -----BEGIN/END----- wrapper, then the base64 body is all that
    // remains (newlines and whitespace included).
    final body = pem.replaceAll(RegExp(r'-----[^-]*-----'), '');
    final base64 = body.replaceAll(RegExp(r'\s'), '');
    if (base64.isEmpty) {
      throw const KeyImportException(
        'No key data found in the file. Pick a .pem private key.',
      );
    }
    final der = CoursePackCrypto.decodeBase64(base64);
    if (der.length == 32) {
      return Uint8List.fromList(der);
    }
    if (der.length >= 48 && der[0] == 0x30) {
      // PKCS#8 Ed25519: a fixed 48-byte envelope whose tail is the seed.
      return Uint8List.fromList(der.sublist(der.length - 32));
    }
    throw KeyImportException(
      'Unrecognised private key format (${der.length} bytes). '
      'Expected a PKCS#8 PEM or a raw 32-byte seed.',
    );
  }

  /// Parses a raw seed written as base64 or 64 hex characters.
  static Uint8List seedFromText(String text) {
    final trimmed = text.trim();
    if (trimmed.length == 64 && RegExp(r'^[0-9a-fA-F]+$').hasMatch(trimmed)) {
      return Uint8List.fromList(
        List.generate(
          32,
          (index) =>
              int.parse(trimmed.substring(index * 2, index * 2 + 2), radix: 16),
        ),
      );
    }
    try {
      final raw = CoursePackCrypto.decodeBase64(trimmed);
      if (raw.length == 32) {
        return Uint8List.fromList(raw);
      }
    } on CoursePackError {
      // Fall through to the error below.
    }
    throw const KeyImportException(
      'Paste a 32-byte seed as base64 or 64 hex characters.',
    );
  }

  static Future<SigningKey> fromPem(String pem) async =>
      fromSeed(seedFromPem(pem));

  static Future<SigningKey> fromSeedText(String text) async =>
      fromSeed(seedFromText(text));

  static Future<SigningKey> fromSeed(List<int> seed) async {
    if (seed.length != 32) {
      throw const KeyImportException('The seed must be exactly 32 bytes.');
    }
    final keyPair = await Ed25519().newKeyPairFromSeed(seed);
    final publicKey = await keyPair.extractPublicKey();
    return SigningKey(
      seed: Uint8List.fromList(seed),
      keyPair: keyPair,
      publicKey: Uint8List.fromList(publicKey.bytes),
    );
  }
}
