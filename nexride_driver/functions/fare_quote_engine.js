/**
 * Server-side fare quotes from `app_config/pricing` city rules.
 */

const {
  normalizePricingConfig,
  resolveCityRule,
  deliveryRuleFromCityRule,
  roundNgn,
} = require("./app_config_pricing");

function computeDistanceTimeFare({ baseFareNgn, perKmNgn, perMinuteNgn, minimumFareNgn, distanceKm, etaMin }) {
  const base = roundNgn(baseFareNgn);
  const km = Math.max(0, Number(distanceKm) || 0);
  const min = Math.max(0, Number(etaMin) || 0);
  const raw = base + roundNgn(km * perKmNgn) + roundNgn(min * perMinuteNgn);
  const minimum = roundNgn(minimumFareNgn);
  return minimum > 0 ? Math.max(raw, minimum) : raw;
}

/**
 * @param {{ config?: object, cityOrMarket: string, distanceKm?: number, etaMin?: number, flow?: 'ride'|'delivery' }}
 */
function quoteTripFare({ config, cityOrMarket, distanceKm = 0, etaMin = 0, flow = "ride" }) {
  const cfg = normalizePricingConfig(config);
  const cityRule = resolveCityRule(cfg, cityOrMarket);
  const fareRule =
    flow === "delivery" ? deliveryRuleFromCityRule(cityRule) : cityRule;
  const tripFareNgn = computeDistanceTimeFare({
    baseFareNgn: fareRule.baseFareNgn,
    perKmNgn: fareRule.perKmNgn,
    perMinuteNgn: fareRule.perMinuteNgn,
    minimumFareNgn: fareRule.minimumFareNgn,
    distanceKm,
    etaMin,
  });
  return {
    city: cityRule.city,
    city_slug: cityRule.slug,
    flow,
    trip_fare_ngn: tripFareNgn,
    fare_rule: fareRule,
    config_updated_at: cfg.updatedAt,
    commission_rate: cfg.commissionRate,
    booking_fee_ngn: cfg.bookingFeeNgn,
  };
}

function assertClientTripFareMatches(serverTripFareNgn, clientTripFareNgn, toleranceNgn = 1) {
  const server = roundNgn(serverTripFareNgn);
  const client = roundNgn(clientTripFareNgn);
  if (server <= 0 || client <= 0) {
    return { ok: true };
  }
  if (Math.abs(server - client) <= toleranceNgn) {
    return { ok: true, trip_fare_ngn: server };
  }
  return {
    ok: false,
    reason: "fare_quote_mismatch",
    reason_code: "fare_quote_mismatch",
    message: "Trip fare does not match server pricing. Refresh the quote and try again.",
    retryable: true,
    expected_trip_fare_ngn: server,
    client_trip_fare_ngn: client,
  };
}

module.exports = {
  computeDistanceTimeFare,
  quoteTripFare,
  assertClientTripFareMatches,
};
