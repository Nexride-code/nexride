/**
 * Trip-scoped ratings — idempotent per ride + rater role.
 */

function normUid(v) {
  return String(v ?? "").trim();
}

function clampRating(v) {
  const n = Number(v);
  if (!Number.isFinite(n)) return 0;
  return Math.min(5, Math.max(1, Math.round(n)));
}

async function submitTripRating(data, context, db) {
  const uid = normUid(context?.auth?.uid);
  if (!uid) return { success: false, reason: "unauthorized" };

  const rideId = normUid(data?.rideId ?? data?.ride_id);
  const rating = clampRating(data?.rating ?? data?.stars);
  const role = String(data?.role ?? "").trim().toLowerCase();
  if (!rideId || rating < 1) {
    return { success: false, reason: "invalid_input" };
  }
  if (role !== "rider" && role !== "driver") {
    return { success: false, reason: "invalid_role" };
  }

  const rideSnap = await db.ref(`ride_requests/${rideId}`).get();
  const ride = rideSnap.val();
  if (!ride || typeof ride !== "object") {
    return { success: false, reason: "ride_not_found" };
  }

  const riderId = normUid(ride.rider_id);
  const driverId = normUid(ride.driver_id ?? ride.matched_driver_id);
  const tripState = String(ride.trip_state ?? "").trim().toLowerCase();
  if (tripState !== "completed" && tripState !== "complete") {
    return { success: false, reason: "trip_not_completed" };
  }

  if (role === "rider" && riderId !== uid) {
    return { success: false, reason: "not_rider" };
  }
  if (role === "driver" && driverId !== uid) {
    return { success: false, reason: "not_driver" };
  }

  const idemKey = `rating_${rideId}_${role}`;
  const idemRef = db.ref(`trip_rating_keys/${idemKey}`);
  if ((await idemRef.get()).exists()) {
    return { success: true, reason: "already_submitted", idempotent: true };
  }

  const targetId = role === "rider" ? driverId : riderId;
  const targetPath = role === "rider" ? `drivers/${targetId}` : `riders/${targetId}`;
  if (!targetId) {
    return { success: false, reason: "missing_target" };
  }

  const targetSnap = await db.ref(targetPath).get();
  const target = targetSnap.val() && typeof targetSnap.val() === "object" ? targetSnap.val() : {};
  const countKey = role === "rider" ? "rating_count" : "rider_rating_count";
  const ratingKey = "rating";
  const prevRating = Number(target[ratingKey] ?? 5);
  const prevCount = Math.max(0, Math.floor(Number(target[countKey] ?? target.total_trips ?? 0)));
  const newRating = ((prevRating * prevCount) + rating) / (prevCount + 1);

  const now = Date.now();
  await db.ref().update({
    [`ride_requests/${rideId}/${role === "rider" ? "rider_rating" : "driver_rating"}`]: rating,
    [`ride_requests/${rideId}/${role === "rider" ? "rider_rated_at" : "driver_rated_at"}`]: now,
    [`${targetPath}/${ratingKey}`]: Math.round(newRating * 100) / 100,
    [`${targetPath}/${countKey}`]: prevCount + 1,
  });

  await idemRef.set({
    ride_id: rideId,
    role,
    rating,
    target_id: targetId,
    submitted_by: uid,
    submitted_at: now,
  });

  return {
    success: true,
    reason: "rating_recorded",
    target_rating: newRating,
  };
}

module.exports = { submitTripRating };
