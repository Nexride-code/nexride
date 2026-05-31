/**
 * Dispatch Fleet verification — document requirements and readiness (manual admin review only).
 */

const admin = require("firebase-admin");
const { FieldValue } = require("firebase-admin/firestore");

const ACCOUNT_KIND_DISPATCH_FLEET = "dispatch_fleet";

const FLEET_VERIFICATION_TYPES = new Set(["cac_business", "nin_individual_business"]);

const FLEET_DOCUMENT_TYPES = new Set([
  "cac_document",
  "owner_id",
  "nin_document",
  "owner_selfie",
  "address_proof",
]);

const FLEET_DOCUMENT_LABELS = {
  cac_document: "CAC certificate",
  owner_id: "Owner government ID",
  nin_document: "NIN slip or card",
  owner_selfie: "Owner selfie",
  address_proof:
    "Address proof (utility bill, bank statement, rent/tenancy, or official letter)",
};

const FLEET_ADDRESS_PROOF_UPLOAD_HINT =
  "Upload a utility bill, bank statement, rent/tenancy document, or official address proof.";

const CAC_REQUIRED_TYPES = ["cac_document", "owner_id", "owner_selfie", "address_proof"];
const NIN_REQUIRED_TYPES = ["nin_document", "owner_selfie", "address_proof"];

/** Max fleet verification upload size (10 MiB). */
const FLEET_UPLOAD_MAX_BYTES = 10 * 1024 * 1024;

/** Strict allowlist — no wildcards (rejects executables and unknown types). */
const FLEET_UPLOAD_ALLOWED_MIME_TYPES = new Set([
  "image/jpeg",
  "image/png",
  "application/pdf",
]);

const FLEET_UPLOAD_MIME_EXTENSIONS = {
  "image/jpeg": new Set(["jpg", "jpeg"]),
  "image/png": new Set(["png"]),
  "application/pdf": new Set(["pdf"]),
};

const FLEET_UPLOAD_BLOCKED_EXTENSIONS = new Set([
  "exe",
  "bat",
  "cmd",
  "com",
  "msi",
  "dll",
  "scr",
  "ps1",
  "sh",
  "bash",
  "apk",
  "jar",
  "js",
  "mjs",
  "html",
  "htm",
  "svg",
  "webp",
  "gif",
  "heic",
  "heif",
  "doc",
  "docx",
  "xls",
  "xlsx",
  "zip",
  "rar",
  "7z",
]);

/** @type {import("firebase-admin/firestore").Firestore | null} */
let firestoreOverrideForTests = null;

function resolveFirestore() {
  return firestoreOverrideForTests || admin.firestore();
}

/** @param {import("firebase-admin/firestore").Firestore | null} fs */
function setFirestoreForTests(fs) {
  firestoreOverrideForTests = fs;
}

function trimStr(v, max = 500) {
  return String(v ?? "")
    .trim()
    .slice(0, max);
}

function fileExtension(fileName) {
  const base = trimStr(fileName, 512);
  const idx = base.lastIndexOf(".");
  if (idx < 0 || idx === base.length - 1) {
    return "";
  }
  return base.slice(idx + 1).toLowerCase();
}

/**
 * Callable + storage validation for fleet verification uploads.
 * @param {{ contentType?: string, sizeBytes?: number, fileName?: string, storageContentType?: string }} input
 */
function validateFleetUploadFile(input = {}) {
  const contentType = trimStr(input.contentType, 128).toLowerCase();
  const storageContentType = trimStr(input.storageContentType, 128).toLowerCase();
  const fileName = trimStr(input.fileName, 512);
  const ext = fileExtension(fileName);

  if (!contentType || !FLEET_UPLOAD_ALLOWED_MIME_TYPES.has(contentType)) {
    return { ok: false, reason: "invalid_file_type" };
  }

  if (ext && FLEET_UPLOAD_BLOCKED_EXTENSIONS.has(ext)) {
    return { ok: false, reason: "invalid_file_type" };
  }

  const allowedExts = FLEET_UPLOAD_MIME_EXTENSIONS[contentType];
  if (ext && allowedExts && !allowedExts.has(ext)) {
    return { ok: false, reason: "invalid_file_type" };
  }

  if (storageContentType && storageContentType !== contentType) {
    if (!FLEET_UPLOAD_ALLOWED_MIME_TYPES.has(storageContentType)) {
      return { ok: false, reason: "invalid_file_type" };
    }
    const storageAllowedExts = FLEET_UPLOAD_MIME_EXTENSIONS[storageContentType];
    if (ext && storageAllowedExts && !storageAllowedExts.has(ext)) {
      return { ok: false, reason: "invalid_file_type" };
    }
  }

  if (input.sizeBytes != null && input.sizeBytes !== "") {
    const sizeBytes = Number(input.sizeBytes);
    if (!Number.isFinite(sizeBytes) || sizeBytes <= 0 || sizeBytes > FLEET_UPLOAD_MAX_BYTES) {
      return { ok: false, reason: "file_too_large" };
    }
  }

  return { ok: true, contentType };
}

