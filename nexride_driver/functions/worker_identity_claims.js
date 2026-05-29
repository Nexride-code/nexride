/**
 * Anti-duplicate worker identity — Slice A (pure helper library).
 *
 * Low-cost, callable-only identity-claim primitives used to detect when a new
 * dispatch account reuses a duplicate-sensitive identity claim (NIN, BVN, bank
 * account, vehicle plate) belonging to an existing business-managed worker.
 *
 * Design constraints (Slice A):
 * - Pure helpers + keyed reads/writes only. No listeners, no polling, no scans.
 * - No OCR, no Cloud Vision, no AI face matching.
 * - Sensitive values are never stored raw and never logged. Only HMAC-SHA256
 *   digests (keyed by a server pepper) are persisted in the claim index.
 * - This module changes no live behavior on its own; nothing is wired in yet.
 */

const crypto = require("node:crypto");

const CLAIM_VERSION = "v1";

/**
 * Dev/test-only fallback pepper. Production MUST set
 * process.env.WORKER_IDENTITY_CLAIM_PEPPER. The fallback only exists so unit
 * tests and local dev produce stable hashes; it is not a secret.
 */
const DEV_PEPPER_FALLBACK = "nexride_dev_worker_identity_pepper_change_me";

/** Claim types whose collision with a business-managed worker triggers review. */
const DUPLICATE_SENSITIVE_CLAIM_TYPES = new Set([
  "nin",
  "bvn",
  "bank_account",
  "plate",
]);

/** Claim types that only ever raise a soft warning (never auto-block). */
const WARNING_ONLY_CLAIM_TYPES = new Set(["phone"]);

function claimPepper() {
  const v = String(process.env.WORKER_IDENTITY_CLAIM_PEPPER ?? "").trim();
  return v.length > 0 ? v : DEV_PEPPER_FALLBACK;
}

function digitsOnly(v) {
  return String(v ?? "").replace(/\D/g, "");
}

function normalizeOwnershipMode(v) {
  const s = String(v ?? "")
    .trim()
    .toLowerCase();
  return s === "business_managed" || s === "individual" ? s : "";
}

/**
 * Normalizes a Nigerian phone number to E.164 (`+234…`). Returns "" when the
 * value is unusable so it is excluded from the claim set.
 * @param {unknown} v
 * @returns {string}
 */
function normalizePhone(v) {
  let d = digitsOnly(v);
  if (!d) return "";
  if (d.startsWith("00")) {
    d = d.slice(2);
  }
  if (d.startsWith("234")) {
    d = d.slice(3);
  }
  d = d.replace(/^0+/, "");
  if (d.length < 7 || d.length > 11) return "";
  return `+234${d}`;
}

/**
 * Normalizes a Nigerian NIN (11 digits). Returns "" when not exactly 11 digits.
 * @param {unknown} v
 * @returns {string}
 */
function normalizeNin(v) {
  const d = digitsOnly(v);
  return d.length === 11 ? d : "";
}

/**
 * Normalizes a Nigerian BVN (11 digits). Returns "" when not exactly 11 digits.
 * @param {unknown} v
 * @returns {string}
 */
function normalizeBvn(v) {
  const d = digitsOnly(v);
  return d.length === 11 ? d : "";
}

/**
 * Normalizes a bank account claim. Combines the digits-only account number with
 * an optional normalized bank code so the same number at different banks does
 * not collide. Returns "" when the account number is not 8–20 digits.
 * @param {unknown} account
 * @param {unknown} [bankCode]
 * @returns {string}
 */
function normalizeBankAccount(account, bankCode) {
  const acct = digitsOnly(account);
  if (acct.length < 8 || acct.length > 20) return "";
  const code = String(bankCode ?? "")
    .trim()
    .toLowerCase()
    .replace(/\s+/g, "");
  return code ? `${acct}:${code}` : acct;
}

/**
 * Normalizes a vehicle plate to uppercase alphanumerics. Returns "" when the
 * cleaned value is not 4–12 characters.
 * @param {unknown} v
 * @returns {string}
 */
function normalizePlate(v) {
  const s = String(v ?? "")
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, "");
  if (s.length < 4 || s.length > 12) return "";
  return s;
}

