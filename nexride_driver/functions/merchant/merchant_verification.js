/**
 * Phase 2B — Merchant verification documents + readiness (Firestore + Storage via callables).
 */

const admin = require("firebase-admin");
const { FieldValue } = require("firebase-admin/firestore");
const { logger } = require("firebase-functions");
const { normUid } = require("../admin_auth");
const adminPerms = require("../admin_permissions");

const DOCUMENT_TYPES = new Set([
  "cac_document",
  "owner_id",
  "storefront_photo",
  "address_proof",
  "operating_license",
]);

const DOCUMENT_STATUSES = new Set([
  "not_submitted",
  "pending",
  "approved",
  "rejected",
  "resubmission_required",
]);

function trimStr(v, max = 500) {
  return String(v ?? "")
    .trim()
    .slice(0, max);
}

function categoryRequiresOperatingLicense(category) {
  const c = String(category ?? "")
    .trim()
    .toLowerCase();
  if (!c) return false;
  return (
    c.includes("restaurant") ||
    c.includes("food") ||
    c.includes("pharmacy")
  );
}

function docsCollection(fs, merchantId) {
  return fs
    .collection("merchant_verification_documents")
    .doc(merchantId)
    .collection("documents");
}

/**
 * Canonical owner id on a merchant row (snake_case or legacy camelCase).
 * @param {Record<string, unknown> | null | undefined} m
 */
function rowOwnerUid(m) {
  return normUid(m?.owner_uid ?? m?.ownerUid);
}

/**
 * Portal role for a signed-in user against a merchant document.
 * @param {Record<string, unknown> | null | undefined} m
 * @param {string} uid
 */
function merchantPortalRole(m, uid) {
  const u = normUid(uid);
  if (!u || !m || typeof m !== "object") {
    return null;
  }
  const owner = normUid(m.owner_uid ?? m.ownerUid);
  if (owner === u) {
    return "owner";
  }
  const staff = Array.isArray(m.staff_uids) ? m.staff_uids.map((x) => normUid(x)) : [];
  if (!staff.includes(u)) {
    return null;
  }
  const roles = m.staff_roles != null && typeof m.staff_roles === "object" ? m.staff_roles : {};
  const r = roles[u];
  return r != null ? String(r) : "cashier";
}

/**
 * @param {Record<string, unknown> | null | undefined} m
 * @param {string} uid
 * @param {string[]} allowedRoles e.g. ["owner","manager"]
 */
function assertMerchantPortalAllowed(m, uid, allowedRoles) {
  const u = normUid(uid);
  const role = merchantPortalRole(m, u);
  if (!role) {
    return { ok: false, reason: "forbidden" };
  }
  const allow = new Set(allowedRoles.map((x) => String(x ?? "").trim().toLowerCase()));
  if (!allow.has(String(role).trim().toLowerCase())) {
    return { ok: false, reason: "role_forbidden" };
  }
  return { ok: true, role };
}

/**
 * Claim `owner_uid` on a merchant doc when it is empty or already matches uid.
 * @param {import("firebase-admin/firestore").Firestore} fs
 * @param {import("firebase-admin/firestore").DocumentReference} docRef
 * @param {string} uid
 */
async function claimMerchantOwnerUidIfEligible(fs, docRef, uid) {
  await fs.runTransaction(async (tx) => {
    const snap = await tx.get(docRef);
    const mm = snap.data() || {};
    const ou = rowOwnerUid(mm);
    if (ou && ou !== uid) return;
    tx.update(docRef, {
      owner_uid: uid,
      updated_at: FieldValue.serverTimestamp(),
    });
  });
}

/**
 * Resolve the Firestore merchant row for the signed-in merchant portal user.
 * Order: owner_uid, legacy ownerUid, then verified login email (contact_email) with safe claim.
 *
 * @param {import("firebase-admin/firestore").Firestore} fs
 * @param {import("firebase-functions").https.CallableContext} context
 * @returns {Promise<
 *   | { ok: true; ref: import("firebase-admin/firestore").DocumentReference; id: string; data: Record<string, unknown> }
 *   | { ok: false; reason: "unauthorized" | "not_found" | "ambiguous_multiple_merchants" }
 * >}
 */
