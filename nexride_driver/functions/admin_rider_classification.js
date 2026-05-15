/**
 * Rider vs internal/driver/merchant/support classification for admin lists
 * and dashboard counts. Keeps sparse real rider docs while excluding staff.
 */

"use strict";

const admin = require("firebase-admin");
const { FieldPath } = require("firebase-admin/firestore");
const { logger } = require("firebase-functions");
const { normUid } = require("./admin_auth");
const { driverProfileLooksCommittedForRiderExclusion } = require("./admin_rider_metrics");

const NON_RIDER_ROLES = new Set([
  "driver",
  "admin",
  "administrator",
  "merchant",
  "staff",
  "support",
  "support_agent",
  "support_manager",
  "dispatcher",
  "operator",
  "system",
  "nexride_admin",
]);

const RIDER_LIKE_ROLES = new Set(["", "rider", "passenger", "customer", "user", "client", "member"]);

function lc(s) {
  return String(s ?? "")
    .trim()
    .toLowerCase();
}

function effectiveRoles(row) {
  if (!row || typeof row !== "object") {
    return [];
  }
  return [
    lc(row.role),
    lc(row.account_role),
    lc(row.accountType),
    lc(row.account_type),
    lc(row.userType),
    lc(row.user_type),
    lc(row.app_role),
    lc(row.persona),
  ].filter((x) => x.length > 0);
}

function rowSaysNonRiderRole(row) {
  for (const r of effectiveRoles(row)) {
    if (RIDER_LIKE_ROLES.has(r)) {
      continue;
    }
    if (NON_RIDER_ROLES.has(r)) {
      return r;
    }
  }
  return "";
}

function driverRtdbNodeLooksLikeDriverAccount(dRow) {
  if (!dRow || typeof dRow !== "object") {
    return false;
  }
  if (driverProfileLooksCommittedForRiderExclusion(dRow)) {
    return true;
  }
  const r = lc(dRow.role ?? dRow.account_role ?? "");
  if (r === "driver") {
    return true;
  }
  if (dRow.isDriver === true || dRow.is_driver === true) {
    return true;
  }
  return false;
}

/**
 * @param {string} uid
 * @param {object} row slim or raw profile
 * @param {string} sourcePath logical source (rtdb/users, firestore/users, auth_listUsers)
 * @param {{
 *   adminUids: Set<string>,
 *   supportUids: Set<string>,
 *   driversVal: Record<string, object>,
 *   merchantOwnerUids: Set<string>,
 *   merchantStaffUids: Set<string>,
 * }} ctx
 */
