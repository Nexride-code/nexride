/**
 * Single orchestration owner — all schedulers delegate here.
 */

"use strict";

const { normUid, rideIsOpenForMatching, canonicalAssignedDriverId } = require("./dispatch_trip_state_engine");
const { loadDispatchConfig } = require("./dispatch_config_engine");
const {
  acquireOrchestrationLease,
  releaseOrchestrationLease,
  sweepStaleOrchestrationLeases,
  forceClearOrchestrationLease,
} = require("./dispatch_orchestration_lease_engine");
const { beginDispatchRun, isStaleDispatchRun } = require("./dispatch_pipeline_tokens_engine");
const {
  incrementDispatchGeneration,
  getDispatchGeneration,
} = require("./dispatch_generation_engine");
const { emitPipelineEvent, pruneOldPipelineEvents } = require("./dispatch_pipeline_events_engine");
const { repairDriverDispatchBlockers, collectDriversToRepairForRide } = require("./dispatch_blocker_engine");
const { expireStaleLeasesImpl, reconcileExpiredLease } = require("./dispatch_offer_lease_engine");
const { incrementMetric, patchDispatchMetrics } = require("./dispatch_metrics_engine");
const { sweepActiveTripConsistency } = require("./dispatch_active_trip_consistency");
const { sweepOrphanRideLifecyclePointers } = require("../ride_pointer_orphans");
const { beginMarketFanout, endMarketFanout } = require("./dispatch_fanout_backpressure_engine");
const { evaluateHotRidePolicy, recordOrchestratorAttempt, bumpHotRideCounter } = require("./dispatch_hot_ride_engine");
const { rebuildDispatchSnapshot } = require("./dispatch_snapshot_engine");
const { evaluateFastRecoveryMode } = require("./dispatch_fast_recovery_engine");
const { indexSearchingRide, removeSearchingRide } = require("./dispatch_searching_rides_index");
const { recordDispatchOutcome } = require("./dispatch_aggregates_engine");

async function withOrchestrationLease(db, rideId, owner, purpose, fn) {
  const lease = await acquireOrchestrationLease(db, rideId, owner, purpose);
  if (!lease.acquired) {
    return { skipped: true, reason: "orchestration_lease_held" };
  }
  try {
    return await fn(lease);
  } finally {
    await releaseOrchestrationLease(db, rideId, lease.leaseId);
  }
}

/**
 * Core fan-out / rerun body (caller must hold orchestration lease when required).
 */
