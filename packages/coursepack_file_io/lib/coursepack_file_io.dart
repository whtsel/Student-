import 'package:flutter/services.dart';

/// Abstraction over the system file picker / saver so the licence generator
/// screen can be driven by a fake in tests.
abstract class FileIo {
  /// Opens the system "open" picker and returns the full text of the chosen
  /// file, or `null` if the user cancelled or the file could not be read.
  Future<String?> pickTextFile();

  /// Opens the system "create document" picker, writes [text] to the chosen
  /// location and returns the resulting URI as a string, or `null` if the
  /// user cancelled or the write failed.
  Future<String?> saveTextFile({
    required String filename,
    required String text,
  });

  /// Opens the system "open" picker for a binary file and returns a real
  /// filesystem path (a copy of the picked content placed in app cache), or
  /// `null` if the user cancelled or the read failed.
  ///
  /// Unlike [pickTextFile], which returns file *content* as text, this is for
  /// binary files (e.g. a CoursePack `.enc` video) that must be read with
  /// random access and therefore need a path, not a text blob.
  Future<String?> pickFilePath();
}

/// [FileIo] backed by the `com.coursepack/file_io` platform channel.
///
/// Uses the platform's Storage Access Framework (ACTION_OPEN_DOCUMENT /
/// ACTION_CREATE_DOCUMENT), so no storage permission is required and files
/// are read and written in place — nothing is copied into app storage.
class CoursepackFileIo implements FileIo {
  const CoursepackFileIo();

  static const MethodChannel _channel =
      MethodChannel('com.coursepack/file_io');

  @override
  Future<String?> pickTextFile() async {
    final text = await _channel.invokeMethod<String>('pickTextFile');
    return text;
  }

  @override
  Future<String?> saveTextFile({
    required String filename,
    required String text,
  }) async {
    final uri = await _channel.invokeMethod<String>(
      'saveTextFile',
      <String, Object>{'filename': filename, 'text': text},
    );
    return uri;
  }

  @override
  Future<String?> pickFilePath() async {
    return _channel.invokeMethod<String>('pickFilePath');
  }
}
