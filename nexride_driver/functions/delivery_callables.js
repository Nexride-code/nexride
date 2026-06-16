/**
 * NexRide delivery (dispatch) — parallel system to car rides.
 *
 * RTDB (server-written only from these callables):
 * - delivery_requests/{deliveryId}
 * - user_active_delivery/{customerId}
 * - delivery_offer_queue/{driverId}/{deliveryId}
 * - delivery_offer_fanout/{deliveryId}/{driverId}
 * - active_deliveries/{deliveryId}  (after accept)
 * - driver_active_delivery/{driverId}
 */

const admin = require("firebase-admin");
const { ServerValue } = require("firebase-admin/database");
const {
  evaluateDriverForOffer,
  evaluateDriverGeoAndMode,
  logMatchLocationSource,
  loadDispatchGates,
} = require("./driver_dispatch_gates");
const { logger } = require("firebase-functions");
const ride = require("./ride_callables");
const riderFirestoreIdentity = require("./rider_firestore_identity");
const { sendPushToUser } = require("./push_notifications");
const deliveryRegions = require("./ecosystem/delivery_regions");
const { syncDeliveryTrackPublic } = require("./track_public");
const fleetAccountability = require("./fleet_driver_accountability");
const { createSupportTicketFirestore } = require("./support_ticket_firestore");

const MAX_FARE_NGN_DEFAULT = 25_000_000;
const MIN_LAT_NG = 4.2;
const MAX_LAT_NG = 13.75;
const MIN_LNG_NG = 2.53;
const MAX_LNG_NG = 14.73;

/** Canonical delivery lifecycle (all clients derive UI from these). */
const DELIVERY_STATE = {
  searching: "searching",
  driver_assigned: "driver_assigned",
  driver_arriving_pickup: "driver_arriving_pickup",
  picked_up: "picked_up",
  on_delivery: "on_delivery",
  arrived_dropoff: "arrived_dropoff",
  completed: "completed",
  cancelled: "cancelled",
};

/** Legacy RTDB values → canonical (read-path normalization). */
const LEGACY_DELIVERY_STATE_MAP = {
  accepted: DELIVERY_STATE.driver_assigned,
  enroute_pickup: DELIVERY_STATE.driver_arriving_pickup,
  arrived_pickup: DELIVERY_STATE.driver_arriving_pickup,
  enroute_dropoff: DELIVERY_STATE.on_delivery,
  delivered: DELIVERY_STATE.completed,
};

const TERMINAL_DELIVERY = new Set([DELIVERY_STATE.completed, DELIVERY_STATE.cancelled]);

const DELIVERY_MATCH_LOCK_MAX_AGE_MS = 120_000;
const DELIVERY_ACCEPT_TX_MAX_ATTEMPTS = 8;
const DELIVERY_GEO_GATE_RADIUS_M = 150;
/** Driver search / offer accept window from create or verified-payment fan-out. */
const DELIVERY_SEARCH_TTL_MS = 180_000;
/** Model B: rider must pay within this window after driver accept (assigned, unpaid). */
const DELIVERY_UNPAID_PAYMENT_TTL_MS = 30 * 60 * 1000;

const DELIVERY_CATEGORIES = new Set(["parcel", "food", "document", "grocery", "other"]);

const PAYMENT_METHODS_ALLOWED = new Set([
  "card",
  "credit_card",
  "creditcard",
  "debit_card",
  "flutterwave",
  "bank_transfer",
]);

/** Driver-only linear progression after accept (canonical states). */
const DRIVER_DELIVERY_NEXT = {
  [DELIVERY_STATE.driver_assigned]: DELIVERY_STATE.driver_arriving_pickup,
  [DELIVERY_STATE.driver_arriving_pickup]: DELIVERY_STATE.picked_up,
  [DELIVERY_STATE.picked_up]: DELIVERY_STATE.on_delivery,
  [DELIVERY_STATE.on_delivery]: DELIVERY_STATE.arrived_dropoff,
  [DELIVERY_STATE.arrived_dropoff]: DELIVERY_STATE.completed,
};

function normalizeDeliveryState(raw) {
  const s = String(raw ?? "").trim().toLowerCase();
  return LEGACY_DELIVERY_STATE_MAP[s] || s;
}

