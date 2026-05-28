const assert = require("node:assert/strict");
const { test } = require("node:test");
const admin = require("firebase-admin");

const fleet = require("../business_fleet_callables");
const fleetVerification = require("../fleet_verification");
const merchantVerification = require("../merchant/merchant_verification");
const merchantPublicSync = require("../merchant_public_sync");

if (!admin.apps.length) {
  admin.initializeApp({ projectId: "nexride-test" });
}

const APPROVED_FLEET_MERCHANT = {
  owner_uid: "owner_1",
  account_kind: "dispatch_fleet",
  merchant_status: "approved",
  status: "approved",
  verification_status: "approved",
  required_documents_complete: true,
};

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

function createMockFirestore(store = {}) {
  let seq = 0;
  return {
    collection(name) {
      if (name !== "merchants") {
        throw new Error(`unexpected collection: ${name}`);
      }
      return {
        doc(id) {
          const docId = id || `m_${++seq}`;
          return {
            id: docId,
            async set(data) {
              store[docId] = { ...(data || {}) };
            },
            async get() {
              const data = store[docId];
              return {
                exists: data != null,
                id: docId,
                data: () => data,
              };
            },
            async update(patch) {
              store[docId] = { ...(store[docId] || {}), ...(patch || {}) };
            },
          };
        },
        where(field, _op, value) {
          return {
            limit(n) {
              return {
                async get() {
                  const docs = Object.entries(store)
                    .filter(([, row]) => row && row[field] === value)
                    .slice(0, n)
                    .map(([id, row]) => ({
                      id,
                      data: () => row,
                    }));
                  return { docs, empty: docs.length === 0 };
                },
              };
            },
          };
        },
      };
    },
    _store: store,
  };
}

function seedFleetOwnerIndex(db, ownerUid, businessId, indexEntry) {
  db._store[`dispatch_fleet_owner_index/${ownerUid}/${businessId}`] = indexEntry;
}

function seedFleetAccount(db, merchants, ownerUid, businessId, merchantRow, indexEntry) {
  const status =
    indexEntry?.status ??
    merchantRow.merchant_status ??
    merchantRow.status ??
    "pending_review";
  seedFleetOwnerIndex(db, ownerUid, businessId, {
    business_id: businessId,
    account_kind: "dispatch_fleet",
    status,
    created_at: indexEntry?.created_at ?? Date.now(),
    ...indexEntry,
  });
  merchants[businessId] = {
    owner_uid: ownerUid,
    account_kind: "dispatch_fleet",
    ...merchantRow,
  };
}

test("fleetAccountApprovedForInvites requires dispatch fleet + approved + docs complete", () => {
  assert.equal(
    fleet.fleetAccountApprovedForInvites({
      account_kind: "dispatch_fleet",
      merchant_status: "approved",
      verification_status: "approved",
      required_documents_complete: true,
    }),
    true,
  );
  assert.equal(
    fleet.fleetAccountApprovedForInvites({
      account_kind: "dispatch_fleet",
      merchant_status: "approved",
      verification_status: "approved",
      required_documents_complete: false,
    }),
    false,
  );
  assert.equal(
    fleet.fleetAccountApprovedForInvites({
      account_kind: "dispatch_fleet",
      merchant_status: "suspended",
      verification_status: "approved",
      required_documents_complete: true,
    }),
    false,
  );
  assert.equal(
    fleet.fleetAccountApprovedForInvites({
      account_kind: "dispatch_fleet",
      merchant_status: "pending_review",
      verification_status: "pending_review",
    }),
    false,
  );
  assert.equal(
    fleet.fleetAccountApprovedForInvites({
      account_kind: "restaurant",
      merchant_status: "approved",
      verification_status: "approved",
    }),
    false,
  );
});

