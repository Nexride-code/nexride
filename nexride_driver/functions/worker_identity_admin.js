/**
 * Admin Duplicate Review Visibility — read-only admin callables.
 *
 * Surfaces the observe-only duplicate identity review signals written by the
 * worker identity checks (Slice B) so admins can SEE flagged accounts. This
 * module never enforces, blocks, or mutates anything — it is strictly read-only.
 *
 * Cost design:
 * - Callable + pagination (limit <= 50), keyed reads only for the visible page.
 * - No listeners, no polling, no broad scans beyond the existing list pattern.
 * - Never returns raw NIN/BVN/bank/plate values and never returns claim hashes.
 *   `matched_claim_types` are claim *type names* (e.g. "nin"), not hashes.
 */

"use strict";

const { logger } = require("firebase-functions");
const { normUid } = require("./admin_auth");
const adminPerms = require("./admin_permissions");

const VALID_REVIEW_STATUSES = new Set([
  "clear",
  "warning",
  "duplicate_review_required",
]);

function strOrNull(v) {
  const s = String(v ?? "").trim();
  return s.length ? s : null;
}

function asStringList(v) {
  if (!Array.isArray(v)) return [];
  return v.map((x) => String(x ?? "").trim()).filter(Boolean);
}

/**
 * Builds a safe driver profile summary for the review views. Only display-safe
 * fields are surfaced — never raw identity documents.
 * @param {Record<string, unknown>|null} profile
 */
function buildDriverSummaryForReview(profile) {
  const p = profile && typeof profile === "object" ? profile : {};
  return {
    driver_name: strOrNull(p.name ?? p.driver_name ?? p.fullName),
    phone: strOrNull(p.phone ?? p.phone_number ?? p.phoneNumber),
    email: strOrNull(p.email),
    service_type: strOrNull(p.service_type ?? p.serviceType),
    ownership_mode: strOrNull(p.ownership_mode ?? p.ownershipMode),
    business_id: strOrNull(p.business_id ?? p.businessId),
    dispatch_vehicle_type: strOrNull(
      p.dispatch_vehicle_type ?? p.dispatchVehicleType,
    ),
    profile_identity_review_status: strOrNull(p.identity_review_status),
    profile_duplicate_review_required: p.duplicate_review_required === true,
    identity_review_updated_at:
      Number(p.identity_review_updated_at ?? 0) || 0,
  };
}

/**
 * Normalizes a stored review record into a safe view object. Strips anything
 * that is not explicitly whitelisted (defensive against future fields).
 * @param {string} uid
 * @param {Record<string, unknown>|null} review
 */
function buildReviewView(uid, review) {
  const r = review && typeof review === "object" ? review : {};
  const status = String(r.status ?? "").trim().toLowerCase();
  const matchedWorkerIds = asStringList(r.matched_worker_ids);
  return {
    driver_id: uid,
    identity_review_status: VALID_REVIEW_STATUSES.has(status)
      ? status
      : status || "clear",
    duplicate_review_required: status === "duplicate_review_required",
    matched_claim_types: asStringList(r.matched_claim_types),
    blocking_claim_types: asStringList(r.blocking_claim_types),
    warning_claim_types: asStringList(r.warning_claim_types),
    matched_worker_ids: matchedWorkerIds,
    matched_worker_count: matchedWorkerIds.length,
    matched_business_ids: asStringList(r.matched_business_ids),
    // `resolved`/`resolution` are not written yet (no Resolve action). Surface
    // them read-only if a future slice adds them.
    resolved: r.resolved === true,
    resolution_status: strOrNull(r.resolution_status),
    created_at: Number(r.created_at ?? 0) || 0,
    updated_at: Number(r.updated_at ?? 0) || 0,
  };
}

function reviewMatchesFilter(uid, review, f) {
  const status = String(review?.status ?? "").trim().toLowerCase();
  if (f.flaggedOnly && status === "clear") return false;
  if (f.status && f.status !== "all" && status !== f.status) return false;
  if (f.search) {
    const q = f.search;
    if (!String(uid).toLowerCase().includes(q)) return false;
  }
  return true;
}

function parseReviewListParams(data) {
  const limitRaw = Number(data?.limit ?? data?.pageSize ?? 50);
  const limit = Math.min(
    50,
    Math.max(1, Number.isFinite(limitRaw) ? Math.floor(limitRaw) : 50),
  );
  const cursor = typeof data?.cursor === "string" ? data.cursor.trim() : "";
  const search = String(data?.search ?? "").trim().toLowerCase();
  let status = String(data?.status ?? "").trim().toLowerCase();
  if (status && status !== "all" && !VALID_REVIEW_STATUSES.has(status)) {
    status = "";
  }
  const flaggedOnly =
    data?.flaggedOnly === true || data?.flagged_only === true;
  return { limit, cursor, search, status, flaggedOnly };
}

