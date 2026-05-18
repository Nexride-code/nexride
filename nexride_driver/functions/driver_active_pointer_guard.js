/**
 * Validates driver active ride/delivery pointers — never block offers on stale pointers.
 */

"use strict";

const { rideDocumentIsTerminal } = require("./ride_pointer_orphans");

const STALE_DRIVER_HEARTBEAT_MS = 90_000;
const STALE_SEARCHING_RIDE_MS = 8 * 60 * 1000;
const ASSIGNED_NOT_STARTED_STALE_MS = 3 * 60 * 1000;
const ENROUTE_IN_TRIP_STALE_MS = 30 * 60 * 1000;

const ENROUTE_IN_TRIP_STATES = new Set([
  "driver_enroute",
  "driver_arriving",
  "driver_on_the_way",
  "driver_arrived",
  "arrived",
  "in_trip",
  "started",
  "on_trip",
  "in_progress",
  "trip_started",
]);

const ACTIVITY_TIMESTAMP_KEYS = [
  "updated_at",
  "updated_at_ms",
  "last_seen_ms",
  "driver_last_seen_ms",
  "started_at",
  "accepted_at",
  "accepted_at_ms",
  "driver_assigned_at",
  "driver_assigned_at_ms",
  "enroute_at",
  "driver_enroute_at",
  "in_trip_at",
  "inTripAt",
  "trip_started_at",
  "tripStartedAt",
  "driver_accepted_at",
  "driverAcceptedAt",
];

const SEARCHING_RIDE_TOKENS = new Set([
  "searching",
  "requested",
  "requesting",
  "searching_driver",
  "matching",
  "awaiting_match",
  "offered",
  "offer_pending",
  "pending_driver_acceptance",
  "pending_driver_action",
  "driver_reviewing_request",
  "driver_found_pending",
]);

const OFFER_BLOCK_RIDE_STATES = new Set([
  "driver_assigned",
  "accepted",
  "driver_enroute",
  "driver_arriving",
  "driver_on_the_way",
  "driver_arrived",
  "arrived",
  "in_trip",
  "started",
  "on_trip",
  "in_progress",
  "trip_started",
]);

const ACTIVE_DELIVERY_STATES = new Set([
  "driver_assigned",
  "driver_arriving_pickup",
  "picked_up",
  "on_delivery",
  "arrived_dropoff",
]);

function normUid(uid) {
  return String(uid ?? "").trim();
}

function normState(raw) {
  return String(raw ?? "").trim().toLowerCase();
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
    s === "unassigned"
  );
}

function canonicalAssignedRideDriverId(ride) {
  if (!ride || typeof ride !== "object") return "";
  const rider = normUid(ride.rider_id ?? ride.riderId);
  for (const key of [
    "matched_driver_id",
    "matchedDriverId",
    "accepted_driver_id",
    "acceptedDriverId",
    "driver_id",
    "driverId",
  ]) {
    const raw = ride[key];
    if (isPlaceholderDriverId(raw)) continue;
    const d = normUid(raw);
    if (!d || (rider && d === rider)) continue;
    return d;
  }
  return "";
}

function normalizeDeliveryState(raw) {
  const s = normState(raw);
  const legacy = {
    accepted: "driver_assigned",
    enroute_pickup: "driver_arriving_pickup",
    arrived_pickup: "driver_arriving_pickup",
    enroute_dropoff: "on_delivery",
    delivered: "completed",
  };
  return legacy[s] || s;
}

function canonicalAssignedDeliveryDriverId(row) {
  if (!row || typeof row !== "object") return "";
  for (const key of [
    "matched_driver_id",
    "matchedDriverId",
    "accepted_driver_id",
    "acceptedDriverId",
    "delivery_driver_id",
    "driver_id",
    "driverId",
  ]) {
    const v = normUid(row[key]);
    if (v && !isPlaceholderDriverId(v)) return v;
  }
  return "";
}

function rideStateTokens(ride) {
  return [
    normState(ride?.trip_state),
    normState(ride?.status),
    normState(ride?.request_status),
  ].filter(Boolean);
}

function isSearchingRide(ride) {
  return rideStateTokens(ride).some((t) => SEARCHING_RIDE_TOKENS.has(t));
}

