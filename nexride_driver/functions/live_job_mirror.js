/**
 * Lightweight RTDB mirrors for realtime UI sync only.
 * Primary authority remains ride_requests (Firestore/CF transactions).
 */

const CANONICAL = {
  REQUEST_PENDING: "REQUEST_PENDING",
  SEARCHING_DRIVER: "SEARCHING_DRIVER",
  DRIVER_OFFERED: "DRIVER_OFFERED",
  DRIVER_ASSIGNED: "DRIVER_ASSIGNED",
  DRIVER_ARRIVING: "DRIVER_ARRIVING",
  DRIVER_ARRIVED: "DRIVER_ARRIVED",
  IN_PROGRESS: "IN_PROGRESS",
  COMPLETED: "COMPLETED",
  PAYMENT_PENDING: "PAYMENT_PENDING",
  PAID: "PAID",
  CLOSED: "CLOSED",
  CANCELLED: "CANCELLED",
};

function normUid(v) {
  return String(v ?? "").trim();
}

function mapRideToCanonicalStatus(ride) {
  if (!ride || typeof ride !== "object") {
    return CANONICAL.REQUEST_PENDING;
  }
  const trip = String(ride.trip_state ?? "").trim().toLowerCase();
  const legacy = String(ride.status ?? "").trim().toLowerCase();
  const payment = String(ride.payment_status ?? "").trim().toLowerCase();

  if (
    trip === "cancelled" ||
    legacy === "cancelled" ||
    trip === "expired" ||
    legacy === "expired"
  ) {
    return CANONICAL.CANCELLED;
  }
  if (trip === "completed" || legacy === "completed") {
    if (payment === "paid" || payment === "verified" || ride.payment_confirmed === true) {
      return CANONICAL.PAID;
    }
    if (legacy === "closed" || trip === "closed") {
      return CANONICAL.CLOSED;
    }
    return CANONICAL.COMPLETED;
  }
  if (trip === "in_progress" || legacy === "on_trip" || legacy === "in_progress") {
    return CANONICAL.IN_PROGRESS;
  }
  if (
    trip === "arrived" ||
    trip === "driver_arrived" ||
    legacy === "arrived"
  ) {
    return CANONICAL.DRIVER_ARRIVED;
  }
  if (trip === "driver_arriving" || legacy === "driver_enroute" || legacy === "enroute") {
    return CANONICAL.DRIVER_ARRIVING;
  }
  if (
    trip === "driver_assigned" ||
    trip === "accepted" ||
    trip === "driver_accepted" ||
    legacy === "accepted" ||
    legacy === "driver_assigned"
  ) {
    return CANONICAL.DRIVER_ASSIGNED;
  }
  if (trip === "searching" || legacy === "searching" || legacy === "pending") {
    return CANONICAL.SEARCHING_DRIVER;
  }
  if (payment === "pending" || payment === "pending_transfer") {
    return CANONICAL.PAYMENT_PENDING;
  }
  return CANONICAL.REQUEST_PENDING;
}

function mapPaymentCanonical(ride) {
  const payment = String(ride?.payment_status ?? "").trim().toLowerCase();
  if (payment === "paid" || payment === "verified" || ride?.payment_confirmed === true) {
    return "PAID";
  }
  if (
    payment === "pending" ||
    payment === "pending_transfer" ||
    payment === "pending_manual_confirmation" ||
    payment === "pending_review"
  ) {
    return "PAYMENT_PENDING";
  }
  return payment || "UNKNOWN";
}

/**
 * Mirror ride_requests → liveJobs/{jobId} (lightweight fields only).
 */
async function syncLiveJobMirror(db, rideId) {
  const rid = String(rideId ?? "").trim();
  if (!rid) {
    return;
  }
  const snap = await db.ref(`ride_requests/${rid}`).get();
  if (!snap.exists() || typeof snap.val() !== "object") {
    await db.ref(`liveJobs/${rid}`).remove();
    return;
  }
  const ride = snap.val();
  const canonical = mapRideToCanonicalStatus(ride);
  await db.ref(`liveJobs/${rid}`).set({
    status: canonical,
    customerId: normUid(ride.rider_id ?? ride.riderId),
    driverId: normUid(ride.driver_id ?? ride.driverId ?? ride.matched_driver_id),
    serviceType: String(ride.service_type ?? "ride").trim() || "ride",
    paymentStatus: mapPaymentCanonical(ride),
    updatedAt: Number(ride.updated_at ?? Date.now()) || Date.now(),
  });
}

/**
 * Mirror drivers/{driverId} → liveDrivers/{driverId} (location + availability only).
 */
async function syncLiveDriverMirror(db, driverId, rideIdOptional) {
  const did = normUid(driverId);
  if (!did) {
    return;
  }
  const snap = await db.ref(`drivers/${did}`).get();
  if (!snap.exists() || typeof snap.val() !== "object") {
    await db.ref(`liveDrivers/${did}`).remove();
    return;
  }
  const d = snap.val();
  const loc = d.location && typeof d.location === "object" ? d.location : {};
  const activeRide =
    normUid(rideIdOptional) ||
    normUid(d.activeRideId ?? d.active_ride_id ?? d.currentRideId);
  await db.ref(`liveDrivers/${did}`).set({
    isOnline: d.isOnline === true || d.is_online === true || d.online === true,
    availabilityMode: String(
      d.driver_availability_mode ?? d.status ?? "offline",
    ).trim(),
    lat: Number(loc.lat ?? loc.latitude ?? 0) || 0,
    lng: Number(loc.lng ?? loc.longitude ?? 0) || 0,
    updatedAt: Number(d.updated_at ?? Date.now()) || Date.now(),
    currentJobId: activeRide || null,
  });
}

module.exports = {
  CANONICAL,
  mapRideToCanonicalStatus,
  syncLiveJobMirror,
  syncLiveDriverMirror,
};
