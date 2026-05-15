import 'package:flutter/material.dart';

import '../config/driver_app_config.dart';
import 'driver_verification_support.dart';

export 'driver_verification_support.dart';

const Color kDriverGold = Color(0xFFD4AF37);
const Color kDriverDark = Color(0xFF111111);
const Color kDriverCream = Color(0xFFF7F2EA);

Map<String, dynamic> _asStringDynamicMap(dynamic value) {
  if (value is Map) {
    return value.map<String, dynamic>(
      (dynamic key, dynamic entryValue) => MapEntry(key.toString(), entryValue),
    );
  }
  return <String, dynamic>{};
}

String _text(dynamic value) => value?.toString().trim() ?? '';

bool _boolValue(dynamic value, {bool fallback = false}) {
  if (value is bool) {
    return value;
  }
  final normalized = value?.toString().trim().toLowerCase();
  if (normalized == 'true' || normalized == '1' || normalized == 'yes') {
    return true;
  }
  if (normalized == 'false' || normalized == '0' || normalized == 'no') {
    return false;
  }
  return fallback;
}

int _intValue(dynamic value, {int fallback = 0}) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.round();
  }
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

List<String> _stringList(dynamic value, {required List<String> fallback}) {
  if (value is List) {
    final normalized = value
        .map((dynamic entry) => entry.toString().trim())
        .where((String entry) => entry.isNotEmpty)
        .toList();
    if (normalized.isNotEmpty) {
      return normalized;
    }
  }
  return List<String>.from(fallback);
}

double _doubleValue(dynamic value) {
  if (value is double) {
    return value;
  }
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

DateTime? _dateTimeValue(dynamic value) {
  if (value == null) {
    return null;
  }
  if (value is int) {
    return DateTime.fromMillisecondsSinceEpoch(value).toLocal();
  }
  if (value is double) {
    return DateTime.fromMillisecondsSinceEpoch(value.round()).toLocal();
  }
  final parsedInt = int.tryParse(value.toString());
  if (parsedInt != null) {
    return DateTime.fromMillisecondsSinceEpoch(parsedInt).toLocal();
  }
  return DateTime.tryParse(value.toString())?.toLocal();
}

int _timestampValue(dynamic value, {required int fallback}) {
  if (value is int) {
    return value;
  }
  if (value is double) {
    return value.round();
  }
  final parsedDate = _dateTimeValue(value);
  if (parsedDate != null) {
    return parsedDate.millisecondsSinceEpoch;
  }
  return fallback;
}

Map<String, dynamic> _firstMap(List<dynamic> candidates) {
  for (final candidate in candidates) {
    final mapped = _asStringDynamicMap(candidate);
    if (mapped.isNotEmpty) {
      return mapped;
    }
  }
  return <String, dynamic>{};
}

String _formatWholeNumberWithCommas(String digits) {
  if (digits.length <= 3) {
    return digits;
  }
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    final remaining = digits.length - i;
    buffer.write(digits[i]);
    if (remaining > 1 && remaining % 3 == 1) {
      buffer.write(',');
    }
  }
  return buffer.toString();
}

String _titleCaseWords(String value) {
  if (value.isEmpty) {
    return value;
  }
  return value
      .split(' ')
      .where((String part) => part.isNotEmpty)
      .map(
        (String part) =>
            '${part[0].toUpperCase()}${part.substring(1).toLowerCase()}',
      )
      .join(' ');
}

String formatDriverCommissionRatePercent(dynamic value) {
  final ratePercent = _doubleValue(value);
  if (ratePercent <= 0) {
    return '0';
  }
  final rounded = ratePercent.roundToDouble();
  return rounded == ratePercent
      ? rounded.toStringAsFixed(0)
      : ratePercent.toStringAsFixed(1);
}

String formatDriverNairaAmount(num amount) {
  final absolute = amount.abs().toDouble();
  final isWholeNumber = absolute.truncateToDouble() == absolute;
  final base =
      isWholeNumber ? absolute.toStringAsFixed(0) : absolute.toStringAsFixed(2);
  final parts = base.split('.');
  final formattedWhole = _formatWholeNumberWithCommas(parts.first);
  final decimalPart = parts.length > 1 ? '.${parts[1]}' : '';
  return '${amount < 0 ? '-' : ''}₦$formattedWhole$decimalPart';
}