async function resolveMerchantForMerchantAuth(fs, context) {
  const uid = normUid(context?.auth?.uid);
  if (!uid) {
    return { ok: false, reason: "unauthorized" };
  }

  const byOwner = await fs
    .collection("merchants")
    .where("owner_uid", "==", uid)
    .limit(1)
    .get();
  if (!byOwner.empty) {
    const doc = byOwner.docs[0];
    return { ok: true, ref: doc.ref, id: doc.id, data: doc.data() || {} };
  }

  const byOwnerCamel = await fs
    .collection("merchants")
    .where("ownerUid", "==", uid)
    .limit(1)
    .get();
  if (!byOwnerCamel.empty) {
    const doc = byOwnerCamel.docs[0];
    const m = doc.data() || {};
    if (!normUid(m.owner_uid)) {
      await doc.ref.update({
        owner_uid: uid,
        updated_at: FieldValue.serverTimestamp(),
      });
      const fr = await doc.ref.get();
      logger.info("MERCHANT_OWNER_BACKFILL", { merchantId: doc.id, uid });
      return { ok: true, ref: doc.ref, id: doc.id, data: fr.data() || {} };
    }
    return { ok: true, ref: doc.ref, id: doc.id, data: m };
  }

  const byStaff = await fs
    .collection("merchants")
    .where("staff_uids", "array-contains", uid)
    .limit(1)
    .get();
  if (!byStaff.empty) {
    const doc = byStaff.docs[0];
    return { ok: true, ref: doc.ref, id: doc.id, data: doc.data() || {} };
  }

  const authEmail = trimStr(context.auth?.token?.email, 200).toLowerCase();
  if (!authEmail) {
    return { ok: false, reason: "not_found" };
  }

  const qe = await fs
    .collection("merchants")
    .where("contact_email", "==", authEmail)
    .limit(25)
    .get();

  /** @type {import("firebase-admin/firestore").QueryDocumentSnapshot[]} */
  const candidates = [];
  for (const doc of qe.docs) {
    const m = doc.data() || {};
    const ou = rowOwnerUid(m);
    if (ou && ou !== uid) continue;
    candidates.push(doc);
  }

  if (candidates.length === 0) {
    return { ok: false, reason: "not_found" };
  }

  const finalize = (doc) => ({
    ok: /** @type {const} */ (true),
    ref: doc.ref,
    id: doc.id,
    data: doc.data() || {},
  });

  const mine = candidates.filter((d) => rowOwnerUid(d.data() || {}) === uid);
  if (mine.length === 1) {
    return finalize(mine[0]);
  }
  if (mine.length > 1) {
    logger.warn("MERCHANT_RESOLVE_AMBIGUOUS_OWNER", { uid, authEmail, count: mine.length });
    return { ok: false, reason: "ambiguous_multiple_merchants" };
  }

  const unclaimed = candidates.filter((d) => !rowOwnerUid(d.data() || {}));
  if (unclaimed.length === 1) {
    const doc = unclaimed[0];
    await claimMerchantOwnerUidIfEligible(fs, doc.ref, uid);
    const fr = await doc.ref.get();
    logger.info("MERCHANT_OWNER_CLAIM", { merchantId: doc.id, uid, authEmail });
    return { ok: true, ref: doc.ref, id: doc.id, data: fr.data() || {} };
  }
  if (unclaimed.length > 1) {
    logger.warn("MERCHANT_RESOLVE_AMBIGUOUS_UNCLAIMED", { uid, authEmail, count: unclaimed.length });
    return { ok: false, reason: "ambiguous_multiple_merchants" };
  }

  return { ok: false, reason: "not_found" };
}

async function loadDocumentsMap(fs, merchantId) {
  const snap = await docsCollection(fs, merchantId).get();
  /** @type {Record<string, Record<string, unknown>>} */
  const map = {};
  for (const d of snap.docs) {
    map[d.id] = d.data() || {};
  }
  return map;
}

function statusForType(documentsMap, documentType) {
  const row = documentsMap[documentType];
  if (!row) return "not_submitted";
  const s = String(row.status ?? "")
    .trim()
    .toLowerCase();
  if (DOCUMENT_STATUSES.has(s)) return s;
  return "not_submitted";
}

/**
 * Pure readiness computation for tests and runtime.
 * @param {Record<string, unknown>} merchantRow
 * @param {Record<string, Record<string, unknown>>} documentsMap
 */
