const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  categoryRequiresOperatingLicense,
  computeMerchantReadinessFromMaps,
  adminReviewMerchantDocument,
  adminGetMerchantReadiness,
} = require("../merchant/merchant_verification");

test("categoryRequiresOperatingLicense for food and pharmacy", () => {
  assert.equal(categoryRequiresOperatingLicense("Restaurant"), true);
  assert.equal(categoryRequiresOperatingLicense("street food"), true);
  assert.equal(categoryRequiresOperatingLicense("Pharmacy"), true);
  assert.equal(categoryRequiresOperatingLicense("grocery"), false);
  assert.equal(categoryRequiresOperatingLicense(""), false);
});

test("readiness blocks until required documents are approved", () => {
  const merchant = {
    merchant_status: "pending",
    payment_model: "subscription",
    subscription_status: "pending_payment",
    category: "Retail",
  };
  const empty = {};
  const r = computeMerchantReadinessFromMaps(merchant, empty);
  assert.equal(r.allowed, false);
  assert.ok(r.missingRequirements.some((x) => x.includes("owner_id")));
  assert.ok(r.missingRequirements.some((x) => x.includes("storefront_photo")));
  assert.equal(r.requires_operating_license, false);
});

test("food category requires operating_license approved", () => {
  const merchant = {
    merchant_status: "pending",
    payment_model: "commission",
    subscription_status: "inactive",
    category: "Food vendor",
  };
  const docs = {
    owner_id: { status: "approved" },
    storefront_photo: { status: "approved" },
  };
  const r = computeMerchantReadinessFromMaps(merchant, docs);
  assert.equal(r.requires_operating_license, true);
  assert.equal(r.allowed, false);
  assert.ok(r.missingRequirements.some((x) => x.includes("operating_license")));
});

test("readiness allows when required docs approved", () => {
  const merchant = {
    merchant_status: "pending",
    payment_model: "subscription",
    subscription_status: "pending_payment",
    category: "Retail",
  };
  const docs = {
    owner_id: { status: "approved" },
    storefront_photo: { status: "approved" },
  };
  const r = computeMerchantReadinessFromMaps(merchant, docs);
  assert.equal(r.allowed, true);
  assert.equal(r.missingRequirements.length, 0);
});

test("pharmacy requires operating_license even when owner and storefront approved", () => {
  const merchant = {
    merchant_status: "pending",
    payment_model: "subscription",
    subscription_status: "inactive",
    category: "Pharmacy",
  };
  const docs = {
    owner_id: { status: "approved" },
    storefront_photo: { status: "approved" },
    operating_license: { status: "pending" },
  };
  const r = computeMerchantReadinessFromMaps(merchant, docs);
  assert.equal(r.allowed, false);
});

test("rejected owner_id blocks readiness until re-approved", () => {
  const merchant = {
    merchant_status: "pending",
    payment_model: "subscription",
    subscription_status: "inactive",
    category: "Retail",
  };
  const docs = {
    owner_id: { status: "rejected" },
    storefront_photo: { status: "approved" },
  };
  const r = computeMerchantReadinessFromMaps(merchant, docs);
  assert.equal(r.allowed, false);
});

test("merchant upload path would set pending (logic: new upload clears rejection)", () => {
  const merchant = { merchant_status: "pending", category: "Retail" };
  const afterUpload = {
    owner_id: { status: "pending" },
    storefront_photo: { status: "not_submitted" },
  };
  const r = computeMerchantReadinessFromMaps(merchant, afterUpload);
  assert.equal(r.documentStatuses.owner_id, "pending");
  assert.equal(r.allowed, false);
});

const noopRtdb = {
  ref: () => ({
    get: async () => ({ val: () => null }),
    push: () => ({ set: async () => {} }),
  }),
};

test("non-admin cannot review verification document", async () => {
  const res = await adminReviewMerchantDocument(
    {
      merchant_id: "m1",
      document_type: "owner_id",
      action: "approve",
    },
    { auth: { uid: "x", token: {} } },
    noopRtdb,
  );
  assert.equal(res.success, false);
  assert.equal(res.reason, "unauthorized");
});

test("non-admin cannot get merchant readiness", async () => {
  const res = await adminGetMerchantReadiness(
    { merchant_id: "m1" },
    { auth: { uid: "x", token: {} } },
    noopRtdb,
  );
  assert.equal(res.success, false);
  assert.equal(res.reason, "unauthorized");
});

test("reject document requires note or rejection_reason", async () => {
  const res = await adminReviewMerchantDocument(
    {
      merchant_id: "m1",
      document_type: "owner_id",
      action: "reject",
    },
    { auth: { uid: "admin1", token: { admin: true, admin_role: "super_admin" } } },
    noopRtdb,
  );
  assert.equal(res.success, false);
  assert.equal(res.reason, "note_required");
});
