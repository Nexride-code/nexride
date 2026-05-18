/**
 * RTDB cost protection — pruning, sampling, queue TTL, coalesced writes.
 */

"use strict";

const { sweepExpiredWorkItems } = require("./dispatch_work_queue_engine");
const { pruneOldPipelineEvents } = require("./dispatch_pipeline_events_engine");

const METRICS_SAMPLE_RATE = 0.15;

function shouldSampleMetrics(key = "") {
  if (METRICS_SAMPLE_RATE >= 1) return true;
  let h = 0;
  const s = String(key);
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0;
  return (h % 100) / 100 < METRICS_SAMPLE_RATE;
}

/**
 * Batch multiple shallow updates into one multi-path update (max 400 paths).
 */
async function coalescedUpdate(db, updates, chunkSize = 350) {
  const entries = Object.entries(updates || {}).filter(([k]) => k);
  if (!entries.length) return { written: 0 };
  let written = 0;
  for (let i = 0; i < entries.length; i += chunkSize) {
    const slice = Object.fromEntries(entries.slice(i, i + chunkSize));
    await db.ref().update(slice);
    written += Object.keys(slice).length;
  }
  return { written };
}

async function pruneStaleExpiryBuckets(db, olderThanMs = 10 * 60_000) {
  const cutoff = Date.now() - olderThanMs;
  const snap = await db.ref("dispatch_lease_expiry_index").limitToFirst(30).get();
  if (!snap.exists()) return { removed: 0 };
  let removed = 0;
  const rows = snap.val() || {};
  for (const bucket of Object.keys(rows)) {
    if (Number(bucket) < cutoff) {
      await db.ref(`dispatch_lease_expiry_index/${bucket}`).remove();
      removed += 1;
    }
  }
  return { removed };
}

async function runCostProtectionSweep(db) {
  const work = await sweepExpiredWorkItems(db);
  const buckets = await pruneStaleExpiryBuckets(db);

  const snap = await db.ref("dispatch_snapshots").limitToFirst(200).get();
  if (snap.exists()) {
    const rows = snap.val() || {};
    for (const rideId of Object.keys(rows).slice(0, 40)) {
      await pruneOldPipelineEvents(db, rideId, 60);
    }
  }

  return { work_removed: work.removed, expiry_buckets_pruned: buckets.removed };
}

module.exports = {
  shouldSampleMetrics,
  coalescedUpdate,
  pruneStaleExpiryBuckets,
  runCostProtectionSweep,
  METRICS_SAMPLE_RATE,
};