function docsCollection(fs, merchantId) {
  return fs
    .collection("merchant_verification_documents")
    .doc(merchantId)
    .collection("documents");
}

/**
 * @param {Record<string, Record<string, unknown>>} documentsMap
 * @param {string} type
 */
function statusForType(documentsMap, type) {
  const row = documentsMap[type];
  if (!row) {
    return "not_submitted";
  }
  const st = String(row.status ?? "pending")
    .trim()
    .toLowerCase();
  if (
    st === "approved" ||
    st === "pending" ||
    st === "rejected" ||
    st === "resubmission_required"
  ) {
    return st;
  }
  return "pending";
}

/**
 * @param {import("firebase-admin/firestore").Firestore} fs
 * @param {string} merchantId
 */
async function loadDocumentsMap(fs, merchantId) {
  const snap = await docsCollection(fs, merchantId).get();
  /** @type {Record<string, Record<string, unknown>>} */
  const out = {};
  for (const d of snap.docs) {
    out[d.id] = d.data() || {};
  }
  return out;
}

function normalizeFleetVerificationType(v) {
  const s = trimStr(v, 64).toLowerCase();
  return FLEET_VERIFICATION_TYPES.has(s) ? s : "";
}

function requiredTypesForMerchant(merchantRow) {
  const vt = normalizeFleetVerificationType(
    merchantRow?.verification_type ?? merchantRow?.verificationType,
  );
  if (vt === "nin_individual_business") {
    return NIN_REQUIRED_TYPES;
  }
  if (vt === "cac_business") {
    return CAC_REQUIRED_TYPES;
  }
  return CAC_REQUIRED_TYPES;
}

/**
 * @param {Record<string, unknown>} merchantRow
 * @param {Record<string, Record<string, unknown>>} documentsMap
 */
function computeFleetReadinessFromMaps(merchantRow, documentsMap) {
  const requiredTypes = requiredTypesForMerchant(merchantRow);
  const verificationType =
    normalizeFleetVerificationType(
      merchantRow?.verification_type ?? merchantRow?.verificationType,
    ) || "cac_business";

  /** @type {Record<string, string>} */
  const documentStatuses = {};
  for (const t of FLEET_DOCUMENT_TYPES) {
    documentStatuses[t] = statusForType(documentsMap, t);
  }

  const missingRequirements = [];
  const missingSubmissions = [];

  for (const type of requiredTypes) {
    const label = FLEET_DOCUMENT_LABELS[type] || type;
    const st = documentStatuses[type];
    if (st === "not_submitted") {
      missingSubmissions.push(`${label} (${type})`);
      missingRequirements.push(`${label} (${type}) is not submitted`);
      continue;
    }
    if (st === "approved") {
      continue;
    }
    if (st === "pending") {
      missingRequirements.push(`${label} (${type}) is pending review`);
    } else if (st === "rejected" || st === "resubmission_required") {
      missingRequirements.push(`${label} (${type}) needs correction or resubmission`);
    } else {
      missingRequirements.push(`${label} (${type}) must be approved`);
    }
  }

  const allSubmitted = missingSubmissions.length === 0;
  const allowed = missingRequirements.length === 0;

  let readableMessage;
  if (allowed) {
    readableMessage = "All required fleet verification documents are approved.";
  } else if (missingRequirements.length === 1) {
    readableMessage = missingRequirements[0];
  } else {
    readableMessage = `Action required: ${missingRequirements.length} verification items remain: ${missingRequirements.join("; ")}`;
  }

  return {
    allowed,
    allSubmitted,
    missingRequirements,
    missingSubmissions,
    documentStatuses,
    verification_type: verificationType,
    required_document_types: requiredTypes,
    readableMessage,
  };
}

/**
 * @param {import("firebase-admin/firestore").Firestore} fs
 * @param {string} merchantId
 */
