import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

class RiderDeviceFingerprintService {
  const RiderDeviceFingerprintService();

  static const String _installFingerprintKey =
      'nexride_rider_install_fingerprint';

  Future<String> getInstallFingerprint() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_installFingerprintKey)?.trim() ?? '';
    if (existing.isNotEmpty) {
      return existing;
    }

    final generated = _generateFingerprint();
    await prefs.setString(_installFingerprintKey, generated);
    return generated;
  }

  String _generateFingerprint() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    final buffer = StringBuffer('nrxr');
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}
