/**
 * Production admin RBAC: Firebase custom claims `admin_role` (+ optional RTDB `admins/{uid}`),
 * enforced on every privileged callable via [enforceCallable] / [enforcePermission].
 */

"use strict";

const { logger } = require("firebase-functions");
const { isNexRideAdmin, normUid } = require("./admin_auth");

const ADMIN_ROLES = new Set([
  "super_admin",
  "ops_admin",
  "finance_admin",
  "support_admin",
  "verification_admin",
  "merchant_ops_admin",
]);

/** Emails that may use legacy `admin: true` without `admin_role` as full super_admin. */
const LEGACY_SUPER_ADMIN_EMAILS = new Set(
  String(process.env.NEXRIDE_RBAC_LEGACY_SUPER_EMAILS || "admin@nexride.africa")
    .split(",")
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean),
);

const ALL_PERMISSIONS = [
  "dashboard.read",
  "riders.read",
  "riders.write",
  "drivers.read",
  "drivers.write",
  "trips.read",
  "trips.write",
  "finance.read",
  "finance.write",
  "withdrawals.read",
  "withdrawals.approve",
  "verification.read",
  "verification.approve",
  "support.read",
  "support.write",
  "merchants.read",
  "merchants.write",
  "service_areas.read",
  "service_areas.write",
  "audit_logs.read",
  "settings.read",
  "settings.write",
];

/** @type {Record<string, Set<string>>} */
const ROLE_PERMISSIONS = {
  super_admin: new Set(ALL_PERMISSIONS),
  ops_admin: new Set([
    "dashboard.read",
    "riders.read",
    "riders.write",
    "drivers.read",
    "drivers.write",
    "trips.read",
    "trips.write",
    "finance.read",
    "support.read",
    "support.write",
    "merchants.read",
    "merchants.write",
    "service_areas.read",
    "service_areas.write",
    "settings.read",
  ]),
  finance_admin: new Set([
    "dashboard.read",
    "riders.read",
    "drivers.read",
    "finance.read",
    "finance.write",
    "withdrawals.read",
    "withdrawals.approve",
  ]),
  support_admin: new Set([
    "dashboard.read",
    "riders.read",
    "riders.write",
    "drivers.read",
    "trips.read",
    "support.read",
    "support.write",
  ]),
  verification_admin: new Set([
    "dashboard.read",
    "drivers.read",
    "drivers.write",
    "verification.read",
    "verification.approve",
    "riders.read",
  ]),
  merchant_ops_admin: new Set([
    "dashboard.read",
    "merchants.read",
    "merchants.write",
    "service_areas.read",
    "service_areas.write",
  ]),
};

/**
 * Callable name → required permission (single source for enforceCallable).
 * Keys must match exported HTTPS function handler names where practical.
 */
