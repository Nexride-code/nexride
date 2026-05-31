import assert from "node:assert/strict";
import { ACTORS } from "../config/emulator.mjs";
import { invokeCallable } from "./callable-client.mjs";

/**
 * Production prepaid ride path via Functions emulator:
 * initiateFlutterwaveRideIntent → verifyFlutterwavePayment (verify_intent_only) → createRideRequest.
 */
export async function runPrepaidRideIntentFlow({
  fare = 5000,
  pickup,
  dropoff,
  distanceKm = 2.5,
  etaMin = 12,
  market = "lagos",
  riderUid = ACTORS.riderId,
  riderClaims = { email: ACTORS.riderEmail, name: "E2E Rider" },
}) {
  const intentPayload = {
    pickup,
    dropoff,
    fare,
    distance_km: distanceKm,
    eta_min: etaMin,
    market,
    market_pool: market,
    email: ACTORS.riderEmail,
    customer_name: "E2E Rider",
  };

  const intentResult = await invokeCallable(
    "initiateFlutterwaveRideIntent",
    intentPayload,
    riderUid,
    riderClaims,
  );

  assert.equal(intentResult?.success, true, JSON.stringify(intentResult));
  const txRef = String(intentResult?.tx_ref ?? "").trim();
  assert.ok(txRef, "initiateFlutterwaveRideIntent must return tx_ref");

  const verifyResult = await invokeCallable(
    "verifyFlutterwavePayment",
    { reference: txRef, verify_intent_only: true },
    riderUid,
    riderClaims,
  );

  assert.equal(verifyResult?.success, true, JSON.stringify(verifyResult));
  const transactionId = String(verifyResult?.transaction_id ?? "").trim();
  assert.ok(transactionId, "verifyFlutterwavePayment must return transaction_id");

  const totalNgn = Number(intentResult?.total_ngn ?? fare + 30);

  return {
    txRef,
    transactionId,
    totalNgn,
    intentResult,
    verifyResult,
  };
}