function computeMerchantReadinessFromMaps(merchantRow, documentsMap) {
  const merchantStatus = String(
    merchantRow.merchant_status ?? merchantRow.status ?? "",
  )
    .trim()
    .toLowerCase();
  const paymentModel = String(merchantRow.payment_model ?? "subscription")
    .trim()
    .toLowerCase();
  const subscriptionStatus = String(
    merchantRow.subscription_status ?? "inactive",
  )
    .trim()
    .toLowerCase();
  const category = merchantRow.category;

  /** @type {Record<string, string>} */
  const documentStatuses = {};
  for (const t of DOCUMENT_TYPES) {
    documentStatuses[t] = statusForType(documentsMap, t);
  }

  const requiresOperatingLicense = categoryRequiresOperatingLicense(category);
  const missingRequirements = [];

  /**
   * @param {string} type
   * @param {string} label
   */
  const requireApproved = (type, label) => {
    const st = documentStatuses[type];
    if (st === "approved") return;
    if (st === "not_submitted") {
      missingRequirements.push(`${label} (${type}) is not submitted`);
    } else if (st === "pending") {
      missingRequirements.push(`${label} (${type}) is pending review`);
    } else if (st === "rejected" || st === "resubmission_required") {
      missingRequirements.push(
        `${label} (${type}) needs correction or resubmission`,
      );
    } else {
      missingRequirements.push(`${label} (${type}) must be approved`);
    }
  };

  requireApproved("owner_id", "Owner government ID");
  requireApproved("storefront_photo", "Storefront or business photo");
  if (requiresOperatingLicense) {
    requireApproved(
      "operating_license",
      "Food or pharmacy operating license",
    );
  }

  const allowed = missingRequirements.length === 0;

  let readableMessage;
  if (allowed) {
    readableMessage = requiresOperatingLicense
      ? "All required verification documents are approved (including operating license)."
      : "All required verification documents are approved.";
  } else if (missingRequirements.length === 1) {
    readableMessage = missingRequirements[0];
  } else {
    readableMessage = `Action required: ${missingRequirements.length} verification items remain: ${missingRequirements.join("; ")}`;
  }

  return {
    allowed,
    missingRequirements,
    documentStatuses,
    merchant_status: merchantStatus || "pending",
    payment_model: paymentModel || "subscription",
    subscription_status: subscriptionStatus || "inactive",
    readableMessage,
    requires_operating_license: requiresOperatingLicense,
  };
}

/**
 * @param {import("firebase-admin/firestore").Firestore} fs
 * @param {string} merchantId
 */
async function recomputeAndMirrorMerchantReadiness(fs, merchantId) {
  const mRef = fs.collection("merchants").doc(merchantId);
  const mSnap = await mRef.get();
  if (!mSnap.exists) return null;
  const m = mSnap.data() || {};
  const documentsMap = await loadDocumentsMap(fs, merchantId);
  const readiness = computeMerchantReadinessFromMaps(m, documentsMap);

  const reqTypes = ["owner_id", "storefront_photo"];
  if (readiness.requires_operating_license) reqTypes.push("operating_license");

  const anyRejectedReq = reqTypes.some((t) => {
    const s = readiness.documentStatuses[t];
    return s === "rejected" || s === "resubmission_required";
  });
  const anyPendingReq = reqTypes.some(
    (t) => readiness.documentStatuses[t] === "pending",
  );
  const anyMissingReq = reqTypes.some(
    (t) => readiness.documentStatuses[t] === "not_submitted",
  );

  let verificationStatus = "in_progress";
  if (anyRejectedReq) verificationStatus = "action_required";
  else if (anyMissingReq) verificationStatus = "incomplete";
  else if (readiness.allowed) verificationStatus = "docs_complete";
  else if (anyPendingReq) verificationStatus = "pending_review";
  else verificationStatus = "pending_review";

  await mRef.update({
    verification_status: verificationStatus,
    required_documents_complete: readiness.allowed,
    document_statuses: readiness.documentStatuses,
    readiness_missing_requirements: readiness.missingRequirements,
    verification_updated_at: FieldValue.serverTimestamp(),
    updated_at: FieldValue.serverTimestamp(),
  });

  return readiness;
}

/**
 * @param {string} merchantId
 */
