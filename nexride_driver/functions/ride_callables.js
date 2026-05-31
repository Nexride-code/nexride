/**
 * NexRide ride lifecycle — server source of truth.
 * All sensitive ride_requests fields are written here (Admin SDK).
 */

const admin = require("firebase-admin");
const { logger } = require("firebase-functions");
const { traceLog } = require("./observability");
const { dispatchVerboseLog } = require("./dispatch_engine/dispatch_production_log");
const { platformFeeNgn } = require("./params");
const { syncRideTrackPublic } = require("./track_public");
const { syncLiveJobMirror, syncLiveDriverMirror } = require("./live_job_mirror");
const cardPayment = require("./card_payment_flow");

/** Public ride track + lightweight liveJobs/liveDrivers mirrors (UI sync only). */
async function syncRideRealtimeMirrors(db, rideId, driverId) {
  await syncRideTrackPublic(db, rideId);
  try {
    await syncLiveJobMirror(db, rideId);
    if (driverId) {
      await syncLiveDriverMirror(db, driverId, rideId);
    }
  } catch (mirrorErr) {
    logger.warn("syncRideRealtimeMirrors_skip", { rideId, error: mirrorErr?.message });
  }
}
const adminPerms = require("./admin_permissions");
const { createWalletTransactionInternal } = require("./wallet_core");
const rideFinance = require("./ride_finance_settlement");
const { ServerValue } = require("firebase-admin/database");
const {
  evaluateDriverForOffer,
  evaluateDriverForOfferSoft,
  evaluateDriverGeoAndMode,
  logMatchLocationSource,
  evaluateDriverVerificationForOffer,
  evaluateCarRideVehicleAndCapability,
  buildDriverFanoutFilterTrace,
  loadDispatchGates,
  normalizeDriverAvailabilityMode,
  summarizeDriverForFanout,
} = require("./driver_dispatch_gates");
const {
  FANOUT_BATCH_SIZE,
  evaluateDriverMatchCandidate,
  sortEligibleCandidates,
  selectNextFanoutBatch,
  deriveMatchingState,
} = require("./driver_match_ranking");
const {
  buildDriverLocationRecord,
  locationPathUpdates,
  normalizeAvailabilityMode: normalizeDriverAvailMode,
} = require("./driver_location_paths");
const { ensureRideChatThread } = require("./ride_chat_admin");
const { sendPushToUser } = require("./push_notifications");
const { resolveDriverMonetization, resolveCommissionPolicy } = require("./driver_monetization");
const riderFirestoreIdentity = require("./rider_firestore_identity");
const deliveryRegions = require("./ecosystem/delivery_regions");
const {
  normalizeDispatchKey,
  resolveCanonicalDispatchMarket,
  applyCanonicalDispatchGeoToRidePayload,
  applyCanonicalDispatchGeoToDriverUpdates,
  rejectCanonicalMarketMutation,
  stripCanonicalMarketFieldsFromUpdate,
  assertRideCanonicalFieldsAligned,
  assertDriverCanonicalFieldsAligned,
} = require("./dispatch_engine/dispatch_geo_normalizer");
const {
  syncDispatchIndexForDriver,
  clearDispatchIndexForDriver,
  removeDriverFromDispatchIndexWhenUnavailable,
  loadDriversFromDispatchIndex,
} = require("./dispatch_engine/dispatch_index_engine");

const TRIP_STATE = {
  searching: "searching",
  assigned: "assigned",
  /** @deprecated alias — use assigned */
  accepted: "assigned",
  driver_assigned: "assigned",
  driver_arriving: "assigned",
  arrived: "arrived",
  on_trip: "on_trip",
  /** @deprecated alias — use on_trip */
  in_progress: "on_trip",
  completed: "completed",
  cancelled: "cancelled",
  expired: "expired",
};

/** Normalize legacy RTDB trip_state tokens to canonical values. */
function normalizeCanonicalTripState(raw) {
  const ts = String(raw ?? "").trim().toLowerCase();
  if (!ts) return TRIP_STATE.searching;
  if (Object.values(TRIP_STATE).includes(ts) && ts !== TRIP_STATE.accepted) {
    if (ts === "driver_assigned" || ts === "driver_arriving") return TRIP_STATE.assigned;
    if (ts === "in_progress") return TRIP_STATE.on_trip;
    return ts;
  }
  if (LEGACY_OPEN_TRIP_STATES.has(ts)) return TRIP_STATE.searching;
  const map = {
    requested: TRIP_STATE.searching,
    requesting: TRIP_STATE.searching,
    searching_driver: TRIP_STATE.searching,
    matching: TRIP_STATE.searching,
    offered: TRIP_STATE.searching,
    pending_driver_action: TRIP_STATE.searching,
    driver_accepted: TRIP_STATE.assigned,
    accepted: TRIP_STATE.assigned,
    assigned: TRIP_STATE.assigned,
    driver_assigned: TRIP_STATE.assigned,
    driver_arriving: TRIP_STATE.assigned,
    arriving: TRIP_STATE.assigned,
    enroute_to_pickup: TRIP_STATE.assigned,
    driver_arrived: TRIP_STATE.arrived,
    arrived: TRIP_STATE.arrived,
    on_trip: TRIP_STATE.on_trip,
    in_progress: TRIP_STATE.on_trip,
    trip_started: TRIP_STATE.on_trip,
    completed: TRIP_STATE.completed,
    cancelled: TRIP_STATE.cancelled,
    expired: TRIP_STATE.expired,
  };
  return map[ts] ?? TRIP_STATE.searching;
}

/** Pointer only — never lifecycle fields (Grab-style thin index). */
async function setRiderActiveTripPointer(db, riderId, rideId) {
  const r = normUid(riderId);
  const rid = normRideIdFromCallableData({ rideId });
  if (!r || !rid) return;
  await db.ref(`rider_active_trip/${r}`).set({
    ride_id: rid,
    updated_at: nowMs(),
  });
}

/**
 * Do not clear rider_active_trip while the ride is still in open-pool search.
 * @returns {Promise<boolean>} true when pointer may be cleared
 */
async function riderActiveTripPointerMayClear(db, riderId, rideIdHint = "") {
  const r = normUid(riderId);
  if (!r) return true;
  const rid = normUid(rideIdHint);
  if (!rid) {
    const ptrSnap = await db.ref(`rider_active_trip/${r}`).get();
    const ptr = ptrSnap.val();
    const ptrRide =
      ptr && typeof ptr === "object"
        ? normUid(ptr.ride_id ?? ptr.rideId)
        : normUid(ptr);
    if (!ptrRide) return true;
    return riderActiveTripPointerMayClear(db, r, ptrRide);
  }
  const rideSnap = await db.ref(`ride_requests/${rid}`).get();
  const ride = rideSnap.val();
  if (!ride || typeof ride !== "object") {
    return false;
  }
  const { rideIsOpenForMatching } = require("./dispatch_engine/dispatch_trip_state_engine");
  if (rideIsOpenForMatching(ride)) {
    console.log(
      "RIDER_ACTIVE_POINTER_SKIP_CLEAR",
      `riderId=${r}`,
      `rideId=${rid}`,
      `trip_state=${String(ride.trip_state ?? "").trim()}`,
      `status=${String(ride.status ?? "").trim()}`,
    );
    return false;
  }
  return true;
}

async function clearRiderActiveTripPointerIfAllowed(db, riderId, rideIdHint = "") {
  const r = normUid(riderId);
  if (!r) return false;
  if (!(await riderActiveTripPointerMayClear(db, r, rideIdHint))) {
    return false;
  }
  await db.ref(`rider_active_trip/${r}`).remove();
  return true;
}

/** Pointer only — never lifecycle fields. */
async function setDriverActiveRidePointer(db, driverId, rideId) {
  const d = normUid(driverId);
  const rid = normRideIdFromCallableData({ rideId });
  if (!d || !rid) return;
  await db.ref(`driver_active_ride/${d}`).set({
    ride_id: rid,
    updated_at: nowMs(),
  });
}

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

/** Assigned driver on a ride row (snake_case + camelCase + match/accept variants). */
function rideAssignedDriverUid(cur) {
  if (!cur || typeof cur !== "object") return "";
  const rider = normUid(cur.rider_id ?? cur.riderId);
  const fields = [
    cur.assigned_driver_uid,
    cur.assignedDriverUid,
    cur.matched_driver_id,
    cur.matchedDriverId,
    cur.accepted_driver_id,
    cur.acceptedDriverId,
    cur.driver_id,
    cur.driverId,
  ];
  for (const raw of fields) {
    const uid = normUid(raw);
    if (!uid) continue;
    const lower = uid.toLowerCase();
    if (lower === "waiting" || lower === "searching" || lower === "assigned") {
      continue;
    }
    if (rider && uid === rider) continue;
    return uid;
  }
  return "";
}

/**
 * @param {Record<string, unknown>|null|undefined} cur
 * @param {string} driverId
 * @returns {{ ok: boolean, reason: string, patch?: Record<string, unknown>, idempotent?: boolean }}
 */
function evaluateDriverArrivedTransition(cur, driverId) {
  if (!cur || typeof cur !== "object") {
    return { ok: false, reason: "ride_missing" };
  }
  if (rideAssignedDriverUid(cur) !== driverId) {
    return { ok: false, reason: "not_assigned_driver" };
  }
  const ts = normalizeCanonicalTripState(cur.trip_state);
  const legacyStatus = String(cur.status ?? "").trim().toLowerCase();
  if (ts === TRIP_STATE.arrived || legacyStatus === "arrived") {
    return { ok: true, reason: "already_arrived", patch: cur, idempotent: true };
  }
  const allowedPreArrival = new Set([
    TRIP_STATE.driver_arriving,
    "driver_arriving",
    TRIP_STATE.driver_assigned,
    "driver_assigned",
    TRIP_STATE.accepted,
    "driver_accepted",
    "accepted",
    "assigned",
    "enroute_to_pickup",
  ]);
  const allowedLegacyStatus = new Set([
    "accepted",
    "driver_assigned",
    "assigned",
    "arriving",
  ]);
  if (
    ts.length > 0 &&
    !allowedPreArrival.has(ts) &&
    !allowedLegacyStatus.has(legacyStatus)
  ) {
    return { ok: false, reason: "invalid_state" };
  }
  const now = nowMs();
  const graceUntil = now + 5 * 60 * 1000;
  return {
    ok: true,
    reason: "arrived",
    patch: {
      ...cur,
      trip_state: TRIP_STATE.arrived,
      status: legacyUiStatusForTripState(TRIP_STATE.arrived),
      driver_arrived: true,
      arrived_at: cur.arrived_at ?? now,
      driver_arrived_at: cur.driver_arrived_at ?? now,
      wait_fee_started_at: cur.wait_fee_started_at ?? now,
      wait_fee_grace_until: cur.wait_fee_grace_until ?? graceUntil,
      last_event: "driver_arrived",
      updated_at: now,
    },
  };
}

function boolTrueGate(v) {
  return v === true || v === "true" || v === 1 || v === "1";
}

