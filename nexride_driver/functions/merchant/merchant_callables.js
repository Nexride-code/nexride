/**
 * Merchant Phase 1 — registration + admin review only (no orders, menus, wallets).
 */

const admin = require("firebase-admin");
const { FieldValue } = require("firebase-admin/firestore");
const { logger } = require("firebase-functions");
const { normUid } = require("../admin_auth");
const adminPerms = require("../admin_permissions");
const merchantVerification = require("./merchant_verification");
const { notifyMerchantApproval } = require("./merchant_approval_notify");
const { writeAdminAuditLog } = require("../admin_audit_log");

const MERCHANT_STATUSES = new Set([
  "pending",
  "pending_review",
  "approved",
  "rejected",
  "suspended",
]);

const PAYMENT_MODELS = new Set(["subscription", "commission"]);

const SUBSCRIPTION_STATUSES = new Set([
  "inactive",
  "pending_payment",
  "under_review",
  "active",
  "expired",
  "rejected",
]);

function trimStr(v, max = 500) {
  return String(v ?? "")
    .trim()
    .slice(0, max);
}

function reviewActionToStatus(action) {
  const a = trimStr(action, 24).toLowerCase();
  if (a === "approve" || a === "reactivate") return "approved";
  if (a === "reject") return "rejected";
  if (a === "suspend") return "suspended";
  return "";
}

function normalizePaymentModel(v) {
  const m = trimStr(v, 40).toLowerCase();
  if (PAYMENT_MODELS.has(m)) return m;
  return "";
}

function normalizeSubscriptionStatus(v) {
  const s = trimStr(v, 40).toLowerCase();
  // Accept UI-friendly aliases (e.g. "pending payment") by normalizing spaces to underscores.
  const normalized = s.replaceAll(" ", "_");
  if (SUBSCRIPTION_STATUSES.has(normalized)) return normalized;
  return "";
}

function computeCanonicalPaymentModelFields(paymentModel) {
  if (paymentModel === "subscription") {
    return {
      payment_model: "subscription",
      commission_exempt: true,
      commission_rate: 0,
      withdrawal_percent: 1.0,
      subscription_amount: 25000,
      subscription_currency: "NGN",
    };
  }

  // Commission model (default)
  return {
    payment_model: "commission",
    commission_exempt: false,
    commission_rate: 0.1,
    withdrawal_percent: 0.9,
    subscription_amount: 0,
    subscription_currency: "NGN",
  };
}

function computeInitialSubscriptionStatusForPaymentModel(paymentModel) {
  if (paymentModel === "subscription") return "pending_payment";
  return "inactive";
}

function initialMerchantStatus() {
  return "pending_review";
}

/**
 * Whitelist updates for merchant-owned profile fields (callable-only writes).
 * Ignores any attempt to change financial / approval fields.
 * @param {object} data
 * @returns {Record<string, unknown>}
 */
function buildMerchantOwnerProfileUpdate(data) {
  /** @type {Record<string, unknown>} */
  const patch = {};
  const businessName = trimStr(data?.business_name ?? data?.businessName, 200);
  if (businessName.length >= 2) {
    patch.business_name = businessName;
  }
  const contactEmail = trimStr(data?.contact_email ?? data?.contactEmail, 200).toLowerCase();
  if (contactEmail.length > 0) {
    patch.contact_email = contactEmail;
  }
  const regionId = trimStr(data?.region_id ?? data?.regionId, 80);
  if (regionId) {
    patch.region_id = regionId;
  }
  const cityId = trimStr(data?.city_id ?? data?.cityId, 120);
  if (cityId) {
    patch.city_id = cityId;
  }
  const phone = trimStr(data?.phone ?? data?.phoneNumber, 40);
  if (phone) {
    patch.phone = phone;
  }
  const ownerName = trimStr(data?.owner_name ?? data?.ownerName, 120);
  if (ownerName.length >= 2) {
    patch.owner_name = ownerName;
  }
  const category = trimStr(data?.category ?? data?.business_category, 80);
  if (category.length >= 2) {
    patch.category = category;
  }
  const address = trimStr(data?.address ?? data?.business_address, 500);
  if (address.length >= 4) {
    patch.address = address;
  }
  const businessType = trimStr(
    data?.business_type ?? data?.businessType ?? data?.store_type,
    64,
  );
  if (businessType.length >= 2) {
    patch.business_type = businessType;
  }
  const regNo = trimStr(
    data?.business_registration_number ??
      data?.businessRegistrationNumber ??
      data?.cac_registration_number ??
      data?.cacRegistrationNumber,
    80,
  );
  if (regNo.length > 0) {
    patch.business_registration_number = regNo;
  }
  const plat = Number(data?.pickup_lat ?? data?.pickupLat);
  const plng = Number(data?.pickup_lng ?? data?.pickupLng);
  if (Number.isFinite(plat) && Number.isFinite(plng)) {
    patch.pickup_lat = plat;
    patch.pickup_lng = plng;
  }
  const storeDescription = trimStr(
    data?.store_description ??
      data?.storeDescription ??
      data?.business_description ??
      data?.description,
    4000,
  );
  if (storeDescription.length > 0) {
    patch.store_description = storeDescription;
  }
  const openingHours = trimStr(
    data?.opening_hours ?? data?.openingHours ?? data?.hours_text ?? data?.store_hours,
    8000,
  );
  if (openingHours.length > 0) {
    patch.opening_hours = openingHours;
  }
  return patch;
}

function applyCanonicalPaymentFields(merchant, paymentModel, { setSubscriptionStatus } = {}) {
  const pm = normalizePaymentModel(paymentModel) || "subscription";
  const canonical = computeCanonicalPaymentModelFields(pm);
  const next = {
    ...merchant,
    ...canonical,
  };

  // Only overwrite subscription_status when explicitly requested (e.g. switching payment model).
  if (setSubscriptionStatus === true) {
    next.subscription_status = computeInitialSubscriptionStatusForPaymentModel(pm);
  } else if (next.subscription_status == null) {
    next.subscription_status = computeInitialSubscriptionStatusForPaymentModel(pm);
  }

  return next;
}

/**
 * @param {import("firebase-admin/firestore").Firestore} fs
 * @param {string} ownerUid
 */
function merchantRowOwnerUid(m) {
  return normUid(m?.owner_uid ?? m?.ownerUid);
}

/**
 * @param {import("firebase-admin/firestore").Firestore} fs
 * @param {string} ownerUid
 * @param {string[]} emailHints Lowercased emails (auth + form contact) to detect unclaimed duplicates.
 */
