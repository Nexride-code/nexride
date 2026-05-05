/**
 * NexRide ride lifecycle — server source of truth.
 * All sensitive ride_requests fields are written here (Admin SDK).
 */

const admin = require("firebase-admin");
const { platformFeeNgn } = require("./params");
const { syncRideTrackPublic } = require("./track_public");
const { isNexRideAdmin } = require("./admin_auth");
const { createWalletTransactionInternal } = require("./wallet_core");
const { ServerValue } = require("firebase-admin/database");
const {
  evaluateDriverForOffer,
  evaluateDriverForOfferSoft,
  loadDispatchGates,
  summarizeDriverForFanout,
} = require("./driver_dispatch_gates");
const { ensureRideChatThread } = require("./ride_chat_admin");

const TRIP_STATE = {
  searching: "searching",
  /** Post-accept canonical (production backend-controlled match). */
  accepted: "accepted",
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

/** Normalize Firebase push-id style keys (trim, unicode dash → ASCII "-"). */
function normalizeFirebasePushIdKey(raw) {
  let s = String(raw ?? "").trim();
  if (!s) return "";
  s = s.replace(/[\u2013\u2014\u2212]/g, "-");
  return s.trim();
}

/**
 * Resolve ride id from callable payloads (camelCase, snake_case, legacy keys).
 * @param {Record<string, unknown>|null|undefined} data
 */
function normRideIdFromCallableData(data) {
  const v =
    data?.rideId ??
    data?.ride_id ??
    data?.rideID ??
    data?.RIDE_ID ??
    data?.requestId ??
    data?.request_id ??
    data?.tripId ??
    data?.trip_id ??
    data?.tripID ??
    data?.rid;
  return normalizeFirebasePushIdKey(normUid(v));
}

/**
 * @param {Record<string, unknown>|null|undefined} data
 * @param {string} authUid
 */
function normDriverIdFromCallableData(data, authUid) {
  const v = data?.driverId ?? data?.driver_id ?? data?.uid;
  const fromBody = normUid(v);
  return fromBody || normUid(authUid);
}

function acceptPayloadLogString(data) {
  try {
    const s = JSON.stringify(data ?? {});
    return s.length > 6000 ? `${s.slice(0, 6000)}...(truncated)` : s;
  } catch {
    return String(data);
  }
}

/** @param {{ exists?: unknown }} snap */
function snapExists(snap) {
  if (snap == null) return false;
  if (typeof snap.exists === "function") {
    return snap.exists();
  }
  return Boolean(snap.exists);
}

/**
 * Canonical "ride document present" check: val() is a non-null object.
 * Prefer this over snap.exists alone so we never treat a malformed leaf as missing.
 * @param {import("firebase-admin/database").DataSnapshot|null|undefined} snap
 * @returns {object|null}
 */
function rideDocFromSnapshot(snap) {
  if (snap == null) return null;
  const v = snap.val();
  if (v == null || typeof v !== "object") return null;
  return v;
}

/**
 * Map internal accept failures to API reasons. Never surface ride_missing when
 * we already proved ride_requests/{id} holds a ride object (avoids false "missing").
 * @param {string} internal
 * @param {boolean} preflightDocPresent
 */
function surfaceAcceptFailureReason(internal, preflightDocPresent) {
  if (
    preflightDocPresent &&
    (internal === "ride_missing" || internal === "tx_empty_current")
  ) {
    return "not_available";
  }
  return internal;
}

/**
 * When the RTDB transaction returns empty `current` intermittently, apply the same
 * accept fields via Admin `update` after a fresh read shows the ride still exists and is open.
 * @returns {Promise<{ ok: boolean, reason?: string, finalRide?: object|null, idempotent?: boolean }>}
 */
async function applyDriverAcceptAdminMerge(rideRef, rideId, driverId, now) {
  const snap = await rideRef.get();
  const pathExists = snapExists(snap);
  const cur = rideDocFromSnapshot(snap);
  console.log(
    "DRIVER_ACCEPT_MERGE_PREFLIGHT",
    `rideId=${rideId}`,
    `exists=${pathExists}`,
    "trip_state=",
    cur ? String(cur.trip_state ?? "").trim().toLowerCase() : "n/a",
    "status=",
    cur ? String(cur.status ?? "").trim().toLowerCase() : "n/a",
  );
  if (!pathExists) {
    return { ok: false, reason: "ride_missing" };
  }
  if (!cur) {
    return { ok: false, reason: "not_available" };
  }
  if (!paymentAllowsDispatch(cur)) {
    return { ok: false, reason: "payment_not_verified" };
  }
  const tripState = String(cur.trip_state ?? "").trim().toLowerCase();
  const status = String(cur.status ?? "").trim().toLowerCase();
  const assignedCanon = canonicalAssignedDriverId(cur);
  const already =
    assignedCanon === driverId &&
    (tripState === TRIP_STATE.accepted ||
      tripState === TRIP_STATE.driver_assigned ||
      tripState === "driver_accepted" ||
      status === "accepted");
  if (already) {
    return { ok: true, finalRide: cur, idempotent: true };
  }
  if (assignedCanon && assignedCanon !== driverId) {
    return { ok: false, reason: "driver_already_set" };
  }
  const openByTrip = isOpenPoolRide(cur);
  const openByStatus = ACCEPTABLE_OPEN_STATUS.has(status);
  if (!openByTrip && !openByStatus) {
    return { ok: false, reason: "status_not_open" };
  }
  const expiresAt = Number(cur.expires_at ?? cur.request_expires_at ?? 0) || 0;
  if (expiresAt > 0 && now >= expiresAt) {
    return { ok: false, reason: "expired" };
  }
  await rideRef.update({
    driver_id: driverId,
    matched_driver_id: driverId,
    accepted_driver_id: driverId,
    status: "accepted",
    trip_state: TRIP_STATE.accepted,
    accepted_at: ServerValue.TIMESTAMP,
    updated_at: now,
  });
  const postSnap = await rideRef.get();
  const post = rideDocFromSnapshot(postSnap) ?? cur;
  return { ok: true, finalRide: post, idempotent: false };
}

/** Single canonical dispatch key shared by ride_requests.market_pool and drivers.dispatch_market. */
function canonicalDispatchMarket(raw) {
  return String(raw ?? "")
    .trim()
    .toLowerCase()
    .replace(/\s+/g, "_")
    .replace(/-+/g, "_");
}

function nowMs() {
  return Date.now();
}

function sleepMs(ms) {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
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
    s === "null" ||
    s === "none" ||
    s === "unassigned" ||
    s === "n/a" ||
    s === "tbd"
  );
}

/**
 * Canonical assigned driver on `ride_requests` for accept / conflict checks.
 * Ignores placeholders, camelCase alias, and corrupt values where driver_id === rider_id.
 */
