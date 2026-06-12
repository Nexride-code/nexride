/**
 * Immutable complete pricing snapshot frozen at ride/delivery create time.
 * Settlement and Flutterwave verification must read ONLY this snapshot.
 */

const {
  normalizePricingConfig,
  resolveCityRule,
  deliveryRuleFromCityRule,
  roundNgn,
  computeBookingFeeNgn,
  commissionRateFromEntity,
  bookingFeeFromEntity,
} = require("./app_config_pricing");

/**
 * @param {{ config: object, cityOrMarket: string, flow?: 'ride'|'delivery', tripFareNgn: number, totalNgn: number }}
 */
function buildCompletePricingSnapshot({
  config,
  cityOrMarket,
  flow = "ride",
  tripFareNgn,
  totalNgn,
}) {
  const cfg = normalizePricingConfig(config);
  const cityRule = resolveCityRule(cfg, cityOrMarket);
  const fareRule = flow === "delivery" ? deliveryRuleFromCityRule(cityRule) : cityRule;
  const now = Date.now();
  const pricingFlow = flow === "delivery" ? "dispatch_request" : "ride_booking";
  const policy = flow === "delivery" ? cfg.dispatch : cfg.rides;
  const bookingFeeNgn = computeBookingFeeNgn(cfg, tripFareNgn, pricingFlow);
  const snapshot = {
    commission_rate: cfg.commissionRate,
    booking_fee_ngn: bookingFeeNgn,
    booking_fee_mode: policy.bookingFeeMode,
    booking_fee_percent: policy.bookingFeePercent,
    booking_fee_min_ngn: policy.bookingFeeMinNgn,
    booking_fee_max_ngn: policy.bookingFeeMaxNgn,
    booking_fee_fixed_ngn: policy.bookingFeeNgn,
    delivery_fee_ngn: flow === "delivery" ? roundNgn(tripFareNgn) : undefined,
    booking_fee_scope: flow === "delivery" ? "dispatch" : "ride",
    base_fare_ngn: fareRule.baseFareNgn,
    per_km_ngn: fareRule.perKmNgn,
    per_minute_ngn: fareRule.perMinuteNgn,
    minimum_fare_ngn: fareRule.minimumFareNgn,
    pricing_version: cfg.updatedAt > 0 ? cfg.updatedAt : now,
    total_ngn: roundNgn(totalNgn),
    trip_fare_ngn: roundNgn(tripFareNgn),
    city_slug: cityRule.slug,
    quoted_at: now,
    frozen: true,
  };
  if (snapshot.delivery_fee_ngn == null) {
    delete snapshot.delivery_fee_ngn;
  }
  return Object.freeze(snapshot);
}

function pricingSnapshotFromConfig(config, tripFareNgn, totalNgn, cityOrMarket = "lagos", flow = "ride") {
  return buildCompletePricingSnapshot({
    config,
    cityOrMarket,
    flow,
    tripFareNgn,
    totalNgn,
  });
}

function readFrozenSnapshot(entity) {
  const snap = entity?.pricing_snapshot;
  return snap && typeof snap === "object" ? snap : null;
}

function frozenTotalNgn(entity) {
  const snap = readFrozenSnapshot(entity);
  if (snap && roundNgn(snap.total_ngn) > 0) {
    return roundNgn(snap.total_ngn);
  }
  return roundNgn(entity?.total_ngn ?? 0);
}

module.exports = {
  buildCompletePricingSnapshot,
  pricingSnapshotFromConfig,
  readFrozenSnapshot,
  frozenTotalNgn,
  commissionRateFromEntity,
  bookingFeeFromEntity,
  roundNgn,
};
