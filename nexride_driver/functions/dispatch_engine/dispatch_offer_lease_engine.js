/**
 * Offer lease lifecycle — production duplicate-safe dispatch offers.
 */

"use strict";

const { normUid } = require("./dispatch_trip_state_engine");
const { loadDispatchConfig } = require("./dispatch_config_engine");
const { incrementMetric, patchDispatchMetrics } = require("./dispatch_metrics_engine");
const { getDispatchGeneration } = require("./dispatch_generation_engine");

const LEASE_STATUS = {
  OFFERED: "offered",
  LEASED: "leased",
  ACCEPTED: "accepted",
  EXPIRED: "expired",
  CANCELLED: "cancelled",
  REASSIGNED: "reassigned",
  COMPLETED: "completed",
};

function newLeaseId(db) {
  try {
    const root = db.ref();
    if (typeof root.push === "function") {
      const key = root.push().key;
      if (key) return key;
    }
  } catch (_) {}
  return `lease_${Date.now()}_${Math.random().toString(36).slice(2, 12)}`;
}

/**
 * Create canonical lease + queue row fields.
 */
async function createOfferLease(db, params) {
  const {
    rideId,
    driverId,
    offerPayload = {},
    offerAttempt = 1,
    popupGeneration = 0,
    source = "fanout",
  } = params;
  const rid = normUid(rideId);
  const d = normUid(driverId);
  if (!rid || !d) {
    return { ok: false, reason: "invalid_ids" };
  }

  const dispatchGen =
    Number(popupGeneration) > 0
      ? Number(popupGeneration)
      : await getDispatchGeneration(db, rid);

  const cfg = await loadDispatchConfig(db);
  const now = Date.now();
  const leaseId = newLeaseId(db);
  const leaseExpiresAt = now + cfg.driver_offer_lease_ms;

  const lease = {
    lease_id: leaseId,
    lease_created_at: now,
    lease_expires_at: leaseExpiresAt,
    lease_status: LEASE_STATUS.OFFERED,
    offer_attempt: offerAttempt,
    popup_generation: dispatchGen,
    dispatch_generation: dispatchGen,
    ride_id: rid,
    driver_id: d,
    source,
    config_lease_ms: cfg.driver_offer_lease_ms,
  };

  const queuePayload = {
    ...offerPayload,
    lease_id: leaseId,
    lease_created_at: now,
    lease_expires_at: leaseExpiresAt,
    offer_attempt: offerAttempt,
    popup_generation: dispatchGen,
    dispatch_generation: dispatchGen,
    expires_at: leaseExpiresAt,
    request_expires_at: leaseExpiresAt,
  };

  await db.ref().update({
    [`driver_offer_leases/${d}/${leaseId}`]: lease,
    [`ride_requests/${rid}/offer_leases/${leaseId}`]: lease,
    [`drivers/${d}/active_offer_lease_id`]: leaseId,
    [`drivers/${d}/active_offer_trip_id`]: rid,
    [`drivers/${d}/last_offer_generation`]: dispatchGen,
    [`ride_requests/${rid}/match_debug/last_lease_id`]: leaseId,
    [`ride_requests/${rid}/match_debug/last_offer_generation`]: dispatchGen,
  });

  console.log(
    "MATCHING_LEASE_CREATED",
    `rideId=${rid}`,
    `driverId=${d}`,
    `leaseId=${leaseId}`,
    `expiresAt=${leaseExpiresAt}`,
    `attempt=${offerAttempt}`,
    `generation=${dispatchGen}`,
  );

  await patchDispatchMetrics(db, rid, {
    first_offer_at: now,
    last_lease_id: leaseId,
    last_offer_generation: dispatchGen,
    dispatch_generation: dispatchGen,
  });

  try {
    const { indexLeaseExpiry } = require("./dispatch_lease_expiry_index_engine");
    await indexLeaseExpiry(db, {
      driverId: d,
      leaseId,
      rideId: rid,
      expiresAtMs: leaseExpiresAt,
    });
  } catch (_) {}

  return { ok: true, leaseId, lease, queuePayload, leaseExpiresAt };
}

function leaseIsActive(lease, now = Date.now()) {
  if (!lease || typeof lease !== "object") return false;
  const st = String(lease.lease_status ?? "").trim().toLowerCase();
  if (st !== LEASE_STATUS.OFFERED && st !== LEASE_STATUS.LEASED) return false;
  const exp = Number(lease.lease_expires_at ?? 0) || 0;
  return exp > 0 && now < exp;
}

/**
 * Validate lease for accept authority.
 */