function rideRawBlocksOffers(ride) {
  const tokens = rideStateTokens(ride);
  if (!tokens.length) return false;
  if (tokens.some((t) => SEARCHING_RIDE_TOKENS.has(t))) return false;
  const ts = normState(ride.trip_state);
  if (ts && OFFER_BLOCK_RIDE_STATES.has(ts)) return true;
  const st = normState(ride.status);
  if (st && OFFER_BLOCK_RIDE_STATES.has(st)) return true;
  return false;
}

function maxActivityTimestampMs(ride, activeTrip) {
  let maxTs = 0;
  const sources = [];
  if (ride && typeof ride === "object") sources.push(ride);
  if (activeTrip && typeof activeTrip === "object") sources.push(activeTrip);
  for (const row of sources) {
    for (const key of ACTIVITY_TIMESTAMP_KEYS) {
      const n = Number(row[key]);
      if (Number.isFinite(n) && n > maxTs) maxTs = n;
    }
  }
  return maxTs;
}

function pickTimestampMs(row, keys) {
  if (!row || typeof row !== "object") return 0;
  let maxTs = 0;
  for (const key of keys) {
    const n = Number(row[key]);
    if (Number.isFinite(n) && n > maxTs) maxTs = n;
  }
  return maxTs;
}

function staleTtlMsForTripState(tripState) {
  const st = normState(tripState);
  if (ENROUTE_IN_TRIP_STATES.has(st)) return ENROUTE_IN_TRIP_STALE_MS;
  return ASSIGNED_NOT_STARTED_STALE_MS;
}

/**
 * @returns {{ isFresh: boolean, ageMs: number, referenceTs: number, activeTripUpdatedAt: number, rideUpdatedAt: number, acceptedAt: number, ttlMs: number }}
 */
function evaluateActiveTripFreshness({ ride, activeTrip, tripState, nowMs = Date.now() }) {
  const activeTripUpdatedAt = pickTimestampMs(activeTrip, [
    "updated_at",
    "updated_at_ms",
    "last_seen_ms",
    "driver_last_seen_ms",
  ]);
  const rideUpdatedAt = pickTimestampMs(ride, ["updated_at", "updated_at_ms"]);
  const acceptedAt = pickTimestampMs(ride, [
    "accepted_at",
    "accepted_at_ms",
    "driver_assigned_at",
    "driver_assigned_at_ms",
  ]);
  const referenceTs = maxActivityTimestampMs(ride, activeTrip);
  if (referenceTs <= 0) {
    return {
      isFresh: false,
      ageMs: -1,
      referenceTs: 0,
      activeTripUpdatedAt,
      rideUpdatedAt,
      acceptedAt,
      ttlMs: staleTtlMsForTripState(tripState),
    };
  }
  const ageMs = nowMs - referenceTs;
  const ttlMs = staleTtlMsForTripState(tripState);
  return {
    isFresh: ageMs <= ttlMs,
    ageMs,
    referenceTs,
    activeTripUpdatedAt,
    rideUpdatedAt,
    acceptedAt,
    ttlMs,
  };
}

function activeTripIsFreshForBlocking(activeTrip, ride, driverId, tripState, nowMs = Date.now()) {
  if (!activeTrip || typeof activeTrip !== "object") return false;
  const d = normUid(driverId);
  const tripDriver = normUid(
    activeTrip.driver_id ??
      activeTrip.driverId ??
      activeTrip.matched_driver_id ??
      activeTrip.matchedDriverId,
  );
  if (tripDriver && tripDriver !== d) return false;
  const st = normState(activeTrip.trip_state ?? activeTrip.status ?? tripState);
  if (st && SEARCHING_RIDE_TOKENS.has(st)) return false;
  const freshness = evaluateActiveTripFreshness({
    ride,
    activeTrip,
    tripState: st || tripState,
    nowMs,
  });
  return freshness.isFresh;
}

