import assert from "node:assert/strict";

export async function assertActiveTripPointers(db, { rideId, riderId, driverId }) {
  const activeTripSnap = await db.ref(`active_trips/${rideId}`).get();
  assert.equal(activeTripSnap.exists(), true, "active_trips should exist during trip");
  assert.equal(activeTripSnap.val()?.ride_id, rideId);
  assert.equal(activeTripSnap.val()?.driver_id, driverId);

  const driverActiveSnap = await db.ref(`driver_active_ride/${driverId}`).get();
  assert.equal(driverActiveSnap.exists(), true, "driver_active_ride should exist during trip");
  assert.equal(driverActiveSnap.val()?.ride_id, rideId);

  const riderActiveSnap = await db.ref(`rider_active_trip/${riderId}`).get();
  assert.equal(riderActiveSnap.exists(), true, "rider_active_trip should exist during trip");
  const riderRideId =
    riderActiveSnap.val() && typeof riderActiveSnap.val() === "object"
      ? riderActiveSnap.val()?.ride_id
      : riderActiveSnap.val();
  assert.equal(riderRideId, rideId);
}

export async function assertActiveTripPointersCleared(db, { rideId, riderId, driverId }) {
  const activeTripSnap = await db.ref(`active_trips/${rideId}`).get();
  assert.equal(activeTripSnap.exists(), false, "active_trips should be cleared");

  const driverActiveSnap = await db.ref(`driver_active_ride/${driverId}`).get();
  assert.equal(driverActiveSnap.exists(), false, "driver_active_ride should be cleared");

  const riderActiveSnap = await db.ref(`rider_active_trip/${riderId}`).get();
  assert.equal(riderActiveSnap.exists(), false, "rider_active_trip should be cleared");
}
