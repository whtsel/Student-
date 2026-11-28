import 'dart:async';

import 'package:coursepack_file_io/coursepack_file_io.dart';
import 'package:flutter/material.dart';

import '../crypto/course_pack_crypto.dart';
import 'ed25519_keys.dart';
import 'licence_model.dart';

/// The CoursePack licence generator: issue device-bound `.lic` files and check
/// the ones you have already issued. Everything runs offline against the
/// seller's Ed25519 signing key and `course_keys.json`.
class LicenserScreen extends StatefulWidget {
  const LicenserScreen({super.key, this.fileIo = const CoursepackFileIo()});

  final FileIo fileIo;

  @override
  State<LicenserScreen> createState() => _LicenserState();
}

class _LicenserState extends State<LicenserScreen> {
  static const Color _bg = Color(0xFF0B0D12);
  static const Color _panel = Color(0xFF14171F);
  static const Color _panelAlt = Color(0xFF1A1F29);
  static const Color _line = Color(0xFF2B3241);
  static const Color _muted = Color(0xFF8A93A8);
  static const Color _text = Color(0xFFE9EDF6);
  static const Color _accent2 = Color(0xFF34D3B4);
  static const Color _danger = Color(0xFFFF8A8A);

  int _tab = 0;

  SigningKey? _key;
  CourseKeys? _course;

  final TextEditingController _name = TextEditingController();
  final TextEditingController _phone = TextEditingController();
  final TextEditingController _fp = TextEditingController();
  final TextEditingController _expires = TextEditingController();
  final TextEditingController _licId = TextEditingController();
  final Set<String> _selected = <String>{};

