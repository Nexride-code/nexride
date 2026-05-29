const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const {
  paymentAllowsDispatchDelivery,
  deliveryHasVerifiedOnlinePayment,
  fanOutDeliveryOffersIfEligible,
  evaluateDeliveryAcceptTransactionDecision,
} = require("../delivery_callables");

const driverId = "drv_gate_1";
const customerId = "cust_gate_1";
const deliveryId = "del_gate_1";
const now = 1_700_300_000_000;

const baseRow = {
  customer_id: customerId,
  market: "lagos",
  market_pool: "lagos",
  pickup: { lat: 6.5244, lng: 3.3792, address: "Pickup" },
  dropoff: { lat: 6.53, lng: 3.38, address: "Dropoff" },
  delivery_state: "searching",
};

function makeFanoutTrackingDb() {
  const state = {
    driversScanned: false,
    offerWrites: [],
    batchUpdates: [],
  };

  const db = {
    ref(refPath) {
      const p = String(refPath);
      if (p === "drivers") {
        return {
          orderByChild() {
            return {
              equalTo() {
                return {
                  get: async () => {
                    state.driversScanned = true;
                    return { val: () => null };
                  },
                };
              },
            };
          },
        };
      }
      if (p === "") {
        return {
          update: async (payload) => {
            state.batchUpdates.push(payload);
            for (const key of Object.keys(payload || {})) {
              if (key.startsWith("delivery_offer_queue/")) {
                state.offerWrites.push(key);
              }
            }
          },
        };
      }
      if (p.startsWith("delivery_requests/") && p.endsWith("/match_debug")) {
        return {
          set: async () => {},
        };
      }
      return {
        get: async () => ({ val: () => null, exists: () => false }),
        set: async () => {},
        update: async () => {},
      };
    },
    state,
  };
  return db;
}

test("paymentAllowsDispatchDelivery requires verified status and payment_transaction_id", () => {
  assert.equal(
    paymentAllowsDispatchDelivery({
      payment_method: "flutterwave",
      payment_status: "verified",
      payment_transaction_id: "flw_123",
    }),
    true,
  );
  assert.equal(
    paymentAllowsDispatchDelivery({
      payment_method: "bank_transfer",
      payment_status: "verified",
      payment_transaction_id: "flw_456",
    }),
    true,
  );
  assert.equal(
    deliveryHasVerifiedOnlinePayment({
      payment_method: "flutterwave",
      payment_status: "verified",
      payment_transaction_id: "flw_123",
    }),
    true,
  );
});

test("pending card/flutterwave does not allow fanout", () => {
  assert.equal(
    paymentAllowsDispatchDelivery({
      payment_method: "flutterwave",
      payment_status: "pending",
    }),
    false,
  );
  assert.equal(
    paymentAllowsDispatchDelivery({
      payment_method: "card",
      payment_status: "pending",
      payment_reference: "tx_ref_1",
    }),
    false,
  );
});

test("pending_transfer bank transfer does not allow fanout", () => {
  assert.equal(
    paymentAllowsDispatchDelivery({
      payment_method: "bank_transfer",
      payment_status: "pending_transfer",
      payment_reference: "tx_ref_va",
    }),
    false,
  );
});

test("verified without payment_transaction_id does not allow fanout", () => {
  assert.equal(
    paymentAllowsDispatchDelivery({
      payment_method: "flutterwave",
      payment_status: "verified",
    }),
    false,
  );
});

test("paid status alone does not allow fanout without verified + tx id", () => {
  assert.equal(
    paymentAllowsDispatchDelivery({
      payment_method: "flutterwave",
      payment_status: "paid",
      payment_transaction_id: "flw_paid",
    }),
    false,
  );
});

test("fanOutDeliveryOffersIfEligible does not scan drivers or write offers for pending payment", async () => {
  const db = makeFanoutTrackingDb();
  await fanOutDeliveryOffersIfEligible(db, deliveryId, {
    ...baseRow,
    payment_method: "flutterwave",
    payment_status: "pending",
  });
  assert.equal(db.state.driversScanned, false);
  assert.equal(db.state.offerWrites.length, 0);
});

test("fanOutDeliveryOffersIfEligible scans drivers for verified payment", async () => {
  const db = makeFanoutTrackingDb();
  await fanOutDeliveryOffersIfEligible(db, deliveryId, {
    ...baseRow,
    payment_method: "flutterwave",
    payment_status: "verified",
    payment_transaction_id: "flw_verified",
  });
  assert.equal(db.state.driversScanned, true);
});

test("evaluateDeliveryAcceptTransactionDecision rejects pending payment", () => {
  const decision = evaluateDeliveryAcceptTransactionDecision(
    {
      ...baseRow,
      payment_method: "flutterwave",
      payment_status: "pending",
      expires_at: now + 60_000,
    },
    driverId,
    { now },
  );
  assert.equal(decision.action, "abort");
  assert.equal(decision.reason, "payment_not_verified");
});

test("evaluateDeliveryAcceptTransactionDecision allows verified payment", () => {
  const decision = evaluateDeliveryAcceptTransactionDecision(
    {
      ...baseRow,
      payment_method: "bank_transfer",
      payment_status: "verified",
      payment_transaction_id: "flw_bank_ok",
      expires_at: now + 60_000,
    },
    driverId,
    { now },
  );
  assert.equal(decision.action, "commit");
});

test("createDeliveryRequest does not fan out at create time", () => {
  const src = fs.readFileSync(
    path.join(__dirname, "../delivery_callables.js"),
    "utf8",
  );
  const start = src.indexOf("async function createDeliveryRequest");
  const end = src.indexOf("async function acceptDeliveryRequest");
  assert.ok(start >= 0 && end > start);
  const createBlock = src.slice(start, end);
  assert.equal(
    createBlock.includes("fanOutDeliveryOffersIfEligible"),
    false,
    "createDeliveryRequest must not fan out before payment verification",
  );
});
