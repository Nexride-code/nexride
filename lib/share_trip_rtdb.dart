import 'dart:math';

import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/foundation.dart';

class ShareTripLink {
  const ShareTripLink({
    required this.token,
    required this.url,
    required this.expiresAt,
  });

  final String token;
  final String url;
  final int expiresAt;
}

class ShareTripPayload {
  const ShareTripPayload({
    required this.rideId,
    required this.riderId,
    required this.status,
    required this.pickup,
    required this.destination,
    required this.stops,
    required this.driverId,
    required this.driver,
    required this.liveLocation,
    required this.rideData,
  });

  final String rideId;
  final String riderId;
  final String status;
  final Map<String, dynamic> pickup;
  final Map<String, dynamic> destination;
  final List<Map<String, dynamic>> stops;
  final String driverId;
  final Map<String, dynamic>? driver;
  final Map<String, dynamic>? liveLocation;
  final Map<String, dynamic>? rideData;
}

class ShareTripRtdbService {
  ShareTripRtdbService({rtdb.FirebaseDatabase? database})
    : _database = database ?? rtdb.FirebaseDatabase.instance;

  static const String shareBaseUrl = 'https://nexride-8d5bc.web.app/ride';
  static const Duration shareLifetime = Duration(hours: 24);

  final rtdb.FirebaseDatabase _database;

  rtdb.DatabaseReference get _rideRequestsRef => _database.ref('ride_requests');
  rtdb.DatabaseReference get _sharedTripsRef => _database.ref('shared_trips');
  rtdb.DatabaseReference get _sharedTripLookupRef =>
      _database.ref('shared_trip_lookup');
  rtdb.DatabaseReference get _driversRef => _database.ref('drivers');
  rtdb.DatabaseReference get _tripRouteLogsRef =>
      _database.ref('trip_route_logs');

  void _log(String message) {
    debugPrint('[ShareTripRTDB] $message');
  }

  Future<ShareTripLink> ensureShare(ShareTripPayload payload) async {
    final shareMeta = await _resolveShareMeta(
      payload: payload,
      allowCreate: true,
    );
    if (shareMeta == null) {
      throw StateError(
        'Unable to create trip share token for ride ${payload.rideId}',
      );
    }

    await _writeSharedTrip(payload: payload, shareMeta: shareMeta);

    return ShareTripLink(
      token: shareMeta.token,
      url: '$shareBaseUrl?rideId=${Uri.encodeComponent(payload.rideId)}'
          '&token=${Uri.encodeComponent(shareMeta.token)}',
      expiresAt: shareMeta.expiresAt,
    );
  }

  Future<void> syncExistingShare(ShareTripPayload payload) async {
    final shareMeta = await _resolveShareMeta(
      payload: payload,
      allowCreate: false,
    );

    if (shareMeta == null) {
      return;
    }

    await _writeSharedTrip(payload: payload, shareMeta: shareMeta);
  }

