const assert = require("node:assert/strict");
const { test } = require("node:test");
const admin = require("firebase-admin");

const fleet = require("../business_fleet_callables");
const merchantVerification = require("../merchant/merchant_verification");

if (!admin.apps.length) {
  admin.initializeApp({ projectId: "nexride-test" });
}

function createMockDb(initial = {}) {
  const store = { ...initial };
  let pushSeq = 0;

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
        if (i === parts.length - 1) {
          cur[p] = v;
        } else {
          if (!cur[p] || typeof cur[p] !== "object") cur[p] = {};
          cur = cur[p];
        }
      }
    }
    return Object.keys(out).length ? out : null;
  }

  function ref(path = "") {
    const p = String(path || "");
    return {
      async get() {
        let val = Object.prototype.hasOwnProperty.call(store, p) ? store[p] : undefined;
        if (val === undefined) {
          val = buildObjectForPath(p);
        }
        return {
          exists: () => val !== undefined && val !== null,
          val: () => (val === undefined ? null : val),
        };
      },
      async set(v) {
        store[p] = v;
      },
      async update(v) {
        if (!p) {
          for (const [k, value] of Object.entries(v || {})) {
            store[k] = value;
          }
          return;
        }
        const cur = (await this.get()).val();
        if (cur && typeof cur === "object" && v && typeof v === "object") {
          store[p] = { ...cur, ...v };
        } else {
          store[p] = v;
        }
      },
      async transaction(fn) {
        const curSnap = await this.get();
        const current = curSnap.val();
        const next = fn(current);
        if (next === undefined) {
          return {
            committed: false,
            snapshot: {
              val: () => current,
              exists: () => current !== null && current !== undefined,
            },
          };
        }
        store[p] = next;
        return {
          committed: true,
          snapshot: {
            val: () => next,
            exists: () => next !== null && next !== undefined,
          },
        };
      },
      push() {
        pushSeq += 1;
        const key = `push_${pushSeq}`;
        const child = p ? `${p}/${key}` : key;
        return {
          key,
          async set(v) {
            store[child] = v;
          },
          async update(v) {
            const cur = store[child] && typeof store[child] === "object" ? store[child] : {};
            store[child] = { ...cur, ...v };
          },
        };
      },
    };
  }

  return {
    ref,
    _store: store,
  };
}

function withMerchantResolution(result, fn) {
  const original = merchantVerification.resolveMerchantForMerchantAuth;
  merchantVerification.resolveMerchantForMerchantAuth = async () => result;
  return Promise.resolve()
    .then(fn)
    .finally(() => {
      merchantVerification.resolveMerchantForMerchantAuth = original;
    });
}

test("invite create/redeem happy path", async () => {
  const db = createMockDb();
  const createRes = await withMerchantResolution(
    { ok: true, id: "biz_1", data: { owner_uid: "owner_1" } },
    () =>
      fleet.businessCreateDriverInvite(
        { dispatch_vehicle_type: "bike" },
        { auth: { uid: "owner_1" } },
        db,
      ),
  );
  assert.equal(createRes.success, true);
  const redeemRes = await fleet.driverRedeemBusinessInvite(
    { invite_code: createRes.invite_code },
    { auth: { uid: "driver_1" } },
    db,
  );
  assert.equal(redeemRes.success, true);
  assert.equal(db._store["drivers/driver_1/ownership_mode"], "business_managed");
  assert.equal(db._store["drivers/driver_1/business_id"], "biz_1");
  assert.equal(db._store["business_driver_links/biz_1/driver_1"].status, "approved");
});

test("expired invite rejected", async () => {
  const db = createMockDb({
    "business_driver_invites/INV_EXPIRED": {
      invite_code: "INV_EXPIRED",
      business_id: "biz_1",
      dispatch_vehicle_type: "bike",
      expires_at: Date.now() - 1000,
    },
  });
  const res = await fleet.driverRedeemBusinessInvite(
    { invite_code: "INV_EXPIRED" },
    { auth: { uid: "driver_1" } },
    db,
  );
  assert.equal(res.success, false);
  assert.equal(res.reason, "invite_expired");
});

test("invalid invite rejected", async () => {
  const db = createMockDb();
  const res = await fleet.driverRedeemBusinessInvite(
    { invite_code: "MISSING_INVITE" },
    { auth: { uid: "driver_1" } },
    db,
  );
  assert.equal(res.success, false);
  assert.equal(res.reason, "invalid_invite");
});

