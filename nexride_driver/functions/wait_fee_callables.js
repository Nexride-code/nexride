/**
 * Driver waiting fee — server authoritative, idempotent per 5-minute interval.
 * Does not mutate ride_finance_settlement; fare fields are read at completeTrip.
 */

const { sendPushToUser } = require("./push_notifications");

const WAIT_INTERVAL_MS = 5 * 60 * 1000;
const WAIT_FEE_DRIVER_NGN = 200;
const WAIT_FEE_PLATFORM_NGN = 50;
const WAIT_FEE_TOTAL_NGN = WAIT_FEE_DRIVER_NGN + WAIT_FEE_PLATFORM_NGN;
const MAX_WAIT_INTERVALS = 6; // 30 minutes grace billing cap before auto-cancel

function normUid(v) {
  return String(v ?? "").trim();
}

function num(v, fallback = 0) {
  const n = Number(v);
  return Number.isFinite(n) ? n : fallback;
}

/**
 * Apply one waiting-fee interval when grace window has elapsed.
 * Idempotency: wait_fee_applied_keys/{rideId}_{intervalIndex}
 */
async function applyRideWaitFeeInterval(data, context, db) {
  const uid = normUid(context?.auth?.uid);
  if (!uid) return { success: false, reason: "unauthorized" };

  const rideId = normUid(data?.rideId ?? data?.ride_id);
  if (!rideId) return { success: false, reason: "invalid_ride_id" };

  const rideSnap = await db.ref(`ride_requests/${rideId}`).get();
  const ride = rideSnap.val();
  if (!ride || typeof ride !== "object") {
    return { success: false, reason: "ride_not_found" };
  }

  const riderId = normUid(ride.rider_id);
  const driverId = normUid(ride.driver_id ?? ride.matched_driver_id);
  const isRider = riderId === uid;
  const isDriver = driverId === uid;
  if (!isRider && !isDriver) {
    return { success: false, reason: "not_trip_participant" };
  }

  const tripState = String(ride.trip_state ?? ride.status ?? "").trim().toLowerCase();
  if (tripState !== "arrived") {
    return { success: false, reason: "invalid_trip_state", trip_state: tripState };
  }

  const startedAt = num(ride.wait_fee_started_at, 0);
  if (startedAt <= 0) {
    return { success: false, reason: "wait_fee_not_started" };
  }

  const now = Date.now();
  const intervalsApplied = Math.max(0, Math.floor(num(ride.wait_fee_intervals_applied, 0)));
  const graceUntil = num(ride.wait_fee_grace_until, startedAt + WAIT_INTERVAL_MS);

  if (now < graceUntil) {
    return {
      success: true,
      reason: "grace_active",
      grace_until: graceUntil,
      remaining_ms: graceUntil - now,
      intervals_applied: intervalsApplied,
    };
  }

  const nextInterval = intervalsApplied;
  const idemKey = `wait_fee_${rideId}_${nextInterval}`;
  const idemRef = db.ref(`wait_fee_applied_keys/${idemKey}`);
  const idemSnap = await idemRef.get();
  if (idemSnap.exists()) {
    return {
      success: true,
      reason: "already_applied",
      idempotent: true,
      interval: nextInterval,
    };
  }

  if (nextInterval >= MAX_WAIT_INTERVALS) {
    return expireWaitingAndCancelRide(db, rideId, ride, riderId, driverId, {
      reason: "max_wait_intervals_exceeded",
    });
  }

  const prevDriver = num(ride.wait_fee_driver, 0);
  const prevTotal = num(ride.wait_fee_total, 0);
  const prevFare = num(ride.fare ?? ride.trip_fare_ngn, 0);
  const nextDriver = prevDriver + WAIT_FEE_DRIVER_NGN;
  const nextTotal = prevTotal + WAIT_FEE_TOTAL_NGN;
  const nextFare = prevFare + WAIT_FEE_TOTAL_NGN;
  const nextGrace = graceUntil + WAIT_INTERVAL_MS;

  const fareBreakdown =
    ride.fare_breakdown && typeof ride.fare_breakdown === "object"
      ? { ...ride.fare_breakdown }
      : {};
  fareBreakdown.waitingCharge = nextTotal;
  fareBreakdown.waitingDriverNgn = nextDriver;

  const patch = {
    wait_fee_intervals_applied: nextInterval + 1,
    wait_fee_applied: true,
    wait_fee_driver: nextDriver,
    wait_fee_platform: num(ride.wait_fee_platform, 0) + WAIT_FEE_PLATFORM_NGN,
    wait_fee_total: nextTotal,
    wait_fee_grace_until: nextGrace,
    wait_fee_last_applied_at: now,
    fare: nextFare,
    trip_fare_ngn: num(ride.trip_fare_ngn, prevFare) > 0 ? num(ride.trip_fare_ngn, prevFare) : prevFare,
    fare_breakdown: fareBreakdown,
    updated_at: now,
  };

  let txReason = "unknown";
  const tx = await db.ref(`ride_requests/${rideId}`).transaction((cur) => {
    if (!cur || typeof cur !== "object") {
      txReason = "ride_missing";
      return;
    }
    const curState = String(cur.trip_state ?? cur.status ?? "").trim().toLowerCase();
    if (curState !== "arrived") {
      txReason = "invalid_trip_state";
      return;
    }
    const applied = Math.max(0, Math.floor(num(cur.wait_fee_intervals_applied, 0)));
    if (applied > nextInterval) {
      txReason = "already_applied_race";
      return;
    }
    return { ...cur, ...patch };
  });

  if (!tx.committed) {
    return { success: false, reason: txReason };
  }

  await idemRef.set({
    ride_id: rideId,
    interval: nextInterval,
    amount_ngn: WAIT_FEE_TOTAL_NGN,
    driver_ngn: WAIT_FEE_DRIVER_NGN,
    applied_at: now,
    applied_by: uid,
  });

  console.log(
    "WAIT_FEE_INTERVAL_APPLIED",
    `rideId=${rideId}`,
    `interval=${nextInterval}`,
    `driver_ngn=${nextDriver}`,
    `grace_until=${nextGrace}`,
  );

  try {
    if (riderId) {
      await sendPushToUser(db, riderId, {
        title: "Waiting fee",
        body: `₦${WAIT_FEE_TOTAL_NGN} waiting charge added for this trip.`,
        data: { type: "wait_fee_applied", rideId },
      });
    }
  } catch (_) {
    /* best-effort */
  }

  return {
    success: true,
    reason: "interval_applied",
    interval: nextInterval,
    wait_fee_driver: nextDriver,
    wait_fee_total: nextTotal,
    grace_until: nextGrace,
  };
}

