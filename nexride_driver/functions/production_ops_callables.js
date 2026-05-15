/**
 * Restored production HTTPS callables for nexride_dispatch codebase parity.
 * Keeps Firebase CLI from deleting remotely-deployed functions when local exports are missing.
 *
 * Many handlers delegate to admin_callables where names/semantics align; others implement
 * RTDB/Firestore paths used by NexRide admin/support surfaces in-repo.
 */

const admin = require("firebase-admin");
const { FieldValue } = require("firebase-admin/firestore");
const { getAuth } = require("firebase-admin/auth");
const { logger } = require("firebase-functions");
const { getStorage } = require("firebase-admin/storage");
const { normUid } = require("./admin_auth");
const adminPerms = require("./admin_permissions");
const adminCallables = require("./admin_callables");
const {
  loadAdminRiderDirectoryContext,
  estimateFirestoreRiderProfiles,
  countAuthRiderProfileBuckets,
  classifyUserForRiderDirectory,
  enrichRiderRowWithProfileCompleteness,
} = require("./admin_rider_classification");
const adminAuditLog = require("./admin_audit_log");

const firestore = () => admin.firestore();

async function requireAdmin(db, ctx, name) {
  const err = await adminPerms.enforceCallable(db, ctx, name);
  if (err) {
    logger.warn(`${name}_rbac_denied`, { uid: normUid(ctx?.auth?.uid), ...err });
  }
  return err;
}

function trim(v, max = 500) {
  return String(v ?? "")
    .trim()
    .slice(0, max);
}

async function adminListUsers(data, context, db) {
  const _rbac_adminListUsers = await requireAdmin(db, context, "adminListUsers");
  if (_rbac_adminListUsers) return _rbac_adminListUsers;
  const limit = Math.min(200, Math.max(1, Number(data?.limit ?? 50) || 50));
  const snap = await firestore().collection("users").limit(limit).get();
  const users = snap.docs.map((d) => {
    const m = d.data() || {};
    return {
      uid: d.id,
      email: String(m.email ?? "").trim() || null,
      displayName: String(m.displayName ?? m.display_name ?? "").trim() || null,
      verificationStatus: String(m.verificationStatus ?? "").trim() || null,
    };
  });
  return { success: true, users };
}

async function adminGetUserProfile(data, context, db) {
  const _rbac_adminGetUserProfile = await requireAdmin(db, context, "adminGetUserProfile");
  if (_rbac_adminGetUserProfile) return _rbac_adminGetUserProfile;
  const uid = normUid(data?.uid ?? data?.userId);
  if (!uid) return { success: false, reason: "invalid_uid" };
  const [uSnap, dSnap, rSnap] = await Promise.all([
    firestore().collection("users").doc(uid).get(),
    db.ref(`drivers/${uid}`).get(),
    db.ref(`users/${uid}`).get(),
  ]);
  return {
    success: true,
    uid,
    firestore_user: uSnap.exists ? uSnap.data() : null,
    rtdb_user: rSnap.exists() ? rSnap.val() : null,
    driver: dSnap.exists() ? dSnap.val() : null,
  };
}

async function adminListTrips(data, context, db) {
  const r = await adminCallables.adminListLiveRides(data, context, db);
  if (!r.success) return r;
  return { success: true, trips: r.rides || [] };
}

async function adminGetTripDetail(data, context, db) {
  return adminCallables.adminGetTripDetail(data, context, db);
}

async function adminListAuditLogs(data, context, db) {
  return adminAuditLog.adminListAuditLogs(data, context, db);
}

