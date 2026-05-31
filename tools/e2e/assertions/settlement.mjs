import assert from "node:assert/strict";

export async function assertRideSettlement(db, { rideId, driverId }) {
  const rideSnap = await db.ref(`ride_requests/${rideId}`).get();
  assert.equal(rideSnap.exists(), true);
  const ride = rideSnap.val();

  assert.equal(ride.trip_state, "completed");
  assert.ok(ride.finance_settled_at, "finance_settled_at required");
  assert.ok(ride.finance_settlement, "finance_settlement required");

  const hookSnap = await db.ref(`trip_settlement_hooks/${rideId}`).get();
  assert.equal(hookSnap.exists(), true, "trip_settlement_hooks record required");
  assert.equal(hookSnap.val()?.settlementStatus, "trip_completed");

  const driverNetSnap = await db.ref(`driver_wallet_ledger/${driverId}/${rideId}_driver_net`).get();
  const legacySnap = await db.ref(`driver_wallet_ledger/${driverId}/${rideId}_fare_credit`).get();
  const hasWalletEntry =
    (driverNetSnap.exists() && driverNetSnap.val()?.completed === true) ||
    (legacySnap.exists() && legacySnap.val()?.completed === true);
  assert.equal(hasWalletEntry, true, "driver_wallet_ledger settlement entry required");

  const bookingFeeSnap = await db.ref(`platform_ledger/${rideId}_booking_fee`).get();
  const commissionSnap = await db.ref(`platform_ledger/${rideId}_commission`).get();
  assert.ok(
    bookingFeeSnap.exists() || commissionSnap.exists(),
    "platform_ledger booking_fee or commission entry required",
  );

  return { ride, hook: hookSnap.val() };
}