async function expireWaitingAndCancelRide(db, rideId, ride, riderId, driverId, { reason }) {
  const now = Date.now();
  const outstanding =
    num(ride.wait_fee_total, 0) > 0 ? num(ride.wait_fee_total, 0) : WAIT_FEE_TOTAL_NGN;

  let cancelReason = "unknown";
  const tx = await db.ref(`ride_requests/${rideId}`).transaction((cur) => {
    if (!cur || typeof cur !== "object") {
      cancelReason = "ride_missing";
      return;
    }
    const ts = String(cur.trip_state ?? "").trim().toLowerCase();
    if (ts === "cancelled" || ts === "completed") {
      cancelReason = "already_terminal";
      return;
    }
    return {
      ...cur,
      trip_state: "cancelled",
      status: "cancelled",
      cancelled_at: now,
      cancelled_by: "system",
      cancel_reason: reason || "waiting_window_expired",
      wait_fee_expired: true,
      updated_at: now,
    };
  });

  if (!tx.committed) {
    return { success: false, reason: cancelReason };
  }

  if (riderId && outstanding > 0) {
    const flagsRef = db.ref(`rider_payment_flags/${riderId}`);
    await flagsRef.transaction((cur) => {
      const flags = cur && typeof cur === "object" ? cur : {};
      const prev = num(flags.outstandingCancellationFeesNgn, 0);
      return {
        ...flags,
        outstandingCancellationFeesNgn: prev + outstanding,
        tripRequestAccess: "blocked",
        last_waiting_fee_at: now,
        updated_at: now,
      };
    });
  }

  console.log(
    "WAIT_FEE_EXPIRED_CANCEL",
    `rideId=${rideId}`,
    `outstanding=${outstanding}`,
    `reason=${reason}`,
  );

  return {
    success: true,
    reason: "waiting_expired_cancelled",
    outstanding_ngn: outstanding,
    cancelled: true,
  };
}

module.exports = {
  applyRideWaitFeeInterval,
  WAIT_INTERVAL_MS,
  WAIT_FEE_DRIVER_NGN,
};
