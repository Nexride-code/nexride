/**
 * Admin business mutations — RTDB/Firestore writes only from server (audited).
 */

const { logger } = require("firebase-functions");
const adminAuditLog = require("./admin_audit_log");
const adminPerms = require("./admin_permissions");
const { normUid } = require("./admin_auth");
const withdrawFlow = require("./withdraw_flow");

function nowMs() {
  return Date.now();
}

function trim(v, max = 2000) {
  return String(v ?? "")
    .trim()
    .slice(0, max);
}

function pricingCityStorageKey(cityName) {
  const s = String(cityName ?? "")
    .trim()
    .toLowerCase();
  if (s === "abuja_fct" || s.startsWith("abuja")) return "abuja";
  if (s.startsWith("lagos")) return "lagos";
  if (s.startsWith("delta")) return "delta";
  if (s.startsWith("edo")) return "edo";
  if (s.startsWith("imo")) return "imo";
  if (s.startsWith("anambra")) return "anambra";
  return s.replace(/[^a-z0-9]+/g, "_").replace(/^_|_$/g, "") || "unknown";
}

function mapVal(v) {
  return v && typeof v === "object" && !Array.isArray(v) ? { ...v } : {};
}

function nextDocumentStatus(currentStatus, action) {
  const st = String(currentStatus ?? "")
    .trim()
    .toLowerCase();
  if (st === "missing") return "missing";
  if (action === "approve") return "approved";
  if (action === "reject" || action === "resubmit") return "rejected";
  return st || "submitted";
}

function nextDocumentResult(action, prevResult) {
  if (action === "approve") return "approved";
  if (action === "reject") return "rejected";
  if (action === "resubmit") return "resubmission_required";
  return prevResult ?? "awaiting_review";
}

/**
 * Non-final withdrawal status updates (e.g. processing) + payout reference on paid path.
 */
async function adminUpdateWithdrawalStatus(data, context, db) {
  const deny = await adminPerms.enforceCallable(db, context, "adminUpdateWithdrawalStatus");
  if (deny) return deny;

  const withdrawalId = normUid(data?.withdrawalId ?? data?.withdrawal_id);
  const status = trim(data?.status, 40).toLowerCase();
  const payoutReference = trim(
    data?.payoutReference ?? data?.payout_reference ?? data?.reference,
    200,
  );
  const note = trim(data?.adminNote ?? data?.admin_note ?? data?.note, 2000);
  if (!withdrawalId || !status) {
    return { success: false, reason: "invalid_input" };
  }

  if (status === "paid" || status === "approved") {
    return withdrawFlow.approveWithdrawal(
      {
        ...data,
        status: "paid",
        payout_reference: payoutReference || undefined,
        payoutReference: payoutReference || undefined,
      },
      context,
      db,
    );
  }
  if (status === "rejected") {
    return withdrawFlow.approveWithdrawal({ ...data, status: "rejected" }, context, db);
  }

  const allowed = new Set(["processing", "pending", "reviewing"]);
  if (!allowed.has(status)) {
    return { success: false, reason: "invalid_status" };
  }

  const ref = db.ref(`withdraw_requests/${withdrawalId}`);
  const snap = await ref.get();
  const w = snap.val();
  if (!w || typeof w !== "object") {
    return { success: false, reason: "not_found" };
  }
  const beforeStatus = String(w.status ?? "").trim().toLowerCase();
  const now = nowMs();
  const adminUid = normUid(context.auth.uid);
  const patch = {
    status,
    updated_at: now,
    updatedAt: now,
    reviewed_by: adminUid,
    admin_note: note || null,
  };
  if (status === "processing") {
    patch.processedAt = now;
    patch.processed_at = now;
  }
  if (payoutReference) {
    patch.payoutReference = payoutReference;
    patch.payout_reference = payoutReference;
  }
  await ref.update(patch);

  const sourcePaths = Array.isArray(data?.sourcePaths)
    ? data.sourcePaths.filter((p) => typeof p === "string" && p.includes("/"))
    : [];
  if (sourcePaths.length > 0) {
    const multi = {};
    for (const path of sourcePaths) {
      multi[`${path}/status`] = status;
      multi[`${path}/updated_at`] = now;
      multi[`${path}/updatedAt`] = now;
      if (status === "processing") {
        multi[`${path}/processedAt`] = now;
      }
      if (payoutReference) {
        multi[`${path}/payoutReference`] = payoutReference;
        multi[`${path}/payout_reference`] = payoutReference;
      }
      if (note) {
        multi[`${path}/note`] = note;
        multi[`${path}/adminNote`] = note;
      }
    }
    await db.ref().update(multi);
  }

  await adminAuditLog.writeAdminAuditLog(db, {
    actor_uid: adminUid,
    action: "update_withdrawal_status",
    entity_type: "withdrawal",
    entity_id: withdrawalId,
    before: { status: beforeStatus },
    after: { status, payout_reference: payoutReference || null },
    reason: note || null,
    source: "admin_business_mutations.adminUpdateWithdrawalStatus",
    type: "admin_update_withdrawal_status",
    created_at: now,
  });

  return { success: true, withdrawalId, status };
}

