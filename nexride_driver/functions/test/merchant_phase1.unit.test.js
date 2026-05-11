const assert = require("node:assert/strict");
const { test } = require("node:test");
const { reviewActionToStatus } = require("../merchant/merchant_callables");

test("reviewActionToStatus maps admin actions", () => {
  assert.equal(reviewActionToStatus("approve"), "approved");
  assert.equal(reviewActionToStatus("Reject"), "rejected");
  assert.equal(reviewActionToStatus("SUSPEND"), "suspended");
  assert.equal(reviewActionToStatus("noop"), "");
});