async function getMerchantReadiness(merchantId) {
  const fs = admin.firestore();
  const mSnap = await fs.collection("merchants").doc(merchantId).get();
  if (!mSnap.exists) return null;
  const documentsMap = await loadDocumentsMap(fs, merchantId);
  return computeMerchantReadinessFromMaps(mSnap.data() || {}, documentsMap);
}

/**
 * @param {string} merchantId
 * @param {Record<string, unknown>} merchantPayload
 */
async function enrichAdminMerchantResponse(merchantId, merchantPayload) {
  const fs = admin.firestore();
  const readiness = await getMerchantReadiness(merchantId);
  const bucket = admin.storage().bucket();
  const snap = await docsCollection(fs, merchantId).get();
  const byId = new Map(snap.docs.map((d) => [d.id, d.data() || {}]));

  /** @type {unknown[]} */
  const verification_documents = [];
  for (const t of DOCUMENT_TYPES) {
    const row = byId.get(t);
    if (!row) {
      verification_documents.push({
        document_type: t,
        status: "not_submitted",
        storage_path: null,
        file_name: null,
        content_type: null,
        uploaded_at: null,
        reviewed_at: null,
        reviewed_by: null,
        admin_note: null,
        rejection_reason: null,
        download_url: null,
      });
      continue;
    }
    let downloadUrl = null;
    const sp = row.storage_path;
    if (sp && typeof sp === "string") {
      try {
        const [url] = await bucket.file(sp).getSignedUrl({
          action: "read",
          expires: Date.now() + 60 * 60 * 1000,
        });
        downloadUrl = url;
      } catch (_e) {
        downloadUrl = null;
      }
    }
    verification_documents.push(serializeDocRow(t, row, downloadUrl));
  }

  return {
    ...merchantPayload,
    readiness: readiness
      ? { ...readiness, documentStatuses: { ...readiness.documentStatuses } }
      : null,
    verification_documents,
  };
}

/**
 * @param {string} id
 * @param {Record<string, unknown>} row
 * @param {string | null} downloadUrl
 */
function serializeDocRow(id, row, downloadUrl) {
  return {
    document_type: id,
    status: String(row.status ?? "pending")
      .trim()
      .toLowerCase(),
    storage_path: row.storage_path != null ? String(row.storage_path) : null,
    file_name: row.file_name != null ? String(row.file_name) : null,
    content_type: row.content_type != null ? String(row.content_type) : null,
    uploaded_at: row.uploaded_at?.toMillis?.() ?? null,
    reviewed_at: row.reviewed_at?.toMillis?.() ?? null,
    reviewed_by: row.reviewed_by != null ? normUid(row.reviewed_by) : null,
    admin_note: row.admin_note != null ? String(row.admin_note) : null,
    rejection_reason:
      row.rejection_reason != null ? String(row.rejection_reason) : null,
    download_url: downloadUrl,
  };
}

/**
 * @param {object} data
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} _db
 */