async function adminGetOperationsDashboard(data, context, db) {
  const _rbac_adminGetOperationsDashboard = await requireAdmin(db, context, "adminGetOperationsDashboard");
  if (_rbac_adminGetOperationsDashboard) return _rbac_adminGetOperationsDashboard;
  const activeSnap = await db.ref("active_trips").get();
  const active = activeSnap.val() && typeof activeSnap.val() === "object" ? activeSnap.val() : {};
  const activeTrips = Object.keys(active).length;

  let onlineDrivers = 0;
  let onlineDriversCapped = false;
  try {
    const [onSnap1, onSnap2] = await Promise.all([
      db.ref("drivers").orderByChild("isOnline").equalTo(true).limitToFirst(120).get(),
      db.ref("drivers").orderByChild("is_online").equalTo(true).limitToFirst(120).get(),
    ]);
    const keys = new Set([
      ...Object.keys((onSnap1.val() && typeof onSnap1.val() === "object" && onSnap1.val()) || {}),
      ...Object.keys((onSnap2.val() && typeof onSnap2.val() === "object" && onSnap2.val()) || {}),
    ]);
    onlineDrivers = keys.size;
    onlineDriversCapped = onlineDrivers >= 120;
  } catch (e) {
    logger.warn("adminGetOperationsDashboard onlineDrivers query failed", {
      err: String(e?.message || e),
    });
  }

  let pendingWithdrawals = 0;
  try {
    const wdSnap = await db
      .ref("withdraw_requests")
      .orderByChild("status")
      .equalTo("pending")
      .limitToFirst(200)
      .get();
    const wdVal = wdSnap.val() && typeof wdSnap.val() === "object" ? wdSnap.val() : {};
    pendingWithdrawals = Object.keys(wdVal).length;
  } catch (e) {
    logger.warn("adminGetOperationsDashboard pending withdrawals query failed", {
      err: String(e?.message || e),
    });
  }

  let supportTicketsOpen = 0;
  let supportTicketsCapped = false;
  try {
    const tSnap = await db
      .ref("support_tickets")
      .orderByChild("status")
      .equalTo("open")
      .limitToFirst(200)
      .get();
    const tVal = tSnap.val() && typeof tSnap.val() === "object" ? tSnap.val() : {};
    supportTicketsOpen = Object.keys(tVal).length;
    supportTicketsCapped = supportTicketsOpen >= 200;
  } catch (e) {
    logger.warn("adminGetOperationsDashboard support open query failed", {
      err: String(e?.message || e),
    });
  }

  let riderDirCtx = null;
  try {
    riderDirCtx = await loadAdminRiderDirectoryContext(db);
  } catch (e) {
    logger.warn("adminGetOperationsDashboard riderDirCtx failed", {
      err: String(e?.message || e),
    });
  }
  const emptyRiderCtx = {
    adminUids: new Set(),
    supportUids: new Set(),
    driversVal: {},
    merchantOwnerUids: new Set(),
    merchantStaffUids: new Set(),
  };
  const riderCtx = riderDirCtx || emptyRiderCtx;

  let totalRidersRtdbSample = 0;
  let totalRidersRtdbCompleted = 0;
  let totalRidersRtdbIncomplete = 0;
  let totalRidersRtdbPendingOnboarding = 0;
  let totalRidersRtdbCapped = false;
  try {
    const rSnap = await db.ref("users").orderByKey().limitToFirst(400).get();
    const rVal = rSnap.val() && typeof rSnap.val() === "object" ? rSnap.val() : {};
    for (const [k, u] of Object.entries(rVal)) {
      if (!u || typeof u !== "object") {
        continue;
      }
      const c = classifyUserForRiderDirectory(k, u, `rtdb/users/${k}`, riderCtx);
      if (!c.include) {
        continue;
      }
      totalRidersRtdbSample += 1;
      const enriched = enrichRiderRowWithProfileCompleteness({ ...u });
      if (enriched.profile_completed) {
        totalRidersRtdbCompleted += 1;
        if (enriched.onboarding_completed === false) {
          totalRidersRtdbPendingOnboarding += 1;
        }
      } else {
        totalRidersRtdbIncomplete += 1;
      }
    }
    totalRidersRtdbCapped = Object.keys(rVal).length >= 400;
  } catch (e) {
    logger.warn("adminGetOperationsDashboard riders sample failed", {
      err: String(e?.message || e),
    });
  }

  let totalRidersAuth = 0;
  let totalRidersAuthIncomplete = 0;
  let totalRidersAuthPendingOnboarding = 0;
  let totalRidersAuthCapped = false;
  try {
    const auth = getAuth();
    const buckets = await countAuthRiderProfileBuckets(
      (max, token) => auth.listUsers(max, token),
      riderCtx,
      { maxPages: 10 },
    );
    totalRidersAuth = buckets.completed;
    totalRidersAuthIncomplete = buckets.incomplete;
    totalRidersAuthPendingOnboarding = buckets.pendingOnboarding;
    totalRidersAuthCapped = buckets.capped;
  } catch (e) {
    logger.warn("adminGetOperationsDashboard riders auth count failed", {
      err: String(e?.message || e),
    });
  }

  let totalRidersFirestore = 0;
  let totalRidersFirestoreIncomplete = 0;
  let totalRidersFirestorePendingOnboarding = 0;
  let totalRidersFirestoreScanned = 0;
  let totalRidersFirestoreCapped = false;
  const firestoreSampleIds = [];
  try {
    const fr = await estimateFirestoreRiderProfiles(firestore(), riderCtx, { maxScan: 2500 });
    totalRidersFirestore = fr.completed_count ?? fr.count ?? 0;
    totalRidersFirestoreIncomplete = fr.incomplete_count ?? 0;
    totalRidersFirestorePendingOnboarding = fr.pending_onboarding_count ?? 0;
    totalRidersFirestoreScanned = fr.scanned;
    totalRidersFirestoreCapped = fr.capped;
    firestoreSampleIds.push(...(fr.sampleIds || []));
  } catch (e) {
    logger.warn("adminGetOperationsDashboard firestore rider estimate failed", {
      err: String(e?.message || e),
    });
  }

  const totalRiders = Math.max(totalRidersRtdbCompleted, totalRidersAuth, totalRidersFirestore);
  const incompleteRiderRegistrations = Math.max(
    totalRidersFirestoreIncomplete,
    totalRidersAuthIncomplete,
    totalRidersRtdbIncomplete,
  );
  const pendingOnboarding = Math.max(
    totalRidersFirestorePendingOnboarding,
    totalRidersAuthPendingOnboarding,
    totalRidersRtdbPendingOnboarding,
  );

  let totalMerchants = 0;
  try {
    const agg = await firestore().collection("merchants").count().get();
    totalMerchants = Number(agg.data().count) || 0;
  } catch (e) {
    logger.warn("adminGetOperationsDashboard merchants count failed", {
      err: String(e?.message || e),
    });
  }

  let totalDrivers = 0;
  let totalDriversCapped = false;
  try {
    const dSnap = await db.ref("drivers").orderByKey().limitToFirst(400).get();
    const dVal = dSnap.val() && typeof dSnap.val() === "object" ? dSnap.val() : {};
    totalDrivers = Object.keys(dVal).length;
    totalDriversCapped = totalDrivers >= 400;
  } catch (e) {
    logger.warn("adminGetOperationsDashboard drivers sample failed", {
      err: String(e?.message || e),
    });
  }

  const dashboard = {
    active_trips: activeTrips,
    online_drivers: onlineDrivers,
    online_drivers_capped: onlineDriversCapped,
    pending_withdrawals: pendingWithdrawals,
    support_tickets_open: supportTicketsOpen,
    support_tickets_capped: supportTicketsCapped,
    total_riders: totalRiders,
    incomplete_rider_registrations: incompleteRiderRegistrations,
    pending_onboarding: pendingOnboarding,
    total_riders_sample: totalRidersRtdbSample,
    total_riders_rtdb_completed_sample: totalRidersRtdbCompleted,
    total_riders_rtdb_incomplete_sample: totalRidersRtdbIncomplete,
    total_riders_capped: totalRidersRtdbCapped,
    total_riders_auth: totalRidersAuth,
    total_riders_auth_capped: totalRidersAuthCapped,
    total_riders_firestore_estimate: totalRidersFirestore,
    total_riders_firestore_scanned: totalRidersFirestoreScanned,
    total_riders_firestore_capped: totalRidersFirestoreCapped,
    total_merchants: totalMerchants,
    total_drivers_sample: totalDrivers,
    total_drivers_capped: totalDriversCapped,
    generated_at: Date.now(),
  };

  if (data && data.includeDebugMetrics === true) {
    dashboard.debug_metrics = {
      rider_source_used:
        "max(completed_riders_rtdb_sample, completed_riders_auth_pages, completed_riders_firestore_scan)",
      rider_count_returned: totalRiders,
      sample_rider_ids: firestoreSampleIds,
    };
  }

  return {
    success: true,
    dashboard,
  };
}

