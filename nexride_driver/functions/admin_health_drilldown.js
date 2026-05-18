/**
 * System Health drill-down rows + safe manual admin actions.
 */

"use strict";

const admin = require("firebase-admin");
const { logger } = require("firebase-functions");
const { normUid } = require("./admin_auth");
const adminPerms = require("./admin_permissions");
const adminAuditLog = require("./admin_audit_log");
const {
  isActiveFlutterwaveVaAwaiting,
  isOpenMatchingTripRow,
  isRecentOpenMatchingTripRow,
  ACTIVE_OPEN_MATCHING_MAX_AGE_MS,
} = require("./matching_health");
const {
  scanServiceAreaWarnings,
  scanOfficialBankAccountWarning,
  scanWithdrawals,
  withdrawalHasDestination,
} = require("./production_health_callable");
const { fanOutDriverOffersIfEligible, cancelRideRequest } = require("./ride_callables");
const { fanOutDeliveryOffersIfEligible } = require("./delivery_callables");
const { verifyFlutterwavePaymentStrict } = require("./flutterwave_api");
const paymentFlow = require("./payment_flow");
const { locationModeLabel } = require("./driver_location_paths");

const firestore = () => admin.firestore();
const STALE_DRIVER_HEARTBEAT_MS = 90_000;
const STALE_RIDE_SEARCH_MS = ACTIVE_OPEN_MATCHING_MAX_AGE_MS;

const TERMINAL_RIDER_PAYMENT_STATUSES = new Set([
  "completed",
  "cancelled",
  "canceled",
  "expired",
  "refunded",
  "verified",
  "paid",
  "prepaid",
  "bank_transfer_expired",
]);

const { canonicalAssignedDriverId } = require("./ride_callables");
const {
  canonicalAssignedDeliveryDriverId,
  normalizeDeliveryState,
} = require("./delivery_callables");

const DRILLDOWN_CARDS = new Set([
  "rides",
  "deliveries",
  "rider_payments",
  "matching",
  "drivers",
  "merchants",
  "service_areas",
  "payment_providers",
  "withdrawals",
  "verifications",
  "support",
  "payout_destinations",
  "infrastructure",
]);

function nowMs() {
  return Date.now();
}

async function requireAdmin(db, ctx, name) {
  return adminPerms.enforceCallable(db, ctx, name);
}

async function writeAudit(db, entry) {
  await adminAuditLog.writeAdminAuditLog(db, adminAuditLog.fromLegacyAuditEntry(entry));
}

function clampLimit(raw, max = 100) {
  return Math.min(max, Math.max(1, Number(raw ?? 40) || 40));
}

function normStatusFilter(raw) {
  const s = String(raw ?? "all").trim().toLowerCase();
  if (s === "red" || s === "yellow" || s === "green" || s === "stale") return s;
  return "all";
}

function rowPassesFilter(rowStatus, filter) {
  if (filter === "all" || filter === "stale") return true;
  return rowStatus === filter;
}

const MATCHING_DRILLDOWN_DEFAULT_LIMIT = 50;
const MATCHING_MAX_SCAN_IDS = 180;
const MATCHING_MAX_STALE_ROWS = 12;
const MATCHING_QUERY_LIMIT = 35;

function buildRow({
  rowId,
  status = "yellow",
  reason = "",
  actionNeeded = "",
  recommendedAction = "",
  entityType = null,
  entityId = null,
  secondaryId = null,
  fields = {},
  actions = [],
}) {
  return {
    row_id: String(rowId || "").trim() || `${entityType || "row"}_${entityId || nowMs()}`,
    status,
    reason: String(reason || "").slice(0, 500),
    action_needed: String(actionNeeded || "").slice(0, 300),
    recommended_action: String(recommendedAction || "").slice(0, 300),
    entity_type: entityType,
    entity_id: entityId,
    secondary_id: secondaryId,
    fields,
    actions,
    explain_placeholder:
      "Explain issue (coming soon): summarizes status, reason, and recommended action from row fields.",
  };
}

function riderPaymentActivityTimeMs(row) {
  if (!row || typeof row !== "object") return 0;
  const candidates = [row.updated_at, row.created_at, row.requested_at];
  let max = 0;
  for (const c of candidates) {
    const n = Number(c);
    if (Number.isFinite(n) && n > max) max = n;
  }
  return max;
}

function normPaymentStatus(row) {
  return String(row?.payment_status ?? row?.paymentStatus ?? "")
    .trim()
    .toLowerCase();
}

async function loadUserContact(db, uid) {
  const id = normUid(uid);
  if (!id) return {};
  try {
    const snap = await db.ref(`users/${id}`).get();
    const u = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
    return {
      rider_name: String(u.displayName ?? u.name ?? u.full_name ?? "").trim() || null,
      phone: String(u.phone ?? u.phone_number ?? "").trim() || null,
      email: String(u.email ?? "").trim() || null,
    };
  } catch (_) {
    return {};
  }
}

async function loadPaymentIntentMeta(fs, txRef) {
  const ref = String(txRef ?? "").trim();
  if (!ref) return {};
  try {
    const doc = await fs.collection("payment_intents").doc(ref).get();
    if (!doc.exists) return {};
    const x = doc.data() || {};
    return {
      webhook_result: x.webhook_result ?? x.webhook_status ?? null,
      webhook_status: x.webhook_status ?? null,
      payment_failure_reason: x.payment_failure_reason ?? x.reason_code ?? null,
      provider: x.provider ?? "flutterwave_va",
    };
  } catch (_) {
    return {};
  }
}

function classifyRiderPaymentRowStatus(row, asOfMs) {
  const ps = normPaymentStatus(row);
  if (ps === "failed" || ps === "declined" || ps === "unpaid") return "red";
  if (ps === "bank_transfer_expired") return "red";
  if (ps === "pending_transfer") {
    const exp = Number(row.va_expires_at_ms ?? row.expires_at_ms ?? 0) || 0;
    if (exp > 0 && exp <= asOfMs) return "red";
    if (isActiveFlutterwaveVaAwaiting(row, asOfMs)) return "yellow";
    return "yellow";
  }
  if (ps === "pending" || ps === "pending_manual_confirmation") return "yellow";
  return "green";
}

async function drilldownRiderPayments(db, { limit, statusFilter, asOfMs }) {
  const fs = firestore();
  const rows = [];
  const queries = [
    { path: "ride_requests", ps: "failed" },
    { path: "ride_requests", ps: "unpaid" },
    { path: "ride_requests", ps: "pending_transfer" },
    { path: "ride_requests", ps: "pending_manual_confirmation" },
    { path: "ride_requests", ps: "pending" },
    { path: "delivery_requests", ps: "failed" },
    { path: "delivery_requests", ps: "pending_transfer" },
  ];

  for (const q of queries) {
    if (rows.length >= limit) break;
    let snap;
    try {
      snap = await db.ref(q.path).orderByChild("payment_status").equalTo(q.ps).limitToFirst(80).get();
    } catch (_) {
      continue;
    }
    const val = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
    for (const [id, row] of Object.entries(val)) {
      if (rows.length >= limit) break;
      if (!row || typeof row !== "object") continue;
      const ps = normPaymentStatus(row);
      if (TERMINAL_RIDER_PAYMENT_STATUSES.has(ps) && ps !== "pending_transfer") continue;
      const rowStatus = classifyRiderPaymentRowStatus(row, asOfMs);
      if (!rowPassesFilter(rowStatus, statusFilter)) continue;
      const isRide = q.path === "ride_requests";
      const riderId = normUid(row.rider_id ?? row.customer_id);
      const txRef = String(
        row.payment_reference ?? row.customer_transaction_reference ?? "",
      ).trim();
      const contact = await loadUserContact(db, riderId);
      const intentMeta = await loadPaymentIntentMeta(fs, txRef);
      const actions = ["copy_tx_ref", "open_payment_intent"];
      if (isRide && id) actions.push("open_trip");
      if (rowStatus === "red" && txRef) {
        actions.push("expire_payment_intent", "retry_verify");
      }
      if (rowStatus === "red" && isRide) actions.push("cancel_failed_payment_request");
      rows.push(
        buildRow({
          rowId: `${q.path}_${id}`,
          status: rowStatus,
          reason: `${ps} · ${intentMeta.payment_failure_reason || row.payment_failure_reason || "payment_issue"}`,
          actionNeeded:
            rowStatus === "red"
              ? "Resolve or expire failed/unpaid payment"
              : "Monitor transfer or confirm payment",
          recommendedAction:
            rowStatus === "red" ? "Expire VA or retry verify" : "Wait for transfer or open intent",
          entityType: isRide ? "ride" : "delivery",
          entityId: id,
          secondaryId: riderId || null,
          fields: {
            ...contact,
            rider_id: riderId || null,
            ride_id: isRide ? id : null,
            delivery_id: isRide ? null : id,
            order_id: row.order_id ?? null,
            tx_ref: txRef || null,
            provider: intentMeta.provider ?? row.payment_provider ?? row.payment_method ?? null,
            payment_status: ps,
            payment_method: row.payment_method ?? null,
            amount_ngn: Number(row.total_ngn ?? row.fare ?? 0) || null,
            expires_at_ms: Number(row.va_expires_at_ms ?? row.expires_at_ms ?? 0) || null,
            webhook_result: intentMeta.webhook_result ?? null,
            failure_reason:
              intentMeta.payment_failure_reason ??
              row.payment_failure_reason ??
              row.payment_error ??
              null,
            updated_at_ms: riderPaymentActivityTimeMs(row) || null,
          },
          actions,
        }),
      );
    }
  }
  return rows;
}

