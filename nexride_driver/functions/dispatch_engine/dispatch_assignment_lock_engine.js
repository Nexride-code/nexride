/**
 * Duplicate assignment defense — ride + driver locks (transaction protected).
 */

"use strict";

const { normUid } = require("./dispatch_trip_state_engine");

const LOCK_TTL_MS = 120_000;

async function acquireAssignmentLocks(db, rideId, driverId, now = Date.now()) {
  const rid = normUid(rideId);
  const d = normUid(driverId);
  if (!rid || !d) {
    return { ok: false, reason: "invalid_input" };
  }

  const rideRef = db.ref(`dispatch_assignment_locks/${rid}`);
  const driverRef = db.ref(`dispatch_driver_assignment_locks/${d}`);

  let rideConflict = false;
  let driverConflict = false;
  let otherDriver = "";
  let otherRide = "";

  const rideTx = await rideRef.transaction((cur) => {
    rideConflict = false;
    otherDriver = "";
    if (cur && typeof cur === "object") {
      const holder = normUid(cur.driver_id);
      const exp = Number(cur.expires_at_ms ?? 0) || 0;
      if (holder && holder !== d && exp > now) {
        rideConflict = true;
        otherDriver = holder;
        return;
      }
    }
    return {
      ride_id: rid,
      driver_id: d,
      acquired_at_ms: now,
      expires_at_ms: now + LOCK_TTL_MS,
    };
  });

  if (!rideTx.committed || rideConflict) {
    console.log(
      "ASSIGNMENT_LOCK_CONFLICT",
      `rideId=${rid}`,
      `driverId=${d}`,
      `type=ride`,
      `holder=${otherDriver}`,
    );
    return { ok: false, reason: "ride_assignment_held", holder: otherDriver };
  }

  const driverTx = await driverRef.transaction((cur) => {
    driverConflict = false;
    otherRide = "";
    if (cur && typeof cur === "object") {
      const holderRide = normUid(cur.ride_id);
      const exp = Number(cur.expires_at_ms ?? 0) || 0;
      if (holderRide && holderRide !== rid && exp > now) {
        driverConflict = true;
        otherRide = holderRide;
        return;
      }
    }
    return {
      driver_id: d,
      ride_id: rid,
      acquired_at_ms: now,
      expires_at_ms: now + LOCK_TTL_MS,
    };
  });

  if (!driverTx.committed || driverConflict) {
    await rideRef.remove().catch(() => {});
    console.log(
      "ASSIGNMENT_LOCK_CONFLICT",
      `rideId=${rid}`,
      `driverId=${d}`,
      `type=driver`,
      `holderRide=${otherRide}`,
    );
    return { ok: false, reason: "driver_assignment_held", holderRide: otherRide };
  }

  console.log("ASSIGNMENT_LOCK_ACQUIRED", `rideId=${rid}`, `driverId=${d}`);
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
  if (rid) {
    await db.ref(`dispatch_assignment_locks/${rid}`).update({
      driver_id: d,
      finalized_at_ms: now,
      expires_at_ms: now + 6 * 60 * 60_000,
    });
  }
  if (d) {
    await db.ref(`dispatch_driver_assignment_locks/${d}`).update({
      ride_id: rid,
      finalized_at_ms: now,
      expires_at_ms: now + 6 * 60 * 60_000,
    });
  }
}

module.exports = {
  acquireAssignmentLocks,
  releaseAssignmentLocks,
  finalizeAssignmentLocks,
};