  LicenceCheckResult? _checkResult;
  final TextEditingController _checkFp = TextEditingController();
  final TextEditingController _seedController = TextEditingController();

  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _fp.dispose();
    _expires.dispose();
    _licId.dispose();
    _checkFp.dispose();
    _seedController.dispose();
    super.dispose();
  }

  String? get _normalizedFp {
    try {
      return CoursePackCrypto.formatFingerprint(_fp.text);
    } on CoursePackError {
      return null;
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _loadSigningKeyFromFile() async {
    setState(() => _busy = true);
    final text = await widget.fileIo.pickTextFile();
    if (!mounted) return;
    setState(() => _busy = false);
    if (text == null) return;
    try {
      final key = await Ed25519Keys.fromPem(text);
      setState(() => _key = key);
      _snack('Signing key loaded.');
    } catch (error) {
      _snack('Could not read that key: $error');
    }
  }

  Future<void> _loadSigningKeyFromSeed() async {
    final text = _seedController.text;
    if (text.trim().isEmpty) {
      _snack('Paste a seed first.');
      return;
    }
    setState(() => _busy = true);
    try {
      final key = await Ed25519Keys.fromSeedText(text);
      if (!mounted) return;
      setState(() {
        _key = key;
        _busy = false;
      });
      _snack('Signing key loaded.');
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Could not read that seed: $error');
    }
  }

  Future<void> _loadCourseKeys() async {
    setState(() => _busy = true);
    final text = await widget.fileIo.pickTextFile();
    if (!mounted) return;
    setState(() => _busy = false);
    if (text == null) return;
    try {
      final course = CourseKeys.parse(text);
      setState(() {
        _course = course;
        _selected
          ..clear()
          ..addAll(course.lectures.map((entry) => entry.id));
      });
      _snack('Course keys loaded: ${course.lectures.length} lectures.');
    } catch (error) {
      _snack('Could not read course_keys.json: $error');
    }
  }

  Future<void> _issue() async {
    final key = _key;
    final course = _course;
    if (key == null || course == null) {
      _snack('Load your signing key and course keys first.');
      return;
    }
    if (_name.text.trim().isEmpty) {
      _snack('Enter the student name.');
      return;
    }
    final fingerprint = _normalizedFp;
    if (fingerprint == null) {
      _snack('Enter a device code (16 hex characters).');
      return;
    }
    final expires = _expires.text.trim();
    if (expires.isNotEmpty && !LicenceChecker.isValidExpiry(expires)) {
      _snack('Expiry must be a YYYY-MM-DD date.');
      return;
    }

    setState(() => _busy = true);
    try {
      final issued = await LicenceGenerator(key: key, course: course).issue(
        name: _name.text,
        fingerprint: _fp.text,
        phone: _phone.text,
        expiresAt: expires,
        licId: _licId.text,
        lectureIds: _selected.toList(),
      );
      final uri = await widget.fileIo.saveTextFile(
        filename: issued.filename,
        text: issued.toJsonText(),
      );
      if (!mounted) return;
      setState(() => _busy = false);
      if (uri == null) {
        _snack('Save cancelled.');
      } else {
        _snack('Licence issued and saved: ${issued.filename}');
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Could not issue licence: $error');
    }
  }

  Future<void> _checkLicence() async {
    final key = _key;
    if (key == null) {
      _snack('Load your signing key to check licences.');
      return;
    }
    setState(() => _busy = true);
    final text = await widget.fileIo.pickTextFile();
    if (!mounted) return;
    setState(() => _busy = false);
    if (text == null) return;
    final result = await LicenceChecker(publicKey: key.publicKey).check(
      text,
      expectedFp: _checkFp.text.trim().isEmpty ? null : _checkFp.text,
    );
    if (!mounted) return;
    setState(() {
      _checkResult = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: _text,
        elevation: 0,
        title: const Text(
          'CoursePack · Licence Generator',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(44),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: _course == null
                ? const Text(
                    'Load your signing key and course keys to begin.',
                    style: TextStyle(color: _muted, fontSize: 12),
                  )
                : Text(
                    '${_course!.title} · ${_course!.courseId} · '
                    '${_course!.lectures.length} lectures',
                    style: const TextStyle(color: _muted, fontSize: 12),
                  ),
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        backgroundColor: _panel,
        selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
        destinations: const <Widget>[
          NavigationDestination(
            icon: Icon(Icons.add_circle_outline),
            selectedIcon: Icon(Icons.add_circle),
            label: 'Issue',
          ),
          NavigationDestination(
            icon: Icon(Icons.verified_user_outlined),
            selectedIcon: Icon(Icons.verified_user),
            label: 'Check',
          ),
          NavigationDestination(
            icon: Icon(Icons.key_outlined),
            selectedIcon: Icon(Icons.key),
            label: 'Keys',
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: _tab == 0
              ? _issueView()
              : _tab == 1
                  ? _checkView()
                  : _keysView(),
        ),
      ),
    );
  }

  Widget _card(Widget child, {double padding = 20}) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(padding),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _line),
      ),
      child: child,
    );
  }

  Widget _field({
    required String label,
    TextEditingController? controller,
    String? hint,
    Widget? suffix,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: const TextStyle(color: _muted, fontSize: 12)),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            style: const TextStyle(color: _text),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: const TextStyle(color: _muted),
              filled: true,
              fillColor: _panelAlt,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: _line),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: _line),
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              suffix: suffix,
            ),
          ),
        ],
      ),
    );
  }

  Widget _issueView() {
    final course = _course;
    return ListView(
      children: <Widget>[
        _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Issue a licence',
                  style: const TextStyle(
                      color: _text, fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(
                'Signed with your key and bound to the device code the student '
                'sends you. The resulting .lic file only works on that device.',
                style: TextStyle(color: _muted, height: 1.5),
              ),
              const SizedBox(height: 16),
              _field(label: 'Student name *', controller: _name),
              _field(label: 'Phone (watermark, optional)', controller: _phone),
              _field(
                label: 'Device code *',
                controller: _fp,
                hint: 'A1B2-C3D4-E5F6-7788',
                suffix: _normalizedFp == null
                    ? null
                    : Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Text(
                          _normalizedFp!,
                          style: const TextStyle(
                              color: _accent2,
                              fontFamily: 'monospace',
                              fontSize: 12),
                        ),
                      ),
              ),
              _field(
                label: 'Expires (YYYY-MM-DD, optional)',
                controller: _expires,
                hint: 'Leave empty for no expiry',
              ),
              _field(
                label: 'Licence ID (optional)',
                controller: _licId,
                hint: 'Auto-generated if left empty',
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (course == null)
          _card(
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Load course_keys.json on the Keys tab to choose lectures.',
                style: TextStyle(color: _muted),
              ),
            ),
          )
        else
          _card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Text('Lectures',
                        style: const TextStyle(
                            color: _text,
                            fontSize: 14,
                            fontWeight: FontWeight.w700)),
                    const Spacer(),
                    TextButton(
                      onPressed: () => setState(() {
                        _selected.clear();
                        _selected
                          ..addAll(course.lectures.map((e) => e.id));
                      }),
                      child: const Text('All', style: TextStyle(color: _accent2)),
                    ),
                    TextButton(
                      onPressed: () => setState(() => _selected.clear()),
                      child: const Text('None', style: TextStyle(color: _muted)),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ...course.lectures.map((entry) {
                  final checked = _selected.contains(entry.id);
                  return CheckboxListTile(
                    value: checked,
                    onChanged: (value) => setState(() {
                      if (value == true) {
                        _selected.add(entry.id);
                      } else {
                        _selected.remove(entry.id);
                      }
                    }),
                    title: Text(
                      '${entry.id} · ${entry.title}',
                      style: const TextStyle(color: _text, fontSize: 14),
                    ),
                    subtitle: Text(entry.file,
                        style: const TextStyle(color: _muted, fontSize: 12)),
                    contentPadding: EdgeInsets.zero,
                    activeColor: _accent2,
                  );
                }),
              ],
            ),
          ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _busy ? null : _issue,
          icon: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ))
              : const Icon(Icons.draw),
          label: const Text('Issue and save .lic'),
        ),
      ],
    );
  }

  Widget _checkView() {
    final result = _checkResult;
    return ListView(
      children: <Widget>[
        _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Check a licence',
                  style: const TextStyle(
                      color: _text, fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(
                'Open a .lic file to confirm it is intact, unexpired and bound '
                'to the expected device.',
                style: TextStyle(color: _muted, height: 1.5),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _busy ? null : _checkLicence,
                icon: const Icon(Icons.folder_open),
                label: const Text('Open .lic file'),
              ),
              const SizedBox(height: 16),
              _field(
                label: 'Device code (optional)',
                controller: _checkFp,
                hint: 'Check device binding',
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (result == null)
          _card(
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('No licence checked yet.',
                  style: TextStyle(color: _muted)),
            ),
          )
        else
          _card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: result.ok
                        ? const Color(0xFF34D3B4).withValues(alpha: 0.12)
                        : const Color(0xFFFF8A8A).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    result.ok ? 'VALID' : 'REJECTED',
                    style: TextStyle(
                      color: result.ok ? _accent2 : _danger,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(result.message,
                    style: const TextStyle(color: _text, fontSize: 14)),
                if (result.payload != null) _checkDetails(result),
              ],
            ),
          ),
      ],
    );
  }

  Widget _checkDetails(LicenceCheckResult result) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Divider(color: _line, height: 24),
        _detail('Student', result.studentName),
        _detail('Licence ID', result.licId),
        _detail('Course', '${result.courseTitle} (${result.courseId})'),
        _detail(
            'Device',
            result.fingerprint.isEmpty
                ? '—'
                : CoursePackCrypto.formatFingerprint(result.fingerprint)),
        _detail('Issued', result.issuedAt),
        _detail('Expires', result.expiresAt.isEmpty ? 'never' : result.expiresAt),
        _detail(
            'Lectures',
            '${result.lectures.length} unlocked: '
            '${result.lectures.map((l) => l['id']).join(', ')}'),
      ],
    );
  }

  Widget _detail(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 84,
            child: Text(label, style: const TextStyle(color: _muted, fontSize: 12)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(color: _text, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _keysView() {
    final key = _key;
    final course = _course;
    return ListView(
      children: <Widget>[
        _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Signing key',
                  style: const TextStyle(
                      color: _text, fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(
                'Your Ed25519 private key, loaded at runtime. It is held in '
                'memory only — never written to disk, never shipped inside '
                'the app, and never committed to the repository. Only the '
                'public key is embedded for verifying licences.',
                style: TextStyle(color: _muted, height: 1.5),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _busy ? null : _loadSigningKeyFromFile,
                icon: const Icon(Icons.vpn_key_outlined),
                label: const Text('Open private key (.pem)'),
              ),
              const SizedBox(height: 12),
              _field(
                label: '…or paste a seed (base64 / hex)',
                controller: _seedController,
              ),
              FilledButton(
                onPressed: _busy ? null : _loadSigningKeyFromSeed,
                child: const Text('Use pasted seed'),
              ),
              const SizedBox(height: 14),
              if (key == null)
                const Text('No key loaded.',
                    style: TextStyle(color: _muted, fontSize: 13))
              else
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Divider(color: _line, height: 20),
                    _detail('Status', 'Loaded'),
                    _detail('Public key', key.publicKeyBase64),
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'The seed is held in memory only — it is never '
                        'displayed, written to disk, or shipped in the app.',
                        style: TextStyle(color: _muted, fontSize: 12),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Course keys',
                  style: const TextStyle(
                      color: _text, fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(
                'The course_keys.json produced by make_course.py. Contains the '
                'lecture decryption keys — keep it private.',
                style: TextStyle(color: _muted, height: 1.5),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _busy ? null : _loadCourseKeys,
                icon: const Icon(Icons.bookmark),
                label: const Text('Open course_keys.json'),
              ),
              const SizedBox(height: 14),
              if (course == null)
                const Text('No course loaded.',
                    style: TextStyle(color: _muted, fontSize: 13))
              else
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Divider(color: _line, height: 20),
                    _detail('Course', '${course.title} (${course.courseId})'),
                    _detail('Lectures', '${course.lectures.length}'),
                    _detail(
                        'Created',
                        course.createdAt.isEmpty ? '—' : course.createdAt),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}
