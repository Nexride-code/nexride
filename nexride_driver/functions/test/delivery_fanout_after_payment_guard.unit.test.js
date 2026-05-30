const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  fanOutDeliveryOffersAfterVerifiedPayment,
  tryAcquireDeliveryVerifiedPaymentFanoutLease,
  fanOutDeliveryOffersIfEligible,
  deliveryFanoutLeaseIsStale,
  DELIVERY_FANOUT_AFTER_PAYMENT_IN_PROGRESS_AT_FIELD,
  DELIVERY_FANOUT_AFTER_PAYMENT_COMPLETED_AT_FIELD,
  DELIVERY_FANOUT_AFTER_PAYMENT_LEASE_MS,
} = require("../delivery_callables");

const deliveryId = "del_fanout_guard_1";
const customerId = "cust_fanout_1";
const idleDriver = "drv_fanout_idle";
const deliveryPath = `delivery_requests/${deliveryId}`;
const matchDebugPath = `delivery_requests/${deliveryId}/match_debug`;
const now = Date.now();

const verifiedRow = {
  customer_id: customerId,
  market: "lagos",
  market_pool: "lagos",
  pickup: { lat: 6.5244, lng: 3.3792, address: "Pickup" },
  dropoff: { lat: 6.53, lng: 3.38, address: "Dropoff" },
  delivery_state: "searching",
  payment_method: "flutterwave",
  payment_status: "verified",
  payment_transaction_id: "flw_fanout_ok",
};

const driverProfile = {
  dispatch_market: "lagos",
  active_services: ["dispatch_delivery"],
  nexride_verified: true,
  isOnline: true,
  last_active_at: now,
};

function makeFanoutGuardDb(initialRow = verifiedRow, options = {}) {
  const store = { [deliveryPath]: { ...initialRow } };
  const state = {
    offerWrites: [],
    expiryUpdates: [],
    transactionCalls: 0,
    failMatchDebugSet: options.failMatchDebugSet === true,
  };
  let txChain = Promise.resolve();

  const enqueueTx = (fn) => {
    const run = txChain.then(fn);
    txChain = run.catch(() => {});
    return run;
  };

  function getVal(path) {
    return Object.prototype.hasOwnProperty.call(store, path) ? store[path] : null;
  }

  function ref(path) {
    const p = path == null || path === "" ? "" : String(path);
    const node = {
      child(sub) {
        return ref(`${p}/${sub}`);
      },
      async get() {
        const val = getVal(p);
        return {
          val: () =>
            val == null ? null : typeof val === "object" ? { ...val } : val,
          exists: () => val != null,
        };
      },
      async set(v) {
        if (state.failMatchDebugSet && p === matchDebugPath) {
          throw new Error("match_debug_set_failed");
        }
        store[p] = v;
      },
      async update(patch) {
        if (p === deliveryPath) {
          state.expiryUpdates.push(patch);
        }
        const cur = getVal(p);
        store[p] = {
          ...(cur && typeof cur === "object" ? cur : {}),
          ...patch,
        };
      },
      async transaction(updateFn) {
        return enqueueTx(async () => {
          state.transactionCalls += 1;
          const cur = getVal(p);
          const next = updateFn(cur ? { ...cur } : null);
          if (next === undefined) {
            return { committed: false, snapshot: { val: () => cur } };
          }
          store[p] = next;
          return { committed: true, snapshot: { val: () => ({ ...next }) } };
        });
      },
    };

    if (p === "drivers") {
      node.orderByChild = () => ({
        equalTo: (market) => ({
          get: async () => {
            if (options.noDrivers) {
              return { val: () => null };
            }
            const out = {};
            for (const [key, val] of Object.entries(store)) {
              if (!key.startsWith("drivers/")) continue;
              const id = key.slice("drivers/".length);
              if (val?.dispatch_market === market) out[id] = val;
            }
            return { val: () => (Object.keys(out).length ? out : null) };
          },
        }),
      });
    }

    if (p === "") {
      node.update = async (payload) => {
        for (const [key, val] of Object.entries(payload || {})) {
          if (key.startsWith("delivery_offer_queue/")) {
            state.offerWrites.push(key);
          }
          if (val === null) delete store[key];
          else store[key] = val;
        }
      };
    }

    return node;
  }

  if (!options.noDrivers) {
    store[`drivers/${idleDriver}`] = driverProfile;
  }
  return { ref, store, state };
}

test("deliveryFanoutLeaseIsStale respects 60s lease", () => {
  assert.equal(deliveryFanoutLeaseIsStale(0, now), true);
  assert.equal(
    deliveryFanoutLeaseIsStale(now - DELIVERY_FANOUT_AFTER_PAYMENT_LEASE_MS, now),
    true,
  );
  assert.equal(
    deliveryFanoutLeaseIsStale(now - DELIVERY_FANOUT_AFTER_PAYMENT_LEASE_MS + 1000, now),
    false,
  );
});

test("first verified fanout sets lease then completed_at and writes offers", async () => {
  const db = makeFanoutGuardDb();
  const result = await fanOutDeliveryOffersAfterVerifiedPayment(
    db,
    deliveryId,
    verifiedRow,
  );
  assert.equal(result.skipped, false);
  assert.equal(result.reason, "fanout_done");
  assert.equal(
    db.state.offerWrites.some(
      (p) => p === `delivery_offer_queue/${idleDriver}/${deliveryId}`,
    ),
    true,
  );
  assert.ok(
    Number(db.store[deliveryPath][DELIVERY_FANOUT_AFTER_PAYMENT_COMPLETED_AT_FIELD]) > 0,
  );
  assert.equal(
    db.store[deliveryPath][DELIVERY_FANOUT_AFTER_PAYMENT_IN_PROGRESS_AT_FIELD],
    undefined,
  );
});

