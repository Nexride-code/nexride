"use strict";

const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  deliveryOpensForFanout,
  deliveryAllowsFanoutPayment,
  purgeExpiredDeliveryOfferQueueEntries,
  fanOutDeliveryOffersIfEligible,
  DELIVERY_STATE,
} = require("../delivery_callables");
const { clearDispatchConfigCache } = require("../dispatch_engine/dispatch_config_engine");

test("pending payment delivery opens for fanout", () => {
  const row = {
    delivery_state: DELIVERY_STATE.searching,
    status: "searching",
    customer_id: "cust_1",
    payment_status: "pending",
    driver_id: "waiting",
  };
  assert.equal(deliveryOpensForFanout(row), true);
  assert.equal(deliveryAllowsFanoutPayment(row), true);
});

test("purgeExpiredDeliveryOfferQueueEntries removes terminal delivery offers", async () => {
  const driverId = "driver_del_purge";
  const deliveryId = "del_terminal_1";
  const db = {
    ref(path) {
      const p = String(path || "");
      const store = db._store || {};
      return {
        async get() {
          const val = p.split("/").reduce(
            (cur, key) => (cur && typeof cur === "object" ? cur[key] : undefined),
            store,
          );
          return {
            exists: () => val !== undefined && val !== null,
            val: () => (val === undefined ? null : val),
          };
        },
        async update(patch) {
          for (const [k, v] of Object.entries(patch)) {
            const parts = k.split("/").filter(Boolean);
            let cur = store;
            for (let i = 0; i < parts.length - 1; i++) {
              if (!cur[parts[i]]) cur[parts[i]] = {};
              cur = cur[parts[i]];
            }
            if (v === null) delete cur[parts[parts.length - 1]];
            else cur[parts[parts.length - 1]] = v;
          }
        },
      };
    },
    _store: {
      delivery_offer_queue: {
        [driverId]: {
          [deliveryId]: { expires_at: Date.now() + 60_000 },
        },
      },
      delivery_requests: {
        [deliveryId]: {
          delivery_state: DELIVERY_STATE.cancelled,
          customer_id: "cust_1",
        },
      },
    },
  };
  const res = await purgeExpiredDeliveryOfferQueueEntries(db, driverId);
  assert.equal(res.removed, 1);
  assert.equal(db._store.delivery_offer_queue[driverId][deliveryId], undefined);
});

