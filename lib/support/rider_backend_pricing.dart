import 'package:flutter/material.dart';

/// Server-authoritative rider pricing (NGN). Riders have no wallets — card/bank only.
class RiderBackendPricingQuote {
  /// Display-only mirrors of production params (not used for payment).
  static const int policyPlatformFeeNgn = 30;
  static const int policySmallOrderFeeNgn = 15;
  static const int policySmallOrderThresholdNgn = 3000;
  const RiderBackendPricingQuote({
    this.subtotalNgn = 0,
    this.deliveryFeeNgn = 0,
    this.tripFareNgn = 0,
    this.platformFeeNgn = 0,
    this.smallOrderFeeNgn = 0,
    this.totalNgn = 0,
    this.isPreview = false,
  });

  final int subtotalNgn;
  final int deliveryFeeNgn;
  final int tripFareNgn;
  final int platformFeeNgn;
  final int smallOrderFeeNgn;
  final int totalNgn;
  final bool isPreview;

  bool get hasAuthoritativeTotal => totalNgn > 0 && !isPreview;

  bool get showsSmallOrderFee => smallOrderFeeNgn > 0;

  bool get showsPlatformFee => platformFeeNgn > 0;

  static bool isPricingTotalMismatch(Map<String, dynamic>? res) {
    if (res == null) return false;
    final code = res['reason_code']?.toString().trim() ?? '';
    final reason = res['reason']?.toString().trim() ?? '';
    return code == 'pricing_total_mismatch' || reason == 'total_mismatch';
  }

  static String pricingMismatchUserMessage([Map<String, dynamic>? res]) {
    final msg = res?['message']?.toString().trim();
    if (msg != null && msg.isNotEmpty) {
      return msg;
    }
    return 'The price changed on our servers. Pull to refresh your fare, then try again.';
  }

  static RiderBackendPricingQuote? tryFromMap(Map<String, dynamic>? map) {
    if (map == null || map.isEmpty) return null;
    final fbRaw = map['fee_breakdown'];
    final fb = fbRaw is Map
        ? Map<String, dynamic>.from(fbRaw as Map)
        : <String, dynamic>{};

    int readInt(dynamic v) {
      if (v is int) return v;
      if (v is double) return v.round();
      return int.tryParse(v?.toString() ?? '') ?? 0;
    }

    final total = readInt(map['total_ngn'] ?? map['totalNgn'] ?? fb['total_ngn']);
    final platform = readInt(
      map['platform_fee_ngn'] ?? map['platformFeeNgn'] ?? fb['platform_fee_ngn'],
    );
    final small = readInt(
      map['small_order_fee_ngn'] ?? map['smallOrderFeeNgn'] ?? fb['small_order_fee_ngn'],
    );
    final subtotal = readInt(map['subtotal_ngn'] ?? fb['subtotal_ngn']);
    final delivery = readInt(map['delivery_fee_ngn'] ?? fb['delivery_fee_ngn']);
    final tripFare = readInt(map['fare'] ?? map['trip_fare_ngn'] ?? subtotal);

    if (total <= 0 && platform <= 0 && tripFare <= 0 && subtotal <= 0) {
      return null;
    }

    return RiderBackendPricingQuote(
      subtotalNgn: subtotal > 0 ? subtotal : tripFare,
      deliveryFeeNgn: delivery,
      tripFareNgn: tripFare,
      platformFeeNgn: platform,
      smallOrderFeeNgn: small,
      totalNgn: total,
    );
  }

  /// Route-estimate display only — total mirrors server policy until backend responds.
  factory RiderBackendPricingQuote.previewTripFare(int tripFareNgn) {
    final platform = policyPlatformFeeNgn;
    return RiderBackendPricingQuote(
      tripFareNgn: tripFareNgn,
      subtotalNgn: tripFareNgn,
      platformFeeNgn: platform,
      totalNgn: tripFareNgn + platform,
      isPreview: true,
    );
  }

  /// Checkout sheet estimate — small-order line only when policy threshold applies.
  factory RiderBackendPricingQuote.previewCommerce({
    required int subtotalNgn,
    required int deliveryFeeNgn,
  }) {
    final platform = policyPlatformFeeNgn;
    final small = subtotalNgn > 0 && subtotalNgn < policySmallOrderThresholdNgn
        ? policySmallOrderFeeNgn
        : 0;
    return RiderBackendPricingQuote(
      subtotalNgn: subtotalNgn,
      deliveryFeeNgn: deliveryFeeNgn,
      platformFeeNgn: platform,
      smallOrderFeeNgn: small,
      totalNgn: subtotalNgn + deliveryFeeNgn + platform + small,
      isPreview: true,
    );
  }
}

class RiderBackendPricingBreakdown extends StatelessWidget {
  const RiderBackendPricingBreakdown({
    super.key,
    required this.quote,
    this.tripFareLabel = 'Trip fare',
    this.subtotalLabel = 'Items subtotal',
    this.compact = false,
  });

  final RiderBackendPricingQuote quote;
  final String tripFareLabel;
  final String subtotalLabel;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final lines = <_Line>[];
    final trip = quote.tripFareNgn > 0 ? quote.tripFareNgn : quote.subtotalNgn;
    if (trip > 0) {
      lines.add(_Line(subtotalLabel != 'Items subtotal' ? tripFareLabel : subtotalLabel, trip));
    } else if (quote.subtotalNgn > 0) {
      lines.add(_Line(subtotalLabel, quote.subtotalNgn));
    }
    if (quote.deliveryFeeNgn > 0) {
      lines.add(_Line('Delivery fee', quote.deliveryFeeNgn));
    }
    if (quote.showsPlatformFee) {
      lines.add(_Line('Platform / booking fee', quote.platformFeeNgn));
    }
    if (quote.showsSmallOrderFee) {
      lines.add(_Line('Small-order fee', quote.smallOrderFeeNgn));
    }

    final totalStyle = TextStyle(
      fontSize: compact ? 14 : 16,
      fontWeight: FontWeight.w800,
      color: Theme.of(context).colorScheme.onSurface,
    );
    final lineStyle = TextStyle(
      fontSize: compact ? 12 : 13,
      fontWeight: FontWeight.w600,
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.72),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final line in lines)
          Padding(
            padding: EdgeInsets.only(bottom: compact ? 4 : 6),
            child: Row(
              children: <Widget>[
                Expanded(child: Text(line.label, style: lineStyle)),
                Text('₦${line.amountNgn}', style: lineStyle),
              ],
            ),
          ),
        if (quote.totalNgn > 0) ...<Widget>[
          const Divider(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  quote.isPreview ? 'Estimated total' : 'Total',
                  style: totalStyle,
                ),
              ),
              Text('₦${quote.totalNgn}', style: totalStyle),
            ],
          ),
          if (quote.isPreview) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              'Final amount is confirmed by NexRide at checkout.',
              style: lineStyle.copyWith(fontSize: 11, fontStyle: FontStyle.italic),
            ),
          ],
        ],
      ],
    );
  }
}

class _Line {
  const _Line(this.label, this.amountNgn);
  final String label;
  final int amountNgn;
}
