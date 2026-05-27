/**
 * Duplicate assignment defense — ride + driver locks (transaction protected).
 * Placeholders (waiting/pending) and expired locks never block accept.
 */

"use strict";

const {
  normUid,
  isPlaceholderDriverId,
  canonicalAssignedDriverId,
} = require("./dispatch_trip_state_engine");
const { loadDispatchConfig } = require("./dispatch_config_engine");
const { rideDocumentIsTerminal } = require("../ride_pointer_orphans");

/** Small grace after offer lease so accept can finish propagation. */
const LOCK_PROPAGATION_GRACE_MS = 5_000;

function isCommittedAssignmentHolder(driverId) {
  return !isPlaceholderDriverId(driverId);
}

function lockExpiresAtMs(lock) {
  if (!lock || typeof lock !== "object") {
    return 0;
  }
  return Number(lock.expires_at_ms ?? lock.expiresAtMs ?? 0) || 0;
}

function lockIsStale(lock, now) {
  const exp = lockExpiresAtMs(lock);
  return exp <= 0 || exp <= now;
}

function lockHolderDriverId(lock) {
  return normUid(lock?.driver_id ?? lock?.driverId);
}

function lockHolderRideId(lock) {
  return normUid(lock?.ride_id ?? lock?.rideId);
}

function buildLockRecord(rideId, driverId, now, ttlMs) {
  return {
    ride_id: rideId,
    driver_id: driverId,
    acquired_at_ms: now,
    expires_at_ms: now + ttlMs,
  };
}

/**
 * True when a non-stale driver lock on `heldRideId` should not block accept on `targetRideId`.
 * After accept, `finalizeAssignmentLocks` can hold a multi-hour lock; completed/cancelled trips
 * and cleared active-ride pointers must not block the next offer.
 */
async function shouldClearDriverLockBlockingAccept(
  db,
  driverId,
  heldRideId,
  targetRideId,
) {
  const d = normUid(driverId);
  const held = normUid(heldRideId);
  const target = normUid(targetRideId);
  if (!d || !held || held === target) {
    return false;
  }

  const [activeDarSnap, activeFieldSnap, heldSnap] = await Promise.all([
    db.ref(`driver_active_ride/${d}`).get(),
    db.ref(`drivers/${d}/active_ride_id`).get(),
    db.ref(`ride_requests/${held}`).get(),
  ]);
  const activeRide =
    normUid(activeDarSnap.val()?.ride_id ?? activeDarSnap.val()?.rideId) ||
    normUid(activeFieldSnap.val()) ||
    "";

  if (activeRide && activeRide !== held) {
    return true;
  }
  if (!heldSnap.exists()) {
    return true;
  }
  const heldRide = heldSnap.val();
  if (!heldRide || typeof heldRide !== "object") {
    return true;
  }
  if (rideDocumentIsTerminal(heldRide)) {
    return true;
  }

  const assigned = canonicalAssignedDriverId(heldRide);
  if (!assigned || assigned !== d) {
    return true;
  }
  // Still assigned on held ride but driver is not actively on it — finished/stale lock.
  if (!activeRide) {
    return true;
  }
  return false;
}

/**
 * @param {import("firebase-admin/database").Database} db
 * @param {string} rideId
 * @param {string} driverId
 * @param {number} [now]
 */