function canonicalAssignedDriverId(ride) {
  if (!ride || typeof ride !== "object") {
    return "";
  }
  const rider = normUid(ride.rider_id ?? ride.riderId);
  const raw = ride.driver_id ?? ride.driverId;
  if (isPlaceholderDriverId(raw)) {
    return "";
  }
  const d = normUid(raw);
  if (!d) {
    return "";
  }
  if (rider && d === rider) {
    return "";
  }
  return d;
}

function isOpenPoolRide(ride) {
  const ts = String(ride.trip_state ?? "").trim().toLowerCase();
  const st = String(ride.status ?? "").trim().toLowerCase();
  if (TRIP_STATE.searching === ts) return true;
  if (LEGACY_OPEN_TRIP_STATES.has(ts)) return true;
  if (LEGACY_OPEN_STATUS.has(st)) return true;
  return false;
}

/**
 * Driver matching / fanout / accept only after Flutterwave (or equivalent) charge is verified server-side.
 * Cash and unverified card are not permitted for dispatch.
 */
function paymentAllowsDispatch(ride) {
  if (!ride || typeof ride !== "object") {
    return false;
  }
  const ps = String(ride.payment_status ?? ride.paymentStatus ?? "")
    .trim()
    .toLowerCase();
  if (ps !== "verified") {
    return false;
  }
  const ptid = String(ride.payment_transaction_id ?? ride.flw_tx_id ?? "").trim();
  return Boolean(ptid);
}

/** True when ride has a recorded verified online payment (required before trip completion). */
function rideHasVerifiedOnlinePayment(ride) {
  if (!ride || typeof ride !== "object") return false;
  const ps = String(ride.payment_status ?? ride.paymentStatus ?? "")
    .trim()
    .toLowerCase();
  const ptid = String(ride.payment_transaction_id ?? ride.flw_tx_id ?? "").trim();
  return ps === "verified" && Boolean(ptid);
}

const ACCEPTABLE_OPEN_STATUS = new Set([
  "searching",
  "requesting",
  "matching",
  "awaiting_match",
  "pending_driver_acceptance",
]);

const PAYMENT_METHODS_ALLOWED = new Set([
  "card",
  "credit_card",
  "creditcard",
  "debit_card",
  "flutterwave",
  "bank_transfer",
]);

const MAX_FARE_NGN_DEFAULT = 25_000_000;
const MIN_LAT_NG = 4.2;
const MAX_LAT_NG = 13.75;
const MIN_LNG_NG = 2.53;
const MAX_LNG_NG = 14.73;

/** @param {object|null|undefined} o */
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

/**
 * When require_users_node is explicitly enabled, ensure users/{uid} exists.
 * Riders often have Firebase Auth but no RTDB profile yet; provisioning avoids
 * false "please sign in again" UX while keeping an explicit audit trail row.
 *
 * @param {import("firebase-admin").database.Database} db
 * @param {string} riderId
 * @param {{ require_riders_users_node: boolean }} gates
 * @param {{ token?: Record<string, unknown> }} [authLike]
 */
async function riderProfileRequirementOk(db, riderId, gates, authLike) {
  if (!gates.require_riders_users_node) {
    return true;
  }
  const uid = normUid(riderId);
  const ref = db.ref(`users/${uid}`);
  const snap = await ref.get();
  if (snap.exists()) {
    return true;
  }
  const token = authLike?.token;
  if (!token || typeof token !== "object") {
    return false;
  }
  try {
    const email = String(token.email ?? "").trim();
    const name = String(token.name ?? "").trim();
    const displayName =
      name || (email ? email.split("@")[0] : "") || "Rider";
    await ref.set({
      uid,
      role: "rider",
      ...(email ? { email } : {}),
      displayName,
      created_at: Date.now(),
      provisioned_via: "nexride_rider_callable",
    });
    return true;
  } catch (e) {
    console.warn(
      "RIDER_USER_PROVISION_FAIL",
      uid,
      e && typeof e === "object" && "message" in e ? e.message : e,
    );
    return false;
  }
}

async function clearFanoutAndOffers(db, rideId, alsoDriverId = "") {
  const rid = normUid(rideId);
  if (!rid) return;
  const updates = {};
  const d0 = normUid(alsoDriverId);
  if (d0) {
    updates[`driver_offer_queue/${d0}/${rid}`] = null;
    updates[`driver_offer_queue_debug/${d0}/${rid}`] = null;
  }
  const snap = await db.ref(`ride_offer_fanout/${rid}`).get();
  const val = snap.val();
  if (val && typeof val === "object") {
    for (const driverId of Object.keys(val)) {
      const d = normUid(driverId);
      if (!d) continue;
      updates[`driver_offer_queue/${d}/${rid}`] = null;
      updates[`driver_offer_queue_debug/${d}/${rid}`] = null;
      updates[`ride_offer_fanout/${rid}/${d}`] = null;
    }
  }
  if (Object.keys(updates).length) {
    await db.ref().update(updates);
  }
}

async function loadRiderCreateGates(db) {
  try {
    const snap = await db.ref("app_config/nexride_rider").get();
    const v = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
    const maxFare = Number(v.max_fare_ngn ?? MAX_FARE_NGN_DEFAULT);
    return {
      /** Opt-in: only block when app_config sets require_users_node === true */
      require_riders_users_node: v.require_users_node === true,
      max_fare_ngn: Number.isFinite(maxFare) && maxFare > 0 ? maxFare : MAX_FARE_NGN_DEFAULT,
      require_ng_pickup: v.require_pickup_in_nigeria_bbox !== false,
    };
  } catch (_) {
    return {
      require_riders_users_node: false,
      max_fare_ngn: MAX_FARE_NGN_DEFAULT,
      require_ng_pickup: true,
    };
  }
}

/** True when client session flags say the driver is on-session (Flutter / RTDB). */
function driverSessionPresenceOnline(profile) {
  const p = profile && typeof profile === "object" ? profile : {};
  return (
    p.isOnline === true || p.is_online === true || p.online === true
  );
}

/**
 * Dispatch availability — aligned with driver GO ONLINE, but session presence
 * (is_online / online) wins over a stale legacy `status: offline` string.
 */
function driverAvailabilityGate(profile) {
  const p = profile && typeof profile === "object" ? profile : {};
  const dispatchState = String(p.dispatch_state ?? "").trim().toLowerCase();
  if (dispatchState && dispatchState !== "available") {
    return { ok: false, reason: `dispatch_state_not_available:${dispatchState}` };
  }
  if (driverSessionPresenceOnline(p)) {
    return { ok: true };
  }
  const status = String(p.status ?? "").trim().toLowerCase();
  if (status && status !== "available") {
    return { ok: false, reason: `status_not_available:${status}` };
  }
  return { ok: true };
}

function addressFromPlace(o) {
  if (!o || typeof o !== "object") return "";
  return String(o.address ?? o.formatted_address ?? o.description ?? "").trim();
}

