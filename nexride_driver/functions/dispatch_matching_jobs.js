/**
 * Production matching maintenance: advance offer batches, sweep ghost online drivers.
 */

"use strict";

const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");
const { logger } = require("firebase-functions");
const { REGION } = require("./params");
const { STALE_DRIVER_HEARTBEAT_MS } = require("./driver_active_pointer_guard");

/** Grace after per-driver offer TTL before advancing to next batch (ms). */
const BATCH_ADVANCE_GRACE_MS = 3_000;

function normUid(v) {
  return String(v ?? "").trim();
}

function isOpenSearchingRide(ride) {
  if (!ride || typeof ride !== "object") return false;
  const ts = String(ride.trip_state ?? "").trim().toLowerCase();
  const st = String(ride.status ?? "").trim().toLowerCase();
  if (ts === "expired" || ts === "completed" || ts === "cancelled") return false;
  if (st === "expired" || st === "completed" || st === "cancelled") return false;
  const assigned = String(ride.matched_driver_id ?? ride.accepted_driver_id ?? "").trim();
  if (assigned && assigned !== "waiting" && assigned !== "pending") return false;
  return (
    ts === "searching" ||
    st === "searching" ||
    st === "requested" ||
    st === "matching"
  );
}

/**
 * True when every driver in the current batch has no live (unexpired) queue offer.
 */
async function currentBatchOffersExpired(db, rideId, batchDriverIds, now) {
  for (const driverId of batchDriverIds) {
    const d = normUid(driverId);
    if (!d) continue;
    const qSnap = await db.ref(`driver_offer_queue/${d}/${rideId}`).get();
    if (!qSnap.exists()) continue;
    const offer = qSnap.val();
    if (!offer || typeof offer !== "object") continue;
    const expiresAt =
      Number(offer.expires_at ?? offer.request_expires_at ?? 0) || 0;
    if (expiresAt <= 0) return false;
    if (now < expiresAt + BATCH_ADVANCE_GRACE_MS) return false;
  }
  return true;
}

/**
 * Advance to next driver batch when current batch timed out without accept.
 */
async function advanceStuckMatchingBatchesImpl(db) {
  const now = Date.now();
  let scanned = 0;
  let advanced = 0;

  const { canonicalAssignedDriverId } = require("./ride_callables");

  const snap = await db.ref("ride_requests").get();
  const rides = snap.val() && typeof snap.val() === "object" ? snap.val() : {};

  for (const [rideId, ride] of Object.entries(rides)) {
    const rid = normUid(rideId);
    if (!rid || !ride || typeof ride !== "object") continue;
    if (!isOpenSearchingRide(ride)) continue;
    if (canonicalAssignedDriverId(ride)) continue;

    scanned += 1;
    const md =
      ride.match_debug && typeof ride.match_debug === "object"
        ? ride.match_debug
        : {};
    const matchingState = String(md.matching_state ?? "").trim();
    const batchRemaining = Number(md.batch_remaining_eligible ?? 0) || 0;
    const batchIds = Array.isArray(md.batch_driver_ids)
      ? md.batch_driver_ids.map(normUid).filter(Boolean)
      : [];

    const shouldConsider =
      batchRemaining > 0 ||
      matchingState === "waiting_next_batch" ||
      matchingState === "offers_active";
    if (!shouldConsider || batchIds.length === 0) continue;

    const expired = await currentBatchOffersExpired(db, rid, batchIds, now);
    if (!expired) continue;

    console.log("MATCH_BATCH_ADVANCE_START", `rideId=${rid}`, `scanner=batch_job`);
    const { enqueueDispatchWork } = require("./dispatch_engine/dispatch_work_queue_engine");
    const { processDispatchWorkQueues } = require("./dispatch_engine/dispatch_work_queue_processor");
    await enqueueDispatchWork(db, "matching", {
      ride_id: rid,
      market: String(ride.market_pool ?? ride.market ?? ride.dispatch_market_id ?? "").trim(),
      reason: "batch_advance_scanner",
      priority: 7,
    });
    const res = await processDispatchWorkQueues(db, { limitPerQueue: 8 });
    if (res?.processed > 0) advanced += 1;
  }

  return { scanned, advanced };
}

/**
 * Mark drivers offline when RTDB says online but heartbeat is stale.
 */
