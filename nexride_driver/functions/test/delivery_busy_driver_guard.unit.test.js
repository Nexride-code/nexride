const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  resolveDeliveryBusyGuardForDriver,
  fanOutDeliveryOffersIfEligible,
  acceptDeliveryRequest,
  DELIVERY_STATE,
} = require("../delivery_callables");

const now = Date.now();
const idleDriver = "drv_idle_1";
const busyRideDriver = "drv_busy_ride_1";
const busyDelDriver = "drv_busy_del_1";
const driverA = "drv_accept_a";
const customerId = "cust_busy_1";
const targetDelivery = "del_target_1";
const otherDelivery = "del_other_1";
const activeRide = "ride_active_1";

const verifiedRow = {
  customer_id: customerId,
  market: "lagos",
  market_pool: "lagos",
  pickup: { lat: 6.5244, lng: 3.3792, address: "Pickup" },
  dropoff: { lat: 6.53, lng: 3.38, address: "Dropoff" },
  delivery_state: "searching",
  payment_method: "flutterwave",
  payment_status: "verified",
  payment_transaction_id: "flw_busy_ok",
};

const driverProfile = {
  dispatch_market: "lagos",
  active_services: ["dispatch_delivery"],
  nexride_verified: true,
  isOnline: true,
  last_active_at: now,
};

