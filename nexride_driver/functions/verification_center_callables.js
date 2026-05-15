/**
 * Phase 2D — Unified admin verification center (merchants + drivers + riders).
 */

const admin = require("firebase-admin");
const { logger } = require("firebase-functions");
const { getStorage } = require("firebase-admin/storage");
const { normUid } = require("./admin_auth");
const adminPerms = require("./admin_permissions");
const merchantVerification = require("./merchant/merchant_verification");
const adminCallables = require("./admin_callables");
const productionOps = require("./production_ops_callables");
const { writeAdminAuditLog } = require("./admin_audit_log");

const firestore = () => admin.firestore();

function trim(v, max = 500) {
  return String(v ?? "")
    .trim()
    .slice(0, max);
}

function merchantDocsCollection(fs, merchantId) {
  return fs.collection("merchant_verification_documents").doc(merchantId).collection("documents");
}

/**
 * @param {string} raw
 */
function normalizeMerchantDocStatus(raw) {
  const s = String(raw ?? "")
    .trim()
    .toLowerCase();
  if (s === "approved") return "approved";
  if (s === "rejected") return "rejected";
  if (s === "resubmission_required") return "resubmission_required";
  if (s === "pending") return "pending";
  if (s === "not_submitted") return "not_submitted";
  return "pending";
}

/**
 * @param {Record<string, unknown>} row
 */
function normalizeDriverDocStatus(row) {
  const status = String(row?.status ?? "")
    .trim()
    .toLowerCase();
  const result = String(row?.result ?? "")
    .trim()
    .toLowerCase();
  if (result === "resubmission_required" || status === "resubmission_required") {
    return "resubmission_required";
  }
  if (status === "approved" || result === "approved") return "approved";
  if (status === "rejected" || result === "rejected") return "rejected";
  if (
    status === "submitted" ||
    result === "awaiting_review" ||
    result === "pending" ||
    status === "pending"
  ) {
    return "pending";
  }
  if (status === "missing" || !status) return "not_submitted";
  return "pending";
}

/**
 * @param {string} st
 * @param {string} filter
 */
function matchesStatusFilter(st, filter) {
  const f = String(filter ?? "all")
    .trim()
    .toLowerCase();
  if (f === "all") return true;
  if (f === "pending") return st === "pending";
  if (f === "approved") return st === "approved";
  if (f === "rejected") return st === "rejected";
  if (f === "resubmission_required") return st === "resubmission_required";
  return true;
}

async function signedReadUrl(storagePath) {
  const p = trim(storagePath, 500);
  if (!p) return null;
  try {
    const bucket = getStorage().bucket();
    const [url] = await bucket.file(p).getSignedUrl({
      action: "read",
      expires: Date.now() + 20 * 60 * 1000,
    });
    return url;
  } catch (e) {
    logger.warn("verification_center_signed_url_failed", { path: p, err: String(e?.message || e) });
    return null;
  }
}

function msFromUnknown(v) {
  if (v == null) return 0;
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "object" && typeof v.toMillis === "function") {
    try {
      return v.toMillis();
    } catch {
      return 0;
    }
  }
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

/**
 * @param {unknown} val
 * @returns {Array<{ driverId: string; documentType: string; row: Record<string, unknown> }>}
 */
function flattenDriverDocuments(val) {
  const out = [];
  if (!val || typeof val !== "object") return out;
  for (const [driverId, docs] of Object.entries(val)) {
    if (!docs || typeof docs !== "object") continue;
    for (const [documentType, raw] of Object.entries(docs)) {
      if (!raw || typeof raw !== "object") continue;
      out.push({
        driverId,
        documentType,
        row: /** @type {Record<string, unknown>} */ (raw),
      });
    }
  }
  return out;
}

function pickIdentityStoragePath(data) {
  if (!data || typeof data !== "object") return null;
  const keys = [
    "selfie_storage_path",
    "id_front_storage_path",
    "id_back_storage_path",
    "license_storage_path",
    "storage_path",
    "path",
  ];
  for (const k of keys) {
    const v = data[k];
    if (typeof v === "string" && v.length > 4 && !v.startsWith("http")) return v.trim();
  }
  const p = data.payload;
  if (p && typeof p === "object") {
    for (const [k, v] of Object.entries(p)) {
      if (
        typeof v === "string" &&
        v.length > 4 &&
        !v.startsWith("http") &&
        (k.toLowerCase().includes("path") || k.toLowerCase().includes("storage"))
      ) {
        return v.trim();
      }
    }
  }
  return null;
}

function normalizeRiderIdentityStatus(raw) {
  const s = String(raw ?? "")
    .trim()
    .toLowerCase();
  if (s === "approved") return "approved";
  if (s === "rejected") return "rejected";
  if (s === "resubmission_required" || s === "resubmit" || s === "action_required") {
    return "resubmission_required";
  }
  if (!s || s === "pending" || s === "submitted" || s === "in_review") return "pending";
  return "pending";
}

