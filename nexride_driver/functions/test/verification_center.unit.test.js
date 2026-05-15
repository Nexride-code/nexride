const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  adminListVerificationUploads,
  adminReviewDriverDocument,
  adminListDriverVerificationDocuments,
  flattenDriverDocuments,
  normalizeDriverDocStatus,
  matchesStatusFilter,
} = require("../verification_center_callables");

const noopDb = {
  ref: () => ({
    get: async () => ({ val: () => null, exists: () => false }),
    push: () => ({ set: async () => {} }),
    update: async () => {},
  }),
};

test("matchesStatusFilter pending", () => {
  assert.equal(matchesStatusFilter("pending", "pending"), true);
  assert.equal(matchesStatusFilter("approved", "pending"), false);
});

test("normalizeDriverDocStatus maps submitted to pending", () => {
  assert.equal(
    normalizeDriverDocStatus({ status: "submitted", result: "awaiting_review" }),
    "pending",
  );
});

test("flattenDriverDocuments handles null", () => {
  assert.deepEqual(flattenDriverDocuments(null), []);
});

test("flattenDriverDocuments flattens tree", () => {
  const rows = flattenDriverDocuments({
    d1: { nin: { status: "submitted", result: "awaiting_review" } },
  });
  assert.equal(rows.length, 1);
  assert.equal(rows[0].driverId, "d1");
  assert.equal(rows[0].documentType, "nin");
});

test("non-admin cannot list verification uploads", async () => {
  const res = await adminListVerificationUploads(
    { userType: "all", status: "all", limit: 10 },
    { auth: { uid: "u1", token: {} } },
    noopDb,
  );
  assert.equal(res.success, false);
  assert.equal(res.reason, "unauthorized");
});

test("non-admin cannot review driver document", async () => {
  const res = await adminReviewDriverDocument(
    { driver_id: "d1", document_type: "nin", action: "approve" },
    { auth: { uid: "u1", token: {} } },
    noopDb,
  );
  assert.equal(res.success, false);
});

test("adminListDriverVerificationDocuments returns empty when tree missing", async () => {
  const res = await adminListDriverVerificationDocuments(
    { driver_id: "adminuid" },
    { auth: { uid: "admin1", token: { admin: true, admin_role: "super_admin" } } },
    noopDb,
  );
  assert.equal(res.success, true);
  assert.ok(Array.isArray(res.documents));
});
