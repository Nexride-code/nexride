/**
 * Backend-owned driver availability refresh before go-online / discovery.
 * Clears stale trip pointers, profile trip summary, and expired offer-queue rows.
 */

"use strict";

const { dispatchVerboseLog } = require("./dispatch_engine/dispatch_production_log");
const {
  removeDriverFromDispatchIndexWhenUnavailable,
} = require("./dispatch_engine/dispatch_index_engine");
const { rideDocumentIsTerminal } = require("./ride_pointer_orphans");
const { repairDriverDispatchBlockers } = require("./repair_driver_dispatch_blockers");
const { isSearchingRide } = require("./driver_active_pointer_guard");

function normUid(uid) {
  return String(uid ?? "").trim();
}

const STALE_PROFILE_STATUS = new Set([
  "arrived",
  "accepted",
  "driver_assigned",
  "driver_enroute",
  "driver_arriving",
  "driver_on_the_way",
  "in_trip",
  "started",
  "on_trip",
  "in_progress",
  "trip_started",
  "busy",
  "on_ride",
]);

/**
 * Remove expired rows under driver_offer_queue/{driverId}.
 * @returns {Promise<{ removed: number }>}
 */
async function purgeExpiredDriverOfferQueueEntries(db, driverId, now = Date.now()) {
  const d = normUid(driverId);
  if (!d) return { removed: 0 };

  const snap = await db.ref(`driver_offer_queue/${d}`).get();
  const queue = snap.exists() && typeof snap.val() === "object" ? snap.val() : {};
  const updates = {};
  let removed = 0;

  for (const [rideId, offer] of Object.entries(queue)) {
    const rid = normUid(rideId);
    if (!rid) continue;
    const exp =
      Number(
        (offer && typeof offer === "object"
          ? offer.expires_at ?? offer.request_expires_at ?? offer.lease_expires_at
          : 0) || 0,
      ) || 0;
    let shouldRemove = exp > 0 && now >= exp;
    if (!shouldRemove) {
      try {
        const rideSnap = await db.ref(`ride_requests/${rid}`).get();
        const ride =
          rideSnap.exists() && typeof rideSnap.val() === "object" ? rideSnap.val() : null;
        const rideExpiresAt =
          Number(ride?.expires_at ?? ride?.request_expires_at ?? 0) || 0;
        const rideExpired = rideExpiresAt > 0 && now >= rideExpiresAt;
        shouldRemove =
          !ride ||
          rideDocumentIsTerminal(ride) ||
          (ride && isSearchingRide(ride) && rideExpired);
      } catch (_) {}
    }
    if (shouldRemove) {
      updates[`driver_offer_queue/${d}/${rid}`] = null;
      updates[`driver_offer_queue_debug/${d}/${rid}`] = null;
      updates[`ride_offer_fanout/${rid}/${d}`] = null;
      removed += 1;
    }
  }

  if (Object.keys(updates).length) {
    await db.ref().update(updates);
  }
  if (removed > 0) {
    try {
      const {
        recordOfferExpired,
      } = require("./dispatch_engine/dispatch_production_metrics");
      recordOfferExpired(removed);
    } catch (_) {}
  }
  return { removed };
}

