import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart' as rtdb;

/// Persists rollout selection on Firestore `users/{uid}` (allowed keys in rules)
/// and mirrors dispatch market to RTDB `users/{uid}/launch_market_city` for legacy reads.
class RiderRolloutProfileStore {
  RiderRolloutProfileStore._();
  static final RiderRolloutProfileStore instance = RiderRolloutProfileStore._();

  static const String kRegionId = 'rollout_region_id';
  static const String kCityId = 'rollout_city_id';
  static const String kDispatchMarketId = 'rollout_dispatch_market_id';

  Future<Map<String, String>?> fetchSelection(String uid) async {
    final id = uid.trim();
    if (id.isEmpty) {
      return null;
    }
    final snap =
        await FirebaseFirestore.instance.collection('users').doc(id).get();
    if (!snap.exists) {
      return null;
    }
    final d = snap.data() ?? <String, dynamic>{};
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
    required String uid,
    required String regionId,
    required String cityId,
    required String dispatchMarketId,
  }) async {
    final id = uid.trim();
    if (id.isEmpty) {
      return;
    }
    await FirebaseFirestore.instance.collection('users').doc(id).set(
      <String, dynamic>{
        kRegionId: regionId.trim(),
        kCityId: cityId.trim(),
        kDispatchMarketId: dispatchMarketId.trim(),
      },
      SetOptions(merge: true),
    );
    try {
      await rtdb.FirebaseDatabase.instance.ref('users/$id').update(<String, dynamic>{
        'launch_market_city': dispatchMarketId.trim(),
        'launch_market_updated_at': rtdb.ServerValue.timestamp,
        'updated_at': rtdb.ServerValue.timestamp,
      });
    } catch (_) {
      /* RTDB optional — Firestore is canonical for rollout */
    }
  }

  String? get currentUid => FirebaseAuth.instance.currentUser?.uid.trim();
}
