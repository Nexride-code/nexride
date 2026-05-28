/**
 * Admin-safe projection and paging for RTDB `payment_transactions/{tx_ref}`.
 * Never exposes PAN/CVV/raw card payloads — Flutterwave refs only.
 */

const { logger } = require("firebase-functions");
const adminPerms = require("./admin_permissions");
const { parseAdminListParams } = require("./admin_list_params");

const DENY_FIELD_SUBSTRINGS = [
  "pan",
  "cvv",
  "cvc",
  "card_number",
  "cardnumber",
  "expiry",
  "exp_month",
  "exp_year",
  "token",
  "encrypted",
  "provider_payload",
  "webhook_body",
  "customer_card",
  "authorization_code",
];

const DENY_EXACT_KEYS = new Set([
  "card",
  "card_data",
  "cardData",
  "payment_method_id",
  "linked_payment_method_id",
  "provider_link",
  "authorization",
]);

function normUid(uid) {
  return String(uid ?? "").trim();
}

function nowMs() {
  return Date.now();
}

function strHint(v, max = 120) {
  const s = String(v ?? "").trim();
  if (!s) return null;
  return s.length > max ? `${s.slice(0, max)}…` : s;
}

function isDeniedFieldKey(key) {
  const k = String(key ?? "").trim();
  if (!k) return true;
  if (DENY_EXACT_KEYS.has(k)) return true;
  const lower = k.toLowerCase();
  return DENY_FIELD_SUBSTRINGS.some((frag) => lower.includes(frag));
}

function derivePaymentPurpose(row) {
  const purpose = String(row?.purpose ?? "").trim();
  return purpose || null;
}

function derivePaymentFlowLabel(row) {
  const purpose = String(row?.purpose ?? "").trim().toLowerCase();
  if (purpose === "driver_wallet_topup") return "wallet_topup";
  const flow = String(row?.flow ?? "").trim();
  return flow || null;
}

function derivePaymentMethod(row) {
  if (!row || typeof row !== "object") return null;
  const purpose = String(row.purpose ?? "").trim().toLowerCase();
  if (purpose === "driver_wallet_topup") return "wallet_topup";
  if (purpose === "driver_subscription_payment") return "subscription";
  if (row.card_authorization === true) return "card";
  const flow = String(row.flow ?? "").trim().toLowerCase();
  const provider = String(row.provider ?? "").trim().toLowerCase();
  if (
    flow.includes("bank") ||
    flow.includes("va") ||
    provider.includes("bank") ||
    row.bank_transfer === true ||
    row.automated_va === true
  ) {
    return "bank_transfer";
  }
  if (flow.includes("card") || provider === "card") {
    return "card";
  }
  const status = String(row.status ?? "").trim().toLowerCase();
  if (status.startsWith("card_")) return "card";
  if (status.includes("bank") || status.includes("transfer")) return "bank_transfer";
  return "card";
}

function normalizeAdminPaymentStatus(row) {
  const status = String(row?.status ?? "").trim().toLowerCase();
  if (!status) return row?.verified === true ? "authorized" : "pending";
  if (status === "card_authorized" || status === "verified") return "authorized";
  if (status === "card_captured" || status === "captured") return "captured";
  if (status.includes("void")) return "voided";
  if (status.includes("refund")) return "refunded";
  if (
    status.includes("fail") ||
    status === "declined" ||
    status === "card_authorization_failed" ||
    status === "expired" ||
    status === "cancelled"
  ) {
    return "failed";
  }
  if (
    status === "pending" ||
    status.startsWith("pending") ||
    status === "card_authorizing" ||
    status.includes("review")
  ) {
    return "pending";
  }
  return status;
}

function deriveCaptureStatus(row, ride) {
  const st = String(row?.status ?? ride?.payment_status ?? "").trim().toLowerCase();
  if (st === "card_captured" || ride?.card_captured_at) return "captured";
  if (st === "card_authorized" || st === "verified") return "authorized_not_captured";
  if (st.includes("capture")) return st;
  return ride?.payment_confirmed === true ? "confirmed" : "n/a";
}

function deriveVoidStatus(row, ride) {
  const st = String(row?.status ?? ride?.payment_status ?? "").trim().toLowerCase();
  if (st.includes("void")) return st;
  if (ride?.card_void_attempted_at) return "void_attempted";
  return "n/a";
}

