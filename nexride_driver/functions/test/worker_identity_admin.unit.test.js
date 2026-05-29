const assert = require("node:assert/strict");
const { test } = require("node:test");
const admin = require("firebase-admin");

const identityAdmin = require("../worker_identity_admin");

if (!admin.apps.length) {
  admin.initializeApp({ projectId: "nexride-test" });
}

const {
  adminListWorkerIdentityReviewsPage,
  adminGetWorkerIdentityReview,
} = identityAdmin;

// Mock DB supporting keyed reads + orderByKey().startAfter().limitToFirst().
function createMockDb(initial = {}) {
  const store = { ...initial };
  function buildObjectForPath(path) {
    const out = {};
    const prefix = `${path}/`;
    for (const [k, v] of Object.entries(store)) {
      if (!k.startsWith(prefix)) continue;
      const rest = k.slice(prefix.length);
      const parts = rest.split("/").filter(Boolean);
      let cur = out;
      for (let i = 0; i < parts.length; i += 1) {
        const p = parts[i];
        if (i === parts.length - 1) cur[p] = v;
        else {
          if (!cur[p] || typeof cur[p] !== "object") cur[p] = {};
          cur = cur[p];
        }
      }
    }
    return Object.keys(out).length ? out : null;
  }
  function ref(path = "") {
    const p = String(path || "");
    const qs = { orderByKey: false, startAfter: null, limit: null };
    const api = {
      orderByKey() {
        qs.orderByKey = true;
        return api;
      },
      startAfter(key) {
        qs.startAfter = String(key || "");
        return api;
      },
      limitToFirst(n) {
        qs.limit = Math.max(0, Number(n) || 0);
        return api;
      },
      async get() {
        if (qs.orderByKey && qs.limit != null) {
          const obj = buildObjectForPath(p) || {};
          let keys = Object.keys(obj).sort();
          if (qs.startAfter) keys = keys.filter((k) => k > qs.startAfter);
          const slice = keys.slice(0, qs.limit);
          if (!slice.length) return { exists: () => false, val: () => null };
          const out = {};
          for (const k of slice) out[k] = obj[k];
          return { exists: () => true, val: () => out };
        }
        let val = Object.prototype.hasOwnProperty.call(store, p)
          ? store[p]
          : undefined;
        if (val === undefined) val = buildObjectForPath(p);
        return { exists: () => val != null, val: () => (val === undefined ? null : val) };
      },
    };
    return api;
  }
  return { ref, _store: store };
}

const ADMIN = { auth: { uid: "admin_1", token: { admin: true, admin_role: "super_admin" } } };
const NON_ADMIN = { auth: { uid: "nobody" } };

function seed() {
  return createMockDb({
    "admins/admin_1": { enabled: true, admin_role: "super_admin" },
    // duplicate_review_required review (NIN collision against business worker)
    "worker_identity_reviews/drv_dup": {
      status: "duplicate_review_required",
      matched_claim_types: ["nin", "bank_account"],
      blocking_claim_types: ["nin"],
      warning_claim_types: ["bank_account"],
      matched_worker_ids: ["drv_fleet"],
      matched_business_ids: ["biz_1"],
      updated_at: 300,
    },
    // warning-only review (phone match)
    "worker_identity_reviews/drv_warn": {
      status: "warning",
      matched_claim_types: ["phone"],
      blocking_claim_types: [],
      warning_claim_types: ["phone"],
      matched_worker_ids: ["drv_other"],
      matched_business_ids: [],
      updated_at: 200,
    },
    // clear review
    "worker_identity_reviews/drv_clear": {
      status: "clear",
      matched_claim_types: [],
      matched_worker_ids: [],
      matched_business_ids: [],
      updated_at: 100,
    },
    "drivers/drv_dup": {
      name: "Dup Rider",
      phone: "+2348010000001",
      service_type: "bike_dispatch",
      ownership_mode: "individual",
      dispatch_vehicle_type: "bike",
      identity_review_status: "duplicate_review_required",
      duplicate_review_required: true,
      // raw doc fields that MUST NOT leak through these callables
      withdrawal_destination: { account_number: "0123456789", bank_code: "058" },
    },
    "drivers/drv_warn": {
      name: "Warn Rider",
      phone: "+2348010000002",
      service_type: "van_dispatch",
      ownership_mode: "individual",
      dispatch_vehicle_type: "van",
    },
    "driver_documents/drv_dup": {
      nin: { documentNumber: "12345678901" },
      bvn: { documentNumber: "22345678901" },
    },
  });
}

test("list returns duplicate_review_required review with matched ids/types", async () => {
  const db = seed();
  const res = await adminListWorkerIdentityReviewsPage({ limit: 50 }, ADMIN, db);
  assert.equal(res.success, true);
  assert.equal(res.observe_only, true);
  const dup = res.reviews.find((r) => r.driver_id === "drv_dup");
  assert.ok(dup, "duplicate review present");
  assert.equal(dup.identity_review_status, "duplicate_review_required");
  assert.equal(dup.duplicate_review_required, true);
  assert.deepEqual(dup.matched_claim_types, ["nin", "bank_account"]);
  assert.deepEqual(dup.matched_worker_ids, ["drv_fleet"]);
  assert.equal(dup.matched_worker_count, 1);
  assert.deepEqual(dup.matched_business_ids, ["biz_1"]);
  // enriched driver summary
  assert.equal(dup.service_type, "bike_dispatch");
  assert.equal(dup.ownership_mode, "individual");
  assert.equal(dup.dispatch_vehicle_type, "bike");
});