function matchingRowCreatedAtMs(row) {
  return Number(row?.created_at ?? row?.requested_at ?? row?.updated_at ?? 0) || 0;
}

async function collectOpenMatchingCandidates(db, refPath) {
  const byId = new Map();
  const paymentStatuses = ["pending_transfer", "pending_manual_confirmation", "pending", "paid"];
  const tripStates = ["searching", "searching_driver", "matching", "requested", "open"];
  const statusValues = ["searching", "requested"];
  const ingest = (val) => {
    if (!val || typeof val !== "object") return;
    for (const [id, row] of Object.entries(val)) {
      if (byId.size >= MATCHING_MAX_SCAN_IDS) return;
      if (!row || typeof row !== "object") continue;
      if (!isOpenMatchingTripRow(row)) continue;
      if (!byId.has(id)) byId.set(id, row);
    }
  };
  for (const ps of paymentStatuses) {
    if (byId.size >= MATCHING_MAX_SCAN_IDS) break;
    try {
      const snap = await db
        .ref(refPath)
        .orderByChild("payment_status")
        .equalTo(ps)
        .limitToFirst(MATCHING_QUERY_LIMIT)
        .get();
      ingest(snap.val());
    } catch (_) {}
  }
  for (const ts of tripStates) {
    if (byId.size >= MATCHING_MAX_SCAN_IDS) break;
    try {
      const snap = await db
        .ref(refPath)
        .orderByChild("trip_state")
        .equalTo(ts)
        .limitToFirst(MATCHING_QUERY_LIMIT)
        .get();
      ingest(snap.val());
    } catch (_) {}
  }
  for (const st of statusValues) {
    if (byId.size >= MATCHING_MAX_SCAN_IDS) break;
    try {
      const snap = await db
        .ref(refPath)
        .orderByChild("status")
        .equalTo(st)
        .limitToFirst(MATCHING_QUERY_LIMIT)
        .get();
      ingest(snap.val());
    } catch (_) {}
  }
  return byId;
}