String formatDriverBusinessStatusLabel(String value) {
  final normalized = value.trim().toLowerCase();
  return switch (normalized) {
    '' => 'Not set',
    'setup_required' => 'Setup required',
    'not_started' => 'Not started',
    'payment_pending' => 'Payment pending',
    'manual_review' => 'Manual review',
    _ => _titleCaseWords(normalized.replaceAll('_', ' ')),
  };
}

class DriverTripSettlementBreakdown {
  const DriverTripSettlementBreakdown({
    required this.selectedModel,
    required this.appliedModel,
    required this.subscriptionStatus,
    required this.subscriptionActive,
    required this.commissionRate,
    required this.commissionAmount,
    required this.netPayout,
  });

  final String selectedModel;
  final String appliedModel;
  final String subscriptionStatus;
  final bool subscriptionActive;
  final double commissionRate;
  final double commissionAmount;
  final double netPayout;
}

double _roundCurrency(double value) {
  return double.parse(value.toStringAsFixed(2));
}

double _firstPositiveBusinessDouble(
  List<dynamic> candidates, {
  required double fallback,
}) {
  for (final dynamic candidate in candidates) {
    final value = _doubleValue(candidate);
    if (value > 0) {
      return value;
    }
  }
  return fallback;
}

int _firstPositiveBusinessInt(
  List<dynamic> candidates, {
  required int fallback,
}) {
  for (final dynamic candidate in candidates) {
    final value = _intValue(candidate);
    if (value > 0) {
      return value;
    }
  }
  return fallback;
}

String _subscriptionPlanDisplayLabel(String planType) {
  return planType.trim().toLowerCase() == 'weekly'
      ? 'Weekly subscription'
      : 'Monthly subscription';
}

String _normalizedSubscriptionStatusFromRecord(
  Map<String, dynamic> subscription, {
  DateTime? now,
}) {
  final rawStatus = _text(subscription['status']).toLowerCase();
  final effectiveNow = now ?? DateTime.now();
  final renewalDate = _dateTimeValue(
    subscription['validUntil'] ??
        subscription['valid_until'] ??
        subscription['expiresAt'] ??
        subscription['expires_at'] ??
        subscription['renewalDate'] ??
        subscription['renewal_date'],
  );

  if (rawStatus == 'active' &&
      renewalDate != null &&
      renewalDate.isBefore(effectiveNow)) {
    return 'expired';
  }

  return rawStatus.isNotEmpty ? rawStatus : 'setup_required';
}

String _businessEligibilityStatusFromNormalized(
  Map<String, dynamic> businessModel,
) {
  final selectedModel = _text(businessModel['selectedModel']);
  if (selectedModel == 'subscription') {
    return _text(_asStringDynamicMap(businessModel['subscription'])['status']);
  }
  return _text(_asStringDynamicMap(businessModel['commission'])['status']);
}

bool _canGoOnlineFromNormalized(Map<String, dynamic> businessModel) {
  final effectiveModel = _text(businessModel['effectiveModel']);
  if (effectiveModel == 'subscription') {
    return _text(
            _asStringDynamicMap(businessModel['subscription'])['status']) ==
        'active';
  }

  final status =
      _text(_asStringDynamicMap(businessModel['commission'])['status']);
  return status == 'eligible' ||
      status == 'active' ||
      status == 'setup_required';
}

bool driverSubscriptionIsActive(
  Map<String, dynamic> businessModel, {
  DateTime? now,
}) {
  final normalized = normalizedDriverBusinessModel(businessModel, now: now);
  return _text(normalized['selectedModel']) == 'subscription' &&
      _text(_asStringDynamicMap(normalized['subscription'])['status']) ==
          'active';
}

String driverEffectiveMonetizationModel(
  Map<String, dynamic> businessModel, {
  DateTime? now,
}) {
  final normalized = normalizedDriverBusinessModel(businessModel, now: now);
  final effectiveModel = _text(normalized['effectiveModel']);
  return effectiveModel == 'subscription' ? 'subscription' : 'commission';
}

