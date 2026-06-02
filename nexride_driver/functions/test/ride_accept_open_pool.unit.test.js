const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  evaluateAcceptTransactionDecision,
  attemptGuardedAcceptDirectWrite,
  buildDriverAcceptAssignmentPatch,
  canonicalAssignedDriverId,
  ridePoolOpenForAccept,
  mapApiAcceptFailureReason,
  paymentAllowsDispatch,
} = require("../ride_callables");
const { isOpenMatchingTripRow } = require("../matching_health");

const driverId = "drv_open_accept_1";
const riderId = "rider_open_1";
const rideId = "ride_open_accept_1";
const now = Date.now() + 120_000;

function openWaitingRide(overrides = {}) {
  return {
    ride_id: rideId,
    rider_id: riderId,
    status: "searching",
    trip_state: "searching",
    driver_id: "waiting",
    payment_method: "flutterwave",
    payment_provider: "flutterwave_va",
    payment_status: "pending_transfer",
    expires_at: now,
    market_pool: "asaba",
    ...overrides,
  };
}

function createMockRideRef(initialRide, { txNullAttempts = 0 } = {}) {
  let ride = { ...initialRide };
  let txCalls = 0;
  const ref = {
    async get() {
      return {
        exists: () => ride != null,
        val: () => ride,
      };
    },
    async update(patch) {
      ride = { ...ride, ...patch };
    },
    async transaction(fn) {
      txCalls += 1;
      const current =
        txNullAttempts > 0 && txCalls <= txNullAttempts ? null : { ...ride };
      const next = fn(current);
      if (next === undefined) {
        return { committed: false, snapshot: { val: () => ride } };
      }
      ride = next;
      return { committed: true, snapshot: { val: () => ride } };
    },
  };
  return {
    ref,
    getRide: () => ride,
    getTxCalls: () => txCalls,
  };
}

test("reproduction: open waiting ride + pending_transfer evaluates to commit", () => {
  const ride = openWaitingRide();
  const offer = { expires_at: now, ride_id: rideId };
  assert.equal(paymentAllowsDispatch(ride), true);
  assert.equal(ridePoolOpenForAccept(ride), true);
  assert.equal(canonicalAssignedDriverId(ride), "");

  const decision = evaluateAcceptTransactionDecision(ride, driverId, {
    rideId,
    authorityOfferVal: offer,
    acceptStartedAt: now - 2_000,
    now: now - 1_000,
    log: false,
  });
  assert.equal(decision.action, "commit");
  assert.equal(decision.patch.trip_state, "assigned");
  assert.equal(decision.patch.status, "assigned");
  assert.equal(decision.patch.driver_id, driverId);
});

test("guarded direct write commits when RTDB transaction sees null current", async () => {
  const { ref, getRide } = createMockRideRef(openWaitingRide(), { txNullAttempts: 8 });
  const offer = { expires_at: now, ride_id: rideId };
  const db = {};

  const direct = await attemptGuardedAcceptDirectWrite(db, ref, rideId, driverId, now - 500, {
    authorityOfferVal: offer,
    acceptStartedAt: now - 2_000,
  });
  assert.equal(direct.ok, true, `direct failed: ${direct.reason}`);
  assert.equal(direct.path, "direct_update");

  const after = getRide();
  assert.equal(after.status, "assigned");
  assert.equal(after.trip_state, "assigned");
  assert.equal(after.driver_id, driverId);
  assert.equal(after.matched_driver_id, driverId);
  assert.equal(canonicalAssignedDriverId(after), driverId);
});

test("tx_empty_current + valid offer maps to accept_pending_retry not transaction_conflict", () => {
  assert.equal(
    mapApiAcceptFailureReason("tx_empty_current", true, { offerWasValid: true }),
    "accept_pending_retry",
  );
});

test("open waiting ride direct commit does not surface transaction_conflict", async () => {
  const { ref } = createMockRideRef(openWaitingRide());
  const offer = { expires_at: now, ride_id: rideId };
  const direct = await attemptGuardedAcceptDirectWrite({}, ref, rideId, driverId, now - 500, {
    authorityOfferVal: offer,
    acceptStartedAt: now - 2_000,
  });
  assert.equal(direct.ok, true);
  assert.notEqual(direct.reason, "transaction_conflict");
});

test("buildDriverAcceptAssignmentPatch includes match_lock mutex fields", () => {
  const patch = buildDriverAcceptAssignmentPatch(driverId, now, 0, {
    useServerTimestamp: false,
  });
  assert.equal(patch.match_lock.accepted_by, driverId);
  assert.equal(patch.accepted_by, driverId);
});

test("accepted ride removed from matching open pool", async () => {
  const { ref, getRide } = createMockRideRef(openWaitingRide());
  const offer = { expires_at: now, ride_id: rideId };
  await attemptGuardedAcceptDirectWrite({}, ref, rideId, driverId, now - 500, {
    authorityOfferVal: offer,
    acceptStartedAt: now - 2_000,
  });
  const after = getRide();
  assert.equal(isOpenMatchingTripRow(after), false);
});

test("buildDriverAcceptAssignmentPatch uses numeric accepted_at inside transactions", () => {
  const patch = buildDriverAcceptAssignmentPatch(driverId, 1_700_000_000_000, 0, {
    useServerTimestamp: false,
  });
  assert.equal(typeof patch.accepted_at, "number");
  assert.equal(patch.accepted_at_ms, 1_700_000_000_000);
});

test("evaluateAcceptTransactionDecision aborts tx_empty_current when current null", () => {
  const decision = evaluateAcceptTransactionDecision(null, driverId, {
    rideId,
    log: false,
  });
  assert.equal(decision.action, "abort");
  assert.equal(decision.reason, "tx_empty_current");
});

console.log("ride_accept_open_pool.unit.test.js OK");