async function buildMatchingDrilldownRow(db, p, id, row, { asOfMs, statusFilter }) {
  if (!isOpenMatchingTripRow(row)) return null;
  const isStale = !isRecentOpenMatchingTripRow(row, asOfMs);
  const md = row.match_debug && typeof row.match_debug === "object" ? row.match_debug : {};
  const offersWritten = Number(md.offers_written ?? 0) || 0;
  const fanSnap = await db.ref(`${p.fanout}/${id}`).get();
  const fan = fanSnap.val() && typeof fanSnap.val() === "object" ? fanSnap.val() : {};
  const offeredIds = Object.keys(fan).filter(Boolean);
  const hasOffers = offersWritten > 0 || offeredIds.length > 0;
  const rowStatus = isStale ? "yellow" : hasOffers ? "green" : "red";
  if (statusFilter === "stale" && !isStale) return null;
  if (statusFilter !== "all" && statusFilter !== "stale" && !rowPassesFilter(rowStatus, statusFilter)) {
    return null;
  }
  const pickup = row.pickup && typeof row.pickup === "object" ? row.pickup : {};
  const dropoff = row.dropoff && typeof row.dropoff === "object" ? row.dropoff : {};
  const matchingState = md.matching_state ?? null;
  const eligibleSameMarket = md.eligible_same_market_count ?? md.eligible_driver_count ?? null;
  const noEligibleReason = md.no_eligible_reason ?? md.reason ?? null;
  const dispatchMarket = String(row.dispatch_market_id ?? row.market_pool ?? row.market ?? "").trim();
  const resolvedCity = String(row.resolved_service_city_id ?? "").trim().toLowerCase();
  const pickupAddr = String(pickup.address ?? pickup.formatted_address ?? "").toLowerCase();
  let onlineDriversInMarket = null;
  if (noEligibleReason === "no_drivers_in_market" && dispatchMarket) {
    try {
      const onlineSnap = await db.ref("online_drivers").limitToFirst(400).get();
      const online = onlineSnap.val() && typeof onlineSnap.val() === "object" ? onlineSnap.val() : {};
      onlineDriversInMarket = Object.values(online).filter((d) => {
        if (!d || typeof d !== "object" || d.is_online !== true) return false;
        const dm = String(d.dispatch_market_id ?? d.dispatch_market ?? "").trim().toLowerCase();
        return dm === dispatchMarket.toLowerCase();
      }).length;
    } catch (_) {
      onlineDriversInMarket = null;
    }
  }
  const marketResolutionMayBeWrong =
    noEligibleReason === "no_drivers_in_market" &&
    pickupAddr.includes("asaba") &&
    resolvedCity === "onitsha";
  const suggestedAction =
    marketResolutionMayBeWrong
      ? "Check pickup market resolution or driver online market."
      : noEligibleReason === "no_drivers_in_market" && (onlineDriversInMarket ?? 0) > 0
        ? "Drivers online in market — check filters or re-run matching."
        : null;

  let dispatchGeneration = null;
  let orchestrationLeaseHeld = false;
  let dispatchMetricsSummary = null;
  let marketPressureSummary = null;
  if (p.kind === "ride") {
    try {
      const [genSnap, orchSnap, metricsSnap, pressureSnap] = await Promise.all([
        db.ref(`ride_requests/${id}/dispatch_generation`).get(),
        db.ref(`dispatch_orchestration_leases/${id}`).get(),
        db.ref(`dispatch_metrics/${id}`).get(),
        dispatchMarket
          ? db.ref(`dispatch_market_pressure/${dispatchMarket}`).get()
          : Promise.resolve({ exists: () => false, val: () => null }),
      ]);
      dispatchGeneration = Number(genSnap.val() ?? 0) || null;
      if (orchSnap.exists()) {
        const orch = orchSnap.val() || {};
        orchestrationLeaseHeld =
          (Number(orch.expires_at ?? 0) || 0) > Date.now();
      }
      if (metricsSnap.exists()) {
        const m = metricsSnap.val() || {};
        dispatchMetricsSummary = {
          recovery_generation: m.recovery_generation ?? null,
          rerun_count: m.rerun_count ?? null,
          last_popup_ack_at_ms: m.last_popup_ack_at_ms ?? null,
        };
      }
      if (pressureSnap.exists()) {
        const pr = pressureSnap.val() || {};
        marketPressureSummary = {
          active_searching: pr.active_searching ?? null,
          active_fanouts: pr.active_fanouts ?? null,
          queue_depth: pr.queue_depth ?? null,
        };
      }
    } catch (_) {}
  }

  return buildRow({
    rowId: `matching_${p.kind}_${id}`,
    status: rowStatus,
    reason: isStale
      ? "stale_open_search"
      : matchingState === "waiting_next_batch"
        ? "waiting_next_batch"
        : md.no_eligible_reason ?? md.matching_block_reason ?? "open_without_offers",
    actionNeeded: isStale
      ? `Stale search (>${Math.round(ACTIVE_OPEN_MATCHING_MAX_AGE_MS / 60000)}m) — cancel or re-run matching`
      : hasOffers
        ? "Monitor driver acceptance"
        : suggestedAction ??
            (matchingState === "waiting_next_batch"
              ? "More eligible drivers remain — wait for decline or re-fan-out"
              : "Re-run matching or cancel stale search"),
    recommendedAction: isStale
      ? "adminCancelStaleRideSearch"
      : hasOffers
        ? "Open trip"
        : "adminRerunRideMatching",
    entityType: p.kind === "ride" ? "ride" : "delivery",
    entityId: id,
    secondaryId: normUid(row.rider_id ?? row.customer_id) || null,
    fields: {
      kind: p.kind,
      ride_id: p.kind === "ride" ? id : null,
      delivery_id: p.kind === "dispatch" ? id : null,
      rider_id: normUid(row.rider_id) || null,
      customer_id: normUid(row.customer_id) || null,
      pickup_address: pickup.address ?? pickup.formatted_address ?? null,
      dropoff_address: dropoff.address ?? dropoff.formatted_address ?? null,
      resolved_service_city_id: row.resolved_service_city_id ?? null,
      resolved_service_region_id: row.resolved_service_region_id ?? null,
      pickup_resolution_warning: md.pickup_resolution_warning ?? null,
      rider_hint_city_id: md.rider_hint_city_id ?? null,
      dispatch_market_id: row.dispatch_market_id ?? row.market_pool ?? row.market ?? null,
      online_drivers_in_dispatch_market: onlineDriversInMarket,
      market_resolution_may_be_wrong: marketResolutionMayBeWrong,
      eligible_driver_count: md.eligible_driver_count ?? null,
      eligible_same_market_count: eligibleSameMarket,
      nearest_driver_ids: md.nearest_driver_ids ?? [],
      offers_written: offersWritten,
      offered_driver_ids: offeredIds.slice(0, 12),
      batch_driver_ids: md.batch_driver_ids ?? [],
      fanout_batch_number: md.fanout_batch_number ?? null,
      batch_remaining_eligible: md.batch_remaining_eligible ?? null,
      matching_state: matchingState,
      candidate_driver_samples: md.candidate_driver_samples ?? [],
      rejected_driver_samples: md.rejected_driver_samples ?? [],
      exhausted_driver_ids: md.exhausted_driver_ids ?? [],
      filtered_reason:
        md.matching_block_reason ??
        (Array.isArray(md.rejected_driver_samples) &&
        md.rejected_driver_samples[0] &&
        typeof md.rejected_driver_samples[0] === "object"
          ? md.rejected_driver_samples[0].filtered_reason
          : null),
      queue_write_by_driver: md.queue_write_by_driver ?? null,
      queue_write_success: md.queue_write_success ?? null,
      listener_seen_by: md.listener_seen_by ?? null,
      listener_seen_at:
        md.listener_seen_at ??
        (md.listener_seen_by && typeof md.listener_seen_by === "object"
          ? Math.max(
              ...Object.values(md.listener_seen_by)
                .map((v) => Number(v) || 0)
                .filter((n) => n > 0),
              0,
            ) || null
          : null),
      no_eligible_reason: md.no_eligible_reason ?? md.reason ?? null,
      matching_block_reason: md.matching_block_reason ?? null,
      payment_status: normPaymentStatus(row),
      created_at_ms: matchingRowCreatedAtMs(row),
      is_stale_search: isStale,
      stale_age_minutes: isStale
        ? Math.round((asOfMs - matchingRowCreatedAtMs(row)) / 60000)
        : null,
      dispatch_generation: dispatchGeneration,
      orchestration_lease_held: orchestrationLeaseHeld,
      dispatch_metrics: dispatchMetricsSummary,
      market_pressure: marketPressureSummary,
      dispatch_snapshot: p.kind === "ride" ? await (async () => {
        try {
          const { readDispatchSnapshot } = require("./dispatch_engine/dispatch_snapshot_engine");
          return await readDispatchSnapshot(db, id);
        } catch (_) {
          return null;
        }
      })() : null,
    },
    actions:
      p.kind === "ride"
        ? [
            "copy_ride_id",
            "open_trip",
            "repair_dispatch_blockers",
            "expire_leases",
            "kill_orchestration_lease",
            "invalidate_dispatch_generation",
            "replay_fanout",
            "rebuild_dispatch_metrics",
            "rebuild_dispatch_snapshot",
            "requeue_dispatch_work",
            "view_dead_letters",
            "rerun_matching",
            "cancel_stale_search",
            "open_rider_profile",
          ]
        : ["copy_ride_id", "open_trip", "rerun_delivery_matching", "open_rider_profile"],
  });
}

async function drilldownMatching(db, { limit, statusFilter, asOfMs, offset = 0 }) {
  const pageLimit = Math.min(MATCHING_DRILLDOWN_DEFAULT_LIMIT, Math.max(1, Number(limit) || 50));
  const pageOffset = Math.max(0, Number(offset) || 0);
  const showStaleOnly = statusFilter === "stale";
  const paths = [
    { kind: "ride", ref: "ride_requests", fanout: "ride_offer_fanout" },
    { kind: "dispatch", ref: "delivery_requests", fanout: "delivery_offer_fanout" },
  ];

  const candidates = [];
  let totalScanned = 0;

  for (const p of paths) {
    const byId = await collectOpenMatchingCandidates(db, p.ref);
    totalScanned += byId.size;
    for (const [id, row] of byId.entries()) {
      if (!isOpenMatchingTripRow(row)) continue;
      const isStale = !isRecentOpenMatchingTripRow(row, asOfMs);
      if (showStaleOnly && !isStale) continue;
      if (!showStaleOnly && isStale && statusFilter !== "all") continue;
      const md = row.match_debug && typeof row.match_debug === "object" ? row.match_debug : {};
      const offersWritten = Number(md.offers_written ?? 0) || 0;
      const rowStatus = isStale ? "yellow" : offersWritten > 0 ? "green" : "red";
      if (!showStaleOnly && statusFilter !== "all" && !rowPassesFilter(rowStatus, statusFilter)) {
        continue;
      }
      candidates.push({
        id,
        row,
        kind: p.kind,
        path: p,
        isStale,
        created_at_ms: matchingRowCreatedAtMs(row),
        offers_written: offersWritten,
      });
    }
  }

  candidates.sort((a, b) => b.created_at_ms - a.created_at_ms);

  const recent = candidates.filter((c) => !c.isStale);
  const stale = candidates.filter((c) => c.isStale);
  let ordered;
  if (showStaleOnly) {
    ordered = stale;
  } else if (statusFilter === "all") {
    ordered = [
      ...recent,
      ...stale.slice(0, MATCHING_MAX_STALE_ROWS),
    ];
  } else {
    ordered = recent;
  }

  const pageSlice = ordered.slice(pageOffset, pageOffset + pageLimit);
  const rows = [];
  for (const c of pageSlice) {
    const built = await buildMatchingDrilldownRow(db, c.path, c.id, c.row, {
      asOfMs,
      statusFilter,
    });
    if (built) rows.push(built);
  }

  return {
    rows,
    total_scanned: totalScanned,
    rows_returned: rows.length,
    has_more: pageOffset + pageLimit < ordered.length,
    next_offset: pageOffset + pageLimit,
    candidate_count: ordered.length,
  };
}

