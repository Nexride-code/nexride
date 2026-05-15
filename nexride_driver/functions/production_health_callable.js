/**
 * Admin-only production health snapshot for store-readiness monitoring.
 * Riders have no wallets/withdrawals — payment issue counts are card/bank/unpaid only.
 */

const admin = require("firebase-admin");
const { getAuth } = require("firebase-admin/auth");
const { getStorage } = require("firebase-admin/storage");
const { logger } = require("firebase-functions");
const { normUid } = require("./admin_auth");
const adminPerms = require("./admin_permissions");
const liveOps = require("./live_operations_dashboard_callable");
const { normalizeServiceAreaRow } = require("./ecosystem/delivery_regions");

const firestore = () => admin.firestore();

const DRIVERS_SCAN_CAP = 800;
const MERCHANTS_SCAN_CAP = 200;
const WITHDRAWALS_CAP = 200;
const STALE_DRIVER_HEARTBEAT_MS = 180_000;
const STALE_MERCHANT_PORTAL_MS = 600_000;
const PORTAL_ONLINE_MS = 120_000;
const SAMPLE_LIMIT = 12;

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

async function countRiderPaymentIssues(db) {
  let failed_card_payments = 0;
  let pending_bank_transfer_confirmations = 0;
  let unpaid_rider_trips_orders = 0;

  const countKeys = (val) =>
    val && typeof val === "object" ? Object.keys(val).length : 0;

  try {
    const failedSnap = await db
      .ref("ride_requests")
      .orderByChild("payment_status")
      .equalTo("failed")
      .limitToFirst(200)
      .get();
    failed_card_payments += countKeys(failedSnap.val());
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
    pending_bank_transfer_confirmations += countKeys(pendingSnap.val());
  } catch (e) {
    logger.warn("production_health pending bank ride_requests", {
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
    unpaid_rider_trips_orders += countKeys(unpaidSnap.val());
  } catch (e) {
    logger.warn("production_health unpaid ride_requests", {
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
    failed_card_payments += countKeys(delFailed.val());
  } catch (_) {}

  try {
    const delPending = await db
      .ref("delivery_requests")
      .orderByChild("payment_status")
      .equalTo("pending_manual_confirmation")
      .limitToFirst(100)
      .get();
    pending_bank_transfer_confirmations += countKeys(delPending.val());
  } catch (_) {}

  try {
    const moSnap = await firestore()
      .collection("merchant_orders")
      .where("payment_status", "in", ["failed", "unpaid", "pending_bank_transfer"])
      .limit(100)
      .get()
      .catch(() => null);
    if (moSnap) {
      for (const doc of moSnap.docs) {
        const ps = String(doc.data()?.payment_status ?? "").toLowerCase();
        if (ps === "failed") failed_card_payments += 1;
        else if (ps === "pending_bank_transfer") pending_bank_transfer_confirmations += 1;
        else if (ps === "unpaid") unpaid_rider_trips_orders += 1;
      }
    }
  } catch (_) {}

  return {
    failed_card_payments,
    pending_bank_transfer_confirmations,
    unpaid_rider_trips_orders,
    total:
      failed_card_payments +
      pending_bank_transfer_confirmations +
      unpaid_rider_trips_orders,
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
    riderPayments,
    withdrawals,
    pendingVerifications,
    activeTripsSnap,
    activeDelSnap,
  ] = await Promise.all([
    scanServiceAreaWarnings(db),
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

  const overall_status = worstStatus(
    infraStatus === "ok" ? "green" : infraStatus === "degraded" ? "yellow" : "red",
    statusLevel(drivers.stale_heartbeat || 0, 3, 15),
    statusLevel(merchants.stale_portal || 0, 2, 8),
    statusLevel(paymentIssueTotal, 1, 10),
    statusLevel(withdrawals.pending_total || 0, 5, 30),
    statusLevel(payoutWarnings, 1, 5),
    statusLevel(support_open, 10, 50),
    statusLevel(serviceAreaWarningTotal, 1, 5),
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
      summary: `${paymentIssueTotal} issues (card/bank/unpaid — no rider wallets)`,
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
      status: statusLevel(serviceAreaWarningTotal, 1, 5),
      summary: `${serviceAreaWarningTotal} configuration warnings`,
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
  countRiderPaymentIssues,
  scanWithdrawals,
};
