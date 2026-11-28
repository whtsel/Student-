import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:coursepack_crypto/course_pack_crypto.dart';
import 'package:coursepack_licence/ed25519_keys.dart';
import 'package:cryptography/cryptography.dart';

/// Video extensions the encrypter will pick up from an input folder, matching
/// `tools/make_course.py`.
const Set<String> _videoExts = <String>{
  '.mp4', '.mkv', '.mov', '.m4v', '.webm', '.avi', '.ts', '.mts',
};

/// Keep clear of Telegram's 2 GB-per-document cap (mirrors make_course.py).
const int _telegramWarnBytes = 1900 * 1024 * 1024;

/// Result of encrypting one source file into a `.enc` file.
class EncryptedLecture {
  EncryptedLecture({
    required this.id,
    required this.title,
    required this.file,
    required this.durationSeconds,
    required this.size,
    required this.plaintextSize,
    required this.chunkLog2,
    required this.sha256,
    required this.contentKeyBase64,
  });

  final String id;
  final String title;
  final String file;
  final double? durationSeconds;
  final int size;
  final int plaintextSize;
  final int chunkLog2;
  final String sha256;
  final String contentKeyBase64;

  /// The manifest entry (safe to upload — carries no keys).
  Map<String, Object?> toManifestEntry() => <String, Object?>{
        'id': id,
        'title': title,
        'duration_s': durationSeconds,
        'file': file,
        'size': size,
        'plaintext_size': plaintextSize,
        'chunk_log2': chunkLog2,
        'sha256': sha256,
      };

  /// The keys-file entry (NEVER uploaded — carries the content key).
  Map<String, Object?> toKeysEntry() => <String, Object?>{
        'id': id,
        'title': title,
        'file': file,
        'duration_s': durationSeconds,
        'key': contentKeyBase64,
      };
}

/// Outcome of a full course encryption run.
class EncryptRunResult {
  const EncryptRunResult({
    required this.courseId,
    required this.title,
    required this.createdAt,
    required this.lectures,
    required this.manifestSignature,
    required this.outDir,
    required this.secretsPath,
  });

  final String courseId;
  final String title;
  final String createdAt;
  final List<EncryptedLecture> lectures;
  final String manifestSignature;
  final String outDir;
  final String secretsPath;
}

/// Standalone CoursePack video encrypter — a Dart port of
/// `tools/make_course.py`. Encrypts a folder (or single file) of lecture
/// videos into CoursePack `.enc` files, writes a signed `manifest.json` and
/// a private `course_keys.json`.
///
/// The wire format, manifest structure and signing are byte-compatible with
/// the Python reference because both use the shared [CoursePackCrypto] core
/// and the same canonical-JSON + Ed25519 signing scheme.
class CourseEncrypter {
  CourseEncrypter({CoursePackCrypto? crypto, Random? random})
      : _crypto = crypto ?? CoursePackCrypto(),
        _random = random ?? Random.secure();

  final CoursePackCrypto _crypto;
  final Random _random;

  Uint8List _randomBytes(int length) {
    final out = Uint8List(length);
    _random.nextBytes(out);
    return out;
  }

  /// Natural sort key so `L02` sorts before `L10` (mirrors make_course.py).
  List<Object> _naturalKey(String name) {
    return <Object>[
      for (final part in RegExp(r'(\d+)').split(name))
        part.isNotEmpty && part.contains(RegExp(r'^\d+$'))
            ? int.parse(part)
            : part.toLowerCase(),
    ];
  }

  /// Strip a leading lecture-number prefix (`01-`, `01_`, `01.`, `01)`, …)
  /// from a filename stem to produce a human title (mirrors make_course.py).
  String _labelFromStem(String stem) {
    final stripped = RegExp(r'^[0-9]+[-_. )]*').replaceAll(stem, '');
    return stripped.isEmpty ? stem : stripped;
  }

  String _human(double n) {
    var value = n;
    for (final unit in <String>['B', 'KB', 'MB', 'GB', 'TB']) {
      if (value.abs() < 1024 || unit == 'TB') {
        return unit == 'B' ? '${value.toInt()} B' : '${value.toStringAsFixed(1)} $unit';
      }
      value /= 1024;
    }
    return '${value.toStringAsFixed(1)} TB';
  }

  /// Probe a video's duration in seconds using `ffprobe`. Returns `null` when
  /// ffprobe is unavailable or the probe fails (mirrors make_course.py).
  Future<double?> _probeDuration(String path) async {
    try {
      final result = await Process.run(
        'ffprobe',
        <String>[
          '-v', 'error',
          '-show_entries', 'format=duration',
          '-of', 'default=nw=1:nk=1',
          path,
        ],
        runSync: false,
      );
      if (result.exitCode != 0) return null;
      return double.tryParse(result.stdout.trim())?.roundTo(2);
    } on ProcessException {
      return null;
    }
  }

