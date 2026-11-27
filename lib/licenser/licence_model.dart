import 'dart:convert';
import 'dart:math' as math;

import 'package:cryptography/cryptography.dart';

import '../crypto/course_pack_crypto.dart';
import 'ed25519_keys.dart';

/// One entry of `course_keys.json` — a lecture plus its content key.
class CourseKeyEntry {
  const CourseKeyEntry({
    required this.id,
    required this.title,
    required this.file,
    required this.key,
    this.durationS,
  });

  final String id;
  final String title;
  final String file;
  final String key;
  final double? durationS;

  factory CourseKeyEntry.fromJson(Map<String, dynamic> json) => CourseKeyEntry(
        id: json['id'] as String,
        title: json['title'] as String,
        file: json['file'] as String,
        key: json['key'] as String,
        durationS: (json['duration_s'] as num?)?.toDouble(),
      );
}

/// The parsed contents of `course_keys.json` (the seller's keyring).
class CourseKeys {
  const CourseKeys({
    required this.version,
    required this.courseId,
    required this.title,
    required this.createdAt,
    required this.lectures,
  });

  final int version;
  final String courseId;
  final String title;
  final String createdAt;
  final List<CourseKeyEntry> lectures;

  factory CourseKeys.fromJson(Map<String, dynamic> json) {
    final version = json['v'];
    if (version != coursePackFormatVersion) {
      throw CoursePackError(
        'course_keys.json has unsupported version $version.',
      );
    }
    return CourseKeys(
      version: version as int,
      courseId: json['course_id'] as String,
      title: json['title'] as String,
      createdAt: json['created_at'] as String? ?? '',
      lectures: (json['lectures'] as List)
          .map((entry) => CourseKeyEntry.fromJson(entry as Map<String, dynamic>))
          .toList(growable: false),
    );
  }

  factory CourseKeys.parse(String text) =>
      CourseKeys.fromJson(jsonDecode(text) as Map<String, dynamic>);
}

/// A generated, signed licence ready to be written to a `.lic` file.
class IssuedLicence {
  const IssuedLicence({
    required this.payload,
    required this.signature,
    required this.filename,
  });

  final Map<String, dynamic> payload;
  final String signature;
  final String filename;

  /// Serialise exactly like `tools/make_licence.py`: `{"payload": …, "sig": …}`
  /// with two-space indentation and non-ASCII characters left unescaped.
  String toJsonText() =>
      toPrettyJson(<String, Object?>{'payload': payload, 'sig': signature});
}

/// Builds and signs device-bound licences — the Android equivalent of
/// `tools/make_licence.py`.
class LicenceGenerator {
  LicenceGenerator({required this.key, required this.course});

  final SigningKey key;
  final CourseKeys course;

  /// Filename slug, matching `make_licence.py`'s `slug()`.
  static String slug(String name) {
    final slug = name.toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceFirst(RegExp(r'^-+'), '')
        .replaceFirst(RegExp(r'-+$'), '');
    return slug.isEmpty ? 'student' : slug;
  }

  static String _newLicId() {
    final rng = math.Random.secure();
    final hex = List<int>.generate(3, (_) => rng.nextInt(256))
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    return 'LIC-$hex';
  }

  /// Builds the canonical payload, matching `make_licence.py` field for field.
  Map<String, dynamic> buildPayload({
    required String name,
    required String fingerprint,
    String phone = '',
    String expiresAt = '',
    String licId = '',
    List<String> lectureIds = const <String>[],
  }) {
    final chosen = lectureIds.isEmpty
        ? course.lectures.map((entry) => entry.id).toList()
        : lectureIds;
    final lectures = course.lectures
        .where((entry) => chosen.contains(entry.id))
        .map((entry) => <String, Object?>{
              'id': entry.id,
              'title': entry.title,
              'file': entry.file,
              'duration_s': entry.durationS,
              'key': entry.key,
            })
        .toList(growable: false);

    return <String, Object?>{
      'v': coursePackFormatVersion,
      'course_id': course.courseId,
      'course_title': course.title,
      'lic_id': licId.trim().isEmpty ? _newLicId() : licId.trim(),
      'name': name.trim(),
      'phone': phone.trim(),
      'fp': CoursePackCrypto.normalizeFingerprint(fingerprint),
      'issued_at': _nowIso(),
      'expires_at': expiresAt.trim().isEmpty ? null : expiresAt.trim(),
      'lectures': lectures,
    };
  }

