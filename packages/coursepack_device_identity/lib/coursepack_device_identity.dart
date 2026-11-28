import 'package:flutter/services.dart';

/// Reads only the platform-specific components used by the CoursePack v1
/// device fingerprint. Hashing and display formatting stay in the Dart core.
class CoursePackDeviceIdentity {
  static const MethodChannel _channel =
      MethodChannel('com.coursepack/device_identity');

  const CoursePackDeviceIdentity();

  Future<String> readComponents() async {
    final value = await _channel.invokeMethod<String>('readComponents');
    if (value == null || value.isEmpty) {
      throw PlatformException(
        code: 'device_identity_unavailable',
        message: 'The operating system did not provide device identity data.',
      );
    }
    return value;
  }
}