function makeNestedStore(initial = {}) {
  const store = JSON.parse(JSON.stringify(initial));
  const applyPathUpdate = (path, value) => {
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
  const getAtPath = (path) => {
    const parts = path ? String(path).split("/").filter(Boolean) : [];
    let cur = store;
    for (const p of parts) {
      if (cur == null) return undefined;
      cur = cur[p];
    }
    return cur;
  };
  const ref = (path) => {
    const p = path == null || path === "" ? "" : String(path);
    const node = {
      child(sub) {
        return ref(p ? `${p}/${sub}` : String(sub));
      },
      async get() {
        const val = getAtPath(p);
        return {
          exists: () => val !== undefined && val !== null,
          val: () => (val === undefined ? null : val),
        };
      },
      async set(v) {
        applyPathUpdate(p, v);
      },
      async update(patch) {
        const cur = getAtPath(p);
        applyPathUpdate(p, {
          ...(cur && typeof cur === "object" ? cur : {}),
          ...patch,
        });
      },
      orderByChild(field) {
        return {
          equalTo(value) {
            return {
              limitToFirst() {
                return this;
              },
              async get() {
                const root = getAtPath(p);
                const out = {};
                if (root && typeof root === "object") {
                  for (const [id, row] of Object.entries(root)) {
                    if (row && typeof row === "object" && String(row[field] ?? "") === String(value)) {
                      out[id] = row;
                    }
                  }
                }
                return { val: () => (Object.keys(out).length ? out : null) };
              },
            };
          },
        };
      },
      limitToFirst() {
        return {
          async get() {
            const val = getAtPath(p);
            return { val: () => val ?? null, exists: () => val != null };
          },
        };
      },
    };
    if (p === "") {
      node.update = async (payload) => {
        for (const [k, v] of Object.entries(payload || {})) {
          applyPathUpdate(k, v);
        }
      };
    }
    return node;
  };
  return { ref, store, getAtPath };
}

function makeFanoutStore({ driverId, driverProfile, deliveryId, row, extra = {} }) {
  const now = Date.now();
  return makeNestedStore({
    app_config: { nexride_dispatch: {}, settings_meta: {} },
    dispatch_index: { abuja_fct: { [driverId]: true } },
    drivers: { [driverId]: driverProfile },
    online_drivers: { [driverId]: { ...driverProfile, is_online: true } },
    delivery_requests: { [deliveryId]: { ...row } },
    driver_active_ride: {},
    driver_active_delivery: {},
    delivery_offer_fanout: {},
    delivery_offer_queue: {},
    ...extra,
  });
}

test("online bike driver receives delivery offer in delivery_offer_queue", async () => {
  clearDispatchConfigCache();
  const driverId = "driver_bike_fanout";
  const deliveryId = "del_bike_fanout_1";
  const now = Date.now();
  const row = {
    delivery_id: deliveryId,
    customer_id: "cust_1",
    market_pool: "abuja_fct",
    dispatch_market_id: "abuja_fct",
    resolved_service_city_id: "wuse",
    delivery_state: DELIVERY_STATE.searching,
    status: "searching",
    payment_status: "pending",
    service_type: "dispatch_delivery",
    pickup: { lat: 9.0765, lng: 7.4898, address: "Pickup A" },
    dropoff: { lat: 9.05, lng: 7.49, address: "Dropoff B" },
    total_ngn: 2500,
    delivery_fee_ngn: 2000,
    booking_fee_ngn: 500,
    match_debug: { matching_state: "pending_fanout" },
  };
  const driverProfile = {
    is_online: true,
    status: "online_available",
    dispatch_state: "online_available",
    dispatch_market_id: "abuja_fct",
    service_area_city_id: "wuse",
    driver_availability_mode: "service_area",
    location_mode: "area",
    vehicle_type: "bike",
    active_services: ["dispatch_delivery"],
    nexride_verified: true,
    last_active_at: now,
    last_dispatch_heartbeat: now,
    lat: 9.076,
    lng: 7.489,
  };
  const { ref, getAtPath } = makeFanoutStore({ driverId, driverProfile, deliveryId, row });
  await fanOutDeliveryOffersIfEligible({ ref }, deliveryId, row);
  const offer = getAtPath(`delivery_offer_queue/${driverId}/${deliveryId}`);
  assert.ok(offer, "bike driver must receive delivery_offer_queue row");
  assert.equal(String(offer.status ?? ""), "offered");
  assert.equal(String(offer.delivery_id ?? ""), deliveryId);
  assert.equal(String(offer.customer_id ?? offer.rider_id ?? ""), "cust_1");
  assert.ok(offer.pickup && offer.dropoff);
});

test("online car driver with dispatch enabled receives delivery offer", async () => {
  clearDispatchConfigCache();
  const driverId = "driver_car_dispatch";
  const deliveryId = "del_car_dispatch_1";
  const now = Date.now();
  const row = {
    delivery_id: deliveryId,
    customer_id: "cust_2",
    market_pool: "abuja_fct",
    dispatch_market_id: "abuja_fct",
    resolved_service_city_id: "wuse",
    delivery_state: DELIVERY_STATE.searching,
    status: "searching",
    payment_status: "pending",
    service_type: "dispatch_delivery",
    pickup: { lat: 9.0765, lng: 7.4898 },
    dropoff: { lat: 9.05, lng: 7.49 },
    match_debug: { matching_state: "pending_fanout" },
  };
  const driverProfile = {
    is_online: true,
    status: "online_available",
    dispatch_state: "online_available",
    dispatch_market_id: "abuja_fct",
    service_area_city_id: "wuse",
    driver_availability_mode: "service_area",
    vehicle_type: "car",
    service_capabilities: { dispatch_delivery: true, ride: true },
    accepts_dispatch: true,
    supports_delivery: true,
    active_services: ["ride"],
    nexride_verified: true,
    last_active_at: now,
    last_dispatch_heartbeat: now,
    lat: 9.076,
    lng: 7.489,
  };
  const { ref, getAtPath } = makeFanoutStore({ driverId, driverProfile, deliveryId, row });
  await fanOutDeliveryOffersIfEligible({ ref }, deliveryId, row);
  const offer = getAtPath(`delivery_offer_queue/${driverId}/${deliveryId}`);
  assert.ok(offer, "car driver with dispatch enabled must receive offer");
});

test("online car driver without dispatch does not receive delivery offer", async () => {
  clearDispatchConfigCache();
  const driverId = "driver_car_ride_only";
  const deliveryId = "del_car_ride_only_1";
  const now = Date.now();
  const row = {
    delivery_id: deliveryId,
    customer_id: "cust_3",
    market_pool: "abuja_fct",
    dispatch_market_id: "abuja_fct",
    delivery_state: DELIVERY_STATE.searching,
    status: "searching",
    payment_status: "pending",
    service_type: "dispatch_delivery",
    pickup: { lat: 9.0765, lng: 7.4898 },
    dropoff: { lat: 9.05, lng: 7.49 },
    match_debug: { matching_state: "pending_fanout" },
  };
  const driverProfile = {
    is_online: true,
    status: "online_available",
    dispatch_state: "online_available",
    dispatch_market_id: "abuja_fct",
    vehicle_type: "car",
    service_capabilities: { ride: true, dispatch_delivery: false },
    active_services: ["ride"],
    nexride_verified: true,
    last_active_at: now,
    last_dispatch_heartbeat: now,
    lat: 9.076,
    lng: 7.489,
  };
  const { ref, getAtPath } = makeFanoutStore({ driverId, driverProfile, deliveryId, row });
  await fanOutDeliveryOffersIfEligible({ ref }, deliveryId, row);
  const offer = getAtPath(`delivery_offer_queue/${driverId}/${deliveryId}`);
  assert.equal(offer, undefined, "ride-only car must not receive delivery offer");
});

test("driver remains eligible for second delivery after first cancel clears lock", async () => {
  clearDispatchConfigCache();
  const driverId = "driver_reoffer_after_cancel";
  const firstDeliveryId = "del_cancelled_1";
  const secondDeliveryId = "del_reoffer_2";
  const now = Date.now();
  const driverProfile = {
    is_online: true,
    status: "online_available",
    dispatch_state: "online_available",
    dispatch_market_id: "abuja_fct",
    service_area_city_id: "wuse",
    vehicle_type: "bike",
    active_services: ["dispatch_delivery"],
    nexride_verified: true,
    last_active_at: now,
    last_dispatch_heartbeat: now,
    lat: 9.076,
    lng: 7.489,
  };
  const secondRow = {
    delivery_id: secondDeliveryId,
    customer_id: "cust_4",
    market_pool: "abuja_fct",
    dispatch_market_id: "abuja_fct",
    resolved_service_city_id: "wuse",
    delivery_state: DELIVERY_STATE.searching,
    status: "searching",
    payment_status: "pending",
    service_type: "dispatch_delivery",
    pickup: { lat: 9.0765, lng: 7.4898 },
    dropoff: { lat: 9.05, lng: 7.49 },
    match_debug: { matching_state: "pending_fanout" },
  };
  const { ref, getAtPath } = makeFanoutStore({
    driverId,
    driverProfile,
    deliveryId: secondDeliveryId,
    row: secondRow,
    extra: {
      driver_active_delivery: {},
      drivers: {
        [driverId]: { ...driverProfile, active_delivery_id: null },
      },
    },
  });
  await fanOutDeliveryOffersIfEligible({ ref }, secondDeliveryId, secondRow);
  const offer = getAtPath(`delivery_offer_queue/${driverId}/${secondDeliveryId}`);
  assert.ok(offer, "driver must receive offer after prior delivery cancel cleared lock");
});

test("fanOutDeliveryOffersIfEligible enqueues with DELIVERY_OFFER_ENQUEUED log path", async () => {
  clearDispatchConfigCache();
  const driverId = "driver_del_fanout";
  const deliveryId = "del_fanout_1";
  const now = Date.now();
  const row = {
    delivery_id: deliveryId,
    customer_id: "cust_1",
    market_pool: "abuja_fct",
    dispatch_market_id: "abuja_fct",
    resolved_service_city_id: "wuse",
    delivery_state: DELIVERY_STATE.searching,
    status: "searching",
    payment_status: "pending",
    service_type: "dispatch_delivery",
    pickup: { lat: 9.0765, lng: 7.4898 },
    dropoff: { lat: 9.05, lng: 7.49 },
    match_debug: { matching_state: "pending_fanout" },
  };
  const driverProfile = {
    is_online: true,
    status: "online_available",
    dispatch_state: "online_available",
    dispatch_market_id: "abuja_fct",
    service_area_city_id: "wuse",
    driver_availability_mode: "service_area",
    location_mode: "area",
    vehicle_type: "bike",
    active_services: ["dispatch_delivery"],
    nexride_verified: true,
    last_active_at: now,
    last_dispatch_heartbeat: now,
  };
  const { ref, getAtPath } = makeNestedStore({
    app_config: { nexride_dispatch: {}, settings_meta: {} },
    dispatch_index: { abuja_fct: {} },
    drivers: { [driverId]: driverProfile },
    online_drivers: { [driverId]: { ...driverProfile, is_online: true } },
    delivery_requests: { [deliveryId]: { ...row } },
    driver_active_ride: {},
    driver_active_delivery: {},
    delivery_offer_fanout: {},
    delivery_offer_queue: {},
  });
  const db = { ref };
  await fanOutDeliveryOffersIfEligible(db, deliveryId, row);
  const offer = getAtPath(`delivery_offer_queue/${driverId}/${deliveryId}`);
  assert.ok(offer, "delivery_offer_queue row must be written");
  assert.equal(String(offer.delivery_id ?? offer.deliveryId ?? ""), deliveryId);
});
