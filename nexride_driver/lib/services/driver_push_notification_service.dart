import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'driver_offer_prime_coordinator.dart';
import 'driver_pending_offer_launch_store.dart';
import '../support/driver_startup_coordinator.dart';
import '../support/driver_startup_platform.dart';
import 'ride_cloud_functions_service.dart';

const Duration _kFcmOperationTimeout = Duration(seconds: 2);

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

  /// Run after [DriverMapScreen] mounts — never during the "Connecting…" bootstrap.
  /// iOS Simulator: no-op (push/APNs unavailable; must not block UX).
  /// Real devices: sets up listeners and registers token with 2s caps per operation.
  Future<void> initializeAfterMapOpened() async {
    if (kIsWeb) {
      debugPrint('DRIVER_PUSH_INIT_SKIPPED web_requires_worker_setup');
      return;
    }
    if (driverStartupIsIosSimulator) {
      driverStartupLog('fcm_token_skipped_ios_simulator');
      return;
    }
    await _initializeFullPushStack();
  }

  Future<void> _initializeFullPushStack() async {
    if (_initialized) {
      return;
    }
    if (kIsWeb) {
      return;
    }
    if (driverStartupIsIosSimulator) {
      driverStartupLog('fcm_token_skipped_ios_simulator');
      return;
    }
    _initialized = true;

    driverStartupLog('fcm_token_start');
    try {
      try {
        await _messaging
            .requestPermission(alert: true, badge: true, sound: true)
            .timeout(_kFcmOperationTimeout);
      } on TimeoutException {
        driverStartupLog('fcm_token_timeout op=requestPermission');
      }

      FirebaseMessaging.onBackgroundMessage(
        driverFirebaseMessagingBackgroundHandler,
      );

      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        DriverPendingOfferLaunchStore.instance
            .captureFromFcmData(Map<String, dynamic>.from(message.data));
        final t = message.data['type'] ?? '';
        final rideId = message.data['rideId']?.toString() ??
            message.data['ride_id']?.toString() ??
            message.data['rideRequestId']?.toString();
        debugPrint('DRIVER_PUSH_FOREGROUND type=$t');
        if (t == 'driver_offer') {
          debugPrint(
            'OFFER_POPUP_STAGE=notification_received rideId=${rideId ?? ''}',
          );
          DriverOfferPrimeCoordinator.instance
              .requestPrime(rideId: rideId ?? '');
        }
      }, onError: (Object error, StackTrace stackTrace) {
        debugPrint('[NEXRIDE_DIAG] FCM_onMessage_stream error=$error');
        debugPrintStack(
          label: '[NEXRIDE_DIAG] FCM_onMessage stack',
          stackTrace: stackTrace,
        );
      });
      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        DriverPendingOfferLaunchStore.instance
            .captureFromFcmData(Map<String, dynamic>.from(message.data));
        final t = message.data['type'] ?? '';
        final rideId = message.data['rideId']?.toString() ??
            message.data['ride_id']?.toString() ??
            message.data['rideRequestId']?.toString();
        debugPrint('DRIVER_PUSH_OPENED type=$t');
        if (t == 'driver_offer') {
          debugPrint(
            'OFFER_POPUP_STAGE=notification_tapped rideId=${rideId ?? ''}',
          );
          DriverOfferPrimeCoordinator.instance
              .requestPrime(rideId: rideId ?? '');
        }
      }, onError: (Object error, StackTrace stackTrace) {
        debugPrint('[NEXRIDE_DIAG] FCM_onMessageOpenedApp error=$error');
        debugPrintStack(
          label: '[NEXRIDE_DIAG] FCM_onMessageOpenedApp stack',
          stackTrace: stackTrace,
        );
      });

      RemoteMessage? initialMessage;
      try {
        initialMessage =
            await _messaging.getInitialMessage().timeout(_kFcmOperationTimeout);
      } on TimeoutException {
        driverStartupLog('fcm_token_timeout op=getInitialMessage');
      }
      if (initialMessage != null) {
        DriverPendingOfferLaunchStore.instance
            .captureFromFcmData(Map<String, dynamic>.from(initialMessage.data));
        final t = initialMessage.data['type'] ?? '';
        final rideId = initialMessage.data['rideId']?.toString() ??
            initialMessage.data['ride_id']?.toString() ??
            initialMessage.data['rideRequestId']?.toString();
        debugPrint('DRIVER_PUSH_INITIAL type=$t');
        if (t == 'driver_offer') {
          debugPrint(
            'OFFER_POPUP_STAGE=notification_tapped rideId=${rideId ?? ''}',
          );
          DriverOfferPrimeCoordinator.instance
              .requestPrime(rideId: rideId ?? '');
        }
      }

      _tokenRefreshSubscription = _messaging.onTokenRefresh.listen((String token) {
        unawaited(_registerToken(token));
      }, onError: (Object error, StackTrace stackTrace) {
        debugPrint('[NEXRIDE_DIAG] FCM_tokenRefresh error=$error');
        debugPrintStack(
          label: '[NEXRIDE_DIAG] FCM_tokenRefresh stack',
          stackTrace: stackTrace,
        );
      });

      String? token;
      try {
        token = await _messaging.getToken().timeout(_kFcmOperationTimeout);
      } on TimeoutException {
        driverStartupLog('fcm_token_timeout op=getToken');
      }
      if (token != null && token.trim().isNotEmpty) {
        await _registerToken(token);
      }
      driverStartupLog('fcm_token_done');
    } catch (error, stackTrace) {
      driverStartupLog('fcm_token_fail');
      debugPrint('[NEXRIDE_DIAG] DRIVER_PUSH_HEAVY_FAIL error=$error');
      debugPrintStack(
        label: '[NEXRIDE_DIAG] DRIVER_PUSH_HEAVY stack',
        stackTrace: stackTrace,
      );
    }
  }

  /// Refresh token with the backend. Real devices only; never blocks simulator.
  Future<void> registerCurrentUserToken() async {
    if (kIsWeb) {
      return;
    }
    if (driverStartupIsIosSimulator) {
      return;
    }
    String? token;
    try {
      token = await _messaging.getToken().timeout(_kFcmOperationTimeout);
    } on TimeoutException {
      driverStartupLog('fcm_token_timeout op=getToken');
      return;
    }
    if (token != null && token.trim().isNotEmpty) {
      await _registerToken(token);
    }
  }

  Future<void> _registerToken(String token) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return;
    }
    final platform = kIsWeb ? 'web' : defaultTargetPlatform.name;
    try {
      await _rideCloud
          .registerDevicePushToken(token: token, platform: platform)
          .timeout(_kFcmOperationTimeout);
    } on TimeoutException {
      driverStartupLog('fcm_token_timeout op=registerDevicePushToken');
    } catch (error) {
      debugPrint('DRIVER_PUSH_REGISTER_FAIL error=$error');
    }
  }

  Future<void> dispose() async {
    await _tokenRefreshSubscription?.cancel();
    _tokenRefreshSubscription = null;
  }
}