function sleepMs(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function haversineMeters(lat1, lng1, lat2, lng2) {
  const R = 6371000;
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

function driverNearPickup(row, driverLat, driverLng, radiusM = DELIVERY_GEO_GATE_RADIUS_M) {
  if (!Number.isFinite(driverLat) || !Number.isFinite(driverLng)) {
    return false;
  }
  const p = coordsFromPickup(row?.pickup);
  if (!Number.isFinite(p.lat) || !Number.isFinite(p.lng)) {
    return false;
  }
  return haversineMeters(p.lat, p.lng, driverLat, driverLng) <= radiusM;
}

function driverNearDropoff(row, driverLat, driverLng, radiusM = DELIVERY_GEO_GATE_RADIUS_M) {
  if (!Number.isFinite(driverLat) || !Number.isFinite(driverLng)) {
    return false;
  }
  const d = coordsFromPickup(row?.dropoff);
  if (!Number.isFinite(d.lat) || !Number.isFinite(d.lng)) {
    return false;
  }
  return haversineMeters(d.lat, d.lng, driverLat, driverLng) <= radiusM;
}

function normUid(u) {
  return String(u ?? "").trim();
}

function nowMs() {
  return Date.now();
}

function normDeliveryIdFromCallableData(data) {
  const v = data?.deliveryId ?? data?.delivery_id ?? data?.requestId ?? data?.request_id;
  let s = String(v ?? "").trim();
  s = s.replace(/[\u2013\u2014\u2212]/g, "-");
  return s;
}

function normDriverIdFromCallableData(data, authUid) {
  const v = data?.driverId ?? data?.driver_id ?? data?.uid;
  const fromBody = normUid(v);
  return fromBody || normUid(authUid);
}

function coordsFromPickup(o) {
  if (!o || typeof o !== "object") return { lat: NaN, lng: NaN };
  const lat = Number(o.lat ?? o.latitude ?? o.Latitude ?? "");
  const lng = Number(o.lng ?? o.longitude ?? o.Longitude ?? "");
  return { lat, lng };
}

function coordsInNgBox(lat, lng) {
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) return false;
  return lat >= MIN_LAT_NG && lat <= MAX_LAT_NG && lng >= MIN_LNG_NG && lng <= MAX_LNG_NG;
}

async function writeAudit(db, entry) {
  await db
    .ref("admin_audit_logs")
    .push()
    .set({ ...entry, created_at: nowMs() });
}

function deliveryHasVerifiedOnlinePayment(row) {
  if (!row || typeof row !== "object") return false;
  const ps = String(row.payment_status ?? "").trim().toLowerCase();
  const ptid = String(row.payment_transaction_id ?? row.flw_tx_id ?? "").trim();
  if (ps === "paid_verified" && Boolean(ptid)) {
    return row.payment_verified === true;
  }
  return ps === "verified" && Boolean(ptid) && row.payment_verified === true;
}

/** Blocks driver/biker cancel once delivery payment is verified or marked paid. */
function deliveryPaymentBlocksDriverCancel(row) {
  if (!row || typeof row !== "object") return false;
  if (row.payment_verified === true) return true;
  const ps = String(row.payment_status ?? "").trim().toLowerCase();
  return ps === "verified" || ps === "paid";
}

/** Model B: fan-out while payment is still pending (searching, unassigned). */
function deliveryFanoutEligibleModelB(row) {
  if (!row || typeof row !== "object") {
    return false;
  }
  const ds = normalizeDeliveryState(row.delivery_state);
  if (ds !== DELIVERY_STATE.searching) {
    return false;
  }
  if (canonicalAssignedDeliveryDriverId(row)) {
    return false;
  }
  return Boolean(normUid(row.customer_id));
}

/** Open-pool delivery states eligible for offer fan-out (includes pending payment). */
const DELIVERY_OPEN_FANOUT_STATES = new Set([
  DELIVERY_STATE.searching,
  "requesting",
  "pending",
  "open",
  "matching",
  "awaiting_match",
  "searching_driver",
]);

const DELIVERY_OPEN_FANOUT_STATUS = new Set([
  "searching",
  "requesting",
  "pending",
  "open",
  "matching",
  "awaiting_match",
]);

/**
 * Canonical open delivery predicate for offer fan-out (unassigned + non-terminal).
 */
function deliveryOpensForFanout(row) {
  if (!row || typeof row !== "object") {
    return false;
  }
  if (canonicalAssignedDeliveryDriverId(row)) {
    return false;
  }
  const ds = normalizeDeliveryState(row.delivery_state);
  if (TERMINAL_DELIVERY.has(ds)) {
    return false;
  }
  const st = String(row.status ?? "").trim().toLowerCase();
  if (DELIVERY_OPEN_FANOUT_STATES.has(ds) || DELIVERY_OPEN_FANOUT_STATUS.has(st)) {
    return true;
  }
  return deliveryFanoutEligibleModelB(row);
}

function deliveryFanoutAbortReason(row) {
  if (!row || typeof row !== "object") {
    return "delivery_missing";
  }
  const ds = normalizeDeliveryState(row.delivery_state);
  if (TERMINAL_DELIVERY.has(ds)) {
    return "delivery_terminal";
  }
  if (canonicalAssignedDeliveryDriverId(row)) {
    return "delivery_assigned";
  }
  if (!deliveryOpensForFanout(row)) {
    return "delivery_not_open_for_fanout";
  }
  return "delivery_not_eligible";
}

/** Fan-out allowed while payment is pending or verified (Model B). */
function deliveryAllowsFanoutPayment(row) {
  if (!row || typeof row !== "object") {
    return false;
  }
  if (deliveryHasVerifiedOnlinePayment(row)) {
    return true;
  }
  const ps = String(row.payment_status ?? "").trim().toLowerCase();
  if (
    ps === "pending" ||
    ps === "pending_transfer" ||
    ps === "pending_review" ||
    ps === "pending_manual_confirmation" ||
    ps === "payment_review" ||
    ps === "card_authorized"
  ) {
    return true;
  }
  return deliveryFanoutEligibleModelB(row);
}

/** Driver progress (start/complete) requires settled payment — accept alone does not. */
function paymentAllowsDispatchDelivery(row) {
  return deliveryHasVerifiedOnlinePayment(row);
}

const DELIVERY_PROGRESS_REQUIRES_PAYMENT = new Set([
  DELIVERY_STATE.driver_arriving_pickup,
  DELIVERY_STATE.picked_up,
  DELIVERY_STATE.on_delivery,
  DELIVERY_STATE.arrived_dropoff,
  DELIVERY_STATE.completed,
]);

function deliveryProgressRequiresVerifiedPayment(currentState, nextState) {
  const cur = normalizeDeliveryState(currentState);
  const next = normalizeDeliveryState(nextState);
  if (next === DELIVERY_STATE.cancelled) {
    return false;
  }
  if (!DELIVERY_PROGRESS_REQUIRES_PAYMENT.has(next)) {
    return false;
  }
  return cur === DELIVERY_STATE.driver_assigned || DELIVERY_PROGRESS_REQUIRES_PAYMENT.has(cur);
}

function hasDeliveryProofPhoto(row) {
  if (!row || typeof row !== "object") {
    return false;
  }
  const url = String(
    row.delivery_proof_photo_url ??
      row.deliveryProofPhotoUrl ??
      row.delivery_proof_url ??
      "",
  ).trim();
  return url.startsWith("https://");
}

function trimStr(v, max = 200) {
  return String(v ?? "").trim().slice(0, max);
}

function deliveryRatingPath(deliveryId, roleKey) {
  return `delivery_ratings/${normUid(deliveryId)}/${roleKey}`;
}

function normDeliveryCustomerId(row) {
  if (!row || typeof row !== "object") {
    return "";
  }
  return normUid(
    row.customer_id ??
      row.customerId ??
      row.rider_id ??
      row.riderId ??
      row.sender_id ??
      row.senderId,
  );
}

function hasPickupProofPhoto(row) {
  if (!row || typeof row !== "object") {
    return false;
  }
  const url = String(row.pickup_proof_photo_url ?? row.pickupProofPhotoUrl ?? "").trim();
  return url.startsWith("https://");
}

async function buildDeliveryDriverContactPatch(db, driverId) {
  const d = normUid(driverId);
  if (!d) {
    return {};
  }
  const [drvSnap, userSnap] = await Promise.all([
    db.ref(`drivers/${d}`).get(),
    db.ref(`users/${d}`).get(),
  ]);
  const drv = drvSnap.val() && typeof drvSnap.val() === "object" ? drvSnap.val() : {};
  const user = userSnap.val() && typeof userSnap.val() === "object" ? userSnap.val() : {};
  const first = trimStr(
    drv.first_name ?? drv.firstName ?? user.first_name ?? user.firstName,
    64,
  );
  const last = trimStr(
    drv.last_name ?? drv.lastName ?? user.last_name ?? user.lastName,
    64,
  );
  const display = trimStr(
    drv.display_name ?? drv.displayName ?? user.display_name ?? user.displayName ?? user.name,
    120,
  );
  const name =
    display ||
    [first, last].filter((x) => x.length > 0).join(" ") ||
    trimStr(drv.name ?? drv.driver_name, 120);
  const phone = trimStr(
    drv.phone ??
      drv.phone_number ??
      drv.driver_phone ??
      user.phone ??
      user.phone_number,
    32,
  );
  const vehicleLabel = trimStr(
    drv.dispatch_vehicle_type ??
      drv.dispatchVehicleType ??
      drv.vehicle_type ??
      drv.car ??
      drv.vehicle_label,
    64,
  );
  const plate = trimStr(
    drv.plate ?? drv.plate_number ?? drv.vehicle_plate ?? drv.vehiclePlate,
    32,
  );
  const photoRaw = trimStr(
    drv.photo_url ?? drv.profile_photo_url ?? user.photo_url ?? user.profile_photo_url,
    512,
  );
  const patch = {
    assigned_driver_id: d,
    driver_name: name || null,
    assigned_driver_name: name || null,
    driver_phone: phone || null,
    assigned_driver_phone: phone || null,
    assigned_driver_vehicle: vehicleLabel || null,
    vehicle_label: vehicleLabel || null,
    vehicle_plate: plate || null,
    car: vehicleLabel || null,
    plate: plate || null,
    driver_photo_url: photoRaw.startsWith("https://") ? photoRaw : null,
    assigned_driver_photo_url: photoRaw.startsWith("https://") ? photoRaw : null,
  };
  try {
    const fs = admin.firestore();
    const fleetPatch = await fleetAccountability.buildFleetDeliveryTrustPatch(db, fs, d, drv);
    Object.assign(patch, fleetPatch);
  } catch (fleetPatchErr) {
    console.log(
      "DELIVERY_FLEET_TRUST_PATCH_FAIL",
      `driverId=${d}`,
      String(fleetPatchErr?.message || fleetPatchErr),
    );
  }
  if (!name && !phone) {
    console.log("DELIVERY_CALL_INFO_MISSING", `driverId=${d}`);
  } else {
    console.log(
      "DELIVERY_DRIVER_CONTACT_ATTACHED",
      `driverId=${d}`,
      `hasName=${Boolean(name)}`,
      `hasPhone=${Boolean(phone)}`,
    );
  }
  return patch;
}

async function buildDeliveryCustomerContactPatch(db, customerId) {
  const c = normUid(customerId);
  if (!c) {
    return {};
  }
  const userSnap = await db.ref(`users/${c}`).get();
  const user = userSnap.val() && typeof userSnap.val() === "object" ? userSnap.val() : {};
  const name = trimStr(
    user.display_name ?? user.displayName ?? user.name ?? user.full_name,
    120,
  );
  const phone = trimStr(user.phone ?? user.phone_number ?? user.mobile, 32);
  return {
    customer_name: name || null,
    rider_name: name || null,
    sender_name: name || null,
    customer_phone: phone || null,
    rider_phone: phone || null,
    sender_phone: phone || null,
  };
}

function evaluateDeliveryCancelDecision(row, uid, opts = {}) {
  const u = normUid(uid);
  const customerId = normDeliveryCustomerId(row);
  const driverId = canonicalAssignedDeliveryDriverId(row);
  const isCustomer = customerId === u;
  const isDriver = driverId === u;
  const ds = normalizeDeliveryState(row.delivery_state);
  const paid = deliveryHasVerifiedOnlinePayment(row);
  const cancelReason = String(opts.cancelReason ?? opts.cancel_reason ?? "").trim();
  const requestOnly =
    opts.requestOnly === true ||
    cancelReason === "request_cancel" ||
    cancelReason === "cancellation_requested";

  if (TERMINAL_DELIVERY.has(ds)) {
    return { allowed: false, reason: "already_terminal" };
  }
  if (!isCustomer && !isDriver) {
    return { allowed: false, reason: "forbidden" };
  }

  if (isCustomer) {
    if (ds === DELIVERY_STATE.searching) {
      return {
        allowed: true,
        mode: "cancel",
        cancel_reason: "cancelled_by_rider_searching",
        policy: "delivery_cancelled_searching",
        log: "DELIVERY_CANCEL_ALLOWED_SEARCHING",
      };
    }
    if (ds === DELIVERY_STATE.driver_assigned && !paid) {
      return {
        allowed: true,
        mode: "cancel",
        cancel_reason: "cancelled_by_rider_unpaid",
        policy: "delivery_cancelled_unpaid",
        log: "DELIVERY_CANCEL_ALLOWED_UNPAID",
      };
    }
    if (
      (ds === DELIVERY_STATE.driver_assigned ||
        ds === DELIVERY_STATE.driver_arriving_pickup) &&
      paid
    ) {
      return {
        allowed: true,
        mode: "cancel",
        cancel_reason: "cancelled_before_pickup_paid",
        policy: "delivery_cancelled_before_pickup_paid",
        refund_status: "pending_review",
        log: "DELIVERY_CANCEL_ALLOWED_BEFORE_PICKUP",
      };
    }
    if (
      ds === DELIVERY_STATE.picked_up ||
      ds === DELIVERY_STATE.on_delivery ||
      ds === DELIVERY_STATE.arrived_dropoff
    ) {
      if (requestOnly) {
        return {
          allowed: true,
          mode: "request",
          policy: "delivery_cancel_requested",
          log: "DELIVERY_CANCEL_REQUESTED",
        };
      }
      return {
        allowed: false,
        reason: "delivery_cancel_not_allowed_after_pickup",
        log: "DELIVERY_CANCEL_BLOCKED_AFTER_PICKUP",
      };
    }
    return { allowed: false, reason: "cannot_cancel_at_stage" };
  }

  if (isDriver) {
    if (ds === DELIVERY_STATE.searching) {
      return { allowed: false, reason: "not_assigned" };
    }
    if (deliveryPaymentBlocksDriverCancel(row)) {
      return {
        allowed: false,
        reason: "paid_delivery_driver_cancel_blocked",
        reason_code: "paid_trip_driver_cancel_blocked",
        message:
          "This delivery has already been paid. Contact support if there is a problem.",
        log: "DELIVERY_CANCEL_BLOCKED_PAYMENT_VERIFIED",
      };
    }
    if (
      ds === DELIVERY_STATE.picked_up ||
      ds === DELIVERY_STATE.on_delivery ||
      ds === DELIVERY_STATE.arrived_dropoff
    ) {
      return {
        allowed: false,
        reason: "delivery_cancel_requires_support",
        log: "DELIVERY_CANCEL_BLOCKED_AFTER_PICKUP",
      };
    }
    if (
      row.cancellation_requested_at &&
      (cancelReason === "driver_accept_cancel" || cancelReason === "mutual_cancel")
    ) {
      return {
        allowed: true,
        mode: "cancel",
        cancel_reason: "cancelled_mutual_after_request",
        policy: "delivery_cancel_mutual",
        log: "DELIVERY_CANCEL_MUTUAL_REQUIRED",
      };
    }
    return {
      allowed: true,
      mode: "cancel",
      cancel_reason: cancelReason || "cancelled_by_driver",
      policy: "delivery_cancelled_by_driver",
      log: "DELIVERY_DRIVER_RELEASED_AFTER_CANCEL",
    };
  }

  return { allowed: false, reason: "forbidden" };
}

async function assertDeliveryChatParticipant(db, deliveryId, uid) {
  const rid = normUid(deliveryId);
  const u = normUid(uid);
  if (!rid || !u) {
    return { ok: false, reason: "invalid_input" };
  }
  const snap = await db.ref(`delivery_requests/${rid}`).get();
  const row = snap.val();
  if (!row || typeof row !== "object") {
    return { ok: false, reason: "delivery_missing" };
  }
  const customerId = normDeliveryCustomerId(row);
  const driverId = canonicalAssignedDeliveryDriverId(row);
  if (u === customerId) {
    return { ok: true, role: "rider", row };
  }
  if (u === driverId) {
    return { ok: true, role: "driver", row };
  }
  console.log(
    "DELIVERY_CHAT_ACCESS_DENIED",
    `deliveryId=${rid}`,
    `uid=${u}`,
    `customerId=${customerId}`,
    `driverId=${driverId || "none"}`,
  );
  return { ok: false, reason: "forbidden" };
}

/**
 * Busy-driver guard for dispatch delivery offers/accept.
 * Reuses ride pointer validation; incoming deliveryId is never treated as busy.
 * @returns {Promise<{ busy: boolean, blockingTripId: string|null, cleared: string[], checks: object[] }>}
 */
async function resolveDeliveryBusyGuardForDriver(db, driverId, deliveryId, source) {
  const d = normUid(driverId);
  const rid = normUid(deliveryId);
  if (!d) {
    return { busy: false, blockingTripId: null, cleared: [], checks: [] };
  }
  const { resolveValidatedBlockingTripForDriver } = require("./driver_active_pointer_guard");
  const blockCheck = await resolveValidatedBlockingTripForDriver(db, d, source, rid);
  const blocking = normUid(blockCheck.blockingTripId);
  if (!blocking || blocking === rid) {
    return {
      busy: false,
      blockingTripId: null,
      cleared: blockCheck.cleared || [],
      checks: blockCheck.checks || [],
    };
  }
  return {
    busy: true,
    blockingTripId: blocking,
    cleared: blockCheck.cleared || [],
    checks: blockCheck.checks || [],
  };
}

/**
 * Fresh search/accept expiry fields for a verified-payment fan-out.
 * Mirrors createDeliveryRequest TTL fields (no search_expires_at in schema).
 */
function deliverySearchExpiryFields(now = nowMs()) {
  const expiresAt = now + DELIVERY_SEARCH_TTL_MS;
  return {
    expires_at: expiresAt,
    search_timeout_at: expiresAt,
    request_expires_at: expiresAt,
    updated_at: now,
  };
}

/**
 * P0-A: extend the driver search window when payment is verified, before fan-out.
 * Skips pending_transfer / pending_review and non-verified rows.
 * @returns {Promise<object>} row merged with refreshed expiry when updated
 */
async function refreshDeliverySearchExpiryForVerifiedFanout(db, deliveryId, row, options = {}) {
  const rid = normUid(deliveryId);
  if (!rid || !row || typeof row !== "object") {
    return row && typeof row === "object" ? row : {};
  }
  const ps = String(row.payment_status ?? "").trim().toLowerCase();
  if (ps === "pending_transfer" || ps === "pending_review") {
    return row;
  }
  if (!deliveryHasVerifiedOnlinePayment(row)) {
    return row;
  }
  const patch = deliverySearchExpiryFields(options.now ?? nowMs());
  await db.ref(`delivery_requests/${rid}`).update(patch);
  console.log(
    "DELIVERY_SEARCH_EXPIRY_REFRESH",
    `deliveryId=${rid}`,
    `expires_at=${patch.expires_at}`,
  );
  return { ...row, ...patch };
}

const DELIVERY_FANOUT_AFTER_PAYMENT_IN_PROGRESS_AT_FIELD =
  "delivery_fanout_after_payment_in_progress_at";
const DELIVERY_FANOUT_AFTER_PAYMENT_COMPLETED_AT_FIELD =
  "delivery_fanout_after_payment_completed_at";
/** Short lease preventing concurrent verified-payment fan-out attempts. */
const DELIVERY_FANOUT_AFTER_PAYMENT_LEASE_MS = 60_000;

function deliveryFanoutLeaseIsStale(inProgressAt, now = nowMs()) {
  const ts = Number(inProgressAt ?? 0) || 0;
  if (ts <= 0) return true;
  return now - ts >= DELIVERY_FANOUT_AFTER_PAYMENT_LEASE_MS;
}

/**
 * Acquire in_progress lease for verified-payment fan-out (skip only when completed_at set).
 * @returns {Promise<{ acquired: boolean, skipped?: boolean, reason?: string, leaseAcquiredAt?: number, row?: object }>}
 */
async function tryAcquireDeliveryVerifiedPaymentFanoutLease(db, deliveryId, options = {}) {
  const rid = normUid(deliveryId);
  if (!rid) {
    return { acquired: false, reason: "invalid_delivery_id" };
  }
  const ref = db.ref(`delivery_requests/${rid}`);
  const now = options.now ?? nowMs();
  let abortReason = null;

  const tx = await ref.transaction((current) => {
    if (!current || typeof current !== "object") {
      abortReason = "delivery_missing";
      return;
    }
    if (!deliveryHasVerifiedOnlinePayment(current)) {
      abortReason = "payment_not_verified";
      return;
    }
    const completed =
      Number(current[DELIVERY_FANOUT_AFTER_PAYMENT_COMPLETED_AT_FIELD] ?? 0) || 0;
    if (completed > 0) {
      abortReason = "fanout_completed";
      return;
    }
    const inProgress =
      Number(current[DELIVERY_FANOUT_AFTER_PAYMENT_IN_PROGRESS_AT_FIELD] ?? 0) || 0;
    if (inProgress > 0 && !deliveryFanoutLeaseIsStale(inProgress, now)) {
      abortReason = "fanout_in_progress";
      return;
    }
    return {
      ...current,
      [DELIVERY_FANOUT_AFTER_PAYMENT_IN_PROGRESS_AT_FIELD]: now,
      updated_at: now,
    };
  });

  if (abortReason === "fanout_completed" || abortReason === "fanout_in_progress") {
    console.log(
      "DELIVERY_FANOUT_AFTER_PAYMENT_SKIP",
      `deliveryId=${rid}`,
      `reason=${abortReason}`,
    );
    return { acquired: false, skipped: true, reason: abortReason };
  }
  if (!tx.committed) {
    console.log(
      "DELIVERY_FANOUT_AFTER_PAYMENT_SKIP",
      `deliveryId=${rid}`,
      `reason=${abortReason || "transaction_aborted"}`,
    );
    return { acquired: false, reason: abortReason || "transaction_aborted" };
  }

  const row = tx.snapshot.val();
  console.log(
    "DELIVERY_FANOUT_AFTER_PAYMENT_LEASE",
    `deliveryId=${rid}`,
    `in_progress_at=${now}`,
  );
  return {
    acquired: true,
    leaseAcquiredAt: now,
    row: row && typeof row === "object" ? row : {},
  };
}

async function markDeliveryVerifiedPaymentFanoutCompleted(db, deliveryId, leaseAcquiredAt) {
  const rid = normUid(deliveryId);
  if (!rid) {
    return { committed: false, reason: "invalid_delivery_id" };
  }
  const ref = db.ref(`delivery_requests/${rid}`);
  const now = nowMs();
  let abortReason = null;

  const tx = await ref.transaction((current) => {
    if (!current || typeof current !== "object") {
      abortReason = "delivery_missing";
      return;
    }
    const inProgress =
      Number(current[DELIVERY_FANOUT_AFTER_PAYMENT_IN_PROGRESS_AT_FIELD] ?? 0) || 0;
    const lease = Number(leaseAcquiredAt ?? 0) || 0;
    if (lease > 0 && inProgress !== lease) {
      abortReason = "lease_lost";
      return;
    }
    const next = {
      ...current,
      [DELIVERY_FANOUT_AFTER_PAYMENT_COMPLETED_AT_FIELD]: now,
      updated_at: now,
    };
    delete next[DELIVERY_FANOUT_AFTER_PAYMENT_IN_PROGRESS_AT_FIELD];
    return next;
  });

  if (!tx.committed) {
    return { committed: false, reason: abortReason || "transaction_aborted" };
  }
  console.log(
    "DELIVERY_FANOUT_AFTER_PAYMENT_COMPLETE",
    `deliveryId=${rid}`,
    `completed_at=${now}`,
  );
  return { committed: true, completedAt: now };
}

async function releaseDeliveryVerifiedPaymentFanoutLease(db, deliveryId, leaseAcquiredAt) {
  const rid = normUid(deliveryId);
  if (!rid) {
    return { committed: false, reason: "invalid_delivery_id" };
  }
  const ref = db.ref(`delivery_requests/${rid}`);
  const now = nowMs();
  let abortReason = null;

  const tx = await ref.transaction((current) => {
    if (!current || typeof current !== "object") {
      abortReason = "delivery_missing";
      return;
    }
    const inProgress =
      Number(current[DELIVERY_FANOUT_AFTER_PAYMENT_IN_PROGRESS_AT_FIELD] ?? 0) || 0;
    const lease = Number(leaseAcquiredAt ?? 0) || 0;
    if (lease > 0 && inProgress !== lease) {
      abortReason = "lease_lost";
      return;
    }
    const next = { ...current, updated_at: now };
    delete next[DELIVERY_FANOUT_AFTER_PAYMENT_IN_PROGRESS_AT_FIELD];
    return next;
  });

  if (!tx.committed) {
    return { committed: false, reason: abortReason || "transaction_aborted" };
  }
  console.log(
    "DELIVERY_FANOUT_AFTER_PAYMENT_RELEASE",
    `deliveryId=${rid}`,
    `lease=${leaseAcquiredAt || 0}`,
  );
  return { committed: true };
}

/**
 * Verified-payment fan-out entry: lease, refresh search TTL, fan out, complete marker.
 * Idempotent across verifyFlutterwavePayment, webhook, admin approve, verifyPaymentInternal.
 */
async function fanOutDeliveryOffersAfterVerifiedPayment(db, deliveryId, row) {
  const acquire = await tryAcquireDeliveryVerifiedPaymentFanoutLease(db, deliveryId);
  if (!acquire.acquired) {
    return {
      ok: true,
      skipped: acquire.skipped === true,
      reason: acquire.reason || "not_acquired",
    };
  }
  const leaseAcquiredAt = acquire.leaseAcquiredAt;
  try {
    const mergedRow = {
      ...(row && typeof row === "object" ? row : {}),
      ...(acquire.row && typeof acquire.row === "object" ? acquire.row : {}),
    };
    const refreshed = await refreshDeliverySearchExpiryForVerifiedFanout(
      db,
      deliveryId,
      mergedRow,
    );
    await fanOutDeliveryOffersIfEligible(db, deliveryId, refreshed, { forceFanout: true });
    await markDeliveryVerifiedPaymentFanoutCompleted(db, deliveryId, leaseAcquiredAt);
    return { ok: true, skipped: false, reason: "fanout_done" };
  } catch (err) {
    await releaseDeliveryVerifiedPaymentFanoutLease(db, deliveryId, leaseAcquiredAt);
    throw err;
  }
}

/**
 * Mirror minimal ride-shaped fields so driver discovery UI can reuse pickup/status checks.
 */
function deliveryUiMirrorFields(deliveryState, driverId) {
  const s = normalizeDeliveryState(deliveryState);
  const d = normUid(driverId);
  const assigned = d || null;
  const assignedFields = {
    driver_id: assigned,
    matched_driver_id: assigned,
    accepted_driver_id: assigned,
    delivery_driver_id: assigned,
  };
  if (s === DELIVERY_STATE.searching) {
    return {
      trip_state: "searching",
      status: "searching",
      driver_id: "waiting",
      matched_driver_id: null,
      accepted_driver_id: null,
      delivery_driver_id: null,
    };
  }
  if (s === DELIVERY_STATE.driver_assigned) {
    return { trip_state: "accepted", status: "accepted", ...assignedFields };
  }
  if (s === DELIVERY_STATE.driver_arriving_pickup) {
    return { trip_state: "driver_arriving", status: "arriving", ...assignedFields };
  }
  if (
    s === DELIVERY_STATE.picked_up ||
    s === DELIVERY_STATE.on_delivery ||
    s === DELIVERY_STATE.arrived_dropoff
  ) {
    return { trip_state: "in_progress", status: "on_trip", ...assignedFields };
  }
  if (s === DELIVERY_STATE.completed) {
    return { trip_state: "completed", status: "completed", ...assignedFields };
  }
  if (s === DELIVERY_STATE.cancelled) {
    return { trip_state: "cancelled", status: "cancelled", ...assignedFields };
  }
  return {
    trip_state: "searching",
    status: "searching",
    driver_id: "waiting",
    matched_driver_id: null,
    accepted_driver_id: null,
    delivery_driver_id: null,
  };
}

async function assertCustomerDeliverySlot(db, customerId) {
  const r = normUid(customerId);
  if (!r) return { ok: true };
  const ptrSnap = await db.ref(`user_active_delivery/${r}`).get();
  if (!ptrSnap.exists()) return { ok: true };
  const ptr = ptrSnap.val() || {};
  const prevId = normUid(ptr.delivery_id ?? ptr.deliveryId);
  if (!prevId) {
    await db.ref(`user_active_delivery/${r}`).remove();
    return { ok: true };
  }
  const prevSnap = await db.ref(`delivery_requests/${prevId}`).get();
  const prev = prevSnap.val();
  if (!prev || typeof prev !== "object" || normUid(prev.customer_id) !== r) {
    await db.ref(`user_active_delivery/${r}`).remove();
    return { ok: true };
  }
  const ds = normalizeDeliveryState(prev.delivery_state);
  if (TERMINAL_DELIVERY.has(ds)) {
    await db.ref(`user_active_delivery/${r}`).remove();
    return { ok: true };
  }
  return { ok: false, reason: "customer_active_delivery", deliveryId: prevId };
}

async function clearDeliveryFanoutAndOffers(db, deliveryId, winnerDriverId = "") {
  const rid = normUid(deliveryId);
  if (!rid) return;
  const updates = {};
  const d0 = normUid(winnerDriverId);
  if (d0) {
    updates[`delivery_offer_queue/${d0}/${rid}`] = null;
  }
  const snap = await db.ref(`delivery_offer_fanout/${rid}`).get();
  const val = snap.val();
  if (val && typeof val === "object") {
    for (const driverId of Object.keys(val)) {
      const d = normUid(driverId);
      if (!d) continue;
      updates[`delivery_offer_queue/${d}/${rid}`] = null;
      updates[`delivery_offer_fanout/${rid}/${d}`] = null;
    }
  }
  if (Object.keys(updates).length) {
    await db.ref().update(updates);
  }
}

function buildDeliveryOfferPayload(deliveryId, customerId, market, row, now, expiresAt) {
  const mirror = deliveryUiMirrorFields(row.delivery_state, row.driver_id);
  const pickupObj = row.pickup && typeof row.pickup === "object" ? row.pickup : {};
  const dropoffObj = row.dropoff && typeof row.dropoff === "object" ? row.dropoff : {};
  const pickupAddr =
    typeof pickupObj.address === "string" && pickupObj.address.trim()
      ? pickupObj.address.trim()
      : "";
  const dropoffAddr =
    typeof dropoffObj.address === "string" && dropoffObj.address.trim()
      ? dropoffObj.address.trim()
      : "";
  return {
    __nexride_request_kind: "delivery",
    delivery_id: deliveryId,
    ride_id: deliveryId,
    rider_id: customerId,
    customer_id: customerId,
    service_type: "dispatch_delivery",
    request_kind: "delivery",
    market,
    market_pool: market,
    pickup: row.pickup,
    dropoff: row.dropoff,
    pickup_lat: Number(pickupObj.lat ?? pickupObj.latitude ?? 0) || null,
    pickup_lng: Number(pickupObj.lng ?? pickupObj.longitude ?? 0) || null,
    dropoff_lat: Number(dropoffObj.lat ?? dropoffObj.latitude ?? 0) || null,
    dropoff_lng: Number(dropoffObj.lng ?? dropoffObj.longitude ?? 0) || null,
    destination: row.dropoff,
    pickup_address: pickupAddr || null,
    dropoff_address: dropoffAddr || null,
    destination_address: dropoffAddr || null,
    fare: row.fare,
    total_ngn: row.total_ngn ?? row.fare,
    delivery_fee_ngn: row.base_fare_ngn ?? row.delivery_fee_ngn ?? row.fare,
    booking_fee_ngn: row.booking_fee_ngn ?? row.platform_fee_ngn ?? 0,
    currency: row.currency,
    distance_km: row.distance_km,
    eta_minutes: row.eta_minutes,
    payment_method: row.payment_method,
    payment_status: row.payment_status,
    package_description: row.package_description,
    food_order_summary: row.food_order_summary != null ? String(row.food_order_summary) : null,
    merchant_id: row.merchant_id != null ? normUid(row.merchant_id) : null,
    merchant_order_id: row.merchant_order_id != null ? normUid(row.merchant_order_id) : null,
    recipient_name: row.recipient_name,
    recipient_phone: row.recipient_phone,
    category: row.category,
    vehicle_requirement:
      row.vehicle_requirement ??
      row.dispatch_vehicle_type ??
      row.requested_vehicle_type ??
      row.vehicle_type ??
      null,
    dispatch_vehicle_type:
      row.dispatch_vehicle_type ??
      row.vehicle_requirement ??
      row.requested_vehicle_type ??
      null,
    trip_state: mirror.trip_state,
    status: "offered",
    driver_id: mirror.driver_id,
    matched_driver_id: mirror.matched_driver_id,
    delivery_state: row.delivery_state,
    created_at: row.created_at ?? now,
    request_status: "offered",
    expires_at: expiresAt,
    __nexride_from_offer_queue: true,
  };
}

function deliveryFanoutServiceAreaSkip(profile, deliveryRow) {
  const deliveryCity = trimStr(
    deliveryRow.resolved_service_city_id ?? deliveryRow.city ?? deliveryRow.market_pool ?? deliveryRow.market,
    64,
  ).toLowerCase();
  const driverCity = trimStr(
    profile.service_area_city_id ??
      profile.rollout_city_id ??
      profile.selected_service_area_id ??
      profile.dispatch_market_id ??
      profile.canonical_market_id ??
      profile.dispatch_market,
    64,
  ).toLowerCase();
  const serviceAreaMode =
    String(profile.driver_availability_mode ?? profile.availability_mode ?? "")
      .trim()
      .toLowerCase() === "service_area" ||
    Boolean(profile.selected_service_area_id || profile.service_area_city_id);
  if (serviceAreaMode && deliveryCity && driverCity && driverCity !== deliveryCity) {
    return {
      skip: true,
      reason: "service_area_mismatch",
      deliveryCity,
      driverCity,
    };
  }
  return { skip: false, reason: null, deliveryCity, driverCity };
}

const MARKET_DRIVER_QUERY_CAP = 400;
const ONLINE_DRIVER_FALLBACK_CAP = 200;

async function loadDeliveryFanoutSkipDriverIds(db, deliveryId, row) {
  const skip = new Set();
  const md =
    row?.match_debug && typeof row.match_debug === "object" ? row.match_debug : {};
  for (const id of md.exhausted_driver_ids || []) {
    const u = normUid(id);
    if (u) skip.add(u);
  }
  const rid = normUid(deliveryId);
  const now = nowMs();
  try {
    const fanSnap = await db.ref(`delivery_offer_fanout/${rid}`).get();
    const fan = fanSnap.val() && typeof fanSnap.val() === "object" ? fanSnap.val() : {};
    const purge = {};
    for (const id of Object.keys(fan)) {
      const u = normUid(id);
      if (!u) continue;
      const qSnap = await db.ref(`delivery_offer_queue/${u}/${rid}`).get();
      if (!qSnap.exists()) {
        purge[`delivery_offer_fanout/${rid}/${u}`] = null;
        continue;
      }
      const offer =
        qSnap.val() && typeof qSnap.val() === "object" ? qSnap.val() : {};
      const exp =
        Number(offer.expires_at ?? offer.request_expires_at ?? offer.lease_expires_at ?? 0) ||
        0;
      const expired = exp > 0 && now >= exp;
      if (expired) {
        purge[`delivery_offer_queue/${u}/${rid}`] = null;
        purge[`delivery_offer_fanout/${rid}/${u}`] = null;
        continue;
      }
      skip.add(u);
    }
    if (Object.keys(purge).length) {
      await db.ref().update(purge);
    }
  } catch (_) {}
  return skip;
}

async function loadDeliveryFanoutDrivers(db, market) {
  return ride.loadDriversForDispatchMarket(db, market);
}

const DISPATCH_DELIVERY_OFFER_SERVICES = new Set([
  "dispatch_delivery",
  "courier",
  "delivery",
  "merchant_delivery",
  "deliveries_mart",
]);

function profileDeliveryOfferServices(profile) {
  const out = [];
  const lists = [
    profile.active_services,
    profile.services,
    profile.service_types,
    profile.driver_service_types,
    profile.driverServiceTypes,
  ];
  for (const list of lists) {
    if (!Array.isArray(list)) continue;
    for (const item of list) {
      const key = String(item ?? "").trim().toLowerCase();
      if (key) out.push(key);
    }
  }
  const single = String(profile.service_type ?? profile.active_service_type ?? "")
    .trim()
    .toLowerCase();
  if (single) out.push(single);
  return out;
}

function driverCanReceiveDispatchDeliveryOffers(profile) {
  if (!profile || typeof profile !== "object") {
    return false;
  }
  const caps =
    profile.service_capabilities && typeof profile.service_capabilities === "object"
      ? profile.service_capabilities
      : profile.serviceCapabilities && typeof profile.serviceCapabilities === "object"
        ? profile.serviceCapabilities
        : null;
  if (caps?.dispatch_delivery === true || caps?.dispatchDelivery === true) {
    return true;
  }
  if (
    profile.accepts_dispatch === true ||
    profile.supports_delivery === true ||
    profile.acceptsDispatch === true ||
    profile.supportsDelivery === true
  ) {
    return true;
  }
  const services = profileDeliveryOfferServices(profile);
  if (services.some((s) => DISPATCH_DELIVERY_OFFER_SERVICES.has(s))) {
    return true;
  }
  const vehicleType = String(
    profile.vehicle_type ??
      profile.vehicleType ??
      profile.dispatch_vehicle_type ??
      profile.dispatchVehicleType ??
      "",
  )
    .trim()
    .toLowerCase();
  if (
    vehicleType === "bike" ||
    vehicleType === "motorcycle" ||
    vehicleType === "bicycle" ||
    vehicleType === "scooter"
  ) {
    return true;
  }
  const ownership = String(profile.ownership_mode ?? profile.ownershipMode ?? "")
    .trim()
    .toLowerCase();
  if (ownership === "business_managed") {
    const dvt = String(
      profile.dispatch_vehicle_type ?? profile.dispatchVehicleType ?? vehicleType,
    )
      .trim()
      .toLowerCase();
    if (dvt === "bike" || dvt === "van" || dvt === "car") {
      return true;
    }
  }
  if (
    (vehicleType === "car" || vehicleType === "van") &&
    (services.some((s) => s === "dispatch_delivery" || s === "dispatch_driver") ||
      profile.accepts_dispatch === true ||
      profile.supports_delivery === true)
  ) {
    return true;
  }
  if (services.some((s) => s === "dispatch_driver")) {
    return true;
  }
  return false;
}

function driverDispatchMarketForFanout(profile) {
  return ride.canonicalDispatchMarket(
    profile.dispatch_market_id ??
      profile.canonical_market_id ??
      profile.dispatch_market ??
      profile.market_pool ??
      profile.market ??
      "",
  );
}

async function fanOutDeliveryOffersIfEligible(db, deliveryId, row, fanoutOptions = {}) {
  const rid = normUid(deliveryId);
  const customerId = normUid(row.customer_id);
  const market = ride.canonicalDispatchMarket(
    row.dispatch_market_id ??
      row.resolved_dispatch_market_id ??
      row.market_pool ??
      row.market ??
      "",
  );
  if (!rid || !market || !customerId) {
    console.log("DELIVERY_FANOUT_ABORT", `deliveryId=${rid}`, "reason=bad_ids_or_market");
    return;
  }
  if (!deliveryOpensForFanout(row)) {
    console.log(
      "DELIVERY_FANOUT_ABORT",
      `deliveryId=${rid}`,
      `reason=${deliveryFanoutAbortReason(row)}`,
      `delivery_state=${String(row.delivery_state ?? "").trim()}`,
      `status=${String(row.status ?? "").trim()}`,
    );
    return;
  }
  if (!deliveryAllowsFanoutPayment(row)) {
    console.log(
      "DELIVERY_FANOUT_ABORT",
      `deliveryId=${rid}`,
      "reason=payment_not_allowed_for_fanout",
      `payment_status=${String(row.payment_status ?? "").trim()}`,
    );
    return;
  }
  const fanoutNow = nowMs();
  const md0 =
    row?.match_debug && typeof row.match_debug === "object" ? row.match_debug : {};
  const isInitialFanout =
    String(md0.matching_state ?? "").trim() === "pending_fanout" ||
    !Number(md0.last_fanout_at_ms ?? 0);
  if (!fanoutOptions.forceFanout && !isInitialFanout) {
    try {
      const { loadDispatchConfig } = require("./dispatch_engine/dispatch_config_engine");
      const dispatchCfg = await loadDispatchConfig(db);
      const lastFanout = Number(md0.last_fanout_at_ms ?? 0) || 0;
      if (lastFanout > 0 && fanoutNow - lastFanout < dispatchCfg.driver_offer_retry_ms) {
        console.log(
          "DELIVERY_FANOUT_THROTTLED",
          `deliveryId=${rid}`,
          `age_ms=${fanoutNow - lastFanout}`,
        );
        return;
      }
    } catch (_) {}
  }

  const serviceArea =
    String(
      row.resolved_service_city_id ?? row.service_city_id ?? row.rollout_city_id ?? "",
    ).trim() || "(none)";
  console.log(
    "DELIVERY_FANOUT_START",
    `deliveryId=${rid}`,
    `market=${market}`,
    `serviceArea=${serviceArea}`,
  );

  const gates = await loadDispatchGates(db);
  const pickup = row.pickup && typeof row.pickup === "object" ? row.pickup : {};
  const dropoff = row.dropoff && typeof row.dropoff === "object" ? row.dropoff : null;
  const now = fanoutNow;
  const expiresAt = now + DELIVERY_SEARCH_TTL_MS;
  let offersWritten = 0;
  let enqueueSkipped = 0;

  const exhaustedDriverIds = new Set(
    (Array.isArray(row.match_debug?.exhausted_driver_ids) ? row.match_debug.exhausted_driver_ids : [])
      .map((x) => normUid(x))
      .filter(Boolean),
  );
  const raw = await loadDeliveryFanoutDrivers(db, market);
  const scanCount = Object.keys(raw).length;
  console.log(
    "DELIVERY_CREATE_FANOUT_START",
    `deliveryId=${rid}`,
    `driverCount=${scanCount}`,
    `market=${market}`,
    `serviceArea=${serviceArea}`,
  );
  console.log("DELIVERY_DRIVER_SCAN_COUNT", `count=${scanCount}`, `market=${market}`);
  console.log("DELIVERY_DRIVER_POOL_READY", `deliveryId=${rid}`, `count=${scanCount}`, `market=${market}`);

  const skipIds = await loadDeliveryFanoutSkipDriverIds(db, rid, row);
  const { buildDriverFanoutFilterTrace } = require("./driver_dispatch_gates");
  for (const skippedId of skipIds) {
    enqueueSkipped += 1;
    console.log(
      "DELIVERY_OFFER_SKIPPED",
      `deliveryId=${rid}`,
      `driverId=${skippedId}`,
      `reason=prior_fanout_or_exhausted`,
    );
  }

  for (const [driverId, profile] of Object.entries(raw)) {
    const d = normUid(driverId);
    if (!d || !profile || typeof profile !== "object") continue;
    if (skipIds.has(d)) continue;
    if (exhaustedDriverIds.has(d)) {
      enqueueSkipped += 1;
      console.log(
        "DELIVERY_OFFER_SKIPPED",
        `deliveryId=${rid}`,
        `driverId=${d}`,
        `reason=driver_declined_exhausted`,
      );
      continue;
    }
    const mergedProfile = ride.mergeDriverPresenceForFanout(profile, null);
    const services = profileDeliveryOfferServices(mergedProfile);
    const canDelivery = driverCanReceiveDispatchDeliveryOffers(mergedProfile);
    if (!canDelivery) {
      enqueueSkipped += 1;
      console.log(
        "DELIVERY_CANDIDATE_REJECTED",
        `deliveryId=${rid}`,
        `driverId=${d}`,
        `reason=missing_delivery_service`,
      );
      continue;
    }
    const driverMarket = driverDispatchMarketForFanout(mergedProfile);
    if (driverMarket && driverMarket !== market) {
      enqueueSkipped += 1;
      console.log(
        "DELIVERY_CANDIDATE_REJECTED",
        `deliveryId=${rid}`,
        `driverId=${d}`,
        `reason=market_mismatch`,
      );
      continue;
    }
    const areaSkip = deliveryFanoutServiceAreaSkip(mergedProfile, row);
    if (areaSkip.skip) {
      enqueueSkipped += 1;
      console.log(
        "DELIVERY_CANDIDATE_REJECTED",
        `deliveryId=${rid}`,
        `driverId=${d}`,
        `reason=${areaSkip.reason || "service_area_mismatch"}`,
      );
      continue;
    }
    const busyGuard = await resolveDeliveryBusyGuardForDriver(db, d, rid, "delivery_fanout");
    const ridePayload = {
      ...row,
      service_type: "dispatch_delivery",
      request_kind: "delivery",
      market_pool: market,
      market,
      ride_id: rid,
    };
    const trace = buildDriverFanoutFilterTrace(
      d,
      mergedProfile,
      ridePayload,
      gates,
      now,
      {
        activeRideId: busyGuard.busy ? busyGuard.blockingTripId : null,
      },
    );
    console.log(
      "DELIVERY_CANDIDATE_EVALUATED",
      `deliveryId=${rid}`,
      `driverId=${d}`,
      `allowed=${trace.allowed}`,
      `reason=${trace.filtered_reason ?? "ok"}`,
    );
    if (!trace.allowed) {
      enqueueSkipped += 1;
      console.log(
        "DELIVERY_CANDIDATE_REJECTED",
        `deliveryId=${rid}`,
        `driverId=${d}`,
        `reason=${trace.filtered_reason ?? "filtered"}`,
      );
      continue;
    }
    const payload = buildDeliveryOfferPayload(rid, customerId, market, row, now, expiresAt);
    const qPath = `delivery_offer_queue/${d}/${rid}`;
    try {
      await db.ref().update({
        [`delivery_offer_fanout/${rid}/${d}`]: true,
        [qPath]: payload,
      });
      await sendPushToUser(db, d, {
        notification: {
          title: "New dispatch request",
          body: "A delivery request is available near you.",
        },
        data: {
          type: "driver_offer",
          deliveryId: rid,
          serviceType: "dispatch_delivery",
          market,
        },
      });
      console.log("DELIVERY_OFFER_ENQUEUED", `deliveryId=${rid}`, `driverId=${d}`, `path=${qPath}`);
      offersWritten += 1;
    } catch (e) {
      enqueueSkipped += 1;
      const msg = e && typeof e === "object" && "message" in e ? String(e.message) : String(e);
      console.log(
        "DELIVERY_OFFER_SKIPPED",
        `deliveryId=${rid}`,
        `driverId=${d}`,
        `reason=queue_write_failed:${msg}`,
      );
    }
  }

  const offerDeliveryStatus =
    offersWritten > 0 ? "offers_sent" : "no_eligible_drivers";
  const matchingState =
    offersWritten > 0 ? "offers_active" : scanCount === 0 ? "blocked" : "waiting_next_batch";
  await db.ref(`delivery_requests/${rid}/match_debug`).set({
    last_fanout_at_ms:
      offersWritten > 0 ? now : Number(md0.last_fanout_at_ms ?? 0) || null,
    last_zero_offer_fanout_at_ms:
      offersWritten === 0 ? now : Number(md0.last_zero_offer_fanout_at_ms ?? 0) || null,
    offers_written: offersWritten,
    offer_delivery_status: offerDeliveryStatus,
    matching_state: matchingState,
    payment_status: String(row.payment_status ?? "").trim().toLowerCase() || null,
    dispatch_market_id: market,
    ride_service_city_id: serviceArea !== "(none)" ? serviceArea : null,
    drivers_in_market_query: scanCount,
    checked_at: now,
    updated_at: now,
  });

  const deliveryPatch = { updated_at: now, matching_state: matchingState };
  if (deliveryOpensForFanout(row) && deliveryAllowsFanoutPayment(row)) {
    const mirror = deliveryUiMirrorFields(DELIVERY_STATE.searching, "");
    deliveryPatch.delivery_state = DELIVERY_STATE.searching;
    deliveryPatch.trip_state = mirror.trip_state;
    deliveryPatch.status = mirror.status;
    deliveryPatch.expires_at = expiresAt;
    deliveryPatch.search_timeout_at = expiresAt;
    deliveryPatch.request_expires_at = expiresAt;
  }
  await db.ref(`delivery_requests/${rid}`).update(deliveryPatch);

  console.log(
    "DELIVERY_CREATE_FANOUT_COMPLETE",
    `deliveryId=${rid}`,
    `enqueuedCount=${offersWritten}`,
    `skippedCount=${enqueueSkipped}`,
  );
  console.log(
    "DELIVERY_FANOUT_COMPLETE",
    `deliveryId=${rid}`,
    `offersWritten=${offersWritten}`,
    `market=${market}`,
  );
  console.log("DELIVERY_FANOUT_DONE", `deliveryId=${rid}`, `offersWritten=${offersWritten}`);
}

function isPlaceholderDriverId(v) {
  if (v == null || v === undefined) return true;
  const s = String(v).trim().toLowerCase();
  return (
    s.length === 0 ||
    s === "waiting" ||
    s === "pending" ||
    s === "null" ||
    s === "undefined" ||
    s === "none"
  );
}

/**
 * Canonical assigned driver on delivery_requests (parity with ride accept).
 */
function canonicalAssignedDeliveryDriverId(row) {
  if (!row || typeof row !== "object") {
    return "";
  }
  const customer = normUid(row.customer_id ?? row.customerId ?? row.rider_id);
  const fields = [
    "matched_driver_id",
    "matchedDriverId",
    "assigned_driver_id",
    "assignedDriverId",
    "accepted_driver_id",
    "acceptedDriverId",
    "delivery_driver_id",
    "deliveryDriverId",
    "driver_id",
    "driverId",
  ];
  for (const key of fields) {
    const raw = row[key];
    if (isPlaceholderDriverId(raw)) {
      continue;
    }
    const d = normUid(raw);
    if (!d) {
      continue;
    }
    if (customer && d === customer) {
      continue;
    }
    return d;
  }
  return "";
}

/** @deprecated use canonicalAssignedDeliveryDriverId */
function canonicalAssignedDriver(row) {
  return canonicalAssignedDeliveryDriverId(row);
}

function deliveryPoolOpenForAccept(row) {
  if (!row || typeof row !== "object") {
    return false;
  }
  const ds = normalizeDeliveryState(row.delivery_state);
  if (ds !== DELIVERY_STATE.searching) {
    return false;
  }
  return !canonicalAssignedDeliveryDriverId(row);
}

function deliveryAssignedOrTerminal(row) {
  if (!row || typeof row !== "object") {
    return false;
  }
  const ds = normalizeDeliveryState(row.delivery_state);
  if (TERMINAL_DELIVERY.has(ds)) {
    return true;
  }
  return Boolean(canonicalAssignedDeliveryDriverId(row));
}

function deliveryUnpaidPaymentPastDeadline(row, now = nowMs()) {
  if (!row || typeof row !== "object" || deliveryHasVerifiedOnlinePayment(row)) {
    return false;
  }
  if (normalizeDeliveryState(row.delivery_state) !== DELIVERY_STATE.driver_assigned) {
    return false;
  }
  const deadline = Number(row.payment_deadline_at ?? row.paymentDeadlineAt ?? 0) || 0;
  return deadline > 0 && now >= deadline;
}

function buildDeliveryAcceptAssignmentPatch(driverId, now, opts = {}) {
  const d = normUid(driverId);
  const mirror = deliveryUiMirrorFields(DELIVERY_STATE.driver_assigned, d);
  const patch = {
    delivery_state: DELIVERY_STATE.driver_assigned,
    delivery_driver_id: d,
    driver_id: d,
    driverId: d,
    matched_driver_id: d,
    matchedDriverId: d,
    assigned_driver_id: d,
    assignedDriverId: d,
    accepted_driver_id: d,
    acceptedDriverId: d,
    accepted_by: d,
    trip_state: mirror.trip_state,
    status: mirror.status,
    accepted_at: now,
    accepted_at_ms: now,
    match_completed_at: now,
    match_completed_at_ms: now,
    updated_at: now,
    matching_state: "matched",
    match_lock: {
      accepted_by: d,
      accepted_at_ms: now,
    },
  };
  if (opts.paymentPending) {
    patch.payment_deadline_at = now + DELIVERY_UNPAID_PAYMENT_TTL_MS;
  }
  return patch;
}

async function acquireDeliveryMatchLockOrReject(deliveryRef, deliveryId, driverId, now) {
  const d = normUid(driverId);
  const rid = normUid(deliveryId);
  if (!rid || !d) {
    return { ok: false, reason: "invalid_input", holder: "" };
  }
  const lockRef = deliveryRef.child("match_lock");
  let otherHolder = "";
  const tx = await lockRef.transaction((cur) => {
    otherHolder = "";
    const existing =
      cur && typeof cur === "object"
        ? normUid(cur.accepted_by ?? cur.acceptedBy)
        : normUid(cur);
    if (existing && existing !== d) {
      const at =
        cur && typeof cur === "object"
          ? Number(cur.accepted_at_ms ?? cur.acceptedAtMs ?? 0) || 0
          : 0;
      const age = at > 0 ? now - at : DELIVERY_MATCH_LOCK_MAX_AGE_MS + 1;
      if (age < DELIVERY_MATCH_LOCK_MAX_AGE_MS) {
        otherHolder = existing;
        return;
      }
    }
    return { accepted_by: d, accepted_at_ms: now };
  });
  if (!tx.committed) {
    return {
      ok: false,
      reason: otherHolder ? "already_taken" : "lock_failed",
      holder: otherHolder,
    };
  }
  return { ok: true, holder: d };
}

function evaluateDeliveryAcceptTransactionDecision(current, driverId, { now = nowMs() } = {}) {
  const d = normUid(driverId);
  if (!current || typeof current !== "object") {
    return { action: "abort", reason: "delivery_missing" };
  }
  const assigned = canonicalAssignedDeliveryDriverId(current);
  if (assigned && assigned === d) {
    return { action: "noop", reason: "already_accepted" };
  }
  if (assigned && assigned !== d) {
    return { action: "abort", reason: "already_taken" };
  }
  const ds = normalizeDeliveryState(current.delivery_state);
  if (ds !== DELIVERY_STATE.searching) {
    return { action: "abort", reason: "status_not_open" };
  }
  const exp = Number(current.expires_at ?? current.request_expires_at ?? 0) || 0;
  if (exp > 0 && now > exp + 30_000) {
    return { action: "abort", reason: "offer_expired" };
  }
  const paymentPending = !deliveryHasVerifiedOnlinePayment(current);
  return {
    action: "commit",
    patch: buildDeliveryAcceptAssignmentPatch(d, now, {
      useServerTimestamp: false,
      paymentPending,
    }),
  };
}

async function attemptGuardedDeliveryDirectWrite(deliveryRef, deliveryId, driverId, now) {
  const patch = buildDeliveryAcceptAssignmentPatch(driverId, now);
  await deliveryRef.update(patch);
  const verify = (await deliveryRef.get()).val();
  if (canonicalAssignedDeliveryDriverId(verify || {}) !== normUid(driverId)) {
    return { ok: false, reason: "direct_write_verify_failed" };
  }
  return { ok: true, row: verify };
}

async function setActiveDeliveryPointers(db, deliveryId, customerId, driverId, row) {
  const rid = normUid(deliveryId);
  const c = normUid(customerId);
  const d = normUid(driverId);
  const merchantId = normUid(row.merchant_id ?? row.merchantId);
  const now = nowMs();
  const ds = normalizeDeliveryState(row.delivery_state);
  if (TERMINAL_DELIVERY.has(ds)) {
    return clearDeliveryActivePointers(db, {
      deliveryId: rid,
      customerId: c,
      driverId: d,
      merchantId,
      source: "setActiveDeliveryPointers_terminal",
    });
  }
  if (!d) {
    const u = {};
    if (rid) {
      u[`active_deliveries/${rid}`] = null;
    }
    if (c) {
      u[`user_active_delivery/${c}`] = null;
      u[`customer_active_delivery/${c}`] = null;
    }
    if (Object.keys(u).length) {
      await db.ref().update(u);
    }
    return { cleared: Object.keys(u).length };
  }
  const summary = {
    delivery_id: rid,
    customer_id: c,
    driver_id: d,
    merchant_id: merchantId || null,
    market_pool: row.market_pool ?? row.market,
    delivery_state: ds || DELIVERY_STATE.driver_assigned,
    fare: Number(row.fare ?? 0) || 0,
    currency: String(row.currency ?? "NGN").trim().toUpperCase() || "NGN",
    pickup_summary:
      row.pickup && typeof row.pickup.address === "string" ? row.pickup.address : "",
    dropoff_summary:
      row.dropoff && typeof row.dropoff.address === "string" ? row.dropoff.address : "",
    payment_status: String(row.payment_status ?? "").trim().toLowerCase(),
    updated_at: now,
  };
  const u = {};
  u[`active_deliveries/${rid}`] = summary;
  u[`user_active_delivery/${c}`] = {
    delivery_id: rid,
    phase: TERMINAL_DELIVERY.has(ds) ? "idle" : "active",
    updated_at: now,
  };
  u[`customer_active_delivery/${c}`] = {
    delivery_id: rid,
    phase: TERMINAL_DELIVERY.has(ds) ? "idle" : "active",
    updated_at: now,
  };
  u[`driver_active_delivery/${d}`] = { delivery_id: rid, updated_at: now };
  u[`drivers/${d}/active_delivery_id`] = rid;
  u[`drivers/${d}/updated_at`] = now;
  if (merchantId) {
    u[`merchant_active_delivery/${merchantId}`] = { delivery_id: rid, updated_at: now };
  }
  await db.ref().update(u);
  if (d) {
    console.log(
      "DELIVERY_LOCK_CREATED",
      `driverId=${d}`,
      `deliveryId=${rid}`,
      `customerId=${c}`,
    );
  }
}

/**
 * Clear all server-owned delivery active pointers for terminal/cancel/expire paths.
 * @returns {Promise<{ cleared: number }>}
 */
async function clearDeliveryActivePointers(
  db,
  { deliveryId, customerId, driverId, merchantId, source = "delivery_cancel" } = {},
) {
  const rid = normUid(deliveryId);
  const c = normUid(customerId);
  const d = normUid(driverId);
  const m = normUid(merchantId);
  const now = nowMs();
  const updates = {};
  if (rid) {
    updates[`active_deliveries/${rid}`] = null;
  }
  if (c) {
    updates[`user_active_delivery/${c}`] = null;
    updates[`customer_active_delivery/${c}`] = null;
  }
  if (d) {
    updates[`driver_active_delivery/${d}`] = null;
    updates[`drivers/${d}/active_delivery_id`] = null;
    updates[`drivers/${d}/updated_at`] = now;
    updates[`delivery_offer_queue/${d}/${rid}`] = null;
    updates[`delivery_offer_fanout/${rid}/${d}`] = null;
  }
  if (m) {
    updates[`merchant_active_delivery/${m}`] = null;
  }
  if (rid) {
    try {
      const fanoutSnap = await db.ref(`delivery_offer_fanout/${rid}`).get();
      const fanout = fanoutSnap.val();
      if (fanout && typeof fanout === "object") {
        for (const otherDriverId of Object.keys(fanout)) {
          const od = normUid(otherDriverId);
          if (!od) continue;
          updates[`delivery_offer_queue/${od}/${rid}`] = null;
          updates[`delivery_offer_fanout/${rid}/${od}`] = null;
        }
      }
    } catch (_) {
      /* best-effort fanout cleanup */
    }
  }
  if (Object.keys(updates).length === 0) {
    return { cleared: 0 };
  }
  await db.ref().update(updates);
  if (c) {
    const sourceKey = String(source || "delivery_cancel").trim().toLowerCase();
    const isCancelSource =
      sourceKey.includes("cancel") ||
      sourceKey === "delivery_expired" ||
      sourceKey === "canceldeliveryrequest";
    if (isCancelSource) {
      console.log(
        "RIDER_READY_FOR_DELIVERY_AFTER_CANCEL",
        `customerId=${c}`,
        `deliveryId=${rid || "unknown"}`,
        `source=${source}`,
      );
    }
  }
  if (d) {
    const sourceKey = String(source || "delivery_cancel").trim().toLowerCase();
    const isCancelSource =
      sourceKey.includes("cancel") ||
      sourceKey === "delivery_expired" ||
      sourceKey === "canceldeliveryrequest";
    const isCompleteSource = sourceKey.includes("complete");
    console.log(
      "DELIVERY_LOCK_CLEARED",
      `driverId=${d}`,
      `deliveryId=${rid || "unknown"}`,
      `source=${source}`,
    );
    if (isCancelSource) {
      console.log(
        "DELIVERY_CANCEL_RELEASE_DRIVER",
        `deliveryId=${rid || "unknown"}`,
        `driverId=${d}`,
        `source=${source}`,
      );
      console.log(
        "DRIVER_READY_FOR_DELIVERY_AFTER_CANCEL",
        `driverId=${d}`,
        `deliveryId=${rid || "unknown"}`,
      );
    } else if (isCompleteSource) {
      console.log(
        "DRIVER_READY_FOR_RIDE_AFTER_DELIVERY",
        `driverId=${d}`,
        `deliveryId=${rid || "unknown"}`,
      );
    }
    console.log("DRIVER_DELIVERY_LOCK_CLEARED", `driverId=${d}`, `deliveryId=${rid || "unknown"}`);
    console.log("DRIVER_RIDE_SOCKET_UNTOUCHED", `driverId=${d}`);
    console.log(
      "ACTIVE_POINTERS_CLEARED",
      `deliveryId=${rid || "none"}`,
      `driverId=${d}`,
      `customerId=${c || "none"}`,
      "paths=driver_active_delivery,active_delivery_id,active_deliveries",
    );
  }
  return { cleared: Object.keys(updates).length };
}

/**
 * Remove expired or terminal delivery rows under delivery_offer_queue/{driverId}.
 * @returns {Promise<{ removed: number }>}
 */
async function purgeExpiredDeliveryOfferQueueEntries(db, driverId, now = Date.now()) {
  const d = normUid(driverId);
  if (!d) return { removed: 0 };

  const snap = await db.ref(`delivery_offer_queue/${d}`).get();
  const queue = snap.exists() && typeof snap.val() === "object" ? snap.val() : {};
  const updates = {};
  let removed = 0;

  for (const [deliveryId, offer] of Object.entries(queue)) {
    const did = normUid(deliveryId);
    if (!did) continue;
    const exp =
      Number(
        (offer && typeof offer === "object"
          ? offer.expires_at ?? offer.request_expires_at ?? offer.lease_expires_at
          : 0) || 0,
      ) || 0;
    let shouldRemove = exp > 0 && now >= exp;
    if (!shouldRemove) {
      try {
        const delSnap = await db.ref(`delivery_requests/${did}`).get();
        const delRow =
          delSnap.exists() && typeof delSnap.val() === "object" ? delSnap.val() : null;
        const ds = normalizeDeliveryState(delRow?.delivery_state);
        const delExpires =
          Number(delRow?.expires_at ?? delRow?.request_expires_at ?? 0) || 0;
        const delExpired = delExpires > 0 && now >= delExpires;
        shouldRemove =
          !delRow ||
          TERMINAL_DELIVERY.has(ds) ||
          (ds === DELIVERY_STATE.searching && delExpired);
      } catch (_) {}
    }
    if (shouldRemove) {
      updates[`delivery_offer_queue/${d}/${did}`] = null;
      updates[`delivery_offer_fanout/${did}/${d}`] = null;
      removed += 1;
    }
  }

  if (Object.keys(updates).length) {
    await db.ref().update(updates);
  }
  return { removed };
}

/**
 * Event-driven refanout: offer open deliveries in the driver's market after terminal release.
 */
async function refanoutSearchingDeliveriesForReleasedDriver(
  db,
  driverId,
  excludeDeliveryId,
  reason,
) {
  const d = normUid(driverId);
  const exclude = normUid(excludeDeliveryId);
  if (!d) return { refanout: 0, reason: "invalid_driver" };

  const { isDriverExplicitlyOffline } = require("./driver_dispatch_gates");
  const drvSnap = await db.ref(`drivers/${d}`).get();
  const prof =
    drvSnap.exists() && typeof drvSnap.val() === "object" ? drvSnap.val() : {};
  if (isDriverExplicitlyOffline(prof)) {
    return { refanout: 0, reason: "driver_offline" };
  }
  const market = ride.canonicalDispatchMarket(
    prof.dispatch_market ??
      prof.market ??
      prof.dispatch_market_id ??
      prof.canonical_market_id ??
      "",
  );
  if (!market) {
    return { refanout: 0, reason: "no_market" };
  }

  let refanout = 0;
  const maxDeliveries = 5;
  try {
    const snap = await db
      .ref("delivery_requests")
      .orderByChild("market_pool")
      .equalTo(market)
      .limitToFirst(24)
      .get();
    const rows = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
    for (const [deliveryId, row] of Object.entries(rows)) {
      if (refanout >= maxDeliveries) break;
      const did = normUid(deliveryId);
      if (!did || did === exclude) continue;
      if (!row || typeof row !== "object") continue;
      if (!deliveryOpensForFanout(row) || !deliveryAllowsFanoutPayment(row)) continue;
      if (canonicalAssignedDeliveryDriverId(row)) continue;
      await fanOutDeliveryOffersIfEligible(db, did, row, { forceFanout: true });
      refanout += 1;
    }
  } catch (scanErr) {
    console.log(
      "DELIVERY_RELEASE_REFANOUT_SCAN_FAIL",
      `driverId=${d}`,
      String(scanErr?.message || scanErr),
    );
  }
  console.log(
    "DELIVERY_RELEASE_REFANOUT",
    JSON.stringify({
      driverId: d,
      refanout,
      reason,
      excludeDeliveryId: exclude || null,
      market,
    }),
  );
  return { refanout, market };
}

/**
 * After delivery terminal state: clear delivery pointers and restore ride/dispatch eligibility.
 */
async function finalizeDriverEligibilityAfterTerminalDelivery(
  db,
  deliveryId,
  { customerId, driverId, merchantId, source = "delivery_terminal" } = {},
) {
  const rid = normUid(deliveryId);
  const d = normUid(driverId);
  const c = normUid(customerId);
  const m = normUid(merchantId);
  const sourceKey = String(source || "delivery_terminal").trim() || "delivery_terminal";

  await clearDeliveryActivePointers(db, {
    deliveryId: rid,
    customerId: c,
    driverId: d,
    merchantId: m,
    source: sourceKey,
  });

  if (!d) {
    return { ok: true, eligible: false, reason: "no_assigned_driver" };
  }

  try {
    const { releaseAssignmentLocks } = require("./dispatch_engine/dispatch_assignment_lock_engine");
    await releaseAssignmentLocks(db, rid, d);
    console.log(
      "ASSIGNMENT_LOCK_RELEASED",
      `deliveryId=${rid || "none"}`,
      `driverId=${d}`,
      `source=${sourceKey}`,
    );
  } catch (lockErr) {
    console.log(
      "DELIVERY_TERMINAL_LOCK_RELEASE_FAIL",
      `deliveryId=${rid || "none"}`,
      `driverId=${d}`,
      lockErr?.message ?? lockErr,
    );
  }

  try {
    const elig = await ride.restoreDriverMatchingEligibilityAfterTripEnd(db, d, {
      source: sourceKey,
      deliveryId: rid,
    });
    try {
      await purgeExpiredDeliveryOfferQueueEntries(db, d);
    } catch (purgeErr) {
      console.log(
        "DELIVERY_OFFER_QUEUE_PURGE_FAIL",
        `driverId=${d}`,
        String(purgeErr?.message || purgeErr),
      );
    }
    if (elig?.eligible) {
      console.log(
        "DELIVERY_READY_FOR_NEXT_OFFER",
        `driverId=${d}`,
        `deliveryId=${rid || "none"}`,
        `source=${sourceKey}`,
      );
      try {
        await refanoutSearchingDeliveriesForReleasedDriver(db, d, rid, sourceKey);
      } catch (refanoutErr) {
        console.log(
          "DELIVERY_TERMINAL_REFANOUT_FAIL",
          `driverId=${d}`,
          `deliveryId=${rid || "none"}`,
          String(refanoutErr?.message || refanoutErr),
        );
      }
    }
    return elig;
  } catch (eligErr) {
    console.log(
      "POST_DELIVERY_ELIGIBILITY_RESTORE_FAIL",
      `deliveryId=${rid || "none"}`,
      `driverId=${d}`,
      `source=${sourceKey}`,
      eligErr?.message ?? eligErr,
    );
    return { ok: false, reason: "eligibility_restore_failed", eligible: false };
  }
}

/**
 * Shared post-terminal commit for delivery cancel, complete, and expire paths.
 */
async function applyDeliveryTerminalPostCommit(
  db,
  deliveryId,
  row,
  {
    customerId,
    driverId,
    merchantId,
    source = "delivery_terminal",
    terminalState = "",
    clearFanout = false,
    excludeDriverFromFanout = "",
  } = {},
) {
  const rid = normUid(deliveryId);
  const d =
    normUid(driverId) || canonicalAssignedDeliveryDriverId(row && typeof row === "object" ? row : {}) || "";
  const c = normUid(customerId || row?.customer_id);
  const m = normUid(merchantId || row?.merchant_id || row?.merchantId);
  const sourceKey = String(source || "delivery_terminal").trim() || "delivery_terminal";
  const terminal = String(terminalState || row?.delivery_state || "")
    .trim()
    .toLowerCase();

  if (clearFanout) {
    await clearDeliveryFanoutAndOffers(db, rid, excludeDriverFromFanout || "");
  }

  if (d) {
    if (terminal === DELIVERY_STATE.cancelled) {
      console.log(
        "DELIVERY_CANCELLED",
        `deliveryId=${rid}`,
        `driverId=${d}`,
        `cancel_reason=${String(row?.cancel_reason ?? "none")}`,
      );
    } else if (
      terminal === DELIVERY_STATE.completed &&
      sourceKey !== "delivery_completed"
    ) {
      console.log("DELIVERY_COMPLETE", `deliveryId=${rid}`, `driverId=${d}`);
    }
  }

  return finalizeDriverEligibilityAfterTerminalDelivery(db, rid, {
    customerId: c,
    driverId: d,
    merchantId: m,
    source: sourceKey,
  });
}

/** Idempotent repair when accept succeeded but pointers lagged. */
async function repairDeliveryActivePointers(db, deliveryId) {
  const rid = normUid(deliveryId);
  if (!rid) {
    return { ok: false, reason: "invalid_delivery_id" };
  }
  const snap = await db.ref(`delivery_requests/${rid}`).get();
  if (!snap.exists()) {
    return { ok: false, reason: "delivery_missing" };
  }
  const row = snap.val() || {};
  const driverId = canonicalAssignedDeliveryDriverId(row);
  const customerId = normUid(row.customer_id);
  if (!driverId || !customerId) {
    return { ok: false, reason: "not_assigned" };
  }
  const ds = normalizeDeliveryState(row.delivery_state);
  if (TERMINAL_DELIVERY.has(ds)) {
    await clearDeliveryActivePointers(db, {
      deliveryId: rid,
      customerId,
      driverId,
      merchantId: normUid(row.merchant_id ?? row.merchantId),
      source: "repairDeliveryActivePointers_terminal",
    });
    return { ok: true, reason: "cleared_terminal" };
  }
  await setActiveDeliveryPointers(db, rid, customerId, driverId, row);
  return { ok: true, reason: "repaired" };
}

/**
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} db
 */
async function createDeliveryRequest(data, context, db) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const customerId = normUid(context.auth.uid);

  const userLifecycle = require("./user_account_lifecycle");
  const activeGate = require("./active_service_gate");
  const serviceGate = await activeGate.assertActiveRequestServiceEnabled(db, "dispatch_delivery");
  if (!serviceGate.ok) {
    console.log("DELIVERY_CREATE_FAIL", customerId, serviceGate.reason || "service_disabled");
    return {
      success: false,
      reason: serviceGate.reason || "service_disabled",
      service_type: serviceGate.service_type,
      message: serviceGate.message,
    };
  }
  const accountGate = await userLifecycle.assertUserCanOperate(db, customerId, "rider");
  if (!accountGate.ok) {
    console.log("DELIVERY_CREATE_FAIL", customerId, accountGate.reason || "account_blocked");
    return { success: false, reason: accountGate.reason || "account_blocked" };
  }

  const bodyCustomer = normUid(data?.customer_id ?? data?.customerId ?? data?.rider_id);
  if (bodyCustomer && bodyCustomer !== customerId) {
    return { success: false, reason: "customer_mismatch" };
  }

  const riderGates = await ride.loadRiderCreateGates(db);
  if (!(await ride.riderProfileRequirementOk(db, customerId, riderGates, context.auth))) {
    return { success: false, reason: "user_profile_required" };
  }

  const identityGate =
    await riderFirestoreIdentity.evaluateRiderFirestoreIdentityForBooking(admin.firestore(), customerId);
  if (!identityGate.ok) {
    console.log("DELIVERY_CREATE_FAIL", customerId, identityGate.reason || "identity_denied");
    return { success: false, reason: identityGate.reason || "identity_denied" };
  }

  const slot = await assertCustomerDeliverySlot(db, customerId);
  if (!slot.ok) {
    return { success: false, reason: slot.reason || "customer_active_delivery", deliveryId: slot.deliveryId };
  }

  const marketRaw = data?.market ?? data?.city ?? "";
  const market = ride.canonicalDispatchMarket(marketRaw);
  if (!market) {
    return { success: false, reason: "invalid_market" };
  }

  const pickup = data?.pickup;
  const dropoff = data?.dropoff;
  if (!pickup || typeof pickup !== "object" || !dropoff || typeof dropoff !== "object") {
    return { success: false, reason: "invalid_pickup_or_dropoff" };
  }

  const pCoord = coordsFromPickup(pickup);
  const dCoord = coordsFromPickup(dropoff);
  if (riderGates.require_ng_pickup && !coordsInNgBox(pCoord.lat, pCoord.lng)) {
    return { success: false, reason: "pickup_location_out_of_region" };
  }
  if (riderGates.require_ng_pickup && !coordsInNgBox(dCoord.lat, dCoord.lng)) {
    return { success: false, reason: "dropoff_location_out_of_region" };
  }

  const rolloutGate = await deliveryRegions.assertRolloutWithHints(
    admin.firestore(),
    market,
    pCoord.lat,
    pCoord.lng,
    "package",
    {
      region_id: data?.service_region_id ?? data?.rollout_region_id,
      city_id: data?.service_city_id ?? data?.rollout_city_id,
    },
  );
  if (!rolloutGate.ok) {
    return {
      success: false,
      reason: rolloutGate.reason || "service_area_unsupported",
      message:
        rolloutGate.message || "NexRide is not available in your area yet.",
    };
  }

  const pkg = String(data?.package_description ?? data?.packageDescription ?? "").trim();
  if (pkg.length < 3) {
    return { success: false, reason: "package_description_required" };
  }
  if (pkg.length > 2000) {
    return { success: false, reason: "package_description_too_long" };
  }

  const recipientName = String(data?.recipient_name ?? data?.recipientName ?? "").trim();
  if (recipientName.length > 0 && recipientName.length < 2) {
    return { success: false, reason: "recipient_name_invalid" };
  }
  const recipientPhone = String(data?.recipient_phone ?? data?.recipientPhone ?? "").trim();
  if (
    recipientPhone.length > 0 &&
    (recipientPhone.length < 8 || recipientPhone.length > 20)
  ) {
    return { success: false, reason: "recipient_phone_invalid" };
  }

  const category = String(data?.category ?? "parcel")
    .trim()
    .toLowerCase();
  if (!DELIVERY_CATEGORIES.has(category)) {
    return { success: false, reason: "invalid_category" };
  }

  const fare = Number(data?.fare ?? 0);
  const { validateAndFreezeEntityPricing } = require("./pricing_quote_flow");
  const { readCustomerOutstandingDeliveryWaitFee } = require("./delivery_wait_fee");
  const carriedForwardWaitFee = await readCustomerOutstandingDeliveryWaitFee(db, customerId);
  const tripFareForPricing = fare + (carriedForwardWaitFee > 0 ? carriedForwardWaitFee : 0);

  const pricingValidation = await validateAndFreezeEntityPricing(db, {
    flow: "dispatch_request",
    market: String(data?.market ?? data?.city ?? "lagos").trim(),
    fare: tripFareForPricing,
    trip_fare_ngn: tripFareForPricing,
    distance_km: Number(data?.distance_km ?? data?.distanceKm ?? 0) || 0,
    eta_min: Number(data?.eta_min ?? data?.etaMin ?? data?.eta_minutes ?? 0) || 0,
    total_ngn: data?.total_ngn ?? data?.totalNgn,
    discount_id: data?.discount_id ?? data?.discountId,
    discount_applied_ngn: data?.discount_applied_ngn ?? data?.discountAppliedNgn,
    rider_id: customerId,
  });
  if (!pricingValidation.ok) {
    const comparison = pricingValidation.pricing_comparison;
    console.warn(
      "[DISPATCH_CREATE_PRICING_MISMATCH]",
      JSON.stringify({
        reason: pricingValidation.reason,
        reason_code: pricingValidation.reason_code,
        market: String(data?.market ?? data?.city ?? "").trim() || null,
        client: comparison?.client ?? {
          trip_fare_ngn: tripFareForPricing,
          delivery_fee_ngn: Number(data?.delivery_fee_ngn ?? data?.deliveryFeeNgn ?? fare) || 0,
          booking_fee_ngn:
            Number(
              data?.booking_fee_ngn ??
                data?.bookingFeeNgn ??
                data?.platform_fee_ngn ??
                data?.platformFeeNgn ??
                0,
            ) || 0,
          total_ngn: Number(data?.total_ngn ?? data?.totalNgn ?? 0) || 0,
        },
        server: comparison?.server ?? {
          trip_fare_ngn: pricingValidation.expected_trip_fare_ngn ?? null,
          total_ngn: pricingValidation.expected_total_ngn ?? null,
          fee_breakdown: pricingValidation.fee_breakdown ?? null,
        },
      }),
    );
    return {
      success: false,
      reason: pricingValidation.reason,
      reason_code: pricingValidation.reason_code,
      message: pricingValidation.message,
      retryable: pricingValidation.retryable,
      expected_trip_fare_ngn: pricingValidation.expected_trip_fare_ngn,
      expected_total_ngn: pricingValidation.expected_total_ngn,
    };
  }
  const pricing = pricingValidation.pricing;
  const pricingSnapshot = pricingValidation.pricing_snapshot;
  if (tripFareForPricing > riderGates.max_fare_ngn) {
    return { success: false, reason: "fare_above_limit" };
  }

  const currency = String(data?.currency ?? "NGN").trim().toUpperCase() || "NGN";
  const paymentMethod = String(data?.payment_method ?? data?.paymentMethod ?? "flutterwave")
    .trim()
    .toLowerCase();
  const paymentNormalized = paymentMethod.replace(/[\s-]+/g, "_");
  if (!PAYMENT_METHODS_ALLOWED.has(paymentNormalized)) {
    return { success: false, reason: "unsupported_payment_method" };
  }
  const paymentStatus = "pending";

  const distanceKm = Number(data?.distance_km ?? data?.distanceKm ?? 0) || 0;
  const etaMin = Number(data?.eta_min ?? data?.etaMin ?? data?.eta_minutes ?? 0) || 0;
  if (!Number.isFinite(distanceKm) || distanceKm < 0 || distanceKm > 3500) {
    return { success: false, reason: "invalid_distance" };
  }
  if (!Number.isFinite(etaMin) || etaMin < 0 || etaMin > 36 * 60) {
    return { success: false, reason: "invalid_eta" };
  }

  const expiresAt = nowMs() + DELIVERY_SEARCH_TTL_MS;
  const delRef = db.ref("delivery_requests").push();
  const deliveryId = normUid(delRef.key);
  if (!deliveryId) {
    return { success: false, reason: "delivery_id_alloc_failed" };
  }

  const ts = nowMs();
  const resolvedMarket = ride.canonicalDispatchMarket(rolloutGate.dispatch_market_id || market);
  const mirror = deliveryUiMirrorFields(DELIVERY_STATE.searching, "");
  const row = {
    delivery_id: deliveryId,
    customer_id: customerId,
    rider_id: customerId,
    service_type: "dispatch_delivery",
    market: resolvedMarket,
    market_pool: resolvedMarket,
    dispatch_market_id: resolvedMarket,
    delivery_state: DELIVERY_STATE.searching,
    trip_state: mirror.trip_state,
    status: mirror.status,
    driver_id: mirror.driver_id,
    matched_driver_id: null,
    pickup,
    dropoff,
    package_description: pkg,
    recipient_name: recipientName,
    recipient_phone: recipientPhone,
    category,
    fare: tripFareForPricing,
    base_fare_ngn: fare,
    carried_forward_wait_fee_ngn: carriedForwardWaitFee > 0 ? carriedForwardWaitFee : 0,
    outstanding_wait_fee_included: carriedForwardWaitFee > 0,
    platform_fee_ngn: pricing.platform_fee_ngn,
    booking_fee_ngn: pricing.platform_fee_ngn,
    small_order_fee_ngn: pricing.small_order_fee_ngn,
    total_ngn: pricing.total_ngn,
    fee_breakdown: pricing.fee_breakdown,
    pricing_snapshot: pricingSnapshot,
    commission_rate: pricingSnapshot.commission_rate,
    currency,
    distance_km: distanceKm,
    eta_minutes: etaMin,
    payment_method: paymentNormalized,
    payment_status: paymentStatus,
    package_photo_url: String(data?.package_photo_url ?? data?.packagePhotoUrl ?? "").trim() || null,
    created_at: ts,
    updated_at: ts,
    expires_at: expiresAt,
    search_timeout_at: expiresAt,
    request_expires_at: expiresAt,
    accepted_at: null,
    completed_at: null,
    cancelled_at: null,
    cancel_reason: "",
    resolved_service_region_id: rolloutGate.region_id || null,
    resolved_service_city_id: rolloutGate.city_id || null,
    resolved_dispatch_market_id: rolloutGate.dispatch_market_id || null,
    match_debug: {
      matching_state: "pending_fanout",
      dispatch_market_id: resolvedMarket,
      resolved_service_city_id: rolloutGate.city_id || null,
      created_at: ts,
    },
  };

  console.log(
    "DELIVERY_CREATE_START",
    `customerId=${customerId}`,
    `deliveryId=${deliveryId}`,
    `market=${resolvedMarket}`,
  );

  await delRef.set(row);
  try {
    const deliveryTrace = require("./delivery_trace");
    await deliveryTrace.syncDeliveryTraceFromDeliveryRow(db, deliveryId, row, "delivery_created");
  } catch (traceErr) {
    console.log("DELIVERY_TRACE_SYNC_FAIL", deliveryId, traceErr?.message ?? traceErr);
  }
  try {
    const adminHist = require("./admin_trip_history_persistence");
    await adminHist.persistAdminDeliveryHistoryEvent(db, deliveryId, row, "delivery_created");
  } catch (adminHistErr) {
    console.log("ADMIN_TRIP_HISTORY_CREATE_FAIL", deliveryId, adminHistErr?.message ?? adminHistErr);
  }
  await db.ref(`user_active_delivery/${customerId}`).set({
    delivery_id: deliveryId,
    phase: "searching",
    updated_at: ts,
  });

  if (pricingValidation.discount?.discount_id && pricingSnapshot?.discount_applied_ngn > 0) {
    try {
      const { consumeDiscount } = require("./user_discounts");
      await consumeDiscount(db, customerId, pricingValidation.discount.discount_id, {
        applied_amount_ngn: pricingSnapshot.discount_applied_ngn,
        entity_type: "delivery",
        entity_id: deliveryId,
        actor_uid: customerId,
        reason: "dispatch_delivery",
      });
    } catch (discountErr) {
      console.log(
        "DELIVERY_DISCOUNT_CONSUME_FAIL",
        deliveryId,
        pricingValidation.discount.discount_id,
        discountErr?.message ?? discountErr,
      );
    }
  }

  console.log(
    "DISPATCH_CREATE_CALL_RESPONSE",
    `deliveryId=${deliveryId}`,
    `success=true`,
    `reason=created`,
    `market=${resolvedMarket}`,
    `payment_status=${paymentStatus}`,
  );
  console.log("DELIVERY_CREATE_SUCCESS", deliveryId, resolvedMarket);
  await writeAudit(db, {
    type: "delivery_create",
    delivery_id: deliveryId,
    customer_id: customerId,
    actor_uid: customerId,
  });

  console.log(
    "DELIVERY_CREATED_PENDING_PAYMENT",
    `deliveryId=${deliveryId}`,
    `customerId=${customerId}`,
    `market=${resolvedMarket}`,
    `payment_status=${paymentStatus}`,
  );
  try {
    await fanOutDeliveryOffersIfEligible(db, deliveryId, row);
  } catch (fanoutErr) {
    console.log(
      "DELIVERY_FANOUT_FAIL",
      `deliveryId=${deliveryId}`,
      String(fanoutErr?.message || fanoutErr),
    );
  }

  return {
    success: true,
    deliveryId,
    reason: "created",
    resolved_service_region_id: rolloutGate.region_id || null,
    resolved_service_city_id: rolloutGate.city_id || null,
    resolved_dispatch_market_id: rolloutGate.dispatch_market_id || null,
  };
}

