/**
 * Scheduled self-healing cleanups for production pilot operations.
 */

"use strict";

const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");
const { logger } = require("firebase-functions");
const { REGION } = require("./params");
const { sweepStaleDriverOfferQueue, expireAbandonedRidesInPool } =
  require("./dispatch_maintenance_jobs");
const { sweepOrphanRideLifecyclePointers } = require("./ride_pointer_orphans");
const {
  tripIdBlocksDriverOffers,
  collectDriverActivePointerTripIds,
  clearDriverActivePointers,
  emptyCleanupStats,
  logCleanupStats,
  STALE_SEARCHING_RIDE_MS,
  normalizeDeliveryState,
  canonicalAssignedDeliveryDriverId,
} = require("./driver_active_pointer_guard");
const { rideDocumentIsTerminal } = require("./ride_pointer_orphans");

const ACTIVE_DELIVERY_GUARD = new Set([
  "driver_assigned",
  "driver_arriving_pickup",
  "picked_up",
  "on_delivery",
  "arrived_dropoff",
]);

function normUid(v) {
  return String(v ?? "").trim();
}

async function applyChunkedUpdate(db, updates) {
  const keys = Object.keys(updates);
  if (!keys.length) return;
  const CHUNK = 400;
  for (let i = 0; i < keys.length; i += CHUNK) {
    const slice = {};
    for (let j = i; j < Math.min(keys.length, i + CHUNK); j++) {
      slice[keys[j]] = updates[keys[j]];
    }
    await db.ref().update(slice);
  }
}

async function cleanStaleDriverActivePointers(db) {
  const stats = emptyCleanupStats();
  const now = Date.now();
  try {
    const [darSnap, dadSnap] = await Promise.all([
      db.ref("driver_active_ride").get(),
      db.ref("driver_active_delivery").get(),
    ]);
    const drivers = new Set();
    const dar = darSnap.val() && typeof darSnap.val() === "object" ? darSnap.val() : {};
    const dad = dadSnap.val() && typeof dadSnap.val() === "object" ? dadSnap.val() : {};
    for (const k of Object.keys(dar)) drivers.add(k);
    for (const k of Object.keys(dad)) drivers.add(k);

    for (const driverId of drivers) {
      const d = normUid(driverId);
      if (!d) continue;
      const tripIds = await collectDriverActivePointerTripIds(db, d);
      for (const tripId of tripIds) {
        stats.scanned += 1;
        const verdict = await tripIdBlocksDriverOffers(db, d, tripId);
        if (verdict.blocks) {
          stats.skipped_active += 1;
          continue;
        }
        if (verdict.reason === "missing") stats.missing += 1;
        else if (verdict.reason.includes("terminal")) stats.terminal += 1;
        else if (verdict.reason.includes("unassigned")) stats.unassigned += 1;
        else stats.stale += 1;
        await clearDriverActivePointers(db, d, tripId, "scheduled_stale_driver_pointer");
        stats.cleared += 1;
      }
    }
  } catch (e) {
    stats.errors += 1;
    logger.warn("cleanStaleDriverActivePointers", { err: String(e?.message || e) });
  }
  logCleanupStats("cleanStaleDriverActivePointers", stats);
  return stats;
}