function classifyUserForRiderDirectory(uid, row, sourcePath, ctx) {
  const id = normUid(uid);
  if (!id) {
    return {
      include: false,
      excluded_reason: "invalid_uid",
      classification_reason: "reject_invalid_uid",
      source_path: sourcePath,
    };
  }
  if (!row || typeof row !== "object") {
    return {
      include: false,
      excluded_reason: "missing_row",
      classification_reason: "reject_missing_row",
      source_path: sourcePath,
    };
  }

  if (ctx.adminUids.has(id)) {
    return {
      include: false,
      excluded_reason: "rtdb_admins",
      classification_reason: "nexride_internal_admin_uid",
      source_path: sourcePath,
    };
  }
  if (ctx.supportUids.has(id)) {
    return {
      include: false,
      excluded_reason: "rtdb_support_staff",
      classification_reason: "nexride_support_uid",
      source_path: sourcePath,
    };
  }
  if (ctx.merchantOwnerUids.has(id)) {
    return {
      include: false,
      excluded_reason: "firestore_merchant_owner",
      classification_reason: "merchant_owner_account",
      source_path: sourcePath,
    };
  }
  if (ctx.merchantStaffUids.has(id)) {
    return {
      include: false,
      excluded_reason: "firestore_merchant_staff",
      classification_reason: "merchant_staff_account",
      source_path: sourcePath,
    };
  }

  const email = lc(row.email ?? row.userEmail ?? row.user_email ?? row.primaryEmail ?? row.primary_email);
  if (email === "admin@nexride.africa") {
    return {
      include: false,
      excluded_reason: "email_admin_inbox",
      classification_reason: "nexride_admin_email",
      source_path: sourcePath,
    };
  }

  if (row.is_admin === true || row.isAdmin === true || row.is_nexride_admin === true) {
    return {
      include: false,
      excluded_reason: "row_is_admin_flag",
      classification_reason: "explicit_admin_flag",
      source_path: sourcePath,
    };
  }

  const nr = rowSaysNonRiderRole(row);
  if (nr) {
    return {
      include: false,
      excluded_reason: `role_${nr}`,
      classification_reason: "non_rider_role_field",
      source_path: sourcePath,
    };
  }

  const dRow = ctx.driversVal[id];
  if (dRow && typeof dRow === "object" && driverRtdbNodeLooksLikeDriverAccount(dRow)) {
    return {
      include: false,
      excluded_reason: "driver_rtdb_profile",
      classification_reason: "driver_account",
      source_path: sourcePath,
    };
  }

  if (row.is_merchant === true || row.isMerchant === true) {
    return {
      include: false,
      excluded_reason: "row_merchant_flag",
      classification_reason: "merchant_markers_on_user_doc",
      source_path: sourcePath,
    };
  }
  const mid = normUid(row.merchant_id ?? row.merchantId ?? "");
  if (mid) {
    return {
      include: false,
      excluded_reason: "row_merchant_id",
      classification_reason: "merchant_id_on_user_doc",
      source_path: sourcePath,
    };
  }

  if (row.test_account === true || row.is_test_user === true || lc(row.account_kind) === "system") {
    return {
      include: false,
      excluded_reason: "test_or_system_flag",
      classification_reason: "non_production_account",
      source_path: sourcePath,
    };
  }

  return {
    include: true,
    excluded_reason: null,
    classification_reason: "rider_or_unclassified_customer",
    source_path: sourcePath,
  };
}

/**
 * @param {*} authUser Firebase Auth UserRecord from Admin SDK listUsers
 * @param {*} ctx
 */
function classifyAuthUserForRiderDirectory(authUser, ctx) {
  const claims =
    authUser?.customClaims && typeof authUser.customClaims === "object" ? authUser.customClaims : {};
  if (claims.admin === true) {
    return {
      include: false,
      excluded_reason: "auth_claim_admin",
      classification_reason: "firebase_auth_admin_claim",
      source_path: "auth_listUsers",
    };
  }
  const cr = lc(claims.role);
  if (cr && NON_RIDER_ROLES.has(cr) && !RIDER_LIKE_ROLES.has(cr)) {
    return {
      include: false,
      excluded_reason: `auth_claim_role_${cr}`,
      classification_reason: "auth_custom_claim_role",
      source_path: "auth_listUsers",
    };
  }
  const row = {
    email: authUser?.email,
    displayName: authUser?.displayName,
    phone: authUser?.phoneNumber,
    role: typeof claims.role === "string" ? claims.role : "",
    account_type: claims.account_type ?? claims.accountType,
    user_type: claims.user_type ?? claims.userType,
    is_admin: claims.admin === true,
    isAdmin: claims.admin === true,
  };
  return classifyUserForRiderDirectory(authUser.uid, row, "auth_listUsers", ctx);
}

