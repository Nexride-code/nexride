/**
 * Trip-scoped ratings — idempotent per ride + direction; survives archived rides.
 */

function normUid(v) {
  return String(v ?? "").trim();
}

function clampRating(v) {
  const n = Number(v);
  if (!Number.isFinite(n)) return 0;
  return Math.min(5, Math.max(1, Math.round(n)));
}

function ratingDirectionForRole(role) {
  return role === "rider" ? "rider_to_driver" : "driver_to_rider";
}

function isCompletedTripState(tripState, status, ride) {
  const ts = String(tripState ?? "").trim().toLowerCase();
  const st = String(status ?? "").trim().toLowerCase();
  return (
    ts === "completed" ||
    ts === "complete" ||
    ts === "trip_completed" ||
    st === "completed" ||
    st === "trip_completed" ||
    ride?.trip_completed === true
  );
}

/**
 * Resolve ride participants from RTDB mirrors when ride_requests is gone.
 */
async function resolveRideForRating(db, rideId, data) {
  const rideRefSnap = await db.ref(`ride_requests/${rideId}`).get();
  if (rideRefSnap.exists() && typeof rideRefSnap.val() === "object") {
    return { ride: rideRefSnap.val(), source: "ride_requests", rideRequestExists: true };
  }

  const activeSnap = await db.ref(`active_trips/${rideId}`).get();
  if (activeSnap.exists() && typeof activeSnap.val() === "object") {
    return { ride: activeSnap.val(), source: "active_trips", rideRequestExists: false };
  }

  const legacySnap = await db.ref(`rides/${rideId}`).get();
  if (legacySnap.exists() && typeof legacySnap.val() === "object") {
    return { ride: legacySnap.val(), source: "rides", rideRequestExists: false };
  }

  return { ride: null, source: "none", rideRequestExists: false };
}

function resolveParticipantIds(ride, role, uid, data) {
  const clientRiderId = normUid(data?.riderId ?? data?.rider_id);
  const clientDriverId = normUid(data?.driverId ?? data?.driver_id);
  const clientTargetId = normUid(
    data?.targetId ?? data?.target_user_id ?? data?.targetUid ?? data?.target_uid,
  );

  let riderId = normUid(ride?.rider_id ?? ride?.riderId) || clientRiderId;
  let driverId =
    normUid(ride?.driver_id ?? ride?.matched_driver_id ?? ride?.driverId) ||
    clientDriverId;

  if (role === "rider") {
    riderId = riderId || uid;
    driverId = driverId || clientTargetId || clientDriverId;
  } else {
    driverId = driverId || uid;
    riderId = riderId || clientTargetId || clientRiderId;
  }

  return { riderId, driverId };
}

async function submitTripRating(data, context, db) {
  const uid = normUid(context?.auth?.uid);
  if (!uid) return { success: false, reason: "unauthorized" };

  const rideId = normUid(data?.rideId ?? data?.ride_id);
  const rating = clampRating(data?.rating ?? data?.stars);
  const role = String(data?.role ?? "").trim().toLowerCase();
  const note = String(data?.note ?? data?.message ?? "").trim();
  if (!rideId || rating < 1) {
    return { success: false, reason: "invalid_input" };
  }
  if (role !== "rider" && role !== "driver") {
    return { success: false, reason: "invalid_role" };
  }

  const direction = ratingDirectionForRole(role);
  const legacyIdemKey = `rating_${rideId}_${role}`;
  const directionIdemKey = `${rideId}/${direction}`;
  const legacyIdemRef = db.ref(`trip_rating_keys/${legacyIdemKey}`);
  const directionIdemRef = db.ref(`trip_rating_keys/${directionIdemKey}`);

  const [legacyIdemSnap, directionIdemSnap] = await Promise.all([
    legacyIdemRef.get(),
    directionIdemRef.get(),
  ]);
  if (legacyIdemSnap.exists() || directionIdemSnap.exists()) {
    return { success: true, reason: "already_submitted", idempotent: true };
  }

  const resolved = await resolveRideForRating(db, rideId, data);
  const ride = resolved.ride;
  const { riderId, driverId } = resolveParticipantIds(ride, role, uid, data);

  if (role === "rider" && riderId !== uid) {
    return { success: false, reason: "not_rider" };
  }
  if (role === "driver" && driverId !== uid) {
    return { success: false, reason: "not_driver" };
  }

  const targetId = role === "rider" ? driverId : riderId;
  if (!targetId) {
    return { success: false, reason: "missing_target" };
  }

  const tripState = String(ride?.trip_state ?? "").trim().toLowerCase();
  const status = String(ride?.status ?? "").trim().toLowerCase();
  const completedLike = isCompletedTripState(tripState, status, ride);

  if (resolved.rideRequestExists && ride && !completedLike) {
    return { success: false, reason: "trip_not_completed" };
  }

  const targetPath = role === "rider" ? `drivers/${targetId}` : `riders/${targetId}`;
  const targetSnap = await db.ref(targetPath).get();
  const target =
    targetSnap.val() && typeof targetSnap.val() === "object" ? targetSnap.val() : {};
  const countKey = role === "rider" ? "rating_count" : "rider_rating_count";
  const ratingKey = "rating";
  const prevRating = Number(target[ratingKey] ?? 5);
  const prevCount = Math.max(
    0,
    Math.floor(Number(target[countKey] ?? target.total_trips ?? 0)),
  );
  const newRating = ((prevRating * prevCount) + rating) / (prevCount + 1);

  const now = Date.now();
  const ratingRecord = {
    rideId,
    ride_id: rideId,
    riderId,
    rider_id: riderId,
    driverId,
    driver_id: driverId,
    role,
    direction,
    rating,
    message: note,
    note,
    submitted_by: uid,
    target_id: targetId,
    source: resolved.source,
    createdAt: now,
    updatedAt: now,
  };

  const updates = {
    [`ride_ratings/${rideId}/${direction}`]: ratingRecord,
    [`${targetPath}/${ratingKey}`]: Math.round(newRating * 100) / 100,
    [`${targetPath}/${countKey}`]: prevCount + 1,
  };

  if (resolved.rideRequestExists) {
    updates[`ride_requests/${rideId}/${role === "rider" ? "rider_rating" : "driver_rating"}`] =
      rating;
    updates[`ride_requests/${rideId}/${role === "rider" ? "rider_rated_at" : "driver_rated_at"}`] =
      now;
  }

  await db.ref().update(updates);

  const idemPayload = {
    ride_id: rideId,
    role,
    direction,
    rating,
    target_id: targetId,
    submitted_by: uid,
    submitted_at: now,
    source: resolved.source,
  };
  await directionIdemRef.set(idemPayload);
  await legacyIdemRef.set(idemPayload);

  return {
    success: true,
    reason: "rating_recorded",
    target_rating: newRating,
    archived_ride: !resolved.rideRequestExists,
  };
}

module.exports = { submitTripRating };
