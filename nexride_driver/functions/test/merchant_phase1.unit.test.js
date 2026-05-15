const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  reviewActionToStatus,
  computeCanonicalPaymentModelFields,
  applyCanonicalPaymentFields,
  normalizeSubscriptionStatus,
  initialMerchantStatus,
  adminUpdateMerchantPaymentModel,
  adminUpdateMerchantSubscriptionStatus,
  buildMerchantOwnerProfileUpdate,
} = require("../merchant/merchant_callables");

test("reviewActionToStatus maps admin actions", () => {
  assert.equal(reviewActionToStatus("approve"), "approved");
  assert.equal(reviewActionToStatus("reactivate"), "approved");
  assert.equal(reviewActionToStatus("Reject"), "rejected");
  assert.equal(reviewActionToStatus("SUSPEND"), "suspended");
  assert.equal(reviewActionToStatus("noop"), "");
});

test("subscription payment model gets 0% commission and full withdrawal", () => {
  const f = computeCanonicalPaymentModelFields("subscription");
  assert.equal(f.commission_rate, 0);
  assert.equal(f.withdrawal_percent, 1.0);
  assert.equal(f.commission_exempt, true);
  assert.equal(f.subscription_amount, 25000);
});

test("commission payment model gets 10% commission and 90% withdrawal", () => {
  const f = computeCanonicalPaymentModelFields("commission");
  assert.equal(f.commission_rate, 0.1);
  assert.equal(f.withdrawal_percent, 0.9);
  assert.equal(f.commission_exempt, false);
  assert.equal(f.subscription_amount, 0);
});

test("admin can change payment model (canonical recompute)", () => {
  const merchant = {
    commission_rate: 0.5,
    withdrawal_percent: 0.1,
    payment_model: "subscription",
  };
  const next = applyCanonicalPaymentFields(merchant, "commission", {
    setSubscriptionStatus: false,
  });
  assert.equal(next.payment_model, "commission");
  assert.equal(next.commission_rate, 0.1);
  assert.equal(next.withdrawal_percent, 0.9);
});

test("non-admin cannot change payment model (unauthorized)", async () => {
  const res = await adminUpdateMerchantPaymentModel(
    { merchant_id: "m1", payment_model: "commission" },
    // Missing uid => isNexRideAdmin returns false without any DB calls.
    { auth: { token: {} } },
    {},
  );
  assert.equal(res.success, false);
  assert.equal(res.reason, "unauthorized");
});

test("non-admin cannot update subscription status (unauthorized)", async () => {
  const res = await adminUpdateMerchantSubscriptionStatus(
    { merchant_id: "m1", subscription_status: "active" },
    { auth: { token: {} } },
    {},
  );
  assert.equal(res.success, false);
  assert.equal(res.reason, "unauthorized");
});

test("approving merchant recomputes financial model", () => {
  const merchant = {
    payment_model: "subscription",
    commission_rate: 0,
    withdrawal_percent: 1.0,
  };
  // Simulate approve + switch to commission in canonical layer.
  const next = applyCanonicalPaymentFields(merchant, "commission", {
    setSubscriptionStatus: false,
  });
  assert.equal(next.commission_rate, 0.1);
  assert.equal(next.withdrawal_percent, 0.9);
});

test("subscription status update normalizes and validates", () => {
  assert.equal(normalizeSubscriptionStatus("under_review"), "under_review");
  assert.equal(normalizeSubscriptionStatus("pending_payment"), "pending_payment");
  assert.equal(normalizeSubscriptionStatus("pending payment"), "pending_payment");
  assert.equal(normalizeSubscriptionStatus("not_a_status"), "");
});

test("new merchant registration status is pending_review", () => {
  assert.equal(initialMerchantStatus(), "pending_review");
});

test("buildMerchantOwnerProfileUpdate only allows safe profile fields", () => {
  const patch = buildMerchantOwnerProfileUpdate({
    business_name: "ACME Foods",
    contact_email: "Owner@Example.com",
    region_id: "lagos",
    city_id: "ikeja",
    phone: "+2348000000000",
    owner_name: "Jane Owner",
    category: "Restaurant",
    address: "12 Allen Avenue, Ikeja",
    store_description: "We serve daily lunch specials.",
    opening_hours: "Mon–Sun 9–21",
    merchant_status: "approved",
    payment_model: "commission",
    commission_rate: 0.99,
    subscription_status: "active",
    withdrawal_percent: 1,
  });
  assert.deepEqual(patch, {
    business_name: "ACME Foods",
    contact_email: "owner@example.com",
    region_id: "lagos",
    city_id: "ikeja",
    phone: "+2348000000000",
    owner_name: "Jane Owner",
    category: "Restaurant",
    address: "12 Allen Avenue, Ikeja",
    store_description: "We serve daily lunch specials.",
    opening_hours: "Mon–Sun 9–21",
  });
});
