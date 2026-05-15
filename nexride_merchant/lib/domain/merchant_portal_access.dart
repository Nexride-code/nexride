import '../models/merchant_profile.dart';

/// Role-based UI gates aligned with Cloud Functions `assertMerchantPortalAllowed`.
class MerchantPortalAccess {
  const MerchantPortalAccess._();

  static String _role(MerchantProfile? m) => (m?.portalRole ?? '').trim().toLowerCase();

  static bool isOwner(MerchantProfile? m) => _role(m) == 'owner';

  static bool isManager(MerchantProfile? m) => _role(m) == 'manager';

  static bool isCashier(MerchantProfile? m) => _role(m) == 'cashier';

  static bool canManageStaff(MerchantProfile? m) => isOwner(m);

  static bool canEditMenu(MerchantProfile? m) => isOwner(m) || isManager(m);

  static bool canChangeAvailability(MerchantProfile? m) => isOwner(m) || isManager(m);

  static bool canViewWalletLedger(MerchantProfile? m) => isOwner(m) || isManager(m);

  /// Wallet top-ups, withdrawals, payment model requests (server: owner only).
  static bool canManageBilling(MerchantProfile? m) => isOwner(m);

  static bool canViewInsights(MerchantProfile? m) => isOwner(m) || isManager(m);

  static bool canEditStoreProfile(MerchantProfile? m) => isOwner(m) || isManager(m);
}