function buildFanoutOfferPayload({
  rid,
  riderId,
  driverUid,
  market,
  ridePayload,
  pickup,
  dropoff,
  now,
  expiresAt,
}) {
  const fare = Number(ridePayload.fare ?? 0) || 0;
  const distanceKm = Number(ridePayload.distance_km ?? ridePayload.distanceKm ?? 0) || 0;
  const etaMin = Number(ridePayload.eta_min ?? ridePayload.etaMin ?? 0) || 0;
  const pickupAddr =
    addressFromPlace(pickup) ||
    String(ridePayload.pickup_address ?? "").trim() ||
    "";
  const dropAddr =
    addressFromPlace(dropoff) ||
    String(
      ridePayload.dropoff_address ??
        ridePayload.destination_address ??
        ridePayload.final_destination_address ??
        "",
    ).trim() ||
    "";
  return {
    ride_id: rid,
    rider_id: riderId || null,
    driver_id: driverUid,
    status: "open",
    market,
    market_pool: market,
    created_at: now,
    expires_at: expiresAt,
    pickup_address: pickupAddr || null,
    dropoff_address: dropAddr || null,
    fare,
    distance_km: distanceKm,
    eta_minutes: etaMin,
    currency: String(ridePayload.currency ?? "NGN").trim().toUpperCase() || "NGN",
    service_type: String(ridePayload.service_type ?? "ride").trim(),
    payment_method: String(ridePayload.payment_method ?? "").trim().toLowerCase(),
    payment_status: String(ridePayload.payment_status ?? "").trim().toLowerCase(),
    pickup,
    dropoff,
    trip_state: TRIP_STATE.searching,
    request_status: "searching",
  };
}

async function writeDriverOfferPaths(db, rid, riderId, d, market, ridePayload, pickup, dropoff, now, expiresAt) {
  const payload = buildFanoutOfferPayload({
    rid,
    riderId,
    driverUid: d,
    market,
    ridePayload,
    pickup,
    dropoff,
    now,
    expiresAt,
  });
  const qPath = `driver_offer_queue/${d}/${rid}`;
  console.log("OFFER_WRITE_START", `path=${qPath}`);
  try {
    await db.ref().update({
      [`ride_offer_fanout/${rid}/${d}`]: true,
      [`driver_offer_queue/${d}/${rid}`]: payload,
      [`driver_offer_queue_debug/${d}/${rid}`]: payload,
    });
    console.log("OFFER_WRITE_SUCCESS", `path=${qPath}`);
    return true;
  } catch (e) {
    const msg = e && typeof e === "object" && "message" in e ? String(e.message) : String(e);
    console.log("OFFER_WRITE_FAIL", `path=${qPath}`, `error=${msg}`);
    return false;
  }
}

async function fanOutDriverOffersIfEligible(db, rideId, ridePayload) {
  const rid = normUid(rideId);
  const riderId = normUid(ridePayload.rider_id ?? ridePayload.riderId);
  const market = canonicalDispatchMarket(
    ridePayload.market_pool ?? ridePayload.market ?? "",
  );
  if (!rid || !market) {
    console.log(
      "MATCH_FANOUT_ABORT",
      `rideId=${rid || "(empty)"}`,
      `market=${market || "(empty)"}`,
      "reason=bad_ride_or_market",
    );
    return;
  }
  if (!paymentAllowsDispatch(ridePayload)) {
    console.log(
      "MATCH_FANOUT_ABORT",
      `rideId=${rid}`,
      `market=${market}`,
      "reason=payment_not_allowed_for_dispatch",
    );
    return;
  }
  const svc = String(ridePayload.service_type ?? "ride").trim().toLowerCase();
  if (svc !== "ride") {
    console.log(
      "MATCH_FANOUT_ABORT",
      `rideId=${rid}`,
      `service_type=${svc}`,
      "reason=phase1_ride_only",
    );
    return;
  }
  console.log("MATCH_FANOUT_START", `rideId=${rid}`, `market=${market}`);

  const gates = await loadDispatchGates(db);
  const useSoft = Boolean(gates.soft_verification);

  const pickup = ridePayload.pickup && typeof ridePayload.pickup === "object" ? ridePayload.pickup : {};
  const dropoff =
    ridePayload.dropoff && typeof ridePayload.dropoff === "object" ? ridePayload.dropoff : null;
  const now = nowMs();
  const expiresAt = now + 180000;

  const writtenUids = new Set();
  let offersWritten = 0;

  async function tryOfferDriver(driverId, profile) {
    const d = normUid(driverId);
    if (!d || !profile || typeof profile !== "object") {
      return;
    }
    if (writtenUids.has(d)) {
      return;
    }
    const snap = summarizeDriverForFanout(d, profile);
    console.log(
      "MATCH_DRIVER_CANDIDATE",
      `uid=${snap.uid}`,
      `dispatch_market=${snap.dispatch_market}`,
      `online=${snap.online}`,
      `status=${snap.status}`,
      `dispatch_state=${snap.dispatch_state}`,
    );

    if (snap.suspended) {
      console.log("MATCH_DRIVER_FILTERED", `uid=${d}`, "reason=suspended");
      return;
    }

    if (useSoft) {
      const softEl = evaluateDriverForOfferSoft(profile, ridePayload);
      if (!softEl.ok) {
        const reason = `${softEl.log || "filtered"}:${softEl.detail || "unknown"}`;
        console.log("MATCH_DRIVER_FILTERED", `uid=${d}`, `reason=${reason}`);
        return;
      }
    } else {
      if (!snap.online) {
        console.log("MATCH_DRIVER_FILTERED", `uid=${d}`, "reason=not_online");
        return;
      }
      const avail = driverAvailabilityGate(profile);
      if (!avail.ok) {
        console.log("MATCH_DRIVER_FILTERED", `uid=${d}`, `reason=${avail.reason}`);
        return;
      }
      const eligibility = evaluateDriverForOffer(profile, gates, ridePayload);
      if (!eligibility.ok) {
        const reason = `${eligibility.log || "filtered"}:${eligibility.detail || "unknown"}`;
        console.log("MATCH_DRIVER_FILTERED", `uid=${d}`, `reason=${reason}`);
        return;
      }
    }

    console.log("MATCH_DRIVER_ELIGIBLE", `uid=${d}`);
    const ok = await writeDriverOfferPaths(
      db,
      rid,
      riderId,
      d,
      market,
      ridePayload,
      pickup,
      dropoff,
      now,
      expiresAt,
    );
    if (ok) {
      writtenUids.add(d);
      offersWritten += 1;
    }
  }

  const driversSnap = await db
    .ref("drivers")
    .orderByChild("dispatch_market")
    .equalTo(market)
    .once("value");
  const raw = driversSnap.val() || {};
  const scanCount = Object.keys(raw).length;
  console.log("MATCH_DRIVER_SCAN_COUNT", `count=${scanCount}`);
  if (scanCount === 0) {
    console.log(
      "MATCH_FANOUT_HINT",
      "no_drivers_in_query",
      `dispatch_market_index_empty_for_market=${market}`,
      "ensure_drivers/{uid}/dispatch_market matches ride market (canonical slug)",
    );
  }

  for (const [driverId, profile] of Object.entries(raw)) {
    await tryOfferDriver(driverId, profile);
  }

  if (useSoft && offersWritten === 0) {
    const allSnap = await db.ref("drivers").once("value");
    const allDrivers = allSnap.val() && typeof allSnap.val() === "object" ? allSnap.val() : {};
    const nAll = Object.keys(allDrivers).length;
    console.log("MATCH_FANOUT_HINT", `full_driver_tree_scan rideId=${rid} keys=${nAll}`);
    for (const [driverId, profile] of Object.entries(allDrivers)) {
      await tryOfferDriver(driverId, profile);
    }
  }

  if (offersWritten === 0) {
    await db.ref(`ride_requests/${rid}/match_debug`).set({
      offers_written: 0,
      reason: "no_eligible_drivers",
      checked_at: ServerValue.TIMESTAMP,
    });
  }

  console.log("MATCH_FANOUT_DONE", `rideId=${rid}`, `offersWritten=${offersWritten}`);

  if (offersWritten === 0 && !useSoft) {
    console.log(
      "MATCH_FANOUT_HINT",
      "verification_may_block_test_drivers",
      "set_RTDB_app_config/nexride_dispatch",
      "soft_verification=true",
      "require_bvn_verification=false",
    );
  }
}