/**
 * Bulk driver verification case review (documents + driver_verifications mirror).
 */
async function adminReviewDriverVerificationCase(data, context, db) {
  const deny = await adminPerms.enforceCallable(db, context, "adminReviewDriverVerificationCase");
  if (deny) return deny;

  const driverId = normUid(data?.driverId ?? data?.driver_id);
  const action = trim(data?.action, 32).toLowerCase();
  const note = trim(data?.note ?? data?.reviewNote, 2000);
  const reviewedBy = normUid(data?.reviewedBy ?? data?.reviewed_by ?? context.auth.uid);
  const rawCase = mapVal(data?.verificationCase ?? data?.verification_case);
  if (!driverId || !action) {
    return { success: false, reason: "invalid_input" };
  }
  if (!["approve", "reject", "resubmit"].includes(action)) {
    return { success: false, reason: "invalid_action" };
  }

  const drvSnap = await db.ref(`drivers/${driverId}`).get();
  const drv = mapVal(drvSnap.val());
  const verification = mapVal(drv.verification ?? rawCase.verification);
  const documents = mapVal(verification.documents ?? rawCase.documents);
  const nextDocuments = {};
  for (const [key, rawDoc] of Object.entries(documents)) {
    const doc = mapVal(rawDoc);
    const nextStatus = nextDocumentStatus(doc.status, action);
    const failureReason =
      action === "reject" || action === "resubmit"
        ? note ||
          (action === "resubmit" ? "resubmission_required" : "rejected_by_admin")
        : "";
    nextDocuments[key] = {
      ...doc,
      status: nextStatus,
      reviewNote: note,
      reviewedAt: nowMs(),
      reviewedBy: reviewedBy,
      failureReason,
      updatedAt: nowMs(),
      result: nextDocumentResult(action, doc.result),
    };
  }

  const now = nowMs();
  const nextVerification = {
    ...verification,
    documents: nextDocuments,
    lastReviewedAt: now,
    reviewedBy,
    updatedAt: now,
    status:
      action === "approve"
        ? "approved"
        : action === "reject"
          ? "rejected"
          : "resubmission_required",
    overallStatus:
      action === "approve"
        ? "approved"
        : action === "reject"
          ? "rejected"
          : "resubmission_required",
    result:
      action === "approve"
        ? "approved"
        : action === "reject"
          ? "rejected"
          : "resubmission_required",
  };

  const auditRef = db.ref("verification_audits").push();
  const updates = {
    [`drivers/${driverId}/verification`]: nextVerification,
    [`drivers/${driverId}/updated_at`]: now,
    [`driver_verifications/${driverId}`]: {
      ...rawCase,
      ...nextVerification,
      driverId,
      driverName: trim(rawCase.driverName ?? drv.name, 200),
      phone: trim(rawCase.phone ?? drv.phone, 80),
      email: trim(rawCase.email ?? drv.email, 200),
      reviewedBy,
      reviewedAt: now,
      updatedAt: now,
    },
    [`verification_audits/${auditRef.key}`]: {
      auditId: auditRef.key,
      driverId,
      action:
        action === "approve"
          ? "verification_approved"
          : action === "reject"
            ? "verification_rejected"
            : "verification_resubmission_requested",
      status: nextVerification.status,
      result: nextVerification.result,
      failureReason: note,
      reviewedBy,
      reviewedAt: now,
      createdAt: now,
      updatedAt: now,
    },
  };

  for (const [docKey, docVal] of Object.entries(nextDocuments)) {
    updates[`driver_documents/${driverId}/${docKey}`] = {
      ...docVal,
      driverId,
      driverName: trim(rawCase.driverName ?? drv.name, 200),
    };
  }

  if (action === "approve") {
    updates[`drivers/${driverId}/verification_status`] = "approved";
    updates[`drivers/${driverId}/identity_verification_status`] = "approved";
    updates[`drivers/${driverId}/is_verified`] = true;
    updates[`drivers/${driverId}/nexride_verified`] = true;
    updates[`drivers/${driverId}/verification_approved_at`] = now;
    updates[`drivers/${driverId}/verification_approved_by`] = reviewedBy;
    updates[`users/${driverId}/kyc_status/kyc_approved`] = true;
    updates[`users/${driverId}/kyc_status/kyc_admin_override`] = true;
    updates[`users/${driverId}/kyc_status/submission_status`] = "approved";
    updates[`users/${driverId}/kyc_status/admin_approved_at`] = now;
    updates[`users/${driverId}/kyc_status/admin_approved_by`] = reviewedBy;
    updates[`users/${driverId}/kyc_status/updated_at`] = now;
  }

  await db.ref().update(updates);

  await adminAuditLog.writeAdminAuditLog(db, {
    actor_uid: reviewedBy,
    action:
      action === "approve"
        ? "approve_verification_case"
        : action === "reject"
          ? "reject_verification_case"
          : "resubmit_verification_case",
    entity_type: "driver",
    entity_id: driverId,
    before: { verification_status: drv.verification_status ?? null },
    after: {
      status: nextVerification.status,
      document_count: Object.keys(nextDocuments).length,
    },
    reason: note || null,
    source: "admin_business_mutations.adminReviewDriverVerificationCase",
    type: "admin_review_driver_verification_case",
    created_at: now,
  });

  return { success: true, driverId, action, status: nextVerification.status };
}

