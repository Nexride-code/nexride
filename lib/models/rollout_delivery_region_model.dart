import 'package:geolocator/geolocator.dart';

/// Parsed row from [listDeliveryRegions] — no hardcoded nationwide list in UI.
class RolloutDeliveryCityModel {
  const RolloutDeliveryCityModel({
    required this.cityId,
    required this.displayName,
    required this.supportsRides,
    required this.supportsFood,
    required this.supportsPackage,
    this.centerLat,
    this.centerLng,
    this.serviceRadiusKm,
  });

  final String cityId;
  final String displayName;
  final bool supportsRides;
  final bool supportsFood;
  final bool supportsPackage;
  final double? centerLat;
  final double? centerLng;
  final double? serviceRadiusKm;

  factory RolloutDeliveryCityModel.fromMap(String id, Map<String, dynamic> m) {
    final clat = _readDouble(m['center_lat'] ?? m['centerLat']);
    final clng = _readDouble(m['center_lng'] ?? m['centerLng']);
    final rad = _readDouble(m['service_radius_km'] ?? m['serviceRadiusKm']);
    return RolloutDeliveryCityModel(
      cityId: id,
      displayName: (m['display_name'] ?? m['city_id'] ?? id).toString(),
      supportsRides: m['supports_rides'] != false,
      supportsFood: m['supports_food'] != false,
      supportsPackage: m['supports_package'] != false,
      centerLat: clat,
      centerLng: clng,
      serviceRadiusKm: rad,
    );
  }
}

double? _readDouble(dynamic v) {
  if (v is num) {
    return v.toDouble();
  }
  if (v is String) {
    return double.tryParse(v.trim());
  }
  return null;
}

/// Smallest-radius match when multiple catalog bubbles overlap (admin-controlled geometry).
class RolloutRideAreaMatch {
  const RolloutRideAreaMatch({
    required this.regionId,
    required this.cityId,
    required this.displayName,
    required this.dispatchMarketId,
    required this.stateLabel,
    required this.distanceKm,
    required this.radiusKm,
  });

  final String regionId;
  final String cityId;
  final String displayName;
  final String dispatchMarketId;
  final String stateLabel;
  final double distanceKm;
  final double radiusKm;
}

RolloutRideAreaMatch? matchRideAreaForPickupCoordinates(
  List<RolloutDeliveryRegionModel> catalog, {
  required double lat,
  required double lng,
}) {
  RolloutRideAreaMatch? best;
  var bestRadius = double.infinity;
  for (final region in catalog) {
    if (!region.supportsRides) {
      continue;
    }
    final dm = region.dispatchMarketId.trim();
    if (dm.isEmpty) {
      continue;
    }
    for (final city in region.cities) {
      if (!city.supportsRides) {
        continue;
      }
      final clat = city.centerLat;
      final clng = city.centerLng;
      final rad = city.serviceRadiusKm;
      if (clat == null ||
          clng == null ||
          rad == null ||
          !rad.isFinite ||
          rad <= 0) {
        continue;
      }
      final dMeters = Geolocator.distanceBetween(clat, clng, lat, lng);
      final dKm = dMeters / 1000.0;
      if (dKm <= rad && rad < bestRadius) {
        bestRadius = rad;
        best = RolloutRideAreaMatch(
          regionId: region.regionId,
          cityId: city.cityId,
          displayName: city.displayName,
          dispatchMarketId: dm,
          stateLabel: region.stateLabel,
          distanceKm: dKm,
          radiusKm: rad,
        );
      }
    }
  }
  return best;
}

class RolloutDeliveryRegionModel {
  const RolloutDeliveryRegionModel({
    required this.regionId,
    required this.stateLabel,
    required this.dispatchMarketId,
    required this.cities,
    required this.supportsRides,
    required this.supportsFood,
    required this.supportsPackage,
  });

  final String regionId;
  final String stateLabel;
  final String dispatchMarketId;
  final List<RolloutDeliveryCityModel> cities;
  final bool supportsRides;
  final bool supportsFood;
  final bool supportsPackage;

  factory RolloutDeliveryRegionModel.fromMap(String id, Map<String, dynamic> m) {
    final rawCities = m['cities'];
    final cities = <RolloutDeliveryCityModel>[];
    if (rawCities is List) {
      for (final e in rawCities) {
        if (e is! Map) {
          continue;
        }
        final cm = Map<String, dynamic>.from(e);
        final cid = (cm['city_id'] ?? '').toString().trim();
        if (cid.isEmpty) {
          continue;
        }
        cities.add(RolloutDeliveryCityModel.fromMap(cid, cm));
      }
    }
    return RolloutDeliveryRegionModel(
      regionId: id,
      stateLabel: (m['state'] ?? id).toString(),
      dispatchMarketId: (m['dispatch_market_id'] ?? '').toString().trim(),
      cities: cities,
      supportsRides: m['supports_rides'] != false,
      supportsFood: m['supports_food'] != false,
      supportsPackage: m['supports_package'] != false,
    );
  }
}

List<RolloutDeliveryRegionModel> parseRolloutRegionsResponse(
  Map<String, dynamic> response,
) {
  if (response['success'] != true) {
    return const <RolloutDeliveryRegionModel>[];
  }
  final raw = response['regions'] ?? response['items'];
  if (raw is! List) {
    return const <RolloutDeliveryRegionModel>[];
  }
  final out = <RolloutDeliveryRegionModel>[];
  for (final e in raw) {
    if (e is! Map) {
      continue;
    }
    final m = Map<String, dynamic>.from(e);
    final rid = (m['region_id'] ?? '').toString().trim();
    if (rid.isEmpty) {
      continue;
    }
    out.add(RolloutDeliveryRegionModel.fromMap(rid, m));
  }
  return out;
}