/**
 * HMAC-SHA256 digest of a normalized claim. Never returns or contains the raw
 * value. Returns "" when type or value is empty.
 * @param {string} claimType
 * @param {string} normalizedValue
 * @param {string} [pepper]
 * @returns {string}
 */
function hashClaim(claimType, normalizedValue, pepper = claimPepper()) {
  const type = String(claimType ?? "")
    .trim()
    .toLowerCase();
  const value = String(normalizedValue ?? "");
  if (!type || !value) return "";
  return crypto
    .createHmac("sha256", String(pepper))
    .update(`${CLAIM_VERSION}:${type}:${value}`)
    .digest("hex");
}

/**
 * Builds the hashed claim set for a driver from raw inputs. Only present,
 * valid claims are included. Output maps claimType -> hash (no raw values).
 * @param {Record<string, unknown>} [input]
 * @param {string} [pepper]
 * @returns {Record<string, string>}
 */
function buildDriverClaims(input = {}, pepper = claimPepper()) {
  const src = input && typeof input === "object" ? input : {};
  const phone = normalizePhone(src.phone);
  const nin = normalizeNin(src.nin);
  const bvn = normalizeBvn(src.bvn);
  const bankAccount = normalizeBankAccount(
    src.bank_account ?? src.account_number ?? src.accountNumber,
    src.bank_code ?? src.bankCode,
  );
  const plate = normalizePlate(
    src.plate ?? src.plate_number ?? src.vehicle_plate_number,
  );

  /** @type {Record<string, string>} */
  const claims = {};
  if (phone) claims.phone = hashClaim("phone", phone, pepper);
  if (nin) claims.nin = hashClaim("nin", nin, pepper);
  if (bvn) claims.bvn = hashClaim("bvn", bvn, pepper);
  if (bankAccount) claims.bank_account = hashClaim("bank_account", bankAccount, pepper);
  if (plate) claims.plate = hashClaim("plate", plate, pepper);
  return claims;
}

/**
 * Finds other workers sharing any of the given claim hashes, using one keyed
 * read per claim type (no scans, no queries). The caller's own uid is ignored.
 * @param {import("firebase-admin/database").Database} db
 * @param {Record<string, string>} claims
 * @param {string} selfUid
 * @returns {Promise<Record<string, Array<{uid: string, ownership_mode: string, business_id: string|null, business_link_status: string}>>>}
 */
async function findDuplicateWorkerIds(db, claims, selfUid) {
  const self = String(selfUid ?? "").trim();
  /** @type {Record<string, Array<object>>} */
  const matchesByType = {};
  for (const [type, hash] of Object.entries(claims || {})) {
    if (!hash) continue;
    const snap = await db.ref(`worker_identity_claims/${type}/${hash}`).get();
    const val = snap && typeof snap.val === "function" ? snap.val() : null;
    if (!val || typeof val !== "object") continue;
    const list = [];
    for (const [uid, meta] of Object.entries(val)) {
      if (String(uid).trim() === self) continue;
      const m = meta && typeof meta === "object" ? meta : {};
      list.push({
        uid: String(uid),
        ownership_mode: normalizeOwnershipMode(m.ownership_mode ?? m.ownershipMode),
        business_id:
          m.business_id != null && String(m.business_id).trim()
            ? String(m.business_id).trim()
            : null,
        business_link_status: String(m.business_link_status ?? m.businessLinkStatus ?? "")
          .trim()
          .toLowerCase(),
      });
    }
    if (list.length) matchesByType[type] = list;
  }
  return matchesByType;
}

/**
 * Pure decision over the matches returned by {@link findDuplicateWorkerIds}.
 *
 * Rules:
 * - No matches -> clear.
 * - A duplicate-sensitive claim (nin/bvn/bank_account/plate) matching an
 *   existing business_managed worker -> duplicate_review_required (block).
 * - Phone-only matches, or matches against individual workers only -> warning.
 * @param {Record<string, Array<{uid: string, ownership_mode: string, business_id: string|null, business_link_status: string}>>} matchesByType
 */
