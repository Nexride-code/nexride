/**
 * Admin-only production health snapshot for store-readiness monitoring.
 * Rider payment diagnostics count only recent/actionable rows (stale/historical excluded).
 */

const admin = require("firebase-admin");
const { getAuth } = require("firebase-admin/auth");
const { getStorage } = require("firebase-admin/storage");
const { logger } = require("firebase-functions");
const { normUid } = require("./admin_auth");
const adminPerms = require("./admin_permissions");
const liveOps = require("./live_operations_dashboard_callable");
const { normalizeServiceAreaRow } = require("./ecosystem/delivery_regions");
const { loadNexrideOfficialBankAccountFromRtdb } = require("./nexride_official_bank_config");

const firestore = () => admin.firestore();

const DRIVERS_SCAN_CAP = 800;
const MERCHANTS_SCAN_CAP = 200;
const WITHDRAWALS_CAP = 200;
const STALE_DRIVER_HEARTBEAT_MS = 180_000;
const STALE_MERCHANT_PORTAL_MS = 600_000;
const PORTAL_ONLINE_MS = 120_000;
const SAMPLE_LIMIT = 12;

/**
 * Rider payment counts are diagnostics-only: exclude historical/stale rows so admin health
 * reflects live operational risk (not legacy wallet-era noise).
 */
const RIDER_PAYMENT_ACTIONABLE_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000; // failed / unpaid
const RIDER_PAYMENT_CARD_INTENT_MAX_AGE_MS = 24 * 60 * 60 * 1000; // abandoned checkouts
const RIDER_PAYMENT_BANK_REVIEW_MAX_AGE_MS = 14 * 24 * 60 * 60 * 1000; // manual bank confirmation

/** Terminal / settled payment_status values — never count as open rider-payment issues. */
const TERMINAL_RIDER_PAYMENT_STATUSES = new Set([
  "completed",
  "cancelled",
  "canceled",
  "expired",
  "refunded",
  "verified",
  "paid",
  "prepaid",
]);

async function requireAdmin(db, ctx, name) {
  const err = await adminPerms.enforceCallable(db, ctx, name);
  if (err) {
    logger.warn(`${name}_rbac_denied`, { uid: normUid(ctx?.auth?.uid), ...err });
  }
  return err;
}

function nowMs() {
  return Date.now();
}

function takeSample(arr, n = SAMPLE_LIMIT) {
  if (!Array.isArray(arr)) return [];
  return arr.slice(0, n);
}

function withdrawalHasDestination(row) {
  if (!row || typeof row !== "object") return false;
  const snap = row.withdrawal_destination_snapshot;
  const wa = row.withdrawalAccount ?? row.destination;
  const bankFromSnap =
    snap && typeof snap === "object" ? String(snap.bank_name ?? "").trim() : "";
  const acctFromSnap =
    snap && typeof snap === "object" ? String(snap.account_number ?? "").trim() : "";
  const holderFromSnap =
    snap && typeof snap === "object" ? String(snap.account_holder_name ?? "").trim() : "";
  const bankFromWa =
    wa && typeof wa === "object" ? String(wa.bankName ?? wa.bank_name ?? "").trim() : "";
  const acctFromWa =
    wa && typeof wa === "object"
      ? String(wa.accountNumber ?? wa.account_number ?? "").replace(/\D/g, "")
      : "";
  const holderFromWa =
    wa && typeof wa === "object"
      ? String(
          wa.accountName ?? wa.account_holder_name ?? wa.account_name ?? wa.holderName ?? "",
        ).trim()
      : "";
  const bank_name = bankFromSnap || bankFromWa;
  const account_number = acctFromSnap || acctFromWa;
  const account_holder_name = holderFromSnap || holderFromWa;
  return !!(bank_name && account_number && account_holder_name);
}

function entityTypeOf(row) {
  return String(row?.entity_type ?? row?.entityType ?? "driver").trim().toLowerCase();
}

function statusLevel(count, yellowAt, redAt) {
  if (count >= redAt) return "red";
  if (count >= yellowAt) return "yellow";
  return "green";
}

function worstStatus(...levels) {
  const order = { green: 0, yellow: 1, red: 2 };
  let w = "green";
  for (const l of levels) {
    if ((order[l] ?? 0) > (order[w] ?? 0)) w = l;
  }
  return w;
}