function formatActivePointerFinalDecisionLog({
  driverId,
  incomingOfferTripId,
  pointerTripId,
  activeTripExists,
  activeTripUpdatedAt,
  rideUpdatedAt,
  acceptedAt,
  ageMs,
  state,
  decision,
  reason,
}) {
  return (
    "ACTIVE_POINTER_FINAL_DECISION " +
    `driverId=${normUid(driverId)} ` +
    `incomingOfferRideId=${normUid(incomingOfferTripId)} ` +
    `pointerTripId=${normUid(pointerTripId)} ` +
    `activeTripExists=${!!activeTripExists} ` +
    `activeTripUpdatedAt=${activeTripUpdatedAt} ` +
    `rideUpdatedAt=${rideUpdatedAt} ` +
    `acceptedAt=${acceptedAt} ` +
    `ageMs=${ageMs} ` +
    `state=${normState(state)} ` +
    `decision=${decision} ` +
    `reason=${reason}`
  );
}

/**
 * @returns {{ blocks: boolean, decision: string, reason: string, kind: string, diagnostic: object }}
 */
function evaluateActivePointerDecision({
  driverId,
  tripId,
  source = "unknown",
  ride = null,
  delivery = null,
  activeTrip = null,
  incomingOfferTripId = "",
  nowMs = Date.now(),
}) {
  const d = normUid(driverId);
  const t = normUid(tripId);
  const kind =
    delivery && typeof delivery === "object"
      ? "delivery"
      : ride && typeof ride === "object"
        ? "ride"
        : "missing";

  const diagnostic = {
    driverId: d,
    tripId: t,
    kind,
    source,
    ride_exists: !!(ride && typeof ride === "object"),
    active_trip_exists: !!(activeTrip && typeof activeTrip === "object"),
    trip_state: normState(ride?.trip_state),
    status: normState(ride?.status),
    request_status: normState(ride?.request_status),
    driver_id: String(ride?.driver_id ?? ride?.driverId ?? ""),
    matched_driver_id: String(ride?.matched_driver_id ?? ride?.matchedDriverId ?? ""),
    accepted_driver_id: String(ride?.accepted_driver_id ?? ride?.acceptedDriverId ?? ""),
    canonical_assigned_driver: "",
    is_terminal: false,
    is_searching: false,
    is_assigned_to_this_driver: false,
    is_driver_active_state: false,
    decision: "ignore",
    reason: "",
  };

  if (!ride && !delivery) {
    diagnostic.decision = "clear";
    diagnostic.reason = "missing";
    return { blocks: false, decision: "clear", reason: "missing", kind: "missing", diagnostic };
  }

  if (delivery && typeof delivery === "object") {
    const assigned = canonicalAssignedDeliveryDriverId(delivery);
    diagnostic.canonical_assigned_driver = assigned;
    const ds = normalizeDeliveryState(delivery.delivery_state);
    diagnostic.trip_state = ds;
    diagnostic.is_searching = ds === "searching";
    diagnostic.is_terminal = ds === "completed" || ds === "cancelled";
    diagnostic.is_assigned_to_this_driver = !!(assigned && assigned === d);
    diagnostic.is_driver_active_state = ACTIVE_DELIVERY_STATES.has(ds);
    if (!assigned || assigned !== d) {
      diagnostic.decision = "clear";
      diagnostic.reason = "delivery_unassigned";
      return {
        blocks: false,
        decision: "clear",
        reason: "delivery_unassigned",
        kind: "delivery",
        diagnostic,
      };
    }
    if (ds === "searching" || diagnostic.is_terminal) {
      diagnostic.decision = "clear";
      diagnostic.reason = `delivery_${ds}`;
      return {
        blocks: false,
        decision: "clear",
        reason: `delivery_${ds}`,
        kind: "delivery",
        diagnostic,
      };
    }
    if (ACTIVE_DELIVERY_STATES.has(ds)) {
      diagnostic.decision = "block";
      diagnostic.reason = "delivery_active";
      return {
        blocks: true,
        decision: "block",
        reason: "delivery_active",
        kind: "delivery",
        diagnostic,
      };
    }
    diagnostic.decision = "clear";
    diagnostic.reason = `delivery_${ds || "unknown"}`;
    return {
      blocks: false,
      decision: "clear",
      reason: diagnostic.reason,
      kind: "delivery",
      diagnostic,
    };
  }

  const assigned = canonicalAssignedRideDriverId(ride);
  diagnostic.canonical_assigned_driver = assigned;
  diagnostic.is_terminal = rideDocumentIsTerminal(ride);
  diagnostic.is_searching = isSearchingRide(ride);
  diagnostic.is_assigned_to_this_driver = !!(assigned && assigned === d);
  diagnostic.is_driver_active_state = rideRawBlocksOffers(ride);

  if (diagnostic.is_terminal) {
    diagnostic.decision = "clear";
    diagnostic.reason = "ride_terminal";
    return { blocks: false, decision: "clear", reason: "ride_terminal", kind: "ride", diagnostic };
  }

  if (diagnostic.is_searching) {
    diagnostic.decision = "clear";
    diagnostic.reason = "ride_searching";
    return { blocks: false, decision: "clear", reason: "ride_searching", kind: "ride", diagnostic };
  }

  if (!assigned) {
    diagnostic.decision = "clear";
    diagnostic.reason = "ride_unassigned";
    return { blocks: false, decision: "clear", reason: "ride_unassigned", kind: "ride", diagnostic };
  }

  if (assigned !== d) {
    diagnostic.decision = "clear";
    diagnostic.reason = "ride_other_driver";
    return { blocks: false, decision: "clear", reason: "ride_other_driver", kind: "ride", diagnostic };
  }

  if (!diagnostic.is_driver_active_state) {
    diagnostic.decision = "clear";
    diagnostic.reason = "ride_not_active_state";
    return {
      blocks: false,
      decision: "clear",
      reason: "ride_not_active_state",
      kind: "ride",
      diagnostic,
    };
  }

  const state = normState(ride.trip_state) || normState(ride.status);
  const freshness = evaluateActiveTripFreshness({
    ride,
    activeTrip,
    tripState: state,
    nowMs,
  });
  const incoming = normUid(incomingOfferTripId);
  const isCrossPointer = incoming.length > 0 && incoming !== t;
  const activeTripFresh =
    diagnostic.active_trip_exists &&
    activeTripIsFreshForBlocking(activeTrip, ride, d, state, nowMs);
  const samePointerFresh =
    !isCrossPointer &&
    freshness.isFresh &&
    (diagnostic.active_trip_exists || freshness.referenceTs > 0);

  console.log(
    formatActivePointerFinalDecisionLog({
      driverId: d,
      incomingOfferTripId: incoming,
      pointerTripId: t,
      activeTripExists: diagnostic.active_trip_exists,
      activeTripUpdatedAt: freshness.activeTripUpdatedAt,
      rideUpdatedAt: freshness.rideUpdatedAt,
      acceptedAt: freshness.acceptedAt,
      ageMs: freshness.ageMs,
      state,
      decision: activeTripFresh || samePointerFresh ? "block" : "clear",
      reason: activeTripFresh
        ? "active_trip_fresh"
        : samePointerFresh
          ? "active_trip_fresh"
          : isCrossPointer
            ? "cross_offer_old_active_trip"
            : "active_trip_stale",
    }),
  );

  if (!activeTripFresh && !samePointerFresh) {
    diagnostic.decision = "clear";
    diagnostic.reason = isCrossPointer
      ? "cross_offer_old_active_trip"
      : "active_trip_stale";
    return {
      blocks: false,
      decision: "clear",
      reason: diagnostic.reason,
      kind: "ride",
      diagnostic,
      freshness,
      shouldRestoreActiveTrip: false,
    };
  }

  diagnostic.decision = "block";
  diagnostic.reason = "active_trip_fresh";
  return {
    blocks: true,
    decision: "block",
    reason: "active_trip_fresh",
    kind: "ride",
    diagnostic,
    freshness,
    shouldRestoreActiveTrip: true,
  };
}