test("business-managed without valid invite payload rejected", async () => {
  const db = createMockDb({
    "business_driver_invites/INV_BAD": {
      invite_code: "INV_BAD",
      business_id: "",
      dispatch_vehicle_type: "bike",
      expires_at: Date.now() + 100000,
    },
  });
  const res = await fleet.driverRedeemBusinessInvite(
    { invite_code: "INV_BAD" },
    { auth: { uid: "driver_1" } },
    db,
  );
  assert.equal(res.success, false);
  assert.equal(res.reason, "business_id_required");
});

test("invalid vehicle type rejected", async () => {
  const db = createMockDb();
  const res = await withMerchantResolution(
    { ok: true, id: "biz_1", data: { owner_uid: "owner_1" } },
    () =>
      fleet.businessCreateDriverInvite(
        { dispatch_vehicle_type: "truck" },
        { auth: { uid: "owner_1" } },
        db,
      ),
  );
  assert.equal(res.success, false);
  assert.equal(res.reason, "invalid_dispatch_vehicle_type");
});

test("idempotent re-link is safe", async () => {
  const db = createMockDb({
    "business_driver_invites/INV_IDEMP": {
      invite_code: "INV_IDEMP",
      business_id: "biz_1",
      dispatch_vehicle_type: "van",
      owner_uid: "owner_1",
      expires_at: Date.now() + 100000,
      status: "pending",
    },
    "drivers/driver_1": {
      ownership_mode: "business_managed",
      business_id: "biz_1",
      business_link_status: "approved",
      dispatch_vehicle_type: "van",
      dispatch_verified: true,
      dispatch_verification_status: "approved",
    },
  });
  const res = await fleet.driverRedeemBusinessInvite(
    { invite_code: "INV_IDEMP" },
    { auth: { uid: "driver_1" } },
    db,
  );
  assert.equal(res.success, true);
  assert.equal(res.idempotent, true);
  assert.equal(res.reason, "already_linked");
});

test("replay redeem blocked for second different driver", async () => {
  const db = createMockDb({
    "business_driver_invites/INV_ONCE": {
      invite_code: "INV_ONCE",
      business_id: "biz_1",
      dispatch_vehicle_type: "bike",
      owner_uid: "owner_1",
      expires_at: Date.now() + 100000,
      status: "pending",
    },
  });
  const first = await fleet.driverRedeemBusinessInvite(
    { invite_code: "INV_ONCE" },
    { auth: { uid: "driver_1" } },
    db,
  );
  assert.equal(first.success, true);
  const second = await fleet.driverRedeemBusinessInvite(
    { invite_code: "INV_ONCE" },
    { auth: { uid: "driver_2" } },
    db,
  );
  assert.equal(second.success, false);
  assert.equal(second.reason, "invite_already_redeemed");
});

test("unauthorized invite creation blocked", async () => {
  const db = createMockDb();
  const res = await withMerchantResolution(
    { ok: false, reason: "unauthorized" },
    () =>
      fleet.businessCreateDriverInvite(
        { dispatch_vehicle_type: "bike" },
        { auth: { uid: "random_user" } },
        db,
      ),
  );
  assert.equal(res.success, false);
  assert.equal(res.reason, "unauthorized");
});

test("conflicting business relink blocked", async () => {
  const db = createMockDb({
    "business_driver_invites/INV_BIZ2": {
      invite_code: "INV_BIZ2",
      business_id: "biz_2",
      dispatch_vehicle_type: "car",
      owner_uid: "owner_2",
      expires_at: Date.now() + 100000,
      status: "pending",
    },
    "drivers/driver_1": {
      ownership_mode: "business_managed",
      business_id: "biz_1",
      business_link_status: "approved",
    },
  });
  const res = await fleet.driverRedeemBusinessInvite(
    { invite_code: "INV_BIZ2" },
    { auth: { uid: "driver_1" } },
    db,
  );
  assert.equal(res.success, false);
  assert.equal(res.reason, "driver_linked_to_another_business");
});

test("malformed ownership_mode blocked by validator", () => {
  const bad = fleet.validateDispatchProfileInput({
    dispatch_vehicle_type: "bike",
    ownership_mode: "corp_managed",
    business_id: "biz_1",
  });
  assert.equal(bad.ok, false);
  assert.equal(bad.reason, "invalid_ownership_mode");
});

