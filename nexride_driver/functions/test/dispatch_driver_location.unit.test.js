"use strict";

const { describe, it } = require("node:test");
const assert = require("node:assert/strict");
const { resolveDriverCoordsForDispatch } = require("../dispatch_engine/dispatch_driver_location");

describe("dispatch_driver_location", () => {
  it("falls back to online_start_location when live GPS stream missing", () => {
    const now = Date.now();
    const coords = resolveDriverCoordsForDispatch(
      {
        driver_availability_mode: "current_location",
        online_start_location: { lat: 9.0765, lng: 7.3986 },
        online_start_location_at: now - 60_000,
        last_dispatch_heartbeat: now - 30_000,
        last_location_updated_at: now - 20 * 60_000,
      },
      now,
    );
    assert.equal(coords.source, "online_start_location");
    assert.ok(coords.inGrace);
    assert.ok(Math.abs(coords.lat - 9.0765) < 0.001);
  });
});