async function adminListActiveOperations(_data, context, db) {
  const _rbac_adminListActiveOperations = await requireAdmin(db, context, "adminListActiveOperations");
  if (_rbac_adminListActiveOperations) return _rbac_adminListActiveOperations;
  const r = await adminCallables.adminListLiveRides({}, context, db);
  if (!r.success) return r;
  return { success: true, operations: r.rides || [] };
}

async function adminListReportsAndDisputes(_data, context, db) {
  const _rbac_adminListReportsAndDisputes = await requireAdmin(db, context, "adminListReportsAndDisputes");
  if (_rbac_adminListReportsAndDisputes) return _rbac_adminListReportsAndDisputes;
  return { success: true, items: [] };
}

async function adminGetSupportTicket(data, context, db) {
  const _rbac_adminGetSupportTicket = await requireAdmin(db, context, "adminGetSupportTicket");
  if (_rbac_adminGetSupportTicket) return _rbac_adminGetSupportTicket;
  const ticketId = trim(data?.ticketId ?? data?.ticket_id ?? data?.id, 120);
  if (!ticketId) return { success: false, reason: "invalid_ticket" };
  const [tSnap, mSnap] = await Promise.all([
    db.ref(`support_tickets/${ticketId}`).get(),
    db.ref(`support_ticket_messages/${ticketId}`).get(),
  ]);
  if (!tSnap.exists()) {
    return { success: false, reason: "not_found" };
  }
  return {
    success: true,
    ticket: { id: ticketId, ...(tSnap.val() && typeof tSnap.val() === "object" ? tSnap.val() : {}) },
    messages: mSnap.val() && typeof mSnap.val() === "object" ? mSnap.val() : {},
  };
}

