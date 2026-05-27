const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  rideAssignedDriverUid,
  evaluateDriverArrivedTransition,
  TRIP_STATE,
} = require("../ride_callables");

const driverId = "drv_arrived_1";
const rideId = "-OtZSt97zv57tCJdN331";

test("rideAssignedDriverUid resolves assigned_driver_uid", () => {
  assert.equal(
    rideAssignedDriverUid({
      driver_id: "waiting",
      assigned_driver_uid: driverId,
    }),
    driverId,
  );
});

test("evaluateDriverArrivedTransition succeeds for assigned + driver_assigned", () => {
  const cur = {
    status: "assigned",
    trip_state: "driver_assigned",
    driver_id: driverId,
    assigned_driver_uid: driverId,
    rider_id: "rider_1",
  };
  const ev = evaluateDriverArrivedTransition(cur, driverId);
  assert.equal(ev.ok, true);
  assert.equal(ev.reason, "arrived");
  assert.equal(ev.patch.trip_state, TRIP_STATE.arrived);
  assert.equal(ev.patch.status, "arrived");
  assert.equal(ev.patch.last_event, "driver_arrived");
});

test("evaluateDriverArrivedTransition fails when driver is not assigned", () => {
  const ev = evaluateDriverArrivedTransition(
    {
      status: "assigned",
      trip_state: "driver_assigned",
      driver_id: "other_driver",
    },
    driverId,
  );
  assert.equal(ev.ok, false);
  assert.equal(ev.reason, "not_assigned_driver");
});

test("evaluateDriverArrivedTransition idempotent when already arrived", () => {
  const cur = {
    status: "arrived",
    trip_state: "arrived",
    driver_id: driverId,
  };
  const ev = evaluateDriverArrivedTransition(cur, driverId);
  assert.equal(ev.ok, true);
  assert.equal(ev.reason, "already_arrived");
  assert.equal(ev.idempotent, true);
});
