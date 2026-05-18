import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Android 13+ POST_NOTIFICATIONS gate for driver offer pushes.
class DriverAndroidNotificationPermission {
  DriverAndroidNotificationPermission._();

  static final DriverAndroidNotificationPermission instance =
      DriverAndroidNotificationPermission._();

  static const String _prefGoOnlineRequested = 'driver_notif_perm_go_online_v1';

  bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  Future<bool> ensureBeforeGoOnline({bool force = false}) async {
    if (!_isAndroid) {
      return true;
    }
    return _requestIfNeeded(
      contextLabel: 'before_go_online',
      persistKey: _prefGoOnlineRequested,
      force: force,
    );
  }

  Future<bool> _isGranted() async {
    if (!_isAndroid) {
      return true;
    }
    final status = await Permission.notification.status;
    return status.isGranted;
  }

  Future<bool> _requestIfNeeded({
    required String contextLabel,
    required String persistKey,
    bool force = false,
  }) async {
    if (!_isAndroid) {
      debugPrint('DRIVER_NOTIF_PERM context=$contextLabel state=skipped_non_android');
      return true;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final alreadyPrompted = prefs.getBool(persistKey) ?? false;
      if (await _isGranted()) {
        debugPrint('DRIVER_NOTIF_PERM context=$contextLabel state=already_granted');
        return true;
      }
      if (alreadyPrompted && !force) {
        debugPrint(
          'DRIVER_NOTIF_PERM context=$contextLabel state=denied_or_dismissed_cached',
        );
        return false;
      }

      final handlerStatus = await Permission.notification.request();
      final granted = handlerStatus.isGranted;
      await prefs.setBool(persistKey, true);

      debugPrint(
        'DRIVER_NOTIF_PERM context=$contextLabel state=${granted ? 'granted' : 'denied'} '
        'handler=$handlerStatus',
      );
      return granted;
    } catch (error) {
      debugPrint(
        'DRIVER_NOTIF_PERM context=$contextLabel state=error error=$error',
      );
      return false;
    }
  }
}
