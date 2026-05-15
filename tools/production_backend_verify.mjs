#!/usr/bin/env node
/**
 * Production backend verification (health + pricing).
 * Uses ADC or scripts/serviceAccountKey.json; never prints secrets.
 *
 * Optional env:
 *   ADMIN_EMAIL (default admin@nexride.africa)
 *   RIDER_TEST_EMAIL — if set, runs callable tamper checks as that rider
 */

import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const require = createRequire(path.join(ROOT, "scripts/package.json"));
const admin = require("firebase-admin");
const PROJECT_ID = "nexride-8d5bc";
const REGION = "us-central1";
const WEB_API_KEY = "AIzaSyBPKbsKmUCfq0ylIAuekiVko_Gu6wWQse4";
const ADMIN_EMAIL = process.env.ADMIN_EMAIL || "admin@nexride.africa";
const ADMIN_ID_TOKEN = String(process.env.ADMIN_ID_TOKEN || "").trim();
const RIDER_TEST_EMAIL = process.env.RIDER_TEST_EMAIL || "";
const RIDER_ID_TOKEN = String(process.env.RIDER_ID_TOKEN || "").trim();

function initAdmin() {
  if (admin.apps.length) return;
  const keyPath = path.join(ROOT, "scripts", "serviceAccountKey.json");
  if (process.env.GOOGLE_APPLICATION_CREDENTIALS) {
    admin.initializeApp({
      credential: admin.credential.applicationDefault(),
      projectId: PROJECT_ID,
      databaseURL: `https://${PROJECT_ID}-default-rtdb.firebaseio.com`,
    });
    return;
  }
  if (fs.existsSync(keyPath)) {
    const sa = JSON.parse(fs.readFileSync(keyPath, "utf8"));
    admin.initializeApp({
      credential: admin.credential.cert(sa),
      projectId: PROJECT_ID,
      databaseURL: `https://${PROJECT_ID}-default-rtdb.firebaseio.com`,
    });
    return;
  }
  admin.initializeApp({
    credential: admin.credential.applicationDefault(),
    projectId: PROJECT_ID,
    databaseURL: `https://${PROJECT_ID}-default-rtdb.firebaseio.com`,
  });
}

async function idTokenForUid(uid) {
  const custom = await admin.auth().createCustomToken(uid);
  const res = await fetch(
    `https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=${WEB_API_KEY}`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ token: custom, returnSecureToken: true }),
    },
  );
  const body = await res.json();
  if (!res.ok) {
    throw new Error(`signInWithCustomToken failed: ${body?.error?.message || res.status}`);
  }
  return body.idToken;
}

