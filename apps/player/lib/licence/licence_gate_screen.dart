import 'dart:async';

import 'package:coursepack_crypto/course_pack_crypto.dart';
import 'package:coursepack_device_identity/coursepack_device_identity.dart';
import 'package:coursepack_file_io/coursepack_file_io.dart';
import 'package:coursepack_licence/licence_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The seller's Ed25519 public key, embedded in the app so licences can be
/// verified offline. This is the PUBLIC key only — the private signing key
/// never leaves the licence generator and is never embedded anywhere.
///
/// Replace this constant with your own seller public key (base64 of the raw
/// 32-byte Ed25519 public key) when you issue licences with your own keypair.
const String _sellerPublicKeyB64 =
    'Jb51d69ZU0gk6UuP4PrO5pqUSIYrePb8rEk05p6zAAc=';

/// The first screen of the users app: shows this device's activation code and
/// lets the student load and verify a CoursePack licence.
///
/// Flow (mirrors `tools/player_sim.py`):
///   1. Compute the device fingerprint from the platform components.
///   2. The student picks a `.lic` file.
///   3. Verify the licence: Ed25519 signature, format version, expiry and
///      device binding (fingerprint match).
///   4. On success, hand the verified payload to the course screen.
class LicenceGateScreen extends StatefulWidget {
  const LicenceGateScreen({
    super.key,
    this.fileIo = const CoursepackFileIo(),
    this.readComponents = _defaultReadComponents,
    this.sellerPublicKey = _sellerPublicKeyB64,
  });

  static const String routeName = '/';

  final FileIo fileIo;

  /// Injectable for tests; defaults to the on-device identity plugin.
  final Future<String> Function() readComponents;

  /// Injectable for tests; defaults to the embedded seller public key (b64).
  final String sellerPublicKey;

  @override
  State<LicenceGateScreen> createState() => _LicenceGateScreenState();
}

Future<String> _defaultReadComponents() =>
    const CoursePackDeviceIdentity().readComponents();

class _LicenceGateScreenState extends State<LicenceGateScreen> {
  static const Color _bg = Color(0xFF0B0D12);
  static const Color _panel = Color(0xFF14171F);
  static const Color _panelAlt = Color(0xFF1A1F29);
  static const Color _line = Color(0xFF2B3241);
  static const Color _muted = Color(0xFF8A93A8);
  static const Color _text = Color(0xFFE9EDF6);
  static const Color _accent = Color(0xFF34D3B4);
  static const Color _danger = Color(0xFFFF8A8A);

  String? _deviceCode;
  String? _deviceCodeError;
  String? _status;
  bool _busy = false;
  LicenceCheckResult? _checkResult;

  @override
  void initState() {
    super.initState();
    _computeDeviceCode();
  }

  Future<void> _computeDeviceCode() async {
    try {
      final components = await widget.readComponents();
      final fingerprint =
          await CoursePackCrypto.computeFingerprint(components);
      setState(() {
        _deviceCode = CoursePackCrypto.formatFingerprint(fingerprint);
        _deviceCodeError = null;
      });
    } catch (e) {
      setState(() {
        _deviceCode = null;
        _deviceCodeError = 'Could not read device identity: $e';
      });
    }
  }

  Future<void> _pickLicence() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // pickTextFile returns the file's text content (not a path).
      final text = await widget.fileIo.pickTextFile();
      if (text == null) {
        setState(() => _status = null);
        return;
      }
      setState(() {
        _status = 'Verifying licence…';
        _checkResult = null;
      });

      // Verify the licence against the embedded seller public key, binding it
      // to this device's fingerprint.
      final publicKey = CoursePackCrypto.decodeBase64(widget.sellerPublicKey);
      final checker = LicenceChecker(publicKey: publicKey);
      final result = await checker.check(
        text,
        expectedFp: _deviceCode,
      );

      setState(() {
        _checkResult = result;
        if (result.ok) {
          _status = 'Licence verified for ${result.payload?['name'] ?? 'this device'}.';
        } else {
          _status = null;
        }
      });
    } catch (e) {
      setState(() => _status = 'Error: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        title: const Text('CoursePack · Sign in'),
        backgroundColor: _bg,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _Section(
              heading: 'This device',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    'Send this code to your instructor to receive a licence:',
                    style: TextStyle(color: _muted),
                  ),
                  const SizedBox(height: 12),
                  _deviceCode == null
                      ? Text(
                          _deviceCodeError ?? 'Reading device identity…',
                          style: const TextStyle(color: _danger),
                        )
                      : _DeviceCodeBox(code: _deviceCode!),
                ],
              ),
            ),
            const SizedBox(height: 20),
            _Section(
              heading: 'Your licence',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    'Load a .lic file issued to this device code.',
                    style: TextStyle(color: _muted),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _busy ? null : _pickLicence,
                    icon: const Icon(Icons.license),
                    label: const Text('Open licence (.lic)'),
                  ),
                  if (_status != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        _status!,
                        style: TextStyle(
                          color: _checkResult?.ok == true ? _accent : _danger,
                        ),
                      ),
                    ),
                  if (_checkResult != null && !_checkResult!.ok)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _checkResult!.message,
                        style: const TextStyle(color: _danger, fontSize: 13),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            if (_checkResult?.ok == true)
              FilledButton(
                onPressed: () {
                  final payload = _checkResult!.payload;
                  if (payload != null) {
                    Navigator.of(context).pushNamed(
                      CourseScreen.routeName,
                      arguments: payload,
                    );
                  }
                },
                child: const Text('Open course'),
              )
            else
              const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.heading, required this.child});
  final String heading;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _LicenceGateScreenState._panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _LicenceGateScreenState._line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            heading,
            style: const TextStyle(
              color: _LicenceGateScreenState._muted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _DeviceCodeBox extends StatelessWidget {
  const _DeviceCodeBox({required this.code});
  final String code;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF0B0D12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF2B3241)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Text(
            code,
            style: const TextStyle(
              color: _LicenceGateScreenState._accent,
              fontSize: 26,
              fontWeight: FontWeight.w700,
              letterSpacing: 3,
            ),
          ),
          const SizedBox(width: 12),
          IconButton(
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: code));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Device code copied')),
              );
            },
          ),
        ],
      ),
    );
  }
}