function formatActivePointerDecisionLog(diagnostic) {
  return (
    "ACTIVE_POINTER_DECISION " +
    `driverId=${diagnostic.driverId} ` +
    `tripId=${diagnostic.tripId} ` +
    `kind=${diagnostic.kind} ` +
    `source=${diagnostic.source} ` +
    `ride_exists=${diagnostic.ride_exists} ` +
    `active_trip_exists=${diagnostic.active_trip_exists} ` +
    `trip_state=${diagnostic.trip_state} ` +
    `status=${diagnostic.status} ` +
    `request_status=${diagnostic.request_status} ` +
    `driver_id=${diagnostic.driver_id} ` +
    `matched_driver_id=${diagnostic.matched_driver_id} ` +
    `accepted_driver_id=${diagnostic.accepted_driver_id} ` +
    `canonical_assigned_driver=${diagnostic.canonical_assigned_driver} ` +
    `is_terminal=${diagnostic.is_terminal} ` +
    `is_searching=${diagnostic.is_searching} ` +
    `is_assigned_to_this_driver=${diagnostic.is_assigned_to_this_driver} ` +
    `is_driver_active_state=${diagnostic.is_driver_active_state} ` +
    `decision=${diagnostic.decision} ` +
    `reason=${diagnostic.reason}`
  );
}