function validateLeaseForAccept(lease, rideId, driverId, now = Date.now()) {
  const rid = normUid(rideId);
  const d = normUid(driverId);
  if (!lease || typeof lease !== "object") {
    return { valid: false, reason: "lease_missing" };
  }
  if (normUid(lease.ride_id) !== rid) {
    return { valid: false, reason: "lease_ride_mismatch" };
  }
  if (normUid(lease.driver_id) !== d) {
    return { valid: false, reason: "lease_driver_mismatch" };
  }
  const st = String(lease.lease_status ?? "").trim().toLowerCase();
  if (st === LEASE_STATUS.ACCEPTED) {
    return { valid: true, reason: "lease_already_accepted", idempotent: true };
  }
  if (st === LEASE_STATUS.CANCELLED || st === LEASE_STATUS.EXPIRED) {
    return { valid: false, reason: "lease_inactive" };
  }
  const exp = Number(lease.lease_expires_at ?? 0) || 0;
  if (exp > 0 && now > exp) {
    return { valid: false, reason: "lease_expired" };
  }
  return { valid: true, reason: "lease_active" };
}

/**
 * On successful accept: lock winner lease, cancel all others for ride.
 */
async function finalizeLeasesOnAccept(db, rideId, winnerDriverId, winnerLeaseId) {
  const rid = normUid(rideId);
  const winner = normUid(winnerDriverId);
  const winLease = normUid(winnerLeaseId);
  if (!rid || !winner) return { cancelled: 0 };

  console.log(
    "MATCHING_ACCEPT_LOCK",
    `rideId=${rid}`,
    `driverId=${winner}`,
    `leaseId=${winLease || "(none)"}`,
  );

  const snap = await db.ref(`ride_requests/${rid}/offer_leases`).get();
  const leases = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  const updates = {};
  let cancelled = 0;

  for (const [leaseId, lease] of Object.entries(leases)) {
    if (!lease || typeof lease !== "object") continue;
    const d = normUid(lease.driver_id);
    const isWinner = d === winner && (!winLease || leaseId === winLease);
    const status = isWinner ? LEASE_STATUS.ACCEPTED : LEASE_STATUS.CANCELLED;
    updates[`ride_requests/${rid}/offer_leases/${leaseId}/lease_status`] = status;
    updates[`ride_requests/${rid}/offer_leases/${leaseId}/resolved_at_ms`] = Date.now();
    if (d) {
      updates[`driver_offer_leases/${d}/${leaseId}/lease_status`] = status;
      updates[`driver_offer_leases/${d}/${leaseId}/resolved_at_ms`] = Date.now();
      if (!isWinner) {
        updates[`driver_offer_queue/${d}/${rid}`] = null;
        updates[`driver_offer_queue_debug/${d}/${rid}`] = null;
        updates[`ride_offer_fanout/${rid}/${d}`] = null;
        if (status === LEASE_STATUS.CANCELLED) cancelled += 1;
      } else {
        updates[`drivers/${d}/active_offer_lease_id`] = leaseId;
        updates[`drivers/${d}/active_offer_trip_id`] = rid;
      }
    }
  }

  updates[`ride_requests/${rid}/dispatch_locked`] = true;
  updates[`ride_requests/${rid}/matching_stopped_at_ms`] = Date.now();

  if (Object.keys(updates).length) {
    await db.ref().update(updates);
  }

  await patchDispatchMetrics(db, rid, {
    accepted_at: Date.now(),
    matched_at: Date.now(),
    winning_driver_id: winner,
    winning_lease_id: winLease || null,
  });

  return { cancelled, winner: winLease };
}

/**
 * Full reconciliation when a single offer lease expires.
 */
async function reconcileExpiredLease(db, driverId, leaseId, lease, now = Date.now()) {
  const d = normUid(driverId);
  const lid = normUid(leaseId);
  const rid = normUid(lease?.ride_id);
  if (!d || !lid) return { advanced: false };

  const updates = {
    [`driver_offer_leases/${d}/${lid}/lease_status`]: LEASE_STATUS.EXPIRED,
    [`driver_offer_leases/${d}/${lid}/expired_at_ms`]: now,
  };
  if (rid) {
    updates[`ride_requests/${rid}/offer_leases/${lid}/lease_status`] = LEASE_STATUS.EXPIRED;
    updates[`driver_offer_queue/${d}/${rid}`] = null;
    updates[`driver_offer_queue_debug/${d}/${rid}`] = null;
    updates[`ride_offer_fanout/${rid}/${d}`] = null;
    await incrementMetric(db, rid, "lease_expire_count", 1);
    await incrementMetric(db, rid, "retry_count", 1);
    try {
      const { bumpHotRideCounter } = require("./dispatch_hot_ride_engine");
      await bumpHotRideCounter(db, rid, "lease_expire_count", 1);
    } catch (_) {}
  }
  const activeLease = normUid((await db.ref(`drivers/${d}/active_offer_lease_id`).get()).val());
  if (activeLease === lid) {
    updates[`drivers/${d}/active_offer_lease_id`] = null;
    updates[`drivers/${d}/active_offer_trip_id`] = null;
  }
  await db.ref().update(updates);
  try {
    const { removeLeaseExpiryIndex } = require("./dispatch_lease_expiry_index_engine");
    await removeLeaseExpiryIndex(db, d, lid, Number(lease?.lease_expires_at ?? now));
  } catch (_) {}
  console.log("MATCHING_LEASE_EXPIRED", `rideId=${rid}`, `driverId=${d}`, `leaseId=${lid}`);
  return { rideId: rid, advanced: Boolean(rid) };
}

