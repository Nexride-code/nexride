class DispatchPaymentBreakdown {
  const DispatchPaymentBreakdown({
    required this.baseFare,
    required this.distanceKm,
    required this.pricePerKm,
    required this.totalDeliveryFee,
    required this.nexrideFee,
    required this.riderEarning,
  });

  final double baseFare;
  final double distanceKm;
  final double pricePerKm;
  final double totalDeliveryFee;
  final double nexrideFee;
  final double riderEarning;
}

const double kDispatchNexridePlatformFeeNgn = 350;

DispatchPaymentBreakdown buildDispatchPaymentBreakdown({
  required double baseFare,
  required double distanceKm,
  required double pricePerKm,
  double nexrideFee = kDispatchNexridePlatformFeeNgn,
}) {
  if (distanceKm <= 0) {
    throw StateError('Dispatch distance calculation failed.');
  }
  if (baseFare < 0 || pricePerKm < 0) {
    throw StateError('Dispatch fare inputs must be non-negative.');
  }

  final totalDeliveryFee = baseFare + (distanceKm * pricePerKm);
  if (totalDeliveryFee <= nexrideFee) {
    throw StateError('Dispatch fare must be greater than platform fee.');
  }

  final riderEarning = totalDeliveryFee - nexrideFee;
  if (riderEarning < 0) {
    throw StateError('Dispatch rider earning cannot be negative.');
  }

  return DispatchPaymentBreakdown(
    baseFare: baseFare,
    distanceKm: distanceKm,
    pricePerKm: pricePerKm,
    totalDeliveryFee: totalDeliveryFee,
    nexrideFee: nexrideFee,
    riderEarning: riderEarning,
  );
}