test("fleet register creates account_kind dispatch_fleet", async () => {
  const db = createMockDb();
  const merchants = {};
  const fs = createMockFirestore(merchants);
  fleet.setFirestoreForTests(fs);

  try {
    const res = await fleet.dispatchFleetRegister(
      {
        business_name: "Lagos Dispatch Fleet",
        verification_type: "cac_business",
        owner_name: "Ada Owner",
        contact_email: "fleet@example.com",
        phone: "+2348000000001",
        address: "12 Fleet Road",
        region_id: "lagos",
        city_id: "ikeja",
      },
      { auth: { uid: "owner_fleet_1", token: { email: "fleet@example.com" } } },
      db,
    );
    assert.equal(res.success, true);
    assert.equal(res.account_kind, "dispatch_fleet");
    const row = merchants[res.business_id];
    assert.equal(row.account_kind, "dispatch_fleet");
    assert.equal(row.merchant_status, "pending_documents");
    assert.equal(row.verification_type, "cac_business");
    assert.equal(row.verification_status, "incomplete");
    assert.equal(row.accepting_orders, false);
    assert.equal(row.is_open, false);
    assert.equal(row.business_type, "dispatch_fleet");
    assert.ok(db._store[`dispatch_fleet_owner_index/owner_fleet_1/${res.business_id}`]);
    assert.equal(
      db._store[`dispatch_fleet_owner_index/owner_fleet_1/${res.business_id}`].account_kind,
      "dispatch_fleet",
    );
  } finally {
    fleet.setFirestoreForTests(null);
  }
});

test("duplicate fleet account blocked via owner index", async () => {
  const db = createMockDb({
    "dispatch_fleet_owner_index/owner_dup/existing_biz": {
      business_id: "existing_biz",
      account_kind: "dispatch_fleet",
      status: "pending_review",
      created_at: Date.now(),
    },
  });
  const merchants = {
    existing_biz: {
      account_kind: "dispatch_fleet",
      merchant_status: "pending_review",
      owner_uid: "owner_dup",
    },
  };
  const fs = createMockFirestore(merchants);
  fleet.setFirestoreForTests(fs);

  try {
    const res = await fleet.dispatchFleetRegister(
      { business_name: "Second Fleet", contact_email: "dup@example.com" },
      { auth: { uid: "owner_dup", token: { email: "dup@example.com" } } },
      db,
    );
    assert.equal(res.success, false);
    assert.equal(res.reason, "fleet_account_already_exists");
    assert.equal(res.business_id, "existing_biz");
  } finally {
    fleet.setFirestoreForTests(null);
  }
});

test("fleet register does not create public teaser", async () => {
  const db = createMockDb();
  const merchants = {
    fleet_1: {
      account_kind: "dispatch_fleet",
      merchant_status: "pending_review",
      business_name: "No Teaser Fleet",
      is_open: false,
      accepting_orders: false,
    },
  };
  const fs = createMockFirestore(merchants);
  merchantPublicSync.setFirestoreForTests(fs);

  try {
    await merchantPublicSync.syncMerchantPublicTeaserFromMerchantId(db, "fleet_1");
    assert.equal(db._store["merchant_public_teaser/fleet_1"], undefined);
  } finally {
    merchantPublicSync.setFirestoreForTests(null);
  }
});

test("getMyAccount returns fleet-safe fields only via owner index", async () => {
  const db = createMockDb();
  const merchants = {};
  seedFleetAccount(db, merchants, "owner_1", "biz_f1", {
    business_name: "Fleet Ltd",
    merchant_status: "pending_documents",
    verification_status: "incomplete",
    verification_type: "cac_business",
    menu_secret: "must_not_leak",
  });
  const verificationDocs = {};
  const fs = createFleetAdminMockFirestore(merchants, verificationDocs);
  fleet.setFirestoreForTests(fs);
  fleetVerification.setFirestoreForTests(fs);

  try {
    const res = await fleet.dispatchFleetGetMyAccount({}, { auth: { uid: "owner_1" } }, db);
    assert.equal(res.success, true);
    assert.equal(res.account.business_id, "biz_f1");
    assert.equal(res.account.account_kind, "dispatch_fleet");
    assert.equal(res.account.verification_type, "cac_business");
    assert.equal(res.account.docs_readiness.allowed, false);
    assert.ok(Array.isArray(res.account.docs_readiness.missing_submissions));
    assert.equal(res.account.menu_secret, undefined);
    assert.equal(res.account.payment_model, undefined);
  } finally {
    fleet.setFirestoreForTests(null);
    fleetVerification.setFirestoreForTests(null);
  }
});

