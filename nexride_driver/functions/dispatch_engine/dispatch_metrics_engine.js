/**
 * Per-ride dispatch metrics at dispatch_metrics/{rideId}.
 */

"use strict";

const { normUid } = require("./dispatch_trip_state_engine");

async function ensureDispatchMetrics(db, rideId) {
  const rid = normUid(rideId);
  if (!rid) return null;
  const ref = db.ref(`dispatch_metrics/${rid}`);
  const snap = await ref.get();
  if (snap.exists()) {
    return snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  }
  const now = Date.now();
  const seed = {
    ride_id: rid,
    request_created_at: now,
    retry_count: 0,
    repair_count: 0,
    lease_expire_count: 0,
    rerun_count: 0,
    stale_blocker_count: 0,
    updated_at_ms: now,
  };
  await ref.set(seed);
  return seed;
}

async function patchDispatchMetrics(db, rideId, patch) {
  const rid = normUid(rideId);
  if (!rid || !patch || typeof patch !== "object") return;
  const ref = db.ref(`dispatch_metrics/${rid}`);
  const snap = await ref.get();
  const now = Date.now();
  if (!snap.exists()) {
    await ensureDispatchMetrics(db, rid);
  }
  const updates = { ...patch, updated_at_ms: now };
  if (patch.first_offer_at && !patch.dispatch_latency_ms) {
    const created = Number(
      (await ref.child("request_created_at").get()).val() ?? now,
    );
    if (created > 0) {
      updates.dispatch_latency_ms = Math.max(0, patch.first_offer_at - created);
    }
  }
  await ref.update(updates);
}

async function incrementMetric(db, rideId, field, delta = 1) {
  const rid = normUid(rideId);
  if (!rid) return;
  await ensureDispatchMetrics(db, rid);
  const snap = await db.ref(`dispatch_metrics/${rid}/${field}`).get();
  const cur = Number(snap.val() ?? 0) || 0;
  await patchDispatchMetrics(db, rid, { [field]: cur + delta });
}

async function recordPipelineStage(db, rideId, stage, extra = {}) {
  const rid = normUid(rideId);
  if (!rid) return;
  console.log(
    "MATCHING_PIPELINE_STAGE",
    `rideId=${rid}`,
    `stage=${stage}`,
    Object.entries(extra)
      .map(([k, v]) => `${k}=${v}`)
      .join(" "),
  );
  await patchDispatchMetrics(db, rid, {
    last_pipeline_stage: stage,
    last_pipeline_stage_at_ms: Date.now(),
    ...extra,
  });
}

module.exports = {
  ensureDispatchMetrics,
  patchDispatchMetrics,
  incrementMetric,
  recordPipelineStage,
};
