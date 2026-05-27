const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  buildDriverAcceptAssignmentPatch,
  mapApiAcceptFailureReason,
  hasAssignedDriver,
  canonicalAssignedDriverId,
  ridePoolOpenForAccept,
  rideAssignedOrTerminal,
} = require("../ride_callables");
const { isOpenMatchingTripRow } = require("../matching_health");

const driverId = "drv_accept_1";
const now = 1_700_000_100_000;

test("buildDriverAcceptAssignmentPatch writes canonical assignment fields", () => {
  const patch = buildDriverAcceptAssignmentPatch(driverId, now, now + 60_000);
  assert.equal(patch.driver_id, driverId);
  assert.equal(patch.driverId, driverId);
  assert.equal(patch.matched_driver_id, driverId);
  assert.equal(patch.matchedDriverId, driverId);
  assert.equal(patch.accepted_driver_id, driverId);
  assert.equal(patch.acceptedDriverId, driverId);
  assert.equal(patch.assigned_driver_uid, driverId);
  assert.equal(patch.status, "assigned");
  assert.equal(patch.request_status, "accepted");
  assert.equal(patch.trip_state, "driver_assigned");
  assert.equal(patch.accepted_at_ms, now);
  assert.equal(patch.match_completed_at, now);
  assert.equal(patch.match_completed_at_ms, now);
  assert.equal(patch.expires_at, now + 60_000);
});

test("accept pool open when driver_id is waiting and trip searching", () => {
  assert.equal(
    ridePoolOpenForAccept({
      trip_state: "searching",
      status: "searching",
      driver_id: "waiting",
    }),
    true,
  );
});

test("rideAssignedOrTerminal false for open waiting pool", () => {
  assert.equal(
    rideAssignedOrTerminal({
      trip_state: "searching",
      status: "searching",
      driver_id: "waiting",
    }),
    false,
  );
});

test("rideAssignedOrTerminal true when matched_driver_id set", () => {
  assert.equal(
    rideAssignedOrTerminal({
      trip_state: "searching",
      status: "searching",
      driver_id: "waiting",
      matched_driver_id: driverId,
    }),
    true,
  );
});

test("ridePoolOpenForAccept false once assigned", () => {
  assert.equal(
    ridePoolOpenForAccept({
      trip_state: "searching",
      status: "accepted",
      matched_driver_id: driverId,
    }),
    false,
  );
});

test("canonicalAssignedDriverId resolves matched_driver_id when driver_id is waiting", () => {
  assert.equal(
    canonicalAssignedDriverId({
      driver_id: "waiting",
      matched_driver_id: driverId,
      status: "accepted",
      trip_state: "driver_assigned",
    }),
    driverId,
  );
});

test("mapApiAcceptFailureReason: tx_empty_current with preflight → transaction_conflict", () => {
  assert.equal(
    mapApiAcceptFailureReason("tx_empty_current", true),
    "transaction_conflict",
  );
});

test("mapApiAcceptFailureReason: ride_missing without preflight → ride_not_found", () => {
  assert.equal(mapApiAcceptFailureReason("ride_missing", false), "ride_not_found");
});

test("mapApiAcceptFailureReason: driver_already_set → already_taken", () => {
  assert.equal(mapApiAcceptFailureReason("driver_already_set", true), "already_taken");
});

test("mapApiAcceptFailureReason: payment_not_verified → payment_pending", () => {
  assert.equal(
    mapApiAcceptFailureReason("payment_not_verified", true),
    "payment_pending",
  );
});

test("mapApiAcceptFailureReason: no_offer → offer_not_found", () => {
  assert.equal(mapApiAcceptFailureReason("no_offer", true), "offer_not_found");
});

test("isOpenMatchingTripRow excludes accepted ride with matched driver", () => {
  assert.equal(
    isOpenMatchingTripRow({
      trip_state: "searching",
      status: "accepted",
      driver_id: "waiting",
      matched_driver_id: driverId,
      rider_id: "rider_1",
    }),
    false,
  );
});

test("isOpenMatchingTripRow includes open searching pool", () => {
  assert.equal(
    isOpenMatchingTripRow({
      trip_state: "searching",
      status: "searching",
      driver_id: "waiting",
    }),
    true,
  );
});

test("canonicalAssignedDriverId ignores waiting placeholders", () => {
  assert.equal(
    canonicalAssignedDriverId({
      driver_id: "waiting",
      matched_driver_id: "waiting",
    }),
    "",
  );
  assert.equal(hasAssignedDriver("waiting"), false);
});

console.log("ride_accept_lifecycle.unit.test.js OK");
