const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  DELIVERY_STATE,
  normalizeDeliveryState,
  canonicalAssignedDeliveryDriverId,
  buildDeliveryAcceptAssignmentPatch,
  deliveryPoolOpenForAccept,
  deliveryUiMirrorFields,
  driverNearPickup,
  DRIVER_DELIVERY_NEXT,
} = require("../delivery_callables");

const driverId = "drv_delivery_1";
const customerId = "cust_1";
const now = 1_700_100_000_000;

test("normalizeDeliveryState maps legacy accepted to driver_assigned", () => {
  assert.equal(normalizeDeliveryState("accepted"), DELIVERY_STATE.driver_assigned);
  assert.equal(normalizeDeliveryState("enroute_pickup"), DELIVERY_STATE.driver_arriving_pickup);
});

test("buildDeliveryAcceptAssignmentPatch writes canonical driver aliases", () => {
  const patch = buildDeliveryAcceptAssignmentPatch(driverId, now);
  assert.equal(patch.delivery_state, DELIVERY_STATE.driver_assigned);
  assert.equal(patch.matched_driver_id, driverId);
  assert.equal(patch.accepted_driver_id, driverId);
  assert.equal(patch.delivery_driver_id, driverId);
  assert.equal(patch.match_lock.accepted_by, driverId);
});

test("canonicalAssignedDeliveryDriverId ignores waiting driver_id", () => {
  assert.equal(
    canonicalAssignedDeliveryDriverId({
      driver_id: "waiting",
      matched_driver_id: driverId,
      customer_id: customerId,
    }),
    driverId,
  );
});

test("deliveryPoolOpenForAccept true for searching without assignee", () => {
  assert.equal(
    deliveryPoolOpenForAccept({
      delivery_state: "searching",
      driver_id: "waiting",
    }),
    true,
  );
});

test("deliveryPoolOpenForAccept false once matched", () => {
  assert.equal(
    deliveryPoolOpenForAccept({
      delivery_state: "searching",
      matched_driver_id: driverId,
    }),
    false,
  );
});

test("deliveryUiMirrorFields exposes matched_driver_id when assigned", () => {
  const mirror = deliveryUiMirrorFields(DELIVERY_STATE.driver_assigned, driverId);
  assert.equal(mirror.matched_driver_id, driverId);
  assert.equal(mirror.driver_id, driverId);
});

test("DRIVER_DELIVERY_NEXT canonical progression", () => {
  assert.equal(
    DRIVER_DELIVERY_NEXT[DELIVERY_STATE.driver_assigned],
    DELIVERY_STATE.driver_arriving_pickup,
  );
  assert.equal(
    DRIVER_DELIVERY_NEXT[DELIVERY_STATE.arrived_dropoff],
    DELIVERY_STATE.completed,
  );
});

test("driverNearPickup within radius", () => {
  const row = {
    pickup: { lat: 6.5244, lng: 3.3792 },
  };
  assert.equal(driverNearPickup(row, 6.5245, 3.3792, 200), true);
  assert.equal(driverNearPickup(row, 6.6, 3.5, 50), false);
});