async function recomputeFleetMerchantReadiness(fs, merchantId) {
  const mRef = fs.collection("merchants").doc(merchantId);
  const mSnap = await mRef.get();
  if (!mSnap.exists) {
    return null;
  }
  const m = mSnap.data() || {};
  if (
    trimStr(m.account_kind ?? m.accountKind, 64).toLowerCase() !== ACCOUNT_KIND_DISPATCH_FLEET
  ) {
    return null;
  }

  const documentsMap = await loadDocumentsMap(fs, merchantId);
  const readiness = computeFleetReadinessFromMaps(m, documentsMap);

  const merchantStatus = String(m.merchant_status ?? m.status ?? "")
    .trim()
    .toLowerCase();

  let nextMerchantStatus = merchantStatus;
  if (
    (merchantStatus === "pending_documents" || merchantStatus === "pending") &&
    readiness.allSubmitted
  ) {
    nextMerchantStatus = "pending_review";
  }

  const anyRejected = readiness.required_document_types.some((t) => {
    const s = readiness.documentStatuses[t];
    return s === "rejected" || s === "resubmission_required";
  });

  let verificationStatus = "incomplete";
  if (readiness.allowed) {
    verificationStatus = "docs_complete";
  } else if (anyRejected) {
    verificationStatus = "action_required";
  } else if (!readiness.allSubmitted) {
    verificationStatus = "incomplete";
  } else {
    verificationStatus = "pending_review";
  }

  /** @type {Record<string, unknown>} */
  const patch = {
    verification_status: verificationStatus,
    required_documents_complete: readiness.allowed,
    document_statuses: readiness.documentStatuses,
    readiness_missing_requirements: readiness.missingRequirements,
    verification_updated_at: FieldValue.serverTimestamp(),
    updated_at: FieldValue.serverTimestamp(),
  };

  if (nextMerchantStatus !== merchantStatus) {
    patch.merchant_status = nextMerchantStatus;
    patch.status = nextMerchantStatus;
  }

  await mRef.update(patch);

  return readiness;
}

/**
 * @param {string} merchantId
 */
async function getFleetReadiness(merchantId) {
  const fs = resolveFirestore();
  const mSnap = await fs.collection("merchants").doc(merchantId).get();
  if (!mSnap.exists) {
    return null;
  }
  const m = mSnap.data() || {};
  const documentsMap = await loadDocumentsMap(fs, merchantId);
  return computeFleetReadinessFromMaps(m, documentsMap);
}

function isFleetDocumentType(type) {
  return FLEET_DOCUMENT_TYPES.has(trimStr(type, 64).toLowerCase());
}

function documentAllowedForMerchant(merchantRow, documentType) {
  const required = requiredTypesForMerchant(merchantRow);
  return required.includes(documentType);
}

/**
 * @param {string} merchantId
 * @param {Record<string, unknown>} merchantPayload
 */
async function enrichFleetAdminVerification(merchantId, merchantPayload) {
  const fs = resolveFirestore();
  const readiness = await getFleetReadiness(merchantId);
  const bucket = admin.storage().bucket();
  const snap = await docsCollection(fs, merchantId).get();
  const byId = new Map(snap.docs.map((d) => [d.id, d.data() || {}]));

  const requiredTypes = readiness
    ? readiness.required_document_types
    : requiredTypesForMerchant(merchantPayload);

  /** @type {unknown[]} */
  const verification_documents = [];
  for (const t of requiredTypes) {
    const row = byId.get(t);
    if (!row) {
      verification_documents.push({
        document_type: t,
        label: FLEET_DOCUMENT_LABELS[t] || t,
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
    verification_documents.push({
      document_type: t,
      label: FLEET_DOCUMENT_LABELS[t] || t,
      status: String(row.status ?? "pending").trim().toLowerCase(),
      storage_path: row.storage_path ?? null,
      file_name: row.file_name ?? null,
      content_type: row.content_type ?? null,
      uploaded_at: row.uploaded_at?.toMillis?.() ?? null,
      reviewed_at: row.reviewed_at?.toMillis?.() ?? null,
      reviewed_by: row.reviewed_by ?? null,
      admin_note: row.admin_note ?? null,
      rejection_reason: row.rejection_reason ?? null,
      download_url: downloadUrl,
    });
  }

  return {
    verification_type:
      readiness?.verification_type ??
      (normalizeFleetVerificationType(
        merchantPayload?.verification_type ?? merchantPayload?.verificationType,
      ) || "cac_business"),
    required_documents_complete: merchantPayload?.required_documents_complete === true,
    readiness: readiness
      ? {
          allowed: readiness.allowed,
          all_submitted: readiness.allSubmitted,
          missing_requirements: readiness.missingRequirements,
          document_statuses: { ...readiness.documentStatuses },
          readable_message: readiness.readableMessage,
        }
      : null,
    verification_documents,
  };
}

module.exports = {
  ACCOUNT_KIND_DISPATCH_FLEET,
  FLEET_VERIFICATION_TYPES,
  FLEET_DOCUMENT_TYPES,
  FLEET_DOCUMENT_LABELS,
  FLEET_ADDRESS_PROOF_UPLOAD_HINT,
  CAC_REQUIRED_TYPES,
  NIN_REQUIRED_TYPES,
  normalizeFleetVerificationType,
  requiredTypesForMerchant,
  isFleetDocumentType,
  documentAllowedForMerchant,
  computeFleetReadinessFromMaps,
  recomputeFleetMerchantReadiness,
  getFleetReadiness,
  enrichFleetAdminVerification,
  loadDocumentsMap,
  docsCollection,
  setFirestoreForTests,
  FLEET_UPLOAD_MAX_BYTES,
  FLEET_UPLOAD_ALLOWED_MIME_TYPES,
  validateFleetUploadFile,
};