/**
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} db
 */
async function acceptDeliveryRequest(data, context, db) {
  const deliveryId = normDeliveryIdFromCallableData(data);
  const authUid = normUid(context.auth?.uid);
  const driverId = normDriverIdFromCallableData(data, authUid);
  console.log("DELIVERY_ACCEPT_START", deliveryId, driverId);

  if (!deliveryId || !driverId || !context.auth || authUid !== driverId) {
    return { success: false, reason: "unauthorized" };
  }

  const ref = db.ref(`delivery_requests/${deliveryId}`);
  const preSnap = await ref.get();
  const pre = preSnap.val();
  if (!pre || typeof pre !== "object") {
    return { success: false, reason: "delivery_missing" };
  }
  if (normUid(pre.customer_id) === "") {
    return { success: false, reason: "invalid_delivery_payload" };
  }

  const customerId = normUid(pre.customer_id);
  const assignedPre = canonicalAssignedDeliveryDriverId(pre);
  const ds0 = normalizeDeliveryState(pre.delivery_state);
  const activeAssignedStates = new Set([
    DELIVERY_STATE.driver_assigned,
    DELIVERY_STATE.driver_arriving_pickup,
    DELIVERY_STATE.picked_up,
    DELIVERY_STATE.on_delivery,
    DELIVERY_STATE.arrived_dropoff,
  ]);
  if (assignedPre === driverId && activeAssignedStates.has(ds0)) {
    await clearDeliveryFanoutAndOffers(db, deliveryId, driverId);
    await repairDeliveryActivePointers(db, deliveryId);
    return { success: true, idempotent: true, reason: "already_accepted" };
  }
  if (assignedPre && assignedPre !== driverId) {
    return { success: false, reason: "already_taken" };
  }
  if (!deliveryPoolOpenForAccept(pre)) {
    return { success: false, reason: "status_not_open" };
  }

  const busyGuard = await resolveDeliveryBusyGuardForDriver(
    db,
    driverId,
    deliveryId,
    "delivery_accept",
  );
  if (busyGuard.busy) {
    console.log(
      "DELIVERY_ACCEPT_FAIL",
      deliveryId,
      driverId,
      "driver_busy",
      `blockingTripId=${busyGuard.blockingTripId || ""}`,
    );
    return { success: false, reason: "driver_busy" };
  }

  const offerSnap = await db.ref(`delivery_offer_queue/${driverId}/${deliveryId}`).get();
  if (!offerSnap.exists()) {
    return { success: false, reason: "no_offer" };
  }

  const gates = await loadDispatchGates(db);
  const drvSnap = await db.ref(`drivers/${driverId}`).get();
  const drvProf = drvSnap.val();
  if (!drvProf || typeof drvProf !== "object") {
    return { success: false, reason: "driver_profile_missing" };
  }
  const el = evaluateDriverForOffer(drvProf, gates, { ...pre, service_type: "dispatch_delivery" });
  if (!el.ok) {
    return { success: false, reason: "driver_not_eligible" };
  }
  const fleetGate = await fleetAccountability.assertFleetLinkedDriverCanOperate(
    db,
    null,
    driverId,
    drvProf,
  );
  if (!fleetGate.ok) {
    return {
      success: false,
      reason: fleetGate.reason || "fleet_suspended",
      message: fleetGate.message || fleetAccountability.FLEET_SUSPENDED_MESSAGE,
    };
  }

  const now = nowMs();
  const lock = await acquireDeliveryMatchLockOrReject(ref, deliveryId, driverId, now);
  if (!lock.ok) {
    return { success: false, reason: lock.reason || "already_taken" };
  }

  let committed = false;
  let lastReason = "unknown";
  let finalRow = null;

  for (let attempt = 1; attempt <= DELIVERY_ACCEPT_TX_MAX_ATTEMPTS; attempt++) {
    const warm = (await ref.get()).val();
    if (!warm || typeof warm !== "object") {
      lastReason = "delivery_missing";
      break;
    }
    const txResult = await ref.transaction((current) => {
      const decision = evaluateDeliveryAcceptTransactionDecision(current, driverId, { now });
      if (decision.action === "abort") {
        lastReason = decision.reason || "unknown";
        return;
      }
      if (decision.action === "noop") {
        return current;
      }
      return { ...current, ...decision.patch };
    });
    if (txResult.committed) {
      committed = true;
      finalRow = txResult.snapshot.val();
      break;
    }
    if (lastReason !== "delivery_missing" && lastReason !== "unknown") {
      break;
    }
    await sleepMs(Math.min(150, 35 * attempt));
  }

  if (!committed) {
    if (deliveryPoolOpenForAccept(pre) || !canonicalAssignedDeliveryDriverId(pre)) {
      const direct = await attemptGuardedDeliveryDirectWrite(ref, deliveryId, driverId, now);
      if (direct.ok) {
        committed = true;
        finalRow = direct.row;
      } else {
        lastReason = direct.reason || lastReason;
      }
    }
  }

  if (!committed) {
    const post = (await ref.get()).val();
    if (canonicalAssignedDeliveryDriverId(post || {}) === driverId) {
      committed = true;
      finalRow = post;
    }
  }

  if (!committed) {
    console.log("DELIVERY_ACCEPT_FAIL", deliveryId, driverId, lastReason);
    return { success: false, reason: lastReason };
  }

  const next = finalRow && typeof finalRow === "object" ? finalRow : pre;
  try {
    const contactPatch = await buildDeliveryDriverContactPatch(db, driverId);
    const customerPatch = await buildDeliveryCustomerContactPatch(db, customerId);
    const mergedContact = { ...contactPatch, ...customerPatch };
    if (Object.keys(mergedContact).length > 0) {
      await ref.update({ ...mergedContact, updated_at: nowMs() });
      Object.assign(next, mergedContact);
    }
  } catch (contactErr) {
    console.log(
      "DELIVERY_DRIVER_CONTACT_ATTACH_FAIL",
      `deliveryId=${deliveryId}`,
      contactErr?.message ?? contactErr,
    );
  }
  try {
    const { resolveDeliveryCommissionRateForDriver } = require("./app_config_pricing");
    const commissionRate = await resolveDeliveryCommissionRateForDriver(db, driverId);
    const priorSnap =
      next.pricing_snapshot && typeof next.pricing_snapshot === "object"
        ? next.pricing_snapshot
        : {};
    const commissionPatch = {
      commission_rate: commissionRate,
      pricing_snapshot: {
        ...priorSnap,
        commission_rate: commissionRate,
        frozen: true,
      },
      updated_at: nowMs(),
    };
    await ref.update(commissionPatch);
    Object.assign(next, commissionPatch);
  } catch (commissionErr) {
    console.log(
      "DELIVERY_COMMISSION_RATE_PATCH_FAIL",
      `deliveryId=${deliveryId}`,
      `driverId=${driverId}`,
      commissionErr?.message ?? commissionErr,
    );
  }
  await clearDeliveryFanoutAndOffers(db, deliveryId, driverId);
  await setActiveDeliveryPointers(db, deliveryId, customerId, driverId, next);
  await ensureDeliveryChatMeta(db, deliveryId, customerId, driverId, next);

  try {
    const paymentPending = !deliveryHasVerifiedOnlinePayment(next);
    if (paymentPending) {
      console.log(
        "DELIVERY_ACCEPTED_PENDING_PAYMENT",
        `deliveryId=${deliveryId}`,
        `driverId=${driverId}`,
        `payment_status=${String(next.payment_status ?? "").trim()}`,
      );
    }
    await sendPushToUser(db, customerId, {
      notification: {
        title: "Driver assigned",
        body: paymentPending
          ? "A biker accepted your delivery. Complete payment to continue."
          : "A driver accepted your delivery request.",
      },
      data: {
        delivery_id: deliveryId,
        type: "delivery_driver_assigned",
      },
    });
    const merchantId = normUid(next.merchant_id ?? next.merchantId);
    if (merchantId) {
      await sendPushToUser(db, merchantId, {
        notification: {
          title: "Driver assigned",
          body: "A driver is heading to your store for pickup.",
        },
        data: { delivery_id: deliveryId, type: "delivery_driver_assigned_merchant" },
      });
    }
    await sendPushToUser(db, driverId, {
      notification: {
        title: "Delivery accepted",
        body: "You are assigned to this delivery. Head to pickup.",
      },
      data: { delivery_id: deliveryId, type: "delivery_active_driver" },
    });
  } catch (pushErr) {
    logger.warn("delivery_accept customer push failed", {
      deliveryId,
      err: String(pushErr?.message || pushErr),
    });
  }

  await writeAudit(db, {
    type: "delivery_accept",
    delivery_id: deliveryId,
    driver_id: driverId,
    customer_id: customerId,
    actor_uid: driverId,
  });
  try {
    const adminHist = require("./admin_trip_history_persistence");
    const acceptedSnap = await db.ref(`delivery_requests/${deliveryId}`).get();
    const acceptedRow =
      acceptedSnap.val() && typeof acceptedSnap.val() === "object" ? acceptedSnap.val() : {};
    await adminHist.persistAdminDeliveryHistoryEvent(
      db,
      deliveryId,
      acceptedRow,
      "delivery_accepted",
    );
  } catch (adminHistErr) {
    console.log("ADMIN_TRIP_HISTORY_ACCEPT_FAIL", deliveryId, adminHistErr?.message ?? adminHistErr);
  }

  console.log("DELIVERY_ACCEPT_SUCCESS", deliveryId, driverId);
  console.log("DELIVERY_ACCEPTED", `deliveryId=${deliveryId}`, `driverId=${driverId}`);
  try {
    await syncDeliveryTrackPublic(db, deliveryId);
  } catch (trackErr) {
    console.log(
      "DELIVERY_TRACK_PUBLIC_SYNC_FAIL",
      `deliveryId=${deliveryId}`,
      trackErr?.message ?? trackErr,
    );
  }
  return { success: true, reason: "accepted", accept_win_path: committed ? "transaction" : "direct" };
}

