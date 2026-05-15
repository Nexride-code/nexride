import 'dart:async';

import 'package:firebase_database/firebase_database.dart' as rtdb;

import 'rollout_catalog_hydration.dart';

class DriverRolloutProfileStore {
  DriverRolloutProfileStore._();
  static final DriverRolloutProfileStore instance = DriverRolloutProfileStore._();

  static const String kRegionId = 'rollout_region_id';
  static const String kCityId = 'rollout_city_id';
  static const String kDispatchMarketId = 'rollout_dispatch_market_id';

  Future<Map<String, String>?> fetchSelection(String driverId) async {
    final id = driverId.trim();
    if (id.isEmpty) {
      return null;
    }
    final snap = await rtdb.FirebaseDatabase.instance
        .ref('drivers/$id')
        .get()
        .timeout(kRolloutProfileFetchTimeout);
    if (!snap.exists || snap.value == null) {
      return null;
    }
    final d = Map<String, dynamic>.from(snap.value! as Map);
    final region = d[kRegionId]?.toString().trim() ?? '';
    final city = d[kCityId]?.toString().trim() ?? '';
    final dm = d[kDispatchMarketId]?.toString().trim() ?? '';
    if (region.isEmpty || city.isEmpty || dm.isEmpty) {
      return null;
    }
    return <String, String>{
      kRegionId: region,
      kCityId: city,
      kDispatchMarketId: dm,
    };
  }

  Future<void> saveSelection({
    required String driverId,
    required String regionId,
    required String cityId,
    required String dispatchMarketId,
  }) async {
    final id = driverId.trim();
    if (id.isEmpty) {
      return;
    }
    final dm = dispatchMarketId.trim();
    await rtdb.FirebaseDatabase.instance.ref('drivers/$id').update(<String, dynamic>{
      kRegionId: regionId.trim(),
      kCityId: cityId.trim(),
      kDispatchMarketId: dm,
      'market': dm,
      'market_pool': dm,
      'dispatch_market': dm,
      'city': dm,
      'launch_market_city': dm,
      'launch_market_updated_at': rtdb.ServerValue.timestamp,
      'updated_at': rtdb.ServerValue.timestamp,
    });
  }
}
