/**
 * Backend-owned repair for stale driver dispatch blockers (active pointers).
 */

"use strict";

const {
  collectDriverActivePointerTripIds,
  clearDriverActivePointers,
  evaluateActivePointerDecision,
  loadTripRows,
  STALE_SEARCHING_RIDE_MS,
  isSearchingRide,
} = require("./driver_active_pointer_guard");

function normUid(v) {
  return String(v ?? "").trim();
}

/**
 * Shared blocker evaluation with incoming-offer context.
 * @returns {Promise<{ blocks: boolean, shouldClear: boolean, reason: string, tripId: string, shouldRestoreActiveTrip?: boolean }>}
 */
async function evaluateDriverBlocker(
  db,
  driverId,
  tripId,
  { incomingRideId = "", source = "evaluate" } = {},
) {
  const d = normUid(driverId);
  const t = normUid(tripId);
  const incoming = normUid(incomingRideId);
  const { ride, delivery, activeTrip } = await loadTripRows(db, t);

  const verdict = evaluateActivePointerDecision({
    driverId: d,
    tripId: t,
    source,
    ride,
    delivery,
    activeTrip,
    incomingOfferTripId: incoming,
  });

  const blocks = verdict.blocks === true;
  const shouldClear = !blocks;
  const reason = verdict.reason || (blocks ? "active" : "clear");

  console.log(
    "DISPATCH_BLOCKER_REPAIR_DECISION",
    `driverId=${d}`,
    `tripId=${t}`,
    `incomingRideId=${incoming}`,
    `source=${source}`,
    `blocks=${blocks}`,
    `reason=${reason}`,
    `decision=${verdict.decision}`,
  );

  return {
    blocks,
    shouldClear,
    reason,
    tripId: t,
    shouldRestoreActiveTrip: verdict.shouldRestoreActiveTrip === true,
    verdict,
  };
}

/**
 * Repair all stale pointers for a driver; optionally scoped to incoming offer.
 */
async function repairDriverDispatchBlockers(
  db,
  driverId,
  { incomingRideId = "", source = "unknown" } = {},
) {
  const d = normUid(driverId);
  const incoming = normUid(incomingRideId);
  const src = String(source || "unknown").trim() || "unknown";

  console.log(
    "DISPATCH_BLOCKER_REPAIR_START",
    `driverId=${d}`,
    `incomingRideId=${incoming}`,
    `source=${src}`,
  );

  if (!d) {
    return {
      success: false,
      cleared: false,
      clearedTripIds: [],
      blockingTripIds: [],
      reason: "invalid_driver_id",
      shouldRetryHydrate: false,
    };
  }

  const clearedTripIds = [];
  const blockingTripIds = [];
  const decisions = [];

  const tripIds = await collectDriverActivePointerTripIds(db, d);
  if (tripIds.size === 0) {
    console.log("DISPATCH_BLOCKER_REPAIR_DONE", `driverId=${d}`, "reason=no_pointers");
    return {
      success: true,
      cleared: false,
      clearedTripIds: [],
      blockingTripIds: [],
      reason: "no_pointers",
      shouldRetryHydrate: false,
      decisions,
    };
  }

  for (const tripId of tripIds) {
    const evalResult = await evaluateDriverBlocker(db, d, tripId, {
      incomingRideId: incoming,
      source: src,
    });
    decisions.push({
      tripId,
      blocks: evalResult.blocks,
      reason: evalResult.reason,
    });

    if (evalResult.blocks) {
      blockingTripIds.push(tripId);
      console.log(
        "DISPATCH_BLOCKER_REPAIR_SKIP_ACTIVE",
        `driverId=${d}`,
        `tripId=${tripId}`,
        `reason=${evalResult.reason}`,
      );
      continue;
    }

    const cleanupReason = `dispatch_blocker_repair_${evalResult.reason}`;
    await clearDriverActivePointers(db, d, tripId, cleanupReason);
    clearedTripIds.push(tripId);
    console.log(
      "DISPATCH_BLOCKER_REPAIR_CLEAR",
      `driverId=${d}`,
      `tripId=${tripId}`,
      `reason=${evalResult.reason}`,
      `incomingRideId=${incoming}`,
    );
  }

  const cleared = clearedTripIds.length > 0;
  const shouldRetryHydrate =
    cleared && blockingTripIds.length === 0 && incoming.length > 0;

  const reason =
    blockingTripIds.length > 0
      ? "active_trip_still_blocking"
      : cleared
        ? "cleared_stale_pointers"
        : "nothing_to_clear";

  console.log(
    "DISPATCH_BLOCKER_REPAIR_DONE",
    `driverId=${d}`,
    `cleared=${cleared}`,
    `clearedCount=${clearedTripIds.length}`,
    `blockingCount=${blockingTripIds.length}`,
    `shouldRetryHydrate=${shouldRetryHydrate}`,
    `reason=${reason}`,
  );

  return {
    success: true,
    cleared,
    clearedTripIds,
    blockingTripIds,
    reason,
    shouldRetryHydrate,
    shouldRestoreActiveTrip:
      blockingTripIds.length === 1 &&
      decisions.some((x) => x.tripId === blockingTripIds[0] && x.blocks),
    decisions,
  };
}

/**
 * Callable: driver (self) or admin.
 */