async function notifyDeliveryLifecyclePush(db, deliveryId, row, nextState) {
  const customerId = normDeliveryCustomerId(row);
  const driverId = canonicalAssignedDeliveryDriverId(row);
  const merchantId = normUid(row.merchant_id ?? row.merchantId);
  const ds = normalizeDeliveryState(nextState);
  const payloads = {
    [DELIVERY_STATE.driver_assigned]: {
      customer: { title: "Driver assigned", body: "Your driver is on the way to pickup." },
      merchant: { title: "Driver assigned", body: "A driver is assigned to your order." },
      driver: { title: "Pickup next", body: "Navigate to the pickup location." },
      type: "delivery_driver_assigned",
    },
    [DELIVERY_STATE.driver_arriving_pickup]: {
      customer: { title: "Driver arriving", body: "Your driver is heading to pickup." },
      merchant: { title: "Driver en route", body: "Driver is heading to your store." },
      type: "delivery_driver_arriving",
    },
    [DELIVERY_STATE.picked_up]: {
      customer: { title: "Order picked up", body: "Your package is on the way." },
      merchant: { title: "Order picked up", body: "The driver collected the order." },
      type: "delivery_picked_up",
    },
    [DELIVERY_STATE.on_delivery]: {
      customer: { title: "On the way", body: "Your delivery is in progress." },
      type: "delivery_on_delivery",
    },
    [DELIVERY_STATE.arrived_dropoff]: {
      customer: { title: "Driver nearby", body: "Your driver is arriving at the destination." },
      type: "delivery_arriving_dropoff",
    },
    [DELIVERY_STATE.completed]: {
      customer: { title: "Delivered", body: "Your delivery is complete." },
      merchant: { title: "Delivery completed", body: "This order has been delivered." },
      driver: { title: "Delivery complete", body: "Great job — delivery completed." },
      type: "delivery_completed",
    },
  };
  const pack = payloads[ds];
  if (!pack) {
    return;
  }
  const data = { delivery_id: deliveryId, type: pack.type };
  try {
    if (customerId && pack.customer) {
      await sendPushToUser(db, customerId, { notification: pack.customer, data });
    }
    if (merchantId && pack.merchant) {
      await sendPushToUser(db, merchantId, { notification: pack.merchant, data });
    }
    if (driverId && pack.driver) {
      await sendPushToUser(db, driverId, { notification: pack.driver, data });
    }
  } catch (e) {
    logger.warn("delivery_lifecycle_push_failed", {
      deliveryId,
      state: ds,
      err: String(e?.message || e),
    });
  }
}

