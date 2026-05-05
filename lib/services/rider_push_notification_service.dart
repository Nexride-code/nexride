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
      debugPrint('RIDER_PUSH_FOREGROUND type=${message.data['type'] ?? ''}');
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
  }
}
