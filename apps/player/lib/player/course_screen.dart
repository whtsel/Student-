import 'dart:io';

import 'package:coursepack_crypto/course_pack_crypto.dart';
import 'package:coursepack_file_io/coursepack_file_io.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../player/course_pack_validator.dart';
import '../player/decrypted_video.dart';

/// The course screen, shown after a licence is verified.
///
/// Lists the lectures named in the verified licence payload. For each
/// lecture the student picks the matching `.enc` file; the app validates that
/// it is a CoursePack file, decrypts it with the content key embedded in the
/// licence, and plays it back in the built-in video player.
///
/// The content key never leaves the app: it arrives inside the verified,
/// device-bound licence and is used only to decrypt the matching `.enc`.
class CourseScreen extends StatefulWidget {
  const CourseScreen({
    super.key,
    required this.payload,
    this.fileIo = const CoursepackFileIo(),
  });

  /// The verified licence payload (already signature + fingerprint checked).
  final Map payload;

  final FileIo fileIo;

  static const String routeName = '/course';

  @override
  State<CourseScreen> createState() => _CourseScreenState();
}

class _CourseScreenState extends State<CourseScreen> {
  static const Color _bg = Color(0xFF0B0D12);
  static const Color _panel = Color(0xFF14171F);
  static const Color _line = Color(0xFF2B3241);
  static const Color _muted = Color(0xFF8A93A8);
  static const Color _accent = Color(0xFF34D3B4);
  static const Color _danger = Color(0xFFFF8A8A);

  /// Per-lecture playback state: resolved `.enc` path, validation, and the
  /// current decrypted/playback session.
  final Map<String, _LectureState> _lectures = {};

  final DecryptedVideo _decrypter = DecryptedVideo();

  List<Map> get _lectureEntries {
    final lectures = widget.payload['lectures'];
    if (lectures is List) {
      return lectures.cast<Map>().toList();
    }
    return const <Map>[];
  }

  _LectureState _stateFor(Map lecture) {
    final id = lecture['id'] as String? ?? '${lecture.hashCode}';
    return _lectures.putIfAbsent(id, () => _LectureState());
  }

  Future<void> _playLecture(Map lecture) async {
    final state = _stateFor(lecture);
    final id = lecture['id'] as String? ?? '${lecture.hashCode}';
    final keyB64 = lecture['key'] as String?;
    if (keyB64 == null || keyB64.isEmpty) {
      setState(() => state.message = 'Licence has no key for this lecture.');
      return;
    }

    // Resolve the .enc file: reuse a previously picked one if present.
    String? encPath = state.encPath;
    if (encPath == null) {
      final picked = await widget.fileIo.pickFilePath();
      if (picked == null) return;
      encPath = picked;
    }

    setState(() {
      state.encPath = encPath;
      state.message = 'Validating CoursePack file…';
    });

    // Gate: reject anything that is not a CoursePack .enc file.
    final validation = CoursePackValidator().check(encPath);
    if (!validation.ok) {
      setState(() => state.message = validation.message);
      return;
    }

    setState(() => state.message = 'Decrypting…');

    try {
      final key = CoursePackCrypto.decodeBase64(keyB64);
      final result = await _decrypter.decryptToTempFile(encPath, key);
      setState(() {
        state.message = null;
      });
      if (!mounted) {
        deleteTempFile(result.tempPath);
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _PlayerScreen(
            title: lecture['title'] as String? ?? id,
            tempPath: result.tempPath,
          ),
        ),
      );
      // When the player is dismissed, delete the decrypted temp file.
      deleteTempFile(result.tempPath);
    } on CoursePackError catch (e) {
      setState(() => state.message = e.message);
    } catch (e) {
      setState(() => state.message = 'Decryption failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        title: Text(widget.payload['name'] as String? ?? 'CoursePack'),
        backgroundColor: _bg,
        elevation: 0,
      ),
      body: _lectureEntries.isEmpty
          ? const Center(
              child: Text(
                'This licence has no lectures.',
                style: TextStyle(color: _muted),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(20),
              itemCount: _lectureEntries.length,
              separatorBuilder: (_, __) =>
                  const SizedBox(height: 12),
              itemBuilder: (BuildContext context, int index) {
                final lecture = _lectureEntries[index];
                final state = _stateFor(lecture);
                return _LectureCard(
                  lecture: lecture,
                  state: state,
                  onPlay: () => _playLecture(lecture),
                );
              },
            ),
    );
  }
}

/// Mutable per-lecture UI state.
class _LectureState {
  String? encPath;
  String? message;
}

class _LectureCard extends StatelessWidget {
  static const Color _panel = Color(0xFF14171F);
  static const Color _line = Color(0xFF2B3241);
  static const Color _muted = Color(0xFF8A93A8);
  static const Color _text = Color(0xFFE9EDF6);
  static const Color _accent = Color(0xFF34D3B4);
  static const Color _danger = Color(0xFFFF8A8A);

  const _LectureCard({
    required this.lecture,
    required this.state,
    required this.onPlay,
  });

  final Map lecture;
  final _LectureState state;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final id = lecture['id'] as String? ?? 'unknown';
    final title = lecture['title'] as String? ?? id;
    final duration = lecture['duration_s'];

    final statusColor = state.message == null
        ? _LectureCard._accent
        : (state.message!.contains('not a CoursePack') ||
                state.message!.contains('Decryption failed') ||
                state.message!.contains('shorter'))
            ? _LectureCard._danger
            : _muted;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _LectureCard._panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _LectureCard._line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(color: _LectureCard._text, fontSize: 16),
                ),
                const SizedBox(height: 4),
                Text(
                  'Lecture $id${duration != null ? ' · ${duration}s' : ''}',
                  style: const TextStyle(color: _muted, fontSize: 12),
                ),
                if (state.message != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      state.message!,
                      style: TextStyle(color: statusColor, fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: onPlay,
            icon: const Icon(Icons.play_arrow, size: 18),
            label: const Text('Play'),
          ),
        ],
      ),
    );
  }
}

/// A full-screen video player over a decrypted temp file.
class _PlayerScreen extends StatefulWidget {
  const _PlayerScreen({required this.title, required this.tempPath});

  final String title;
  final String tempPath;

  @override
  State<_PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<_PlayerScreen> {
  static const Color _bg = Color(0xFF0B0D12);

  late VideoPlayerController _controller;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.tempPath));
    _controller.initialize().then((_) {
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        title: Text(widget.title),
        backgroundColor: _bg,
        elevation: 0,
      ),
      body: Center(
        child: _ready
            ? AspectRatio(
                aspectRatio: _controller.value.aspectRatio,
                child: VideoPlayer(_controller),
              )
            : const Center(child: CircularProgressIndicator()),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          setState(() {
            _controller.value.isPlaying
                ? _controller.pause()
                : _controller.play();
          });
        },
        child: Icon(_controller.value.isPlaying ? Icons.pause : Icons.play_arrow),
      ),
    );
  }
}
