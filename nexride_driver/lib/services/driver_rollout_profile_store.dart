import 'package:firebase_database/firebase_database.dart' as rtdb;

class DriverRolloutProfileStore {
  DriverRolloutProfileStore._();
  static final DriverRolloutProfileStore instance = DriverRolloutProfileStore._();

  static const String kRegionId = 'rollout_region_id';
  static const String kCityId = 'rollout_city_id';
  static const String kDispatchMarketId = 'rollout_dispatch_market_id';

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
