const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  evaluateDeliveryAcceptTransactionDecision,
  canonicalAssignedDeliveryDriverId,
  DELIVERY_STATE,
} = require("../delivery_callables");

const driverA = "drv_a";
const driverB = "drv_b";
const now = 1_700_200_000_000;

test("evaluateDeliveryAcceptTransactionDecision commits open searching row when payment verified", () => {
  const decision = evaluateDeliveryAcceptTransactionDecision(
    {
      delivery_state: "searching",
      driver_id: "waiting",
      customer_id: "cust_1",
      payment_method: "flutterwave",
      payment_status: "verified",
      payment_transaction_id: "flw_123",
      expires_at: now + 60_000,
    },
    driverA,
    { now },
  );
  assert.equal(decision.action, "commit");
  assert.equal(decision.patch.matched_driver_id, driverA);
});

test("evaluateDeliveryAcceptTransactionDecision aborts when payment pending", () => {
  const decision = evaluateDeliveryAcceptTransactionDecision(
    {
      delivery_state: "searching",
      driver_id: "waiting",
      customer_id: "cust_1",
      payment_method: "flutterwave",
      payment_status: "pending",
      expires_at: now + 60_000,
    },
    driverA,
    { now },
  );
  assert.equal(decision.action, "abort");
  assert.equal(decision.reason, "payment_not_verified");
});

test("evaluateDeliveryAcceptTransactionDecision aborts when already taken", () => {
  const decision = evaluateDeliveryAcceptTransactionDecision(
    {
      delivery_state: "driver_assigned",
      matched_driver_id: driverB,
      customer_id: "cust_1",
    },
    driverA,
    { now },
  );
  assert.equal(decision.action, "abort");
  assert.equal(decision.reason, "already_taken");
});

test("evaluateDeliveryAcceptTransactionDecision noop for same driver", () => {
  const decision = evaluateDeliveryAcceptTransactionDecision(
    {
      delivery_state: DELIVERY_STATE.driver_assigned,
      matched_driver_id: driverA,
      customer_id: "cust_1",
    },
    driverA,
    { now },
  );
  assert.equal(decision.action, "noop");
});

test("canonicalAssignedDeliveryDriverId is single winner field", () => {
  const row = {
    delivery_state: DELIVERY_STATE.driver_assigned,
    driver_id: "waiting",
    matched_driver_id: driverA,
    accepted_driver_id: driverA,
    customer_id: "cust_1",
  };
  assert.equal(canonicalAssignedDeliveryDriverId(row), driverA);
});
