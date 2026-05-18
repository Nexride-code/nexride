const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  createOfferLease,
  validateLeaseForAccept,
  finalizeLeasesOnAccept,
  LEASE_STATUS,
} = require("../dispatch_engine/dispatch_offer_lease_engine");

function mockDb(initial = {}) {
  const store = JSON.parse(JSON.stringify(initial));
  const apply = (path, value) => {
    const parts = path.split("/").filter(Boolean);
    if (value === null) {
      let cur = store;
      for (let i = 0; i < parts.length - 1; i++) {
        if (!cur[parts[i]]) return;
        cur = cur[parts[i]];
      }
      delete cur[parts[parts.length - 1]];
      return;
    }
    let cur = store;
    for (let i = 0; i < parts.length - 1; i++) {
      const p = parts[i];
      if (!cur[p] || typeof cur[p] !== "object") cur[p] = {};
      cur = cur[p];
    }
    cur[parts[parts.length - 1]] = value;
  };
  const ref = (path) => {
    const parts = path ? String(path).split("/").filter(Boolean) : [];
    return {
      get: async () => {
        let cur = store;
        for (const p of parts) {
          if (cur == null) break;
          cur = cur[p];
        }
        return { exists: () => cur != null, val: () => cur };
      },
      child: (p) => ref(parts.concat(String(p)).join("/")),
      update: async (patch) => {
        for (const [k, v] of Object.entries(patch)) {
          apply(k, v);
        }
      },
      set: async (v) => apply(parts.join("/"), v),
    };
  };
  return {
    ref: (p) => {
      if (!p) {
        return {
          update: async (u) => {
            for (const [k, v] of Object.entries(u)) apply(k, v);
          },
        };
      }
      return ref(p);
    },
    _store: store,
  };
}

test("createOfferLease writes lease paths and queue fields", async () => {
  const db = mockDb({
    ride_requests: { ride1: { match_debug: { fanout_batch_number: 1 } } },
    app_config: {
      nexride_dispatch: { driver_offer_lease_ms: 8000 },
    },
  });
  const res = await createOfferLease(db, {
    rideId: "ride1",
    driverId: "d1",
    offerPayload: { ride_id: "ride1", fare: 1000 },
    offerAttempt: 2,
    popupGeneration: 3,
  });
  assert.equal(res.ok, true);
  assert.ok(res.leaseId);
  assert.equal(res.queuePayload.lease_id, res.leaseId);
  assert.equal(res.queuePayload.popup_generation, 3);
  assert.ok(db._store.driver_offer_leases.d1[res.leaseId]);
  assert.equal(db._store.drivers.d1.active_offer_trip_id, "ride1");
});

test("validateLeaseForAccept rejects expired lease", () => {
  const now = Date.now();
  const lease = {
    lease_id: "l1",
    ride_id: "ride1",
    driver_id: "d1",
    lease_status: LEASE_STATUS.OFFERED,
    lease_expires_at: now - 1000,
  };
  const v = validateLeaseForAccept(lease, "ride1", "d1", now);
  assert.equal(v.valid, false);
  assert.equal(v.reason, "lease_expired");
});

test("finalizeLeasesOnAccept cancels competing leases", async () => {
  const db = mockDb({
    ride_requests: {
      ride1: {
        offer_leases: {
          l1: { driver_id: "d1", ride_id: "ride1", lease_status: LEASE_STATUS.OFFERED },
          l2: { driver_id: "d2", ride_id: "ride1", lease_status: LEASE_STATUS.OFFERED },
        },
      },
    },
    driver_offer_leases: {
      d1: { l1: { driver_id: "d1", ride_id: "ride1", lease_status: LEASE_STATUS.OFFERED } },
      d2: { l2: { driver_id: "d2", ride_id: "ride1", lease_status: LEASE_STATUS.OFFERED } },
    },
    driver_offer_queue: {
      d1: { ride1: {} },
      d2: { ride1: {} },
    },
  });
  const r = await finalizeLeasesOnAccept(db, "ride1", "d1", "l1");
  assert.equal(r.cancelled, 1);
  assert.equal(
    db._store.ride_requests.ride1.offer_leases.l1.lease_status,
    LEASE_STATUS.ACCEPTED,
  );
  assert.equal(
    db._store.ride_requests.ride1.offer_leases.l2.lease_status,
    LEASE_STATUS.CANCELLED,
  );
  assert.equal(db._store.driver_offer_queue.d2.ride1, undefined);
});