async function adminAssignSupportTicket(data, context, db) {
  const _rbac_adminAssignSupportTicket = await requireAdmin(db, context, "adminAssignSupportTicket");
  if (_rbac_adminAssignSupportTicket) return _rbac_adminAssignSupportTicket;
  const ticketId = trim(data?.ticketId ?? data?.ticket_id, 120);
  const assigneeId = normUid(data?.assigneeId ?? data?.assignee_uid);
  const assigneeName = trim(data?.assigneeName ?? data?.assignee_name, 200);
  if (!ticketId || !assigneeId) return { success: false, reason: "invalid_input" };
  const now = Date.now();
  await db.ref(`support_tickets/${ticketId}`).update({
    assignedToStaffId: assigneeId,
    assignedToStaffName: assigneeName || assigneeId,
    updatedAt: now,
    updated_at: now,
  });
  return { success: true, ticketId, assigneeId };
}

async function adminReplySupportTicket(data, context, db) {
  const _rbac_adminReplySupportTicket = await requireAdmin(db, context, "adminReplySupportTicket");
  if (_rbac_adminReplySupportTicket) return _rbac_adminReplySupportTicket;
  const ticketId = trim(data?.ticketId ?? data?.ticket_id, 120);
  const message = trim(data?.message ?? data?.body, 8000);
  const visibility = trim(data?.visibility ?? "public", 20).toLowerCase() === "internal" ? "internal" : "public";
  if (!ticketId || !message) return { success: false, reason: "invalid_input" };
  const adminUid = normUid(context.auth.uid);
  const msgKey = db.ref(`support_ticket_messages/${ticketId}`).push().key;
  if (!msgKey) return { success: false, reason: "message_key_failed" };
  const now = Date.now();
  const updates = {
    [`support_ticket_messages/${ticketId}/${msgKey}`]: {
      ticketDocumentId: ticketId,
      senderId: adminUid,
      senderRole: "admin",
      senderName: trim(context.auth.token?.email || "Admin", 120),
      message,
      visibility,
      createdAt: now,
      created_at: now,
    },
    [`support_tickets/${ticketId}/updatedAt`]: now,
    [`support_tickets/${ticketId}/updated_at`]: now,
    [`support_tickets/${ticketId}/lastReplyAt`]: now,
    [`support_tickets/${ticketId}/last_reply_at`]: now,
  };
  if (visibility === "public") {
    updates[`support_tickets/${ticketId}/replyCount`] = admin.database.ServerValue.increment(1);
    updates[`support_tickets/${ticketId}/lastPublicSenderRole`] = "admin";
    updates[`support_tickets/${ticketId}/lastSupportReplyAt`] = now;
    updates[`support_tickets/${ticketId}/last_support_reply_at`] = now;
  }
  await db.ref().update(updates);
  return { success: true, ticketId, messageId: msgKey };
}

async function adminUpdateSupportTicketStatus(data, context, db) {
  const _rbac_adminUpdateSupportTicketStatus = await requireAdmin(db, context, "adminUpdateSupportTicketStatus");
  if (_rbac_adminUpdateSupportTicketStatus) return _rbac_adminUpdateSupportTicketStatus;
  const ticketId = trim(data?.ticketId ?? data?.ticket_id, 120);
  const status = trim(data?.status, 80);
  if (!ticketId || !status) return { success: false, reason: "invalid_input" };
  const now = Date.now();
  await db.ref(`support_tickets/${ticketId}`).update({
    status,
    updatedAt: now,
    updated_at: now,
  });
  return { success: true, ticketId, status };
}

async function adminEscalateSupportTicket(data, context, db) {
  const _rbac_adminEscalateSupportTicket = await requireAdmin(db, context, "adminEscalateSupportTicket");
  if (_rbac_adminEscalateSupportTicket) return _rbac_adminEscalateSupportTicket;
  const ticketId = trim(data?.ticketId ?? data?.ticket_id, 120);
  if (!ticketId) return { success: false, reason: "invalid_input" };
  const now = Date.now();
  await db.ref(`support_tickets/${ticketId}`).update({
    escalated: true,
    updatedAt: now,
    updated_at: now,
  });
  return { success: true, ticketId };
}

async function adminListMarkets(data, context, db) {
  const _rbac_adminListMarkets = await requireAdmin(db, context, "adminListMarkets");
  if (_rbac_adminListMarkets) return _rbac_adminListMarkets;
  const snap = await db.ref("platform_settings/markets").get();
  const val = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  const markets = Object.keys(val).map((id) => ({
    id,
    ...(typeof val[id] === "object" ? val[id] : {}),
  }));
  return { success: true, markets };
}

