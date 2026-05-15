import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../models/merchant_profile.dart';
import '../services/merchant_gateway_service.dart';
import '../utils/nx_callable_messages.dart';

bool nxSuccess(dynamic v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  final s = v?.toString().trim().toLowerCase();
  return s == 'true' || s == '1' || s == 'yes';
}

class MerchantAppState extends ChangeNotifier {
  MerchantAppState({MerchantGatewayService? gateway})
      : _gateway = gateway ?? MerchantGatewayService();

  final MerchantGatewayService _gateway;

  MerchantGatewayService get gateway => _gateway;

  User? _user;
  MerchantProfile? _merchant;
  bool _loadingMerchant = false;
  String? _merchantLoadError;
  /// Set when [merchantGetMyMerchant] returns `success: false` (e.g. `not_found` for routing).
  String? _merchantLoadFailureReason;
  bool _pendingGateDismissed = false;

  User? get user => _user;
  MerchantProfile? get merchant => _merchant;
  bool get loadingMerchant => _loadingMerchant;
  String? get merchantLoadError => _merchantLoadError;
  String? get merchantLoadFailureReason => _merchantLoadFailureReason;

  bool get isApproved =>
      (_merchant?.merchantStatus ?? '').toLowerCase() == 'approved';

  /// First launch after signup: full-screen pending approval until merchant continues.
  bool get shouldShowPendingApprovalGate =>
      _merchant != null &&
      !_pendingGateDismissed &&
      _merchant!.isAwaitingApproval;

  void acknowledgePendingPortal() {
    _pendingGateDismissed = true;
    notifyListeners();
  }
  void attachAuth(User? u) {
    _user = u;
    if (u == null) {
      _merchant = null;
      _merchantLoadError = null;
      _merchantLoadFailureReason = null;
      _pendingGateDismissed = false;
    }
    notifyListeners();
  }

  Future<void> refreshMerchant() async {
    if (_user == null) {
      _merchant = null;
      notifyListeners();
      return;
    }
    _loadingMerchant = true;
    _merchantLoadError = null;
    _merchantLoadFailureReason = null;
    notifyListeners();
    try {
      final data = await _gateway.merchantGetMyMerchant();
      if (!nxSuccess(data['success'])) {
        _merchant = null;
        _merchantLoadFailureReason = data['reason']?.toString();
        _merchantLoadError = nxMapFailureMessage(
          Map<String, dynamic>.from(data),
          'We could not load your store profile. Please try again.',
        );
      } else {
        final raw = data['merchant'];
        _merchant =
            raw is Map ? MerchantProfile.fromMap(Map<String, dynamic>.from(raw)) : null;
        _merchantLoadError = null;
        _merchantLoadFailureReason = null;
      }
    } catch (e) {
      _merchant = null;
      _merchantLoadFailureReason = null;
      _merchantLoadError = nxUserFacingMessage(e);
    } finally {
      _loadingMerchant = false;
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>> updateProfile(Map<String, dynamic> patch) {
    return _gateway.merchantUpdateMerchantProfile(patch);
  }
}