/**
 * @param {object} data
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} db
 */
async function adminListVerificationUploads(data, context, db) {
  const denyLvu = await adminPerms.enforceCallable(db, context, "adminListVerificationUploads");
  if (denyLvu) return denyLvu;
  const userType = trim(data?.userType ?? data?.user_type ?? "all", 32).toLowerCase();
  const statusFilter = trim(data?.status ?? "pending", 32).toLowerCase();
  const limit = Math.min(300, Math.max(1, Number(data?.limit ?? 120) || 120));

  /** @type {unknown[]} */
  const rows = [];
  const want = (t) => userType === "all" || userType === t;

  const fs = firestore();
  const bucket = getStorage().bucket();

  /** @type {Map<string, Record<string, unknown>>} */
  const driverProfileCache = new Map();

  async function driverProfile(driverId) {
    if (driverProfileCache.has(driverId)) return driverProfileCache.get(driverId) || {};
    const snap = await db.ref(`drivers/${driverId}`).get();
    const v = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
    driverProfileCache.set(driverId, v);
    return v;
  }

  if (want("merchant")) {
    const mq = await fs.collection("merchants").limit(80).get();
    for (const md of mq.docs) {
      const merchantId = md.id;
      const m = md.data() || {};
      let readinessSummary = "";
      try {
        const readiness = await merchantVerification.getMerchantReadiness(merchantId);
        if (readiness) {
          readinessSummary = readiness.allowed
            ? "Ready for merchant approval"
            : String(readiness.readableMessage || "").trim();
        }
      } catch (_e) {
        readinessSummary = "";
      }
      const dsnap = await merchantDocsCollection(fs, merchantId).get();
      for (const d of dsnap.docs) {
        const documentType = d.id;
        const row = d.data() || {};
        const st = normalizeMerchantDocStatus(row.status);
        if (!matchesStatusFilter(st, statusFilter)) continue;
        const storagePath =
          row.storage_path != null ? String(row.storage_path).trim() : "";
        let signedUrl = null;
        if (storagePath) {
          try {
            const [url] = await bucket.file(storagePath).getSignedUrl({
              action: "read",
              expires: Date.now() + 20 * 60 * 1000,
            });
            signedUrl = url;
          } catch (_e) {
            signedUrl = null;
          }
        }
        const adminNote = [row.admin_note, row.rejection_reason]
          .map((x) => (x != null ? String(x).trim() : ""))
          .filter(Boolean)
          .join(" · ");
        rows.push({
          user_type: "merchant",
          user_id: merchantId,
          merchant_id: merchantId,
          display_name: String(m.business_name ?? m.businessName ?? merchantId).trim() || merchantId,
          email: String(m.contact_email ?? m.contactEmail ?? "").trim(),
          phone: String(m.phone ?? "").trim(),
          document_type: documentType,
          status: st,
          storage_path: storagePath || null,
          signed_url: signedUrl,
          uploaded_at: msFromUnknown(row.uploaded_at),
          reviewed_at: msFromUnknown(row.reviewed_at),
          admin_note: adminNote || null,
          readiness_summary: readinessSummary || null,
        });
      }
    }
  }

  if (want("driver")) {
    let tree = null;
    try {
      const snap = await db.ref("driver_documents").get();
      tree = snap.val();
    } catch (e) {
      logger.warn("driver_documents_read_failed", { err: String(e?.message || e) });
      tree = null;
    }
    const flat = flattenDriverDocuments(tree);
    for (const item of flat) {
      const { driverId, documentType, row } = item;
      const st = normalizeDriverDocStatus(row);
      if (!matchesStatusFilter(st, statusFilter)) continue;
      const prof = await driverProfile(driverId);
      const storagePath = trim(
        row.reference ?? row.fileReference ?? row.storage_path ?? row.storagePath,
        500,
      );
      const signedUrl = storagePath ? await signedReadUrl(storagePath) : null;
      const adminNote = trim(row.reviewNote ?? row.review_note ?? row.failureReason ?? "", 2000);
      rows.push({
        user_type: "driver",
        user_id: driverId,
        merchant_id: null,
        display_name: String(prof.name ?? prof.displayName ?? driverId).trim() || driverId,
        email: String(prof.email ?? "").trim(),
        phone: String(prof.phone ?? "").trim(),
        document_type: documentType,
        status: st,
        storage_path: storagePath || null,
        signed_url: signedUrl,
        uploaded_at: msFromUnknown(row.submittedAt ?? row.submitted_at ?? row.createdAt ?? row.created_at),
        reviewed_at: msFromUnknown(row.reviewedAt ?? row.reviewed_at),
        admin_note: adminNote || null,
        readiness_summary: null,
      });
    }
  }

  if (want("rider")) {
    /** @type {import("firebase-admin/firestore").QueryDocumentSnapshot[]} */
    let ivDocs = [];
    try {
      ivDocs = (await fs.collection("identity_verifications").limit(120).get()).docs;
    } catch (e) {
      logger.warn("identity_verifications_read_failed", { err: String(e?.message || e) });
    }
    for (const doc of ivDocs) {
      const uid = doc.id;
      const data = doc.data() || {};
      const ut = String(data.user_type ?? data.userType ?? "")
        .trim()
        .toLowerCase();
      if (ut && ut !== "rider") continue;
      const st = normalizeRiderIdentityStatus(data.status);
      if (!matchesStatusFilter(st, statusFilter)) continue;
      const storagePath = pickIdentityStoragePath(data);
      const signedUrl = storagePath ? await signedReadUrl(storagePath) : null;
      rows.push({
        user_type: "rider",
        user_id: uid,
        merchant_id: null,
        display_name: String(data.display_name ?? data.displayName ?? uid).trim() || uid,
        email: String(data.email ?? "").trim(),
        phone: String(data.phone ?? "").trim(),
        document_type: "identity_verification",
        status: st,
        storage_path: storagePath,
        signed_url: signedUrl,
        uploaded_at: msFromUnknown(data.updated_at ?? data.last_client_sync_at ?? data.created_at),
        reviewed_at: msFromUnknown(data.reviewed_at),
        admin_note: trim(data.review_note ?? data.note ?? "", 2000) || null,
        readiness_summary: null,
      });
    }

    try {
      const uq = await fs
        .collection("users")
        .where("verificationStatus", "==", "pending_review")
        .limit(60)
        .get();
      for (const ud of uq.docs) {
        const uid = ud.id;
        const u = ud.data() || {};
        const st = "pending";
        if (!matchesStatusFilter(st, statusFilter)) continue;
        const storagePath = `user_verification/${uid}/selfie.jpg`;
        const signedUrl = await signedReadUrl(storagePath);
        rows.push({
          user_type: "rider",
          user_id: uid,
          merchant_id: null,
          display_name: String(u.displayName ?? u.display_name ?? uid).trim() || uid,
          email: String(u.email ?? "").trim(),
          phone: String(u.phone ?? "").trim(),
          document_type: "rider_selfie",
          status: st,
          storage_path: storagePath,
          signed_url: signedUrl,
          uploaded_at: msFromUnknown(u.selfieSubmittedAt ?? u.selfie_submitted_at),
          reviewed_at: null,
          admin_note: null,
          readiness_summary: null,
        });
      }
    } catch (e) {
      logger.warn("rider_selfie_pending_query_failed", { err: String(e?.message || e) });
    }
  }

  rows.sort((a, b) => (b.uploaded_at || 0) - (a.uploaded_at || 0));
  const trimmed = rows.slice(0, limit);

  return {
    success: true,
    rows: trimmed,
    meta: { userType, statusFilter, limit, count: trimmed.length },
  };
}