double driverCommissionRateForBusinessModel(
  Map<String, dynamic> businessModel, {
  DateTime? now,
}) {
  final normalized = normalizedDriverBusinessModel(businessModel, now: now);
  if (_text(normalized['effectiveModel']) == 'subscription') {
    return 0;
  }
  final commission = _asStringDynamicMap(normalized['commission']);
  return _firstPositiveBusinessDouble(
    <dynamic>[
      commission['rate'],
      commission['commissionRate'],
      normalized['commissionRate'],
      normalized['commission_rate'],
    ],
    fallback: DriverBusinessConfig.commissionRate,
  );
}

DriverTripSettlementBreakdown calculateDriverTripSettlement({
  required double grossFare,
  required Map<String, dynamic> businessModel,
  DateTime? now,
}) {
  final normalized = normalizedDriverBusinessModel(businessModel, now: now);
  final subscriptionStatus =
      _text(_asStringDynamicMap(normalized['subscription'])['status']);
  final subscriptionActive = driverSubscriptionIsActive(normalized, now: now);
  final commissionRate = driverCommissionRateForBusinessModel(
    normalized,
    now: now,
  );
  final commissionAmount = grossFare <= 0 ? 0.0 : grossFare * commissionRate;
  final netPayout =
      grossFare - commissionAmount < 0 ? 0.0 : grossFare - commissionAmount;

  return DriverTripSettlementBreakdown(
    selectedModel: _text(normalized['selectedModel']),
    appliedModel: subscriptionActive ? 'subscription' : 'commission',
    subscriptionStatus: subscriptionStatus,
    subscriptionActive: subscriptionActive,
    commissionRate: commissionRate,
    commissionAmount: commissionAmount,
    netPayout: netPayout,
  );
}

bool driverSettlementCountsTowardWallet(String settlementStatus) {
  final normalized = settlementStatus.trim().toLowerCase();
  return normalized == 'completed' || normalized == 'trip_completed';
}

Map<String, dynamic> buildDriverTripSettlementRecord({
  required double grossFare,
  required Map<String, dynamic> businessModel,
  required String paymentMethod,
  required String settlementStatus,
  required String completionState,
  String reviewStatus = 'not_required',
  int reportedOutstandingAmountNgn = 0,
  String city = '',
  Map<String, dynamic>? fareBreakdown,
  DateTime? now,
}) {
  final normalizedBusinessModel = normalizedDriverBusinessModel(
    businessModel,
    now: now,
  );
  final settlement = calculateDriverTripSettlement(
    grossFare: grossFare,
    businessModel: normalizedBusinessModel,
    now: now,
  );
  final normalizedPaymentMethod =
      paymentMethod.trim().isEmpty ? 'unspecified' : paymentMethod.trim();
  final normalizedSettlementStatus = settlementStatus.trim().isEmpty
      ? 'trip_completed'
      : settlementStatus.trim();
  final normalizedReviewStatus =
      reviewStatus.trim().isEmpty ? 'not_required' : reviewStatus.trim();

  return <String, dynamic>{
    'selectedModel': settlement.selectedModel,
    'appliedModel': settlement.appliedModel,
    'subscriptionStatus': settlement.subscriptionStatus,
    'subscriptionActive': settlement.subscriptionActive,
    'commissionRate': _roundCurrency(settlement.commissionRate),
    'commissionRatePercent': _roundCurrency(settlement.commissionRate * 100),
    'commissionAmountNgn': _roundCurrency(settlement.commissionAmount),
    'commissionAmount': _roundCurrency(settlement.commissionAmount),
    'grossFareNgn': _roundCurrency(grossFare),
    'grossFare': _roundCurrency(grossFare),
    'driverPayoutNgn': _roundCurrency(settlement.netPayout),
    'driverPayout': _roundCurrency(settlement.netPayout),
    'netEarningNgn': _roundCurrency(settlement.netPayout),
    'netEarning': _roundCurrency(settlement.netPayout),
    'paymentMethod': normalizedPaymentMethod,
    'settlementStatus': normalizedSettlementStatus,
    'completionState': completionState.trim(),
    'reviewStatus': normalizedReviewStatus,
    'reportedOutstandingAmountNgn': reportedOutstandingAmountNgn,
    'city': city.trim(),
    'fareBreakdown': _asStringDynamicMap(fareBreakdown),
    'countsTowardWallet':
        driverSettlementCountsTowardWallet(normalizedSettlementStatus),
    'businessModelSnapshot': normalizedBusinessModel,
  };
}