function logActivePointerDecision(diagnostic) {
  console.log(formatActivePointerDecisionLog(diagnostic));
}

/**
 * @returns {{ blocks: boolean, reason: string, kind: "ride"|"delivery"|"missing"|"none" }}
 */
function classifyTripForDriverOffers(driverId, rideRow, deliveryRow, activeTrip = null) {
  const verdict = evaluateActivePointerDecision({
    driverId,
    tripId: "",
    source: "classify",
    ride: rideRow,
    delivery: deliveryRow,
    activeTrip,
  });
  return {
    blocks: verdict.blocks,
    reason: verdict.reason,
    kind: verdict.kind,
    decision: verdict.decision,
    diagnostic: verdict.diagnostic,
  };
}

async function loadTripRows(db, tripId) {
  const id = normUid(tripId);
  if (!id) {
    return { ride: null, delivery: null, activeTrip: null, activeDelivery: null };
  }
  const [rideSnap, delSnap, activeSnap, activeDelSnap] = await Promise.all([
    db.ref(`ride_requests/${id}`).get(),
    db.ref(`delivery_requests/${id}`).get(),
    db.ref(`active_trips/${id}`).get(),
    db.ref(`active_deliveries/${id}`).get(),
  ]);
  const ride =
    rideSnap.exists() && rideSnap.val() && typeof rideSnap.val() === "object"
      ? rideSnap.val()
      : null;
  let delivery =
    delSnap.exists() && delSnap.val() && typeof delSnap.val() === "object"
      ? delSnap.val()
      : null;
  const activeTrip =
    activeSnap.exists() && activeSnap.val() && typeof activeSnap.val() === "object"
      ? activeSnap.val()
      : null;
  const activeDelivery =
    activeDelSnap.exists() &&
    activeDelSnap.val() &&
    typeof activeDelSnap.val() === "object"
      ? activeDelSnap.val()
      : null;
  if (!delivery && activeDelivery) {
    delivery = activeDelivery;
  }
  return { ride, delivery, activeTrip, activeDelivery };
}

/**
 * @returns {Promise<{ blocks: boolean, reason: string, kind: string, decision: string, diagnostic: object }>}
 */
async function tripIdBlocksDriverOffers(
  db,
  driverId,
  tripId,
  source = "trip_check",
  incomingOfferTripId = "",
) {
  const { ride, delivery, activeTrip } = await loadTripRows(db, tripId);
  if (!ride && !delivery) {
    const diagnostic = {
      driverId: normUid(driverId),
      tripId: normUid(tripId),
      kind: "missing",
      source,
      ride_exists: false,
      active_trip_exists: false,
      trip_state: "",
      status: "",
      request_status: "",
      driver_id: "",
      matched_driver_id: "",
      accepted_driver_id: "",
      canonical_assigned_driver: "",
      is_terminal: true,
      is_searching: false,
      is_assigned_to_this_driver: false,
      is_driver_active_state: false,
      decision: "clear",
      reason: "missing",
    };
    logActivePointerDecision(diagnostic);
    return { blocks: false, reason: "missing", kind: "missing", decision: "clear", diagnostic };
  }
  const verdict = evaluateActivePointerDecision({
    driverId,
    tripId,
    source,
    ride,
    delivery,
    activeTrip,
    incomingOfferTripId: normUid(incomingOfferTripId),
  });
  logActivePointerDecision(verdict.diagnostic);
  return verdict;
}