/**
 * @param {object} data
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} db
 */
async function adminReviewDriverDocument(data, context, db) {
  const denyRdd = await adminPerms.enforceCallable(db, context, "adminReviewDriverDocument");
  if (denyRdd) return denyRdd;
  const adminUid = normUid(context.auth.uid);
  const driverId = normUid(data?.driver_id ?? data?.driverId ?? data?.user_id);
  const documentType = trim(data?.document_type ?? data?.documentType, 120);
  const action = trim(data?.action, 32).toLowerCase();
  const note = trim(data?.note ?? data?.admin_note ?? data?.rejection_reason, 2000);
  if (!driverId || !documentType) {
    return { success: false, reason: "invalid_input" };
  }
  if (action !== "approve" && action !== "reject" && action !== "require_resubmit") {
    return { success: false, reason: "invalid_action" };
  }
  if ((action === "reject" || action === "require_resubmit") && note.length < 2) {
    return { success: false, reason: "note_required" };
  }

  const docRef = db.ref(`driver_documents/${driverId}/${documentType}`);
  const snap = await docRef.get();
  if (!snap.exists()) {
    return { success: false, reason: "document_not_found" };
  }
  const prev = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  const now = Date.now();
  let nextStatus = "submitted";
  let nextResult = "awaiting_review";
  if (action === "approve") {
    nextStatus = "approved";
    nextResult = "approved";
  } else if (action === "reject") {
    nextStatus = "rejected";
    nextResult = "rejected";
  } else {
    nextStatus = "rejected";
    nextResult = "resubmission_required";
  }

  const patch = {
    ...prev,
    status: nextStatus,
    result: nextResult,
    reviewedAt: now,
    reviewedBy: adminUid,
    reviewNote: note || null,
    failureReason: action === "approve" ? "" : note,
    updatedAt: now,
  };

  const updates = {
    [`driver_documents/${driverId}/${documentType}`]: patch,
    [`drivers/${driverId}/verification/documents/${documentType}`]: patch,
    [`drivers/${driverId}/updated_at`]: now,
    [`driver_verifications/${driverId}/updatedAt`]: now,
  };

  await db.ref().update(updates);
  await writeAdminAuditLog(db, {
    actor_uid: adminUid,
    action:
      action === "approve"
        ? "approve_verification"
        : action === "reject"
          ? "reject_verification"
          : "verification_document_review",
    entity_type: "driver",
    entity_id: driverId,
    before: { status: prev.status, result: prev.result },
    after: { status: nextStatus, result: nextResult, documentType: documentType },
    reason: note || null,
    source: "verification_center.adminReviewDriverDocument",
    type: "driver_verification_document_review",
    created_at: now,
  });

  return { success: true, driver_id: driverId, document_type: documentType, status: nextStatus };
}