Map<String, dynamic> normalizedDriverBusinessModel(
  dynamic rawValue, {
  DateTime? now,
}) {
  final existing = _asStringDynamicMap(rawValue);
  final existingCommission = _firstMap(<dynamic>[
    existing['commission'],
    existing['commissionModel'],
    existing['commission_model'],
  ]);
  final existingSubscription = _firstMap(<dynamic>[
    existing['subscription'],
    existing['subscriptionModel'],
    existing['subscription_model'],
  ]);
  final existingPricingSnapshot = _firstMap(<dynamic>[
    existing['pricingSnapshot'],
    existing['pricing_snapshot'],
    existing['pricing'],
    existing['monetizationConfig'],
    existing['monetization_config'],
  ]);

  final selectedModel = (_text(existing['selectedModel']).isNotEmpty
              ? _text(existing['selectedModel'])
              : _text(existing['selected_model'])) ==
          'subscription'
      ? 'subscription'
      : 'commission';
  final commissionRate = _firstPositiveBusinessDouble(
    <dynamic>[
      existingPricingSnapshot['commissionRate'],
      existingPricingSnapshot['commission_rate'],
      existingCommission['rate'],
      existingCommission['commissionRate'],
      existingCommission['commission_rate'],
      existing['commissionRate'],
      existing['commission_rate'],
    ],
    fallback: DriverBusinessConfig.commissionRate,
  );
  final commissionRatePercent = commissionRate * 100;
  final weeklySubscriptionPriceNgn = _firstPositiveBusinessInt(
    <dynamic>[
      existingPricingSnapshot['weeklySubscriptionNgn'],
      existingPricingSnapshot['weekly_subscription_ngn'],
      existingSubscription['weeklyPriceNgn'],
      existingSubscription['weekly_price_ngn'],
      existing['weeklySubscriptionNgn'],
      existing['weekly_subscription_ngn'],
    ],
    fallback: DriverBusinessConfig.weeklySubscriptionPriceNgn,
  );
  final monthlySubscriptionPriceNgn = _firstPositiveBusinessInt(
    <dynamic>[
      existingPricingSnapshot['monthlySubscriptionNgn'],
      existingPricingSnapshot['monthly_subscription_ngn'],
      existingSubscription['monthlyPriceNgn'],
      existingSubscription['monthly_price_ngn'],
      existing['monthlySubscriptionNgn'],
      existing['monthly_subscription_ngn'],
    ],
    fallback: DriverBusinessConfig.monthlySubscriptionPriceNgn,
  );

  final commissionStatus = _text(existingCommission['status']).isNotEmpty
      ? _text(existingCommission['status'])
      : 'eligible';
  final subscriptionStatus = _normalizedSubscriptionStatusFromRecord(
    existingSubscription,
    now: now,
  );
  final defaultSubscriptionPriceLabel =
      'Weekly ${formatDriverNairaAmount(weeklySubscriptionPriceNgn)} • '
      'Monthly ${formatDriverNairaAmount(monthlySubscriptionPriceNgn)}';
  final subscriptionPlanType = _text(
    existingSubscription['planType'] ?? existingSubscription['plan_type'],
  ).isNotEmpty
      ? _text(
          existingSubscription['planType'] ?? existingSubscription['plan_type'])
      : 'monthly';
  final selectedModelLabel = selectedModel == 'subscription'
      ? _subscriptionPlanDisplayLabel(subscriptionPlanType)
      : 'Commission';
  final effectiveModel =
      selectedModel == 'subscription' && subscriptionStatus == 'active'
          ? 'subscription'
          : 'commission';
  final effectiveModelLabel = effectiveModel == 'subscription'
      ? _subscriptionPlanDisplayLabel(subscriptionPlanType)
      : 'Commission';

  final normalized = <String, dynamic>{
    'selectedModel': selectedModel,
    'selectedModelLabel': selectedModelLabel,
    'effectiveModel': effectiveModel,
    'effectiveModelLabel': effectiveModelLabel,
    'pricingSnapshot': <String, dynamic>{
      'commissionRate': commissionRate,
      'commissionRatePercent': commissionRatePercent,
      'weeklySubscriptionNgn': weeklySubscriptionPriceNgn,
      'monthlySubscriptionNgn': monthlySubscriptionPriceNgn,
      'updatedAt': existingPricingSnapshot['updatedAt'] ??
          existingPricingSnapshot['updated_at'] ??
          existing['updatedAt'] ??
          existing['updated_at'],
    },
    'commission': <String, dynamic>{
      'label': 'Commission model',
      'description':
          'Pay a flat ${formatDriverCommissionRatePercent(commissionRatePercent)}% commission on each completed trip.',
      'status': commissionStatus,
      'rate': commissionRate,
      'ratePercent': commissionRatePercent,
      'updatedAt':
          existingCommission['updatedAt'] ?? existingCommission['updated_at'],
    },
    'subscription': <String, dynamic>{
      'label': 'Subscription model',
      'description':
          'Choose a weekly or monthly plan and keep 100% of trip earnings while your subscription is active.',
      'status': subscriptionStatus,
      'paymentStatus': _text(
        existingSubscription['paymentStatus'] ??
            existingSubscription['payment_status'],
      ).isNotEmpty
          ? _text(
              existingSubscription['paymentStatus'] ??
                  existingSubscription['payment_status'],
            )
          : 'not_started',
      'planType': subscriptionPlanType,
      'planLabel': _subscriptionPlanDisplayLabel(subscriptionPlanType),
      'renewalDate': existingSubscription['renewalDate'] ??
          existingSubscription['renewal_date'] ??
          existingSubscription['validUntil'] ??
          existingSubscription['valid_until'],
      'weeklyPriceNgn': weeklySubscriptionPriceNgn,
      'monthlyPriceNgn': monthlySubscriptionPriceNgn,
      'priceLabel': defaultSubscriptionPriceLabel,
      'updatedAt': existingSubscription['updatedAt'] ??
          existingSubscription['updated_at'],
    },
    'updatedAt': existing['updatedAt'] ?? existing['updated_at'],
  };

  normalized['canGoOnline'] = _canGoOnlineFromNormalized(normalized);
  normalized['eligibilityStatus'] =
      _businessEligibilityStatusFromNormalized(normalized);
  return normalized;
}