async function loadAdminRiderDirectoryContext(db) {
  const fs = admin.firestore();
  const [adminsSnap, supportSnap, driversSnap] = await Promise.all([
    db.ref("admins").get(),
    db.ref("support_staff").get(),
    db.ref("drivers").orderByKey().limitToFirst(8000).get(),
  ]);

  const adminUids = new Set();
  const av = adminsSnap.val();
  if (av && typeof av === "object") {
    for (const k of Object.keys(av)) {
      const x = normUid(k);
      if (!x) {
        continue;
      }
      if (av[k] === true || (typeof av[k] === "object" && av[k] != null)) {
        adminUids.add(x);
      }
    }
  }

  const supportUids = new Set();
  const sv = supportSnap.val();
  if (sv && typeof sv === "object") {
    for (const [k, v] of Object.entries(sv)) {
      const x = normUid(k);
      if (!x) {
        continue;
      }
      if (v === true) {
        supportUids.add(x);
        continue;
      }
      if (v && typeof v === "object") {
        const disabled = v.disabled === true || v.enabled === false;
        const role = lc(v.role);
        if (!disabled && (role === "support_agent" || role === "support_manager" || role === "support")) {
          supportUids.add(x);
        }
      }
    }
  }

  const driversVal =
    driversSnap.val() && typeof driversSnap.val() === "object" ? driversSnap.val() : {};

  const merchantOwnerUids = new Set();
  const merchantStaffUids = new Set();
  try {
    let cursor = null;
    const batch = 100;
    let scanned = 0;
    const cap = 2500;
    while (scanned < cap) {
      let q = fs.collection("merchants").orderBy(FieldPath.documentId()).limit(batch);
      if (cursor) {
        q = q.startAfter(cursor);
      }
      const snap = await q.get();
      if (snap.empty) {
        break;
      }
      for (const doc of snap.docs) {
        scanned += 1;
        const m = doc.data() || {};
        const o = normUid(m.owner_uid ?? m.ownerUid);
        if (o) {
          merchantOwnerUids.add(o);
        }
        const staff = Array.isArray(m.staff_uids)
          ? m.staff_uids
          : Array.isArray(m.staffUids)
            ? m.staffUids
            : [];
        for (const s of staff) {
          const sid = normUid(s);
          if (sid) {
            merchantStaffUids.add(sid);
          }
        }
      }
      cursor = snap.docs[snap.docs.length - 1];
      if (snap.size < batch) {
        break;
      }
    }
  } catch (e) {
    logger.warn("loadAdminRiderDirectoryContext merchants scan failed", {
      err: String(e?.message || e),
    });
  }

  return {
    adminUids,
    supportUids,
    driversVal,
    merchantOwnerUids,
    merchantStaffUids,
  };
}

function attachClassificationDebug(row, cls, enabled) {
  if (!enabled || !row || typeof row !== "object" || !cls) {
    return row;
  }
  return {
    ...row,
    classification_reason: cls.classification_reason,
    excluded_reason: cls.excluded_reason,
    source_path: cls.source_path,
  };
}

function timestampLikeToMs(v) {
  if (v == null || v === "") {
    return 0;
  }
  if (typeof v === "number" && Number.isFinite(v)) {
    return v;
  }
  if (typeof v === "string") {
    const n = Date.parse(v);
    return Number.isFinite(n) ? n : 0;
  }
  if (typeof v === "object") {
    try {
      if (typeof v.toMillis === "function") {
        return Number(v.toMillis()) || 0;
      }
      if (typeof v._seconds === "number") {
        return Number(v._seconds) * 1000;
      }
    } catch (_) {
      /* ignore */
    }
  }
  return 0;
}

function phoneDigits(s) {
  return String(s ?? "").replace(/\D/g, "");
}

function hasPhoneOrEmail(row) {
  const d = phoneDigits(row.phone ?? row.phoneNumber ?? row.mobile ?? row.msisdn ?? row.phone_number);
  if (d.length >= 10) {
    return true;
  }
  if (d.length >= 6) {
    return true;
  }
  const email = lc(row.email ?? row.primary_email ?? row.primaryEmail ?? row.userEmail ?? row.user_email);
  return email.includes("@") && email.length > 5;
}

