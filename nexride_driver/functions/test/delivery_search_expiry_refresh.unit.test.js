const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  DELIVERY_SEARCH_TTL_MS,
  deliverySearchExpiryFields,
  refreshDeliverySearchExpiryForVerifiedFanout,
  evaluateDeliveryAcceptTransactionDecision,
} = require("../delivery_callables");

const deliveryId = "del_exp_1";
const driverId = "drv_exp_1";
const customerId = "cust_exp_1";
const now = 1_700_400_000_000;

function makeExpiryDb(initialRow) {
  const path = `delivery_requests/${deliveryId}`;
  const store = { [path]: { ...initialRow } };
  const updates = [];
  return {
    updates,
    row: () => ({ ...store[path] }),
    db: {
      ref(refPath) {
        const p = String(refPath);
        return {
          update: async (patch) => {
            updates.push({ path: p, patch: { ...patch } });
            if (store[p]) {
              Object.assign(store[p], patch);
            }
          },
          get: async () => ({ val: () => (store[p] ? { ...store[p] } : null) }),
        };
      },
    },
  };
}

const verifiedRow = {
  delivery_id: deliveryId,
  customer_id: customerId,
  delivery_state: "searching",
  payment_method: "flutterwave",
  payment_status: "verified",
  payment_transaction_id: "flw_999",
  expires_at: now - 60_000,
  search_timeout_at: now - 60_000,
  request_expires_at: now - 60_000,
};

test("deliverySearchExpiryFields uses centralized TTL", () => {
  const patch = deliverySearchExpiryFields(now);
  assert.equal(patch.expires_at, now + DELIVERY_SEARCH_TTL_MS);
  assert.equal(patch.search_timeout_at, patch.expires_at);
  assert.equal(patch.request_expires_at, patch.expires_at);
  assert.equal(patch.updated_at, now);
  assert.equal(DELIVERY_SEARCH_TTL_MS, 180_000);
});

test("verified payment refreshes expires_at before fanout merge row", async () => {
  const mock = makeExpiryDb(verifiedRow);
  const merged = await refreshDeliverySearchExpiryForVerifiedFanout(
    mock.db,
    deliveryId,
    verifiedRow,
    { now },
  );
  assert.equal(mock.updates.length, 1);
  assert.equal(mock.updates[0].path, `delivery_requests/${deliveryId}`);
  assert.ok(merged.expires_at > now);
  assert.equal(merged.expires_at, now + DELIVERY_SEARCH_TTL_MS);
  assert.equal(mock.row().expires_at, merged.expires_at);
});

test("slow card verify after original expiry gets fresh expires_at", async () => {
  const stale = {
    ...verifiedRow,
    expires_at: now - 300_000,
    search_timeout_at: now - 300_000,
    request_expires_at: now - 300_000,
  };
  const mock = makeExpiryDb(stale);
  const merged = await refreshDeliverySearchExpiryForVerifiedFanout(
    mock.db,
    deliveryId,
    stale,
    { now },
  );
  assert.ok(merged.expires_at > now);
  assert.ok(merged.expires_at >= now + DELIVERY_SEARCH_TTL_MS - 1);
});

test("acceptDeliveryRequest allows verified row with refreshed expiry", () => {
  const refreshedExpiry = now + DELIVERY_SEARCH_TTL_MS;
  const decision = evaluateDeliveryAcceptTransactionDecision(
    {
      delivery_state: "searching",
      driver_id: "waiting",
      customer_id: customerId,
      payment_method: "flutterwave",
      payment_status: "verified",
      payment_transaction_id: "flw_999",
      expires_at: refreshedExpiry,
      request_expires_at: refreshedExpiry,
    },
    driverId,
    { now },
  );
  assert.equal(decision.action, "commit");
});

test("accept rejects stale expiry without refresh", () => {
  const decision = evaluateDeliveryAcceptTransactionDecision(
    {
      delivery_state: "searching",
      driver_id: "waiting",
      customer_id: customerId,
      payment_method: "flutterwave",
      payment_status: "verified",
      payment_transaction_id: "flw_999",
      expires_at: now - 60_000,
    },
    driverId,
    { now },
  );
  assert.equal(decision.action, "abort");
  assert.equal(decision.reason, "offer_expired");
});

test("pending_transfer does not refresh expiry", async () => {
  const mock = makeExpiryDb({
    ...verifiedRow,
    payment_status: "pending_transfer",
    payment_transaction_id: "",
  });
  const merged = await refreshDeliverySearchExpiryForVerifiedFanout(
    mock.db,
    deliveryId,
    mock.row(),
  );
  assert.equal(mock.updates.length, 0);
  assert.equal(merged.expires_at, now - 60_000);
});

test("pending_review does not refresh expiry", async () => {
  const mock = makeExpiryDb({
    ...verifiedRow,
    payment_status: "pending_review",
    payment_transaction_id: "flw_late",
  });
  const merged = await refreshDeliverySearchExpiryForVerifiedFanout(
    mock.db,
    deliveryId,
    mock.row(),
  );
  assert.equal(mock.updates.length, 0);
  assert.equal(merged.expires_at, now - 60_000);
});