async function merchantUploadVerificationDocument(data, context, _db) {
  const uid = normUid(context?.auth?.uid);
  if (!uid) {
    return { success: false, reason: "unauthorized" };
  }

  const fs = admin.firestore();
  const resolved = await resolveMerchantForMerchantAuth(fs, context);
  if (!resolved.ok) {
    return {
      success: false,
      reason:
        resolved.reason === "unauthorized"
          ? "unauthorized"
          : resolved.reason === "ambiguous_multiple_merchants"
            ? "ambiguous_multiple_merchants"
            : "not_found",
    };
  }
  const m0 = resolved.data || {};
  const gate = assertMerchantPortalAllowed(m0, uid, ["owner", "manager"]);
  if (!gate.ok) {
    return { success: false, reason: gate.reason };
  }
  const merchantRef = resolved.ref;
  const merchantId = resolved.id;

  const documentType = trimStr(
    data?.document_type ?? data?.documentType,
    64,
  ).toLowerCase();
  if (!DOCUMENT_TYPES.has(documentType)) {
    return { success: false, reason: "invalid_document_type" };
  }

  const storagePath = trimStr(data?.storage_path ?? data?.storagePath, 1024);
  const fileNameIn = trimStr(data?.file_name ?? data?.fileName, 256);
  const contentType = trimStr(
    data?.content_type ?? data?.contentType,
    128,
  ).toLowerCase();

  const prefix = `merchant_uploads/${merchantId}/verification/${documentType}/`;
  if (!storagePath.startsWith(prefix) || storagePath.includes("..")) {
    return { success: false, reason: "invalid_storage_path" };
  }
  const lastSeg = storagePath.slice(prefix.length);
  if (!lastSeg || lastSeg.includes("/")) {
    return { success: false, reason: "invalid_storage_path" };
  }

  if (
    !contentType ||
    (!contentType.startsWith("image/") && contentType !== "application/pdf")
  ) {
    return { success: false, reason: "invalid_content_type" };
  }

  const bucket = admin.storage().bucket();
  const file = bucket.file(storagePath);
  const [exists] = await file.exists();
  if (!exists) {
    return { success: false, reason: "storage_object_missing" };
  }

  const [meta] = await file.getMetadata();
  const size = Number(meta.size || 0);
  if (size <= 0 || size > 12 * 1024 * 1024) {
    return { success: false, reason: "invalid_file_size" };
  }

  const docRef = docsCollection(fs, merchantId).doc(documentType);
  const now = FieldValue.serverTimestamp();
  await docRef.set(
    {
      merchant_id: merchantId,
      document_type: documentType,
      status: "pending",
      storage_path: storagePath,
      file_name: fileNameIn || lastSeg,
      content_type: contentType,
      uploaded_at: now,
      reviewed_at: null,
      reviewed_by: null,
      admin_note: null,
      rejection_reason: null,
      updated_at: now,
    },
    { merge: true },
  );

  await recomputeAndMirrorMerchantReadiness(fs, merchantId);

  logger.info("MERCHANT_VERIFICATION_UPLOAD", { merchantId, documentType, uid });
  return {
    success: true,
    merchant_id: merchantId,
    document_type: documentType,
    status: "pending",
  };
}

/**
 * @param {object} _data
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} _db
 */
async function merchantListMyVerificationDocuments(_data, context, _db) {
  const uid = normUid(context?.auth?.uid);
  if (!uid) {
    return { success: false, reason: "unauthorized" };
  }
  const fs = admin.firestore();
  const resolved = await resolveMerchantForMerchantAuth(fs, context);
  if (!resolved.ok) {
    return {
      success: false,
      reason:
        resolved.reason === "unauthorized"
          ? "unauthorized"
          : resolved.reason === "ambiguous_multiple_merchants"
            ? "ambiguous_multiple_merchants"
            : "not_found",
    };
  }
  const merchantId = resolved.id;
  const bucket = admin.storage().bucket();
  const snap = await docsCollection(fs, merchantId).get();
  const byId = new Map(snap.docs.map((d) => [d.id, d.data() || {}]));

  const documents = [];
  for (const t of DOCUMENT_TYPES) {
    const row = byId.get(t);
    if (!row) {
      documents.push({
        document_type: t,
        status: "not_submitted",
        storage_path: null,
        file_name: null,
        content_type: null,
        uploaded_at: null,
        reviewed_at: null,
        reviewed_by: null,
        admin_note: null,
        rejection_reason: null,
        download_url: null,
      });
      continue;
    }
    let downloadUrl = null;
    const sp = row.storage_path;
    if (sp && typeof sp === "string") {
      try {
        const [url] = await bucket.file(sp).getSignedUrl({
          action: "read",
          expires: Date.now() + 60 * 60 * 1000,
        });
        downloadUrl = url;
      } catch (_e) {
        downloadUrl = null;
      }
    }
    documents.push(serializeDocRow(t, row, downloadUrl));
  }

  return { success: true, merchant_id: merchantId, documents };
}

/**
 * @param {object} data
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} db
 */