function isRetryableProbeError(message) {
  return /timeout|timed out|unavailable|deadline|econnreset|503|429|resource-exhausted|network/i.test(
    String(message || ""),
  );
}

/**
 * Standard subsystem probe envelope for admin health UI.
 */
async function runSubsystemProbe(name, fn) {
  const t0 = nowMs();
  try {
    await fn();
    return {
      subsystem: name,
      status: "ok",
      reachable: true,
      latency_ms: nowMs() - t0,
      failure_reason: null,
      retryable: false,
    };
  } catch (e) {
    const failure_reason = String(e?.message || e).slice(0, 500);
    const retryable = isRetryableProbeError(failure_reason);
    return {
      subsystem: name,
      status: retryable ? "degraded" : "critical",
      reachable: false,
      latency_ms: nowMs() - t0,
      failure_reason,
      retryable,
    };
  }
}

async function probeRtdb(db) {
  return runSubsystemProbe("rtdb", async () => {
    const snap = await db.ref("app_config").limitToFirst(1).get();
    if (snap && typeof snap.exists === "function" && !snap.exists()) {
      return;
    }
  });
}

async function probeFirestore() {
  return runSubsystemProbe("firestore", async () => {
    await firestore().collection("merchants").limit(1).get();
  });
}

async function probeAuth() {
  return runSubsystemProbe("auth", async () => {
    await getAuth().listUsers(1);
  });
}

async function probeStorage() {
  return runSubsystemProbe("storage", async () => {
    const bucket = getStorage().bucket();
    await bucket.getMetadata();
  });
}

function probeFunctionsRuntime() {
  return {
    subsystem: "functions",
    status: "ok",
    reachable: true,
    latency_ms: 0,
    failure_reason: null,
    retryable: false,
    note: "Health callable executing on Cloud Functions Gen2",
  };
}

function infrastructureRollup(subsystems) {
  const list = Object.values(subsystems || {});
  const anyCritical = list.some((s) => s.status === "critical");
  const anyDegraded = list.some((s) => s.status === "degraded" || (s.retryable && !s.reachable));
  const allReachable = list.every((s) => s.reachable !== false);
  let status = "ok";
  if (anyCritical) status = "critical";
  else if (anyDegraded || !allReachable) status = "degraded";
  return { status, all_reachable: allReachable, subsystems: subsystems };
}

function classifyServiceAreaRowWarnings(regionId, area) {
  const warnings = [];
  let missing_geo = 0;
  let disabled_active_area = 0;
  let missing_dispatch_market_id = 0;
  const cityEnabled = area.enabled !== false;
  const regionEnabled = area.region_enabled !== false;
  const lat = area.center_lat;
  const lng = area.center_lng;
  const hasGeo =
    lat != null &&
    lng != null &&
    Number.isFinite(Number(lat)) &&
    Number.isFinite(Number(lng));
  const dmId = String(area.dispatch_market_id ?? "").trim();
  if (!hasGeo) {
    missing_geo += 1;
    warnings.push({
      type: "missing_geo",
      region_id: regionId,
      city_id: area.city_id,
      display_name: area.display_name,
    });
  }
  if (!dmId) {
    missing_dispatch_market_id += 1;
    warnings.push({
      type: "missing_dispatch_market_id",
      region_id: regionId,
      city_id: area.city_id,
      display_name: area.display_name,
    });
  }
  if (cityEnabled && regionEnabled && !hasGeo) {
    disabled_active_area += 1;
    warnings.push({
      type: "disabled_active_area",
      region_id: regionId,
      city_id: area.city_id,
      display_name: area.display_name,
      note: "enabled area missing center coordinates",
    });
  }
  return { missing_geo, disabled_active_area, missing_dispatch_market_id, warnings };
}

async function scanOfficialBankAccountWarning(db) {
  try {
    const row = await loadNexrideOfficialBankAccountFromRtdb(db);
    if (row) {
      return { configured: true, source_path: row.source_path || null, warnings: [] };
    }
    return {
      configured: false,
      source_path: null,
      warnings: [
        {
          type: "official_bank_not_configured",
          note: "RTDB app_config/nexride_official_bank_account is missing or incomplete",
        },
      ],
    };
  } catch (e) {
    logger.warn("production_health official bank scan failed", {
      err: String(e?.message || e),
    });
    return {
      configured: false,
      source_path: null,
      warnings: [{ type: "official_bank_scan_failed", note: String(e?.message || e) }],
    };
  }
}