async function cleanStaleSearchingRides(db) {
  const stats = emptyCleanupStats();
  const now = Date.now();
  try {
    const snap = await db.ref("ride_requests").get();
    const rides = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
    for (const [rideId, ride] of Object.entries(rides)) {
      const rid = normUid(rideId);
      if (!rid || !ride || typeof ride !== "object") continue;
      stats.scanned += 1;
      if (rideDocumentIsTerminal(ride)) {
        stats.terminal += 1;
        continue;
      }
      const ts = String(ride.trip_state ?? ride.status ?? "").toLowerCase();
      if (ts !== "searching" && ts !== "requested" && ts !== "searching_driver") {
        continue;
      }
      const assigned = String(ride.driver_id ?? "").trim();
      if (assigned && !assigned.startsWith("placeholder_") && assigned !== "waiting") {
        stats.skipped_active += 1;
        continue;
      }
      const expiresAt =
        Number(ride.expires_at ?? ride.request_expires_at ?? ride.created_at_ms ?? 0) || 0;
      const age = expiresAt > 0 ? now - expiresAt : now - (Number(ride.created_at_ms ?? 0) || 0);
      if (age < STALE_SEARCHING_RIDE_MS) continue;
      await db.ref(`ride_requests/${rid}`).update({
        trip_state: "expired",
        status: "cancelled",
        cancel_reason: "stale_searching_sweeper",
        cancel_actor: "system",
        updated_at: now,
        "match_debug/cleanup_reason": "stale_searching_ride",
      });
      stats.cleared += 1;
    }
    const delSnap = await db.ref("delivery_requests").get();
    const deliveries =
      delSnap.val() && typeof delSnap.val() === "object" ? delSnap.val() : {};
    for (const [deliveryId, row] of Object.entries(deliveries)) {
      const did = normUid(deliveryId);
      if (!did || !row || typeof row !== "object") continue;
      stats.scanned += 1;
      const ds = normalizeDeliveryState(row.delivery_state);
      if (ds !== "searching") continue;
      if (canonicalAssignedDeliveryDriverId(row)) {
        stats.skipped_active += 1;
        continue;
      }
      const expiresAt = Number(row.expires_at ?? row.request_expires_at ?? 0) || 0;
      if (expiresAt > 0 && now - expiresAt < STALE_SEARCHING_RIDE_MS) continue;
      await db.ref(`delivery_requests/${did}`).update({
        delivery_state: "cancelled",
        status: "cancelled",
        cancel_reason: "stale_searching_delivery_sweeper",
        updated_at: now,
        "match_debug/cleanup_reason": "stale_searching_delivery",
      });
      stats.cleared += 1;
    }
  } catch (e) {
    stats.errors += 1;
    logger.warn("cleanStaleSearchingRides", { err: String(e?.message || e) });
  }
  logCleanupStats("cleanStaleSearchingRides", stats);
  return stats;
}

async function cleanExpiredDriverOffersJob(db) {
  const stats = emptyCleanupStats();
  try {
    const snap = await db.ref("driver_offer_queue").get();
    const queues = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
    const now = Date.now();
    const updates = {};
    for (const [driverId, queue] of Object.entries(queues)) {
      const d = normUid(driverId);
      if (!d || !queue || typeof queue !== "object") continue;
      for (const [tripId, offer] of Object.entries(queue)) {
        const tid = normUid(tripId);
        if (!tid) continue;
        stats.scanned += 1;
        const expiresAt =
          Number((offer && (offer.expires_at ?? offer.request_expires_at)) || 0) || 0;
        if (expiresAt <= 0 || now <= expiresAt) continue;
        updates[`driver_offer_queue/${d}/${tid}`] = null;
        updates[`driver_offer_queue_debug/${d}/${tid}`] = null;
        updates[`ride_offer_fanout/${tid}/${d}`] = null;
        updates[`delivery_offer_fanout/${tid}/${d}`] = null;
        updates[`delivery_offer_queue/${d}/${tid}`] = null;
        stats.cleared += 1;
      }
    }
    await applyChunkedUpdate(db, updates);
  } catch (e) {
    stats.errors += 1;
    logger.warn("cleanExpiredDriverOffers", { err: String(e?.message || e) });
  }
  logCleanupStats("cleanExpiredDriverOffers", stats);
  return stats;
}

async function cleanOrphanActiveTrips(db) {
  const stats = emptyCleanupStats();
  try {
    const res = await sweepOrphanRideLifecyclePointers(db);
    stats.scanned =
      (res.cleared_active_trips || 0) +
      (res.cleared_rider_pointers || 0) +
      (res.cleared_driver_pointers || 0);
    stats.cleared = res.paths_cleared || 0;
  } catch (e) {
    stats.errors += 1;
    logger.warn("cleanOrphanActiveTrips", { err: String(e?.message || e) });
  }
  logCleanupStats("cleanOrphanActiveTrips", stats);
  return stats;
}

