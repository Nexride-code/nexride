import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'rider_ride_cloud_functions_service.dart';

@pragma('vm:entry-point')
Future<void> riderFirebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('RIDER_PUSH_BACKGROUND type=${message.data['type'] ?? ''}');
}

class RiderPushNotificationService {
  RiderPushNotificationService._();

  static final RiderPushNotificationService instance = RiderPushNotificationService._();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  StreamSubscription<String>? _tokenRefreshSubscription;
  bool _initialized = false;

  /// Optional hook for [MapScreen] to refresh active ride on foreground FCM.
  void Function(Map<String, String> data)? onForegroundData;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    if (kIsWeb) {
      debugPrint('RIDER_PUSH_INIT_SKIPPED web_requires_worker_setup');
      return;
    }

    try {
      await _messaging.requestPermission(alert: true, badge: true, sound: true);
      FirebaseMessaging.onBackgroundMessage(
        riderFirebaseMessagingBackgroundHandler,
      );

    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      final data = Map<String, String>.from(
        message.data.map(
          (key, value) => MapEntry(key, value?.toString() ?? ''),
        ),
      );
      final rideId = _rideIdFromPushData(data);
      debugPrint(
        'RIDER_PUSH_FOREGROUND type=${data['type'] ?? ''} '
        'rideId=$rideId',
      );
      onForegroundData?.call(data);
    });
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      debugPrint('RIDER_PUSH_OPENED type=${message.data['type'] ?? ''}');
    });
    final initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) {
      debugPrint('RIDER_PUSH_INITIAL type=${initialMessage.data['type'] ?? ''}');
    }

    _tokenRefreshSubscription = _messaging.onTokenRefresh.listen((String token) {
      unawaited(_registerToken(token));
    });
      final token = await _messaging.getToken();
      if (token != null && token.trim().isNotEmpty) {
        await _registerToken(token);
      }
    } catch (error) {
      debugPrint('RIDER_PUSH_INIT_FAIL error=$error');
    }
  }

  Future<void> registerCurrentUserToken() async {
    final token = await _messaging.getToken();
    if (token != null && token.trim().isNotEmpty) {
      await _registerToken(token);
    }
  }

  Future<void> _registerToken(String token) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final platform = kIsWeb ? 'web' : defaultTargetPlatform.name;
    try {
      await RiderRideCloudFunctionsService.instance.registerDevicePushToken(
        token: token,
        platform: platform,
      );
    } catch (error) {
      debugPrint('RIDER_PUSH_REGISTER_FAIL error=$error');
    }
  }

  Future<void> dispose() async {
    await _tokenRefreshSubscription?.cancel();
    _tokenRefreshSubscription = null;
    onForegroundData = null;
  }

  static String _rideIdFromPushData(Map<String, String> data) {
    for (final key in <String>[
      'rideId',
      'ride_id',
      'requestId',
      'request_id',
      'tripId',
      'trip_id',
    ]) {
      final value = data[key]?.trim() ?? '';
      if (value.isNotEmpty) {
        return value;
      }
    }
    return '';
  }
}
