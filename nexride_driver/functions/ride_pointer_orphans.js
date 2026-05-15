/**
 * Defensive reconciliation for RTDB ride activity pointers when a prior write
 * partially failed or a client never retried cleanup after a terminal ride.
 *
 * Sweeps: active_trips/*, rider_active_trip/*, driver_active_ride/*
 * Idempotent — only nulls paths that disagree with canonical ride_requests state.
 */

"use strict";

function normUid(uid) {
  return String(uid ?? "").trim();
}

function isPlaceholderDriverId(v) {
  if (v === null || v === undefined) return true;
  const s = String(v).trim().toLowerCase();
  return (
    s.length === 0 ||
    s === "waiting" ||
    s === "pending" ||
    s === "null" ||
    s === "none" ||
    s === "unassigned" ||
    s === "n/a" ||
    s === "tbd"
  );
}

/**
 * @param {null|undefined|object} ride
 * @returns {boolean}
 */
function rideDocumentIsTerminal(ride) {
  if (!ride || typeof ride !== "object") {
    return true;
  }
  const ts = String(ride.trip_state ?? "").trim().toLowerCase();
  const st = String(ride.status ?? "").trim().toLowerCase();
  if (
    ts === "completed" ||
    ts === "cancelled" ||
    ts === "expired" ||
    ts === "trip_completed" ||
    ts === "trip_cancelled"
  ) {
    return true;
  }
  if (st === "completed" || st === "cancelled" || st === "expired") {
    return true;
  }
  return false;
}

function riderActiveTripRideId(ptrVal) {
  if (ptrVal === null || ptrVal === undefined) {
    return "";
  }
  if (typeof ptrVal === "string") {
    return normUid(ptrVal);
  }
  if (typeof ptrVal === "object") {
    return normUid(ptrVal.ride_id ?? ptrVal.rideId);
  }
  return "";
}

async function applyChunkedRootUpdate(db, updates) {
  const keys = Object.keys(updates);
  if (!keys.length) {
    return;
  }
  const CHUNK = 400;
  for (let i = 0; i < keys.length; i += CHUNK) {
    const slice = {};
    for (let j = i; j < Math.min(keys.length, i + CHUNK); j += 1) {
      const k = keys[j];
      slice[k] = updates[k];
    }
    await db.ref().update(slice);
  }
}

/**
 * @param {import("firebase-admin").database.Database} db
 * @returns {Promise<{ cleared_active_trips: number, cleared_rider_pointers: number, cleared_driver_pointers: number, paths_cleared: number }>}
 */
