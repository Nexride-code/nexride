const assert = require("node:assert/strict");
const { test } = require("node:test");
const { parseConfig, DEFAULTS } = require("../dispatch_engine/dispatch_config_engine");

test("parseConfig defaults to 30s lease and 8s retry", () => {
  const cfg = parseConfig({});
  assert.equal(cfg.driver_offer_lease_ms, 30_000);
  assert.equal(cfg.driver_offer_retry_ms, DEFAULTS.driver_offer_retry_ms);
  assert.equal(cfg.driver_offer_batch_size, DEFAULTS.driver_offer_batch_size);
});

test("parseConfig respects configured lease ms", () => {
  const cfg = parseConfig({ driver_offer_lease_ms: 12000, driver_offer_batch_size: 3 });
  assert.equal(cfg.driver_offer_lease_ms, 12000);
  assert.equal(cfg.driver_offer_batch_size, 3);
});
