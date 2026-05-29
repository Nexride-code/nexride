const assert = require("node:assert/strict");
const { test } = require("node:test");
const wic = require("../worker_identity_claims");

const PEPPER = "test_pepper_value";

function makeDb(store) {
  return {
    ref(path) {
      const parts = String(path ?? "")
        .split("/")
        .filter(Boolean);
      return {
        async get() {
          let cur = store;
          for (const p of parts) {
            cur = cur == null ? undefined : cur[p];
          }
          return {
            val: () => (cur === undefined ? null : cur),
            exists: () => cur != null,
          };
        },
        async update(updates) {
          for (const [k, v] of Object.entries(updates)) {
            const segs = [...parts, ...String(k).split("/").filter(Boolean)];
            let cur = store;
            for (let i = 0; i < segs.length - 1; i += 1) {
              cur[segs[i]] = cur[segs[i]] || {};
              cur = cur[segs[i]];
            }
            cur[segs[segs.length - 1]] = v;
          }
        },
      };
    },
  };
}

test("normalizePhone produces E.164 for Nigerian formats", () => {
  assert.equal(wic.normalizePhone("08031234567"), "+2348031234567");
  assert.equal(wic.normalizePhone("+234 803 123 4567"), "+2348031234567");
  assert.equal(wic.normalizePhone("2348031234567"), "+2348031234567");
  assert.equal(wic.normalizePhone("0803-123-4567"), "+2348031234567");
  assert.equal(wic.normalizePhone(""), "");
  assert.equal(wic.normalizePhone("123"), "");
});

test("normalizeNin / normalizeBvn require 11 digits", () => {
  assert.equal(wic.normalizeNin("12345678901"), "12345678901");
  assert.equal(wic.normalizeNin("123-456-789-01"), "12345678901");
  assert.equal(wic.normalizeNin("12345"), "");
  assert.equal(wic.normalizeBvn("22112223334"), "22112223334");
  assert.equal(wic.normalizeBvn("999"), "");
});

test("normalizeBankAccount combines account and bank code", () => {
  assert.equal(wic.normalizeBankAccount("0123456789", "058"), "0123456789:058");
  assert.equal(wic.normalizeBankAccount("01234 56789"), "0123456789");
  assert.equal(wic.normalizeBankAccount("123"), "");
});

test("normalizePlate strips to uppercase alphanumerics", () => {
  assert.equal(wic.normalizePlate("abc-123-de"), "ABC123DE");
  assert.equal(wic.normalizePlate("AB1"), "");
});

test("hashClaim is deterministic for same inputs", () => {
  const a = wic.hashClaim("nin", "12345678901", PEPPER);
  const b = wic.hashClaim("nin", "12345678901", PEPPER);
  assert.equal(a, b);
  assert.equal(a.length, 64);
});

test("hashClaim differs by pepper and never equals the raw value", () => {
  const raw = "12345678901";
  const h1 = wic.hashClaim("nin", raw, PEPPER);
  const h2 = wic.hashClaim("nin", raw, "other_pepper");
  assert.notEqual(h1, h2);
  assert.notEqual(h1, raw);
  assert.ok(!h1.includes(raw));
});

test("buildDriverClaims only includes present, valid claims", () => {
  const claims = wic.buildDriverClaims(
    {
      phone: "08031234567",
      nin: "12345678901",
      bank_account: "0123456789",
      bank_code: "058",
      plate: "ABC-123-DE",
      bvn: "bad",
    },
    PEPPER,
  );
  assert.deepEqual(Object.keys(claims).sort(), [
    "bank_account",
    "nin",
    "phone",
    "plate",
  ]);
  for (const v of Object.values(claims)) {
    assert.equal(v.length, 64);
  }
});

test("findDuplicateWorkerIds ignores the self uid", async () => {
  const claims = wic.buildDriverClaims({ nin: "12345678901" }, PEPPER);
  const ninHash = claims.nin;
  const db = makeDb({
    worker_identity_claims: {
      nin: { [ninHash]: { self: { ownership_mode: "business_managed" } } },
    },
  });
  const matches = await wic.findDuplicateWorkerIds(db, claims, "self");
  assert.deepEqual(matches, {});
  assert.equal(wic.evaluateDuplicateReview(matches).status, "clear");
});

