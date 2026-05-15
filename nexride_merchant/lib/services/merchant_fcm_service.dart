import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'merchant_gateway_service.dart';

/// Foreground notifications + FCM token registration (uses existing `registerDevicePushToken` callable).
class MerchantFcmService {
  MerchantFcmService._();
  static final MerchantFcmService instance = MerchantFcmService._();

  final FlutterLocalNotificationsPlugin _local = FlutterLocalNotificationsPlugin();
  bool _inited = false;

  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    'nexride_high_importance',
    'NexRide orders',
    description: 'New customer orders and merchant alerts.',
    importance: Importance.max,
  );

  Future<void> init(MerchantGatewayService gateway) async {
    if (_inited) return;
    _inited = true;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings();
    await _local.initialize(
      const InitializationSettings(android: androidInit, iOS: iosInit),
    );

    final androidImpl = _local.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.createNotificationChannel(_channel);

    final messaging = FirebaseMessaging.instance;
    await messaging.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    final settings = await messaging.requestPermission(alert: true, badge: true, sound: true);
    if (kDebugMode) {
      debugPrint('[FCM] auth status=${settings.authorizationStatus}');
    }

    FirebaseMessaging.onMessage.listen((RemoteMessage msg) {
      _showLocalFromRemote(msg);
    });

    messaging.onTokenRefresh.listen((String token) async {
      await _registerToken(gateway, token);
    });

    final t = await messaging.getToken();
    if (t != null) {
      await _registerToken(gateway, t);
    }
  }

  Future<void> _registerToken(MerchantGatewayService gateway, String token) async {
    try {
      await gateway.registerDevicePushToken(<String, dynamic>{
        'token': token,
        'platform': Platform.isIOS ? 'ios' : 'android',
        'app': 'merchant',
      });
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[FCM] registerDevicePushToken failed: $e');
      }
    }
  }

  void _showLocalFromRemote(RemoteMessage msg) {
    final n = msg.notification;
    final title = n?.title ?? 'NexRide Merchant';
    final body = n?.body ?? msg.data['body']?.toString() ?? 'New activity';
    _local.show(
      msg.hashCode,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.id,
          _channel.name,
          channelDescription: _channel.description,
          importance: Importance.max,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
        ),
        iOS: const DarwinNotificationDetails(),
      ),
      payload: msg.data['order_id']?.toString(),
    );
  }
}