Map<String, dynamic> normalizedDriverWallet(
  dynamic rawValue, {
  dynamic fallbackRoot,
  DateTime? now,
}) {
  final effectiveNow = now ?? DateTime.now();
  final existing = _asStringDynamicMap(rawValue);
  final root = _asStringDynamicMap(fallbackRoot);
  return <String, dynamic>{
    ...existing,
    'balance': _doubleValue(
      existing['balance'] ??
          existing['currentBalance'] ??
          root['balance'] ??
          existing['walletBalance'] ??
          root['walletBalance'] ??
          existing['availableBalance'],
    ),
    'currency': _text(existing['currency']).isNotEmpty
        ? _text(existing['currency'])
        : _text(root['currency']).isNotEmpty
            ? _text(root['currency'])
            : 'NGN',
    'last_updated': _timestampValue(
      existing['last_updated'] ??
          existing['lastUpdated'] ??
          existing['updated_at'] ??
          existing['updatedAt'] ??
          root['last_updated'] ??
          root['lastUpdated'] ??
          root['updated_at'] ??
          root['updatedAt'],
      fallback: effectiveNow.millisecondsSinceEpoch,
    ),
  };
}

Map<String, dynamic> normalizedDriverEarnings(
  dynamic rawValue, {
  dynamic fallbackRoot,
  DateTime? now,
}) {
  final effectiveNow = now ?? DateTime.now();
  final existing = _asStringDynamicMap(rawValue);
  final root = _asStringDynamicMap(fallbackRoot);
  return <String, dynamic>{
    ...existing,
    'total': _doubleValue(
      existing['total'] ??
          existing['totalEarnings'] ??
          existing['netTotal'] ??
          root['totalEarnings'] ??
          existing['earningsTotal'],
    ),
    'today': _doubleValue(
      existing['today'] ??
          existing['todayEarnings'] ??
          root['todayEarnings'] ??
          existing['daily'],
    ),
    'weekly': _doubleValue(
      existing['weekly'] ??
          existing['weeklyEarnings'] ??
          root['weeklyEarnings'],
    ),
    'monthly': _doubleValue(
      existing['monthly'] ??
          existing['monthlyEarnings'] ??
          root['monthlyEarnings'],
    ),
    'updated_at': _timestampValue(
      existing['updated_at'] ??
          existing['updatedAt'] ??
          existing['last_updated'] ??
          existing['lastUpdated'] ??
          root['updated_at'] ??
          root['updatedAt'],
      fallback: effectiveNow.millisecondsSinceEpoch,
    ),
  };
}