async function sweepOrphanRideLifecyclePointers(db) {
  const updates = {};
  const schedule = (relPath) => {
    const p = String(relPath || "").trim();
    if (!p) return;
    updates[p] = null;
  };

  let clearedActiveTrips = 0;
  let clearedRiderPointers = 0;
  let clearedDriverPointers = 0;

  const atSnap = await db.ref("active_trips").get();
  const atMap = atSnap.val() && typeof atSnap.val() === "object" ? atSnap.val() : {};
  for (const rideKey of Object.keys(atMap)) {
    const rideId = normUid(rideKey);
    if (!rideId) continue;
    const rSnap = await db.ref(`ride_requests/${rideId}`).get();
    const ride = rSnap.val() && typeof rSnap.val() === "object" ? rSnap.val() : null;
    if (!rideDocumentIsTerminal(ride)) {
      continue;
    }
    const summary = atMap[rideKey] && typeof atMap[rideKey] === "object" ? atMap[rideKey] : {};
    const riderFromRide = normUid(ride?.rider_id ?? ride?.riderId);
    const driverFromRide = normUid(ride?.driver_id ?? ride?.driverId);
    const riderFromSummary = normUid(summary.rider_id ?? summary.riderId);
    const driverFromSummary = normUid(summary.driver_id ?? summary.driverId);
    const r = riderFromRide || riderFromSummary;
    const d =
      !isPlaceholderDriverId(ride?.driver_id ?? ride?.driverId) && driverFromRide
        ? driverFromRide
        : !isPlaceholderDriverId(summary?.driver_id) && driverFromSummary
          ? driverFromSummary
          : "";
    schedule(`active_trips/${rideId}`);
    if (r) schedule(`rider_active_trip/${r}`);
    if (d) schedule(`driver_active_ride/${d}`);
    clearedActiveTrips += 1;
  }

  const ratSnap = await db.ref("rider_active_trip").get();
  const ratMap = ratSnap.val() && typeof ratSnap.val() === "object" ? ratSnap.val() : {};
  for (const [riderKey, ptrVal] of Object.entries(ratMap)) {
    const riderId = normUid(riderKey);
    if (!riderId) continue;
    const rideId = riderActiveTripRideId(ptrVal);
    if (!rideId) {
      schedule(`rider_active_trip/${riderId}`);
      clearedRiderPointers += 1;
      continue;
    }
    const rideSnap = await db.ref(`ride_requests/${rideId}`).get();
    const ride = rideSnap.val() && typeof rideSnap.val() === "object" ? rideSnap.val() : null;
    const riderOnRide = normUid(ride?.rider_id ?? ride?.riderId);
    if (!ride) {
      schedule(`rider_active_trip/${riderId}`);
      schedule(`active_trips/${rideId}`);
      clearedRiderPointers += 1;
      continue;
    }
    if (rideDocumentIsTerminal(ride)) {
      schedule(`rider_active_trip/${riderId}`);
      schedule(`active_trips/${rideId}`);
      clearedRiderPointers += 1;
      continue;
    }
    if (riderOnRide && riderOnRide !== riderId) {
      schedule(`rider_active_trip/${riderId}`);
      clearedRiderPointers += 1;
    }
  }

  const darSnap = await db.ref("driver_active_ride").get();
  const darMap = darSnap.val() && typeof darSnap.val() === "object" ? darSnap.val() : {};
  for (const [driverKey, ptrVal] of Object.entries(darMap)) {
    const driverId = normUid(driverKey);
    if (!driverId) continue;
    let rideId = "";
    if (ptrVal && typeof ptrVal === "object") {
      rideId = normUid(ptrVal.ride_id ?? ptrVal.rideId);
    } else if (typeof ptrVal === "string") {
      rideId = normUid(ptrVal);
    }
    if (!rideId) {
      schedule(`driver_active_ride/${driverId}`);
      clearedDriverPointers += 1;
      continue;
    }
    const rideSnap = await db.ref(`ride_requests/${rideId}`).get();
    const ride = rideSnap.val() && typeof rideSnap.val() === "object" ? rideSnap.val() : null;
    const assigned = normUid(ride?.driver_id ?? ride?.driverId);
    const badAssignment =
      ride &&
      !isPlaceholderDriverId(ride?.driver_id) &&
      assigned &&
      assigned !== driverId;
    if (!ride) {
      schedule(`driver_active_ride/${driverId}`);
      schedule(`active_trips/${rideId}`);
      clearedDriverPointers += 1;
      continue;
    }
    if (rideDocumentIsTerminal(ride)) {
      schedule(`driver_active_ride/${driverId}`);
      schedule(`active_trips/${rideId}`);
      clearedDriverPointers += 1;
      continue;
    }
    if (badAssignment) {
      schedule(`driver_active_ride/${driverId}`);
      clearedDriverPointers += 1;
    }
  }

  await applyChunkedRootUpdate(db, updates);
  const pathsCleared = Object.keys(updates).length;
  console.log(
    "RIDE_POINTER_ORPHAN_SWEEP",
    `active_trips_rows=${clearedActiveTrips}`,
    `rider_ptr=${clearedRiderPointers}`,
    `driver_ptr=${clearedDriverPointers}`,
    `paths=${pathsCleared}`,
  );
  return {
    cleared_active_trips: clearedActiveTrips,
    cleared_rider_pointers: clearedRiderPointers,
    cleared_driver_pointers: clearedDriverPointers,
    paths_cleared: pathsCleared,
  };
}

module.exports = {
  rideDocumentIsTerminal,
  riderActiveTripRideId,
  sweepOrphanRideLifecyclePointers,
};
