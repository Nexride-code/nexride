import { randomBytes } from "node:crypto";
import admin from "firebase-admin";
import {
  E2E_PROJECT_ID,
  E2E_RTDB_DEFAULT_INSTANCE,
  E2E_RTDB_LEGACY_INSTANCE,
  buildE2eRtdbDatabaseUrl,
  resolveE2eRtdbDatabaseUrl,
} from "./rtdb-namespace.mjs";

export function uniquePrepaidTxRef(prefix = "e2e_ride_prepaid") {
  const suffix = randomBytes(4).toString("hex");
  return `${prefix}_${Date.now()}_${process.pid}_${suffix}`;
}

export function rideIntentDiagnostics(rideIntent) {
  const intent = rideIntent && typeof rideIntent === "object" ? rideIntent : null;
  return {
    keys: intent ? Object.keys(intent).sort() : [],
    market: intent?.market ?? null,
    city: intent?.city ?? null,
    pickup: intent?.pickup ?? null,
    dropoff: intent?.dropoff ?? null,
    destination: intent?.destination ?? null,
    fare: intent?.fare ?? null,
    total_ngn: intent?.total_ngn ?? null,
    currency: intent?.currency ?? null,
    distance_km: intent?.distance_km ?? intent?.distanceKm ?? null,
    eta_min: intent?.eta_min ?? intent?.etaMin ?? null,
    service_type: intent?.service_type ?? intent?.serviceType ?? null,
    platform_fee_ngn: intent?.platform_fee_ngn ?? null,
    market_pool: intent?.market_pool ?? null,
    has_fee_breakdown: Boolean(intent?.fee_breakdown && typeof intent.fee_breakdown === "object"),
  };
}

export function logRideIntentDiagnostics(phase, txRef, rideIntent, extra = {}) {
  console.log("E2E_RIDE_INTENT_DIAG", {
    phase,
    txRef,
    ...rideIntentDiagnostics(rideIntent),
    ...extra,
  });
}

export function prepaidRowSnapshot(val, exists = val != null) {
  const row = val && typeof val === "object" ? val : null;
  return {
    exists: Boolean(exists && row),
    rider_id: row?.rider_id ?? null,
    verified: row?.verified ?? null,
    verified_type: row ? typeof row.verified : null,
    consumed_ride_id: row?.consumed_ride_id ?? null,
    intent_abandoned_at: row?.intent_abandoned_at ?? null,
    has_ride_intent: Boolean(row?.ride_intent && typeof row.ride_intent === "object"),
    transaction_id: String(row?.transaction_id ?? row?.flutterwave_transaction_id ?? "").trim() || null,
  };
}

export function prepaidRowAfterFailureSnapshot(val, exists = val != null) {
  const row = val && typeof val === "object" ? val : null;
  return {
    exists: Boolean(exists && row),
    consumed_ride_id: row?.consumed_ride_id ?? null,
    ride_id: row?.ride_id ?? null,
    verified: row?.verified ?? null,
    verified_type: row ? typeof row.verified : null,
    rider_id: row?.rider_id ?? null,
    updated_at: row?.updated_at ?? null,
  };
}

export async function readPrepaidRow(db, txRef) {
  const snap = await db.ref(`payment_transactions/${txRef}`).get();
  return { snap, row: snap.exists() ? snap.val() : null };
}

/**
 * Read the same txRef from alternate RTDB namespaces to detect harness/Functions drift.
 */
export async function probePrepaidNamespaceVisibility(txRef) {
  const target = resolveE2eRtdbDatabaseUrl();

  async function readNamespace(namespace) {
    const appName = `e2e-ns-probe-${namespace}`;
    let app;
    try {
      app = admin.app(appName);
    } catch {
      app = admin.initializeApp(
        {
          projectId: E2E_PROJECT_ID,
          databaseURL: buildE2eRtdbDatabaseUrl(namespace),
        },
        appName,
      );
    }
    const snap = await app.database().ref(`payment_transactions/${txRef}`).get();
    const row = snap.exists() ? snap.val() : null;
    return {
      namespace,
      exists: snap.exists(),
      verified: row?.verified ?? null,
      verified_type: row ? typeof row.verified : null,
      rider_id: row?.rider_id ?? null,
      consumed_ride_id: row?.consumed_ride_id ?? null,
    };
  }

  const candidates = [
    target.namespace,
    E2E_RTDB_DEFAULT_INSTANCE,
    E2E_RTDB_LEGACY_INSTANCE,
  ];
  const unique = [...new Set(candidates)];
  const probes = await Promise.all(unique.map((ns) => readNamespace(ns)));

  return {
    harnessAlignedNamespace: target.namespace,
    probes,
  };
}

export function logPrepaidSnapshot(phase, txRef, snapshot, extra = {}) {
  console.log("E2E_PREPAID_SNAPSHOT", { phase, txRef, ...snapshot, ...extra });
}