async function acquireAssignmentLocks(db, rideId, driverId, now = Date.now()) {
  const rid = normUid(rideId);
  const d = normUid(driverId);
  if (!rid || !d) {
    return { ok: false, reason: "invalid_input" };
  }

  const dispatchCfg = await loadDispatchConfig(db);
  const lockTtlMs =
    Number(dispatchCfg.driver_offer_lease_ms ?? 30_000) + LOCK_PROPAGATION_GRACE_MS;

  const rideRef = db.ref(`dispatch_assignment_locks/${rid}`);
  const driverRef = db.ref(`dispatch_driver_assignment_locks/${d}`);

  console.log(
    "ASSIGNMENT_LOCK_CHECK",
    `rideId=${rid}`,
    `driverId=${d}`,
    `lockTtlMs=${lockTtlMs}`,
    `now=${now}`,
  );

  let rideConflict = false;
  let driverConflict = false;
  let otherDriver = "";
  let otherRide = "";
  let rideStaleCleared = false;
  let driverStaleCleared = false;

  const rideTx = await rideRef.transaction((cur) => {
    rideConflict = false;
    otherDriver = "";
    if (cur && typeof cur === "object") {
      const holder = lockHolderDriverId(cur);
      const holderRide = lockHolderRideId(cur);
      const stale = lockIsStale(cur, now);
      if (stale) {
        rideStaleCleared = true;
        console.log(
          "ASSIGNMENT_LOCK_STALE_CLEAR",
          `type=ride`,
          `rideId=${rid}`,
          `priorHolder=${holder || "(none)"}`,
          `priorRide=${holderRide || "(none)"}`,
          `expires_at_ms=${lockExpiresAtMs(cur)}`,
        );
      } else if (holderRide === rid && (!isCommittedAssignmentHolder(holder) || holder === d)) {
        console.log(
          "ASSIGNMENT_OWNER_RESOLVED",
          `type=ride_reentrant`,
          `rideId=${rid}`,
          `driverId=${d}`,
          `priorHolder=${holder || "(none)"}`,
        );
      } else if (isCommittedAssignmentHolder(holder) && holder !== d) {
        rideConflict = true;
        otherDriver = holder;
        console.log(
          "ASSIGNMENT_COMMIT_ABORT",
          `type=ride`,
          `rideId=${rid}`,
          `driverId=${d}`,
          `holder=${holder}`,
        );
        return;
      }
    }
    return buildLockRecord(rid, d, now, lockTtlMs);
  });

  if (!rideTx.committed || rideConflict) {
    console.log(
      "ASSIGNMENT_LOCK_CONFLICT",
      `rideId=${rid}`,
      `driverId=${d}`,
      `type=ride`,
      `holder=${otherDriver}`,
      `staleCleared=${rideStaleCleared}`,
    );
    return {
      ok: false,
      reason: isCommittedAssignmentHolder(otherDriver) ? "ride_assignment_held" : "ride_lock_busy",
      holder: otherDriver,
    };
  }

  const driverLockPre = await driverRef.get();
  const driverLockVal =
    driverLockPre.exists() && driverLockPre.val() && typeof driverLockPre.val() === "object"
      ? driverLockPre.val()
      : null;
  const preHeldRide = lockHolderRideId(driverLockVal);
  if (
    driverLockVal &&
    preHeldRide &&
    preHeldRide !== rid &&
    !lockIsStale(driverLockVal, now)
  ) {
    const clearPre = await shouldClearDriverLockBlockingAccept(db, d, preHeldRide, rid);
    if (clearPre) {
      console.log(
        "ASSIGNMENT_LOCK_STALE_CLEAR",
        `type=driver_precheck`,
        `driverId=${d}`,
        `priorRide=${preHeldRide}`,
        `targetRide=${rid}`,
      );
      await driverRef.remove().catch(() => {});
    }
  }

  const driverTx = await driverRef.transaction((cur) => {
    driverConflict = false;
    otherRide = "";
    if (cur && typeof cur === "object") {
      const holderRide = lockHolderRideId(cur);
      const holderDriver = lockHolderDriverId(cur);
      const stale = lockIsStale(cur, now);
      if (stale) {
        driverStaleCleared = true;
        console.log(
          "ASSIGNMENT_LOCK_STALE_CLEAR",
          `type=driver`,
          `driverId=${d}`,
          `priorRide=${holderRide || "(none)"}`,
          `expires_at_ms=${lockExpiresAtMs(cur)}`,
        );
      } else if (holderRide === rid) {
        console.log(
          "ASSIGNMENT_OWNER_RESOLVED",
          `type=driver_reentrant`,
          `rideId=${rid}`,
          `driverId=${d}`,
        );
      } else if (holderRide && holderRide !== rid) {
        driverConflict = true;
        otherRide = holderRide;
        console.log(
          "ASSIGNMENT_COMMIT_ABORT",
          `type=driver`,
          `rideId=${rid}`,
          `driverId=${d}`,
          `holderRide=${holderRide}`,
          `holderDriver=${holderDriver || d}`,
        );
        return;
      }
    }
    return buildLockRecord(rid, d, now, lockTtlMs);
  });

  if (!driverTx.committed || driverConflict) {
    await rideRef.remove().catch(() => {});
    console.log(
      "ASSIGNMENT_LOCK_CONFLICT",
      `rideId=${rid}`,
      `driverId=${d}`,
      `type=driver`,
      `holderRide=${otherRide}`,
      `staleCleared=${driverStaleCleared}`,
    );
    return {
      ok: false,
      reason: "driver_assignment_held",
      holderRide: otherRide,
    };
  }

  console.log(
    "ASSIGNMENT_LOCK_ACQUIRED",
    `rideId=${rid}`,
    `driverId=${d}`,
    `ttlMs=${lockTtlMs}`,
    `rideStaleCleared=${rideStaleCleared}`,
    `driverStaleCleared=${driverStaleCleared}`,
  );
  return { ok: true, ride_id: rid, driver_id: d };
}

async function releaseAssignmentLocks(db, rideId, driverId) {
  const rid = normUid(rideId);
  const d = normUid(driverId);
  const updates = {};
  if (rid) updates[`dispatch_assignment_locks/${rid}`] = null;
  if (d) updates[`dispatch_driver_assignment_locks/${d}`] = null;
  if (Object.keys(updates).length) {
    await db.ref().update(updates);
  }
}

async function finalizeAssignmentLocks(db, rideId, driverId) {
  const rid = normUid(rideId);
  const d = normUid(driverId);
  const now = Date.now();
  const dispatchCfg = await loadDispatchConfig(db);
  const lockTtlMs =
    Number(dispatchCfg.driver_offer_lease_ms ?? 30_000) + 6 * 60 * 60_000;
  if (rid) {
    await db.ref(`dispatch_assignment_locks/${rid}`).update({
      driver_id: d,
      finalized_at_ms: now,
      expires_at_ms: now + lockTtlMs,
    });
  }
  if (d) {
    await db.ref(`dispatch_driver_assignment_locks/${d}`).update({
      ride_id: rid,
      finalized_at_ms: now,
      expires_at_ms: now + lockTtlMs,
    });
  }
  console.log("ASSIGNMENT_COMMIT_SUCCESS", `rideId=${rid}`, `driverId=${d}`);
}

module.exports = {
  LOCK_PROPAGATION_GRACE_MS,
  acquireAssignmentLocks,
  releaseAssignmentLocks,
  finalizeAssignmentLocks,
  shouldClearDriverLockBlockingAccept,
  isCommittedAssignmentHolder,
  lockIsStale,
};
