const assert = require("node:assert/strict");
const { test } = require("node:test");
const { evaluateCarRideVehicleAndCapability } = require("../driver_dispatch_gates");

const rideCar = { market_pool: "lagos", service_type: "ride", vehicle_type: "car" };

test("car ride: bike / okada driver cannot be offered", () => {
  assert.equal(
    evaluateCarRideVehicleAndCapability(
      { dispatch_market: "lagos", vehicle_type: "bike" },
      rideCar,
    ).ok,
    false,
  );
  assert.equal(
    evaluateCarRideVehicleAndCapability(
      { dispatch_market: "lagos", vehicle_type: "okada" },
      rideCar,
    ).ok,
    false,
  );
});

test("car ride: explicit car driver passes", () => {
  assert.equal(
    evaluateCarRideVehicleAndCapability(
      { dispatch_market: "lagos", vehicle_type: "car", nexride_verified: true },
      rideCar,
    ).ok,
    true,
  );
});

test("car ride: legacy driver with no vehicle_type passes (car fleet default)", () => {
  assert.equal(
    evaluateCarRideVehicleAndCapability(
      { dispatch_market: "lagos", nexride_verified: true },
      rideCar,
    ).ok,
    true,
  );
});

test("car ride: service_capabilities.ride false rejects", () => {
  const r = evaluateCarRideVehicleAndCapability(
    {
      dispatch_market: "lagos",
      vehicle_type: "car",
      service_capabilities: { ride: false },
    },
    rideCar,
  );
  assert.equal(r.ok, false);
  assert.equal(r.detail, "ride_capability_false");
});

test("car ride gate skipped for dispatch_delivery payload", () => {
  assert.equal(
    evaluateCarRideVehicleAndCapability({ vehicle_type: "bike" }, {
      ...rideCar,
      service_type: "dispatch_delivery",
    }).ok,
    true,
  );
});
