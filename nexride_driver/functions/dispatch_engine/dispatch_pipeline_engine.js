/**
 * Canonical matching pipeline orchestrator.
 */

"use strict";

const { normUid, rideIsOpenForMatching, canonicalAssignedDriverId } = require("./dispatch_trip_state_engine");
const { loadDispatchConfig } = require("./dispatch_config_engine");
const {
  ensureDispatchMetrics,
  recordPipelineStage,
  incrementMetric,
  patchDispatchMetrics,
} = require("./dispatch_metrics_engine");
const {
  repairDriverDispatchBlockers,
  collectDriversToRepairForRide,
} = require("./dispatch_blocker_engine");

const STAGES = {
  REQUEST_CREATED: "REQUEST_CREATED",
  DISCOVER_CANDIDATES: "DISCOVER_CANDIDATES",
  REPAIR_BLOCKERS: "REPAIR_BLOCKERS",
  ELIGIBILITY_FILTER: "ELIGIBILITY_FILTER",
  DISTANCE_RANK: "DISTANCE_RANK",
  CREATE_LEASE_BATCH: "CREATE_LEASE_BATCH",
  WAIT_FOR_ACCEPT: "WAIT_FOR_ACCEPT",
  LEASE_EXPIRE: "LEASE_EXPIRE",
  NEXT_BATCH: "NEXT_BATCH",
  RETRY_EXPANSION: "RETRY_EXPANSION",
  FAILSAFE_RECOVERY: "FAILSAFE_RECOVERY",
};

async function runMatchingPipeline(db, rideId, ridePayload, options = {}) {
  const rid = normUid(rideId);
  const source = String(options.source ?? "pipeline").trim() || "pipeline";
  if (!rid || !ridePayload || typeof ridePayload !== "object") {
    return { ok: false, reason: "invalid_ride" };
  }

  console.log("MATCHING_PIPELINE_START", `rideId=${rid}`, `source=${source}`);
  await ensureDispatchMetrics(db, rid);
  await recordPipelineStage(db, rid, STAGES.REQUEST_CREATED, { source });

  if (!rideIsOpenForMatching(ridePayload)) {
    await recordPipelineStage(db, rid, "PIPELINE_SKIP_NOT_SEARCHING");
    return { ok: false, reason: "ride_not_searching" };
  }
  if (canonicalAssignedDriverId(ridePayload)) {
    return { ok: false, reason: "already_assigned" };
  }

  const cfg = await loadDispatchConfig(db);
  const attempt = Number(ridePayload?.match_debug?.fanout_batch_number ?? 0) || 0;
  if (attempt >= cfg.driver_offer_max_attempts) {
    await recordPipelineStage(db, rid, STAGES.FAILSAFE_RECOVERY, {
      reason: "max_attempts",
    });
    const { runFailsafeRecovery } = require("./dispatch_recovery_engine");
    await runFailsafeRecovery(db, rid, ridePayload);
    return { ok: false, reason: "max_attempts_failsafe" };
  }

  await recordPipelineStage(db, rid, STAGES.REPAIR_BLOCKERS);
  const md =
    ridePayload.match_debug && typeof ridePayload.match_debug === "object"
      ? ridePayload.match_debug
      : {};
  const drivers = await collectDriversToRepairForRide(db, rid, md);
  for (const driverId of drivers) {
    await repairDriverDispatchBlockers(db, driverId, {
      incomingRideId: rid,
      source: `pipeline_${source}`,
    });
  }

  const { orchestrateFanoutRerun } = require("./dispatch_orchestrator");
  return orchestrateFanoutRerun(db, rid, ridePayload, { source });
}

module.exports = {
  STAGES,
  runMatchingPipeline,
};
