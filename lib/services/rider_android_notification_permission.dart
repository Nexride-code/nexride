import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Android 13+ POST_NOTIFICATIONS gate for rider trip status + FCM.
class RiderAndroidNotificationPermission {
  RiderAndroidNotificationPermission._();

  static final RiderAndroidNotificationPermission instance =
      RiderAndroidNotificationPermission._();

  static const String _prefFirstOpenRequested = 'rider_notif_perm_first_open_v1';
  static const String _prefPreSearchRequested = 'rider_notif_perm_pre_search_v1';

  bool _firstOpenRequestedThisSession = false;

  bool get _isAndroid =>
      !kIsWeb && Platform.isAndroid;

  Future<bool> ensureForFirstAppOpen({bool force = false}) async {
    if (!_isAndroid) {
      return true;
    }
    if (_firstOpenRequestedThisSession && !force) {
      return _isGranted();
    }
    _firstOpenRequestedThisSession = true;
    return _requestIfNeeded(
      contextLabel: 'first_app_open',
      persistKey: _prefFirstOpenRequested,
      force: force,
    );
  }

  Future<bool> ensureBeforeRideSearch({bool force = false}) async {
    if (!_isAndroid) {
      return true;
    }
    return _requestIfNeeded(
      contextLabel: 'before_ride_search',
      persistKey: _prefPreSearchRequested,
      force: force,
    );
  }

  Future<bool> _isGranted() async {
    if (!_isAndroid) {
      return true;
    }
    final android = FlutterLocalNotificationsPlugin()
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    final granted = await android?.areNotificationsEnabled();
    if (granted != null) {
      return granted;
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
      debugPrint('RIDER_NOTIF_PERM context=$contextLabel state=skipped_non_android');
      return true;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final alreadyPrompted = prefs.getBool(persistKey) ?? false;
      if (await _isGranted()) {
        debugPrint('RIDER_NOTIF_PERM context=$contextLabel state=already_granted');
        return true;
      }
      if (alreadyPrompted && !force) {
        debugPrint(
          'RIDER_NOTIF_PERM context=$contextLabel state=denied_or_dismissed_cached',
        );
        return false;
      }

      final android = FlutterLocalNotificationsPlugin()
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      bool? pluginGranted;
      if (android != null) {
        pluginGranted = await android.requestNotificationsPermission();
      }

      final handlerStatus = await Permission.notification.request();
      final granted = pluginGranted == true || handlerStatus.isGranted;
      await prefs.setBool(persistKey, true);

      debugPrint(
        'RIDER_NOTIF_PERM context=$contextLabel state=${granted ? 'granted' : 'denied'} '
        'plugin=$pluginGranted handler=$handlerStatus',
      );
      return granted;
    } catch (error) {
      debugPrint(
        'RIDER_NOTIF_PERM context=$contextLabel state=error error=$error',
      );
      return false;
    }
  }
}