function pointerTripId(ptrVal) {
  if (ptrVal == null) return "";
  if (typeof ptrVal === "string") return normUid(ptrVal);
  if (typeof ptrVal === "object") {
    return normUid(
      ptrVal.ride_id ?? ptrVal.rideId ?? ptrVal.delivery_id ?? ptrVal.deliveryId,
    );
  }
  return "";
}

/**
 * Collect candidate trip ids from RTDB pointers (not in-memory).
 */
async function collectDriverActivePointerTripIds(db, driverId) {
  const d = normUid(driverId);
  const ids = new Set();
  if (!d) return ids;

  const [darSnap, dadSnap, driverSnap] = await Promise.all([
    db.ref(`driver_active_ride/${d}`).get(),
    db.ref(`driver_active_delivery/${d}`).get(),
    db.ref(`drivers/${d}`).get(),
  ]);
  const dar = darSnap.val();
  const dad = dadSnap.val();
  const driverRow =
    driverSnap.exists() && typeof driverSnap.val() === "object" ? driverSnap.val() : {};
  const fromDar = pointerTripId(dar);
  const fromDad = pointerTripId(dad);
  if (fromDar) ids.add(fromDar);
  if (fromDad) ids.add(fromDad);
  for (const key of ["activeRideId", "currentRideId", "active_ride_id", "active_delivery_id"]) {
    const v = normUid(driverRow[key]);
    if (v) ids.add(v);
  }
  return ids;
}

async function clearDriverActivePointers(db, driverId, tripId, cleanupReason) {
  const d = normUid(driverId);
  const t = normUid(tripId);
  if (!d) return false;
  const now = Date.now();
  const debugPayload = {
    driver_offer_unblocked_at: now,
    reason:
      cleanupReason === "admin_force_clear"
        ? cleanupReason
        : "stale_active_trip_blocking_new_offer",
    cleared_at_ms: now,
    driver_id: d,
  };
  const updates = {
    [`driver_active_ride/${d}`]: null,
    [`driver_active_delivery/${d}`]: null,
    [`drivers/${d}/activeRideId`]: null,
    [`drivers/${d}/currentRideId`]: null,
    [`drivers/${d}/active_ride_id`]: null,
    [`drivers/${d}/active_delivery_id`]: null,
    [`drivers/${d}/updated_at`]: now,
    [`drivers/${d}/cleanup_debug`]: {
      ...debugPayload,
      cleanup_reason: cleanupReason,
      trip_id: t || null,
    },
  };
  if (t) {
    updates[`ride_requests/${t}/cleanup_debug`] = debugPayload;
    updates[`active_trips/${t}/cleanup_debug`] = {
      reason: "stale_active_trip_blocking_new_offer",
      cleared_at_ms: now,
      driver_id: d,
    };
    updates[`delivery_requests/${t}/cleanup_debug`] = {
      cleanup_reason: cleanupReason,
      cleared_at_ms: now,
      driver_id: d,
    };
  }
  await db.ref().update(updates);
  return true;
}

async function readDriverActivePointerSnapshot(db, driverId) {
  const d = normUid(driverId);
  const [darSnap, dadSnap, driverSnap] = await Promise.all([
    db.ref(`driver_active_ride/${d}`).get(),
    db.ref(`driver_active_delivery/${d}`).get(),
    db.ref(`drivers/${d}`).get(),
  ]);
  const driverRow =
    driverSnap.exists() && typeof driverSnap.val() === "object" ? driverSnap.val() : {};
  return {
    driver_active_ride: darSnap.exists() ? darSnap.val() : null,
    driver_active_delivery: dadSnap.exists() ? dadSnap.val() : null,
    activeRideId: driverRow.activeRideId ?? null,
    currentRideId: driverRow.currentRideId ?? null,
    active_ride_id: driverRow.active_ride_id ?? null,
    active_delivery_id: driverRow.active_delivery_id ?? null,
  };
}

/**
 * Admin: force-clear all active pointers for a driver (logs prior values).
 */