/**
 * @param {object} data
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} db
 */
async function adminListDriverVerificationDocuments(data, context, db) {
  const denyLdvd = await adminPerms.enforceCallable(db, context, "adminListDriverVerificationDocuments");
  if (denyLdvd) return denyLdvd;
  const driverId = normUid(data?.driver_id ?? data?.driverId);
  if (!driverId) return { success: false, reason: "invalid_driver_id" };
  let val = null;
  try {
    const snap = await db.ref(`driver_documents/${driverId}`).get();
    val = snap.val();
  } catch (_e) {
    val = null;
  }
  const docs = [];
  if (val && typeof val === "object") {
    for (const [k, raw] of Object.entries(val)) {
      if (!raw || typeof raw !== "object") continue;
      docs.push({ document_type: k, ...(typeof raw === "object" ? raw : {}) });
    }
  }
  return { success: true, driver_id: driverId, documents: docs };
}

/**
 * @param {object} data
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} db
 */
async function adminReviewRiderDocument(data, context, db) {
  const denyRrd = await adminPerms.enforceCallable(db, context, "adminReviewRiderDocument");
  if (denyRrd) return denyRrd;
  const uid = normUid(data?.user_id ?? data?.userId ?? data?.rider_id ?? data?.riderId);
  const documentType = trim(data?.document_type ?? data?.documentType, 120).toLowerCase();
  const action = trim(data?.action, 32).toLowerCase();
  const note = trim(data?.note ?? data?.admin_note ?? data?.rejection_reason, 2000);
  if (!uid) return { success: false, reason: "invalid_input" };
  if (action !== "approve" && action !== "reject" && action !== "require_resubmit") {
    return { success: false, reason: "invalid_action" };
  }
  if ((action === "reject" || action === "require_resubmit") && note.length < 2) {
    return { success: false, reason: "note_required" };
  }

  if (documentType === "rider_selfie" || documentType === "selfie") {
    const decision = action === "approve" ? "approved" : "rejected";
    const rejectionReason =
      action === "approve"
        ? ""
        : action === "require_resubmit"
          ? `Resubmission required: ${note}`
          : note;
    if (decision === "rejected" && rejectionReason.length < 8) {
      return { success: false, reason: "rejection_reason_required" };
    }
    return adminCallables.adminReviewRiderFirestoreIdentity(
      { riderId: uid, decision, rejectionReason },
      context,
      db,
    );
  }

  const decision =
    action === "approve"
      ? "approved"
      : action === "reject"
        ? "rejected"
        : "resubmission_required";
  return productionOps.adminReviewIdentityVerification({ uid, decision, note }, context, db);
}

/**
 * @param {object} data
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} db
 */
async function adminListRiderVerificationDocuments(data, context, db) {
  const denyLrvd = await adminPerms.enforceCallable(db, context, "adminListRiderVerificationDocuments");
  if (denyLrvd) return denyLrvd;
  const riderId = normUid(data?.rider_id ?? data?.riderId ?? data?.user_id);
  if (!riderId) return { success: false, reason: "invalid_rider_id" };
  const fs = firestore();
  const [idSnap, uSnap] = await Promise.all([
    fs.collection("identity_verifications").doc(riderId).get(),
    fs.collection("users").doc(riderId).get(),
  ]);
  return {
    success: true,
    rider_id: riderId,
    identity_verification: idSnap.exists ? idSnap.data() : null,
    firestore_user: uSnap.exists ? uSnap.data() : null,
  };
}

module.exports = {
  adminListVerificationUploads,
  adminReviewDriverDocument,
  adminListDriverVerificationDocuments,
  adminReviewRiderDocument,
  adminListRiderVerificationDocuments,
  flattenDriverDocuments,
  normalizeDriverDocStatus,
  matchesStatusFilter,
};
