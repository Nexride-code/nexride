import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'rider_pending_trip_notification_store.dart';

/// Phase-1 persistent rider trip status notification (searching → completed).
class RiderTripStatusNotificationService {
  RiderTripStatusNotificationService._();

  static final RiderTripStatusNotificationService instance =
      RiderTripStatusNotificationService._();

  static const int _notificationId = 91042;
  static const String _channelId = 'nexride_rider_trip_status';
  static const String _channelName = 'Trip status';

  final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  String? _activeRideId;
  String? _lastStatusKey;

  static const AndroidNotificationChannel _androidChannel =
      AndroidNotificationChannel(
    _channelId,
    _channelName,
    description: 'Live trip status while a ride is in progress.',
    importance: Importance.low,
  );

  Future<void> initialize() async {
    if (_initialized || kIsWeb) {
      return;
    }
    _initialized = true;
    const androidInit = AndroidInitializationSettings('@drawable/ic_stat_nexride');
    const iosInit = DarwinInitializationSettings();
    await _local.initialize(
      const InitializationSettings(android: androidInit, iOS: iosInit),
      onDidReceiveNotificationResponse: _onNotificationResponse,
    );
    final androidImpl = _local.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.createNotificationChannel(_androidChannel);

    final launchDetails = await _local.getNotificationAppLaunchDetails();
    final launchPayload =
        launchDetails?.notificationResponse?.payload?.trim();
    if (launchDetails?.didNotificationLaunchApp == true &&
        launchPayload != null &&
        launchPayload.isNotEmpty) {
      _capturePayload(launchPayload);
    }
  }

  void _onNotificationResponse(NotificationResponse response) {
    final payload = response.payload?.trim();
    if (payload == null || payload.isEmpty) {
      return;
    }
    _capturePayload(payload);
  }

  void _capturePayload(String payload) {
    const prefix = 'ride:';
    if (!payload.startsWith(prefix)) {
      return;
    }
    final rideId = payload.substring(prefix.length).trim();
    if (rideId.isEmpty) {
      return;
    }
    RiderPendingTripNotificationStore.instance.captureRideId(rideId);
  }

  Future<void> syncFromUiStatus({
    required String? rideId,
    required String status,
  }) async {
    if (kIsWeb) {
      return;
    }
    await initialize();
    final normalizedRideId = rideId?.trim();
    final normalizedStatus = status.trim().toLowerCase();
    if (normalizedRideId == null || normalizedRideId.isEmpty) {
      await clear();
      return;
    }

    final statusKey = _statusCopy(normalizedStatus);
    if (statusKey == null) {
      await clear();
      return;
    }

    if (_activeRideId == normalizedRideId && _lastStatusKey == statusKey) {
      return;
    }

    _activeRideId = normalizedRideId;
    _lastStatusKey = statusKey;

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _androidChannel.description,
      importance: Importance.low,
      priority: Priority.low,
      ongoing:
          normalizedStatus != 'completed' && normalizedStatus != 'cancelled',
      onlyAlertOnce: true,
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: false,
      presentSound: false,
    );

    try {
      await _local.show(
        _notificationId,
        'NexRide trip',
        statusKey,
        NotificationDetails(android: androidDetails, iOS: iosDetails),
        payload: 'ride:$normalizedRideId',
      );
      debugPrint(
        'RIDER_TRIP_STATUS_NOTIFICATION rideId=$normalizedRideId status=$normalizedStatus',
      );
    } catch (error) {
      debugPrint(
        'RIDER_TRIP_STATUS_NOTIFICATION skipped rideId=$normalizedRideId '
        'reason=show_failed error=$error',
      );
    }

    if (normalizedStatus == 'completed' ||
        normalizedStatus == 'cancelled' ||
        normalizedStatus == 'driver_cancelled' ||
        normalizedStatus == 'rider_cancelled') {
      await Future<void>.delayed(const Duration(seconds: 8));
      await clear();
    }
  }

  String? _statusCopy(String status) {
    return switch (status) {
      'searching' || 'requested' => 'Searching for driver',
      'pending_driver_action' || 'assigned' || 'accepted' => 'Driver assigned',
      'arriving' => 'Driver arriving',
      'arrived' => 'Driver arriving',
      'on_trip' => 'Trip started',
      'completed' => 'Completed',
      _ => null,
    };
  }

  Future<void> clear() async {
    if (kIsWeb) {
      return;
    }
    _activeRideId = null;
    _lastStatusKey = null;
    if (!_initialized) {
      return;
    }
    await _local.cancel(_notificationId);
  }

  Future<void> dispose() async {
    await clear();
  }
}
