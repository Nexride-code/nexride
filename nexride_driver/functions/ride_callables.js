/**
 * NexRide ride lifecycle — server source of truth.
 * All sensitive ride_requests fields are written here (Admin SDK).
 */

const admin = require("firebase-admin");

const TRIP_STATE = {
  searching: "searching",
  driver_assigned: "driver_assigned",
  driver_arriving: "driver_arriving",
  arrived: "arrived",
  in_progress: "in_progress",
  completed: "completed",
  cancelled: "cancelled",
  expired: "expired",
};

/** Legacy open-pool trip_state / status tokens → treat as searchable pool */
const LEGACY_OPEN_TRIP_STATES = new Set([
  "requested",
  "requesting",
  "searching_driver",
  "searching",
  "awaiting_match",
  "matching",
  "offered",
  "offer_pending",
  "pending_driver_acceptance",
  "pending_driver_action",
  "driver_reviewing_request",
]);

const LEGACY_OPEN_STATUS = new Set([
  "requested",
  "requesting",
  "searching",
  "searching_driver",
  "matching",
  "awaiting_match",
  "offered",
  "offer_pending",
  "assigned",
  "pending_driver_acceptance",
  "pending_driver_action",
]);

function normUid(uid) {
  return String(uid ?? "").trim();
}

function nowMs() {
  return Date.now();
}

function auditRef(db) {
  return db.ref("admin_audit_logs").push();
}

async function writeAudit(db, entry) {
  const ref = auditRef(db);
  await ref.set({
    ...entry,
    created_at: nowMs(),
  });
}

function isPlaceholderDriverId(v) {
  if (v === null || v === undefined) return true;
  const s = String(v).trim().toLowerCase();
  return (
    s.length === 0 ||
    s === "waiting" ||
    s === "pending" ||
    s === "null"
  );
}

function isOpenPoolRide(ride) {
  const ts = String(ride.trip_state ?? "").trim().toLowerCase();
  const st = String(ride.status ?? "").trim().toLowerCase();
  if (TRIP_STATE.searching === ts) return true;
  if (LEGACY_OPEN_TRIP_STATES.has(ts)) return true;
  if (LEGACY_OPEN_STATUS.has(st)) return true;
  return false;
}

function legacyUiStatusForTripState(tripState) {
  switch (tripState) {
    case TRIP_STATE.searching:
      return "searching";
    case TRIP_STATE.driver_assigned:
      return "accepted";
    case TRIP_STATE.driver_arriving:
      return "arriving";
    case TRIP_STATE.arrived:
      return "arrived";
    case TRIP_STATE.in_progress:
      return "on_trip";
    case TRIP_STATE.completed:
      return "completed";
    case TRIP_STATE.cancelled:
      return "cancelled";
    case TRIP_STATE.expired:
      return "cancelled";
    default:
      return "searching";
  }
}

function platformFeeNgn() {
  const v = Number(process.env.NEXRIDE_PLATFORM_FEE_NGN || 350);
  return Number.isFinite(v) && v > 0 ? v : 350;
}

function grossFareFromRide(ride) {
  const candidates = [
    ride.fare,
    ride.total_delivery_fee,
    ride.total_delivery_fee_paid,
    ride.grossFare,
    ride.gross_fare,
  ];
  for (const c of candidates) {
    const n = Number(c);
    if (Number.isFinite(n) && n > 0) return n;
  }
  return 0;
}

/**
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin").database.Database} db
 */
