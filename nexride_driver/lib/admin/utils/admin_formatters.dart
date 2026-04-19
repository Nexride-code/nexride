import 'package:flutter/material.dart';

import '../admin_config.dart';

String formatAdminCurrency(num amount) {
  final absolute = amount.abs();
  final isWhole = absolute.truncateToDouble() == absolute.toDouble();
  final value =
      isWhole ? absolute.toStringAsFixed(0) : absolute.toStringAsFixed(2);
  final parts = value.split('.');
  final whole = parts.first;
  final withCommas = whole.replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (Match _) => ',',
  );
  final decimals = parts.length > 1 ? '.${parts[1]}' : '';
  return '${amount < 0 ? '-' : ''}₦$withCommas$decimals';
}

String formatAdminCompactNumber(num value) {
  final absolute = value.abs().toDouble();
  if (absolute >= 1000000) {
    return '${(value / 1000000).toStringAsFixed(1)}M';
  }
  if (absolute >= 1000) {
    return '${(value / 1000).toStringAsFixed(1)}K';
  }
  return value
      .toStringAsFixed(value is int || value == value.roundToDouble() ? 0 : 1);
}

String formatAdminDate(DateTime? value) {
  if (value == null) {
    return 'Not available';
  }
  return '${_monthShort(value.month)} ${value.day}, ${value.year}';
}

String formatAdminDateTime(DateTime? value) {
  if (value == null) {
    return 'Not available';
  }
  final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
  final minute = value.minute.toString().padLeft(2, '0');
  final period = value.hour >= 12 ? 'PM' : 'AM';
  return '${_monthShort(value.month)} ${value.day}, ${value.year} • $hour:$minute $period';
}

Color adminStatusColor(String status) {
  return switch (status.trim().toLowerCase()) {
    'active' ||
    'approved' ||
    'paid' ||
    'completed' ||
    'subscription' ||
    'weekly subscription' ||
    'monthly subscription' ||
    'verified' =>
      AdminThemeTokens.success,
    'pending' ||
    'requested' ||
    'assigned' ||
    'accepted' ||
    'arrived' ||
    'started' ||
    'processing' ||
    'under_review' ||
    'manual_review' ||
    'submitted' =>
      AdminThemeTokens.warning,
    'cancelled' ||
    'canceled' ||
    'inactive' ||
    'deactivated' ||
    'suspended' ||
    'failed' ||
    'rejected' ||
    'blacklisted' =>
      AdminThemeTokens.danger,
    _ => AdminThemeTokens.info,
  };
}

String sentenceCaseStatus(String status) {
  final normalized = status.trim().replaceAll('_', ' ');
  if (normalized.isEmpty) {
    return 'Unknown';
  }
  return normalized
      .split(' ')
      .where((String part) => part.isNotEmpty)
      .map(
        (String part) =>
            '${part[0].toUpperCase()}${part.substring(1).toLowerCase()}',
      )
      .join(' ');
}

String driverMonetizationStatusLabel({
  required String monetizationModel,
  required String subscriptionPlanType,
  required bool subscriptionActive,
}) {
  if (subscriptionActive ||
      monetizationModel.trim().toLowerCase() == 'subscription') {
    return subscriptionPlanType.trim().toLowerCase() == 'weekly'
        ? 'Weekly subscription'
        : 'Monthly subscription';
  }
  return 'Commission';
}

String _monthShort(int month) {
  return switch (month) {
    1 => 'Jan',
    2 => 'Feb',
    3 => 'Mar',
    4 => 'Apr',
    5 => 'May',
    6 => 'Jun',
    7 => 'Jul',
    8 => 'Aug',
    9 => 'Sep',
    10 => 'Oct',
    11 => 'Nov',
    _ => 'Dec',
  };
}