async function adminUpdateMarketEnabled(data, context, db) {
  const _rbac_adminUpdateMarketEnabled = await requireAdmin(db, context, "adminUpdateMarketEnabled");
  if (_rbac_adminUpdateMarketEnabled) return _rbac_adminUpdateMarketEnabled;
  const marketId = trim(data?.marketId ?? data?.market_id, 80);
  const enabled = data?.enabled === true;
  if (!marketId) return { success: false, reason: "invalid_market" };
  await db.ref(`platform_settings/markets/${marketId}`).update({
    enabled,
    updated_at: Date.now(),
  });
  return { success: true, marketId, enabled };
}

async function adminGetPricingConfig(data, context, db) {
  const _rbac_adminGetPricingConfig = await requireAdmin(db, context, "adminGetPricingConfig");
  if (_rbac_adminGetPricingConfig) return _rbac_adminGetPricingConfig;
  const marketId = trim(data?.marketId ?? data?.market_id ?? "lagos", 80);
  const snap = await db.ref(`platform_settings/markets/${marketId}/pricing_config`).get();
  return { success: true, marketId, config: snap.val() || {} };
}

async function adminUpdatePricingConfig(data, context, db) {
  const _rbac_adminUpdatePricingConfig = await requireAdmin(db, context, "adminUpdatePricingConfig");
  if (_rbac_adminUpdatePricingConfig) return _rbac_adminUpdatePricingConfig;
  const marketId = trim(data?.marketId ?? data?.market_id, 80);
  const patch = data?.pricing_config ?? data?.pricingConfig ?? data?.config;
  if (!marketId || !patch || typeof patch !== "object") {
    return { success: false, reason: "invalid_payload" };
  }
  await db.ref(`platform_settings/markets/${marketId}/pricing_config`).update(patch);
  return { success: true, marketId };
}

async function getPricingConfigForMarket(data, context, db) {
  if (!context.auth?.uid) {
    return { success: false, reason: "unauthorized" };
  }
  const marketId = trim(data?.marketId ?? data?.market_id ?? "lagos", 80);
  const snap = await db.ref(`platform_settings/markets/${marketId}/pricing_config`).get();
  return { success: true, marketId, config: snap.val() || {} };
}

async function listEnabledServiceMarkets(_data, context, db) {
  if (!context.auth?.uid) {
    return { success: false, reason: "unauthorized" };
  }
  const snap = await db.ref("platform_settings/markets").get();
  const val = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  const markets = Object.keys(val).filter((id) => {
    const row = val[id];
    return row && typeof row === "object" && row.enabled !== false;
  });
  return { success: true, markets };
}

async function adminListIdentityVerifications(data, context, db) {
  const _rbac_adminListIdentityVerifications = await requireAdmin(db, context, "adminListIdentityVerifications");
  if (_rbac_adminListIdentityVerifications) return _rbac_adminListIdentityVerifications;
  const limit = Math.min(200, Math.max(1, Number(data?.limit ?? 50) || 50));
  const snap = await firestore().collection("identity_verifications").limit(limit).get();
  const rows = snap.docs.map((d) => ({ id: d.id, ...(d.data() || {}) }));
  return { success: true, rows };
}

async function adminReviewIdentityVerification(data, context, db) {
  const _rbac_adminReviewIdentityVerification = await requireAdmin(db, context, "adminReviewIdentityVerification");
  if (_rbac_adminReviewIdentityVerification) return _rbac_adminReviewIdentityVerification;
  const uid = normUid(data?.uid ?? data?.userId);
  const decision = trim(data?.decision ?? data?.status, 32).toLowerCase();
  const note = trim(data?.note, 2000);
  if (!uid || !decision) return { success: false, reason: "invalid_input" };
  await firestore()
    .collection("identity_verifications")
    .doc(uid)
    .set(
      {
        status: decision,
        review_note: note || null,
        reviewed_at: FieldValue.serverTimestamp(),
        reviewed_by: normUid(context.auth.uid),
      },
      { merge: true },
    );
  return { success: true, uid, decision };
}

async function adminIdentityVerificationDebug(data, context, db) {
  const _rbac_adminIdentityVerificationDebug = await requireAdmin(db, context, "adminIdentityVerificationDebug");
  if (_rbac_adminIdentityVerificationDebug) return _rbac_adminIdentityVerificationDebug;
  const uid = normUid(data?.uid ?? data?.userId);
  if (!uid) return { success: false, reason: "invalid_uid" };
  const snap = await firestore().collection("identity_verifications").doc(uid).get();
  return { success: true, exists: snap.exists, data: snap.data() || null };
}

async function adminIdentityVerificationSignedUrl(data, context, db) {
  const _rbac_adminIdentityVerificationSignedUrl = await requireAdmin(db, context, "adminIdentityVerificationSignedUrl");
  if (_rbac_adminIdentityVerificationSignedUrl) return _rbac_adminIdentityVerificationSignedUrl;
  const path = trim(data?.path ?? data?.storagePath, 500);
  if (!path) return { success: false, reason: "invalid_path" };
  const bucket = admin.storage().bucket();
  const [url] = await bucket.file(path).getSignedUrl({
    action: "read",
    expires: Date.now() + 15 * 60 * 1000,
  });
  return { success: true, url };
}