async function drilldownDrivers(db, { limit, statusFilter, asOfMs }) {
  const rows = [];
  const [onlineSnap, driversSnap] = await Promise.all([
    db.ref("online_drivers").limitToFirst(400).get(),
    db.ref("drivers").limitToFirst(400).get(),
  ]);
  const online =
    onlineSnap.val() && typeof onlineSnap.val() === "object" ? onlineSnap.val() : {};
  const all =
    driversSnap.val() && typeof driversSnap.val() === "object" ? driversSnap.val() : {};

  for (const [driverId, mirror] of Object.entries(online)) {
    if (rows.length >= limit) break;
    if (!mirror || typeof mirror !== "object" || mirror.is_online !== true) continue;
    const prof = all[driverId] && typeof all[driverId] === "object" ? all[driverId] : {};
    const merged = { ...prof, ...mirror };
    const ts = Math.max(Number(merged.updated_at ?? 0) || 0, Number(mirror.updated_at ?? 0) || 0);
    const lat = Number(merged.lat ?? "");
    const lng = Number(merged.lng ?? "");
    const market = String(merged.dispatch_market_id ?? merged.dispatch_market ?? "").trim();
    const mode = locationModeLabel(merged.location_mode ?? merged.availability_mode);
    let rowStatus = "green";
    let reason = "online";
    let actionNeeded = "None";
    let recommendedAction = "Monitor";
    const actions = ["open_driver_profile", "view_location_mode"];

    if (!market) {
      rowStatus = "red";
      reason = "missing_dispatch_market_id";
      actionNeeded = "Set dispatch market or take offline";
      recommendedAction = "Edit driver area / mark offline";
      actions.push("mark_offline");
    } else if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
      rowStatus = "yellow";
      reason = "missing_location";
      actionNeeded = "Driver has no coordinates";
      recommendedAction = "Ask driver to refresh GPS or area mode";
    } else if (ts > 0 && asOfMs - ts > STALE_DRIVER_HEARTBEAT_MS) {
      rowStatus = "yellow";
      reason = "stale_heartbeat";
      actionNeeded = "Heartbeat stale while marked online";
      recommendedAction = "Mark offline or wait for refresh";
      actions.push("mark_offline");
    }

    const darSnap = await db.ref(`driver_active_ride/${driverId}`).get();
    const dar = darSnap.val() && typeof darSnap.val() === "object" ? darSnap.val() : {};
    const activeRideId = normUid(dar.ride_id ?? dar.rideId);
    if (activeRideId) {
      const rideSnap = await db.ref(`ride_requests/${activeRideId}`).get();
      const ride = rideSnap.val();
      const tsState = String(ride?.trip_state ?? ride?.status ?? "").toLowerCase();
      if (
        !ride ||
        tsState === "completed" ||
        tsState === "cancelled" ||
        tsState === "canceled" ||
        tsState === "expired"
      ) {
        rowStatus = rowStatus === "green" ? "yellow" : rowStatus;
        reason = "stale_active_ride_pointer";
        actionNeeded = "Clear stale driver_active_ride";
        recommendedAction = "adminClearDriverStaleActiveRide";
        actions.push("clear_stale_active_ride");
      }
    }

    if (!rowPassesFilter(rowStatus, statusFilter)) continue;
    rows.push(
      buildRow({
        rowId: `driver_${driverId}`,
        status: rowStatus,
        reason,
        actionNeeded,
        recommendedAction,
        entityType: "driver",
        entityId: driverId,
        fields: {
          driver_id: driverId,
          online: true,
          location_mode: mode || null,
          dispatch_market_id: market || null,
          service_area_city_id: merged.service_area_city_id ?? null,
          lat: Number.isFinite(lat) ? lat : null,
          lng: Number.isFinite(lng) ? lng : null,
          last_updated_at_ms: ts || null,
          active_ride_id: activeRideId || null,
          listener_offer_status: "check driver_offer_queue in RTDB",
        },
        actions,
      }),
    );
  }
  return rows;
}

async function drilldownMerchants(db, { limit, statusFilter }) {
  const rows = [];
  try {
    const snap = await firestore()
      .collection("merchant_orders")
      .where("status", "in", ["pending", "confirmed", "preparing", "ready", "awaiting_driver"])
      .limit(Math.min(limit, 60))
      .get();
    for (const doc of snap.docs) {
      if (rows.length >= limit) break;
      const data = doc.data() || {};
      const needsDriver =
        String(data.fulfillment_type ?? "").includes("delivery") &&
        !String(data.driver_id ?? data.assigned_driver_id ?? "").trim();
      const ps = String(data.payment_status ?? "").toLowerCase();
      const failedTopup = ps === "failed" || ps === "unpaid";
      let rowStatus = "green";
      if (failedTopup) rowStatus = "red";
      else if (needsDriver) rowStatus = "yellow";
      if (!rowPassesFilter(rowStatus, statusFilter)) continue;
      rows.push(
        buildRow({
          rowId: `merchant_order_${doc.id}`,
          status: rowStatus,
          reason: failedTopup ? `payment_${ps}` : needsDriver ? "needs_driver" : "open_order",
          actionNeeded: failedTopup
            ? "Review merchant payment"
            : needsDriver
              ? "Assign driver / rerun delivery matching"
              : "Monitor order",
          recommendedAction: needsDriver ? "adminRerunDeliveryMatching" : "Open merchant profile",
          entityType: "merchant_order",
          entityId: doc.id,
          secondaryId: String(data.merchant_id ?? "").trim() || null,
          fields: {
            merchant_id: data.merchant_id ?? null,
            order_id: doc.id,
            status: data.status ?? null,
            payment_status: ps || null,
            needs_driver: needsDriver,
            delivery_id: data.delivery_id ?? null,
          },
          actions: ["open_merchant_profile", "rerun_delivery_matching", "cancel_stale_delivery"],
        }),
      );
    }
  } catch (e) {
    logger.warn("drilldownMerchants failed", { err: String(e?.message || e) });
  }
  return rows;
}

async function drilldownServiceAreas(db, { limit, statusFilter }) {
  const [svc, bank] = await Promise.all([
    scanServiceAreaWarnings(db),
    scanOfficialBankAccountWarning(db),
  ]);
  const rows = [];
  for (const w of svc.warnings || []) {
    if (rows.length >= limit) break;
    const rowStatus = "yellow";
    if (!rowPassesFilter(rowStatus, statusFilter)) continue;
    rows.push(
      buildRow({
        rowId: `svc_${w.region_id}_${w.city_id}_${w.type}`,
        status: rowStatus,
        reason: w.type,
        actionNeeded: "Fix service area configuration",
        recommendedAction: "Edit city or seed rollout regions",
        entityType: "service_area",
        entityId: w.city_id ?? null,
        secondaryId: w.region_id ?? null,
        fields: { ...w },
        actions: ["seed_rollout_regions", "enable_disable_city", "edit_dispatch_market"],
      }),
    );
  }
  for (const w of bank.warnings || []) {
    if (rows.length >= limit) break;
    const rowStatus = "red";
    if (!rowPassesFilter(rowStatus, statusFilter)) continue;
    rows.push(
      buildRow({
        rowId: `bank_${w.type}`,
        status: rowStatus,
        reason: w.type,
        actionNeeded: "Configure official bank account",
        recommendedAction: "Update app_config/nexride_official_bank_account",
        entityType: "config",
        entityId: "official_bank",
        fields: { ...w },
        actions: [],
      }),
    );
  }
  return rows;
}