test("second verified fanout skips because completed_at exists", async () => {
  const db = makeFanoutGuardDb({
    ...verifiedRow,
    [DELIVERY_FANOUT_AFTER_PAYMENT_COMPLETED_AT_FIELD]: now - 60_000,
  });
  const result = await fanOutDeliveryOffersAfterVerifiedPayment(
    db,
    deliveryId,
    verifiedRow,
  );
  assert.equal(result.skipped, true);
  assert.equal(result.reason, "fanout_completed");
  assert.equal(db.state.offerWrites.length, 0);
  assert.equal(db.state.expiryUpdates.length, 0);
});

test("concurrent fanout attempts only one writes offers", async () => {
  const db = makeFanoutGuardDb();
  const results = await Promise.all([
    fanOutDeliveryOffersAfterVerifiedPayment(db, deliveryId, verifiedRow),
    fanOutDeliveryOffersAfterVerifiedPayment(db, deliveryId, verifiedRow),
  ]);
  const done = results.filter((r) => r.reason === "fanout_done");
  const skipped = results.filter(
    (r) => r.reason === "fanout_completed" || r.reason === "fanout_in_progress",
  );
  assert.equal(done.length, 1);
  assert.equal(skipped.length, 1);
  assert.equal(db.state.offerWrites.length, 1);
});

test("stale in_progress allows retry", async () => {
  const staleAt = now - DELIVERY_FANOUT_AFTER_PAYMENT_LEASE_MS - 1000;
  const db = makeFanoutGuardDb({
    ...verifiedRow,
    [DELIVERY_FANOUT_AFTER_PAYMENT_IN_PROGRESS_AT_FIELD]: staleAt,
  });
  const result = await fanOutDeliveryOffersAfterVerifiedPayment(
    db,
    deliveryId,
    verifiedRow,
  );
  assert.equal(result.reason, "fanout_done");
  assert.ok(
    Number(db.store[deliveryPath][DELIVERY_FANOUT_AFTER_PAYMENT_COMPLETED_AT_FIELD]) > 0,
  );
});

test("active fresh in_progress blocks duplicate", async () => {
  const db = makeFanoutGuardDb({
    ...verifiedRow,
    [DELIVERY_FANOUT_AFTER_PAYMENT_IN_PROGRESS_AT_FIELD]: now - 5000,
  });
  const acquire = await tryAcquireDeliveryVerifiedPaymentFanoutLease(
    db,
    deliveryId,
    { now },
  );
  assert.equal(acquire.acquired, false);
  assert.equal(acquire.reason, "fanout_in_progress");
});

test("fanout throw does not set completed_at", async () => {
  const db = makeFanoutGuardDb(verifiedRow, { failMatchDebugSet: true });
  await assert.rejects(
    () => fanOutDeliveryOffersAfterVerifiedPayment(db, deliveryId, verifiedRow),
    /match_debug_set_failed/,
  );
  assert.equal(
    db.store[deliveryPath][DELIVERY_FANOUT_AFTER_PAYMENT_COMPLETED_AT_FIELD],
    undefined,
  );
});

test("fanout throw clears in_progress if possible", async () => {
  const db = makeFanoutGuardDb(verifiedRow, { failMatchDebugSet: true });
  await assert.rejects(
    () => fanOutDeliveryOffersAfterVerifiedPayment(db, deliveryId, verifiedRow),
    /match_debug_set_failed/,
  );
  assert.equal(
    db.store[deliveryPath][DELIVERY_FANOUT_AFTER_PAYMENT_IN_PROGRESS_AT_FIELD],
    undefined,
  );
});

test("unverified payment sets no markers", async () => {
  const db = makeFanoutGuardDb({
    ...verifiedRow,
    payment_status: "pending",
    payment_transaction_id: "",
  });
  const acquire = await tryAcquireDeliveryVerifiedPaymentFanoutLease(db, deliveryId);
  assert.equal(acquire.acquired, false);
  assert.equal(acquire.reason, "payment_not_verified");
  await fanOutDeliveryOffersIfEligible(db, deliveryId, {
    ...verifiedRow,
    payment_status: "pending",
    payment_transaction_id: "",
  });
  assert.equal(db.state.offerWrites.length, 0);
  assert.equal(
    db.store[deliveryPath][DELIVERY_FANOUT_AFTER_PAYMENT_COMPLETED_AT_FIELD],
    undefined,
  );
  assert.equal(
    db.store[deliveryPath][DELIVERY_FANOUT_AFTER_PAYMENT_IN_PROGRESS_AT_FIELD],
    undefined,
  );
});

test("zero eligible drivers sets completed_at and match_debug no_eligible_drivers", async () => {
  const db = makeFanoutGuardDb(verifiedRow, { noDrivers: true });
  const result = await fanOutDeliveryOffersAfterVerifiedPayment(
    db,
    deliveryId,
    verifiedRow,
  );
  assert.equal(result.reason, "fanout_done");
  assert.equal(db.state.offerWrites.length, 0);
  assert.ok(
    Number(db.store[deliveryPath][DELIVERY_FANOUT_AFTER_PAYMENT_COMPLETED_AT_FIELD]) > 0,
  );
  assert.equal(db.store[matchDebugPath].offer_delivery_status, "no_eligible_drivers");
});

test("webhook after callable verify does not duplicate offers", async () => {
  const db = makeFanoutGuardDb();
  await fanOutDeliveryOffersAfterVerifiedPayment(db, deliveryId, verifiedRow);
  const second = await fanOutDeliveryOffersAfterVerifiedPayment(
    db,
    deliveryId,
    verifiedRow,
  );
  assert.equal(second.reason, "fanout_completed");
  assert.equal(db.state.offerWrites.length, 1);
});