async function syncIdentityVerificationSubmission(data, context, db) {
  const uid = normUid(context?.auth?.uid);
  if (!uid) return { success: false, reason: "unauthorized" };
  const userType = trim(data?.userType ?? data?.user_type ?? "driver", 32);
  await firestore()
    .collection("identity_verifications")
    .doc(uid)
    .set(
      {
        user_type: userType,
        last_client_sync_at: FieldValue.serverTimestamp(),
        ...(typeof data?.payload === "object" && data.payload ? data.payload : {}),
      },
      { merge: true },
    );
  return { success: true, uid };
}

async function adminSuspendUser(data, context, db) {
  return adminCallables.adminSuspendAccount(data, context, db);
}

async function adminWarnUser(data, context, db) {
  return adminCallables.adminWarnAccount(data, context, db);
}

async function adminUnsuspendUser(data, context, db) {
  const uid = normUid(data?.uid ?? data?.userId);
  const role = trim(data?.role, 16).toLowerCase();
  if (!uid || (role !== "driver" && role !== "rider")) {
    return { success: false, reason: "invalid_input", reason_code: "invalid_input" };
  }
  const unsuspendPerm = role === "driver" ? "drivers.write" : "riders.write";
  const denyUnsuspend = await adminPerms.enforcePermission(
    db,
    context,
    unsuspendPerm,
    "adminUnsuspendUser",
    { auditDenied: true },
  );
  if (denyUnsuspend) return denyUnsuspend;
  const now = Date.now();
  const adminUid = normUid(context.auth.uid);
  let before = null;
  if (role === "driver") {
    const pSnap = await db.ref(`drivers/${uid}`).get();
    const p = pSnap.val() && typeof pSnap.val() === "object" ? pSnap.val() : {};
    before = {
      suspended: !!p.suspended,
      account_suspended: !!p.account_suspended,
      account_status: p.account_status ?? p.accountStatus ?? null,
    };
    await db.ref(`drivers/${uid}`).update({
      suspended: false,
      account_suspended: false,
      account_status: "active",
      accountStatus: "active",
      admin_unsuspended_at: now,
      admin_unsuspended_by: adminUid,
      updated_at: now,
    });
  } else {
    const pSnap = await db.ref(`users/${uid}`).get();
    const p = pSnap.val() && typeof pSnap.val() === "object" ? pSnap.val() : {};
    before = {
      status: p.status ?? null,
      account_status: p.account_status ?? p.accountStatus ?? null,
    };
    await db.ref(`users/${uid}`).update({
      status: "active",
      account_status: "active",
      admin_unsuspended_at: now,
      admin_unsuspended_by: adminUid,
      updated_at: now,
    });
  }
  await adminAuditLog.writeAdminAuditLog(db, {
    actor_uid: adminUid,
    action: "unsuspend_user",
    entity_type: role === "driver" ? "driver" : "rider",
    entity_id: uid,
    before,
    after: { suspended: false, account_status: "active", role },
    reason: trim(data?.reason ?? data?.note ?? "", 500) || "admin_unsuspend",
    source: "production_ops.adminUnsuspendUser",
    type: "admin_unsuspend_user",
    created_at: now,
  });
  return { success: true, reason: "active", reason_code: "unsuspended", uid, role };
}

async function adminDisableUser(data, context, db) {
  const wrapped = {
    ...data,
    reason: trim(data?.reason, 500) || "account_disabled_by_admin",
  };
  return adminCallables.adminSuspendAccount(wrapped, context, db);
}

async function adminUpdateUserStatus(data, context, db) {
  const _rbac_adminUpdateUserStatus = await requireAdmin(db, context, "adminUpdateUserStatus");
  if (_rbac_adminUpdateUserStatus) return _rbac_adminUpdateUserStatus;
  const uid = normUid(data?.uid ?? data?.userId);
  const status = trim(data?.status, 80);
  if (!uid || !status) return { success: false, reason: "invalid_input" };
  await db.ref(`users/${uid}`).update({
    account_status: status,
    status,
    updated_at: Date.now(),
  });
  return { success: true, uid, status };
}

async function adminBlockUserTrips(data, context, db) {
  const _rbac_adminBlockUserTrips = await requireAdmin(db, context, "adminBlockUserTrips");
  if (_rbac_adminBlockUserTrips) return _rbac_adminBlockUserTrips;
  const uid = normUid(data?.uid ?? data?.userId);
  if (!uid) return { success: false, reason: "invalid_input" };
  await db.ref(`users/${uid}`).update({
    trips_blocked: true,
    trips_blocked_at: Date.now(),
    trips_blocked_by: normUid(context.auth.uid),
    updated_at: Date.now(),
  });
  return { success: true, uid };
}