  /// Signs a payload with the seller's private key. Ed25519 is deterministic,
  /// so this produces the same signature bytes as the Python toolchain.
  Future<String> signPayload(Map<String, dynamic> payload) async {
    final canonical = CoursePackCrypto.canonicalJsonBytes(payload);
    final signature = await Ed25519().sign(canonical, keyPair: key.keyPair);
    return CoursePackCrypto.encodeBase64(signature.bytes);
  }

  /// Builds, signs and wraps a licence for writing to disk.
  Future<IssuedLicence> issue({
    required String name,
    required String fingerprint,
    String phone = '',
    String expiresAt = '',
    String licId = '',
    List<String> lectureIds = const <String>[],
  }) async {
    final payload = buildPayload(
      name: name,
      fingerprint: fingerprint,
      phone: phone,
      expiresAt: expiresAt,
      licId: licId,
      lectureIds: lectureIds,
    );
    final signature = await signPayload(payload);
    return IssuedLicence(
      payload: payload,
      signature: signature,
      filename: '${slug(name)}.lic',
    );
  }

  static String _nowIso() {
    final now = DateTime.now().toUtc();
    final pad = (int value) => value.toString().padLeft(2, '0');
    return '${now.year.toString().padLeft(4, '0')}-${pad(now.month)}-${pad(now.day)}'
        'T${pad(now.hour)}:${pad(now.minute)}:${pad(now.second)}+00:00';
  }
}

/// Outcome of checking a `.lic` file, mirroring `tools/verify_licence.py`.
class LicenceCheckResult {
  const LicenceCheckResult({
    required this.ok,
    required this.message,
    this.payload,
    this.signature,
    this.expired,
    this.fingerprintMismatch,
  });

  final bool ok;
  final String message;
  final Map<String, dynamic>? payload;
  final String? signature;
  final bool? expired;
  final bool? fingerprintMismatch;

  String get studentName => payload?['name'] as String? ?? '';
  String get licId => payload?['lic_id'] as String? ?? '';
  String get courseTitle => payload?['course_title'] as String? ?? '';
  String get courseId => payload?['course_id'] as String? ?? '';
  String get fingerprint =>
      payload?['fp'] as String? ?? '';
  String get issuedAt => payload?['issued_at'] as String? ?? '';
  String get expiresAt => payload?['expires_at'] as String? ?? '';
  List<Map<String, dynamic>> get lectures =>
      (payload?['lectures'] as List?)?.cast<Map<String, dynamic>>() ??
      const <Map<String, dynamic>>[];
}

/// Verifies a `.lic` file against a public key, checking signature, expiry
/// and (optionally) device binding.
class LicenceChecker {
  LicenceChecker({required this.publicKey});

  final Uint8List publicKey;
  final CoursePackCrypto _crypto = CoursePackCrypto();

  Future<LicenceCheckResult> check(String text, {String? expectedFp}) async {
    final Map<String, dynamic> doc;
    try {
      doc = jsonDecode(text) as Map<String, dynamic>;
    } on FormatException {
      return const LicenceCheckResult(
        ok: false,
        message: 'Licence file is not readable.',
      );
    }

    final payload = doc['payload'];
    final signature = doc['sig'];
    if (payload is! Map || signature is! String) {
      return const LicenceCheckResult(
        ok: false,
        message: 'Licence file is not readable.',
      );
    }

    final payloadMap = (payload as Map).cast<String, dynamic>();
    final Uint8List sigBytes;
    try {
      sigBytes = CoursePackCrypto.decodeBase64(signature);
    } on CoursePackError {
      return LicenceCheckResult(
        ok: false,
        message: 'This licence file has been modified and is not valid.',
      );
    }

    final canonical = CoursePackCrypto.canonicalJsonBytes(payloadMap);
    final valid = await _crypto.verifyEd25519(
      publicKey: publicKey,
      message: canonical,
      signature: sigBytes,
    );
    if (!valid) {
      return LicenceCheckResult(
        ok: false,
        message: 'This licence file has been modified and is not valid.',
      );
    }

    bool? expired;
    final expiresAt = payloadMap['expires_at'];
    if (expiresAt is String && expiresAt.isNotEmpty) {
      final expiry = _parseDate(expiresAt);
      if (expiry != null && _isAfter(DateTime.now(), expiry)) {
        expired = true;
      }
    }

    bool? fingerprintMismatch;
    if (expectedFp != null && expectedFp.trim().isNotEmpty) {
      try {
        final want = CoursePackCrypto.normalizeFingerprint(expectedFp);
        final have = CoursePackCrypto.normalizeFingerprint(
          payloadMap['fp'] as String,
        );
        fingerprintMismatch = want != have;
      } on CoursePackError {
        fingerprintMismatch = true;
      }
    }

    if (expired == true) {
      return LicenceCheckResult(
        ok: false,
        message: 'This licence expired on $expiresAt.',
        payload: payloadMap,
        signature: signature,
        expired: true,
        fingerprintMismatch: fingerprintMismatch,
      );
    }
    if (fingerprintMismatch == true) {
      return LicenceCheckResult(
        ok: false,
        message: 'This licence was issued to a different device.',
        payload: payloadMap,
        signature: signature,
        expired: expired,
        fingerprintMismatch: true,
      );
    }
    return LicenceCheckResult(
      ok: true,
      message: 'Licence is valid.',
      payload: payloadMap,
      signature: signature,
      expired: expired,
      fingerprintMismatch: fingerprintMismatch,
    );
  }

