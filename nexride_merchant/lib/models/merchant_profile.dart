class MerchantProfile {
  const MerchantProfile({
    required this.merchantId,
    required this.businessName,
    required this.merchantStatus,
    required this.paymentModel,
    required this.subscriptionStatus,
    this.subscriptionAmount,
    this.subscriptionCurrency,
    this.commissionRate,
    this.withdrawalPercent,
    this.phone,
    this.address,
    this.category,
    this.contactEmail,
    this.ownerName,
    this.businessType,
    this.businessRegistrationNumber,
    this.isOpen = true,
    this.acceptingOrders = true,
    this.availabilityStatus,
    this.closedReason,
    this.storeLogoUrl,
    this.storeBannerUrl,
    this.verificationStatus,
    this.requiredDocumentsComplete = false,
    this.readinessMissing = const <String>[],
    this.walletBalanceNgn,
    this.withdrawableEarningsNgn,
    this.adminNote,
    this.storeDescription,
    this.openingHours,
    this.portalLastSeenMs,
    this.portalRole,
  });

  final String merchantId;
  final String businessName;
  final String merchantStatus;
  final String paymentModel;
  final String subscriptionStatus;
  final num? subscriptionAmount;
  final String? subscriptionCurrency;
  final num? commissionRate;
  final num? withdrawalPercent;
  final String? phone;
  final String? address;
  final String? category;
  final String? contactEmail;
  final String? ownerName;
  final String? businessType;
  final String? businessRegistrationNumber;
  /// When null from legacy merchants, treat as open (server semantics).
  final bool isOpen;
  final bool acceptingOrders;
  final String? availabilityStatus;
  final String? closedReason;
  final String? storeLogoUrl;
  final String? storeBannerUrl;
  final String? verificationStatus;
  final bool requiredDocumentsComplete;
  final List<String> readinessMissing;
  final num? walletBalanceNgn;
  final num? withdrawableEarningsNgn;
  final String? adminNote;
  final String? storeDescription;
  final String? openingHours;
  final int? portalLastSeenMs;
  final String? portalRole;

  bool get isLiveForOrders =>
      merchantStatus.toLowerCase() == 'approved' && isOpen && acceptingOrders;

  bool get isAwaitingApproval {
    final s = merchantStatus.toLowerCase();
    return s == 'pending' || s == 'pending_review';
  }

  factory MerchantProfile.fromMap(Map<String, dynamic> m) {
    final rawOpen = m['is_open'];
    final rawAcc = m['accepting_orders'];
    return MerchantProfile(
      merchantId: '${m['merchant_id'] ?? ''}'.trim(),
      businessName: '${m['business_name'] ?? ''}'.trim(),
      merchantStatus: '${m['merchant_status'] ?? m['status'] ?? 'pending'}'.trim(),
      paymentModel: '${m['payment_model'] ?? 'subscription'}'.trim(),
      subscriptionStatus: '${m['subscription_status'] ?? 'inactive'}'.trim(),
      subscriptionAmount: m['subscription_amount'] as num?,
      subscriptionCurrency: m['subscription_currency']?.toString(),
      commissionRate: m['commission_rate'] as num?,
      withdrawalPercent: m['withdrawal_percent'] as num?,
      phone: m['phone']?.toString(),
      address: m['address']?.toString(),
      category: m['category']?.toString(),
      contactEmail: m['contact_email']?.toString(),
      ownerName: m['owner_name']?.toString(),
      businessType: m['business_type']?.toString(),
      businessRegistrationNumber: m['business_registration_number']?.toString(),
      isOpen: rawOpen == null ? true : m['is_open'] == true,
      acceptingOrders: rawAcc == null ? true : m['accepting_orders'] == true,
      availabilityStatus: _normalizeAvailabilityStatus(m['availability_status']?.toString()),
      closedReason: m['closed_reason']?.toString(),
      storeLogoUrl: m['store_logo_url']?.toString(),
      storeBannerUrl: m['store_banner_url']?.toString(),
      verificationStatus: m['verification_status']?.toString(),
      requiredDocumentsComplete: m['required_documents_complete'] == true,
      readinessMissing: (m['readiness_missing_requirements'] is List)
          ? (m['readiness_missing_requirements'] as List)
              .map((e) => e.toString())
              .toList()
          : const <String>[],
      walletBalanceNgn: m['wallet_balance_ngn'] as num?,
      withdrawableEarningsNgn: m['withdrawable_earnings_ngn'] as num?,
      adminNote: m['admin_note']?.toString(),
      storeDescription: m['store_description']?.toString(),
      openingHours: m['opening_hours']?.toString(),
      portalLastSeenMs: m['portal_last_seen_ms'] is num ? (m['portal_last_seen_ms'] as num).toInt() : null,
      portalRole: m['portal_role']?.toString(),
    );
  }

  static String? _normalizeAvailabilityStatus(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final s = raw.toLowerCase();
    if (s == 'online') return 'open';
    if (s == 'offline') return 'closed';
    return raw;
  }
}
