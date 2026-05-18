/**
 * Compact dispatch snapshot per ride — fast reconnect / admin / watchdog checks.
 */

"use strict";

const { normUid, rideIsOpenForMatching, canonicalAssignedDriverId } = require("./dispatch_trip_state_engine");
const { getDispatchGeneration } = require("./dispatch_generation_engine");

async function rebuildDispatchSnapshot(db, rideId, ride = null) {
  const rid = normUid(rideId);
  if (!rid) return null;

  if (!ride) {
    const snap = await db.ref(`ride_requests/${rid}`).get();
    ride = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  }

  const [metricsSnap, orchSnap, hotSnap] = await Promise.all([
    db.ref(`dispatch_metrics/${rid}`).get(),
    db.ref(`dispatch_orchestration_leases/${rid}`).get(),
    db.ref(`dispatch_hot_rides/${rid}`).get(),
  ]);

  const metrics = metricsSnap.val() || {};
  const md = ride.match_debug && typeof ride.match_debug === "object" ? ride.match_debug : {};
  const leaseSnap = await db.ref(`ride_requests/${rid}/offer_leases`).get();
  const leases = leaseSnap.val() && typeof leaseSnap.val() === "object" ? leaseSnap.val() : {};
  let activeLeaseCount = 0;
  const now = Date.now();
  for (const lease of Object.values(leases)) {
    if (!lease || typeof lease !== "object") continue;
    const st = String(lease.lease_status ?? "").trim().toLowerCase();
    const exp = Number(lease.lease_expires_at ?? 0) || 0;
    if ((st === "offered" || st === "leased") && exp > now) activeLeaseCount += 1;
  }

  const generation =
    Number(ride.dispatch_generation ?? 0) || (await getDispatchGeneration(db, rid));

  const snapshot = {
    ride_id: rid,
    ride_state: String(ride.trip_state ?? ride.status ?? "").trim(),
    generation,
    active_lease_count: activeLeaseCount,
    assigned_driver_id: canonicalAssignedDriverId(ride) || null,
    last_pipeline_stage: metrics.last_pipeline_stage ?? md.matching_state ?? null,
    last_recovery_reason: metrics.last_run_source ?? md.batch_advance_reason ?? null,
    retry_count: Number(metrics.retry_count ?? 0) || 0,
    orchestration_state: orchSnap.exists()
      ? {
          held: (Number(orchSnap.val()?.expires_at ?? 0) || 0) > now,
          owner: orchSnap.val()?.orchestration_owner ?? null,
        }
      : { held: false },
    hot_ride: hotSnap.exists() ? hotSnap.val() : null,
    updated_at_ms: now,
  };

  await db.ref(`dispatch_snapshots/${rid}`).set(snapshot);
  return snapshot;
}

async function readDispatchSnapshot(db, rideId) {
  const rid = normUid(rideId);
  if (!rid) return null;
  const snap = await db.ref(`dispatch_snapshots/${rid}`).get();
  if (!snap.exists()) {
    const rideSnap = await db.ref(`ride_requests/${rid}`).get();
    if (!rideSnap.exists()) return null;
    return rebuildDispatchSnapshot(db, rid, rideSnap.val());
  }
  return snap.val();
}

async function patchDispatchSnapshot(db, rideId, patch) {
  const rid = normUid(rideId);
  if (!rid || !patch) return;
  await db.ref(`dispatch_snapshots/${rid}`).update({
    ...patch,
    updated_at_ms: Date.now(),
  });
}

module.exports = {
  rebuildDispatchSnapshot,
  readDispatchSnapshot,
  patchDispatchSnapshot,
};
