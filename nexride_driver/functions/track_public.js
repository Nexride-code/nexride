/**
 * Public ride tracking mirror — no rider/driver PII beyond coarse areas + first name.
 * RTDB: ride_track_public/{track_token} — read-only for clients; only Admin SDK writes.
 */

const TRIP_STATE = {
  searching: "searching",
  accepted: "accepted",
  driver_assigned: "driver_assigned",
  driver_arriving: "driver_arriving",
  arrived: "arrived",
  in_progress: "in_progress",
  completed: "completed",
  cancelled: "cancelled",
  expired: "expired",
};

function normUid(uid) {
  return String(uid ?? "").trim();
}

function nowMs() {
  return Date.now();
}

function isPlaceholderDriverId(v) {
  if (v === null || v === undefined) return true;
  const s = String(v).trim().toLowerCase();
  return s.length === 0 || s === "waiting" || s === "pending" || s === "null";
}

function capitalizeWord(s) {
  const t = String(s || "").trim();
  if (!t) return "";
  return t.charAt(0).toUpperCase() + t.slice(1).toLowerCase();
}

function firstNameFromDriverAndUser(driver, user) {
  const uFirst = String(user?.firstName ?? user?.first_name ?? "").trim();
  if (uFirst) return capitalizeWord(uFirst.split(/\s+/)[0]).slice(0, 48) || null;
  const disp = String(user?.displayName ?? "").trim();
  if (disp) {
    const w = disp.split(/\s+/)[0];
    if (w && w.length > 1) return capitalizeWord(w).slice(0, 48);
  }
  const dName = String(driver?.name ?? driver?.driverName ?? "").trim();
  if (dName) {
    const w = dName.split(/\s+/)[0];
    if (w && w.length > 1) return capitalizeWord(w).slice(0, 48);
  }
  return null;
}

function vehicleLabelFromDriver(driver) {
  if (!driver || typeof driver !== "object") return "";
  const car = String(driver.car ?? "").trim();
  if (car) return car.slice(0, 80);
  const v = driver.vehicle;
  if (v && typeof v === "object") {
    const color = String(v.color ?? "").trim();
    const make = String(v.make ?? "").trim();
    const model = String(v.model ?? "").trim();
    const parts = [color, make, model].filter(Boolean);
    if (parts.length) return parts.join(" ").slice(0, 80);
  }
  return "";
}

function areaFromLocation(loc, rideHints) {
  const hints = rideHints && typeof rideHints === "object" ? rideHints : {};
  const fromHints = String(
    hints.pickup_area ??
      hints.pickup_zone ??
      hints.destination_area ??
      hints.area ??
      "",
  ).trim();
  if (fromHints) return fromHints.slice(0, 120);

  if (!loc || typeof loc !== "object") return "";
  const direct = String(
    loc.area ?? loc.neighborhood ?? loc.community ?? loc.zone ?? loc.locality ?? loc.city ?? "",
  ).trim();
  if (direct) return direct.slice(0, 120);

  const addr = String(loc.address ?? loc.formatted_address ?? loc.name ?? "").trim();
  if (addr) {
    const parts = addr.split(",").map((s) => s.trim()).filter(Boolean);
    if (parts.length >= 2) {
      return parts.slice(-2).join(", ").slice(0, 120);
    }
    return addr.slice(0, 80);
  }
  return "";
}

function pickupAreaFromRide(ride) {
  const pickup = ride.pickup && typeof ride.pickup === "object" ? ride.pickup : {};
  const hints = {
    pickup_area: ride.pickup_area ?? ride.pickupArea,
    pickup_zone: ride.pickup_zone,
    area: ride.area,
  };
  const a = areaFromLocation(pickup, hints);
  return a || "Pickup area";
}

function dropoffAreaFromRide(ride) {
  const drop = ride.dropoff && typeof ride.dropoff === "object" ? ride.dropoff : {};
  const hints = {
    destination_area: ride.destination_area ?? ride.destinationArea,
    destination_zone: ride.destination_zone,
  };
  const a = areaFromLocation(drop, hints);
  return a || "Drop-off area";
}

function tripPhaseAndStatus(ride) {
  const ts = String(ride.trip_state ?? "").trim().toLowerCase();
  const st = String(ride.status ?? "").trim().toLowerCase();

  if (ts === TRIP_STATE.completed || st === "completed" || st === "trip_completed") {
    return { trip_phase: "completed", trip_status: "Trip completed" };
  }
  if (ts === TRIP_STATE.cancelled || st === "cancelled") {
    return { trip_phase: "cancelled", trip_status: "Trip cancelled" };
  }
  if (ts === TRIP_STATE.expired) {
    return { trip_phase: "expired", trip_status: "Request expired" };
  }
  if (ts === TRIP_STATE.in_progress || ts === "trip_started") {
    return { trip_phase: "in_progress", trip_status: "Trip in progress" };
  }
  if (ts === TRIP_STATE.arrived || ts === "driver_arrived") {
    return { trip_phase: "arrived", trip_status: "Driver at pickup" };
  }
  if (ts === TRIP_STATE.driver_arriving || ts === "driver_arriving") {
    return { trip_phase: "en_route", trip_status: "Driver on the way" };
  }
  if (
    ts === TRIP_STATE.accepted ||
    ts === TRIP_STATE.driver_assigned ||
    ts === "driver_accepted" ||
    st === "accepted"
  ) {
    return { trip_phase: "assigned", trip_status: "Driver assigned" };
  }
  if (ts === TRIP_STATE.searching || st === "searching" || st === "matching") {
    return { trip_phase: "searching", trip_status: "Finding a driver" };
  }
  return { trip_phase: "searching", trip_status: "Finding a driver" };
}