/**
 * Admin read of fare/pricing config (RTDB is not client-readable for admins on web).
 */
async function adminGetAppPricingConfig(_data, context, db) {
  const deny = await adminPerms.enforceCallable(db, context, "adminGetAppPricingConfig");
  if (deny) return deny;

  const [pricingSnap, citySnap, dispatchSnap] = await Promise.all([
    db.ref("app_config/pricing").get(),
    db.ref("app_config/city_enablement").get(),
    db.ref("app_config/nexride_dispatch").get(),
  ]);

  return {
    success: true,
    pricing: pricingSnap.val() && typeof pricingSnap.val() === "object" ? pricingSnap.val() : {},
    city_enablement:
      citySnap.val() && typeof citySnap.val() === "object" ? citySnap.val() : {},
    nexride_dispatch:
      dispatchSnap.val() && typeof dispatchSnap.val() === "object" ? dispatchSnap.val() : {},
  };
}

/**
 * Authenticated clients (driver/rider apps) read pricing for fare UI — RTDB rules deny direct client reads.
 */
async function getAppPricingConfig(_data, context, db) {
  if (!context.auth?.uid) {
    return { success: false, reason: "unauthorized" };
  }
  const snap = await db.ref("app_config/pricing").get();
  return {
    success: true,
    pricing: snap.val() && typeof snap.val() === "object" ? snap.val() : {},
  };
}

/**
 * Updates app_config pricing + optional driver businessModel pricingSnapshot batch.
 */
