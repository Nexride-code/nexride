import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Cold-start + resume handling for shared-trip URLs (`/trip/{rideId}?token=`).
///
/// Share tokens are stored in **Realtime Database** at `shared_trips/{token}` (see
/// `docs/shared_backend_contracts.md`). Verification requires a signed-in user per RTDB rules.
class RiderTripDeepLinkService {
  RiderTripDeepLinkService._();
  static final RiderTripDeepLinkService instance = RiderTripDeepLinkService._();

  static const _prefRideId = 'rider_pending_trip_link_ride_id';
  static const _prefToken = 'rider_pending_trip_link_token';

  static const Set<String> _httpsTripHosts = <String>{
    'nexride.africa',
    'nexride-8d5bc.web.app',
  };

  static final FirebaseAnalytics _analytics = FirebaseAnalytics.instance;

  static Future<void> _log(String name, Map<String, Object> params) async {
    try {
      await _analytics.logEvent(name: name, parameters: params);
    } catch (e) {
      debugPrint('[RIDER_TRIP_LINK] analytics $name failed: $e');
    }
  }

  /// Returns true if [uri] is a NexRide shared-trip deep link.
  bool looksLikeTripDeepLink(Uri uri) {
    return parseTripRideId(uri) != null &&
        (uri.queryParameters['token'] ?? '').trim().isNotEmpty;
  }

  String? parseTripRideId(Uri uri) {
    if (uri.scheme.toLowerCase() == 'nexride' &&
        uri.host.toLowerCase() == 'trip') {
      if (uri.pathSegments.isEmpty) {
        return null;
      }
      return uri.pathSegments.first.trim();
    }
    if (uri.scheme.toLowerCase() == 'https' &&
        _httpsTripHosts.contains(uri.host.toLowerCase())) {
      final segs = uri.pathSegments;
      final idx = segs.indexOf('trip');
      if (idx >= 0 && idx + 1 < segs.length) {
        return segs[idx + 1].trim();
      }
    }
    return null;
  }

  Future<void> persistPendingLink({
    required String rideId,
    required String token,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefRideId, rideId);
    await prefs.setString(_prefToken, token);
  }

  Future<void> clearPendingLink() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefRideId);
    await prefs.remove(_prefToken);
  }

  Future<({String rideId, String token})?> loadPendingLink() async {
    final prefs = await SharedPreferences.getInstance();
    final rideId = (prefs.getString(_prefRideId) ?? '').trim();
    final token = (prefs.getString(_prefToken) ?? '').trim();
    if (rideId.isEmpty || token.isEmpty) {
      return null;
    }
    return (rideId: rideId, token: token);
  }

  /// Validates `shared_trips/{token}.ride_id == rideId`; optional expiry check.
  Future<bool> verifyShareToken({
    required String rideId,
    required String token,
  }) async {
    final snap =
        await rtdb.FirebaseDatabase.instance.ref('shared_trips/$token').get();
    if (!snap.exists || snap.value is! Map) {
      return false;
    }
    final data = Map<String, dynamic>.from(snap.value! as Map);
    final rid = (data['ride_id'] ?? data['rideId'] ?? '').toString().trim();
    if (rid != rideId.trim()) {
      return false;
    }
    final expiresAt = _asInt(data['expires_at'] ?? data['expiresAt']);
    if (expiresAt != null &&
        expiresAt > 0 &&
        DateTime.now().millisecondsSinceEpoch > expiresAt) {
      return false;
    }
    return true;
  }

  int? _asInt(dynamic v) {
    if (v is int) {
      return v;
    }
    if (v is num) {
      return v.toInt();
    }
    if (v is String) {
      return int.tryParse(v.trim());
    }
    return null;
  }

  /// After sign-in, load pending link from disk and return a ride id if still valid.
  Future<String?> consumePendingAfterAuth() async {
    final pending = await loadPendingLink();
    if (pending == null) {
      return null;
    }
    final ok = await verifyShareToken(
      rideId: pending.rideId,
      token: pending.token,
    );
    await clearPendingLink();
    if (!ok) {
      await _log('LINK_TRIP_INVALID', <String, Object>{
        'source': 'pending_after_auth',
      });
      return null;
    }
    await logNavigated(pending.rideId);
    return pending.rideId;
  }

  Future<void> logOpen(Uri uri) async {
    await _log('LINK_TRIP_OPEN', <String, Object>{
      'scheme': uri.scheme,
      'host': uri.host,
    });
  }

  Future<void> logInvalid(String reason) async {
    await _log('LINK_TRIP_INVALID', <String, Object>{
      'reason': reason,
    });
  }

  Future<void> logNavigated(String rideId) async {
    await _log('LINK_TRIP_NAVIGATED', <String, Object>{
      'ride_id': rideId,
    });
  }
}