async function executeFanoutRerun(db, rideId, ridePayload, options = {}) {
  const rid = normUid(rideId);
  const source = String(options.source ?? "orchestrator").trim() || "orchestrator";
  if (!rid) return { ok: false, reason: "invalid_ride_id" };

  const snap = await db.ref(`ride_requests/${rid}`).get();
  const ride =
    snap.val() && typeof snap.val() === "object" ? snap.val() : ridePayload || {};
  if (!rideIsOpenForMatching(ride)) {
    return { ok: false, reason: "ride_not_searching" };
  }
  if (canonicalAssignedDriverId(ride) || ride.dispatch_locked === true) {
    await removeSearchingRide(db, rid, ride);
    return { ok: false, reason: "ride_locked_or_assigned" };
  }

  const hot = await evaluateHotRidePolicy(db, rid);
  if (!hot.allowed) {
    return { ok: false, reason: hot.reason, cooldown_until_ms: hot.cooldown_until_ms };
  }
  await recordOrchestratorAttempt(db, rid);

  const runToken = await beginDispatchRun(db, rid, source);
  const generation = options.skipGenerationIncrement
    ? await getDispatchGeneration(db, rid)
    : await incrementDispatchGeneration(db, rid, source);

  const market = String(
    ride.market_pool ?? ride.market ?? ride.dispatch_market_id ?? "",
  ).trim();
  const fastRecovery = await evaluateFastRecoveryMode(db, market);
  const pressure = await beginMarketFanout(db, market);
  if (!pressure.allowed) {
    await patchDispatchMetrics(db, rid, { last_fanout_blocked: "backpressure" });
    return { ok: false, reason: "fanout_backpressure" };
  }

  const fanoutStarted = Date.now();
  try {
    const md =
      ride.match_debug && typeof ride.match_debug === "object" ? ride.match_debug : {};
    const drivers = await collectDriversToRepairForRide(db, rid, md);
    for (const driverId of drivers) {
      await repairDriverDispatchBlockers(db, driverId, {
        incomingRideId: rid,
        source: `orchestrator_${source}`,
      });
    }

    const { fanOutDriverOffersIfEligible } = require("../ride_callables");
    const freshSnap = await db.ref(`ride_requests/${rid}`).get();
    const fresh =
      freshSnap.val() && typeof freshSnap.val() === "object" ? freshSnap.val() : ride;
    if (await isStaleDispatchRun(db, rid, runToken)) {
      return { ok: false, reason: "stale_dispatch_run" };
    }
    await fanOutDriverOffersIfEligible(db, rid, fresh, {
      marketPressureHeld: true,
      fastRecovery: fastRecovery.active,
      batchSizeAdjust:
        (pressure.batchSizeAdjust || 0) +
        (hot.batchSizeAdjust || 0) +
        (fastRecovery.batchSizeAdjust || 0),
      radiusExpandKm: fastRecovery.radiusExpandKm || 0,
    });
    await incrementMetric(db, rid, "rerun_count", 1);
    await bumpHotRideCounter(db, rid, "rerun_count", 1);
    await indexSearchingRide(db, rid, fresh);
    await emitPipelineEvent(db, rid, {
      stage: "FANOUT_RERUN",
      generation,
      reason: source,
      extra: { runToken },
    });
    await pruneOldPipelineEvents(db, rid);
    await rebuildDispatchSnapshot(db, rid, fresh);
    await recordDispatchOutcome(db, market, {
      match_latency_ms: Date.now() - fanoutStarted,
      rerun: 1,
    });
    return { ok: true, generation, runToken };
  } finally {
    await endMarketFanout(db, market);
  }
}

/**
 * Canonical fan-out / rerun — generation bump + idempotent run token.
 */
async function orchestrateFanoutRerun(db, rideId, ridePayload, options = {}) {
  const rid = normUid(rideId);
  const source = String(options.source ?? "orchestrator").trim() || "orchestrator";
  if (!rid) return { ok: false, reason: "invalid_ride_id" };
  if (options.skipOrchestrationLease) {
    return executeFanoutRerun(db, rid, ridePayload, options);
  }

  return withOrchestrationLease(db, rid, "orchestrator", `fanout_${source}`, async () =>
    executeFanoutRerun(db, rid, ridePayload, options),
  );
}

async function orchestrateBlockerRepair(db, rideId) {
  const rid = normUid(rideId);
  if (!rid) return { skipped: true };

  return withOrchestrationLease(db, rid, "orchestrator", "blocker_repair", async () => {
    const mdSnap = await db.ref(`ride_requests/${rid}/match_debug`).get();
    const matchDebug = mdSnap.val() && typeof mdSnap.val() === "object" ? mdSnap.val() : {};
    const drivers = await collectDriversToRepairForRide(db, rid, matchDebug);
    let clearedAny = false;
    for (const driverId of drivers) {
      const res = await repairDriverDispatchBlockers(db, driverId, {
        incomingRideId: rid,
        source: "orchestrator_blocker_repair",
      });
      if (res.cleared) clearedAny = true;
    }
    if (clearedAny) {
      console.log("MATCHING_RECOVERY_RERUN", `rideId=${rid}`, "reason=blocker_repair");
      const rideSnap = await db.ref(`ride_requests/${rid}`).get();
      const ride = rideSnap.val() || {};
      await executeFanoutRerun(db, rid, ride, {
        source: "blocker_repair",
        skipOrchestrationLease: true,
      });
    }
    return { clearedAny, drivers: drivers.size };
  });
}

