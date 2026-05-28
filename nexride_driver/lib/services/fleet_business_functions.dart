import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Fleet / dispatch business callables for the driver app.
class FleetBusinessFunctions {
  FleetBusinessFunctions({FirebaseFunctions? functions})
      : _fn = functions ??
            FirebaseFunctions.instanceFor(region: 'us-central1');

  final FirebaseFunctions _fn;
  static const Duration _timeout = Duration(seconds: 30);

  Future<Map<String, dynamic>> driverRedeemBusinessInvite({
    required String inviteCode,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await user.getIdToken(true);
    }
    final trimmed = inviteCode.trim();
    final result = await _fn
        .httpsCallable(
          'driverRedeemBusinessInvite',
          options: HttpsCallableOptions(timeout: _timeout),
        )
        .call(<String, dynamic>{
          'invite_code': trimmed,
          'inviteCode': trimmed,
        })
        .timeout(_timeout);
    final data = result.data;
    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }
    return <String, dynamic>{};
  }
}

String fleetRedeemErrorMessage(String? reason) {
  final r = reason?.trim().toLowerCase() ?? '';
  switch (r) {
    case 'unauthorized':
      return 'You must be signed in to redeem an invite.';
    case 'invalid_invite':
    case 'invalid_invite_code':
      return 'Invalid invite code. Check the code and try again.';
    case 'invite_expired':
      return 'This invite has expired. Ask your fleet business for a new code.';
    case 'invite_already_redeemed':
      return 'This invite was already used.';
    case 'driver_linked_to_another_business':
      return 'You are already linked to another fleet business.';
    case 'invite_not_for_driver':
      return 'This invite is assigned to a different driver account.';
    default:
      if (r.isEmpty) {
        return 'Could not redeem invite. Please try again.';
      }
      return 'Could not redeem invite ($r).';
  }
}