function deriveRefundStatus(row) {
  const st = String(row?.status ?? "").trim().toLowerCase();
  if (st.includes("refund")) return st;
  return "n/a";
}

function projectSafePaymentTransaction(txRef, row, ride = null) {
  const ref = String(txRef ?? row?.tx_ref ?? "").trim();
  if (!row || typeof row !== "object") {
    return null;
  }
  const rideId = normUid(row.ride_id ?? row.rideId) || null;
  const riderId = normUid(row.rider_id ?? row.riderId ?? row.owner_uid ?? row.ownerUid) || null;
  const driverId =
    normUid(row.driver_id ?? row.driverId) || normUid(ride?.driver_id ?? ride?.driverId) || null;
  const flwRef = strHint(row.flw_ref ?? row.flwRef, 80);
  const authorizationRef = strHint(
    row.authorization_ref ?? row.authorizationRef,
    80,
  );
  const transactionId = strHint(
    row.transaction_id ?? row.flutterwave_transaction_id ?? row.flw_transaction_id,
    80,
  );

  return {
    tx_ref: ref,
    purpose: derivePaymentPurpose(row),
    flow: derivePaymentFlowLabel(row),
    rideId,
    riderId,
    driverId,
    amount: Number(row.amount ?? row.amount_ngn ?? row.total_ngn ?? 0) || 0,
    currency: String(row.currency ?? "NGN").trim().toUpperCase() || "NGN",
    payment_method: derivePaymentMethod(row),
    payment_status: normalizeAdminPaymentStatus(row),
    flw_ref: flwRef,
    authorization_ref: authorizationRef,
    transaction_id: transactionId,
    capture_status: deriveCaptureStatus(row, ride),
    void_status: deriveVoidStatus(row, ride),
    refund_status: deriveRefundStatus(row),
    created_at: Number(row.created_at ?? 0) || 0,
    updated_at: Number(row.updated_at ?? 0) || 0,
  };
}

function parsePaymentTransactionsListParams(data) {
  const base = parseAdminListParams(data || {});
  const method = String(data?.method ?? data?.payment_method ?? "")
    .trim()
    .toLowerCase();
  const rideId = normUid(data?.rideId ?? data?.ride_id);
  const riderId = normUid(data?.riderId ?? data?.rider_id);
  const driverId = normUid(data?.driverId ?? data?.driver_id);
  return { ...base, method, rideId, riderId, driverId };
}

function paymentTransactionRowMatches(txRef, row, f) {
  if (!row || typeof row !== "object") return false;
  const safe = projectSafePaymentTransaction(txRef, row);
  if (!safe) return false;

  if (f.method && f.method !== "all") {
    const want = f.method === "bank" ? "bank_transfer" : f.method;
    const got = String(safe.payment_method ?? "").toLowerCase();
    const purpose = String(row.purpose ?? "").trim().toLowerCase();
    if (want === "wallet_topup") {
      if (purpose !== "driver_wallet_topup" && got !== "wallet_topup") return false;
    } else if (want === "bank_transfer" && got !== "bank_transfer") return false;
    else if (want === "card" && got !== "card") return false;
    else if (want === "subscription" && got !== "subscription") return false;
  }

  if (f.status && f.status !== "all") {
    const got = String(safe.payment_status ?? "").toLowerCase();
    if (got !== f.status && !got.includes(f.status)) return false;
  }

  if (f.rideId && normUid(safe.rideId) !== f.rideId) return false;
  if (f.riderId && normUid(safe.riderId) !== f.riderId) return false;
  if (f.driverId && normUid(safe.driverId) !== f.driverId) return false;

  const t = Number(safe.updated_at || safe.created_at || 0) || 0;
  if (f.createdFrom > 0 && t > 0 && t < f.createdFrom) return false;
  if (f.createdTo > 0 && t > 0 && t > f.createdTo) return false;

  if (f.search) {
    const q = f.search.toLowerCase();
    const hay = [
      txRef,
      safe.tx_ref,
      safe.rideId,
      safe.riderId,
      safe.driverId,
      safe.flw_ref,
      safe.authorization_ref,
      safe.transaction_id,
      safe.payment_status,
      safe.payment_method,
    ]
      .filter(Boolean)
      .join(" ")
      .toLowerCase();
    if (!hay.includes(q)) return false;
  }

  return true;
}

