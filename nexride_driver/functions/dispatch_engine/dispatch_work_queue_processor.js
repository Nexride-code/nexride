/**
 * Processes dispatch work queues — schedulers enqueue, processor mutates.
 */

"use strict";

const { normUid } = require("./dispatch_trip_state_engine");
const {
  QUEUES,
  listPendingWork,
  claimWorkItem,
  completeWorkItem,
  failWorkItem,
} = require("./dispatch_work_queue_engine");

async function processWorkItem(db, queue, item) {
  const rideId = normUid(item.ride_id);
  const {
    orchestrateFanoutRerun,
    orchestrateBatchAdvance,
    orchestrateBlockerRepair,
  } = require("./dispatch_orchestrator");
  const { processLeaseExpiryBuckets } = require("./dispatch_lease_expiry_index_engine");
  const { sweepActiveTripConsistency } = require("./dispatch_active_trip_consistency");
  const { sweepOrphanRideLifecyclePointers } = require("../ride_pointer_orphans");
  const { detectAndRecoverStalledPipeline } = require("./dispatch_pipeline_timeout_engine");
  const { evaluateHotRidePolicy } = require("./dispatch_hot_ride_engine");

  try {
    switch (queue) {
      case "matching": {
        if (!rideId) return { ok: false, reason: "no_ride" };
        const hot = await evaluateHotRidePolicy(db, rideId);
        if (!hot.allowed) {
          return { ok: false, reason: hot.reason, skipped: true };
        }
        if (String(item.reason).includes("batch_advance")) {
          return orchestrateBatchAdvance(db, rideId);
        }
        const snap = await db.ref(`ride_requests/${rideId}`).get();
        return orchestrateFanoutRerun(db, rideId, snap.val() || {}, {
          source: `work_queue_${item.reason || queue}`,
        });
      }
      case "rerun": {
        if (!rideId) return { ok: false, reason: "no_ride" };
        const snap = await db.ref(`ride_requests/${rideId}`).get();
        return orchestrateFanoutRerun(db, rideId, snap.val() || {}, {
          source: `work_queue_rerun`,
        });
      }
      case "recovery": {
        if (rideId) {
          return detectAndRecoverStalledPipeline(db, rideId, { market: item.market });
        }
        return { recovered: false };
      }
      case "lease_expiry":
        return processLeaseExpiryBuckets(db);
      case "orphan_cleanup": {
        const orphans = await sweepOrphanRideLifecyclePointers(db);
        const trips = await sweepActiveTripConsistency(db);
        return { ok: true, orphans, trips };
      }
      default:
        return { ok: false, reason: "unknown_queue" };
    }
  } catch (e) {
    return { ok: false, error: String(e?.message || e) };
  }
}

async function processDispatchWorkQueues(db, options = {}) {
  const limitPerQueue = Math.min(60, Math.max(1, Number(options.limitPerQueue) || 25));
  const stats = { processed: 0, failed: 0, by_queue: {} };

  for (const queue of QUEUES) {
    stats.by_queue[queue] = { processed: 0, failed: 0 };
    const pending = await listPendingWork(db, queue, limitPerQueue);
    for (const item of pending) {
      const workId = item.work_id || item.workId;
      if (!workId) continue;
      const claimed = await claimWorkItem(db, queue, workId);
      if (!claimed) continue;

      const result = await processWorkItem(db, queue, claimed);
      if (result?.ok !== false && result?.skipped !== true) {
        await completeWorkItem(db, queue, workId, result);
        stats.processed += 1;
        stats.by_queue[queue].processed += 1;
      } else if (result?.skipped) {
        await completeWorkItem(db, queue, workId, result);
      } else {
        await failWorkItem(db, queue, workId, result?.reason || result?.error || "failed");
        stats.failed += 1;
        stats.by_queue[queue].failed += 1;
      }
    }
  }

  return stats;
}

/**
 * Enqueue watchdog work from searching index (no full-tree scan).
 */
async function enqueueWatchdogWorkFromIndex(db, cfg) {
  const { listSearchingRidesForTick } = require("./dispatch_searching_rides_index");
  const { enqueueDispatchWork } = require("./dispatch_work_queue_engine");
  const { rideIsOpenForMatching } = require("./dispatch_trip_state_engine");

  const entries = await listSearchingRidesForTick(db, { maxPerShard: 6, maxMarkets: 12 });
  const now = Date.now();
  let enqueued = 0;

  for (const entry of entries) {
    const rid = normUid(entry.rideId);
    if (!rid) continue;

    const created = Number(entry.meta?.created_at_ms ?? 0) || 0;
    if (created > 0 && now - created > cfg.stale_searching_ride_ms) {
      await enqueueDispatchWork(db, "rerun", {
        ride_id: rid,
        market: entry.market,
        reason: "failsafe_stale_search",
        priority: 8,
        generation: entry.meta?.generation,
      });
      enqueued += 1;
      continue;
    }

    const rideSnap = await db.ref(`ride_requests/${rid}`).get();
    const ride = rideSnap.val();
    if (!ride || !rideIsOpenForMatching(ride)) continue;

    const md = ride.match_debug && typeof ride.match_debug === "object" ? ride.match_debug : {};
    const drivers =
      (Array.isArray(md.batch_driver_ids) ? md.batch_driver_ids : []).length +
      (Array.isArray(md.exhausted_driver_ids) ? md.exhausted_driver_ids : []).length;
    if (drivers > 0) {
      await enqueueDispatchWork(db, "recovery", {
        ride_id: rid,
        market: entry.market,
        reason: "blocker_scan",
        priority: 5,
      });
      enqueued += 1;
    }
  }

  return { enqueued, scanned: entries.length };
}

module.exports = {
  processDispatchWorkQueues,
  processWorkItem,
  enqueueWatchdogWorkFromIndex,
};