async function createRideRequest(data, context, db) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const riderId = normUid(context.auth.uid);
  const rideId = normUid(data?.ride_id ?? data?.rideId);
  if (!rideId) {
    return { success: false, reason: "invalid_ride_id" };
  }
  const bodyRider = normUid(data?.rider_id ?? data?.riderId);
  if (bodyRider && bodyRider !== riderId) {
    return { success: false, reason: "rider_mismatch" };
  }

  const marketRaw = data?.market ?? data?.city ?? "";
  const market = String(marketRaw).trim().toLowerCase().replace(/\s+/g, "_");
  if (!market) {
    return { success: false, reason: "invalid_market" };
  }

  const pickup = data?.pickup;
  const dropoff = data?.dropoff;
  if (!pickup || typeof pickup !== "object") {
    return { success: false, reason: "invalid_pickup" };
  }

  const fare = Number(data?.fare ?? 0);
  const currency = String(data?.currency ?? "NGN").trim().toUpperCase() || "NGN";
  const paymentMethod = String(data?.payment_method ?? data?.paymentMethod ?? "cash")
    .trim()
    .toLowerCase();
  const paymentStatus = String(
    data?.payment_status ?? data?.paymentStatus ?? "pending",
  )
    .trim()
    .toLowerCase();

  const distanceKm = Number(data?.distance_km ?? data?.distanceKm ?? 0) || 0;
  const etaMin = Number(data?.eta_min ?? data?.etaMin ?? 0) || 0;
  const expiresAt =
    Number(data?.expires_at ?? data?.expiresAt ?? 0) ||
    nowMs() + 15 * 60 * 1000;

  const rideRef = db.ref(`ride_requests/${rideId}`);
  const snap = await rideRef.get();
  if (snap.exists()) {
    return { success: false, reason: "ride_id_already_exists" };
  }

  const ts = nowMs();
  const payload = {
    ride_id: rideId,
    rider_id: riderId,
    driver_id: null,
    market,
    market_pool: market,
    status: "searching",
    trip_state: TRIP_STATE.searching,
    pickup,
    dropoff: dropoff && typeof dropoff === "object" ? dropoff : null,
    fare,
    currency,
    distance_km: distanceKm,
    eta_min: etaMin,
    payment_method: paymentMethod,
    payment_status: paymentStatus,
    payment_reference: String(data?.payment_reference ?? data?.paymentReference ?? "").trim() || null,
    created_at: ts,
    updated_at: ts,
    expires_at: expiresAt,
    accepted_at: null,
    completed_at: null,
    cancelled_at: null,
    service_type: String(data?.service_type ?? data?.serviceType ?? "ride").trim(),
  };

  await rideRef.set(payload);
  await writeAudit(db, {
    type: "ride_create",
    ride_id: rideId,
    rider_id: riderId,
    actor_uid: riderId,
  });

  return { success: true, rideId, reason: "created" };
}

async function acceptRideRequest(data, context, db) {
  const rideId = normUid(data?.rideId ?? data?.ride_id);
  const driverId = normUid(data?.driverId ?? data?.driver_id);
  const authUid = normUid(context.auth?.uid);

  if (!rideId || !driverId) {
    return { success: false, reason: "invalid_input" };
  }
  if (!context.auth || authUid !== driverId) {
    return { success: false, reason: "unauthorized" };
  }

  const ridePath = `ride_requests/${rideId}`;
  const rideRef = db.ref(ridePath);
  const now = nowMs();
  let failureReason = "unknown";
  let idempotent = false;

  const tx = await rideRef.transaction((current) => {
    if (!current || typeof current !== "object") {
      failureReason = "ride_missing";
      return;
    }

    const tripState = String(current.trip_state ?? "").trim().toLowerCase();
    const status = String(current.status ?? "").trim().toLowerCase();
    const rawDriverId = current.driver_id;
    const assigned = normUid(rawDriverId);

    const already =
      assigned === authUid &&
      (tripState === TRIP_STATE.driver_assigned ||
        tripState === "driver_accepted" ||
        status === "accepted");
    if (already) {
      idempotent = true;
      return current;
    }

    if (!isPlaceholderDriverId(rawDriverId)) {
      failureReason = "driver_already_set";
      return;
    }

    if (!isOpenPoolRide(current)) {
      failureReason = "status_not_open";
      return;
    }

    const expiresAt = Number(current.expires_at ?? current.request_expires_at ?? 0) || 0;
    if (expiresAt > 0 && now >= expiresAt) {
      failureReason = "expired";
      return;
    }

    return {
      ...current,
      driver_id: driverId,
      matched_driver_id: driverId,
      accepted_driver_id: driverId,
      status: "accepted",
      trip_state: TRIP_STATE.driver_assigned,
      market_pool: null,
      accepted_at: now,
      updated_at: now,
    };
  });

  if (!tx.committed && !idempotent) {
    return {
      success: false,
      reason: failureReason === "unknown" ? "not_available" : failureReason,
    };
  }

  await writeAudit(db, {
    type: "ride_accept",
    ride_id: rideId,
    driver_id: driverId,
    actor_uid: driverId,
  });

  return {
    success: true,
    idempotent,
    reason: idempotent ? "already_accepted" : "accepted",
  };
}