/**
 * Read-only paginated list of identity reviews. RBAC: verification.read.
 * @param {object} data
 * @param {object} context
 * @param {import("firebase-admin/database").Database} db
 */
async function adminListWorkerIdentityReviewsPage(data, context, db) {
  const rbac = await adminPerms.enforceCallable(
    db,
    context,
    "adminListWorkerIdentityReviewsPage",
  );
  if (rbac) return rbac;

  const f = parseReviewListParams(data || {});
  const limit = f.limit;
  const MAX_SCAN = 4000;
  const BATCH = 120;
  let resumeKey = f.cursor.trim();
  /** @type {Record<string, object>} */
  const matches = {};
  let scanned = 0;
  let lastScannedKey = resumeKey;
  let lastBatchFull = false;

  while (Object.keys(matches).length < limit + 1 && scanned < MAX_SCAN) {
    let q = db.ref("worker_identity_reviews").orderByKey();
    if (resumeKey) {
      q = q.startAfter(resumeKey);
    }
    let snap;
    try {
      snap = await q.limitToFirst(BATCH).get();
    } catch (e) {
      logger.warn("adminListWorkerIdentityReviewsPage batch failed", {
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
      if (reviewMatchesFilter(k, row, f)) {
        matches[k] = buildReviewView(k, row);
        if (Object.keys(matches).length >= limit + 1) break;
      }
    }
    resumeKey = batchKeys[batchKeys.length - 1];
    if (batchKeys.length < BATCH) break;
  }

  const keys = Object.keys(matches).sort(
    (a, b) => (matches[b].updated_at || 0) - (matches[a].updated_at || 0),
  );
  const hasMoreFromMatches = keys.length > limit;
  const pageKeys = hasMoreFromMatches ? keys.slice(0, limit) : keys;

  // Enrich the visible page only — one keyed read of drivers/{uid} per row.
  const items = [];
  for (const uid of pageKeys) {
    let profile = null;
    try {
      const dSnap = await db.ref(`drivers/${uid}`).get();
      const dVal = dSnap && typeof dSnap.val === "function" ? dSnap.val() : null;
      profile = dVal && typeof dVal === "object" ? dVal : null;
    } catch (e) {
      logger.warn("adminListWorkerIdentityReviewsPage enrich read failed", {
        uid,
        err: String(e?.message || e),
      });
      profile = null;
    }
    items.push({ ...matches[uid], ...buildDriverSummaryForReview(profile) });
  }

  const hasMore =
    hasMoreFromMatches ||
    (pageKeys.length === limit && lastBatchFull && scanned < MAX_SCAN);
  const nextCursor = lastScannedKey && hasMore ? lastScannedKey : null;
  return {
    success: true,
    observe_only: true,
    reviews: items,
    nextCursor,
    hasMore,
    count: items.length,
    scanned,
    capped_scan: scanned >= MAX_SCAN,
  };
}

/**
 * Read-only detail for a single driver's identity review. RBAC: verification.read.
 * @param {object} data
 * @param {object} context
 * @param {import("firebase-admin/database").Database} db
 */
async function adminGetWorkerIdentityReview(data, context, db) {
  const rbac = await adminPerms.enforceCallable(
    db,
    context,
    "adminGetWorkerIdentityReview",
  );
  if (rbac) return rbac;

  const uid = normUid(data?.driver_id ?? data?.driverId ?? data?.uid);
  if (!uid) {
    return { success: false, reason: "driver_id_required" };
  }

  let reviewVal = null;
  let profileVal = null;
  try {
    const [rSnap, dSnap] = await Promise.all([
      db.ref(`worker_identity_reviews/${uid}`).get(),
      db.ref(`drivers/${uid}`).get(),
    ]);
    const rv = rSnap && typeof rSnap.val === "function" ? rSnap.val() : null;
    const dv = dSnap && typeof dSnap.val === "function" ? dSnap.val() : null;
    reviewVal = rv && typeof rv === "object" ? rv : null;
    profileVal = dv && typeof dv === "object" ? dv : null;
  } catch (e) {
    logger.warn("adminGetWorkerIdentityReview read failed", {
      uid,
      err: String(e?.message || e),
    });
    return { success: false, reason: "read_failed" };
  }

  if (!reviewVal && !profileVal) {
    return { success: true, found: false, observe_only: true, review: null };
  }

  return {
    success: true,
    found: reviewVal != null,
    observe_only: true,
    review: {
      ...buildReviewView(uid, reviewVal),
      ...buildDriverSummaryForReview(profileVal),
    },
  };
}

module.exports = {
  buildReviewView,
  buildDriverSummaryForReview,
  reviewMatchesFilter,
  parseReviewListParams,
  adminListWorkerIdentityReviewsPage,
  adminGetWorkerIdentityReview,
};