async function orchestrateBatchAdvance(db, rideId) {
  const rid = normUid(rideId);
  if (!rid) return { skipped: true };

  return withOrchestrationLease(db, rid, "orchestrator", "batch_advance", async () => {
    const snap = await db.ref(`ride_requests/${rid}`).get();
    const ride = snap.val();
    if (!ride || !rideIsOpenForMatching(ride)) return { skipped: true, reason: "not_searching" };
    if (canonicalAssignedDriverId(ride) || ride.dispatch_locked) {
      return { skipped: true, reason: "assigned" };
    }

    const md = ride.match_debug && typeof ride.match_debug === "object" ? ride.match_debug : {};
    const batchIds = Array.isArray(md.batch_driver_ids)
      ? md.batch_driver_ids.map(normUid).filter(Boolean)
      : [];
    const priorExhausted = Array.isArray(md.exhausted_driver_ids)
      ? md.exhausted_driver_ids.map(normUid).filter(Boolean)
      : [];
    await db.ref(`ride_requests/${rid}/match_debug`).update({
      exhausted_driver_ids: [...new Set([...priorExhausted, ...batchIds])],
      last_batch_advance_at_ms: Date.now(),
    });

    console.log("MATCHING_BATCH_ADVANCE", `rideId=${rid}`);
    await incrementDispatchGeneration(db, rid, "batch_advance");
    const freshSnap = await db.ref(`ride_requests/${rid}`).get();
    return executeFanoutRerun(db, rid, freshSnap.val() || ride, {
      source: "batch_advance",
      skipGenerationIncrement: true,
    });
  });
}

/**
 * Lightweight scheduled tick — scanners only; mutations under orchestration lease.
 */
async function runScheduledOrchestratorTick(db, scanner = "watchdog") {
  const stats = {
    scanner,
    orchestration_leases_cleared: 0,
    leases_expired: 0,
    batch_advanced: 0,
    blocker_repairs: 0,
    active_trip_repairs: 0,
    work_queue: null,
    index_enqueue: null,
    pipeline_stalls: null,
    cost_protection: null,
    orphans: null,
  };

  const orchSweep = await sweepStaleOrchestrationLeases(db);
  stats.orchestration_leases_cleared = orchSweep.cleared;

  const { enqueueDispatchWork } = require("./dispatch_work_queue_engine");
  await enqueueDispatchWork(db, "lease_expiry", {
    reason: "scheduled_tick",
    priority: 10,
  });
  await enqueueDispatchWork(db, "orphan_cleanup", {
    reason: "scheduled_tick",
    priority: 4,
  });

  const cfg = await loadDispatchConfig(db);
  const {
    enqueueWatchdogWorkFromIndex,
    processDispatchWorkQueues,
  } = require("./dispatch_work_queue_processor");
  stats.index_enqueue = await enqueueWatchdogWorkFromIndex(db, cfg);
  stats.work_queue = await processDispatchWorkQueues(db, { limitPerQueue: 30 });

  const leaseResult = await expireStaleLeasesImpl(db);
  stats.leases_expired = leaseResult.expired;

  for (const rideId of leaseResult.ridesNeedingAdvance || []) {
    const res = await orchestrateBatchAdvance(db, rideId);
    if (res && res.ok) stats.batch_advanced += 1;
  }

  const { scanSnapshotsForStalls } = require("./dispatch_pipeline_timeout_engine");
  stats.pipeline_stalls = await scanSnapshotsForStalls(db, 25);

  stats.active_trip_repairs = (await sweepActiveTripConsistency(db)).repaired;
  try {
    const { runCostProtectionSweep } = require("./dispatch_cost_protection_engine");
    stats.cost_protection = await runCostProtectionSweep(db);
    stats.orphans = await sweepOrphanRideLifecyclePointers(db);
    console.log("ORPHAN_CLEANUP", JSON.stringify(stats.orphans || {}));
  } catch (e) {
    stats.orphans = { error: String(e?.message || e) };
  }

  return stats;
}