Map<String, dynamic> normalizedDriverSupportCounters(
  dynamic rawValue, {
  dynamic fallbackRoot,
  DateTime? now,
}) {
  final effectiveNow = now ?? DateTime.now();
  final existing = _asStringDynamicMap(rawValue);
  final root = _asStringDynamicMap(fallbackRoot);
  return <String, dynamic>{
    ...existing,
    'total': _intValue(existing['total'] ?? root['supportTicketCount']),
    'open': _intValue(
      existing['open'] ??
          existing['openTickets'] ??
          existing['open_tickets'] ??
          root['openSupportTickets'],
    ),
    'unreadReplies': _intValue(
      existing['unreadReplies'] ??
          existing['unread_replies'] ??
          existing['unread'] ??
          root['unreadSupportReplies'],
    ),
    'updated_at': _timestampValue(
      existing['updated_at'] ??
          existing['updatedAt'] ??
          existing['last_updated'] ??
          existing['lastUpdated'] ??
          root['updated_at'] ??
          root['updatedAt'],
      fallback: effectiveNow.millisecondsSinceEpoch,
    ),
  };
}

dynamic normalizedDriverTrips(
  dynamic rawValue, {
  dynamic fallbackRoot,
}) {
  final candidate = rawValue ?? fallbackRoot;
  if (candidate is List) {
    return candidate
        .map<dynamic>(
          (dynamic entry) => entry is Map ? _asStringDynamicMap(entry) : entry,
        )
        .toList(growable: false);
  }
  if (candidate is Map) {
    return candidate.map<String, dynamic>(
      (dynamic key, dynamic value) => MapEntry<String, dynamic>(
        key.toString(),
        value is Map ? _asStringDynamicMap(value) : value,
      ),
    );
  }
  return <String, dynamic>{};
}

String driverBusinessModelLabel(String selectedModel) {
  return driverBusinessModelLabelForPlan(
    selectedModel: selectedModel,
    subscriptionPlanType: 'monthly',
  );
}

String driverBusinessModelLabelForPlan({
  required String selectedModel,
  required String subscriptionPlanType,
}) {
  return selectedModel == 'subscription'
      ? _subscriptionPlanDisplayLabel(subscriptionPlanType)
      : 'Commission';
}

String driverSelectedMonetizationModeLabel(Map<String, dynamic> businessModel) {
  final normalized = normalizedDriverBusinessModel(businessModel);
  final label = _text(normalized['selectedModelLabel']);
  return label.isNotEmpty ? label : 'Commission';
}

String driverAppliedMonetizationModeLabel(
  Map<String, dynamic> businessModel, {
  DateTime? now,
}) {
  final normalized = normalizedDriverBusinessModel(businessModel, now: now);
  final label = _text(normalized['effectiveModelLabel']);
  return label.isNotEmpty ? label : 'Commission';
}

String driverBusinessEligibilityStatus(Map<String, dynamic> businessModel) {
  final normalized = normalizedDriverBusinessModel(businessModel);
  return _businessEligibilityStatusFromNormalized(normalized);
}

bool driverCanGoOnlineFromBusinessModel(Map<String, dynamic> businessModel) {
  final normalized = normalizedDriverBusinessModel(businessModel);
  return _canGoOnlineFromNormalized(normalized);
}

