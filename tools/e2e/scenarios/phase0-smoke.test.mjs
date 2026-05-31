import assert from "node:assert/strict";
import { test } from "node:test";
import { ACTORS, E2E_PROJECT_ID, EMULATOR } from "../config/emulator.mjs";
import { assertNotProductionRuntime, isBlockedProjectId } from "../config/project-guard.mjs";
import { rtdb } from "../lib/admin.mjs";
import { invokeCallable } from "../lib/callable-client.mjs";
import { seedBaseline } from "../seed/seed-baseline.mjs";

test("project guard rejects production project id", () => {
  assert.equal(isBlockedProjectId("nexride-8d5bc"), true);
  assert.equal(isBlockedProjectId(E2E_PROJECT_ID), false);
  assert.throws(() => assertNotProductionRuntime("nexride-8d5bc"));
});

test("Phase 0 smoke: emulators, seed, createDeliveryRequest", async () => {
  assertNotProductionRuntime();

  const rtdbHost = process.env.FIREBASE_DATABASE_EMULATOR_HOST;
  const authHost = process.env.FIREBASE_AUTH_EMULATOR_HOST;
  const fsHost = process.env.FIRESTORE_EMULATOR_HOST;

  assert.ok(rtdbHost, "FIREBASE_DATABASE_EMULATOR_HOST must be set");
  assert.ok(authHost, "FIREBASE_AUTH_EMULATOR_HOST must be set");
  assert.ok(fsHost, "FIRESTORE_EMULATOR_HOST must be set");
  assert.match(rtdbHost, /127\.0\.0\.1|localhost/);
  assert.doesNotMatch(rtdbHost, /firebaseio\.com/);

  console.log("E2E_PHASE0_ENV", {
    projectId: E2E_PROJECT_ID,
    rtdbHost,
    authHost,
    fsHost,
    functionsHost: process.env.FIREBASE_FUNCTIONS_EMULATOR_HOST || "(sdk default)",
  });

  const db = rtdb();
  const pingPath = "e2e/phase0_ping";
  const pingAt = Date.now();
  await db.ref(pingPath).set({ ok: true, at: pingAt, project_id: E2E_PROJECT_ID });
  const pingSnap = await db.ref(pingPath).get();
  assert.equal(pingSnap.val()?.project_id, E2E_PROJECT_ID);

  const seed = await seedBaseline();
  assert.equal(seed.riderId, ACTORS.riderId);
  assert.equal(seed.driverId, ACTORS.driverId);

  const driverSnap = await db.ref(`drivers/${ACTORS.driverId}`).get();
  assert.equal(driverSnap.val()?.dispatch_market, "lagos");

  const fare = 5000;
  const totalNgn = fare + 30;
  const payload = {
    market: "lagos",
    pickup: { lat: 6.5244, lng: 3.3792, address: "E2E Pickup Lagos" },
    dropoff: { lat: 6.53, lng: 3.38, address: "E2E Dropoff Lagos" },
    package_description: "E2E Phase 0 parcel",
    recipient_name: "E2E Recipient",
    recipient_phone: "+2348012345678",
    category: "parcel",
    fare,
    total_ngn: totalNgn,
    payment_method: "flutterwave",
    distance_km: 2.5,
    eta_minutes: 12,
  };

  let createResult;
  try {
    createResult = await invokeCallable(
      "createDeliveryRequest",
      payload,
      ACTORS.riderId,
      { email: ACTORS.riderEmail, name: "E2E Rider" },
    );
  } catch (err) {
    const msg = err && typeof err === "object" && "message" in err ? String(err.message) : String(err);
    throw new Error(`createDeliveryRequest callable failed: ${msg}`);
  }

  assert.equal(createResult?.success, true, JSON.stringify(createResult));
  const deliveryId = String(createResult?.deliveryId ?? "").trim();
  assert.ok(deliveryId, "deliveryId required");

  const deliverySnap = await db.ref(`delivery_requests/${deliveryId}`).get();
  assert.equal(deliverySnap.exists(), true);
  assert.equal(deliverySnap.val()?.customer_id, ACTORS.riderId);
  assert.equal(deliverySnap.val()?.delivery_state, "searching");
  assert.equal(deliverySnap.val()?.payment_status, "pending");

  const userActiveSnap = await db.ref(`user_active_delivery/${ACTORS.riderId}`).get();
  assert.equal(userActiveSnap.val()?.delivery_id, deliveryId);

  console.log("E2E_PHASE0_PASS", {
    projectId: E2E_PROJECT_ID,
    deliveryId,
    emulators: {
      auth: `${EMULATOR.authHost}:${EMULATOR.authPort}`,
      rtdb: `${EMULATOR.rtdbHost}:${EMULATOR.rtdbPort}`,
      firestore: `${EMULATOR.firestoreHost}:${EMULATOR.firestorePort}`,
      functions: `${EMULATOR.functionsHost}:${EMULATOR.functionsPort}`,
    },
    productionBlocked: "nexride-8d5bc",
    costUsd: 0,
  });
});