test("list returns warning review", async () => {
  const db = seed();
  const res = await adminListWorkerIdentityReviewsPage({ limit: 50 }, ADMIN, db);
  const warn = res.reviews.find((r) => r.driver_id === "drv_warn");
  assert.ok(warn);
  assert.equal(warn.identity_review_status, "warning");
  assert.equal(warn.duplicate_review_required, false);
  assert.deepEqual(warn.matched_claim_types, ["phone"]);
});

test("flaggedOnly excludes clear reviews", async () => {
  const db = seed();
  const res = await adminListWorkerIdentityReviewsPage(
    { limit: 50, flaggedOnly: true },
    ADMIN,
    db,
  );
  const ids = res.reviews.map((r) => r.driver_id);
  assert.ok(ids.includes("drv_dup"));
  assert.ok(ids.includes("drv_warn"));
  assert.ok(!ids.includes("drv_clear"));
});

test("status filter narrows to duplicate_review_required", async () => {
  const db = seed();
  const res = await adminListWorkerIdentityReviewsPage(
    { limit: 50, status: "duplicate_review_required" },
    ADMIN,
    db,
  );
  assert.equal(res.reviews.length, 1);
  assert.equal(res.reviews[0].driver_id, "drv_dup");
});

test("detail returns matched ids/types and driver summary", async () => {
  const db = seed();
  const res = await adminGetWorkerIdentityReview({ driver_id: "drv_dup" }, ADMIN, db);
  assert.equal(res.success, true);
  assert.equal(res.found, true);
  assert.equal(res.observe_only, true);
  assert.equal(res.review.identity_review_status, "duplicate_review_required");
  assert.deepEqual(res.review.matched_worker_ids, ["drv_fleet"]);
  assert.deepEqual(res.review.matched_business_ids, ["biz_1"]);
  assert.deepEqual(res.review.blocking_claim_types, ["nin"]);
  assert.equal(res.review.driver_name, "Dup Rider");
  assert.equal(res.review.phone, "+2348010000001");
});

test("no raw NIN/BVN/bank/plate or claim hashes are returned", async () => {
  const db = seed();
  const list = await adminListWorkerIdentityReviewsPage({ limit: 50 }, ADMIN, db);
  const detail = await adminGetWorkerIdentityReview({ driver_id: "drv_dup" }, ADMIN, db);
  const blob = JSON.stringify(list) + JSON.stringify(detail);
  // Raw identity numbers seeded in driver_documents / withdrawal_destination
  assert.ok(!blob.includes("12345678901"), "raw NIN must not leak");
  assert.ok(!blob.includes("22345678901"), "raw BVN must not leak");
  assert.ok(!blob.includes("0123456789"), "raw bank account must not leak");
  // No hex claim-hash-looking fields
  assert.ok(!/\bclaim_hash\b/.test(blob), "no claim_hash field");
  assert.ok(!/[a-f0-9]{64}/.test(blob), "no sha256 hex digest in payload");
});

test("detail for unknown driver returns found=false (no error)", async () => {
  const db = seed();
  const res = await adminGetWorkerIdentityReview({ driver_id: "ghost" }, ADMIN, db);
  assert.equal(res.success, true);
  assert.equal(res.found, false);
  assert.equal(res.review, null);
});

test("detail requires driver_id", async () => {
  const db = seed();
  const res = await adminGetWorkerIdentityReview({}, ADMIN, db);
  assert.equal(res.success, false);
  assert.equal(res.reason, "driver_id_required");
});

test("pagination works with small limit and cursor", async () => {
  const db = seed();
  const page1 = await adminListWorkerIdentityReviewsPage({ limit: 1 }, ADMIN, db);
  assert.equal(page1.success, true);
  assert.equal(page1.count, 1);
  assert.equal(page1.hasMore, true);
  assert.ok(page1.nextCursor, "nextCursor set when more rows exist");

  const page2 = await adminListWorkerIdentityReviewsPage(
    { limit: 1, cursor: page1.nextCursor },
    ADMIN,
    db,
  );
  assert.equal(page2.success, true);
  assert.equal(page2.count, 1);
  // Different row than page 1 (cursor advanced by key).
  assert.notEqual(page2.reviews[0].driver_id, page1.reviews[0].driver_id);
});

test("non-admin is denied for both callables", async () => {
  const db = seed();
  const list = await adminListWorkerIdentityReviewsPage({ limit: 50 }, NON_ADMIN, db);
  assert.notEqual(list.success, true);
  const detail = await adminGetWorkerIdentityReview({ driver_id: "drv_dup" }, NON_ADMIN, db);
  assert.notEqual(detail.success, true);
});