async function createDeliverySupportTicket(data, context, db) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const deliveryId = normDeliveryIdFromCallableData(data);
  const reportId = String(data?.reportId ?? data?.report_id ?? "").trim();
  const reason = String(data?.reason ?? "other").trim().slice(0, 120);
  const message = String(data?.message ?? "").trim().slice(0, 2000);
  const reporterRole = String(data?.reporterRole ?? data?.reporter_role ?? "customer").trim();
  if (!deliveryId) {
    return { success: false, reason: "invalid_delivery_id" };
  }
  const snap = await db.ref(`delivery_requests/${deliveryId}`).get();
  if (!snap.exists()) {
    return { success: false, reason: "delivery_missing" };
  }
  const row = snap.val() || {};
  // Deterministic doc id keeps creation idempotent per delivery report.
  const ticketId = `delivery_report__${deliveryId}__${reportId || nowMs()}`;
  const driverId = canonicalAssignedDeliveryDriverId(row) || null;
  const fleetBusinessId = trimStr(row.fleet_business_id ?? row.fleetBusinessId, 128) || null;

  // Single source of truth: write the ticket to Firestore `support_tickets`
  // (the helper is idempotent on an existing doc id).
  const writeResult = await createSupportTicketFirestore({
    ticketDocumentId: ticketId,
    ownerUid: normUid(context.auth.uid),
    createdByType: reporterRole === "driver" ? "driver" : "rider",
    message: message || `Delivery report: ${reason}`,
    subject: `Delivery report: ${reason}`,
    category: "delivery_report",
    priority: "normal",
    rideId: deliveryId,
    tripId: deliveryId,
    driverId,
    sourceType: "delivery_report",
    tags: ["delivery_report", "delivery_linked"],
    tripSnapshot: {
      tripId: deliveryId,
      status: normalizeDeliveryState(row.delivery_state),
      disputeReason: reason,
    },
  });
  if (!writeResult.success && writeResult.code !== "already_exists") {
    return writeResult;
  }
  if (driverId) {
    try {
      const incidentRes = await fleetAccountability.recordFleetLinkedDeliveryIncident(
        db,
        admin.firestore(),
        {
          deliveryId,
          driverId,
          riderUid: normUid(context.auth.uid),
          issueType: reason,
          description: message,
          actorUid: normUid(context.auth.uid),
          ticketId,
          severity: "normal",
        },
      );
      if (incidentRes.success && incidentRes.fleet_owner_uid) {
        await sendPushToUser(db, incidentRes.fleet_owner_uid, {
          notification: {
            title: "Delivery issue reported",
            body: "A rider reported an issue on a fleet-linked delivery.",
          },
          data: {
            type: "fleet_delivery_incident",
            business_id: incidentRes.business_id,
            delivery_id: deliveryId,
            incident_id: incidentRes.incident_id,
          },
        });
      }
    } catch (incidentErr) {
      console.log(
        "FLEET_DELIVERY_INCIDENT_FAIL",
        `deliveryId=${deliveryId}`,
        String(incidentErr?.message || incidentErr),
      );
    }
  }
  if (reportId) {
    await db.ref(`support_reports/deliveries/${deliveryId}/${reportId}`).update({
      support_ticket_id: ticketId,
      assignment_status: "ticket_created",
    });
  }
  return { success: true, ticketId };
}

