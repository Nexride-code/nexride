const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  dispatchMarketToRegionId,
  isRolloutDispatchMarket,
  ROLLOUT_DISPATCH_MARKET_IDS,
} = require("../ecosystem/delivery_regions");

test("dispatch market maps to rollout region id", () => {
  assert.equal(dispatchMarketToRegionId("lagos"), "lagos");
  assert.equal(dispatchMarketToRegionId("abuja_fct"), "abuja");
  assert.equal(dispatchMarketToRegionId("imo"), "imo");
});

test("isRolloutDispatchMarket matches known rollout markets", () => {
  assert.equal(isRolloutDispatchMarket("lagos"), true);
  assert.equal(isRolloutDispatchMarket("abuja"), true);
  assert.equal(isRolloutDispatchMarket("port_harcourt"), false);
  assert.equal(ROLLOUT_DISPATCH_MARKET_IDS.includes("imo"), true);
});