async function drilldownPaymentProviders(_db, { statusFilter }) {
  const payDiag = require("./payment_diagnostics_store");
  const {
    flutterwaveSecretForVerify,
    flutterwavePublicKeyForClient,
    flutterwaveKeysReady,
  } = require("./params");
  const projectId = String(process.env.GCLOUD_PROJECT || "").trim();
  const snap = payDiag.getDiagnosticsSnapshot();
  const rowStatus = flutterwaveKeysReady() ? "green" : "red";
  if (!rowPassesFilter(rowStatus, statusFilter)) return [];
  return [
    buildRow({
      rowId: "payment_providers_flutterwave",
      status: rowStatus,
      reason: rowStatus === "green" ? "keys_ready" : "keys_missing",
      actionNeeded: rowStatus === "red" ? "Configure Flutterwave keys" : "Monitor webhooks",
      recommendedAction: "Copy webhook URL into Flutterwave dashboard",
      entityType: "payment_provider",
      entityId: "flutterwave",
      fields: {
        flutterwave_public_ready: Boolean(String(flutterwavePublicKeyForClient() || "").trim()),
        flutterwave_secret_ready: Boolean(String(flutterwaveSecretForVerify() || "").trim()),
        flutterwave_keys_ready: flutterwaveKeysReady(),
        webhook_url: projectId
          ? `https://us-central1-${projectId}.cloudfunctions.net/flutterwaveWebhook`
          : null,
        last_webhook_received_at_ms: snap.last_webhook_received_at_ms ?? null,
        last_va_failure: snap.last_va_create_errors?.[0] ?? null,
        last_card_failure: snap.last_card_init_errors?.[0] ?? null,
        last_verify_error: snap.last_verify_errors?.[0] ?? null,
      },
      actions: ["copy_webhook_url", "open_payment_diagnostics"],
    }),
  ];
}

async function drilldownWithdrawals(db, { limit, statusFilter }) {
  const wd = await scanWithdrawals(db);
  const rows = [];
  try {
    const snap = await db
      .ref("withdraw_requests")
      .orderByChild("status")
      .equalTo("pending")
      .limitToFirst(limit)
      .get();
    const val = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
    for (const [id, row] of Object.entries(val)) {
      if (rows.length >= limit) break;
      if (!row || typeof row !== "object") continue;
      const hasDest = withdrawalHasDestination(row);
      const rowStatus = hasDest ? "yellow" : "red";
      if (!rowPassesFilter(rowStatus, statusFilter)) continue;
      const et = String(row.entity_type ?? row.entityType ?? "driver").toLowerCase();
      rows.push(
        buildRow({
          rowId: `withdrawal_${id}`,
          status: rowStatus,
          reason: hasDest ? "pending_withdrawal" : "missing_payout_destination",
          actionNeeded: hasDest ? "Approve or reject withdrawal" : "Collect payout destination",
          recommendedAction: "Open withdrawals queue",
          entityType: et === "merchant" ? "merchant" : "driver",
          entityId: normUid(row.driverId ?? row.driver_id ?? row.merchantId ?? row.merchant_id),
          secondaryId: id,
          fields: {
            withdrawal_id: id,
            amount_ngn: Number(row.amount_ngn ?? row.amount ?? 0) || null,
            entity_type: et,
            has_destination: hasDest,
          },
          actions: ["open_withdrawals"],
        }),
      );
    }
  } catch (e) {
    logger.warn("drilldownWithdrawals failed", { err: String(e?.message || e) });
  }
  if (rows.length === 0 && wd.pending_total > 0) {
    rows.push(
      buildRow({
        rowId: "withdrawals_summary",
        status: "yellow",
        reason: "pending_withdrawals",
        actionNeeded: `${wd.pending_total} pending withdrawals`,
        recommendedAction: "Open withdrawals admin section",
        entityType: "summary",
        entityId: null,
        fields: {
          pending_driver: wd.pending_driver,
          pending_merchant: wd.pending_merchant,
        },
        actions: ["open_withdrawals"],
      }),
    );
  }
  return rows;
}

async function drilldownVerifications({ limit, statusFilter }) {
  const rows = [];
  try {
    const snap = await firestore()
      .collection("identity_verifications")
      .where("status", "in", ["pending", "submitted", "under_review"])
      .limit(limit)
      .get();
    for (const doc of snap.docs) {
      const data = doc.data() || {};
      const rowStatus = "yellow";
      if (!rowPassesFilter(rowStatus, statusFilter)) continue;
      rows.push(
        buildRow({
          rowId: `verification_${doc.id}`,
          status: rowStatus,
          reason: String(data.status ?? "pending"),
          actionNeeded: "Review verification documents",
          recommendedAction: "Open verification center",
          entityType: "user",
          entityId: String(data.user_id ?? data.uid ?? doc.id).trim() || doc.id,
          fields: {
            verification_id: doc.id,
            status: data.status ?? null,
            document_type: data.document_type ?? null,
            submitted_at: data.submitted_at ?? null,
          },
          actions: ["open_verification"],
        }),
      );
    }
  } catch (e) {
    logger.warn("drilldownVerifications failed", { err: String(e?.message || e) });
  }
  return rows;
}

async function drilldownSupport(db, { limit, statusFilter }) {
  const rows = [];
  try {
    const snap = await db
      .ref("support_tickets")
      .orderByChild("status")
      .equalTo("open")
      .limitToFirst(limit)
      .get();
    const val = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
    for (const [id, row] of Object.entries(val)) {
      if (!row || typeof row !== "object") continue;
      const rowStatus = "yellow";
      if (!rowPassesFilter(rowStatus, statusFilter)) continue;
      rows.push(
        buildRow({
          rowId: `support_${id}`,
          status: rowStatus,
          reason: String(row.subject ?? row.category ?? "open_ticket"),
          actionNeeded: "Respond to support ticket",
          recommendedAction: "Open support inbox",
          entityType: "support_ticket",
          entityId: id,
          secondaryId: normUid(row.user_id ?? row.rider_id ?? row.driver_id),
          fields: {
            ticket_id: id,
            subject: row.subject ?? null,
            priority: row.priority ?? null,
            created_at_ms: Number(row.created_at ?? 0) || null,
          },
          actions: ["open_support"],
        }),
      );
    }
  } catch (e) {
    logger.warn("drilldownSupport failed", { err: String(e?.message || e) });
  }
  return rows;
}

async function drilldownPayoutDestinations(db, { limit, statusFilter }) {
  const wd = await scanWithdrawals(db);
  const rows = [];
  for (const s of wd.payout_warning_samples || []) {
    if (rows.length >= limit) break;
    const rowStatus = "red";
    if (!rowPassesFilter(rowStatus, statusFilter)) continue;
    rows.push(
      buildRow({
        rowId: `payout_${s.type}_${s.withdrawal_id}`,
        status: rowStatus,
        reason: s.type,
        actionNeeded: "Add payout destination before approval",
        recommendedAction: "Contact driver/merchant to update bank details",
        entityType: s.type?.includes("merchant") ? "merchant" : "driver",
        entityId: s.merchant_id ?? s.driver_id ?? null,
        secondaryId: s.withdrawal_id ?? null,
        fields: { ...s },
        actions: ["open_withdrawals"],
      }),
    );
  }
  return rows;
}

async function drilldownInfrastructure(data, { statusFilter }) {
  const rows = [];
  const subsystems = data?.subsystems;
  if (!subsystems || typeof subsystems !== "object") return rows;
  for (const [key, row] of Object.entries(subsystems)) {
    const r = row && typeof row === "object" ? row : {};
    const st = String(r.status ?? "ok");
    const rowStatus = st === "ok" ? "green" : st === "degraded" ? "yellow" : "red";
    if (!rowPassesFilter(rowStatus, statusFilter)) continue;
    rows.push(
      buildRow({
        rowId: `infra_${key}`,
        status: rowStatus,
        reason: r.failure_reason ?? st,
        actionNeeded: rowStatus === "green" ? "None" : "Investigate subsystem connectivity",
        recommendedAction: "Check Firebase console / retry probe",
        entityType: "infrastructure",
        entityId: key,
        fields: {
          subsystem: key,
          reachable: r.reachable === true,
          latency_ms: r.latency_ms ?? null,
          failure_reason: r.failure_reason ?? null,
          retryable: r.retryable === true,
        },
        actions: [],
      }),
    );
  }
  return rows;
}

