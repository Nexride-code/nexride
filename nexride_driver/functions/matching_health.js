/**
 * Matching pipeline + rider payment health helpers for admin production snapshot.
 */

"use strict";

const { normUid } = require("./admin_auth");
const { locationModeLabel } = require("./driver_location_paths");

const STALE_GPS_MS = 12 * 60 * 1000;
/** Open-pool rows older than this are ignored for matching health (stale stuck searches). */
const ACTIVE_OPEN_MATCHING_MAX_AGE_MS = 45 * 60 * 1000;

/** @param {object|null|undefined} o */
function coordsFromPickup(o) {
  if (!o || typeof o !== "object") return { lat: NaN, lng: NaN };
  const lat = Number(o.lat ?? o.latitude ?? o.Latitude ?? "");
  const lng = Number(o.lng ?? o.longitude ?? o.Longitude ?? "");
  return { lat, lng };
}

const OPEN_MATCHING_TRIP_STATES = new Set([
  "searching",
  "requesting",
  "searching_driver",
  "matching",
  "awaiting_match",
  "offered",
  "offer_pending",
  "open",
  "requested",
]);

const TERMINAL_TRIP_STATES = new Set([
  "completed",
  "cancelled",
  "canceled",
  "expired",
  "trip_completed",
  "trip_cancelled",
]);

function nowMs() {
  return Date.now();
}

function normPaymentStatus(row) {
  return String(row?.payment_status ?? row?.paymentStatus ?? "")
    .trim()
    .toLowerCase();
}

function isPlaceholderDriverIdHealth(v) {
  if (v == null || v === undefined) return true;
  const s = String(v).trim().toLowerCase();
  return (
    s.length === 0 ||
    s === "waiting" ||
    s === "pending" ||
    s === "none" ||
    s === "null" ||
    s === "undefined" ||
    s === "unassigned"
  );
}

function rowHasAssignedDriver(row) {
  if (!row || typeof row !== "object") return false;
  const rider = normUid(row.rider_id ?? row.riderId);
  const fields = [
    "matched_driver_id",
    "matchedDriverId",
    "accepted_driver_id",
    "acceptedDriverId",
    "driver_id",
    "driverId",
  ];
  for (const key of fields) {
    const raw = row[key];
    if (isPlaceholderDriverIdHealth(raw)) continue;
    const d = normUid(raw);
    if (!d) continue;
    if (rider && d === rider) continue;
    return true;
  }
  return false;
}

const ASSIGNED_ACTIVE_TRIP_STATES_HEALTH = new Set([
  "driver_assigned",
  "driver_accepted",
  "accepted",
  "driver_arriving",
  "driver_arrived",
  "arrived",
  "in_progress",
  "on_trip",
  "enroute",
  "in_trip",
]);

function isOpenMatchingTripRow(row) {
  if (!row || typeof row !== "object") return false;
  if (rowHasAssignedDriver(row)) return false;
  const rs = String(row.request_status ?? row.requestStatus ?? "")
    .trim()
    .toLowerCase();
  if (rs === "accepted") return false;
  const ts = String(row.trip_state ?? row.status ?? "")
    .trim()
    .toLowerCase();
  if (TERMINAL_TRIP_STATES.has(ts)) return false;
  if (ASSIGNED_ACTIVE_TRIP_STATES_HEALTH.has(ts)) return false;
  const st = String(row.status ?? "").trim().toLowerCase();
  if (st === "accepted") return false;
  if (OPEN_MATCHING_TRIP_STATES.has(ts)) return true;
  return OPEN_MATCHING_TRIP_STATES.has(st);
}

/** Open matching row within the active dispatch window (excludes stale stuck searches). */
function isRecentOpenMatchingTripRow(row, asOfMs = nowMs()) {
  if (!isOpenMatchingTripRow(row)) return false;
  const created = Number(row.created_at ?? row.requested_at ?? 0) || 0;
  const updated = Number(row.updated_at ?? row.search_started_at ?? created) || 0;
  const anchor = Math.max(created, updated);
  if (anchor > 0 && asOfMs - anchor > ACTIVE_OPEN_MATCHING_MAX_AGE_MS) {
    return false;
  }
  return true;
}

function isActiveFlutterwaveVaAwaiting(row, asOfMs) {
  if (!row || typeof row !== "object") return false;
  const ps = normPaymentStatus(row);
  if (ps !== "pending_transfer") return false;
  const pm = String(row.payment_method ?? row.paymentMethod ?? "")
    .trim()
    .toLowerCase()
    .replace(/[\s-]+/g, "_");
  if (pm !== "bank_transfer") return false;
  if (row.bank_transfer_automated !== true) return false;
  if (!isOpenMatchingTripRow(row)) return false;
  const exp = Number(row.va_expires_at_ms ?? row.expires_at_ms ?? 0) || 0;
  if (exp > 0 && exp <= asOfMs) return false;
  return true;
}