  static DateTime? _parseDate(String text) {
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(text);
    if (match == null) return null;
    return DateTime.utc(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }

  /// True when [text] is a valid `YYYY-MM-DD` date.
  static bool isValidExpiry(String text) => _parseDate(text) != null;

  /// Date-only comparison, matching Python's `date.today() > end`.
  static bool _isAfter(DateTime now, DateTime date) {
    if (now.year != date.year) return now.year > date.year;
    if (now.month != date.month) return now.month > date.month;
    return now.day > date.day;
  }
}

/// Serialise JSON the way Python's `json.dumps(indent=2, ensure_ascii=False)`
/// does: two-space indentation, `": "` separators, and only the characters
/// Python escapes by default are escaped.
String toPrettyJson(Object? value) {
  final buffer = StringBuffer();
  _writePretty(buffer, value, 0);
  return buffer.toString();
}

void _writePretty(StringBuffer buffer, Object? value, int depth) {
  if (value is Map) {
    if (value.isEmpty) {
      buffer.write('{}');
      return;
    }
    buffer.write('{');
    var first = true;
    for (final entry in value.entries) {
      if (!first) buffer.write(',');
      first = false;
      buffer.write('\n');
      _writeIndent(buffer, depth + 1);
      buffer.write(_escapeString(entry.key.toString()));
      buffer.write(': ');
      _writePretty(buffer, entry.value, depth + 1);
    }
    buffer.write('\n');
    _writeIndent(buffer, depth);
    buffer.write('}');
  } else if (value is List) {
    if (value.isEmpty) {
      buffer.write('[]');
      return;
    }
    buffer.write('[');
    var first = true;
    for (final item in value) {
      if (!first) buffer.write(',');
      first = false;
      buffer.write('\n');
      _writeIndent(buffer, depth + 1);
      _writePretty(buffer, item, depth + 1);
    }
    buffer.write('\n');
    _writeIndent(buffer, depth);
    buffer.write(']');
  } else {
    buffer.write(_escapeScalar(value));
  }
}

void _writeIndent(StringBuffer buffer, int depth) {
  for (var i = 0; i < depth; i++) {
    buffer.write('  ');
  }
}

String _escapeScalar(Object? value) {
  switch (value) {
    case null:
      return 'null';
    case bool b:
      return b ? 'true' : 'false';
    case int i:
      return i.toString();
    case double d:
      return d.toString();
    case String s:
      return _escapeString(s);
    default:
      throw ArgumentError('Cannot serialise ${value.runtimeType} to JSON.');
  }
}

const Map<int, String> _shortEscapes = <int, String>{
  0x22: '\\"',
  0x5C: '\\\\',
  0x08: '\\b',
  0x0C: '\\f',
  0x0A: '\\n',
  0x0D: '\\r',
  0x09: '\\t',
};

String _escapeString(String value) {
  final buffer = StringBuffer();
  for (final char in value.codeUnits) {
    final escaped = _shortEscapes[char];
    if (escaped != null) {
      buffer.write(escaped);
    } else if (char < 0x20) {
      buffer.write('\\u${char.toRadixString(16).padLeft(4, '0')}');
    } else {
      buffer.write(char);
    }
  }
  return buffer.toString();
}