async function scanServiceAreaWarnings(db) {
  const warnings = [];
  let missing_geo = 0;
  let disabled_active_area = 0;
  let missing_dispatch_market_id = 0;
  try {
    const fs = firestore();
    const regionsSnap = await fs.collection("delivery_regions").limit(80).get();
    for (const regDoc of regionsSnap.docs) {
      const regionId = regDoc.id;
      const r = regDoc.data() || {};
      const citiesSnap = await fs
        .collection("delivery_regions")
        .doc(regionId)
        .collection("cities")
        .limit(120)
        .get();
      for (const cityDoc of citiesSnap.docs) {
        const area = normalizeServiceAreaRow(regionId, r, cityDoc.id, cityDoc.data() || {});
        const c = classifyServiceAreaRowWarnings(regionId, area);
        missing_geo += c.missing_geo;
        disabled_active_area += c.disabled_active_area;
        missing_dispatch_market_id += c.missing_dispatch_market_id;
        warnings.push(...c.warnings);
      }
    }
  } catch (e) {
    logger.warn("production_health service_areas scan failed", {
      err: String(e?.message || e),
    });
  }
  return {
    missing_geo,
    disabled_active_area,
    missing_dispatch_market_id,
    warnings: takeSample(warnings, 20),
  };
}

function _normPaymentStatus(row) {
  return String(row?.payment_status ?? row?.paymentStatus ?? "")
    .trim()
    .toLowerCase();
}

function riderPaymentActivityTimeMs(row) {
  if (!row || typeof row !== "object") return 0;
  const candidates = [
    row.updated_at,
    row.updatedAt,
    row.payment_verified_at,
    row.paid_at,
    row.created_at,
    row.createdAt,
  ];
  let max = 0;
  for (const c of candidates) {
    const n = Number(c);
    if (Number.isFinite(n) && n > max) max = n;
  }
  return max;
}

/**
 * Rows without any payment reference/timestamp/method are usually stale pre-schema wallet-era
 * mirrors — ignore for health noise.
 */
function hasObservedPaymentSchema(row) {
  if (!row || typeof row !== "object") return false;
  const refOk =
    String(row.payment_reference ?? row.customer_transaction_reference ?? "").trim().length > 0;
  const txOk =
    String(row.payment_transaction_id ?? row.paymentTransactionId ?? "").trim().length > 0;
  const methodOk =
    String(row.payment_method ?? row.paymentMethod ?? "").trim().length > 0;
  const timeOk = riderPaymentActivityTimeMs(row) > 0;
  return refOk || txOk || methodOk || timeOk;
}

function isPaymentVerificationMismatchSignal(row) {
  if (!row || typeof row !== "object") return false;
  const parts = [
    row.payment_failure_reason,
    row.payment_error,
    row.payment_issue,
    row.verify_error,
    row.last_verify_reason,
    row.payment_notes,
    row.payment_issue_code,
    row.verify_failure_code,
  ]
    .filter((x) => x != null)
    .map((x) => String(x));
  const blob = parts.join(" ").toLowerCase();
  const code = String(row.payment_issue_code ?? row.verify_failure_code ?? "")
    .trim()
    .toLowerCase();
  if (
    code.includes("mismatch") ||
    code.includes("owner") ||
    code.includes("amount") ||
    code.includes("pricing")
  ) {
    return true;
  }
  return (
    /mismatch|pricing_total|wrong amount|payment_owner|payment_context|amount_mismatch/i.test(blob) ===
    true
  );
}

function merchantOrderActivityMs(data) {
  if (!data || typeof data !== "object") return 0;
  const raw = data.updated_at ?? data.created_at;
  if (raw && typeof raw.toMillis === "function") return raw.toMillis() || 0;
  const n = Number(raw);
  return Number.isFinite(n) ? n : 0;
}

async function countRiderPaymentIssues(db) {
  return _countRiderPaymentIssuesImpl(db, nowMs());
}

