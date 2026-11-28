import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:coursepack_crypto/course_pack_crypto.dart';
import 'package:coursepack_device_identity/coursepack_device_identity.dart';

class DeviceCodeScreen extends StatefulWidget {
  const DeviceCodeScreen({
    super.key,
    Future<String> Function()? readComponents,
  }) : _readComponents = readComponents;

  final Future<String> Function()? _readComponents;

  @override
  State<DeviceCodeScreen> createState() => _DeviceCodeScreenState();
}

class _DeviceCodeScreenState extends State<DeviceCodeScreen> {
  String? _deviceCode;
  String? _error;
  bool _loading = true;

  Future<String> _readNativeComponents() =>
      const CoursePackDeviceIdentity().readComponents();

  @override
  void initState() {
    super.initState();
    _loadDeviceCode();
  }

  Future<void> _loadDeviceCode() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final components = await (widget._readComponents ?? _readNativeComponents)();
      if (components.isEmpty) {
        throw const CoursePackError('No device identity components are available.');
      }
      final fingerprint = await CoursePackCrypto.computeFingerprint(components);
      if (!mounted) return;
      setState(() {
        _deviceCode = CoursePackCrypto.formatFingerprint(fingerprint);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'CoursePack could not read this device’s identity. Please retry.';
        _loading = false;
      });
    }
  }

  Future<void> _copyCode() async {
    final code = _deviceCode;
    if (code == null) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Device code copied')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: const Color(0xFF0B0D12),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, viewport) => SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: math.max(0.0, viewport.maxHeight - 32),
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Card(
                color: const Color(0xFF14171F),
                shape: RoundedRectangleBorder(
                  side: const BorderSide(color: Color(0xFF2B3241)),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(28, 30, 28, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'COURSEPACK  ·  DEVICE ACTIVATION',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: const Color(0xFF34D3B4),
                              letterSpacing: 1.4,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Send this code to your instructor',
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                              color: const Color(0xFFE9EDF6),
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Your licence is issued for this device only. '
                        'CoursePack works offline; no account or server is required.',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: const Color(0xFF8A93A8),
                              height: 1.55,
                            ),
                      ),
                      const SizedBox(height: 22),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 20,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0A0D14),
                          border: Border.all(color: colors.primary.withValues(alpha: 0.55)),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          children: [
                            Text(
                              'DEVICE CODE',
                              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                    color: const Color(0xFF626B7E),
                                    letterSpacing: 1.7,
                                  ),
                            ),
                            const SizedBox(height: 10),
                            if (_loading)
                              const SizedBox(
                                height: 34,
                                child: Center(
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              )
                            else if (_error != null)
                              Text(
                                _error!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Color(0xFFFF8A8A)),
                              )
                            else
                              SelectableText(
                                _deviceCode!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Color(0xFFEAF1FF),
                                  fontFamily: 'monospace',
                                  fontSize: 25,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 2.2,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),
                      if (_error != null)
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: _loading ? null : _loadDeviceCode,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Retry'),
                          ),
                        )
                      else
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton.icon(
                            onPressed: _loading ? null : _copyCode,
                            icon: const Icon(Icons.copy, size: 18),
                            label: const Text('Copy code'),
                          ),
                        ),
                      const SizedBox(height: 12),
                      const Divider(color: Color(0xFF232936)),
                      const SizedBox(height: 8),
                      const Text(
                        '1. Copy the code and send it with the name you paid under.\n'
                        '2. Your instructor will return a .lic file for this device.\n'
                        '3. Open that file in CoursePack to continue.',
                        style: TextStyle(
                          color: Color(0xFF8A93A8),
                          height: 1.7,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);
  }
}
