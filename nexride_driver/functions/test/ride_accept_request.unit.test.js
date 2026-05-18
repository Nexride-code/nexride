const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  paymentAllowsDispatch,
  normalizedPaymentMethod,
  effectiveAcceptExpiryMs,
  acceptWindowOpenAt,
  acceptWindowOpenForAccept,
  hasAssignedDriver,
  canonicalAssignedDriverId,
  ridePoolOpenForAccept,
  inferAcceptTxAbortReason,
  evaluateOfferAcceptAuthority,
  ACCEPT_EXPIRY_GRACE_MS,
} = require("../ride_callables");

const now = 1_700_000_000_000;

test("bank_transfer + pending_transfer allows dispatch/accept", () => {
  assert.equal(
    paymentAllowsDispatch({
      payment_method: "bank_transfer",
      payment_status: "pending_transfer",
    }),
    true,
  );
});

test("flutterwave_va provider + pending_transfer allows dispatch/accept", () => {
  assert.equal(
    paymentAllowsDispatch({
      payment_method: "flutterwave",
      payment_provider: "flutterwave_va",
      payment_status: "pending_transfer",
    }),
    true,
  );
});

test("flutterwave + pending_transfer allows dispatch when VA issued but method not retagged", () => {
  assert.equal(
    paymentAllowsDispatch({
      payment_method: "flutterwave",
      payment_status: "pending_transfer",
    }),
    true,
  );
});

test("bank_transfer + pending alone does not allow dispatch before VA", () => {
  assert.equal(
    paymentAllowsDispatch({
      payment_method: "bank_transfer",
      payment_status: "pending",
    }),
    false,
  );
});

test("accept window uses max of ride and offer expiry", () => {
  const ride = { expires_at: now - 60_000 };
  const offer = { expires_at: now + 120_000 };
  assert.equal(effectiveAcceptExpiryMs(ride, offer), now + 120_000);
  assert.equal(acceptWindowOpenAt(ride, offer, now), true);
});

test("accept fails when both ride and offer are expired beyond grace", () => {
  const ride = { expires_at: now - 120_000 };
  const offer = { expires_at: now - 30_000 };
  const started = now - 35_000;
  assert.equal(acceptWindowOpenForAccept(ride, offer, started, now), false);
});

test("accept grace: started before expiry, server within grace after expiry", () => {
  const exp = now - 3_000;
  const ride = { expires_at: exp };
  const offer = { expires_at: exp };
  const started = now - 8_000;
  assert.equal(acceptWindowOpenForAccept(ride, offer, started, now), true);
  assert.ok(now < exp + ACCEPT_EXPIRY_GRACE_MS);
});

test("accept grace fails when expired well beyond grace window", () => {
  const exp = now - 30_000;
  const ride = { expires_at: exp };
  const offer = { expires_at: exp };
  const started = now - 35_000;
  assert.equal(acceptWindowOpenForAccept(ride, offer, started, now), false);
});

test("normalizedPaymentMethod maps flutterwave_va to bank_transfer", () => {
  assert.equal(
    normalizedPaymentMethod({
      payment_method: "flutterwave_va",
    }),
    "bank_transfer",
  );
});

test("evaluateOfferAcceptAuthority: queue row grants access", () => {
  const r = evaluateOfferAcceptAuthority({
    driverId: "drv1",
    ride: {},
    offerPresent: true,
    offerVal: { ride_id: "ride1", status: "open", expires_at: now + 60_000 },
  });
  assert.equal(r.valid, true);
  assert.equal(r.source, "queue");
});

test("evaluateOfferAcceptAuthority: batch_driver_ids grants access without queue", () => {
  const r = evaluateOfferAcceptAuthority({
    driverId: "drv1",
    ride: {
      match_debug: {
        batch_driver_ids: ["drv1", "drv2"],
      },
    },
    offerPresent: false,
    offerVal: null,
  });
  assert.equal(r.valid, true);
  assert.equal(r.source, "batch_driver_ids");
});