/**
 * Ends the rider's previous open-pool search (if any) so a new request is the single active dispatch.
 * @returns {Promise<{ ok: true } | { ok: false, reason: string, rideId?: string }>}
 */
async function supersedePriorOpenRideForRider(db, riderId) {
  const r = normUid(riderId);
  if (!r) {
    return { ok: true };
  }
  const ptrSnap = await db.ref(`rider_active_ride/${r}`).get();
  if (!ptrSnap.exists()) {
    return { ok: true };
  }
  const ptr = ptrSnap.val() || {};
  const prevId = normUid(ptr.ride_id ?? ptr.rideId);
  if (!prevId) {
    await db.ref(`rider_active_ride/${r}`).remove();
    return { ok: true };
  }
  const prevRef = db.ref(`ride_requests/${prevId}`);
  const prevSnap = await prevRef.get();
  const prev = prevSnap.val();
  if (!prev || typeof prev !== "object" || normUid(prev.rider_id) !== r) {
    await db.ref(`rider_active_ride/${r}`).remove();
    return { ok: true };
  }
  const assignedRaw = prev.driver_id;
  if (!isPlaceholderDriverId(assignedRaw)) {
    return { ok: false, reason: "rider_active_trip", rideId: prevId };
  }
  const ts = String(prev.trip_state ?? "").trim().toLowerCase();
  if (
    ts === TRIP_STATE.completed ||
    ts === TRIP_STATE.cancelled ||
    ts === TRIP_STATE.expired ||
    ts === "trip_completed" ||
    ts === "trip_cancelled"
  ) {
    await db.ref(`rider_active_ride/${r}`).remove();
    return { ok: true };
  }
  if (!isOpenPoolRide(prev)) {
    return { ok: false, reason: "rider_active_trip", rideId: prevId };
  }
  let supersedeFail = "";
  const tx = await prevRef.transaction((cur) => {
    if (!cur || typeof cur !== "object") {
      supersedeFail = "missing";
      return;
    }
    if (normUid(cur.rider_id) !== r) {
      supersedeFail = "rider";
      return;
    }
    if (!isPlaceholderDriverId(cur.driver_id)) {
      supersedeFail = "claimed";
      return;
    }
    if (!isOpenPoolRide(cur)) {
      supersedeFail = "not_open";
      return;
    }
    const now = nowMs();
    return {
      ...cur,
      trip_state: TRIP_STATE.cancelled,
      status: "cancelled",
      cancelled_at: now,
      updated_at: now,
      cancel_reason: "superseded_by_new_request",
      cancel_actor: "system",
      cancelled_by: "rider_resubmit",
    };
  });
  if (!tx.committed) {
    if (supersedeFail === "claimed") {
      return { ok: false, reason: "rider_active_trip", rideId: prevId };
    }
    const fresh = (await prevRef.get()).val();
    if (
      fresh &&
      typeof fresh === "object" &&
      normUid(fresh.rider_id) === r &&
      isPlaceholderDriverId(fresh.driver_id) &&
      isOpenPoolRide(fresh)
    ) {
      return { ok: true };
    }
    return { ok: false, reason: "rider_active_trip", rideId: prevId };
  }
  await clearFanoutAndOffers(db, prevId);
  await db.ref(`rider_active_ride/${r}`).remove();
  await writeAudit(db, {
    type: "ride_supersede",
    ride_id: prevId,
    rider_id: r,
    actor_uid: r,
  });
  await syncRideTrackPublic(db, prevId);
  return { ok: true };
}

async function setActiveTripPointers(db, rideId, riderId, driverId, rideSummary) {
  const rid = normUid(rideId);
  const r = normUid(riderId);
  const d = normUid(driverId);
  if (!rid || !r || !d) {
    return;
  }
  const now = nowMs();
  const pickup =
    rideSummary && rideSummary.pickup && typeof rideSummary.pickup === "object"
      ? rideSummary.pickup
      : null;
  await db.ref().update({
    [`active_trips/${rid}`]: {
      ride_id: rid,
      rider_id: r,
      driver_id: d,
      status: "active",
      updated_at: now,
      trip_state: rideSummary?.trip_state ?? TRIP_STATE.accepted,
      market_pool: canonicalDispatchMarket(
        rideSummary?.market_pool ?? rideSummary?.market ?? "",
      ) || null,
      fare: Number(rideSummary?.fare ?? 0) || 0,
      currency:
        String(rideSummary?.currency ?? "NGN").trim().toUpperCase() || "NGN",
      payment_status: rideSummary?.payment_status ?? null,
      payment_method: rideSummary?.payment_method ?? null,
      pickup,
    },
    [`rider_active_ride/${r}`]: {
      ride_id: rid,
      phase: "accepted",
      updated_at: now,
    },
    [`driver_active_ride/${d}`]: { ride_id: rid, updated_at: now },
  });
  console.log("ACTIVE_TRIP_CREATED", rid, "rider=", r, "driver=", d);
  console.log("RIDER_ACTIVE_RIDE_UPDATED", r, "ride_id=", rid);
  console.log("DRIVER_ACTIVE_RIDE_UPDATED", d, "ride_id=", rid);
}

async function clearActiveTripPointers(db, rideId, riderId, driverId) {
  const rid = normUid(rideId);
  const r = normUid(riderId);
  const d = normUid(driverId);
  const u = {};
  if (rid) u[`active_trips/${rid}`] = null;
  if (r) u[`rider_active_ride/${r}`] = null;
  if (d) u[`driver_active_ride/${d}`] = null;
  if (Object.keys(u).length) {
    await db.ref().update(u);
  }
}