async function cleanStaleDeliveryPointers(db) {
  const stats = emptyCleanupStats();
  const paths = [
    "active_deliveries",
    "customer_active_delivery",
    "merchant_active_delivery",
    "driver_active_delivery",
  ];
  try {
    for (const root of paths) {
      const snap = await db.ref(root).get();
      const map = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
      for (const [key, ptr] of Object.entries(map)) {
        stats.scanned += 1;
        let deliveryId = normUid(key);
        let driverId = "";
        if (root === "driver_active_delivery") {
          driverId = normUid(key);
          deliveryId = normUid(
            ptr && typeof ptr === "object"
              ? ptr.delivery_id ?? ptr.deliveryId
              : ptr,
          );
        } else if (ptr && typeof ptr === "object") {
          deliveryId = normUid(ptr.delivery_id ?? ptr.deliveryId ?? key);
        }
        if (!deliveryId) {
          stats.missing += 1;
          await db.ref(`${root}/${key}`).remove();
          stats.cleared += 1;
          continue;
        }
        const rowSnap = await db.ref(`delivery_requests/${deliveryId}`).get();
        if (!rowSnap.exists()) {
          stats.missing += 1;
          await db.ref(`${root}/${key}`).remove();
          stats.cleared += 1;
          continue;
        }
        const row = rowSnap.val() || {};
        const ds = normalizeDeliveryState(row.delivery_state);
        if (ds === "completed" || ds === "cancelled") {
          stats.terminal += 1;
          await db.ref(`${root}/${key}`).remove();
          stats.cleared += 1;
          continue;
        }
        if (driverId) {
          const assigned = canonicalAssignedDeliveryDriverId(row);
          if (assigned && assigned !== driverId) {
            stats.unassigned += 1;
            await db.ref(`${root}/${key}`).remove();
            stats.cleared += 1;
            continue;
          }
          if (ds === "searching") {
            stats.stale += 1;
            await db.ref(`${root}/${key}`).remove();
            stats.cleared += 1;
            continue;
          }
          if (ACTIVE_DELIVERY_GUARD.has(ds)) {
            stats.skipped_active += 1;
          }
        }
      }
    }
  } catch (e) {
    stats.errors += 1;
    logger.warn("cleanStaleDeliveryPointers", { err: String(e?.message || e) });
  }
  logCleanupStats("cleanStaleDeliveryPointers", stats);
  return stats;
}

function scheduleJob(name, schedule, handler) {
  return onSchedule(
    { schedule, timeZone: "Africa/Lagos", region: REGION },
    async () => {
      const db = admin.database();
      try {
        await handler(db);
        logger.info("PRODUCTION_CLEANUP_OK", { job: name });
      } catch (e) {
        logger.error("PRODUCTION_CLEANUP_FAIL", {
          job: name,
          error: String(e?.message || e),
        });
      }
    },
  );
}

exports.cleanStaleDriverActivePointers = scheduleJob(
  "cleanStaleDriverActivePointers",
  "every 10 minutes",
  cleanStaleDriverActivePointers,
);
exports.cleanStaleSearchingRides = scheduleJob(
  "cleanStaleSearchingRides",
  "every 10 minutes",
  cleanStaleSearchingRides,
);
exports.cleanExpiredDriverOffers = scheduleJob(
  "cleanExpiredDriverOffers",
  "every 15 minutes",
  cleanExpiredDriverOffersJob,
);
exports.cleanOrphanActiveTrips = scheduleJob(
  "cleanOrphanActiveTrips",
  "every 10 minutes",
  cleanOrphanActiveTrips,
);
exports.cleanStaleDeliveryPointers = scheduleJob(
  "cleanStaleDeliveryPointers",
  "every 10 minutes",
  cleanStaleDeliveryPointers,
);

module.exports.cleanStaleDriverActivePointersImpl = cleanStaleDriverActivePointers;
module.exports.cleanStaleSearchingRidesImpl = cleanStaleSearchingRides;
module.exports.cleanExpiredDriverOffersImpl = cleanExpiredDriverOffersJob;
module.exports.cleanOrphanActiveTripsImpl = cleanOrphanActiveTrips;
module.exports.cleanStaleDeliveryPointersImpl = cleanStaleDeliveryPointers;