async function adminForceDriverOffline(data, context, db) {
  const _rbac_adminForceDriverOffline = await requireAdmin(db, context, "adminForceDriverOffline");
  if (_rbac_adminForceDriverOffline) return _rbac_adminForceDriverOffline;
  const driverId = normUid(data?.driverId ?? data?.driver_id ?? data?.uid);
  if (!driverId) {
    return { success: false, reason: "invalid_driver_id", reason_code: "invalid_driver_id" };
  }
  const reasonRaw = trim(data?.reason ?? data?.note ?? "", 500);
  const reason =
    reasonRaw.length >= 4 ? reasonRaw : "admin_force_offline_default";
  const now = Date.now();
  const adminUid = normUid(context.auth.uid);
  const prevSnap = await db.ref(`drivers/${driverId}`).get();
  const prev = prevSnap.val() && typeof prevSnap.val() === "object" ? prevSnap.val() : {};
  const before = {
    online: !!(prev.online || prev.is_online || prev.isOnline),
    status: prev.status ?? null,
    dispatch_state: prev.dispatch_state ?? null,
  };
  await db.ref().update({
    [`drivers/${driverId}/online`]: false,
    [`drivers/${driverId}/is_online`]: false,
    [`drivers/${driverId}/isOnline`]: false,
    [`drivers/${driverId}/isAvailable`]: false,
    [`drivers/${driverId}/available`]: false,
    [`drivers/${driverId}/status`]: "offline",
    [`drivers/${driverId}/dispatch_state`]: "offline",
    [`drivers/${driverId}/driver_availability_mode`]: "offline",
    [`drivers/${driverId}/admin_forced_offline_at`]: now,
    [`drivers/${driverId}/admin_forced_offline_by`]: adminUid,
    [`drivers/${driverId}/admin_forced_offline_reason`]: reason,
    [`drivers/${driverId}/updated_at`]: now,
    [`online_drivers/${driverId}`]: null,
  });
  await adminAuditLog.writeAdminAuditLog(db, {
    actor_uid: adminUid,
    action: "force_driver_offline",
    entity_type: "driver",
    entity_id: driverId,
    before,
    after: { online: false, status: "offline" },
    reason,
    source: "production_ops.adminForceDriverOffline",
    type: "admin_force_driver_offline",
    created_at: now,
  });
  return { success: true, reason: "offline", reason_code: "forced_offline", driverId };
}

async function getDriverSubscriptionSummary(data, context, db) {
  const uid = normUid(context?.auth?.uid);
  if (!uid) return { success: false, reason: "unauthorized" };
  const driverId = normUid(data?.driverId ?? data?.driver_id ?? uid);
  if (driverId !== uid && !(await adminPerms.canAdmin(db, context, "drivers.read"))) {
    return { success: false, reason: "unauthorized" };
  }
  const snap = await db.ref(`drivers/${driverId}/subscription`).get();
  return { success: true, subscription: snap.val() || {} };
}

async function adminGetSubscriptionOperations(_data, context, db) {
  const _rbac_adminGetSubscriptionOperations = await requireAdmin(db, context, "adminGetSubscriptionOperations");
  if (_rbac_adminGetSubscriptionOperations) return _rbac_adminGetSubscriptionOperations;
  const snap = await db.ref("driver_subscriptions_queue").get();
  return { success: true, queue: snap.val() || {} };
}

async function adminDriverSubscriptionManage(data, context, db) {
  const _rbac_adminDriverSubscriptionManage = await requireAdmin(db, context, "adminDriverSubscriptionManage");
  if (_rbac_adminDriverSubscriptionManage) return _rbac_adminDriverSubscriptionManage;
  const driverId = normUid(data?.driverId ?? data?.driver_id);
  const action = trim(data?.action, 40).toLowerCase();
  if (!driverId || !action) return { success: false, reason: "invalid_input" };
  await db.ref(`drivers/${driverId}/subscription`).update({
    admin_last_action: action,
    admin_last_action_at: Date.now(),
    admin_last_action_by: normUid(context.auth.uid),
  });
  return { success: true, driverId, action };
}

async function renewDriverSubscriptionFromWallet(data, context, db) {
  const uid = normUid(context?.auth?.uid);
  if (!uid) return { success: false, reason: "unauthorized" };
  const driverId = normUid(data?.driverId ?? data?.driver_id ?? uid);
  if (driverId !== uid) return { success: false, reason: "unauthorized" };
  await db.ref(`drivers/${driverId}/subscription`).update({
    wallet_renew_requested_at: Date.now(),
  });
  return { success: true, driverId };
}