String driverBusinessEligibilityMessage(Map<String, dynamic> businessModel) {
  final normalized = normalizedDriverBusinessModel(businessModel);
  final selectedModel = _text(normalized['selectedModel']);
  final commission = _asStringDynamicMap(normalized['commission']);
  final commissionRateLabel = formatDriverCommissionRatePercent(
    commission['ratePercent'],
  );

  if (selectedModel == 'subscription') {
    final subscriptionStatus =
        _text(_asStringDynamicMap(normalized['subscription'])['status']);
    if (subscriptionStatus == 'active') {
      return 'Your subscription is active. You keep 100% of trip earnings while the plan remains valid.';
    }
    if (subscriptionStatus == 'expired') {
      return 'Your subscription has expired. Renew a weekly or monthly plan to keep 100% of trip earnings again.';
    }
    return 'Your subscription is not active yet. Until a valid plan is active, completed trips follow the standard $commissionRateLabel% commission rule.';
  }

  return driverCanGoOnlineFromBusinessModel(normalized)
      ? 'Your commission model is active. A $commissionRateLabel% commission is deducted from each completed trip.'
      : 'Your commission model is currently restricted from going online.';
}

String driverProfilePath(String driverId) => 'drivers/$driverId';

String driverVerificationAdminPath(String driverId) =>
    'driver_verifications/$driverId';

Map<String, dynamic> buildDriverProfileDefaults({
  required String driverId,
  required Map<String, dynamic> existing,
  String? fallbackName,
  String? fallbackEmail,
  String? fallbackPhone,
  Map<String, dynamic>? pricingConfig,
}) {
  final effectiveNow = DateTime.now();
  final isOnline = _boolValue(existing['isOnline'] ?? existing['online']);
  final isAvailable = _boolValue(
    existing['isAvailable'] ?? existing['available'],
  );
  final rawBusinessModel = _asStringDynamicMap(
    existing['businessModel'] ?? existing['business_model'],
  );
  final effectiveBusinessModel =
      pricingConfig != null && pricingConfig.isNotEmpty
          ? <String, dynamic>{
              ...rawBusinessModel,
              'pricingSnapshot': pricingConfig,
            }
          : rawBusinessModel;
  final lastAvailabilityIntent =
      _text(existing['last_availability_intent']).toLowerCase() == 'online'
          ? 'online'
          : 'offline';

  return <String, dynamic>{
    'id': driverId,
    'uid':
        _text(existing['uid']).isNotEmpty ? _text(existing['uid']) : driverId,
    'name': _text(existing['name']).isNotEmpty
        ? _text(existing['name'])
        : (fallbackName ?? 'Driver'),
    'email': _text(existing['email']).isNotEmpty
        ? _text(existing['email'])
        : (fallbackEmail ?? ''),
    'phone': _text(existing['phone']).isNotEmpty
        ? _text(existing['phone'])
        : (fallbackPhone ?? ''),
    'car': _text(existing['car']),
    'plate': _text(existing['plate']),
    'country': _text(existing['country']).isNotEmpty
        ? _text(existing['country'])
        : 'nigeria',
    'country_code': _text(existing['country_code']).isNotEmpty
        ? _text(existing['country_code'])
        : 'NG',
    'city': _text(existing['city']),
    'area': _text(existing['area']),
    'zone': _text(existing['zone']).isNotEmpty
        ? _text(existing['zone'])
        : _text(existing['area']),
    'community': _text(existing['community']).isNotEmpty
        ? _text(existing['community'])
        : _text(existing['area']),
    'launch_market_city': _text(existing['launch_market_city']).isNotEmpty
        ? _text(existing['launch_market_city'])
        : _text(existing['city']),
    'launch_market_country': _text(existing['launch_market_country']).isNotEmpty
        ? _text(existing['launch_market_country'])
        : 'Nigeria',
    'last_availability_intent':
        _text(existing['last_availability_intent']).isNotEmpty
            ? lastAvailabilityIntent
            : (isOnline ? 'online' : 'offline'),
    'isOnline': isOnline,
    'isAvailable': isAvailable,
    'available': isAvailable,
    'status': _text(existing['status']).isNotEmpty
        ? _text(existing['status'])
        : (isOnline ? 'idle' : 'offline'),
    'serviceTypes': _stringList(
      existing['serviceTypes'] ?? existing['service_types'],
      fallback: kDriverServiceTypes,
    ),
    'businessModel': normalizedDriverBusinessModel(
      effectiveBusinessModel,
      now: effectiveNow,
    ),
    'verification': normalizedDriverVerification(
      mergeDriverVerificationNodeWithAdminIdentity(
        verificationSubdoc: existing['verification'],
        identityVerificationStatus: existing['identity_verification_status'] ??
            existing['identityVerificationStatus'],
        verificationStatusField:
            existing['verification_status'] ?? existing['verificationStatus'],
      ),
    ),
    'wallet': normalizedDriverWallet(
      existing['wallet'] ?? existing['wallet_data'],
      fallbackRoot: existing,
      now: effectiveNow,
    ),
    'earnings': normalizedDriverEarnings(
      existing['earnings'] ??
          existing['earningSummary'] ??
          existing['earnings_summary'],
      fallbackRoot: existing,
      now: effectiveNow,
    ),
    'trips': normalizedDriverTrips(
      existing['trips'] ?? existing['tripHistory'] ?? existing['trip_history'],
    ),
    'supportCounters': normalizedDriverSupportCounters(
      existing['supportCounters'] ?? existing['support_counters'],
      fallbackRoot: existing,
      now: effectiveNow,
    ),
  };
}

