/**
 * Self-tests (run: node functions/test/driver_dispatch_gates.selftest.js)
 */
const assert = require("node:assert/strict");
const { evaluateDriverForOffer } = require("../driver_dispatch_gates");

const ride = { market_pool: "lagos", service_type: "ride" };

const suspended = {
  suspended: true,
  dispatch_market: "lagos",
  verification: {},
};
assert.equal(evaluateDriverForOffer(suspended, {}, ride).ok, false);

const unverifiedNoDocs = {
  dispatch_market: "lagos",
  nexride_verified: false,
  verification: {},
};
assert.equal(evaluateDriverForOffer(unverifiedNoDocs, {}, ride).ok, false);

const soft = evaluateDriverForOffer(unverifiedNoDocs, { soft_verification: true }, ride);
assert.equal(soft.ok, true);

const verifiedAdmin = {
  dispatch_market: "lagos",
  nexride_verified: true,
  verification: { restrictions: {} },
};
assert.equal(evaluateDriverForOffer(verifiedAdmin, {}, ride).ok, true);

const docOk = {
  dispatch_market: "lagos",
  nexride_verified: false,
  verification: {
    documents: {
      nin: { status: "approved" },
      drivers_license: { status: "verified" },
      vehicle_documents: { status: "approved" },
    },
  },
};
assert.equal(evaluateDriverForOffer(docOk, {}, ride).ok, true);

const bvnRequired = evaluateDriverForOffer(docOk, { require_bvn: true }, ride);
assert.equal(bvnRequired.ok, false);

console.log("driver_dispatch_gates.selftest: ok");
