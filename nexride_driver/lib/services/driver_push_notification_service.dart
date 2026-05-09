import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'driver_offer_prime_coordinator.dart';
import 'ride_cloud_functions_service.dart';

@pragma('vm:entry-point')
Future<void> driverFirebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('DRIVER_PUSH_BACKGROUND type=${message.data['type'] ?? ''}');
}

class DriverPushNotificationService {
  DriverPushNotificationService._();

  static final DriverPushNotificationService instance = DriverPushNotificationService._();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final RideCloudFunctionsService _rideCloud = RideCloudFunctionsService();
  StreamSubscription<String>? _tokenRefreshSubscription;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    if (kIsWeb) {
      debugPrint('DRIVER_PUSH_INIT_SKIPPED web_requires_worker_setup');
      return;
    }

    try {
      await _messaging.requestPermission(alert: true, badge: true, sound: true);
      FirebaseMessaging.onBackgroundMessage(
        driverFirebaseMessagingBackgroundHandler,
      );

    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      final t = message.data['type'] ?? '';
      debugPrint('DRIVER_PUSH_FOREGROUND type=$t');
      if (t == 'driver_offer') {
        DriverOfferPrimeCoordinator.instance.requestPrime();
      }
    });
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      final t = message.data['type'] ?? '';
      debugPrint('DRIVER_PUSH_OPENED type=$t');
      if (t == 'driver_offer') {
        DriverOfferPrimeCoordinator.instance.requestPrime();
      }
    });
    final initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) {
      final t = initialMessage.data['type'] ?? '';
      debugPrint('DRIVER_PUSH_INITIAL type=$t');
      if (t == 'driver_offer') {
        DriverOfferPrimeCoordinator.instance.requestPrime();
      }
    }

    _tokenRefreshSubscription = _messaging.onTokenRefresh.listen((String token) {
      unawaited(_registerToken(token));
    });
      final token = await _messaging.getToken();
      if (token != null && token.trim().isNotEmpty) {
        await _registerToken(token);
      }
    } catch (error) {
      debugPrint('DRIVER_PUSH_INIT_FAIL error=$error');
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
      await _rideCloud.registerDevicePushToken(token: token, platform: platform);
    } catch (error) {
      debugPrint('DRIVER_PUSH_REGISTER_FAIL error=$error');
    }
  }

  Future<void> dispose() async {
    await _tokenRefreshSubscription?.cancel();
    _tokenRefreshSubscription = null;
  }
}
