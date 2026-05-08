import 'package:shared_preferences/shared_preferences.dart';

/// Persists a prepaid Flutterwave ride-intent `tx_ref` after successful verify
/// so we can complete [createRideRequest] if the app stops before the callable returns.
class RiderPrepaidIntentRecoveryStore {
  static const _kTxRef = 'nexride_pending_prepaid_flutterwave_tx_ref';

  Future<void> rememberPendingTxRef(String txRef) async {
    final trimmed = txRef.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final p = await SharedPreferences.getInstance();
    await p.setString(_kTxRef, trimmed);
  }

  Future<void> clearPendingTxRef() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kTxRef);
  }

  Future<String?> readPendingTxRef() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kTxRef)?.trim() ?? '';
    return raw.isEmpty ? null : raw;
  }
}
