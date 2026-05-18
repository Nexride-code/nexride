/**
 * Pipeline stall detection — enqueue recovery, invalidate stale orchestration.
 */

"use strict";

const { normUid } = require("./dispatch_trip_state_engine");
const { readDispatchSnapshot, rebuildDispatchSnapshot } = require("./dispatch_snapshot_engine");
const { forceClearOrchestrationLease } = require("./dispatch_orchestration_lease_engine");
const { incrementDispatchGeneration } = require("./dispatch_generation_engine");
const { enqueueDispatchWork } = require("./dispatch_work_queue_engine");

const STALL_MS = 45_000;

async function detectAndRecoverStalledPipeline(db, rideId, options = {}) {
  const rid = normUid(rideId);
  if (!rid) return { recovered: false };

  const snap = (await readDispatchSnapshot(db, rid)) || {};
  const updated = Number(snap.updated_at_ms ?? 0) || 0;
  const now = Date.now();
  const stage = String(snap.last_pipeline_stage ?? "").trim();
  const searching =
    String(snap.ride_state ?? "").trim().toLowerCase() === "searching" ||
    !snap.assigned_driver_id;

  if (!searching) return { recovered: false, reason: "not_searching" };
  if (updated > 0 && now - updated < STALL_MS) {
    return { recovered: false, reason: "fresh_snapshot" };
  }

  console.log(
    "PIPELINE_TIMEOUT_RECOVERY",
    `rideId=${rid}`,
    `stage=${stage || "unknown"}`,
    `ageMs=${updated > 0 ? now - updated : -1}`,
  );

  await forceClearOrchestrationLease(db, rid);
  const generation = await incrementDispatchGeneration(db, rid, "pipeline_timeout");

  await enqueueDispatchWork(db, "recovery", {
    ride_id: rid,
    market: options.market,
    reason: "pipeline_timeout",
    generation,
    priority: 9,
  });

  await rebuildDispatchSnapshot(db, rid);
  return { recovered: true, generation, stage };
}

async function scanSnapshotsForStalls(db, limit = 30) {
  const snap = await db.ref("dispatch_snapshots").limitToFirst(limit * 2).get();
  if (!snap.exists()) return { scanned: 0, recovered: 0 };
  const rows = snap.val() || {};
  let scanned = 0;
  let recovered = 0;
  const now = Date.now();

  for (const [rideId, row] of Object.entries(rows)) {
    if (scanned >= limit) break;
    scanned += 1;
    if (!row || typeof row !== "object") continue;
    const updated = Number(row.updated_at_ms ?? 0) || 0;
    if (updated > 0 && now - updated < STALL_MS) continue;
    if (row.assigned_driver_id) continue;
    const res = await detectAndRecoverStalledPipeline(db, rideId, {
      market: row.market,
    });
    if (res.recovered) recovered += 1;
  }

  return { scanned, recovered };
}

module.exports = {
  detectAndRecoverStalledPipeline,
  scanSnapshotsForStalls,
  STALL_MS,
};