function legacyUiStatusForTripState(tripState) {
  switch (tripState) {
    case TRIP_STATE.searching:
      return "searching";
    case TRIP_STATE.accepted:
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
    console.log("RIDER_CREATE_FAIL", "unauthorized");
    return { success: false, reason: "unauthorized" };
  }
  const riderId = normUid(context.auth.uid);
  console.log("RIDER_CREATE_START", riderId);
  const riderGates = await loadRiderCreateGates(db);

  const bodyRider = normUid(data?.rider_id ?? data?.riderId);
  if (bodyRider && bodyRider !== riderId) {
    console.log("RIDER_CREATE_FAIL", riderId, "rider_mismatch");
    return { success: false, reason: "rider_mismatch" };
  }

  if (!(await riderProfileRequirementOk(db, riderId, riderGates, context.auth))) {
    console.log("RIDER_CREATE_FAIL", riderId, "no_user_profile");
    return { success: false, reason: "rider_profile_required" };
  }

  const marketRaw = data?.market ?? data?.city ?? "";
  const market = canonicalDispatchMarket(marketRaw);
  if (!market) {
    console.log("RIDER_CREATE_FAIL", riderId, "invalid_market");
    return { success: false, reason: "invalid_market" };
  }

  const supersede = await supersedePriorOpenRideForRider(db, riderId);
  if (!supersede.ok) {
    console.log("RIDER_CREATE_FAIL", riderId, supersede.reason || "rider_active_trip");
    return {
      success: false,
      reason: supersede.reason || "rider_active_trip",
      rideId: supersede.rideId,
    };
  }

  const pickup = data?.pickup;
  const dropoff = data?.dropoff;
  if (!pickup || typeof pickup !== "object") {
    console.log("RIDER_CREATE_FAIL", riderId, "invalid_pickup");
    return { success: false, reason: "invalid_pickup" };
  }

  const pCoord = coordsFromPickup(pickup);
  if (
    riderGates.require_ng_pickup &&
    !coordsInNgBox(pCoord.lat, pCoord.lng)
  ) {
    console.log("RIDER_CREATE_FAIL", riderId, "pickup_location_out_of_region");
    return { success: false, reason: "pickup_location_out_of_region" };
  }

  if (dropoff && typeof dropoff === "object") {
    const dCoord = coordsFromPickup(dropoff);
    if (
      riderGates.require_ng_pickup &&
      Number.isFinite(dCoord.lat) &&
      Number.isFinite(dCoord.lng) &&
      !coordsInNgBox(dCoord.lat, dCoord.lng)
    ) {
      console.log("RIDER_CREATE_FAIL", riderId, "dropoff_location_out_of_region");
      return { success: false, reason: "dropoff_location_out_of_region" };
    }
  }

  const fare = Number(data?.fare ?? 0);
  if (!Number.isFinite(fare) || fare <= 0) {
    console.log("RIDER_CREATE_FAIL", riderId, "invalid_fare");
    return { success: false, reason: "invalid_fare" };
  }
  if (fare > riderGates.max_fare_ngn) {
    console.log("RIDER_CREATE_FAIL", riderId, "fare_above_limit");
    return { success: false, reason: "fare_above_limit" };
  }

  const currency = String(data?.currency ?? "NGN").trim().toUpperCase() || "NGN";
  const paymentMethod = String(data?.payment_method ?? data?.paymentMethod ?? "flutterwave")
    .trim()
    .toLowerCase();
  const paymentNormalized = paymentMethod.replace(/[\s-]+/g, "_");
  if (!PAYMENT_METHODS_ALLOWED.has(paymentNormalized)) {
    console.log("RIDER_CREATE_FAIL", riderId, "unsupported_payment_method", paymentNormalized);
    return { success: false, reason: "unsupported_payment_method" };
  }

  const paymentStatus = "pending";

  const distanceKm = Number(data?.distance_km ?? data?.distanceKm ?? 0) || 0;
  const etaMin = Number(data?.eta_min ?? data?.etaMin ?? 0) || 0;
  if (!Number.isFinite(distanceKm) || distanceKm < 0 || distanceKm > 3500) {
    console.log("RIDER_CREATE_FAIL", riderId, "invalid_distance");
    return { success: false, reason: "invalid_distance" };
  }
  if (!Number.isFinite(etaMin) || etaMin < 0 || etaMin > 36 * 60) {
    console.log("RIDER_CREATE_FAIL", riderId, "invalid_eta");
    return { success: false, reason: "invalid_eta" };
  }
  const expiresAt = nowMs() + 180000;

  const rideRef = db.ref("ride_requests").push();
  const rideId = normUid(rideRef.key);
  if (!rideId) {
    console.log("RIDER_CREATE_FAIL", riderId, "ride_id_alloc_failed");
    return { success: false, reason: "ride_id_alloc_failed" };
  }

  const trackToken = normUid(db.ref().push().key);
  if (!trackToken) {
    console.log("RIDER_CREATE_FAIL", riderId, "track_token_alloc_failed");
    return { success: false, reason: "track_token_alloc_failed" };
  }

  const ts = nowMs();
  const payload = {
    ride_id: rideId,
    rider_id: riderId,
    driver_id: null,
    track_token: trackToken,
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
    payment_method: paymentNormalized,
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

  const RIDER_CREATE_METADATA_ALLOW = new Set([
    "stops",
    "stop_count",
    "rider_trust_snapshot",
    "route_basis",
    "pickup_address",
    "destination_address",
    "final_destination",
    "final_destination_address",
    "city",
    "country",
    "country_code",
    "area",
    "zone",
    "community",
    "pickup_area",
    "pickup_zone",
    "pickup_community",
    "destination_area",
    "destination_zone",
    "destination_community",
    "service_area",
    "pickup_scope",
    "destination_scope",
    "fare_breakdown",
    "requested_at",
    "search_timeout_at",
    "request_expires_at",
    "payment_context",
    "settlement_status",
    "support_status",
    "destination",
    "state_machine_version",
    "duration_min",
    "cancel_reason",
    "pricing_snapshot",
    "packagePhotoUrl",
    "packagePhotoSubmittedAt",
    "payment_placeholder",
    "search_started_at",
    "pickupConfirmedAt",
    "deliveredAt",
    "dispatch_details",
  ]);

  const md = data?.ride_metadata ?? data?.rideMetadata;
  if (md && typeof md === "object") {
    for (const [k, v] of Object.entries(md)) {
      if (!RIDER_CREATE_METADATA_ALLOW.has(k)) {
        continue;
      }
      payload[k] = v;
    }
  }

  await rideRef.set(payload);
  await db.ref(`rider_active_ride/${riderId}`).set({
    ride_id: rideId,
    phase: "searching",
    updated_at: ts,
  });
  console.log("RIDER_CREATE_SUCCESS", rideId, market);
  await fanOutDriverOffersIfEligible(db, rideId, payload);
  await writeAudit(db, {
    type: "ride_create",
    ride_id: rideId,
    rider_id: riderId,
    actor_uid: riderId,
  });

  await syncRideTrackPublic(db, rideId);

  return { success: true, rideId, trackToken, reason: "created" };
}

async function acceptRideRequest(data, context, db) {
  console.log("DRIVER_ACCEPT_CALL_RECEIVED");
  console.log("DRIVER_ACCEPT_PAYLOAD", acceptPayloadLogString(data));

  const rideId = normRideIdFromCallableData(data);
  const authUid = normUid(context.auth?.uid);
  const driverId = normDriverIdFromCallableData(data, authUid);

  let dbUrl = "";
  try {
    dbUrl = String(db.app?.options?.databaseURL ?? "");
  } catch (_) {
    dbUrl = "";
  }
  console.log("DRIVER_ACCEPT_DB_URL", dbUrl || "(default)");

  console.log("DRIVER_ACCEPT_START", rideId, driverId);

  if (!rideId || !driverId) {
    console.log("DRIVER_ACCEPT_FAIL_REASON", rideId || "(empty)", "invalid_input");
    return { success: false, reason: "invalid_input" };
  }
  if (!context.auth || authUid !== driverId) {
    console.log("DRIVER_ACCEPT_FAIL_REASON", rideId, "unauthorized");
    return { success: false, reason: "unauthorized" };
  }

  const rawKeys =
    data && typeof data === "object" && !Array.isArray(data)
      ? Object.keys(data).join(",")
      : "";
  console.log(
    "DRIVER_ACCEPT_INPUT",
    `rideId=${rideId}`,
    `driverId=${driverId}`,
    `rawKeys=${rawKeys}`,
  );

  const ridePath = `ride_requests/${rideId}`;
  const rideRef = db.ref(ridePath);
  console.log("DRIVER_ACCEPT_RIDE_LOOKUP_PATH", ridePath);

  let preSnap = await rideRef.get();
  let pre = rideDocFromSnapshot(preSnap);
  if (!pre && snapExists(preSnap)) {
    preSnap = await rideRef.get();
    pre = rideDocFromSnapshot(preSnap);
  }
  const readExists = snapExists(preSnap);
  /** Path exists at ride_requests/{id} — never surface ride_missing when this is true. */
  const preflightDocPresent = readExists;
  if (!pre && readExists) {
    console.log(
      "DRIVER_ACCEPT_READ_VAL_ANOMALY",
      `rideId=${rideId}`,
      "exists=true",
      "val_not_non_null_object",
    );
    pre = {};
  }
  const preTrip0 = pre && Object.keys(pre).length ? String(pre.trip_state ?? "").trim().toLowerCase() : "";
  const preStatus0 = pre && Object.keys(pre).length ? String(pre.status ?? "").trim().toLowerCase() : "";
  console.log(
    "DRIVER_ACCEPT_READ",
    `rideId=${rideId}`,
    `path=${ridePath}`,
    `exists=${readExists}`,
    `trip_state=${preTrip0}`,
    `status=${preStatus0}`,
  );
  if (!readExists) {
    console.log(
      "DRIVER_ACCEPT_FAIL_REASON",
      rideId,
      "ride_missing",
      "ride_path_missing",
    );
    return { success: false, reason: "ride_missing" };
  }

  const riderPrecheck = normUid(pre.rider_id ?? pre.riderId);
  if (!riderPrecheck) {
    console.log(
      "DRIVER_ACCEPT_RIDER_DEFER",
      `rideId=${rideId}`,
      "exists=true",
      "reason=rider_id_missing_preflight_tx_will_authorize",
    );
  }

  const preTrip = String(pre?.trip_state ?? "").trim().toLowerCase();
  const preStatus = String(pre?.status ?? "").trim().toLowerCase();
  console.log(
    "DRIVER_ACCEPT_PRE",
    rideId,
    "raw_driver_id=",
    pre?.driver_id,
    "canonical_assigned=",
    canonicalAssignedDriverId(pre || {}),
    "trip_state=",
    preTrip,
    "status=",
    preStatus,
  );
  const preAssigned = canonicalAssignedDriverId(pre || {});
  const alreadyMine =
    pre &&
    typeof pre === "object" &&
    preAssigned === driverId &&
    (preTrip === TRIP_STATE.accepted ||
      preTrip === TRIP_STATE.driver_assigned ||
      preTrip === "driver_accepted" ||
      preStatus === "accepted");
  if (alreadyMine) {
    console.log("DRIVER_ACCEPT_ALREADY_ACCEPTED_IDEMPOTENT", rideId, driverId);
    await syncRideTrackPublic(db, rideId);
    return { success: true, idempotent: true, reason: "already_accepted" };
  }

  const gates = await loadDispatchGates(db);
  const drvSnap = await db.ref(`drivers/${driverId}`).get();
  const drvProf = drvSnap.val();
  if (!drvProf || typeof drvProf !== "object") {
    console.log("DRIVER_ACCEPT_FAIL_REASON", rideId, "driver_profile_missing");
    return { success: false, reason: "driver_profile_missing" };
  }
  const el = evaluateDriverForOffer(drvProf, gates, pre || {});
  if (!el.ok) {
    console.log(
      "DRIVER_ACCEPT_FAIL_REASON",
      rideId,
      "driver_not_eligible",
      el.log || "verification_gate",
      el.detail,
    );
    return { success: false, reason: "driver_not_eligible" };
  }

  const offerSnap = await db.ref(`driver_offer_queue/${driverId}/${rideId}`).get();
  const offerPresent = snapExists(offerSnap);
  if (!offerPresent) {
    const st0 = String(pre?.status ?? "").trim().toLowerCase();
    const openForAccept =
      isOpenPoolRide(pre || {}) || ACCEPTABLE_OPEN_STATUS.has(st0);
    const driverSlotFree = !canonicalAssignedDriverId(pre || {});
    if (
      !(
        openForAccept &&
        driverSlotFree &&
        paymentAllowsDispatch(pre || {})
      )
    ) {
      console.log("DRIVER_ACCEPT_FAIL_REASON", rideId, "no_offer");
      return { success: false, reason: "no_offer" };
    }
    console.log(
      "DRIVER_ACCEPT_OFFER_SKIPPED",
      rideId,
      driverId,
      "reason=no_queue_row_open_ride",
    );
  } else {
    const offer = offerSnap.val();
    if (offer && String(offer.status ?? "").trim().toLowerCase() === "withdrawn") {
      console.log("DRIVER_ACCEPT_FAIL_REASON", rideId, "offer_withdrawn");
      return { success: false, reason: "offer_withdrawn" };
    }

    const offerRid = normUid(offer?.ride_id);
    if (offerRid && offerRid !== rideId) {
      console.log("DRIVER_ACCEPT_FAIL_REASON", rideId, "offer_ride_mismatch");
      return { success: false, reason: "offer_ride_mismatch" };
    }
    const offerMarket = canonicalDispatchMarket(offer?.market ?? "");
    const rideMarket = canonicalDispatchMarket(
      pre?.market_pool ?? pre?.market ?? "",
    );
    if (!offerMarket || !rideMarket || offerMarket !== rideMarket) {
      console.log("DRIVER_ACCEPT_FAIL_REASON", rideId, "offer_market_mismatch");
      return { success: false, reason: "offer_market_mismatch" };
    }
  }

  if (!paymentAllowsDispatch(pre || {})) {
    console.log("DRIVER_ACCEPT_FAIL_REASON", rideId, "payment_not_verified");
    return { success: false, reason: "payment_not_verified" };
  }

  const now = nowMs();
  const lastFailure = { reason: "unknown" };
  const maxTxAttempts = 8;
  let tx = null;
  let committed = false;

  console.log("DRIVER_ACCEPT_TX_BEGIN", rideId, driverId);

  for (let attempt = 1; attempt <= maxTxAttempts; attempt++) {
    const warmSnap = await rideRef.get();
    const warmExists = snapExists(warmSnap);
    const warmVal = rideDocFromSnapshot(warmSnap);
    if (!warmExists) {
      lastFailure.reason = "ride_missing";
      console.log(
        "DRIVER_ACCEPT_WARM_MISSING",
        `rideId=${rideId}`,
        "attempt=",
        attempt,
        "exists=false",
      );
      break;
    }
    if (!warmVal) {
      console.log(
        "DRIVER_ACCEPT_WARM_VAL_EMPTY",
        `rideId=${rideId}`,
        "attempt=",
        attempt,
        "exists=true",
        "proceed_tx",
      );
    }

    const attemptResult = await rideRef.transaction((current) => {
      lastFailure.reason = "unknown";
      if (!current || typeof current !== "object") {
        lastFailure.reason = "tx_empty_current";
        return;
      }

      if (!paymentAllowsDispatch(current)) {
        lastFailure.reason = "payment_not_verified";
        return;
      }

      const tripState = String(current.trip_state ?? "").trim().toLowerCase();
      const status = String(current.status ?? "").trim().toLowerCase();
      const assignedCanon = canonicalAssignedDriverId(current);

      const already =
        assignedCanon === driverId &&
        (tripState === TRIP_STATE.accepted ||
          tripState === TRIP_STATE.driver_assigned ||
          tripState === "driver_accepted" ||
          status === "accepted");
      if (already) {
        return current;
      }

      if (assignedCanon && assignedCanon !== driverId) {
        lastFailure.reason = "driver_already_set";
        return;
      }

      const openByTrip = isOpenPoolRide(current);
      const openByStatus = ACCEPTABLE_OPEN_STATUS.has(status);
      if (!openByTrip && !openByStatus) {
        lastFailure.reason = "status_not_open";
        return;
      }

      const expiresAt = Number(current.expires_at ?? current.request_expires_at ?? 0) || 0;
      if (expiresAt > 0 && now >= expiresAt) {
        lastFailure.reason = "expired";
        return;
      }

      return {
        ...current,
        driver_id: driverId,
        matched_driver_id: driverId,
        accepted_driver_id: driverId,
        status: "accepted",
        trip_state: TRIP_STATE.accepted,
        accepted_at: ServerValue.TIMESTAMP,
        updated_at: now,
      };
    });

    tx = attemptResult.snapshot;
    committed = Boolean(attemptResult.committed);
    if (committed) {
      console.log("DRIVER_ACCEPT_TX_SUCCESS", rideId, driverId, "path=transaction");
      break;
    }

    if (lastFailure.reason !== "ride_missing" && lastFailure.reason !== "tx_empty_current") {
      break;
    }

    console.log(
      "DRIVER_ACCEPT_TX_RETRY",
      rideId,
      "attempt=",
      attempt,
      "max=",
      maxTxAttempts,
      "reason=transaction_saw_empty_while_warm_had_data",
    );
    await sleepMs(Math.min(150, 35 * attempt));
  }

  let failureReason = lastFailure.reason;
  let finalRideVal = null;

  if (committed && tx && typeof tx.val === "function") {
    finalRideVal = rideDocFromSnapshot(tx);
  }

  if (
    !committed &&
    (failureReason === "ride_missing" ||
      failureReason === "tx_empty_current" ||
      failureReason === "unknown")
  ) {
    console.log("DRIVER_ACCEPT_MERGE_FALLBACK", rideId, "tx_reason=", failureReason);
    const merge = await applyDriverAcceptAdminMerge(rideRef, rideId, driverId, now);
    if (merge.ok && merge.idempotent) {
      console.log("DRIVER_ACCEPT_TX_SUCCESS", rideId, driverId, "path=admin_merge_idempotent");
      await syncRideTrackPublic(db, rideId);
      return { success: true, idempotent: true, reason: "already_accepted" };
    }
    if (merge.ok) {
      committed = true;
      finalRideVal = merge.finalRide ?? null;
      failureReason = "unknown";
      console.log("DRIVER_ACCEPT_TX_SUCCESS", rideId, driverId, "path=admin_merge");
    } else {
      failureReason = merge.reason || failureReason;
      console.log("DRIVER_ACCEPT_MERGE_FAIL", rideId, failureReason);
    }
  }

  if (!committed) {
    console.log("DRIVER_ACCEPT_TX_ABORT", rideId, "reason=", failureReason);
    if (failureReason === "driver_already_set") {
      const postSnap = await rideRef.get();
      const post = rideDocFromSnapshot(postSnap);
      console.log(
        "DRIVER_ACCEPT_ALREADY_TAKEN",
        rideId,
        "driver=",
        driverId,
        "winner_canonical=",
        canonicalAssignedDriverId(post || {}),
        "raw_driver_id=",
        post?.driver_id,
        "trip_state=",
        post ? String(post.trip_state ?? "").trim().toLowerCase() : "",
      );
    }
    const rawReason =
      failureReason === "driver_already_set"
        ? "already_taken"
        : failureReason === "unknown"
          ? "not_available"
          : failureReason;
    const apiReason = surfaceAcceptFailureReason(rawReason, preflightDocPresent);
    if (rawReason !== apiReason) {
      console.log(
        "DRIVER_ACCEPT_SURFACE_NOT_MISSING",
        rideId,
        "inner=",
        rawReason,
        "surface=",
        apiReason,
      );
    }
    console.log("DRIVER_ACCEPT_FAIL_REASON", rideId, apiReason);
    console.log("DRIVER_ACCEPT_FAIL", rideId, apiReason);
    return {
      success: false,
      reason: apiReason,
    };
  }

  if (!finalRideVal || typeof finalRideVal !== "object") {
    const postSnap = await rideRef.get();
    finalRideVal = rideDocFromSnapshot(postSnap);
    console.log(
      "DRIVER_ACCEPT_FINAL_RIDE_FALLBACK_GET",
      rideId,
      "ok=",
      Boolean(finalRideVal && typeof finalRideVal === "object"),
    );
  }

  const riderId = normUid(finalRideVal?.rider_id ?? finalRideVal?.riderId);
  if (!riderId) {
    console.log(
      "DRIVER_ACCEPT_INVALID_RIDE",
      rideId,
      "reason=invalid_ride_payload",
      "missing_field=rider_id",
      "phase=post_commit",
    );
    return { success: false, reason: "invalid_ride_payload" };
  }

  await clearFanoutAndOffers(db, rideId, driverId);
  await setActiveTripPointers(db, rideId, riderId, driverId, finalRideVal);

  await ensureRideChatThread(db, rideId, riderId, driverId);

  await writeAudit(db, {
    type: "ride_accept",
    ride_id: rideId,
    driver_id: driverId,
    actor_uid: driverId,
  });

  await syncRideTrackPublic(db, rideId);

  return {
    success: true,
    idempotent: false,
    reason: "accepted",
  };
}

async function driverEnroute(data, context, db) {
  const rideId = normRideIdFromCallableData(data);
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
    if (
      ts !== TRIP_STATE.driver_assigned &&
      ts !== TRIP_STATE.accepted &&
      ts !== "driver_accepted"
    ) {
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
  await syncRideTrackPublic(db, rideId);
  return { success: true, reason: "enroute" };
}

async function driverArrived(data, context, db) {
  const rideId = normRideIdFromCallableData(data);
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
  await syncRideTrackPublic(db, rideId);
  return { success: true, reason: "arrived" };
}

async function startTrip(data, context, db) {
  const rideId = normRideIdFromCallableData(data);
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
  await syncRideTrackPublic(db, rideId);
  return { success: true, reason: "started" };
}

async function completeTrip(data, context, db) {
  const rideId = normRideIdFromCallableData(data);
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
    if (!rideHasVerifiedOnlinePayment(cur)) {
      reason = "payment_not_verified";
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
  await clearActiveTripPointers(db, rideId, riderId, driverId);
  if (riderId) {
    await db.ref(`rider_active_ride/${riderId}`).remove();
  }
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
  await syncRideTrackPublic(db, rideId);

  if (rideHasVerifiedOnlinePayment(ride)) {
    const gross = grossFareFromRide(ride);
    const fee = platformFeeNgn();
    const driverPayout = Math.max(0, gross - fee);
    if (driverPayout > 0 && driverId) {
      const ledgerRef = db.ref(`driver_wallet_ledger/${driverId}/${rideId}_fare_credit`);
      const ltxn = await ledgerRef.transaction((cur) => {
        if (cur && typeof cur === "object" && cur.completed) {
          return undefined;
        }
        if (cur && typeof cur === "object" && cur.pending) {
          return undefined;
        }
        if (cur != null && cur !== undefined) {
          return undefined;
        }
        return { pending: true, at: nowMs() };
      });
      if (!ltxn.committed) {
        console.log("WALLET_CREDIT_LOCK_SKIP", rideId);
      } else {
        const wt = await createWalletTransactionInternal(db, {
          userId: driverId,
          amount: driverPayout,
          type: "driver_earning_credit",
          idempotencyKey: `${rideId}_fare_credit`,
        });
        if (wt.success) {
          await ledgerRef.update({
            completed: true,
            amount: driverPayout,
            credited_at: nowMs(),
            source: "complete_trip",
          });
          console.log("WALLET_CREDITED", driverId, rideId);
        } else {
          try {
            await ledgerRef.remove();
          } catch (_) {
            /* ignore */
          }
        }
      }
    }
  }

  return { success: true, reason: "completed" };
}

async function cancelRideRequest(data, context, db) {
  const rideId = normRideIdFromCallableData(data);
  const cancelReason = String(data?.cancel_reason ?? data?.cancelReason ?? "").trim();
  if (!rideId || !context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const uid = normUid(context.auth.uid);
  let isAdminUser = context.auth?.token?.admin === true;
  if (!isAdminUser) {
    isAdminUser = await isNexRideAdmin(db, context);
  }
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
    const isAdmin = isAdminUser;
    if (!isRider && !isDriver && !isAdmin) {
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
        cancelReason ||
        (isAdmin ? "admin_cancelled" : isRider ? "rider_cancelled" : "driver_cancelled"),
      cancel_actor: isAdmin ? "admin" : isRider ? "rider" : "driver",
      cancelled_by: isAdmin ? "admin" : isRider ? "rider" : "driver",
    };
  });
  if (!tx.committed) {
    return { success: false, reason };
  }
  const v = tx.snapshot.val();
  const rider = normUid(v?.rider_id);
  const drv = normUid(v?.driver_id);
  await clearFanoutAndOffers(db, rideId);
  if (drv && !isPlaceholderDriverId(v?.driver_id)) {
    await clearActiveTripPointers(db, rideId, rider, drv);
  }
  if (rider) {
    await db.ref(`rider_active_ride/${rider}`).remove();
  }
  await writeAudit(db, {
    type: "ride_cancel",
    ride_id: rideId,
    actor_uid: uid,
    cancel_reason: cancelReason,
  });
  await syncRideTrackPublic(db, rideId);
  return { success: true, reason: "cancelled" };
}

async function expireRideRequest(data, context, db) {
  const rideId = normRideIdFromCallableData(data);
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
  await clearFanoutAndOffers(db, rideId);
  if (uid) {
    await db.ref(`rider_active_ride/${uid}`).remove();
  }
  await writeAudit(db, { type: "ride_expire", ride_id: rideId, actor_uid: uid });
  await syncRideTrackPublic(db, rideId);
  return { success: true, reason: "expired" };
}

const PATCHABLE_TOP_LEVEL = new Set([
  "chat_ready",
  "chat_ready_at",
  "chat_last_message",
  "chat_last_message_text",
  "chat_last_message_sender_id",
  "chat_last_message_sender_role",
  "chat_last_message_at",
  "chat_updated_at",
  "has_chat_messages",
  "deliveryProofPhotoUrl",
  "deliveryProofSubmittedAt",
  "deliveryProofStatus",
  "deliveredAt",
  "rider_safety_alert",
  "fare",
  "fare_breakdown",
  "duration_min",
  "route_basis",
  "updated_at",
  "route_log_updated_at",
  "route_log_last_event_at",
  "route_log_last_event_status",
  "route_log_last_event_source",
  "has_route_logs",
]);

function isAllowedPatchKey(k) {
  if (PATCHABLE_TOP_LEVEL.has(k)) {
    return true;
  }
  return k.startsWith("dispatch_details/deliveryProof") ||
    k.startsWith("dispatch_details/pickupConfirmed") ||
    k.startsWith("dispatch_details/deliveredAt") ||
    k.startsWith("route_basis/");
}

async function patchRideRequestMetadata(data, context, db) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const rideId = normRideIdFromCallableData(data);
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
  await syncRideTrackPublic(db, rideId);
  return { success: true, reason: "patched" };
}

module.exports = {
  TRIP_STATE,
  createRideRequest,
  acceptRideRequest,
  fanOutDriverOffersIfEligible,
  driverEnroute,
  driverArrived,
  startTrip,
  completeTrip,
  cancelRideRequest,
  expireRideRequest,
  patchRideRequestMetadata,
  canonicalDispatchMarket,
  loadRiderCreateGates,
  loadDispatchGates,
  evaluateDriverForOffer,
  riderProfileRequirementOk,
};