test("getMyAccount hides commerce merchant rows", async () => {
  const db = createMockDb();
  const merchants = {};
  seedFleetOwnerIndex(db, "owner_1", "m_rest", {
    business_id: "m_rest",
    account_kind: "dispatch_fleet",
    status: "approved",
    created_at: Date.now(),
  });
  merchants.m_rest = {
    owner_uid: "owner_1",
    business_type: "restaurant",
    merchant_status: "approved",
  };
  fleet.setFirestoreForTests(createMockFirestore(merchants));
  try {
    const res = await fleet.dispatchFleetGetMyAccount({}, { auth: { uid: "owner_1" } }, db);
    assert.equal(res.success, false);
    assert.equal(res.reason, "not_found");
  } finally {
    fleet.setFirestoreForTests(null);
  }
});

test("random user cannot read another fleet account", async () => {
  const db = createMockDb();
  fleet.setFirestoreForTests(createMockFirestore({}));
  try {
    const res = await fleet.dispatchFleetGetMyAccount({}, { auth: { uid: "random_user" } }, db);
    assert.equal(res.success, false);
    assert.equal(res.reason, "not_found");
  } finally {
    fleet.setFirestoreForTests(null);
  }
});

test("invite blocked when fleet suspended", async () => {
  const db = createMockDb();
  const merchants = {};
  seedFleetAccount(db, merchants, "owner_1", "biz_suspended", {
    ...APPROVED_FLEET_MERCHANT,
    merchant_status: "suspended",
    required_documents_complete: true,
  });
  fleet.setFirestoreForTests(createMockFirestore(merchants));
  try {
    const res = await fleet.businessCreateDriverInvite(
      { dispatch_vehicle_type: "bike" },
      { auth: { uid: "owner_1" } },
      db,
    );
    assert.equal(res.success, false);
    assert.equal(res.reason, "fleet_suspended");
  } finally {
    fleet.setFirestoreForTests(null);
  }
});

test("invite blocked when approved but documents incomplete", async () => {
  const db = createMockDb();
  const merchants = {};
  seedFleetAccount(db, merchants, "owner_1", "biz_partial", {
    ...APPROVED_FLEET_MERCHANT,
    required_documents_complete: false,
  });
  fleet.setFirestoreForTests(createMockFirestore(merchants));
  try {
    const res = await fleet.businessCreateDriverInvite(
      { dispatch_vehicle_type: "bike" },
      { auth: { uid: "owner_1" } },
      db,
    );
    assert.equal(res.success, false);
    assert.equal(res.reason, "fleet_not_approved");
  } finally {
    fleet.setFirestoreForTests(null);
  }
});

test("invite blocked when pending_review", async () => {
  const db = createMockDb();
  const merchants = {};
  seedFleetAccount(db, merchants, "owner_1", "biz_pending", {
    ...APPROVED_FLEET_MERCHANT,
    merchant_status: "pending_review",
    verification_status: "pending_review",
  });
  fleet.setFirestoreForTests(createMockFirestore(merchants));
  try {
    const res = await fleet.businessCreateDriverInvite(
      { dispatch_vehicle_type: "bike" },
      { auth: { uid: "owner_1" } },
      db,
    );
    assert.equal(res.success, false);
    assert.equal(res.reason, "fleet_not_approved");
  } finally {
    fleet.setFirestoreForTests(null);
  }
});