const CALLABLE_PERMISSIONS = {
  // admin_callables
  adminListLiveRides: "trips.read",
  adminGetRideDetails: "trips.read",
  adminListLiveTrips: "trips.read",
  adminGetTripDetail: "trips.read",
  adminCancelTrip: "trips.write",
  adminMarkTripEmergency: "trips.write",
  adminResolveTripEmergency: "trips.write",
  adminListOnlineDrivers: "drivers.read",
  adminApproveWithdrawal: "withdrawals.approve",
  adminRejectWithdrawal: "withdrawals.approve",
  adminVerifyDriver: "verification.approve",
  adminApproveManualPayment: "finance.write",
  adminSuspendDriver: "drivers.write",
  adminListSupportTickets: "support.read",
  adminListPendingWithdrawals: "withdrawals.read",
  adminListPayments: "finance.read",
  adminFetchDriversTree: "drivers.read",
  adminListDriversPage: "drivers.read",
  adminGetSidebarBadgeCounts: "dashboard.read",
  adminListDrivers: "drivers.read",
  adminGetDriverProfile: "drivers.read",
  adminGetDriverOverview: "drivers.read",
  adminGetDriverVerification: "verification.read",
  adminGetDriverWallet: "drivers.read",
  adminGetDriverTrips: "drivers.read",
  adminGetDriverSubscription: "drivers.read",
  adminGetDriverViolations: "drivers.read",
  adminGetDriverNotes: "drivers.read",
  adminGetDriverAuditTimeline: "drivers.read",
  adminListRidersPage: "riders.read",
  adminGetRiderProfile: "riders.read",
  adminListTripsPage: "trips.read",
  adminListWithdrawalsPage: "withdrawals.read",
  adminListSupportTicketsPage: "support.read",
  adminListRiders: "riders.read",
  adminReviewSubscriptionRequest: "drivers.read",
  adminFetchSubscriptionProofUrl: "drivers.read",
  adminFlagUserForSupportContact: "support.write",
  adminReviewRiderFirestoreIdentity: "verification.approve",
  adminApproveDriverVerification: "verification.approve",
  adminDeleteAccount: "settings.write",
  // production_ops_callables
  adminListUsers: "riders.read",
  adminGetUserProfile: "riders.read",
  adminGetOperationsDashboard: "dashboard.read",
  adminListActiveOperations: "trips.read",
  adminListReportsAndDisputes: "support.read",
  adminGetSupportTicket: "support.read",
  adminAssignSupportTicket: "support.write",
  adminReplySupportTicket: "support.write",
  adminUpdateSupportTicketStatus: "support.write",
  adminEscalateSupportTicket: "support.write",
  adminListMarkets: "settings.read",
  adminUpdateMarketEnabled: "settings.write",
  adminGetPricingConfig: "settings.read",
  adminUpdatePricingConfig: "settings.write",
  adminListIdentityVerifications: "verification.read",
  adminReviewIdentityVerification: "verification.approve",
  adminIdentityVerificationDebug: "verification.read",
  adminIdentityVerificationSignedUrl: "verification.read",
  adminUnsuspendUser: "drivers.write",
  adminUpdateUserStatus: "support.write",
  adminBlockUserTrips: "support.write",
  adminForceDriverOffline: "drivers.write",
  adminGetSubscriptionOperations: "drivers.read",
  adminDriverSubscriptionManage: "drivers.write",
  adminListTrips: "trips.read",
  adminConfirmBankTransferPayment: "finance.write",
  adminDisableUser: "drivers.write",
  adminSuspendUser: "drivers.write",
  adminWarnUser: "support.write",
  // live_operations_dashboard_callable
  adminGetLiveOperationsDashboard: "trips.read",
  adminGetProductionHealthSnapshot: "dashboard.read",
  // admin_audit_log
  adminListAuditLogs: "audit_logs.read",
  // withdraw_flow (also used by approveWithdrawal export)
  approveWithdrawal: "withdrawals.approve",
  // ecosystem delivery_regions admin
  adminUpsertDeliveryRegion: "service_areas.write",
  adminUpsertDeliveryCity: "service_areas.write",
  adminSeedRolloutDeliveryRegions: "service_areas.write",
  adminSeedDefaultNigeriaDeliveryRegions: "service_areas.write",
  adminListDeliveryRollout: "service_areas.read",
  adminListServiceAreas: "service_areas.read",
  adminGetServiceArea: "service_areas.read",
  adminUpsertServiceArea: "service_areas.write",
  adminEnableServiceArea: "service_areas.write",
  adminDisableServiceArea: "service_areas.write",
  // merchant_callables
  adminListMerchants: "merchants.read",
  adminListMerchantsPage: "merchants.read",
  adminGetMerchantProfile: "merchants.read",
  adminGetMerchant: "merchants.read",
  adminUpdateMerchantLocation: "merchants.write",
  adminReviewMerchant: "merchants.write",
  adminUpdateMerchantPaymentModel: "merchants.write",
  adminUpdateMerchantSubscriptionStatus: "merchants.write",
  adminWarnMerchant: "merchants.write",
  adminSetMerchantCommissionWithdrawal: "merchants.write",
  adminAppendMerchantInternalNote: "merchants.write",
  recomputeMerchantFinancialModel: "merchants.write",
  // merchant_commerce / merchant_wallet / merchant_verification (named exports)
  adminListMerchantOrders: "merchants.read",
  adminReviewMerchantBankTopUp: "merchants.write",
  adminListMerchantBankTopUps: "merchants.read",
  adminListMerchantPaymentModelRequests: "merchants.read",
  adminResolveMerchantPaymentModelRequest: "merchants.write",
  adminReviewMerchantDocument: "merchants.write",
  adminGetMerchantReadiness: "merchants.read",
  adminRecomputeMerchantReadiness: "merchants.write",
  // verification_center_callables
  adminListVerificationUploads: "verification.read",
  adminReviewDriverDocument: "verification.approve",
  adminListDriverVerificationDocuments: "verification.read",
  adminReviewRiderDocument: "verification.approve",
  adminListRiderVerificationDocuments: "verification.read",
  // index.js privileged
  createWalletTransaction: "finance.write",
  recordTripCompletion: "trips.write",
};

function normEmail(email) {
  return String(email ?? "")
    .trim()
    .toLowerCase();
}

/**
 * @param {unknown} val RTDB `admins/{uid}` value
 */
function legacySuperFromAdminsNode(val, email) {
  if (val === true) return true;
  if (val && typeof val === "object") {
    if (val.enabled === false || val.disabled === true) return false;
    if (val.legacy_super_admin === true) return true;
    // Any active admin record in RTDB counts as migration-safe legacy super
    // when JWT `admin_role` is absent (rollout: avoid locking out listed admins).
    return true;
  }
  if (LEGACY_SUPER_ADMIN_EMAILS.has(normEmail(email))) return true;
  return false;
}

/**
 * Resolves effective admin role for RBAC, or null if the user should not pass permission checks.
 * @param {import("firebase-admin/database").Database} db
 * @param {import("firebase-functions").https.CallableContext} context
 * @returns {Promise<string|null>}
 */