function evaluateDuplicateReview(matchesByType) {
  const map = matchesByType && typeof matchesByType === "object" ? matchesByType : {};
  const types = Object.keys(map);
  if (types.length === 0) {
    return {
      status: "clear",
      duplicate_review_required: false,
      warning: false,
      matched_claim_types: [],
      blocking_claim_types: [],
      warning_claim_types: [],
      matched_worker_ids: [],
      matched_business_ids: [],
    };
  }

  const blockingTypes = [];
  const warningTypes = [];
  const workerIds = new Set();
  const businessIds = new Set();

  for (const type of types) {
    const list = Array.isArray(map[type]) ? map[type] : [];
    let typeBlocks = false;
    for (const m of list) {
      if (m.uid) workerIds.add(m.uid);
      if (m.business_id) businessIds.add(m.business_id);
      const businessLinked = m.ownership_mode === "business_managed";
      if (businessLinked && DUPLICATE_SENSITIVE_CLAIM_TYPES.has(type)) {
        typeBlocks = true;
      }
    }
    if (typeBlocks) {
      blockingTypes.push(type);
    } else {
      warningTypes.push(type);
    }
  }

  const block = blockingTypes.length > 0;
  return {
    status: block ? "duplicate_review_required" : "warning",
    duplicate_review_required: block,
    warning: !block,
    matched_claim_types: types,
    blocking_claim_types: blockingTypes,
    warning_claim_types: warningTypes,
    matched_worker_ids: [...workerIds],
    matched_business_ids: [...businessIds],
  };
}

/**
 * Upserts a driver's claim hashes into the locked claim index via a single
 * multi-path keyed write. Stores only metadata (never raw values).
 * @param {import("firebase-admin/database").Database} db
 * @param {string} uid
 * @param {Record<string, string>} claims
 * @param {{ownership_mode?: unknown, business_id?: unknown, business_link_status?: unknown, created_at?: number}} [meta]
 */
async function upsertWorkerIdentityClaims(db, uid, claims, meta = {}) {
  const u = String(uid ?? "").trim();
  if (!u) {
    return { success: false, reason: "invalid_uid", written: 0 };
  }
  const entries = Object.entries(claims || {}).filter(([, hash]) => !!hash);
  if (entries.length === 0) {
    return { success: true, written: 0 };
  }
  const now = Number(meta.created_at) || Date.now();
  const businessId =
    meta.business_id != null && String(meta.business_id).trim()
      ? String(meta.business_id).trim()
      : null;
  const row = {
    created_at: now,
    ownership_mode: normalizeOwnershipMode(meta.ownership_mode) || "individual",
    business_id: businessId,
    business_link_status:
      String(meta.business_link_status ?? "")
        .trim()
        .toLowerCase() || null,
  };

  /** @type {Record<string, object>} */
  const updates = {};
  for (const [type, hash] of entries) {
    updates[`worker_identity_claims/${type}/${hash}/${u}`] = row;
  }
  await db.ref().update(updates);
  return { success: true, written: entries.length };
}

/**
 * Extracts raw claim sources from a driver profile + their documents map.
 * Pure: reads only the known field shapes, returns raw values (not hashed).
 * @param {Record<string, unknown>} [profile]
 * @param {Record<string, unknown>} [documents] driver_documents/{uid} subtree
 * @returns {Record<string, unknown>}
 */
function extractClaimSources(profile = {}, documents = {}) {
  const p = profile && typeof profile === "object" ? profile : {};
  const docs = documents && typeof documents === "object" ? documents : {};
  const docNumber = (type) => {
    const d = docs[type];
    if (!d || typeof d !== "object") return "";
    return d.documentNumber ?? d.document_number ?? d.number ?? "";
  };
  const dest =
    p.withdrawal_destination && typeof p.withdrawal_destination === "object"
      ? p.withdrawal_destination
      : {};
  return {
    phone: p.phone ?? p.phone_number ?? p.phoneNumber,
    nin: docNumber("nin"),
    bvn: docNumber("bvn"),
    bank_account: dest.account_number ?? dest.accountNumber,
    bank_code: dest.bank_code ?? dest.bankCode,
    plate:
      docNumber("vehicle_documents") ||
      p.plate ||
      p.vehicle_plate_number ||
      p.plate_number,
  };
}

/**
 * Observe-only orchestrator. Gathers a driver's current claim sources via two
 * keyed reads, upserts hashed claims, evaluates duplicate status, and writes
 * observe-only metadata. NEVER blocks any flow; callers should treat failures
 * as best-effort. Keyed reads/writes only — no scans, no listeners.
 * @param {import("firebase-admin/database").Database} db
 * @param {string} uid
 * @param {{ now?: number, pepper?: string }} [opts]
 */