async function ownerHasBlockingMerchant(fs, ownerUid, emailHints = []) {
  const uid = normUid(ownerUid);
  if (!uid) return null;
  const block = new Set(["pending", "pending_review", "approved", "suspended", "rejected"]);

  const q = await fs.collection("merchants").where("owner_uid", "==", uid).limit(25).get();
  for (const doc of q.docs) {
    const d = doc.data() || {};
    const st =
      String(d.merchant_status ?? d.status ?? "")
        .trim()
        .toLowerCase();
    if (block.has(st)) return doc.id;
  }

  const qCamel = await fs.collection("merchants").where("ownerUid", "==", uid).limit(25).get();
  for (const doc of qCamel.docs) {
    const d = doc.data() || {};
    const st =
      String(d.merchant_status ?? d.status ?? "")
        .trim()
        .toLowerCase();
    if (block.has(st)) return doc.id;
  }

  const hintSet = new Set(
    (emailHints || [])
      .map((e) => trimStr(e, 200).toLowerCase())
      .filter(Boolean),
  );
  for (const em of hintSet) {
    const qe = await fs.collection("merchants").where("contact_email", "==", em).limit(25).get();
    for (const doc of qe.docs) {
      const d = doc.data() || {};
      const ou = merchantRowOwnerUid(d);
      if (ou && ou !== uid) continue;
      const st =
        String(d.merchant_status ?? d.status ?? "")
          .trim()
          .toLowerCase();
      if (block.has(st)) return doc.id;
    }
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
  const paymentModel =
    normalizePaymentModel(data?.payment_model ?? data?.paymentModel) ||
    "subscription";
  const rawBusinessType = trimStr(
    data?.business_type ?? data?.businessType ?? data?.store_type,
    64,
  ).toLowerCase();
  const allowedBusinessTypes = new Set([
    "restaurant",
    "grocery",
    "mart",
    "grocery_mart",
    "pharmacy",
    "other",
  ]);
  const businessTypeStored = allowedBusinessTypes.has(rawBusinessType)
    ? rawBusinessType
    : "other";
  const registrationNumber = trimStr(
    data?.business_registration_number ??
      data?.businessRegistrationNumber ??
      data?.cac_registration_number ??
      data?.cacRegistrationNumber,
    80,
  );

  const fs = admin.firestore();
  const authEmail = trimStr(context.auth?.token?.email, 200).toLowerCase();
  const existingId = await ownerHasBlockingMerchant(fs, uid, [authEmail, contactEmail]);
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
  const canonical = computeCanonicalPaymentModelFields(paymentModel);
  const initialSubscriptionStatus =
    computeInitialSubscriptionStatusForPaymentModel(paymentModel);
  await ref.set({
    merchant_id: merchantId,
    owner_uid: uid,
    created_by: uid,
    business_name: businessName,
    contact_email: contactEmail || null,
    // Canonical merchant workflow fields
    merchant_status: initialMerchantStatus(),
    status: initialMerchantStatus(), // Backward compat for older clients/UI
    payment_model: canonical.payment_model,
    subscription_amount: canonical.subscription_amount,
    subscription_currency: canonical.subscription_currency,
    subscription_status: initialSubscriptionStatus,
    commission_rate: canonical.commission_rate,
    commission_exempt: canonical.commission_exempt,
    withdrawal_percent: canonical.withdrawal_percent,

    // Optional merchant profile fields (Phase 1 — admin can display placeholders)
    region_id: trimStr(data?.region_id ?? data?.regionId, 80) || null,
    city_id: trimStr(data?.city_id ?? data?.cityId, 120) || null,
    phone: trimStr(data?.phone ?? data?.phoneNumber, 40) || null,
    owner_name: trimStr(data?.owner_name ?? data?.ownerName, 120) || null,
    category: trimStr(data?.category ?? data?.business_category, 80) || null,
    address: trimStr(data?.address ?? data?.business_address, 500) || null,

    // Admin metadata
    admin_note: null,
    approved_at: null,
    approved_by: null,

    created_at: now,
    updated_at: now,
    reviewed_at: null,
    reviewed_by: null,
    review_note: null,

    // Phase 2B — verification summary (mirrored from documents subcollection)
    verification_status: "incomplete",
    required_documents_complete: false,
    document_statuses: {},
    readiness_missing_requirements: [],

    business_type: businessTypeStored,
    business_registration_number: registrationNumber || null,

    // Availability (merchants go online only after approval + explicit toggle in app).
    is_open: false,
    accepting_orders: false,
    availability_status: "closed",
    closed_reason: null,
  });

  await merchantVerification.recomputeAndMirrorMerchantReadiness(fs, merchantId);

  logger.info("MERCHANT_REGISTER", { merchantId, owner_uid: uid });
  if (_db) {
    try {
      const { syncMerchantPublicTeaserFromMerchantId } = require("../merchant_public_sync");
      await syncMerchantPublicTeaserFromMerchantId(_db, merchantId);
    } catch (e) {
      logger.warn("MERCHANT_REGISTER_TEASER_SYNC_FAILED", { err: String(e?.message || e), merchantId });
    }
  }
  return { success: true, merchant_id: merchantId, status: initialMerchantStatus() };
}

/**
 * Normalize legacy availability_status values for API clients.
 * @param {Record<string, unknown>} m
 */
function availabilityStatusForClient(m) {
  const s = String(m.availability_status ?? "")
    .trim()
    .toLowerCase();
  if (s === "online") return "open";
  if (s === "offline") return "closed";
  if (s === "open" || s === "closed" || s === "paused") return s;
  return s || null;
}

/**
 * Merchant: read own merchant row (resolved via owner_uid, legacy ownerUid, or contact_email claim).
 * @param {object} _data
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} _db
 */
async function merchantGetMyMerchant(_data, context, _db) {
  const fs = admin.firestore();
  const resolved = await merchantVerification.resolveMerchantForMerchantAuth(fs, context);
  if (!resolved.ok) {
    if (resolved.reason === "unauthorized") {
      return { success: false, reason: "unauthorized" };
    }
    if (resolved.reason === "ambiguous_multiple_merchants") {
      return { success: false, reason: "ambiguous_multiple_merchants" };
    }
    return { success: false, reason: "not_found" };
  }
  const snap = await resolved.ref.get();
  const m = snap.data() || {};
  const merchantStatus = String(m.merchant_status ?? m.status ?? "")
    .trim()
    .toLowerCase();
  const paymentModel = normalizePaymentModel(m.payment_model) || "subscription";
  const canonical = computeCanonicalPaymentModelFields(paymentModel);
  const storedCr = Number(m.commission_rate);
  const storedWr = Number(m.withdrawal_percent);
  const commissionRateDisplay =
    paymentModel === "commission" && Number.isFinite(storedCr) && storedCr >= 0 && storedCr <= 0.6
      ? storedCr
      : canonical.commission_rate;
  const withdrawalPercentDisplay =
    paymentModel === "commission" && Number.isFinite(storedWr) && storedWr > 0 && storedWr <= 1
      ? storedWr
      : canonical.withdrawal_percent;
  const commissionExemptDisplay = paymentModel === "subscription" ? true : Boolean(m.commission_exempt);
  const subscriptionStatus =
    normalizeSubscriptionStatus(m.subscription_status) ||
    computeInitialSubscriptionStatusForPaymentModel(paymentModel);

  return {
    success: true,
    merchant: {
      merchant_id: snap.id,
      owner_uid: merchantRowOwnerUid(m),
      business_name: String(m.business_name ?? ""),
      merchant_status: merchantStatus || "pending",
      payment_model: canonical.payment_model,
      subscription_amount: canonical.subscription_amount,
      subscription_currency: canonical.subscription_currency,
      subscription_status: subscriptionStatus,
      commission_rate: commissionRateDisplay,
      commission_exempt: commissionExemptDisplay,
      withdrawal_percent: withdrawalPercentDisplay,
      region_id: m.region_id ?? null,
      city_id: m.city_id ?? null,
      phone: m.phone ?? null,
      owner_name: m.owner_name != null ? String(m.owner_name) : null,
      category: m.category != null ? String(m.category) : null,
      address: m.address != null ? String(m.address) : null,
      contact_email: m.contact_email != null ? String(m.contact_email) : null,
      business_type: m.business_type != null ? String(m.business_type) : null,
      business_registration_number:
        m.business_registration_number != null
          ? String(m.business_registration_number)
          : null,
      store_description: m.store_description != null ? String(m.store_description) : null,
      opening_hours: m.opening_hours != null ? String(m.opening_hours) : null,
      is_open: m.is_open == null ? true : Boolean(m.is_open),
      accepting_orders:
        m.accepting_orders == null ? true : Boolean(m.accepting_orders),
      availability_status: availabilityStatusForClient(m),
      closed_reason: m.closed_reason != null ? String(m.closed_reason) : null,
      store_logo_url: m.store_logo_url != null ? String(m.store_logo_url) : null,
      store_banner_url: m.store_banner_url != null ? String(m.store_banner_url) : null,
      pickup_lat: m.pickup_lat ?? null,
      pickup_lng: m.pickup_lng ?? null,
      admin_note: m.admin_note != null ? String(m.admin_note) : null,
      approved_at: m.approved_at?.toMillis?.() ?? null,
      approved_by: m.approved_by != null ? normUid(m.approved_by) : null,
      created_at: m.created_at?.toMillis?.() ?? null,
      updated_at: m.updated_at?.toMillis?.() ?? null,
      status: merchantStatus || "pending",

      verification_status:
        m.verification_status != null ? String(m.verification_status) : null,
      required_documents_complete: m.required_documents_complete === true,
      document_statuses:
        m.document_statuses != null && typeof m.document_statuses === "object"
          ? m.document_statuses
          : {},
      readiness_missing_requirements: Array.isArray(m.readiness_missing_requirements)
        ? m.readiness_missing_requirements.map((x) => String(x))
        : [],

      wallet_balance_ngn: m.wallet_balance_ngn != null ? Number(m.wallet_balance_ngn) : null,
      withdrawable_earnings_ngn:
        m.withdrawable_earnings_ngn != null ? Number(m.withdrawable_earnings_ngn) : null,

      portal_last_seen_ms: m.portal_last_seen_ms != null ? Number(m.portal_last_seen_ms) : null,
      staff_uids: Array.isArray(m.staff_uids) ? m.staff_uids.map((x) => normUid(x)).filter(Boolean) : [],
      staff_roles: m.staff_roles != null && typeof m.staff_roles === "object" ? m.staff_roles : {},
      portal_role: merchantVerification.merchantPortalRole(m, normUid(context?.auth?.uid)),
    },
  };
}

/**
 * Merchant: update safe profile fields only (no status / payment model changes).
 * Rejected merchants may set `resubmit_application: true` to queue a fresh review
 * (optionally change `payment_model` while rejected — not allowed after approval).
 * @param {object} data
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} _db
 */
async function merchantUpdateMerchantProfile(data, context, _db) {
  const uid = normUid(context?.auth?.uid);
  if (!uid) {
    return { success: false, reason: "unauthorized" };
  }
  const fs = admin.firestore();
  const resolved = await merchantVerification.resolveMerchantForMerchantAuth(fs, context);
  if (!resolved.ok) {
    if (resolved.reason === "unauthorized") {
      return { success: false, reason: "unauthorized" };
    }
    if (resolved.reason === "ambiguous_multiple_merchants") {
      return { success: false, reason: "ambiguous_multiple_merchants" };
    }
    return { success: false, reason: "not_found" };
  }
  const ref = resolved.ref;
  const m = resolved.data;
  const merchantStatus = String(m.merchant_status ?? m.status ?? "")
    .trim()
    .toLowerCase();
  const now = FieldValue.serverTimestamp();

  const resubmit = Boolean(data?.resubmit_application ?? data?.resubmitApplication);
  if (resubmit) {
    const ownerGate = merchantVerification.assertMerchantPortalAllowed(m, uid, ["owner"]);
    if (!ownerGate.ok) {
      return { success: false, reason: ownerGate.reason };
    }
    if (merchantStatus !== "rejected") {
      return { success: false, reason: "resubmit_not_allowed" };
    }
    const patch = buildMerchantOwnerProfileUpdate(data);
    const pmIn = normalizePaymentModel(data?.payment_model ?? data?.paymentModel);
    if (Object.keys(patch).length === 0 && !pmIn) {
      return { success: false, reason: "no_valid_fields" };
    }
    const finalPm =
      pmIn ||
      normalizePaymentModel(m.payment_model) ||
      "subscription";
    const canonical = computeCanonicalPaymentModelFields(finalPm);
    const subStatus = computeInitialSubscriptionStatusForPaymentModel(finalPm);
    await ref.update({
      ...patch,
      ...canonical,
      subscription_status: subStatus,
      merchant_status: "pending_review",
      status: "pending_review",
      admin_note: null,
      review_note: null,
      reviewed_at: null,
      reviewed_by: null,
      approved_at: null,
      approved_by: null,
      updated_at: now,
      updated_by: uid,
    });
    logger.info("MERCHANT_RESUBMIT", { merchantId: ref.id, owner_uid: uid });
    return { success: true, merchant_id: ref.id, resubmitted: true };
  }

  const patchGate = merchantVerification.assertMerchantPortalAllowed(m, uid, ["owner", "manager"]);
  if (!patchGate.ok) {
    return { success: false, reason: patchGate.reason };
  }

  const patch = buildMerchantOwnerProfileUpdate(data);
  if (Object.keys(patch).length === 0) {
    return { success: false, reason: "no_valid_fields" };
  }

  await ref.update({
    ...patch,
    updated_at: now,
    updated_by: uid,
  });
  logger.info("MERCHANT_PROFILE_UPDATE", { merchantId: ref.id, owner_uid: uid });
  return { success: true, merchant_id: ref.id };
}

/**
 * @param {object} data
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} db
 */
async function adminListMerchants(data, context, db) {
  const denyLm = await adminPerms.enforceCallable(db, context, "adminListMerchants");
  if (denyLm) return denyLm;
  const statusFilter = trimStr(data?.status, 32).toLowerCase();
  const paymentModelFilter = normalizePaymentModel(
    data?.payment_model ?? data?.paymentModel,
  );
  const subscriptionStatusFilter = normalizeSubscriptionStatus(
    data?.subscription_status ?? data?.subscriptionStatus,
  );
  const limit = Math.min(200, Math.max(1, Number(data?.limit ?? 80) || 80));
  const fs = admin.firestore();
  const fetchLimit =
    statusFilter && MERCHANT_STATUSES.has(statusFilter)
      ? Math.min(600, limit * 6)
      : paymentModelFilter
        ? Math.min(600, limit * 6)
        : limit;
  const snap = await fs.collection("merchants").orderBy("created_at", "desc").limit(fetchLimit).get();
  let merchants = snap.docs.map((d) => {
    const m = d.data() || {};
    const merchantStatus = String(m.merchant_status ?? m.status ?? "")
      .trim()
      .toLowerCase();
    const paymentModel = normalizePaymentModel(m.payment_model) || "subscription";
    const canonical = computeCanonicalPaymentModelFields(paymentModel);
    const storedCr = Number(m.commission_rate);
    const storedWr = Number(m.withdrawal_percent);
    const commission_rate =
      paymentModel === "commission" && Number.isFinite(storedCr) && storedCr >= 0 && storedCr <= 0.6
        ? storedCr
        : canonical.commission_rate;
    const withdrawal_percent =
      paymentModel === "commission" && Number.isFinite(storedWr) && storedWr > 0 && storedWr <= 1
        ? storedWr
        : canonical.withdrawal_percent;
    const commission_exempt = paymentModel === "subscription" ? true : Boolean(m.commission_exempt);
    const subscriptionStatus =
      normalizeSubscriptionStatus(m.subscription_status) ||
      computeInitialSubscriptionStatusForPaymentModel(paymentModel);

    return {
      merchant_id: d.id,
      owner_uid: merchantRowOwnerUid(m),
      business_name: String(m.business_name ?? ""),
      // Canonical fields
      merchant_status: merchantStatus || "pending",
      payment_model: canonical.payment_model,
      subscription_amount: canonical.subscription_amount,
      subscription_currency: canonical.subscription_currency,
      subscription_status: subscriptionStatus,
      commission_rate,
      commission_exempt,
      withdrawal_percent,

      // Profile fields (optional)
      region_id: m.region_id ?? null,
      city_id: m.city_id ?? null,
      phone: m.phone ?? null,
      owner_name: m.owner_name != null ? String(m.owner_name) : null,
      category: m.category != null ? String(m.category) : null,
      address: m.address != null ? String(m.address) : null,
      contact_email: m.contact_email != null ? String(m.contact_email) : null,
      business_type: m.business_type != null ? String(m.business_type) : null,
      store_description: m.store_description != null ? String(m.store_description) : null,
      opening_hours: m.opening_hours != null ? String(m.opening_hours) : null,
      is_open: m.is_open == null ? true : Boolean(m.is_open),
      accepting_orders:
        m.accepting_orders == null ? true : Boolean(m.accepting_orders),
      availability_status: availabilityStatusForClient(m),
      closed_reason: m.closed_reason != null ? String(m.closed_reason) : null,

      // Admin notes / audit metadata
      admin_note: m.admin_note != null ? String(m.admin_note) : null,

      approved_at: m.approved_at?.toMillis?.() ?? null,
      approved_by: m.approved_by != null ? normUid(m.approved_by) : null,

      created_at: m.created_at?.toMillis?.() ?? null,
      updated_at: m.updated_at?.toMillis?.() ?? null,

      // Optional earnings/wallet stubs (if you backfill later)
      wallet_balance_ngn: m.wallet_balance_ngn ?? null,
      withdrawable_earnings_ngn: m.withdrawable_earnings_ngn ?? null,
      estimated_monthly_order_gross_ngn:
        m.estimated_monthly_order_gross_ngn ?? null,

      // Backward compat for older UI code
      status: merchantStatus || "pending",

      verification_status:
        m.verification_status != null ? String(m.verification_status) : null,
      required_documents_complete: m.required_documents_complete === true,
      portal_last_seen_ms: m.portal_last_seen_ms != null ? Number(m.portal_last_seen_ms) : null,
      portal_online_hint:
        m.portal_last_seen_ms != null && Date.now() - Number(m.portal_last_seen_ms) < 120000,
    };
  });
  if (statusFilter && MERCHANT_STATUSES.has(statusFilter)) {
    if (statusFilter === "pending") {
      merchants = merchants.filter((row) => {
        const st = String(row.merchant_status ?? "")
          .trim()
          .toLowerCase();
        return st === "pending" || st === "pending_review";
      });
    } else {
      merchants = merchants.filter((row) => row.merchant_status === statusFilter);
    }
  }
  if (paymentModelFilter) {
    merchants = merchants.filter(
      (row) => row.payment_model === paymentModelFilter,
    );
  }
  if (subscriptionStatusFilter) {
    merchants = merchants.filter(
      (row) => row.subscription_status === subscriptionStatusFilter,
    );
  }

  merchants = merchants.slice(0, limit);
  return { success: true, merchants };
}

/**
 * Paginated-style merchant list for admin ops console (Firestore-backed).
 * Delegates to [adminListMerchants] with a capped limit; accepts same filters.
 */
async function adminListMerchantsPage(data, context, db) {
  const limit = Math.min(100, Math.max(1, Number(data?.limit ?? 50) || 50));
  return adminListMerchants({ ...(data || {}), limit }, context, db);
}

/** Full merchant admin record (alias of [adminGetMerchant]). */
async function adminGetMerchantProfile(data, context, db) {
  return adminGetMerchant(data, context, db);
}

/**
 * @param {object} data
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} db
 */
async function adminGetMerchant(data, context, db) {
  const denyGm = await adminPerms.enforceCallable(db, context, "adminGetMerchant");
  if (denyGm) return denyGm;
  const merchantId = trimStr(data?.merchant_id ?? data?.merchantId, 128);
  if (!merchantId) {
    return { success: false, reason: "invalid_merchant_id" };
  }
  const snap = await admin.firestore().collection("merchants").doc(merchantId).get();
  if (!snap.exists) {
    return { success: false, reason: "not_found" };
  }
  const m = snap.data() || {};
  const merchantStatus = String(m.merchant_status ?? m.status ?? "")
    .trim()
    .toLowerCase();
  const paymentModel = normalizePaymentModel(m.payment_model) || "subscription";
  const canonical = computeCanonicalPaymentModelFields(paymentModel);
  const storedCr = Number(m.commission_rate);
  const storedWr = Number(m.withdrawal_percent);
  const commissionRateDisplay =
    paymentModel === "commission" && Number.isFinite(storedCr) && storedCr >= 0 && storedCr <= 0.6
      ? storedCr
      : canonical.commission_rate;
  const withdrawalPercentDisplay =
    paymentModel === "commission" && Number.isFinite(storedWr) && storedWr > 0 && storedWr <= 1
      ? storedWr
      : canonical.withdrawal_percent;
  const commissionExemptDisplay = paymentModel === "subscription" ? true : Boolean(m.commission_exempt);
  const subscriptionStatus =
    normalizeSubscriptionStatus(m.subscription_status) ||
    computeInitialSubscriptionStatusForPaymentModel(paymentModel);
  const base = {
    merchant_id: snap.id,
    owner_uid: merchantRowOwnerUid(m),
    business_name: String(m.business_name ?? ""),
    // Canonical fields
    merchant_status: merchantStatus || "pending",
    payment_model: canonical.payment_model,
    subscription_amount: canonical.subscription_amount,
    subscription_currency: canonical.subscription_currency,
    subscription_status: subscriptionStatus,
    commission_rate: commissionRateDisplay,
    commission_exempt: commissionExemptDisplay,
    withdrawal_percent: withdrawalPercentDisplay,

    // Profile fields (optional)
    region_id: m.region_id ?? null,
    city_id: m.city_id ?? null,
    phone: m.phone ?? null,
    owner_name: m.owner_name != null ? String(m.owner_name) : null,
    category: m.category != null ? String(m.category) : null,
    business_type: m.business_type != null ? String(m.business_type) : null,
    address: m.address != null ? String(m.address) : null,
    contact_email: m.contact_email != null ? String(m.contact_email) : null,
    pickup_lat: m.pickup_lat ?? null,
    pickup_lng: m.pickup_lng ?? null,
    prep_time_min:
      m.prep_time_min != null && Number.isFinite(Number(m.prep_time_min))
        ? Number(m.prep_time_min)
        : null,
    delivery_radius_km:
      m.delivery_radius_km != null && Number.isFinite(Number(m.delivery_radius_km))
        ? Number(m.delivery_radius_km)
        : null,
    merchant_warning: m.merchant_warning != null ? String(m.merchant_warning) : null,
    merchant_warned_at: m.merchant_warned_at?.toMillis?.() ?? null,

    admin_note: m.admin_note != null ? String(m.admin_note) : null,

    approved_at: m.approved_at?.toMillis?.() ?? null,
    approved_by: m.approved_by != null ? normUid(m.approved_by) : null,

    created_at: m.created_at?.toMillis?.() ?? null,
    updated_at: m.updated_at?.toMillis?.() ?? null,

    // Backward compat for older UI
    status: merchantStatus || "pending",

    reviewed_at: m.reviewed_at?.toMillis?.() ?? null,
    reviewed_by: m.reviewed_by != null ? normUid(m.reviewed_by) : null,
    review_note: m.review_note != null ? String(m.review_note) : null,

    verification_status:
      m.verification_status != null ? String(m.verification_status) : null,
    required_documents_complete: m.required_documents_complete === true,
    document_statuses:
      m.document_statuses != null && typeof m.document_statuses === "object"
        ? m.document_statuses
        : {},
    readiness_missing_requirements: Array.isArray(m.readiness_missing_requirements)
      ? m.readiness_missing_requirements.map((x) => String(x))
      : [],

    portal_last_seen_ms: m.portal_last_seen_ms != null ? Number(m.portal_last_seen_ms) : null,
    portal_last_seen_uid: m.portal_last_seen_uid != null ? normUid(m.portal_last_seen_uid) : null,
    is_open: m.is_open == null ? true : Boolean(m.is_open),
    accepting_orders: m.accepting_orders == null ? true : Boolean(m.accepting_orders),
    availability_status: availabilityStatusForClient(m),
    staff_uids: Array.isArray(m.staff_uids) ? m.staff_uids.map((x) => normUid(x)).filter(Boolean) : [],
    staff_roles: m.staff_roles != null && typeof m.staff_roles === "object" ? m.staff_roles : {},
  };

  const merchant = await merchantVerification.enrichAdminMerchantResponse(
    snap.id,
    base,
  );
  if (db && Boolean(data?.include_portal_snapshot ?? data?.includePortalSnapshot)) {
    try {
      const teaserSnap = await db.ref(`merchant_public_teaser/${merchantId}`).get();
      merchant.public_storefront_teaser = teaserSnap.val() || null;
    } catch (_) {
      merchant.public_storefront_teaser = null;
    }
    try {
      const presSnap = await db.ref(`merchant_portal_presence/${merchantId}`).limitToFirst(80).get();
      merchant.portal_presence = presSnap.val() || null;
    } catch (_) {
      merchant.portal_presence = null;
    }
  }
  if (Boolean(data?.include_order_metrics ?? data?.includeOrderMetrics)) {
    const fs = admin.firestore();
    const oSnap = await fs.collection("merchant_orders").where("merchant_id", "==", snap.id).limit(200).get();
    const byStatus = {};
    let delayedReady = 0;
    const nowMs = Date.now();
    for (const d of oSnap.docs) {
      const od = d.data() || {};
      const st = String(od.order_status ?? "unknown");
      byStatus[st] = (byStatus[st] || 0) + 1;
      const ts = od.updated_at?.toMillis?.() ?? od.created_at?.toMillis?.() ?? 0;
      if (st === "ready_for_pickup" && ts && nowMs - ts > 30 * 60 * 1000) {
        delayedReady += 1;
      }
    }
    merchant.order_metrics = {
      counts_by_status: byStatus,
      delayed_ready_for_pickup: delayedReady,
    };
  }
  if (Boolean(data?.include_internal_notes ?? data?.includeInternalNotes)) {
    let notesSnap;
    try {
      notesSnap = await snap.ref.collection("internal_notes").limit(50).get();
    } catch (_) {
      notesSnap = null;
    }
    const notes = [];
    if (notesSnap && !notesSnap.empty) {
      const arr = notesSnap.docs.map((n) => {
        const v = n.data() || {};
        return {
          id: n.id,
          text: String(v.text ?? ""),
          admin_uid: normUid(v.admin_uid),
          created_at: v.created_at?.toMillis?.() ?? v.created_at?._seconds * 1000 ?? 0,
        };
      });
      arr.sort((a, b) => b.created_at - a.created_at);
      for (const x of arr.slice(0, 25)) {
        notes.push({ ...x, created_at: x.created_at || null });
      }
    }
    merchant.internal_notes = notes;
  }
  return {
    success: true,
    merchant,
  };
}

/**
 * Admin: set merchant map / service location fields used for rider discovery & delivery.
 */
async function adminUpdateMerchantLocation(data, context, db) {
  const denyUml = await adminPerms.enforceCallable(db, context, "adminUpdateMerchantLocation");
  if (denyUml) return denyUml;
  const merchantId = trimStr(data?.merchant_id ?? data?.merchantId, 128);
  if (!merchantId) {
    return { success: false, reason: "invalid_merchant_id" };
  }
  const plat = Number(data?.pickup_lat ?? data?.pickupLat ?? "");
  const plng = Number(data?.pickup_lng ?? data?.pickupLng ?? "");
  const patch = {
    updated_at: FieldValue.serverTimestamp(),
    location_updated_by: normUid(context.auth?.uid),
  };
  if (Number.isFinite(plat) && Number.isFinite(plng)) {
    patch.pickup_lat = plat;
    patch.pickup_lng = plng;
  }
  const cityId = trimStr(data?.city_id ?? data?.cityId, 120);
  const regionId = trimStr(data?.region_id ?? data?.regionId, 80);
  if (cityId) {
    patch.city_id = cityId;
  }
  if (regionId) {
    patch.region_id = regionId;
  }
  const prep = Number(data?.prep_time_min ?? data?.prepTimeMin ?? "");
  if (Number.isFinite(prep) && prep >= 0 && prep <= 240) {
    patch.prep_time_min = Math.round(prep);
  }
  const rad = Number(data?.delivery_radius_km ?? data?.deliveryRadiusKm ?? "");
  if (Number.isFinite(rad) && rad > 0 && rad <= 80) {
    patch.delivery_radius_km = rad;
  }
  await admin.firestore().collection("merchants").doc(merchantId).set(patch, { merge: true });
  if (db) {
    try {
      const { syncMerchantPublicTeaserFromMerchantId } = require("../merchant_public_sync");
      await syncMerchantPublicTeaserFromMerchantId(db, merchantId, {});
    } catch (e) {
      logger.warn("ADMIN_MERCHANT_LOCATION_TEASER_SYNC_FAIL", {
        merchantId,
        err: String(e?.message || e),
      });
    }
  }
  return { success: true };
}

/**
 * @param {object} data
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} db
 */
async function adminReviewMerchant(data, context, db) {
  const denyRm = await adminPerms.enforceCallable(db, context, "adminReviewMerchant");
  if (denyRm) return denyRm;
  const adminUid = normUid(context.auth.uid);
  const merchantId = trimStr(data?.merchant_id ?? data?.merchantId, 128);
  const action = trimStr(data?.action, 24).toLowerCase();
  const note = trimStr(data?.note ?? data?.review_note, 2000);
  const forceManualApprove = Boolean(
    data?.force_manual_approve ?? data?.forceManualApprove,
  );
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

  const m = snap.data() || {};
  const paymentModel = normalizePaymentModel(m.payment_model) || "subscription";
  const canonical = computeCanonicalPaymentModelFields(paymentModel);
  const currentSubStatus =
    normalizeSubscriptionStatus(m.subscription_status) ||
    computeInitialSubscriptionStatusForPaymentModel(paymentModel);

  let readinessOverridden = false;
  if (nextStatus === "approved") {
    const readiness = await merchantVerification.getMerchantReadiness(merchantId);
    const allowed = Boolean(readiness?.allowed);
    if (!allowed) {
      if (!forceManualApprove) {
        return {
          success: false,
          reason: "readiness_blocked",
          readable_message: readiness?.readableMessage ?? "Verification incomplete.",
          readiness: readiness
            ? {
                allowed: readiness.allowed,
                missingRequirements: readiness.missingRequirements,
                documentStatuses: { ...readiness.documentStatuses },
                merchant_status: readiness.merchant_status,
                payment_model: readiness.payment_model,
                subscription_status: readiness.subscription_status,
                readableMessage: readiness.readableMessage,
                requires_operating_license: readiness.requires_operating_license,
              }
            : null,
        };
      }
      readinessOverridden = true;
    }
  }

  // Keep subscription_status unless we need to initialize/overwrite due to model mismatch
  // or because the merchant is being rejected.
  let nextSubscriptionStatus = currentSubStatus;
  if (paymentModel === "commission") {
    nextSubscriptionStatus = "inactive";
  } else if (nextStatus === "rejected" && nextSubscriptionStatus !== "rejected") {
    nextSubscriptionStatus = "rejected";
  } else if (!SUBSCRIPTION_STATUSES.has(nextSubscriptionStatus)) {
    nextSubscriptionStatus =
      computeInitialSubscriptionStatusForPaymentModel(paymentModel);
  }

  const priorCr = Number(m.commission_rate);
  const priorWr = Number(m.withdrawal_percent);
  let commissionRate = canonical.commission_rate;
  let withdrawalPercent = canonical.withdrawal_percent;
  let commissionExempt = canonical.commission_exempt;
  if (paymentModel === "commission") {
    if (Number.isFinite(priorCr) && priorCr >= 0 && priorCr <= 0.6) {
      commissionRate = priorCr;
    }
    if (Number.isFinite(priorWr) && priorWr > 0 && priorWr <= 1) {
      withdrawalPercent = priorWr;
    }
    commissionExempt = false;
  }

  const now = FieldValue.serverTimestamp();
  /** @type {Record<string, unknown>} */
  const merchantPatch = {
    merchant_status: nextStatus,
    status: nextStatus, // Backward compat
    payment_model: canonical.payment_model,
    commission_exempt: commissionExempt,
    commission_rate: commissionRate,
    withdrawal_percent: withdrawalPercent,
    subscription_amount: canonical.subscription_amount,
    subscription_currency: canonical.subscription_currency,
    subscription_status: nextSubscriptionStatus,
    updated_at: now,
    reviewed_at: now,
    reviewed_by: adminUid,
    review_note: note || null,

    // Canonical admin note
    admin_note: note || null,

    // Approval metadata
    approved_at: nextStatus === "approved" ? now : null,
    approved_by: nextStatus === "approved" ? adminUid : null,
  };
  if (nextStatus === "approved" && readinessOverridden) {
    merchantPatch.readiness_override_at = now;
    merchantPatch.readiness_override_by = adminUid;
  }
  await ref.update(merchantPatch);

  await writeAdminAuditLog(db, {
    actor_uid: adminUid,
    action: "update_merchant_status",
    entity_type: "merchant",
    entity_id: merchantId,
    before: {
      merchant_status: m.merchant_status ?? m.status ?? null,
      payment_model: m.payment_model ?? null,
      subscription_status: m.subscription_status ?? null,
    },
    after: {
      merchant_status: nextStatus,
      payment_model: merchantPatch.payment_model,
      subscription_status: merchantPatch.subscription_status,
      readiness_overridden: readinessOverridden,
    },
    reason: note || null,
    source: "merchant_callables.adminReviewMerchant",
    type: "merchant_review",
    created_at: Date.now(),
  });

  logger.info("MERCHANT_REVIEW", {
    merchantId,
    action,
    nextStatus,
    adminUid,
    readinessOverridden,
  });

  if (db) {
    try {
      const { syncMerchantPublicTeaserFromMerchantId } = require("./merchant_public_sync");
      await syncMerchantPublicTeaserFromMerchantId(db, merchantId);
    } catch (e) {
      logger.warn("MERCHANT_REVIEW_TEASER_SYNC_FAILED", { merchantId, err: String(e?.message || e) });
    }
  }

  if (nextStatus === "approved") {
    try {
      let contactEmail = trimStr(m.contact_email ?? m.contactEmail, 320);
      const ownerUid = normUid(m.owner_uid);
      if (!contactEmail && ownerUid) {
        try {
          const u = await admin.auth().getUser(ownerUid);
          contactEmail = trimStr(u.email, 320);
        } catch {
          // ignore
        }
      }
      await notifyMerchantApproval(db, {
        ownerUid,
        contactEmail,
        businessName: trimStr(m.business_name ?? m.businessName, 200),
      });
    } catch (e) {
      logger.warn("MERCHANT_APPROVAL_NOTIFY_FAILED", { merchantId, err: String(e) });
    }
  }

  return { success: true, merchant_id: merchantId, status: nextStatus };
}

/**
 * Admin: change merchant payment model (subscription vs commission).
 * Updates canonical financial fields immediately (no touching earnings/order history).
 */
async function adminUpdateMerchantPaymentModel(data, context, db) {
  const denyUmpm = await adminPerms.enforceCallable(db, context, "adminUpdateMerchantPaymentModel");
  if (denyUmpm) return denyUmpm;
  const adminUid = normUid(context.auth.uid);
  const merchantId = trimStr(data?.merchant_id ?? data?.merchantId, 128);
  const paymentModel = normalizePaymentModel(
    data?.payment_model ?? data?.paymentModel,
  );
  if (!merchantId || !paymentModel) {
    return { success: false, reason: "invalid_input" };
  }

  const ref = admin.firestore().collection("merchants").doc(merchantId);
  const snap = await ref.get();
  if (!snap.exists) {
    return { success: false, reason: "not_found" };
  }

  const now = FieldValue.serverTimestamp();
  const canonical = computeCanonicalPaymentModelFields(paymentModel);
  const nextSubscriptionStatus =
    paymentModel === "subscription"
      ? computeInitialSubscriptionStatusForPaymentModel(paymentModel)
      : "inactive";

  // Only update canonical workflow fields; leave merchant_status & wallet/ledger alone.
  await ref.update({
    payment_model: canonical.payment_model,
    commission_exempt: canonical.commission_exempt,
    commission_rate: canonical.commission_rate,
    withdrawal_percent: canonical.withdrawal_percent,
    subscription_amount: canonical.subscription_amount,
    subscription_currency: canonical.subscription_currency,
    subscription_status: nextSubscriptionStatus,
    updated_at: now,
  });

  await writeAdminAuditLog(db, {
    actor_uid: adminUid,
    action: "update_wallet_payment_model",
    entity_type: "merchant",
    entity_id: merchantId,
    before: {
      payment_model: m.payment_model ?? null,
      subscription_status: m.subscription_status ?? null,
    },
    after: {
      payment_model: canonical.payment_model,
      subscription_status: nextSubscriptionStatus,
    },
    reason: trimStr(data?.reason ?? data?.note, 500) || null,
    source: "merchant_callables.adminUpdateMerchantPaymentModel",
    type: "merchant_payment_model_update",
    created_at: Date.now(),
  });

  return {
    success: true,
    merchant_id: merchantId,
    payment_model: paymentModel,
    subscription_status: nextSubscriptionStatus,
  };
}

/**
 * Admin: update merchant subscription payment workflow state.
 * Does not change merchant_status (approval) — merchants may be approved but subscription can be inactive/pending, etc.
 */
async function adminUpdateMerchantSubscriptionStatus(data, context, db) {
  const denyUmss = await adminPerms.enforceCallable(db, context, "adminUpdateMerchantSubscriptionStatus");
  if (denyUmss) return denyUmss;
  const adminUid = normUid(context.auth.uid);
  const merchantId = trimStr(data?.merchant_id ?? data?.merchantId, 128);
  const subscriptionStatus = normalizeSubscriptionStatus(
    data?.subscription_status ?? data?.subscriptionStatus,
  );
  const note = trimStr(data?.note ?? data?.admin_note ?? data?.review_note, 2000);

  if (!merchantId || !subscriptionStatus) {
    return { success: false, reason: "invalid_input" };
  }

  const ref = admin.firestore().collection("merchants").doc(merchantId);
  const snap = await ref.get();
  if (!snap.exists) {
    return { success: false, reason: "not_found" };
  }

  const m = snap.data() || {};
  const paymentModel = normalizePaymentModel(m.payment_model) || "subscription";
  if (paymentModel !== "subscription") {
    return {
      success: false,
      reason: "payment_model_mismatch",
    };
  }

  const now = FieldValue.serverTimestamp();
  await ref.update({
    subscription_status: subscriptionStatus,
    updated_at: now,
    // Optional admin note for this transition
    admin_note: note || m.admin_note || null,
  });

  await writeAdminAuditLog(db, {
    actor_uid: adminUid,
    action: "update_merchant_subscription_status",
    entity_type: "merchant",
    entity_id: merchantId,
    before: { subscription_status: m.subscription_status ?? null },
    after: { subscription_status: subscriptionStatus },
    reason: note || null,
    source: "merchant_callables.adminUpdateMerchantSubscriptionStatus",
    type: "merchant_subscription_status_update",
    created_at: Date.now(),
  });

  return { success: true, merchant_id: merchantId, subscription_status: subscriptionStatus };
}

/**
 * Admin: recompute merchant canonical financial fields from payment_model.
 * Safe idempotent operation: does not touch merchant_status or any ledger/order history.
 */
async function recomputeMerchantFinancialModel(data, context, db) {
  const denyRmf = await adminPerms.enforceCallable(db, context, "recomputeMerchantFinancialModel");
  if (denyRmf) return denyRmf;
  const merchantId = trimStr(data?.merchant_id ?? data?.merchantId, 128);
  if (!merchantId) {
    return { success: false, reason: "invalid_merchant_id" };
  }

  const ref = admin.firestore().collection("merchants").doc(merchantId);
  const snap = await ref.get();
  if (!snap.exists) {
    return { success: false, reason: "not_found" };
  }
  const m = snap.data() || {};
  const paymentModel = normalizePaymentModel(m.payment_model) || "subscription";
  const canonical = computeCanonicalPaymentModelFields(paymentModel);

  let nextSubscriptionStatus;
  if (paymentModel === "commission") {
    nextSubscriptionStatus = "inactive";
  } else {
    nextSubscriptionStatus =
      normalizeSubscriptionStatus(m.subscription_status) ||
      computeInitialSubscriptionStatusForPaymentModel(paymentModel);
  }

  const now = FieldValue.serverTimestamp();
  const adminUid = normUid(context.auth.uid);
  await ref.update({
    payment_model: canonical.payment_model,
    commission_exempt: canonical.commission_exempt,
    commission_rate: canonical.commission_rate,
    withdrawal_percent: canonical.withdrawal_percent,
    subscription_amount: canonical.subscription_amount,
    subscription_currency: canonical.subscription_currency,
    subscription_status: nextSubscriptionStatus,
    updated_at: now,
  });

  await writeAdminAuditLog(db, {
    actor_uid: adminUid,
    action: "update_wallet_payment_model",
    entity_type: "merchant",
    entity_id: merchantId,
    before: {
      payment_model: m.payment_model ?? null,
      commission_rate: m.commission_rate ?? null,
      withdrawal_percent: m.withdrawal_percent ?? null,
    },
    after: {
      payment_model: canonical.payment_model,
      commission_rate: canonical.commission_rate,
      withdrawal_percent: canonical.withdrawal_percent,
      subscription_status: nextSubscriptionStatus,
    },
    reason: "recompute_merchant_financial_model",
    source: "merchant_callables.recomputeMerchantFinancialModel",
    type: "merchant_recompute_financial_model",
    created_at: Date.now(),
  });

  return {
    success: true,
    merchant_id: merchantId,
    payment_model: paymentModel,
    subscription_status: nextSubscriptionStatus,
    commission_rate: canonical.commission_rate,
    withdrawal_percent: canonical.withdrawal_percent,
  };
}

async function adminWarnMerchant(data, context, db) {
  const denyWm = await adminPerms.enforceCallable(db, context, "adminWarnMerchant");
  if (denyWm) return denyWm;
  const adminUid = normUid(context.auth.uid);
  const merchantId = trimStr(data?.merchant_id ?? data?.merchantId, 128);
  const message = trimStr(data?.message ?? data?.warning, 2000);
  if (!merchantId || message.length < 4) {
    return { success: false, reason: "invalid_input" };
  }
  const ref = admin.firestore().collection("merchants").doc(merchantId);
  const snap = await ref.get();
  if (!snap.exists) {
    return { success: false, reason: "not_found" };
  }
  const prior = snap.data() || {};
  const now = FieldValue.serverTimestamp();
  await ref.update({
    merchant_warning: message,
    merchant_warned_at: now,
    updated_at: now,
  });
  await ref.collection("internal_notes").add({
    text: `[WARN] ${message}`,
    admin_uid: adminUid,
    created_at: now,
  });
  await writeAdminAuditLog(db, {
    actor_uid: adminUid,
    action: "warn_merchant",
    entity_type: "merchant",
    entity_id: merchantId,
    before: { merchant_warning: prior.merchant_warning ?? null },
    after: { merchant_warning: message },
    reason: message,
    source: "merchant_callables.adminWarnMerchant",
    type: "merchant_warn",
    created_at: Date.now(),
  });
  return { success: true, merchant_id: merchantId };
}

async function adminSetMerchantCommissionWithdrawal(data, context, db) {
  const denySmcw = await adminPerms.enforceCallable(db, context, "adminSetMerchantCommissionWithdrawal");
  if (denySmcw) return denySmcw;
  const adminUid = normUid(context.auth.uid);
  const merchantId = trimStr(data?.merchant_id ?? data?.merchantId, 128);
  const cr = Number(data?.commission_rate ?? data?.commissionRate);
  const wrIn = Number(data?.withdrawal_percent ?? data?.withdrawalPercent);
  if (!merchantId || !Number.isFinite(cr) || cr < 0 || cr > 0.5) {
    return { success: false, reason: "invalid_commission_rate" };
  }
  const wr = Number.isFinite(wrIn) && wrIn > 0 && wrIn <= 1 ? wrIn : Math.max(0, 1 - cr);
  const ref = admin.firestore().collection("merchants").doc(merchantId);
  const snap = await ref.get();
  if (!snap.exists) {
    return { success: false, reason: "not_found" };
  }
  const m = snap.data() || {};
  if (normalizePaymentModel(m.payment_model) !== "commission") {
    return { success: false, reason: "payment_model_must_be_commission" };
  }
  const now = FieldValue.serverTimestamp();
  await ref.update({
    commission_rate: cr,
    withdrawal_percent: wr,
    commission_exempt: cr === 0,
    updated_at: now,
  });
  await writeAdminAuditLog(db, {
    actor_uid: adminUid,
    action: "update_wallet_payment_model",
    entity_type: "merchant",
    entity_id: merchantId,
    before: {
      commission_rate: m.commission_rate ?? null,
      withdrawal_percent: m.withdrawal_percent ?? null,
    },
    after: { commission_rate: cr, withdrawal_percent: wr, commission_exempt: cr === 0 },
    reason: trimStr(data?.reason ?? data?.note, 500) || "commission_override",
    source: "merchant_callables.adminSetMerchantCommissionWithdrawal",
    type: "merchant_commission_override",
    created_at: Date.now(),
  });
  return { success: true, merchant_id: merchantId, commission_rate: cr, withdrawal_percent: wr };
}

async function adminAppendMerchantInternalNote(data, context, db) {
  const denyAmn = await adminPerms.enforceCallable(db, context, "adminAppendMerchantInternalNote");
  if (denyAmn) return denyAmn;
  const adminUid = normUid(context.auth.uid);
  const merchantId = trimStr(data?.merchant_id ?? data?.merchantId, 128);
  const text = trimStr(data?.text ?? data?.note, 4000);
  if (!merchantId || text.length < 2) {
    return { success: false, reason: "invalid_input" };
  }
  const ref = admin.firestore().collection("merchants").doc(merchantId);
  const snap = await ref.get();
  if (!snap.exists) {
    return { success: false, reason: "not_found" };
  }
  const now = FieldValue.serverTimestamp();
  const doc = await ref.collection("internal_notes").add({
    text,
    admin_uid: adminUid,
    created_at: now,
  });
  await writeAdminAuditLog(db, {
    actor_uid: adminUid,
    action: "merchant_internal_note",
    entity_type: "merchant",
    entity_id: merchantId,
    before: null,
    after: { note_id: doc.id, text_preview: text.slice(0, 200) },
    reason: text.slice(0, 500),
    source: "merchant_callables.adminAppendMerchantInternalNote",
    type: "merchant_internal_note",
    created_at: Date.now(),
  });
  return { success: true, merchant_id: merchantId, note_id: doc.id };
}

/**
 * Derives canonical open/closed/paused + is_open + accepting_orders from client payload.
 * @param {object} data
 */
function normalizeMerchantAvailabilityInput(data) {
  const raw = trimStr(data?.availability_status ?? data?.availabilityStatus, 40).toLowerCase();
  if (raw === "open" || raw === "closed" || raw === "paused") {
    return { mode: raw };
  }
  if (raw === "online") return { mode: "open" };
  if (raw === "offline") return { mode: "closed" };
  const hi = data?.is_open ?? data?.isOpen;
  const acc = data?.accepting_orders ?? data?.acceptingOrders;
  if (hi === undefined && acc === undefined) {
    return { mode: "" };
  }
  const isOpen = Boolean(hi);
  const accepting = acc === undefined ? isOpen : Boolean(acc);
  if (isOpen && accepting) return { mode: "open" };
  if (isOpen && !accepting) return { mode: "paused" };
  return { mode: "closed" };
}

/**
 * Approved merchant: storefront availability (rider catalog + order acceptance).
 */
async function merchantUpdateAvailability(data, context, _db) {
  const fs = admin.firestore();
  const resolved = await merchantVerification.resolveMerchantForMerchantAuth(fs, context);
  if (!resolved.ok) {
    if (resolved.reason === "unauthorized") {
      return { success: false, reason: "unauthorized" };
    }
    if (resolved.reason === "ambiguous_multiple_merchants") {
      return { success: false, reason: "ambiguous_multiple_merchants" };
    }
    return { success: false, reason: "not_found" };
  }
  const ref = resolved.ref;
  const m = resolved.data || {};
  const merchantStatus = String(m.merchant_status ?? m.status ?? "")
    .trim()
    .toLowerCase();
  const uid = normUid(context?.auth?.uid);
  const availGate = merchantVerification.assertMerchantPortalAllowed(m, uid, ["owner", "manager"]);
  if (!availGate.ok) {
    return { success: false, reason: availGate.reason };
  }
  if (merchantStatus === "suspended" || merchantStatus === "rejected") {
    return { success: false, reason: "merchant_not_allowed" };
  }
  if (merchantStatus !== "approved") {
    return { success: false, reason: "merchant_not_approved" };
  }
  const n = normalizeMerchantAvailabilityInput(data);
  if (!n.mode) {
    return {
      success: false,
      reason: "invalid_input",
      message: "Provide availability_status (open|closed|paused) and/or is_open + accepting_orders.",
    };
  }
  const mode = n.mode;
  const isOpen = mode === "open" || mode === "paused";
  const acceptingOrders = mode === "open";
  const closedReason = trimStr(data?.closed_reason ?? data?.closedReason, 500);
  const now = FieldValue.serverTimestamp();
  await ref.update({
    is_open: isOpen,
    accepting_orders: acceptingOrders,
    availability_status: mode,
    closed_reason: closedReason || null,
    updated_at: now,
    updated_by: uid || null,
  });
  logger.info("MERCHANT_AVAILABILITY", {
    merchantId: ref.id,
    is_open: isOpen,
    accepting_orders: acceptingOrders,
    availability_status: mode,
  });
  if (_db) {
    try {
      const { syncMerchantPublicTeaserFromMerchantId } = require("../merchant_public_sync");
      await syncMerchantPublicTeaserFromMerchantId(_db, ref.id);
    } catch (e) {
      logger.warn("MERCHANT_AVAILABILITY_TEASER_SYNC_FAILED", {
        err: String(e?.message || e),
        merchantId: ref.id,
      });
    }
  }
  return {
    success: true,
    merchant_id: ref.id,
    is_open: isOpen,
    accepting_orders: acceptingOrders,
    availability_status: mode,
    closed_reason: closedReason || null,
  };
}

/** @deprecated Use merchantUpdateAvailability (same implementation). */
const merchantSetAvailability = merchantUpdateAvailability;

/**
 * Portal heartbeat: presence for admin + RTDB storefront mirror.
 * @param {object} data
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} _db
 */
async function merchantPortalHeartbeat(data, context, _db) {
  const uid = normUid(context?.auth?.uid);
  if (!uid) {
    return { success: false, reason: "unauthorized" };
  }
  const fs = admin.firestore();
  const resolved = await merchantVerification.resolveMerchantForMerchantAuth(fs, context);
  if (!resolved.ok) {
    return { success: false, reason: resolved.reason || "not_found" };
  }
  const sessionId = trimStr(data?.session_id ?? data?.sessionId, 128) || uid;
  const deviceLabel = trimStr(data?.device_label ?? data?.deviceLabel, 120);
  const now = Date.now();
  await resolved.ref.set(
    {
      portal_last_seen_ms: now,
      portal_last_seen_uid: uid,
      portal_last_session_id: sessionId,
      portal_device_label: deviceLabel || null,
      updated_at: FieldValue.serverTimestamp(),
    },
    { merge: true },
  );
  if (_db) {
    try {
      const { syncMerchantPublicTeaserFromMerchantId } = require("../merchant_public_sync");
      await syncMerchantPublicTeaserFromMerchantId(_db, resolved.ref.id);
    } catch (_) {}
    const safeKey = normUid(sessionId).replace(/[.#$\[\]/]/g, "_").slice(0, 80) || "default";
    await _db.ref(`merchant_portal_presence/${resolved.ref.id}/${safeKey}`).set({
      uid,
      session_id: sessionId,
      device_label: deviceLabel || null,
      last_seen_ms: now,
    });
  }
  return { success: true, merchant_id: resolved.ref.id, last_seen_ms: now };
}

/**
 * Owner-only: add/update/remove cashier or manager staff (by uid).
 * @param {object} data
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} _db
 */
async function merchantPutStaffMember(data, context, _db) {
  const uid = normUid(context?.auth?.uid);
  if (!uid) {
    return { success: false, reason: "unauthorized" };
  }
  const fs = admin.firestore();
  const resolved = await merchantVerification.resolveMerchantForMerchantAuth(fs, context);
  if (!resolved.ok) {
    return { success: false, reason: resolved.reason || "not_found" };
  }
  const owner = normUid(resolved.data?.owner_uid ?? resolved.data?.ownerUid);
  if (owner !== uid) {
    return { success: false, reason: "owner_only" };
  }
  let target = normUid(data?.staff_uid ?? data?.staffUid);
  const email = trimStr(data?.staff_email ?? data?.staffEmail, 320).toLowerCase();
  if (!target && email) {
    try {
      const u = await admin.auth().getUserByEmail(email);
      target = normUid(u.uid);
    } catch {
      return { success: false, reason: "user_not_found" };
    }
  }
  const role = trimStr(data?.role, 24).toLowerCase();
  if (!target || target === uid) {
    return { success: false, reason: "invalid_staff_uid" };
  }
  const allowed = new Set(["manager", "cashier", "remove"]);
  if (!allowed.has(role)) {
    return { success: false, reason: "invalid_role" };
  }
  const ref = resolved.ref;
  const snap = await ref.get();
  const m = snap.data() || {};
  const staff = Array.isArray(m.staff_uids) ? m.staff_uids.map((x) => normUid(x)).filter(Boolean) : [];
  const roles = m.staff_roles != null && typeof m.staff_roles === "object" ? { ...m.staff_roles } : {};
  if (role === "remove") {
    const next = staff.filter((x) => x !== target);
    delete roles[target];
    await ref.update({
      staff_uids: next,
      staff_roles: roles,
      updated_at: FieldValue.serverTimestamp(),
      updated_by: uid,
    });
    if (_db) {
      await writeAdminAuditLog(_db, {
        actor_uid: uid,
        action: "merchant_staff_remove",
        entity_type: "merchant",
        entity_id: ref.id,
        before: { staff_uids: staff, target },
        after: { staff_uids: next },
        reason: "merchant_staff_remove",
        source: "merchant_callables.merchantPutStaffMember",
        type: "merchant_staff_remove",
        created_at: Date.now(),
      });
    }
    return { success: true, staff_uids: next, staff_roles: roles };
  }
  if (!staff.includes(target)) staff.push(target);
  roles[target] = role;
  await ref.update({
    staff_uids: staff,
    staff_roles: roles,
    updated_at: FieldValue.serverTimestamp(),
    updated_by: uid,
  });
  if (_db) {
    await writeAdminAuditLog(_db, {
      actor_uid: uid,
      action: "merchant_staff_update",
      entity_type: "merchant",
      entity_id: ref.id,
      before: { staff_uids: m.staff_uids ?? null },
      after: { staff_uids: staff, staff_uid: target, role },
      reason: "merchant_staff_update",
      source: "merchant_callables.merchantPutStaffMember",
      type: "merchant_staff_update",
      created_at: Date.now(),
    });
  }
  return { success: true, staff_uids: staff, staff_roles: roles };
}

module.exports = {
  merchantRegister,
  merchantGetMyMerchant,
  merchantUpdateMerchantProfile,
  merchantUpdateAvailability,
  merchantSetAvailability,
  merchantPortalHeartbeat,
  merchantPutStaffMember,
  adminListMerchants,
  adminListMerchantsPage,
  adminGetMerchant,
  adminGetMerchantProfile,
  adminReviewMerchant,
  adminUpdateMerchantPaymentModel,
  adminUpdateMerchantSubscriptionStatus,
  recomputeMerchantFinancialModel,
  adminWarnMerchant,
  adminSetMerchantCommissionWithdrawal,
  adminAppendMerchantInternalNote,
  adminUpdateMerchantLocation,
  /** @internal unit tests */
  reviewActionToStatus,
  /** @internal unit tests */
  normalizePaymentModel,
  normalizeSubscriptionStatus,
  computeCanonicalPaymentModelFields,
  computeInitialSubscriptionStatusForPaymentModel,
  initialMerchantStatus,
  applyCanonicalPaymentFields,
  buildMerchantOwnerProfileUpdate,
};
