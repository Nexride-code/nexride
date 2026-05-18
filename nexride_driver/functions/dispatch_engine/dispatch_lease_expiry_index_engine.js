/**
 * Minute-bucketed lease expiry index — avoids full lease tree scans.
 */

"use strict";

const { normUid } = require("./dispatch_trip_state_engine");

function expiryBucketMs(expiresAtMs) {
  const m = Math.floor(Number(expiresAtMs) / 60_000) * 60_000;
  return m > 0 ? m : Date.now();
}

function indexKey(driverId, leaseId) {
  return `${normUid(driverId)}_${normUid(leaseId)}`;
}

function bucketPath(bucketMs) {
  return `dispatch_lease_expiry_index/${bucketMs}`;
}

async function indexLeaseExpiry(db, { driverId, leaseId, rideId, expiresAtMs }) {
  const d = normUid(driverId);
  const lid = normUid(leaseId);
  const rid = normUid(rideId);
  const exp = Number(expiresAtMs) || 0;
  if (!d || !lid || exp <= 0) return;

  const bucket = expiryBucketMs(exp);
  const key = indexKey(d, lid);
  await db.ref(`${bucketPath(bucket)}/${key}`).set({
    driver_id: d,
    lease_id: lid,
    ride_id: rid || null,
    expires_at: exp,
    indexed_at_ms: Date.now(),
  });
}

async function removeLeaseExpiryIndex(db, driverId, leaseId, expiresAtMs) {
  const d = normUid(driverId);
  const lid = normUid(leaseId);
  if (!d || !lid) return;
  const bucket = expiryBucketMs(expiresAtMs || Date.now());
  await db.ref(`${bucketPath(bucket)}/${indexKey(d, lid)}`).remove();
}

/**
 * Process buckets at or before now (current + previous minute).
 */
async function processLeaseExpiryBuckets(db, now = Date.now()) {
  const { reconcileExpiredLease, LEASE_STATUS } = require("./dispatch_offer_lease_engine");
  const { enqueueDispatchWork } = require("./dispatch_work_queue_engine");

  let scanned = 0;
  let expired = 0;
  const ridesNeedingAdvance = new Set();

  const buckets = [
    expiryBucketMs(now),
    expiryBucketMs(now - 60_000),
    expiryBucketMs(now - 120_000),
  ];

  for (const bucket of buckets) {
    const snap = await db.ref(bucketPath(bucket)).get();
    if (!snap.exists()) continue;
    const rows = snap.val() && typeof snap.val() === "object" ? snap.val() : {};

    for (const [key, row] of Object.entries(rows)) {
      if (!row || typeof row !== "object") continue;
      scanned += 1;
      const exp = Number(row.expires_at ?? 0) || 0;
      if (exp > now) continue;

      const d = normUid(row.driver_id);
      const lid = normUid(row.lease_id);
      const rid = normUid(row.ride_id);
      if (!d || !lid) {
        await db.ref(`${bucketPath(bucket)}/${key}`).remove();
        continue;
      }

      const leaseSnap = await db.ref(`driver_offer_leases/${d}/${lid}`).get();
      const lease = leaseSnap.val();
      const st = String(lease?.lease_status ?? "").trim().toLowerCase();
      if (
        lease &&
        (st === LEASE_STATUS.OFFERED || st === LEASE_STATUS.LEASED) &&
        Number(lease.lease_expires_at ?? 0) <= now
      ) {
        console.log(
          "LEASE_EXPIRY_INDEX_HIT",
          `rideId=${rid}`,
          `driverId=${d}`,
          `leaseId=${lid}`,
          `bucket=${bucket}`,
        );
        const res = await reconcileExpiredLease(db, d, lid, lease, now);
        expired += 1;
        if (res?.rideId) ridesNeedingAdvance.add(res.rideId);
      }

      await db.ref(`${bucketPath(bucket)}/${key}`).remove();
    }

    if (bucket < expiryBucketMs(now - 120_000)) {
      await db.ref(bucketPath(bucket)).remove().catch(() => {});
    }
  }

  for (const rideId of ridesNeedingAdvance) {
    await enqueueDispatchWork(db, "matching", {
      ride_id: rideId,
      reason: "lease_expired_batch_advance",
      priority: 7,
    });
  }

  return { scanned, expired, ridesNeedingAdvance: [...ridesNeedingAdvance] };
}

module.exports = {
  indexLeaseExpiry,
  removeLeaseExpiryIndex,
  processLeaseExpiryBuckets,
  expiryBucketMs,
};
