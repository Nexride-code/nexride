"use strict";

const { describe, it } = require("node:test");
const assert = require("node:assert/strict");

const waitFee = require("../wait_fee_callables");

describe("wait_fee_callables constants", () => {
  it("uses ₦200 driver fee per 5 minute interval", () => {
    assert.equal(waitFee.WAIT_FEE_DRIVER_NGN, 200);
    assert.equal(waitFee.WAIT_INTERVAL_MS, 5 * 60 * 1000);
  });
});