async function _countRiderPaymentIssuesImpl(db, asOfMs) {
  let failed_card_payments = 0;
  let pending_bank_transfer_confirmations = 0;
  let unpaid_rider_trips_orders = 0;
  let active_payment_intents = 0;
  let payment_verification_mismatches = 0;

  const countRtdbMap = (val, windowMs, bucket) => {
    if (!val || typeof val !== "object") return;
    const cutoff = asOfMs - windowMs;
    for (const row of Object.values(val)) {
      if (!row || typeof row !== "object") continue;
      if (!hasObservedPaymentSchema(row)) continue;
      const ps = _normPaymentStatus(row);
      if (TERMINAL_RIDER_PAYMENT_STATUSES.has(ps)) continue;
      const t = riderPaymentActivityTimeMs(row);
      if (!t || t < cutoff) continue;
      if (bucket === "failed") {
        failed_card_payments += 1;
        if (isPaymentVerificationMismatchSignal(row)) payment_verification_mismatches += 1;
      } else if (bucket === "bank") {
        pending_bank_transfer_confirmations += 1;
      } else if (bucket === "unpaid") {
        unpaid_rider_trips_orders += 1;
      } else if (bucket === "intent") {
        active_payment_intents += 1;
      }
    }
  };

  try {
    const failedSnap = await db
      .ref("ride_requests")
      .orderByChild("payment_status")
      .equalTo("failed")
      .limitToFirst(200)
      .get();
    countRtdbMap(failedSnap.val(), RIDER_PAYMENT_ACTIONABLE_MAX_AGE_MS, "failed");
  } catch (e) {
    logger.warn("production_health failed payments ride_requests", {
      err: String(e?.message || e),
    });
  }

  try {
    const pendingSnap = await db
      .ref("ride_requests")
      .orderByChild("payment_status")
      .equalTo("pending_manual_confirmation")
      .limitToFirst(200)
      .get();
    countRtdbMap(pendingSnap.val(), RIDER_PAYMENT_BANK_REVIEW_MAX_AGE_MS, "bank");
  } catch (e) {
    logger.warn("production_health pending bank ride_requests", {
      err: String(e?.message || e),
    });
  }

  try {
    const pendingVaSnapRide = await db
      .ref("ride_requests")
      .orderByChild("payment_status")
      .equalTo("pending_transfer")
      .limitToFirst(150)
      .get();
    countRtdbMap(pendingVaSnapRide.val(), RIDER_PAYMENT_BANK_REVIEW_MAX_AGE_MS, "bank");
  } catch (e) {
    logger.warn("production_health pending_transfer ride_requests", {
      err: String(e?.message || e),
    });
  }

  try {
    const unpaidSnap = await db
      .ref("ride_requests")
      .orderByChild("payment_status")
      .equalTo("unpaid")
      .limitToFirst(200)
      .get();
    countRtdbMap(unpaidSnap.val(), RIDER_PAYMENT_ACTIONABLE_MAX_AGE_MS, "unpaid");
  } catch (e) {
    logger.warn("production_health unpaid ride_requests", {
      err: String(e?.message || e),
    });
  }

  try {
    const intentSnap = await db
      .ref("ride_requests")
      .orderByChild("payment_status")
      .equalTo("pending")
      .limitToFirst(150)
      .get();
    countRtdbMap(intentSnap.val(), RIDER_PAYMENT_CARD_INTENT_MAX_AGE_MS, "intent");
  } catch (e) {
    logger.warn("production_health pending card intents ride_requests", {
      err: String(e?.message || e),
    });
  }

  try {
    const delFailed = await db
      .ref("delivery_requests")
      .orderByChild("payment_status")
      .equalTo("failed")
      .limitToFirst(100)
      .get();
    countRtdbMap(delFailed.val(), RIDER_PAYMENT_ACTIONABLE_MAX_AGE_MS, "failed");
  } catch (_) {}

  try {
    const delPending = await db
      .ref("delivery_requests")
      .orderByChild("payment_status")
      .equalTo("pending_manual_confirmation")
      .limitToFirst(100)
      .get();
    countRtdbMap(delPending.val(), RIDER_PAYMENT_BANK_REVIEW_MAX_AGE_MS, "bank");
  } catch (_) {}

  try {
    const delPendingVaSnap = await db
      .ref("delivery_requests")
      .orderByChild("payment_status")
      .equalTo("pending_transfer")
      .limitToFirst(100)
      .get();
    countRtdbMap(delPendingVaSnap.val(), RIDER_PAYMENT_BANK_REVIEW_MAX_AGE_MS, "bank");
  } catch (_) {}

  try {
    const delUnpaid = await db
      .ref("delivery_requests")
      .orderByChild("payment_status")
      .equalTo("unpaid")
      .limitToFirst(100)
      .get();
    countRtdbMap(delUnpaid.val(), RIDER_PAYMENT_ACTIONABLE_MAX_AGE_MS, "unpaid");
  } catch (_) {}

  try {
    const delIntent = await db
      .ref("delivery_requests")
      .orderByChild("payment_status")
      .equalTo("pending")
      .limitToFirst(100)
      .get();
    countRtdbMap(delIntent.val(), RIDER_PAYMENT_CARD_INTENT_MAX_AGE_MS, "intent");
  } catch (_) {}

  try {
    const moSnap = await firestore()
      .collection("merchant_orders")
      .where("payment_status", "in", ["failed", "unpaid", "pending_bank_transfer"])
      .limit(200)
      .get()
      .catch(() => null);
    if (moSnap) {
      const failCut = asOfMs - RIDER_PAYMENT_ACTIONABLE_MAX_AGE_MS;
      const bankCut = asOfMs - RIDER_PAYMENT_BANK_REVIEW_MAX_AGE_MS;
      for (const doc of moSnap.docs) {
        const data = doc.data() || {};
        const ps = String(data.payment_status ?? "")
          .trim()
          .toLowerCase();
        if (!ps) continue;
        if (TERMINAL_RIDER_PAYMENT_STATUSES.has(ps)) continue;
        const t = merchantOrderActivityMs(data);
        if (ps === "failed") {
          if (!t || t < failCut) continue;
          failed_card_payments += 1;
          if (isPaymentVerificationMismatchSignal(data)) payment_verification_mismatches += 1;
        } else if (ps === "pending_bank_transfer") {
          if (!t || t < bankCut) continue;
          pending_bank_transfer_confirmations += 1;
        } else if (ps === "unpaid") {
          if (!t || t < failCut) continue;
          unpaid_rider_trips_orders += 1;
        }
      }
    }
  } catch (e) {
    logger.warn("production_health merchant_orders scan failed", { err: String(e?.message || e) });
  }

  const total =
    failed_card_payments +
    pending_bank_transfer_confirmations +
    unpaid_rider_trips_orders +
    active_payment_intents;

  return {
    failed_card_payments,
    pending_bank_transfer_confirmations,
    unpaid_rider_trips_orders,
    active_payment_intents,
    payment_verification_mismatches,
    total,
    actionable_window_failed_unpaid_ms: RIDER_PAYMENT_ACTIONABLE_MAX_AGE_MS,
    actionable_window_bank_review_ms: RIDER_PAYMENT_BANK_REVIEW_MAX_AGE_MS,
    actionable_window_card_intent_ms: RIDER_PAYMENT_CARD_INTENT_MAX_AGE_MS,
  };
}

