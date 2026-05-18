/**
 * Per-ride orchestration mutex — only one mutator at a time (15s TTL).
 */

"use strict";

const { normUid } = require("./dispatch_trip_state_engine");

const ORCHESTRATION_LEASE_TTL_MS = 15_000;

function newOrchestrationLeaseId() {
  return `orch_${Date.now()}_${Math.random().toString(36).slice(2, 10)}`;
}

/**
 * @returns {Promise<{ acquired: boolean, leaseId?: string, reason?: string }>}
 */
async function acquireOrchestrationLease(db, rideId, owner, purpose) {
  const rid = normUid(rideId);
  const o = String(owner ?? "orchestrator").trim() || "orchestrator";
  const p = String(purpose ?? "tick").trim() || "tick";
  if (!rid) return { acquired: false, reason: "invalid_ride_id" };

  const now = Date.now();
  const leaseId = newOrchestrationLeaseId();
  const expiresAt = now + ORCHESTRATION_LEASE_TTL_MS;
  const ref = db.ref(`dispatch_orchestration_leases/${rid}`);

  let blocked = false;
  const tx = await ref.transaction((cur) => {
    if (cur && typeof cur === "object") {
      const exp = Number(cur.expires_at ?? 0) || 0;
      if (exp > now) {
        blocked = true;
        return;
      }
    }
    return {
      orchestration_lease_id: leaseId,
      orchestration_owner: o,
      acquired_at: now,
      expires_at: expiresAt,
      purpose: p,
    };
  });

  if (blocked || !tx.committed) {
    const existing = tx.snapshot.exists() ? tx.snapshot.val() : null;
    console.log(
      "ORCHESTRATION_LEASE_SKIPPED",
      `rideId=${rid}`,
      `owner=${o}`,
      `purpose=${p}`,
      `holder=${existing?.orchestration_owner ?? "unknown"}`,
    );
    return { acquired: false, reason: "lease_held" };
  }

  console.log(
    "ORCHESTRATION_LEASE_ACQUIRED",
    `rideId=${rid}`,
    `leaseId=${leaseId}`,
    `owner=${o}`,
    `purpose=${p}`,
    `expiresAt=${expiresAt}`,
  );
  return { acquired: true, leaseId };
}

async function releaseOrchestrationLease(db, rideId, leaseId) {
  const rid = normUid(rideId);
  const lid = String(leaseId ?? "").trim();
  if (!rid) return;
  const ref = db.ref(`dispatch_orchestration_leases/${rid}`);
  const snap = await ref.get();
  if (!snap.exists()) return;
  const cur = snap.val();
  if (lid && cur?.orchestration_lease_id !== lid) return;
  await ref.remove();
}

async function sweepStaleOrchestrationLeases(db) {
  const now = Date.now();
  let cleared = 0;
  const snap = await db.ref("dispatch_orchestration_leases").get();
  const rows = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  const updates = {};
  for (const [rideId, row] of Object.entries(rows)) {
    const rid = normUid(rideId);
    if (!rid || !row || typeof row !== "object") continue;
    const exp = Number(row.expires_at ?? 0) || 0;
    if (exp > 0 && now <= exp) continue;
    updates[`dispatch_orchestration_leases/${rid}`] = null;
    cleared += 1;
  }
  if (Object.keys(updates).length) {
    await db.ref().update(updates);
  }
  return { cleared };
}

async function forceClearOrchestrationLease(db, rideId) {
  const rid = normUid(rideId);
  if (!rid) return { success: false };
  await db.ref(`dispatch_orchestration_leases/${rid}`).remove();
  return { success: true, ride_id: rid };
}

module.exports = {
  ORCHESTRATION_LEASE_TTL_MS,
  acquireOrchestrationLease,
  releaseOrchestrationLease,
  sweepStaleOrchestrationLeases,
  forceClearOrchestrationLease,
};