/**
 * Meaningful display identity: not empty, and not a lone generic "Rider" label
 * (username / handle counts as identity).
 */
function hasDisplayOrUsername(row) {
  const username = lc(row.username ?? row.userName ?? row.handle ?? row.nickname ?? "");
  if (username.length >= 2 && username !== "rider") {
    return true;
  }
  const candidates = [
    String(row.displayName ?? "").trim(),
    String(row.name ?? "").trim(),
    String(row.fullName ?? row.full_name ?? "").trim(),
    String(row.preferredName ?? row.preferred_name ?? "").trim(),
  ];
  for (const c of candidates) {
    if (c.length < 2) {
      continue;
    }
    if (c.toLowerCase() === "rider") {
      continue;
    }
    return true;
  }
  return false;
}

function hasCreatedTimestamp(row) {
  const ms = Math.max(
    Number(row.created_at ?? row.createdAt ?? 0) || 0,
    timestampLikeToMs(row.signupAt),
    timestampLikeToMs(row.auth_created_at),
    Number(row.auth_creation_ms ?? row.authCreationMs ?? 0) || 0,
    timestampLikeToMs(row.metadataCreationTime),
  );
  return ms > 0;
}

function resolveOnboardingCompleted(row) {
  const ob = row.onboarding_completed ?? row.onboardingComplete;
  if (ob === true) {
    return true;
  }
  if (ob === false) {
    return false;
  }
  const stage = lc(row.onboarding_stage ?? row.onboardingStep ?? row.onboarding_step ?? "");
  if (stage === "complete" || stage === "completed" || stage === "done") {
    return true;
  }
  if (stage && stage !== "complete" && stage !== "completed" && stage !== "done") {
    return false;
  }
  return null;
}

function computeRiderProfileCompleteness(row) {
  const profile_completed = !!(hasDisplayOrUsername(row) && hasPhoneOrEmail(row) && hasCreatedTimestamp(row));
  const onboarding_completed = resolveOnboardingCompleted(row);
  return { profile_completed, onboarding_completed };
}

/**
 * Adds profile_completed (boolean) and onboarding_completed (boolean) when known.
 * @param {object} row
 */
function enrichRiderRowWithProfileCompleteness(row) {
  if (!row || typeof row !== "object") {
    return row;
  }
  const { profile_completed, onboarding_completed } = computeRiderProfileCompleteness(row);
  const out = { ...row, profile_completed };
  if (onboarding_completed === true || onboarding_completed === false) {
    out.onboarding_completed = onboarding_completed;
  } else {
    delete out.onboarding_completed;
  }
  return out;
}

/**
 * Firestore users/{uid} scan for dashboard totals — uses same classifier as admin list.
 */
async function estimateFirestoreRiderProfiles(fs, ctx, opts) {
  const maxScan = Math.min(8000, Math.max(200, Number(opts?.maxScan ?? 2500) || 2500));
  const batchSize = 120;
  let scanned = 0;
  let completedCount = 0;
  let incompleteCount = 0;
  let pendingOnboardingCount = 0;
  let cursor = null;
  const sampleIds = [];
  while (scanned < maxScan) {
    let q = fs.collection("users").orderBy(FieldPath.documentId()).limit(batchSize);
    if (cursor) {
      q = q.startAfter(cursor);
    }
    let snap;
    try {
      snap = await q.get();
    } catch (e) {
      logger.warn("estimateFirestoreRiderProfiles query failed", {
        err: String(e?.message || e),
      });
      break;
    }
    if (snap.empty) {
      break;
    }
    for (const doc of snap.docs) {
      scanned += 1;
      const d = doc.data() || {};
      const uid = doc.id;
      const slim = {
        uid,
        ...d,
        role: lc(d.role ?? d.account_role ?? d.accountType ?? d.userType ?? ""),
        email: d.email ?? d.primary_email ?? "",
        phone: d.phone ?? d.phoneNumber ?? "",
      };
      const c = classifyUserForRiderDirectory(uid, slim, "firestore/users", ctx);
      if (!c.include) {
        continue;
      }
      const enriched = enrichRiderRowWithProfileCompleteness(slim);
      if (enriched.profile_completed) {
        completedCount += 1;
        if (enriched.onboarding_completed === false) {
          pendingOnboardingCount += 1;
        }
        if (sampleIds.length < 8) {
          sampleIds.push(uid);
        }
      } else {
        incompleteCount += 1;
      }
    }
    cursor = snap.docs[snap.docs.length - 1];
    if (snap.size < batchSize) {
      break;
    }
  }
  const classifiedTotal = completedCount + incompleteCount;
  return {
    /** @deprecated use completed_count — kept for older readers */
    count: completedCount,
    completed_count: completedCount,
    incomplete_count: incompleteCount,
    pending_onboarding_count: pendingOnboardingCount,
    classified_total: classifiedTotal,
    scanned,
    capped: scanned >= maxScan,
    sampleIds,
  };
}

