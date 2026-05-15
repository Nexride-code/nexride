const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  adminListLiveTrips,
  adminGetTripDetail,
  adminCancelTrip,
  adminMarkTripEmergency,
  adminListOnlineDrivers,
  adminSuspendDriver,
} = require("../admin_callables");

const adminCtx = { auth: { uid: "admin1", token: { admin: true, admin_role: "super_admin" } } };
const userCtx = { auth: { uid: "u1", token: {} } };

/** Minimal RTDB mock: most paths empty; override `overrides` for targeted reads. */
function makeEmptyLiveDb(overrides = {}) {
  const chainTerminal = {
    get: async () => ({ val: () => null, exists: () => false }),
    update: async () => {},
    set: async () => {},
  };
  return {
    ref(path) {
      const p = String(path);
      if (overrides[p]) {
        return overrides[p];
      }
      if (p === "ride_requests" || p === "delivery_requests") {
        return {
          orderByKey: () => ({
            limitToLast: () => ({
              get: async () => ({ val: () => null, exists: () => false }),
            }),
          }),
        };
      }
      if (p === "admin_audit_logs") {
        return {
          orderByKey: () => ({
            limitToLast: () => ({
              get: async () => ({ val: () => null, exists: () => false }),
            }),
          }),
          push: () => ({ set: async () => {} }),
        };
      }
      return {
        ...chainTerminal,
        orderByKey: () => ({
          limitToLast: () => ({
            get: async () => ({ val: () => null, exists: () => false }),
          }),
        }),
      };
    },
  };
}

test("non-admin cannot list live trips", async () => {
  const res = await adminListLiveTrips({}, userCtx, makeEmptyLiveDb());
  assert.equal(res.success, false);
  assert.equal(res.reason, "unauthorized");
});

test("non-admin cannot perform adminCancelTrip", async () => {
  const res = await adminCancelTrip(
    { tripId: "t1", note: "long enough note here" },
    userCtx,
    makeEmptyLiveDb(),
  );
  assert.equal(res.success, false);
});

test("adminCancelTrip requires note", async () => {
  const res = await adminCancelTrip({ tripId: "t1", note: "short" }, adminCtx, makeEmptyLiveDb());
  assert.equal(res.success, false);
  assert.equal(res.reason, "note_required");
});

test("adminSuspendDriver requires note", async () => {
  const res = await adminSuspendDriver({ driverId: "d1", note: "x" }, adminCtx, makeEmptyLiveDb());
  assert.equal(res.success, false);
  assert.equal(res.reason, "reason_required");
});

test("adminListLiveTrips returns empty arrays when no data", async () => {
  const res = await adminListLiveTrips({}, adminCtx, makeEmptyLiveDb());
  assert.equal(res.success, true);
  assert.ok(Array.isArray(res.trips));
  assert.equal(res.trips.length, 0);
  assert.ok(Array.isArray(res.recent_completed));
  assert.ok(Array.isArray(res.recent_cancelled));
});

test("adminListOnlineDrivers returns empty drivers array when none online", async () => {
  const res = await adminListOnlineDrivers({}, adminCtx, makeEmptyLiveDb());
  assert.equal(res.success, true);
  assert.ok(Array.isArray(res.drivers));
  assert.equal(res.drivers.length, 0);
});

test("adminMarkTripEmergency audit payload shape", async () => {
  let auditPayload = null;
  const tripId = "ride_em_1";
  const db = {
    ref(path) {
      const p = String(path);
      if (p === "admin_audit_logs") {
        return {
          orderByKey: () => ({
            limitToLast: () => ({
              get: async () => ({ val: () => null, exists: () => false }),
            }),
          }),
          push: () => ({
            key: "log_test_1",
            set: async (v) => {
              auditPayload = v;
            },
          }),
        };
      }
      if (p === `ride_requests/${tripId}`) {
        return {
          get: async () => ({
            exists: () => true,
            val: () => ({ rider_id: "r1", trip_state: "driver_assigned", updated_at: 1 }),
          }),
          update: async () => {},
        };
      }
      return {
        get: async () => ({ val: () => null, exists: () => false }),
        orderByKey: () => ({
          limitToLast: () => ({
            get: async () => ({ val: () => null, exists: () => false }),
          }),
        }),
      };
    },
  };
  const res = await adminMarkTripEmergency(
    { tripId, note: "Emergency note at least eight chars" },
    adminCtx,
    db,
  );
  assert.equal(res.success, true);
  assert.ok(auditPayload && typeof auditPayload === "object");
  assert.equal(auditPayload.type, "admin_mark_trip_emergency");
  assert.equal(auditPayload.action, "mark_trip_emergency");
  assert.equal(auditPayload.entity_type, "trip");
  assert.equal(auditPayload.entity_id, tripId);
  assert.equal(auditPayload.actor_uid, "admin1");
  assert.ok(typeof auditPayload.reason === "string" && auditPayload.reason.length >= 8);
  assert.ok(typeof auditPayload.created_at === "number");
});