async function scanWithdrawals(db) {
  let pending_driver = 0;
  let pending_merchant = 0;
  let driver_missing_destination = 0;
  let merchant_missing_destination = 0;
  const payout_samples = [];

  try {
    const wdSnap = await db
      .ref("withdraw_requests")
      .orderByChild("status")
      .equalTo("pending")
      .limitToFirst(WITHDRAWALS_CAP)
      .get();
    const wdVal = wdSnap.val() && typeof wdSnap.val() === "object" ? wdSnap.val() : {};
    for (const [id, row] of Object.entries(wdVal)) {
      if (!row || typeof row !== "object") continue;
      const et = entityTypeOf(row);
      const isMerchant = et === "merchant";
      if (isMerchant) pending_merchant += 1;
      else pending_driver += 1;
      const hasDest = withdrawalHasDestination(row);
      if (!hasDest) {
        if (isMerchant) {
          merchant_missing_destination += 1;
          if (payout_samples.length < SAMPLE_LIMIT) {
            payout_samples.push({
              type: "merchant_withdrawal_missing_destination",
              withdrawal_id: id,
              merchant_id: normUid(row.merchantId ?? row.merchant_id) || null,
            });
          }
        } else {
          driver_missing_destination += 1;
          if (payout_samples.length < SAMPLE_LIMIT) {
            payout_samples.push({
              type: "driver_withdrawal_missing_destination",
              withdrawal_id: id,
              driver_id: normUid(row.driverId ?? row.driver_id) || null,
            });
          }
        }
      }
    }
  } catch (e) {
    logger.warn("production_health withdrawals scan failed", {
      err: String(e?.message || e),
    });
  }

  return {
    pending_driver,
    pending_merchant,
    pending_total: pending_driver + pending_merchant,
    driver_missing_destination,
    merchant_missing_destination,
    payout_warning_samples: payout_samples,
  };
}

