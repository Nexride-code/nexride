const assert = require("node:assert/strict");
const { test } = require("node:test");
const wic = require("../worker_identity_claims");
const withdrawFlow = require("../withdraw_flow");

function makeDb(store) {
  function resolve(parts) {
    let cur = store;
    for (const p of parts) cur = cur == null ? undefined : cur[p];
    return cur;
  }
  function setPath(parts, value) {
    let cur = store;
    for (let i = 0; i < parts.length - 1; i += 1) {
      cur[parts[i]] = cur[parts[i]] || {};
      cur = cur[parts[i]];
    }
    cur[parts[parts.length - 1]] = value;
  }
  return {
    ref(path) {
      const parts = String(path ?? "")
        .split("/")
        .filter(Boolean);
      return {
        async get() {
          const cur = resolve(parts);
          return {
            val: () => (cur === undefined ? null : cur),
            exists: () => cur != null,
          };
        },
        async set(value) {
          setPath(parts, value);
        },
        async update(updates) {
          for (const [k, v] of Object.entries(updates)) {
            setPath([...parts, ...String(k).split("/").filter(Boolean)], v);
          }
        },
      };
    },
  };
}

test("runWorkerIdentityDuplicateCheck upserts claims + observe-only status", async () => {
  const store = {
    drivers: {
      drvA: {
        phone: "08031234567",
        ownership_mode: "individual",
        withdrawal_destination: { account_number: "0123456789", bank_code: "058" },
      },
    },
    driver_documents: {
      drvA: { nin: { documentNumber: "12345678901" } },
    },
  };
  const db = makeDb(store);
  const res = await wic.runWorkerIdentityDuplicateCheck(db, "drvA", { now: 1700000000000 });

  assert.equal(res.success, true);
  assert.equal(res.status, "clear");
  assert.deepEqual(res.claim_types.sort(), ["bank_account", "nin", "phone"]);

  // Claim index populated (hashed keys only — no raw values anywhere).
  assert.ok(store.worker_identity_claims.nin);
  assert.ok(store.worker_identity_claims.phone);
  assert.ok(store.worker_identity_claims.bank_account);
  assert.ok(!JSON.stringify(store.worker_identity_claims).includes("12345678901"));
  assert.ok(!JSON.stringify(store.worker_identity_claims).includes("0123456789"));

  // Observe-only metadata written.
  assert.equal(store.drivers.drvA.identity_review_status, "clear");
  assert.equal(store.drivers.drvA.duplicate_review_required, false);
  assert.ok(store.worker_identity_reviews.drvA);
});

test("self-match is excluded (own prior claim does not flag)", async () => {
  const claims = wic.buildDriverClaims({ nin: "12345678901" });
  const store = {
    drivers: { drvSelf: { ownership_mode: "business_managed", business_id: "biz1" } },
    driver_documents: { drvSelf: { nin: { documentNumber: "12345678901" } } },
    worker_identity_claims: {
      nin: { [claims.nin]: { drvSelf: { ownership_mode: "business_managed" } } },
    },
  };
  const db = makeDb(store);
  const res = await wic.runWorkerIdentityDuplicateCheck(db, "drvSelf", { now: 1 });
  assert.equal(res.status, "clear");
  assert.equal(store.drivers.drvSelf.duplicate_review_required, false);
});

test("document-approval scenario: NIN collision with business_managed flags review", async () => {
  const claims = wic.buildDriverClaims({ nin: "12345678901" });
  const store = {
    drivers: {
      existingBiz: { ownership_mode: "business_managed", business_id: "biz1" },
      newDrv: { ownership_mode: "individual" },
    },
    driver_documents: { newDrv: { nin: { documentNumber: "12345678901" } } },
    worker_identity_claims: {
      nin: { [claims.nin]: { existingBiz: { ownership_mode: "business_managed", business_id: "biz1" } } },
    },
  };
  const db = makeDb(store);
  const res = await wic.runWorkerIdentityDuplicateCheck(db, "newDrv", { now: 1 });
  assert.equal(res.duplicate_review_required, true);
  assert.equal(store.drivers.newDrv.identity_review_status, "duplicate_review_required");
  assert.deepEqual(store.drivers.newDrv.possible_duplicate_worker_ids, ["existingBiz"]);
  assert.deepEqual(store.worker_identity_reviews.newDrv.matched_business_ids, ["biz1"]);
});

test("fleet-redeem scenario: claims stored with business_managed metadata", async () => {
  const store = {
    drivers: {
      bikerX: {
        phone: "08039998888",
        ownership_mode: "business_managed",
        business_id: "biz9",
        business_link_status: "approved",
      },
    },
    driver_documents: { bikerX: { vehicle_documents: { documentNumber: "ABC123DE" } } },
  };
  const db = makeDb(store);
  const res = await wic.runWorkerIdentityDuplicateCheck(db, "bikerX", { now: 1 });
  assert.equal(res.success, true);
  const plateClaim = wic.buildDriverClaims({ plate: "ABC123DE" }).plate;
  const row = store.worker_identity_claims.plate[plateClaim].bikerX;
  assert.equal(row.ownership_mode, "business_managed");
  assert.equal(row.business_id, "biz9");
  assert.equal(row.business_link_status, "approved");
});

test("withdrawal destination save triggers claim upsert (observe-only, never blocks)", async () => {
  // Pre-seed a colliding business_managed bank_account claim.
  const bankClaim = wic.buildDriverClaims({
    bank_account: "0123456789",
    bank_code: "058",
  }).bank_account;
  const store = {
    drivers: { drvW: { phone: "08031234567", ownership_mode: "individual" } },
    driver_documents: {},
    worker_identity_claims: {
      bank_account: {
        [bankClaim]: { otherBiz: { ownership_mode: "business_managed", business_id: "bizZ" } },
      },
    },
  };
  const db = makeDb(store);

  const result = await withdrawFlow.driverUpdateWithdrawalDestination(
    {
      bank_name: "GTBank",
      account_number: "0123456789",
      account_holder_name: "Test Driver",
      bank_code: "058",
    },
    { auth: { uid: "drvW" } },
    db,
  );

  // The save itself still succeeds — observe-only never blocks.
  assert.equal(result.success, true);
  assert.ok(store.drivers.drvW.withdrawal_destination);
  // Claim was upserted for this driver.
  assert.ok(store.worker_identity_claims.bank_account[bankClaim].drvW);
  // Observe-only status reflects the duplicate but does not block.
  assert.equal(store.drivers.drvW.identity_review_status, "duplicate_review_required");
  assert.equal(store.drivers.drvW.duplicate_review_required, true);
  assert.deepEqual(store.drivers.drvW.possible_duplicate_worker_ids, ["otherBiz"]);
});

test("workerRunIdentityDuplicateCheck callable requires auth", async () => {
  const db = makeDb({ drivers: {}, driver_documents: {} });
  const denied = await wic.workerRunIdentityDuplicateCheck({}, {}, db);
  assert.equal(denied.success, false);
  assert.equal(denied.reason, "unauthorized");

  const store = { drivers: { drvC: { phone: "08031234567" } }, driver_documents: {} };
  const ok = await wic.workerRunIdentityDuplicateCheck(
    {},
    { auth: { uid: "drvC" } },
    makeDb(store),
  );
  assert.equal(ok.success, true);
  assert.equal(ok.status, "clear");
  // Callable response stays minimal (no other workers' ids leaked to drivers).
  assert.equal(ok.matched_worker_ids, undefined);
});