async function sweepStaleOnlineDriversImpl(db) {
  const now = Date.now();
  let scanned = 0;
  let forcedOffline = 0;

  const snap = await db.ref("online_drivers").get();
  const online = snap.val() && typeof snap.val() === "object" ? snap.val() : {};

  for (const driverId of Object.keys(online)) {
    const d = normUid(driverId);
    if (!d) continue;
    scanned += 1;

    const profSnap = await db.ref(`drivers/${d}`).get();
    const prof =
      profSnap.exists() && typeof profSnap.val() === "object" ? profSnap.val() : {};
    const onlineRow =
      online[d] && typeof online[d] === "object" ? online[d] : {};

    const lastSeen = Math.max(
      Number(prof.last_active_at ?? 0) || 0,
      Number(prof.last_seen_at ?? 0) || 0,
      Number(prof.presence_heartbeat_at ?? 0) || 0,
      Number(prof.availability?.last_seen_ms ?? 0) || 0,
      Number(onlineRow.last_seen_ms ?? 0) || 0,
      Number(onlineRow.updated_at ?? 0) || 0,
    );

    if (lastSeen > 0 && now - lastSeen <= STALE_DRIVER_HEARTBEAT_MS) {
      continue;
    }

    const updates = {
      [`drivers/${d}/online`]: false,
      [`drivers/${d}/is_online`]: false,
      [`drivers/${d}/isOnline`]: false,
      [`drivers/${d}/isAvailable`]: false,
      [`drivers/${d}/available`]: false,
      [`drivers/${d}/status`]: "offline",
      [`drivers/${d}/dispatch_state`]: "offline",
      [`drivers/${d}/driver_availability_mode`]: "offline",
      [`drivers/${d}/updated_at`]: now,
      [`drivers/${d}/last_availability_intent`]: "offline",
      [`drivers/${d}/last_availability_intent_at`]: now,
      [`drivers/${d}/presence_offline_reason`]: "stale_heartbeat_sweep",
      [`drivers/${d}/presence_offline_at_ms`]: now,
      [`online_drivers/${d}`]: null,
      [`driver_locations/${d}`]: null,
    };

    const queueSnap = await db.ref(`driver_offer_queue/${d}`).get();
    const queue =
      queueSnap.exists() && typeof queueSnap.val() === "object" ? queueSnap.val() : {};
    for (const rideId of Object.keys(queue)) {
      const rid = normUid(rideId);
      if (!rid) continue;
      updates[`driver_offer_queue/${d}/${rid}`] = null;
      updates[`driver_offer_queue_debug/${d}/${rid}`] = null;
      updates[`ride_offer_fanout/${rid}/${d}`] = null;
    }

    await db.ref().update(updates);
    forcedOffline += 1;
    console.log(
      "DRIVER_PRESENCE_STALE_OFFLINE",
      `driverId=${d}`,
      `last_seen_ms=${lastSeen}`,
      `age_ms=${lastSeen > 0 ? now - lastSeen : -1}`,
    );
  }

  return { scanned, forcedOffline };
}

const advanceStuckMatchingBatches = onSchedule(
  { schedule: "every 2 minutes", timeZone: "Africa/Lagos", region: REGION },
  async () => {
    const db = admin.database();
    try {
      const stats = await advanceStuckMatchingBatchesImpl(db);
      logger.info("MATCH_BATCH_ADVANCE_OK", stats);
    } catch (e) {
      logger.error("MATCH_BATCH_ADVANCE_FAIL", {
        error: String(e?.message || e),
      });
    }
  },
);

const sweepStaleOnlineDrivers = onSchedule(
  { schedule: "every 2 minutes", timeZone: "Africa/Lagos", region: REGION },
  async () => {
    const db = admin.database();
    try {
      const stats = await sweepStaleOnlineDriversImpl(db);
      logger.info("DRIVER_PRESENCE_SWEEP_OK", stats);
    } catch (e) {
      logger.error("DRIVER_PRESENCE_SWEEP_FAIL", {
        error: String(e?.message || e),
      });
    }
  },
);

module.exports = {
  advanceStuckMatchingBatches,
  sweepStaleOnlineDrivers,
  advanceStuckMatchingBatchesImpl,
  sweepStaleOnlineDriversImpl,
  BATCH_ADVANCE_GRACE_MS,
};