async function ensureDeliveryChatMeta(db, deliveryId, customerId, driverId, row) {
  const rid = normUid(deliveryId);
  const c = normUid(customerId);
  const d = normUid(driverId);
  if (!rid || !c || !d) {
    return;
  }
  const now = nowMs();
  const metaPath = `delivery_chats/${rid}/meta`;
  const snap = await db.ref(metaPath).get();
  const existing = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  await db.ref(metaPath).update({
    delivery_id: rid,
    ride_id: rid,
    customer_id: c,
    rider_id: c,
    driver_id: d,
    merchant_id: normUid(row.merchant_id ?? row.merchantId) || null,
    status: "active",
    created_at: existing.created_at ?? now,
    updated_at: now,
    safety_notice:
      "Never share private contact or payment information. Harassment, abuse, or sexual content is prohibited. Report unsafe behavior immediately.",
  });
}

/**
 * Driver advances delivery_state one step; completes with payment gate for card.
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} db
 */
async function updateDeliveryState(data, context, db) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const deliveryId = normDeliveryIdFromCallableData(data);
  const driverId = normUid(context.auth.uid);
  const explicit = String(data?.delivery_state ?? data?.deliveryState ?? "").trim().toLowerCase();

  if (!deliveryId || !driverId) {
    return { success: false, reason: "invalid_input" };
  }

  const ref = db.ref(`delivery_requests/${deliveryId}`);
  const snap = await ref.get();
  const cur = snap.val();
  if (!cur || typeof cur !== "object") {
    return { success: false, reason: "delivery_missing" };
  }
  if (canonicalAssignedDeliveryDriverId(cur) !== driverId) {
    return { success: false, reason: "not_assigned_driver" };
  }

  const current = normalizeDeliveryState(cur.delivery_state);
  const explicitNorm = normalizeDeliveryState(explicit);
  let nextState = DRIVER_DELIVERY_NEXT[current];
  if (explicitNorm === DELIVERY_STATE.cancelled && current !== DELIVERY_STATE.completed) {
    nextState = DELIVERY_STATE.cancelled;
  }
  if (explicitNorm && explicitNorm !== current && DRIVER_DELIVERY_NEXT[current] === undefined) {
    const allowedExplicit = new Set(Object.values(DELIVERY_STATE));
    if (allowedExplicit.has(explicitNorm)) {
      nextState = explicitNorm;
    }
  }
  if (!nextState) {
    return { success: false, reason: "invalid_transition" };
  }

  if (
    explicitNorm &&
    explicitNorm !== nextState &&
    !(explicitNorm === DELIVERY_STATE.completed && nextState === DELIVERY_STATE.completed)
  ) {
    if (Object.values(DELIVERY_STATE).includes(explicitNorm)) {
      nextState = explicitNorm;
    } else {
      return { success: false, reason: "state_mismatch" };
    }
  }

  const forceGeo = data?.force_geo_override === true || data?.forceGeoOverride === true;
  const driverLat = Number(data?.driver_lat ?? data?.driverLat ?? cur.driver_lat ?? NaN);
  const driverLng = Number(data?.driver_lng ?? data?.driverLng ?? cur.driver_lng ?? NaN);

  if (!forceGeo && nextState === DELIVERY_STATE.picked_up && current === DELIVERY_STATE.driver_arriving_pickup) {
    if (!driverNearPickup(cur, driverLat, driverLng)) {
      return { success: false, reason: "not_near_pickup", geo_gate_m: DELIVERY_GEO_GATE_RADIUS_M };
    }
  }
  if (!forceGeo && nextState === DELIVERY_STATE.completed && current === DELIVERY_STATE.arrived_dropoff) {
    if (!driverNearDropoff(cur, driverLat, driverLng)) {
      return { success: false, reason: "not_near_dropoff", geo_gate_m: DELIVERY_GEO_GATE_RADIUS_M };
    }
  }

  if (
    deliveryProgressRequiresVerifiedPayment(current, nextState) ||
    (nextState === DELIVERY_STATE.picked_up && current === DELIVERY_STATE.driver_arriving_pickup)
  ) {
    if (
      nextState === DELIVERY_STATE.picked_up &&
      current === DELIVERY_STATE.driver_arriving_pickup &&
      !hasPickupProofPhoto(cur)
    ) {
      console.log(
        "DELIVERY_PICKUP_PROOF_REQUIRED",
        `deliveryId=${deliveryId}`,
        `driverId=${driverId}`,
      );
      return { success: false, reason: "pickup_proof_required" };
    }
    if (deliveryProgressRequiresVerifiedPayment(current, nextState) &&
      !deliveryHasVerifiedOnlinePayment(cur)) {
      console.log(
        "DELIVERY_PAYMENT_REQUIRED_TO_START",
        `deliveryId=${deliveryId}`,
        `driverId=${driverId}`,
        `from=${current}`,
        `to=${nextState}`,
        `payment_status=${String(cur.payment_status ?? "").trim()}`,
      );
      return {
        success: false,
        reason: "payment_not_verified",
        message: "Waiting for rider payment verification.",
      };
    }
  }

  if (nextState === DELIVERY_STATE.completed) {
    if (!deliveryHasVerifiedOnlinePayment(cur)) {
      console.log(
        "DELIVERY_COMPLETE_BLOCKED_PAYMENT_NOT_VERIFIED",
        `deliveryId=${deliveryId}`,
        `driverId=${driverId}`,
      );
      return { success: false, reason: "payment_not_verified" };
    }
    if (!hasDeliveryProofPhoto(cur)) {
      console.log(
        "DELIVERY_COMPLETE_BLOCKED_PROOF_REQUIRED",
        `deliveryId=${deliveryId}`,
        `driverId=${driverId}`,
      );
      return { success: false, reason: "delivery_proof_required" };
    }
  }

  const now = nowMs();
  const mirror = deliveryUiMirrorFields(nextState, driverId);
  const nextRow = {
    ...cur,
    delivery_state: nextState,
    trip_state: mirror.trip_state,
    status: mirror.status,
    updated_at: now,
  };
  if (nextState === DELIVERY_STATE.completed) {
    nextRow.completed_at = cur.completed_at ?? now;
  }
  if (nextState === DELIVERY_STATE.cancelled) {
    nextRow.cancelled_at = now;
    nextRow.cancel_reason = String(data?.cancel_reason ?? data?.cancelReason ?? "driver_cancelled").slice(0, 200);
  }

  await ref.set(nextRow);

  try {
    const deliveryTrace = require("./delivery_trace");
    if (nextState === DELIVERY_STATE.completed) {
      await deliveryTrace.syncDeliveryTraceFromDeliveryRow(
        db,
        deliveryId,
        nextRow,
        "delivery_completed",
      );
    } else if (nextState === DELIVERY_STATE.cancelled) {
      await deliveryTrace.mergeDeliveryTrace(
        db,
        deliveryId,
        {
          delivery_state: DELIVERY_STATE.cancelled,
          status: "cancelled",
          cancelled_at: nextRow.cancelled_at ?? now,
          settlement_status: "cancelled",
        },
        { source: "delivery_cancelled" },
      );
    } else {
      await deliveryTrace.syncDeliveryTraceFromDeliveryRow(
        db,
        deliveryId,
        nextRow,
        "delivery_state_updated",
      );
    }
  } catch (traceErr) {
    console.log("DELIVERY_TRACE_SYNC_FAIL", deliveryId, traceErr?.message ?? traceErr);
  }
  try {
    const adminHist = require("./admin_trip_history_persistence");
    const eventType =
      nextState === DELIVERY_STATE.completed
        ? "delivery_completed"
        : nextState === DELIVERY_STATE.cancelled
          ? "delivery_cancelled"
          : "delivery_state_updated";
    await adminHist.persistAdminDeliveryHistoryEvent(db, deliveryId, nextRow, eventType, {
      cancel_reason: nextRow.cancel_reason,
      cancelled_by: nextRow.cancelled_by ?? nextRow.cancel_actor,
    });
  } catch (adminHistErr) {
    console.log("ADMIN_TRIP_HISTORY_STATE_FAIL", deliveryId, adminHistErr?.message ?? adminHistErr);
  }

  if (nextState === DELIVERY_STATE.completed) {
    console.log(
      "DELIVERY_COMPLETED_WITH_PROOF",
      `deliveryId=${deliveryId}`,
      `driverId=${driverId}`,
    );
    try {
      const walletSettlement = require("./payment_wallet_settlement");
      await walletSettlement.applyWalletSettlementsAfterAuthoritativePayment(db, {
        deliveryId,
        source: "delivery_completed",
        requireCompleted: true,
      });
    } catch (settleErr) {
      console.log(
        "WALLET_SETTLEMENT_FAIL",
        `deliveryId=${deliveryId}`,
        settleErr?.message ?? settleErr,
      );
    }
  }

  if (nextState === DELIVERY_STATE.driver_arriving_pickup && current !== DELIVERY_STATE.driver_arriving_pickup) {
    try {
      const { startDeliveryWaitFeeWindow } = require("./delivery_wait_fee");
      await startDeliveryWaitFeeWindow(db, deliveryId, cur);
    } catch (waitErr) {
      console.log(
        "DELIVERY_WAIT_FEE_START_FAIL",
        `deliveryId=${deliveryId}`,
        waitErr?.message ?? waitErr,
      );
    }
  }

  if (TERMINAL_DELIVERY.has(nextState)) {
    try {
      const { persistDeliveryTerminalHistory } = require("./trip_history_persistence");
      await persistDeliveryTerminalHistory(db, deliveryId, nextRow);
    } catch (histErr) {
      console.log(
        "TRIP_HISTORY_PERSIST_FAIL",
        `deliveryId=${deliveryId}`,
        histErr?.message ?? histErr,
      );
    }
    const terminalSource =
      nextState === DELIVERY_STATE.completed
        ? "delivery_completed"
        : "delivery_cancelled";
    try {
      const { finalizeDeliveryWaitFeeOnTerminal } = require("./delivery_wait_fee");
      const paid =
        nextState === DELIVERY_STATE.completed && deliveryHasVerifiedOnlinePayment(nextRow);
      await finalizeDeliveryWaitFeeOnTerminal(db, deliveryId, nextRow, { paid });
    } catch (waitFinErr) {
      console.log(
        "DELIVERY_WAIT_FEE_FINALIZE_FAIL",
        `deliveryId=${deliveryId}`,
        waitFinErr?.message ?? waitFinErr,
      );
    }
    try {
      await applyDeliveryTerminalPostCommit(db, deliveryId, nextRow, {
        customerId: normUid(cur.customer_id),
        driverId,
        merchantId: normUid(cur.merchant_id ?? cur.merchantId),
        source: terminalSource,
        terminalState: nextState,
        clearFanout: nextState === DELIVERY_STATE.cancelled,
        excludeDriverFromFanout: driverId,
      });
    } catch (terminalErr) {
      console.log(
        "DELIVERY_TERMINAL_POST_COMMIT_FAIL",
        `deliveryId=${deliveryId}`,
        terminalErr?.message ?? terminalErr,
      );
    }
  } else {
    await db.ref().update({
      [`active_deliveries/${deliveryId}/delivery_state`]: nextState,
      [`active_deliveries/${deliveryId}/updated_at`]: now,
    });
  }

  await writeAudit(db, {
    type: "delivery_state_update",
    delivery_id: deliveryId,
    driver_id: driverId,
    delivery_state: nextState,
    actor_uid: driverId,
  });

  await notifyDeliveryLifecyclePush(db, deliveryId, nextRow, nextState);

  try {
    await syncDeliveryTrackPublic(db, deliveryId);
  } catch (trackErr) {
    console.log(
      "DELIVERY_TRACK_PUBLIC_SYNC_FAIL",
      `deliveryId=${deliveryId}`,
      trackErr?.message ?? trackErr,
    );
  }

  return { success: true, delivery_state: nextState };
}

