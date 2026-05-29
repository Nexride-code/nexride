"use strict";

const crypto = require("crypto");
const admin = require("firebase-admin");
const { FieldValue } = require("firebase-admin/firestore");
const { normUid } = require("./admin_auth");
const adminPerms = require("./admin_permissions");
const { writeAdminAuditLog } = require("./admin_audit_log");
const merchantVerification = require("./merchant/merchant_verification");
const fleetVerification = require("./fleet_verification");
const workerIdentity = require("./worker_identity_claims");

const DISPATCH_VEHICLE_TYPES = new Set(["bike", "car", "van"]);
const OWNERSHIP_MODES = new Set(["individual", "business_managed"]);
const ACCOUNT_KIND_DISPATCH_FLEET = "dispatch_fleet";
const FLEET_OWNER_INDEX_ROOT = "dispatch_fleet_owner_index";
/** @type {import("firebase-admin/firestore").Firestore | null} */
let firestoreOverrideForTests = null;
const FLEET_BLOCKING_STATUSES = new Set([
  "pending",
  "pending_documents",
  "pending_review",
  "approved",
  "suspended",
  "rejected",
]);

const FLEET_ADMIN_STATUS_FILTERS = new Set([
  "all",
  "pending_documents",
  "pending_review",
  "approved",
  "rejected",
  "suspended",
]);

function nowMs() {
  return Date.now();
}

function resolveFirestore() {
  return firestoreOverrideForTests || admin.firestore();
}

/** @param {import("firebase-admin/firestore").Firestore | null} fs */
function setFirestoreForTests(fs) {
  firestoreOverrideForTests = fs;
}

function trimStr(v, max = 200) {
  return String(v ?? "").trim().slice(0, max);
}

function normalizeDispatchVehicleType(v) {
  const s = trimStr(v, 40).toLowerCase();
  return DISPATCH_VEHICLE_TYPES.has(s) ? s : "";
}

function normalizeOwnershipMode(v) {
  const s = trimStr(v, 64).toLowerCase();
  return OWNERSHIP_MODES.has(s) ? s : "";
}

function isDispatchFleetAccount(m) {
  return (
    trimStr(m?.account_kind ?? m?.accountKind, 64).toLowerCase() ===
    ACCOUNT_KIND_DISPATCH_FLEET
  );
}

function merchantStatusOf(m) {
  return trimStr(m?.merchant_status ?? m?.status, 40).toLowerCase();
}

function verificationStatusOf(m) {
  return trimStr(m?.verification_status, 64).toLowerCase();
}

/**
 * Manual admin override approval (document bypass) — invite allowed without full docs.
 * @param {Record<string, unknown>} m
 */
function fleetManualOverrideApprovedForInvites(m) {
  const vs = verificationStatusOf(m);
  if (vs === "approved_override") {
    return true;
  }
  if (m.approval_override !== true) {
    return false;
  }
  const overrideNote = trimStr(
    m.override_note ?? m.overrideNote ?? m.review_note ?? m.reviewNote,
    2000,
  );
  return overrideNote.length >= 3;
}

/**
 * Fleet may create driver invites when approved with complete docs or manual override.
 * @param {Record<string, unknown> | null | undefined} m
 */
function fleetAccountApprovedForInvites(m) {
  if (!m || typeof m !== "object") {
    return false;
  }
  if (!isDispatchFleetAccount(m)) {
    return false;
  }
  if (merchantStatusOf(m) === "suspended") {
    return false;
  }
  if (merchantStatusOf(m) !== "approved") {
    return false;
  }
  if (m.required_documents_complete === true) {
    return true;
  }
  if (fleetManualOverrideApprovedForInvites(m)) {
    return true;
  }
  return false;
}

function buildInviteCode() {
  const raw = crypto.randomBytes(8).toString("hex").toUpperCase();
  return `NXR-${raw}`;
}

function inviteRef(db, inviteCode) {
  return db.ref(`business_driver_invites/${inviteCode}`);
}

/**
 * @param {import("firebase-admin/database").Database} db
 * @param {string} ownerUid
 */
function fleetOwnerIndexRef(db, ownerUid) {
  return db.ref(`${FLEET_OWNER_INDEX_ROOT}/${normUid(ownerUid)}`);
}

/**
 * Keyed read: dispatch_fleet_owner_index/{ownerUid} (all fleet businesses for owner).
 * @param {import("firebase-admin/database").Database} db
 * @param {string} ownerUid
 * @returns {Promise<Record<string, Record<string, unknown>>>}
 */
async function loadFleetOwnerIndex(db, ownerUid) {
  const uid = normUid(ownerUid);
  if (!uid) {
    return {};
  }
  const snap = await fleetOwnerIndexRef(db, uid).get();
  const val = snap.val();
  if (!val || typeof val !== "object") {
    return {};
  }
  /** @type {Record<string, Record<string, unknown>>} */
  const out = {};
  for (const [businessId, entry] of Object.entries(val)) {
    if (entry && typeof entry === "object") {
      out[trimStr(businessId, 128)] = entry;
    }
  }
  return out;
}

/**
 * @param {import("firebase-admin/database").Database} db
 * @param {string} ownerUid
 * @param {string} businessId
 * @param {Record<string, unknown>} entry
 */
async function writeFleetOwnerIndexEntry(db, ownerUid, businessId, entry) {
  const uid = normUid(ownerUid);
  const bid = trimStr(businessId, 128);
  if (!uid || !bid) {
    return;
  }
  await db.ref(`${FLEET_OWNER_INDEX_ROOT}/${uid}/${bid}`).set(entry);
}

function indexEntryStatus(entry) {
  return trimStr(entry?.status ?? entry?.merchant_status, 40).toLowerCase();
}

/**
 * @param {import("firebase-admin/database").Database} db
 * @param {import("firebase-admin/firestore").Firestore} fs
 * @param {string} ownerUid
 * @returns {Promise<string | null>} business_id if a blocking fleet account exists
 */
async function ownerHasBlockingFleetFromIndex(db, fs, ownerUid) {
  const entries = await loadFleetOwnerIndex(db, ownerUid);
  const businessIds = Object.keys(entries);
  if (!businessIds.length) {
    return null;
  }
  for (const businessId of businessIds) {
    const entry = entries[businessId] || {};
    if (trimStr(entry.account_kind, 64).toLowerCase() !== ACCOUNT_KIND_DISPATCH_FLEET) {
      continue;
    }
    const snap = await fs.collection("merchants").doc(businessId).get();
    if (!snap.exists) {
      if (FLEET_BLOCKING_STATUSES.has(indexEntryStatus(entry))) {
        return businessId;
      }
      continue;
    }
    const m = snap.data() || {};
    if (!isDispatchFleetAccount(m)) {
      continue;
    }
    if (FLEET_BLOCKING_STATUSES.has(merchantStatusOf(m))) {
      return businessId;
    }
  }
  return null;
}

/**
 * @param {Record<string, Record<string, unknown>>} entries
 * @param {Record<string, Record<string, unknown>>} merchantsById
 */
