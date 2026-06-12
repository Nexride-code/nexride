/**
 * Validate client fare against app_config/pricing and freeze quote on entity create.
 */

const { loadAppPricingConfig, pricingSnapshotFromConfig } = require("./app_config_pricing");
const { quoteTripFare, assertClientTripFareMatches } = require("./fare_quote_engine");
const { computeRiderPricing, assertClientTotalMatches } = require("./pricing_calculator");
const {
  findBestEligibleDiscount,
  enrichPricingSnapshotWithDiscount,
  normalizeAppliesTo,
} = require("./user_discounts");

async function validateAndFreezeEntityPricing(db, input) {
  const flow = String(input.flow ?? "ride_booking").trim();
  const market = String(input.market ?? input.city ?? "lagos").trim();
  const clientTripFare = Number(input.trip_fare_ngn ?? input.fare ?? 0);
  const distanceKm = Number(input.distance_km ?? input.distanceKm ?? 0) || 0;
  const etaMin = Number(input.eta_min ?? input.etaMin ?? 0) || 0;
  const clientTotalRaw = input.total_ngn ?? input.totalNgn;
  const riderUid = String(input.rider_id ?? input.riderId ?? input.user_id ?? input.userId ?? "").trim();

  if (!Number.isFinite(clientTripFare) || clientTripFare <= 0) {
    return { ok: false, reason: "invalid_fare" };
  }

  const config = await loadAppPricingConfig(db);
  const quoteFlow = flow === "dispatch_request" || flow === "dispatch_delivery" ? "delivery" : "ride";
  const serverQuote = quoteTripFare({
    config,
    cityOrMarket: market,
    distanceKm,
    etaMin,
    flow: quoteFlow,
  });

  if (distanceKm > 0 || etaMin > 0) {
    const fareMatch = assertClientTripFareMatches(serverQuote.trip_fare_ngn, clientTripFare);
    if (!fareMatch.ok) {
      return fareMatch;
    }
  }

  const tripFare = roundTripFare(serverQuote.trip_fare_ngn, clientTripFare);
  const pricing = computeRiderPricing(
    {
      flow,
      trip_fare_ngn: tripFare,
    },
    config,
  );

  let discountCtx = null;
  if (riderUid) {
    const appliesTo =
      quoteFlow === "delivery"
        ? "delivery"
        : flow.includes("merchant") || flow.includes("order")
          ? "merchant_order"
          : "ride";
    discountCtx = await findBestEligibleDiscount(db, riderUid, appliesTo, pricing.total_ngn);
    if (discountCtx?.discount_amount_ngn > 0) {
      pricing.total_ngn = Math.max(0, pricing.total_ngn - discountCtx.discount_amount_ngn);
      if (pricing.fee_breakdown && typeof pricing.fee_breakdown === "object") {
        pricing.fee_breakdown = {
          ...pricing.fee_breakdown,
          discount_applied_ngn: discountCtx.discount_amount_ngn,
          total_ngn: pricing.total_ngn,
        };
      }
    }
  }

  const totalMismatch = assertClientTotalMatches(pricing, clientTotalRaw);
  if (!totalMismatch.ok) {
    return totalMismatch;
  }

  let pricingSnapshot = pricingSnapshotFromConfig(
    config,
    tripFare,
    pricing.total_ngn,
    market,
    quoteFlow,
  );
  if (discountCtx?.discount_amount_ngn > 0) {
    pricingSnapshot = enrichPricingSnapshotWithDiscount(pricingSnapshot, discountCtx);
  }

  return {
    ok: true,
    config,
    pricing,
    trip_fare_ngn: tripFare,
    pricing_snapshot: pricingSnapshot,
    server_quote: serverQuote,
    discount: discountCtx
      ? {
          discount_id: discountCtx.discount.discountId,
          discount_amount_ngn: discountCtx.discount_amount_ngn,
          applies_to: normalizeAppliesTo(discountCtx.discount.applies_to ?? discountCtx.discount.appliesTo),
        }
      : null,
  };
}

function roundTripFare(server, client) {
  const s = Math.round(Math.max(0, Number(server) || 0));
  const c = Math.round(Math.max(0, Number(client) || 0));
  return s > 0 ? s : c;
}

module.exports = {
  validateAndFreezeEntityPricing,
};