function buildPublicDoc(ride, driverProfile, userProfile) {
  const { trip_phase, trip_status } = tripPhaseAndStatus(ride);
  const etaRaw = Number(ride.eta_min ?? ride.duration_min ?? 0);
  const eta_min = Number.isFinite(etaRaw) && etaRaw > 0 ? Math.round(etaRaw) : 0;

  const driverId = normUid(ride.driver_id);
  const hasDriver = driverId && !isPlaceholderDriverId(ride.driver_id);

  return {
    trip_status,
    trip_phase,
    pickup_area: pickupAreaFromRide(ride),
    dropoff_area: dropoffAreaFromRide(ride),
    eta_min,
    vehicle_label: hasDriver ? vehicleLabelFromDriver(driverProfile) : "",
    driver_first_name: hasDriver ? firstNameFromDriverAndUser(driverProfile, userProfile) : null,
    updated_at: nowMs(),
  };
}

/**
 * Upsert `ride_track_public/{token}` from canonical `ride_requests/{rideId}`.
 * Ensures `ride_requests/{rideId}.track_token` exists (legacy backfill).
 */
async function syncRideTrackPublic(db, rideId) {
  const rid = normUid(rideId);
  if (!rid) return;

  const rideSnap = await db.ref(`ride_requests/${rid}`).get();
  const ride = rideSnap.val();
  if (!ride || typeof ride !== "object") {
    return;
  }

  let token = String(ride.track_token ?? "").trim();
  if (!token) {
    token = normUid(db.ref().push().key);
    if (!token) return;
    await db.ref(`ride_requests/${rid}`).update({
      track_token: token,
      updated_at: nowMs(),
    });
  }

  const driverId = normUid(ride.driver_id);
  let driverProfile = null;
  let userProfile = null;
  if (driverId && !isPlaceholderDriverId(ride.driver_id)) {
    const [dSnap, uSnap] = await Promise.all([
      db.ref(`drivers/${driverId}`).get(),
      db.ref(`users/${driverId}`).get(),
    ]);
    driverProfile = dSnap.val();
    userProfile = uSnap.val();
  }

  const publicDoc = buildPublicDoc(ride, driverProfile, userProfile);
  await db.ref(`ride_track_public/${token}`).set(publicDoc);
}

/**
 * Callable handler — unauthenticated; token is the capability.
 * @param {Record<string, unknown>} data
 * @param {import("firebase-admin").database.Database} db
 */
async function getRideTrackSummary(data, db) {
  const token = String(data?.token ?? "").trim();
  if (!token || token.length < 6) {
    return { success: false, reason: "invalid_token" };
  }

  const snap = await db.ref(`ride_track_public/${token}`).get();
  if (!snap.exists()) {
    return { success: false, reason: "not_found" };
  }
  const v = snap.val() || {};

  return {
    success: true,
    summary: {
      trip_status: String(v.trip_status ?? ""),
      trip_phase: String(v.trip_phase ?? ""),
      pickup_area: String(v.pickup_area ?? ""),
      dropoff_area: String(v.dropoff_area ?? ""),
      eta_min: Number(v.eta_min ?? 0) || 0,
      vehicle_label: String(v.vehicle_label ?? ""),
      driver_first_name:
        v.driver_first_name === null || v.driver_first_name === undefined
          ? null
          : String(v.driver_first_name),
      updated_at: Number(v.updated_at ?? 0) || 0,
    },
  };
}

/**
 * Authenticated rider or assigned driver obtains the public tracking token for a ride.
 * Writes `ride_track_public/{token}` via syncRideTrackPublic.
 *
 * @param {Record<string, unknown>} data
 * @param {{ auth?: { uid?: string } }|null|undefined} context
 * @param {import("firebase-admin").database.Database} db
 */
async function createTripShareToken(data, context, db) {
  const uid = normUid(context?.auth?.uid);
  if (!uid) {
    return { success: false, reason: "unauthorized" };
  }
  const rideId = normUid(data?.rideId ?? data?.ride_id ?? "");
  if (!rideId) {
    return { success: false, reason: "invalid_ride_id" };
  }
  const rideSnap = await db.ref(`ride_requests/${rideId}`).get();
  const ride = rideSnap.val();
  if (!ride || typeof ride !== "object") {
    return { success: false, reason: "ride_missing" };
  }
  const rider = normUid(ride.rider_id ?? ride.riderId);
  const driver = normUid(ride.driver_id ?? ride.driverId ?? ride.matched_driver_id);
  if (uid !== rider && uid !== driver) {
    return { success: false, reason: "forbidden" };
  }
  let token = String(ride.track_token ?? "").trim();
  if (!token) {
    token = normUid(db.ref().push().key);
    if (!token) {
      return { success: false, reason: "token_alloc_failed" };
    }
    await db.ref(`ride_requests/${rideId}`).update({
      track_token: token,
      updated_at: nowMs(),
    });
  }
  await syncRideTrackPublic(db, rideId);
  return {
    success: true,
    ride_id: rideId,
    track_token: token,
    track_path: `/track/${token}`,
  };
}

module.exports = {
  syncRideTrackPublic,
  getRideTrackSummary,
  createTripShareToken,
};
