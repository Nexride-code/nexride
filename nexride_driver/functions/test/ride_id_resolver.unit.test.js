const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  rideIdLookupCandidates,
  rideIdEquivalentForms,
  rideIdsMatch,
  resolveRideRequestId,
} = require("../ride_id_resolver");

function makeDb(initial = {}) {
  const store = { ...initial };

  function ref(path) {
    const parts = String(path).split("/").filter(Boolean);
    const self = {
      async get() {
        let cur = store;
        for (const p of parts) {
          if (cur == null) return { exists: () => false, val: () => null };
          cur = cur[p];
        }
        return { exists: () => cur !== undefined && cur !== null, val: () => cur };
      },
      orderByChild(childKey) {
        return {
          equalTo(value) {
            return {
              limitToFirst() {
                return {
                  async get() {
                    const rootKey = parts[0];
                    const bucket = store[rootKey];
                    if (!bucket || typeof bucket !== "object") {
                      return { exists: () => false, val: () => null };
                    }
                    for (const [key, row] of Object.entries(bucket)) {
                      if (String(row?.[childKey] ?? "") === String(value)) {
                        return { exists: () => true, val: () => ({ [key]: row }) };
                      }
                    }
                    return { exists: () => false, val: () => null };
                  },
                };
              },
            };
          },
        };
      },
    };
    return self;
  }

  return { ref, _store: store };
}

test("rideIdLookupCandidates tries exact then dash-prefixed form", () => {
  assert.deepEqual(rideIdLookupCandidates("OuUOPZ8tOQeA10abFjq"), [
    "OuUOPZ8tOQeA10abFjq",
    "-OuUOPZ8tOQeA10abFjq",
  ]);
  assert.deepEqual(rideIdLookupCandidates("-OuUOPZ8tOQeA10abFjq"), ["-OuUOPZ8tOQeA10abFjq"]);
});

test("rideIdsMatch treats dash and non-dash forms as equivalent", () => {
  assert.equal(rideIdsMatch("OuUOPZ8tOQeA10abFjq", "-OuUOPZ8tOQeA10abFjq"), true);
  assert.equal(rideIdsMatch("abc", "xyz"), false);
});

test("resolveRideRequestId finds dashed RTDB key from undashed input", async () => {
  const canonical = "-OuUOPZ8tOQeA10abFjq";
  const db = makeDb({
    ride_requests: {
      [canonical]: { driver_id: "drv1", status: "completed" },
    },
  });
  const resolved = await resolveRideRequestId(db, "OuUOPZ8tOQeA10abFjq");
  assert.equal(resolved.ok, true);
  assert.equal(resolved.rideId, canonical);
  assert.equal(resolved.resolved_via, "ride_requests");
});

test("resolveRideRequestId finds ride via payment_transactions ride_id", async () => {
  const canonical = "-OuUOPZ8tOQeA10abFjq";
  const db = makeDb({
    ride_requests: {
      [canonical]: { driver_id: "drv1", status: "completed" },
    },
    payment_transactions: {
      fw_tx_1: {
        ride_id: canonical,
        tx_ref: "fw_tx_1",
        verified: true,
      },
    },
  });
  const resolved = await resolveRideRequestId(db, "fw_tx_1");
  assert.equal(resolved.ok, true);
  assert.equal(resolved.rideId, canonical);
  assert.equal(resolved.resolved_via, "payment_transactions_tx_ref");
});

test("both input forms resolve to the same canonical ride id", async () => {
  const canonical = "-OuUOPZ8tOQeA10abFjq";
  const db = makeDb({
    ride_requests: {
      [canonical]: { driver_id: "drv1", status: "completed" },
    },
  });
  const plain = await resolveRideRequestId(db, "OuUOPZ8tOQeA10abFjq");
  const dashed = await resolveRideRequestId(db, canonical);
  assert.equal(plain.rideId, dashed.rideId);
  assert.equal(plain.rideId, canonical);
});
