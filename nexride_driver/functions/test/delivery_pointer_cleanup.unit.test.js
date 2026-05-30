const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  clearDeliveryActivePointers,
  cancelDeliveryRequest,
  expireDeliveryRequest,
  updateDeliveryState,
  DELIVERY_STATE,
} = require("../delivery_callables");
const { adminCancelTrip } = require("../admin_callables");

const deliveryId = "del_ptr_cleanup_1";
const customerId = "cust_ptr_cleanup_1";
const driverId = "drv_ptr_cleanup_1";
const merchantId = "merch_ptr_cleanup_1";
const deliveryPath = `delivery_requests/${deliveryId}`;

const pickup = { lat: 6.5244, lng: 3.3792, address: "Pickup" };
const dropoff = { lat: 6.53, lng: 3.38, address: "Dropoff" };

const verifiedPayment = {
  payment_method: "flutterwave",
  payment_status: "verified",
  payment_transaction_id: "flw_ptr_cleanup",
};

function pointerPaths(ids = {}) {
  const rid = ids.deliveryId ?? deliveryId;
  const c = ids.customerId ?? customerId;
  const d = ids.driverId ?? driverId;
  const m = ids.merchantId ?? merchantId;
  return {
    activeDelivery: `active_deliveries/${rid}`,
    userActive: `user_active_delivery/${c}`,
    customerActive: `customer_active_delivery/${c}`,
    driverActive: `driver_active_delivery/${d}`,
    merchantActive: `merchant_active_delivery/${m}`,
  };
}

function seedAssignedPointers(store, ids = {}) {
  const paths = pointerPaths(ids);
  store[paths.activeDelivery] = {
    delivery_id: ids.deliveryId ?? deliveryId,
    customer_id: ids.customerId ?? customerId,
    driver_id: ids.driverId ?? driverId,
    delivery_state: DELIVERY_STATE.driver_assigned,
  };
  store[paths.userActive] = {
    delivery_id: ids.deliveryId ?? deliveryId,
    phase: "active",
  };
  store[paths.customerActive] = {
    delivery_id: ids.deliveryId ?? deliveryId,
    phase: "active",
  };
  store[paths.driverActive] = {
    delivery_id: ids.deliveryId ?? deliveryId,
  };
  store[paths.merchantActive] = {
    delivery_id: ids.deliveryId ?? deliveryId,
  };
  return paths;
}

function makePointerCleanupDb(initialStore = {}) {
  const store = { ...initialStore };
  const state = { batchUpdates: [], removes: [] };

  function ref(path) {
    const p = path == null || path === "" ? "" : String(path);
    const node = {
      child(sub) {
        return ref(`${p}/${sub}`);
      },
      push() {
        const key = `push_${state.batchUpdates.length}`;
        return {
          key,
          set: async (v) => {
            store[`${p}/${key}`] = v;
          },
        };
      },
      async get() {
        const val = Object.prototype.hasOwnProperty.call(store, p) ? store[p] : null;
        return {
          val: () =>
            val == null ? null : typeof val === "object" ? { ...val } : val,
          exists: () => val != null,
        };
      },
      async set(v) {
        store[p] = v;
      },
      async update(patch) {
        if (p === "") {
          state.batchUpdates.push(patch);
          for (const [key, val] of Object.entries(patch || {})) {
            if (val === null) delete store[key];
            else store[key] = val;
          }
          return;
        }
        const cur = store[p];
        store[p] = {
          ...(cur && typeof cur === "object" ? cur : {}),
          ...patch,
        };
      },
      async remove() {
        state.removes.push(p);
        delete store[p];
      },
    };

    if (p === "") {
      node.update = async (payload) => {
        state.batchUpdates.push(payload);
        for (const [key, val] of Object.entries(payload || {})) {
          if (val === null) delete store[key];
          else store[key] = val;
        }
      };
    }

    if (p.startsWith("delivery_offer_fanout/")) {
      node.get = async () => ({ val: () => null, exists: () => false });
    }

    return node;
  }

  return { ref, store, state };
}

function assertPointersCleared(store, ids = {}) {
  const paths = pointerPaths(ids);
  for (const path of Object.values(paths)) {
    assert.equal(store[path], undefined, `expected cleared: ${path}`);
  }
}

function assertLastBatchClearsAllPointers(state, ids = {}) {
  const paths = pointerPaths(ids);
  const last = state.batchUpdates[state.batchUpdates.length - 1];
  assert.ok(last, "expected pointer cleanup batch update");
  for (const path of Object.values(paths)) {
    assert.equal(last[path], null, `expected null in batch: ${path}`);
  }
}

test("clearDeliveryActivePointers clears all known delivery pointers", async () => {
  const db = makePointerCleanupDb();
  seedAssignedPointers(db.store);

  const result = await clearDeliveryActivePointers(db, {
    deliveryId,
    customerId,
    driverId,
    merchantId,
  });

  assert.equal(result.cleared, 5);
  assertPointersCleared(db.store);
});