  Future<_ShareMeta?> _resolveShareMeta({
    required ShareTripPayload payload,
    required bool allowCreate,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    Map<String, dynamic>? shareData = _asStringDynamicMap(
      payload.rideData?['share'],
    );

    if (shareData == null) {
      final snapshot = await _rideRequestsRef
          .child(payload.rideId)
          .child('share')
          .get();
      shareData = _asStringDynamicMap(snapshot.value);
    }

    final isEnabled = shareData?['enabled'] == true;
    final token = shareData?['token']?.toString().trim() ?? '';
    final createdAt = _asInt(shareData?['created_at']) ?? nowMs;
    final expiresAt = _asInt(shareData?['expires_at']) ?? 0;
    final isReusable = isEnabled && token.isNotEmpty && expiresAt > nowMs;

    if (isReusable) {
      return _ShareMeta(
        token: token,
        createdAt: createdAt,
        expiresAt: expiresAt,
      );
    }

    if (!allowCreate) {
      return null;
    }

    final newCreatedAt = nowMs;
    final newExpiresAt = nowMs + shareLifetime.inMilliseconds;
    final newToken = _generateToken();

    await _rideRequestsRef.child(payload.rideId).child('share').set({
      'enabled': true,
      'token': newToken,
      'created_at': newCreatedAt,
      'expires_at': newExpiresAt,
      'updated_at': nowMs,
    });

    _log('share created rideId=${payload.rideId}');

    return _ShareMeta(
      token: newToken,
      createdAt: newCreatedAt,
      expiresAt: newExpiresAt,
    );
  }

  Future<void> _writeSharedTrip({
    required ShareTripPayload payload,
    required _ShareMeta shareMeta,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final rideData = payload.rideData;
    final existingSharedTrip = _asStringDynamicMap(
      (await _sharedTripsRef.child(shareMeta.token).get()).value,
    );
    final driverPayload = await _buildDriverPayload(
      driverId: payload.driverId,
      existingDriver: payload.driver,
    );
    final routeLog = await _readTripRouteLog(payload.rideId);
    final routePayload = await _buildRoutePayload(
      rideId: payload.rideId,
      rideData: rideData,
      existingRoute: _asStringDynamicMap(existingSharedTrip?['route']),
      routeLog: routeLog,
    );
    final liveLocation = _buildLiveLocationPayload(
      payload.liveLocation,
      fallbackUpdatedAt: _asInt(rideData?['updated_at']) ?? nowMs,
      previousLiveLocation: _asStringDynamicMap(
        existingSharedTrip?['live_location'],
      ),
      fallbackLiveLocation: _lastCheckpointAsLiveLocation(routeLog),
    );

    final sharedTripPayload = <String, dynamic>{
      'share_version': 2,
      'token': shareMeta.token,
      'ride_id': payload.rideId,
      'status': payload.status,
      if ((rideData?['trip_state']?.toString().trim().isNotEmpty ?? false))
        'trip_state': rideData?['trip_state'],
      'pickup': payload.pickup,
      'destination': payload.destination,
      'stops': payload.stops,
      'driver': driverPayload,
      'route': routePayload,
      'live_location': liveLocation,
      'created_at': shareMeta.createdAt,
      'expires_at': shareMeta.expiresAt,
      'payment': _buildPaymentSharePayload(rideData),
      'updated_at':
          _asInt(rideData?['updated_at']) ??
          liveLocation?['updated_at'] ??
          nowMs,
      if (_asInt(rideData?['assigned_at']) != null)
        'assigned_at': _asInt(rideData?['assigned_at']),
      if (_asInt(rideData?['accepted_at']) != null)
        'accepted_at': _asInt(rideData?['accepted_at']),
      if (_asInt(rideData?['arriving_at']) != null)
        'arriving_at': _asInt(rideData?['arriving_at']),
      if (_asInt(rideData?['arrived_at']) != null)
        'arrived_at': _asInt(rideData?['arrived_at']),
      if (_asInt(rideData?['started_at']) != null)
        'started_at': _asInt(rideData?['started_at']),
      if (_asInt(rideData?['completed_at']) != null)
        'completed_at': _asInt(rideData?['completed_at']),
      if (_asInt(rideData?['cancelled_at']) != null)
        'cancelled_at': _asInt(rideData?['cancelled_at']),
    };

    final shareLookupPayload = <String, dynamic>{
      'ride_id': payload.rideId,
      'token': shareMeta.token,
      'created_at': shareMeta.createdAt,
      'expires_at': shareMeta.expiresAt,
      'updated_at': nowMs,
    };

    await Future.wait<void>(<Future<void>>[
      _sharedTripsRef.child(shareMeta.token).set(sharedTripPayload),
      _sharedTripLookupRef.child(payload.rideId).set(shareLookupPayload),
      _rideRequestsRef.child(payload.rideId).child('share').update({
        'enabled': true,
        'token': shareMeta.token,
        'created_at': shareMeta.createdAt,
        'expires_at': shareMeta.expiresAt,
        'updated_at': nowMs,
      }),
    ]);

    if (liveLocation != null &&
        liveLocation['lat'] != null &&
        liveLocation['lng'] != null) {
      _log(
        'driver live location synced rideId=${payload.rideId} lat=${liveLocation['lat']} lng=${liveLocation['lng']}',
      );
    }

    _log('share updated rideId=${payload.rideId} status=${payload.status}');
  }

  Future<Map<String, dynamic>?> _readTripRouteLog(String rideId) async {
    if (rideId.trim().isEmpty) {
      return null;
    }

    try {
      final snapshot = await _tripRouteLogsRef.child(rideId).get();
      return _asStringDynamicMap(snapshot.value);
    } catch (error) {
      _log('route log lookup failed rideId=$rideId error=$error');
      return null;
    }
  }

  Future<Map<String, dynamic>> _buildDriverPayload({
    required String driverId,
    required Map<String, dynamic>? existingDriver,
  }) async {
    if (driverId.isEmpty || driverId == 'waiting') {
      return <String, dynamic>{
        'id': '',
        'name': 'Driver not assigned yet',
        'car': '',
        'plate': '',
        'rating': null,
        'photo_url': '',
      };
    }

    Map<String, dynamic> profile = <String, dynamic>{};
    try {
      final snapshot = await _driversRef.child(driverId).get();
      profile = _asStringDynamicMap(snapshot.value) ?? <String, dynamic>{};
    } catch (error) {
      _log('driver profile lookup failed driverId=$driverId error=$error');
    }

    final mergedDriver = existingDriver ?? <String, dynamic>{};

    return <String, dynamic>{
      'name': _firstNonEmpty(mergedDriver['name'], profile['name']) ?? 'Driver',
      'car':
          _firstNonEmpty(
            mergedDriver['car'],
            mergedDriver['vehicle'],
            profile['car'],
          ) ??
          '',
      'plate': _firstNonEmpty(mergedDriver['plate'], profile['plate']) ?? '',
      'rating':
          _asDouble(mergedDriver['rating']) ?? _asDouble(profile['rating']),
      'photo_url':
          _firstNonEmpty(
            mergedDriver['photo_url'],
            mergedDriver['photoUrl'],
            profile['photo_url'],
            profile['photoUrl'],
            profile['avatar'],
            profile['profile_photo'],
            profile['image'],
          ) ??
          '',
    };
  }

  Future<Map<String, dynamic>> _buildRoutePayload({
    required String rideId,
    required Map<String, dynamic>? rideData,
    required Map<String, dynamic>? existingRoute,
    required Map<String, dynamic>? routeLog,
  }) async {
    final rideRouteBasis = _asStringDynamicMap(rideData?['route_basis']);
    final routeLogBasis = _asStringDynamicMap(routeLog?['routeBasis']);
    final routePath =
        _normalizeRoutePath(rideRouteBasis?['expectedRoutePoints']) ??
        _normalizeRoutePath(routeLogBasis?['expectedRoutePoints']) ??
        _normalizeRoutePath(existingRoute?['path']) ??
        <Map<String, dynamic>>[];

    return <String, dynamic>{
      'updated_at':
          _asInt(rideRouteBasis?['updatedAt']) ??
          _asInt(routeLog?['updatedAt']) ??
          _asInt(existingRoute?['updated_at']) ??
          DateTime.now().millisecondsSinceEpoch,
      'distance_km':
          _asDouble(rideData?['distance_km']) ??
          _asDouble(rideRouteBasis?['distanceKm']) ??
          _asDouble(routeLogBasis?['distanceKm']) ??
          _asDouble(existingRoute?['distance_km']),
      'path': routePath,
    };
  }

  Map<String, dynamic>? _buildLiveLocationPayload(
    Map<String, dynamic>? liveLocation, {
    required int fallbackUpdatedAt,
    Map<String, dynamic>? previousLiveLocation,
    Map<String, dynamic>? fallbackLiveLocation,
  }) {
    final primaryLocation =
        liveLocation ?? fallbackLiveLocation ?? previousLiveLocation;
    if (primaryLocation == null) {
      return null;
    }

    final lat = _asDouble(primaryLocation['lat']);
    final lng = _asDouble(primaryLocation['lng']);
    if (lat == null || lng == null) {
      return null;
    }

    final explicitHeading = _asDouble(primaryLocation['heading']);
    final previousLat = _asDouble(previousLiveLocation?['lat']);
    final previousLng = _asDouble(previousLiveLocation?['lng']);
    final previousHeading = _asDouble(previousLiveLocation?['heading']) ?? 0;

    double heading = explicitHeading ?? previousHeading;
    if ((explicitHeading == null || explicitHeading == 0) &&
        previousLat != null &&
        previousLng != null) {
      final inferredHeading = _bearingBetween(
        startLat: previousLat,
        startLng: previousLng,
        endLat: lat,
        endLng: lng,
      );

      if (inferredHeading != null) {
        heading = inferredHeading;
      }
    }

    return <String, dynamic>{
      'lat': lat,
      'lng': lng,
      'heading': heading,
      'updated_at': _asInt(primaryLocation['updated_at']) ?? fallbackUpdatedAt,
    };
  }

  Map<String, dynamic>? _lastCheckpointAsLiveLocation(
    Map<String, dynamic>? routeLog,
  ) {
    final lastCheckpoint = _asStringDynamicMap(routeLog?['lastCheckpoint']);
    if (lastCheckpoint == null) {
      return null;
    }

    final lat = _asDouble(lastCheckpoint['lat']);
    final lng = _asDouble(lastCheckpoint['lng']);
    if (lat == null || lng == null) {
      return null;
    }

    return <String, dynamic>{
      'lat': lat,
      'lng': lng,
      'updated_at': _asInt(lastCheckpoint['updatedAt']),
    };
  }

  List<Map<String, dynamic>>? _normalizeRoutePath(dynamic value) {
    if (value is! List) {
      return null;
    }

    final points = <Map<String, dynamic>>[];
    for (final rawPoint in value) {
      final point = _asStringDynamicMap(rawPoint);
      if (point == null) {
        continue;
      }

      final lat = _asDouble(point['lat']);
      final lng = _asDouble(point['lng']);
      if (lat == null || lng == null) {
        continue;
      }

      points.add(<String, dynamic>{'lat': lat, 'lng': lng});
    }

    if (points.isEmpty) {
      return null;
    }

    return points;
  }

  double? _bearingBetween({
    required double startLat,
    required double startLng,
    required double endLat,
    required double endLng,
  }) {
    final latDelta = endLat - startLat;
    final lngDelta = endLng - startLng;
    if (latDelta.abs() < 0.00001 && lngDelta.abs() < 0.00001) {
      return null;
    }

    final startLatRadians = startLat * (pi / 180);
    final endLatRadians = endLat * (pi / 180);
    final deltaLngRadians = (endLng - startLng) * (pi / 180);

    final y = sin(deltaLngRadians) * cos(endLatRadians);
    final x =
        cos(startLatRadians) * sin(endLatRadians) -
        sin(startLatRadians) * cos(endLatRadians) * cos(deltaLngRadians);
    final bearing = atan2(y, x) * (180 / pi);
    return (bearing + 360) % 360;
  }

  Map<String, dynamic>? _asStringDynamicMap(dynamic value) {
    if (value is! Map) {
      return null;
    }

    return value.map<String, dynamic>(
      (key, nestedValue) => MapEntry(key.toString(), nestedValue),
    );
  }

  double? _asDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }

    if (value is String) {
      return double.tryParse(value);
    }

    return null;
  }

