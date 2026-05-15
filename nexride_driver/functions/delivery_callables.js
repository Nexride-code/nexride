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
const { evaluateDriverForOffer, evaluateDriverGeoAndMode, loadDispatchGates } = require("./driver_dispatch_gates");
const ride = require("./ride_callables");
const riderFirestoreIdentity = require("./rider_firestore_identity");
const { sendPushToUser } = require("./push_notifications");
const deliveryRegions = require("./ecosystem/delivery_regions");

const MAX_FARE_NGN_DEFAULT = 25_000_000;
const MIN_LAT_NG = 4.2;
const MAX_LAT_NG = 13.75;
const MIN_LNG_NG = 2.53;
const MAX_LNG_NG = 14.73;

const DELIVERY_STATE = {
  searching: "searching",
  accepted: "accepted",
  enroute_pickup: "enroute_pickup",
  arrived_pickup: "arrived_pickup",
  picked_up: "picked_up",
  enroute_dropoff: "enroute_dropoff",
  arrived_dropoff: "arrived_dropoff",
  delivered: "delivered",
  completed: "completed",
  cancelled: "cancelled",
};

const TERMINAL_DELIVERY = new Set([DELIVERY_STATE.completed, DELIVERY_STATE.cancelled]);

const DELIVERY_CATEGORIES = new Set(["parcel", "food", "document", "grocery", "other"]);

const PAYMENT_METHODS_ALLOWED = new Set([
  "card",
  "credit_card",
  "creditcard",
  "debit_card",
  "flutterwave",
  "bank_transfer",
]);

/** Driver-only linear progression after accept. */
const DRIVER_DELIVERY_NEXT = {
  [DELIVERY_STATE.accepted]: DELIVERY_STATE.enroute_pickup,
  [DELIVERY_STATE.enroute_pickup]: DELIVERY_STATE.arrived_pickup,
  [DELIVERY_STATE.arrived_pickup]: DELIVERY_STATE.picked_up,
  [DELIVERY_STATE.picked_up]: DELIVERY_STATE.enroute_dropoff,
  [DELIVERY_STATE.enroute_dropoff]: DELIVERY_STATE.arrived_dropoff,
  [DELIVERY_STATE.arrived_dropoff]: DELIVERY_STATE.delivered,
};

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
  return deliveryHasVerifiedOnlinePayment(row);
}

/**
 * Mirror minimal ride-shaped fields so driver discovery UI can reuse pickup/status checks.
 */