async function setDriverSubscriptionAutoRenew(data, context, db) {
  const uid = normUid(context?.auth?.uid);
  if (!uid) return { success: false, reason: "unauthorized" };
  const driverId = normUid(data?.driverId ?? data?.driver_id ?? uid);
  if (driverId !== uid) return { success: false, reason: "unauthorized" };
  const enabled = data?.enabled === true || data?.autoRenew === true;
  await db.ref(`drivers/${driverId}/subscription`).update({
    auto_renew: enabled,
    updated_at: Date.now(),
  });
  return { success: true, driverId, auto_renew: enabled };
}

async function driverConfirmBankTransferPayment(data, context, db) {
  const uid = normUid(context?.auth?.uid);
  if (!uid) return { success: false, reason: "unauthorized" };
  const reference = trim(data?.reference ?? data?.tx_ref, 200);
  if (!reference) return { success: false, reason: "invalid_reference" };
  await db.ref(`payment_transactions/${reference}`).update({
    driver_marked_paid: true,
    driver_marked_paid_at: Date.now(),
    driver_marked_paid_by: uid,
  });
  return { success: true, reference };
}

async function driverReportBankTransferNotReceived(data, context, db) {
  const uid = normUid(context?.auth?.uid);
  if (!uid) return { success: false, reason: "unauthorized" };
  const reference = trim(data?.reference ?? data?.tx_ref, 200);
  if (!reference) return { success: false, reason: "invalid_reference" };
  await db.ref(`payment_transactions/${reference}`).update({
    driver_disputed_not_received: true,
    driver_disputed_at: Date.now(),
    driver_disputed_by: uid,
  });
  return { success: true, reference };
}

async function finalizeBankTransferReceiptUpload(data, context, db) {
  const uid = normUid(context?.auth?.uid);
  if (!uid) return { success: false, reason: "unauthorized" };
  const reference = trim(data?.reference ?? data?.tx_ref, 200);
  const url = trim(data?.url ?? data?.receiptUrl, 2000);
  if (!reference || !url) return { success: false, reason: "invalid_input" };
  await db.ref(`payment_transactions/${reference}`).update({
    bank_transfer_receipt_url: url,
    receipt_uploaded: true,
    receipt_uploaded_at: Date.now(),
    receipt_uploaded_by: uid,
  });
  return { success: true, reference };
}

async function getBankTransferReceiptSignedUrl(data, context, db) {
  const uid = normUid(context?.auth?.uid);
  if (!uid) return { success: false, reason: "unauthorized" };
  const path = trim(data?.path ?? data?.storagePath, 500);
  if (!path) return { success: false, reason: "invalid_path" };
  const bucket = getStorage().bucket();
  const [url] = await bucket.file(path).getSignedUrl({
    action: "write",
    expires: Date.now() + 20 * 60 * 1000,
    contentType: trim(data?.contentType ?? "image/jpeg", 120),
  });
  return { success: true, url };
}

async function adminConfirmBankTransferPayment(data, context, db) {
  let note = String(data?.note ?? data?.reason ?? "").trim();
  if (note.length < 12) {
    note = `Admin bank transfer confirm ${Date.now()}`.slice(0, 500);
  }
  return adminCallables.adminApproveManualPayment({ ...data, note }, context, db);
}

module.exports = {
  adminAssignSupportTicket,
  adminBlockUserTrips,
  adminConfirmBankTransferPayment,
  adminDisableUser,
  adminDriverSubscriptionManage,
  adminEscalateSupportTicket,
  adminForceDriverOffline,
  adminGetOperationsDashboard,
  adminGetPricingConfig,
  adminGetSubscriptionOperations,
  adminGetSupportTicket,
  adminGetTripDetail,
  adminGetUserProfile,
  adminIdentityVerificationDebug,
  adminIdentityVerificationSignedUrl,
  adminListActiveOperations,
  adminListAuditLogs,
  adminListIdentityVerifications,
  adminListMarkets,
  adminListReportsAndDisputes,
  adminListTrips,
  adminListUsers,
  adminReplySupportTicket,
  adminReviewIdentityVerification,
  adminSuspendUser,
  adminUnsuspendUser,
  adminUpdateMarketEnabled,
  adminUpdatePricingConfig,
  adminUpdateSupportTicketStatus,
  adminUpdateUserStatus,
  adminWarnUser,
  driverConfirmBankTransferPayment,
  driverReportBankTransferNotReceived,
  finalizeBankTransferReceiptUpload,
  getBankTransferReceiptSignedUrl,
  getDriverSubscriptionSummary,
  getPricingConfigForMarket,
  listEnabledServiceMarkets,
  renewDriverSubscriptionFromWallet,
  setDriverSubscriptionAutoRenew,
  syncIdentityVerificationSubmission,
};