async function callCallable(name, idToken, data = {}) {
  const url = `https://${REGION}-${PROJECT_ID}.cloudfunctions.net/${name}`;
  const res = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${idToken}`,
    },
    body: JSON.stringify({ data }),
  });
  const text = await res.text();
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    json = { raw: text.slice(0, 500) };
  }
  if (!res.ok) {
    const err = json?.error || json;
    throw new Error(`${name} HTTP ${res.status}: ${err?.message || JSON.stringify(err)}`);
  }
  return json?.result ?? json;
}

function assert(cond, msg) {
  if (!cond) throw new Error(msg);
}

async function verifyHealth(adminToken) {
  const res = await callCallable("adminGetProductionHealthSnapshot", adminToken, {});
  assert(res?.success === true, "health snapshot success=false");
  const infra = res.snapshot?.infrastructure;
  assert(infra?.subsystems, "missing infrastructure.subsystems");
  const names = ["rtdb", "firestore", "auth", "storage", "functions"];
  for (const n of names) {
    assert(infra.subsystems[n], `missing subsystem ${n}`);
    const s = infra.subsystems[n];
    console.log(
      `  [health] ${n}: status=${s.status} reachable=${s.reachable} latency_ms=${s.latency_ms}` +
        (s.failure_reason ? ` failure_reason=${s.failure_reason}` : ""),
    );
  }
  const rtdb = infra.subsystems.rtdb;
  assert(rtdb.reachable === true, "RTDB probe unreachable (false RED risk)");
  assert(
    !String(rtdb.failure_reason || "").includes(".info/connected"),
    "RTDB still using client-only .info/connected probe",
  );
  assert(
    res.snapshot?.rider_payment_issues?.rider_wallet_count === undefined,
    "rider_wallet_count must not exist",
  );
  assert(
    res.snapshot?.rider_payment_issues?.rider_withdrawal_count === undefined,
    "rider_withdrawal_count must not exist",
  );
  console.log(`  [health] infrastructure.status=${infra.status} overall=${res.snapshot.overall_status}`);
  return res;
}

function verifyPricingModule() {
  process.chdir(path.join(ROOT, "nexride_driver", "functions"));
  const envPath = path.join(process.cwd(), ".env.nexride-8d5bc");
  if (fs.existsSync(envPath)) {
    const lines = fs.readFileSync(envPath, "utf8").split("\n");
    for (const line of lines) {
      const m = line.match(/^([A-Z0-9_]+)=(.*)$/);
      if (m) process.env[m[1]] = m[2];
    }
  }
  const {
    computeRiderPricing,
    assertClientTotalMatches,
  } = require(path.join(process.cwd(), "pricing_calculator.js"));

  const ride = computeRiderPricing({ flow: "ride_booking", trip_fare_ngn: 2500 });
  assert(ride.platform_fee_ngn === 30, `ride platform_fee ${ride.platform_fee_ngn}`);
  assert(ride.total_ngn === 2530, `ride total ${ride.total_ngn}`);

  const dispatch = computeRiderPricing({ flow: "dispatch_request", trip_fare_ngn: 1200 });
  assert(dispatch.platform_fee_ngn === 30, `dispatch platform_fee ${dispatch.platform_fee_ngn}`);

  const small = computeRiderPricing({
    flow: "food_order",
    subtotal_ngn: 500,
    delivery_fee_ngn: 200,
  });
  assert(small.platform_fee_ngn === 30, "merchant platform_fee");
  assert(small.small_order_fee_ngn === 15, "small_order_fee below threshold");
  assert(small.total_ngn === 745, `small order total ${small.total_ngn}`);

  const large = computeRiderPricing({
    flow: "food_order",
    subtotal_ngn: 5000,
    delivery_fee_ngn: 200,
  });
  assert(large.small_order_fee_ngn === 0, "small_order_fee at/above threshold");

  const tamper = assertClientTotalMatches(ride, 1000);
  assert(tamper.ok === false && tamper.reason_code === "pricing_total_mismatch", "tamper not rejected");

  assert(ride.rider_wallet_balance === undefined, "no rider_wallet in pricing");
  console.log("  [pricing] module checks PASS (production .env params)");
  process.chdir(ROOT);
}

async function verifyRideTamper(riderToken) {
  const lagosPickup = { lat: 6.5244, lng: 3.3792, address: "Lagos Island" };
  const res = await callCallable("createRideRequest", riderToken, {
    fare: 2500,
    total_ngn: 2500,
    pickup: lagosPickup,
    dropoff: { lat: 6.45, lng: 3.4, address: "Lagos dropoff" },
    market: "lagos",
    distance_km: 5,
    eta_min: 15,
    payment_method: "bank_transfer",
  });
  assert(
    res?.reason_code === "pricing_total_mismatch" || res?.reason === "total_mismatch",
    `expected pricing_total_mismatch, got ${JSON.stringify(res)}`,
  );
  console.log("  [pricing] createRideRequest rejects tampered total_ngn (production callable)");
}

async function adminTokenFromEnvOrSdk() {
  if (ADMIN_ID_TOKEN) {
    console.log("  [auth] using ADMIN_ID_TOKEN from environment");
    return ADMIN_ID_TOKEN;
  }
  initAdmin();
  const adminUser = await admin.auth().getUserByEmail(ADMIN_EMAIL);
  return idTokenForUid(adminUser.uid);
}

async function riderTokenFromEnvOrSdk() {
  if (RIDER_ID_TOKEN) {
    return RIDER_ID_TOKEN;
  }
  if (!RIDER_TEST_EMAIL) return null;
  initAdmin();
  const rider = await admin.auth().getUserByEmail(RIDER_TEST_EMAIL);
  return idTokenForUid(rider.uid);
}

async function main() {
  console.log("=== NexRide production backend verify ===\n");

  verifyPricingModule();

  const adminToken = await adminTokenFromEnvOrSdk();
  await verifyHealth(adminToken);

  const riderToken = await riderTokenFromEnvOrSdk();
  if (riderToken) {
    await verifyRideTamper(riderToken);
  } else {
    console.log(
      "  [pricing] skip live createRideRequest tamper test (set RIDER_TEST_EMAIL or RIDER_ID_TOKEN)",
    );
  }

  console.log("\n=== ALL CHECKS PASSED ===");
}

main().catch((e) => {
  console.error("\n=== VERIFY FAILED ===\n", e.message || e);
  process.exit(1);
});