async function drilldownActiveRides(db, { limit, statusFilter }) {
  const rows = [];
  const ACTIVE_TRIP_STATES = new Set([
    "driver_assigned",
    "driver_accepted",
    "driver_arriving",
    "arrived",
    "in_progress",
    "on_trip",
    "accepted",
    "assigned",
    "arriving",
    "arrived_pickup",
  ]);

  try {
    const atSnap = await db.ref("active_trips").limitToFirst(Math.min(limit * 2, 80)).get();
    const atVal = atSnap.val() && typeof atSnap.val() === "object" ? atSnap.val() : {};
    const rideIds = Object.keys(atVal).slice(0, limit);

    for (const rideId of rideIds) {
      const rSnap = await db.ref(`ride_requests/${rideId}`).get();
      if (!rSnap.exists()) {
        continue;
      }
      const ride = rSnap.val() || {};
      const driverId = canonicalAssignedDriverId(ride);
      const tripState = String(ride.trip_state ?? "").trim().toLowerCase();
      const status = String(ride.status ?? "").trim().toLowerCase();
      const isActive =
        ACTIVE_TRIP_STATES.has(tripState) ||
        ACTIVE_TRIP_STATES.has(status) ||
        (Boolean(driverId) && tripState !== "searching" && status !== "cancelled");
      const rowStatus = isActive ? "green" : "yellow";
      if (!rowPassesFilter(rowStatus, statusFilter)) {
        continue;
      }

      let chatCount = 0;
      let latestChatMs = 0;
      try {
        const chatSnap = await db.ref(`ride_chats/${rideId}/messages`).limitToLast(50).get();
        const chatVal =
          chatSnap.val() && typeof chatSnap.val() === "object" ? chatSnap.val() : {};
        chatCount = Object.keys(chatVal).length;
        for (const msg of Object.values(chatVal)) {
          const ms = Number(msg?.created_at_ms ?? msg?.created_at ?? 0) || 0;
          if (ms > latestChatMs) {
            latestChatMs = ms;
          }
        }
      } catch (_) {
        /* optional */
      }

      let reportCount = 0;
      try {
        const reportsSnap = await db
          .ref("support_reports/trips")
          .orderByChild("tripId")
          .equalTo(rideId)
          .limitToFirst(20)
          .get();
        const repVal =
          reportsSnap.val() && typeof reportsSnap.val() === "object"
            ? reportsSnap.val()
            : {};
        reportCount = Object.keys(repVal).length;
      } catch (_) {
        /* optional */
      }

      const darSnap = driverId
        ? await db.ref(`driver_active_ride/${driverId}`).get()
        : { exists: () => false };

      const pickup =
        ride.pickup_address ??
        (ride.pickup && typeof ride.pickup === "object"
          ? ride.pickup.address ?? ride.pickup.label
          : ride.pickup) ??
        null;
      const dropoff =
        ride.dropoff_address ??
        ride.destination_address ??
        (ride.dropoff && typeof ride.dropoff === "object"
          ? ride.dropoff.address ?? ride.dropoff.label
          : ride.dropoff) ??
        ride.destination ??
        null;

      rows.push(
        buildRow({
          rowId: `active_ride_${rideId}`,
          status: rowStatus,
          reason: `${tripState || status || "active"} · payment ${ride.payment_status ?? "—"}`,
          actionNeeded: "Monitor live trip",
          recommendedAction: "Open trip detail and in-trip chat",
          entityType: "ride",
          entityId: rideId,
          secondaryId: driverId || normUid(ride.rider_id),
          fields: {
            ride_id: rideId,
            rider_id: normUid(ride.rider_id),
            driver_id: driverId || null,
            trip_state: ride.trip_state ?? null,
            status: ride.status ?? null,
            payment_status: ride.payment_status ?? null,
            payment_method: ride.payment_method ?? null,
            pickup,
            dropoff,
            chat_message_count: chatCount,
            latest_chat_timestamp_ms: latestChatMs || null,
            report_count: reportCount,
            active_trip_exists: true,
            driver_active_ride_exists: darSnap.exists(),
          },
          actions: [
            "open_trip",
            "open_rider_profile",
            ...(driverId ? ["open_driver_profile"] : []),
            "open_support",
          ],
        }),
      );
      if (rows.length >= limit) {
        break;
      }
    }
  } catch (e) {
    logger.warn("drilldownActiveRides failed", { err: String(e?.message || e) });
  }
  return rows;
}

async function drilldownActiveDeliveries(db, { limit, statusFilter }) {
  const rows = [];
  try {
    const atSnap = await db.ref("active_deliveries").limitToFirst(Math.min(limit * 2, 80)).get();
    const atVal = atSnap.val() && typeof atSnap.val() === "object" ? atSnap.val() : {};
    for (const deliveryId of Object.keys(atVal).slice(0, limit)) {
      const rSnap = await db.ref(`delivery_requests/${deliveryId}`).get();
      if (!rSnap.exists()) continue;
      const row = rSnap.val() || {};
      const driverId = canonicalAssignedDeliveryDriverId(row);
      const ds = normalizeDeliveryState(row.delivery_state);
      const rowStatus = ds === "cancelled" ? "red" : ds === "completed" ? "green" : "yellow";
      if (!rowPassesFilter(rowStatus, statusFilter)) continue;
      let chatCount = 0;
      let reportCount = 0;
      try {
        const chatSnap = await db.ref(`delivery_chats/${deliveryId}/messages`).limitToLast(30).get();
        const chatVal =
          chatSnap.val() && typeof chatSnap.val() === "object" ? chatSnap.val() : {};
        chatCount = Object.keys(chatVal).length;
      } catch (_) {}
      try {
        const repSnap = await db.ref(`support_reports/deliveries/${deliveryId}`).get();
        const repVal = repSnap.val() && typeof repSnap.val() === "object" ? repSnap.val() : {};
        reportCount = Object.keys(repVal).length;
      } catch (_) {}
      rows.push(
        buildRow({
          rowId: `active_delivery_${deliveryId}`,
          status: rowStatus,
          reason: `${ds} · payment ${row.payment_status ?? "—"}`,
          actionNeeded: "Monitor delivery",
          recommendedAction: "Open delivery detail and chat",
          entityType: "delivery",
          entityId: deliveryId,
          secondaryId: driverId || normUid(row.customer_id),
          fields: {
            delivery_id: deliveryId,
            customer_id: normUid(row.customer_id),
            driver_id: driverId || null,
            merchant_id: normUid(row.merchant_id ?? row.merchantId) || null,
            delivery_state: ds,
            payment_status: row.payment_status ?? null,
            chat_message_count: chatCount,
            report_count: reportCount,
            active_delivery_exists: true,
          },
          actions: [
            "open_trip",
            "open_delivery_chat",
            "open_rider_profile",
            ...(driverId ? ["open_driver_profile"] : []),
            "open_support",
          ],
        }),
      );
    }
  } catch (e) {
    logger.warn("drilldownActiveDeliveries failed", { err: String(e?.message || e) });
  }
  return rows;
}