function isPaymentIssueRed(row, asOfMs, terminalStatuses) {
  if (!row || typeof row !== "object") return false;
  const ps = normPaymentStatus(row);
  if (terminalStatuses.has(ps)) return false;
  if (ps === "failed" || ps === "declined" || ps === "bank_transfer_expired") return true;
  if (ps === "unpaid") return true;
  if (isActiveFlutterwaveVaAwaiting(row, asOfMs)) return false;
  if (ps === "pending_transfer" && isOpenMatchingTripRow(row)) return false;
  return false;
}

function classifyRiderPaymentRow(row, asOfMs, terminalStatuses, buckets) {
  if (!row || typeof row !== "object") return;
  const ps = normPaymentStatus(row);
  if (terminalStatuses.has(ps)) return;

  if (isActiveFlutterwaveVaAwaiting(row, asOfMs)) {
    buckets.pending_va_awaiting_transfer += 1;
    return;
  }

  if (ps === "failed" || ps === "declined") {
    buckets.failed_card_payments += 1;
    return;
  }
  if (ps === "bank_transfer_expired") {
    buckets.failed_card_payments += 1;
    return;
  }
  if (ps === "unpaid") {
    buckets.unpaid_rider_trips_orders += 1;
    return;
  }
  if (ps === "pending") {
    buckets.active_payment_intents += 1;
    return;
  }
  if (ps === "pending_manual_confirmation") {
    buckets.pending_bank_transfer_confirmations += 1;
    return;
  }
  if (ps === "pending_transfer") {
    buckets.pending_bank_transfer_confirmations += 1;
  }
}

const MATCHING_DISPATCH_FAILURE_STATES = new Set([
  "blocked",
  "no_offers",
  "no_drivers_written",
]);

/**
 * True when a recent open row is a real dispatch failure (eligible drivers exist but
 * offers were not written). Excludes waiting_next_batch, pending_fanout, and VA-awaiting rows.
 */
function isMatchingDispatchFailure(row, md, { offersWritten = 0, offeredIds = [] } = {}, asOfMs = nowMs()) {
  if (!row || typeof row !== "object") return false;
  if (!isRecentOpenMatchingTripRow(row, asOfMs)) return false;
  const written = Number(offersWritten) || 0;
  const fanoutCount = Array.isArray(offeredIds) ? offeredIds.length : 0;
  if (written > 0 || fanoutCount > 0) return false;
  if (isActiveFlutterwaveVaAwaiting(row, asOfMs)) return false;

  const debug = md && typeof md === "object" ? md : {};
  const matchingState = String(debug.matching_state ?? "")
    .trim()
    .toLowerCase();
  if (matchingState === "waiting_next_batch" || matchingState === "pending_fanout") {
    return false;
  }

  const noEligibleReason = String(debug.no_eligible_reason ?? debug.reason ?? "").trim();
  if (noEligibleReason === "waiting_next_batch") return false;

  const eligibleCount =
    Number(debug.eligible_driver_count ?? debug.eligible_same_market_count ?? 0) || 0;
  if (eligibleCount <= 0) return false;

  const queueWriteSuccess = debug.queue_write_success;
  if (queueWriteSuccess === true) return false;

  if (MATCHING_DISPATCH_FAILURE_STATES.has(matchingState)) return true;
  if (queueWriteSuccess === false) return true;
  if (
    noEligibleReason === "all_batches_exhausted" ||
    noEligibleReason === "all_drivers_filtered"
  ) {
    return true;
  }

  return false;
}

/**
 * Worst status across recent open matching rows.
 * One dispatch failure => red even if other open rows already have offers.
 */
function matchingStatusFromCounts({
  open,
  withOffers,
  noOffers,
  eligibleOnline,
  dispatchFailures = 0,
  pendingVa = 0,
}) {
  if (open === 0) return "green";
  if (dispatchFailures > 0) return "red";
  if (noOffers > 0) {
    if (eligibleOnline > 0) return "red";
    return "yellow";
  }
  if (pendingVa > 0) return "yellow";
  if (withOffers > 0 && noOffers === 0) return "green";
  return "green";
}

function primaryMatchingBlockReason(samples) {
  if (!Array.isArray(samples) || samples.length === 0) return null;
  const counts = {};
  for (const s of samples) {
    const r = String(s?.no_eligible_reason ?? "").trim();
    if (!r) continue;
    counts[r] = (counts[r] || 0) + 1;
  }
  const ranked = Object.entries(counts).sort((a, b) => b[1] - a[1]);
  return ranked.length > 0 ? ranked[0][0] : null;
}