test("non-fleet merchant cannot create fleet driver invite", async () => {
  const db = createMockDb();
  const merchants = {};
  seedFleetOwnerIndex(db, "owner_1", "biz_commerce", {
    business_id: "biz_commerce",
    account_kind: "dispatch_fleet",
    status: "approved",
    created_at: Date.now(),
  });
  merchants.biz_commerce = {
    owner_uid: "owner_1",
    business_type: "restaurant",
    merchant_status: "approved",
    verification_status: "approved",
  };
  fleet.setFirestoreForTests(createMockFirestore(merchants));
  try {
    const res = await fleet.businessCreateDriverInvite(
      { dispatch_vehicle_type: "bike" },
      { auth: { uid: "owner_1" } },
      db,
    );
    assert.equal(res.success, false);
    assert.equal(res.reason, "not_found");
  } finally {
    fleet.setFirestoreForTests(null);
  }
});

test("invite create/redeem happy path", async () => {
  const db = createMockDb();
  const merchants = {};
  seedFleetAccount(db, merchants, "owner_1", "biz_1", { ...APPROVED_FLEET_MERCHANT });
  fleet.setFirestoreForTests(createMockFirestore(merchants));
  let createRes;
  try {
    createRes = await fleet.businessCreateDriverInvite(
      { dispatch_vehicle_type: "bike" },
      { auth: { uid: "owner_1" } },
      db,
    );
  } finally {
    fleet.setFirestoreForTests(null);
  }
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
  const merchants = {};
  seedFleetAccount(db, merchants, "owner_1", "biz_1", { ...APPROVED_FLEET_MERCHANT });
  fleet.setFirestoreForTests(createMockFirestore(merchants));
  try {
    const res = await fleet.businessCreateDriverInvite(
      { dispatch_vehicle_type: "truck" },
      { auth: { uid: "owner_1" } },
      db,
    );
    assert.equal(res.success, false);
    assert.equal(res.reason, "invalid_dispatch_vehicle_type");
  } finally {
    fleet.setFirestoreForTests(null);
  }
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

test("invite creation without fleet owner index blocked", async () => {
  const db = createMockDb();
  fleet.setFirestoreForTests(createMockFirestore({}));
  try {
    const res = await fleet.businessCreateDriverInvite(
      { dispatch_vehicle_type: "bike" },
      { auth: { uid: "random_user" } },
      db,
    );
    assert.equal(res.success, false);
    assert.equal(res.reason, "not_found");
  } finally {
    fleet.setFirestoreForTests(null);
  }
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

function createFleetAdminMockFirestore(store = {}, verificationDocs = {}) {
  function sortEntries(entries, orderFields) {
    return [...entries].sort((a, b) => {
      for (const { field, dir } of orderFields) {
        let av;
        let bv;
        if (field === "__name__") {
          av = a.id;
          bv = b.id;
        } else if (field === "created_at") {
          av = Number(a.created_at) || 0;
          bv = Number(b.created_at) || 0;
        } else {
          av = a[field];
          bv = b[field];
        }
        if (av < bv) {
          return dir === "desc" ? 1 : -1;
        }
        if (av > bv) {
          return dir === "desc" ? -1 : 1;
        }
      }
      return 0;
    });
  }

  function applyStartAfter(entries, startAfterValues) {
    if (!startAfterValues || startAfterValues.length < 2) {
      return entries;
    }
    const t = startAfterValues[0];
    const cursorMs = t && typeof t.toMillis === "function" ? t.toMillis() : Number(t) || 0;
    const cursorId = String(startAfterValues[1] || "");
    return entries.filter((e) => {
      const ms = Number(e.created_at) || 0;
      if (ms < cursorMs) {
        return true;
      }
      if (ms > cursorMs) {
        return false;
      }
      return e.id < cursorId;
    });
  }

  function makeQuery(filters, orderFields = [], startAfterValues = null) {
    return {
      where(field, op, value) {
        return makeQuery([...filters, { field, op, value }], orderFields, startAfterValues);
      },
      orderBy(field, dir = "asc") {
        const f =
          field && typeof field === "object" && String(field).includes("FieldPath")
            ? "__name__"
            : field;
        return makeQuery(filters, [...orderFields, { field: f, dir }], startAfterValues);
      },
      startAfter(...values) {
        return makeQuery(filters, orderFields, values);
      },
      limit(n) {
        return {
          async get() {
            let entries = Object.entries(store).map(([id, row]) => ({ id, ...row }));
            for (const f of filters) {
              entries = entries.filter((e) => f.op === "==" && e[f.field] === f.value);
            }
            entries = sortEntries(entries, orderFields);
            entries = applyStartAfter(entries, startAfterValues);
            const docs = entries.slice(0, n).map((e) => {
              const { id, ...data } = e;
              return { id, data: () => data };
            });
            return { docs, empty: docs.length === 0 };
          },
        };
      },
    };
  }

  return {
    collection(name) {
      if (name === "merchant_verification_documents") {
        return {
          doc(merchantId) {
            return {
              collection(subName) {
                if (subName !== "documents") {
                  throw new Error(`unexpected subcollection: ${subName}`);
                }
                return {
                  doc(type) {
                    const key = `${merchantId}/${type}`;
                    return {
                      id: type,
                      async get() {
                        const data = verificationDocs[key];
                        return { exists: data != null, id: type, data: () => data };
                      },
                      async set(data) {
                        verificationDocs[key] = { ...(data || {}) };
                      },
                    };
                  },
                  async get() {
                    const prefix = `${merchantId}/`;
                    const docs = Object.entries(verificationDocs)
                      .filter(([k]) => k.startsWith(prefix))
                      .map(([k, data]) => {
                        const type = k.slice(prefix.length);
                        return { id: type, data: () => data };
                      });
                    return { docs, empty: docs.length === 0 };
                  },
                };
              },
            };
          },
        };
      }
      if (name !== "merchants") {
        throw new Error(`unexpected collection: ${name}`);
      }
      const queryApi = makeQuery([]);
      return {
        ...queryApi,
        doc(id) {
          return {
            id,
            async get() {
              const data = store[id];
              return { exists: data != null, id, data: () => data };
            },
            async update(patch) {
              store[id] = { ...(store[id] || {}), ...(patch || {}) };
            },
            async set(data) {
              store[id] = { ...(data || {}) };
            },
          };
        },
      };
    },
    _store: store,
    _verificationDocs: verificationDocs,
  };
}

function seedApprovedCacFleetDocs(verificationDocs, merchantId) {
  for (const type of fleetVerification.CAC_REQUIRED_TYPES) {
    verificationDocs[`${merchantId}/${type}`] = {
      status: "approved",
      storage_path: `fleet_verification_uploads/${merchantId}/${type}/file.pdf`,
    };
  }
}

function adminRtdb() {
  return createMockDb({
    "admins/admin_1": { enabled: true, admin_role: "super_admin" },
  });
}

function adminContext() {
  return { auth: { uid: "admin_1", token: { admin: true, admin_role: "super_admin" } } };
}

function auditLogsFromDb(db) {
  return Object.entries(db._store)
    .filter(([k]) => k.startsWith("admin_audit_logs/"))
    .map(([, v]) => v);
}

test("adminListDispatchFleetPage returns only dispatch_fleet accounts", async () => {
  const merchants = {
    fleet_pending: {
      account_kind: "dispatch_fleet",
      merchant_status: "pending_review",
      business_name: "Pending Fleet",
      created_at: 1000,
    },
    fleet_approved: {
      account_kind: "dispatch_fleet",
      merchant_status: "approved",
      business_name: "Approved Fleet",
      created_at: 3000,
    },
    restaurant_1: {
      account_kind: "restaurant",
      merchant_status: "pending_review",
      business_name: "Restaurant",
      created_at: 9000,
    },
  };
  fleet.setFirestoreForTests(createFleetAdminMockFirestore(merchants));
  const res = await fleet.adminListDispatchFleetPage(
    { status: "all", limit: 10 },
    adminContext(),
    adminRtdb(),
  );
  assert.equal(res.success, true);
  assert.equal(res.accounts.length, 2);
  assert.equal(res.accounts[0].business_name, "Approved Fleet");
  assert.equal(res.accounts[1].business_name, "Pending Fleet");
});

test("adminGetDispatchFleetAccount rejects non-fleet merchant", async () => {
  const merchants = {
    biz_rest: {
      account_kind: "restaurant",
      merchant_status: "pending_review",
      business_name: "Restaurant",
      created_at: 1000,
    },
  };
  fleet.setFirestoreForTests(createFleetAdminMockFirestore(merchants));
  const res = await fleet.adminGetDispatchFleetAccount(
    { business_id: "biz_rest" },
    adminContext(),
    adminRtdb(),
  );
  assert.equal(res.success, false);
  assert.equal(res.reason, "not_dispatch_fleet");
});

test("adminReviewDispatchFleet approve blocked without complete documents", async () => {
  const merchants = {
    fleet_1: {
      account_kind: "dispatch_fleet",
      merchant_status: "pending_review",
      verification_status: "pending_review",
      verification_type: "cac_business",
      required_documents_complete: false,
      owner_uid: "owner_1",
      business_name: "Fleet Co",
      created_at: 1000,
    },
  };
  const verificationDocs = {};
  const fs = createFleetAdminMockFirestore(merchants, verificationDocs);
  fleet.setFirestoreForTests(fs);
  fleetVerification.setFirestoreForTests(fs);
  const db = adminRtdb();
  try {
    const res = await fleet.adminReviewDispatchFleet(
      { business_id: "fleet_1", action: "approve", note: "verified" },
      adminContext(),
      db,
    );
    assert.equal(res.success, false);
    assert.equal(res.reason, "fleet_documents_incomplete");
  } finally {
    fleet.setFirestoreForTests(null);
    fleetVerification.setFirestoreForTests(null);
  }
});

test("adminReviewDispatchFleet approve updates statuses and audit", async () => {
  const merchants = {
    fleet_1: {
      account_kind: "dispatch_fleet",
      merchant_status: "pending_review",
      verification_status: "docs_complete",
      verification_type: "cac_business",
      required_documents_complete: true,
      owner_uid: "owner_1",
      business_name: "Fleet Co",
      created_at: 1000,
    },
  };
  const verificationDocs = {};
  seedApprovedCacFleetDocs(verificationDocs, "fleet_1");
  const fs = createFleetAdminMockFirestore(merchants, verificationDocs);
  const db = adminRtdb();
  seedFleetOwnerIndex(db, "owner_1", "fleet_1", { status: "pending_review" });
  fleet.setFirestoreForTests(fs);
  fleetVerification.setFirestoreForTests(fs);
  try {
    const res = await fleet.adminReviewDispatchFleet(
      { business_id: "fleet_1", action: "approve", note: "verified" },
      adminContext(),
      db,
    );
    assert.equal(res.success, true);
    assert.equal(res.merchant_status, "approved");
    assert.equal(res.verification_status, "approved");
    assert.equal(merchants.fleet_1.merchant_status, "approved");
    assert.equal(merchants.fleet_1.verification_status, "approved");
    const audits = auditLogsFromDb(db);
    assert.ok(audits.some((row) => row.type === "DISPATCH_FLEET_REVIEWED"));
  } finally {
    fleet.setFirestoreForTests(null);
    fleetVerification.setFirestoreForTests(null);
  }
});

test("adminReviewDispatchFleet reject stores rejection reason", async () => {
  const merchants = {
    fleet_2: {
      account_kind: "dispatch_fleet",
      merchant_status: "pending_review",
      verification_status: "pending_review",
      business_name: "Fleet Two",
      created_at: 2000,
    },
  };
  const db = adminRtdb();
  fleet.setFirestoreForTests(createFleetAdminMockFirestore(merchants));
  const res = await fleet.adminReviewDispatchFleet(
    {
      business_id: "fleet_2",
      action: "reject",
      note: "Incomplete business details",
    },
    adminContext(),
    db,
  );
  assert.equal(res.success, true);
  assert.equal(res.merchant_status, "rejected");
  assert.equal(merchants.fleet_2.rejection_reason, "Incomplete business details");
  assert.equal(merchants.fleet_2.verification_status, "rejected");
});