function authUserToProfileRow(authUser) {
  const claims =
    authUser?.customClaims && typeof authUser.customClaims === "object" ? authUser.customClaims : {};
  const createdMs = authUser.metadata?.creationTime
    ? new Date(authUser.metadata.creationTime).getTime()
    : 0;
  const lastLoginMs = authUser.metadata?.lastSignInTime
    ? new Date(authUser.metadata.lastSignInTime).getTime()
    : 0;
  return {
    displayName: authUser.displayName || "",
    name: authUser.displayName || "",
    email: authUser.email || "",
    phone: authUser.phoneNumber || "",
    role: typeof claims.role === "string" ? claims.role : "",
    account_type: claims.account_type ?? claims.accountType,
    user_type: claims.user_type ?? claims.userType,
    is_admin: claims.admin === true,
    isAdmin: claims.admin === true,
    created_at: createdMs,
    createdAt: createdMs,
    last_active_at: lastLoginMs,
    lastActiveAt: lastLoginMs,
    metadataCreationTime: createdMs,
    onboarding_completed: claims.onboarding_completed ?? claims.onboardingComplete,
  };
}

async function countAuthRiderProfileBuckets(listUsers, ctx, opts) {
  const maxPages = Math.min(30, Math.max(1, Number(opts?.maxPages ?? 10) || 10));
  let pageToken;
  let completed = 0;
  let incomplete = 0;
  let pendingOnboarding = 0;
  for (let page = 0; page < maxPages; page += 1) {
    const res = await listUsers(1000, pageToken);
    for (const u of res.users) {
      const c = classifyAuthUserForRiderDirectory(u, ctx);
      if (!c.include) {
        continue;
      }
      const row = enrichRiderRowWithProfileCompleteness(authUserToProfileRow(u));
      if (row.profile_completed) {
        completed += 1;
        if (row.onboarding_completed === false) {
          pendingOnboarding += 1;
        }
      } else {
        incomplete += 1;
      }
    }
    if (!res.pageToken) {
      return {
        completed,
        incomplete,
        pendingOnboarding,
        classified_total: completed + incomplete,
        capped: false,
      };
    }
    pageToken = res.pageToken;
  }
  return {
    completed,
    incomplete,
    pendingOnboarding,
    classified_total: completed + incomplete,
    capped: true,
  };
}

module.exports = {
  NON_RIDER_ROLES,
  RIDER_LIKE_ROLES,
  classifyUserForRiderDirectory,
  classifyAuthUserForRiderDirectory,
  loadAdminRiderDirectoryContext,
  attachClassificationDebug,
  estimateFirestoreRiderProfiles,
  countAuthRiderProfileBuckets,
  enrichRiderRowWithProfileCompleteness,
  computeRiderProfileCompleteness,
  authUserToProfileRow,
  driverRtdbNodeLooksLikeDriverAccount,
};
