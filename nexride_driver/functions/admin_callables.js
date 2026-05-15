/**
 * Admin-only HTTPS callables (verify `admins/{uid}` or `auth.token.admin`).
 */

const { logger } = require("firebase-functions");
const admin = require("firebase-admin");
const { FieldValue, FieldPath } = require("firebase-admin/firestore");
const { getAuth } = require("firebase-admin/auth");
const { normUid } = require("./admin_auth");
const adminPerms = require("./admin_permissions");
const withdrawFlow = require("./withdraw_flow");
const { fanOutDriverOffersIfEligible, cancelRideRequest } = require("./ride_callables");
const {
  fanOutDeliveryOffersIfEligible,
  clearDeliveryFanoutAndOffers,
  deliveryUiMirrorFields,
  DELIVERY_STATE,
  TERMINAL_DELIVERY,
} = require("./delivery_callables");
const { syncRideTrackPublic } = require("./track_public");
const { sendPushToUser } = require("./push_notifications");
const { parseAdminListParams } = require("./admin_list_params");
const {
  driverProfileLooksCommittedForRiderExclusion,
} = require("./admin_rider_metrics");
const {
  loadAdminRiderDirectoryContext,
  classifyUserForRiderDirectory,
  classifyAuthUserForRiderDirectory,
  attachClassificationDebug,
  enrichRiderRowWithProfileCompleteness,
  authUserToProfileRow,
} = require("./admin_rider_classification");
const adminAuditLog = require("./admin_audit_log");

function nowMs() {
  return Date.now();
}

async function writeAdminAudit(db, entry) {
  await adminAuditLog.writeAdminAuditLog(db, adminAuditLog.fromLegacyAuditEntry(entry));
}

const ADMIN_TAB_SOFT_BYTES = 100 * 1024;
const ADMIN_TAB_HARD_BYTES = 1024 * 1024;

function jsonUtf8Bytes(obj) {
  try {
    return Buffer.byteLength(JSON.stringify(obj == null ? {} : obj), "utf8");
  } catch (e) {
    return 0;
  }
}

/** Log payload size; hard-reject >1MB for admin tab callables (Phase 3M). */
function finalizeDriverTabResponse(name, payload) {
  const bytes = jsonUtf8Bytes(payload);
  if (bytes > ADMIN_TAB_HARD_BYTES) {
    logger.warn("[AdminPerf][PAYLOAD_WARN]", {
      surface: "callable",
      name,
      bytes,
      band: "hard_reject",
      hard: ADMIN_TAB_HARD_BYTES,
    });
    return { success: false, reason: "payload_too_large", approx_bytes: bytes };
  }
  if (bytes > ADMIN_TAB_SOFT_BYTES) {
    logger.warn("[AdminPerf][PAYLOAD_WARN]", {
      surface: "callable",
      name,
      bytes,
      band: "soft",
      soft: ADMIN_TAB_SOFT_BYTES,
    });
  } else {
    logger.info("[AdminCallable]", { name, payload_bytes: bytes });
  }
  return payload;
}

async function _driverPrimaryExists(db, driverId) {
  const dSnap = await db.ref(`drivers/${driverId}`).get();
  const exists = typeof dSnap.exists === "function" ? dSnap.exists() : !!dSnap.exists;
  if (!exists || !dSnap.val()) {
    return { ok: false, snap: dSnap, raw: null };
  }
  return { ok: true, snap: dSnap, raw: dSnap.val() };
}

function pickupAreaHint(ride) {
  const p = ride?.pickup && typeof ride.pickup === "object" ? ride.pickup : {};
  return (
    String(ride?.pickup_area ?? p.area ?? p.city ?? "").trim().slice(0, 80) || "—"
  );
}

function dropoffAreaHint(ride) {
  const d = ride?.dropoff && typeof ride.dropoff === "object" ? ride.dropoff : {};
  return (
    String(ride?.destination_area ?? ride?.dropoff_area ?? d.area ?? d.city ?? d.address ?? "").trim().slice(0, 80) ||
    "—"
  );
}

async function _adminGate(functionName, context, db) {
  const err = await adminPerms.enforceCallable(db, context, functionName);
  if (err) {
    const uid = normUid(context?.auth?.uid);
    logger.warn(
      `ADMIN_CALL_DENIED function=${functionName} uid=${uid || "none"} body=${JSON.stringify(err)}`,
    );
    return err;
  }
  logger.info(`ADMIN_CALL_ALLOWED function=${functionName} uid=${normUid(context?.auth?.uid)}`);
  return null;
}

async function adminListLiveRides(_data, context, db) {
  const _rbac = await _adminGate("adminListLiveRides", context, db);
  if (_rbac) return _rbac;
  const snap = await db.ref("active_trips").get();
  const entries = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  const rideIds = Object.keys(entries).slice(0, 150);
  const rides = [];
  for (const rideId of rideIds) {
    const rSnap = await db.ref(`ride_requests/${rideId}`).get();
    const v = rSnap.val();
    if (!v || typeof v !== "object") continue;
    rides.push({
      ride_id: rideId,
      trip_state: v.trip_state ?? null,
      status: v.status ?? null,
      rider_id: normUid(v.rider_id),
      rider_name: String(v.rider_name ?? "").trim() || null,
      driver_id: normUid(v.driver_id) || null,
      driver_name: String(v.driver_name ?? "").trim() || null,
      fare: Number(v.fare ?? 0) || 0,
      currency: String(v.currency ?? "NGN"),
      payment_status: String(v.payment_status ?? ""),
      payment_method: String(v.payment_method ?? ""),
      receipt_uploaded: v.receipt_uploaded === true,
      bank_transfer_receipt_url: String(v.bank_transfer_receipt_url ?? "").trim() || null,
      pickup_area: pickupAreaHint(v),
      dropoff_area: dropoffAreaHint(v),
      updated_at: Number(v.updated_at ?? 0) || 0,
    });
  }
  rides.sort((a, b) => (b.updated_at || 0) - (a.updated_at || 0));
  return { success: true, rides };
}

async function adminGetRideDetails(data, context, db) {
  const _rbac = await _adminGate("adminGetRideDetails", context, db);
  if (_rbac) return _rbac;
  const rideId = normUid(data?.rideId ?? data?.ride_id);
  if (!rideId) {
    return { success: false, reason: "invalid_ride_id" };
  }
  const rSnap = await db.ref(`ride_requests/${rideId}`).get();
  const ride = rSnap.val();
  if (!ride || typeof ride !== "object") {
    return { success: false, reason: "not_found" };
  }
  const trackToken = String(ride.track_token ?? "").trim() || null;
  const payments = [];
  const refKeys = new Set(
    [ride.payment_reference, ride.customer_transaction_reference]
      .map((x) => String(x ?? "").trim())
      .filter(Boolean),
  );
  for (const refKey of refKeys) {
    const [txSnap, paySnap] = await Promise.all([
      db.ref(`payment_transactions/${refKey}`).get(),
      db.ref(`payments/${refKey}`).get(),
    ]);
    const row = txSnap.val() || paySnap.val();
    if (row && typeof row === "object") {
      payments.push({
        reference: refKey,
        verified: !!row.verified,
        amount: Number(row.amount ?? 0) || 0,
        ride_id: row.ride_id ?? null,
        updated_at: Number(row.updated_at ?? 0) || 0,
      });
    }
  }
  return {
    success: true,
    ride,
    track_token: trackToken,
    payments,
  };
}