test("cancel after accept clears all pointers including customer and merchant", async () => {
  const row = {
    customer_id: customerId,
    merchant_id: merchantId,
    delivery_state: DELIVERY_STATE.driver_assigned,
    driver_id: driverId,
    matched_driver_id: driverId,
    pickup,
    dropoff,
    ...verifiedPayment,
  };
  const db = makePointerCleanupDb({ [deliveryPath]: row });
  seedAssignedPointers(db.store);

  const res = await cancelDeliveryRequest(
    { deliveryId },
    { auth: { uid: customerId } },
    db,
  );

  assert.equal(res.success, true);
  assertPointersCleared(db.store);
});

test("expire searching clears user_active_delivery and defensive assignment pointers", async () => {
  const row = {
    customer_id: customerId,
    merchant_id: merchantId,
    delivery_state: DELIVERY_STATE.searching,
    pickup,
    dropoff,
    ...verifiedPayment,
  };
  const db = makePointerCleanupDb({ [deliveryPath]: row });
  seedAssignedPointers(db.store);
  db.store[pointerPaths().userActive] = {
    delivery_id: deliveryId,
    phase: "searching",
  };

  const res = await expireDeliveryRequest({ deliveryId }, { auth: { uid: customerId } }, db);

  assert.equal(res.success, true);
  assert.equal(res.reason, "expired");
  assertPointersCleared(db.store);
});

test("updateDeliveryState completed clears all pointers", async () => {
  const row = {
    customer_id: customerId,
    merchant_id: merchantId,
    delivery_state: DELIVERY_STATE.arrived_dropoff,
    driver_id: driverId,
    matched_driver_id: driverId,
    pickup,
    dropoff,
    ...verifiedPayment,
  };
  const db = makePointerCleanupDb({ [deliveryPath]: row });
  seedAssignedPointers(db.store);

  const res = await updateDeliveryState(
    {
      deliveryId,
      delivery_state: DELIVERY_STATE.completed,
      driver_lat: dropoff.lat,
      driver_lng: dropoff.lng,
    },
    { auth: { uid: driverId } },
    db,
  );

  assert.equal(res.success, true);
  assert.equal(res.delivery_state, DELIVERY_STATE.completed);
  assertPointersCleared(db.store);
});

test("updateDeliveryState cancelled clears all pointers", async () => {
  const row = {
    customer_id: customerId,
    merchant_id: merchantId,
    delivery_state: DELIVERY_STATE.driver_assigned,
    driver_id: driverId,
    matched_driver_id: driverId,
    pickup,
    dropoff,
    ...verifiedPayment,
  };
  const db = makePointerCleanupDb({ [deliveryPath]: row });
  seedAssignedPointers(db.store);

  const res = await updateDeliveryState(
    { deliveryId, delivery_state: DELIVERY_STATE.cancelled },
    { auth: { uid: driverId } },
    db,
  );

  assert.equal(res.success, true);
  assert.equal(res.delivery_state, DELIVERY_STATE.cancelled);
  assertPointersCleared(db.store);
});

test("admin delivery cancel clears all pointers", async () => {
  const row = {
    customer_id: customerId,
    merchant_id: merchantId,
    delivery_state: DELIVERY_STATE.picked_up,
    driver_id: driverId,
    matched_driver_id: driverId,
    pickup,
    dropoff,
    ...verifiedPayment,
  };
  const db = makePointerCleanupDb({ [deliveryPath]: row });
  seedAssignedPointers(db.store);

  const res = await adminCancelTrip(
    { tripId: deliveryId, kind: "delivery", note: "admin cleanup pointer test" },
    { auth: { uid: "admin_ptr_1", token: { admin: true, admin_role: "super_admin" } } },
    db,
  );

  assert.equal(res.success, true);
  assert.equal(res.trip_kind, "delivery");
  assertPointersCleared(db.store);
});

test("merchant delivery cancel clears merchant_active_delivery", async () => {
  const row = {
    customer_id: customerId,
    merchant_id: merchantId,
    delivery_state: DELIVERY_STATE.on_delivery,
    driver_id: driverId,
    matched_driver_id: driverId,
    pickup,
    dropoff,
    category: "food",
    ...verifiedPayment,
  };
  const db = makePointerCleanupDb({ [deliveryPath]: row });
  const paths = seedAssignedPointers(db.store);

  const res = await cancelDeliveryRequest(
    { deliveryId },
    { auth: { uid: driverId } },
    db,
  );

  assert.equal(res.success, true);
  assert.equal(db.store[paths.merchantActive], undefined);
  assertLastBatchClearsAllPointers(db.state, {
    deliveryId,
    customerId,
    driverId,
    merchantId,
  });
});
