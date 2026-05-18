/**
 * Canonical dispatch_generation — invalidates stale popups/retries.
 */

"use strict";

const { normUid } = require("./dispatch_trip_state_engine");
const { emitPipelineEvent } = require("./dispatch_pipeline_events_engine");

async function getDispatchGeneration(db, rideId) {
  const rid = normUid(rideId);
  if (!rid) return 0;
  const snap = await db.ref(`ride_requests/${rid}/dispatch_generation`).get();
  return Number(snap.val() ?? 0) || 0;
}

/**
 * Increment generation on rerun/retry/recovery/repair.
 */
async function incrementDispatchGeneration(db, rideId, reason = "unknown") {
  const rid = normUid(rideId);
  if (!rid) return 0;
  const cur = await getDispatchGeneration(db, rid);
  const next = cur + 1;
  await db.ref(`ride_requests/${rid}`).update({
    dispatch_generation: next,
    dispatch_generation_updated_at_ms: Date.now(),
    dispatch_generation_reason: String(reason).slice(0, 120),
  });
  console.log(
    "DISPATCH_GENERATION_INCREMENT",
    `rideId=${rid}`,
    `generation=${next}`,
    `reason=${reason}`,
  );
  await emitPipelineEvent(db, rid, {
    stage: "DISPATCH_GENERATION_INCREMENT",
    generation: next,
    reason,
  });
  return next;
}

function generationMatches(offerGeneration, rideGeneration) {
  const og = Number(offerGeneration ?? 0) || 0;
  const rg = Number(rideGeneration ?? 0) || 0;
  if (rg <= 0) return true;
  if (og <= 0) return false;
  return og >= rg;
}

module.exports = {
  getDispatchGeneration,
  incrementDispatchGeneration,
  generationMatches,
};
