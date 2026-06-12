/**
 * Pricing quote callables — read app_config/pricing only (no new GCP services).
 */

const { loadAppPricingConfig } = require("./app_config_pricing");
const { quoteTripFare } = require("./fare_quote_engine");
const { computeRiderPricing } = require("./pricing_calculator");

function normUid(v) {
  return String(v ?? "").trim();
}

async function quoteRideFare(data, context, db) {
  if (!context.auth?.uid) {
    return { success: false, reason: "unauthorized" };
  }
  const market = String(data?.market ?? data?.city ?? "lagos").trim();
  const distanceKm = Number(data?.distance_km ?? data?.distanceKm ?? 0) || 0;
  const etaMin = Number(data?.eta_min ?? data?.etaMin ?? 0) || 0;
  const config = await loadAppPricingConfig(db);
  const quote = quoteTripFare({ config, cityOrMarket: market, distanceKm, etaMin, flow: "ride" });
  const pricing = computeRiderPricing(
    { flow: "ride_booking", trip_fare_ngn: quote.trip_fare_ngn },
    config,
  );
  return {
    success: true,
    quote: {
      ...quote,
      total_ngn: pricing.total_ngn,
      platform_fee_ngn: pricing.platform_fee_ngn,
      fee_breakdown: pricing.fee_breakdown,
    },
  };
}

async function quoteDeliveryFare(data, context, db) {
  if (!context.auth?.uid) {
    return { success: false, reason: "unauthorized" };
  }
  const market = String(data?.market ?? data?.city ?? "lagos").trim();
  const distanceKm = Number(data?.distance_km ?? data?.distanceKm ?? 0) || 0;
  const etaMin = Number(data?.eta_min ?? data?.etaMin ?? 0) || 0;
  const config = await loadAppPricingConfig(db);
  const quote = quoteTripFare({
    config,
    cityOrMarket: market,
    distanceKm,
    etaMin,
    flow: "delivery",
  });
  const pricing = computeRiderPricing(
    { flow: "dispatch_request", trip_fare_ngn: quote.trip_fare_ngn },
    config,
  );
  return {
    success: true,
    quote: {
      ...quote,
      total_ngn: pricing.total_ngn,
      platform_fee_ngn: pricing.platform_fee_ngn,
      fee_breakdown: pricing.fee_breakdown,
    },
  };
}

module.exports = {
  quoteRideFare,
  quoteDeliveryFare,
  normUid,
};