async function scanOpenRequestMatching(db, asOfMs, { kind, refPath, fanoutPath, paymentStatuses }) {
  let open_requests = 0;
  let open_without_offers = 0;
  let open_with_offers = 0;
  let dispatch_failures = 0;
  let pending_va_awaiting = 0;
  let pending_offers = 0;
  let last_offer_created_at = null;
  const samples = [];
  const seenIds = new Set();

  async function processOpenRow(id, row) {
    if (!row || typeof row !== "object") return;
    if (seenIds.has(id)) return;
    if (!isRecentOpenMatchingTripRow(row, asOfMs)) return;
    seenIds.add(id);
    open_requests += 1;
    const fanSnap = await db.ref(`${fanoutPath}/${id}`).get();
    const fan = fanSnap.val() && typeof fanSnap.val() === "object" ? fanSnap.val() : {};
    const offeredIds = Object.keys(fan).map((k) => normUid(k)).filter(Boolean);
    const md = row.match_debug && typeof row.match_debug === "object" ? row.match_debug : {};
    const offersWritten = Number(md.offers_written ?? offeredIds.length) || offeredIds.length;
    const lastAt = Number(md.updated_at ?? md.checked_at ?? row.updated_at ?? 0) || 0;
    if (lastAt > (last_offer_created_at || 0) && offersWritten > 0) {
      last_offer_created_at = lastAt;
    }
    pending_offers += offeredIds.length;
    if (isActiveFlutterwaveVaAwaiting(row, asOfMs)) {
      pending_va_awaiting += 1;
    }
    if (offersWritten > 0 || offeredIds.length > 0) {
      open_with_offers += 1;
    } else {
      open_without_offers += 1;
      if (
        isMatchingDispatchFailure(
          row,
          md,
          { offersWritten, offeredIds },
          asOfMs,
        )
      ) {
        dispatch_failures += 1;
      }
    }
    if (samples.length < 8) {
      const pickup = row.pickup && typeof row.pickup === "object" ? row.pickup : {};
      const pc = coordsFromPickup(pickup);
      samples.push({
        kind,
        request_id: id,
        payment_status: normPaymentStatus(row),
        offer_delivery_status: md.offer_delivery_status ?? null,
        offers_written: offersWritten,
        matching_state: md.matching_state ?? null,
        eligible_driver_count:
          Number(md.eligible_driver_count ?? md.eligible_same_market_count ?? 0) || 0,
        queue_write_success: md.queue_write_success ?? null,
        dispatch_failure: isMatchingDispatchFailure(
          row,
          md,
          { offersWritten, offeredIds },
          asOfMs,
        ),
        no_eligible_reason: md.no_eligible_reason ?? md.reason ?? null,
        offered_driver_ids: offeredIds.slice(0, 6),
        dispatch_market_id: String(row.market_pool ?? row.market ?? "").trim() || null,
        pickup_lat: pc?.lat ?? null,
        pickup_lng: pc?.lng ?? null,
        created_at_ms: Number(row.created_at ?? row.requested_at ?? 0) || 0,
      });
    }
  }

  for (const ps of paymentStatuses) {
    let snap;
    try {
      snap = await db.ref(refPath).orderByChild("payment_status").equalTo(ps).limitToFirst(60).get();
    } catch (_) {
      continue;
    }
    const val = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
    for (const [id, row] of Object.entries(val)) {
      await processOpenRow(id, row);
    }
  }

  const tripStateQueries = [
    "searching",
    "searching_driver",
    "matching",
    "requested",
    "open",
    "awaiting_match",
  ];
  for (const ts of tripStateQueries) {
    let snap;
    try {
      snap = await db.ref(refPath).orderByChild("trip_state").equalTo(ts).limitToFirst(80).get();
    } catch (_) {
      continue;
    }
    const val = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
    for (const [id, row] of Object.entries(val)) {
      await processOpenRow(id, row);
    }
  }

  return {
    open_requests,
    open_without_offers,
    open_with_offers,
    dispatch_failures,
    pending_va_awaiting,
    pending_offers,
    last_offer_created_at,
    samples,
  };
}

/**
 * @param {import("firebase-admin/database").Database} db
 * @param {number} eligibleOnlineDrivers from live ops dashboard
 */