test("evaluateOfferAcceptAuthority: offered_driver_ids grants access", () => {
  const r = evaluateOfferAcceptAuthority({
    driverId: "drv9",
    ride: {
      match_debug: {
        offered_driver_ids: ["drv9"],
      },
    },
    offerPresent: false,
    offerVal: null,
  });
  assert.equal(r.valid, true);
  assert.equal(r.source, "offered_driver_ids");
});

test("evaluateOfferAcceptAuthority: queue_write audit grants access", () => {
  const r = evaluateOfferAcceptAuthority({
    driverId: "drvA",
    ride: {
      match_debug: {
        queue_write_by_driver: { drvA: true },
      },
    },
    offerPresent: false,
    offerVal: null,
  });
  assert.equal(r.valid, true);
  assert.equal(r.source, "audit");
});

test("evaluateOfferAcceptAuthority: fanout bit grants access", () => {
  const r = evaluateOfferAcceptAuthority({
    driverId: "drvB",
    ride: {},
    offerPresent: false,
    offerVal: null,
    rideOfferFanoutPresent: true,
  });
  assert.equal(r.valid, true);
  assert.equal(r.source, "audit");
});

test("evaluateOfferAcceptAuthority: random driver denied", () => {
  const r = evaluateOfferAcceptAuthority({
    driverId: "stranger",
    ride: {
      match_debug: {
        batch_driver_ids: ["drv1"],
        offered_driver_ids: ["drv2"],
        queue_write_by_driver: { drv3: true },
      },
    },
    offerPresent: false,
    offerVal: null,
    rideOfferFanoutPresent: false,
  });
  assert.equal(r.valid, false);
  assert.equal(r.source, "none");
});

test("hasAssignedDriver: waiting/null/empty are unassigned", () => {
  assert.equal(hasAssignedDriver("waiting"), false);
  assert.equal(hasAssignedDriver("null"), false);
  assert.equal(hasAssignedDriver(""), false);
  assert.equal(hasAssignedDriver(undefined), false);
  assert.equal(hasAssignedDriver("drv_real_1"), true);
});

test("canonicalAssignedDriverId: driver_id waiting is unassigned", () => {
  assert.equal(
    canonicalAssignedDriverId({
      driver_id: "waiting",
      matched_driver_id: "waiting",
      trip_state: "searching",
      status: "searching",
    }),
    "",
  );
});

test("canonicalAssignedDriverId: matched_driver_id wins over waiting driver_id", () => {
  assert.equal(
    canonicalAssignedDriverId({
      driver_id: "waiting",
      matched_driver_id: "drv_winner",
      rider_id: "rider1",
    }),
    "drv_winner",
  );
});

test("ridePoolOpenForAccept: searching + waiting driver is open pool", () => {
  assert.equal(
    ridePoolOpenForAccept({
      trip_state: "searching",
      status: "searching",
      driver_id: "waiting",
    }),
    true,
  );
});

test("inferAcceptTxAbortReason: open waiting pool is not driver_already_set", () => {
  const liveNow = Date.now();
  const reason = inferAcceptTxAbortReason(
    {
      trip_state: "searching",
      status: "searching",
      driver_id: "waiting",
      payment_method: "bank_transfer",
      payment_status: "pending_transfer",
      expires_at: liveNow + 120_000,
    },
    "drv1",
    { expires_at: liveNow + 120_000 },
    liveNow - 1_000,
  );
  assert.equal(reason, "unknown");
});

test("evaluateOfferAcceptAuthority: withdrawn queue row denied", () => {
  const r = evaluateOfferAcceptAuthority({
    driverId: "drv1",
    ride: {},
    offerPresent: true,
    offerVal: { status: "withdrawn" },
  });
  assert.equal(r.valid, false);
  assert.equal(r.withdrawn, true);
});

console.log("ride_accept_request.unit.test.js OK");