test("phone-only match is a warning, never a block", () => {
  const result = wic.evaluateDuplicateReview({
    phone: [
      { uid: "other", ownership_mode: "business_managed", business_id: "biz1" },
    ],
  });
  assert.equal(result.duplicate_review_required, false);
  assert.equal(result.warning, true);
  assert.equal(result.status, "warning");
  assert.deepEqual(result.matched_worker_ids, ["other"]);
});

test("NIN match with a business_managed worker blocks", async () => {
  const claims = wic.buildDriverClaims({ nin: "12345678901" }, PEPPER);
  const db = makeDb({
    worker_identity_claims: {
      nin: {
        [claims.nin]: {
          existing: { ownership_mode: "business_managed", business_id: "biz1" },
        },
      },
    },
  });
  const matches = await wic.findDuplicateWorkerIds(db, claims, "new_uid");
  const result = wic.evaluateDuplicateReview(matches);
  assert.equal(result.duplicate_review_required, true);
  assert.equal(result.status, "duplicate_review_required");
  assert.deepEqual(result.blocking_claim_types, ["nin"]);
  assert.deepEqual(result.matched_business_ids, ["biz1"]);
});

test("bank_account match with a business_managed worker blocks", async () => {
  const claims = wic.buildDriverClaims(
    { bank_account: "0123456789", bank_code: "058" },
    PEPPER,
  );
  const db = makeDb({
    worker_identity_claims: {
      bank_account: {
        [claims.bank_account]: {
          existing: { ownership_mode: "business_managed" },
        },
      },
    },
  });
  const matches = await wic.findDuplicateWorkerIds(db, claims, "new_uid");
  assert.equal(wic.evaluateDuplicateReview(matches).duplicate_review_required, true);
});

test("plate match with a business_managed worker blocks", async () => {
  const claims = wic.buildDriverClaims({ plate: "ABC-123-DE" }, PEPPER);
  const db = makeDb({
    worker_identity_claims: {
      plate: {
        [claims.plate]: { existing: { ownership_mode: "business_managed" } },
      },
    },
  });
  const matches = await wic.findDuplicateWorkerIds(db, claims, "new_uid");
  assert.equal(wic.evaluateDuplicateReview(matches).duplicate_review_required, true);
});

test("NIN match with an individual worker is a warning only", async () => {
  const claims = wic.buildDriverClaims({ nin: "12345678901" }, PEPPER);
  const db = makeDb({
    worker_identity_claims: {
      nin: {
        [claims.nin]: { existing: { ownership_mode: "individual" } },
      },
    },
  });
  const matches = await wic.findDuplicateWorkerIds(db, claims, "new_uid");
  const result = wic.evaluateDuplicateReview(matches);
  assert.equal(result.duplicate_review_required, false);
  assert.equal(result.warning, true);
});

test("missing claims evaluate to clear", async () => {
  const claims = wic.buildDriverClaims({}, PEPPER);
  assert.deepEqual(claims, {});
  const db = makeDb({});
  const matches = await wic.findDuplicateWorkerIds(db, claims, "new_uid");
  assert.equal(wic.evaluateDuplicateReview(matches).status, "clear");
});

test("upsertWorkerIdentityClaims writes hashed claims with metadata only", async () => {
  const claims = wic.buildDriverClaims(
    { nin: "12345678901", plate: "ABC-123-DE" },
    PEPPER,
  );
  const store = {};
  const db = makeDb(store);
  const res = await wic.upsertWorkerIdentityClaims(db, "uid1", claims, {
    ownership_mode: "individual",
    business_id: null,
    business_link_status: "approved",
    created_at: 1700000000000,
  });
  assert.equal(res.success, true);
  assert.equal(res.written, 2);
  const ninRow = store.worker_identity_claims.nin[claims.nin].uid1;
  assert.equal(ninRow.ownership_mode, "individual");
  assert.equal(ninRow.business_id, null);
  assert.equal(ninRow.business_link_status, "approved");
  // Stored key is a hash; the raw value must not appear anywhere.
  assert.ok(!JSON.stringify(store).includes("12345678901"));
});