async function repairDriverDispatchBlockersCallable(data, context, db) {
  const driverId = normUid(data?.driverId ?? data?.driver_id);
  const incomingRideId = normUid(
    data?.incomingRideId ?? data?.incoming_ride_id ?? data?.incomingOfferRideId,
  );
  const source = String(data?.source ?? "callable").trim() || "callable";
  const uid = normUid(context.auth?.uid);

  if (!uid) {
    return { success: false, reason: "unauthorized", cleared: false };
  }

  if (driverId !== uid) {
    const { requireAdmin } = require("./admin_auth");
    const deny = await requireAdmin(db, context, "repairDriverDispatchBlockers");
    if (deny) {
      return { success: false, reason: "forbidden", cleared: false };
    }
  }

  return repairDriverDispatchBlockers(db, driverId, {
    incomingRideId,
    source,
  });
}

function matchingRowIsOpenSearch(ride) {
  if (!ride || typeof ride !== "object") return false;
  if (isSearchingRide(ride)) return true;
  const st = String(ride.status ?? ride.request_status ?? "").trim().toLowerCase();
  return (
    st === "searching" ||
    st === "requested" ||
    st === "matching" ||
    st === "searching_driver"
  );
}

function matchingRowCreatedAtMs(row) {
  const n = Number(
    row?.created_at_ms ??
      row?.created_at ??
      row?.requested_at_ms ??
      row?.requested_at ??
      0,
  );
  return Number.isFinite(n) ? n : 0;
}

/**
 * Collect driver ids that may be stale-blocked for a searching ride.
 */
async function collectDriversToRepairForRide(db, rideId, matchDebug) {
  const drivers = new Set();
  const rid = normUid(rideId);
  if (!rid) return drivers;

  try {
    const fanSnap = await db.ref(`ride_offer_fanout/${rid}`).get();
    const fan = fanSnap.val() && typeof fanSnap.val() === "object" ? fanSnap.val() : {};
    for (const k of Object.keys(fan)) {
      const d = normUid(k);
      if (d) drivers.add(d);
    }
  } catch (_) {}

  const rejected = Array.isArray(matchDebug?.rejected_driver_samples)
    ? matchDebug.rejected_driver_samples
    : [];
  for (const sample of rejected) {
    if (!sample || typeof sample !== "object") continue;
    const reason = String(sample.filtered_reason ?? "").toLowerCase();
    if (
      reason.includes("active_ride") ||
      reason.includes("driver_active") ||
      reason.includes("busy")
    ) {
      const d = normUid(sample.driverId ?? sample.driver_id);
      if (d) drivers.add(d);
    }
  }

  return drivers;
}

/**
 * Legacy entry — delegates to central orchestrator (avoid duplicate scheduler work).
 */
async function repairStuckMatchingAndDriverBlockersImpl(db) {
  const { runScheduledOrchestratorTick } = require("./dispatch_engine/dispatch_orchestrator");
  const stats = await runScheduledOrchestratorTick(db, "repairStuckMatchingLegacy");
  return {
    scanned: stats.blocker_repairs ?? 0,
    repairedRides: stats.blocker_repairs ?? 0,
    clearedDrivers: 0,
    reruns: stats.batch_advanced ?? 0,
    delegated: true,
  };
}

/**
 * Admin: repair blockers for drivers tied to a ride, then re-run matching.
 */
async function adminRepairDispatchBlockersForRide(data, context, db) {
  const { requireAdmin } = require("./admin_auth");
  const deny = await requireAdmin(db, context, "adminRepairDispatchBlockers");
  if (deny) return deny;

  const rideId = normUid(data?.rideId ?? data?.ride_id);
  if (!rideId) {
    return { success: false, reason: "invalid_ride_id" };
  }

  const snap = await db.ref(`ride_requests/${rideId}`).get();
  const ride = snap.val();
  if (!ride || typeof ride !== "object") {
    return { success: false, reason: "ride_not_found" };
  }

  const mdSnap = await db.ref(`ride_requests/${rideId}/match_debug`).get();
  const matchDebug = mdSnap.val() && typeof mdSnap.val() === "object" ? mdSnap.val() : {};
  const drivers = await collectDriversToRepairForRide(db, rideId, matchDebug);

  const repairResults = [];
  for (const driverId of drivers) {
    repairResults.push(
      await repairDriverDispatchBlockers(db, driverId, {
        incomingRideId: rideId,
        source: "admin_repair_dispatch_blockers",
      }),
    );
  }

  const { orchestrateFanoutRerun } = require("./dispatch_engine/dispatch_orchestrator");
  await orchestrateFanoutRerun(db, rideId, ride, { source: "admin_repair_dispatch_blockers" });
  const mdAfter = await db.ref(`ride_requests/${rideId}/match_debug`).get();
  const md = mdAfter.val() || {};

  return {
    success: true,
    reason: "repair_and_rerun_complete",
    ride_id: rideId,
    drivers_repaired: drivers.size,
    cleared_total: repairResults.filter((r) => r.cleared).length,
    offers_written: Number(md.offers_written ?? 0) || 0,
    eligible_driver_count: Number(md.eligible_driver_count ?? 0) || 0,
    repair_results: repairResults,
  };
}

const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");
const { logger } = require("firebase-functions");
const { REGION } = require("./params");

/** @deprecated Use `dispatchWatchdog` — kept as no-op to avoid duplicate 1-min scans. */
const repairStuckMatchingAndDriverBlockers = onSchedule(
  { schedule: "every 5 minutes", timeZone: "Africa/Lagos", region: REGION },
  async () => {
    logger.info("DISPATCH_BLOCKER_WATCHDOG_DELEGATED", {
      note: "mutation work runs in dispatchWatchdog orchestrator only",
    });
  },
);

module.exports = {
  evaluateDriverBlocker,
  repairDriverDispatchBlockers,
  repairDriverDispatchBlockersCallable,
  repairStuckMatchingAndDriverBlockers,
  repairStuckMatchingAndDriverBlockersImpl,
  adminRepairDispatchBlockersForRide,
  collectDriversToRepairForRide,
};
