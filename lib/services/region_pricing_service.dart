import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../config/rider_app_config.dart';

/// Fetches live fare rules from Firestore `region_pricing/{city}` with an
/// in-memory cache so each city is only fetched once per app session.
/// Falls back to the hardcoded [RiderFareSettings] values when the
/// Firestore document is absent or malformed.
class RegionPricingService {
  RegionPricingService._();
  static final RegionPricingService instance = RegionPricingService._();

  final Map<String, RiderFareRule> _cache = {};

  CollectionReference<Map<String, dynamic>> get _col =>
      FirebaseFirestore.instance.collection('region_pricing');

  /// Returns the live fare rule for [city], fetching from Firestore if not
  /// already cached.  Falls back to the hardcoded rule if Firestore is
  /// unavailable or the document doesn't exist.
  Future<RiderFareRule> ruleForCity(String city) async {
    final normalized = RiderLaunchScope.normalizeSupportedCity(city) ?? city;
    if (_cache.containsKey(normalized)) {
      return _cache[normalized]!;
    }
    try {
      final snap = await _col.doc(normalized).get();
      if (snap.exists) {
        final rule = _parseRule(snap.data()!);
        if (rule != null) {
          _cache[normalized] = rule;
          return rule;
        }
      }
    } catch (_) {
      // Network error — fall through to hardcoded.
    }
    final fallback =
        RiderFareSettings.maybeForCity(normalized) ??
        (throw StateError('No pricing rule for city: $city'));
    _cache[normalized] = fallback;
    return fallback;
  }

  /// Synchronous lookup — only returns a value if already cached.
  RiderFareRule? cachedRuleForCity(String? city) {
    final normalized = RiderLaunchScope.normalizeSupportedCity(city);
    return normalized == null ? null : _cache[normalized];
  }

  /// Warms up the cache for [city] in the background without throwing.
  void prewarmForCity(String city) {
    unawaited(ruleForCity(city).then((_) {}, onError: (_) {}));
  }

  /// Invalidates the in-memory cache so the next call re-fetches Firestore.
  void invalidate() => _cache.clear();

  RiderFareRule? _parseRule(Map<String, dynamic> data) {
    final baseFare = _toDouble(data['base_fare']);
    final perKmRate = _toDouble(data['per_km_rate']);
    final perMinuteRate = _toDouble(data['per_minute_rate']);
    final minimumFare = _toDouble(data['minimum_fare']);
    if (baseFare == null ||
        perKmRate == null ||
        perMinuteRate == null ||
        minimumFare == null) {
      return null;
    }
    return RiderFareRule(
      baseFare: baseFare,
      perKmRate: perKmRate,
      perMinuteRate: perMinuteRate,
      minimumFare: minimumFare,
    );
  }

  double? _toDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }
}