async function adminUpdateAppPricingConfig(data, context, db) {
  const deny = await adminPerms.enforceCallable(db, context, "adminUpdateAppPricingConfig");
  if (deny) return deny;

  const cities = Array.isArray(data?.cities) ? data.cities : [];
  const commissionRate = Number(data?.commissionRate ?? data?.commission_rate ?? 0);
  const weeklySubscriptionNgn = Number(
    data?.weeklySubscriptionNgn ?? data?.weekly_subscription_ngn ?? 0,
  );
  const monthlySubscriptionNgn = Number(
    data?.monthlySubscriptionNgn ?? data?.monthly_subscription_ngn ?? 0,
  );
  if (!cities.length) {
    return { success: false, reason: "invalid_cities" };
  }

  const normalizedCities = {};
  const cityEnablement = {};
  for (const row of cities) {
    if (!row || typeof row !== "object") continue;
    const city = trim(row.city ?? row.name, 120);
    if (!city) continue;
    const slug = pricingCityStorageKey(city);
    normalizedCities[slug] = {
      city,
      baseFareNgn: Number(row.baseFareNgn ?? row.base_fare_ngn ?? 0),
      perKmNgn: Number(row.perKmNgn ?? row.per_km_ngn ?? 0),
      perMinuteNgn: Number(row.perMinuteNgn ?? row.per_minute_ngn ?? 0),
      minimumFareNgn: Number(row.minimumFareNgn ?? row.minimum_fare_ngn ?? 0),
      enabled: row.enabled !== false,
    };
    cityEnablement[slug] = normalizedCities[slug].enabled;
  }

  const now = nowMs();
  const pricingSnapshot = {
    commissionRate,
    weeklySubscriptionNgn,
    monthlySubscriptionNgn,
    updatedAt: now,
  };

  await db.ref().update({
    "app_config/pricing": {
      cities: normalizedCities,
      ...pricingSnapshot,
    },
    "app_config/city_enablement": cityEnablement,
  });

  const driverBatchSize = 150;
  const maxDriversToScan = 25000;
  let processed = 0;
  let pageCursor = null;

  while (processed < maxDriversToScan) {
    let q = db.ref("drivers").orderByKey().limitToFirst(driverBatchSize);
    if (pageCursor) {
      q = db.ref("drivers").orderByKey().startAfter(pageCursor).limitToFirst(driverBatchSize);
    }
    const snap = await q.get();
    const val = snap.val();
    if (!val || typeof val !== "object") break;
    const keys = Object.keys(val).sort();
    if (!keys.length) break;

    const batch = {};
    for (const driverId of keys) {
      const profile = mapVal(val[driverId]);
      const bm = mapVal(profile.businessModel ?? profile.business_model);
      const nextBm = {
        ...bm,
        pricingSnapshot,
        updatedAt: now,
      };
      batch[`drivers/${driverId}/businessModel`] = nextBm;
      batch[`drivers/${driverId}/updated_at`] = now;
      batch[`driver_business_models/${driverId}`] = {
        driverId,
        driverName: trim(profile.name, 200),
        phone: trim(profile.phone, 80),
        businessModel: nextBm,
        updatedAt: now,
      };
    }
    if (Object.keys(batch).length) {
      await db.ref().update(batch);
    }
    processed += keys.length;
    pageCursor = keys[keys.length - 1];
    if (keys.length < driverBatchSize) break;
  }

  await adminAuditLog.writeAdminAuditLog(db, {
    actor_uid: normUid(context.auth.uid),
    action: "update_app_pricing_config",
    entity_type: "settings",
    entity_id: "app_config/pricing",
    before: {},
    after: {
      city_count: Object.keys(normalizedCities).length,
      drivers_processed: processed,
      commission_rate: commissionRate,
    },
    reason: null,
    source: "admin_business_mutations.adminUpdateAppPricingConfig",
    type: "admin_update_app_pricing_config",
    created_at: now,
  });

  logger.info("adminUpdateAppPricingConfig", {
    cities: Object.keys(normalizedCities).length,
    driversProcessed: processed,
  });

  return {
    success: true,
    cities: Object.keys(normalizedCities).length,
    drivers_processed: processed,
  };
}

/**
 * Admin sets driver subscription status on businessModel (commission exempt when active).
 */