async function clearStaleDriverTripSummary(db, driverId, now = Date.now()) {
  const d = normUid(driverId);
  if (!d) return { cleared: false };

  const profSnap = await db.ref(`drivers/${d}`).get();
  const prof =
    profSnap.exists() && typeof profSnap.val() === "object" ? profSnap.val() : {};
  const updates = {};
  let cleared = false;

  const summaryRideId = normUid(
    prof.latest_trip_ride_id ??
      prof.latestTripRideId ??
      prof.activeRideId ??
      prof.currentRideId ??
      prof.active_ride_id,
  );

  if (summaryRideId) {
    const rideSnap = await db.ref(`ride_requests/${summaryRideId}`).get();
    const ride =
      rideSnap.exists() && typeof rideSnap.val() === "object" ? rideSnap.val() : null;
    const rideExpiresAt =
      Number(ride?.expires_at ?? ride?.request_expires_at ?? 0) || 0;
    const rideExpired = rideExpiresAt > 0 && now >= rideExpiresAt;
    const shouldClear =
      !ride ||
      rideDocumentIsTerminal(ride) ||
      (ride && isSearchingRide(ride) && rideExpired);
    if (shouldClear) {
      updates[`drivers/${d}/latest_trip_ride_id`] = null;
      updates[`drivers/${d}/latestTripRideId`] = null;
      updates[`drivers/${d}/latest_trip_status`] = null;
      updates[`drivers/${d}/latest_trip_trip_state`] = null;
      updates[`drivers/${d}/latest_trip_at`] = null;
      updates[`drivers/${d}/active_offer_lease_id`] = null;
      updates[`drivers/${d}/active_offer_trip_id`] = null;
      updates[`drivers/${d}/activeRideId`] = null;
      updates[`drivers/${d}/currentRideId`] = null;
      updates[`drivers/${d}/active_ride_id`] = null;
      cleared = true;
    }
  }

  const status = String(prof.status ?? "").trim().toLowerCase();
  const dispatchState = String(prof.dispatch_state ?? "").trim().toLowerCase();
  const hasBlockingTrip = normUid(prof.activeRideId ?? prof.currentRideId);
  if (
    !hasBlockingTrip &&
    (STALE_PROFILE_STATUS.has(status) || STALE_PROFILE_STATUS.has(dispatchState))
  ) {
    updates[`drivers/${d}/status`] = "online_available";
    updates[`drivers/${d}/dispatch_state`] = "online_available";
    updates[`drivers/${d}/activeRideId`] = null;
    updates[`drivers/${d}/currentRideId`] = null;
    updates[`drivers/${d}/active_ride_id`] = null;
    cleared = true;
  }

  if (Object.keys(updates).length) {
    updates[`drivers/${d}/availability_refreshed_at`] = now;
    updates[`drivers/${d}/updated_at`] = now;
    await db.ref().update(updates);
    try {
      await removeDriverFromDispatchIndexWhenUnavailable(db, d, "stale_profile_cleared");
    } catch (_) {}
  }

  return { cleared };
}

/**
 * Full refresh: pointers, profile summary, expired offers.
 */
async function refreshDriverAvailability(db, driverId, options = {}) {
  const d = normUid(driverId);
  const source = String(options.source ?? "refresh").trim() || "refresh";
  if (!d) {
    return { success: false, reason: "invalid_driver_id" };
  }

  dispatchVerboseLog("REFRESH_DRIVER_AVAILABILITY_START", `driverId=${d}`, `source=${source}`);

  const repair = await repairDriverDispatchBlockers(db, d, {
    source: `refresh_availability_${source}`,
  });

  const summary = await clearStaleDriverTripSummary(db, d);
  const offers = await purgeExpiredDriverOfferQueueEntries(db, d);

  try {
    const {
      maybeUpsertAvailableDriverThrottled,
    } = require("./dispatch_engine/dispatch_available_drivers_index");
    await maybeUpsertAvailableDriverThrottled(db, d, {
      source: `refresh_availability_${source}`,
    });
  } catch (geoErr) {
    dispatchVerboseLog(
      "DISPATCH_GEO_INDEX_UPSERT_FAIL",
      `driverId=${d}`,
      String(geoErr?.message || geoErr),
    );
  }

  if (repair.success !== false) {
    console.log(
      "DISPATCH_BLOCKER_REPAIR_OK",
      `driverId=${d}`,
      `source=${source}`,
      `repairReason=${repair.reason ?? ""}`,
    );
  }

  dispatchVerboseLog(
    "REFRESH_DRIVER_AVAILABILITY_DONE",
    `driverId=${d}`,
    `repair=${repair.reason}`,
    `clearedPointers=${(repair.clearedTripIds || []).length}`,
    `summaryCleared=${summary.cleared}`,
    `offersRemoved=${offers.removed}`,
  );

  return {
    success: true,
    reason: "refreshed",
    repair,
    summary_cleared: summary.cleared,
    offers_removed: offers.removed,
  };
}

async function refreshDriverAvailabilityCallable(data, context, db) {
  const uid = normUid(context?.auth?.uid);
  const target = normUid(data?.driverId ?? data?.driver_id) || uid;
  if (!uid) {
    return { success: false, reason: "unauthorized" };
  }
  if (target !== uid) {
    const { requireAdmin } = require("./admin_auth");
    const deny = await requireAdmin(db, context, "refreshDriverAvailability");
    if (deny) {
      return { success: false, reason: "forbidden" };
    }
  }
  return refreshDriverAvailability(db, target, {
    source: String(data?.source ?? "callable").trim() || "callable",
  });
}

module.exports = {
  refreshDriverAvailability,
  refreshDriverAvailabilityCallable,
  purgeExpiredDriverOfferQueueEntries,
};