/**
 * Expire leases past TTL; return ride ids needing batch advance.
 */
async function expireStaleLeasesImpl(db) {
  try {
    const { processLeaseExpiryBuckets } = require("./dispatch_lease_expiry_index_engine");
    const indexed = await processLeaseExpiryBuckets(db);
    if (indexed.expired > 0 || indexed.scanned > 0) {
      return indexed;
    }
  } catch (e) {
    console.log("LEASE_EXPIRY_INDEX_FALLBACK", String(e?.message || e));
  }

  const now = Date.now();
  let scanned = 0;
  let expired = 0;
  const ridesNeedingAdvance = new Set();

  const snap = await db.ref("driver_offer_leases").limitToFirst(500).get();
  const byDriver = snap.val() && typeof snap.val() === "object" ? snap.val() : {};

  for (const [driverId, leases] of Object.entries(byDriver)) {
    const d = normUid(driverId);
    if (!d || !leases || typeof leases !== "object") continue;
    for (const [leaseId, lease] of Object.entries(leases)) {
      if (!lease || typeof lease !== "object") continue;
      scanned += 1;
      const st = String(lease.lease_status ?? "").trim().toLowerCase();
      if (st !== LEASE_STATUS.OFFERED && st !== LEASE_STATUS.LEASED) continue;
      const exp = Number(lease.lease_expires_at ?? 0) || 0;
      if (exp <= 0 || now <= exp) continue;

      const rid = normUid(lease.ride_id);
      const updates = {
        [`driver_offer_leases/${d}/${leaseId}/lease_status`]: LEASE_STATUS.EXPIRED,
        [`driver_offer_leases/${d}/${leaseId}/expired_at_ms`]: now,
      };
      if (rid) {
        updates[`ride_requests/${rid}/offer_leases/${leaseId}/lease_status`] =
          LEASE_STATUS.EXPIRED;
        updates[`driver_offer_queue/${d}/${rid}`] = null;
        updates[`driver_offer_queue_debug/${d}/${rid}`] = null;
        updates[`ride_offer_fanout/${rid}/${d}`] = null;
        ridesNeedingAdvance.add(rid);
        await incrementMetric(db, rid, "lease_expire_count", 1);
      }
      const activeLease = normUid(
        (await db.ref(`drivers/${d}/active_offer_lease_id`).get()).val(),
      );
      if (activeLease === leaseId) {
        updates[`drivers/${d}/active_offer_lease_id`] = null;
        updates[`drivers/${d}/active_offer_trip_id`] = null;
      }
      await db.ref().update(updates);
      expired += 1;
      console.log(
        "MATCHING_LEASE_EXPIRED",
        `rideId=${rid}`,
        `driverId=${d}`,
        `leaseId=${leaseId}`,
      );
    }
  }

  return { scanned, expired, ridesNeedingAdvance: [...ridesNeedingAdvance] };
}

async function clearLeasesForRide(db, rideId, exceptDriverId = "") {
  const rid = normUid(rideId);
  if (!rid) return;
  const snap = await db.ref(`ride_requests/${rid}/offer_leases`).get();
  const leases = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  const updates = {};
  const except = normUid(exceptDriverId);
  for (const [leaseId, lease] of Object.entries(leases)) {
    const d = normUid(lease?.driver_id);
    if (!d) continue;
    if (except && d === except) continue;
    updates[`driver_offer_leases/${d}/${leaseId}/lease_status`] = LEASE_STATUS.CANCELLED;
    updates[`ride_requests/${rid}/offer_leases/${leaseId}/lease_status`] =
      LEASE_STATUS.CANCELLED;
    updates[`driver_offer_leases/${d}/${leaseId}`] = null;
    updates[`ride_requests/${rid}/offer_leases/${leaseId}`] = null;
  }
  if (Object.keys(updates).length) {
    await db.ref().update(updates);
  }
}

module.exports = {
  LEASE_STATUS,
  createOfferLease,
  leaseIsActive,
  validateLeaseForAccept,
  finalizeLeasesOnAccept,
  reconcileExpiredLease,
  expireStaleLeasesImpl,
  clearLeasesForRide,
};