async function _adminGate(callableName, context, db) {
  return adminPerms.enforceCallable(db, context, callableName);
}

async function adminListPaymentTransactionsPage(data, context, db) {
  const deny = await _adminGate("adminListPaymentTransactionsPage", context, db);
  if (deny) return deny;

  const f = parsePaymentTransactionsListParams(data || {});
  const limit = f.limit;
  const MAX_SCAN = 5000;
  const BATCH = 120;
  let resumeKey = f.cursor.trim();
  const matches = {};
  let scanned = 0;
  let lastScannedKey = resumeKey;
  let lastBatchFull = false;

  while (Object.keys(matches).length < limit + 1 && scanned < MAX_SCAN) {
    let q = db.ref("payment_transactions").orderByKey();
    if (resumeKey) {
      q = q.startAfter(resumeKey);
    }
    let snap;
    try {
      snap = await q.limitToFirst(BATCH).get();
    } catch (e) {
      logger.warn("adminListPaymentTransactionsPage batch failed", {
        err: String(e?.message || e),
      });
      break;
    }
    const val = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
    const batchKeys = Object.keys(val).sort();
    lastBatchFull = batchKeys.length === BATCH;
    if (batchKeys.length === 0) break;

    for (const k of batchKeys) {
      scanned += 1;
      lastScannedKey = k;
      const row = val[k];
      if (!paymentTransactionRowMatches(k, row, f)) continue;
      const projected = projectSafePaymentTransaction(k, row);
      if (!projected) continue;
      matches[k] = projected;
      if (Object.keys(matches).length >= limit + 1) break;
    }
    resumeKey = batchKeys[batchKeys.length - 1];
    if (batchKeys.length < BATCH) break;
  }

  const keys = Object.keys(matches).sort(
    (a, b) => (matches[b].updated_at || 0) - (matches[a].updated_at || 0),
  );
  const hasMoreFromMatches = keys.length > limit;
  const pageKeys = hasMoreFromMatches ? keys.slice(0, limit) : keys;
  const transactions = {};
  for (const k of pageKeys) {
    transactions[k] = matches[k];
  }
  const hasMore =
    hasMoreFromMatches || (pageKeys.length === limit && lastBatchFull && scanned < MAX_SCAN);
  const nextCursor = lastScannedKey && hasMore ? lastScannedKey : null;

  return {
    success: true,
    transactions,
    nextCursor,
    hasMore,
    count: pageKeys.length,
    scanned,
    capped_scan: scanned >= MAX_SCAN,
  };
}

function paymentAuditTypes() {
  return new Set([
    "manual_payment_approved",
    "admin_approve_manual_payment",
    "admin_confirm_bank_transfer",
    "bank_transfer_confirmed",
    "payment_verified",
    "payment_review",
  ]);
}

function buildPaymentTimelineEvents(ride, safeRows, auditRows) {
  const events = [];
  const push = (at, kind, label, detail) => {
    const ms = Number(at || 0) || 0;
    if (!label) return;
    events.push({ at: ms, kind, label, detail: detail || null });
  };

  if (ride && typeof ride === "object") {
    const pm = String(ride.payment_method ?? "").trim().toLowerCase();
    push(ride.created_at ?? ride.requested_at, "ride_created", "Ride created", `method=${pm || "—"}`);
    push(
      ride.card_authorized_at ?? ride.payment_verified_at,
      "card_auth",
      "Card authorization",
      String(ride.payment_status ?? ""),
    );
    push(ride.card_captured_at, "card_capture", "Card capture", String(ride.payment_status ?? ""));
    push(
      ride.card_void_attempted_at,
      "card_void",
      "Card void / release",
      String(ride.payment_status ?? ""),
    );
    push(
      ride.payment_confirmed_at ?? ride.bank_transfer_confirmed_at,
      "bank_transfer",
      "Bank transfer confirmation",
      String(ride.payment_status ?? ""),
    );
    push(ride.payment_verified_at, "payment_verified", "Payment verified", pm);
  }

  for (const row of safeRows) {
    push(row.created_at, "payment_tx", "Payment transaction created", row.tx_ref);
    push(row.updated_at, "payment_tx_update", `Status: ${row.payment_status}`, row.tx_ref);
  }

  for (const a of auditRows) {
    const t = String(a.type ?? "").trim().toLowerCase();
    if (!paymentAuditTypes().has(t) && !t.includes("payment") && !t.includes("bank")) {
      continue;
    }
    push(
      a.created_at,
      "admin_action",
      a.type || "admin",
      String(a.note ?? a.reason ?? "").slice(0, 240) || null,
    );
  }

  events.sort((a, b) => (Number(b.at) || 0) - (Number(a.at) || 0));
  return events.slice(0, 40);
}

