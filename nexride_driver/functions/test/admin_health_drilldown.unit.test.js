"use strict";

const assert = require("node:assert/strict");
const { DRILLDOWN_CARDS } = require("../admin_health_drilldown");

assert.ok(DRILLDOWN_CARDS.has("rider_payments"));
assert.ok(DRILLDOWN_CARDS.has("matching"));
assert.ok(DRILLDOWN_CARDS.has("drivers"));
assert.ok(DRILLDOWN_CARDS.has("payout_destinations"));
assert.equal(DRILLDOWN_CARDS.has("unknown"), false);

console.log("admin_health_drilldown.unit.test.js OK");
