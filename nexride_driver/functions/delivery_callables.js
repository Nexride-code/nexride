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
  return ps === "verified" && Boolean(ptid);
}

function paymentAllowsDispatchDelivery(row) {
  // P0-1: dispatch offers and driver accept require settled online payment only.
  // Fan-out after verify/webhook/admin-approve uses the same gate.
  return deliveryHasVerifiedOnlinePayment(row);
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

/**
 * Verified-payment fan-out entry: refresh search TTL, then fan out with fresh row.
 */
async function fanOutDeliveryOffersAfterVerifiedPayment(db, deliveryId, row) {
  const refreshed = await refreshDeliverySearchExpiryForVerifiedFanout(db, deliveryId, row);
  await fanOutDeliveryOffersIfEligible(db, deliveryId, refreshed);
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
  const pickupAddr =
    typeof pickupObj.address === "string" && pickupObj.address.trim()
      ? pickupObj.address.trim()
      : "";
  return {
    __nexride_request_kind: "delivery",
    delivery_id: deliveryId,
    ride_id: deliveryId,
    rider_id: customerId,
    customer_id: customerId,
    service_type: "dispatch_delivery",
    market,
    market_pool: market,
    pickup: row.pickup,
    dropoff: row.dropoff,
    pickup_address: pickupAddr || null,
    fare: row.fare,
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
    trip_state: mirror.trip_state,
    status: mirror.status,
    driver_id: mirror.driver_id,
    matched_driver_id: mirror.matched_driver_id,
    delivery_state: row.delivery_state,
    created_at: row.created_at ?? now,
    request_status: mirror.status,
    expires_at: expiresAt,
    __nexride_from_offer_queue: true,
  };
}

async function fanOutDeliveryOffersIfEligible(db, deliveryId, row) {
  const rid = normUid(deliveryId);
  const customerId = normUid(row.customer_id);
  const market = ride.canonicalDispatchMarket(row.market_pool ?? row.market ?? "");
  if (!rid || !market || !customerId) {
    console.log("DELIVERY_FANOUT_ABORT", `deliveryId=${rid}`, "reason=bad_ids_or_market");
    return;
  }
  if (!paymentAllowsDispatchDelivery(row)) {
    console.log("DELIVERY_FANOUT_ABORT", `deliveryId=${rid}`, "reason=payment_blocked");
    return;
  }
  console.log("DELIVERY_FANOUT_START", `deliveryId=${rid}`, `market=${market}`);

  const gates = await loadDispatchGates(db);
  const pickup = row.pickup && typeof row.pickup === "object" ? row.pickup : {};
  const dropoff = row.dropoff && typeof row.dropoff === "object" ? row.dropoff : null;
  const now = nowMs();
  const expiresAt = now + DELIVERY_SEARCH_TTL_MS;
  let offersWritten = 0;
  let scanCount = 0;

  const driversSnap = await db.ref("drivers").orderByChild("dispatch_market").equalTo(market).get();
  const raw = driversSnap.val();
  if (!raw || typeof raw !== "object") {
    console.log("DELIVERY_DRIVER_SCAN_COUNT", "count=0");
    return;
  }
  const entries = Object.entries(raw);
  scanCount = entries.length;
  console.log("DELIVERY_DRIVER_SCAN_COUNT", `count=${scanCount}`);

  for (const [driverId, profile] of entries) {
    const d = normUid(driverId);
    if (!d || !profile || typeof profile !== "object") continue;
    const activeSvc = profile.active_services;
    const canDelivery =
      Array.isArray(activeSvc) &&
      activeSvc.some((x) => String(x).trim().toLowerCase() === "dispatch_delivery");
    if (!canDelivery) {
      console.log("DELIVERY_DRIVER_FILTERED", `uid=${d}`, "reason=no_dispatch_delivery_service");
      continue;
    }
    const el = evaluateDriverForOffer(profile, gates, {
      ...row,
      service_type: "dispatch_delivery",
      market_pool: market,
      market,
    });
    if (!el.ok) {
      console.log("DELIVERY_DRIVER_FILTERED", `uid=${d}`, `reason=${el.log || "gate"}`);
      continue;
    }
    const geo = evaluateDriverGeoAndMode(profile, { ...row, market_pool: market, market }, now);
    logMatchLocationSource(logger, d, profile, { ...row, market_pool: market, market }, geo, now);
    if (!geo.ok) {
      console.log(
        "DELIVERY_DRIVER_FILTERED",
        `uid=${d}`,
        `reason=${geo.log || "geo"}:${geo.detail || ""}`,
      );
      continue;
    }
    const busyGuard = await resolveDeliveryBusyGuardForDriver(
      db,
      d,
      rid,
      "delivery_offer_write",
    );
    if (busyGuard.busy) {
      console.log(
        "DELIVERY_DRIVER_FILTERED",
        `uid=${d}`,
        "reason=driver_busy",
        `blockingTripId=${busyGuard.blockingTripId || ""}`,
      );
      continue;
    }
    console.log("DELIVERY_DRIVER_ELIGIBLE", `uid=${d}`);
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
      console.log("DELIVERY_OFFER_WRITE_SUCCESS", `path=${qPath}`);
      offersWritten += 1;
    } catch (e) {
      const msg = e && typeof e === "object" && "message" in e ? String(e.message) : String(e);
      console.log("DELIVERY_OFFER_WRITE_FAIL", `path=${qPath}`, `error=${msg}`);
    }
  }
  const offerDeliveryStatus =
    offersWritten > 0 ? "offers_sent" : "no_eligible_drivers";
  await db.ref(`delivery_requests/${rid}/match_debug`).set({
    offers_written: offersWritten,
    offer_delivery_status: offerDeliveryStatus,
    payment_status: String(row.payment_status ?? "").trim().toLowerCase() || null,
    payment_reference:
      String(row.payment_reference ?? row.customer_transaction_reference ?? "").trim() ||
      null,
    checked_at: now,
    updated_at: now,
  });
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

function buildDeliveryAcceptAssignmentPatch(driverId, now, opts = {}) {
  const d = normUid(driverId);
  const mirror = deliveryUiMirrorFields(DELIVERY_STATE.driver_assigned, d);
  return {
    delivery_state: DELIVERY_STATE.driver_assigned,
    delivery_driver_id: d,
    driver_id: d,
    driverId: d,
    matched_driver_id: d,
    matchedDriverId: d,
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
  if (!paymentAllowsDispatchDelivery(current)) {
    return { action: "abort", reason: "payment_not_verified" };
  }
  const exp = Number(current.expires_at ?? current.request_expires_at ?? 0) || 0;
  if (exp > 0 && now > exp + 30_000) {
    return { action: "abort", reason: "offer_expired" };
  }
  return {
    action: "commit",
    patch: buildDeliveryAcceptAssignmentPatch(d, now, { useServerTimestamp: false }),
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
  if (merchantId) {
    u[`merchant_active_delivery/${merchantId}`] = { delivery_id: rid, updated_at: now };
  }
  await db.ref().update(u);
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
  console.log("DELIVERY_CREATE_START", customerId);

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
  if (recipientName.length < 2) {
    return { success: false, reason: "recipient_name_required" };
  }
  const recipientPhone = String(data?.recipient_phone ?? data?.recipientPhone ?? "").trim();
  if (recipientPhone.length < 8 || recipientPhone.length > 20) {
    return { success: false, reason: "recipient_phone_invalid" };
  }

  const category = String(data?.category ?? "parcel")
    .trim()
    .toLowerCase();
  if (!DELIVERY_CATEGORIES.has(category)) {
    return { success: false, reason: "invalid_category" };
  }

  const fare = Number(data?.fare ?? 0);
  if (!Number.isFinite(fare) || fare <= 0) {
    return { success: false, reason: "invalid_fare" };
  }
  if (fare > riderGates.max_fare_ngn) {
    return { success: false, reason: "fare_above_limit" };
  }

  const { computeRiderPricing, assertClientTotalMatches } = require("./pricing_calculator");
  const pricing = computeRiderPricing({
    flow: "dispatch_request",
    trip_fare_ngn: fare,
  });
  const totalMismatch = assertClientTotalMatches(pricing, data?.total_ngn ?? data?.totalNgn);
  if (!totalMismatch.ok) {
    return {
      success: false,
      reason: totalMismatch.reason,
      reason_code: totalMismatch.reason_code,
      message: totalMismatch.message,
      retryable: totalMismatch.retryable,
    };
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
  const mirror = deliveryUiMirrorFields(DELIVERY_STATE.searching, "");
  const row = {
    delivery_id: deliveryId,
    customer_id: customerId,
    rider_id: customerId,
    service_type: "dispatch_delivery",
    market,
    market_pool: market,
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
    fare,
    platform_fee_ngn: pricing.platform_fee_ngn,
    small_order_fee_ngn: pricing.small_order_fee_ngn,
    total_ngn: pricing.total_ngn,
    fee_breakdown: pricing.fee_breakdown,
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
  };

  await delRef.set(row);
  await db.ref(`user_active_delivery/${customerId}`).set({
    delivery_id: deliveryId,
    phase: "searching",
    updated_at: ts,
  });

  console.log("DELIVERY_CREATE_SUCCESS", deliveryId, market);
  await writeAudit(db, {
    type: "delivery_create",
    delivery_id: deliveryId,
    customer_id: customerId,
    actor_uid: customerId,
  });

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
  if (!paymentAllowsDispatchDelivery(pre)) {
    return { success: false, reason: "payment_not_verified" };
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
  await clearDeliveryFanoutAndOffers(db, deliveryId, driverId);
  await setActiveDeliveryPointers(db, deliveryId, customerId, driverId, next);
  await ensureDeliveryChatMeta(db, deliveryId, customerId, driverId, next);

  try {
    await sendPushToUser(db, customerId, {
      notification: {
        title: "Driver assigned",
        body: "A driver accepted your delivery request.",
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

  console.log("DELIVERY_ACCEPT_SUCCESS", deliveryId, driverId);
  return { success: true, reason: "accepted", accept_win_path: committed ? "transaction" : "direct" };
}

async function notifyDeliveryLifecyclePush(db, deliveryId, row, nextState) {
  const customerId = normUid(row.customer_id);
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
  const ticketId = `delivery_report__${deliveryId}__${reportId || nowMs()}`;
  const ticketRef = db.ref(`support_tickets/${ticketId}`);
  if ((await ticketRef.get()).exists()) {
    return { success: true, idempotent: true, ticketId };
  }
  const now = nowMs();
  await ticketRef.set({
    ticket_id: ticketId,
    delivery_id: deliveryId,
    ride_id: deliveryId,
    report_id: reportId || null,
    category: "delivery_report",
    subject: `Delivery report: ${reason}`,
    message,
    reporter_id: normUid(context.auth.uid),
    reporter_role: reporterRole,
    customer_id: normUid(row.customer_id),
    driver_id: canonicalAssignedDeliveryDriverId(row) || null,
    merchant_id: normUid(row.merchant_id ?? row.merchantId) || null,
    payment_status: row.payment_status ?? null,
    delivery_state: normalizeDeliveryState(row.delivery_state),
    assignment_status: "unassigned",
    status: "open",
    priority: "normal",
    created_at: now,
    updated_at: now,
    chat_path: `delivery_chats/${deliveryId}/messages`,
  });
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

  if (nextState === DELIVERY_STATE.completed) {
    if (!deliveryHasVerifiedOnlinePayment(cur)) {
      return { success: false, reason: "payment_not_verified" };
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

  const updates = {};
  if (TERMINAL_DELIVERY.has(nextState)) {
    updates[`active_deliveries/${deliveryId}`] = null;
    updates[`user_active_delivery/${normUid(cur.customer_id)}`] = null;
    updates[`customer_active_delivery/${normUid(cur.customer_id)}`] = null;
    updates[`driver_active_delivery/${driverId}`] = null;
    const merchantId = normUid(cur.merchant_id ?? cur.merchantId);
    if (merchantId) {
      updates[`merchant_active_delivery/${merchantId}`] = null;
    }
  } else {
    updates[`active_deliveries/${deliveryId}/delivery_state`] = nextState;
    updates[`active_deliveries/${deliveryId}/updated_at`] = now;
  }
  if (Object.keys(updates).length) {
    await db.ref().update(updates);
  }

  await writeAudit(db, {
    type: "delivery_state_update",
    delivery_id: deliveryId,
    driver_id: driverId,
    delivery_state: nextState,
    actor_uid: driverId,
  });

  await notifyDeliveryLifecyclePush(db, deliveryId, nextRow, nextState);

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
  await clearDeliveryFanoutAndOffers(db, deliveryId, "");
  await db.ref(`user_active_delivery/${customerId}`).remove();
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
  const customerId = normUid(row.customer_id);
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
  if (isCustomer) {
    const allowed =
      ds === DELIVERY_STATE.searching ||
      ds === DELIVERY_STATE.driver_assigned ||
      ds === DELIVERY_STATE.driver_arriving_pickup;
    if (!allowed) {
      return { success: false, reason: "cannot_cancel_at_stage" };
    }
  } else if (ds === DELIVERY_STATE.searching) {
    return { success: false, reason: "not_assigned" };
  }
  const now = nowMs();
  const mirror = deliveryUiMirrorFields(DELIVERY_STATE.cancelled, driverId || "");
  const cancelReason = String(data?.cancel_reason ?? data?.cancelReason ?? "user_cancelled").slice(
    0,
    200,
  );
  await ref.set({
    ...row,
    delivery_state: DELIVERY_STATE.cancelled,
    trip_state: mirror.trip_state,
    status: mirror.status,
    cancelled_at: now,
    cancel_reason: cancelReason,
    updated_at: now,
  });
  await clearDeliveryFanoutAndOffers(db, deliveryId, isDriver ? uid : "");
  const u = {};
  u[`active_deliveries/${deliveryId}`] = null;
  u[`user_active_delivery/${customerId}`] = null;
  if (driverId) {
    u[`driver_active_delivery/${driverId}`] = null;
  }
  await db.ref().update(u);
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
  paymentAllowsDispatchDelivery,
  resolveDeliveryBusyGuardForDriver,
  DELIVERY_SEARCH_TTL_MS,
  deliverySearchExpiryFields,
  refreshDeliverySearchExpiryForVerifiedFanout,
  fanOutDeliveryOffersAfterVerifiedPayment,
  clearDeliveryFanoutAndOffers,
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
  driverNearPickup,
  driverNearDropoff,
};