async function runWorkerIdentityDuplicateCheck(db, uid, opts = {}) {
  const u = String(uid ?? "").trim();
  if (!u) {
    return { success: false, reason: "invalid_uid" };
  }
  const now = Number(opts.now) || Date.now();

  const profileSnap = await db.ref(`drivers/${u}`).get();
  const profileVal = profileSnap && typeof profileSnap.val === "function" ? profileSnap.val() : null;
  const profile = profileVal && typeof profileVal === "object" ? profileVal : {};

  const docsSnap = await db.ref(`driver_documents/${u}`).get();
  const docsVal = docsSnap && typeof docsSnap.val === "function" ? docsSnap.val() : null;
  const documents = docsVal && typeof docsVal === "object" ? docsVal : {};

  const claims = buildDriverClaims(extractClaimSources(profile, documents), opts.pepper);

  const ownershipMode =
    normalizeOwnershipMode(profile.ownership_mode ?? profile.ownershipMode) || "individual";
  const businessId =
    profile.business_id != null && String(profile.business_id).trim()
      ? String(profile.business_id).trim()
      : null;
  const businessLinkStatus =
    String(profile.business_link_status ?? profile.businessLinkStatus ?? "")
      .trim()
      .toLowerCase() || null;

  await upsertWorkerIdentityClaims(db, u, claims, {
    ownership_mode: ownershipMode,
    business_id: businessId,
    business_link_status: businessLinkStatus,
    created_at: now,
  });

  const matches = await findDuplicateWorkerIds(db, claims, u);
  const review = evaluateDuplicateReview(matches);

  // Observe-only metadata — surfaces status without blocking any flow.
  await db.ref(`drivers/${u}`).update({
    identity_review_status: review.status,
    duplicate_review_required: review.duplicate_review_required === true,
    possible_duplicate_worker_ids: review.matched_worker_ids,
    identity_review_updated_at: now,
  });

  // Detail record in the locked review node for later admin review (Slice D).
  await db.ref(`worker_identity_reviews/${u}`).set({
    status: review.status,
    matched_claim_types: review.matched_claim_types,
    blocking_claim_types: review.blocking_claim_types,
    warning_claim_types: review.warning_claim_types,
    matched_worker_ids: review.matched_worker_ids,
    matched_business_ids: review.matched_business_ids,
    updated_at: now,
  });

  return {
    success: true,
    status: review.status,
    duplicate_review_required: review.duplicate_review_required,
    claim_types: Object.keys(claims),
    matched_claim_types: review.matched_claim_types,
    matched_worker_ids: review.matched_worker_ids,
    matched_business_ids: review.matched_business_ids,
  };
}

/**
 * Auth-required callable wrapper. Recomputes observe-only status for the
 * caller. Returns a minimal summary (no other workers' ids exposed to drivers).
 * @param {object} _data
 * @param {{ auth?: { uid?: string } }} context
 * @param {import("firebase-admin/database").Database} db
 */
async function workerRunIdentityDuplicateCheck(_data, context, db) {
  if (!context || !context.auth || !context.auth.uid) {
    return { success: false, reason: "unauthorized" };
  }
  const uid = String(context.auth.uid).trim();
  const res = await runWorkerIdentityDuplicateCheck(db, uid);
  if (res.success === false) {
    return res;
  }
  return {
    success: true,
    status: res.status,
    duplicate_review_required: res.duplicate_review_required,
    matched_claim_types: res.matched_claim_types,
  };
}

module.exports = {
  CLAIM_VERSION,
  DUPLICATE_SENSITIVE_CLAIM_TYPES,
  WARNING_ONLY_CLAIM_TYPES,
  normalizePhone,
  normalizeNin,
  normalizeBvn,
  normalizeBankAccount,
  normalizePlate,
  hashClaim,
  buildDriverClaims,
  findDuplicateWorkerIds,
  evaluateDuplicateReview,
  upsertWorkerIdentityClaims,
  extractClaimSources,
  runWorkerIdentityDuplicateCheck,
  workerRunIdentityDuplicateCheck,
};
