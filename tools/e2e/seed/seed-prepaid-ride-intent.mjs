import { ACTORS } from "../config/emulator.mjs";
import { rtdb } from "../lib/admin.mjs";

const PLATFORM_FEE_NGN = 30;

/**
 * Build ride_intent exactly like initiateFlutterwaveRideIntent (payment_flow.js).
 */
export function buildProductionRideIntent({
  pickup,
  dropoff,
  fare,
  totalNgn,
  feeBreakdown,
  market = "lagos",
  marketPool = "lagos",
  currency = "NGN",
  distanceKm = 2.5,
  etaMin = 12,
  serviceType = "ride",
}) {
  /** @type {Record<string, unknown>} */
  const rideIntent = {
    pickup,
    fare,
    platform_fee_ngn: PLATFORM_FEE_NGN,
    total_ngn: totalNgn,
    fee_breakdown: feeBreakdown,
    currency,
    distance_km: distanceKm,
    eta_min: etaMin,
    market,
    market_pool: marketPool,
    service_type: serviceType,
  };
  if (dropoff && typeof dropoff === "object") {
    rideIntent.dropoff = dropoff;
  }
  return rideIntent;
}

/**
 * Seed verified prepaid intent using the same two-step RTDB shape as production:
 * 1) initiateFlutterwaveRideIntent pending row
 * 2) persistVerifiedFlutterwaveCharge merge (verify intent / webhook)
 */
export async function seedPrepaidRideIntent({
  txRef,
  fare = 5000,
  pickup = { lat: 6.5244, lng: 3.3792, address: "E2E Ride Pickup Lagos" },
  dropoff = { lat: 6.53, lng: 3.38, address: "E2E Ride Dropoff Lagos" },
  transactionId = "e2e-flw-tx-ride-1",
  distanceKm = 2.5,
  etaMin = 12,
  market = "lagos",
  marketPool = "lagos",
}) {
  const ref = String(txRef ?? "").trim();
  if (!ref) {
    throw new Error("seedPrepaidRideIntent: txRef required");
  }

  const totalNgn = fare + PLATFORM_FEE_NGN;
  const now = Date.now();
  const currency = "NGN";
  const feeBreakdown = {
    subtotal_ngn: fare,
    delivery_fee_ngn: 0,
    platform_fee_ngn: PLATFORM_FEE_NGN,
    small_order_fee_ngn: 0,
    total_ngn: totalNgn,
    small_order_threshold_ngn: 3000,
  };

  const rideIntent = buildProductionRideIntent({
    pickup,
    dropoff,
    fare,
    totalNgn,
    feeBreakdown,
    market,
    marketPool,
    currency,
    distanceKm,
    etaMin,
  });

  const path = `payment_transactions/${ref}`;

  // Step 1 — initiateFlutterwaveRideIntent pending row (no null keys).
  await rtdb().ref(path).set({
    tx_ref: ref,
    rider_id: ACTORS.riderId,
    amount: totalNgn,
    currency,
    ride_intent: rideIntent,
    fee_breakdown: feeBreakdown,
    status: "pending",
    intent: true,
    provider_link: "e2e-local-no-network",
    verified: false,
    created_at: now,
    updated_at: now,
  });

  // Step 2 — persistVerifiedFlutterwaveCharge merge for verified intent.
  await rtdb().ref(path).update({
    provider: "flutterwave",
    transaction_id: transactionId,
    flutterwave_transaction_id: transactionId,
    status: "verified",
    raw_status: "successful",
    verified: true,
    verified_at: now,
    webhook_applied: true,
    provider_status: "successful",
    provider_payload: { event: "e2e_seed_verify", data: { status: "successful" } },
    updated_at: now,
  });

  return {
    txRef: ref,
    fare,
    totalNgn,
    transactionId,
    rideIntent,
    feeBreakdown,
  };
}