async function recordDriverOfferPopupAck(db, driverId, payload) {
  const d = normUid(driverId);
  const rideId = normUid(payload?.rideId ?? payload?.ride_id);
  const leaseId = normUid(payload?.lease_id ?? payload?.leaseId);
  if (!d || !rideId) {
    return { success: false, reason: "invalid_input" };
  }

  const rideGen = await getDispatchGeneration(db, rideId);
  const offerGen = Number(payload?.generation ?? payload?.popup_generation ?? 0) || 0;
  if (rideGen > 0 && offerGen > 0 && offerGen < rideGen) {
    return { success: false, reason: "generation_mismatch" };
  }

  const now = Date.now();
  const renderedAt = Number(payload?.popup_rendered_at ?? payload?.popupRenderedAt ?? now) || now;
  await db.ref(`driver_offer_ack/${rideId}/${d}`).set({
    lease_id: leaseId || null,
    generation: offerGen || rideGen,
    popup_rendered_at: renderedAt,
    acked_at: now,
    driver_id: d,
    ride_id: rideId,
  });

  console.log(
    "POPUP_ACK_RECEIVED",
    `rideId=${rideId}`,
    `driverId=${d}`,
    `leaseId=${leaseId}`,
    `generation=${offerGen || rideGen}`,
  );

  await patchDispatchMetrics(db, rideId, {
    first_popup_rendered_at: renderedAt,
    popup_delivery_latency_ms: Math.max(0, renderedAt - (Number(payload?.offer_created_at ?? 0) || now)),
    last_popup_ack_driver_id: d,
    last_popup_ack_at_ms: now,
  });

  return { success: true, reason: "ack_recorded" };
}

async function adminOrchestratorAction(data, context, db) {
  const { requireAdmin } = require("../admin_auth");
  const deny = await requireAdmin(db, context, "adminOrchestratorAction");
  if (deny) return deny;

  const rideId = normUid(data?.rideId ?? data?.ride_id);
  const action = String(data?.action ?? "").trim().toLowerCase();
  if (!rideId) return { success: false, reason: "invalid_ride_id" };

  switch (action) {
    case "kill_orchestration_lease":
      return { success: true, ...(await forceClearOrchestrationLease(db, rideId)) };
    case "invalidate_generation": {
      const gen = await incrementDispatchGeneration(db, rideId, "admin_invalidate");
      return { success: true, dispatch_generation: gen };
    }
    case "replay_fanout": {
      const snap = await db.ref(`ride_requests/${rideId}`).get();
      return orchestrateFanoutRerun(db, rideId, snap.val() || {}, { source: "admin_replay" });
    }
    case "expire_all_leases": {
      const r = await expireStaleLeasesImpl(db);
      return { success: true, ...r };
    }
    case "rebuild_metrics": {
      await db.ref(`dispatch_metrics/${rideId}`).remove();
      const { ensureDispatchMetrics } = require("./dispatch_metrics_engine");
      await ensureDispatchMetrics(db, rideId);
      return { success: true, reason: "metrics_rebuilt" };
    }
    case "repair_blockers":
      return { success: true, ...(await orchestrateBlockerRepair(db, rideId)) };
    case "rebuild_snapshot": {
      const snap = await db.ref(`ride_requests/${rideId}`).get();
      const built = await rebuildDispatchSnapshot(db, rideId, snap.val() || {});
      return { success: true, snapshot: built };
    }
    case "requeue_work": {
      const { enqueueDispatchWork } = require("./dispatch_work_queue_engine");
      const q = String(data?.queue ?? "matching").trim() || "matching";
      const r = await enqueueDispatchWork(db, q, {
        ride_id: rideId,
        market: data?.market,
        reason: String(data?.reason ?? "admin_requeue"),
        priority: 9,
      });
      return { success: r.ok, workId: r.workId };
    }
    case "list_dead_letters": {
      const { listDeadLetters } = require("./dispatch_dead_letter_engine");
      return { success: true, letters: await listDeadLetters(db, 40) };
    }
    case "repair_assignment": {
      const { sweepActiveTripConsistency } = require("./dispatch_active_trip_consistency");
      return { success: true, ...(await sweepActiveTripConsistency(db, 80)) };
    }
    case "migrate_shard": {
      const { indexSearchingRide } = require("./dispatch_searching_rides_index");
      const snap = await db.ref(`ride_requests/${rideId}`).get();
      return { success: true, ...(await indexSearchingRide(db, rideId, snap.val() || {})) };
    }
    default:
      return { success: false, reason: "unknown_action" };
  }
}

module.exports = {
  withOrchestrationLease,
  executeFanoutRerun,
  orchestrateFanoutRerun,
  orchestrateBlockerRepair,
  orchestrateBatchAdvance,
  runScheduledOrchestratorTick,
  recordDriverOfferPopupAck,
  adminOrchestratorAction,
  forceClearOrchestrationLease,
};