Map<String, dynamic> buildDriverProfileRecord({
  required String driverId,
  required Map<String, dynamic> existing,
  String? fallbackName,
  String? fallbackEmail,
  String? fallbackPhone,
  Map<String, dynamic>? pricingConfig,
}) {
  final defaults = buildDriverProfileDefaults(
    driverId: driverId,
    existing: existing,
    fallbackName: fallbackName,
    fallbackEmail: fallbackEmail,
    fallbackPhone: fallbackPhone,
    pricingConfig: pricingConfig,
  );

  return <String, dynamic>{
    ...existing,
    ...defaults,
    'last_availability_intent': defaults['last_availability_intent'],
    'isOnline': defaults['isOnline'] == true,
    'isAvailable': defaults['isAvailable'] == true,
    'available': defaults['available'] == true,
    'status': defaults['status'],
    'serviceTypes': defaults['serviceTypes'],
    'businessModel': defaults['businessModel'],
    'verification': defaults['verification'],
    'wallet': defaults['wallet'],
    'earnings': defaults['earnings'],
    'trips': defaults['trips'],
    'supportCounters': defaults['supportCounters'],
  };
}

Map<String, dynamic> buildDriverBusinessModelAdminPayload({
  required String driverId,
  required Map<String, dynamic> driverProfile,
  required Map<String, dynamic> businessModel,
}) {
  final normalized = normalizedDriverBusinessModel(businessModel);
  return <String, dynamic>{
    'driverId': driverId,
    'driverName': _text(driverProfile['name']),
    'phone': _text(driverProfile['phone']),
    'selectedModel': normalized['selectedModel'],
    'appliedMonetizationModel': driverEffectiveMonetizationModel(normalized),
    'commissionRate': driverCommissionRateForBusinessModel(normalized),
    'commissionRatePercent':
        driverCommissionRateForBusinessModel(normalized) * 100,
    'subscriptionActive': driverSubscriptionIsActive(normalized),
    'canGoOnline': normalized['canGoOnline'],
    'eligibilityStatus': normalized['eligibilityStatus'],
    'businessModel': normalized,
  };
}

Map<String, dynamic> buildDriverVerificationAdminPayload({
  required String driverId,
  required Map<String, dynamic> driverProfile,
  required Map<String, dynamic> verification,
}) {
  final normalized = normalizedDriverVerification(verification);
  return <String, dynamic>{
    'driverId': driverId,
    'driverName': _text(driverProfile['name']),
    'phone': _text(driverProfile['phone']),
    'email': _text(driverProfile['email']),
    'businessModel': normalizedDriverBusinessModel(
      driverProfile['businessModel'],
    )['selectedModel'],
    ...normalized,
    'documentType': normalized['documentType'] ?? 'aggregate',
    'submittedAt': normalized['submittedAt'],
    'verificationProvider':
        normalized['verificationProvider'] ?? 'multi_provider',
    'providerReference': normalized['providerReference'] ?? '',
    'status': normalized['status'] ?? normalized['overallStatus'],
    'result': normalized['result'] ?? normalized['overallStatus'],
    'failureReason': normalized['failureReason'] ?? '',
    'reviewedAt': normalized['reviewedAt'],
    'reviewedBy': normalized['reviewedBy'] ?? '',
  };
}