async function adminGetHealthDrilldown(data, context, db) {
  const name = "adminGetHealthDrilldown";
  const deny = await requireAdmin(db, context, name);
  if (deny) return deny;

  const card = String(data?.card ?? "").trim().toLowerCase();
  if (!DRILLDOWN_CARDS.has(card)) {
    return { success: false, reason: "invalid_card", allowed_cards: [...DRILLDOWN_CARDS] };
  }
  const limit =
    String(data?.card ?? "").trim().toLowerCase() === "matching"
      ? Math.min(
          MATCHING_DRILLDOWN_DEFAULT_LIMIT,
          Math.max(1, Number(data?.limit ?? MATCHING_DRILLDOWN_DEFAULT_LIMIT) || MATCHING_DRILLDOWN_DEFAULT_LIMIT),
        )
      : clampLimit(data?.limit);
  const statusFilter = normStatusFilter(data?.status_filter ?? data?.statusFilter);
  const asOfMs = nowMs();
  const offset = Math.max(0, Number(data?.offset ?? 0) || 0);

  let rows = [];
  let drilldownMeta = {};
  try {
    switch (card) {
      case "rider_payments":
        rows = await drilldownRiderPayments(db, { limit, statusFilter, asOfMs });
        break;
      case "rides":
        rows = await drilldownActiveRides(db, { limit, statusFilter });
        break;
      case "deliveries":
        rows = await drilldownActiveDeliveries(db, { limit, statusFilter });
        break;
      case "matching": {
        const matchingResult = await drilldownMatching(db, {
          limit,
          statusFilter,
          asOfMs,
          offset,
        });
        rows = matchingResult.rows;
        drilldownMeta = {
          total_scanned: matchingResult.total_scanned,
          rows_returned: matchingResult.rows_returned,
          has_more: matchingResult.has_more,
          next_offset: matchingResult.next_offset,
          candidate_count: matchingResult.candidate_count,
        };
        break;
      }
      case "drivers":
        rows = await drilldownDrivers(db, { limit, statusFilter, asOfMs });
        break;
      case "merchants":
        rows = await drilldownMerchants(db, { limit, statusFilter });
        break;
      case "service_areas":
        rows = await drilldownServiceAreas(db, { limit, statusFilter });
        break;
      case "payment_providers":
        rows = await drilldownPaymentProviders(db, { statusFilter });
        break;
      case "withdrawals":
        rows = await drilldownWithdrawals(db, { limit, statusFilter });
        break;
      case "verifications":
        rows = await drilldownVerifications({ limit, statusFilter });
        break;
      case "support":
        rows = await drilldownSupport(db, { limit, statusFilter });
        break;
      case "payout_destinations":
        rows = await drilldownPayoutDestinations(db, { limit, statusFilter });
        break;
      case "infrastructure":
        rows = await drilldownInfrastructure(data, { statusFilter });
        break;
      default:
        break;
    }
  } catch (e) {
    logger.error("adminGetHealthDrilldown failed", { card, err: String(e?.message || e) });
    return { success: false, reason: "drilldown_failed", message: String(e?.message || e) };
  }

  return {
    success: true,
    card,
    status_filter: statusFilter,
    row_count: rows.length,
    rows,
    ...drilldownMeta,
  };
}

// --- Targeted manual actions ---

async function adminRetryPaymentVerify(data, context, db) {
  const deny = await requireAdmin(db, context, "adminRetryPaymentVerify");
  if (deny) return deny;
  const txRef = String(data?.tx_ref ?? data?.reference ?? "").trim();
  if (!txRef) return { success: false, reason: "invalid_tx_ref" };
  const adminUid = normUid(context.auth?.uid);

  const ptSnap = await db.ref(`payment_transactions/${txRef}`).get();
  if (!ptSnap.exists()) {
    return { success: false, reason: "payment_reference_not_found" };
  }
  const existing = ptSnap.val() || {};
  if (existing.verified === true) {
    await writeAudit(db, {
      type: "admin_retry_payment_verify",
      tx_ref: txRef,
      actor_uid: adminUid,
      result: "already_verified",
    });
    return { success: true, reason: "already_verified", idempotent: true };
  }

  const rideId = String(existing.ride_id ?? "").trim();
  const deliveryId = String(existing.delivery_id ?? "").trim();
  const v = await verifyFlutterwavePaymentStrict({
    transactionId: /^\d+$/.test(txRef) ? txRef : "",
    txRef,
    expect: {
      expectedTxRef: txRef,
      expectedCurrency: String(existing.currency ?? "NGN").trim() || "NGN",
    },
  });

  if (v.ok) {
    const payKey = String(v.flwTransactionId || txRef).trim();
    await paymentFlow.mirrorPaymentRecords(db, {
      payKey,
      txRef,
      rideId: rideId || null,
      deliveryId: deliveryId || null,
      riderId: String(existing.rider_id ?? "").trim() || null,
      verified: true,
      amount: v.amount ?? 0,
      providerStatus: v.providerStatus || "successful",
      payload: v.payload || {},
      webhookEvent: "admin_retry_verify",
    });
  }

  await writeAudit(db, {
    type: "admin_retry_payment_verify",
    tx_ref: txRef,
    ride_id: rideId || null,
    delivery_id: deliveryId || null,
    actor_uid: adminUid,
    verified: v.ok === true,
    provider_status: v.providerStatus ?? null,
    failure_reason: v.ok ? null : v.reason ?? v.message ?? "verify_failed",
  });

  return {
    success: v.ok === true,
    reason: v.ok ? "verified" : v.reason || v.message || "verify_failed",
    provider_status: v.providerStatus ?? null,
  };
}

async function adminExpirePaymentIntent(data, context, db) {
  const deny = await requireAdmin(db, context, "adminExpirePaymentIntent");
  if (deny) return deny;
  const txRef = String(data?.tx_ref ?? data?.reference ?? "").trim();
  if (!txRef) return { success: false, reason: "invalid_tx_ref" };
  const adminUid = normUid(context.auth?.uid);
  const fs = firestore();
  const bankTransferVa = require("./bank_transfer_va");
  const docRef = fs.collection(bankTransferVa.INTENT_COLLECTION).doc(txRef);
  const doc = await docRef.get();
  if (!doc.exists) {
    return { success: false, reason: "intent_not_found" };
  }
  const x = doc.data() || {};
  const curStatus = String(x.status ?? "").trim().toLowerCase();
  if (curStatus === "expired" || curStatus === "verified" || curStatus === "paid") {
    await writeAudit(db, {
      type: "admin_expire_payment_intent",
      tx_ref: txRef,
      actor_uid: adminUid,
      result: "already_terminal",
      status: curStatus,
    });
    return { success: true, reason: "already_terminal", idempotent: true, status: curStatus };
  }

  const now = nowMs();
  await docRef.set(
    {
      status: "expired",
      settlement_state: "admin_expired",
      expired_at_ms: now,
      admin_expired_by: adminUid,
      updated_at: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true },
  );

  const rideId = normUid(x.ride_id);
  if (rideId) {
    const rideSnap = await db.ref(`ride_requests/${rideId}`).get();
    const ride = rideSnap.val();
    const pref = String(ride?.payment_reference ?? "").trim();
    if (
      ride &&
      pref === txRef &&
      String(ride.payment_status ?? "").trim().toLowerCase() === "pending_transfer"
    ) {
      const { releaseOpenRideForBankTransferFailure } = require("./ride_callables");
      await releaseOpenRideForBankTransferFailure(db, rideId, {
        cancelReason: "admin_expired_va",
        paymentStatus: "bank_transfer_expired",
      });
    }
  }

  await writeAudit(db, {
    type: "admin_expire_payment_intent",
    tx_ref: txRef,
    ride_id: rideId || null,
    actor_uid: adminUid,
    result: "expired",
  });
  return { success: true, reason: "expired" };
}

async function adminRerunRideMatching(data, context, db) {
  const deny = await requireAdmin(db, context, "adminRerunRideMatching");
  if (deny) return deny;
  const rideId = normUid(data?.rideId ?? data?.ride_id);
  if (!rideId) return { success: false, reason: "invalid_ride_id" };
  const adminUid = normUid(context.auth?.uid);
  const snap = await db.ref(`ride_requests/${rideId}`).get();
  const ride = snap.val();
  if (!ride || typeof ride !== "object") {
    return { success: false, reason: "ride_not_found" };
  }
  const { orchestrateFanoutRerun } = require("./dispatch_engine/dispatch_orchestrator");
  const orch = await orchestrateFanoutRerun(db, rideId, ride, {
    source: "admin_rerun_matching",
  });
  const mdSnap = await db.ref(`ride_requests/${rideId}/match_debug`).get();
  const md = mdSnap.val() || {};
  await writeAudit(db, {
    type: "admin_rerun_ride_matching",
    ride_id: rideId,
    actor_uid: adminUid,
    offers_written: md.offers_written ?? null,
    dispatch_generation: orch?.generation ?? null,
  });
  return {
    success: orch?.ok !== false,
    reason: orch?.reason ?? "fanout_complete",
    offers_written: Number(md.offers_written ?? 0) || 0,
    eligible_driver_count: Number(md.eligible_driver_count ?? 0) || 0,
    no_eligible_reason: md.no_eligible_reason ?? null,
  };
}