test("adminGetTripDetail returns ride payload", async () => {
  const tripId = "r1";
  const db = {
    ref(path) {
      const p = String(path);
      if (p === `ride_requests/${tripId}`) {
        return {
          get: async () => ({
            exists: () => true,
            val: () => ({
              ride_id: tripId,
              rider_id: "x",
              fare: 100,
              currency: "NGN",
            }),
          }),
        };
      }
      if (p.startsWith("payment_transactions/") || p.startsWith("payments/")) {
        return {
          get: async () => ({ val: () => null, exists: () => false }),
        };
      }
      if (p === "admin_audit_logs") {
        return {
          orderByKey: () => ({
            limitToLast: () => ({
              get: async () => ({ val: () => null, exists: () => false }),
            }),
          }),
        };
      }
      return {
        get: async () => ({ val: () => null, exists: () => false }),
        orderByKey: () => ({
          limitToLast: () => ({
            get: async () => ({ val: () => null, exists: () => false }),
          }),
        }),
      };
    },
  };
  const res = await adminGetTripDetail({ tripId }, adminCtx, db);
  assert.equal(res.success, true);
  assert.equal(res.trip_kind, "ride");
  assert.ok(res.ride && typeof res.ride === "object");
  assert.ok(Array.isArray(res.audit_timeline));
  assert.ok(Array.isArray(res.payments));
});

test("adminListLiveTrips unions driver_active_ride when active_trips has no key", async () => {
  const now = Date.now();
  const db = {
    ref(path) {
      const p = String(path);
      if (p === "active_trips" || p === "active_deliveries") {
        return { get: async () => ({ val: () => ({}), exists: () => true }) };
      }
      if (p === "rider_active_trip" || p === "user_active_delivery") {
        return { get: async () => ({ val: () => null, exists: () => false }) };
      }
      if (p === "driver_active_ride") {
        return {
          get: async () => ({
            val: () => ({ drv1: { ride_id: "rid1", updated_at: 1 } }),
            exists: () => true,
          }),
        };
      }
      if (p === "driver_active_delivery") {
        return { get: async () => ({ val: () => null, exists: () => false }) };
      }
      if (p === "ride_requests/rid1") {
        return {
          get: async () => ({
            exists: () => true,
            val: () => ({
              rider_id: "r1",
              driver_id: "drv1",
              trip_state: "driver_assigned",
              status: "assigned",
              fare: 100,
              currency: "NGN",
              updated_at: now,
              created_at: now,
              pickup: {},
            }),
          }),
        };
      }
      if (p === "ride_requests" || p === "delivery_requests") {
        return {
          orderByKey: () => ({
            limitToLast: () => ({
              get: async () => ({ val: () => null, exists: () => false }),
            }),
          }),
        };
      }
      return {
        get: async () => ({ val: () => null, exists: () => false }),
        orderByKey: () => ({
          limitToLast: () => ({
            get: async () => ({ val: () => null, exists: () => false }),
          }),
        }),
      };
    },
  };
  const res = await adminListLiveTrips({}, adminCtx, db);
  assert.equal(res.success, true);
  assert.equal(res.trips.length, 1);
  assert.equal(res.trips[0].trip_id, "rid1");
});

test("adminListLiveTrips unions user_active_delivery phase active", async () => {
  const now = Date.now();
  const db = {
    ref(path) {
      const p = String(path);
      if (p === "active_trips" || p === "active_deliveries") {
        return { get: async () => ({ val: () => ({}), exists: () => true }) };
      }
      if (p === "rider_active_trip") {
        return { get: async () => ({ val: () => null, exists: () => false }) };
      }
      if (p === "user_active_delivery") {
        return {
          get: async () => ({
            val: () => ({ cust1: { delivery_id: "del1", phase: "active", updated_at: 1 } }),
            exists: () => true,
          }),
        };
      }
      if (p === "driver_active_ride" || p === "driver_active_delivery") {
        return { get: async () => ({ val: () => null, exists: () => false }) };
      }
      if (p === "delivery_requests/del1") {
        return {
          get: async () => ({
            exists: () => true,
            val: () => ({
              customer_id: "cust1",
              delivery_state: "enroute_pickup",
              trip_state: "driver_assigned",
              status: "assigned",
              fare: 50,
              currency: "NGN",
              updated_at: now,
              created_at: now,
              pickup: {},
              dropoff: {},
            }),
          }),
        };
      }
      if (p === "ride_requests" || p === "delivery_requests") {
        return {
          orderByKey: () => ({
            limitToLast: () => ({
              get: async () => ({ val: () => null, exists: () => false }),
            }),
          }),
        };
      }
      return {
        get: async () => ({ val: () => null, exists: () => false }),
        orderByKey: () => ({
          limitToLast: () => ({
            get: async () => ({ val: () => null, exists: () => false }),
          }),
        }),
      };
    },
  };
  const res = await adminListLiveTrips({}, adminCtx, db);
  assert.equal(res.success, true);
  assert.equal(res.trips.length, 1);
  assert.equal(res.trips[0].trip_id, "del1");
  assert.equal(res.trips[0].trip_kind, "delivery");
});