async function driverEnroute(data, context, db) {
  const rideId = normUid(data?.rideId ?? data?.ride_id);
  const driverId = normUid(context.auth?.uid);
  if (!rideId || !context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const rideRef = db.ref(`ride_requests/${rideId}`);
  let reason = "unknown";
  const tx = await rideRef.transaction((cur) => {
    if (!cur || typeof cur !== "object") {
      reason = "ride_missing";
      return;
    }
    if (normUid(cur.driver_id) !== driverId) {
      reason = "not_assigned_driver";
      return;
    }
    const ts = String(cur.trip_state ?? "").trim().toLowerCase();
    if (ts === TRIP_STATE.driver_arriving) {
      return cur;
    }
    if (ts !== TRIP_STATE.driver_assigned && ts !== "driver_accepted") {
      reason = "invalid_state";
      return;
    }
    const now = nowMs();
    return {
      ...cur,
      trip_state: TRIP_STATE.driver_arriving,
      status: legacyUiStatusForTripState(TRIP_STATE.driver_arriving),
      arriving_at: cur.arriving_at ?? now,
      updated_at: now,
    };
  });
  if (!tx.committed) {
    return { success: false, reason };
  }
  await writeAudit(db, { type: "ride_enroute", ride_id: rideId, actor_uid: driverId });
  return { success: true, reason: "enroute" };
}

async function driverArrived(data, context, db) {
  const rideId = normUid(data?.rideId ?? data?.ride_id);
  const driverId = normUid(context.auth?.uid);
  if (!rideId || !context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const rideRef = db.ref(`ride_requests/${rideId}`);
  let reason = "unknown";
  const tx = await rideRef.transaction((cur) => {
    if (!cur || typeof cur !== "object") {
      reason = "ride_missing";
      return;
    }
    if (normUid(cur.driver_id) !== driverId) {
      reason = "not_assigned_driver";
      return;
    }
    const ts = String(cur.trip_state ?? "").trim().toLowerCase();
    if (ts === TRIP_STATE.arrived || ts === "driver_arrived") {
      return cur;
    }
    if (ts !== TRIP_STATE.driver_arriving && ts !== "driver_arriving") {
      reason = "invalid_state";
      return;
    }
    const now = nowMs();
    return {
      ...cur,
      trip_state: TRIP_STATE.arrived,
      status: legacyUiStatusForTripState(TRIP_STATE.arrived),
      arrived_at: cur.arrived_at ?? now,
      updated_at: now,
    };
  });
  if (!tx.committed) {
    return { success: false, reason };
  }
  await writeAudit(db, { type: "ride_arrived_pickup", ride_id: rideId, actor_uid: driverId });
  return { success: true, reason: "arrived" };
}

async function startTrip(data, context, db) {
  const rideId = normUid(data?.rideId ?? data?.ride_id);
  const driverId = normUid(context.auth?.uid);
  if (!rideId || !context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const rideRef = db.ref(`ride_requests/${rideId}`);
  let reason = "unknown";
  const routeLogTimeoutMs = 3 * 60 * 1000;
  const tx = await rideRef.transaction((cur) => {
    if (!cur || typeof cur !== "object") {
      reason = "ride_missing";
      return;
    }
    if (normUid(cur.driver_id) !== driverId) {
      reason = "not_assigned_driver";
      return;
    }
    const ts = String(cur.trip_state ?? "").trim().toLowerCase();
    if (ts === TRIP_STATE.in_progress || ts === "trip_started") {
      return cur;
    }
    if (ts !== TRIP_STATE.arrived && ts !== "driver_arrived") {
      reason = "invalid_state";
      return;
    }
    const now = nowMs();
    return {
      ...cur,
      trip_state: TRIP_STATE.in_progress,
      status: legacyUiStatusForTripState(TRIP_STATE.in_progress),
      started_at: cur.started_at ?? now,
      route_log_timeout_at: now + routeLogTimeoutMs,
      has_started_route_checkpoints: false,
      route_log_trip_started_checkpoint_at: null,
      start_timeout_at: null,
      updated_at: now,
    };
  });
  if (!tx.committed) {
    return { success: false, reason };
  }
  await writeAudit(db, { type: "ride_start", ride_id: rideId, actor_uid: driverId });
  return { success: true, reason: "started" };
}

async function completeTrip(data, context, db) {
  const rideId = normUid(data?.rideId ?? data?.ride_id);
  const driverId = normUid(context.auth?.uid);
  if (!rideId || !context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const rideRef = db.ref(`ride_requests/${rideId}`);
  let reason = "unknown";
  const tx = await rideRef.transaction((cur) => {
    if (!cur || typeof cur !== "object") {
      reason = "ride_missing";
      return;
    }
    if (normUid(cur.driver_id) !== driverId) {
      reason = "not_assigned_driver";
      return;
    }
    const ts = String(cur.trip_state ?? "").trim().toLowerCase();
    if (ts === TRIP_STATE.completed || ts === "trip_completed") {
      return cur;
    }
    if (ts !== TRIP_STATE.in_progress && ts !== "trip_started") {
      reason = "invalid_state";
      return;
    }
    const now = nowMs();
    const gross = grossFareFromRide(cur);
    const fee = platformFeeNgn();
    const driverPayout = Math.max(0, gross - fee);
    const settlement = {
      grossFareNgn: gross,
      commissionAmountNgn: fee,
      driverPayoutNgn: driverPayout,
      netEarningNgn: driverPayout,
      currency: String(cur.currency ?? "NGN"),
      recorded_at: now,
      source: "driver_complete_trip",
    };
    return {
      ...cur,
      trip_state: TRIP_STATE.completed,
      status: legacyUiStatusForTripState(TRIP_STATE.completed),
      completed_at: cur.completed_at ?? now,
      trip_completed: true,
      settlement,
      grossFare: gross,
      commission: fee,
      commissionAmount: fee,
      driverPayout,
      netEarning: driverPayout,
      updated_at: now,
    };
  });
  if (!tx.committed) {
    return { success: false, reason };
  }
  const ride = tx.snapshot.val();
  const riderId = normUid(ride?.rider_id);
  const hookRef = db.ref(`trip_settlement_hooks/${rideId}`);
  await hookRef.update({
    rideId,
    rider_id: riderId,
    driver_id: driverId,
    settlementStatus: "trip_completed",
    completionState: "driver_marked_completed",
    updated_at: nowMs(),
    settlement: ride?.settlement ?? {},
  });
  await writeAudit(db, { type: "ride_complete", ride_id: rideId, actor_uid: driverId });
  return { success: true, reason: "completed" };
}

async function cancelRideRequest(data, context, db) {
  const rideId = normUid(data?.rideId ?? data?.ride_id);
  const cancelReason = String(data?.cancel_reason ?? data?.cancelReason ?? "").trim();
  if (!rideId || !context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const uid = normUid(context.auth.uid);
  const rideRef = db.ref(`ride_requests/${rideId}`);
  let reason = "unknown";
  const tx = await rideRef.transaction((cur) => {
    if (!cur || typeof cur !== "object") {
      reason = "ride_missing";
      return;
    }
    const rider = normUid(cur.rider_id);
    const driver = normUid(cur.driver_id);
    const isRider = uid === rider;
    const isDriver = uid === driver && !isPlaceholderDriverId(cur.driver_id);
    if (!isRider && !isDriver) {
      reason = "forbidden";
      return;
    }
    const tsState = String(cur.trip_state ?? "").trim().toLowerCase();
    if (
      tsState === TRIP_STATE.completed ||
      tsState === TRIP_STATE.cancelled ||
      tsState === TRIP_STATE.expired ||
      tsState === "trip_completed" ||
      tsState === "trip_cancelled"
    ) {
      reason = "already_terminal";
      return;
    }
    const now = nowMs();
    return {
      ...cur,
      trip_state: TRIP_STATE.cancelled,
      status: "cancelled",
      cancelled_at: now,
      updated_at: now,
      cancel_reason:
        cancelReason || (isRider ? "rider_cancelled" : "driver_cancelled"),
      cancel_actor: isRider ? "rider" : "driver",
      cancelled_by: isRider ? "rider" : "driver",
    };
  });
  if (!tx.committed) {
    return { success: false, reason };
  }
  await writeAudit(db, {
    type: "ride_cancel",
    ride_id: rideId,
    actor_uid: uid,
    cancel_reason: cancelReason,
  });
  return { success: true, reason: "cancelled" };
}

async function expireRideRequest(data, context, db) {
  const rideId = normUid(data?.rideId ?? data?.ride_id);
  if (!rideId || !context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const uid = normUid(context.auth.uid);
  const rideRef = db.ref(`ride_requests/${rideId}`);
  let reason = "unknown";
  const tx = await rideRef.transaction((cur) => {
    if (!cur || typeof cur !== "object") {
      reason = "ride_missing";
      return;
    }
    if (normUid(cur.rider_id) !== uid) {
      reason = "forbidden";
      return;
    }
    if (!isOpenPoolRide(cur) || !isPlaceholderDriverId(cur.driver_id)) {
      reason = "invalid_state";
      return;
    }
    const now = nowMs();
    const exp = Number(cur.expires_at ?? 0) || 0;
    if (exp > 0 && now < exp) {
      reason = "not_expired_yet";
      return;
    }
    return {
      ...cur,
      trip_state: TRIP_STATE.expired,
      status: "cancelled",
      cancelled_at: now,
      updated_at: now,
      cancel_reason: "expired",
      cancel_actor: "system",
    };
  });
  if (!tx.committed) {
    return { success: false, reason };
  }
  await writeAudit(db, { type: "ride_expire", ride_id: rideId, actor_uid: uid });
  return { success: true, reason: "expired" };
}

const PATCHABLE_TOP_LEVEL = new Set([
  "chat_ready",
  "chat_ready_at",
  "deliveryProofPhotoUrl",
  "deliveryProofSubmittedAt",
  "deliveryProofStatus",
  "deliveredAt",
  "rider_safety_alert",
  "updated_at",
]);

function isAllowedPatchKey(k) {
  if (PATCHABLE_TOP_LEVEL.has(k)) {
    return true;
  }
  return k.startsWith("dispatch_details/deliveryProof") ||
    k.startsWith("dispatch_details/pickupConfirmed") ||
    k.startsWith("dispatch_details/deliveredAt");
}

async function patchRideRequestMetadata(data, context, db) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const rideId = normUid(data?.rideId ?? data?.ride_id);
  const patch = data?.patch && typeof data.patch === "object" ? data.patch : {};
  if (!rideId || Object.keys(patch).length === 0) {
    return { success: false, reason: "invalid_input" };
  }
  const rideSnap = await db.ref(`ride_requests/${rideId}`).get();
  const ride = rideSnap.val();
  if (!ride || typeof ride !== "object") {
    return { success: false, reason: "ride_missing" };
  }
  const rider = normUid(ride.rider_id);
  const driver = normUid(ride.driver_id);
  const uid = normUid(context.auth.uid);
  if (uid !== rider && uid !== driver) {
    return { success: false, reason: "forbidden" };
  }
  const updates = {};
  for (const [k, v] of Object.entries(patch)) {
    if (!isAllowedPatchKey(k)) {
      return { success: false, reason: "disallowed_field", field: k };
    }
    updates[k] = v;
  }
  updates.updated_at = nowMs();
  await db.ref(`ride_requests/${rideId}`).update(updates);
  await writeAudit(db, {
    type: "ride_patch_metadata",
    ride_id: rideId,
    actor_uid: uid,
    keys: Object.keys(patch).join(","),
  });
  return { success: true, reason: "patched" };
}

module.exports = {
  TRIP_STATE,
  createRideRequest,
  acceptRideRequest,
  driverEnroute,
  driverArrived,
  startTrip,
  completeTrip,
  cancelRideRequest,
  expireRideRequest,
  patchRideRequestMetadata,
};
