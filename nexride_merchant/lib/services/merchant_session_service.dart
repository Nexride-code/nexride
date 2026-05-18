import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:flutter/widgets.dart';

import '../state/merchant_app_state.dart';

class MerchantSessionService {
  MerchantSessionService._();

  static final MerchantSessionService instance = MerchantSessionService._();

  Future<void> signOut({BuildContext? context, String reason = 'user_logout'}) async {
    debugPrint('MERCHANT_SESSION sign_out_start reason=$reason');
    if (context != null && context.mounted) {
      try {
        context.read<MerchantAppState>().attachAuth(null);
      } catch (e, st) {
        debugPrint('MERCHANT_SESSION detach_state failed: $e\n$st');
      }
    }
    await FirebaseAuth.instance.signOut();
    debugPrint('MERCHANT_SESSION sign_out_complete');
  }
}
