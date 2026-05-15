const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  effectiveCommissionFromMerchantDoc,
} = require("../merchant/merchant_commerce");
const {
  adminSetMerchantCommissionWithdrawal,
  normalizePaymentModel,
} = require("../merchant/merchant_callables");

test("effectiveCommissionFromMerchantDoc — subscription is 0% / 100% withdrawal", () => {
  const r = effectiveCommissionFromMerchantDoc({
    payment_model: "subscription",
    commission_exempt: true,
  });
  assert.equal(r.commission_exempt, true);
  assert.equal(r.commission_rate, 0);
  assert.equal(r.withdrawal_percent, 1);
});

test("effectiveCommissionFromMerchantDoc — commission defaults 10/90", () => {
  const r = effectiveCommissionFromMerchantDoc({
    payment_model: "commission",
    commission_exempt: false,
  });
  assert.equal(r.commission_rate, 0.1);
  assert.equal(r.withdrawal_percent, 0.9);
});

test("effectiveCommissionFromMerchantDoc — respects stored override", () => {
  const r = effectiveCommissionFromMerchantDoc({
    payment_model: "commission",
    commission_rate: 0.12,
    withdrawal_percent: 0.88,
  });
  assert.equal(r.commission_rate, 0.12);
  assert.equal(r.withdrawal_percent, 0.88);
});

test("non-admin cannot set merchant commission", async () => {
  const ctx = { auth: { uid: "u1", token: {} } };
  const db = { ref: () => ({ get: async () => ({ val: () => null }) }) };
  const res = await adminSetMerchantCommissionWithdrawal(
    { merchant_id: "m1", commission_rate: 0.15, withdrawal_percent: 0.85 },
    ctx,
    db,
  );
  assert.equal(res.success, false);
  assert.equal(res.reason, "unauthorized");
});

test("normalizePaymentModel accepts commission and subscription", () => {
  assert.equal(normalizePaymentModel("COMMISSION"), "commission");
  assert.equal(normalizePaymentModel("subscription"), "subscription");
});