  /// Optional pre-encryption re-encode via `ffmpeg` (mirrors make_course.py).
  /// Raises [CoursePackError] when ffmpeg is not on PATH.
  Future<String> _reencode(String src, String tmpDir, int crf, int maxHeight) async {
    final dst = '$tmpDir/re.mp4';
    final scale = "scale=-2:'min($maxHeight,ih)'";
    final cmd = <String>[
      'ffmpeg', '-y', '-v', 'error', '-i', src,
      '-vf', scale,
      '-c:v', 'libx265', '-crf', '$crf', '-preset', 'medium',
      '-tag:v', 'hvc1',
      '-c:a', 'aac', '-b:a', '96k', '-ac', '2',
      '-movflags', '+faststart',
      dst,
    ];
    try {
      await Process.run(cmd[0], cmd.sublist(1), runSync: false);
    } on ProcessException {
      throw const CoursePackError('--reencode needs ffmpeg on PATH');
    }
    return dst;
  }

  /// Encrypt one source file into a `.enc` file using the shared crypto core.
  ///
  /// Streams the source in fixed-size chunks so memory use stays bounded even
  /// for large videos, mirroring Python's `encrypt_stream`.
  Future<_EncryptedFile> _encryptFile(
    String src,
    String encPath,
    List<int> key,
    int chunkLog2,
  ) async {
    final fileNonce = _randomBytes(16);
    final fileId = _randomBytes(16);

    final source = File(src);
    final plaintextSize = source.lengthSync();

    final header = _crypto.buildHeader(
      fileNonce: fileNonce,
      plaintextSize: plaintextSize,
      fileId: fileId,
      chunkLog2: chunkLog2,
    );

    final out = File(encPath)..createSync();
    final outRaf = out.openSync();
    try {
      outRaf.writeSync(header);

      final chunkSize = 1 << chunkLog2;
      final chunkCount =
          plaintextSize == 0 ? 0 : (plaintextSize + chunkSize - 1) ~/ chunkSize;

      final sourceRaf = source.openSync();
      try {
        for (var index = 0; index < chunkCount; index++) {
          final block = sourceRaf.readSync(chunkSize);
          if (block.isEmpty) {
            throw const CoursePackError('source truncated while reading');
          }
          final encrypted = await _crypto.encryptChunk(
            plaintext: block,
            key: key,
            fileNonce: fileNonce,
            index: index,
          );
          outRaf.writeSync(encrypted);
        }
      } finally {
        sourceRaf.closeSync();
      }
    } finally {
      outRaf.closeSync();
    }

    final encSize = out.lengthSync();

    // Hash the .enc file, then re-read and validate its header (a sanity
    // check that the header we wrote parses back cleanly).
    final sha = await _crypto.sha256(File(encPath).readAsBytesSync());
    final raf = File(encPath).openSync();
    try {
      _crypto.parseHeader(raf.readSync(coursePackHeaderSize));
    } finally {
      raf.closeSync();
    }

    return _EncryptedFile(
      encSize: encSize,
      plaintextSize: plaintextSize,
      sha256: sha.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
    );
  }

