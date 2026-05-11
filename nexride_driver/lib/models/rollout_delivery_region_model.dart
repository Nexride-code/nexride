class RolloutDeliveryCityModel {
  const RolloutDeliveryCityModel({
    required this.cityId,
    required this.displayName,
    required this.supportsRides,
    required this.supportsFood,
    required this.supportsPackage,
  });

  final String cityId;
  final String displayName;
  final bool supportsRides;
  final bool supportsFood;
  final bool supportsPackage;

  factory RolloutDeliveryCityModel.fromMap(String id, Map<String, dynamic> m) {
    return RolloutDeliveryCityModel(
      cityId: id,
      displayName: (m['display_name'] ?? m['city_id'] ?? id).toString(),
      supportsRides: m['supports_rides'] != false,
      supportsFood: m['supports_food'] != false,
      supportsPackage: m['supports_package'] != false,
    );
  }
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
