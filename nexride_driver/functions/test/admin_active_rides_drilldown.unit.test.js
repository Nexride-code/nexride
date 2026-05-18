const assert = require("node:assert/strict");
const { test } = require("node:test");

const DRILLDOWN_CARDS = require("../admin_health_drilldown").DRILLDOWN_CARDS;

test("health drilldown allows Active operations rides card", () => {
  assert.equal(DRILLDOWN_CARDS.has("rides"), true);
});

test("health drilldown allows deliveries card", () => {
  assert.equal(DRILLDOWN_CARDS.has("deliveries"), true);
});
