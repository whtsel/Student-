import 'dart:io';

import 'package:coursepack_crypto/course_pack_crypto.dart';
import 'package:coursepack_licence/ed25519_keys.dart';
import 'package:coursepack_encrypter/encrypter.dart';

/// Standalone CoursePack video encrypter CLI — a Dart port of
/// `tools/make_course.py`.
///
/// Encrypts a folder (or single file) of lecture videos into CoursePack
/// `.enc` files, then writes a signed `manifest.json`/`manifest.sig` (safe to
/// upload) and a private `course_keys.json` (never upload).
///
/// Usage:
///   dart run bin/encrypt_video.dart \
///       --input  ~/course/raw \
///       --out    ~/course/dist \
///       --secrets ~/course/secrets \
///       --keydir ~/course/keys \
///       --title  "Statistics 201"
///
/// The signing key is loaded from `<keydir>/ed25519_private.pem` at runtime
/// and held in memory only; only the public key is ever embedded anywhere.
void main(List<String> args) async {
  final parser = _ArgParser();
  final opts = parser.parse(args);

  if (opts.help) {
    _printHelp();
    exit(0);
  }

  try {
    // Load the seller's signing key from the key directory at runtime.
    final pemPath = '${opts.keydir}/ed25519_private.pem';
    final pem = File(pemPath).readAsStringSync();
    final signingKey = await Ed25519Keys.fromPem(pem);

    print('course encryption starting…');
    final result = await CourseEncrypter().encrypt(
      input: opts.input,
      outDir: opts.out,
      secretsDir: opts.secrets,
      title: opts.title,
      signingKey: signingKey,
      chunkLog2: opts.chunkLog2,
      reencode: opts.reencode,
      crf: opts.crf,
      maxHeight: opts.maxHeight,
    );

    final totalPt = result.lectures.fold<int>(
      0,
      (sum, l) => sum + l.plaintextSize,
    );
    final totalCt = result.lectures.fold<int>(0, (sum, l) => sum + l.size);
    print('');
    print('done. ${_human(totalPt.toDouble())} plaintext -> '
        '${_human(totalCt.toDouble())} encrypted');
    print('  ship  : ${result.outDir}/  '
        '(${result.lectures.length} .enc + manifest.json + manifest.sig)');
    print('  secret: ${result.secretsPath}   <-- never upload this');
  } on CoursePackError catch (e) {
    stderr.writeln('error: ${e.message}');
    exit(2);
  } on KeyImportException catch (e) {
    stderr.writeln('error: ${e.message}');
    exit(2);
  } on FileSystemException catch (e) {
    stderr.writeln('error: ${e.message}');
    exit(2);
  } catch (e) {
    stderr.writeln('error: $e');
    exit(1);
  }
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

void _printHelp() {
  stdout.writeln('''CoursePack video encrypter — encrypts lecture videos into .enc files.

Usage:
  dart run bin/encrypt_video.dart --input <path> [options]

Options:
  --input <path>       folder of source videos, or a single video file
  --out <dir>          where .enc + manifest.json + manifest.sig go (default: dist)
  --secrets <dir>      where course_keys.json goes (default: secrets)
  --keydir <dir>       dir holding ed25519_private.pem (default: keys)
  --title <text>       course title (default: My Course)
  --chunk-log2 <n>     log2 of chunk size in bytes (default 20 = 1 MiB)
  --reencode           shrink with ffmpeg before encrypting (needs ffmpeg)
  --crf <n>            x265 CRF for --reencode (default 28)
  --max-height <n>     cap resolution for --reencode (default 1080)
  -h, --help           show this help

Outputs:
  <out>/L01.enc ...          uploaded to Telegram (safe to leak)
  <out>/manifest.json        uploaded to Telegram (safe to leak)
  <out>/manifest.sig         uploaded to Telegram (safe to leak)
  <secrets>/course_keys.json NEVER uploaded. Your keyring for licences.
''');
}

/// Minimal flag parser for the encrypter CLI.
class _ArgParser {
  _ArgParser();

  _EncrypterOpts parse(List<String> args) {
    var i = 0;
    String next() {
      if (i >= args.length) {
        throw ArgumentError('missing value for a flag');
      }
      return args[i++];
    }

    var input = '';
    var out = 'dist';
    var secrets = 'secrets';
    var keydir = 'keys';
    var title = 'My Course';
    var chunkLog2 = defaultChunkLog2;
    var reencode = false;
    var crf = 28;
    var maxHeight = 1080;
    var help = false;

    while (i < args.length) {
      final arg = args[i++];
      switch (arg) {
        case '-h':
        case '--help':
          help = true;
        case '--input':
          input = next();
        case '--out':
          out = next();
        case '--secrets':
          secrets = next();
        case '--keydir':
          keydir = next();
        case '--title':
          title = next();
        case '--chunk-log2':
          chunkLog2 = int.parse(next());
        case '--reencode':
          reencode = true;
        case '--crf':
          crf = int.parse(next());
        case '--max-height':
          maxHeight = int.parse(next());
        default:
          throw ArgumentError('unknown argument: $arg');
      }
    }

    if (!help && input.isEmpty) {
      throw ArgumentError('--input is required');
    }

    return _EncrypterOpts(
      input: input,
      out: out,
      secrets: secrets,
      keydir: keydir,
      title: title,
      chunkLog2: chunkLog2,
      reencode: reencode,
      crf: crf,
      maxHeight: maxHeight,
      help: help,
    );
  }
}

class _EncrypterOpts {
  const _EncrypterOpts({
    required this.input,
    required this.out,
    required this.secrets,
    required this.keydir,
    required this.title,
    required this.chunkLog2,
    required this.reencode,
    required this.crf,
    required this.maxHeight,
    required this.help,
  });

  final String input;
  final String out;
  final String secrets;
  final String keydir;
  final String title;
  final int chunkLog2;
  final bool reencode;
  final int crf;
  final int maxHeight;
  final bool help;
}
