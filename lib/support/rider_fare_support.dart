import 'dart:math' as math;

import '../config/rider_app_config.dart';

class RiderFareBreakdown {
  const RiderFareBreakdown({
    required this.serviceKey,
    required this.city,
    required this.baseFare,
    required this.distanceKm,
    required this.durationMin,
    required this.perKmRate,
    required this.perMinuteRate,
    required this.minimumFare,
    required this.surgeMultiplier,
    required this.trafficWindowLabel,
    required this.calculatedFare,
    required this.minimumAdjustedFare,
    required this.minimumFareApplied,
    required this.totalFare,
  });

  final String serviceKey;
  final String city;
  final double baseFare;
  final double distanceKm;
  final double durationMin;
  final double perKmRate;
  final double perMinuteRate;
  final double minimumFare;
  final double surgeMultiplier;
  final String trafficWindowLabel;
  final double calculatedFare;
  final double minimumAdjustedFare;
  final bool minimumFareApplied;
  final double totalFare;

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'serviceKey': serviceKey,
      'market': city,
      'baseFare': baseFare,
      'distanceKm': distanceKm,
      'durationMin': durationMin,
      'perKmRate': perKmRate,
      'perMinuteRate': perMinuteRate,
      'minimumFare': minimumFare,
      'surgeMultiplier': surgeMultiplier,
      'trafficMultiplier': surgeMultiplier,
      'trafficWindowLabel': trafficWindowLabel,
      'calculatedFare': calculatedFare,
      'subtotal': calculatedFare,
      'minimumAdjustedFare': minimumAdjustedFare,
      'minimumFareApplied': minimumFareApplied,
      'waitingCharge': 0.0,
      'finalFare': totalFare,
      'totalFare': totalFare,
    };
  }
}

double estimateRiderDurationMinutes({
  required double distanceKm,
  int? durationSeconds,
}) {
  final safeDistanceKm = distanceKm.isFinite && distanceKm > 0
      ? distanceKm
      : 0.0;
  final directDurationMinutes = durationSeconds != null && durationSeconds > 0
      ? durationSeconds / 60
      : (safeDistanceKm / RiderFareSettings.averageSpeedKmPerHour) * 60;

  return math.max(
    RiderFareSettings.minimumDurationMinutes.toDouble(),
    directDurationMinutes,
  );
}

RiderFareBreakdown calculateRiderFare({
  required String serviceKey,
  required String city,
  required double distanceKm,
  double? durationMin,
  int? durationSeconds,
  DateTime? requestTime,
  double? surgeMultiplier,
}) {
  final safeDistanceKm = distanceKm.isFinite && distanceKm > 0
      ? distanceKm
      : 0.0;
  final safeDurationMin =
      durationMin != null && durationMin.isFinite && durationMin > 0
      ? durationMin
      : estimateRiderDurationMinutes(
          distanceKm: safeDistanceKm,
          durationSeconds: durationSeconds,
        );
  final normalizedCity = RiderFareSettings.normalizeSupportedCity(city);
  if (normalizedCity == null) {
    throw StateError('Unsupported NexRide pricing city: $city');
  }
  final configuredTrafficWindow = RiderFareSettings.activeTrafficWindowForCity(
    normalizedCity,
    at: requestTime,
  );
  final resolvedMultiplier =
      surgeMultiplier ??
      RiderFareSettings.trafficMultiplierForCity(
        normalizedCity,
        at: requestTime,
      );
  final safeSurgeMultiplier =
      resolvedMultiplier.isFinite && resolvedMultiplier > 0
      ? resolvedMultiplier
      : RiderFareSettings.defaultSurgeMultiplier;
  final rule = RiderFareSettings.forCity(normalizedCity);
  final calculatedFare =
      rule.baseFare +
      (safeDistanceKm * rule.perKmRate) +
      (safeDurationMin * rule.perMinuteRate);
  final minimumAdjustedFare = math.max(calculatedFare, rule.minimumFare);
  final totalFare = minimumAdjustedFare * safeSurgeMultiplier;

  return RiderFareBreakdown(
    serviceKey: serviceKey,
    city: normalizedCity,
    baseFare: double.parse(rule.baseFare.toStringAsFixed(2)),
    distanceKm: double.parse(safeDistanceKm.toStringAsFixed(2)),
    durationMin: double.parse(safeDurationMin.toStringAsFixed(2)),
    perKmRate: double.parse(rule.perKmRate.toStringAsFixed(2)),
    perMinuteRate: double.parse(rule.perMinuteRate.toStringAsFixed(2)),
    minimumFare: double.parse(rule.minimumFare.toStringAsFixed(2)),
    surgeMultiplier: double.parse(safeSurgeMultiplier.toStringAsFixed(2)),
    trafficWindowLabel: configuredTrafficWindow?.label ?? 'standard',
    calculatedFare: double.parse(calculatedFare.toStringAsFixed(2)),
    minimumAdjustedFare: double.parse(minimumAdjustedFare.toStringAsFixed(2)),
    minimumFareApplied:
        minimumAdjustedFare > calculatedFare && safeSurgeMultiplier > 0,
    totalFare: double.parse(totalFare.toStringAsFixed(2)),
  );
}