async function adminReviewMerchantDocument(data, context, db) {
  const denyRmd = await adminPerms.enforceCallable(db, context, "adminReviewMerchantDocument");
  if (denyRmd) return denyRmd;
  const adminUid = normUid(context.auth.uid);
  const merchantId = trimStr(data?.merchant_id ?? data?.merchantId, 128);
  const documentType = trimStr(
    data?.document_type ?? data?.documentType,
    64,
  ).toLowerCase();
  const action = trimStr(data?.action, 32).toLowerCase();
  const adminNote = trimStr(data?.admin_note ?? data?.note, 2000);
  const rejectionReason = trimStr(
    data?.rejection_reason ?? data?.rejectionReason,
    2000,
  );

  if (!merchantId || !DOCUMENT_TYPES.has(documentType)) {
    return { success: false, reason: "invalid_input" };
  }

  let nextStatus = "";
  if (action === "approve") nextStatus = "approved";
  else if (action === "reject") nextStatus = "rejected";
  else if (
    action === "require_resubmit" ||
    action === "resubmission_required"
  ) {
    nextStatus = "resubmission_required";
  } else {
    return { success: false, reason: "invalid_action" };
  }

  if (
    (nextStatus === "rejected" || nextStatus === "resubmission_required") &&
    !adminNote &&
    !rejectionReason
  ) {
    return { success: false, reason: "note_required" };
  }

  const fs = admin.firestore();
  const docRef = docsCollection(fs, merchantId).doc(documentType);
  const snap = await docRef.get();
  if (!snap.exists) {
    return { success: false, reason: "document_not_found" };
  }

  const now = FieldValue.serverTimestamp();
  await docRef.set(
    {
      status: nextStatus,
      reviewed_at: now,
      reviewed_by: adminUid,
      admin_note: adminNote || null,
      rejection_reason:
        nextStatus === "rejected" || nextStatus === "resubmission_required"
          ? rejectionReason || adminNote || null
          : null,
      updated_at: now,
    },
    { merge: true },
  );

  await recomputeAndMirrorMerchantReadiness(fs, merchantId);

  await db.ref("admin_audit_logs").push().set({
    type: "merchant_verification_document_review",
    merchant_id: merchantId,
    document_type: documentType,
    action,
    next_status: nextStatus,
    admin_uid: adminUid,
    created_at: Date.now(),
  });

  return {
    success: true,
    merchant_id: merchantId,
    document_type: documentType,
    status: nextStatus,
  };
}

/**
 * @param {object} data
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} db
 */
async function adminGetMerchantReadiness(data, context, db) {
  const denyGmr = await adminPerms.enforceCallable(db, context, "adminGetMerchantReadiness");
  if (denyGmr) return denyGmr;
  const merchantId = trimStr(data?.merchant_id ?? data?.merchantId, 128);
  if (!merchantId) {
    return { success: false, reason: "invalid_merchant_id" };
  }
  const snap = await admin.firestore().collection("merchants").doc(merchantId).get();
  if (!snap.exists) {
    return { success: false, reason: "not_found" };
  }
  const readiness = await getMerchantReadiness(merchantId);
  if (!readiness) {
    return { success: false, reason: "not_found" };
  }
  return {
    success: true,
    merchant_id: merchantId,
    ...readiness,
    documentStatuses: { ...readiness.documentStatuses },
  };
}

/**
 * @param {object} data
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} db
 */
async function adminRecomputeMerchantReadiness(data, context, db) {
  const denyRmr = await adminPerms.enforceCallable(db, context, "adminRecomputeMerchantReadiness");
  if (denyRmr) return denyRmr;
  const merchantId = trimStr(data?.merchant_id ?? data?.merchantId, 128);
  if (!merchantId) {
    return { success: false, reason: "invalid_merchant_id" };
  }
  const fs = admin.firestore();
  const snap = await fs.collection("merchants").doc(merchantId).get();
  if (!snap.exists) {
    return { success: false, reason: "not_found" };
  }
  const readiness = await recomputeAndMirrorMerchantReadiness(fs, merchantId);
  if (!readiness) {
    return { success: false, reason: "not_found" };
  }
  return {
    success: true,
    merchant_id: merchantId,
    ...readiness,
    documentStatuses: { ...readiness.documentStatuses },
  };
}

module.exports = {
  DOCUMENT_TYPES,
  DOCUMENT_STATUSES,
  categoryRequiresOperatingLicense,
  computeMerchantReadinessFromMaps,
  recomputeAndMirrorMerchantReadiness,
  getMerchantReadiness,
  enrichAdminMerchantResponse,
  merchantPortalRole,
  assertMerchantPortalAllowed,
  resolveMerchantForMerchantAuth,
  merchantUploadVerificationDocument,
  merchantListMyVerificationDocuments,
  adminReviewMerchantDocument,
  adminGetMerchantReadiness,
  adminRecomputeMerchantReadiness,
};