function makeGuardTestDb(initialStore = {}) {
  const store = { ...initialStore };
  const state = { offerWrites: [], rootUpdates: [] };

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
        store[p] = v;
      },
      async update(patch) {
        const cur = getVal(p);
        store[p] = {
          ...(cur && typeof cur === "object" ? cur : {}),
          ...patch,
        };
      },
      async transaction(fn) {
        const cur = getVal(p);
        const next = fn(cur);
        if (next === undefined) {
          return { committed: false, snapshot: { val: () => cur } };
        }
        store[p] = next;
        return { committed: true, snapshot: { val: () => next } };
      },
    };

    if (p === "drivers") {
      node.orderByChild = () => ({
        equalTo: (market) => ({
          get: async () => {
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
        state.rootUpdates.push(payload);
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

  return { ref, store, state };
}

function freshActiveRideRow(driverId) {
  return {
    rider_id: "rider_busy_1",
    matched_driver_id: driverId,
    trip_state: "driver_assigned",
    status: "accepted",
    accepted_at: now - 60_000,
    updated_at: now - 30_000,
  };
}

function activeDeliveryRow(driverId) {
  return {
    customer_id: customerId,
    matched_driver_id: driverId,
    delivery_state: DELIVERY_STATE.driver_assigned,
    updated_at: now,
  };
}

test("resolveDeliveryBusyGuardForDriver blocks active ride pointer", async () => {
  const db = makeGuardTestDb({
    [`driver_active_ride/${busyRideDriver}`]: { ride_id: activeRide },
    [`ride_requests/${activeRide}`]: freshActiveRideRow(busyRideDriver),
    [`active_trips/${activeRide}`]: {
      driver_id: busyRideDriver,
      trip_state: "driver_assigned",
      updated_at: now - 30_000,
    },
  });
  const guard = await resolveDeliveryBusyGuardForDriver(
    db,
    busyRideDriver,
    targetDelivery,
    "test",
  );
  assert.equal(guard.busy, true);
  assert.equal(guard.blockingTripId, activeRide);
});

test("resolveDeliveryBusyGuardForDriver blocks other active delivery", async () => {
  const db = makeGuardTestDb({
    [`driver_active_delivery/${busyDelDriver}`]: { delivery_id: otherDelivery },
    [`delivery_requests/${otherDelivery}`]: activeDeliveryRow(busyDelDriver),
    [`active_deliveries/${otherDelivery}`]: {
      delivery_state: DELIVERY_STATE.on_delivery,
      updated_at: now,
    },
  });
  const guard = await resolveDeliveryBusyGuardForDriver(
    db,
    busyDelDriver,
    targetDelivery,
    "test",
  );
  assert.equal(guard.busy, true);
  assert.equal(guard.blockingTripId, otherDelivery);
});

test("resolveDeliveryBusyGuardForDriver allows same delivery pointer", async () => {
  const db = makeGuardTestDb({
    [`driver_active_delivery/${driverA}`]: { delivery_id: targetDelivery },
    [`delivery_requests/${targetDelivery}`]: activeDeliveryRow(driverA),
    [`active_deliveries/${targetDelivery}`]: {
      delivery_state: DELIVERY_STATE.driver_assigned,
      updated_at: now,
    },
  });
  const guard = await resolveDeliveryBusyGuardForDriver(
    db,
    driverA,
    targetDelivery,
    "test",
  );
  assert.equal(guard.busy, false);
  assert.equal(guard.blockingTripId, null);
});

test("fanOutDeliveryOffersIfEligible skips driver with active ride", async () => {
  const db = makeGuardTestDb({
    [`drivers/${busyRideDriver}`]: driverProfile,
    [`driver_active_ride/${busyRideDriver}`]: { ride_id: activeRide },
    [`ride_requests/${activeRide}`]: freshActiveRideRow(busyRideDriver),
    [`active_trips/${activeRide}`]: {
      driver_id: busyRideDriver,
      trip_state: "driver_assigned",
      updated_at: now - 30_000,
    },
  });
  await fanOutDeliveryOffersIfEligible(db, targetDelivery, verifiedRow);
  assert.equal(db.state.offerWrites.length, 0);
});

test("fanOutDeliveryOffersIfEligible skips driver with active delivery", async () => {
  const db = makeGuardTestDb({
    [`drivers/${busyDelDriver}`]: driverProfile,
    [`driver_active_delivery/${busyDelDriver}`]: { delivery_id: otherDelivery },
    [`delivery_requests/${otherDelivery}`]: activeDeliveryRow(busyDelDriver),
    [`active_deliveries/${otherDelivery}`]: {
      delivery_state: DELIVERY_STATE.picked_up,
      updated_at: now,
    },
  });
  await fanOutDeliveryOffersIfEligible(db, targetDelivery, verifiedRow);
  assert.equal(db.state.offerWrites.length, 0);
});

test("fanOutDeliveryOffersIfEligible allows idle driver", async () => {
  const db = makeGuardTestDb({
    [`drivers/${idleDriver}`]: driverProfile,
  });
  await fanOutDeliveryOffersIfEligible(db, targetDelivery, verifiedRow);
  assert.equal(
    db.state.offerWrites.some((p) => p === `delivery_offer_queue/${idleDriver}/${targetDelivery}`),
    true,
  );
});

test("acceptDeliveryRequest rejects driver with active ride", async () => {
  const db = makeGuardTestDb({
    [`delivery_requests/${targetDelivery}`]: {
      ...verifiedRow,
      expires_at: now + 120_000,
    },
    [`delivery_offer_queue/${driverA}/${targetDelivery}`]: { delivery_id: targetDelivery },
    [`driver_active_ride/${driverA}`]: { ride_id: activeRide },
    [`ride_requests/${activeRide}`]: freshActiveRideRow(driverA),
    [`active_trips/${activeRide}`]: {
      driver_id: driverA,
      trip_state: "driver_assigned",
      updated_at: now - 30_000,
    },
    [`drivers/${driverA}`]: driverProfile,
  });
  const result = await acceptDeliveryRequest(
    { deliveryId: targetDelivery },
    { auth: { uid: driverA } },
    db,
  );
  assert.equal(result.success, false);
  assert.equal(result.reason, "driver_busy");
});

test("acceptDeliveryRequest rejects driver with another active delivery", async () => {
  const db = makeGuardTestDb({
    [`delivery_requests/${targetDelivery}`]: {
      ...verifiedRow,
      expires_at: now + 120_000,
    },
    [`delivery_offer_queue/${driverA}/${targetDelivery}`]: { delivery_id: targetDelivery },
    [`driver_active_delivery/${driverA}`]: { delivery_id: otherDelivery },
    [`delivery_requests/${otherDelivery}`]: activeDeliveryRow(driverA),
    [`active_deliveries/${otherDelivery}`]: {
      delivery_state: DELIVERY_STATE.on_delivery,
      updated_at: now,
    },
    [`drivers/${driverA}`]: driverProfile,
  });
  const result = await acceptDeliveryRequest(
    { deliveryId: targetDelivery },
    { auth: { uid: driverA } },
    db,
  );
  assert.equal(result.success, false);
  assert.equal(result.reason, "driver_busy");
});

test("acceptDeliveryRequest allows same delivery idempotent accept", async () => {
  const db = makeGuardTestDb({
    [`delivery_requests/${targetDelivery}`]: {
      ...verifiedRow,
      delivery_state: DELIVERY_STATE.driver_assigned,
      matched_driver_id: driverA,
      accepted_driver_id: driverA,
      expires_at: now + 120_000,
    },
    [`drivers/${driverA}`]: driverProfile,
  });
  const result = await acceptDeliveryRequest(
    { deliveryId: targetDelivery },
    { auth: { uid: driverA } },
    db,
  );
  assert.equal(result.success, true);
  assert.equal(result.idempotent, true);
});
