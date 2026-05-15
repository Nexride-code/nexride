/**
 * Scheduled background sweepers that keep the driver_offer_queue and the
 * canonical ride/delivery tables tidy. They are idempotent and additive — the
 * primary offer cleanup still happens inline in `clearFanoutAndOffers` when a
 * ride is matched, cancelled or expired. These jobs cover the edge cases where
 * a rider/customer client never invokes `expireRideRequest` (app killed during
 * matching, network drop, etc.) and offers would otherwise linger.
 */

const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");
const { REGION } = require("./params");
const { sweepOrphanRideLifecyclePointers } = require("./ride_pointer_orphans");

const STALE_OFFER_GRACE_MS = 5 * 60 * 1000; // 5 min past expires_at
const ABANDONED_RIDE_GRACE_MS = 10 * 60 * 1000; // 10 min past ride expires_at

function nowMs() {
  return Date.now();
}

function normUid(uid) {
  return String(uid ?? "").trim();
}

/**
 * Sweep `driver_offer_queue/*` and remove offers whose `expires_at` has
 * elapsed by more than STALE_OFFER_GRACE_MS. Driver clients already filter
 * expired offers locally; this sweep prevents the database from growing
 * unbounded when a rider abandons a ride during the searching window and the
 * client-side `expireRideRequest` callable never fires.
 */
async function sweepStaleDriverOfferQueue(db) {
  const snap = await db.ref("driver_offer_queue").get();
  const queues = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  const now = nowMs();
  const updates = {};
  let removedOffers = 0;
  let scannedDrivers = 0;
  let scannedOffers = 0;

  for (const [driverId, queue] of Object.entries(queues)) {
    const d = normUid(driverId);
    if (!d) continue;
    if (!queue || typeof queue !== "object") continue;
    scannedDrivers += 1;
    for (const [rideId, offer] of Object.entries(queue)) {
      const rid = normUid(rideId);
      if (!rid) continue;
      scannedOffers += 1;
      const expiresAt = Number(
        (offer && (offer.expires_at ?? offer.request_expires_at)) || 0,
      ) || 0;
      if (expiresAt > 0 && now - expiresAt > STALE_OFFER_GRACE_MS) {
        updates[`driver_offer_queue/${d}/${rid}`] = null;
        updates[`driver_offer_queue_debug/${d}/${rid}`] = null;
        updates[`ride_offer_fanout/${rid}/${d}`] = null;
        removedOffers += 1;
      }
    }
  }
  if (Object.keys(updates).length) {
    await db.ref().update(updates);
  }
  console.log(
    "DISPATCH_SWEEP_OFFER_QUEUE",
    `scanned_drivers=${scannedDrivers}`,
    `scanned_offers=${scannedOffers}`,
    `removed=${removedOffers}`,
  );
}

/**
 * Force-expire rides that are still in the open searching pool past their
 * expires_at. Saves us from "phantom open rides" when a rider client crashes
 * mid-matching. We mark trip_state=expired, status=cancelled, then clear the
 * fan-out the same way `expireRideRequest` does.
 */
async function expireAbandonedRidesInPool(db) {
  const snap = await db.ref("ride_requests").get();
  const rides = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  const now = nowMs();
  let expired = 0;

  for (const [rideId, ride] of Object.entries(rides)) {
    const rid = normUid(rideId);
    if (!rid || !ride || typeof ride !== "object") continue;
    const status = String(ride.status ?? "").trim().toLowerCase();
    const tripState = String(ride.trip_state ?? "").trim().toLowerCase();
    if (
      tripState === "trip_completed" ||
      tripState === "trip_cancelled" ||
      tripState === "expired" ||
      status === "completed" ||
      status === "cancelled" ||
      status === "expired"
    ) {
      continue;
    }
    const expiresAt = Number(
      ride.expires_at ?? ride.request_expires_at ?? 0,
    ) || 0;
    if (expiresAt <= 0) continue;
    if (now - expiresAt < ABANDONED_RIDE_GRACE_MS) continue;

    // Only sweep open-pool rides that never matched a driver. If a driver was
    // assigned, we leave it for `cancelRideRequest`/admin tooling to handle.
    const driverId = String(ride.driver_id ?? "").trim();
    if (driverId && !driverId.startsWith("placeholder_")) continue;

    await db.ref(`ride_requests/${rid}`).update({
      trip_state: "expired",
      status: "cancelled",
      cancelled_at: now,
      cancel_reason: "abandoned_by_rider_sweeper",
      cancel_actor: "system",
      updated_at: now,
    });
    // Clear all fan-out for this rid.
    const fanSnap = await db.ref(`ride_offer_fanout/${rid}`).get();
    const fan = fanSnap.val() && typeof fanSnap.val() === "object" ? fanSnap.val() : {};
    const updates = {};
    for (const driverUid of Object.keys(fan)) {
      const d = normUid(driverUid);
      if (!d) continue;
      updates[`driver_offer_queue/${d}/${rid}`] = null;
      updates[`driver_offer_queue_debug/${d}/${rid}`] = null;
      updates[`ride_offer_fanout/${rid}/${d}`] = null;
    }
    const riderId = normUid(ride.rider_id);
    if (riderId) {
      updates[`rider_active_trip/${riderId}`] = null;
    }
    if (Object.keys(updates).length) {
      await db.ref().update(updates);
    }
    expired += 1;
  }
  console.log("DISPATCH_SWEEP_ABANDONED_RIDES", `expired=${expired}`);
}

exports.sweepDispatchHealth = onSchedule(
  {
    schedule: "every 5 minutes",
    timeZone: "Africa/Lagos",
    region: REGION,
  },
  async (_event) => {
    const db = admin.database();
    try {
      await sweepStaleDriverOfferQueue(db);
    } catch (e) {
      console.log("DISPATCH_SWEEP_OFFER_QUEUE_FAIL", String(e?.message || e));
    }
    try {
      await expireAbandonedRidesInPool(db);
    } catch (e) {
      console.log("DISPATCH_SWEEP_ABANDONED_RIDES_FAIL", String(e?.message || e));
    }
    try {
      await sweepOrphanRideLifecyclePointers(db);
    } catch (e) {
      console.log("DISPATCH_SWEEP_RIDE_POINTER_ORPHANS_FAIL", String(e?.message || e));
    }
  },
);

module.exports = {
  sweepStaleDriverOfferQueue,
  expireAbandonedRidesInPool,
  sweepOrphanRideLifecyclePointers,
};