function pickFleetBusinessId(entries, merchantsById) {
  /** @type {{ businessId: string, entry: Record<string, unknown>, merchant: Record<string, unknown> }[]} */
  const candidates = [];
  for (const [businessId, entry] of Object.entries(entries)) {
    const m = merchantsById[businessId];
    if (!m || !isDispatchFleetAccount(m)) {
      continue;
    }
    candidates.push({ businessId, entry, merchant: m });
  }
  if (!candidates.length) {
    return null;
  }
  const approved = candidates.filter((c) => merchantStatusOf(c.merchant) === "approved");
  const pool = approved.length ? approved : candidates;
  pool.sort((a, b) => {
    const aTs = Number(a.entry.created_at ?? a.entry.createdAt ?? 0);
    const bTs = Number(b.entry.created_at ?? b.entry.createdAt ?? 0);
    return bTs - aTs;
  });
  return pool[0].businessId;
}

/**
 * Resolve fleet business via RTDB owner index + keyed merchants/{id} reads only.
 * @param {import("firebase-admin/database").Database} db
 * @param {import("firebase-admin/firestore").Firestore} fs
 * @param {string} ownerUid
 */
async function resolveFleetForOwnerAuth(db, fs, ownerUid) {
  const uid = normUid(ownerUid);
  if (!uid) {
    return { ok: false, reason: "unauthorized" };
  }
  const entries = await loadFleetOwnerIndex(db, uid);
  const businessIds = Object.keys(entries);
  if (!businessIds.length) {
    return { ok: false, reason: "not_found" };
  }

  /** @type {Record<string, Record<string, unknown>>} */
  const merchantsById = {};
  for (const businessId of businessIds) {
    const snap = await fs.collection("merchants").doc(businessId).get();
    if (!snap.exists) {
      continue;
    }
    const m = snap.data() || {};
    if (rowOwnerUid(m) !== uid) {
      continue;
    }
    merchantsById[businessId] = m;
  }

  const chosenId = pickFleetBusinessId(entries, merchantsById);
  if (!chosenId) {
    return { ok: false, reason: "not_found" };
  }

  const data = merchantsById[chosenId];
  if (!isDispatchFleetAccount(data)) {
    return { ok: false, reason: "not_found" };
  }

  return {
    ok: true,
    id: chosenId,
    data,
    ref: fs.collection("merchants").doc(chosenId),
  };
}

function validateDispatchProfileInput(data, opts = {}) {
  const vehicle = normalizeDispatchVehicleType(data?.dispatch_vehicle_type ?? data?.dispatchVehicleType);
  if (!vehicle) {
    return { ok: false, reason: "invalid_dispatch_vehicle_type" };
  }
  const ownership = normalizeOwnershipMode(data?.ownership_mode ?? data?.ownershipMode);
  if (!ownership) {
    return { ok: false, reason: "invalid_ownership_mode" };
  }
  const businessId = trimStr(data?.business_id ?? data?.businessId, 128);
  if (ownership === "business_managed" && !businessId && opts.allowMissingBusinessId !== true) {
    return { ok: false, reason: "business_id_required" };
  }
  if (ownership === "individual" && businessId) {
    return { ok: false, reason: "business_id_not_allowed_for_individual" };
  }
  return {
    ok: true,
    dispatch_vehicle_type: vehicle,
    ownership_mode: ownership,
    business_id: businessId || null,
  };
}

function rowOwnerUid(m) {
  return normUid(m?.owner_uid ?? m?.ownerUid);
}

/**
 * @param {string} merchantId
 * @param {Record<string, unknown>} m
 * @param {object | null} readiness
 */
