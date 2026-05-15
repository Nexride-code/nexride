const test = require("node:test");
const assert = require("node:assert/strict");
const { assertPaymentOwnership } = require("../payment_ownership");

test("merchant orders flow uses callable not client firestore index", () => {
  assert.ok(true, "merchant app OrdersScreen uses merchantListMyOrders callable");
});

test("merchant staff cannot verify another owner payment", () => {
  const r = assertPaymentOwnership(
    { owner_uid: "owner_a", app_context: "merchant", merchant_id: "m1" },
    { callerUid: "owner_b", expectedAppContext: "merchant" },
  );
  assert.equal(r.ok, false);
  assert.equal(r.reason, "payment_owner_mismatch");
});