async function scanDriverLocationDiagnostics(db, asOfMs = nowMs()) {
  let online_gps_drivers = 0;
  let online_area_drivers = 0;
  let stale_gps_drivers = 0;
  let missing_dispatch_market_id = 0;
  let online_without_coords = 0;

  try {
    const snap = await db.ref("online_drivers").limitToFirst(500).get();
    const val = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
    for (const [driverId, row] of Object.entries(val)) {
      if (!row || typeof row !== "object") continue;
      if (row.is_online !== true) continue;
      const mode =
        locationModeLabel(row.location_mode ?? row.availability_mode) ||
        locationModeLabel(row.availability_mode);
      const lat = Number(row.lat ?? "");
      const lng = Number(row.lng ?? "");
      const market = String(row.dispatch_market_id ?? "").trim();
      if (!market) missing_dispatch_market_id += 1;
      if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
        online_without_coords += 1;
        continue;
      }
      if (mode === "gps") {
        online_gps_drivers += 1;
        const ts = Number(row.updated_at ?? 0) || 0;
        if (ts > 0 && asOfMs - ts > STALE_GPS_MS) stale_gps_drivers += 1;
      } else if (mode === "area") {
        online_area_drivers += 1;
      }
    }
  } catch (_) {}

  return {
    online_gps_drivers,
    online_area_drivers,
    stale_gps_drivers,
    missing_dispatch_market_id,
    online_without_coords,
  };
}

async function scanMatchingPipelineHealth(db, eligibleOnlineDrivers = 0) {
  const asOfMs = nowMs();
  const location_diagnostics = await scanDriverLocationDiagnostics(db, asOfMs);
  const ride = await scanOpenRequestMatching(db, asOfMs, {
    kind: "ride",
    refPath: "ride_requests",
    fanoutPath: "ride_offer_fanout",
    paymentStatuses: ["pending_transfer", "pending_manual_confirmation", "pending"],
  });
  const dispatch = await scanOpenRequestMatching(db, asOfMs, {
    kind: "dispatch",
    refPath: "delivery_requests",
    fanoutPath: "delivery_offer_fanout",
    paymentStatuses: ["pending_transfer", "pending", "pending_manual_confirmation"],
  });

  const ride_matching_status = matchingStatusFromCounts({
    open: ride.open_requests,
    withOffers: ride.open_with_offers,
    noOffers: ride.open_without_offers,
    eligibleOnline: eligibleOnlineDrivers,
    dispatchFailures: ride.dispatch_failures,
    pendingVa: ride.pending_va_awaiting,
  });
  const dispatch_matching_status = matchingStatusFromCounts({
    open: dispatch.open_requests,
    withOffers: dispatch.open_with_offers,
    noOffers: dispatch.open_without_offers,
    eligibleOnline: eligibleOnlineDrivers,
    dispatchFailures: dispatch.dispatch_failures,
    pendingVa: dispatch.pending_va_awaiting,
  });

  const merchant_delivery_matching_status =
    dispatch.open_requests > 0 ? dispatch_matching_status : "green";

  const last_offer_created_at = Math.max(
    ride.last_offer_created_at || 0,
    dispatch.last_offer_created_at || 0,
  ) || null;

  const overall = worstMatchingStatus(ride_matching_status, dispatch_matching_status);

  const openWithoutOffers = ride.open_without_offers + dispatch.open_without_offers;
  const allSamples = [...ride.samples, ...dispatch.samples];
  const matching_block_reason =
    openWithoutOffers > 0 ? primaryMatchingBlockReason(allSamples) : null;

  return {
    ride_matching_status,
    dispatch_matching_status,
    merchant_delivery_matching_status,
    overall_matching_status: overall,
    matching_block_reason,
    last_offer_created_at,
    open_requests_without_offers: openWithoutOffers,
    open_requests_with_offers: ride.open_with_offers + dispatch.open_with_offers,
    pending_offers: ride.pending_offers + dispatch.pending_offers,
    eligible_online_drivers: eligibleOnlineDrivers,
    location_diagnostics,
    ride,
    dispatch,
    samples: allSamples.slice(0, 12),
  };
}

function worstMatchingStatus(...statuses) {
  const order = { green: 0, yellow: 1, red: 2 };
  let w = "green";
  for (const s of statuses) {
    if ((order[s] ?? 0) > (order[w] ?? 0)) w = s;
  }
  return w;
}

module.exports = {
  OPEN_MATCHING_TRIP_STATES,
  ACTIVE_OPEN_MATCHING_MAX_AGE_MS,
  isOpenMatchingTripRow,
  isRecentOpenMatchingTripRow,
  isActiveFlutterwaveVaAwaiting,
  classifyRiderPaymentRow,
  matchingStatusFromCounts,
  isMatchingDispatchFailure,
  MATCHING_DISPATCH_FAILURE_STATES,
  primaryMatchingBlockReason,
  scanMatchingPipelineHealth,
  scanDriverLocationDiagnostics,
};