async function resolveEffectiveAdminRole(db, context) {
  const uid = normUid(context?.auth?.uid);
  if (!uid) return null;
  const token = context.auth?.token && typeof context.auth.token === "object" ? context.auth.token : {};
  const email = normEmail(token.email);

  if (!(await isNexRideAdmin(db, context))) {
    return null;
  }

  const fromToken = String(token.admin_role ?? "")
    .trim()
    .toLowerCase();
  if (ADMIN_ROLES.has(fromToken)) {
    return fromToken;
  }

  let rtdbVal = null;
  try {
    const snap = await db.ref(`admins/${uid}`).get();
    rtdbVal = snap.val();
  } catch (e) {
    logger.warn("resolveEffectiveAdminRole admins read failed", { uid, err: String(e?.message || e) });
  }

  if (rtdbVal && typeof rtdbVal === "object") {
    const fromDb = String(rtdbVal.admin_role ?? rtdbVal.role ?? "")
      .trim()
      .toLowerCase();
    if (ADMIN_ROLES.has(fromDb)) {
      return fromDb;
    }
  }

  if (fromToken && !ADMIN_ROLES.has(fromToken)) {
    logger.warn("resolveEffectiveAdminRole invalid admin_role claim", { uid, fromToken });
  }

  if (legacySuperFromAdminsNode(rtdbVal, email)) {
    return "super_admin";
  }

  if (token.admin === true && LEGACY_SUPER_ADMIN_EMAILS.has(email)) {
    return "super_admin";
  }

  return null;
}

function roleHasPermission(role, permission) {
  const set = ROLE_PERMISSIONS[role];
  return !!(set && set.has(permission));
}

function forbiddenResponse(requiredPermission) {
  return {
    success: false,
    reason: "forbidden",
    reason_code: "admin_permission_denied",
    required_permission: requiredPermission,
  };
}

function unauthorizedResponse() {
  return { success: false, reason: "unauthorized", reason_code: "unauthorized" };
}

function isSensitiveWritePermission(permission) {
  if (!permission || typeof permission !== "string") return false;
  return (
    permission.endsWith(".write") ||
    permission.endsWith(".approve") ||
    permission === "withdrawals.approve"
  );
}

async function logDeniedAdminAction(db, context, callableName, requiredPermission) {
  const adminAuditLog = require("./admin_audit_log");
  const uid = normUid(context?.auth?.uid);
  const token = context.auth?.token && typeof context.auth.token === "object" ? context.auth.token : {};
  const email = normEmail(token.email);
  try {
    await adminAuditLog.writeAdminAuditLog(db, {
      actor_uid: uid || null,
      actor_email: email || null,
      action: "denied_admin_action",
      entity_type: "callable",
      entity_id: String(callableName || "").slice(0, 200) || null,
      before: null,
      after: { callable: callableName, required_permission: requiredPermission },
      reason: "permission_denied",
      source: "admin_permissions",
      type: "admin_denied_admin_action",
      created_at: Date.now(),
    });
  } catch (e) {
    logger.warn("logDeniedAdminAction failed", { err: String(e?.message || e) });
  }
}

/**
 * @returns {Promise<boolean>}
 */
async function canAdmin(db, context, permission) {
  const role = await resolveEffectiveAdminRole(db, context);
  if (!role) return false;
  return roleHasPermission(role, permission);
}

/**
 * @returns {Promise<null | Record<string, unknown>>} null when allowed
 */
async function enforcePermission(db, context, permission, callableName, opts = {}) {
  if (!context?.auth?.uid) {
    return unauthorizedResponse();
  }
  if (!(await isNexRideAdmin(db, context))) {
    return unauthorizedResponse();
  }
  const role = await resolveEffectiveAdminRole(db, context);
  if (!role) {
    const body = forbiddenResponse(permission);
    if (opts.auditDenied === true && isSensitiveWritePermission(permission)) {
      await logDeniedAdminAction(db, context, callableName || "unknown", permission);
    }
    return body;
  }
  if (!roleHasPermission(role, permission)) {
    if (opts.auditDenied === true && isSensitiveWritePermission(permission)) {
      await logDeniedAdminAction(db, context, callableName || "unknown", permission);
    }
    return forbiddenResponse(permission);
  }
  return null;
}

/**
 * @returns {Promise<null | Record<string, unknown>>}
 */
async function enforceCallable(db, context, callableName) {
  const permission = CALLABLE_PERMISSIONS[callableName];
  if (!permission) {
    logger.error("[RBAC] missing CALLABLE_PERMISSIONS entry", { callableName });
    return forbiddenResponse("settings.write");
  }
  return enforcePermission(db, context, permission, callableName, {
    auditDenied: isSensitiveWritePermission(permission),
  });
}

module.exports = {
  ADMIN_ROLES,
  ALL_PERMISSIONS,
  ROLE_PERMISSIONS,
  CALLABLE_PERMISSIONS,
  LEGACY_SUPER_ADMIN_EMAILS,
  resolveEffectiveAdminRole,
  canAdmin,
  enforcePermission,
  enforceCallable,
  forbiddenResponse,
  unauthorizedResponse,
  roleHasPermission,
  logDeniedAdminAction,
  isSensitiveWritePermission,
};