  int? _asInt(dynamic value) {
    if (value is int) {
      return value;
    }

    if (value is num) {
      return value.toInt();
    }

    if (value is String) {
      return int.tryParse(value);
    }

    return null;
  }

  String? _firstNonEmpty(
    dynamic first, [
    dynamic second,
    dynamic third,
    dynamic fourth,
    dynamic fifth,
    dynamic sixth,
    dynamic seventh,
  ]) {
    final candidates = <dynamic>[
      first,
      second,
      third,
      fourth,
      fifth,
      sixth,
      seventh,
    ];

    for (final candidate in candidates) {
      final text = candidate?.toString().trim() ?? '';
      if (text.isNotEmpty) {
        return text;
      }
    }

    return null;
  }

  String _generateToken() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
    final random = Random.secure();
    return List<String>.generate(
      20,
      (_) => chars[random.nextInt(chars.length)],
    ).join();
  }

  Map<String, dynamic> _buildPaymentSharePayload(Map<String, dynamic>? rideData) {
    final paymentMethod = rideData?['payment_method']?.toString().trim() ?? '';
    final paymentStatus = rideData?['payment_status']?.toString().trim() ?? '';
    final settlementStatus =
        rideData?['settlement_status']?.toString().trim() ?? '';
    final placeholder = _asStringDynamicMap(rideData?['payment_placeholder']);
    final provider = placeholder?['provider']?.toString().trim() ?? '';
    final placeholderStatus = placeholder?['status']?.toString().trim() ?? '';

    return <String, dynamic>{
      'method': paymentMethod,
      'status': paymentStatus,
      'settlement_status': settlementStatus,
      'provider': provider,
      'provider_status': placeholderStatus,
    };
  }
}

class _ShareMeta {
  const _ShareMeta({
    required this.token,
    required this.createdAt,
    required this.expiresAt,
  });

  final String token;
  final int createdAt;
  final int expiresAt;
}