  /// Encrypt a folder (or single file) of lecture videos into CoursePack
  /// `.enc` files and write the signed manifest + private keys file.
  ///
  /// [input] may be a directory of videos or a single video file. [outDir]
  /// receives the `.enc` files plus `manifest.json`/`manifest.sig`;
  /// [secretsDir] receives the private `course_keys.json`.
  Future<EncryptRunResult> encrypt({
    required String input,
    required String outDir,
    required String secretsDir,
    required String title,
    required SigningKey signingKey,
    int chunkLog2 = defaultChunkLog2,
    bool reencode = false,
    int crf = 28,
    int maxHeight = 1080,
  }) async {
    // ---- collect inputs --------------------------------------------------
    final files = <String>;
    if (Directory(input).existsSync()) {
      final dir = Directory(input);
      files.addAll(dir
          .listSync()
          .whereType<File>()
          .map((f) => f.path)
          .where((p) =>
              _videoExts.contains(p.toLowerCase().substring(p.lastIndexOf('.'))))
          .toList()
          ..sort((a, b) => _naturalKey(a).compareTo(_naturalKey(b))));
    } else if (File(input).existsSync()) {
      files.add(input);
    } else {
      throw CoursePackError('no such path: $input');
    }

    if (files.isEmpty) {
      throw CoursePackError(
        'no video files found in $input (looked for: '
        '${_videoExts.join(', ')})',
      );
    }

    Directory(outDir).createSync(recursive: true);
    Directory(secretsDir).createSync(recursive: true);

    final courseId = _randomBytes(8)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    final createdAt = _nowIso();

    final manifestLectures = <Map<String, Object?>>[];
    final keyLectures = <Map<String, Object?>>[];
    final lectures = <EncryptedLecture>[];
    final warnings = <String>[];
    var totalPlaintext = 0;
    var totalCiphertext = 0;

    for (var idx = 1; idx <= files.length; idx++) {
      final src = files[idx - 1];
      final lid = 'L${idx.toString().padLeft(2, '0')}';
      final base = src.substring(src.lastIndexOf('/') + 1);
      final stem = base.substring(0, base.lastIndexOf('.'));
      final label = _labelFromStem(stem);
      final encPath = '$outDir/$lid.enc';

      print('  $lid  $stem  (${_human(File(src).lengthSync().toDouble())})');

      String toEncrypt = src;
      String? workDir;
      try {
        if (reencode) {
          workDir = Directory.systemTemp.createTempSync('cp-').path;
          toEncrypt = await _reencode(src, workDir, crf, maxHeight);
          print('    re-encoded -> ${_human(File(toEncrypt).lengthSync().toDouble())}');
        }

        final key = _randomBytes(coursePackKeySize);
        final duration = await _probeDuration(toEncrypt);

        final encrypted = await _encryptFile(toEncrypt, encPath, key, chunkLog2);

        if (encrypted.encSize > _telegramWarnBytes) {
          warnings.add(
            '$lid is ${_human(encrypted.encSize.toDouble())} — over '
            'Telegram\'s 2 GB per-file cap. Split it or re-run with --reencode.',
          );
        }

        final lecture = EncryptedLecture(
          id: lid,
          title: label,
          file: '$lid.enc',
          durationSeconds: duration,
          size: encrypted.encSize,
          plaintextSize: encrypted.plaintextSize,
          chunkLog2: chunkLog2,
          sha256: encrypted.sha256,
          contentKeyBase64: CoursePackCrypto.encodeBase64(key),
        );
        lectures.add(lecture);
        manifestLectures.add(lecture.toManifestEntry());
        keyLectures.add(lecture.toKeysEntry());
        totalPlaintext += encrypted.plaintextSize;
        totalCiphertext += encrypted.encSize;
        print('       -> ${_human(encrypted.encSize.toDouble())}  '
            'sha256 ${encrypted.sha256.substring(0, 16)}…');
      } finally {
        if (workDir != null) {
          Directory(workDir).deleteSync(recursive: true);
        }
      }
    }

    final manifest = <String, Object?>{
      'v': coursePackFormatVersion,
      'course_id': courseId,
      'title': title,
      'created_at': createdAt,
      'lectures': manifestLectures,
    };

    // Sign the canonical JSON manifest with the seller's Ed25519 key.
    final canonical = CoursePackCrypto.canonicalJsonBytes(manifest);
    final signature = await Ed25519().sign(canonical, keyPair: signingKey.keyPair);
    final manifestSignature = CoursePackCrypto.encodeBase64(signature.bytes);

    File('$outDir/manifest.json')
      ..writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(manifest),
      );
    File('$outDir/manifest.sig').writeAsStringSync('$manifestSignature\n');

    final keysPayload = <String, Object?>{
      'v': coursePackFormatVersion,
      'course_id': courseId,
      'title': title,
      'created_at': createdAt,
      'lectures': keyLectures,
    };
    final keysPath = '$secretsDir/course_keys.json';
    File(keysPath).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(keysPayload),
    );

    for (final w in warnings) {
      print('  WARNING: $w');
    }

    return EncryptRunResult(
      courseId: courseId,
      title: title,
      createdAt: createdAt,
      lectures: lectures,
      manifestSignature: manifestSignature,
      outDir: outDir,
      secretsPath: keysPath,
    );
  }

  static String _nowIso() {
    final now = DateTime.now().toUtc();
    final pad = (int v) => v.toString().padLeft(2, '0');
    return '${now.year.toString().padLeft(4, '0')}-${pad(now.month)}-${pad(now.day)}'
        'T${pad(now.hour)}:${pad(now.minute)}:${pad(now.second)}+00:00';
  }
}

class _EncryptedFile {
  const _EncryptedFile({
    required this.encSize,
    required this.plaintextSize,
    required this.sha256,
  });

  final int encSize;
  final int plaintextSize;
  final String sha256;
}

extension on double {
  double roundTo(int digits) {
    final factor = pow(10, digits).toDouble();
    return (this * factor).round() / factor;
  }
}