async function loadSafePaymentRowsForRide(db, ride) {
  const refKeys = new Set(
    [
      ride?.payment_reference,
      ride?.customer_transaction_reference,
      ride?.payment_intent_id,
      ride?.payment_transaction_id,
    ]
      .map((x) => String(x ?? "").trim())
      .filter(Boolean),
  );
  const rows = [];
  for (const refKey of refKeys) {
    const txSnap = await db.ref(`payment_transactions/${refKey}`).get();
    const row = txSnap.val();
    if (row && typeof row === "object") {
      const safe = projectSafePaymentTransaction(refKey, row, ride);
      if (safe) rows.push(safe);
    }
  }
  return rows;
}

async function buildRidePaymentAdminView(db, ride, auditTimeline = []) {
  const safeRows = await loadSafePaymentRowsForRide(db, ride);
  const primary = safeRows[0] ?? null;
  const pm = String(ride?.payment_method ?? "").trim().toLowerCase();
  const ps = String(ride?.payment_status ?? "").trim().toLowerCase();

  const payment_detail = {
    payment_method: pm || primary?.payment_method || null,
    payment_status: ps || primary?.payment_status || null,
    tx_ref:
      primary?.tx_ref ??
      strHint(ride?.payment_reference ?? ride?.customer_transaction_reference, 120),
    flw_ref: primary?.flw_ref ?? strHint(ride?.flw_ref, 80),
    authorization_ref:
      primary?.authorization_ref ?? strHint(ride?.authorization_ref, 80),
    transaction_id:
      primary?.transaction_id ??
      strHint(ride?.payment_transaction_id ?? ride?.flw_tx_id, 80),
    card_auth: {
      status: ps.includes("card") ? ps : primary?.payment_status ?? null,
      authorized_at: Number(ride?.card_authorized_at ?? ride?.payment_verified_at ?? 0) || null,
    },
    capture: {
      status: deriveCaptureStatus(primary || {}, ride),
      captured_at: Number(ride?.card_captured_at ?? 0) || null,
    },
    void_refund: {
      void_status: deriveVoidStatus(primary || {}, ride),
      refund_status: deriveRefundStatus(primary || {}),
      void_attempted_at: Number(ride?.card_void_attempted_at ?? 0) || null,
    },
    bank_transfer: {
      status: ps,
      payment_confirmed: ride?.payment_confirmed === true,
      automated: ride?.bank_transfer_automated === true,
      confirmed_at:
        Number(ride?.payment_confirmed_at ?? ride?.bank_transfer_confirmed_at ?? 0) || null,
      receipt_url: strHint(ride?.bank_transfer_receipt_url, 200),
    },
    admin_actions: auditTimeline
      .filter((a) => {
        const t = String(a?.type ?? "").toLowerCase();
        return paymentAuditTypes().has(t) || t.includes("payment") || t.includes("bank");
      })
      .slice(0, 20)
      .map((a) => ({
        type: a.type ?? null,
        at: Number(a.created_at ?? 0) || 0,
        note: strHint(a.note ?? a.reason, 240),
        admin_uid: normUid(a.admin_uid ?? a.actor_uid) || null,
      })),
  };

  const payment_timeline = buildPaymentTimelineEvents(ride, safeRows, auditTimeline);

  return {
    payments: safeRows,
    payment_detail,
    payment_timeline,
  };
}

module.exports = {
  DENY_EXACT_KEYS,
  DENY_FIELD_SUBSTRINGS,
  isDeniedFieldKey,
  derivePaymentPurpose,
  derivePaymentFlowLabel,
  derivePaymentMethod,
  normalizeAdminPaymentStatus,
  projectSafePaymentTransaction,
  paymentTransactionRowMatches,
  adminListPaymentTransactionsPage,
  buildRidePaymentAdminView,
  loadSafePaymentRowsForRide,
};