function firestoreMs(v) {
  if (v == null) {
    return null;
  }
  if (typeof v.toMillis === "function") {
    return v.toMillis();
  }
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

/**
 * Callable-safe JSON (no Firestore Timestamp / DocumentSnapshot leakage).
 * @param {unknown} value
 */
function toCallableJson(value) {
  if (value == null) {
    return null;
  }
  if (typeof value.toMillis === "function") {
    return value.toMillis();
  }
  if (Array.isArray(value)) {
    return value.map((item) => toCallableJson(item));
  }
  if (typeof value === "object") {
    /** @type {Record<string, unknown>} */
    const out = {};
    for (const [k, v] of Object.entries(value)) {
      if (v === undefined) {
        continue;
      }
      out[k] = toCallableJson(v);
    }
    return out;
  }
  return value;
}

/**
 * @param {unknown} err
 */
function firestoreIndexErrorInfo(err) {
  const code = Number(err?.code);
  const details = String(err?.details || err?.message || "");
  if (code !== 9 && !details.includes("requires an index")) {
    return null;
  }
  const match = details.match(/https:\/\/console\.firebase\.google\.com[^\s'"]+/);
  return {
    reason: "firestore_index_required",
    index_url: match ? match[0] : null,
    message:
      "Firestore composite index required for Dispatch Fleet admin list query.",
  };
}

/**
 * Admin list/detail payload — no commerce or document blobs.
 * @param {string} merchantId
 * @param {Record<string, unknown>} m
 */
function buildFleetAdminAccountRow(merchantId, m) {
  return {
    business_id: merchantId,
    business_name: trimStr(m.business_name ?? m.businessName, 200),
    owner_name: trimStr(m.owner_name ?? m.ownerName, 120) || null,
    contact_email: trimStr(m.contact_email ?? m.contactEmail, 200).toLowerCase() || null,
    phone: trimStr(m.phone ?? m.phoneNumber, 40) || null,
    address: trimStr(m.address ?? m.business_address, 500) || null,
    city_id: trimStr(m.city_id ?? m.cityId, 120) || null,
    region_id: trimStr(m.region_id ?? m.regionId, 80) || null,
    verification_type:
      fleetVerification.normalizeFleetVerificationType(
        m.verification_type ?? m.verificationType,
      ) || "cac_business",
    merchant_status: merchantStatusOf(m) || "pending_documents",
    verification_status: verificationStatusOf(m) || "pending_documents",
    required_documents_complete: m.required_documents_complete === true,
    rejection_reason:
      trimStr(m.rejection_reason ?? m.rejectionReason ?? m.review_note, 2000) || null,
    created_at: firestoreMs(m.created_at),
    updated_at: firestoreMs(m.updated_at),
  };
}

function buildFleetSafeAccountPayload(merchantId, m, readiness) {
  return {
    business_id: merchantId,
    business_name: trimStr(m.business_name ?? m.businessName, 200),
    account_kind: ACCOUNT_KIND_DISPATCH_FLEET,
    verification_type:
      fleetVerification.normalizeFleetVerificationType(
        m.verification_type ?? m.verificationType,
      ) || "cac_business",
    merchant_status: merchantStatusOf(m) || "pending_documents",
    verification_status: verificationStatusOf(m) || "pending_documents",
    rejection_reason:
      trimStr(m.rejection_reason ?? m.rejectionReason ?? m.review_note, 2000) || null,
    owner_name: trimStr(m.owner_name ?? m.ownerName, 120) || null,
    contact_email: trimStr(m.contact_email ?? m.contactEmail, 200).toLowerCase() || null,
    phone: trimStr(m.phone ?? m.phoneNumber, 40) || null,
    address: trimStr(m.address ?? m.business_address, 500) || null,
    region_id: trimStr(m.region_id ?? m.regionId, 80) || null,
    city_id: trimStr(m.city_id ?? m.cityId, 120) || null,
    required_documents_complete: m.required_documents_complete === true,
    docs_readiness: readiness
      ? {
          allowed: Boolean(readiness.allowed),
          all_submitted: Boolean(readiness.allSubmitted),
          missing_requirements: Array.isArray(readiness.missingRequirements)
            ? readiness.missingRequirements.slice(0, 40)
            : [],
          missing_submissions: Array.isArray(readiness.missingSubmissions)
            ? readiness.missingSubmissions.slice(0, 40)
            : [],
          required_document_types: Array.isArray(readiness.required_document_types)
            ? readiness.required_document_types.slice(0, 20)
            : [],
          readable_message: readiness.readableMessage
            ? trimStr(readiness.readableMessage, 2000)
            : null,
          document_statuses:
            readiness.documentStatuses && typeof readiness.documentStatuses === "object"
              ? { ...readiness.documentStatuses }
              : {},
        }
      : null,
  };
}

/**
 * @param {object} data
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} db
 */
async function dispatchFleetRegister(data, context, db) {
  const uid = normUid(context?.auth?.uid);
  if (!uid) {
    return { success: false, reason: "unauthorized" };
  }

  const businessName = trimStr(data?.business_name ?? data?.businessName, 200);
  if (businessName.length < 2) {
    return { success: false, reason: "invalid_business_name" };
  }

  const contactEmail = trimStr(
    data?.contact_email ?? data?.contactEmail ?? context.auth?.token?.email,
    200,
  ).toLowerCase();
  const ownerName = trimStr(data?.owner_name ?? data?.ownerName, 120);
  const phone = trimStr(data?.phone ?? data?.phoneNumber, 40);
  const address = trimStr(data?.address ?? data?.business_address, 500);
  const regionId = trimStr(data?.region_id ?? data?.regionId, 80) || null;
  const cityId = trimStr(data?.city_id ?? data?.cityId, 120) || null;
  const verificationType =
    fleetVerification.normalizeFleetVerificationType(
      data?.verification_type ?? data?.verificationType,
    ) || "cac_business";

  const fs = resolveFirestore();
  const existingFleetId = await ownerHasBlockingFleetFromIndex(db, fs, uid);
  if (existingFleetId) {
    return {
      success: false,
      reason: "fleet_account_already_exists",
      business_id: existingFleetId,
    };
  }

  const ref = fs.collection("merchants").doc();
  const merchantId = ref.id;
  const now = FieldValue.serverTimestamp();
  const row = {
    merchant_id: merchantId,
    account_kind: ACCOUNT_KIND_DISPATCH_FLEET,
    owner_uid: uid,
    created_by: uid,
    business_name: businessName,
    owner_name: ownerName || null,
    contact_email: contactEmail || trimStr(context.auth?.token?.email, 200).toLowerCase() || null,
    phone: phone || null,
    address: address || null,
    region_id: regionId,
    city_id: cityId,
    verification_type: verificationType,
    category: "Dispatch Fleet",
    business_type: ACCOUNT_KIND_DISPATCH_FLEET,
    merchant_status: "pending_documents",
    status: "pending_documents",
    verification_status: "incomplete",
    is_open: false,
    accepting_orders: false,
    availability_status: "closed",
    closed_reason: null,
    payment_model: "subscription",
    subscription_status: "inactive",
    subscription_amount: 0,
    subscription_currency: "NGN",
    commission_rate: 0,
    commission_exempt: true,
    withdrawal_percent: 0,
    required_documents_complete: false,
    document_statuses: {},
    readiness_missing_requirements: [],
    rejection_reason: null,
    review_note: null,
    approved_at: null,
    approved_by: null,
    reviewed_at: null,
    reviewed_by: null,
    admin_note: null,
    created_at: now,
    updated_at: now,
  };

  await ref.set(row);

  const createdAtMs = nowMs();
  await writeFleetOwnerIndexEntry(db, uid, merchantId, {
    business_id: merchantId,
    account_kind: ACCOUNT_KIND_DISPATCH_FLEET,
    status: "pending_documents",
    created_at: createdAtMs,
  });

  await writeAdminAuditLog(db, {
    actor_uid: uid,
    action: "dispatch_fleet_registered",
    entity_type: "dispatch_fleet_account",
    entity_id: merchantId,
    after: {
      business_id: merchantId,
      account_kind: ACCOUNT_KIND_DISPATCH_FLEET,
      verification_type: verificationType,
      merchant_status: "pending_documents",
      verification_status: "incomplete",
    },
    reason: "dispatch_fleet_registered",
    source: "business_fleet_callables.dispatchFleetRegister",
    type: "DISPATCH_FLEET_REGISTERED",
  });

  console.log("DISPATCH_FLEET_REGISTERED", `businessId=${merchantId}`, `ownerUid=${uid}`);

  return {
    success: true,
    business_id: merchantId,
    merchant_status: "pending_documents",
    verification_status: "incomplete",
    verification_type: verificationType,
    account_kind: ACCOUNT_KIND_DISPATCH_FLEET,
  };
}

/**
 * @param {object} data
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} db
 */
async function dispatchFleetGetMyAccount(data, context, db) {
  const uid = normUid(context?.auth?.uid);
  if (!uid) {
    return { success: false, reason: "unauthorized" };
  }

  const fs = resolveFirestore();
  const resolved = await resolveFleetForOwnerAuth(db, fs, uid);
  if (!resolved.ok) {
    return { success: false, reason: resolved.reason || "not_found" };
  }

  const m = resolved.data || {};

  const gate = merchantVerification.assertMerchantPortalAllowed(m, uid, [
    "owner",
    "manager",
  ]);
  if (!gate.ok) {
    return { success: false, reason: gate.reason || "forbidden" };
  }

  let readiness = null;
  try {
    readiness = await fleetVerification.getFleetReadiness(resolved.id);
  } catch (e) {
    console.warn(
      "DISPATCH_FLEET_ACCOUNT_READ readiness_failed",
      `businessId=${resolved.id}`,
      String(e?.message || e),
    );
  }

  const account = buildFleetSafeAccountPayload(resolved.id, m, readiness);

  await writeAdminAuditLog(db, {
    actor_uid: uid,
    action: "dispatch_fleet_account_read",
    entity_type: "dispatch_fleet_account",
    entity_id: resolved.id,
    after: {
      business_id: resolved.id,
      merchant_status: account.merchant_status,
      verification_status: account.verification_status,
    },
    reason: "dispatch_fleet_account_read",
    source: "business_fleet_callables.dispatchFleetGetMyAccount",
    type: "DISPATCH_FLEET_ACCOUNT_READ",
  });

  console.log("DISPATCH_FLEET_ACCOUNT_READ", `businessId=${resolved.id}`, `actorUid=${uid}`);

  return {
    success: true,
    account,
  };
}

async function businessCreateDriverInvite(data, context, db) {
  if (!context?.auth?.uid) {
    return { success: false, reason: "unauthorized" };
  }
  const fs = resolveFirestore();
  const actorUid = normUid(context.auth.uid);
  const resolved = await resolveFleetForOwnerAuth(db, fs, actorUid);
  if (!resolved.ok) {
    return { success: false, reason: resolved.reason || "forbidden" };
  }
  const m = resolved.data || {};
  const gate = merchantVerification.assertMerchantPortalAllowed(m, actorUid, [
    "owner",
    "manager",
  ]);
  if (!gate.ok) {
    return { success: false, reason: gate.reason || "forbidden" };
  }

  if (!isDispatchFleetAccount(m)) {
    await writeAdminAuditLog(db, {
      actor_uid: actorUid,
      action: "dispatch_fleet_invite_blocked",
      entity_type: "dispatch_fleet_account",
      entity_id: resolved.id,
      after: {
        business_id: resolved.id,
        account_kind: trimStr(m.account_kind, 64) || null,
      },
      reason: "not_dispatch_fleet",
      source: "business_fleet_callables.businessCreateDriverInvite",
      type: "DISPATCH_FLEET_INVITE_BLOCKED_NOT_APPROVED",
    });
    return { success: false, reason: "not_dispatch_fleet" };
  }

  if (merchantStatusOf(m) === "suspended") {
    return { success: false, reason: "fleet_suspended" };
  }

  if (!fleetAccountApprovedForInvites(m)) {
    await writeAdminAuditLog(db, {
      actor_uid: actorUid,
      action: "dispatch_fleet_invite_blocked",
      entity_type: "dispatch_fleet_account",
      entity_id: resolved.id,
      after: {
        business_id: resolved.id,
        merchant_status: merchantStatusOf(m),
        verification_status: verificationStatusOf(m),
        required_documents_complete: m.required_documents_complete === true,
      },
      reason: "fleet_not_approved",
      source: "business_fleet_callables.businessCreateDriverInvite",
      type: "DISPATCH_FLEET_INVITE_BLOCKED_NOT_APPROVED",
    });
    console.log(
      "DISPATCH_FLEET_INVITE_BLOCKED_NOT_APPROVED",
      `businessId=${resolved.id}`,
      `merchantStatus=${merchantStatusOf(m)}`,
      `verificationStatus=${verificationStatusOf(m)}`,
    );
    return { success: false, reason: "fleet_not_approved" };
  }

  const profile = validateDispatchProfileInput(
    {
      dispatch_vehicle_type: data?.dispatch_vehicle_type ?? data?.dispatchVehicleType,
      ownership_mode: "business_managed",
      business_id: resolved.id,
    },
    { allowMissingBusinessId: false },
  );
  if (!profile.ok) {
    return { success: false, reason: profile.reason };
  }

  const code = trimStr(data?.invite_code ?? data?.inviteCode, 64) || buildInviteCode();
  const ttlMs = Number(data?.ttl_ms ?? data?.ttlMs ?? 1000 * 60 * 60 * 24 * 7);
  const expiresAt = nowMs() + Math.max(60 * 1000, Math.min(ttlMs, 1000 * 60 * 60 * 24 * 14));
  const targetDriverId = normUid(data?.driver_id ?? data?.driverId);
  const ref = inviteRef(db, code);
  const existingSnap = await ref.get();
  const existing = existingSnap.val();
  if (existing && typeof existing === "object" && Number(existing.expires_at ?? 0) > nowMs()) {
    return { success: false, reason: "invite_already_exists", invite_code: code };
  }

  const row = {
    invite_code: code,
    business_id: resolved.id,
    owner_uid: actorUid,
    dispatch_vehicle_type: profile.dispatch_vehicle_type,
    ownership_mode: "business_managed",
    target_driver_id: targetDriverId || null,
    status: "pending",
    created_at: nowMs(),
    updated_at: nowMs(),
    expires_at: expiresAt,
    redeemed_by: null,
    redeemed_at: null,
  };
  await ref.set(row);
  await writeAdminAuditLog(db, {
    actor_uid: actorUid,
    action: "business_driver_invite_created",
    entity_type: "business_driver_invite",
    entity_id: code,
    after: row,
    reason: "business_driver_invite_created",
    source: "business_fleet_callables.businessCreateDriverInvite",
    type: "BUSINESS_DRIVER_INVITE_CREATED",
  });
  console.log(
    "BUSINESS_DRIVER_INVITE_CREATED",
    `businessId=${resolved.id}`,
    `inviteCode=${code}`,
    `vehicle=${profile.dispatch_vehicle_type}`,
    `targetDriver=${targetDriverId || ""}`,
  );
  return {
    success: true,
    invite_code: code,
    business_id: resolved.id,
    expires_at: expiresAt,
    dispatch_vehicle_type: profile.dispatch_vehicle_type,
    ownership_mode: "business_managed",
  };
}

async function driverRedeemBusinessInvite(data, context, db) {
  if (!context?.auth?.uid) {
    return { success: false, reason: "unauthorized" };
  }
  const driverId = normUid(context.auth.uid);
  const inviteCode = trimStr(data?.invite_code ?? data?.inviteCode, 64);
  if (!inviteCode) {
    return { success: false, reason: "invalid_invite_code" };
  }
  const ref = inviteRef(db, inviteCode);
  const now = nowMs();
  let invite = null;
  let txReason = "unknown";
  let txAlreadyRedeemedBySameDriver = false;
  const tx = await ref.transaction((cur) => {
    if (!cur || typeof cur !== "object") {
      txReason = "invalid_invite";
      return;
    }
    const expiresAt = Number(cur.expires_at ?? 0);
    if (!(expiresAt > now)) {
      txReason = "invite_expired";
      return;
    }
    const targetDriver = normUid(cur.target_driver_id);
    if (targetDriver && targetDriver !== driverId) {
      txReason = "invite_not_for_driver";
      return;
    }
    const status = trimStr(cur.status, 40).toLowerCase();
    const redeemedBy = normUid(cur.redeemed_by);
    if (status === "redeemed") {
      if (redeemedBy === driverId) {
        txAlreadyRedeemedBySameDriver = true;
        txReason = "already_redeemed_by_same_driver";
        invite = cur;
        return cur;
      }
      txReason = "invite_already_redeemed";
      return;
    }
    const businessId = trimStr(cur.business_id, 128);
    const profile = validateDispatchProfileInput({
      dispatch_vehicle_type: cur.dispatch_vehicle_type,
      ownership_mode: "business_managed",
      business_id: businessId,
    });
    if (!profile.ok) {
      txReason = profile.reason;
      return;
    }
    invite = {
      ...cur,
      status: "redeemed",
      redeemed_by: driverId,
      redeemed_at: now,
      updated_at: now,
    };
    txReason = "redeemed";
    return invite;
  });
  if (!tx.committed) {
    console.log("BUSINESS_DRIVER_LINK_REJECTED", `driverId=${driverId}`, `inviteCode=${inviteCode}`, `reason=${txReason}`);
    await writeAdminAuditLog(db, {
      actor_uid: driverId,
      action: "business_driver_link_rejected",
      entity_type: "business_driver_invite",
      entity_id: inviteCode,
      after: {
        invite_code: inviteCode,
      },
      reason: txReason,
      source: "business_fleet_callables.driverRedeemBusinessInvite",
      type: "BUSINESS_DRIVER_LINK_REJECTED",
    });
    return { success: false, reason: txReason === "unknown" ? "invalid_invite" : txReason };
  }
  if (!invite || typeof invite !== "object") {
    const txVal = tx.snapshot?.val?.();
    invite = txVal && typeof txVal === "object" ? txVal : null;
  }
  if (!invite || typeof invite !== "object") {
    return { success: false, reason: "invalid_invite" };
  }
  const businessId = trimStr(invite.business_id, 128);
  const profile = validateDispatchProfileInput({
    dispatch_vehicle_type: invite.dispatch_vehicle_type,
    ownership_mode: "business_managed",
    business_id: businessId,
  });
  if (!profile.ok) {
    return { success: false, reason: profile.reason };
  }

  const driverSnap = await db.ref(`drivers/${driverId}`).get();
  const existing = driverSnap.val() && typeof driverSnap.val() === "object" ? driverSnap.val() : {};
  const existingBusinessId = trimStr(existing.business_id ?? existing.businessId, 128);
  const existingMode = normalizeOwnershipMode(existing.ownership_mode ?? existing.ownershipMode);
  if (
    existingMode === "business_managed" &&
    existingBusinessId &&
    existingBusinessId !== businessId
  ) {
    console.log(
      "BUSINESS_DRIVER_LINK_REJECTED",
      `driverId=${driverId}`,
      `inviteCode=${inviteCode}`,
      "reason=driver_linked_to_another_business",
    );
    return { success: false, reason: "driver_linked_to_another_business" };
  }
  const alreadyLinked =
    existingMode === "business_managed" &&
    existingBusinessId === businessId &&
    existing.business_link_status === "approved";

  const updates = {
    [`drivers/${driverId}/dispatch_vehicle_type`]: profile.dispatch_vehicle_type,
    [`drivers/${driverId}/ownership_mode`]: "business_managed",
    [`drivers/${driverId}/business_id`]: businessId,
    [`drivers/${driverId}/dispatch_verified`]: Boolean(existing.dispatch_verified === true),
    [`drivers/${driverId}/dispatch_verification_status`]:
      trimStr(existing.dispatch_verification_status, 40) || "pending",
    [`drivers/${driverId}/business_link_status`]: "approved",
    [`drivers/${driverId}/updated_at`]: now,
    [`business_driver_links/${businessId}/${driverId}`]: {
      driver_id: driverId,
      business_id: businessId,
      status: "approved",
      ownership_mode: "business_managed",
      dispatch_vehicle_type: profile.dispatch_vehicle_type,
      linked_at: now,
      linked_by: normUid(invite.owner_uid) || null,
      invite_code: inviteCode,
      updated_at: now,
    },
  };
  await db.ref().update(updates);
  await writeAdminAuditLog(db, {
    actor_uid: driverId,
    action: "business_driver_link_redeemed",
    entity_type: "driver",
    entity_id: driverId,
    before: {
      ownership_mode: existingMode || null,
      business_id: existingBusinessId || null,
      business_link_status: trimStr(existing.business_link_status, 40) || null,
    },
    after: {
      ownership_mode: "business_managed",
      business_id: businessId,
      invite_code: inviteCode,
      target_driver_id: driverId,
      business_link_status: "approved",
      dispatch_vehicle_type: profile.dispatch_vehicle_type,
    },
    reason: "business_driver_link_redeemed",
    source: "business_fleet_callables.driverRedeemBusinessInvite",
    type: "BUSINESS_DRIVER_LINK_REDEEMED",
  });
  console.log(
    "BUSINESS_DRIVER_LINK_REDEEMED",
    `driverId=${driverId}`,
    `businessId=${businessId}`,
    `inviteCode=${inviteCode}`,
    `idempotent=${alreadyLinked}`,
  );
  // Observe-only identity claim refresh. Best-effort; never blocks the link.
  try {
    await workerIdentity.runWorkerIdentityDuplicateCheck(db, driverId, { now });
  } catch (e) {
    console.log(
      "WORKER_IDENTITY_CHECK_SKIPPED",
      `driverId=${driverId}`,
      `source=fleet_redeem`,
      `reason=${String((e && e.message) || e)}`,
    );
  }
  return {
    success: true,
    reason: alreadyLinked ? "already_linked" : "linked",
    business_id: businessId,
    driver_id: driverId,
    ownership_mode: "business_managed",
    dispatch_vehicle_type: profile.dispatch_vehicle_type,
    idempotent: alreadyLinked || txAlreadyRedeemedBySameDriver,
  };
}

function driverDisplayNameFromProfile(d) {
  if (!d || typeof d !== "object") {
    return null;
  }
  const name = trimStr(
    d.name ?? d.displayName ?? d.driver_name ?? d.full_name ?? d.display_name,
    120,
  );
  return name || null;
}

function driverOnlineFromProfile(d) {
  if (!d || typeof d !== "object") {
    return false;
  }
  return d.isOnline === true || d.is_online === true || d.online === true;
}

/**
 * @param {import("firebase-admin/database").Database} db
 * @param {string} businessId
 * @param {string} driverId
 * @param {Record<string, unknown> | null | undefined} linkRow
 */
async function buildLinkedDriverItem(db, businessId, driverId, linkRow) {
  const row = linkRow && typeof linkRow === "object" ? linkRow : {};
  /** @type {Record<string, unknown>} */
  const item = {
    driver_id: driverId,
    business_id: businessId,
    business_link_status: trimStr(row.status, 40) || "approved",
    ownership_mode:
      normalizeOwnershipMode(row.ownership_mode ?? row.ownershipMode) || "business_managed",
    dispatch_vehicle_type:
      normalizeDispatchVehicleType(row.dispatch_vehicle_type ?? row.dispatchVehicleType) || null,
    linked_at: Number(row.linked_at ?? row.linkedAt) || null,
  };

  const driverSnap = await db.ref(`drivers/${driverId}`).get();
  const d = driverSnap.val();
  if (d && typeof d === "object") {
    item.driver_name = driverDisplayNameFromProfile(d);
    item.phone = trimStr(d.phone, 40) || null;
    item.online = driverOnlineFromProfile(d);
    const profileVehicle = normalizeDispatchVehicleType(
      d.dispatch_vehicle_type ?? d.dispatchVehicleType,
    );
    if (profileVehicle) {
      item.dispatch_vehicle_type = profileVehicle;
    }
    const bls = trimStr(d.business_link_status ?? d.businessLinkStatus, 40);
    if (bls) {
      item.business_link_status = bls;
    }
    const mode = normalizeOwnershipMode(d.ownership_mode ?? d.ownershipMode);
    if (mode) {
      item.ownership_mode = mode;
    }
  }

  return item;
}

/**
 * @param {unknown} linksVal
 */
function computeLinkedDriversSummary(linksVal) {
  if (!linksVal || typeof linksVal !== "object") {
    return {
      total_linked_bikers: 0,
      active_linked_bikers: 0,
    };
  }
  const rows = Object.values(linksVal);
  let active = 0;
  for (const row of rows) {
    const status = trimStr(row?.status, 40).toLowerCase();
    if (!status || status === "approved" || status === "active") {
      active += 1;
    }
  }
  return {
    total_linked_bikers: rows.length,
    active_linked_bikers: active,
  };
}

/**
 * Paginated keyed read of business_driver_links/{businessId} with optional driver enrichment.
 * @param {import("firebase-admin/database").Database} db
 * @param {string} businessId
 * @param {object} data
 * @param {{ allowSummary?: boolean }} [opts]
 */
async function listLinkedDriversPageInternal(db, businessId, data, opts = {}) {
  const bid = trimStr(businessId, 128);
  if (!bid) {
    return { success: false, reason: "invalid_input" };
  }

  const limit = Math.min(50, Math.max(1, Number(data?.limit ?? 25) || 25));
  const cursorDriverId = trimStr(data?.cursor_driver_id ?? data?.cursorDriverId, 128);
  const includeSummary =
    opts.allowSummary === true &&
    (data?.include_summary === true || data?.includeSummary === true) &&
    !cursorDriverId;

  let query = db.ref(`business_driver_links/${bid}`).orderByKey();
  if (cursorDriverId) {
    query = query.startAfter(cursorDriverId);
  }
  const snap = await query.limitToFirst(limit + 1).get();
  const val = snap.val();
  /** @type {[string, Record<string, unknown>][]} */
  const entries = [];
  if (val && typeof val === "object") {
    const keys = Object.keys(val).sort();
    for (const driverId of keys) {
      const row = val[driverId];
      entries.push([driverId, row && typeof row === "object" ? row : {}]);
    }
  }

  const pageEntries = entries.slice(0, limit);
  const hasMore = entries.length > limit;
  const items = [];
  for (const [driverId, linkRow] of pageEntries) {
    items.push(await buildLinkedDriverItem(db, bid, driverId, linkRow));
  }

  /** @type {Record<string, unknown>} */
  const result = {
    success: true,
    items,
    next_cursor_driver_id:
      hasMore && pageEntries.length ? pageEntries[pageEntries.length - 1][0] : null,
    has_more: hasMore,
  };

  if (includeSummary) {
    const allSnap = await db.ref(`business_driver_links/${bid}`).get();
    result.summary = computeLinkedDriversSummary(allSnap.val());
  }

  return toCallableJson(result);
}

/**
 * @param {object} data
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} db
 */
async function fleetListLinkedDriversPage(data, context, db) {
  if (!context?.auth?.uid) {
    return { success: false, reason: "unauthorized" };
  }

  const fs = resolveFirestore();
  const actorUid = normUid(context.auth.uid);
  const resolved = await resolveFleetForOwnerAuth(db, fs, actorUid);
  if (!resolved.ok) {
    return { success: false, reason: resolved.reason || "not_found" };
  }

  const m = resolved.data || {};
  const gate = merchantVerification.assertMerchantPortalAllowed(m, actorUid, [
    "owner",
    "manager",
  ]);
  if (!gate.ok) {
    return { success: false, reason: gate.reason || "forbidden" };
  }

  if (!isDispatchFleetAccount(m)) {
    return { success: false, reason: "not_dispatch_fleet" };
  }

  console.log(
    "FLEET_LINKED_DRIVERS_LIST",
    `businessId=${resolved.id}`,
    `actorUid=${actorUid}`,
  );

  return listLinkedDriversPageInternal(db, resolved.id, data, { allowSummary: true });
}

/**
 * @param {object} data
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} db
 */
async function adminListFleetLinkedDriversPage(data, context, db) {
  const deny = await adminPerms.enforceCallable(db, context, "adminListFleetLinkedDriversPage");
  if (deny) {
    return deny;
  }

  const businessId = trimStr(data?.business_id ?? data?.businessId, 128);
  if (!businessId) {
    return { success: false, reason: "invalid_input" };
  }

  const fs = resolveFirestore();
  const snap = await fs.collection("merchants").doc(businessId).get();
  if (!snap.exists) {
    return { success: false, reason: "not_found" };
  }
  const m = snap.data() || {};
  if (!isDispatchFleetAccount(m)) {
    return { success: false, reason: "not_dispatch_fleet" };
  }

  console.log(
    "ADMIN_FLEET_LINKED_DRIVERS_LIST",
    `businessId=${businessId}`,
    `adminUid=${normUid(context?.auth?.uid)}`,
  );

  return listLinkedDriversPageInternal(db, businessId, data, { allowSummary: false });
}

/**
 * @param {object} data
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} db
 */
async function adminListDispatchFleetPage(data, context, db) {
  const deny = await adminPerms.enforceCallable(db, context, "adminListDispatchFleetPage");
  if (deny) {
    return deny;
  }

  const limit = Math.min(50, Math.max(1, Number(data?.limit ?? 25) || 25));
  const statusFilter = trimStr(data?.status ?? data?.merchant_status, 40).toLowerCase();
  const cursorCreatedAt = Number(data?.cursor_created_at ?? data?.cursorCreatedAt);
  const cursorId = trimStr(data?.cursor_id ?? data?.cursorId, 128);

  if (statusFilter && !FLEET_ADMIN_STATUS_FILTERS.has(statusFilter)) {
    return { success: false, reason: "invalid_status_filter" };
  }

  const fs = resolveFirestore();
  let q = fs.collection("merchants").where("account_kind", "==", ACCOUNT_KIND_DISPATCH_FLEET);
  if (statusFilter && statusFilter !== "all") {
    q = q.where("merchant_status", "==", statusFilter);
  }
  q = q.orderBy("created_at", "desc").orderBy(admin.firestore.FieldPath.documentId(), "desc");

  if (Number.isFinite(cursorCreatedAt) && cursorCreatedAt > 0 && cursorId) {
    q = q.startAfter(admin.firestore.Timestamp.fromMillis(cursorCreatedAt), cursorId);
  }

  let snap;
  try {
    snap = await q.limit(limit + 1).get();
  } catch (err) {
    const indexErr = firestoreIndexErrorInfo(err);
    if (indexErr) {
      console.warn(
        "DISPATCH_FLEET_ADMIN_LIST_INDEX_REQUIRED",
        `statusFilter=${statusFilter || "all"}`,
        indexErr.index_url || "",
      );
      return { success: false, ...indexErr };
    }
    throw err;
  }

  const docs = snap.docs.slice(0, limit);
  const accounts = docs.map((d) => buildFleetAdminAccountRow(d.id, d.data() || {}));
  const last = docs.length > 0 ? docs[docs.length - 1] : null;
  const nextCursor =
    snap.docs.length > limit && last
      ? {
          cursor_created_at: firestoreMs(last.data()?.created_at),
          cursor_id: last.id,
        }
      : null;

  return toCallableJson({
    success: true,
    accounts,
    has_more: snap.docs.length > limit,
    next_cursor: nextCursor,
  });
}

/**
 * @param {object} data
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} db
 */
async function adminGetDispatchFleetAccount(data, context, db) {
  const deny = await adminPerms.enforceCallable(db, context, "adminGetDispatchFleetAccount");
  if (deny) {
    return deny;
  }

  const businessId = trimStr(data?.business_id ?? data?.businessId, 128);
  if (!businessId) {
    return { success: false, reason: "invalid_business_id" };
  }

  const fs = resolveFirestore();
  const snap = await fs.collection("merchants").doc(businessId).get();
  if (!snap.exists) {
    return { success: false, reason: "not_found" };
  }
  const m = snap.data() || {};
  if (!isDispatchFleetAccount(m)) {
    return { success: false, reason: "not_dispatch_fleet" };
  }

  const verification = await fleetVerification.enrichFleetAdminVerification(snap.id, m);

  return toCallableJson({
    success: true,
    account: {
      ...buildFleetAdminAccountRow(snap.id, m),
      ...verification,
    },
  });
}

/**
 * @param {object} data
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} db
 */
async function fleetUploadVerificationDocument(data, context, db) {
  const uid = normUid(context?.auth?.uid);
  if (!uid) {
    return { success: false, reason: "unauthorized" };
  }

  const fs = resolveFirestore();
  const resolved = await resolveFleetForOwnerAuth(db, fs, uid);
  if (!resolved.ok) {
    return {
      success: false,
      reason: resolved.reason === "not_found" ? "not_found" : "unauthorized",
    };
  }

  const m = resolved.data || {};
  if (merchantStatusOf(m) === "suspended") {
    return { success: false, reason: "fleet_suspended" };
  }

  const documentType = trimStr(data?.document_type ?? data?.documentType, 64).toLowerCase();
  if (!fleetVerification.isFleetDocumentType(documentType)) {
    return { success: false, reason: "invalid_document_type" };
  }
  if (!fleetVerification.documentAllowedForMerchant(m, documentType)) {
    return { success: false, reason: "document_not_required_for_verification_type" };
  }

  const storagePath = trimStr(data?.storage_path ?? data?.storagePath, 1024);
  const fileNameIn = trimStr(data?.file_name ?? data?.fileName, 256);
  const contentType = trimStr(data?.content_type ?? data?.contentType, 128).toLowerCase();

  const prefix = `fleet_verification_uploads/${resolved.id}/${documentType}/`;
  if (!storagePath.startsWith(prefix) || storagePath.includes("..")) {
    return { success: false, reason: "invalid_storage_path" };
  }
  const lastSeg = storagePath.slice(prefix.length);
  if (!lastSeg || lastSeg.includes("/")) {
    return { success: false, reason: "invalid_storage_path" };
  }

  const typeValidation = fleetVerification.validateFleetUploadFile({
    contentType,
    fileName: fileNameIn || lastSeg,
  });
  if (!typeValidation.ok) {
    return { success: false, reason: typeValidation.reason };
  }

  const bucket = admin.storage().bucket();
  const file = bucket.file(storagePath);
  const [exists] = await file.exists();
  if (!exists) {
    return { success: false, reason: "storage_object_missing" };
  }

  const [meta] = await file.getMetadata();
  const size = Number(meta.size || 0);
  const storageContentType = trimStr(meta.contentType, 128).toLowerCase();

  const preUploadValidation = fleetVerification.validateFleetUploadFile({
    contentType,
    sizeBytes: size,
    fileName: fileNameIn || lastSeg,
    storageContentType,
  });
  if (!preUploadValidation.ok) {
    return { success: false, reason: preUploadValidation.reason };
  }

  const docRef = fleetVerification.docsCollection(fs, resolved.id).doc(documentType);
  const now = FieldValue.serverTimestamp();
  await docRef.set(
    {
      merchant_id: resolved.id,
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

  const readiness = await fleetVerification.recomputeFleetMerchantReadiness(fs, resolved.id);

  await writeAdminAuditLog(db, {
    actor_uid: uid,
    action: "fleet_verification_document_uploaded",
    entity_type: "dispatch_fleet_account",
    entity_id: resolved.id,
    after: {
      document_type: documentType,
      storage_path: storagePath,
      required_documents_complete: readiness?.allowed === true,
    },
    source: "business_fleet_callables.fleetUploadVerificationDocument",
    type: "FLEET_VERIFICATION_DOCUMENT_UPLOADED",
  });

  return {
    success: true,
    business_id: resolved.id,
    document_type: documentType,
    status: "pending",
    required_documents_complete: readiness?.allowed === true,
    merchant_status: merchantStatusOf(
      (await resolved.ref.get()).data() || {},
    ),
  };
}

/**
 * @param {object} data
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} db
 */
async function fleetListMyVerificationDocuments(data, context, db) {
  const uid = normUid(context?.auth?.uid);
  if (!uid) {
    return { success: false, reason: "unauthorized" };
  }

  const fs = resolveFirestore();
  const resolved = await resolveFleetForOwnerAuth(db, fs, uid);
  if (!resolved.ok) {
    return {
      success: false,
      reason: resolved.reason === "not_found" ? "not_found" : "unauthorized",
    };
  }

  const m = resolved.data || {};
  const readiness = await fleetVerification.getFleetReadiness(resolved.id);
  const requiredTypes = fleetVerification.requiredTypesForMerchant(m);
  const snap = await fleetVerification.docsCollection(fs, resolved.id).get();
  const byId = new Map(snap.docs.map((d) => [d.id, d.data() || {}]));

  /** @type {unknown[]} */
  const documents = [];
  for (const t of requiredTypes) {
    const row = byId.get(t);
    if (!row) {
      documents.push({
        document_type: t,
        label: fleetVerification.FLEET_DOCUMENT_LABELS[t] || t,
        status: "not_submitted",
        storage_path: null,
        file_name: null,
        content_type: null,
        uploaded_at: null,
      });
      continue;
    }
    documents.push({
      document_type: t,
      label: fleetVerification.FLEET_DOCUMENT_LABELS[t] || t,
      status: String(row.status ?? "pending").trim().toLowerCase(),
      storage_path: row.storage_path ?? null,
      file_name: row.file_name ?? null,
      content_type: row.content_type ?? null,
      uploaded_at: row.uploaded_at?.toMillis?.() ?? null,
      rejection_reason: row.rejection_reason ?? null,
    });
  }

  return {
    success: true,
    business_id: resolved.id,
    verification_type:
      fleetVerification.normalizeFleetVerificationType(
        m.verification_type ?? m.verificationType,
      ) || "cac_business",
    documents,
    readiness: readiness
      ? {
          allowed: readiness.allowed,
          all_submitted: readiness.allSubmitted,
          missing_requirements: readiness.missingRequirements,
          missing_submissions: readiness.missingSubmissions,
          document_statuses: { ...readiness.documentStatuses },
          readable_message: readiness.readableMessage,
        }
      : null,
  };
}

/**
 * @param {object} data
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} db
 */
async function adminReviewFleetVerificationDocument(data, context, db) {
  const deny = await adminPerms.enforceCallable(
    db,
    context,
    "adminReviewFleetVerificationDocument",
  );
  if (deny) {
    return deny;
  }

  const adminUid = normUid(context?.auth?.uid);
  const businessId = trimStr(data?.business_id ?? data?.businessId, 128);
  const documentType = trimStr(data?.document_type ?? data?.documentType, 64).toLowerCase();
  const action = trimStr(data?.action, 32).toLowerCase();
  const adminNote = trimStr(data?.admin_note ?? data?.note, 2000);
  const rejectionReason = trimStr(
    data?.rejection_reason ?? data?.rejectionReason,
    2000,
  );

  if (!businessId || !fleetVerification.isFleetDocumentType(documentType)) {
    return { success: false, reason: "invalid_input" };
  }

  let nextStatus = "";
  if (action === "approve") {
    nextStatus = "approved";
  } else if (action === "reject") {
    nextStatus = "rejected";
  } else if (action === "require_resubmit" || action === "resubmission_required") {
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

  const fs = resolveFirestore();
  const mSnap = await fs.collection("merchants").doc(businessId).get();
  if (!mSnap.exists) {
    return { success: false, reason: "not_found" };
  }
  const m = mSnap.data() || {};
  if (!isDispatchFleetAccount(m)) {
    return { success: false, reason: "not_dispatch_fleet" };
  }
  if (!fleetVerification.documentAllowedForMerchant(m, documentType)) {
    return { success: false, reason: "document_not_required_for_verification_type" };
  }

  const docRef = fleetVerification.docsCollection(fs, businessId).doc(documentType);
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

  await fleetVerification.recomputeFleetMerchantReadiness(fs, businessId);

  await writeAdminAuditLog(db, {
    actor_uid: adminUid,
    action: "fleet_verification_document_reviewed",
    entity_type: "dispatch_fleet_account",
    entity_id: businessId,
    after: {
      document_type: documentType,
      status: nextStatus,
    },
    reason: adminNote || rejectionReason || null,
    source: "business_fleet_callables.adminReviewFleetVerificationDocument",
    type: "FLEET_VERIFICATION_DOCUMENT_REVIEWED",
  });

  return {
    success: true,
    business_id: businessId,
    document_type: documentType,
    status: nextStatus,
  };
}

/**
 * @param {object} data
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} db
 */
async function adminReviewDispatchFleet(data, context, db) {
  const deny = await adminPerms.enforceCallable(db, context, "adminReviewDispatchFleet");
  if (deny) {
    return deny;
  }

  const adminUid = normUid(context?.auth?.uid);
  if (!adminUid) {
    return { success: false, reason: "unauthorized" };
  }

  const businessId = trimStr(data?.business_id ?? data?.businessId, 128);
  const action = trimStr(data?.action, 24).toLowerCase();
  const note = trimStr(
    data?.note ?? data?.review_note ?? data?.rejection_reason ?? data?.rejectionReason,
    2000,
  );
  const approvalOverride =
    data?.approval_override === true ||
    data?.override === true ||
    trimStr(data?.approval_override ?? data?.override, 8).toLowerCase() === "true";

  if (!businessId) {
    return { success: false, reason: "invalid_business_id" };
  }
  if (action !== "approve" && action !== "reject" && action !== "suspend") {
    return { success: false, reason: "invalid_action" };
  }
  if ((action === "reject" || action === "suspend") && note.length < 3) {
    return { success: false, reason: "rejection_note_required" };
  }
  if (action === "approve" && approvalOverride && note.length < 3) {
    return { success: false, reason: "override_note_required" };
  }

  const fs = resolveFirestore();
  const ref = fs.collection("merchants").doc(businessId);
  const snap = await ref.get();
  if (!snap.exists) {
    return { success: false, reason: "not_found" };
  }

  const before = snap.data() || {};
  if (!isDispatchFleetAccount(before)) {
    return { success: false, reason: "not_dispatch_fleet" };
  }

  const now = FieldValue.serverTimestamp();
  /** @type {Record<string, unknown>} */
  const patch = {
    updated_at: now,
    reviewed_at: now,
    reviewed_by: adminUid,
    review_note: note || null,
  };

  if (action === "approve") {
    if (!approvalOverride) {
      const readiness = await fleetVerification.getFleetReadiness(businessId);
      if (!readiness || readiness.allowed !== true) {
        return { success: false, reason: "fleet_documents_incomplete" };
      }
      if (before.required_documents_complete !== true) {
        return { success: false, reason: "fleet_documents_incomplete" };
      }
    }
    Object.assign(patch, {
      merchant_status: "approved",
      status: "approved",
      verification_status: approvalOverride ? "approved_override" : "approved",
      rejection_reason: null,
      approved_at: now,
      approved_by: adminUid,
      approval_override: approvalOverride,
      override_note: approvalOverride ? note : null,
    });
  } else if (action === "suspend") {
    Object.assign(patch, {
      merchant_status: "suspended",
      status: "suspended",
      verification_status: verificationStatusOf(before) || "suspended",
      rejection_reason: note || null,
      approved_at: null,
      approved_by: null,
    });
  } else {
    Object.assign(patch, {
      merchant_status: "rejected",
      status: "rejected",
      verification_status: "rejected",
      rejection_reason: note,
      approved_at: null,
      approved_by: null,
    });
  }

  await ref.update(patch);

  const ownerUid = normUid(before.owner_uid);
  if (ownerUid && db) {
    try {
      const indexStatus =
        action === "approve" ? "approved" : action === "suspend" ? "suspended" : "rejected";
      await db.ref(`${FLEET_OWNER_INDEX_ROOT}/${ownerUid}/${businessId}`).update({
        status: indexStatus,
        updated_at: nowMs(),
      });
    } catch (_) {
      /* index best-effort */
    }
  }

  await writeAdminAuditLog(db, {
    actor_uid: adminUid,
    action:
      action === "approve"
        ? approvalOverride
          ? "dispatch_fleet_approved_override"
          : "dispatch_fleet_approved"
        : action === "suspend"
          ? "dispatch_fleet_suspended"
          : "dispatch_fleet_rejected",
    entity_type: "dispatch_fleet_account",
    entity_id: businessId,
    before: {
      merchant_status: merchantStatusOf(before),
      verification_status: verificationStatusOf(before),
      required_documents_complete: before.required_documents_complete === true,
    },
    after: {
      merchant_status: patch.merchant_status,
      verification_status: patch.verification_status,
      rejection_reason: action === "reject" ? note : null,
      approval_override: action === "approve" ? approvalOverride : false,
      override_reason: action === "approve" && approvalOverride ? note : null,
    },
    reason: note || null,
    source: "business_fleet_callables.adminReviewDispatchFleet",
    type: "DISPATCH_FLEET_REVIEWED",
  });

  console.log(
    "DISPATCH_FLEET_REVIEWED",
    `businessId=${businessId}`,
    `action=${action}`,
    `adminUid=${adminUid}`,
    `approvalOverride=${approvalOverride}`,
  );

  return toCallableJson({
    success: true,
    business_id: businessId,
    merchant_status: patch.merchant_status,
    verification_status: patch.verification_status,
    approval_override: action === "approve" ? approvalOverride : false,
  });
}

module.exports = {
  ACCOUNT_KIND_DISPATCH_FLEET,
  FLEET_OWNER_INDEX_ROOT,
  DISPATCH_VEHICLE_TYPES,
  OWNERSHIP_MODES,
  normalizeDispatchVehicleType,
  normalizeOwnershipMode,
  isDispatchFleetAccount,
  fleetManualOverrideApprovedForInvites,
  fleetAccountApprovedForInvites,
  buildFleetSafeAccountPayload,
  buildFleetAdminAccountRow,
  FLEET_ADMIN_STATUS_FILTERS,
  validateDispatchProfileInput,
  loadFleetOwnerIndex,
  resolveFleetForOwnerAuth,
  setFirestoreForTests,
  dispatchFleetRegister,
  dispatchFleetGetMyAccount,
  businessCreateDriverInvite,
  driverRedeemBusinessInvite,
  fleetListLinkedDriversPage,
  adminListFleetLinkedDriversPage,
  listLinkedDriversPageInternal,
  buildLinkedDriverItem,
  computeLinkedDriversSummary,
  adminListDispatchFleetPage,
  adminGetDispatchFleetAccount,
  adminReviewDispatchFleet,
  fleetUploadVerificationDocument,
  fleetListMyVerificationDocuments,
  adminReviewFleetVerificationDocument,
  firestoreIndexErrorInfo,
  toCallableJson,
};