/** Legacy open-pool tokens (aligned with ride_callables) for ops bucketing only. */
const LEGACY_OPEN_TRIP_STATES_OPS = new Set([
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

const LEGACY_OPEN_STATUS_OPS = new Set([
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

function isPlaceholderDriverIdOps(v) {
  if (v == null || v === undefined) return true;
  const s = String(v).trim().toLowerCase();
  return s.length === 0 || s === "waiting" || s === "pending" || s === "null";
}

function deliveryAssignedDriverId(row) {
  const raw = row?.driver_id ?? row?.driverId;
  if (isPlaceholderDriverIdOps(raw)) return "";
  const c = normUid(row?.customer_id);
  const d = normUid(raw);
  if (c && d === c) return "";
  return d;
}

function rideOpsUiBucket(ride) {
  const ts = String(ride?.trip_state ?? "").trim().toLowerCase();
  const st = String(ride?.status ?? "").trim().toLowerCase();
  if (st === "cancelled" || ts === "cancelled" || ts === "trip_cancelled") return "cancelled";
  if (ts === "completed" || st === "completed" || ts === "trip_completed") return "completed";
  if (ts === "in_progress") return "in_progress";
  if (ts === "arrived") return "arrived";
  if (ts === "driver_arriving") return "driver_arriving";
  if (ts === "driver_assigned" || ts === "accepted") return "accepted";
  if (ts === "searching" || LEGACY_OPEN_TRIP_STATES_OPS.has(ts) || LEGACY_OPEN_STATUS_OPS.has(st)) {
    return "searching";
  }
  return "other";
}

function deliveryOpsUiBucket(row) {
  const ds = String(row?.delivery_state ?? "").trim().toLowerCase();
  if (ds === DELIVERY_STATE.cancelled) return "cancelled";
  if (ds === DELIVERY_STATE.completed) return "completed";
  if (ds === DELIVERY_STATE.searching) return "searching";
  if (ds === DELIVERY_STATE.accepted || ds === DELIVERY_STATE.enroute_pickup) return "accepted";
  if (ds === DELIVERY_STATE.arrived_pickup) return "arrived_pickup";
  if (
    ds === DELIVERY_STATE.picked_up ||
    ds === DELIVERY_STATE.enroute_dropoff ||
    ds === DELIVERY_STATE.arrived_dropoff ||
    ds === DELIVERY_STATE.delivered
  ) {
    return "in_progress";
  }
  return "other";
}

function strHint(v, max = 120) {
  const s = String(v ?? "").trim();
  return s ? s.slice(0, max) : null;
}

function regionHintFromRow(row) {
  return (
    strHint(row?.market_pool, 40) ||
    strHint(row?.market, 40) ||
    strHint(row?.pickup?.city ?? row?.pickup?.area, 60) ||
    "—"
  );
}

async function loadPaymentRowsForRefs(db, rideOrDelivery) {
  const payments = [];
  const refKeys = new Set(
    [rideOrDelivery?.payment_reference, rideOrDelivery?.customer_transaction_reference]
      .map((x) => String(x ?? "").trim())
      .filter(Boolean),
  );
  for (const refKey of refKeys) {
    const [txSnap, paySnap] = await Promise.all([
      db.ref(`payment_transactions/${refKey}`).get(),
      db.ref(`payments/${refKey}`).get(),
    ]);
    const row = txSnap.val() || paySnap.val();
    if (row && typeof row === "object") {
      payments.push({
        reference: refKey,
        verified: !!row.verified,
        amount: Number(row.amount ?? 0) || 0,
        ride_id: row.ride_id ?? null,
        delivery_id: row.delivery_id ?? null,
        updated_at: Number(row.updated_at ?? 0) || 0,
      });
    }
  }
  return payments;
}

async function filterAdminAuditForTrip(db, tripId) {
  const tid = normUid(tripId);
  if (!tid) return [];
  const snap = await db.ref("admin_audit_logs").orderByKey().limitToLast(300).get();
  const val = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  const rows = [];
  for (const [k, v] of Object.entries(val)) {
    if (!v || typeof v !== "object") continue;
    const hit =
      normUid(v.ride_id) === tid ||
      normUid(v.delivery_id) === tid ||
      normUid(v.trip_id) === tid;
    if (hit) rows.push({ id: k, ...v });
  }
  rows.sort((a, b) => (Number(b.created_at) || 0) - (Number(a.created_at) || 0));
  return rows.slice(0, 80);
}

function summarizeLiveRideRow(rideId, v) {
  const bucket = rideOpsUiBucket(v);
  const created = Number(v.created_at ?? v.requested_at ?? 0) || 0;
  const updated = Number(v.updated_at ?? 0) || 0;
  const elapsedMs = created ? Math.max(0, nowMs() - created) : 0;
  const fare = Number(v.fare ?? v.estimated_fare ?? 0) || 0;
  const finalFare = Number(v.final_fare ?? v.fare_final ?? v.fare ?? 0) || 0;
  return {
    trip_kind: "ride",
    trip_id: rideId,
    ui_bucket: bucket,
    trip_state: v.trip_state ?? null,
    status: v.status ?? null,
    rider_id: normUid(v.rider_id),
    rider_name: strHint(v.rider_name, 120),
    rider_phone: strHint(v.rider_phone ?? v.riderPhone ?? v.phone, 40),
    driver_id: normUid(v.driver_id) || null,
    driver_name: strHint(v.driver_name ?? v.driverName, 120),
    driver_phone: strHint(v.driver_phone ?? v.driverPhone, 40),
    fare_estimate: fare,
    final_fare: finalFare,
    currency: String(v.currency ?? "NGN"),
    payment_status: String(v.payment_status ?? ""),
    payment_method: String(v.payment_method ?? ""),
    region: regionHintFromRow(v),
    pickup_area: pickupAreaHint(v),
    dropoff_area: dropoffAreaHint(v),
    admin_emergency: v.admin_emergency === true,
    created_at: created,
    updated_at: updated,
    elapsed_ms: elapsedMs,
    distance_km: Number(v.distance_km ?? 0) || 0,
    eta_minutes: Number(v.eta_min ?? v.eta_minutes ?? 0) || 0,
  };
}

function summarizeLiveDeliveryRow(deliveryId, v) {
  const bucket = deliveryOpsUiBucket(v);
  const created = Number(v.created_at ?? 0) || 0;
  const updated = Number(v.updated_at ?? 0) || 0;
  const elapsedMs = created ? Math.max(0, nowMs() - created) : 0;
  const fare = Number(v.fare ?? 0) || 0;
  const drv = deliveryAssignedDriverId(v);
  const src = String(v.source ?? "").trim().toLowerCase();
  const svcType = String(v.service_type ?? "").trim().toLowerCase();
  const deliverySource =
    src === "merchant_food_order" ? "merchant_food_order" :
    svcType === "dispatch_delivery" ? "dispatch" : "delivery";
  return {
    trip_kind: "delivery",
    delivery_source: deliverySource,
    merchant_order_id: normUid(v.merchant_order_id) || null,
    trip_id: deliveryId,
    ui_bucket: bucket,
    trip_state: v.trip_state ?? null,
    status: v.status ?? null,
    delivery_state: v.delivery_state ?? null,
    rider_id: normUid(v.customer_id ?? v.rider_id),
    rider_name: strHint(v.customer_name ?? v.rider_name, 120),
    rider_phone: strHint(v.customer_phone ?? v.rider_phone, 40),
    driver_id: drv || null,
    driver_name: strHint(v.driver_name, 120),
    driver_phone: strHint(v.driver_phone, 40),
    fare_estimate: fare,
    final_fare: fare,
    currency: String(v.currency ?? "NGN"),
    payment_status: String(v.payment_status ?? ""),
    payment_method: String(v.payment_method ?? ""),
    region: regionHintFromRow(v),
    pickup_area: pickupAreaHint(v),
    dropoff_area: dropoffAreaHint(v),
    admin_emergency: v.admin_emergency === true,
    created_at: created,
    updated_at: updated,
    elapsed_ms: elapsedMs,
    distance_km: Number(v.distance_km ?? 0) || 0,
    eta_minutes: Number(v.eta_minutes ?? 0) || 0,
  };
}

async function adminListLiveTrips(_data, context, db) {
  const _rbac = await _adminGate("adminListLiveTrips", context, db);
  if (_rbac) return _rbac;
  const seen = new Set();
  const trips = [];

  const [activeTripsSnap, activeDelSnap, riderPtrSnap, userDelSnap, driverActiveRideSnap, driverActiveDelSnap] =
    await Promise.all([
      db.ref("active_trips").get(),
      db.ref("active_deliveries").get(),
      db.ref("rider_active_trip").get(),
      db.ref("user_active_delivery").get(),
      db.ref("driver_active_ride").get(),
      db.ref("driver_active_delivery").get(),
    ]);

  const activeTripIds = Object.keys(activeTripsSnap.val() && typeof activeTripsSnap.val() === "object" ? activeTripsSnap.val() : {}).slice(
    0,
    180,
  );
  const activeDelIds = Object.keys(activeDelSnap.val() && typeof activeDelSnap.val() === "object" ? activeDelSnap.val() : {}).slice(0, 180);

  /** Server clears these pointers on cancel/complete; include all ride_ids (not only "searching"). */
  const riderPtrs = riderPtrSnap.val() && typeof riderPtrSnap.val() === "object" ? riderPtrSnap.val() : {};
  const riderPointerRideIds = [];
  for (const ptr of Object.values(riderPtrs)) {
    const rid = normUid(ptr?.ride_id);
    if (!rid) continue;
    riderPointerRideIds.push(rid);
  }

  const driverRideRaw =
    driverActiveRideSnap.val() && typeof driverActiveRideSnap.val() === "object"
      ? driverActiveRideSnap.val()
      : {};
  const driverActiveRideIds = [];
  for (const row of Object.values(driverRideRaw)) {
    const rid = normUid(row?.ride_id);
    if (rid) driverActiveRideIds.push(rid);
  }

  const userDel = userDelSnap.val() && typeof userDelSnap.val() === "object" ? userDelSnap.val() : {};
  /** Phases: searching (open) → active (after accept). Server clears on terminal. */
  const userDeliveryPointerIds = [];
  for (const ptr of Object.values(userDel)) {
    const did = normUid(ptr?.delivery_id);
    if (!did) continue;
    userDeliveryPointerIds.push(did);
  }

  const driverDelRaw =
    driverActiveDelSnap.val() && typeof driverActiveDelSnap.val() === "object"
      ? driverActiveDelSnap.val()
      : {};
  const driverActiveDeliveryIds = [];
  for (const row of Object.values(driverDelRaw)) {
    const did = normUid(row?.delivery_id);
    if (did) driverActiveDeliveryIds.push(did);
  }

  const rideIdUnion = new Set([
    ...activeTripIds,
    ...riderPointerRideIds.slice(0, 150),
    ...driverActiveRideIds.slice(0, 150),
  ]);
  const delIdUnion = new Set([
    ...activeDelIds,
    ...userDeliveryPointerIds.slice(0, 150),
    ...driverActiveDeliveryIds.slice(0, 150),
  ]);

  for (const rideId of rideIdUnion) {
    const rSnap = await db.ref(`ride_requests/${rideId}`).get();
    const v = rSnap.val();
    if (!v || typeof v !== "object") continue;
    if (seen.has(`ride:${rideId}`)) continue;
    seen.add(`ride:${rideId}`);
    trips.push(summarizeLiveRideRow(rideId, v));
  }

  for (const deliveryId of delIdUnion) {
    const rSnap = await db.ref(`delivery_requests/${deliveryId}`).get();
    const v = rSnap.val();
    if (!v || typeof v !== "object") continue;
    if (seen.has(`del:${deliveryId}`)) continue;
    seen.add(`del:${deliveryId}`);
    trips.push(summarizeLiveDeliveryRow(deliveryId, v));
  }

  // Merchant orders from Firestore — include active ones not already surfaced via delivery_requests.
  const TERMINAL_ORDER_STATUSES = new Set(["completed", "cancelled", "merchant_rejected"]);
  try {
    const fs = admin.firestore();
    const ordersSnap = await fs.collection("merchant_orders")
      .where("order_status", "not-in", ["completed", "cancelled", "merchant_rejected"])
      .orderBy("order_status")
      .orderBy("created_at", "desc")
      .limit(80)
      .get();
    for (const doc of ordersSnap.docs) {
      const o = doc.data() || {};
      const ost = String(o.order_status ?? "").trim().toLowerCase();
      if (TERMINAL_ORDER_STATUSES.has(ost)) continue;
      // If delivery already in trips list skip duplicate display.
      const did = normUid(o.delivery_id);
      if (did && seen.has(`del:${did}`)) continue;
      const createdMs =
        o.created_at?.toMillis?.() ??
        (o.created_at?._seconds ? o.created_at._seconds * 1000 : 0);
      const updatedMs =
        o.updated_at?.toMillis?.() ??
        (o.updated_at?._seconds ? o.updated_at._seconds * 1000 : 0);
      trips.push({
        trip_kind: "merchant_order",
        delivery_source: "merchant_food_order",
        merchant_order_id: doc.id,
        trip_id: doc.id,
        ui_bucket: ost === "pending_merchant" ? "searching" : "in_progress",
        trip_state: ost,
        status: ost,
        rider_id: normUid(o.customer_uid),
        rider_name: strHint(o.recipient_name, 120),
        rider_phone: strHint(o.recipient_phone, 40),
        driver_id: did || null,
        driver_name: null,
        driver_phone: null,
        fare_estimate: Number(o.total_ngn ?? 0) || 0,
        final_fare: Number(o.total_ngn ?? 0) || 0,
        currency: "NGN",
        payment_status: String(o.payment_status ?? "verified"),
        payment_method: String(o.payment_method ?? "flutterwave"),
        region: strHint(o.market ?? o.city_id, 40),
        pickup_area: strHint(o.pickup_snapshot?.address ?? o.pickup_snapshot?.business_name, 80),
        dropoff_area: strHint(o.dropoff_snapshot?.address ?? o.dropoff_snapshot?.name, 80),
        admin_emergency: false,
        created_at: createdMs,
        updated_at: updatedMs || createdMs,
        elapsed_ms: createdMs ? Math.max(0, nowMs() - createdMs) : 0,
        distance_km: 0,
        eta_minutes: 0,
      });
    }
  } catch (e) {
    logger.warn("adminListLiveTrips: merchant_orders query failed", { error: String(e) });
  }

  trips.sort((a, b) => (b.updated_at || 0) - (a.updated_at || 0));

  const recentSnapRides = await db.ref("ride_requests").orderByKey().limitToLast(320).get();
  const recentSnapDel = await db.ref("delivery_requests").orderByKey().limitToLast(320).get();
  const cutoff = nowMs() - 168 * 3600 * 1000;
  const recentCompleted = [];
  const recentCancelled = [];

  const ingestRecent = (kind, id, row) => {
    const bucket = kind === "ride" ? rideOpsUiBucket(row) : deliveryOpsUiBucket(row);
    const updated = Number(row.updated_at ?? 0) || 0;
    if (updated < cutoff) return;
    const summary =
      kind === "ride" ? summarizeLiveRideRow(id, row) : summarizeLiveDeliveryRow(id, row);
    if (bucket === "completed") recentCompleted.push(summary);
    else if (bucket === "cancelled") recentCancelled.push(summary);
  };

  const rv = recentSnapRides.val() && typeof recentSnapRides.val() === "object" ? recentSnapRides.val() : {};
  for (const [id, row] of Object.entries(rv)) {
    if (!row || typeof row !== "object") continue;
    ingestRecent("ride", id, row);
  }
  const dv = recentSnapDel.val() && typeof recentSnapDel.val() === "object" ? recentSnapDel.val() : {};
  for (const [id, row] of Object.entries(dv)) {
    if (!row || typeof row !== "object") continue;
    ingestRecent("delivery", id, row);
  }
  recentCompleted.sort((a, b) => (b.updated_at || 0) - (a.updated_at || 0));
  recentCancelled.sort((a, b) => (b.updated_at || 0) - (a.updated_at || 0));

  return {
    success: true,
    trips,
    recent_completed: recentCompleted.slice(0, 120),
    recent_cancelled: recentCancelled.slice(0, 120),
  };
}

async function adminGetTripDetail(data, context, db) {
  const _rbac = await _adminGate("adminGetTripDetail", context, db);
  if (_rbac) return _rbac;
  const tripId = normUid(
    data?.tripId ??
      data?.trip_id ??
      data?.rideId ??
      data?.ride_id ??
      data?.deliveryId ??
      data?.delivery_id,
  );
  if (!tripId) {
    return { success: false, reason: "invalid_trip_id" };
  }
  const rSnap = await db.ref(`ride_requests/${tripId}`).get();
  if (rSnap.exists()) {
    const ride = rSnap.val();
    const payments = await loadPaymentRowsForRefs(db, ride);
    const audit_timeline = await filterAdminAuditForTrip(db, tripId);
    const trackToken = String(ride.track_token ?? "").trim() || null;
    return {
      success: true,
      trip_kind: "ride",
      trip_id: tripId,
      ride,
      payments,
      audit_timeline,
      track_token: trackToken,
    };
  }
  const dSnap = await db.ref(`delivery_requests/${tripId}`).get();
  if (dSnap.exists()) {
    const delivery = dSnap.val();
    const payments = await loadPaymentRowsForRefs(db, delivery);
    const audit_timeline = await filterAdminAuditForTrip(db, tripId);
    return {
      success: true,
      trip_kind: "delivery",
      trip_id: tripId,
      delivery,
      payments,
      audit_timeline,
      track_token: null,
    };
  }
  return { success: false, reason: "not_found" };
}

async function adminCancelTrip(data, context, db) {
  const _rbac = await _adminGate("adminCancelTrip", context, db);
  if (_rbac) return _rbac;
  const note = String(data?.note ?? data?.reason ?? "").trim();
  if (note.length < 8) {
    return { success: false, reason: "note_required" };
  }
  const adminUid = normUid(context.auth.uid);
  const tripId = normUid(
    data?.tripId ??
      data?.trip_id ??
      data?.rideId ??
      data?.ride_id ??
      data?.deliveryId ??
      data?.delivery_id,
  );
  if (!tripId) {
    return { success: false, reason: "invalid_trip_id" };
  }
  const explicitKind = String(data?.kind ?? data?.trip_kind ?? "").trim().toLowerCase();

  const rideSnap = await db.ref(`ride_requests/${tripId}`).get();
  const delSnap = await db.ref(`delivery_requests/${tripId}`).get();
  const isRide = rideSnap.exists();
  const isDel = delSnap.exists();
  if (!isRide && !isDel) {
    return { success: false, reason: "not_found" };
  }
  if (explicitKind === "ride" && !isRide) return { success: false, reason: "kind_mismatch" };
  if (explicitKind === "delivery" && !isDel) return { success: false, reason: "kind_mismatch" };

  const cancelRideBranch = async () => {
    const cancelReason = `admin_cancel:${note.slice(0, 400)}`;
    const res = await cancelRideRequest({ rideId: tripId, cancel_reason: cancelReason }, context, db);
    if (!res.success) {
      return { success: false, reason: res.reason || "cancel_failed", trip_kind: "ride", trip_id: tripId };
    }
    await writeAdminAudit(db, {
      type: "admin_cancel_trip",
      trip_kind: "ride",
      trip_id: tripId,
      actor_uid: adminUid,
      note: note.slice(0, 500),
    });
    return { success: true, trip_kind: "ride", trip_id: tripId, reason: "cancelled" };
  };

  const cancelDeliveryBranch = async () => {
    const row = delSnap.val();
    if (!row || typeof row !== "object") {
      return { success: false, reason: "not_found", trip_kind: "delivery", trip_id: tripId };
    }
    const ds = String(row?.delivery_state ?? "").trim().toLowerCase();
    if (TERMINAL_DELIVERY.has(ds)) {
      return { success: false, reason: "already_terminal", trip_kind: "delivery", trip_id: tripId };
    }
    const customerId = normUid(row.customer_id);
    const driverId = deliveryAssignedDriverId(row);
    const now = nowMs();
    const mirror = deliveryUiMirrorFields(DELIVERY_STATE.cancelled, driverId || "");
    await db.ref(`delivery_requests/${tripId}`).set({
      ...row,
      delivery_state: DELIVERY_STATE.cancelled,
      trip_state: mirror.trip_state,
      status: mirror.status,
      cancelled_at: now,
      cancel_reason: `admin_cancel:${note.slice(0, 200)}`,
      admin_cancelled_by: adminUid,
      admin_cancel_note: note.slice(0, 500),
      updated_at: now,
    });
    await clearDeliveryFanoutAndOffers(db, tripId, driverId || "");
    const u = {};
    u[`active_deliveries/${tripId}`] = null;
    u[`user_active_delivery/${customerId}`] = null;
    if (driverId) u[`driver_active_delivery/${driverId}`] = null;
    await db.ref().update(u);
    await writeAdminAudit(db, {
      type: "admin_cancel_trip",
      trip_kind: "delivery",
      trip_id: tripId,
      actor_uid: adminUid,
      note: note.slice(0, 500),
    });
    return { success: true, trip_kind: "delivery", trip_id: tripId, reason: "cancelled" };
  };

  if (explicitKind === "delivery") {
    return cancelDeliveryBranch();
  }
  if (explicitKind === "ride") {
    return cancelRideBranch();
  }
  if (isRide) {
    return cancelRideBranch();
  }
  if (isDel) {
    return cancelDeliveryBranch();
  }
  return { success: false, reason: "not_found" };
}

async function adminMarkTripEmergency(data, context, db) {
  const _rbac = await _adminGate("adminMarkTripEmergency", context, db);
  if (_rbac) return _rbac;
  const note = String(data?.note ?? data?.reason ?? "").trim();
  if (note.length < 8) {
    return { success: false, reason: "note_required" };
  }
  const tripId = normUid(
    data?.tripId ??
      data?.trip_id ??
      data?.rideId ??
      data?.ride_id ??
      data?.deliveryId ??
      data?.delivery_id,
  );
  if (!tripId) return { success: false, reason: "invalid_trip_id" };
  const adminUid = normUid(context.auth.uid);
  const now = nowMs();
  const rideSnap = await db.ref(`ride_requests/${tripId}`).get();
  if (rideSnap.exists()) {
    await db.ref(`ride_requests/${tripId}`).update({
      admin_emergency: true,
      admin_emergency_note: note.slice(0, 800),
      admin_emergency_at: now,
      admin_emergency_by: adminUid,
      updated_at: now,
    });
    await writeAdminAudit(db, {
      type: "admin_mark_trip_emergency",
      trip_kind: "ride",
      trip_id: tripId,
      actor_uid: adminUid,
      note: note.slice(0, 500),
    });
    return { success: true, trip_kind: "ride", trip_id: tripId };
  }
  const dSnap = await db.ref(`delivery_requests/${tripId}`).get();
  if (dSnap.exists()) {
    await db.ref(`delivery_requests/${tripId}`).update({
      admin_emergency: true,
      admin_emergency_note: note.slice(0, 800),
      admin_emergency_at: now,
      admin_emergency_by: adminUid,
      updated_at: now,
    });
    await writeAdminAudit(db, {
      type: "admin_mark_trip_emergency",
      trip_kind: "delivery",
      trip_id: tripId,
      actor_uid: adminUid,
      note: note.slice(0, 500),
    });
    return { success: true, trip_kind: "delivery", trip_id: tripId };
  }
  return { success: false, reason: "not_found" };
}

async function adminResolveTripEmergency(data, context, db) {
  const _rbac = await _adminGate("adminResolveTripEmergency", context, db);
  if (_rbac) return _rbac;
  const note = String(data?.note ?? data?.reason ?? "").trim();
  if (note.length < 8) {
    return { success: false, reason: "note_required" };
  }
  const tripId = normUid(
    data?.tripId ??
      data?.trip_id ??
      data?.rideId ??
      data?.ride_id ??
      data?.deliveryId ??
      data?.delivery_id,
  );
  if (!tripId) return { success: false, reason: "invalid_trip_id" };
  const adminUid = normUid(context.auth.uid);
  const now = nowMs();
  const rideSnap = await db.ref(`ride_requests/${tripId}`).get();
  if (rideSnap.exists()) {
    await db.ref(`ride_requests/${tripId}`).update({
      admin_emergency: false,
      admin_emergency_resolved_note: note.slice(0, 800),
      admin_emergency_resolved_at: now,
      admin_emergency_resolved_by: adminUid,
      updated_at: now,
    });
    await writeAdminAudit(db, {
      type: "admin_resolve_trip_emergency",
      trip_kind: "ride",
      trip_id: tripId,
      actor_uid: adminUid,
      note: note.slice(0, 500),
    });
    return { success: true, trip_kind: "ride", trip_id: tripId };
  }
  const dSnap = await db.ref(`delivery_requests/${tripId}`).get();
  if (dSnap.exists()) {
    await db.ref(`delivery_requests/${tripId}`).update({
      admin_emergency: false,
      admin_emergency_resolved_note: note.slice(0, 800),
      admin_emergency_resolved_at: now,
      admin_emergency_resolved_by: adminUid,
      updated_at: now,
    });
    await writeAdminAudit(db, {
      type: "admin_resolve_trip_emergency",
      trip_kind: "delivery",
      trip_id: tripId,
      actor_uid: adminUid,
      note: note.slice(0, 500),
    });
    return { success: true, trip_kind: "delivery", trip_id: tripId };
  }
  return { success: false, reason: "not_found" };
}

async function adminListOnlineDrivers(_data, context, db) {
  const _rbac = await _adminGate("adminListOnlineDrivers", context, db);
  if (_rbac) return _rbac;
  const [activeTripsSnap, activeDelSnap, drvSnap] = await Promise.all([
    db.ref("active_trips").get(),
    db.ref("active_deliveries").get(),
    db.ref("drivers").get(),
  ]);
  const busyDrivers = new Map();
  const at = activeTripsSnap.val() && typeof activeTripsSnap.val() === "object" ? activeTripsSnap.val() : {};
  for (const [tid, row] of Object.entries(at)) {
    const d = normUid(row?.driver_id ?? row?.driverId);
    if (d) busyDrivers.set(d, { kind: "ride", trip_id: tid });
  }
  const ad = activeDelSnap.val() && typeof activeDelSnap.val() === "object" ? activeDelSnap.val() : {};
  for (const [did, row] of Object.entries(ad)) {
    const d = normUid(row?.driver_id ?? row?.driverId);
    if (d) busyDrivers.set(d, { kind: "delivery", trip_id: did });
  }

  const raw = drvSnap.val() && typeof drvSnap.val() === "object" ? drvSnap.val() : {};
  const drivers = [];
  for (const [uid, drow] of Object.entries(raw)) {
    if (!drow || typeof drow !== "object") continue;
    const online = drow.online === true || drow.is_online === true || drow.isOnline === true;
    if (!online) continue;
    const driverId = normUid(uid);
    const busy = busyDrivers.get(driverId);
    const driver_class = busy ? "busy" : "idle";
    drivers.push({
      driver_id: driverId,
      name: strHint(drow.name ?? drow.full_name ?? drow.display_name, 120),
      phone: strHint(drow.phone ?? drow.phone_number ?? drow.mobile, 40),
      email: strHint(drow.email, 80),
      market: strHint(drow.dispatch_market ?? drow.market ?? drow.market_pool, 40),
      online: true,
      driver_class,
      active_trip_id: busy?.trip_id ?? null,
      active_trip_kind: busy?.kind ?? null,
      updated_at: Number(drow.updated_at ?? 0) || 0,
    });
  }
  drivers.sort((a, b) => (b.updated_at || 0) - (a.updated_at || 0));
  return { success: true, drivers };
}

async function adminApproveWithdrawal(data, context, db) {
  const _rbac = await _adminGate("adminApproveWithdrawal", context, db);
  if (_rbac) return _rbac;
  return withdrawFlow.approveWithdrawal(
    { ...data, status: "paid" },
    context,
    db,
  );
}

async function adminRejectWithdrawal(data, context, db) {
  const _rbac = await _adminGate("adminRejectWithdrawal", context, db);
  if (_rbac) return _rbac;
  return withdrawFlow.approveWithdrawal(
    { ...data, status: "rejected" },
    context,
    db,
  );
}

async function adminVerifyDriver(data, context, db) {
  const _rbac = await _adminGate("adminVerifyDriver", context, db);
  if (_rbac) return _rbac;
  const driverId = normUid(data?.driverId ?? data?.driver_id ?? data?.uid);
  if (!driverId) {
    return { success: false, reason: "invalid_driver_id" };
  }
  const note = String(data?.note ?? "").trim().slice(0, 500);
  const now = Date.now();
  const dSnap = await db.ref(`drivers/${driverId}`).get();
  const prev = dSnap.val() && typeof dSnap.val() === "object" ? dSnap.val() : {};
  if (prev.nexride_verified === true) {
    return { success: true, reason: "already_verified", driverId, idempotent: true };
  }
  await db.ref(`drivers/${driverId}`).update({
    nexride_verified: true,
    nexride_verified_at: now,
    nexride_verified_by: normUid(context.auth.uid),
    nexride_verification_note: note || null,
    updated_at: now,
  });
  await db.ref(`driver_verifications/${driverId}`).update({
    status: "verified",
    verified_at: now,
    verified_by: normUid(context.auth.uid),
    note: note || null,
  });
  console.log(
    "VERIFICATION_APPROVED",
    driverId,
    "admin=",
    normUid(context.auth.uid),
  );
  logger.info("adminVerifyDriver", { driverId, admin: normUid(context.auth.uid) });
  await writeAdminAudit(db, {
    type: "admin_verify_driver",
    driver_id: driverId,
    actor_uid: normUid(context.auth.uid),
    note: note || null,
  });
  return { success: true, reason: "driver_verified", driverId };
}

/**
 * Admin-only: mark a pending bank/card payment as verified without re-calling Flutterwave
 * (evidence reviewed out-of-band). Requires audit note + matching payment_transactions row.
 */
async function adminApproveManualPayment(data, context, db) {
  const _rbac = await _adminGate("adminApproveManualPayment", context, db);
  if (_rbac) return _rbac;
  const adminUid = normUid(context.auth.uid);
  const reference = String(
    data?.reference ?? data?.tx_ref ?? data?.transaction_id ?? data?.transactionId ?? "",
  ).trim();
  const note = String(data?.note ?? data?.reason ?? "").trim();
  if (!reference || note.length < 12) {
    return { success: false, reason: "invalid_input" };
  }
  const ptSnap = await db.ref(`payment_transactions/${reference}`).get();
  const pt = ptSnap.val();
  if (!pt || typeof pt !== "object") {
    return { success: false, reason: "payment_transaction_not_found" };
  }
  if (pt.verified === true) {
    return { success: true, reason: "already_verified", idempotent: true };
  }
  const rideId = normUid(pt.ride_id);
  const deliveryId = normUid(pt.delivery_id);
  if (!rideId && !deliveryId) {
    return { success: false, reason: "missing_trip_reference" };
  }
  const payKey = String(pt.transaction_id ?? pt.flutterwave_transaction_id ?? reference).trim() || reference;
  const riderId = normUid(pt.rider_id);
  const amount = Number(pt.amount ?? 0) || 0;
  const currency = String(pt.currency ?? "NGN").trim().toUpperCase() || "NGN";
  const now = nowMs();

  if (rideId) {
    const rSnap = await db.ref(`ride_requests/${rideId}`).get();
    const ride = rSnap.val();
    if (!ride || typeof ride !== "object") {
      return { success: false, reason: "ride_not_found" };
    }
    const expectedRefs = new Set(
      [ride.payment_reference, ride.customer_transaction_reference, reference]
        .map((x) => String(x ?? "").trim())
        .filter(Boolean),
    );
    if (!expectedRefs.has(reference)) {
      return { success: false, reason: "reference_mismatch_ride" };
    }
    if (riderId && normUid(ride.rider_id) !== riderId) {
      return { success: false, reason: "rider_mismatch" };
    }
  }
  if (deliveryId) {
    const dSnap = await db.ref(`delivery_requests/${deliveryId}`).get();
    const del = dSnap.val();
    if (!del || typeof del !== "object") {
      return { success: false, reason: "delivery_not_found" };
    }
    const expectedRefs = new Set(
      [del.payment_reference, del.customer_transaction_reference, reference]
        .map((x) => String(x ?? "").trim())
        .filter(Boolean),
    );
    if (!expectedRefs.has(reference)) {
      return { success: false, reason: "reference_mismatch_delivery" };
    }
    const cust = normUid(del.customer_id);
    if (riderId && cust !== riderId) {
      return { success: false, reason: "customer_mismatch" };
    }
  }

  await db.ref().update({
    [`payment_transactions/${reference}`]: {
      ...pt,
      tx_ref: pt.tx_ref || reference,
      verified: true,
      provider_status: "successful",
      admin_manual_approved: true,
      admin_manual_approved_at: now,
      admin_manual_approved_by: adminUid,
      admin_manual_approval_note: note.slice(0, 800),
      updated_at: now,
    },
    [`payments/${payKey}`]: {
      provider: "manual_admin",
      transaction_id: payKey,
      tx_ref: reference,
      ride_id: rideId || null,
      delivery_id: deliveryId || null,
      rider_id: riderId || null,
      amount,
      currency,
      status: "verified",
      verified_at: now,
      verified: true,
      webhook_applied: true,
      admin_manual: true,
      updated_at: now,
    },
  });

  if (rideId) {
    await db.ref(`ride_requests/${rideId}`).update({
      payment_status: "verified",
      payment_verified_at: now,
      payment_provider: "manual_admin",
      payment_transaction_id: payKey,
      paid_at: now,
      updated_at: now,
    });
    const activeSnap = await db.ref(`active_trips/${rideId}`).get();
    if (activeSnap.exists()) {
      await db.ref(`active_trips/${rideId}`).update({
        payment_status: "verified",
        payment_provider: "manual_admin",
        payment_transaction_id: payKey,
        paid_at: now,
        updated_at: now,
      });
    }
    const fresh = (await db.ref(`ride_requests/${rideId}`).get()).val();
    await fanOutDriverOffersIfEligible(db, rideId, fresh || {});
    await syncRideTrackPublic(db, rideId);
  }
  if (deliveryId) {
    await db.ref(`delivery_requests/${deliveryId}`).update({
      payment_status: "verified",
      payment_verified_at: now,
      payment_provider: "manual_admin",
      payment_transaction_id: payKey,
      paid_at: now,
      updated_at: now,
    });
    const freshDel = (await db.ref(`delivery_requests/${deliveryId}`).get()).val();
    await fanOutDeliveryOffersIfEligible(db, deliveryId, freshDel || {});
  }

  await writeAdminAudit(db, {
    type: "admin_manual_payment_approve",
    reference,
    ride_id: rideId || null,
    delivery_id: deliveryId || null,
    actor_uid: adminUid,
    note: note.slice(0, 800),
  });
  logger.info("adminApproveManualPayment", { reference, rideId, deliveryId, admin: adminUid });
  return { success: true, reason: "approved" };
}

async function adminSuspendDriver(data, context, db) {
  const _rbac = await _adminGate("adminSuspendDriver", context, db);
  if (_rbac) return _rbac;
  const driverId = normUid(data?.driverId ?? data?.driver_id ?? data?.uid);
  const reason = String(data?.reason ?? data?.note ?? "").trim().slice(0, 500);
  if (!driverId) {
    return { success: false, reason: "invalid_driver_id" };
  }
  if (reason.length < 8) {
    return { success: false, reason: "reason_required" };
  }
  const now = nowMs();
  const adminUid = normUid(context.auth.uid);
  const dBeforeSnap = await db.ref(`drivers/${driverId}`).get();
  const dBefore =
    dBeforeSnap.val() && typeof dBeforeSnap.val() === "object" ? dBeforeSnap.val() : {};
  const before = {
    suspended: !!dBefore.suspended,
    account_suspended: !!dBefore.account_suspended,
    online: !!(dBefore.online || dBefore.is_online || dBefore.isOnline),
    status: dBefore.status ?? null,
  };
  await db.ref(`drivers/${driverId}`).update({
    suspended: true,
    account_suspended: true,
    admin_suspended_at: now,
    admin_suspended_by: adminUid,
    admin_suspension_reason: reason,
    isOnline: false,
    is_online: false,
    online: false,
    isAvailable: false,
    available: false,
    status: "offline",
    dispatch_state: "offline",
    driver_availability_mode: "offline",
    updated_at: now,
  });
  try {
    await db.ref(`online_drivers/${driverId}`).remove();
  } catch (_) {
    /* ignore */
  }
  await adminAuditLog.writeAdminAuditLog(db, {
    actor_uid: adminUid,
    action: "suspend_driver",
    entity_type: "driver",
    entity_id: driverId,
    before,
    after: {
      suspended: true,
      account_suspended: true,
      online: false,
      status: "offline",
    },
    reason,
    source: "admin_callables.adminSuspendDriver",
    type: "admin_suspend_driver",
    created_at: now,
  });
  logger.info("adminSuspendDriver", { driverId, admin: adminUid });
  return { success: true, reason: "suspended", reason_code: "suspended", driverId };
}

async function adminListSupportTickets(_data, context, db) {
  const _rbac = await _adminGate("adminListSupportTickets", context, db);
  if (_rbac) return _rbac;
  const snap = await db.ref("support_tickets").orderByKey().limitToLast(200).get();
  const val = snap.val() || {};
  const tickets = Object.entries(val).map(([id, t]) => ({
    id,
    status: t?.status ?? null,
    createdByUserId: normUid(t?.createdByUserId),
    subject: String(t?.subject ?? "").slice(0, 200) || null,
    ride_id: normUid(t?.ride_id ?? t?.rideId) || null,
    updatedAt: Number(t?.updatedAt ?? t?.updated_at ?? 0) || 0,
    createdAt: Number(t?.createdAt ?? t?.created_at ?? 0) || 0,
  }));
  tickets.sort((a, b) => b.updatedAt - a.updatedAt);
  return { success: true, tickets };
}

async function adminListPendingWithdrawals(_data, context, db) {
  const _rbac = await _adminGate("adminListPendingWithdrawals", context, db);
  if (_rbac) return _rbac;
  const snap = await db.ref("withdraw_requests").orderByChild("status").equalTo("pending").limitToFirst(80).get();
  const raw = snap.val() || {};
  const rows = Object.entries(raw).map(([id, w]) => ({
    id,
    ...w,
  }));
  rows.sort((a, b) => (b.updated_at || b.requestedAt || 0) - (a.updated_at || a.requestedAt || 0));
  return { success: true, withdrawals: rows };
}

async function adminListPayments(_data, context, db) {
  const _rbac = await _adminGate("adminListPayments", context, db);
  if (_rbac) return _rbac;
  const snap = await db.ref("payments").orderByKey().limitToLast(50).get();
  const val = snap.val() || {};
  const rows = Object.entries(val).map(([transaction_id, row]) => ({
    transaction_id,
    verified: !!row?.verified,
    amount: Number(row?.amount ?? 0) || 0,
    ride_id: row?.ride_id ?? null,
    rider_id: row?.rider_id ?? null,
    updated_at: Number(row?.updated_at ?? 0) || 0,
  }));
  rows.sort((a, b) => (b.updated_at || 0) - (a.updated_at || 0));
  return { success: true, payments: rows };
}

/** Strip heavy RTDB fields so admin web can parse the payload without hanging. */
function slimDriverProfileForAdmin(_uid, raw) {
  if (!raw || typeof raw !== "object") {
    return {};
  }
  const omit = new Set([
    "lastLocation",
    "last_location",
    "location",
    "currentLocation",
    "current_location",
    "gps",
    "gps_history",
    "gpsHistory",
    "location_history",
    "locationHistory",
    "route_polyline",
    "routePolyline",
    "active_route",
    "activeRoute",
    "trips",
    "trip_history",
    "tripHistory",
    "chats",
    "messages",
    "debug",
    "internalNotes",
    "presence_trace",
    "presenceTrace",
  ]);
  const out = { ...raw };
  for (const k of omit) {
    delete out[k];
  }
  if (out.vehicle && typeof out.vehicle === "object") {
    const v = out.vehicle;
    out.vehicle = {
      model: v.model,
      plate: v.plate,
      color: v.color,
      year: v.year,
      make: v.make,
      type: v.type,
    };
  }
  return out;
}

function driverRowMatchesListFilters(uid, row, f) {
  if (!row || typeof row !== "object") return false;
  const city = String(row.city ?? "").trim().toLowerCase();
  const state = String(
    row.state ?? row.region ?? row.dispatch_market ?? row.state_name ?? row.province ?? "",
  )
    .trim()
    .toLowerCase();
  if (f.city && f.city !== "all") {
    if (!city.includes(f.city) && city !== f.city) return false;
  }
  if (f.stateOrRegion && f.stateOrRegion !== "all") {
    if (!state.includes(f.stateOrRegion) && state !== f.stateOrRegion) return false;
  }
  if (f.search) {
    const q = f.search.replace(/\s+/g, " ").trim();
    const needlePhone = q.replace(/\s/g, "");
    const name = String(row.name ?? row.driverName ?? "").toLowerCase();
    const phone = String(row.phone ?? "").replace(/\s/g, "");
    const email = String(row.email ?? "").toLowerCase();
    if (
      !uid.toLowerCase().includes(q) &&
      !name.includes(q) &&
      !phone.includes(needlePhone) &&
      !email.includes(q)
    ) {
      return false;
    }
  }
  if (f.status && f.status !== "all") {
    const online = !!(row.isOnline ?? row.is_online ?? row.online);
    if (f.status === "online" && !online) return false;
    if (f.status === "offline" && online) return false;
    const acct = String(row.accountStatus ?? row.account_status ?? "").toLowerCase();
    const op = String(row.status ?? "").toLowerCase();
    if (!["online", "offline"].includes(f.status) && !acct.includes(f.status) && !op.includes(f.status)) {
      return false;
    }
  }
  if (f.verificationStatus && f.verificationStatus !== "all") {
    const verObj = row.verification && typeof row.verification === "object" ? row.verification : {};
    const ov = String(verObj.overallStatus ?? row.verification_status ?? "").toLowerCase();
    const nx = row.nexride_verified === true ? "verified" : "";
    if (!ov.includes(f.verificationStatus) && !nx.includes(f.verificationStatus)) {
      return false;
    }
  }
  const cAt = Number(row.created_at ?? row.createdAt ?? 0) || 0;
  if (f.createdFrom > 0 && cAt > 0 && cAt < f.createdFrom) return false;
  if (f.createdTo > 0 && cAt > 0 && cAt > f.createdTo) return false;
  if (f.monetizationModel && f.monetizationModel !== "all") {
    const bm = row.businessModel && typeof row.businessModel === "object" ? row.businessModel : {};
    const sel = String(bm.selectedModel ?? row.monetization_model ?? "").trim().toLowerCase();
    if (!sel.includes(f.monetizationModel)) return false;
  }
  return true;
}

function slimRiderProfileForAdmin(_uid, raw) {
  if (!raw || typeof raw !== "object") {
    return {};
  }
  const omit = new Set([
    "chats",
    "messages",
    "trip_history",
    "tripHistory",
    "trips",
    "location",
    "locations",
    "gps",
    "gps_history",
    "notifications",
    "notification_history",
  ]);
  const out = { ...raw };
  for (const k of omit) {
    delete out[k];
  }
  return out;
}

function riderRowMatchesListFilters(uid, row, f) {
  if (!row || typeof row !== "object") return false;
  const role = String(row.role ?? row.account_role ?? "").trim().toLowerCase();
  if (role === "driver") return false;
  const city = String(row.city ?? row.homeCity ?? "").trim().toLowerCase();
  const state = String(row.state ?? row.region ?? "").trim().toLowerCase();
  if (f.city && f.city !== "all") {
    if (!city.includes(f.city) && city !== f.city) return false;
  }
  if (f.stateOrRegion && f.stateOrRegion !== "all") {
    if (!state.includes(f.stateOrRegion) && state !== f.stateOrRegion) return false;
  }
  if (f.search) {
    const q = f.search.replace(/\s+/g, " ").trim();
    const needlePhone = q.replace(/\s/g, "");
    const name = String(row.displayName ?? row.name ?? "").toLowerCase();
    const uname = String(row.username ?? row.userName ?? row.handle ?? "").toLowerCase();
    const phone = String(row.phone ?? "").replace(/\s/g, "");
    const email = String(row.email ?? "").toLowerCase();
    if (
      !uid.toLowerCase().includes(q) &&
      !name.includes(q) &&
      !uname.includes(q) &&
      !phone.includes(needlePhone) &&
      !email.includes(q)
    ) {
      return false;
    }
  }
  if (f.status && f.status !== "all") {
    const trust = row.trustSummary && typeof row.trustSummary === "object" ? row.trustSummary : {};
    let st = String(row.status ?? trust.accountStatus ?? "").toLowerCase();
    if (!st) {
      st = "active";
    }
    if (!st.includes(f.status)) return false;
  }
  if (f.verificationStatus && f.verificationStatus !== "all") {
    const ver = row.verification && typeof row.verification === "object" ? row.verification : {};
    const trust = row.trustSummary && typeof row.trustSummary === "object" ? row.trustSummary : {};
    const ov = String(ver.overallStatus ?? trust.verificationStatus ?? "").toLowerCase();
    if (!ov.includes(f.verificationStatus)) return false;
  }
  const cAt = Number(row.createdAt ?? row.created_at ?? 0) || 0;
  if (f.createdFrom > 0 && cAt > 0 && cAt < f.createdFrom) return false;
  if (f.createdTo > 0 && cAt > 0 && cAt > f.createdTo) return false;
  const pc = f.profileCompleteness || "completed";
  if (pc === "completed") {
    if (row.profile_completed !== true) return false;
  } else if (pc === "incomplete") {
    if (row.profile_completed === true) return false;
  }
  return true;
}

function firestoreTimestampMs(ts) {
  if (!ts) return 0;
  try {
    if (typeof ts.toMillis === "function") return Number(ts.toMillis()) || 0;
    if (typeof ts._seconds === "number") return Number(ts._seconds) * 1000;
  } catch (_) {
    /* ignore */
  }
  const n = Number(ts);
  return Number.isFinite(n) ? n : 0;
}

function slimFirestoreRiderRowForAdmin(uid, d) {
  if (!d || typeof d !== "object") return null;
  if (d.isDriver === true || d.is_driver === true) return null;
  const role = String(d.role ?? d.account_role ?? d.accountType ?? d.userType ?? "")
    .trim()
    .toLowerCase();
  if (role === "driver") return null;
  const name = String(
    d.displayName ??
      d.name ??
      d.fullName ??
      d.full_name ??
      d.preferredName ??
      d.preferred_name ??
      "",
  ).trim();
  const username = String(d.username ?? d.userName ?? d.handle ?? "").trim() || null;
  const email = String(
    d.email ?? d.primary_email ?? d.primaryEmail ?? d.userEmail ?? d.user_email ?? "",
  ).trim();
  const phone = String(
    d.phone ?? d.phoneNumber ?? d.mobile ?? d.phone_number ?? d.msisdn ?? "",
  ).trim();
  const rolloutCity = String(d.rollout_city_id ?? d.rollout_dispatch_market_id ?? "").trim();
  const city =
    String(d.city ?? d.homeCity ?? d.launchCity ?? d.launch_city ?? "").trim() ||
    (rolloutCity || null);
  const state = String(d.state ?? d.region ?? "").trim() || null;
  const verificationStatus = String(
    d.verificationStatus ?? d.verification_status ?? d.verification?.overallStatus ?? "",
  )
    .trim()
    .toLowerCase();
  const createdAt =
    firestoreTimestampMs(d.createdAt) ||
    firestoreTimestampMs(d.created_at) ||
    firestoreTimestampMs(d.signupAt) ||
    0;
  return {
    uid,
    name: name || null,
    displayName: name || null,
    username,
    email: email || null,
    phone: phone || null,
    city,
    state,
    status: String(d.status ?? "active").trim().toLowerCase() || "active",
    role: role || "",
    verification: {
      overallStatus: verificationStatus || undefined,
    },
    trustSummary: {
      accountStatus: String(d.accountStatus ?? d.status ?? "active")
        .trim()
        .toLowerCase(),
      verificationStatus: verificationStatus || undefined,
    },
    createdAt,
    created_at: createdAt,
    onboarding_completed: d.onboarding_completed ?? d.onboardingComplete,
    onboarding_stage: d.onboarding_stage ?? d.onboardingStep ?? null,
    profile_source: "firestore",
    profile_incomplete: !(name || email || phone),
  };
}

/**
 * Riders may be authoritative in Firestore (`users/{uid}`) while RTDB `users` is partial.
 * First admin list page: merge a capped Firestore scan so live portals show the same people
 * as identity / verification surfaces.
 */
async function mergeFirestoreRidersIntoAdminMatches(matches, f, limit, riderDirCtx, includeClsDebug) {
  const want = limit + 1;
  if (Object.keys(matches).length >= want) {
    return { merged: 0, scanned: 0 };
  }
  const fs = admin.firestore();
  let merged = 0;
  let scanned = 0;
  let cursor = null;
  const batchSize = 80;
  const maxScan = 2400;
  while (Object.keys(matches).length < want && scanned < maxScan) {
    let q = fs.collection("users").orderBy(FieldPath.documentId()).limit(batchSize);
    if (cursor) {
      q = q.startAfter(cursor);
    }
    let snap;
    try {
      snap = await q.get();
    } catch (e) {
      logger.warn("mergeFirestoreRidersIntoAdminMatches query failed", {
        err: String(e?.message || e),
      });
      break;
    }
    if (snap.empty) {
      break;
    }
    for (const doc of snap.docs) {
      cursor = doc;
      scanned += 1;
      const uid = doc.id;
      if (matches[uid]) {
        continue;
      }
      const slim = slimFirestoreRiderRowForAdmin(uid, doc.data());
      if (!slim) {
        continue;
      }
      const cls = classifyUserForRiderDirectory(uid, slim, `firestore/users/${uid}`, riderDirCtx);
      if (!cls.include) {
        continue;
      }
      const enriched = enrichRiderRowWithProfileCompleteness(slim);
      if (riderRowMatchesListFilters(uid, enriched, f)) {
        matches[uid] = attachClassificationDebug(enriched, cls, includeClsDebug);
        merged += 1;
        if (Object.keys(matches).length >= want) {
          return { merged, scanned };
        }
      }
    }
    if (snap.size < batchSize) {
      break;
    }
  }
  return { merged, scanned };
}

function slimTripListRow(id, ride) {
  if (!ride || typeof ride !== "object") {
    return { ride_id: id };
  }
  const pickup = ride.pickup && typeof ride.pickup === "object" ? ride.pickup : {};
  return {
    ride_id: id,
    trip_state: ride.trip_state ?? null,
    status: ride.status ?? null,
    rider_id: normUid(ride.rider_id),
    rider_name: String(ride.rider_name ?? "").trim().slice(0, 80) || null,
    driver_id: normUid(ride.driver_id) || null,
    driver_name: String(ride.driver_name ?? "").trim().slice(0, 80) || null,
    fare: Number(ride.fare ?? 0) || 0,
    currency: String(ride.currency ?? "NGN"),
    city: String(ride.city ?? pickup.city ?? pickup.area ?? "").trim().slice(0, 80) || null,
    service_type: String(ride.service_type ?? ride.serviceType ?? "").trim().slice(0, 40) || null,
    pickup_hint: pickupAreaHint(ride),
    dropoff_hint: dropoffAreaHint(ride),
    created_at: Number(ride.created_at ?? ride.createdAt ?? 0) || 0,
    updated_at: Number(ride.updated_at ?? ride.updatedAt ?? 0) || 0,
  };
}

function tripRowMatchesFilters(row, f) {
  if (!row || typeof row !== "object") return false;
  if (f.city && f.city !== "all") {
    const c = String(row.city ?? "").toLowerCase();
    if (!c.includes(f.city)) return false;
  }
  if (f.status && f.status !== "all") {
    const st = String(row.status ?? row.trip_state ?? "").toLowerCase();
    if (!st.includes(f.status)) return false;
  }
  if (f.search) {
    const q = f.search.toLowerCase();
    const id = String(row.ride_id ?? "").toLowerCase();
    const rn = String(row.rider_name ?? "").toLowerCase();
    const dn = String(row.driver_name ?? "").toLowerCase();
    if (!id.includes(q) && !rn.includes(q) && !dn.includes(q)) return false;
  }
  const cAt = Number(row.created_at ?? 0) || 0;
  if (f.createdFrom > 0 && cAt > 0 && cAt < f.createdFrom) return false;
  if (f.createdTo > 0 && cAt > 0 && cAt > f.createdTo) return false;
  return true;
}

async function adminFetchDriversTree(data, context, db) {
  const _rbac = await _adminGate("adminFetchDriversTree", context, db);
  if (_rbac) return _rbac;
  const maxRaw = Number(data?.maxDrivers ?? data?.limit ?? 0);
  const maxDrivers =
    Number.isFinite(maxRaw) && maxRaw > 0 ? Math.min(500, Math.floor(maxRaw)) : null;
  const snap = await db.ref("drivers").get();
  const val = snap.val();
  const drivers = val && typeof val === "object" ? val : {};
  let entries = Object.entries(drivers);
  if (maxDrivers != null) {
    entries = entries.slice(0, maxDrivers);
  }
  const slim = {};
  for (const [uid, row] of entries) {
    slim[uid] = slimDriverProfileForAdmin(uid, row);
  }
  return {
    success: true,
    drivers: slim,
    count: Object.keys(slim).length,
    capped: maxDrivers != null,
  };
}

/**
 * Paginated drivers for admin web — key-ordered scan with server-side filters
 * (no full-tree download; capped scan per request).
 */
async function adminListDriversPage(data, context, db) {
  const _rbac = await _adminGate("adminListDriversPage", context, db);
  if (_rbac) return _rbac;
  const f = parseAdminListParams(data || {});
  const limit = f.limit;
  const MAX_SCAN = 5000;
  const BATCH = 120;
  let resumeKey = f.cursor.trim();
  const matches = {};
  let scanned = 0;
  let lastScannedKey = resumeKey;
  let lastBatchFull = false;

  while (Object.keys(matches).length < limit + 1 && scanned < MAX_SCAN) {
    let q = db.ref("drivers").orderByKey();
    if (resumeKey) {
      q = q.startAfter(resumeKey);
    }
    let snap;
    try {
      snap = await q.limitToFirst(BATCH).get();
    } catch (e) {
      logger.warn("adminListDriversPage batch query failed", {
        err: String(e?.message || e),
        resumeKey: resumeKey || null,
      });
      break;
    }
    const val = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
    const batchKeys = Object.keys(val).sort();
    lastBatchFull = batchKeys.length === BATCH;
    if (batchKeys.length === 0) {
      break;
    }
    for (const k of batchKeys) {
      scanned += 1;
      lastScannedKey = k;
      const slim = slimDriverProfileForAdmin(k, val[k]);
      if (driverRowMatchesListFilters(k, slim, f)) {
        matches[k] = slim;
        if (Object.keys(matches).length >= limit + 1) {
          break;
        }
      }
    }
    resumeKey = batchKeys[batchKeys.length - 1];
    if (batchKeys.length < BATCH) {
      break;
    }
  }

  const keys = Object.keys(matches).sort();
  const hasMoreFromMatches = keys.length > limit;
  const pageKeys = hasMoreFromMatches ? keys.slice(0, limit) : keys;
  const page = {};
  for (const k of pageKeys) {
    page[k] = matches[k];
  }
  const hasMore = hasMoreFromMatches || (pageKeys.length === limit && lastBatchFull && scanned < MAX_SCAN);
  const nextCursor = lastScannedKey && hasMore ? lastScannedKey : null;

  return {
    success: true,
    drivers: page,
    nextCursor,
    hasMore,
    count: pageKeys.length,
    scanned,
    capped_scan: scanned >= MAX_SCAN,
  };
}

/**
 * Lightweight counts for admin sidebar badges (avoids wiring full RTDB tree
 * listeners on the Flutter web admin client).
 */
async function adminGetSidebarBadgeCounts(_data, context, db) {
  const _rbac = await _adminGate("adminGetSidebarBadgeCounts", context, db);
  if (_rbac) return _rbac;

  const countKeys = (val) =>
    val && typeof val === "object" ? Object.keys(val).length : 0;

  const subscriptionSnap = await db
    .ref("drivers")
    .orderByChild("subscription_pending")
    .equalTo(true)
    .limitToFirst(500)
    .get();

  let tripsPaymentPending = 0;
  try {
    const tripSnap = await db
      .ref("ride_requests")
      .orderByChild("payment_status")
      .equalTo("pending_manual_confirmation")
      .limitToFirst(500)
      .get();
    tripsPaymentPending = countKeys(tripSnap.val());
  } catch (e) {
    logger.warn("adminGetSidebarBadgeCounts trip query failed", {
      err: String(e?.message || e),
    });
  }

  let supportOpen = 0;
  try {
    const supportSnap = await db
      .ref("support_tickets")
      .orderByChild("updatedAt")
      .limitToLast(800)
      .get();
    const supportVal = supportSnap.val() || {};
    for (const t of Object.values(supportVal)) {
      const s = String(t?.status || "").toLowerCase();
      if (s === "open" || s === "pending_user" || s === "escalated") {
        supportOpen += 1;
      }
    }
  } catch (e) {
    logger.warn("adminGetSidebarBadgeCounts support query failed", {
      err: String(e?.message || e),
    });
  }

  return {
    success: true,
    subscription_drivers_pending: countKeys(subscriptionSnap.val()),
    trips_payment_pending_confirmation: tripsPaymentPending,
    support_tickets_open: supportOpen,
  };
}

async function adminListDrivers(_data, context, db) {
  const _rbac = await _adminGate("adminListDrivers", context, db);
  if (_rbac) return _rbac;
  const snap = await db.ref("drivers").limitToFirst(120).get();
  const val = snap.val() || {};
  let drivers = Object.entries(val).map(([uid, d]) => ({
    uid,
    name: String(d?.name ?? d?.driverName ?? "").trim() || null,
    car: String(d?.car ?? "").trim() || null,
    market: String(d?.dispatch_market ?? d?.market ?? "").trim() || null,
    is_online: !!(d?.isOnline ?? d?.is_online),
    nexride_verified: !!d?.nexride_verified,
  }));

  // Fallback for environments where driver records are user-profile based.
  if (drivers.length === 0) {
    const userSnap = await db.ref("users").limitToFirst(300).get();
    const users = userSnap.val() || {};
    drivers = Object.entries(users)
      .filter(([, u]) => {
        const role = String(u?.role ?? u?.account_role ?? "").trim().toLowerCase();
        return role === "driver";
      })
      .map(([uid, u]) => ({
        uid,
        name: String(u?.displayName ?? u?.name ?? "").trim() || null,
        car: String(u?.car ?? "").trim() || null,
        market: String(u?.dispatch_market ?? u?.market ?? "").trim() || null,
        is_online: !!(u?.isOnline ?? u?.is_online),
        nexride_verified: !!(u?.nexride_verified ?? u?.kyc_approved),
      }));
  }
  return { success: true, drivers };
}

async function adminListRiders(_data, context, db) {
  const _rbac = await _adminGate("adminListRiders", context, db);
  if (_rbac) return _rbac;
  const page = await adminListRidersPage({ limit: 200, cursor: "" }, context, db);
  if (!page.success) {
    return { success: false, reason: page.reason || "list_failed" };
  }
  const map = page.riders && typeof page.riders === "object" ? page.riders : {};
  const riders = Object.keys(map)
    .sort()
    .map((uid) => {
      const row = map[uid];
      if (!row || typeof row !== "object") {
        return { uid };
      }
      return { uid, ...row };
    });
  return { success: true, riders };
}

function buildDispatchPresenceForAdmin(rawDriver) {
  const raw = rawDriver && typeof rawDriver === "object" ? rawDriver : {};
  const lastLoc =
    raw.last_location && typeof raw.last_location === "object" ? raw.last_location : {};
  const lastLat = Number(lastLoc.lat ?? lastLoc.latitude ?? "");
  const lastLng = Number(lastLoc.lng ?? lastLoc.longitude ?? "");
  return {
    is_online: !!(raw.isOnline ?? raw.is_online ?? raw.online),
    driver_availability_mode: String(raw.driver_availability_mode ?? "").trim() || null,
    lat: Number.isFinite(Number(raw.lat)) ? Number(raw.lat) : null,
    lng: Number.isFinite(Number(raw.lng)) ? Number(raw.lng) : null,
    last_location:
      Number.isFinite(lastLat) && Number.isFinite(lastLng)
        ? { lat: lastLat, lng: lastLng }
        : null,
    last_location_updated_at: Number(raw.last_location_updated_at ?? 0) || null,
    selected_service_area_id: String(raw.selected_service_area_id ?? "").trim() || null,
    selected_service_area_name: String(raw.selected_service_area_name ?? "").trim() || null,
    last_seen_at: Number(raw.last_seen_at ?? raw.last_active_at ?? 0) || null,
    nexride_verified: raw.nexride_verified === true,
    suspended: !!(
      raw.suspended === true ||
      raw.account_suspended === true ||
      String(raw.driver_status ?? "")
        .trim()
        .toLowerCase() === "suspended"
    ),
  };
}

async function adminGetDriverProfile(data, context, db) {
  const _rbac = await _adminGate("adminGetDriverProfile", context, db);
  if (_rbac) return _rbac;
  const driverId = normUid(data?.driverId ?? data?.driver_id);
  if (!driverId) {
    return { success: false, reason: "invalid_driver_id" };
  }
  const [dSnap, wSnap, verSnap, docSnap] = await Promise.all([
    db.ref(`drivers/${driverId}`).get(),
    db.ref(`wallets/${driverId}`).get(),
    db.ref(`driver_verifications/${driverId}`).get(),
    db.ref(`driver_documents/${driverId}`).get(),
  ]);
  const exists = typeof dSnap.exists === "function" ? dSnap.exists() : !!dSnap.exists;
  if (!exists || !dSnap.val()) {
    return { success: false, reason: "not_found" };
  }
  const rawDriver = dSnap.val() && typeof dSnap.val() === "object" ? dSnap.val() : {};
  const driver = slimDriverProfileForAdmin(driverId, rawDriver);
  const dispatch_presence = buildDispatchPresenceForAdmin(rawDriver);
  const walletRaw = wSnap.val() && typeof wSnap.val() === "object" ? wSnap.val() : {};
  const verification = verSnap.val() && typeof verSnap.val() === "object" ? verSnap.val() : {};
  const documents_meta = {};
  const dv = docSnap.val();
  if (dv && typeof dv === "object") {
    for (const [k, v] of Object.entries(dv)) {
      if (!v || typeof v !== "object") continue;
      documents_meta[k] = {
        status: v.status ?? v.state ?? null,
        updated_at: Number(v.updated_at ?? v.updatedAt ?? 0) || 0,
        file: typeof v.file === "string" ? String(v.file).slice(0, 240) : null,
      };
    }
  }
  return {
    success: true,
    driver_id: driverId,
    driver,
    dispatch_presence,
    wallet: {
      balance: Number(walletRaw.balance ?? walletRaw.currentBalance ?? 0) || 0,
      currency: String(walletRaw.currency ?? "NGN"),
    },
    verification,
    documents_meta,
  };
}

function slimWalletTabForAdmin(raw) {
  if (!raw || typeof raw !== "object") {
    return { balance: 0, currency: "NGN" };
  }
  const omit = new Set([
    "transactions",
    "transaction_history",
    "history",
    "ledger",
    "entries",
    "raw",
  ]);
  const out = {};
  for (const [k, v] of Object.entries(raw)) {
    if (omit.has(k)) continue;
    if (typeof v === "object" && v !== null && !Array.isArray(v)) {
      const nestedKeys = Object.keys(v);
      if (nestedKeys.length > 24) continue;
      out[k] = v;
    } else if (typeof v === "string") {
      out[k] = String(v).slice(0, 400);
    } else if (typeof v === "number" || typeof v === "boolean" || v == null) {
      out[k] = v;
    }
  }
  out.balance = Number(raw.balance ?? raw.currentBalance ?? out.balance ?? 0) || 0;
  out.currency = String(raw.currency ?? out.currency ?? "NGN");
  return out;
}

function slimVerificationDocumentsMeta(docSnapVal) {
  const documents_meta = {};
  const dv = docSnapVal;
  if (dv && typeof dv === "object") {
    let n = 0;
    for (const [k, v] of Object.entries(dv)) {
      if (n >= 48) break;
      if (!v || typeof v !== "object") continue;
      documents_meta[k] = {
        status: v.status ?? v.state ?? null,
        updated_at: Number(v.updated_at ?? v.updatedAt ?? 0) || 0,
        file: typeof v.file === "string" ? String(v.file).slice(0, 240) : null,
      };
      n += 1;
    }
  }
  return documents_meta;
}

async function adminGetDriverOverview(data, context, db) {
  const _rbac = await _adminGate("adminGetDriverOverview", context, db);
  if (_rbac) return _rbac;
  const driverId = normUid(data?.driverId ?? data?.driver_id);
  if (!driverId) {
    return { success: false, reason: "invalid_driver_id" };
  }
  const primary = await _driverPrimaryExists(db, driverId);
  if (!primary.ok) {
    return { success: false, reason: "not_found" };
  }
  const docSnap = await db.ref(`driver_documents/${driverId}`).get();
  const docVal = docSnap.val() && typeof docSnap.val() === "object" ? docSnap.val() : {};
  const document_slot_count = Object.keys(docVal).length;
  const payload = {
    success: true,
    driver_id: driverId,
    driver: slimDriverProfileForAdmin(driverId, primary.raw),
    dispatch_presence: buildDispatchPresenceForAdmin(primary.raw),
    document_slot_count,
  };
  return finalizeDriverTabResponse("adminGetDriverOverview", payload);
}

async function adminGetDriverVerification(data, context, db) {
  const _rbac = await _adminGate("adminGetDriverVerification", context, db);
  if (_rbac) return _rbac;
  const driverId = normUid(data?.driverId ?? data?.driver_id);
  if (!driverId) {
    return { success: false, reason: "invalid_driver_id" };
  }
  const primary = await _driverPrimaryExists(db, driverId);
  if (!primary.ok) {
    return { success: false, reason: "not_found" };
  }
  const [verSnap, docSnap] = await Promise.all([
    db.ref(`driver_verifications/${driverId}`).get(),
    db.ref(`driver_documents/${driverId}`).get(),
  ]);
  const verification = verSnap.val() && typeof verSnap.val() === "object" ? verSnap.val() : {};
  const documents_meta = slimVerificationDocumentsMeta(docSnap.val());
  const driverVerificationSlice =
    primary.raw.verification && typeof primary.raw.verification === "object"
      ? primary.raw.verification
      : {};
  const payload = {
    success: true,
    driver_id: driverId,
    verification,
    documents_meta,
    driver_verification: driverVerificationSlice,
  };
  return finalizeDriverTabResponse("adminGetDriverVerification", payload);
}

async function adminGetDriverWallet(data, context, db) {
  const _rbac = await _adminGate("adminGetDriverWallet", context, db);
  if (_rbac) return _rbac;
  const driverId = normUid(data?.driverId ?? data?.driver_id);
  if (!driverId) {
    return { success: false, reason: "invalid_driver_id" };
  }
  const primary = await _driverPrimaryExists(db, driverId);
  if (!primary.ok) {
    return { success: false, reason: "not_found" };
  }
  const wSnap = await db.ref(`wallets/${driverId}`).get();
  const walletRaw = wSnap.val() && typeof wSnap.val() === "object" ? wSnap.val() : {};
  const payload = {
    success: true,
    driver_id: driverId,
    wallet: slimWalletTabForAdmin(walletRaw),
  };
  return finalizeDriverTabResponse("adminGetDriverWallet", payload);
}

async function adminGetDriverTrips(data, context, db) {
  const _rbac = await _adminGate("adminGetDriverTrips", context, db);
  if (_rbac) return _rbac;
  const driverId = normUid(data?.driverId ?? data?.driver_id);
  if (!driverId) {
    return { success: false, reason: "invalid_driver_id" };
  }
  const primary = await _driverPrimaryExists(db, driverId);
  if (!primary.ok) {
    return { success: false, reason: "not_found" };
  }
  const limit = Math.min(40, Math.max(5, Number(data?.limit ?? 25) || 25));
  let trips = [];
  try {
    const q = db
      .ref("ride_requests")
      .orderByChild("driver_id")
      .equalTo(driverId)
      .limitToLast(limit);
    const snap = await q.get();
    const val = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
    trips = Object.entries(val).map(([id, ride]) => slimTripListRow(id, ride));
    trips.sort((a, b) => (b.updated_at || 0) - (a.updated_at || 0));
  } catch (e) {
    logger.warn("adminGetDriverTrips query failed", { driverId, err: String(e?.message || e) });
    trips = [];
  }
  const payload = { success: true, driver_id: driverId, trips, trip_query_limit: limit };
  return finalizeDriverTabResponse("adminGetDriverTrips", payload);
}

async function adminGetDriverSubscription(data, context, db) {
  const _rbac = await _adminGate("adminGetDriverSubscription", context, db);
  if (_rbac) return _rbac;
  const driverId = normUid(data?.driverId ?? data?.driver_id);
  if (!driverId) {
    return { success: false, reason: "invalid_driver_id" };
  }
  const primary = await _driverPrimaryExists(db, driverId);
  if (!primary.ok) {
    return { success: false, reason: "not_found" };
  }
  const raw = primary.raw;
  const bm = raw.businessModel && typeof raw.businessModel === "object" ? raw.businessModel : {};
  const payload = {
    success: true,
    driver_id: driverId,
    subscription: {
      monetization_model: String(raw.monetization_model ?? bm.selectedModel ?? "").trim() || null,
      subscription_plan_type: String(
        raw.subscription_plan_type ?? raw.subscriptionPlanType ?? "",
      ).trim() || null,
      subscription_status: String(
        raw.subscription_status ?? raw.subscriptionStatus ?? "",
      ).trim() || null,
      subscription_active: !!(raw.subscription_active ?? raw.subscriptionActive),
      business_model: {
        selectedModel: bm.selectedModel ?? null,
        commissionPercent: bm.commissionPercent ?? bm.commission_percent ?? null,
      },
      subscription_expires_at: Number(raw.subscription_expires_at ?? raw.subscriptionExpiresAt ?? 0) || 0,
      subscription_started_at: Number(raw.subscription_started_at ?? raw.subscriptionStartedAt ?? 0) || 0,
    },
  };
  return finalizeDriverTabResponse("adminGetDriverSubscription", payload);
}

async function adminGetDriverViolations(data, context, db) {
  const _rbac = await _adminGate("adminGetDriverViolations", context, db);
  if (_rbac) return _rbac;
  const driverId = normUid(data?.driverId ?? data?.driver_id);
  if (!driverId) {
    return { success: false, reason: "invalid_driver_id" };
  }
  const primary = await _driverPrimaryExists(db, driverId);
  if (!primary.ok) {
    return { success: false, reason: "not_found" };
  }
  const raw = primary.raw;
  const violations = [];
  const pushText = (code, message, at) => {
    const msg = String(message ?? "").trim();
    if (!msg) return;
    violations.push({
      code: String(code),
      message: msg.slice(0, 2000),
      at: Number(at ?? 0) || 0,
    });
  };
  pushText("suspend_reason", raw.suspend_reason ?? raw.suspension_reason, raw.suspended_at);
  pushText("account_warning", raw.account_warning ?? raw.admin_warning, raw.warned_at);
  pushText("deactivated_reason", raw.deactivated_reason, raw.deactivated_at);
  const payload = { success: true, driver_id: driverId, violations };
  return finalizeDriverTabResponse("adminGetDriverViolations", payload);
}

function slimNoteField(v, maxLen) {
  if (v == null) return null;
  if (typeof v === "string") {
    const s = v.trim();
    return s ? s.slice(0, maxLen) : null;
  }
  if (typeof v === "object") {
    try {
      const s = JSON.stringify(v);
      return s.length > maxLen ? `${s.slice(0, maxLen)}…` : s;
    } catch (e) {
      return null;
    }
  }
  return String(v).slice(0, maxLen);
}

async function adminGetDriverNotes(data, context, db) {
  const _rbac = await _adminGate("adminGetDriverNotes", context, db);
  if (_rbac) return _rbac;
  const driverId = normUid(data?.driverId ?? data?.driver_id);
  if (!driverId) {
    return { success: false, reason: "invalid_driver_id" };
  }
  const primary = await _driverPrimaryExists(db, driverId);
  if (!primary.ok) {
    return { success: false, reason: "not_found" };
  }
  const raw = primary.raw;
  const payload = {
    success: true,
    driver_id: driverId,
    notes: {
      admin_note: slimNoteField(raw.admin_note, 8000),
      operator_notes: slimNoteField(raw.operator_notes, 8000),
      support_notes: slimNoteField(raw.support_notes, 8000),
      internal_notes: slimNoteField(raw.internalNotes ?? raw.internal_notes, 8000),
    },
  };
  return finalizeDriverTabResponse("adminGetDriverNotes", payload);
}

async function adminGetDriverAuditTimeline(data, context, db) {
  const _rbac = await _adminGate("adminGetDriverAuditTimeline", context, db);
  if (_rbac) return _rbac;
  const driverId = normUid(data?.driverId ?? data?.driver_id);
  if (!driverId) {
    return { success: false, reason: "invalid_driver_id" };
  }
  const primary = await _driverPrimaryExists(db, driverId);
  if (!primary.ok) {
    return { success: false, reason: "not_found" };
  }
  let verification_audits = [];
  try {
    const q = db
      .ref("verification_audits")
      .orderByChild("driverId")
      .equalTo(driverId)
      .limitToLast(40);
    const snap = await q.get();
    const val = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
    verification_audits = Object.entries(val)
      .map(([id, row]) => ({
        id,
        action: row?.action ?? null,
        status: row?.status ?? null,
        result: row?.result ?? null,
        failureReason: String(row?.failureReason ?? "").trim().slice(0, 800) || null,
        reviewedBy: String(row?.reviewedBy ?? "").trim() || null,
        reviewedAt: Number(row?.reviewedAt ?? row?.createdAt ?? 0) || 0,
      }))
      .sort((a, b) => (b.reviewedAt || 0) - (a.reviewedAt || 0));
  } catch (e) {
    logger.warn("adminGetDriverAuditTimeline verification_audits query failed", {
      driverId,
      err: String(e?.message || e),
    });
    verification_audits = [];
  }
  let admin_audit_tail = [];
  try {
    const adminSnap = await db
      .ref("admin_audit_logs")
      .orderByChild("driver_id")
      .equalTo(driverId)
      .limitToLast(30)
      .get();
    const val = adminSnap.val() && typeof adminSnap.val() === "object" ? adminSnap.val() : {};
    admin_audit_tail = Object.entries(val)
      .map(([id, row]) => ({
        id,
        type: row?.type ?? null,
        actor_uid: row?.actor_uid ?? null,
        created_at: Number(row?.created_at ?? 0) || 0,
      }))
      .sort((a, b) => (b.created_at || 0) - (a.created_at || 0));
  } catch (e) {
    logger.warn("adminGetDriverAuditTimeline admin_audit_logs query failed", {
      driverId,
      err: String(e?.message || e),
    });
    admin_audit_tail = [];
  }
  const payload = {
    success: true,
    driver_id: driverId,
    verification_audits,
    admin_audit_tail,
  };
  return finalizeDriverTabResponse("adminGetDriverAuditTimeline", payload);
}

async function adminListRidersPage(data, context, db) {
  const _rbac = await _adminGate("adminListRidersPage", context, db);
  if (_rbac) return _rbac;
  const f = parseAdminListParams(data || {});
  const limit = f.limit;
  const MAX_SCAN = 5000;
  const BATCH = 120;
  let resumeKey = f.cursor.trim();
  const matches = {};
  let scanned = 0;
  let lastScannedKey = resumeKey;
  let lastBatchFull = false;
  const riderDirCtx = await loadAdminRiderDirectoryContext(db);
  const includeClsDebug = !!(data && data.includeRiderClassificationDebug);

  while (Object.keys(matches).length < limit + 1 && scanned < MAX_SCAN) {
    let q = db.ref("users").orderByKey();
    if (resumeKey) {
      q = q.startAfter(resumeKey);
    }
    let snap;
    try {
      snap = await q.limitToFirst(BATCH).get();
    } catch (e) {
      logger.warn("adminListRidersPage batch query failed", {
        err: String(e?.message || e),
      });
      break;
    }
    const val = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
    const batchKeys = Object.keys(val).sort();
    lastBatchFull = batchKeys.length === BATCH;
    if (batchKeys.length === 0) break;
    for (const k of batchKeys) {
      scanned += 1;
      lastScannedKey = k;
      const slim = slimRiderProfileForAdmin(k, val[k]);
      const cls = classifyUserForRiderDirectory(k, slim, `rtdb/users/${k}`, riderDirCtx);
      if (!cls.include) {
        continue;
      }
      const enriched = enrichRiderRowWithProfileCompleteness(slim);
      if (riderRowMatchesListFilters(k, enriched, f)) {
        matches[k] = attachClassificationDebug(enriched, cls, includeClsDebug);
        if (Object.keys(matches).length >= limit + 1) break;
      }
    }
    resumeKey = batchKeys[batchKeys.length - 1];
    if (batchKeys.length < BATCH) break;
  }

  // Merge Firebase Auth accounts so riders who authenticated but never wrote
  // an RTDB users/ profile still appear in the admin list.
  // Only run this on first page (no cursor) to avoid duplicates across pages.
  if (!f.cursor.trim()) {
    try {
      const auth = getAuth();
      let pageToken;
      let authMerged = 0;
      for (let page = 0; page < 10; page += 1) {
        const listResult = await auth.listUsers(1000, pageToken);
        for (const authUser of listResult.users) {
          const uid = authUser.uid;
          if (matches[uid]) continue;
          const c = classifyAuthUserForRiderDirectory(authUser, riderDirCtx);
          if (!c.include) continue;
          const authProfile = {
            ...authUserToProfileRow(authUser),
            status: authUser.disabled ? "suspended" : "active",
            account_status: authUser.disabled ? "suspended" : "active",
            profile_incomplete: true,
          };
          const enriched = enrichRiderRowWithProfileCompleteness(authProfile);
          if (riderRowMatchesListFilters(uid, enriched, f)) {
            matches[uid] = attachClassificationDebug(enriched, c, includeClsDebug);
            authMerged += 1;
          }
        }
        if (!listResult.pageToken) break;
        pageToken = listResult.pageToken;
      }
      logger.info("adminListRidersPage auth merge", { authMerged });
    } catch (e) {
      logger.warn("adminListRidersPage: auth list merge failed", { error: String(e) });
    }
    try {
      const fr = await mergeFirestoreRidersIntoAdminMatches(
        matches,
        f,
        limit,
        riderDirCtx,
        includeClsDebug,
      );
      logger.info("adminListRidersPage firestore merge", fr);
    } catch (e) {
      logger.warn("adminListRidersPage firestore merge failed", { error: String(e) });
    }
  }

  const keys = Object.keys(matches).sort((a, b) => {
    const ra = matches[a] || {};
    const rb = matches[b] || {};
    const pa = ra.profile_completed === true ? 1 : 0;
    const pb = rb.profile_completed === true ? 1 : 0;
    if (pb !== pa) {
      return pb - pa;
    }
    const ta = Number(ra.created_at ?? ra.createdAt ?? 0) || 0;
    const tb = Number(rb.created_at ?? rb.createdAt ?? 0) || 0;
    return tb - ta;
  });
  const hasMoreFromMatches = keys.length > limit;
  const pageKeys = hasMoreFromMatches ? keys.slice(0, limit) : keys;
  const page = {};
  for (const k of pageKeys) {
    page[k] = matches[k];
  }
  const hasMore = hasMoreFromMatches || (pageKeys.length === limit && lastBatchFull && scanned < MAX_SCAN);
  const nextCursor = lastScannedKey && hasMore ? lastScannedKey : null;
  return {
    success: true,
    riders: page,
    nextCursor,
    hasMore,
    count: pageKeys.length,
    scanned,
    capped_scan: scanned >= MAX_SCAN,
  };
}

async function adminGetRiderProfile(data, context, db) {
  const _rbac = await _adminGate("adminGetRiderProfile", context, db);
  if (_rbac) return _rbac;
  const riderId = normUid(data?.riderId ?? data?.rider_id ?? data?.uid);
  if (!riderId) {
    return { success: false, reason: "invalid_rider_id" };
  }
  let rtdbRaw = null;
  const snap = await db.ref(`users/${riderId}`).get();
  const exists = typeof snap.exists === "function" ? snap.exists() : !!snap.exists;
  if (exists && snap.val()) {
    rtdbRaw = snap.val();
  }
  let rider = rtdbRaw ? slimRiderProfileForAdmin(riderId, rtdbRaw) : null;

  let fsSlim = null;
  try {
    const fsDoc = await admin.firestore().collection("users").doc(riderId).get();
    if (fsDoc.exists) {
      fsSlim = slimFirestoreRiderRowForAdmin(riderId, fsDoc.data());
    }
  } catch (e) {
    logger.warn("adminGetRiderProfile firestore read failed", {
      riderId,
      err: String(e?.message || e),
    });
  }

  if (fsSlim && rider && typeof rider === "object") {
    rider = { ...rider, ...fsSlim, rtdb_missing: false };
  } else if (fsSlim) {
    rider = { ...fsSlim, rtdb_missing: !rtdbRaw };
  }

  if (!rider || (typeof rider === "object" && Object.keys(rider).length === 0)) {
    return { success: false, reason: "not_found" };
  }

  let auth_metadata = null;
  try {
    const auth = getAuth();
    const u = await auth.getUser(riderId);
    const ar = authUserToProfileRow(u);
    rider = {
      ...rider,
      email: rider.email || ar.email,
      phone: rider.phone || ar.phone,
      displayName: rider.displayName || ar.displayName,
      name: rider.name || ar.name,
      created_at: Number(rider.created_at ?? rider.createdAt ?? 0) || ar.created_at || 0,
      createdAt: Number(rider.createdAt ?? rider.created_at ?? 0) || ar.createdAt || 0,
      last_active_at: Number(rider.last_active_at ?? rider.lastActiveAt ?? 0) || ar.last_active_at || 0,
      lastActiveAt: Number(rider.lastActiveAt ?? rider.last_active_at ?? 0) || ar.lastActiveAt || 0,
    };
    auth_metadata = {
      uid: riderId,
      creation_time: u.metadata.creationTime,
      last_sign_in_time: u.metadata.lastSignInTime,
      disabled: u.disabled,
    };
  } catch (e) {
    logger.warn("adminGetRiderProfile auth getUser failed", {
      riderId,
      err: String(e?.message || e),
    });
  }

  let trip_count_hint = null;
  if (rtdbRaw && typeof rtdbRaw === "object") {
    const th = rtdbRaw.trip_history ?? rtdbRaw.tripHistory;
    if (th && typeof th === "object") {
      trip_count_hint = Math.min(5000, Object.keys(th).length);
    }
  }

  const account_events = [];
  const pushAcct = (code, message, at) => {
    const msg = String(message ?? "").trim();
    if (!msg) {
      return;
    }
    account_events.push({
      code: String(code),
      message: msg.slice(0, 2000),
      at: Number(at ?? 0) || 0,
    });
  };
  const rawForNotes = rtdbRaw && typeof rtdbRaw === "object" ? rtdbRaw : {};
  pushAcct("suspend_reason", rawForNotes.suspend_reason ?? rawForNotes.suspension_reason, rawForNotes.suspended_at);
  pushAcct("account_warning", rawForNotes.account_warning ?? rawForNotes.admin_warning, rawForNotes.warned_at);
  pushAcct("deactivated_reason", rawForNotes.deactivated_reason, rawForNotes.deactivated_at);

  let warnings_tail = [];
  try {
    const wSnap = await db.ref(`users/${riderId}/warnings`).limitToLast(40).get();
    const wv = wSnap.val();
    if (wv && typeof wv === "object") {
      warnings_tail = Object.entries(wv)
        .map(([id, w]) => ({
          id,
          message: String(w?.message ?? w?.body ?? w?.text ?? "").trim().slice(0, 2000),
          kind: String(w?.kind ?? w?.type ?? "").trim(),
          created_at: Number(w?.created_at ?? w?.at ?? 0) || 0,
        }))
        .filter((x) => x.message || x.created_at || x.kind)
        .sort((a, b) => b.created_at - a.created_at);
    }
  } catch (e) {
    logger.warn("adminGetRiderProfile warnings read failed", {
      riderId,
      err: String(e?.message || e),
    });
  }

  rider = enrichRiderRowWithProfileCompleteness(rider);

  return {
    success: true,
    rider_id: riderId,
    rider,
    auth_metadata,
    trip_count_hint,
    warnings_tail,
    account_events,
  };
}

async function adminListTripsPage(data, context, db) {
  const _rbac = await _adminGate("adminListTripsPage", context, db);
  if (_rbac) return _rbac;
  const f = parseAdminListParams(data || {});
  const limit = f.limit;
  const MAX_SCAN = 4000;
  const BATCH = 100;
  let resumeKey = f.cursor.trim();
  const matches = {};
  let scanned = 0;
  let lastScannedKey = resumeKey;
  let lastBatchFull = false;

  while (Object.keys(matches).length < limit + 1 && scanned < MAX_SCAN) {
    let q = db.ref("ride_requests").orderByKey();
    if (resumeKey) {
      q = q.startAfter(resumeKey);
    }
    let snap;
    try {
      snap = await q.limitToFirst(BATCH).get();
    } catch (e) {
      logger.warn("adminListTripsPage batch failed", { err: String(e?.message || e) });
      break;
    }
    const val = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
    const batchKeys = Object.keys(val).sort();
    lastBatchFull = batchKeys.length === BATCH;
    if (batchKeys.length === 0) break;
    for (const k of batchKeys) {
      scanned += 1;
      lastScannedKey = k;
      const row = slimTripListRow(k, val[k]);
      if (tripRowMatchesFilters(row, f)) {
        matches[k] = row;
        if (Object.keys(matches).length >= limit + 1) break;
      }
    }
    resumeKey = batchKeys[batchKeys.length - 1];
    if (batchKeys.length < BATCH) break;
  }

  const keys = Object.keys(matches).sort();
  const hasMoreFromMatches = keys.length > limit;
  const pageKeys = hasMoreFromMatches ? keys.slice(0, limit) : keys;
  const page = {};
  for (const k of pageKeys) {
    page[k] = matches[k];
  }
  const hasMore = hasMoreFromMatches || (pageKeys.length === limit && lastBatchFull && scanned < MAX_SCAN);
  const nextCursor = lastScannedKey && hasMore ? lastScannedKey : null;
  return {
    success: true,
    trips: page,
    nextCursor,
    hasMore,
    count: pageKeys.length,
    scanned,
    capped_scan: scanned >= MAX_SCAN,
  };
}

function withdrawalRowMatches(id, row, f) {
  if (!row || typeof row !== "object") return false;
  const st = String(row.status ?? "").toLowerCase();
  if (f.status && f.status !== "all" && !st.includes(f.status)) return false;
  if (f.search) {
    const q = f.search.toLowerCase();
    const name = String(row.driverName ?? row.driver_name ?? "").toLowerCase();
    const did = String(row.driverId ?? row.driver_id ?? "").toLowerCase();
    const mid = String(row.merchantId ?? row.merchant_id ?? "").toLowerCase();
    const et = String(row.entity_type ?? row.entityType ?? "").toLowerCase();
    if (
      !id.toLowerCase().includes(q) &&
      !name.includes(q) &&
      !did.includes(q) &&
      !mid.includes(q) &&
      !et.includes(q)
    ) {
      return false;
    }
  }
  const t = Number(row.requestedAt ?? row.updated_at ?? row.created_at ?? 0) || 0;
  if (f.createdFrom > 0 && t > 0 && t < f.createdFrom) return false;
  if (f.createdTo > 0 && t > 0 && t > f.createdTo) return false;
  return true;
}

async function adminListWithdrawalsPage(data, context, db) {
  const _rbac = await _adminGate("adminListWithdrawalsPage", context, db);
  if (_rbac) return _rbac;
  const f = parseAdminListParams(data || {});
  const limit = f.limit;
  const MAX_SCAN = 4000;
  const BATCH = 120;
  let resumeKey = f.cursor.trim();
  const matches = {};
  let scanned = 0;
  let lastScannedKey = resumeKey;
  let lastBatchFull = false;

  while (Object.keys(matches).length < limit + 1 && scanned < MAX_SCAN) {
    let q = db.ref("withdraw_requests").orderByKey();
    if (resumeKey) {
      q = q.startAfter(resumeKey);
    }
    let snap;
    try {
      snap = await q.limitToFirst(BATCH).get();
    } catch (e) {
      logger.warn("adminListWithdrawalsPage batch failed", { err: String(e?.message || e) });
      break;
    }
    const val = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
    const batchKeys = Object.keys(val).sort();
    lastBatchFull = batchKeys.length === BATCH;
    if (batchKeys.length === 0) break;
    for (const k of batchKeys) {
      scanned += 1;
      lastScannedKey = k;
      const row = val[k];
      if (withdrawalRowMatches(k, row, f)) {
        const snap = row?.withdrawal_destination_snapshot;
        const wa = row?.withdrawalAccount ?? row?.destination;
        const bankFromSnap =
          snap && typeof snap === "object" ? String(snap.bank_name ?? "").trim() : "";
        const acctFromSnap =
          snap && typeof snap === "object" ? String(snap.account_number ?? "").trim() : "";
        const holderFromSnap =
          snap && typeof snap === "object" ? String(snap.account_holder_name ?? "").trim() : "";
        const bankFromWa =
          wa && typeof wa === "object"
            ? String(wa.bankName ?? wa.bank_name ?? "").trim()
            : "";
        const acctFromWa =
          wa && typeof wa === "object"
            ? String(wa.accountNumber ?? wa.account_number ?? "").replace(/\D/g, "")
            : "";
        const holderFromWa =
          wa && typeof wa === "object"
            ? String(
                wa.accountName ??
                  wa.account_holder_name ??
                  wa.account_name ??
                  wa.holderName ??
                  "",
              ).trim()
            : "";
        const bank_name = bankFromSnap || bankFromWa;
        const account_number = acctFromSnap || acctFromWa;
        const account_holder_name = holderFromSnap || holderFromWa;
        const has_destination = !!(bank_name && account_number && account_holder_name);
        matches[k] = {
          id: k,
          status: row?.status ?? null,
          amount: Number(row?.amount ?? 0) || 0,
          entity_type: String(row?.entity_type ?? row?.entityType ?? "driver")
            .trim()
            .toLowerCase(),
          driver_id: normUid(row?.driverId ?? row?.driver_id),
          driver_name: String(row?.driverName ?? row?.driver_name ?? "").slice(0, 120) || null,
          merchant_id: normUid(row?.merchantId ?? row?.merchant_id) || null,
          requestedAt: Number(row?.requestedAt ?? row?.created_at ?? 0) || 0,
          updated_at: Number(row?.updated_at ?? row?.updatedAt ?? 0) || 0,
          bank_name: bank_name || null,
          account_number: account_number || null,
          account_holder_name: account_holder_name || null,
          has_destination: has_destination,
        };
        if (Object.keys(matches).length >= limit + 1) break;
      }
    }
    resumeKey = batchKeys[batchKeys.length - 1];
    if (batchKeys.length < BATCH) break;
  }

  const keys = Object.keys(matches).sort(
    (a, b) => (matches[b].requestedAt || 0) - (matches[a].requestedAt || 0),
  );
  const hasMoreFromMatches = keys.length > limit;
  const pageKeys = hasMoreFromMatches ? keys.slice(0, limit) : keys;
  const page = {};
  for (const k of pageKeys) {
    page[k] = matches[k];
  }
  const hasMore = hasMoreFromMatches || (pageKeys.length === limit && lastBatchFull && scanned < MAX_SCAN);
  const nextCursor = lastScannedKey && hasMore ? lastScannedKey : null;
  return {
    success: true,
    withdrawals: page,
    nextCursor,
    hasMore,
    count: pageKeys.length,
    scanned,
    capped_scan: scanned >= MAX_SCAN,
  };
}

function supportTicketRowMatches(id, t, f) {
  if (!t || typeof t !== "object") return false;
  const st = String(t.status ?? "").toLowerCase();
  if (f.status && f.status !== "all" && !st.includes(f.status)) return false;
  if (f.search) {
    const q = f.search.toLowerCase();
    const subj = String(t.subject ?? "").toLowerCase();
    const uid = String(t.createdByUserId ?? "").toLowerCase();
    if (!id.toLowerCase().includes(q) && !subj.includes(q) && !uid.includes(q)) return false;
  }
  const uAt = Number(t.updatedAt ?? t.updated_at ?? 0) || 0;
  if (f.createdFrom > 0 && uAt > 0 && uAt < f.createdFrom) return false;
  if (f.createdTo > 0 && uAt > 0 && uAt > f.createdTo) return false;
  return true;
}

async function adminListSupportTicketsPage(data, context, db) {
  const _rbac = await _adminGate("adminListSupportTicketsPage", context, db);
  if (_rbac) return _rbac;
  const f = parseAdminListParams(data || {});
  const limit = f.limit;
  const MAX_SCAN = 4000;
  const BATCH = 120;
  let resumeKey = f.cursor.trim();
  const matches = {};
  let scanned = 0;
  let lastScannedKey = resumeKey;
  let lastBatchFull = false;

  while (Object.keys(matches).length < limit + 1 && scanned < MAX_SCAN) {
    let q = db.ref("support_tickets").orderByKey();
    if (resumeKey) {
      q = q.startAfter(resumeKey);
    }
    let snap;
    try {
      snap = await q.limitToFirst(BATCH).get();
    } catch (e) {
      logger.warn("adminListSupportTicketsPage batch failed", { err: String(e?.message || e) });
      break;
    }
    const val = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
    const batchKeys = Object.keys(val).sort();
    lastBatchFull = batchKeys.length === BATCH;
    if (batchKeys.length === 0) break;
    for (const k of batchKeys) {
      scanned += 1;
      lastScannedKey = k;
      const t = val[k];
      if (supportTicketRowMatches(k, t, f)) {
        matches[k] = {
          id: k,
          status: t?.status ?? null,
          createdByUserId: normUid(t?.createdByUserId),
          subject: String(t?.subject ?? "").slice(0, 200) || null,
          ride_id: normUid(t?.ride_id ?? t?.rideId) || null,
          updatedAt: Number(t?.updatedAt ?? t?.updated_at ?? 0) || 0,
          createdAt: Number(t?.createdAt ?? t?.created_at ?? 0) || 0,
        };
        if (Object.keys(matches).length >= limit + 1) break;
      }
    }
    resumeKey = batchKeys[batchKeys.length - 1];
    if (batchKeys.length < BATCH) break;
  }

  const keys = Object.keys(matches).sort(
    (a, b) => (matches[b].updatedAt || 0) - (matches[a].updatedAt || 0),
  );
  const hasMoreFromMatches = keys.length > limit;
  const pageKeys = hasMoreFromMatches ? keys.slice(0, limit) : keys;
  const page = {};
  for (const k of pageKeys) {
    page[k] = matches[k];
  }
  const hasMore = hasMoreFromMatches || (pageKeys.length === limit && lastBatchFull && scanned < MAX_SCAN);
  const nextCursor = lastScannedKey && hasMore ? lastScannedKey : null;
  return {
    success: true,
    tickets: page,
    nextCursor,
    hasMore,
    count: pageKeys.length,
    scanned,
    capped_scan: scanned >= MAX_SCAN,
  };
}

async function adminReviewSubscriptionRequest(data, context, db) {
  const _rbac = await _adminGate("adminReviewSubscriptionRequest", context, db);
  if (_rbac) return _rbac;
  let driverId = "";
  let action = "";
  try {
    driverId = normUid(data?.driverId ?? data?.driver_id ?? data?.uid);
    action = String(data?.action ?? "").trim().toLowerCase();
    logger.info("ADMIN_REVIEW_START", { driverId, action });
    if (!driverId || (action !== "approve" && action !== "reject")) {
      logger.info("ADMIN_REVIEW_INVALID_INPUT", { driverId, action });
      return { success: false, reason: "invalid_input" };
    }
    const now = nowMs();
    const driverSnap = await db.ref(`drivers/${driverId}`).get();
    const driverExists =
      typeof driverSnap.exists === "function"
        ? driverSnap.exists()
        : !!driverSnap.exists;
    logger.info("ADMIN_REVIEW_DRIVER_READ", {
      exists: driverExists,
      driverId,
    });
    const driver =
      driverSnap.val() && typeof driverSnap.val() === "object" ? driverSnap.val() : null;
    if (!driver) {
      logger.warn("ADMIN_REVIEW_DRIVER_MISSING", { driverId });
      return { success: false, reason: "driver_not_found" };
    }
    const planType = String(
      driver.subscription_type ??
        driver?.businessModel?.subscription?.planType ??
        "monthly",
    )
      .trim()
      .toLowerCase() === "weekly"
      ? "weekly"
      : "monthly";
    const durationDays = planType === "weekly" ? 7 : 30;
    const expiresAt = now + durationDays * 24 * 60 * 60 * 1000;
    logger.info("ADMIN_REVIEW_COMPUTING", { action, planType, expiresAt });
    const expiryDateLabel = new Date(expiresAt).toLocaleDateString("en-NG", {
      day: "2-digit",
      month: "short",
      year: "numeric",
    });
    const updates = {
      [`drivers/${driverId}/subscription_pending`]: false,
      [`drivers/${driverId}/updated_at`]: now,
      [`drivers/${driverId}/businessModel/selectedModel`]: "subscription",
      [`drivers/${driverId}/businessModel/subscription/planType`]: planType,
      [`drivers/${driverId}/businessModel/subscription/updatedAt`]: now,
      [`drivers/${driverId}/businessModel/updatedAt`]: now,
    };
    if (action === "approve") {
      updates[`drivers/${driverId}/subscription_status`] = "active";
      updates[`drivers/${driverId}/commission_exempt`] = true;
      updates[`drivers/${driverId}/subscription_renewal_reminder_sent`] = false;
      updates[`drivers/${driverId}/subscription_expires_at`] = expiresAt;
      updates[`drivers/${driverId}/businessModel/subscription/status`] = "active";
      updates[`drivers/${driverId}/businessModel/subscription/paymentStatus`] = "paid";
      updates[`drivers/${driverId}/businessModel/commissionExempt`] = true;
      updates[`drivers/${driverId}/businessModel/commission_exempt`] = true;
    } else {
      updates[`drivers/${driverId}/subscription_status`] = "rejected";
      updates[`drivers/${driverId}/commission_exempt`] = false;
      updates[`drivers/${driverId}/businessModel/subscription/status`] = "rejected";
      updates[`drivers/${driverId}/businessModel/subscription/paymentStatus`] = "rejected";
      updates[`drivers/${driverId}/businessModel/commissionExempt`] = false;
      updates[`drivers/${driverId}/businessModel/commission_exempt`] = false;
    }
    await db.ref().update(updates);
    logger.info("ADMIN_REVIEW_RTDB_WRITTEN", { driverId, action });
    if (action === "approve") {
      await sendPushToUser(db, driverId, {
        notification: {
          title: "Subscription Approved!",
          body: `You now keep 100% of your trip earnings. Your plan is active until ${expiryDateLabel}.`,
        },
        data: {
          type: "subscription_status",
          status: "active",
          expires_at: String(expiresAt),
        },
      });
    } else {
      await sendPushToUser(db, driverId, {
        notification: {
          title: "Subscription Update",
          body: "Your subscription request was not approved. Please contact NexRide support for assistance.",
        },
        data: {
          type: "subscription_status",
          status: "rejected",
        },
      });
    }
    logger.info("ADMIN_REVIEW_FCM_SENT", { driverId });
    await writeAdminAudit(db, {
      type: "admin_subscription_review",
      driver_id: driverId,
      action,
      actor_uid: normUid(context.auth.uid),
      plan_type: planType,
      expires_at: action === "approve" ? expiresAt : null,
    });
    logger.info("ADMIN_REVIEW_COMPLETE", {
      driverId,
      action,
      success: true,
    });
    return { success: true, action, driverId };
  } catch (error) {
    logger.error("ADMIN_REVIEW_UNHANDLED_ERROR", {
      message: error?.message,
      stack: error?.stack,
      driverId,
      action,
    });
    throw error;
  }
}

async function adminFetchSubscriptionProofUrl(data, context, db) {
  const _rbac = await _adminGate("adminFetchSubscriptionProofUrl", context, db);
  if (_rbac) return _rbac;
  const driverId = normUid(data?.driverId ?? data?.driver_id ?? data?.uid);
  if (!driverId) {
    return { success: false, reason: "invalid_driver_id" };
  }
  const snap = await db.ref(`drivers/${driverId}/subscription_proof_url`).get();
  const proofUrl = String(snap.val() ?? "").trim();
  if (!proofUrl) {
    return { success: false, reason: "no_proof_url" };
  }
  logger.info("adminFetchSubscriptionProofUrl", { driverId, admin: normUid(context.auth.uid) });
  return { success: true, proofUrl };
}

async function adminSuspendAccount(data, context, db) {
  const uid = normUid(data?.uid ?? data?.userId);
  const role = String(data?.role ?? "").trim().toLowerCase();
  const reason = String(data?.reason ?? "").trim().slice(0, 500);
  if (!uid || (role !== "driver" && role !== "rider")) {
    return { success: false, reason: "invalid_input" };
  }
  const suspendPerm = role === "driver" ? "drivers.write" : "riders.write";
  const deny = await adminPerms.enforcePermission(db, context, suspendPerm, "adminSuspendAccount", {
    auditDenied: true,
  });
  if (deny) return deny;
  if (reason.length < 8) {
    return { success: false, reason: "reason_required" };
  }
  const adminUid = normUid(context.auth.uid);
  const now = nowMs();
  let before = null;
  if (role === "driver") {
    const prevSnap = await db.ref(`drivers/${uid}`).get();
    const p = prevSnap.val() && typeof prevSnap.val() === "object" ? prevSnap.val() : {};
    before = {
      suspended: !!p.suspended,
      account_suspended: !!p.account_suspended,
      account_status: p.account_status ?? p.accountStatus ?? null,
      online: !!(p.online || p.is_online || p.isOnline),
    };
  } else {
    const prevSnap = await db.ref(`users/${uid}`).get();
    const p = prevSnap.val() && typeof prevSnap.val() === "object" ? prevSnap.val() : {};
    before = {
      status: p.status ?? null,
      account_status: p.account_status ?? p.accountStatus ?? null,
    };
  }
  if (role === "driver") {
    await db.ref(`drivers/${uid}`).update({
      suspended: true,
      account_suspended: true,
      account_status: "suspended",
      accountStatus: "suspended",
      admin_suspended_at: now,
      admin_suspended_by: adminUid,
      admin_suspension_reason: reason,
      isOnline: false,
      is_online: false,
      online: false,
      isAvailable: false,
      available: false,
      status: "offline",
      dispatch_state: "offline",
      driver_availability_mode: "offline",
      updated_at: now,
    });
    try {
      await db.ref(`online_drivers/${uid}`).remove();
    } catch (_) {
      /* ignore */
    }
    await sendPushToUser(db, uid, {
      notification: {
        title: "Account suspended",
        body: "Your account has been suspended. Contact support.",
      },
    });
  } else {
    await db.ref(`users/${uid}`).update({
      status: "suspended",
      account_status: "suspended",
      admin_suspended_at: now,
      admin_suspended_by: adminUid,
      admin_suspension_reason: reason,
      updated_at: now,
      "trustSummary/accountStatus": "suspended",
    });
    await sendPushToUser(db, uid, {
      notification: {
        title: "Account suspended",
        body: "Your account has been suspended. Contact support.",
      },
    });
  }
  await adminAuditLog.writeAdminAuditLog(db, {
    actor_uid: adminUid,
    action: role === "driver" ? "suspend_driver" : "suspend_rider",
    entity_type: role === "driver" ? "driver" : "rider",
    entity_id: uid,
    before,
    after: {
      suspended: true,
      account_status: "suspended",
      role,
    },
    reason,
    source: "admin_callables.adminSuspendAccount",
    type: "admin_suspend_account",
    created_at: now,
  });
  logger.info("adminSuspendAccount", { uid, role, admin: adminUid });
  return { success: true, reason: "suspended", reason_code: "suspended", uid, role };
}

async function adminWarnAccount(data, context, db) {
  const uid = normUid(data?.uid ?? data?.userId);
  const role = String(data?.role ?? "").trim().toLowerCase();
  const reason = String(data?.reason ?? "").trim().slice(0, 500);
  const message = String(data?.message ?? "").trim().slice(0, 500);
  if (!uid || (role !== "driver" && role !== "rider")) {
    return { success: false, reason: "invalid_input" };
  }
  const warnPerm = role === "driver" ? "drivers.write" : "riders.write";
  const denyWarn = await adminPerms.enforcePermission(db, context, warnPerm, "adminWarnAccount", {
    auditDenied: true,
  });
  if (denyWarn) return denyWarn;
  if (reason.length < 4) {
    return { success: false, reason: "reason_required" };
  }
  const adminUid = normUid(context.auth.uid);
  const now = nowMs();
  const warnPath = role === "driver" ? `drivers/${uid}/warnings` : `users/${uid}/warnings`;
  await db.ref(warnPath).push().set({
    created_at: now,
    reason,
    message: message || null,
    admin_uid: adminUid,
  });
  await sendPushToUser(db, uid, {
    notification: {
      title: "NexRide notice",
      body: "You have received a warning from NexRide.",
    },
    data: {
      kind: "admin_warning",
      reason: reason.slice(0, 200),
    },
  });
  await adminAuditLog.writeAdminAuditLog(db, {
    actor_uid: adminUid,
    action: role === "driver" ? "warn_driver" : "warn_rider",
    entity_type: role === "driver" ? "driver" : "rider",
    entity_id: uid,
    before: null,
    after: { warning_recorded: true, message: message || null },
    reason,
    source: "admin_callables.adminWarnAccount",
    type: "admin_warn_account",
    created_at: now,
  });
  logger.info("adminWarnAccount", { uid, role, admin: adminUid });
  return { success: true, reason: "warned", reason_code: "warned", uid, role };
}

async function adminDeleteAccount(data, context, db) {
  const _rbac = await _adminGate("adminDeleteAccount", context, db);
  if (_rbac) return _rbac;
  const uid = normUid(data?.uid ?? data?.userId);
  const role = String(data?.role ?? "").trim().toLowerCase();
  if (!uid || (role !== "driver" && role !== "rider")) {
    return { success: false, reason: "invalid_input" };
  }
  const adminUid = normUid(context.auth.uid);
  if (uid === adminUid) {
    return { success: false, reason: "cannot_delete_self" };
  }
  const updates = {};
  updates[`user_device_tokens/${uid}`] = null;
  if (role === "driver") {
    updates[`drivers/${uid}`] = null;
    updates[`users/${uid}`] = null;
  } else {
    updates[`users/${uid}`] = null;
  }
  await db.ref().update(updates);
  try {
    await getAuth().deleteUser(uid);
  } catch (err) {
    logger.warn("adminDeleteAccount: auth deleteUser failed", {
      uid,
      err: String(err?.message || err),
    });
  }
  await writeAdminAudit(db, {
    type: "admin_delete_account",
    uid,
    role,
    actor_uid: adminUid,
  });
  logger.info("adminDeleteAccount", { uid, role, admin: adminUid });
  return { success: true, uid, role };
}

async function adminFlagUserForSupportContact(data, context, db) {
  const _rbac = await _adminGate("adminFlagUserForSupportContact", context, db);
  if (_rbac) return _rbac;
  const uid = normUid(data?.uid ?? data?.userId);
  const role = String(data?.role ?? "").trim().toLowerCase();
  const note = String(data?.note ?? "").trim().slice(0, 500);
  const priority = ["urgent", "high", "normal"].includes(
    String(data?.priority ?? "normal").trim().toLowerCase(),
  )
    ? String(data.priority).trim().toLowerCase()
    : "normal";

  if (!uid || !["driver", "rider", "merchant"].includes(role)) {
    return { success: false, reason: "invalid_input" };
  }
  if (note.length < 4) {
    return { success: false, reason: "note_required" };
  }

  const adminUid = normUid(context.auth.uid);
  const now = nowMs();

  await db.ref("admin_support_flags").push().set({
    uid,
    role,
    note,
    priority,
    admin_uid: adminUid,
    created_at: now,
    status: "pending",
  });

  try {
    await sendPushToUser(db, uid, {
      notification: {
        title: "NexRide Support",
        body: "Our support team will be in touch with you shortly.",
      },
      data: { kind: "support_contact_flag" },
    });
  } catch (e) {
    logger.warn("adminFlagUserForSupportContact: push failed", { uid, error: String(e) });
  }

  await writeAdminAudit(db, {
    type: "admin_flag_for_support",
    uid,
    role,
    note,
    priority,
    actor_uid: adminUid,
  });

  logger.info("adminFlagUserForSupportContact", { uid, role, priority, admin: adminUid });
  return { success: true, uid, role, priority };
}

async function adminReviewRiderFirestoreIdentity(data, context, db) {
  const _rbac = await _adminGate("adminReviewRiderFirestoreIdentity", context, db);
  if (_rbac) return _rbac;
  const riderId = normUid(data?.riderId ?? data?.rider_id ?? data?.uid);
  const decision = String(data?.decision ?? "").trim().toLowerCase();
  if (!riderId || (decision !== "approved" && decision !== "rejected")) {
    return { success: false, reason: "invalid_payload" };
  }
  const rejectionReason = String(data?.rejectionReason ?? data?.rejection_reason ?? "").trim().slice(0, 2000);
  if (decision === "rejected" && rejectionReason.length < 8) {
    return { success: false, reason: "rejection_reason_required" };
  }

  const fs = admin.firestore();
  const adminUid = normUid(context.auth.uid);

  /** @type {Record<string, unknown>} */
  const payload = {
    verificationStatus: decision === "approved" ? "approved" : "rejected",
    verificationReviewedAt: FieldValue.serverTimestamp(),
    verificationReviewedBy: adminUid,
  };

  if (decision === "approved") {
    payload.verificationRejected = false;
    payload.verificationRejectionReason = FieldValue.delete();
  } else {
    payload.verificationRejected = true;
    payload.verificationRejectionReason = rejectionReason;
  }

  await fs.collection("users").doc(riderId).set(payload, { merge: true });

  const vRoot = `users/${riderId}/verification`;
  const now = nowMs();
  try {
    if (decision === "approved") {
      await db.ref().update({
        [`${vRoot}/overallStatus`]: "approved",
        [`${vRoot}/documents/identity/status`]: "verified",
        [`${vRoot}/documents/selfie/status`]: "verified",
        [`${vRoot}/checks/identity/status`]: "verified",
        [`${vRoot}/checks/liveness/status`]: "verified",
        [`${vRoot}/checks/face_match/status`]: "verified",
        [`${vRoot}/reviewedAt`]: now,
        [`${vRoot}/reviewedBy`]: adminUid,
        [`${vRoot}/updatedAt`]: now,
      });
    } else {
      await db.ref().update({
        [`${vRoot}/overallStatus`]: "rejected",
        [`${vRoot}/documents/identity/status`]: "rejected",
        [`${vRoot}/documents/selfie/status`]: "rejected",
        [`${vRoot}/failureReason`]: rejectionReason.slice(0, 500),
        [`${vRoot}/reviewedAt`]: now,
        [`${vRoot}/reviewedBy`]: adminUid,
        [`${vRoot}/updatedAt`]: now,
      });
    }
  } catch (e) {
    logger.warn("adminReviewRiderFirestoreIdentity: rtdb verification mirror failed", riderId, String(e?.message || e));
  }

  // Mirror review result to identity_verifications so the panel reflects it.
  await fs.collection("identity_verifications").doc(riderId).set(
    {
      status: decision === "approved" ? "approved" : "rejected",
      reviewed_at: FieldValue.serverTimestamp(),
      review_note: decision === "rejected" ? rejectionReason : "",
      updated_at: FieldValue.serverTimestamp(),
    },
    { merge: true },
  ).catch((e) => logger.warn("identity_verifications mirror failed", riderId, String(e?.message || e)));

  // Push notification to the rider.
  const notifTitle = decision === "approved" ? "Identity Verified" : "Verification Update";
  const notifBody = decision === "approved"
    ? "Your identity has been verified. You can now book rides."
    : `Your identity verification was not approved. ${rejectionReason ? rejectionReason.slice(0, 120) : "Please resubmit."}`;
  await sendPushToUser(db, riderId, {
    notification: { title: notifTitle, body: notifBody },
    data: { type: "rider_identity_review", decision },
  }).catch((e) => logger.warn("rider identity push failed", riderId, String(e?.message || e)));

  await writeAdminAudit(db, {
    type: "admin_review_rider_firestore_identity",
    rider_id: riderId,
    actor_uid: adminUid,
    decision,
    rejection_reason: decision === "rejected" ? rejectionReason : "",
  });

  logger.info("adminReviewRiderFirestoreIdentity", { riderId, decision, admin: adminUid });
  return { success: true, riderId, decision };
}

async function adminApproveDriverVerification(data, context, db) {
  const _rbac = await _adminGate("adminApproveDriverVerification", context, db);
  if (_rbac) return _rbac;
  const driverId = normUid(data?.driverId ?? data?.driver_id ?? data?.uid);
  if (!driverId) {
    return { success: false, reason: "invalid_driver_id", reason_code: "invalid_driver_id" };
  }
  const now = nowMs();
  const adminUid = normUid(context.auth.uid);
  const prevSnap = await db.ref(`drivers/${driverId}`).get();
  const prev = prevSnap.val() && typeof prevSnap.val() === "object" ? prevSnap.val() : {};
  const before = {
    nexride_verified: !!prev.nexride_verified,
    verification_status: prev.verification_status ?? null,
    identity_verification_status: prev.identity_verification_status ?? null,
  };
  // Multi-path RTDB update: driver profile (identity + verification blob) **and**
  // `users/{uid}/kyc_status` so the driver app's KYC gate
  // (`driverPassesKycGateForGoOnline`) passes after manual admin approval.
  const dRoot = `drivers/${driverId}`;
  const kycRoot = `users/${driverId}/kyc_status`;
  await db.ref().update({
    [`${dRoot}/verification_status`]: "approved",
    [`${dRoot}/identity_verification_status`]: "approved",
    [`${dRoot}/is_verified`]: true,
    [`${dRoot}/nexride_verified`]: true,
    [`${dRoot}/verification_approved_at`]: now,
    [`${dRoot}/verification_approved_by`]: adminUid,
    [`${dRoot}/verification/overallStatus`]: "approved",
    [`${dRoot}/updated_at`]: now,
    [`${kycRoot}/kyc_approved`]: true,
    [`${kycRoot}/kyc_admin_override`]: true,
    [`${kycRoot}/submission_status`]: "approved",
    [`${kycRoot}/admin_approved_at`]: now,
    [`${kycRoot}/admin_approved_by`]: adminUid,
    [`${kycRoot}/updated_at`]: now,
  });
  await adminAuditLog.writeAdminAuditLog(db, {
    actor_uid: adminUid,
    action: "approve_verification",
    entity_type: "driver",
    entity_id: driverId,
    before,
    after: {
      nexride_verified: true,
      verification_status: "approved",
      identity_verification_status: "approved",
    },
    reason: String(data?.reason ?? data?.note ?? "").trim().slice(0, 500) || null,
    source: "admin_callables.adminApproveDriverVerification",
    type: "admin_approve_driver_verification",
    created_at: now,
  });
  await sendPushToUser(db, driverId, {
    notification: {
      title: "Account Verified",
      body: "Your driver account has been verified. You can now go online and accept rides.",
    },
    data: { type: "driver_verification_approved" },
  }).catch((e) => logger.warn("driver verification push failed", driverId, String(e?.message || e)));
  logger.info("adminApproveDriverVerification", { driverId, admin: adminUid });
  return { success: true, reason: "approved", reason_code: "driver_verification_approved", driverId };
}

module.exports = {
  adminListLiveRides,
  adminGetRideDetails,
  adminListLiveTrips,
  adminGetTripDetail,
  adminCancelTrip,
  adminMarkTripEmergency,
  adminResolveTripEmergency,
  adminListOnlineDrivers,
  adminApproveWithdrawal,
  adminRejectWithdrawal,
  adminVerifyDriver,
  adminApproveManualPayment,
  adminSuspendDriver,
  adminListSupportTickets,
  adminGetSidebarBadgeCounts,
  adminListPendingWithdrawals,
  adminListPayments,
  adminListDrivers,
  adminFetchDriversTree,
  adminListDriversPage,
  adminGetDriverProfile,
  adminGetDriverOverview,
  adminGetDriverVerification,
  adminGetDriverWallet,
  adminGetDriverTrips,
  adminGetDriverSubscription,
  adminGetDriverViolations,
  adminGetDriverNotes,
  adminGetDriverAuditTimeline,
  adminListRidersPage,
  adminGetRiderProfile,
  adminListTripsPage,
  adminListWithdrawalsPage,
  adminListSupportTicketsPage,
  adminListRiders,
  adminReviewSubscriptionRequest,
  adminFetchSubscriptionProofUrl,
  adminSuspendAccount,
  adminWarnAccount,
  adminDeleteAccount,
  adminFlagUserForSupportContact,
  adminReviewRiderFirestoreIdentity,
  adminApproveDriverVerification,
};