async function expireDeliveryRequest(data, context, db) {
  const customerId = normUid(context.auth?.uid);
  const deliveryId = normDeliveryIdFromCallableData(data);
  if (!customerId || !deliveryId) {
    return { success: false, reason: "invalid_input" };
  }
  const ref = db.ref(`delivery_requests/${deliveryId}`);
  const row = (await ref.get()).val();
  if (!row || typeof row !== "object" || normUid(row.customer_id) !== customerId) {
    return { success: false, reason: "forbidden" };
  }
  const ds = normalizeDeliveryState(row.delivery_state);
  if (ds !== DELIVERY_STATE.searching) {
    return { success: false, reason: "status_not_open" };
  }
  const now = nowMs();
  const mirror = deliveryUiMirrorFields(DELIVERY_STATE.cancelled, "");
  await ref.set({
    ...row,
    delivery_state: DELIVERY_STATE.cancelled,
    trip_state: mirror.trip_state,
    status: mirror.status,
    cancelled_at: now,
    cancel_reason: "search_timeout",
    updated_at: now,
  });
  const cancelledRow = {
    ...row,
    delivery_state: DELIVERY_STATE.cancelled,
    trip_state: mirror.trip_state,
    status: mirror.status,
    cancelled_at: now,
    cancel_reason: "search_timeout",
    updated_at: now,
  };
  try {
    const { persistDeliveryTerminalHistory } = require("./trip_history_persistence");
    await persistDeliveryTerminalHistory(db, deliveryId, cancelledRow);
  } catch (histErr) {
    console.log(
      "TRIP_HISTORY_PERSIST_FAIL",
      `deliveryId=${deliveryId}`,
      histErr?.message ?? histErr,
    );
  }
  try {
    const adminHist = require("./admin_trip_history_persistence");
    await adminHist.persistAdminDeliveryHistoryEvent(
      db,
      deliveryId,
      cancelledRow,
      "delivery_expired",
      { cancel_reason: "search_timeout", cancelled_by: "system" },
    );
  } catch (adminHistErr) {
    console.log("ADMIN_TRIP_HISTORY_EXPIRE_FAIL", deliveryId, adminHistErr?.message ?? adminHistErr);
  }
  let driverId = canonicalAssignedDeliveryDriverId(row);
  const merchantId = normUid(row.merchant_id ?? row.merchantId);
  if (!driverId) {
    const activeSnap = await db.ref(`active_deliveries/${deliveryId}`).get();
    const active = activeSnap.val();
    if (active && typeof active === "object") {
      driverId = normUid(active.driver_id ?? active.driverId);
    }
  }
  try {
    await applyDeliveryTerminalPostCommit(db, deliveryId, cancelledRow, {
      customerId,
      driverId,
      merchantId,
      source: "delivery_expired",
      terminalState: DELIVERY_STATE.cancelled,
      clearFanout: true,
    });
  } catch (terminalErr) {
    console.log(
      "DELIVERY_EXPIRE_POST_COMMIT_FAIL",
      `deliveryId=${deliveryId}`,
      terminalErr?.message ?? terminalErr,
    );
  }
  await writeAudit(db, {
    type: "delivery_expire",
    delivery_id: deliveryId,
    customer_id: customerId,
    actor_uid: customerId,
  });
  return { success: true, reason: "expired" };
}

async function cancelDeliveryRequest(data, context, db) {
  const uid = normUid(context.auth?.uid);
  const deliveryId = normDeliveryIdFromCallableData(data);
  if (!uid || !deliveryId) {
    return { success: false, reason: "invalid_input" };
  }
  const ref = db.ref(`delivery_requests/${deliveryId}`);
  const row = (await ref.get()).val();
  if (!row || typeof row !== "object") {
    return { success: false, reason: "delivery_missing" };
  }
  const customerId = normDeliveryCustomerId(row);
  const driverId = canonicalAssignedDeliveryDriverId(row);
  const isCustomer = customerId === uid;
  const isDriver = driverId === uid;
  if (!isCustomer && !isDriver) {
    return { success: false, reason: "forbidden" };
  }
  const ds = normalizeDeliveryState(row.delivery_state);
  if (TERMINAL_DELIVERY.has(ds)) {
    return { success: false, reason: "already_terminal" };
  }
  const now = nowMs();
  const cancelReasonCode = String(
    data?.cancel_reason_code ?? data?.cancelReasonCode ?? "",
  )
    .trim()
    .slice(0, 80);
  const cancelReasonText = String(
    data?.cancel_reason_text ?? data?.cancelReasonText ?? "",
  )
    .trim()
    .slice(0, 200);
  const cancelNote = String(data?.cancel_note ?? data?.cancelNote ?? "")
    .trim()
    .slice(0, 500);
  let cancelReason = String(data?.cancel_reason ?? data?.cancelReason ?? "user_cancelled").slice(
    0,
    200,
  );
  if (cancelReasonCode) {
    cancelReason = cancelReasonCode;
  }
  if (
    isCustomer &&
    (cancelReason === "payment_timeout" || cancelReason === "unpaid_payment_timeout")
  ) {
    if (!deliveryUnpaidPaymentPastDeadline(row, now)) {
      return { success: false, reason: "payment_deadline_not_reached" };
    }
    if (ds !== DELIVERY_STATE.driver_assigned) {
      return { success: false, reason: "cannot_cancel_at_stage" };
    }
    console.log(
      "DELIVERY_CANCEL_UNPAID_PAYMENT_TIMEOUT",
      `deliveryId=${deliveryId}`,
      `customerId=${customerId}`,
    );
  } else {
    const decision = evaluateDeliveryCancelDecision(row, uid, {
      cancelReason,
      requestOnly:
        data?.request_only === true ||
        data?.requestOnly === true ||
        cancelReason === "request_cancel",
    });
    if (!decision.allowed) {
      if (decision.log === "DELIVERY_CANCEL_BLOCKED_PAYMENT_VERIFIED") {
        console.log(
          "DELIVERY_CANCEL_BLOCKED_PAYMENT_VERIFIED",
          `deliveryId=${deliveryId}`,
          `driverId=${driverId || uid}`,
          `payment_status=${String(row.payment_status ?? "").trim().toLowerCase()}`,
          `total_ngn=${Number(row.total_ngn ?? row.fare ?? 0) || 0}`,
        );
      } else if (decision.log) {
        console.log(decision.log, `deliveryId=${deliveryId}`, `uid=${uid}`);
      }
      return {
        success: false,
        reason: decision.reason || "cannot_cancel_at_stage",
        reason_code: decision.reason_code ?? decision.reason,
        message: decision.message ?? undefined,
      };
    }
    if (decision.mode === "request") {
      console.log(
        decision.log || "DELIVERY_CANCEL_REQUESTED",
        `deliveryId=${deliveryId}`,
        `uid=${uid}`,
      );
      await ref.update({
        cancellation_requested_at: now,
        cancellation_requested_by: uid,
        cancellation_request_reason: cancelReasonText || cancelReason || "request_cancel",
        cancel_requested_by: isCustomer ? "customer" : isDriver ? "driver" : uid,
        cancel_reason_code: cancelReasonCode || cancelReason || null,
        cancel_reason_text: cancelReasonText || cancelReason || null,
        cancel_note: cancelNote || null,
        updated_at: now,
      });
      if (driverId) {
        try {
          await sendPushToUser(db, driverId, {
            notification: {
              title: "Cancellation requested",
              body: "The sender requested to cancel this delivery. Review in the app.",
            },
            data: { type: "delivery_cancel_requested", delivery_id: deliveryId },
          });
        } catch (_) {}
      }
      return { success: true, reason: "delivery_cancel_requested", policy: decision.policy };
    }
    if (decision.log) {
      console.log(decision.log, `deliveryId=${deliveryId}`, `uid=${uid}`);
    }
    cancelReason = decision.cancel_reason || cancelReason;
  }

  const mirror = deliveryUiMirrorFields(DELIVERY_STATE.cancelled, driverId || "");
  const finalCancelReason = cancelReason;
  const cancelledPatch = {
    ...row,
    delivery_state: DELIVERY_STATE.cancelled,
    trip_state: mirror.trip_state,
    status: mirror.status,
    cancelled_at: now,
    cancel_reason: finalCancelReason,
    cancel_requested_by: isCustomer ? "customer" : isDriver ? "driver" : uid,
    cancel_reason_code: cancelReasonCode || finalCancelReason || null,
    cancel_reason_text: cancelReasonText || finalCancelReason || null,
    cancel_note: cancelNote || null,
    updated_at: now,
    cancellation_requested_at: null,
    cancellation_requested_by: null,
  };
  const policyDecision = evaluateDeliveryCancelDecision(row, uid, { cancelReason: finalCancelReason });
  if (policyDecision.refund_status) {
    cancelledPatch.refund_status = policyDecision.refund_status;
  }
  if (policyDecision.policy) {
    cancelledPatch.cancel_policy = policyDecision.policy;
  }
  await ref.set(cancelledPatch);
  const cancelledRow = cancelledPatch;
  try {
    const { persistDeliveryTerminalHistory } = require("./trip_history_persistence");
    await persistDeliveryTerminalHistory(db, deliveryId, cancelledRow);
  } catch (histErr) {
    console.log(
      "TRIP_HISTORY_PERSIST_FAIL",
      `deliveryId=${deliveryId}`,
      histErr?.message ?? histErr,
    );
  }
  try {
    const adminHist = require("./admin_trip_history_persistence");
    await adminHist.persistAdminDeliveryHistoryEvent(
      db,
      deliveryId,
      cancelledRow,
      "delivery_cancelled",
      {
        cancel_reason: finalCancelReason,
        cancelled_by: cancelledPatch.cancel_requested_by,
      },
    );
  } catch (adminHistErr) {
    console.log("ADMIN_TRIP_HISTORY_CANCEL_FAIL", deliveryId, adminHistErr?.message ?? adminHistErr);
  }
  try {
    await applyDeliveryTerminalPostCommit(db, deliveryId, cancelledRow, {
      customerId,
      driverId,
      merchantId: normUid(row.merchant_id ?? row.merchantId),
      source: "cancelDeliveryRequest",
      terminalState: DELIVERY_STATE.cancelled,
      clearFanout: true,
      excludeDriverFromFanout: isDriver ? uid : "",
    });
  } catch (terminalErr) {
    console.log(
      "DELIVERY_CANCEL_POST_COMMIT_FAIL",
      `deliveryId=${deliveryId}`,
      terminalErr?.message ?? terminalErr,
    );
  }
  try {
    const { syncDeliveryTrackPublic } = require("./track_public");
    await syncDeliveryTrackPublic(db, deliveryId);
  } catch (trackErr) {
    console.log(
      "DELIVERY_SHARE_TRACK_SYNC_FAIL",
      `deliveryId=${deliveryId}`,
      trackErr?.message ?? trackErr,
    );
  }
  await writeAudit(db, {
    type: "delivery_cancel",
    delivery_id: deliveryId,
    customer_id: customerId,
    driver_id: driverId || null,
    actor_uid: uid,
  });
  return { success: true, reason: "cancelled" };
}