function isDriverSuspendedProfile(d) {
  const p = d && typeof d === "object" ? d : {};
  return (
    boolTrueGate(p.suspended) ||
    boolTrueGate(p.account_suspended) ||
    String(p.driver_status ?? "")
      .trim()
      .toLowerCase() === "suspended"
  );
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

/** Fresh accept mutex — stale locks beyond this may be replaced (lease + grace). */
const MATCH_LOCK_MAX_AGE_MS = 35_000;

/** Canonical API reasons returned to driver clients on accept failure. */
const ACCEPT_API_FAILURE_REASONS = new Set([
  "ride_not_found",
  "offer_not_found",
  "offer_expired",
  "already_taken",
  "already_assigned",
  "invalid_state",
  "payment_not_dispatchable",
  "payment_pending",
  "driver_offline",
  "transaction_conflict",
  "accept_pending_retry",
  "authority_missing",
  "ride_cancelled",
]);

/**
 * Map internal accept failures to canonical API reasons for the driver client.
 * @param {string} internal
 * @param {boolean} preflightDocPresent
 * @param {{ offerWasValid?: boolean }} [opts]
 */
function mapApiAcceptFailureReason(internal, preflightDocPresent, opts = {}) {
  const offerWasValid = opts.offerWasValid === true;
  const key = String(internal ?? "").trim().toLowerCase();
  switch (key) {
    case "ride_missing":
      return preflightDocPresent && offerWasValid ? "accept_pending_retry" : "ride_not_found";
    case "tx_empty_current":
    case "unknown":
    case "not_available":
    case "transaction_not_committed":
      if (offerWasValid && preflightDocPresent) {
        return "accept_pending_retry";
      }
      return "transaction_conflict";
    case "no_offer":
    case "offer_withdrawn":
      return "offer_not_found";
    case "expired":
    case "offer_expired":
      return "offer_expired";
    case "driver_already_set":
    case "already_taken":
    case "already_assigned":
    case "ride_assignment_held":
      return "already_taken";
    case "driver_assignment_held":
    case "ride_lock_busy":
      return offerWasValid && preflightDocPresent
        ? "accept_pending_retry"
        : "transaction_conflict";
    case "ride_cancelled":
      return "ride_cancelled";
    case "payment_not_verified":
      return "payment_pending";
    case "status_not_open":
    case "status_not_requesting":
      return "invalid_state";
    case "driver_profile_missing":
    case "driver_not_eligible":
    case "driver_not_eligible_vehicle":
      return "driver_offline";
    case "offer_ride_mismatch":
    case "offer_market_mismatch":
      return "authority_missing";
    default:
      if (ACCEPT_API_FAILURE_REASONS.has(key)) {
        return key;
      }
      return key || "transaction_conflict";
  }
}

/**
 * When the RTDB transaction returns empty `current` intermittently, apply the same
 * accept fields via Admin `update` after a fresh read shows the ride still exists and is open.
 * @returns {Promise<{ ok: boolean, reason?: string, finalRide?: object|null, idempotent?: boolean }>}
 */
async function applyDriverAcceptAdminMerge(db, rideRef, rideId, driverId, now, opts = {}) {
  const acceptStartedAt = Number(opts.acceptStartedAt ?? 0) || 0;
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
    return { ok: false, reason: "invalid_state" };
  }
  if (!paymentAllowsAcceptRide(cur)) {
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
  const svcMerge = String(cur.service_type ?? "ride").trim().toLowerCase();
  let offerForExpiry = null;
  let authority = {
    valid: true,
    source: "none",
    offerQueueExists: false,
    offerVal: null,
    withdrawn: false,
  };
  if (svcMerge === "ride" || svcMerge === "") {
    const offerSnapM = await db.ref(`driver_offer_queue/${driverId}/${rideId}`).get();
    const offerPresentM = snapExists(offerSnapM);
    offerForExpiry =
      offerPresentM && offerSnapM.val() && typeof offerSnapM.val() === "object"
        ? offerSnapM.val()
        : null;
    authority = await resolveOfferAcceptAuthority(
      db,
      rideId,
      driverId,
      cur,
      offerPresentM,
      offerForExpiry,
    );
    if (authority.withdrawn) {
      return { ok: false, reason: "offer_withdrawn" };
    }
    if (!authority.valid) {
      return { ok: false, reason: "no_offer" };
    }
    if (!offerForExpiry && authority.offerVal) {
      offerForExpiry = authority.offerVal;
    }
  }
  if (!ridePoolOpenForAccept(cur)) {
    return { ok: false, reason: "status_not_open" };
  }
  if (!acceptWindowOpenForAccept(cur, offerForExpiry, acceptStartedAt, now)) {
    return { ok: false, reason: "expired" };
  }
  return attemptGuardedAcceptDirectWrite(db, rideRef, rideId, driverId, now, {
    authorityOfferVal: offerForExpiry,
    acceptStartedAt,
  });
}

/** Single canonical dispatch key shared by ride_requests.market_pool and drivers.dispatch_market. */
function canonicalDispatchMarket(raw) {
  return normalizeDispatchKey(raw);
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

/**
 * True when [v] is a real committed driver uid (not pool placeholders).
 */
function hasAssignedDriver(v) {
  if (v === null || v === undefined) {
    return false;
  }
  const s = String(v).trim().toLowerCase();
  return (
    s !== "" &&
    s !== "waiting" &&
    s !== "null" &&
    s !== "undefined" &&
    s !== "pending" &&
    s !== "none" &&
    s !== "unassigned" &&
    s !== "n/a" &&
    s !== "tbd"
  );
}

function isPlaceholderDriverId(v) {
  return !hasAssignedDriver(v);
}

/**
 * Canonical assigned driver on `ride_requests` for accept / conflict checks.
 * Checks matched/accepted aliases before driver_id; ignores placeholders and rider_id corruption.
 */
function canonicalAssignedDriverId(ride) {
  if (!ride || typeof ride !== "object") {
    return "";
  }
  const rider = normUid(ride.rider_id ?? ride.riderId);
  const fields = [
    "matched_driver_id",
    "matchedDriverId",
    "accepted_driver_id",
    "acceptedDriverId",
    "driver_id",
    "driverId",
  ];
  for (const key of fields) {
    const raw = ride[key];
    if (!hasAssignedDriver(raw)) {
      continue;
    }
    const d = normUid(raw);
    if (!d) {
      continue;
    }
    if (rider && d === rider) {
      continue;
    }
    return d;
  }
  return "";
}

function ridePoolOpenForAccept(ride) {
  if (!ride || typeof ride !== "object") {
    return false;
  }
  if (rideAssignedOrTerminal(ride)) {
    return false;
  }
  const status = String(ride.status ?? "").trim().toLowerCase();
  return isOpenPoolRide(ride) || ACCEPTABLE_OPEN_STATUS.has(status);
}

const ASSIGNED_OR_ACTIVE_TRIP_STATES = new Set([
  TRIP_STATE.driver_assigned,
  "driver_accepted",
  TRIP_STATE.driver_arriving,
  "driver_arriving",
  "driver_on_the_way",
  TRIP_STATE.arrived,
  "driver_arrived",
  TRIP_STATE.in_progress,
  "on_trip",
  "enroute",
  "in_trip",
]);

const TERMINAL_TRIP_STATES_ACCEPT = new Set([
  TRIP_STATE.completed,
  TRIP_STATE.cancelled,
  TRIP_STATE.expired,
  "trip_completed",
  "trip_cancelled",
  "canceled",
]);

/**
 * True when the ride is no longer an open matching pool row (assigned or terminal).
 */
function rideAssignedOrTerminal(ride) {
  if (!ride || typeof ride !== "object") {
    return false;
  }
  const assigned = canonicalAssignedDriverId(ride);
  if (assigned) {
    return true;
  }
  const rs = String(ride.request_status ?? ride.requestStatus ?? "")
    .trim()
    .toLowerCase();
  const st = String(ride.status ?? "").trim().toLowerCase();
  if (rs === "accepted" || st === "accepted") {
    return true;
  }
  const ts = String(ride.trip_state ?? "").trim().toLowerCase();
  if (ASSIGNED_OR_ACTIVE_TRIP_STATES.has(ts)) {
    return true;
  }
  if (TERMINAL_TRIP_STATES_ACCEPT.has(ts)) {
    return true;
  }
  return false;
}

/**
 * Canonical assignment patch written atomically on driver accept.
 * @param {string} driverId
 * @param {number} now
 * @param {number} [effectiveExp]
 */
function readMatchLockHolder(ride) {
  if (!ride || typeof ride !== "object") {
    return "";
  }
  const ml = ride.match_lock;
  if (ml && typeof ml === "object") {
    const by = normUid(ml.accepted_by ?? ml.acceptedBy);
    if (by) {
      return by;
    }
  }
  return normUid(ride.accepted_by ?? ride.acceptedBy);
}

function readMatchLockAgeMs(ride, now = nowMs()) {
  if (!ride || typeof ride !== "object") {
    return Number.POSITIVE_INFINITY;
  }
  const ml = ride.match_lock;
  const at =
    ml && typeof ml === "object"
      ? Number(ml.accepted_at_ms ?? ml.acceptedAtMs ?? 0) || 0
      : Number(ride.accepted_at_ms ?? ride.acceptedAtMs ?? 0) || 0;
  if (at <= 0) {
    return Number.POSITIVE_INFINITY;
  }
  return Math.max(0, now - at);
}

/**
 * Acquire accept mutex on ride_requests/{id}/match_lock before assignment commit.
 */
async function acquireMatchLockOrReject(rideRef, rideId, driverId, now) {
  const d = normUid(driverId);
  const rid = normUid(rideId);
  if (!rid || !d) {
    return { ok: false, reason: "invalid_input", holder: "" };
  }
  const lockRef = rideRef.child("match_lock");
  let abortReason = "unknown";
  let otherHolder = "";
  const tx = await lockRef.transaction((cur) => {
    abortReason = "unknown";
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
      const age = at > 0 ? now - at : MATCH_LOCK_MAX_AGE_MS + 1;
      if (age < MATCH_LOCK_MAX_AGE_MS) {
        otherHolder = existing;
        abortReason = "driver_already_set";
        dispatchVerboseLog(
          "ACCEPT_LOCK_FAIL",
          `rideId=${rid}`,
          `holder=${existing}`,
          `ageMs=${age}`,
        );
        return;
      }
    }
    dispatchVerboseLog("ACCEPT_LOCK_ACQUIRED", `rideId=${rid}`, `driverId=${d}`);
    return { accepted_by: d, accepted_at_ms: now };
  });
  if (!tx.committed) {
    return {
      ok: false,
      reason: otherHolder ? "driver_already_set" : abortReason,
      holder: otherHolder,
    };
  }
  return { ok: true, holder: d };
}

/** Drop accept mutex when this driver still holds it after a failed accept attempt. */
async function releaseAcceptMatchLock(rideRef, driverId) {
  const d = normUid(driverId);
  if (!d) {
    return;
  }
  try {
    const lockRef = rideRef.child("match_lock");
    const snap = await lockRef.get();
    const cur = snap.val();
    let holder = "";
    if (cur && typeof cur === "object") {
      holder = normUid(cur.accepted_by ?? cur.acceptedBy);
    } else {
      holder = normUid(cur);
    }
    if (holder === d) {
      await lockRef.remove();
      dispatchVerboseLog("ACCEPT_MATCH_LOCK_RELEASED", `driverId=${d}`);
    }
  } catch (e) {
    dispatchVerboseLog("ACCEPT_MATCH_LOCK_RELEASE_FAIL", e?.message ?? e);
  }
}

function buildDriverAcceptAssignmentPatch(driverId, now, effectiveExp = 0, opts = {}) {
  const d = normUid(driverId);
  const useServerTimestamp = opts.useServerTimestamp !== false;
  const patch = {
    driver_id: d,
    driverId: d,
    matched_driver_id: d,
    matchedDriverId: d,
    accepted_driver_id: d,
    acceptedDriverId: d,
    assigned_driver_uid: d,
    assigned_driver_id: d,
    accepted_by: d,
    status: "assigned",
    request_status: "accepted",
    trip_state: TRIP_STATE.driver_assigned,
    accepted_at: useServerTimestamp ? ServerValue.TIMESTAMP : now,
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
  if (effectiveExp > 0) {
    patch.expires_at = effectiveExp;
    patch.request_expires_at = effectiveExp;
  }
  return patch;
}

function summarizeAcceptTxCurrent(current) {
  if (!current || typeof current !== "object") {
    return { exists: false, keys: [] };
  }
  return { exists: true, keys: Object.keys(current).slice(0, 48) };
}

/**
 * Pure accept decision for RTDB transaction / guarded direct write.
 * @returns {{ action: "commit"|"abort"|"noop", reason?: string, patch?: object, effectiveExp?: number }}
 */
function evaluateAcceptTransactionDecision(current, driverId, opts = {}) {
  const rideId = normUid(opts.rideId ?? "");
  const authorityOfferVal = opts.authorityOfferVal ?? null;
  const acceptStartedAt = Number(opts.acceptStartedAt ?? 0) || 0;
  const now = Number(opts.now ?? 0) || nowMs();
  const shouldLog = opts.log !== false && Boolean(rideId);
  const curSummary = summarizeAcceptTxCurrent(current);

  if (shouldLog) {
    console.log(
      "ACCEPT_TX_ENTER",
      `rideId=${rideId}`,
      `driverId=${driverId}`,
      `currentExists=${curSummary.exists}`,
    );
    console.log(
      "ACCEPT_TX_CURRENT_KEYS",
      curSummary.keys.length ? curSummary.keys.join(",") : "(none)",
    );
  }

  if (!current || typeof current !== "object") {
    if (shouldLog) {
      dispatchVerboseLog("ACCEPT_TX_RETURN_ABORT", `rideId=${rideId}`, "reason=tx_empty_current");
    }
    return { action: "abort", reason: "tx_empty_current" };
  }

  const tripState = String(current.trip_state ?? "").trim().toLowerCase();
  const status = String(current.status ?? "").trim().toLowerCase();
  const requestStatus = String(current.request_status ?? current.requestStatus ?? "")
    .trim()
    .toLowerCase();
  const assignedCanon = canonicalAssignedDriverId(current);
  const paymentStatus = String(current.payment_status ?? current.paymentStatus ?? "")
    .trim()
    .toLowerCase();
  const paymentMethod = normalizedPaymentMethod(current);
  const provider = String(
    current.payment_provider ?? current.paymentProvider ?? current.provider ?? "",
  )
    .trim()
    .toLowerCase();
  const allowsDispatch = paymentAllowsAcceptRide(current);
  const offerExpiresAt = Number(authorityOfferVal?.expires_at ?? 0) || 0;
  const rideExpiresAt = Number(current.expires_at ?? current.request_expires_at ?? 0) || 0;
  const acceptOpen = acceptWindowOpenForAccept(current, authorityOfferVal, acceptStartedAt, now);

  if (shouldLog) {
    console.log(
      "ACCEPT_TX_ASSIGNMENT_CHECK",
      `rideId=${rideId}`,
      `driver_id=${String(current.driver_id ?? "")}`,
      `matched_driver_id=${String(current.matched_driver_id ?? "")}`,
      `accepted_driver_id=${String(current.accepted_driver_id ?? "")}`,
      `canonicalAssignedDriverId=${assignedCanon || "(none)"}`,
      `hasAssignedDriver=${hasAssignedDriver(current.driver_id) || hasAssignedDriver(current.matched_driver_id)}`,
    );
    console.log(
      "ACCEPT_TX_OPEN_CHECK",
      `rideId=${rideId}`,
      `status=${status}`,
      `trip_state=${tripState}`,
      `request_status=${requestStatus}`,
      `ridePoolOpenForAccept=${ridePoolOpenForAccept(current)}`,
    );
    console.log(
      "ACCEPT_TX_PAYMENT_CHECK",
      `rideId=${rideId}`,
      `payment_status=${paymentStatus}`,
      `payment_method=${paymentMethod}`,
      `provider=${provider}`,
      `allowsDispatch=${allowsDispatch}`,
    );
    console.log(
      "ACCEPT_TX_EXPIRY_CHECK",
      `rideId=${rideId}`,
      `now=${now}`,
      `expiresAt=${Math.max(rideExpiresAt, offerExpiresAt)}`,
      `offerExpiresAt=${offerExpiresAt}`,
      `acceptStartedAt=${acceptStartedAt}`,
      `open=${acceptOpen}`,
    );
  }

  if (
    tripState === "cancelled" ||
    tripState === "trip_cancelled" ||
    status === "cancelled" ||
    requestStatus === "cancelled"
  ) {
    if (shouldLog) {
      dispatchVerboseLog("ACCEPT_TX_RETURN_ABORT", `rideId=${rideId}`, "reason=ride_cancelled");
    }
    return { action: "abort", reason: "ride_cancelled" };
  }

  if (!allowsDispatch) {
    if (shouldLog) {
      dispatchVerboseLog("ACCEPT_TX_RETURN_ABORT", `rideId=${rideId}`, "reason=payment_not_verified");
    }
    return { action: "abort", reason: "payment_not_verified" };
  }

  const lockHolder = readMatchLockHolder(current);
  if (lockHolder && lockHolder !== normUid(driverId)) {
    const lockAge = readMatchLockAgeMs(current, now);
    if (lockAge < MATCH_LOCK_MAX_AGE_MS) {
      if (shouldLog) {
        console.log(
          "ACCEPT_TX_RETURN_ABORT",
          `rideId=${rideId}`,
          "reason=driver_already_set",
          `lockHolder=${lockHolder}`,
        );
      }
      return { action: "abort", reason: "driver_already_set" };
    }
  }

  if (shouldLog && opts.authoritySource) {
    console.log(
      "ACCEPT_TX_AUTHORITY_CHECK",
      `rideId=${rideId}`,
      `source=${opts.authoritySource}`,
      `valid=${opts.authorityValid === true}`,
      `queueExists=${opts.offerQueueExists === true}`,
    );
  }

  const already =
    assignedCanon === normUid(driverId) &&
    (tripState === TRIP_STATE.accepted ||
      tripState === TRIP_STATE.driver_assigned ||
      tripState === "driver_accepted" ||
      status === "accepted");
  if (already) {
    if (shouldLog) {
      dispatchVerboseLog("ACCEPT_TX_RETURN_NOOP", `rideId=${rideId}`, "reason=already_accepted");
    }
    return { action: "noop", reason: "already_accepted" };
  }

  if (assignedCanon && assignedCanon !== normUid(driverId)) {
    if (shouldLog) {
      console.log(
        "ACCEPT_TX_RETURN_ABORT",
        `rideId=${rideId}`,
        "reason=driver_already_set",
        `winner=${assignedCanon}`,
      );
    }
    return { action: "abort", reason: "driver_already_set" };
  }

  if (!ridePoolOpenForAccept(current)) {
    if (shouldLog) {
      dispatchVerboseLog("ACCEPT_TX_RETURN_ABORT", `rideId=${rideId}`, "reason=status_not_open");
    }
    return { action: "abort", reason: "status_not_open" };
  }

  if (!acceptOpen) {
    if (shouldLog) {
      dispatchVerboseLog("ACCEPT_TX_RETURN_ABORT", `rideId=${rideId}`, "reason=expired");
    }
    return { action: "abort", reason: "expired" };
  }

  const effectiveExp = effectiveAcceptExpiryMs(current, authorityOfferVal);
  const patch = buildDriverAcceptAssignmentPatch(driverId, now, effectiveExp, {
    useServerTimestamp: false,
  });
  if (shouldLog) {
    dispatchVerboseLog("ACCEPT_TX_RETURN_COMMIT", `rideId=${rideId}`, `driverId=${driverId}`);
  }
  return { action: "commit", patch, effectiveExp };
}

/**
 * Guarded Admin update when RTDB transaction sees null current intermittently.
 */
async function attemptGuardedAcceptDirectWrite(db, rideRef, rideId, driverId, now, opts = {}) {
  const snap = await rideRef.get();
  const pathExists = snapExists(snap);
  const cur = rideDocFromSnapshot(snap);
  if (!pathExists) {
    return { ok: false, reason: "ride_not_found" };
  }
  if (!cur) {
    return { ok: false, reason: "invalid_state" };
  }
  const decision = evaluateAcceptTransactionDecision(cur, driverId, {
    rideId,
    authorityOfferVal: opts.authorityOfferVal ?? null,
    acceptStartedAt: opts.acceptStartedAt ?? 0,
    now,
    log: true,
  });
  if (decision.action === "abort") {
    return { ok: false, reason: decision.reason };
  }
  if (decision.action === "noop") {
    return { ok: true, finalRide: cur, idempotent: true, path: "direct_noop" };
  }
  const writePatch = {
    ...decision.patch,
    accepted_at: now,
  };
  dispatchVerboseLog("ACCEPT_DIRECT_WRITE_BEGIN", `rideId=${rideId}`, `driverId=${driverId}`);
  const writeOnce = async () => {
    await rideRef.update(writePatch);
    return rideDocFromSnapshot(await rideRef.get());
  };
  let verify = await writeOnce();
  let winner = canonicalAssignedDriverId(verify || {});
  if (winner !== normUid(driverId)) {
    await sleepMs(40);
    verify = await writeOnce();
    winner = canonicalAssignedDriverId(verify || {});
  }
  if (winner !== normUid(driverId)) {
    console.log(
      "ACCEPT_DIRECT_VERIFY_FAIL",
      `rideId=${rideId}`,
      `expected=${driverId}`,
      `actual=${winner || "(none)"}`,
    );
    return {
      ok: false,
      reason: winner ? "driver_already_set" : "tx_empty_current",
    };
  }
  dispatchVerboseLog("ACCEPT_DIRECT_WRITE_OK", `rideId=${rideId}`, `driverId=${driverId}`);
  return {
    ok: true,
    finalRide: verify,
    idempotent: false,
    path: "direct_update",
  };
}

async function countOfferQueueRowsForRide(db, rideId) {
  const rid = normUid(rideId);
  if (!rid) {
    return 0;
  }
  let count = 0;
  try {
    const fanSnap = await db.ref(`ride_offer_fanout/${rid}`).get();
    const fan = fanSnap.val() && typeof fanSnap.val() === "object" ? fanSnap.val() : {};
    for (const driverId of Object.keys(fan)) {
      const d = normUid(driverId);
      if (!d) {
        continue;
      }
      const qSnap = await db.ref(`driver_offer_queue/${d}/${rid}`).get();
      if (snapExists(qSnap)) {
        count += 1;
      }
    }
  } catch (_) {}
  return count;
}

async function recordAcceptSuccessDebug(db, rideId, driverId, details = {}) {
  const rid = normUid(rideId);
  const did = normUid(driverId);
  if (!rid || !did) {
    return;
  }
  const now = nowMs();
  try {
    await db.ref(`ride_requests/${rid}/match_debug`).update({
      matching_state: "matched",
      match_completed_at_ms: now,
      accepted_driver_id: did,
      last_accept_attempt_at: now,
      last_accept_driver_id: did,
      last_accept_failure_reason: null,
      offer_authority_source: String(details.offerAuthoritySource ?? "").trim() || null,
      updated_at: now,
    });
  } catch (e) {
    dispatchVerboseLog("ACCEPT_SUCCESS_DEBUG_WRITE_FAIL", rid, e?.message ?? e);
  }
}

/**
 * Infer why an accept transaction aborted when the callback left reason=unknown.
 */
function inferAcceptTxAbortReason(ride, driverId, authorityOfferVal, acceptStartedAtMs) {
  if (!ride || typeof ride !== "object") {
    return "tx_empty_current";
  }
  const assigned = canonicalAssignedDriverId(ride);
  if (assigned && assigned !== normUid(driverId)) {
    return "driver_already_set";
  }
  if (!paymentAllowsAcceptRide(ride)) {
    return "payment_not_verified";
  }
  if (!ridePoolOpenForAccept(ride)) {
    return "status_not_open";
  }
  if (!acceptWindowOpenForAccept(ride, authorityOfferVal, acceptStartedAtMs, nowMs())) {
    return "expired";
  }
  return "unknown";
}

function isOpenPoolRide(ride) {
  const ts = String(ride.trip_state ?? "").trim().toLowerCase();
  const st = String(ride.status ?? "").trim().toLowerCase();
  if (TRIP_STATE.searching === ts) return true;
  if (LEGACY_OPEN_TRIP_STATES.has(ts)) return true;
  if (LEGACY_OPEN_STATUS.has(st)) return true;
  return false;
}

const BANK_TRANSFER_DISPATCH_STATUSES = new Set([
  "pending_transfer",
  "pending_review",
  "paid",
  "verified",
]);

/** Accept may proceed while payment is still under review (Start Trip stays gated). */
const ACCEPT_RIDE_REVIEW_PAYMENT_STATUSES = new Set([
  "pending_manual_confirmation",
  "payment_review",
  "bank_transfer_pending",
  "automated_va",
  "pending",
  "pending_review",
]);

/** Grace after offer TTL when accept began before expiry (ms). */
const ACCEPT_EXPIRY_GRACE_MS = 10_000;

function acceptStartedAtFromCallableData(data) {
  const raw =
    data?.accept_started_at ??
    data?.acceptStartedAt ??
    data?.accept_requested_at ??
    data?.acceptRequestedAt ??
    0;
  const n = Number(raw) || 0;
  return n > 0 ? n : 0;
}

function driverIdInUidList(list, driverId) {
  if (!Array.isArray(list)) {
    return false;
  }
  const d = normUid(driverId);
  if (!d) {
    return false;
  }
  return list.some((x) => normUid(x) === d);
}

/**
 * Synchronous fan-out membership proof (queue row, batch list, offered list, queue_write audit).
 * @returns {{ valid: boolean, source: string, offerQueueExists: boolean, offerVal: object|null, withdrawn: boolean }}
 */
function evaluateOfferAcceptAuthority({
  driverId,
  ride,
  offerPresent,
  offerVal,
  rideOfferFanoutPresent = false,
}) {
  const d = normUid(driverId);
  if (!d) {
    return {
      valid: false,
      source: "none",
      offerQueueExists: false,
      offerVal: null,
      withdrawn: false,
    };
  }
  if (offerPresent) {
    if (offerVal && String(offerVal.status ?? "").trim().toLowerCase() === "withdrawn") {
      return {
        valid: false,
        source: "queue",
        offerQueueExists: true,
        offerVal,
        withdrawn: true,
      };
    }
    return {
      valid: true,
      source: "queue",
      offerQueueExists: true,
      offerVal,
      withdrawn: false,
    };
  }
  const md =
    ride?.match_debug && typeof ride.match_debug === "object" ? ride.match_debug : {};
  if (driverIdInUidList(md.batch_driver_ids, d)) {
    return {
      valid: true,
      source: "batch_driver_ids",
      offerQueueExists: false,
      offerVal: null,
      withdrawn: false,
    };
  }
  if (driverIdInUidList(md.offered_driver_ids, d)) {
    return {
      valid: true,
      source: "offered_driver_ids",
      offerQueueExists: false,
      offerVal: null,
      withdrawn: false,
    };
  }
  const qwd = md.queue_write_by_driver;
  if (qwd && typeof qwd === "object") {
    const keys = Object.keys(qwd);
    for (const k of keys) {
      if (normUid(k) !== d) {
        continue;
      }
      const v = qwd[k];
      if (v === true || v === "true" || (typeof v === "object" && v != null)) {
        return {
          valid: true,
          source: "audit",
          offerQueueExists: false,
          offerVal: null,
          withdrawn: false,
        };
      }
    }
  }
  if (rideOfferFanoutPresent) {
    return {
      valid: true,
      source: "audit",
      offerQueueExists: false,
      offerVal: null,
      withdrawn: false,
    };
  }
  return {
    valid: false,
    source: "none",
    offerQueueExists: false,
    offerVal: null,
    withdrawn: false,
  };
}

async function resolveOfferAcceptAuthority(db, rideId, driverId, ride, offerPresent, offerVal) {
  const base = evaluateOfferAcceptAuthority({
    driverId,
    ride,
    offerPresent,
    offerVal,
  });
  if (base.valid || base.withdrawn) {
    return base;
  }
  const rid = normUid(rideId);
  const d = normUid(driverId);
  if (!rid || !d) {
    return base;
  }
  const fanSnap = await db.ref(`ride_offer_fanout/${rid}/${d}`).get();
  const fanPresent = snapExists(fanSnap) && fanSnap.val() === true;
  return evaluateOfferAcceptAuthority({
    driverId,
    ride,
    offerPresent: false,
    offerVal: null,
    rideOfferFanoutPresent: fanPresent,
  });
}

function normalizedPaymentMethod(ride) {
  const method = String(ride?.payment_method ?? ride?.paymentMethod ?? "")
    .trim()
    .toLowerCase()
    .replace(/[\s-]+/g, "_");
  const provider = String(
    ride?.payment_provider ?? ride?.paymentProvider ?? ride?.provider ?? "",
  )
    .trim()
    .toLowerCase()
    .replace(/[\s-]+/g, "_");
  if (
    method === "bank_transfer" ||
    method === "flutterwave_va" ||
    provider === "flutterwave_va"
  ) {
    return "bank_transfer";
  }
  return method;
}

/**
 * Accept/dispatch expiry: max of ride pool TTL and active offer TTL so a driver
 * popup countdown (offer queue) cannot outlive the server accept window.
 */
function effectiveAcceptExpiryMs(ride, offer) {
  const rideExp =
    Number(ride?.expires_at ?? ride?.request_expires_at ?? 0) || 0;
  const offerExp =
    Number(offer?.expires_at ?? offer?.request_expires_at ?? 0) || 0;
  return Math.max(rideExp, offerExp);
}

function acceptWindowOpenAt(ride, offer, atMs) {
  return acceptWindowOpenForAccept(ride, offer, atMs, atMs);
}

/**
 * Accept TTL with post-expiry grace when the driver started accept before expiry.
 */
function acceptWindowOpenForAccept(ride, offer, acceptStartedAtMs, serverNowMs) {
  const exp = effectiveAcceptExpiryMs(ride, offer);
  if (exp <= 0) {
    return true;
  }
  const started =
    Number(acceptStartedAtMs) > 0 ? Number(acceptStartedAtMs) : Number(serverNowMs);
  const now = Number(serverNowMs) > 0 ? Number(serverNowMs) : nowMs();
  if (started < exp) {
    return now < exp + ACCEPT_EXPIRY_GRACE_MS;
  }
  return false;
}

async function recordAcceptFailureDebug(db, rideId, driverId, details) {
  const rid = normUid(rideId);
  const did = normUid(driverId);
  if (!rid || !did) {
    return;
  }
  const patch = {
    last_accept_attempt_at: nowMs(),
    last_accept_driver_id: did,
    last_accept_failure_reason: String(details?.reason ?? "").trim() || "unknown",
    offer_queue_exists_at_accept: details?.offerQueueExists === true,
    ride_state_at_accept: String(details?.rideState ?? "").trim() || null,
    ride_status_at_accept: String(details?.rideStatus ?? "").trim() || null,
    payment_status_at_accept: String(details?.paymentStatus ?? "").trim() || null,
    payment_method_at_accept: String(details?.paymentMethod ?? "").trim() || null,
    accept_expires_at_ms: Number(details?.acceptExpiresAtMs ?? 0) || null,
    offer_authority_source: String(details?.offerAuthoritySource ?? "").trim() || null,
    offer_authority_valid: details?.offerAuthorityValid === true,
    updated_at: nowMs(),
  };
  try {
    await db.ref(`ride_requests/${rid}/match_debug`).update(patch);
  } catch (e) {
    console.log(
      "DRIVER_ACCEPT_DEBUG_WRITE_FAIL",
      rid,
      e?.message ?? e,
    );
  }
}

/**
 * Gate dispatch (fan-out) and driver accept on payment state.
 * Cash is never dispatched.
 *
 * `payment_method` is normalized (`bank transfer` → `bank_transfer`) so RTDB
 * variants still match.
 *
 * Anyone changing this function must also re-read `fanOutDriverOffersIfEligible`
 * and `acceptRideRequest` because they all share this gate.
 */
function paymentAllowsDispatch(ride) {
  if (!ride || typeof ride !== "object") {
    return false;
  }
  const method = normalizedPaymentMethod(ride);

  const psRaw = ride.payment_status ?? ride.paymentStatus ?? "";
  const status = String(psRaw ?? "").trim().toLowerCase();

  if (method === "cash") {
    return false;
  }

  if (method === "bank_transfer") {
    if (status === "bank_transfer_expired" || status === "failed" || status === "declined") {
      return false;
    }
    /* Fan-out only after Flutterwave VA is issued (`pending_transfer`) or payment settled. */
    return BANK_TRANSFER_DISPATCH_STATUSES.has(status);
  }

  if (cardPayment.isCardPaymentMethod(method)) {
    if (cardPayment.CARD_BLOCKED_MATCH_STATUSES.has(status)) {
      return false;
    }
    return cardPayment.cardPaymentAllowsMatching(ride);
  }

  return [
    "paid",
    "verified",
    "pending_manual_confirmation",
    "pending",
    "pending_transfer",
  ].includes(status);
}

/**
 * Driver accept may proceed before payment is fully settled.
 * Fan-out / Start Trip still use [paymentAllowsDispatch].
 */
function paymentAllowsAcceptRide(ride) {
  if (!ride || typeof ride !== "object") {
    return false;
  }
  const method = normalizedPaymentMethod(ride);
  if (cardPayment.isCardPaymentMethod(method)) {
    return cardPayment.cardPaymentAllowsMatching(ride);
  }
  if (paymentAllowsDispatch(ride)) {
    return true;
  }
  if (method === "cash") {
    return false;
  }
  const status = String(ride.payment_status ?? ride.paymentStatus ?? "")
    .trim()
    .toLowerCase();
  if (status === "bank_transfer_expired" || status === "failed" || status === "declined") {
    return false;
  }
  if (ACCEPT_RIDE_REVIEW_PAYMENT_STATUSES.has(status)) {
    return true;
  }
  const settlement = String(ride.settlement_status ?? ride.settlementStatus ?? "")
    .trim()
    .toLowerCase();
  if (settlement === "payment_review") {
    return true;
  }
  const automatedVa =
    ride.bank_transfer_automated === true ||
    ride.automated_va === true ||
    String(ride.payment_provider ?? ride.paymentProvider ?? "")
      .trim()
      .toLowerCase() === "flutterwave_va";
  if (automatedVa && (status === "" || ACCEPT_RIDE_REVIEW_PAYMENT_STATUSES.has(status))) {
    return true;
  }
  return false;
}

/** Fan-out may start before VA is issued; accept uses [paymentAllowsAcceptRide]. */
function paymentAllowsFanout(ride) {
  if (!ride || typeof ride !== "object") {
    return false;
  }
  const method = normalizedPaymentMethod(ride);
  const status = String(ride.payment_status ?? ride.paymentStatus ?? "")
    .trim()
    .toLowerCase();
  if (method === "bank_transfer") {
    if (status === "bank_transfer_expired" || status === "failed" || status === "declined") {
      return false;
    }
    return (
      BANK_TRANSFER_DISPATCH_STATUSES.has(status) || status === "pending_manual_confirmation"
    );
  }
  if (cardPayment.isCardPaymentMethod(method)) {
    return cardPayment.cardPaymentAllowsMatching(ride);
  }
  return paymentAllowsDispatch(ride);
}

/** True when ride has settled online payment credentials (trip completion / wallet credit). */
function rideHasVerifiedOnlinePayment(ride) {
  if (!ride || typeof ride !== "object") return false;
  const ps = String(ride.payment_status ?? ride.paymentStatus ?? "")
    .trim()
    .toLowerCase();
  const ptid = String(ride.payment_transaction_id ?? ride.flw_tx_id ?? "").trim();
  if ((ps === "verified" || ps === "paid" || ps === "card_captured") && Boolean(ptid)) {
    return true;
  }
  if (cardPayment.isCardPaymentMethod(ride.payment_method ?? ride.paymentMethod)) {
    return cardPayment.CARD_AUTHORIZED_STATUSES.has(ps) && Boolean(ptid);
  }
  // Driver attestation for card-on-file, bank transfer, or delayed capture.
  if (ride.driver_confirmed_rider_payment === true) return true;
  return false;
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
  const uid = normUid(riderId);
  if (!uid) {
    return false;
  }
  const ref = db.ref(`users/${uid}`);
  const snap = await ref.get();
  if (snap.exists()) {
    return true;
  }
  const token = authLike?.token;
  if (!token || typeof token !== "object") {
    if (gates.require_riders_users_node) {
      return false;
    }
    return true;
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

/**
 * Driver declines an offer popup: clear this driver's queue row + fanout bit.
 */
async function withdrawDriverOffer(data, context, db) {
  const driverId = normUid(context?.auth?.uid);
  if (!driverId) {
    return { success: false, reason: "unauthorized" };
  }
  const rideId = normUid(data?.rideId ?? data?.ride_id);
  if (!rideId) {
    return { success: false, reason: "invalid_ride_id" };
  }
  console.log("DRIVER_DECLINE_SERVER_SYNC_START", { driverId, rideId });
  await db.ref().update({
    [`driver_offer_queue/${driverId}/${rideId}`]: null,
    [`driver_offer_queue_debug/${driverId}/${rideId}`]: null,
    [`ride_offer_fanout/${rideId}/${driverId}`]: null,
  });
  console.log("DRIVER_WITHDRAW_OFFER", { driverId, rideId });
  const reason = String(data?.reason ?? data?.withdraw_reason ?? "").trim().toLowerCase();
  try {
    await writeAudit(db, {
      type: "driver_offer_withdrawn",
      ride_id: rideId,
      driver_id: driverId,
      actor_uid: driverId,
      withdraw_reason: reason || "unspecified",
    });
  } catch (e) {
    console.log("DRIVER_WITHDRAW_OFFER_AUDIT_FAIL", rideId, String(e?.message || e));
  }

  // Rider stays in searching — offer next batch (declined driver excluded from future batches).
  try {
    const rideRef = db.ref(`ride_requests/${rideId}`);
    const rideSnap = await rideRef.get();
    const ride = rideSnap.val() && typeof rideSnap.val() === "object" ? rideSnap.val() : null;
    if (ride) {
      const md =
        ride.match_debug && typeof ride.match_debug === "object" ? ride.match_debug : {};
      const exhausted = Array.isArray(md.exhausted_driver_ids) ? [...md.exhausted_driver_ids] : [];
      if (!exhausted.includes(driverId)) {
        exhausted.push(driverId);
      }
      await rideRef.child("match_debug").update({
        exhausted_driver_ids: exhausted.slice(-80),
        last_decline_at: nowMs(),
        last_decline_driver_id: driverId,
      });
    }
    if (
      ride &&
      paymentAllowsDispatch(ride) &&
      !canonicalAssignedDriverId(ride) &&
      String(ride.service_type ?? "ride").trim().toLowerCase() === "ride" &&
      (isOpenPoolRide(ride) || ACCEPTABLE_OPEN_STATUS.has(String(ride.status ?? "").trim().toLowerCase()))
    ) {
      const fresh = (await rideRef.get()).val() || ride;
      await fanOutDriverOffersIfEligible(db, rideId, fresh);
    }
  } catch (e) {
    console.log("DRIVER_WITHDRAW_REFANOUT_FAIL", rideId, String(e?.message || e));
  }
  console.log("DRIVER_DECLINE_SERVER_SYNC_OK", { driverId, rideId });
  return { success: true, rideId, driverId };
}

async function clearFanoutAndOffers(db, rideId, alsoDriverId = "") {
  const rid = normUid(rideId);
  if (!rid) return;
  try {
    const { clearLeasesForRide } = require("./dispatch_engine/dispatch_offer_lease_engine");
    await clearLeasesForRide(db, rid, alsoDriverId);
  } catch (_) {}
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
const DRIVER_DISPATCH_AVAILABLE_STATES = new Set([
  "",
  "available",
  "online_available",
]);

function driverDispatchStateAvailable(raw) {
  const s = String(raw ?? "").trim().toLowerCase();
  return DRIVER_DISPATCH_AVAILABLE_STATES.has(s);
}

function driverStatusAllowsOffers(raw) {
  const s = String(raw ?? "").trim().toLowerCase();
  if (DRIVER_DISPATCH_AVAILABLE_STATES.has(s)) return true;
  const busy = new Set([
    "arrived",
    "accepted",
    "driver_assigned",
    "driver_enroute",
    "driver_arriving",
    "driver_on_the_way",
    "in_trip",
    "started",
    "on_trip",
    "in_progress",
    "trip_started",
    "busy",
    "on_ride",
  ]);
  return !busy.has(s);
}

function driverAvailabilityGate(profile) {
  const p = profile && typeof profile === "object" ? profile : {};
  const dispatchState = String(p.dispatch_state ?? "").trim().toLowerCase();
  if (!driverDispatchStateAvailable(dispatchState)) {
    return { ok: false, reason: `dispatch_state_not_available:${dispatchState}` };
  }
  if (driverSessionPresenceOnline(p)) {
    if (!driverStatusAllowsOffers(p.status)) {
      return { ok: false, reason: `status_busy_while_online:${String(p.status ?? "")}` };
    }
    return { ok: true };
  }
  const status = String(p.status ?? "").trim().toLowerCase();
  if (!driverStatusAllowsOffers(status)) {
    return { ok: false, reason: `status_not_available:${status}` };
  }
  return { ok: true };
}

function addressFromPlace(o) {
  if (!o || typeof o !== "object") return "";
  return String(o.address ?? o.formatted_address ?? o.description ?? "").trim();
}

/** Ensures lat/lng exist on offer pickup/dropoff maps for driver popup geo gates. */
function normalizeOfferPlaceGeo(place, ridePayload, prefix) {
  const o = place && typeof place === "object" ? { ...place } : {};
  const lat = Number(
    o.lat ?? o.latitude ?? ridePayload[`${prefix}_lat`] ?? ridePayload[`${prefix}Lat`] ?? "",
  );
  const lng = Number(
    o.lng ?? o.longitude ?? ridePayload[`${prefix}_lng`] ?? ridePayload[`${prefix}Lng`] ?? "",
  );
  if (Number.isFinite(lat) && Number.isFinite(lng)) {
    o.lat = lat;
    o.lng = lng;
  }
  return o;
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
  const pickupGeo = normalizeOfferPlaceGeo(pickup, ridePayload, "pickup");
  const dropoffGeo = dropoff
    ? normalizeOfferPlaceGeo(dropoff, ridePayload, "dropoff")
    : normalizeOfferPlaceGeo(
        ridePayload.destination && typeof ridePayload.destination === "object"
          ? ridePayload.destination
          : {},
        ridePayload,
        "destination",
      );
  return {
    ride_id: rid,
    rider_id: riderId || null,
    driver_id: driverUid,
    status: "open",
    market,
    market_pool: market,
    canonical_market_id: market,
    dispatch_market_id: market,
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
    pickup: pickupGeo,
    dropoff: dropoffGeo,
    trip_state: TRIP_STATE.searching,
    request_status: "searching",
    __nexride_from_offer_queue: true,
  };
}

async function writeDriverOfferPaths(
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
  driverProfile = null,
) {
  try {
    const {
      resolveValidatedBlockingTripForDriver,
    } = require("./driver_active_pointer_guard");
    const blockCheck = await resolveValidatedBlockingTripForDriver(
      db,
      d,
      "offer_write",
      rid,
    );
    if (blockCheck.blockingTripId) {
      console.log(
        "OFFER_WRITE_SKIP",
        `rideId=${rid}`,
        `driverId=${d}`,
        `blockingTripId=${blockCheck.blockingTripId}`,
      );
      return false;
    }
  } catch (_) {}
  try {
    const { purgeExpiredDriverOfferQueueEntries } = require("./refresh_driver_availability");
    await purgeExpiredDriverOfferQueueEntries(db, d, now);
  } catch (purgeErr) {
    console.log(
      "OFFER_QUEUE_PURGE_FAIL",
      `driverId=${d}`,
      String(purgeErr?.message || purgeErr),
    );
  }

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
  dispatchVerboseLog("OFFER_WRITE_START", `path=${qPath}`);
  try {
    const darSnap = await db.ref(`driver_active_ride/${d}`).get();
    const dar = darSnap.val() && typeof darSnap.val() === "object" ? darSnap.val() : {};
    const activeRideId = normUid(dar.ride_id ?? dar.rideId) || null;
    const prof = driverProfile && typeof driverProfile === "object" ? driverProfile : {};
    const offerAuditNow = nowMs();
    const auditBase = {
      offer_created_at_ms: offerAuditNow,
      offer_written_to_driver_queue: offerAuditNow,
      offer_push_sent: offerAuditNow,
    };
    const rideSnap = await db.ref(`ride_requests/${rid}`).get();
    const rideRow =
      rideSnap.exists() && typeof rideSnap.val() === "object" ? rideSnap.val() : {};
    const md =
      rideRow.match_debug && typeof rideRow.match_debug === "object"
        ? rideRow.match_debug
        : {};
    const offerAttempt =
      (Number(md.fanout_batch_number ?? 0) || 0) + 1;
    const { createOfferLease } = require("./dispatch_engine/dispatch_offer_lease_engine");
    const matchingLeaseMs = Math.max(3_000, Number(expiresAt) - Number(now));
    const leaseResult = await createOfferLease(db, {
      rideId: rid,
      driverId: d,
      offerPayload: { ...payload, ...auditBase },
      offerAttempt,
      source: "fanout",
      leaseMs: matchingLeaseMs,
    });
    if (!leaseResult.ok) {
      dispatchVerboseLog("OFFER_LEASE_FAIL", `rideId=${rid}`, `driverId=${d}`);
      return false;
    }
    const queuePayload = leaseResult.queuePayload;
    await db.ref().update({
      [`ride_offer_fanout/${rid}/${d}`]: true,
      [`driver_offer_queue/${d}/${rid}`]: queuePayload,
      [`driver_offer_queue_debug/${d}/${rid}`]: queuePayload,
      [`driver_offer_audit/${rid}/${d}`]: auditBase,
    });
    await sendPushToUser(db, d, {
      notification: {
        title: "New trip request",
        body: "A rider request is available near you.",
      },
      data: {
        type: "driver_offer",
        rideId: rid,
        serviceType: "ride",
        market,
        expires_at: String(queuePayload.expires_at ?? ""),
        lease_id: String(queuePayload.lease_id ?? ""),
        wake: "driver_offer",
      },
    });
    dispatchVerboseLog("OFFER_WRITE_SUCCESS", `path=${qPath}`);
    console.log("OFFER_WRITE_OK", `rideId=${rid}`, `driverId=${d}`, `path=${qPath}`);
    try {
      const {
        recordOfferWritten,
      } = require("./dispatch_engine/dispatch_production_metrics");
      const rideCreatedAt =
        Number(
          rideRow.created_at ??
            rideRow.createdAt ??
            ridePayload?.created_at ??
            0,
        ) || 0;
      recordOfferWritten(rideCreatedAt);
    } catch (_) {}
    logger.info("MATCH_QUEUE_WRITE", {
      rideId: rid,
      driverId: d,
      path: qPath,
      market,
    });
    logger.info("RIDE_OFFER_AUDIT", {
      event: "offer_delivered",
      rideId: rid,
      driverId: d,
      path: qPath,
      payment_status: String(ridePayload.payment_status ?? "").trim().toLowerCase(),
      payment_method: String(ridePayload.payment_method ?? "").trim().toLowerCase(),
      driver_active_ride: activeRideId,
      service_area: String(prof.rollout_city_id ?? prof.city ?? prof.service_city_id ?? "").trim() || null,
      vehicle_type: String(prof.vehicle_type ?? prof.vehicleType ?? "").trim() || null,
      driver_online: prof.online === true || String(prof.status ?? "").trim().toLowerCase() === "online",
      dispatch_market: String(prof.dispatch_market ?? prof.market ?? "").trim() || null,
    });
    return true;
  } catch (e) {
    const msg = e && typeof e === "object" && "message" in e ? String(e.message) : String(e);
    dispatchVerboseLog("OFFER_WRITE_FAIL", `path=${qPath}`, `error=${msg}`);
    logger.warn("MATCH_QUEUE_WRITE", {
      rideId: rid,
      driverId: d,
      path: qPath,
      success: false,
      error: msg,
    });
    return false;
  }
}

/**
 * Resolve online driver profiles for a dispatch market (indexed + fallbacks).
 * Dispatch matching MUST NOT call Google Places/Geocoding/Distance Matrix APIs —
 * only stored coordinates, canonical market IDs, and precomputed rider route metrics.
 * @param {import("firebase-admin/database").Database} db
 * @param {string} market
 */
const MARKET_DRIVER_QUERY_CAP = 120;
const ONLINE_DRIVER_FALLBACK_CAP = 80;

async function loadDriversForDispatchMarket(db, market) {
  const m = canonicalDispatchMarket(market);
  if (!m) return {};

  let raw = await loadDriversFromDispatchIndex(db, m);

  if (Object.keys(raw).length > 0) {
    return raw;
  }

  console.log("DISPATCH_INDEX_EMPTY_WARNING", `market=${m}`);

  try {
    const snap1 = await db
      .ref("drivers")
      .orderByChild("dispatch_market_id")
      .equalTo(m)
      .limitToFirst(MARKET_DRIVER_QUERY_CAP)
      .get();
    raw = snap1.val() && typeof snap1.val() === "object" ? snap1.val() : {};
  } catch (_) {}

  if (Object.keys(raw).length === 0) {
    try {
      const snap2 = await db
        .ref("drivers")
        .orderByChild("canonical_market_id")
        .equalTo(m)
        .limitToFirst(MARKET_DRIVER_QUERY_CAP)
        .get();
      const v2 = snap2.val() && typeof snap2.val() === "object" ? snap2.val() : {};
      raw = { ...raw, ...v2 };
    } catch (_) {}
  }

  if (Object.keys(raw).length === 0) {
    try {
      const onlineSnap = await db.ref("online_drivers").limitToFirst(ONLINE_DRIVER_FALLBACK_CAP).get();
      const online =
        onlineSnap.val() && typeof onlineSnap.val() === "object" ? onlineSnap.val() : {};
      let fetched = 0;
      for (const [id, row] of Object.entries(online)) {
        if (!row || typeof row !== "object" || row.is_online !== true) continue;
        const dm = canonicalDispatchMarket(
          row.dispatch_market_id ?? row.dispatch_market ?? row.market_pool ?? "",
        );
        if (dm !== m) continue;
        if (fetched >= ONLINE_DRIVER_FALLBACK_CAP) break;
        const profSnap = await db.ref(`drivers/${id}`).get();
        const prof = profSnap.val() && typeof profSnap.val() === "object" ? profSnap.val() : null;
        if (prof) {
          raw[id] = { ...prof, ...row };
          fetched += 1;
        }
      }
      if (fetched > 0) {
        console.log(
          "DISPATCH_MARKET_FALLBACK_ONLINE_ONLY",
          `market=${m}`,
          `count=${fetched}`,
          `cap=${ONLINE_DRIVER_FALLBACK_CAP}`,
        );
      }
    } catch (_) {}
  }

  return raw;
}

function rideDispatchMarketFromPayload(ridePayload) {
  return resolveCanonicalDispatchMarket(ridePayload);
}

async function loadFanoutSkipDriverIds(db, rideId, ridePayload) {
  const skip = new Set();
  const md =
    ridePayload?.match_debug && typeof ridePayload.match_debug === "object"
      ? ridePayload.match_debug
      : {};
  for (const id of md.exhausted_driver_ids || []) {
    const u = normUid(id);
    if (u) skip.add(u);
  }
  try {
    const fanSnap = await db.ref(`ride_offer_fanout/${rideId}`).get();
    const fan = fanSnap.val() && typeof fanSnap.val() === "object" ? fanSnap.val() : {};
    for (const id of Object.keys(fan)) {
      const u = normUid(id);
      if (!u) continue;
      const qSnap = await db.ref(`driver_offer_queue/${u}/${rideId}`).get();
      if (qSnap.exists()) {
        skip.add(u);
      }
    }
  } catch (_) {}
  return skip;
}

/**
 * Fan-out driver offers — no Google Maps API calls (coordinates + canonical markets only).
 */
async function fanOutDriverOffersIfEligible(db, rideId, ridePayload, fanoutOptions = {}) {
  const rid = normUid(rideId);
  const riderId = normUid(ridePayload.rider_id ?? ridePayload.riderId);
  const market = rideDispatchMarketFromPayload(ridePayload);
  assertRideCanonicalFieldsAligned(ridePayload, rid);
  if (!rid || !market) {
    dispatchVerboseLog(
      "MATCH_FANOUT_ABORT",
      `rideId=${rid || "(empty)"}`,
      `market=${market || "(empty)"}`,
      !market ? "reason=missing_canonical_market" : "reason=bad_ride_or_market",
    );
    return;
  }
  if (!paymentAllowsFanout(ridePayload)) {
    if (cardPayment.isCardPaymentMethod(ridePayload.payment_method ?? ridePayload.paymentMethod)) {
      console.log(
        "CARD_PAYMENT_BLOCKED_MATCHING",
        `rideId=${rid}`,
        `payment_status=${String(ridePayload.payment_status ?? "").trim().toLowerCase()}`,
        `payment_method=${String(ridePayload.payment_method ?? "").trim().toLowerCase()}`,
      );
    }
    dispatchVerboseLog(
      "MATCH_FANOUT_ABORT",
      `rideId=${rid}`,
      `market=${market}`,
      `payment_status=${String(ridePayload.payment_status ?? "").trim()}`,
      `payment_method=${String(ridePayload.payment_method ?? "").trim()}`,
      "reason=payment_not_allowed_for_fanout",
    );
    return;
  }
  const svc = String(ridePayload.service_type ?? "ride").trim().toLowerCase();
  if (svc !== "ride") {
    dispatchVerboseLog(
      "MATCH_FANOUT_ABORT",
      `rideId=${rid}`,
      `service_type=${svc}`,
      "reason=phase1_ride_only",
    );
    return;
  }
  if (rideAssignedOrTerminal(ridePayload)) {
    dispatchVerboseLog(
      "MATCH_FANOUT_ABORT",
      `rideId=${rid}`,
      `market=${market}`,
      `trip_state=${String(ridePayload.trip_state ?? "").trim()}`,
      `assigned=${canonicalAssignedDriverId(ridePayload) || "none"}`,
      "reason=ride_already_assigned_or_terminal",
    );
    return;
  }
  const fanoutNow = nowMs();
  const md0 =
    ridePayload?.match_debug && typeof ridePayload.match_debug === "object"
      ? ridePayload.match_debug
      : {};
  const isInitialFanout =
    String(md0.matching_state ?? "").trim() === "pending_fanout" ||
    !Number(md0.last_fanout_at_ms ?? 0);
  if (!fanoutOptions.forceFanout && !isInitialFanout) {
    const { loadDispatchConfig } = require("./dispatch_engine/dispatch_config_engine");
    const dispatchCfg = await loadDispatchConfig(db);
    const lastFanout = Number(md0.last_fanout_at_ms ?? 0) || 0;
    if (lastFanout > 0 && fanoutNow - lastFanout < dispatchCfg.driver_offer_retry_ms) {
      dispatchVerboseLog(
        "MATCH_FANOUT_THROTTLED",
        `rideId=${rid}`,
        `age_ms=${fanoutNow - lastFanout}`,
        `min_interval_ms=${dispatchCfg.driver_offer_retry_ms}`,
      );
      return;
    }
  }
  dispatchVerboseLog("MATCH_FANOUT_START", `rideId=${rid}`, `market=${market}`);
  try {
    const { logDispatchRideContext } = require("./dispatch_engine/dispatch_observability");
    logDispatchRideContext(rid, ridePayload);
  } catch (_) {}
  try {
    const { ensureDispatchMetrics } = require("./dispatch_engine/dispatch_metrics_engine");
    await ensureDispatchMetrics(db, rid);
  } catch (_) {}

  const marketPressureHeld = Boolean(fanoutOptions.marketPressureHeld);
  const { beginMarketFanout, endMarketFanout } = require("./dispatch_engine/dispatch_fanout_backpressure_engine");
  let marketPressure = { allowed: true, batchSizeAdjust: 0 };
  if (!marketPressureHeld) {
    marketPressure = await beginMarketFanout(db, market);
    if (!marketPressure.allowed) {
      dispatchVerboseLog("MATCH_FANOUT_ABORT", `rideId=${rid}`, "reason=backpressure");
      return;
    }
  }

  try {
  const gates = await loadDispatchGates(db);
  const useSoft = Boolean(gates.soft_verification);

  const pickup = ridePayload.pickup && typeof ridePayload.pickup === "object" ? ridePayload.pickup : {};
  const dropoff =
    ridePayload.dropoff && typeof ridePayload.dropoff === "object" ? ridePayload.dropoff : null;
  const now = nowMs();
  const { loadDispatchConfig } = require("./dispatch_engine/dispatch_config_engine");
  const dispatchCfg = await loadDispatchConfig(db);
  let batchSize = dispatchCfg.driver_offer_batch_size;
  if (marketPressure.batchSizeAdjust) {
    batchSize = Math.max(1, batchSize + marketPressure.batchSizeAdjust);
  }
  const expiresAt = now + dispatchCfg.driver_offer_lease_ms;

  const candidateSamples = [];
  const rejectedDriverSamples = [];
  const allCandidates = [];

  async function evaluateDriverMap(driverMap) {
    for (const [driverId, profile] of Object.entries(driverMap)) {
      const d = normUid(driverId);
      if (!d || !profile || typeof profile !== "object") continue;
      let busyRid = null;
      try {
        const {
          resolveValidatedBlockingTripForDriver,
        } = require("./driver_active_pointer_guard");
        const resolved = await resolveValidatedBlockingTripForDriver(
          db,
          d,
          "match_fanout",
          rid,
        );
        busyRid = resolved.blockingTripId;
        if (busyRid) {
          try {
            await removeDriverFromDispatchIndexWhenUnavailable(db, d, "active_ride");
          } catch (_) {}
        }
        if (resolved.cleared.length > 0) {
          logger.info("MATCH_FANOUT_STALE_POINTER_CLEARED", {
            rideId: rid,
            driverId: d,
            cleared: resolved.cleared,
          });
        }
      } catch (_) {}
      assertDriverCanonicalFieldsAligned(profile, d);
      try {
        const {
          logDispatchDriverContext,
        } = require("./dispatch_engine/dispatch_observability");
        const { resolveDriverCoordsForDispatch } = require("./dispatch_engine/dispatch_driver_location");
        const coords = resolveDriverCoordsForDispatch(profile, now);
        logDispatchDriverContext(d, profile, coords);
      } catch (_) {}
      const cand = evaluateDriverMatchCandidate(d, profile, ridePayload, gates, now, {
        activeRideId: busyRid,
        useSoft,
        driverLastSeenMs:
          Number(profile.last_active_at ?? profile.last_seen_at ?? 0) || null,
      });
      cand._profile = profile;
      allCandidates.push(cand);
      if (candidateSamples.length < 32) {
        candidateSamples.push({
          driverId: d,
          dispatch_market_id: cand.dispatch_market_id,
          service_area_city_id: cand.service_area_city_id,
          location_mode: cand.location_mode,
          distance_to_pickup_km: cand.distance_to_pickup_km,
          priority_group: cand.priority_group,
          priority_label: cand.priority_label,
          allowed: cand.allowed,
          filtered_reason: cand.filtered_reason,
        });
      }
      if (!cand.allowed && rejectedDriverSamples.length < 20) {
        rejectedDriverSamples.push(cand);
      }
      logger.info("MATCH_DRIVER_FILTER_TRACE", { rideId: rid, market, ...cand });
      const prof = profile && typeof profile === "object" ? profile : {};
      const traceStatus = String(prof.status ?? "").trim().toLowerCase() || "(none)";
      const traceDispatchState =
        String(prof.dispatch_state ?? "").trim().toLowerCase() || "(none)";
      const traceServiceAreaCity =
        String(prof.service_area_city_id ?? prof.rollout_city_id ?? "").trim() || "(none)";
      const traceDispatchMarket =
        String(cand.dispatch_market_id ?? prof.dispatch_market_id ?? prof.canonical_market_id ?? "")
          .trim() || "(none)";
      const traceReason = cand.allowed
        ? "eligible"
        : String(cand.filtered_reason ?? "unknown").trim() || "unknown";
      console.log(
        "MATCH_DRIVER_FILTER_TRACE",
        `rideId=${rid}`,
        `driverId=${d}`,
        `status=${traceStatus}`,
        `dispatch_state=${traceDispatchState}`,
        `service_area_city=${traceServiceAreaCity}`,
        `dispatch_market_id=${traceDispatchMarket}`,
        `reason=${traceReason}`,
      );
      if (cand.allowed) {
        console.log("MATCH_ELIGIBLE", `rideId=${rid}`, `driverId=${d}`);
        logMatchLocationSource(logger, d, profile, ridePayload, { ok: true }, now);
      } else {
        console.log("MATCH_REJECT", `rideId=${rid}`, `driverId=${d}`, `reason=${traceReason}`);
      }
    }
  }

  const pickupLat = Number(pickup.lat ?? pickup.latitude ?? "");
  const pickupLng = Number(pickup.lng ?? pickup.longitude ?? "");
  const radiusKm =
    dispatchCfg.matching_retry_radius_km + (Number(fanoutOptions.radiusExpandKm) || 0);
  const rideServiceArea =
    String(
      ridePayload.resolved_service_city_id ??
        ridePayload.service_city_id ??
        ridePayload.rollout_city_id ??
        "",
    ).trim() || "(none)";
  console.log(
    "MATCH_DRIVER_POOL_QUERY",
    `market=${market}`,
    `serviceArea=${rideServiceArea}`,
  );

  let raw = {};
  if (Number.isFinite(pickupLat) && Number.isFinite(pickupLng)) {
    try {
      const {
        loadAvailableDriversNearPickup,
      } = require("./dispatch_engine/dispatch_available_drivers_index");
      raw = await loadAvailableDriversNearPickup(db, market, pickupLat, pickupLng, {
        radiusKm,
        fastRecovery: Boolean(fanoutOptions.fastRecovery),
      });
    } catch (indexErr) {
      logger.info("MATCH_FANOUT_INDEX_FALLBACK", {
        rideId: rid,
        error: String(indexErr?.message || indexErr),
      });
    }
  }
  if (Object.keys(raw).length === 0) {
    raw = await loadDriversForDispatchMarket(db, market);
  }
  let scanCount = Object.keys(raw).length;
  console.log("MATCH_DRIVER_POOL_READY", `rideId=${rid}`, `count=${scanCount}`);
  dispatchVerboseLog("MATCH_DRIVER_SCAN_COUNT", `count=${scanCount}`);
  if (scanCount === 0) {
    console.log(
      "MATCH_FANOUT_HINT",
      "no_drivers_in_query",
      `dispatch_market_index_empty_for_market=${market}`,
    );
    try {
      const { recordNoCandidate } = require("./dispatch_engine/dispatch_production_metrics");
      recordNoCandidate();
    } catch (_) {}
  }

  await evaluateDriverMap(raw);

  if (useSoft && !allCandidates.some((c) => c.allowed)) {
    const broadAlready = Number(md0.broad_scan_blocked_at_ms ?? 0) > 0;
    console.log(
      "DISPATCH_BROAD_SCAN_BLOCKED",
      `rideId=${rid}`,
      `market=${market}`,
      `indexed=${scanCount}`,
      `already_logged=${broadAlready}`,
    );
    try {
      await db.ref(`ride_requests/${rid}/match_debug`).update({
        broad_scan_blocked_at_ms: fanoutNow,
      });
    } catch (_) {}
  }

  const eligibleSorted = sortEligibleCandidates(allCandidates);
  const eligibleDriverCount = eligibleSorted.length;
  console.log(
    "MATCH_LATENCY_DRIVER_POOL_READY",
    `rideId=${rid}`,
    `eligible=${eligibleDriverCount}`,
    `indexed=${scanCount}`,
    `durationMs=${nowMs() - fanoutNow}`,
  );
  const rejectionCounts = {};
  const { canonicalMatchRejectReason, logDispatchFanoutSummary } = require(
    "./dispatch_engine/dispatch_observability",
  );
  for (const c of allCandidates) {
    if (c.allowed) continue;
    const key = canonicalMatchRejectReason(c.filtered_reason);
    rejectionCounts[key] = (rejectionCounts[key] || 0) + 1;
  }
  logDispatchFanoutSummary({
    rideId: rid,
    market,
    indexed_driver_count: scanCount,
    eligible_count: eligibleDriverCount,
    rejected_count: allCandidates.length - eligibleDriverCount,
    rejection_reason_breakdown: rejectionCounts,
  });
  if (eligibleDriverCount === 0 && scanCount > 0) {
    for (const c of allCandidates) {
      if (c.allowed) continue;
      const d = normUid(c.driver_id);
      const reason = String(c.filtered_reason ?? "unknown").trim() || "unknown";
      console.log("MATCH_REJECT", `rideId=${rid}`, `driverId=${d}`, `reason=${reason}`);
    }
    console.log(
      "MATCH_FANOUT_ZERO_ELIGIBLE",
      `rideId=${rid}`,
      `indexed=${scanCount}`,
      `rejection_breakdown=${JSON.stringify(rejectionCounts)}`,
    );
    try {
      const { recordNoCandidate } = require("./dispatch_engine/dispatch_production_metrics");
      recordNoCandidate();
    } catch (_) {}
  }
  const nearestDriverIds = eligibleSorted.slice(0, 8).map((c) => c.driver_id);
  const skipIds = await loadFanoutSkipDriverIds(db, rid, ridePayload);
  for (const skippedId of skipIds) {
    logger.info("MATCH_QUEUE_SKIP", {
      rideId: rid,
      driverId: skippedId,
      reason: "prior_fanout_or_exhausted",
    });
  }
  const remainingPool = eligibleSorted.filter((c) => !skipIds.has(normUid(c.driver_id)));
  const batch = selectNextFanoutBatch(remainingPool, new Set(), batchSize);
  const batchRemaining = Math.max(0, remainingPool.length - batch.length);
  const batchDriverIds = batch.map((item) => item.driverId);
  logger.info("MATCH_BATCH_FANOUT", {
    rideId: rid,
    market,
    batch_number:
      (Number(ridePayload?.match_debug?.fanout_batch_number ?? 0) || 0) + (batch.length > 0 ? 1 : 0),
    batch_driver_ids: batchDriverIds,
    batch_size: batch.length,
    eligible_total: eligibleDriverCount,
    remaining_after_batch: batchRemaining,
    skipped_prior: skipIds.size,
  });
  for (const cand of eligibleSorted) {
    const d = normUid(cand.driver_id);
    if (!d || batchDriverIds.includes(d) || skipIds.has(d)) {
      continue;
    }
    logger.info("MATCH_QUEUE_SKIP", {
      rideId: rid,
      driverId: d,
      reason: batchRemaining > 0 ? "waiting_next_batch" : "not_in_current_batch",
      priority_group: cand.priority_group,
    });
  }

  const writtenUids = new Set();
  const queueWriteByDriver = {};
  let offersWritten = 0;
  const batchNumber =
    (Number(ridePayload?.match_debug?.fanout_batch_number ?? 0) || 0) + (batch.length > 0 ? 1 : 0);

  console.log(
    "MATCH_OFFERS_WRITE_START",
    `rideId=${rid}`,
    `driverIds=[${batchDriverIds.join(",")}]`,
  );

  for (const item of batch) {
    const d = item.driverId;
    const profile = item.profile;
    console.log(
      "MATCH_DRIVER_ELIGIBLE",
      `uid=${d}`,
      `priority_group=${item.candidate.priority_group}`,
      `distance_km=${item.candidate.distance_to_pickup_km}`,
    );
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
      profile,
    );
    queueWriteByDriver[d] = ok;
    if (ok) {
      writtenUids.add(d);
      offersWritten += 1;
    } else {
      logger.warn("MATCH_QUEUE_SKIP", {
        rideId: rid,
        driverId: d,
        reason: "queue_write_failed",
      });
    }
  }
  console.log("MATCH_OFFERS_WRITTEN", `rideId=${rid}`, `count=${offersWritten}`);
  console.log(
    "MATCH_LATENCY_OFFERS_WRITTEN",
    `rideId=${rid}`,
    `offersWritten=${offersWritten}`,
    `durationMs=${nowMs() - fanoutNow}`,
  );
  console.log("MATCH_FANOUT_DONE", `rideId=${rid}`, `count=${offersWritten}`);

  const noEligibleReason =
    offersWritten === 0
      ? eligibleDriverCount === 0
        ? scanCount === 0
          ? "no_drivers_in_market"
          : "all_drivers_filtered"
        : batchRemaining > 0
          ? "waiting_next_batch"
          : "all_batches_exhausted"
      : null;
  const offerDeliveryStatus = offersWritten > 0 ? "offers_sent" : "no_eligible_drivers";
  const matchingBlockReason =
    noEligibleReason === "all_drivers_filtered" && rejectedDriverSamples.length > 0
      ? String(rejectedDriverSamples[0]?.filtered_reason ?? "").trim() || noEligibleReason
      : noEligibleReason;
  const matchingState = deriveMatchingState({
    eligibleCount: eligibleDriverCount,
    offersWritten,
    batchRemaining,
  });
  const matchDebugNow = nowMs();
  const priorExhausted = Array.isArray(ridePayload?.match_debug?.exhausted_driver_ids)
    ? ridePayload.match_debug.exhausted_driver_ids
    : [];

  await db.ref(`ride_requests/${rid}/match_debug`).set({
    last_fanout_at_ms: matchDebugNow,
    matching_attempted_at: matchDebugNow,
    eligible_driver_count: eligibleDriverCount,
    eligible_same_market_count: eligibleDriverCount,
    offers_written: offersWritten,
    offer_delivery_status: offerDeliveryStatus,
    matching_state: matchingState,
    reason: noEligibleReason,
    no_eligible_reason: noEligibleReason,
    matching_block_reason: matchingBlockReason,
    sampled_driver_ids: Array.from(writtenUids).slice(0, 12),
    nearest_driver_ids: nearestDriverIds,
    batch_driver_ids: batchDriverIds.length > 0 ? batchDriverIds : Array.from(writtenUids),
    queue_write_by_driver: queueWriteByDriver,
    queue_write_success:
      batch.length === 0 ? null : offersWritten === batch.length && offersWritten > 0,
    fanout_batch_number: batchNumber,
    fanout_batch_size: FANOUT_BATCH_SIZE,
    batch_remaining_eligible: batchRemaining,
    candidate_driver_samples: candidateSamples,
    rejected_driver_samples: rejectedDriverSamples,
    exhausted_driver_ids: priorExhausted,
    payment_status: String(ridePayload.payment_status ?? "").trim().toLowerCase() || null,
    payment_reference:
      String(ridePayload.payment_reference ?? ridePayload.customer_transaction_reference ?? "").trim() ||
      null,
    dispatch_market_id: market,
    ride_service_city_id: String(ridePayload.resolved_service_city_id ?? "").trim() || null,
    drivers_in_market_query: scanCount,
    checked_at: ServerValue.TIMESTAMP,
    updated_at: matchDebugNow,
  });
  const ridePoolPatch = {
    matching_attempted_at: matchDebugNow,
    eligible_driver_count: eligibleDriverCount,
    offers_written: offersWritten,
    no_eligible_reason: noEligibleReason,
    matching_block_reason: matchingBlockReason,
    matching_state: matchingState,
  };
  if (offersWritten > 0 && isOpenPoolRide(ridePayload)) {
    ridePoolPatch.expires_at = expiresAt;
    ridePoolPatch.request_expires_at = expiresAt;
    ridePoolPatch.trip_state = TRIP_STATE.searching;
    ridePoolPatch.status = "searching";
  }
  await db.ref(`ride_requests/${rid}`).update(ridePoolPatch);

  if (offersWritten === 0) {
    logger.warn("RIDE_OFFER_AUDIT", {
      event: eligibleDriverCount === 0 ? "no_eligible_drivers" : "batch_waiting",
      rideId: rid,
      market,
      drivers_in_market_query: scanCount,
      eligible_driver_count: eligibleDriverCount,
      batch_remaining: batchRemaining,
      matching_state: matchingState,
    });
  }

  dispatchVerboseLog(
    "MATCH_FANOUT_DONE",
    `rideId=${rid}`,
    `offersWritten=${offersWritten}`,
    `batch=${batch.length}`,
    `eligible=${eligibleDriverCount}`,
  );

  const pCoord = coordsFromPickup(pickup);
  logger.info("MATCH_HEALTH_AUDIT", {
    rideId: rid,
    payment_status: String(ridePayload.payment_status ?? "").trim().toLowerCase() || null,
    service_area:
      String(
        ridePayload.resolved_service_city_id ??
          ridePayload.service_city_id ??
          ridePayload.rollout_city_id ??
          "",
      ).trim() || null,
    dispatch_market_id: market,
    pickup_lat: Number.isFinite(pCoord.lat) ? pCoord.lat : null,
    pickup_lng: Number.isFinite(pCoord.lng) ? pCoord.lng : null,
    eligible_driver_count: eligibleDriverCount,
    nearest_driver_ids: nearestDriverIds,
    offers_written: offersWritten,
    no_eligible_reason: noEligibleReason,
    matching_state: matchingState,
    sampled_driver_ids: Array.from(writtenUids).slice(0, 8),
    rejected_driver_samples: rejectedDriverSamples,
    drivers_in_market_query: scanCount,
    fanout_batch_size: FANOUT_BATCH_SIZE,
  });

  if (offersWritten === 0 && !useSoft) {
    dispatchVerboseLog(
      "MATCH_FANOUT_HINT",
      "verification_may_block_test_drivers",
      "set_RTDB_app_config/nexride_dispatch",
      "soft_verification=true",
    );
  }
  } finally {
    if (!marketPressureHeld) {
      await endMarketFanout(db, market);
    }
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
  const ptrSnap = await db.ref(`rider_active_trip/${r}`).get();
  if (!ptrSnap.exists()) {
    return { ok: true };
  }
  const ptr = ptrSnap.val() || {};
  const prevId = normUid(ptr.ride_id ?? ptr.rideId);
  if (!prevId) {
    await db.ref(`rider_active_trip/${r}`).remove();
    return { ok: true };
  }
  const prevRef = db.ref(`ride_requests/${prevId}`);
  const prevSnap = await prevRef.get();
  const prev = prevSnap.val();
  if (!prev || typeof prev !== "object" || normUid(prev.rider_id) !== r) {
    await db.ref(`rider_active_trip/${r}`).remove();
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
    await db.ref(`rider_active_trip/${r}`).remove();
    return { ok: true };
  }
  if (!isOpenPoolRide(prev)) {
    // Stale pointer to a non-open ride (e.g. already cancelled/closed by server flow).
    // Clear it and allow creating a fresh request instead of surfacing rider_active_trip.
    await db.ref(`rider_active_trip/${r}`).remove();
    return { ok: true };
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
    if (supersedeFail === "not_open") {
      await db.ref(`rider_active_trip/${r}`).remove();
      return { ok: true };
    }
    return { ok: false, reason: "rider_active_trip", rideId: prevId };
  }
  await clearFanoutAndOffers(db, prevId);
  await db.ref(`rider_active_trip/${r}`).remove();
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
    return { activeTripWritten: false, driverActiveRideWritten: false };
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
      status: "accepted",
      request_status: "accepted",
      updated_at: now,
      trip_state: rideSummary?.trip_state ?? TRIP_STATE.driver_assigned,
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
    [`rider_active_trip/${r}`]: {
      ride_id: rid,
      updated_at: now,
    },
    [`driver_active_ride/${d}`]: { ride_id: rid, updated_at: now },
    [`drivers/${d}/active_ride_id`]: rid,
  });
  console.log("ACTIVE_TRIP_CREATED", rid, "rider=", r, "driver=", d);
  console.log("RIDER_ACTIVE_TRIP_UPDATED", r, "ride_id=", rid);
  console.log("DRIVER_ACTIVE_RIDE_UPDATED", d, "ride_id=", rid);
  return { activeTripWritten: true, driverActiveRideWritten: true };
}

async function clearActiveTripPointers(db, rideId, riderId, driverId) {
  const rid = normUid(rideId);
  const r = normUid(riderId);
  const d = normUid(driverId);
  const u = {};
  if (rid) u[`active_trips/${rid}`] = null;
  if (d) u[`driver_active_ride/${d}`] = null;
  if (Object.keys(u).length) {
    await db.ref().update(u);
  }
  if (r) {
    await clearRiderActiveTripPointerIfAllowed(db, r, rid);
  }
}

function legacyUiStatusForTripState(tripState) {
  const canon = normalizeCanonicalTripState(tripState);
  switch (canon) {
    case TRIP_STATE.searching:
      return "searching";
    case TRIP_STATE.assigned:
      return "accepted";
    case TRIP_STATE.arrived:
      return "arrived";
    case TRIP_STATE.on_trip:
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
  const createStartedMs = nowMs();
  if (!context.auth) {
    console.log("RIDER_CREATE_FAIL", "unauthorized");
    return { success: false, reason: "unauthorized" };
  }
  const riderId = normUid(context.auth.uid);
  console.log("RIDER_CREATE_START", riderId);
  const riderGates = await loadRiderCreateGates(db);
  console.log(
    "RIDER_CREATE_INPUT",
    `rider=${riderId}`,
    `market=${String(data?.market ?? data?.city ?? "").trim() || "(empty)"}`,
    `payment=${String(data?.payment_method ?? data?.paymentMethod ?? "").trim() || "(empty)"}`,
  );

  const bodyRider = normUid(data?.rider_id ?? data?.riderId);
  if (bodyRider && bodyRider !== riderId) {
    console.log("RIDER_CREATE_FAIL", riderId, "rider_mismatch");
    return { success: false, reason: "rider_mismatch" };
  }

  if (!(await riderProfileRequirementOk(db, riderId, riderGates, context.auth))) {
    console.log("RIDER_CREATE_FAIL", riderId, "no_user_profile");
    return { success: false, reason: "rider_profile_required" };
  }

  const identityGate =
    await riderFirestoreIdentity.evaluateRiderFirestoreIdentityForBooking(admin.firestore(), riderId);
  if (!identityGate.ok) {
    console.log("RIDER_CREATE_FAIL", riderId, identityGate.reason || "identity_denied");
    return { success: false, reason: identityGate.reason || "identity_denied" };
  }

  const flagsSnap = await db.ref(`rider_payment_flags/${riderId}`).get();
  const flags = flagsSnap.val() && typeof flagsSnap.val() === "object" ? flagsSnap.val() : {};
  const outstanding = Number(flags.outstandingCancellationFeesNgn ?? 0);
  if (Number.isFinite(outstanding) && outstanding > 0) {
    console.log("RIDER_CREATE_FAIL", riderId, "outstanding_waiting_balance", outstanding);
    return {
      success: false,
      reason: "outstanding_waiting_balance",
      outstanding_ngn: outstanding,
    };
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

  const prepaidFwRef = normUid(data?.prepaid_flutterwave_ref ?? data?.prepaidFlutterwaveRef ?? "");
  let intentMerged = null;
  /** @type {string} */
  let prepaidTransactionId = "";
  if (prepaidFwRef) {
    const prepaidPtxRef = db.ref(`payment_transactions/${prepaidFwRef}`);
    const ptxSnap = await prepaidPtxRef.get();
    const ptx = ptxSnap.val();
    if (!ptx || typeof ptx !== "object") {
      console.log("RIDER_CREATE_FAIL", riderId, "prepaid_transaction_missing");
      return { success: false, reason: "prepaid_transaction_missing" };
    }
    if (normUid(ptx.rider_id) !== riderId) {
      console.log("RIDER_CREATE_FAIL", riderId, "prepaid_forbidden");
      return { success: false, reason: "prepaid_forbidden" };
    }
    if (String(ptx.consumed_ride_id ?? "").trim()) {
      console.log("RIDER_CREATE_FAIL", riderId, "prepaid_already_used");
      return { success: false, reason: "prepaid_already_used" };
    }
    if (String(ptx.intent_abandoned_at ?? "").trim()) {
      console.log("RIDER_CREATE_FAIL", riderId, "prepaid_intent_abandoned");
      return { success: false, reason: "prepaid_intent_abandoned" };
    }
    if (!ptx.ride_intent || typeof ptx.ride_intent !== "object") {
      console.log("RIDER_CREATE_FAIL", riderId, "prepaid_invalid_intent");
      return { success: false, reason: "prepaid_invalid_intent" };
    }
    if (ptx.verified !== true) {
      console.log("RIDER_CREATE_FAIL", riderId, "prepaid_not_verified");
      return { success: false, reason: "prepaid_not_verified" };
    }
    prepaidTransactionId = String(ptx.transaction_id ?? ptx.flutterwave_transaction_id ?? "").trim();
    if (!prepaidTransactionId) {
      console.log("RIDER_CREATE_FAIL", riderId, "prepaid_missing_txn_id");
      return { success: false, reason: "prepaid_missing_txn_id" };
    }
    intentMerged = ptx.ride_intent;
  }

  const marketRaw =
    intentMerged?.market ?? intentMerged?.city ?? data?.market ?? data?.city ?? "";
  const market = canonicalDispatchMarket(marketRaw) || "lagos";

  const pickup =
    intentMerged && intentMerged.pickup && typeof intentMerged.pickup === "object"
      ? intentMerged.pickup
      : data?.pickup;
  const dropoff =
    intentMerged && intentMerged.dropoff && typeof intentMerged.dropoff === "object"
      ? intentMerged.dropoff
      : intentMerged &&
          intentMerged.destination &&
          typeof intentMerged.destination === "object"
        ? intentMerged.destination
        : data?.dropoff;
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

  const rolloutGate = await deliveryRegions.assertRolloutWithHints(
    admin.firestore(),
    market,
    pCoord.lat,
    pCoord.lng,
    "rides",
    {
      region_id: data?.service_region_id ?? data?.rollout_region_id,
      city_id: data?.service_city_id ?? data?.rollout_city_id,
    },
    { strict_ride_request_hints: true },
  );
  const resolvedMarket =
    normalizeDispatchKey(rolloutGate.dispatch_market_id || market) || canonicalDispatchMarket(market);
  if (!resolvedMarket) {
    console.log("RIDER_CREATE_FAIL", riderId, "missing_canonical_market");
    return { success: false, reason: "missing_canonical_market" };
  }
  if (!rolloutGate.ok) {
    console.log("RIDER_CREATE_FAIL", riderId, rolloutGate.reason || "rollout_denied");
    let reason = rolloutGate.reason || "service_area_unsupported";
    let message =
      rolloutGate.message || "NexRide is not available in your area yet.";
    if (
      reason === "pickup_outside_enabled_city" ||
      reason === "service_area_unsupported"
    ) {
      reason = "no_service_area_for_pickup";
      message = "NexRide is not available in this pickup area yet.";
    }
    return {
      success: false,
      reason,
      message,
      suggested_service_area_id: rolloutGate.suggested_service_area_id ?? null,
      suggested_service_area_name: rolloutGate.suggested_service_area_name ?? null,
      suggested_service_region_id: rolloutGate.suggested_service_region_id ?? null,
      suggested_state: rolloutGate.suggested_state ?? null,
      suggested_dispatch_market_id: rolloutGate.suggested_dispatch_market_id ?? null,
    };
  }

  const fare = Number(intentMerged?.fare ?? data?.fare ?? 0);
  if (!Number.isFinite(fare) || fare <= 0) {
    console.log("RIDER_CREATE_FAIL", riderId, "invalid_fare");
    return { success: false, reason: "invalid_fare" };
  }
  if (fare > riderGates.max_fare_ngn) {
    console.log("RIDER_CREATE_FAIL", riderId, "fare_above_limit");
    return { success: false, reason: "fare_above_limit" };
  }

  const { computeRiderPricing, assertClientTotalMatches } = require("./pricing_calculator");
  const pricing = computeRiderPricing({
    flow: "ride_booking",
    trip_fare_ngn: fare,
  });
  const totalMismatch = assertClientTotalMatches(
    pricing,
    data?.total_ngn ?? data?.totalNgn ?? intentMerged?.total_ngn,
  );
  if (!totalMismatch.ok) {
    console.log("RIDER_CREATE_FAIL", riderId, totalMismatch.reason);
    return {
      success: false,
      reason: totalMismatch.reason,
      reason_code: totalMismatch.reason_code,
      message: totalMismatch.message,
      retryable: totalMismatch.retryable,
    };
  }

  const currency =
    String(intentMerged?.currency ?? data?.currency ?? "NGN").trim().toUpperCase() || "NGN";
  const paymentMethod = String(data?.payment_method ?? data?.paymentMethod ?? "flutterwave")
    .trim()
    .toLowerCase();
  let paymentNormalized = paymentMethod.replace(/[\s-]+/g, "_");
  if (!PAYMENT_METHODS_ALLOWED.has(paymentNormalized)) {
    console.log("RIDER_CREATE_WARN", riderId, "unsupported_payment_method_fallback", paymentNormalized);
    paymentNormalized = "flutterwave";
  }
  if (prepaidFwRef) {
    paymentNormalized = "flutterwave";
  }

  const rideRef = db.ref("ride_requests").push();
  const rideId = normUid(rideRef.key);
  if (!rideId) {
    console.log("RIDER_CREATE_FAIL", riderId, "ride_id_alloc_failed");
    return { success: false, reason: "ride_id_alloc_failed" };
  }

  const isCardRide =
    cardPayment.isCardPaymentMethod(paymentNormalized) && !prepaidFwRef;
  let cardAuthResult = null;
  if (isCardRide) {
    paymentNormalized = "card";
    cardAuthResult = await cardPayment.authorizeCardForRideCreation({
      db,
      riderId,
      context,
      data,
      pricing,
      currency,
      rideId,
    });
    if (!cardAuthResult?.ok) {
      console.log(
        "CARD_PAYMENT_BLOCKED_MATCHING",
        `rideId=${rideId}`,
        `riderId=${riderId}`,
        `reason=${cardAuthResult?.reason || "card_authorization_failed"}`,
      );
      return {
        success: false,
        reason: cardAuthResult?.reason || "card_authorization_failed",
        message:
          "Card authorization failed. Please try another card or payment method.",
      };
    }
  }

  const paymentStatus = prepaidFwRef
    ? "paid"
    : cardAuthResult?.ok
      ? cardAuthResult.payment_status
      : paymentNormalized === "bank_transfer"
        ? "pending_manual_confirmation"
        : "pending";

  const distanceKm =
    Number(intentMerged?.distance_km ??
      intentMerged?.distanceKm ??
      data?.distance_km ??
      data?.distanceKm ??
      0) || 0;
  const etaMin =
    Number(
      intentMerged?.eta_min ?? intentMerged?.etaMin ?? data?.eta_min ?? data?.etaMin ?? 0,
    ) || 0;
  if (!Number.isFinite(distanceKm) || distanceKm < 0 || distanceKm > 3500) {
    console.log("RIDER_CREATE_FAIL", riderId, "invalid_distance");
    return { success: false, reason: "invalid_distance" };
  }
  if (!Number.isFinite(etaMin) || etaMin < 0 || etaMin > 36 * 60) {
    console.log("RIDER_CREATE_FAIL", riderId, "invalid_eta");
    return { success: false, reason: "invalid_eta" };
  }
  const searchWindowMs = 45_000;
  const expiresAt = nowMs() + searchWindowMs;

  const trackToken = normUid(db.ref().push().key);
  if (!trackToken) {
    console.log("RIDER_CREATE_FAIL", riderId, "track_token_alloc_failed");
    return { success: false, reason: "track_token_alloc_failed" };
  }

  const ts = nowMs();
  const riderNameFromBody = String(data?.rider_name ?? data?.riderName ?? "").trim();
  const riderNameFromToken = String(context.auth?.token?.name ?? "").trim();
  const riderEmail = String(context.auth?.token?.email ?? "").trim();
  const riderName = riderNameFromBody ||
    riderNameFromToken ||
    (riderEmail ? riderEmail.split("@")[0] : "") ||
    "Rider";
  const payload = {
    ride_id: rideId,
    rider_id: riderId,
    rider_name: riderName,
    driver_id: "waiting",
    track_token: trackToken,
    market,
    market_pool: market,
    status: "requesting",
    trip_state: "requesting",
    pickup,
    destination: dropoff && typeof dropoff === "object" ? dropoff : null,
    dropoff: dropoff && typeof dropoff === "object" ? dropoff : null,
    fare,
    platform_fee_ngn: pricing.platform_fee_ngn,
    small_order_fee_ngn: pricing.small_order_fee_ngn,
    total_ngn: pricing.total_ngn,
    fee_breakdown: pricing.fee_breakdown,
    currency,
    distance_km: distanceKm,
    eta_min: etaMin,
    payment_method: paymentNormalized,
    payment_status: paymentStatus,
    payment_transaction_id: prepaidFwRef
      ? prepaidTransactionId
      : cardAuthResult?.ok
        ? cardAuthResult.payment_transaction_id
        : null,
    customer_transaction_reference: prepaidFwRef
      ? prepaidFwRef
      : cardAuthResult?.ok
        ? cardAuthResult.tx_ref
        : String(data?.customer_transaction_reference ?? data?.customerTransactionReference ?? "")
              .trim() || null,
    payment_reference: prepaidFwRef
      ? prepaidFwRef
      : cardAuthResult?.ok
        ? cardAuthResult.tx_ref
        : String(data?.payment_reference ?? data?.paymentReference ?? "").trim() || null,
    payment_intent_id: cardAuthResult?.ok ? cardAuthResult.payment_intent_id : null,
    authorization_ref: cardAuthResult?.ok ? cardAuthResult.authorization_ref : null,
    flw_ref: cardAuthResult?.ok ? cardAuthResult.flw_ref : null,
    card_payment_method_id: cardAuthResult?.ok ? cardAuthResult.payment_method_id : null,
    payment_recipient: paymentNormalized === "bank_transfer" ? "nexride" : null,
    created_at: ts,
    updated_at: ts,
    expires_at: expiresAt,
    request_expires_at: expiresAt,
    search_timeout_at: expiresAt,
    accepted_at: null,
    completed_at: null,
    cancelled_at: null,
    service_type: String(
      intentMerged?.service_type ?? data?.service_type ?? data?.serviceType ?? "ride",
    ).trim(),
    /** Car-hailing (Grab/Bolt-style); fan-out matches only drivers with compatible vehicle + ride capability */
    vehicle_type: "car",
    requested_vehicle_type: "car",
    resolved_service_region_id: rolloutGate.region_id || null,
    resolved_service_city_id: rolloutGate.city_id || null,
    resolved_dispatch_market_id: resolvedMarket || null,
    dispatch_market_id: resolvedMarket,
    market_pool: resolvedMarket,
    match_debug: {
      matching_state: "pending_fanout",
      dispatch_market_id: resolvedMarket,
      resolved_dispatch_market_id: resolvedMarket || null,
      resolved_service_region_id: rolloutGate.region_id || null,
      resolved_service_city_id: rolloutGate.city_id || null,
      pickup_resolution_source:
        rolloutGate.pickup_resolution_source ?? rolloutGate.matched_by ?? null,
      pickup_resolution_distance_km: rolloutGate.distance_km ?? null,
      pickup_resolution_override_applied:
        rolloutGate.pickup_resolution_override_applied === true,
      pickup_resolution_warning: rolloutGate.pickup_resolution_warning ?? null,
      rider_hint_region_id: rolloutGate.rider_hint_region_id ?? null,
      rider_hint_city_id: rolloutGate.rider_hint_city_id ?? null,
      candidate_driver_samples: [],
      batch_driver_ids: [],
      nearest_driver_ids: [],
      created_at: ts,
    },
  };

  if (paymentNormalized === "bank_transfer" && !prepaidFwRef) {
    payload.payment_reference = rideId;
    payload.customer_transaction_reference = rideId;
  }

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

  const md = intentMerged?.ride_metadata ?? data?.ride_metadata ?? data?.rideMetadata;
  if (md && typeof md === "object") {
    for (const [k, v] of Object.entries(md)) {
      if (!RIDER_CREATE_METADATA_ALLOW.has(k)) {
        continue;
      }
      payload[k] = v;
    }
  }

  applyCanonicalDispatchGeoToRidePayload(payload, {
    canonical_market_id: resolvedMarket,
    region_id: rolloutGate.region_id || null,
    city_id: rolloutGate.city_id || null,
    country_code: "ng",
  });

  if (prepaidFwRef) {
    const prepaidPath = `payment_transactions/${prepaidFwRef}`;
    const ptRef = db.ref(prepaidPath);

    const ptTxn = await ptRef.transaction((cur) => {
      if (cur === null) {
        return cur;
      }
      if (!cur || typeof cur !== "object") {
        return undefined;
      }
      if (normUid(cur.rider_id) !== riderId) {
        return undefined;
      }
      if (cur.verified !== true) {
        return undefined;
      }
      if (String(cur.consumed_ride_id ?? "").trim()) {
        return undefined;
      }
      if (String(cur.intent_abandoned_at ?? "").trim()) {
        return undefined;
      }
      return {
        ...cur,
        consumed_ride_id: rideId,
        ride_id: rideId,
        updated_at: ts,
      };
    });

    const consumedSnap = ptTxn.snapshot;
    const consumedRow =
      consumedSnap && typeof consumedSnap.exists === "function" && consumedSnap.exists()
        ? consumedSnap.val()
        : null;
    const prepaidConsumeOk =
      ptTxn.committed === true &&
      consumedSnap &&
      typeof consumedSnap.exists === "function" &&
      consumedSnap.exists() &&
      consumedRow &&
      typeof consumedRow === "object" &&
      String(consumedRow.consumed_ride_id ?? "").trim() === rideId &&
      String(consumedRow.ride_id ?? "").trim() === rideId;

    if (!prepaidConsumeOk) {
      console.log("RIDER_CREATE_FAIL", riderId, "prepaid_consume_tx_abort");
      return { success: false, reason: "prepaid_already_used" };
    }
  }

  try {
    await rideRef.set(payload);
  } catch (e) {
    console.log("RIDER_CREATE_WRITE_FAIL", `path=ride_requests/${rideId}`, e?.message ?? e);
    console.log("RIDER_CREATE_WRITE_PAYLOAD", JSON.stringify(payload));
    if (prepaidFwRef) {
      try {
        await db.ref(`payment_transactions/${prepaidFwRef}`).update({
          consumed_ride_id: null,
          ride_id: null,
          updated_at: nowMs(),
        });
      } catch (rollbackErr) {
        console.log("PREPAID_ROLLBACK_FAIL", prepaidFwRef, rollbackErr?.message ?? rollbackErr);
      }
    }
    if (cardAuthResult?.ok) {
      await cardPayment.rollbackCardAuthorization(db, cardAuthResult);
    }
    return { success: false, reason: "ride_write_failed" };
  }
  if (cardAuthResult?.ok && cardAuthResult.tx_ref) {
    await db.ref(`payment_transactions/${cardAuthResult.tx_ref}`).update({
      ride_id: rideId,
      consumed_ride_id: rideId,
      updated_at: ts,
    });
  }
  try {
    await setRiderActiveTripPointer(db, riderId, rideId);
  } catch (e) {
    console.log("RIDER_ACTIVE_TRIP_POINTER_FAIL", `path=rider_active_trip/${riderId}`, e?.message ?? e);
    // Keep ride creation successful even if pointer write fails.
  }
  console.log("RIDER_CREATE_SUCCESS", rideId, market);
  console.log(
    "RIDER_CREATE_RIDE_OK",
    `rideId=${rideId}`,
    `market=${resolvedMarket}`,
    `serviceArea=${rolloutGate.city_id || "(none)"}`,
    `paymentStatus=${String(payload.payment_status ?? "").trim().toLowerCase() || "(none)"}`,
  );
  console.log(
    "MATCH_LATENCY_RIDE_CREATED",
    `rideId=${rideId}`,
    `durationMs=${nowMs() - createStartedMs}`,
  );
  try {
    const { indexSearchingRide } = require("./dispatch_engine/dispatch_searching_rides_index");
    await indexSearchingRide(db, rideId, payload);
    const { rebuildDispatchSnapshot } = require("./dispatch_engine/dispatch_snapshot_engine");
    await rebuildDispatchSnapshot(db, rideId, payload);
  } catch (_) {}
  const fanoutPayload = {
    ...payload,
    dispatch_market_id: resolvedMarket,
    market_pool: resolvedMarket,
    resolved_dispatch_market_id: resolvedMarket,
  };
  await fanOutDriverOffersIfEligible(db, rideId, fanoutPayload);
  try {
    const ptrSnap = await db.ref(`rider_active_trip/${riderId}`).get();
    const ptrVal = ptrSnap.val();
    const ptrRide =
      ptrVal && typeof ptrVal === "object"
        ? normUid(ptrVal.ride_id ?? ptrVal.rideId)
        : normUid(ptrVal);
    if (ptrRide !== rideId) {
      await setRiderActiveTripPointer(db, riderId, rideId);
      console.log(
        "RIDER_ACTIVE_POINTER_REASSERT",
        `riderId=${riderId}`,
        `rideId=${rideId}`,
        `prior=${ptrRide || "none"}`,
      );
    }
  } catch (reassertErr) {
    console.log(
      "RIDER_ACTIVE_POINTER_REASSERT_FAIL",
      `riderId=${riderId}`,
      `rideId=${rideId}`,
      reassertErr?.message ?? reassertErr,
    );
  }
  console.log(
    "MATCH_LATENCY_OFFERS_FANOUT_COMPLETE",
    `rideId=${rideId}`,
    `durationMs=${nowMs() - createStartedMs}`,
  );
  await writeAudit(db, {
    type: "ride_create",
    ride_id: rideId,
    rider_id: riderId,
    actor_uid: riderId,
  });

  await syncRideTrackPublic(db, rideId);

  return {
    success: true,
    rideId,
    trackToken,
    reason: "created",
    resolved_service_region_id: rolloutGate.region_id || null,
    resolved_service_city_id: rolloutGate.city_id || null,
    resolved_dispatch_market_id: rolloutGate.dispatch_market_id || null,
  };
}

/**
 * Rider-triggered rematch — retains canonical market from ride row (no Google API calls).
 */
async function retryRideMatching(data, context, db) {
  const rideId = normRideIdFromCallableData(data);
  const riderId = normUid(context?.auth?.uid);
  if (!rideId || !riderId) {
    return { success: false, reason: "unauthorized" };
  }
  const snap = await db.ref(`ride_requests/${rideId}`).get();
  const ride = snap.exists() && typeof snap.val() === "object" ? snap.val() : null;
  if (!ride) {
    return { success: false, reason: "ride_missing" };
  }
  if (normUid(ride.rider_id ?? ride.riderId) !== riderId) {
    return { success: false, reason: "forbidden" };
  }
  if (canonicalAssignedDriverId(ride)) {
    return { success: false, reason: "already_assigned" };
  }
  if (!paymentAllowsDispatch(ride)) {
    return { success: false, reason: "payment_not_ready" };
  }
  if (!isOpenPoolRide(ride)) {
    return { success: false, reason: "not_searching" };
  }
  const now = nowMs();
  const searchWindowMs = 45_000;
  const nextExpires = now + searchWindowMs;
  await db.ref(`ride_requests/${rideId}`).update({
    expires_at: nextExpires,
    request_expires_at: nextExpires,
    search_timeout_at: nextExpires,
    matching_state: "retry_fanout",
    updated_at: now,
  });
  const freshSnap = await db.ref(`ride_requests/${rideId}`).get();
  const fresh = freshSnap.val() && typeof freshSnap.val() === "object" ? freshSnap.val() : ride;
  assertRideCanonicalFieldsAligned(fresh, rideId);
  await fanOutDriverOffersIfEligible(db, rideId, fresh, { forceFanout: true });
  return {
    success: true,
    reason: "refanout",
    rideId,
    canonical_market_id: rideDispatchMarketFromPayload(fresh),
  };
}

async function acceptRideRequest(data, context, db) {
  dispatchVerboseLog("ACCEPT_REQUEST_RECEIVED");
  dispatchVerboseLog("DRIVER_ACCEPT_CALL_RECEIVED");
  dispatchVerboseLog("DRIVER_ACCEPT_PAYLOAD", acceptPayloadLogString(data));

  try {
    const rideId = normRideIdFromCallableData(data);
  const authUid = normUid(context.auth?.uid);
  const driverId = normDriverIdFromCallableData(data, authUid);

  let dbUrl = "";
  try {
    dbUrl = String(db.app?.options?.databaseURL ?? "");
  } catch (_) {
    dbUrl = "";
  }
  dispatchVerboseLog("DRIVER_ACCEPT_DB_URL", dbUrl || "(default)");

  dispatchVerboseLog("DRIVER_ACCEPT_START", rideId, driverId);

  if (!rideId || !driverId) {
    dispatchVerboseLog("DRIVER_ACCEPT_FAIL_REASON", rideId || "(empty)", "invalid_input");
    return { success: false, reason: "invalid_input" };
  }
  if (!context.auth || authUid !== driverId) {
    dispatchVerboseLog("DRIVER_ACCEPT_FAIL_REASON", rideId, "unauthorized");
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
  dispatchVerboseLog("DRIVER_ACCEPT_RIDE_LOOKUP_PATH", ridePath);

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
    dispatchVerboseLog(
      "DRIVER_ACCEPT_FAIL_REASON",
      rideId,
      "ride_missing",
      "ride_path_missing",
    );
    return { success: false, reason: "ride_not_found" };
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
  const riderNamePresent = String(pre?.rider_name ?? "").trim().length > 0;
  const paymentMethodPresent = String(pre?.payment_method ?? "").trim().length > 0;
  const prepaidRefPresent =
    String(pre?.prepaid_flutterwave_ref ?? "").trim().length > 0 ||
    String(pre?.customer_transaction_reference ?? "").trim().startsWith("nexride_");
  console.log(
    "DRIVER_ACCEPT_REQUIRED_FIELDS",
    `rideId=${rideId}`,
    `rider_name=${riderNamePresent}`,
    `payment_method=${paymentMethodPresent}`,
    `prepaid_ref_or_tx_ref=${prepaidRefPresent}`,
  );
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
  if (alreadyMine || preAssigned === driverId) {
    dispatchVerboseLog("DRIVER_ACCEPT_ALREADY_ACCEPTED_IDEMPOTENT", rideId, driverId);
    const riderIdempotent = normUid(pre.rider_id ?? pre.riderId);
    if (riderIdempotent) {
      await clearFanoutAndOffers(db, rideId, driverId);
      await setActiveTripPointers(db, rideId, riderIdempotent, driverId, pre);
    }
    await syncRideRealtimeMirrors(db, rideId, driverId);
    return {
      success: true,
      idempotent: true,
      reason: "already_accepted",
      accept_win_path: "idempotent",
    };
  }

  const gates = await loadDispatchGates(db);
  const drvSnap = await db.ref(`drivers/${driverId}`).get();
  const drvProf = drvSnap.val();
  if (!drvProf || typeof drvProf !== "object") {
    dispatchVerboseLog("DRIVER_ACCEPT_DRIVER_PROFILE", `driverId=${driverId}`, "exists=false");
    dispatchVerboseLog("DRIVER_ACCEPT_FAIL_REASON", rideId, "driver_profile_missing");
    return { success: false, reason: "driver_profile_missing" };
  }
  dispatchVerboseLog("DRIVER_ACCEPT_DRIVER_PROFILE", `driverId=${driverId}`, "exists=true");
  const el = evaluateDriverForOffer(drvProf, gates, pre || {});
  if (!el.ok) {
    dispatchVerboseLog(
      "DRIVER_ACCEPT_FAIL_REASON",
      rideId,
      "driver_not_eligible",
      el.log || "verification_gate",
      el.detail,
    );
    return { success: false, reason: "driver_not_eligible" };
  }

  const vcap = evaluateCarRideVehicleAndCapability(drvProf, pre || {});
  if (!vcap.ok) {
    dispatchVerboseLog(
      "DRIVER_ACCEPT_FAIL_REASON",
      rideId,
      "driver_not_eligible_vehicle",
      vcap.log || "vehicle_capability",
      vcap.detail,
    );
    return { success: false, reason: "driver_not_eligible" };
  }

  const acceptStartedAt = acceptStartedAtFromCallableData(data);
  const offerSnap = await db.ref(`driver_offer_queue/${driverId}/${rideId}`).get();
  const offerPresent = snapExists(offerSnap);
  const offerVal =
    offerPresent && offerSnap.val() && typeof offerSnap.val() === "object"
      ? offerSnap.val()
      : null;
  const authority = await resolveOfferAcceptAuthority(
    db,
    rideId,
    driverId,
    pre || {},
    offerPresent,
    offerVal,
  );
  const authorityOfferVal = authority.offerVal || offerVal;
  const prePaymentStatus = String(pre?.payment_status ?? "").trim().toLowerCase();
  const acceptDebugCtx = {
    offerQueueExists: authority.offerQueueExists,
    offerAuthoritySource: authority.source,
    offerAuthorityValid: authority.valid,
    rideState: preTrip,
    rideStatus: preStatus,
    paymentStatus: prePaymentStatus,
    paymentMethod: normalizedPaymentMethod(pre || {}),
    acceptExpiresAtMs: effectiveAcceptExpiryMs(pre || {}, authorityOfferVal),
  };
  dispatchVerboseLog(
    "OFFER_ACCEPT_SERVER_CHECK",
    `rideId=${rideId}`,
    `driverId=${driverId}`,
    `status=${preStatus}`,
    `trip_state=${preTrip}`,
    `payment_status=${prePaymentStatus}`,
  );
  dispatchVerboseLog(
    "OFFER_ACCEPT_QUEUE_CHECK",
    `path=driver_offer_queue/${driverId}/${rideId}`,
    `exists=${authority.offerQueueExists}`,
    `authority=${authority.source}`,
    `authority_valid=${authority.valid}`,
  );
  const mdPre =
    pre?.match_debug && typeof pre.match_debug === "object" ? pre.match_debug : {};
  dispatchVerboseLog(
    "ACCEPT_AUTHORITY_CHECK",
    `rideId=${rideId}`,
    `driverId=${driverId}`,
    `source=${authority.source}`,
    `valid=${authority.valid}`,
    `queueExists=${authority.offerQueueExists}`,
    `batchIds=${JSON.stringify(mdPre.batch_driver_ids ?? []).slice(0, 200)}`,
    `offeredIds=${JSON.stringify(mdPre.offered_driver_ids ?? []).slice(0, 200)}`,
    `audit=${JSON.stringify(mdPre.queue_write_by_driver ?? {}).slice(0, 200)}`,
  );
  if (authority.withdrawn) {
    dispatchVerboseLog("DRIVER_ACCEPT_FAIL_REASON", rideId, "offer_withdrawn");
    await recordAcceptFailureDebug(db, rideId, driverId, {
      ...acceptDebugCtx,
      reason: "offer_withdrawn",
    });
    return { success: false, reason: "offer_not_found" };
  }
  if (!authority.valid) {
    dispatchVerboseLog("DRIVER_ACCEPT_FAIL_REASON", rideId, "offer_not_found");
    await recordAcceptFailureDebug(db, rideId, driverId, {
      ...acceptDebugCtx,
      reason: "offer_not_found",
    });
    return { success: false, reason: "offer_not_found" };
  }

  const leaseIdFromOffer = normUid(authorityOfferVal?.lease_id);

  const offerRid = normUid(authorityOfferVal?.ride_id);
  if (offerRid && offerRid !== rideId) {
    dispatchVerboseLog("DRIVER_ACCEPT_FAIL_REASON", rideId, "offer_ride_mismatch");
    await recordAcceptFailureDebug(db, rideId, driverId, {
      ...acceptDebugCtx,
      reason: "offer_ride_mismatch",
    });
    return { success: false, reason: "authority_missing" };
  }
  const offerMarket = canonicalDispatchMarket(authorityOfferVal?.market ?? "");
  const rideMarket = canonicalDispatchMarket(pre?.market_pool ?? pre?.market ?? "");
  if (!offerMarket || !rideMarket || offerMarket !== rideMarket) {
    dispatchVerboseLog("DRIVER_ACCEPT_FAIL_REASON", rideId, "authority_missing");
    await recordAcceptFailureDebug(db, rideId, driverId, {
      ...acceptDebugCtx,
      reason: "authority_missing",
    });
    return { success: false, reason: "authority_missing" };
  }

  const now = nowMs();
  if (leaseIdFromOffer) {
    const { validateLeaseForAccept } = require("./dispatch_engine/dispatch_offer_lease_engine");
    let leaseVal = null;
    try {
      const leaseSnap = await db
        .ref(`driver_offer_leases/${driverId}/${leaseIdFromOffer}`)
        .get();
      leaseVal = leaseSnap.exists() ? leaseSnap.val() : null;
    } catch (_) {}
    const leaseCheck = validateLeaseForAccept(leaseVal, rideId, driverId, now);
    if (!leaseCheck.valid && !leaseCheck.idempotent) {
      const leaseReason =
        leaseCheck.reason === "lease_expired" ? "offer_expired" : "offer_not_found";
      dispatchVerboseLog("DRIVER_ACCEPT_FAIL_REASON", rideId, leaseReason, leaseCheck.reason);
      await recordAcceptFailureDebug(db, rideId, driverId, {
        ...acceptDebugCtx,
        reason: leaseReason,
        lease_reason: leaseCheck.reason,
      });
      return { success: false, reason: leaseReason };
    }
  }
  if (!acceptWindowOpenForAccept(pre || {}, authorityOfferVal, acceptStartedAt, now)) {
    dispatchVerboseLog("DRIVER_ACCEPT_FAIL_REASON", rideId, "offer_expired");
    await recordAcceptFailureDebug(db, rideId, driverId, {
      ...acceptDebugCtx,
      reason: "offer_expired",
    });
    return { success: false, reason: "offer_expired" };
  }

  const paymentAllowsAccept = paymentAllowsAcceptRide(pre || {});
  if (!paymentAllowsAccept) {
    dispatchVerboseLog("DRIVER_ACCEPT_FAIL_REASON", rideId, "payment_not_verified");
    await recordAcceptFailureDebug(db, rideId, driverId, {
      ...acceptDebugCtx,
      reason: "payment_not_verified",
    });
    return { success: false, reason: "payment_not_dispatchable" };
  }
  if (!paymentAllowsDispatch(pre || {})) {
    console.log(
      "ACCEPT_PAYMENT_REVIEW_ALLOWED",
      `rideId=${rideId}`,
      `driverId=${driverId}`,
      `payment_status=${prePaymentStatus}`,
      `payment_method=${normalizedPaymentMethod(pre || {})}`,
    );
  }
  const lastFailure = { reason: "unknown" };
  const maxTxAttempts = 8;
  let tx = null;
  let committed = false;
  let acceptWinPath = "unknown";

  const {
    acquireAssignmentLocks,
    releaseAssignmentLocks,
    finalizeAssignmentLocks,
    shouldClearDriverLockBlockingAccept,
  } = require("./dispatch_engine/dispatch_assignment_lock_engine");
  let assignLocks = await acquireAssignmentLocks(db, rideId, driverId, now);
  if (
    !assignLocks.ok &&
    assignLocks.reason === "driver_assignment_held" &&
    normUid(assignLocks.holderRide) &&
    normUid(assignLocks.holderRide) !== rideId
  ) {
    const heldRideId = normUid(assignLocks.holderRide);
    try {
      const clearHeld = await shouldClearDriverLockBlockingAccept(
        db,
        driverId,
        heldRideId,
        rideId,
      );
      if (clearHeld) {
        dispatchVerboseLog(
          "ASSIGNMENT_LOCK_SELF_HEAL",
          `driverId=${driverId}`,
          `heldRide=${heldRideId}`,
          `targetRide=${rideId}`,
        );
        await db.ref(`dispatch_driver_assignment_locks/${driverId}`).remove().catch(() => {});
        assignLocks = await acquireAssignmentLocks(db, rideId, driverId, now);
      }
    } catch (e) {
      dispatchVerboseLog(
        "ASSIGNMENT_LOCK_SELF_HEAL_FAIL",
        `driverId=${driverId}`,
        `heldRide=${heldRideId}`,
        e?.message ?? e,
      );
    }
  }
  if (
    !assignLocks.ok &&
    (assignLocks.reason === "ride_lock_busy" ||
      (assignLocks.reason === "ride_assignment_held" &&
        !hasAssignedDriver(assignLocks.holder)))
  ) {
    try {
      await db.ref(`dispatch_assignment_locks/${rideId}`).remove().catch(() => {});
      dispatchVerboseLog(
        "ASSIGNMENT_LOCK_SELF_HEAL",
        `type=ride_lock`,
        `rideId=${rideId}`,
        `driverId=${driverId}`,
        `inner=${assignLocks.reason}`,
      );
      assignLocks = await acquireAssignmentLocks(db, rideId, driverId, now);
    } catch (e) {
      dispatchVerboseLog("ASSIGNMENT_LOCK_SELF_HEAL_FAIL", `rideId=${rideId}`, e?.message ?? e);
    }
  }
  if (!assignLocks.ok) {
    let lockReason = assignLocks.reason || "driver_already_set";
    if (
      lockReason === "ride_assignment_held" &&
      !hasAssignedDriver(assignLocks.holder)
    ) {
      lockReason = "ride_lock_busy";
    }
    const lockApi = mapApiAcceptFailureReason(lockReason, true, {
      offerWasValid: authority.valid,
    });
    dispatchVerboseLog(
      "ACCEPT_ASSIGNMENT_LOCK_FAIL",
      `rideId=${rideId}`,
      `inner=${assignLocks.reason}`,
      `reason=${lockApi}`,
      `holder=${assignLocks.holder ?? ""}`,
      `holderRide=${assignLocks.holderRide ?? ""}`,
    );
    await recordAcceptFailureDebug(db, rideId, driverId, {
      ...acceptDebugCtx,
      reason: lockApi,
    });
    return { success: false, reason: lockApi };
  }

  const lock = await acquireMatchLockOrReject(rideRef, rideId, driverId, now);
  if (!lock.ok) {
    await releaseAcceptMatchLock(rideRef, driverId);
    await releaseAssignmentLocks(db, rideId, driverId);
    const lockApi = mapApiAcceptFailureReason(lock.reason || "driver_already_set", true, {
      offerWasValid: authority.valid,
    });
    dispatchVerboseLog("ACCEPT_LOCK_FAIL", `rideId=${rideId}`, `reason=${lockApi}`);
    await recordAcceptFailureDebug(db, rideId, driverId, {
      ...acceptDebugCtx,
      reason: lockApi,
    });
    return { success: false, reason: lockApi };
  }

  console.log(
    "ACCEPT_TX_BEFORE",
    `rideId=${rideId}`,
    `status=${preStatus}`,
    `trip_state=${preTrip}`,
    `request_status=${String(pre?.request_status ?? "").trim()}`,
    `driver_id=${String(pre?.driver_id ?? "")}`,
    `matched_driver_id=${String(pre?.matched_driver_id ?? "")}`,
    `payment_status=${prePaymentStatus}`,
    `expires_at=${Number(pre?.expires_at ?? 0) || 0}`,
    `offer_expires_at=${Number(authorityOfferVal?.expires_at ?? 0) || 0}`,
  );
  dispatchVerboseLog("DRIVER_ACCEPT_TX_BEGIN", rideId, driverId);

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
      const decision = evaluateAcceptTransactionDecision(current, driverId, {
        rideId,
        authorityOfferVal,
        acceptStartedAt,
        now,
        log: true,
        authoritySource: authority.source,
        authorityValid: authority.valid,
        offerQueueExists: authority.offerQueueExists,
      });
      if (decision.action === "abort") {
        lastFailure.reason = decision.reason || "unknown";
        if (decision.reason === "driver_already_set") {
          console.log(
            "DRIVER_ACCEPT_TX_GUARD_FAIL",
            rideId,
            "reason=driver_already_set",
            `winner=${canonicalAssignedDriverId(current || {})}`,
          );
        } else if (decision.reason === "status_not_open") {
          console.log(
            "DRIVER_ACCEPT_TX_GUARD_FAIL",
            rideId,
            "reason=status_not_open",
            `trip_state=${String(current?.trip_state ?? "")}`,
            `status=${String(current?.status ?? "")}`,
          );
        } else if (decision.reason === "expired") {
          dispatchVerboseLog("DRIVER_ACCEPT_TX_GUARD_FAIL", rideId, "reason=expired");
        }
        return;
      }
      if (decision.action === "noop") {
        return current;
      }
      console.log(
        "ACCEPT_TX_COMMIT",
        `rideId=${rideId}`,
        `driverId=${driverId}`,
        `prior_driver_id=${String(current?.driver_id ?? "")}`,
        `prior_matched=${String(current?.matched_driver_id ?? "")}`,
      );
      return {
        ...current,
        ...decision.patch,
      };
    });

    tx = attemptResult.snapshot;
    committed = Boolean(attemptResult.committed);
    if (committed) {
      acceptWinPath = "transaction";
      dispatchVerboseLog("DRIVER_ACCEPT_TX_SUCCESS", rideId, driverId, "path=transaction");
      break;
    }

    if (
      lastFailure.reason !== "ride_missing" &&
      lastFailure.reason !== "tx_empty_current" &&
      lastFailure.reason !== "unknown"
    ) {
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
    dispatchVerboseLog("DRIVER_ACCEPT_MERGE_FALLBACK", rideId, "tx_reason=", failureReason);
    const merge = await applyDriverAcceptAdminMerge(db, rideRef, rideId, driverId, now, {
      acceptStartedAt,
    });
    if (merge.ok && merge.idempotent) {
      acceptWinPath = merge.path || "admin_merge_idempotent";
      dispatchVerboseLog("DRIVER_ACCEPT_TX_SUCCESS", rideId, driverId, "path=admin_merge_idempotent");
      const riderMerge = normUid(merge.finalRide?.rider_id ?? merge.finalRide?.riderId);
      if (riderMerge) {
        await clearFanoutAndOffers(db, rideId, driverId);
        await setActiveTripPointers(db, rideId, riderMerge, driverId, merge.finalRide);
      }
      await syncRideRealtimeMirrors(db, rideId, driverId);
      return {
        success: true,
        idempotent: true,
        reason: "already_accepted",
        accept_win_path: acceptWinPath,
      };
    }
    if (merge.ok) {
      committed = true;
      acceptWinPath = merge.path || "admin_merge";
      finalRideVal = merge.finalRide ?? null;
      failureReason = "unknown";
      console.log(
        "DRIVER_ACCEPT_TX_SUCCESS",
        rideId,
        driverId,
        `path=${acceptWinPath}`,
      );
    } else {
      failureReason = merge.reason || failureReason;
      dispatchVerboseLog("DRIVER_ACCEPT_MERGE_FAIL", rideId, failureReason);
    }
  }

  if (!committed) {
    const postDiag = rideDocFromSnapshot(await rideRef.get());
    const openUnassigned =
      postDiag &&
      ridePoolOpenForAccept(postDiag) &&
      !canonicalAssignedDriverId(postDiag) &&
      paymentAllowsAcceptRide(postDiag) &&
      acceptWindowOpenForAccept(postDiag, authorityOfferVal, acceptStartedAt, now);
    if (openUnassigned) {
      console.log(
        "DRIVER_ACCEPT_DIRECT_UPDATE_FALLBACK",
        rideId,
        driverId,
        `priorReason=${failureReason}`,
      );
      const direct = await attemptGuardedAcceptDirectWrite(db, rideRef, rideId, driverId, now, {
        authorityOfferVal,
        acceptStartedAt,
      });
      if (direct.ok) {
        committed = true;
        acceptWinPath = direct.path || "direct_update";
        finalRideVal = direct.finalRide ?? postDiag;
        console.log(
          "DRIVER_ACCEPT_TX_SUCCESS",
          rideId,
          driverId,
          `path=${acceptWinPath}`,
        );
      } else {
        failureReason = direct.reason || failureReason;
        dispatchVerboseLog("DRIVER_ACCEPT_DIRECT_UPDATE_FAIL", rideId, failureReason);
      }
    } else if (failureReason === "unknown") {
      failureReason = inferAcceptTxAbortReason(
        postDiag,
        driverId,
        authorityOfferVal,
        acceptStartedAt,
      );
      console.log(
        "DRIVER_ACCEPT_TX_DIAGNOSE",
        rideId,
        `inferred=${failureReason}`,
        `raw_driver_id=${postDiag ? String(postDiag.driver_id ?? "") : "n/a"}`,
        `trip_state=${postDiag ? String(postDiag.trip_state ?? "") : "n/a"}`,
        `status=${postDiag ? String(postDiag.status ?? "") : "n/a"}`,
      );
    }
  }

  if (!committed) {
    const reconcileSnap = rideDocFromSnapshot(await rideRef.get());
    if (canonicalAssignedDriverId(reconcileSnap || {}) === driverId) {
      committed = true;
      acceptWinPath = "post_read_reconcile";
      finalRideVal = reconcileSnap;
      console.log(
        "DRIVER_ACCEPT_POST_READ_RECONCILE",
        rideId,
        driverId,
        "reason=assignment_visible_after_abort",
      );
    }
  }

  if (!committed) {
    dispatchVerboseLog("DRIVER_ACCEPT_TX_ABORT", rideId, "reason=", failureReason);
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
      failureReason === "driver_already_set" ? "already_taken" : failureReason;
    const apiReason = mapApiAcceptFailureReason(rawReason, preflightDocPresent, {
      offerWasValid: authority.valid,
    });
    console.log(
      "ACCEPT_TX_GUARD_FAIL",
      `rideId=${rideId}`,
      `reason=${apiReason}`,
      `inner=${rawReason}`,
    );
    dispatchVerboseLog("DRIVER_ACCEPT_FAIL_REASON", rideId, apiReason);
    dispatchVerboseLog("DRIVER_ACCEPT_FAIL", rideId, apiReason);
    await recordAcceptFailureDebug(db, rideId, driverId, {
      ...acceptDebugCtx,
      reason: apiReason,
    });
    await releaseAcceptMatchLock(rideRef, driverId);
    await releaseAssignmentLocks(db, rideId, driverId);
    return {
      success: false,
      reason: apiReason,
      inner_reason: rawReason,
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
    await releaseAssignmentLocks(db, rideId, driverId);
    return { success: false, reason: "invalid_ride_payload" };
  }

  const postTrip = rideDocFromSnapshot(await rideRef.get()) ?? finalRideVal;
  console.log(
    "ACCEPT_TX_AFTER",
    `rideId=${rideId}`,
    `status=${String(postTrip?.status ?? "")}`,
    `trip_state=${String(postTrip?.trip_state ?? "")}`,
    `driver_id=${String(postTrip?.driver_id ?? "")}`,
    `matched_driver_id=${String(postTrip?.matched_driver_id ?? "")}`,
  );

  await finalizeAssignmentLocks(db, rideId, driverId);
  try {
    const { removeSearchingRide } = require("./dispatch_engine/dispatch_searching_rides_index");
    await removeSearchingRide(db, rideId, postTrip);
    const { rebuildDispatchSnapshot } = require("./dispatch_engine/dispatch_snapshot_engine");
    await rebuildDispatchSnapshot(db, rideId, postTrip);
  } catch (_) {}
  try {
    const { finalizeLeasesOnAccept } = require("./dispatch_engine/dispatch_offer_lease_engine");
    await finalizeLeasesOnAccept(db, rideId, driverId, leaseIdFromOffer);
  } catch (e) {
    console.log(
      "MATCHING_ACCEPT_LOCK_FAIL",
      `rideId=${rideId}`,
      `error=${String(e?.message || e)}`,
    );
  }
  await clearFanoutAndOffers(db, rideId, driverId);
  const queuesRemaining = await countOfferQueueRowsForRide(db, rideId);
  const pointerWrites = await setActiveTripPointers(
    db,
    rideId,
    riderId,
    driverId,
    postTrip,
  );
  await recordAcceptSuccessDebug(db, rideId, driverId, {
    offerAuthoritySource: authority.source,
  });
  console.log(
    "ACCEPT_ASSIGNMENT_PROPAGATED",
    `rideId=${rideId}`,
    `driverId=${driverId}`,
    `activeTripWritten=${pointerWrites.activeTripWritten}`,
    `driverActiveRideWritten=${pointerWrites.driverActiveRideWritten}`,
    `queuesCleared=${queuesRemaining === 0}`,
    `queuesRemaining=${queuesRemaining}`,
  );

  await ensureRideChatThread(db, rideId, riderId, driverId);
  await sendPushToUser(db, riderId, {
    notification: {
      title: "Driver accepted your ride",
      body: "Your driver has accepted the ride and is heading your way.",
    },
    data: {
      type: "ride_driver_assigned",
      rideId,
      status: "accepted",
    },
  });

  await writeAudit(db, {
    type: "ride_accept",
    ride_id: rideId,
    driver_id: driverId,
    actor_uid: driverId,
  });

  await syncRideRealtimeMirrors(db, rideId, driverId);

  console.log(
    "MATCH_ASSIGNED",
    `rideId=${rideId}`,
    `driverId=${driverId}`,
    `riderId=${riderId}`,
  );
  try {
    const { recordOfferAccepted } = require("./dispatch_engine/dispatch_production_metrics");
    recordOfferAccepted();
  } catch (_) {}
  try {
    await removeDriverFromDispatchIndexWhenUnavailable(db, driverId, "ride_accepted");
  } catch (_) {}
  dispatchVerboseLog(
    "ACCEPT_WIN_PATH",
    `rideId=${rideId}`,
    `driverId=${driverId}`,
    `path=${acceptWinPath}`,
  );

  return {
    success: true,
    idempotent: false,
    reason: "accepted",
    accept_win_path: acceptWinPath,
  };
  } catch (error) {
    console.error(
      "DRIVER_ACCEPT_UNHANDLED_ERROR",
      `message=${error?.message || error}`,
      `stack=${error?.stack || "no_stack"}`,
    );
    throw error;
  }
}

async function driverEnroute(data, context, db) {
  const rideId = normRideIdFromCallableData(data);
  const driverId = normUid(context.auth?.uid);
  if (!rideId || !context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const monetization = await resolveDriverMonetization(db, driverId);
  const settlementFee = monetization.isSubscription ? 0 : platformFeeNgn();
  const rideRef = db.ref(`ride_requests/${rideId}`);
  const preSnap = await rideRef.get();
  const preVal = preSnap.exists() ? preSnap.val() : null;
  let reason = "unknown";
  let committed = false;
  let postRide = preVal;
  const tx = await rideRef.transaction((cur) => {
    if (cur === null) {
      return cur;
    }
    if (!cur || typeof cur !== "object") {
      reason = "ride_missing";
      return;
    }
    if (canonicalAssignedDriverId(cur) !== driverId) {
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
      request_status: "accepted",
      arriving_at: cur.arriving_at ?? now,
      updated_at: now,
    };
  });
  if (tx.committed) {
    committed = true;
    postRide = tx.snapshot.val();
  } else if (reason === "ride_missing" && preSnap.exists()) {
    const cur = preVal && typeof preVal === "object" ? preVal : null;
    if (!cur) {
      reason = "ride_missing";
    } else if (canonicalAssignedDriverId(cur) !== driverId) {
      reason = "not_assigned_driver";
    } else {
      const ts = String(cur.trip_state ?? "").trim().toLowerCase();
      if (ts === TRIP_STATE.driver_arriving) {
        committed = true;
        postRide = cur;
      } else if (
        ts !== TRIP_STATE.driver_assigned &&
        ts !== TRIP_STATE.accepted &&
        ts !== "driver_accepted"
      ) {
        reason = "invalid_state";
      } else {
        const now = nowMs();
        const patch = {
          trip_state: TRIP_STATE.driver_arriving,
          status: legacyUiStatusForTripState(TRIP_STATE.driver_arriving),
          request_status: "accepted",
          arriving_at: cur.arriving_at ?? now,
          updated_at: now,
        };
        await rideRef.update(patch);
        committed = true;
        postRide = { ...cur, ...patch };
      }
    }
  }
  if (!committed) {
    return { success: false, reason };
  }
  await writeAudit(db, { type: "ride_enroute", ride_id: rideId, actor_uid: driverId });
  const riderId = normUid(postRide?.rider_id);
  if (riderId) {
    await sendPushToUser(db, riderId, {
      notification: {
        title: "Driver is en route",
        body: "Your driver is on the way to your pickup location.",
      },
      data: {
        type: "ride_driver_enroute",
        rideId,
        status: "driver_arriving",
      },
    });
  }
  await syncRideRealtimeMirrors(db, rideId, driverId);
  return { success: true, reason: "enroute" };
}

async function driverArrived(data, context, db) {
  const rideId = normRideIdFromCallableData(data);
  const driverId = normUid(context.auth?.uid);
  const arrivedStart = Date.now();
  traceLog({
    event: "DRIVER_ARRIVED",
    rideId,
    uid: driverId,
    role: "driver",
    path: `ride_requests/${rideId}/trip_state`,
    source: "driverArrived",
  });
  console.log(`ARRIVED_CALL_START rideId=${rideId} driverId=${driverId}`);
  if (!rideId || !context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const rideRef = db.ref(`ride_requests/${rideId}`);
  const preSnap = await rideRef.get();
  const preVal = preSnap.exists() ? preSnap.val() : null;
  console.log(
    `ARRIVED_RIDE_READ rideId=${rideId} exists=${preSnap.exists()} ` +
      `status=${String(preVal?.status ?? "")} trip_state=${String(preVal?.trip_state ?? "")} ` +
      `driver_id=${rideAssignedDriverUid(preVal)}`,
  );

  let reason = "unknown";
  let committed = false;
  let postRide = preVal;
  const tx = await rideRef.transaction((cur) => {
    const ev = evaluateDriverArrivedTransition(cur, driverId);
    reason = ev.reason;
    if (!ev.ok) {
      return;
    }
    if (ev.idempotent) {
      return ev.patch;
    }
    return ev.patch;
  });
  if (tx.committed) {
    committed = true;
    postRide = tx.snapshot.val();
    console.log(`ARRIVED_COMMIT_SUCCESS rideId=${rideId}`);
    console.log(
      `ARRIVED_WRITE_PATH path=ride_requests/${rideId}/trip_state value=${String(postRide?.trip_state ?? "")}`,
    );
    console.log(
      `ARRIVED_WRITE_PATH path=ride_requests/${rideId}/status value=${String(postRide?.status ?? "")}`,
    );
    console.log(
      `ARRIVED_WRITE_PATH path=ride_requests/${rideId}/driver_arrived value=${String(postRide?.driver_arrived ?? "")}`,
    );
  } else if (reason === "ride_missing" && preSnap.exists()) {
    const ev = evaluateDriverArrivedTransition(preVal, driverId);
    reason = ev.reason;
    if (ev.ok && ev.patch) {
      await rideRef.update(ev.patch);
      committed = true;
      postRide = { ...(preVal && typeof preVal === "object" ? preVal : {}), ...ev.patch };
      console.log(`ARRIVED_COMMIT_SUCCESS rideId=${rideId} source=fallback_update`);
      console.log(
        `ARRIVED_WRITE_PATH path=ride_requests/${rideId}/trip_state value=${String(postRide?.trip_state ?? "")}`,
      );
      console.log(
        `ARRIVED_WRITE_PATH path=ride_requests/${rideId}/status value=${String(postRide?.status ?? "")}`,
      );
    }
  }
  if (!committed) {
    console.log(`ARRIVED_CALL_FAIL rideId=${rideId} reason=${reason}`);
    return { success: false, reason };
  }
  await writeAudit(db, { type: "ride_arrived_pickup", ride_id: rideId, actor_uid: driverId });
  const riderId = normUid(postRide?.rider_id ?? postRide?.riderId);
  const arrivalStatus = legacyUiStatusForTripState(TRIP_STATE.arrived);
  const mirrorUpdates = {
    [`drivers/${driverId}/current_trip_status`]: arrivalStatus,
    [`drivers/${driverId}/status`]: arrivalStatus,
    [`drivers/${driverId}/updated_at`]: ServerValue.TIMESTAMP,
  };
  try {
    await db.ref().update(mirrorUpdates);
    if (riderId) {
      await setRiderActiveTripPointer(db, riderId, rideId);
      console.log("RIDER_ACTIVE_TRIP_POINTER", riderId, "ride_id=", rideId);
    }
  } catch (pointerErr) {
    console.warn("RIDER_ACTIVE_TRIP_POINTER_FAIL", pointerErr?.message ?? pointerErr);
  }
  if (riderId) {
    await sendPushToUser(db, riderId, {
      notification: {
        title: "Driver arrived",
        body: "Your driver has arrived at the pickup point.",
      },
      data: {
        type: "ride_driver_arrived",
        rideId,
        status: "arrived",
      },
    });
  }
  await syncRideRealtimeMirrors(db, rideId, driverId);
  return { success: true, reason: reason === "already_arrived" ? "already_arrived" : "arrived" };
}

async function startTrip(data, context, db) {
  const rideId = normRideIdFromCallableData(data);
  const driverId = normUid(context.auth?.uid);
  const startMs = Date.now();
  if (!rideId || !context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  traceLog({
    event: "START_TRIP",
    rideId,
    uid: driverId,
    role: "driver",
    path: `ride_requests/${rideId}`,
    source: "startTrip",
  });
  const rideRef = db.ref(`ride_requests/${rideId}`);
  const preResolve = await rideRef.get();
  traceLog({
    event: preResolve.exists() ? "START_TRIP_RESOLVE_RIDE" : "START_TRIP_RESOLVE_RIDE_MISSING",
    rideId,
    uid: driverId,
    role: "driver",
    path: `ride_requests/${rideId}`,
    trip_state: preResolve.exists()
      ? normalizeCanonicalTripState(preResolve.val()?.trip_state)
      : "",
    source: "startTrip",
  });
  if (!preResolve.exists()) {
    return { success: false, reason: "ride_missing" };
  }
  const preRide =
    preResolve.val() && typeof preResolve.val() === "object" ? preResolve.val() : null;
  let reason = "unknown";
  let committed = false;
  let postRide = preRide;
  const routeLogTimeoutMs = 3 * 60 * 1000;
  traceLog({
    event: "START_TRIP_TRANSACTION_BEGIN",
    rideId,
    uid: driverId,
    role: "driver",
    path: `ride_requests/${rideId}`,
    source: "startTrip",
  });
  const tx = await rideRef.transaction((cur) => {
    if (cur === null) {
      return cur;
    }
    if (!cur || typeof cur !== "object") {
      reason = "ride_missing";
      return;
    }
    if (rideAssignedDriverUid(cur) !== driverId) {
      reason = "not_assigned_driver";
      return;
    }
    const pmRawStart = cur.payment_method ?? cur.paymentMethod ?? "";
    const pmStart = String(pmRawStart ?? "")
      .trim()
      .toLowerCase()
      .replace(/[\s-]+/g, "_");
    const psStart = String(cur.payment_status ?? "").trim().toLowerCase();
    const ptidStart = String(cur.payment_transaction_id ?? cur.flw_tx_id ?? "").trim();
    /** @type {Record<string, unknown>} */
    const bankTransferPatch = {};
    if (cardPayment.isCardPaymentMethod(pmStart)) {
      if (!cardPayment.cardPaymentAllowsMatching(cur)) {
        console.log(
          "START_TRIP_BLOCKED_PAYMENT_PENDING",
          `rideId=${rideId}`,
          `driverId=${driverId}`,
          `payment_status=${psStart}`,
          `payment_method=${pmStart}`,
          `reason=card_not_authorized`,
        );
        reason = "card_authorization_pending";
        return;
      }
    } else if (pmStart === "bank_transfer") {
      const bankSettled =
        (psStart === "verified" || psStart === "paid") && Boolean(ptidStart);
      if (
        !bankSettled &&
        psStart !== "pending_transfer" &&
        !rideHasVerifiedOnlinePayment(cur)
      ) {
        console.log(
          "START_TRIP_BLOCKED_PAYMENT_PENDING",
          `rideId=${rideId}`,
          `driverId=${driverId}`,
          `payment_status=${psStart}`,
          `payment_method=${pmStart}`,
        );
        reason = "bank_transfer_pending_confirmation";
        return;
      }
      if (!bankSettled && psStart === "pending_transfer") {
        const bankTransferVa = require("./bank_transfer_va");
        const etaMin = Number(cur.eta_minutes ?? cur.estimated_duration_min ?? 15);
        bankTransferPatch.va_expires_at_ms = bankTransferVa.computeVaExpiryMs({ etaMinutes: etaMin });
        bankTransferPatch.va_payment_countdown_active = true;
      }
    }
    const ts = normalizeCanonicalTripState(cur.trip_state);
    if (ts === TRIP_STATE.on_trip) {
      return cur;
    }
    if (ts !== TRIP_STATE.arrived) {
      reason = "invalid_state";
      return;
    }
    const now = nowMs();
    return {
      ...cur,
      ...bankTransferPatch,
      trip_state: TRIP_STATE.on_trip,
      status: legacyUiStatusForTripState(TRIP_STATE.on_trip),
      started_at: cur.started_at ?? now,
      route_log_timeout_at: now + routeLogTimeoutMs,
      has_started_route_checkpoints: false,
      route_log_trip_started_checkpoint_at: null,
      start_timeout_at: null,
      updated_at: now,
    };
  });
  if (tx.committed) {
    committed = true;
    postRide = tx.snapshot.val();
  } else if (reason === "ride_missing" && preResolve.exists() && preRide) {
    if (rideAssignedDriverUid(preRide) !== driverId) {
      reason = "not_assigned_driver";
    } else {
      const ts = normalizeCanonicalTripState(preRide.trip_state);
      if (ts === TRIP_STATE.on_trip) {
        committed = true;
        postRide = preRide;
      } else if (ts !== TRIP_STATE.arrived && ts !== TRIP_STATE.assigned) {
        reason = "invalid_state";
      } else {
        const now = nowMs();
        const patch = {
          trip_state: TRIP_STATE.on_trip,
          status: "in_progress",
          started_at: preRide.started_at ?? now,
          trip_started_at: preRide.trip_started_at ?? now,
          route_log_timeout_at: now + routeLogTimeoutMs,
          has_started_route_checkpoints: false,
          route_log_trip_started_checkpoint_at: null,
          start_timeout_at: null,
          updated_at: now,
        };
        await rideRef.update(patch);
        committed = true;
        postRide = { ...preRide, ...patch };
      }
    }
  }
  if (!committed) {
    traceLog({
      event: "START_TRIP_TRANSACTION_FAIL",
      rideId,
      uid: driverId,
      role: "driver",
      path: `ride_requests/${rideId}`,
      trip_state: normalizeCanonicalTripState(
        tx.snapshot && tx.snapshot.exists() ? tx.snapshot.val()?.trip_state : "",
      ),
      source: "startTrip",
      elapsedMs: Date.now() - startMs,
      extra: { reason },
    });
    return { success: false, reason };
  }
  traceLog({
    event: "START_TRIP_TRANSACTION_OK",
    rideId,
    uid: driverId,
    role: "driver",
    path: `ride_requests/${rideId}/trip_state`,
    trip_state: TRIP_STATE.on_trip,
    source: "startTrip",
    elapsedMs: Date.now() - startMs,
  });
  await writeAudit(db, { type: "ride_start", ride_id: rideId, actor_uid: driverId });
  const riderId = normUid(postRide?.rider_id);
  if (riderId) {
    await sendPushToUser(db, riderId, {
      notification: {
        title: "Trip started",
        body: "Your trip has started. Enjoy your ride.",
      },
      data: {
        type: "ride_trip_started",
        rideId,
        status: "in_progress",
      },
    });
  }
  await syncRideRealtimeMirrors(db, rideId, driverId);
  return { success: true, reason: "started" };
}

async function completeTrip(data, context, db) {
  const rideId = normRideIdFromCallableData(data);
  const driverId = normUid(context.auth?.uid);
  if (!rideId || !context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const driverSnap = await db.ref(`drivers/${driverId}`).get();
  const driverData =
    driverSnap.val() && typeof driverSnap.val() === "object" ? driverSnap.val() : {};
  const subExpiresAt = Number(driverData.subscription_expires_at ?? 0);
  const isExpired = subExpiresAt > 0 && Date.now() > subExpiresAt;
  if (
    isExpired &&
    (driverData.commission_exempt === true || driverData.commissionExempt === true)
  ) {
    const now = nowMs();
    await db.ref(`drivers/${driverId}`).update({
      commission_exempt: false,
      commissionExempt: false,
      subscription_status: "expired",
      effectiveModel: "commission",
      subscription_renewal_reminder_sent: false,
      updated_at: now,
      "businessModel/subscription/status": "expired",
      "businessModel/commissionExempt": false,
      "businessModel/commission_exempt": false,
      "businessModel/effectiveModel": "commission",
    });
    console.log(
      "SUBSCRIPTION_EXPIRED_COMPLETE_TRIP",
      `driverId=${driverId}`,
      `expiredAt=${subExpiresAt}`,
    );
  }
  const monetization = await resolveDriverMonetization(db, driverId);
  const commissionPolicy = await resolveCommissionPolicy(db, driverId);
  console.log(
    "COMMISSION_EXEMPT",
    `driverId=${driverId}`,
    `exempt=${commissionPolicy.exempt}`,
    `reason=${commissionPolicy.reason}`,
  );
  const rideRef = db.ref(`ride_requests/${rideId}`);
  const preRideSnap = await rideRef.get();
  const preRide =
    preRideSnap.exists() && typeof preRideSnap.val() === "object" ? preRideSnap.val() : null;
  const financeBreakdown = rideFinance.computeRideFinanceBreakdown(preRide || {}, {
    commissionExempt: commissionPolicy.exempt,
  });
  if (preRide && cardPayment.isCardPaymentMethod(preRide.payment_method ?? preRide.paymentMethod)) {
    const capture = await cardPayment.captureRideCardOnCompletion({
      db,
      rideId,
      ride: preRide,
    });
    if (!capture.ok) {
      return { success: false, reason: capture.reason || "card_capture_failed" };
    }
  }
  let reason = "unknown";
  let committed = false;
  let postRide = preRide;
  const tx = await rideRef.transaction((cur) => {
    if (cur === null) {
      return cur;
    }
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
    const settlementPatch = rideFinance.buildRideSettlementPatch(financeBreakdown, "driver_complete_trip");
    return {
      ...cur,
      trip_state: TRIP_STATE.completed,
      status: legacyUiStatusForTripState(TRIP_STATE.completed),
      completed_at: cur.completed_at ?? now,
      trip_completed: true,
      trip_fare_ngn: financeBreakdown.trip_fare_ngn,
      booking_fee_ngn: financeBreakdown.booking_fee_ngn,
      platform_fee_ngn: financeBreakdown.booking_fee_ngn,
      commission_ngn: financeBreakdown.commission_ngn,
      driver_net_ngn: financeBreakdown.driver_net_ngn,
      selectedModel: monetization.selectedModel,
      effectiveModel: monetization.effectiveModel,
      ...settlementPatch,
      updated_at: now,
    };
  });
  if (tx.committed) {
    committed = true;
    postRide = tx.snapshot.val();
  } else if (reason === "ride_missing" && preRideSnap.exists() && preRide) {
    if (normUid(preRide.driver_id) !== driverId) {
      reason = "not_assigned_driver";
    } else {
      const ts = String(preRide.trip_state ?? "").trim().toLowerCase();
      if (ts === TRIP_STATE.completed || ts === "trip_completed") {
        committed = true;
        postRide = preRide;
      } else if (ts !== TRIP_STATE.in_progress && ts !== "trip_started") {
        reason = "invalid_state";
      } else if (!rideHasVerifiedOnlinePayment(preRide)) {
        reason = "payment_not_verified";
      } else {
        const now = nowMs();
        const settlementPatch = rideFinance.buildRideSettlementPatch(
          financeBreakdown,
          "driver_complete_trip",
        );
        const patch = {
          trip_state: TRIP_STATE.completed,
          status: legacyUiStatusForTripState(TRIP_STATE.completed),
          completed_at: preRide.completed_at ?? now,
          trip_completed: true,
          trip_fare_ngn: financeBreakdown.trip_fare_ngn,
          booking_fee_ngn: financeBreakdown.booking_fee_ngn,
          platform_fee_ngn: financeBreakdown.booking_fee_ngn,
          commission_ngn: financeBreakdown.commission_ngn,
          driver_net_ngn: financeBreakdown.driver_net_ngn,
          selectedModel: monetization.selectedModel,
          effectiveModel: monetization.effectiveModel,
          ...settlementPatch,
          updated_at: now,
        };
        await rideRef.update(patch);
        committed = true;
        postRide = { ...preRide, ...patch };
      }
    }
  }
  if (!committed) {
    return { success: false, reason };
  }
  const ride = postRide;
  const riderId = normUid(ride?.rider_id);
  await clearActiveTripPointers(db, rideId, riderId, driverId);
  try {
    const { releaseAssignmentLocks } = require("./dispatch_engine/dispatch_assignment_lock_engine");
    await releaseAssignmentLocks(db, rideId, driverId);
  } catch (e) {
    console.log(
      "COMPLETE_TRIP_LOCK_RELEASE_FAIL",
      `rideId=${rideId}`,
      `driverId=${driverId}`,
      e?.message ?? e,
    );
  }
  if (riderId) {
    await clearRiderActiveTripPointerIfAllowed(db, riderId, rideId);
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
  await syncRideRealtimeMirrors(db, rideId, driverId);

  if (rideHasVerifiedOnlinePayment(ride)) {
    const fin = await rideFinance.settleCompletedRideOnce(db, {
      rideId,
      ride,
      driverId,
      riderId,
      source: "complete_trip",
    });
    if (!fin.success && fin.reason !== "already_settled") {
      console.log(
        "FINANCE_SETTLE_FAIL",
        `rideId=${rideId}`,
        `reason=${fin.reason || "unknown"}`,
      );
    }
  }

  return { success: true, reason: "completed" };
}

/**
 * System / sweeper: cancel an open-pool ride when bank transfer setup or VA expired.
 * Clears fan-out and rider_active_trip without requiring a callable auth context.
 */
async function releaseOpenRideForBankTransferFailure(
  db,
  rideId,
  { cancelReason = "payment_failed", paymentStatus = "failed" } = {},
) {
  const rid = normUid(rideId);
  if (!rid) {
    return { success: false, reason: "invalid_ride_id" };
  }
  const rideRef = db.ref(`ride_requests/${rid}`);
  let reason = "unknown";
  const tx = await rideRef.transaction((cur) => {
    if (!cur || typeof cur !== "object") {
      reason = "ride_missing";
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
    const driverId = normUid(cur.driver_id);
    if (driverId && !isPlaceholderDriverId(cur.driver_id)) {
      reason = "driver_already_assigned";
      return;
    }
    const now = nowMs();
    const ps = String(paymentStatus || "failed").trim().toLowerCase();
    return {
      ...cur,
      trip_state: TRIP_STATE.cancelled,
      status: "cancelled",
      payment_status: ps,
      cancelled_at: now,
      updated_at: now,
      cancel_reason: String(cancelReason || "payment_failed").trim() || "payment_failed",
      cancel_actor: "system",
      cancelled_by: "system",
    };
  });
  if (!tx.committed) {
    return { success: false, reason };
  }
  const v = tx.snapshot.val();
  const rider = normUid(v?.rider_id);
  await clearFanoutAndOffers(db, rid);
  if (rider) {
    await clearRiderActiveTripPointerIfAllowed(db, rider, rid);
  }
  await db.ref(`active_trips/${rid}`).remove().catch(() => {});
  await syncRideTrackPublic(db, rid);
  return { success: true, reason: "released" };
}

function isCancelRideTerminalState(cur) {
  const tsState = String(cur?.trip_state ?? "").trim().toLowerCase();
  return (
    tsState === TRIP_STATE.completed ||
    tsState === TRIP_STATE.cancelled ||
    tsState === TRIP_STATE.expired ||
    tsState === "trip_completed" ||
    tsState === "trip_cancelled"
  );
}

/** Driver cancel auth: canonical assignee plus legacy driver_id when not a placeholder. */
function isCancelRideDriverActor(cur, uid) {
  const assigned = canonicalAssignedDriverId(cur);
  if (assigned && uid === assigned) {
    return true;
  }
  const driver = normUid(cur?.driver_id ?? cur?.driverId);
  return uid === driver && !isPlaceholderDriverId(cur?.driver_id ?? cur?.driverId);
}

function cancelRideActorHint(cur, uid, isAdmin) {
  if (!cur || typeof cur !== "object") {
    return isAdmin ? "admin" : "unknown";
  }
  const rider = normUid(cur.rider_id ?? cur.riderId);
  if (uid === rider) {
    return "rider";
  }
  if (isCancelRideDriverActor(cur, uid)) {
    return "driver";
  }
  if (isAdmin) {
    return "admin";
  }
  return "unknown";
}

/**
 * Pure cancel decision for RTDB transaction and warm-read fallback.
 * @returns {{ ok: boolean, reason: string, patch?: Record<string, unknown> }}
 */
function evaluateCancelRideTransition(cur, uid, isAdmin, cancelReason) {
  if (!cur || typeof cur !== "object") {
    return { ok: false, reason: "ride_missing" };
  }
  const rider = normUid(cur.rider_id ?? cur.riderId);
  const isRider = uid === rider;
  const isDriver = isCancelRideDriverActor(cur, uid);
  const isAdminActor = isAdmin;
  if (!isRider && !isDriver && !isAdminActor) {
    return { ok: false, reason: "forbidden" };
  }
  if (isCancelRideTerminalState(cur)) {
    return { ok: false, reason: "already_terminal" };
  }
  const now = nowMs();
  const effectiveCancelReason =
    cancelReason ||
    (isAdminActor ? "admin_cancelled" : isRider ? "rider_cancelled" : "driver_cancelled");
  const nextStatus =
    isDriver && !isRider && !isAdminActor ? "driver_cancelled" : "cancelled";
  return {
    ok: true,
    reason: "cancelled",
    patch: {
      ...cur,
      trip_state: TRIP_STATE.cancelled,
      status: nextStatus,
      cancelled_at: now,
      updated_at: now,
      cancel_reason: effectiveCancelReason,
      cancel_actor: isAdminActor ? "admin" : isRider ? "rider" : "driver",
      cancelled_by: isAdminActor ? "admin" : isRider ? "rider" : "driver",
    },
  };
}

async function applyCancelRidePostCommit(db, rideId, v, uid, cancelReason) {
  const rider = normUid(v?.rider_id ?? v?.riderId);
  const drv =
    canonicalAssignedDriverId(v) ||
    (isPlaceholderDriverId(v?.driver_id) ? "" : normUid(v?.driver_id));
  const tripState = String(v?.trip_state ?? "").trim().toLowerCase();
  const tripStarted =
    tripState === TRIP_STATE.on_trip ||
    tripState === TRIP_STATE.in_progress ||
    tripState === "trip_started";
  if (
    !tripStarted &&
    cardPayment.isCardPaymentMethod(v?.payment_method ?? v?.paymentMethod)
  ) {
    await cardPayment.voidRideCardOnCancel({ db, rideId, ride: v });
  }
  await clearFanoutAndOffers(db, rideId);
  if (drv) {
    await clearActiveTripPointers(db, rideId, rider, drv);
    try {
      const { releaseAssignmentLocks } = require("./dispatch_engine/dispatch_assignment_lock_engine");
      await releaseAssignmentLocks(db, rideId, drv);
    } catch (e) {
      console.log(
        "CANCEL_TRIP_LOCK_RELEASE_FAIL",
        `rideId=${rideId}`,
        `driverId=${drv}`,
        e?.message ?? e,
      );
    }
  }
  if (rider) {
    await clearRiderActiveTripPointerIfAllowed(db, rider, rideId);
  }
  await writeAudit(db, {
    type: "ride_cancel",
    ride_id: rideId,
    actor_uid: uid,
    cancel_reason: cancelReason,
  });
  await syncRideRealtimeMirrors(db, rideId, drv);
}

async function cancelRideRequest(data, context, db) {
  const rideId = normRideIdFromCallableData(data);
  const cancelReason = String(data?.cancel_reason ?? data?.cancelReason ?? "").trim();
  if (!rideId || !context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const uid = normUid(context.auth.uid);
  const isAdminUser = await adminPerms.canAdmin(db, context, "trips.write");
  const rideRef = db.ref(`ride_requests/${rideId}`);
  const payloadKeys =
    data && typeof data === "object" && !Array.isArray(data) ? Object.keys(data).join(",") : "";

  const preSnap = await rideRef.get();
  const warmExists = snapExists(preSnap);
  const preRide = rideDocFromSnapshot(preSnap);
  const warmType = preRide
    ? "object"
    : preSnap.val() === null || preSnap.val() === undefined
      ? "null"
      : typeof preSnap.val();

  console.log(
    "CANCEL_BACKEND_REQUEST",
    `rideId=${rideId}`,
    `uid=${uid}`,
    `actor=${cancelRideActorHint(preRide, uid, isAdminUser)}`,
    `payloadKeys=${payloadKeys}`,
  );
  console.log(
    "CANCEL_BACKEND_RIDE_LOOKUP",
    `rideId=${rideId}`,
    `warmExists=${warmExists}`,
    `warmType=${warmType}`,
    `trip_state=${preRide ? String(preRide.trip_state ?? "") : ""}`,
    `status=${preRide ? String(preRide.status ?? "") : ""}`,
  );

  let txReason = "unknown";
  const tx = await rideRef.transaction((cur) => {
    const decision = evaluateCancelRideTransition(cur, uid, isAdminUser, cancelReason);
    txReason = decision.reason;
    if (!decision.ok) {
      return;
    }
    return decision.patch;
  });

  let finalRide = tx.committed ? rideDocFromSnapshot(tx.snapshot) : null;
  let fallbackUsed = false;

  if (!tx.committed) {
    const failReason = txReason;
    if (failReason === "ride_missing" && preRide) {
      const fallbackDecision = evaluateCancelRideTransition(
        preRide,
        uid,
        isAdminUser,
        cancelReason,
      );
      txReason = fallbackDecision.reason;
      if (!fallbackDecision.ok) {
        console.log(
          "CANCEL_BACKEND_FAIL_REASON",
          `reason=${fallbackDecision.reason}`,
          `warmExists=${warmExists}`,
          `txReason=${failReason}`,
          `fallbackUsed=false`,
        );
        return { success: false, reason: fallbackDecision.reason };
      }
      await rideRef.update(fallbackDecision.patch);
      finalRide = fallbackDecision.patch;
      fallbackUsed = true;
      console.log(
        "CANCEL_BACKEND_FALLBACK_UPDATE_OK",
        `rideId=${rideId}`,
        `uid=${uid}`,
      );
    } else {
      console.log(
        "CANCEL_BACKEND_FAIL_REASON",
        `reason=${failReason}`,
        `warmExists=${warmExists}`,
        `txReason=${failReason}`,
        `fallbackUsed=false`,
      );
      return { success: false, reason: failReason };
    }
  }

  if (!finalRide) {
    console.log(
      "CANCEL_BACKEND_FAIL_REASON",
      `reason=ride_missing`,
      `warmExists=${warmExists}`,
      `txReason=${txReason}`,
      `fallbackUsed=${fallbackUsed}`,
    );
    return { success: false, reason: "ride_missing" };
  }

  await applyCancelRidePostCommit(db, rideId, finalRide, uid, cancelReason);
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
    await clearRiderActiveTripPointerIfAllowed(db, uid, rideId);
  }
  await writeAudit(db, { type: "ride_expire", ride_id: rideId, actor_uid: uid });
  await syncRideTrackPublic(db, rideId);
  try {
    const { recordMatchTimeout } = require("./dispatch_engine/dispatch_production_metrics");
    recordMatchTimeout();
  } catch (_) {}
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
  "bank_transfer_receipt_url",
  "receipt_uploaded",
  "bank_transfer_receipt_uploaded_at",
  "driver_confirmed_rider_payment",
  "driver_confirmed_rider_payment_at",
]);

const RECEIPT_MIRROR_KEYS = new Set([
  "bank_transfer_receipt_url",
  "receipt_uploaded",
  "bank_transfer_receipt_uploaded_at",
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

  for (const k of Object.keys(patch)) {
    if (!RECEIPT_MIRROR_KEYS.has(k)) {
      continue;
    }
    if (uid !== rider) {
      return { success: false, reason: "forbidden" };
    }
    const pm = String(ride.payment_method ?? "")
      .trim()
      .toLowerCase()
      .replace(/[\s-]+/g, "_");
    if (pm !== "bank_transfer") {
      return { success: false, reason: "invalid_payment_method_for_receipt" };
    }
    const st = String(ride.status ?? "").trim().toLowerCase();
    if (st !== "completed") {
      return { success: false, reason: "ride_not_completed" };
    }
  }

  const driverPaymentConfirmKeys = new Set([
    "driver_confirmed_rider_payment",
    "driver_confirmed_rider_payment_at",
  ]);
  for (const k of Object.keys(patch)) {
    if (!driverPaymentConfirmKeys.has(k)) {
      continue;
    }
    if (uid !== driver) {
      return { success: false, reason: "forbidden" };
    }
    const ts = String(ride.trip_state ?? "").trim().toLowerCase();
    if (ts !== TRIP_STATE.in_progress && ts !== "trip_started") {
      return { success: false, reason: "invalid_state_for_payment_confirm" };
    }
  }

  const marketReject = rejectCanonicalMarketMutation(patch, {
    rideId,
    source: "patchRideRequestMetadata",
  });
  if (!marketReject.ok) {
    return { success: false, reason: marketReject.reason, fields: marketReject.fields };
  }

  const updates = {};
  for (const [k, v] of Object.entries(patch)) {
    if (!isAllowedPatchKey(k)) {
      return { success: false, reason: "disallowed_field", field: k };
    }
    updates[k] = v;
  }
  stripCanonicalMarketFieldsFromUpdate(updates);
  updates.updated_at = nowMs();
  await db.ref(`ride_requests/${rideId}`).update(updates);

  const mirrorActive = {};
  if ("bank_transfer_receipt_url" in patch) {
    mirrorActive.bank_transfer_receipt_url = updates.bank_transfer_receipt_url;
  }
  if ("receipt_uploaded" in patch) {
    mirrorActive.receipt_uploaded = updates.receipt_uploaded;
  }
  if ("bank_transfer_receipt_uploaded_at" in patch) {
    mirrorActive.bank_transfer_receipt_uploaded_at = updates.bank_transfer_receipt_uploaded_at;
  }
  if (Object.keys(mirrorActive).length) {
    mirrorActive.updated_at = updates.updated_at;
    const activeSnap = await db.ref(`active_trips/${rideId}`).get();
    if (activeSnap.exists()) {
      await db.ref(`active_trips/${rideId}`).update(mirrorActive);
    }
  }

  await writeAudit(db, {
    type: "ride_patch_metadata",
    ride_id: rideId,
    actor_uid: uid,
    keys: Object.keys(patch).join(","),
  });
  await syncRideTrackPublic(db, rideId);
  return { success: true, reason: "patched" };
}

async function setDriverOnline(data, context, db) {
  const driverId = normUid(context?.auth?.uid);
  if (!driverId) {
    return { success: false, reason: "unauthorized" };
  }

  const snap = await db.ref(`drivers/${driverId}`).get();
  const d = snap.val() && typeof snap.val() === "object" ? snap.val() : {};

  if (isDriverSuspendedProfile(d)) {
    return {
      success: false,
      reason: "driver_suspended",
      message: "Your account is suspended. Contact support if you believe this is a mistake.",
    };
  }

  const dmRaw = String(
    data?.dispatch_market ??
      data?.dispatchMarket ??
      d.dispatch_market ??
      d.market_pool ??
      d.market ??
      d.launch_market_city ??
      "",
  ).trim();
  const market = canonicalDispatchMarket(dmRaw);
  if (!market) {
    return {
      success: false,
      reason: "driver_service_area_unsupported",
      message: "Select launch city before going online.",
    };
  }

  const gates = await loadDispatchGates(db);
  const dPreview = { ...d, dispatch_market: market, market_pool: market, market };
  const approval = evaluateDriverVerificationForOffer(
    dPreview,
    { soft_verification: false, require_bvn: gates.require_bvn === true },
    { market_pool: market, market, service_type: "ride" },
  );
  if (!approval.ok) {
    if (approval.log === "DRIVER_FILTERED_VERIFICATION") {
      return {
        success: false,
        reason: "driver_not_approved",
        message:
          "Your account must be approved before going online. Complete verification in the Driver Hub.",
      };
    }
    return {
      success: false,
      reason: String(approval.detail || approval.log || "not_eligible").trim() || "not_eligible",
      message: "You are not eligible to go online yet.",
    };
  }

  let mode = normalizeDriverAvailMode(
    data?.driver_availability_mode ??
      data?.availability_mode ??
      data?.availabilityMode ??
      "",
  );
  const latIn = Number(data?.latitude ?? data?.lat ?? "");
  const lngIn = Number(data?.longitude ?? data?.lng ?? "");
  const regionHint = String(data?.service_region_id ?? data?.rollout_region_id ?? "").trim();
  const cityHint = String(data?.service_city_id ?? data?.rollout_city_id ?? "").trim();
  const accuracyIn = Number(data?.accuracy ?? data?.location_accuracy ?? "");
  const headingIn = Number(data?.heading ?? "");

  if (!mode) {
    if (Number.isFinite(latIn) && Number.isFinite(lngIn)) {
      mode = "current_location";
    } else if (regionHint && cityHint) {
      mode = "service_area";
    }
  }

  if (mode === "offline") {
    return setDriverOffline(data, context, db);
  }

  if (mode !== "current_location" && mode !== "service_area") {
    return {
      success: false,
      reason: "invalid_availability_mode",
      message:
        "Choose how you want to receive requests: current GPS location or selected service area.",
    };
  }

  let onlineRollout = { ok: true };
  if (mode === "service_area") {
    if (!regionHint || !cityHint) {
      return {
        success: false,
        reason: "service_area_required",
        message: "Choose a service area (state and city) before going online in area mode.",
      };
    }
    if (!Number.isFinite(latIn) || !Number.isFinite(lngIn)) {
      return {
        success: false,
        reason: "area_center_required",
        message:
          "Service area center coordinates are required for area mode. Choose your operating area and try again.",
      };
    }
    onlineRollout = await deliveryRegions.assertRolloutWithHints(
      admin.firestore(),
      market,
      latIn,
      lngIn,
      "rides",
      { region_id: regionHint, city_id: cityHint },
    );
  } else if (mode === "current_location") {
    if (!Number.isFinite(latIn) || !Number.isFinite(lngIn)) {
      return {
        success: false,
        reason: "location_required",
        message:
          "Location permission and GPS are required to go online while matching from your current position.",
      };
    }
    onlineRollout = await deliveryRegions.assertRolloutWithHints(
      admin.firestore(),
      market,
      latIn,
      lngIn,
      "rides",
      {
        region_id: data?.service_region_id ?? data?.rollout_region_id,
        city_id: data?.service_city_id ?? data?.rollout_city_id,
      },
    );
  }

  if (!onlineRollout.ok) {
    return {
      success: false,
      reason: onlineRollout.reason || "driver_service_area_unsupported",
      message: onlineRollout.message || "Service area not supported.",
    };
  }

  const canonicalMarket =
    normalizeDispatchKey(onlineRollout.dispatch_market_id || market) || canonicalDispatchMarket(market);
  if (!canonicalMarket) {
    return {
      success: false,
      reason: "missing_canonical_market",
      message: "Service area dispatch market is not configured.",
    };
  }

  const now = nowMs();
  try {
    const { refreshDriverAvailability } = require("./refresh_driver_availability");
    await refreshDriverAvailability(db, driverId, { source: "set_driver_online" });
  } catch (refreshErr) {
    console.log(
      "REFRESH_DRIVER_AVAILABILITY_FAIL",
      `driverId=${driverId}`,
      String(refreshErr?.message || refreshErr),
    );
  }

  const selectedName = String(data?.selected_service_area_name ?? "").trim().slice(0, 200);
  const selectedServiceAreaId = mode === "service_area" ? cityHint : null;

  /** @type {Record<string, unknown>} */
  const updates = {
    online: true,
    is_online: true,
    isOnline: true,
    isAvailable: true,
    available: true,
    status: "online_available",
    dispatch_state: "online_available",
    activeRideId: null,
    currentRideId: null,
    active_ride_id: null,
    last_active_at: now,
    last_seen_at: now,
    last_seen_ms: now,
    presence_heartbeat_at: now,
    online_session_started_at: now,
    updated_at: now,
    driver_availability_mode: mode,
    selected_service_area_id: selectedServiceAreaId,
    selected_service_area_name:
      mode === "service_area" && selectedName ? selectedName : null,
    rollout_region_id: regionHint || null,
    rollout_city_id: cityHint || null,
    last_availability_intent: "online",
    last_availability_intent_at: now,
  };

  const publishLat =
    Number.isFinite(latIn) && Number.isFinite(lngIn) ? latIn : Number.NaN;
  const publishLng =
    Number.isFinite(lngIn) && Number.isFinite(latIn) ? lngIn : Number.NaN;

  if (Number.isFinite(publishLat) && Number.isFinite(publishLng)) {
    updates.lat = publishLat;
    updates.lng = publishLng;
    const locSnap = { lat: publishLat, lng: publishLng };
    updates.last_location = locSnap;
    updates.last_valid_location = locSnap;
    updates.last_location_ts = now;
    updates.last_location_updated_at = now;
    updates.online_start_location = locSnap;
    updates.online_start_location_at = now;
    updates.last_dispatch_heartbeat = now;
    updates.dispatch_eligibility_grace_until_ms = now + 10 * 60 * 1000;
    updates.location_permission_degraded = false;
  }

  updates.location_mode = mode === "current_location" ? "gps" : "area";
  updates.service_area_region_id = regionHint || null;
  updates.service_area_city_id = cityHint || null;

  const dispatchMode = mode === "current_location" ? "gps" : "service_area";
  applyCanonicalDispatchGeoToDriverUpdates(updates, {
    canonical_market_id: canonicalMarket,
    region_id: onlineRollout.region_id || regionHint || null,
    city_id: onlineRollout.city_id || cityHint || null,
    country_code: "ng",
    availability_mode: dispatchMode,
    service_area_id: selectedServiceAreaId || cityHint || null,
    service_area_name: selectedName || null,
  });
  updates.driver_availability_mode = mode;
  updates.gps_active = dispatchMode === "gps";
  updates.location_permission_degraded = false;

  const locRecord = buildDriverLocationRecord({
    lat: publishLat,
    lng: publishLng,
    availabilityMode: mode,
    serviceRegionId: regionHint,
    serviceCityId: cityHint,
    dispatchMarketId: canonicalMarket,
    updatedAtMs: now,
    accuracy: Number.isFinite(accuracyIn) ? accuracyIn : null,
    heading: Number.isFinite(headingIn) ? headingIn : null,
  });

  const paths = locationPathUpdates(driverId, locRecord, {
    ...updates,
    is_online: true,
    isOnline: true,
    driver_availability_mode: mode,
  });

  await db.ref().update(paths);

  const canonSnap = await db.ref(`drivers/${driverId}/canonical_market_id`).get();
  const canonWritten = normalizeDispatchKey(canonSnap.val() ?? "");
  if (!canonWritten) {
    const offlineNow = nowMs();
    await db.ref(`drivers/${driverId}`).update({
      online: false,
      is_online: false,
      isOnline: false,
      isAvailable: false,
      available: false,
      status: "offline_incomplete_profile",
      dispatch_state: "offline_incomplete_profile",
      updated_at: offlineNow,
      last_availability_intent: "offline",
      last_availability_intent_at: offlineNow,
    });
    await db.ref(`online_drivers/${driverId}`).remove();
    await clearDispatchIndexForDriver(db, driverId);
    return {
      success: false,
      reason: "offline_incomplete_profile",
      message:
        "Dispatch market is not configured on your profile. Re-select your service area and try again.",
    };
  }

  try {
    await syncDispatchIndexForDriver(db, driverId, canonicalMarket);
  } catch (indexErr) {
    console.log(
      "DISPATCH_INDEX_SYNC_FAIL",
      `driverId=${driverId}`,
      String(indexErr?.message || indexErr),
    );
  }

  try {
    const {
      maybeUpsertAvailableDriverThrottled,
    } = require("./dispatch_engine/dispatch_available_drivers_index");
    const profileSnap = await db.ref(`drivers/${driverId}`).get();
    const onlineProfile =
      profileSnap.val() && typeof profileSnap.val() === "object" ? profileSnap.val() : {};
    await maybeUpsertAvailableDriverThrottled(db, driverId, {
      force: true,
      source: "set_driver_online",
      market: canonicalMarket,
      profile: onlineProfile,
    });
  } catch (geoErr) {
    console.log(
      "DISPATCH_GEO_INDEX_UPSERT_FAIL",
      `driverId=${driverId}`,
      String(geoErr?.message || geoErr),
    );
  }

  console.info("DRIVER_ONLINE", { driverId, market: canonicalMarket, mode });
  return {
    success: true,
    reason: "online",
    driver_availability_mode: mode,
    dispatch_market_id: canonicalMarket,
    canonical_market_id: canonicalMarket,
  };
}

async function setDriverOffline(data, context, db) {
  const driverId = normUid(context?.auth?.uid);
  if (!driverId) {
    return { success: false, reason: "unauthorized" };
  }

  const now = nowMs();
  const paths = {
    [`drivers/${driverId}/online`]: false,
    [`drivers/${driverId}/is_online`]: false,
    [`drivers/${driverId}/isOnline`]: false,
    [`drivers/${driverId}/isAvailable`]: false,
    [`drivers/${driverId}/available`]: false,
    [`drivers/${driverId}/status`]: "offline",
    [`drivers/${driverId}/dispatch_state`]: "offline",
    [`drivers/${driverId}/online_session_started_at`]: null,
    [`drivers/${driverId}/driver_availability_mode`]: "offline",
    [`drivers/${driverId}/updated_at`]: now,
    [`drivers/${driverId}/last_availability_intent`]: "offline",
    [`drivers/${driverId}/last_availability_intent_at`]: now,
    [`online_drivers/${driverId}`]: null,
    [`driver_locations/${driverId}`]: null,
  };
  try {
    await clearDispatchIndexForDriver(db, driverId);
  } catch (_) {}
  await db.ref().update(paths);
  console.info("DRIVER_OFFLINE", { driverId });
  return { success: true, reason: "offline" };
}

async function driverUpdateLiveLocation(data, context, db) {
  const driverId = normUid(context?.auth?.uid);
  if (!driverId) {
    return { success: false, reason: "unauthorized" };
  }
  const lat = Number(data?.latitude ?? data?.lat ?? "");
  const lng = Number(data?.longitude ?? data?.lng ?? "");
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
    return {
      success: false,
      reason: "location_required",
      message: "GPS coordinates are missing or invalid.",
    };
  }

  const snap = await db.ref(`drivers/${driverId}`).get();
  const d = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  if (isDriverSuspendedProfile(d)) {
    return {
      success: false,
      reason: "driver_suspended",
      message: "Your account is suspended.",
    };
  }

  const online =
    d.isOnline === true || d.is_online === true || d.online === true;
  if (!online) {
    return { success: false, reason: "not_online", message: "You are not online." };
  }

  const mode = normalizeDriverAvailabilityMode(
    d.driver_availability_mode ?? d.availability_mode ?? "",
  );
  if (mode && mode !== "current_location") {
    return {
      success: false,
      reason: "invalid_availability_mode",
      message: "Live location refresh applies only when using current GPS mode.",
    };
  }

  const now = nowMs();
  const regionId = String(d.rollout_region_id ?? d.service_area_region_id ?? "").trim();
  const cityId = String(
    d.rollout_city_id ?? d.service_area_city_id ?? d.selected_service_area_id ?? "",
  ).trim();
  const marketId = String(d.dispatch_market_id ?? d.dispatch_market ?? "").trim();
  const accuracyIn = Number(data?.accuracy ?? "");
  const headingIn = Number(data?.heading ?? "");

  const locRecord = buildDriverLocationRecord({
    lat,
    lng,
    availabilityMode: "current_location",
    serviceRegionId: regionId,
    serviceCityId: cityId,
    dispatchMarketId: marketId,
    updatedAtMs: now,
    accuracy: Number.isFinite(accuracyIn) ? accuracyIn : null,
    heading: Number.isFinite(headingIn) ? headingIn : null,
  });

  const paths = locationPathUpdates(driverId, locRecord, {
    driver_availability_mode: "current_location",
    is_online: true,
    isOnline: true,
    updated_at: now,
  });

  await db.ref().update(paths);

  try {
    const {
      maybeUpsertAvailableDriverThrottled,
    } = require("./dispatch_engine/dispatch_available_drivers_index");
    await maybeUpsertAvailableDriverThrottled(db, driverId, {
      source: "live_location",
      market: marketId,
      profile: {
        ...d,
        lat,
        lng,
        latitude: lat,
        longitude: lng,
        is_online: true,
        isOnline: true,
      },
    });
  } catch (geoErr) {
    console.log(
      "DISPATCH_GEO_INDEX_UPSERT_FAIL",
      `driverId=${driverId}`,
      String(geoErr?.message || geoErr),
    );
  }

  return { success: true, reason: "updated" };
}

/**
 * One-time canonical geography migration (drivers, rides, online_drivers, dispatch_index).
 * @param {Record<string, unknown>} data
 * @param {import("firebase-functions/v1").CallableContext} context
 * @param {import("firebase-admin/database").Database} db
 */
async function adminMigrateDispatchCanonicalGeography(data, context, db) {
  const deny = await adminPerms.enforceCallable(
    db,
    context,
    "adminMigrateDispatchCanonicalGeography",
  );
  if (deny) return deny;
  const dryRun = data?.dry_run === true || data?.dryRun === true;
  const limit = Number(data?.limit) || 5000;
  const { migrateDispatchCanonicalGeography } = require(
    "./dispatch_engine/dispatch_canonical_migration",
  );
  return migrateDispatchCanonicalGeography(db, { dryRun, limit });
}

module.exports = {
  TRIP_STATE,
  createRideRequest,
  acceptRideRequest,
  paymentAllowsDispatch,
  paymentAllowsAcceptRide,
  paymentAllowsFanout,
  normalizedPaymentMethod,
  effectiveAcceptExpiryMs,
  acceptWindowOpenAt,
  acceptWindowOpenForAccept,
  hasAssignedDriver,
  rideAssignedDriverUid,
  evaluateDriverArrivedTransition,
  isCancelRideTerminalState,
  isCancelRideDriverActor,
  evaluateCancelRideTransition,
  canonicalAssignedDriverId,
  ridePoolOpenForAccept,
  rideAssignedOrTerminal,
  buildDriverAcceptAssignmentPatch,
  readMatchLockHolder,
  acquireMatchLockOrReject,
  evaluateAcceptTransactionDecision,
  attemptGuardedAcceptDirectWrite,
  mapApiAcceptFailureReason,
  MATCH_LOCK_MAX_AGE_MS,
  inferAcceptTxAbortReason,
  evaluateOfferAcceptAuthority,
  resolveOfferAcceptAuthority,
  ACCEPT_EXPIRY_GRACE_MS,
  fanOutDriverOffersIfEligible,
  retryRideMatching,
  driverEnroute,
  driverArrived,
  startTrip,
  completeTrip,
  cancelRideRequest,
  releaseOpenRideForBankTransferFailure,
  expireRideRequest,
  patchRideRequestMetadata,
  adminMigrateDispatchCanonicalGeography,
  setDriverOnline,
  setDriverOffline,
  refreshDriverAvailability: async (db, driverId, options) => {
    const { refreshDriverAvailability: refresh } = require("./refresh_driver_availability");
    return refresh(db, driverId, options);
  },
  driverUpdateLiveLocation,
  withdrawDriverOffer,
  canonicalDispatchMarket,
  loadRiderCreateGates,
  loadDispatchGates,
  evaluateDriverForOffer,
  riderProfileRequirementOk,
  coordsFromPickup,
  coordsInNgBox,
};