function deliveryUiMirrorFields(deliveryState, driverId) {
  const s = String(deliveryState ?? "").trim().toLowerCase();
  const d = normUid(driverId);
  const assigned = d || null;
  if (s === DELIVERY_STATE.searching) {
    return { trip_state: "searching", status: "searching", driver_id: "waiting", matched_driver_id: null };
  }
  if (s === DELIVERY_STATE.accepted) {
    return { trip_state: "accepted", status: "accepted", driver_id: assigned, matched_driver_id: assigned };
  }
  if (s === DELIVERY_STATE.enroute_pickup) {
    return { trip_state: "driver_arriving", status: "arriving", driver_id: assigned, matched_driver_id: assigned };
  }
  if (s === DELIVERY_STATE.arrived_pickup) {
    return { trip_state: "arrived", status: "arrived", driver_id: assigned, matched_driver_id: assigned };
  }
  if (
    s === DELIVERY_STATE.picked_up ||
    s === DELIVERY_STATE.enroute_dropoff ||
    s === DELIVERY_STATE.arrived_dropoff ||
    s === DELIVERY_STATE.delivered
  ) {
    return { trip_state: "in_progress", status: "on_trip", driver_id: assigned, matched_driver_id: assigned };
  }
  if (s === DELIVERY_STATE.completed) {
    return { trip_state: "completed", status: "completed", driver_id: assigned, matched_driver_id: assigned };
  }
  if (s === DELIVERY_STATE.cancelled) {
    return { trip_state: "cancelled", status: "cancelled", driver_id: assigned, matched_driver_id: assigned };
  }
  return { trip_state: "searching", status: "searching", driver_id: "waiting", matched_driver_id: null };
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
  const ds = String(prev.delivery_state ?? "").trim().toLowerCase();
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
  const expiresAt = now + 180000;
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
    if (!geo.ok) {
      console.log(
        "DELIVERY_DRIVER_FILTERED",
        `uid=${d}`,
        `reason=${geo.log || "geo"}:${geo.detail || ""}`,
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
  console.log("DELIVERY_FANOUT_DONE", `deliveryId=${rid}`, `offersWritten=${offersWritten}`);
}

async function setActiveDeliveryPointers(db, deliveryId, customerId, driverId, row) {
  const rid = normUid(deliveryId);
  const c = normUid(customerId);
  const d = normUid(driverId);
  const now = nowMs();
  const summary = {
    delivery_id: rid,
    customer_id: c,
    driver_id: d,
    market_pool: row.market_pool ?? row.market,
    delivery_state: DELIVERY_STATE.accepted,
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
  u[`user_active_delivery/${c}`] = { delivery_id: rid, phase: "active", updated_at: now };
  u[`driver_active_delivery/${d}`] = { delivery_id: rid, updated_at: now };
  await db.ref().update(u);
}

function isPlaceholderDriverId(v) {
  if (v == null || v === undefined) return true;
  const s = String(v).trim().toLowerCase();
  return s.length === 0 || s === "waiting" || s === "pending" || s === "null";
}

function canonicalAssignedDriver(row) {
  if (!row || typeof row !== "object") return "";
  const raw = row.driver_id ?? row.driverId;
  if (isPlaceholderDriverId(raw)) return "";
  const c = normUid(row.customer_id);
  const d = normUid(raw);
  if (c && d === c) return "";
  return d;
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

  const expiresAt = nowMs() + 180000;
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
  await fanOutDeliveryOffersIfEligible(db, deliveryId, row);
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
  let pre = (await ref.get()).val();
  if (!pre || typeof pre !== "object") {
    return { success: false, reason: "delivery_missing" };
  }
  if (normUid(pre.customer_id) === "") {
    return { success: false, reason: "invalid_delivery_payload" };
  }

  const customerId = normUid(pre.customer_id);
  const assigned = canonicalAssignedDriver(pre);
  const ds0 = String(pre.delivery_state ?? "").trim().toLowerCase();
  if (
    assigned === driverId &&
    (ds0 === DELIVERY_STATE.accepted ||
      ds0 === DELIVERY_STATE.enroute_pickup ||
      ds0 === DELIVERY_STATE.arrived_pickup ||
      ds0 === DELIVERY_STATE.picked_up)
  ) {
    return { success: true, idempotent: true, reason: "already_accepted" };
  }
  if (assigned && assigned !== driverId) {
    return { success: false, reason: "already_taken" };
  }
  if (ds0 !== DELIVERY_STATE.searching) {
    return { success: false, reason: "status_not_open" };
  }
  if (!paymentAllowsDispatchDelivery(pre)) {
    return { success: false, reason: "payment_not_verified" };
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
  const mirror = deliveryUiMirrorFields(DELIVERY_STATE.accepted, driverId);
  const next = {
    ...pre,
    delivery_state: DELIVERY_STATE.accepted,
    trip_state: mirror.trip_state,
    status: mirror.status,
    driver_id: driverId,
    matched_driver_id: driverId,
    accepted_at: now,
    updated_at: now,
  };

  await ref.set(next);
  await clearDeliveryFanoutAndOffers(db, deliveryId, driverId);
  await setActiveDeliveryPointers(db, deliveryId, customerId, driverId, next);

  await writeAudit(db, {
    type: "delivery_accept",
    delivery_id: deliveryId,
    driver_id: driverId,
    customer_id: customerId,
    actor_uid: driverId,
  });

  console.log("DELIVERY_ACCEPT_SUCCESS", deliveryId, driverId);
  return { success: true, reason: "accepted" };
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
  if (normUid(cur.driver_id) !== driverId) {
    return { success: false, reason: "not_assigned_driver" };
  }

  const current = String(cur.delivery_state ?? "").trim().toLowerCase();
  let nextState = DRIVER_DELIVERY_NEXT[current];
  if (explicit === DELIVERY_STATE.cancelled && current !== DELIVERY_STATE.completed) {
    nextState = DELIVERY_STATE.cancelled;
  }
  if (!nextState) {
    if (explicit === DELIVERY_STATE.completed && current === DELIVERY_STATE.delivered) {
      nextState = DELIVERY_STATE.completed;
    } else {
      return { success: false, reason: "invalid_transition" };
    }
  }

  if (explicit && explicit !== nextState && !(explicit === DELIVERY_STATE.completed && nextState === DELIVERY_STATE.completed)) {
    /** allow jump to completed only from delivered via explicit */
    if (!(explicit === DELIVERY_STATE.completed && current === DELIVERY_STATE.delivered)) {
      return { success: false, reason: "state_mismatch" };
    }
    nextState = DELIVERY_STATE.completed;
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
    updates[`driver_active_delivery/${driverId}`] = null;
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
  const ds = String(row.delivery_state ?? "").trim().toLowerCase();
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
  const driverRaw = row.driver_id ?? row.driverId;
  const driverId = isPlaceholderDriverId(driverRaw) ? "" : normUid(driverRaw);
  const isCustomer = customerId === uid;
  const isDriver = driverId === uid;
  if (!isCustomer && !isDriver) {
    return { success: false, reason: "forbidden" };
  }
  const ds = String(row.delivery_state ?? "").trim().toLowerCase();
  if (TERMINAL_DELIVERY.has(ds)) {
    return { success: false, reason: "already_terminal" };
  }
  if (isCustomer) {
    const allowed =
      ds === DELIVERY_STATE.searching ||
      ds === DELIVERY_STATE.accepted ||
      ds === DELIVERY_STATE.enroute_pickup ||
      ds === DELIVERY_STATE.arrived_pickup;
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
  deliveryUiMirrorFields,
  clearDeliveryFanoutAndOffers,
  createDeliveryRequest,
  createFoodDeliveryForMerchantOrder,
  acceptDeliveryRequest,
  updateDeliveryState,
  expireDeliveryRequest,
  cancelDeliveryRequest,
  fanOutDeliveryOffersIfEligible,
};
