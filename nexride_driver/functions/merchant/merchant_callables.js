/**
 * Merchant Phase 1 — registration + admin review only (no orders, menus, wallets).
 */

const admin = require("firebase-admin");
const { FieldValue } = require("firebase-admin/firestore");
const { logger } = require("firebase-functions");
const { isNexRideAdmin, normUid } = require("../admin_auth");

const MERCHANT_STATUSES = new Set(["pending", "approved", "rejected", "suspended"]);

function trimStr(v, max = 500) {
  return String(v ?? "")
    .trim()
    .slice(0, max);
}

function reviewActionToStatus(action) {
  const a = trimStr(action, 24).toLowerCase();
  if (a === "approve") return "approved";
  if (a === "reject") return "rejected";
  if (a === "suspend") return "suspended";
  return "";
}

/**
 * @param {import("firebase-admin/firestore").Firestore} fs
 * @param {string} ownerUid
 */
async function ownerHasBlockingMerchant(fs, ownerUid) {
  const uid = normUid(ownerUid);
  if (!uid) return null;
  const q = await fs.collection("merchants").where("owner_uid", "==", uid).limit(25).get();
  const block = new Set(["pending", "approved", "suspended"]);
  for (const doc of q.docs) {
    const st = String(doc.data()?.status ?? "").trim().toLowerCase();
    if (block.has(st)) return doc.id;
  }
  return null;
}

/**
 * @param {object} data
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} _db
 */
async function merchantRegister(data, context, _db) {
  const uid = normUid(context?.auth?.uid);
  if (!uid) {
    return { success: false, reason: "unauthorized" };
  }
  const businessName = trimStr(data?.business_name ?? data?.businessName, 200);
  if (businessName.length < 2) {
    return { success: false, reason: "invalid_business_name" };
  }
  const contactEmail = trimStr(data?.contact_email ?? data?.contactEmail, 200).toLowerCase();

  const fs = admin.firestore();
  const existingId = await ownerHasBlockingMerchant(fs, uid);
  if (existingId) {
    return {
      success: false,
      reason: "merchant_already_exists",
      merchant_id: existingId,
      message: "You already have a merchant profile or pending application.",
    };
  }

  const ref = fs.collection("merchants").doc();
  const merchantId = ref.id;
  const now = FieldValue.serverTimestamp();
  await ref.set({
    merchant_id: merchantId,
    owner_uid: uid,
    business_name: businessName,
    contact_email: contactEmail || null,
    status: "pending",
    created_at: now,
    updated_at: now,
    reviewed_at: null,
    reviewed_by: null,
    review_note: null,
  });

  logger.info("MERCHANT_REGISTER", { merchantId, owner_uid: uid });
  return { success: true, merchant_id: merchantId, status: "pending" };
}

/**
 * @param {object} data
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} db
 */
async function adminListMerchants(data, context, db) {
  if (!(await isNexRideAdmin(db, context))) {
    return { success: false, reason: "unauthorized" };
  }
  const statusFilter = trimStr(data?.status, 32).toLowerCase();
  const limit = Math.min(100, Math.max(1, Number(data?.limit ?? 50) || 50));
  const fs = admin.firestore();
  const fetchLimit = statusFilter && MERCHANT_STATUSES.has(statusFilter) ? Math.min(300, limit * 6) : limit;
  const snap = await fs.collection("merchants").orderBy("created_at", "desc").limit(fetchLimit).get();
  let merchants = snap.docs.map((d) => {
    const m = d.data() || {};
    return {
      merchant_id: d.id,
      owner_uid: normUid(m.owner_uid),
      business_name: String(m.business_name ?? ""),
      status: String(m.status ?? "").toLowerCase(),
      contact_email: m.contact_email != null ? String(m.contact_email) : null,
      created_at: m.created_at?.toMillis?.() ?? null,
      updated_at: m.updated_at?.toMillis?.() ?? null,
    };
  });
  if (statusFilter && MERCHANT_STATUSES.has(statusFilter)) {
    merchants = merchants.filter((row) => row.status === statusFilter).slice(0, limit);
  }
  return { success: true, merchants };
}

/**
 * @param {object} data
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} db
 */
async function adminGetMerchant(data, context, db) {
  if (!(await isNexRideAdmin(db, context))) {
    return { success: false, reason: "unauthorized" };
  }
  const merchantId = trimStr(data?.merchant_id ?? data?.merchantId, 128);
  if (!merchantId) {
    return { success: false, reason: "invalid_merchant_id" };
  }
  const snap = await admin.firestore().collection("merchants").doc(merchantId).get();
  if (!snap.exists) {
    return { success: false, reason: "not_found" };
  }
  const m = snap.data() || {};
  return {
    success: true,
    merchant: {
      merchant_id: snap.id,
      owner_uid: normUid(m.owner_uid),
      business_name: String(m.business_name ?? ""),
      status: String(m.status ?? ""),
      contact_email: m.contact_email != null ? String(m.contact_email) : null,
      created_at: m.created_at?.toMillis?.() ?? null,
      updated_at: m.updated_at?.toMillis?.() ?? null,
      reviewed_at: m.reviewed_at?.toMillis?.() ?? null,
      reviewed_by: m.reviewed_by != null ? normUid(m.reviewed_by) : null,
      review_note: m.review_note != null ? String(m.review_note) : null,
    },
  };
}

/**
 * @param {object} data
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} db
 */
async function adminReviewMerchant(data, context, db) {
  if (!(await isNexRideAdmin(db, context))) {
    return { success: false, reason: "unauthorized" };
  }
  const adminUid = normUid(context.auth.uid);
  const merchantId = trimStr(data?.merchant_id ?? data?.merchantId, 128);
  const action = trimStr(data?.action, 24).toLowerCase();
  const note = trimStr(data?.note ?? data?.review_note, 2000);
  if (!merchantId) {
    return { success: false, reason: "invalid_merchant_id" };
  }
  const nextStatus = reviewActionToStatus(action);
  if (!nextStatus) {
    return { success: false, reason: "invalid_action" };
  }

  const ref = admin.firestore().collection("merchants").doc(merchantId);
  const snap = await ref.get();
  if (!snap.exists) {
    return { success: false, reason: "not_found" };
  }

  const now = FieldValue.serverTimestamp();
  await ref.update({
    status: nextStatus,
    updated_at: now,
    reviewed_at: now,
    reviewed_by: adminUid,
    review_note: note || null,
  });

  await db.ref("admin_audit_logs").push().set({
    type: "merchant_review",
    merchant_id: merchantId,
    action,
    next_status: nextStatus,
    admin_uid: adminUid,
    created_at: Date.now(),
  });

  logger.info("MERCHANT_REVIEW", { merchantId, action, nextStatus, adminUid });
  return { success: true, merchant_id: merchantId, status: nextStatus };
}

module.exports = {
  merchantRegister,
  adminListMerchants,
  adminGetMerchant,
  adminReviewMerchant,
  /** @internal unit tests */
  reviewActionToStatus,
};
