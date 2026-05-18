/**
 * Hot-ride protection — cooldown runaway reruns.
 */

"use strict";

const { normUid } = require("./dispatch_trip_state_engine");

const THRESHOLDS = {
  rerun_count: 18,
  repair_count: 12,
  lease_expire_count: 25,
  orchestrator_attempts: 20,
};

const COOLDOWN_MS = 90_000;

async function readHotRide(db, rideId) {
  const rid = normUid(rideId);
  if (!rid) return null;
  const snap = await db.ref(`dispatch_hot_rides/${rid}`).get();
  if (!snap.exists()) return null;
  return snap.val() && typeof snap.val() === "object" ? snap.val() : null;
}

async function bumpHotRideCounter(db, rideId, field, delta = 1, extra = {}) {
  const rid = normUid(rideId);
  if (!rid) return null;
  const ref = db.ref(`dispatch_hot_rides/${rid}`);
  const snap = await ref.get();
  const cur = snap.exists() && typeof snap.val() === "object" ? snap.val() : {};
  const next = (Number(cur[field] ?? 0) || 0) + delta;
  const patch = {
    [field]: next,
    updated_at_ms: Date.now(),
    last_failure_reason: extra.last_failure_reason ?? cur.last_failure_reason ?? null,
  };
  await ref.update(patch);
  return { ...cur, ...patch };
}

async function evaluateHotRidePolicy(db, rideId) {
  const rid = normUid(rideId);
  if (!rid) return { allowed: true };

  const row = (await readHotRide(db, rid)) || {};
  const cooldownUntil = Number(row.cooldown_until_ms ?? 0) || 0;
  if (cooldownUntil > Date.now()) {
    console.log(
      "HOT_RIDE_COOLDOWN",
      `rideId=${rid}`,
      `until=${cooldownUntil}`,
      `reason=${row.last_failure_reason ?? "threshold"}`,
    );
    return {
      allowed: false,
      reason: "hot_ride_cooldown",
      cooldown_until_ms: cooldownUntil,
      batchSizeAdjust: -2,
      retrySpacingMs: 15_000,
    };
  }

  for (const [field, limit] of Object.entries(THRESHOLDS)) {
    if ((Number(row[field] ?? 0) || 0) >= limit) {
      const until = Date.now() + COOLDOWN_MS;
      await db.ref(`dispatch_hot_rides/${rid}`).update({
        cooldown_until_ms: until,
        last_failure_reason: `${field}_exceeded`,
        throttled_at_ms: Date.now(),
      });
      console.log("HOT_RIDE_COOLDOWN", `rideId=${rid}`, `field=${field}`, `limit=${limit}`);
      return {
        allowed: false,
        reason: "hot_ride_threshold",
        cooldown_until_ms: until,
        batchSizeAdjust: -3,
        retrySpacingMs: 20_000,
      };
    }
  }

  return { allowed: true };
}

async function recordOrchestratorAttempt(db, rideId) {
  return bumpHotRideCounter(db, rideId, "orchestrator_attempts", 1);
}

module.exports = {
  THRESHOLDS,
  readHotRide,
  bumpHotRideCounter,
  evaluateHotRidePolicy,
  recordOrchestratorAttempt,
};