/**
 * Trusted server path: create a food delivery row for an existing merchant order
 * (customer already validated by caller). Used by merchant commerce dispatch.
 *
 * @param {import("firebase-admin/database").Database} db
 * @param {object} row Pre-built delivery_requests payload including delivery_id, customer_id, pickup, dropoff, fare, payment_*, category "food", etc.
 * @returns {Promise<{ ok: true, deliveryId: string } | { ok: false, reason: string, deliveryId?: string }>}
 */
async function createFoodDeliveryForMerchantOrder(db, row) {
  if (!row || typeof row !== "object") {
    return { ok: false, reason: "invalid_row" };
  }
  const deliveryId = normUid(row.delivery_id);
  const customerId = normUid(row.customer_id);
  if (!deliveryId || !customerId) {
    return { ok: false, reason: "invalid_ids" };
  }
  const slot = await assertCustomerDeliverySlot(db, customerId);
  if (!slot.ok) {
    return { ok: false, reason: slot.reason || "customer_active_delivery", deliveryId: slot.deliveryId };
  }
  const ref = db.ref(`delivery_requests/${deliveryId}`);
  const ts = nowMs();
  const exp = Number(row.expires_at) > 0 ? Number(row.expires_at) : ts + 180000;
  const mirror = deliveryUiMirrorFields(DELIVERY_STATE.searching, "");
  const full = {
    ...row,
    delivery_id: deliveryId,
    customer_id: customerId,
    rider_id: customerId,
    service_type: "dispatch_delivery",
    delivery_state: DELIVERY_STATE.searching,
    trip_state: mirror.trip_state,
    status: mirror.status,
    driver_id: mirror.driver_id,
    matched_driver_id: null,
    category: "food",
    created_at: row.created_at ?? ts,
    updated_at: ts,
    expires_at: exp,
    search_timeout_at: row.search_timeout_at ?? exp,
    request_expires_at: row.request_expires_at ?? exp,
  };
  await ref.set(full);
  await db.ref(`user_active_delivery/${customerId}`).set({
    delivery_id: deliveryId,
    phase: "searching",
    updated_at: ts,
  });
  await fanOutDeliveryOffersIfEligible(db, deliveryId, full);
  await writeAudit(db, {
    type: "delivery_create",
    delivery_id: deliveryId,
    customer_id: customerId,
    actor_uid: customerId,
    merchant_id: normUid(row.merchant_id) || null,
    merchant_order_id: normUid(row.merchant_order_id) || null,
    source: "merchant_food_order",
  });
  return { ok: true, deliveryId };
}

async function registerPickupProofPhoto(data, context, db) {
  const driverId = normUid(context?.auth?.uid);
  const deliveryId = normDeliveryIdFromCallableData(data);
  const photoUrl = trimStr(
    data?.pickup_proof_photo_url ?? data?.pickupProofPhotoUrl ?? data?.delivery_proof_photo_url,
    512,
  );
  console.log(
    "DELIVERY_PICKUP_PROOF_UPLOAD_START",
    `deliveryId=${deliveryId}`,
    `driverId=${driverId}`,
  );
  if (!driverId || !deliveryId || !photoUrl.startsWith("https://")) {
    console.log(
      "DELIVERY_PICKUP_PROOF_UPLOAD_FAIL",
      `deliveryId=${deliveryId}`,
      `reason=invalid_input`,
    );
    return { success: false, reason: "invalid_input" };
  }
  const ref = db.ref(`delivery_requests/${deliveryId}`);
  const snap = await ref.get();
  const row = snap.val();
  if (!row || typeof row !== "object") {
    return { success: false, reason: "delivery_missing" };
  }
  if (canonicalAssignedDeliveryDriverId(row) !== driverId) {
    return { success: false, reason: "not_assigned_driver" };
  }
  const now = nowMs();
  await ref.update({
    pickup_proof_photo_url: photoUrl,
    pickup_proof_uploaded_at: now,
    pickup_proof_uploaded_by: driverId,
    updated_at: now,
  });
  console.log(
    "DELIVERY_PICKUP_PROOF_UPLOAD_SUCCESS",
    `deliveryId=${deliveryId}`,
    `driverId=${driverId}`,
  );
  return { success: true, reason: "pickup_proof_registered" };
}

async function registerDeliveryProofPhoto(data, context, db) {
  const driverId = normUid(context?.auth?.uid);
  const deliveryId = normDeliveryIdFromCallableData(data);
  const photoUrl = trimStr(data?.delivery_proof_photo_url ?? data?.deliveryProofPhotoUrl, 512);
  console.log(
    "DELIVERY_PROOF_UPLOAD_START",
    `deliveryId=${deliveryId}`,
    `driverId=${driverId}`,
  );
  if (!driverId || !deliveryId || !photoUrl.startsWith("https://")) {
    console.log(
      "DELIVERY_PROOF_UPLOAD_FAIL",
      `deliveryId=${deliveryId}`,
      `reason=invalid_input`,
    );
    return { success: false, reason: "invalid_input" };
  }
  const ref = db.ref(`delivery_requests/${deliveryId}`);
  const snap = await ref.get();
  const row = snap.val();
  if (!row || typeof row !== "object") {
    return { success: false, reason: "delivery_missing" };
  }
  if (canonicalAssignedDeliveryDriverId(row) !== driverId) {
    return { success: false, reason: "not_assigned_driver" };
  }
  const now = nowMs();
  await ref.update({
    delivery_proof_photo_url: photoUrl,
    delivery_proof_uploaded_at: now,
    delivery_proof_status: "submitted",
    updated_at: now,
  });
  console.log(
    "DELIVERY_PROOF_UPLOAD_SUCCESS",
    `deliveryId=${deliveryId}`,
    `driverId=${driverId}`,
  );
  const customerId = normUid(row.customer_id);
  if (customerId) {
    try {
      await sendPushToUser(db, customerId, {
        notification: {
          title: "Delivery photo uploaded",
          body: "Your courier uploaded a delivery proof photo.",
        },
        data: {
          type: "delivery_proof_uploaded",
          delivery_id: deliveryId,
        },
      });
    } catch (pushErr) {
      console.log(
        "DELIVERY_PROOF_NOTIFY_FAIL",
        `deliveryId=${deliveryId}`,
        String(pushErr?.message || pushErr),
      );
    }
  }
  return { success: true, reason: "proof_registered" };
}

async function submitDeliveryRating(data, context, db) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const uid = normUid(context.auth.uid);
  const deliveryId = normDeliveryIdFromCallableData(data);
  const ratingRaw = Number(data?.rating ?? 0);
  const rating = Math.round(ratingRaw);
  if (!deliveryId || rating < 1 || rating > 5) {
    return { success: false, reason: "invalid_input" };
  }
  const comment = trimStr(data?.comment, 500);
  const part = await assertDeliveryChatParticipant(db, deliveryId, uid);
  if (!part.ok) {
    return { success: false, reason: part.reason || "forbidden" };
  }
  const row = part.row;
  const customerId = normDeliveryCustomerId(row);
  const driverId = canonicalAssignedDeliveryDriverId(row);
  const ds = normalizeDeliveryState(row.delivery_state);
  if (ds !== DELIVERY_STATE.completed) {
    return { success: false, reason: "delivery_not_completed" };
  }
  let roleKey = "";
  let toUid = "";
  if (uid === customerId) {
    roleKey = "rider_to_driver";
    toUid = driverId;
    console.log("DELIVERY_RIDER_RATING_SUBMIT", `deliveryId=${deliveryId}`, `rating=${rating}`);
  } else if (uid === driverId) {
    roleKey = "driver_to_rider";
    toUid = customerId;
    console.log("DELIVERY_DRIVER_RATING_SUBMIT", `deliveryId=${deliveryId}`, `rating=${rating}`);
  } else {
    return { success: false, reason: "forbidden" };
  }
  const path = deliveryRatingPath(deliveryId, roleKey);
  const existing = await db.ref(path).get();
  if (existing.exists()) {
    console.log(
      "DELIVERY_RATING_DUPLICATE_BLOCKED",
      `deliveryId=${deliveryId}`,
      `from_uid=${uid}`,
      `roleKey=${roleKey}`,
    );
    return { success: false, reason: "rating_duplicate" };
  }
  const now = nowMs();
  await db.ref(path).set({
    delivery_id: deliveryId,
    from_uid: uid,
    to_uid: toUid,
    rating,
    comment: comment || null,
    created_at: now,
    role: roleKey,
  });
  if (uid === customerId && driverId) {
    const avgSnap = await db.ref(`drivers/${driverId}/delivery_rating_summary`).get();
    const prior = avgSnap.val() && typeof avgSnap.val() === "object" ? avgSnap.val() : {};
    const count = Number(prior.count ?? 0) + 1;
    const sum = Number(prior.sum ?? 0) + rating;
    await db.ref(`drivers/${driverId}/delivery_rating_summary`).set({
      count,
      sum,
      average: Math.round((sum / count) * 10) / 10,
      updated_at: now,
    });
    const fleetBusinessId = trimStr(row.fleet_business_id ?? row.fleetBusinessId, 128);
    if (fleetBusinessId) {
      try {
        await fleetAccountability.applyFleetRatingForDelivery(admin.firestore(), db, {
          businessId: fleetBusinessId,
          driverId,
          deliveryId,
          rating,
          riderUid: uid,
        });
      } catch (fleetRatingErr) {
        console.log(
          "FLEET_RATING_UPDATE_FAIL",
          `deliveryId=${deliveryId}`,
          `businessId=${fleetBusinessId}`,
          String(fleetRatingErr?.message || fleetRatingErr),
        );
      }
    } else {
      const driverSnap = await db.ref(`drivers/${driverId}`).get();
      const driverProf =
        driverSnap.val() && typeof driverSnap.val() === "object" ? driverSnap.val() : {};
      if (fleetAccountability.isDriverLinkedToActiveFleet(driverProf)) {
        const linkedFleetId = trimStr(driverProf.business_id ?? driverProf.businessId, 128);
        if (linkedFleetId) {
          try {
            await fleetAccountability.applyFleetRatingForDelivery(admin.firestore(), db, {
              businessId: linkedFleetId,
              driverId,
              deliveryId,
              rating,
              riderUid: uid,
            });
          } catch (fleetRatingErr) {
            console.log(
              "FLEET_RATING_UPDATE_FAIL",
              `deliveryId=${deliveryId}`,
              `businessId=${linkedFleetId}`,
              String(fleetRatingErr?.message || fleetRatingErr),
            );
          }
        }
      }
    }
  }
  return { success: true, reason: "rating_saved" };
}

async function sendDeliveryChatMessage(data, context, db) {
  if (!context.auth) {
    console.log("DELIVERY_CHAT_ACCESS_DENIED", "reason=unauthorized");
    return { success: false, reason: "unauthorized" };
  }
  const uid = normUid(context.auth.uid);
  const deliveryId = normDeliveryIdFromCallableData(data);
  const msgType = trimStr(data?.type ?? "text", 16).toLowerCase() || "text";
  const text = trimStr(data?.text, 2000);
  const imageUrl = trimStr(data?.image_url ?? data?.imageUrl, 512);
  if (!deliveryId) {
    return { success: false, reason: "invalid_input" };
  }
  const part = await assertDeliveryChatParticipant(db, deliveryId, uid);
  if (!part.ok) {
    return { success: false, reason: part.reason || "forbidden" };
  }
  if (msgType === "text" && !text) {
    return { success: false, reason: "empty_message" };
  }
  if (msgType === "image" && !imageUrl.startsWith("https://")) {
    return { success: false, reason: "invalid_image_url" };
  }
  await ensureDeliveryChatMeta(
    db,
    deliveryId,
    normUid(part.row.customer_id),
    canonicalAssignedDeliveryDriverId(part.row),
    part.row,
  );
  const now = nowMs();
  const msgRef = db.ref(`delivery_chats/${deliveryId}/messages`).push();
  const messageId = msgRef.key || "";
  const payload = {
    delivery_id: deliveryId,
    sender_id: uid,
    sender_uid: uid,
    sender_role: part.role === "driver" ? "driver" : "rider",
    type: msgType === "image" ? "image" : "text",
    text: msgType === "text" ? text : "",
    image_url: msgType === "image" ? imageUrl : null,
    created_at: now,
    created_at_ms: now,
    timestamp: now,
    status: "sent",
    server_ack: true,
  };
  await msgRef.set(payload);
  if (msgType === "image") {
    console.log(
      "CHAT_IMAGE_MESSAGE_CREATED",
      `chatKind=delivery_chat`,
      `threadId=${deliveryId}`,
      `messageId=${messageId}`,
      `senderId=${uid}`,
      `messageType=image`,
      `imageUrl=${imageUrl}`,
    );
    console.log(
      "DELIVERY_CHAT_IMAGE_SENT",
      `deliveryId=${deliveryId}`,
      `messageId=${messageId}`,
      `sender=${uid}`,
    );
  } else {
    console.log(
      "DELIVERY_CHAT_MESSAGE_SENT",
      `deliveryId=${deliveryId}`,
      `messageId=${messageId}`,
      `sender=${uid}`,
    );
  }
  try {
    await onDeliveryChatMessageNotify(db, deliveryId, messageId, payload);
    console.log(
      "DELIVERY_CHAT_NOTIFY_SENT",
      `deliveryId=${deliveryId}`,
      `messageId=${messageId}`,
    );
  } catch (notifyErr) {
    console.log(
      "DELIVERY_CHAT_NOTIFY_FAIL",
      `deliveryId=${deliveryId}`,
      String(notifyErr?.message || notifyErr),
    );
  }
  return { success: true, message_id: messageId, reason: "sent" };
}

async function onDeliveryChatMessageNotify(db, deliveryId, messageId, msg) {
  const { onDeliveryChatMessageCreated } = require("./delivery_chat_triggers");
  await onDeliveryChatMessageCreated(
    {
      params: { deliveryId, messageId },
      data: { val: () => msg },
    },
    db,
  );
}

module.exports = {
  DELIVERY_STATE,
  TERMINAL_DELIVERY,
  LEGACY_DELIVERY_STATE_MAP,
  normalizeDeliveryState,
  canonicalAssignedDeliveryDriverId,
  canonicalAssignedDriver,
  deliveryPoolOpenForAccept,
  deliveryAssignedOrTerminal,
  buildDeliveryAcceptAssignmentPatch,
  evaluateDeliveryAcceptTransactionDecision,
  acquireDeliveryMatchLockOrReject,
  attemptGuardedDeliveryDirectWrite,
  DRIVER_DELIVERY_NEXT,
  deliveryUiMirrorFields,
  deliveryHasVerifiedOnlinePayment,
  deliveryPaymentBlocksDriverCancel,
  profileDeliveryOfferServices,
  driverDispatchMarketForFanout,
  deliveryFanoutEligibleModelB,
  deliveryOpensForFanout,
  deliveryAllowsFanoutPayment,
  purgeExpiredDeliveryOfferQueueEntries,
  refanoutSearchingDeliveriesForReleasedDriver,
  deliveryUnpaidPaymentPastDeadline,
  DELIVERY_UNPAID_PAYMENT_TTL_MS,
  deliveryProgressRequiresVerifiedPayment,
  hasDeliveryProofPhoto,
  hasPickupProofPhoto,
  normDeliveryCustomerId,
  evaluateDeliveryCancelDecision,
  buildDeliveryDriverContactPatch,
  paymentAllowsDispatchDelivery,
  resolveDeliveryBusyGuardForDriver,
  DELIVERY_SEARCH_TTL_MS,
  deliverySearchExpiryFields,
  refreshDeliverySearchExpiryForVerifiedFanout,
  tryAcquireDeliveryVerifiedPaymentFanoutLease,
  markDeliveryVerifiedPaymentFanoutCompleted,
  releaseDeliveryVerifiedPaymentFanoutLease,
  deliveryFanoutLeaseIsStale,
  DELIVERY_FANOUT_AFTER_PAYMENT_IN_PROGRESS_AT_FIELD,
  DELIVERY_FANOUT_AFTER_PAYMENT_COMPLETED_AT_FIELD,
  DELIVERY_FANOUT_AFTER_PAYMENT_LEASE_MS,
  fanOutDeliveryOffersAfterVerifiedPayment,
  clearDeliveryFanoutAndOffers,
  clearDeliveryActivePointers,
  finalizeDriverEligibilityAfterTerminalDelivery,
  applyDeliveryTerminalPostCommit,
  setActiveDeliveryPointers,
  repairDeliveryActivePointers,
  ensureDeliveryChatMeta,
  createDeliveryRequest,
  createFoodDeliveryForMerchantOrder,
  acceptDeliveryRequest,
  createDeliverySupportTicket,
  notifyDeliveryLifecyclePush,
  updateDeliveryState,
  expireDeliveryRequest,
  cancelDeliveryRequest,
  fanOutDeliveryOffersIfEligible,
  deliveryFanoutServiceAreaSkip,
  driverCanReceiveDispatchDeliveryOffers,
  registerPickupProofPhoto,
  registerDeliveryProofPhoto,
  submitDeliveryRating,
  sendDeliveryChatMessage,
  assertDeliveryChatParticipant,
  driverNearPickup,
  driverNearDropoff,
};