async function adminUpdateDriverSubscriptionStatus(data, context, db) {
  const deny = await adminPerms.enforceCallable(
    db,
    context,
    "adminUpdateDriverSubscriptionStatus",
  );
  if (deny) return deny;

  const driverId = normUid(data?.driverId ?? data?.driver_id);
  const status = trim(data?.status ?? data?.subscriptionStatus, 40).toLowerCase();
  if (!driverId || !status) {
    return { success: false, reason: "invalid_input" };
  }

  const driverPath = `drivers/${driverId}`;
  const snap = await db.ref(`${driverPath}/businessModel`).get();
  const current = mapVal(snap.val());
  const active = status === "active";
  const now = nowMs();
  const nextBm = {
    ...current,
    selectedModel: "subscription",
    commissionExempt: active,
    commission_exempt: active,
    subscription: {
      ...mapVal(current.subscription),
      status,
      updatedAt: now,
    },
    updatedAt: now,
  };

  const profileSnap = await db.ref(driverPath).get();
  const profile = mapVal(profileSnap.val());

  await db.ref().update({
    [`${driverPath}/businessModel`]: nextBm,
    [`${driverPath}/updated_at`]: now,
    [`driver_business_models/${driverId}`]: {
      driverId,
      driverName: trim(profile.name, 200),
      phone: trim(profile.phone, 80),
      selectedModel: "subscription",
      subscriptionActive: active,
      businessModel: nextBm,
      updatedAt: now,
    },
  });

  await adminAuditLog.writeAdminAuditLog(db, {
    actor_uid: normUid(context.auth.uid),
    action: "update_driver_subscription_status",
    entity_type: "driver",
    entity_id: driverId,
    before: { subscription_status: mapVal(current.subscription).status ?? null },
    after: { subscription_status: status, commission_exempt: active },
    reason: null,
    source: "admin_business_mutations.adminUpdateDriverSubscriptionStatus",
    type: "admin_update_driver_subscription_status",
    created_at: now,
  });

  return { success: true, driverId, status };
}

/**
 * Driver self-service: commission vs subscription model selection (not final approval).
 */
async function driverSelectBusinessModel(data, context, db) {
  const uid = normUid(context?.auth?.uid);
  const driverId = normUid(data?.driverId ?? data?.driver_id ?? uid);
  if (!uid || !driverId || uid !== driverId) {
    return { success: false, reason: "unauthorized" };
  }
  const selectedModel = trim(data?.selectedModel ?? data?.model, 32).toLowerCase();
  if (selectedModel !== "commission" && selectedModel !== "subscription") {
    return { success: false, reason: "invalid_model" };
  }

  const profileSnap = await db.ref(`drivers/${driverId}`).get();
  const profile = mapVal(profileSnap.val());
  const bmSnap = await db.ref(`drivers/${driverId}/businessModel`).get();
  const current = mapVal(bmSnap.val());
  const now = Date.now();

  const nextBm = { ...current, selectedModel, updatedAt: now };
  if (selectedModel === "subscription") {
    const sub = mapVal(current.subscription);
    nextBm.subscription = {
      ...sub,
      status: sub.status && String(sub.status).trim() ? sub.status : "setup_required",
      updatedAt: now,
    };
    const subStatus = String(nextBm.subscription.status || "").toLowerCase();
    nextBm.commissionExempt = subStatus === "active";
    nextBm.commission_exempt = subStatus === "active";
    nextBm.canGoOnline = subStatus === "active";
  } else {
    const comm = mapVal(current.commission);
    nextBm.commission = {
      ...comm,
      status: comm.status && String(comm.status).trim() ? comm.status : "eligible",
      updatedAt: now,
    };
    nextBm.commissionExempt = false;
    nextBm.commission_exempt = false;
    nextBm.canGoOnline = true;
  }
  nextBm.eligibilityStatus =
    nextBm.canGoOnline === true ? "eligible" : "setup_required";
  nextBm.effectiveModel = selectedModel;

  await db.ref().update({
    [`drivers/${driverId}/businessModel`]: nextBm,
    [`drivers/${driverId}/updated_at`]: now,
    [`driver_business_models/${driverId}`]: {
      driverId,
      driverName: trim(profile.name, 200),
      phone: trim(profile.phone, 80),
      selectedModel,
      subscriptionActive: !!nextBm.commissionExempt,
      businessModel: nextBm,
      updatedAt: now,
    },
  });

  await adminAuditLog.writeAdminAuditLog(db, {
    actor_uid: uid,
    action: "driver_select_business_model",
    entity_type: "driver",
    entity_id: driverId,
    before: { selectedModel: current.selectedModel ?? null },
    after: { selectedModel, canGoOnline: nextBm.canGoOnline },
    reason: null,
    source: "admin_business_mutations.driverSelectBusinessModel",
    type: "driver_select_business_model",
    created_at: now,
  });

  return {
    success: true,
    driverId,
    selectedModel,
    canGoOnline: nextBm.canGoOnline === true,
  };
}

module.exports = {
  adminUpdateWithdrawalStatus,
  adminReviewDriverVerificationCase,
  adminGetAppPricingConfig,
  getAppPricingConfig,
  adminUpdateAppPricingConfig,
  adminUpdateDriverSubscriptionStatus,
  driverSelectBusinessModel,
};
