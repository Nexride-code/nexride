import assert from "node:assert/strict";
import { test } from "node:test";
import { ACTORS, E2E_PROJECT_ID } from "../config/emulator.mjs";
import { assertNotProductionRuntime } from "../config/project-guard.mjs";
import { assertActiveTripPointers, assertActiveTripPointersCleared } from "../assertions/ride-pointers.mjs";
import { assertRideSettlement } from "../assertions/settlement.mjs";
import { getE2eRtdbTarget, rtdb } from "../lib/admin.mjs";
import { invokeCallable } from "../lib/callable-client.mjs";
import { runPrepaidRideIntentFlow } from "../lib/prepaid-ride-intent-flow.mjs";
import {
  logPrepaidSnapshot,
  prepaidRowAfterFailureSnapshot,
  readPrepaidRow,
} from "../lib/prepaid-diagnostics.mjs";
import { waitForRef } from "../lib/poll.mjs";
import { seedBaseline } from "../seed/seed-baseline.mjs";

const LAGOS_PICKUP = { lat: 6.5244, lng: 3.3792, address: "E2E Ride Pickup Lagos" };
const LAGOS_DROPOFF = { lat: 6.53, lng: 3.38, address: "E2E Ride Dropoff Lagos" };

test("Phase 1: ride happy path (prepaid intent → create → offer → accept → lifecycle → settlement)", async () => {
  assertNotProductionRuntime();

  const db = rtdb();
  const rtdbTarget = getE2eRtdbTarget();
  assert.equal(
    rtdbTarget.namespace,
    E2E_PROJECT_ID,
    "harness must read the Functions emulator RTDB namespace",
  );

  await seedBaseline();

  const fare = 5000;
  const callableRiderUid = ACTORS.riderId;
  const riderClaims = { email: ACTORS.riderEmail, name: "E2E Rider" };

  const { txRef, transactionId, totalNgn } = await runPrepaidRideIntentFlow({
    fare,
    pickup: LAGOS_PICKUP,
    dropoff: LAGOS_DROPOFF,
    riderUid: callableRiderUid,
    riderClaims,
  });

  const afterVerify = await readPrepaidRow(db, txRef);
  assert.equal(afterVerify.snap.exists(), true, "verified prepaid row must exist after verifyFlutterwavePayment");
  assert.equal(afterVerify.row?.verified, true);
  assert.equal(String(afterVerify.row?.consumed_ride_id ?? "").trim(), "");

  const createPayload = {
    prepaid_flutterwave_ref: txRef,
    total_ngn: totalNgn,
    distance_km: 2.5,
    eta_min: 12,
  };

  const createInvokeTxRefs = new Set();
  async function invokeCreateRideRequestOnce(payload, uid, claims) {
    const ref = String(payload?.prepaid_flutterwave_ref ?? "").trim();
    if (createInvokeTxRefs.has(ref)) {
      throw new Error(`E2E_CREATE_RIDE_REQUEST_DUPLICATE_INVOKE txRef=${ref}`);
    }
    createInvokeTxRefs.add(ref);
    return invokeCallable("createRideRequest", payload, uid, claims);
  }

  const createResult = await invokeCreateRideRequestOnce(
    createPayload,
    callableRiderUid,
    riderClaims,
  );

  assert.equal(createInvokeTxRefs.size, 1, "createRideRequest must be invoked exactly once for txRef");
  assert.equal(createInvokeTxRefs.has(txRef), true);

  if (!createResult?.success) {
    const afterFailure = await readPrepaidRow(db, txRef);
    logPrepaidSnapshot(
      "after_create_failure",
      txRef,
      prepaidRowAfterFailureSnapshot(afterFailure.row, afterFailure.snap.exists()),
      { createResult, callableRiderUid },
    );
    assert.fail(`createRideRequest failed: ${JSON.stringify(createResult)}`);
  }

  assert.notEqual(createResult?.reason, "card_not_linked", "card auth must be skipped for prepaid");
  const rideId = String(createResult?.rideId ?? "").trim();
  assert.ok(rideId, "rideId required");

  const rideAfterCreate = (await db.ref(`ride_requests/${rideId}`).get()).val();
  assert.equal(rideAfterCreate?.payment_status, "paid");
  assert.equal(String(rideAfterCreate?.payment_transaction_id ?? "").trim(), transactionId);
  assert.ok(
    ["requesting", "searching"].includes(String(rideAfterCreate?.trip_state ?? "")),
    `trip_state after create must be requesting or searching, got ${rideAfterCreate?.trip_state}`,
  );
  assert.equal(String(rideAfterCreate?.customer_transaction_reference ?? "").trim(), txRef);

  const consumedSnap = await db.ref(`payment_transactions/${txRef}`).get();
  assert.equal(String(consumedSnap.val()?.consumed_ride_id ?? "").trim(), rideId);

  const offerPath = `driver_offer_queue/${ACTORS.driverId}/${rideId}`;
  const { val: offer, elapsedMs: offerWaitMs } = await waitForRef(
    db,
    offerPath,
    (val) =>
      val != null &&
      (String(val?.ride_id ?? val?.rideId ?? "").trim() === rideId || typeof val === "object"),
    { timeoutMs: 25_000, label: offerPath },
  );
  console.log("E2E_WAIT_OFFER_OK", { rideId, elapsedMs: offerWaitMs });
  assert.ok(offer, "driver offer required");

  const acceptResult = await invokeCallable(
    "acceptRide",
    { rideId },
    ACTORS.driverId,
    { email: ACTORS.driverEmail },
  );
  console.log("E2E_ACCEPT_RIDE_RESULT", acceptResult);
  assert.equal(acceptResult?.success, true, JSON.stringify(acceptResult));

  await assertActiveTripPointers(db, {
    rideId,
    riderId: ACTORS.riderId,
    driverId: ACTORS.driverId,
  });

  const driverClaims = { email: ACTORS.driverEmail };
  const driverEnroutePayload = { rideId };
  const driverArrivedPayload = {
    rideId,
    ride_id: rideId,
    requestId: rideId,
    tripId: rideId,
  };
  const startTripPayload = { rideId };
  const completeTripPayload = { rideId };

  const enrouteResult = await invokeCallable(
    "driverEnroute",
    driverEnroutePayload,
    ACTORS.driverId,
    driverClaims,
  );
  console.log("E2E_DRIVER_ENROUTE_RESULT", enrouteResult);
  assert.equal(enrouteResult?.success, true, JSON.stringify(enrouteResult));

  const arrivedResult = await invokeCallable(
    "driverArrived",
    driverArrivedPayload,
    ACTORS.driverId,
    driverClaims,
  );
  console.log("E2E_DRIVER_ARRIVED_RESULT", arrivedResult);
  assert.equal(arrivedResult?.success, true, JSON.stringify(arrivedResult));

  const startResult = await invokeCallable(
    "startTrip",
    startTripPayload,
    ACTORS.driverId,
    driverClaims,
  );
  console.log("E2E_START_TRIP_RESULT", startResult);
  assert.equal(startResult?.success, true, JSON.stringify(startResult));

  const rideInProgress = (await db.ref(`ride_requests/${rideId}`).get()).val();
  assert.equal(rideInProgress?.trip_state, "on_trip");

  const completeResult = await invokeCallable(
    "completeTrip",
    completeTripPayload,
    ACTORS.driverId,
    driverClaims,
  );
  console.log("E2E_COMPLETE_TRIP_RESULT", completeResult);
  assert.equal(completeResult?.success, true, JSON.stringify(completeResult));

  await assertActiveTripPointersCleared(db, {
    rideId,
    riderId: ACTORS.riderId,
    driverId: ACTORS.driverId,
  });

  const settlement = await assertRideSettlement(db, { rideId, driverId: ACTORS.driverId });
  console.log("E2E_SETTLEMENT_OK", {
    rideId,
    finance_settled_at: settlement.ride?.finance_settled_at ?? null,
    settlementStatus: settlement.hook?.settlementStatus ?? null,
  });

  console.log("E2E_PHASE1_PASS", {
    projectId: E2E_PROJECT_ID,
    rideId,
    txRef,
    transactionId,
  });
});