async function countPendingVerifications() {
  let pending = 0;
  try {
    const snap = await firestore()
      .collection("identity_verifications")
      .where("status", "in", ["pending", "submitted", "under_review"])
      .limit(200)
      .get();
    pending = snap.size;
  } catch (e) {
    try {
      const snap = await firestore().collection("identity_verifications").limit(200).get();
      for (const doc of snap.docs) {
        const st = String(doc.data()?.status ?? "").toLowerCase();
        if (st === "pending" || st === "submitted" || st === "under_review") pending += 1;
      }
    } catch (e2) {
      logger.warn("production_health verifications count failed", {
        err: String(e2?.message || e2),
      });
    }
  }
  return pending;
}

async function adminGetProductionHealthSnapshot(data, context, db) {
  const name = "adminGetProductionHealthSnapshot";
  try {
    const deny = await requireAdmin(db, context, name);
    if (deny) return deny;

    const n = nowMs();
    const includeDebug = data && data.includeDebugMetrics === true;

    let rtdbProbe;
    let firestoreProbe;
    let authProbe;
    let storageProbe;
    let liveDash;
    try {
      [rtdbProbe, firestoreProbe, authProbe, storageProbe, liveDash] = await Promise.all([
        probeRtdb(db),
        probeFirestore(),
        probeAuth(),
        probeStorage(),
        liveOps.adminGetLiveOperationsDashboard({}, context, db).catch((e) => ({
          success: false,
          reason: "live_dashboard_exception",
          message: String(e?.message || e),
        })),
      ]);
    } catch (probeErr) {
      logger.error("production_health probe bundle failed", {
        err: String(probeErr?.message || probeErr),
      });
      rtdbProbe =
        rtdbProbe ||
        ({
          subsystem: "rtdb",
          status: "critical",
          reachable: false,
          latency_ms: 0,
          failure_reason: String(probeErr?.message || probeErr),
          retryable: true,
        });
      firestoreProbe =
        firestoreProbe ||
        ({
          subsystem: "firestore",
          status: "critical",
          reachable: false,
          latency_ms: 0,
          failure_reason: "probe_bundle_failed",
          retryable: true,
        });
      authProbe =
        authProbe ||
        ({
          subsystem: "auth",
          status: "critical",
          reachable: false,
          latency_ms: 0,
          failure_reason: "probe_bundle_failed",
          retryable: true,
        });
      storageProbe =
        storageProbe ||
        ({
          subsystem: "storage",
          status: "critical",
          reachable: false,
          latency_ms: 0,
          failure_reason: "probe_bundle_failed",
          retryable: true,
        });
      liveDash = liveDash || { success: false, reason: "live_dashboard_failed" };
    }

    const functionsProbe = probeFunctionsRuntime();
    const infrastructure = infrastructureRollup({
      rtdb: rtdbProbe,
      firestore: firestoreProbe,
      auth: authProbe,
      storage: storageProbe,
      functions: functionsProbe,
    });

    if (!liveDash || !liveDash.success) {
      return {
        success: false,
        reason: liveDash?.reason || "live_dashboard_failed",
        reason_code: "live_dashboard_failed",
        message:
          liveDash?.message ||
          "Unable to load live operations metrics for health snapshot.",
        retryable: true,
        infrastructure,
      };
    }

  const [
    serviceAreas,
    officialBank,
    riderPayments,
    withdrawals,
    pendingVerifications,
    activeTripsSnap,
    activeDelSnap,
  ] = await Promise.all([
    scanServiceAreaWarnings(db),
    scanOfficialBankAccountWarning(db),
    countRiderPaymentIssues(db),
    scanWithdrawals(db),
    countPendingVerifications(),
    db.ref("active_trips").get(),
    db.ref("active_deliveries").get(),
  ]);

  const activeTrips =
    activeTripsSnap.val() && typeof activeTripsSnap.val() === "object"
      ? Object.keys(activeTripsSnap.val()).length
      : 0;
  const activeDeliveries =
    activeDelSnap.val() && typeof activeDelSnap.val() === "object"
      ? Object.keys(activeDelSnap.val()).length
      : 0;

  let support_open = 0;
  try {
    const tSnap = await db
      .ref("support_tickets")
      .orderByChild("status")
      .equalTo("open")
      .limitToFirst(200)
      .get();
    const tVal = tSnap.val() && typeof tSnap.val() === "object" ? tSnap.val() : {};
    support_open = Object.keys(tVal).length;
  } catch (_) {}

  const drivers = liveDash.drivers || {};
  const merchants = liveDash.merchants || {};
  const rides = liveDash.rides || {};

  let latest_driver_heartbeat_ms = null;
  let latest_driver_heartbeat_id = null;
  const driverSample = Array.isArray(drivers.sample) ? drivers.sample : [];
  for (const d of driverSample) {
    const ts = Math.max(Number(d.updated_at ?? 0) || 0, Number(d.mirror_updated_at ?? 0) || 0);
    if (ts > (latest_driver_heartbeat_ms || 0)) {
      latest_driver_heartbeat_ms = ts;
      latest_driver_heartbeat_id = d.driver_id || null;
    }
  }

  let latest_merchant_portal_ms = null;
  let latest_merchant_portal_id = null;
  let latest_merchant_order_ms = null;
  const merchantSample = Array.isArray(merchants.sample) ? merchants.sample : [];
  for (const m of merchantSample) {
    const pls = Number(m.portal_last_seen_ms ?? 0) || 0;
    if (pls > (latest_merchant_portal_ms || 0)) {
      latest_merchant_portal_ms = pls;
      latest_merchant_portal_id = m.merchant_id || null;
    }
  }
  const mo = liveDash.merchant_orders || {};
  const moSample = Array.isArray(mo.sample) ? mo.sample : [];
  for (const o of moSample) {
    const ts = Number(o.updated_at ?? 0) || 0;
    if (ts > (latest_merchant_order_ms || 0)) latest_merchant_order_ms = ts;
  }

  const infraStatus = infrastructure.status;
  const infraOk = infraStatus === "ok";

  const paymentIssueTotal = riderPayments.total || 0;
  const payoutWarnings =
    withdrawals.driver_missing_destination + withdrawals.merchant_missing_destination;
  const serviceAreaWarningTotal =
    serviceAreas.missing_geo +
    serviceAreas.missing_dispatch_market_id +
    serviceAreas.disabled_active_area;
  const officialBankWarningTotal = officialBank.configured ? 0 : 1;
  const configurationWarningTotal = serviceAreaWarningTotal + officialBankWarningTotal;

  const overall_status = worstStatus(
    infraStatus === "ok" ? "green" : infraStatus === "degraded" ? "yellow" : "red",
    statusLevel(drivers.stale_heartbeat || 0, 3, 15),
    statusLevel(merchants.stale_portal || 0, 2, 8),
    statusLevel(paymentIssueTotal, 1, 10),
    statusLevel(withdrawals.pending_total || 0, 5, 30),
    statusLevel(payoutWarnings, 1, 5),
    statusLevel(support_open, 10, 50),
    statusLevel(configurationWarningTotal, 1, 5),
  );

  const cards = [
    {
      id: "infrastructure",
      title: "Infrastructure",
      status: infraStatus === "ok" ? "green" : infraStatus === "degraded" ? "yellow" : "red",
      summary:
        infraStatus === "ok"
          ? "All backends reachable"
          : infraStatus === "degraded"
            ? "Degraded subsystem(s) — see diagnostics"
            : "Critical subsystem failure — see diagnostics",
    },
    {
      id: "drivers",
      title: "Drivers",
      status: statusLevel(drivers.stale_heartbeat || 0, 3, 15),
      summary: `${drivers.online ?? 0} online / ${drivers.total ?? 0} sampled · ${drivers.stale_heartbeat ?? 0} stale`,
    },
    {
      id: "merchants",
      title: "Merchants",
      status: statusLevel(merchants.stale_portal || 0, 2, 8),
      summary: `${merchants.open ?? 0} open · ${merchants.orders_live ?? 0} orders live`,
    },
    {
      id: "rides",
      title: "Active operations",
      status: statusLevel(rides.active || 0, 50, 200),
      summary: `${rides.active ?? 0} live trips · ${activeTrips} active_trips · ${activeDeliveries} deliveries`,
    },
    {
      id: "rider_payments",
      title: "Rider payments",
      status: statusLevel(paymentIssueTotal, 1, 10),
      summary: `${paymentIssueTotal} actionable issues (recent card/bank/unpaid intents · excludes stale/historical)`,
    },
    {
      id: "withdrawals",
      title: "Withdrawals",
      status: statusLevel(withdrawals.pending_total || 0, 5, 30),
      summary: `${withdrawals.pending_driver} driver · ${withdrawals.pending_merchant} merchant pending`,
    },
    {
      id: "payout_warnings",
      title: "Payout destinations",
      status: statusLevel(payoutWarnings, 1, 5),
      summary: `${payoutWarnings} pending without destination`,
    },
    {
      id: "verifications",
      title: "Verifications",
      status: statusLevel(pendingVerifications, 5, 40),
      summary: `${pendingVerifications} pending review`,
    },
    {
      id: "support",
      title: "Support",
      status: statusLevel(support_open, 10, 50),
      summary: `${support_open} open tickets`,
    },
    {
      id: "service_areas",
      title: "Service areas",
      status: statusLevel(configurationWarningTotal, 1, 5),
      summary: `${configurationWarningTotal} configuration warnings (areas + official bank)`,
    },
  ];

  const snapshot = {
    generated_at: n,
    overall_status,
    infrastructure,
    active_operations: {
      rides_deliveries_live: rides.active ?? 0,
      active_trips_rtdb: activeTrips,
      active_deliveries_rtdb: activeDeliveries,
    },
    drivers: {
      total: drivers.total ?? 0,
      online: drivers.online ?? 0,
      stale_heartbeat: drivers.stale_heartbeat ?? 0,
      latest_heartbeat_ms: latest_driver_heartbeat_ms,
      latest_heartbeat_driver_id: latest_driver_heartbeat_id,
      stale_threshold_ms: STALE_DRIVER_HEARTBEAT_MS,
    },
    merchants: {
      total: merchants.total ?? 0,
      open: merchants.open ?? 0,
      closed: merchants.closed ?? 0,
      orders_live: merchants.orders_live ?? 0,
      portal_online: merchants.portal_online ?? 0,
      stale_portal: merchants.stale_portal ?? 0,
      latest_portal_last_seen_ms: latest_merchant_portal_ms,
      latest_portal_merchant_id: latest_merchant_portal_id,
      latest_order_updated_ms: latest_merchant_order_ms,
      stale_portal_threshold_ms: STALE_MERCHANT_PORTAL_MS,
      portal_online_threshold_ms: PORTAL_ONLINE_MS,
    },
    withdrawals,
    verifications: { pending: pendingVerifications },
    support: { open: support_open },
    rider_payment_issues: riderPayments,
    service_area_warnings: serviceAreas,
    official_bank: officialBank,
    payout_warnings: {
      driver_withdrawal_missing_destination: withdrawals.driver_missing_destination,
      merchant_withdrawal_missing_destination: withdrawals.merchant_missing_destination,
      samples: withdrawals.payout_warning_samples,
    },
    cards,
    ...(includeDebug
      ? {
          debug: {
            live_ops_now_ms: liveDash.now_ms,
            drivers_scan_capped: (drivers.total ?? 0) >= DRIVERS_SCAN_CAP,
            merchants_scan_capped: (merchants.total ?? 0) >= MERCHANTS_SCAN_CAP,
          },
        }
      : {}),
  };

    return { success: true, snapshot };
  } catch (fatalErr) {
    logger.error("adminGetProductionHealthSnapshot fatal", {
      err: String(fatalErr?.message || fatalErr),
    });
    return {
      success: false,
      reason: "internal_error",
      reason_code: "health_snapshot_internal_error",
      message: "System health snapshot failed internally.",
      retryable: true,
    };
  }
}

module.exports = {
  runSubsystemProbe,
  infrastructureRollup,
  adminGetProductionHealthSnapshot,
  withdrawalHasDestination,
  entityTypeOf,
  classifyServiceAreaRowWarnings,
  scanServiceAreaWarnings,
  scanOfficialBankAccountWarning,
  countRiderPaymentIssues,
  /** @internal Tests: deterministic `asOf` for rider payment windows. */
  _countRiderPaymentIssuesAt: (db, asOfMs) => _countRiderPaymentIssuesImpl(db, asOfMs),
  scanWithdrawals,
};