async function adminForceClearDriverActivePointers(db, driverId, actorUid = "") {
  const d = normUid(driverId);
  if (!d) {
    return { success: false, reason: "invalid_driver_id" };
  }
  const before = await readDriverActivePointerSnapshot(db, d);
  const tripIds = await collectDriverActivePointerTripIds(db, d);
  const firstTripId = tripIds.size > 0 ? [...tripIds][0] : "";
  await clearDriverActivePointers(db, d, firstTripId, "admin_force_clear");
  console.log(
    "ADMIN_FORCE_CLEAR_DRIVER_ACTIVE_POINTERS",
    `driverId=${d}`,
    `actor=${normUid(actorUid)}`,
    `before=${JSON.stringify(before)}`,
  );
  return {
    success: true,
    reason: "cleared",
    driver_id: d,
    before,
    cleared_trip_ids: [...tripIds],
  };
}

/**
 * Returns first trip id that truly blocks offers; clears stale pointers along the way.
 * @returns {Promise<{ blockingTripId: string|null, cleared: string[], checks: object[] }>}
 */
async function resolveValidatedBlockingTripForDriver(
  db,
  driverId,
  source,
  incomingRideId = "",
) {
  const d = normUid(driverId);
  const incoming = normUid(incomingRideId);
  const result = { blockingTripId: null, cleared: [], checks: [] };
  if (!d) return result;

  const tripIds = await collectDriverActivePointerTripIds(db, d);
  for (const tripId of tripIds) {
    const verdict = await tripIdBlocksDriverOffers(db, d, tripId, source, incoming);
    result.checks.push({ tripId, ...verdict, source });
    if (verdict.blocks) {
      result.blockingTripId = tripId;
      return result;
    }
    await clearDriverActivePointers(db, d, tripId, `${source}_stale_${verdict.reason}`);
    result.cleared.push(tripId);
  }
  return result;
}

function driverHeartbeatIsStale(profile, onlineRow, nowMs = Date.now()) {
  const ts = Math.max(
    Number(profile?.last_active_at ?? 0) || 0,
    Number(profile?.last_seen_at ?? 0) || 0,
    Number(profile?.availability?.last_seen_ms ?? 0) || 0,
    Number(onlineRow?.last_seen_ms ?? 0) || 0,
    Number(onlineRow?.updated_at ?? 0) || 0,
  );
  if (ts <= 0) return true;
  return nowMs - ts > STALE_DRIVER_HEARTBEAT_MS;
}

function emptyCleanupStats() {
  return {
    scanned: 0,
    cleared: 0,
    skipped_active: 0,
    missing: 0,
    terminal: 0,
    unassigned: 0,
    stale: 0,
    errors: 0,
  };
}

function logCleanupStats(job, stats) {
  console.log(
    "PRODUCTION_CLEANUP",
    `job=${job}`,
    `scanned=${stats.scanned}`,
    `cleared=${stats.cleared}`,
    `skipped_active=${stats.skipped_active}`,
    `missing=${stats.missing}`,
    `terminal=${stats.terminal}`,
    `unassigned=${stats.unassigned}`,
    `stale=${stats.stale}`,
    `errors=${stats.errors}`,
  );
}

module.exports = {
  STALE_DRIVER_HEARTBEAT_MS,
  STALE_SEARCHING_RIDE_MS,
  ASSIGNED_NOT_STARTED_STALE_MS,
  ENROUTE_IN_TRIP_STALE_MS,
  tripIdBlocksDriverOffers,
  loadTripRows,
  collectDriverActivePointerTripIds,
  clearDriverActivePointers,
  resolveValidatedBlockingTripForDriver,
  classifyTripForDriverOffers,
  evaluateActivePointerDecision,
  formatActivePointerDecisionLog,
  logActivePointerDecision,
  canonicalAssignedRideDriverId,
  canonicalAssignedDeliveryDriverId,
  normalizeDeliveryState,
  adminForceClearDriverActivePointers,
  readDriverActivePointerSnapshot,
  driverHeartbeatIsStale,
  emptyCleanupStats,
  logCleanupStats,
  isSearchingRide,
  rideRawBlocksOffers,
  evaluateActiveTripFreshness,
  activeTripIsFreshForBlocking,
  formatActivePointerFinalDecisionLog,
};