async function adminCancelStaleRideSearch(data, context, db) {
  const deny = await requireAdmin(db, context, "adminCancelStaleRideSearch");
  if (deny) return deny;
  const rideId = normUid(data?.rideId ?? data?.ride_id);
  if (!rideId) return { success: false, reason: "invalid_ride_id" };
  const snap = await db.ref(`ride_requests/${rideId}`).get();
  const ride = snap.val();
  if (!ride || typeof ride !== "object") {
    return { success: false, reason: "ride_not_found" };
  }
  if (!isOpenMatchingTripRow(ride)) {
    return { success: false, reason: "not_open_search" };
  }
  const anchor = Math.max(
    Number(ride.created_at ?? 0) || 0,
    Number(ride.updated_at ?? 0) || 0,
  );
  if (anchor > 0 && nowMs() - anchor < STALE_RIDE_SEARCH_MS) {
    return { success: false, reason: "not_stale_yet", min_age_ms: STALE_RIDE_SEARCH_MS };
  }
  const res = await cancelRideRequest(
    { rideId, cancel_reason: "admin_stale_search_cancelled" },
    context,
    db,
  );
  return res;
}

function rideStillBlocksOffers(ride, driverId) {
  if (!ride || typeof ride !== "object") {
    return false;
  }
  const assigned = canonicalAssignedDriverId(ride);
  if (!assigned || assigned !== driverId) {
    return false;
  }
  const ts = String(ride.trip_state ?? ride.status ?? "").toLowerCase();
  const terminal = new Set([
    "completed",
    "cancelled",
    "canceled",
    "expired",
    "trip_completed",
    "trip_cancelled",
  ]);
  if (terminal.has(ts)) {
    return false;
  }
  if (ts === "searching" || ts === "requested" || ts === "searching_driver") {
    return false;
  }
  return true;
}

function deliveryStillBlocksOffers(row, driverId) {
  if (!row || typeof row !== "object") {
    return false;
  }
  const assigned = canonicalAssignedDeliveryDriverId(row);
  if (!assigned || assigned !== driverId) {
    return false;
  }
  const ds = normalizeDeliveryState(row.delivery_state);
  if (ds === "searching" || ds === "completed" || ds === "cancelled") {
    return false;
  }
  return true;
}

async function adminForceClearDriverActivePointers(data, context, db) {
  const deny = await requireAdmin(db, context, "adminForceClearDriverActivePointers");
  if (deny) return deny;
  const driverId = normUid(data?.driverId ?? data?.driver_id);
  if (!driverId) return { success: false, reason: "invalid_driver_id" };
  const {
    adminForceClearDriverActivePointers: forceClear,
  } = require("./driver_active_pointer_guard");
  const adminUid = normUid(context.auth?.uid);
  const result = await forceClear(db, driverId, adminUid);
  await writeAudit(db, {
    type: "admin_force_clear_driver_active_pointers",
    driver_id: driverId,
    before: result.before,
    cleared_trip_ids: result.cleared_trip_ids ?? [],
    actor_uid: adminUid,
  });
  return result;
}

async function adminClearDriverStaleActiveRide(data, context, db) {
  const deny = await requireAdmin(db, context, "adminClearDriverStaleActiveRide");
  if (deny) return deny;
  const driverId = normUid(data?.driverId ?? data?.driver_id);
  if (!driverId) return { success: false, reason: "invalid_driver_id" };
  const adminUid = normUid(context.auth?.uid);
  const darSnap = await db.ref(`driver_active_ride/${driverId}`).get();
  const dadSnap = await db.ref(`driver_active_delivery/${driverId}`).get();
  const driverSnap = await db.ref(`drivers/${driverId}`).get();
  const driverRow = driverSnap.val() && typeof driverSnap.val() === "object" ? driverSnap.val() : {};
  const candidateIds = new Set();
  const dar = darSnap.val() || {};
  const dad = dadSnap.val() || {};
  const rideId = normUid(dar.ride_id ?? dar.rideId);
  const deliveryId = normUid(dad.delivery_id ?? dad.deliveryId);
  if (rideId) candidateIds.add(rideId);
  if (deliveryId) candidateIds.add(deliveryId);
  for (const key of ["activeRideId", "currentRideId", "active_ride_id", "active_delivery_id"]) {
    const id = normUid(driverRow[key]);
    if (id) candidateIds.add(id);
  }
  if (!darSnap.exists() && !dadSnap.exists() && candidateIds.size === 0) {
    return { success: true, reason: "already_clear", idempotent: true };
  }
  for (const tripId of candidateIds) {
    const rideSnap = await db.ref(`ride_requests/${tripId}`).get();
    if (rideSnap.exists() && rideStillBlocksOffers(rideSnap.val(), driverId)) {
      return { success: false, reason: "ride_still_active", ride_id: tripId };
    }
    const delSnap = await db.ref(`delivery_requests/${tripId}`).get();
    if (delSnap.exists() && deliveryStillBlocksOffers(delSnap.val(), driverId)) {
      return { success: false, reason: "delivery_still_active", delivery_id: tripId };
    }
  }
  const updates = {
    [`driver_active_ride/${driverId}`]: null,
    [`driver_active_delivery/${driverId}`]: null,
    [`drivers/${driverId}/activeRideId`]: null,
    [`drivers/${driverId}/currentRideId`]: null,
    [`drivers/${driverId}/active_ride_id`]: null,
    [`drivers/${driverId}/active_delivery_id`]: null,
    [`drivers/${driverId}/updated_at`]: Date.now(),
  };
  await db.ref().update(updates);
  await writeAudit(db, {
    type: "admin_clear_driver_stale_active_ride",
    driver_id: driverId,
    ride_id: rideId || null,
    delivery_id: deliveryId || null,
    cleared_trip_ids: [...candidateIds],
    actor_uid: adminUid,
  });
  return {
    success: true,
    reason: "cleared",
    driver_id: driverId,
    ride_id: rideId || null,
    delivery_id: deliveryId || null,
  };
}

async function adminRerunDeliveryMatching(data, context, db) {
  const deny = await requireAdmin(db, context, "adminRerunDeliveryMatching");
  if (deny) return deny;
  const deliveryId = normUid(data?.deliveryId ?? data?.delivery_id);
  if (!deliveryId) return { success: false, reason: "invalid_delivery_id" };
  const adminUid = normUid(context.auth?.uid);
  const snap = await db.ref(`delivery_requests/${deliveryId}`).get();
  const row = snap.val();
  if (!row || typeof row !== "object") {
    return { success: false, reason: "delivery_not_found" };
  }
  await fanOutDeliveryOffersIfEligible(db, deliveryId, row);
  await writeAudit(db, {
    type: "admin_rerun_delivery_matching",
    delivery_id: deliveryId,
    actor_uid: adminUid,
  });
  return { success: true, reason: "fanout_complete", delivery_id: deliveryId };
}

module.exports = {
  adminGetHealthDrilldown,
  adminRetryPaymentVerify,
  adminExpirePaymentIntent,
  adminRerunRideMatching,
  adminCancelStaleRideSearch,
  adminClearDriverStaleActiveRide,
  adminForceClearDriverActivePointers,
  adminRerunDeliveryMatching,
  DRILLDOWN_CARDS,
};
