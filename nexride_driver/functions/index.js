require("./params");
const { onCall, onRequest } = require("firebase-functions/v2/https");
const { monitorSubscriptionExpiry } = require("./subscription_expiry_jobs");
const { sweepDispatchHealth } = require("./dispatch_maintenance_jobs");
const { cleanExpiredDriverOffers } = require("./offer_cleanup_jobs");
const admin = require("firebase-admin");
const { verifyFlutterwavePaymentStrict } = require("./flutterwave_api");
const { createWalletTransactionInternal } = require("./wallet_core");
const {
  flutterwaveSecretKey,
  flutterwaveWebhookSecret,
  agoraAppIdSecret,
  agoraAppCertificateSecret,
  REGION,
  platformFeeNgn,
} = require("./params");

admin.initializeApp();
const db = admin.database();

exports.monitorSubscriptionExpiry = monitorSubscriptionExpiry;
exports.sweepDispatchHealth = sweepDispatchHealth;
exports.cleanExpiredDriverOffers = cleanExpiredDriverOffers;
const { expireStaleVaPaymentIntents } = require("./va_intent_expiry_jobs");
exports.expireStaleVaPaymentIntents = expireStaleVaPaymentIntents;

function callableContext(request) {
  return { auth: request.auth };
}

const { normUid } = require("./admin_auth");
const adminPerms = require("./admin_permissions");
const ride = require("./ride_callables");
const delivery = require("./delivery_callables");
const paymentFlow = require("./payment_flow");
const withdrawFlow = require("./withdraw_flow");
const trackPublic = require("./track_public");
const adminCallables = require("./admin_callables");
const riderFirestoreIdentity = require("./rider_firestore_identity");
const supportCallables = require("./support_callables");
const adminRoles = require("./admin_roles");
const accountPassword = require("./account_password");
const { getRideCallRtcToken, generateAgoraToken, clearStaleRideCall } = require("./ride_call_rtc");
const { resolveDriverMonetization, resolveCommissionPolicy } = require("./driver_monetization");
const pushNotifications = require("./push_notifications");
const safetyEscalation = require("./safety_escalation");

const { assertPaymentOwnership } = require("./payment_ownership");

async function verifyPaymentInternal(reference, callerUid = "") {
  const ref = String(reference || "").trim();
  if (!ref) {
    return {
      success: false,
      reason: "payment_reference_not_found",
      reason_code: "payment_reference_not_found",
    };
  }
  const txRef = db.ref(`payment_transactions/${ref}`);
  const existingSnap = await txRef.get();
  if (!existingSnap.exists() || !existingSnap.val()) {
    return {
      success: false,
      reason: "payment_reference_not_found",
      reason_code: "payment_reference_not_found",
    };
  }
  const existing = existingSnap.val() || {};
  if (existing.verified === true) {
    return {
      success: true,
      reason: "already_verified",
      amount: Number(existing.amount || 0),
      providerStatus: String(existing.provider_status || "successful"),
    };
  }

  if (String(existing.purpose || "").trim() === "merchant_wallet_topup") {
    const uid = String(callerUid || "").trim();
    if (!uid) {
      return { success: false, reason: "unauthorized" };
    }
    const fs = admin.firestore();
    return merchantWallet.verifyAndFinalizeMerchantWalletTopUpForReference(db, fs, ref, {
      callerUid: uid,
    });
  }

  let rideId = String(existing.ride_id || "").trim();
  let deliveryId = String(existing.delivery_id || "").trim();
  const riderId = String(existing.rider_id || "").trim();
  const ownership = assertPaymentOwnership(existing, {
    callerUid,
    expectedAppContext: "rider",
    expectedRiderId: riderId || callerUid,
  });
  if (!ownership.ok) {
    return {
      success: false,
      reason: ownership.reason,
      reason_code: ownership.reason_code,
    };
  }
  if (!rideId && !deliveryId) {
    rideId = paymentFlow.extractRideIdFromNexrideTxRef(ref);
    deliveryId = paymentFlow.extractDeliveryIdFromNexrideTxRef(ref);
  }
  const rideSnap = rideId ? await db.ref(`ride_requests/${rideId}`).get() : null;
  const rideRow = rideSnap && rideSnap.val() && typeof rideSnap.val() === "object" ? rideSnap.val() : null;
  const deliverySnap = deliveryId ? await db.ref(`delivery_requests/${deliveryId}`).get() : null;
  const deliveryRow =
    deliverySnap && deliverySnap.val() && typeof deliverySnap.val() === "object"
      ? deliverySnap.val()
      : null;
  const entityRow = rideRow || deliveryRow;
  const expectedTx = String(
    entityRow
      ? (entityRow.customer_transaction_reference ?? entityRow.payment_reference ?? ref)
      : ref,
  ).trim();
  const expectCur = String(
    entityRow?.currency ?? existing.currency ?? "NGN",
  )
    .trim()
    .toUpperCase() || "NGN";
  let minFare;
  if (entityRow) {
    const f = Number(entityRow.fare ?? entityRow.total_delivery_fee ?? 0);
    if (Number.isFinite(f) && f > 0) minFare = f;
  }
  if (minFare == null) {
    const a = Number(existing.amount ?? 0);
    if (Number.isFinite(a) && a > 0) minFare = a;
  }
  const expect = {
    expectedTxRef: expectedTx || undefined,
    expectedCurrency: expectCur,
  };
  if (minFare != null && Number.isFinite(minFare)) {
    expect.minAmount = minFare;
  }

  const v = await verifyFlutterwavePaymentStrict({
    transactionId: /^\d+$/.test(ref) ? ref : "",
    txRef: ref,
    expect,
  });
  const payKey = String(v.flwTransactionId || ref || "").trim();
  await paymentFlow.mirrorPaymentRecords(db, {
    payKey,
    txRef: ref,
    rideId: rideId || null,
    deliveryId: deliveryId || null,
    riderId: riderId || null,
    verified: v.ok,
    amount: v.amount ?? 0,
    providerStatus: v.providerStatus || "unknown",
    payload: v.payload || {},
    webhookEvent: "callable_verify_payment",
    webhookApplied: false,
  });

  if (!v.ok) {
    const failReason = String(v.reason || "verification_failed").trim();
    const cancelled =
      failReason === "cancelled" ||
      failReason === "canceled" ||
      failReason === "payment_cancelled";
    return {
      success: false,
      reason: cancelled ? "payment_cancelled" : failReason,
      reason_code: cancelled ? "payment_cancelled" : failReason,
    };
  }
  const driverId = entityRow ? String(entityRow.driver_id || "").trim() : "";
  await paymentFlow.persistVerifiedFlutterwaveCharge(db, {
    transactionId: payKey,
    txRef: String(v.tx_ref || ref).trim(),
    rideId: rideId || null,
    deliveryId: deliveryId || null,
    riderId: riderId || null,
    driverId: driverId || null,
    amount: v.amount ?? 0,
    currency: v.currency || expectCur,
    rawStatus: String(v.payload?.data?.status ?? ""),
    webhookBody: { event: "callable_verify_payment", data: v.payload?.data },
  });
  if (rideId) {
    const ts = Date.now();
    await db.ref(`ride_requests/${rideId}`).update({
      payment_status: "verified",
      payment_verified_at: ts,
      payment_provider: "flutterwave",
      payment_transaction_id: payKey,
      paid_at: ts,
      updated_at: ts,
    });
    const activeSnap = await db.ref(`active_trips/${rideId}`).get();
    if (activeSnap.exists()) {
      await db.ref(`active_trips/${rideId}`).update({
        payment_status: "verified",
        payment_provider: "flutterwave",
        payment_transaction_id: payKey,
        paid_at: ts,
        updated_at: ts,
      });
    }
    const freshSnap = await db.ref(`ride_requests/${rideId}`).get();
    await ride.fanOutDriverOffersIfEligible(db, rideId, freshSnap.val() || {});
    await trackPublic.syncRideTrackPublic(db, rideId);
  }
  if (deliveryId) {
    const ts = Date.now();
    await db.ref(`delivery_requests/${deliveryId}`).update({
      payment_status: "verified",
      payment_verified_at: ts,
      payment_provider: "flutterwave",
      payment_transaction_id: payKey,
      paid_at: ts,
      updated_at: ts,
    });
    const freshDel = (await db.ref(`delivery_requests/${deliveryId}`).get()).val() || {};
    await delivery.fanOutDeliveryOffersIfEligible(db, deliveryId, freshDel);
  }
  return {
    success: true,
    reason: "verified",
    amount: v.amount,
    providerStatus: v.providerStatus,
    transaction_id: payKey,
  };
}

const rideCallOpts = { region: REGION };

exports.createRideRequest = onCall(rideCallOpts, async (request) =>
  ride.createRideRequest(request.data, callableContext(request), db),
);

exports.riderNotifySelfieSubmittedForReview = onCall(rideCallOpts, async (request) =>
  riderFirestoreIdentity.riderNotifySelfieSubmittedForReview(request.data, callableContext(request)),
);

const ecosystemDelivery = require("./ecosystem/delivery_regions");
const rolloutBackfill = require("./ecosystem/rollout_backfill");

exports.listDeliveryRegions = onCall(rideCallOpts, async (request) =>
  ecosystemDelivery.listDeliveryRegions(request.data, callableContext(request)),
);
exports.adminUpsertDeliveryRegion = onCall(rideCallOpts, async (request) =>
  ecosystemDelivery.adminUpsertDeliveryRegion(request.data, callableContext(request), db),
);
exports.adminSeedRolloutDeliveryRegions = onCall(rideCallOpts, async (request) =>
  ecosystemDelivery.adminSeedRolloutDeliveryRegions(request.data, callableContext(request), db),
);
exports.adminUpsertDeliveryCity = onCall(rideCallOpts, async (request) =>
  ecosystemDelivery.adminUpsertDeliveryCity(request.data, callableContext(request), db),
);
exports.adminListDeliveryRollout = onCall(rideCallOpts, async (request) =>
  ecosystemDelivery.adminListDeliveryRollout(request.data, callableContext(request), db),
);
exports.adminListServiceAreas = onCall(rideCallOpts, async (request) =>
  ecosystemDelivery.adminListServiceAreas(request.data, callableContext(request), db),
);
exports.adminGetServiceArea = onCall(rideCallOpts, async (request) =>
  ecosystemDelivery.adminGetServiceArea(request.data, callableContext(request), db),
);
exports.adminUpsertServiceArea = onCall(rideCallOpts, async (request) =>
  ecosystemDelivery.adminUpsertServiceArea(request.data, callableContext(request), db),
);
exports.adminEnableServiceArea = onCall(rideCallOpts, async (request) =>
  ecosystemDelivery.adminEnableServiceArea(request.data, callableContext(request), db),
);
exports.adminDisableServiceArea = onCall(rideCallOpts, async (request) =>
  ecosystemDelivery.adminDisableServiceArea(request.data, callableContext(request), db),
);
exports.validateServiceLocation = onCall(rideCallOpts, async (request) =>
  ecosystemDelivery.validateServiceLocation(request.data, callableContext(request)),
);
exports.backfillUserRolloutRegions = onCall(rideCallOpts, async (request) =>
  rolloutBackfill.adminBackfillUserRolloutRegions(request.data, callableContext(request), db),
);

// --- Merchant Phase 1 (registration + admin review only; no orders/menus/wallets) ---
const merchantCallables = require("./merchant/merchant_callables");
const merchantWallet = require("./merchant/merchant_wallet");
const nexrideOfficialBankConfig = require("./nexride_official_bank_config");
exports.merchantRegister = onCall(rideCallOpts, async (request) =>
  merchantCallables.merchantRegister(request.data, callableContext(request), db),
);
exports.merchantGetMyMerchant = onCall(rideCallOpts, async (request) =>
  merchantCallables.merchantGetMyMerchant(
    request.data,
    callableContext(request),
    db,
  ),
);
exports.merchantUpdateMerchantProfile = onCall(rideCallOpts, async (request) =>
  merchantCallables.merchantUpdateMerchantProfile(
    request.data,
    callableContext(request),
    db,
  ),
);
exports.merchantSetAvailability = onCall(rideCallOpts, async (request) =>
  merchantCallables.merchantSetAvailability(request.data, callableContext(request), db),
);
exports.merchantUpdateAvailability = onCall(rideCallOpts, async (request) =>
  merchantCallables.merchantUpdateAvailability(request.data, callableContext(request), db),
);
exports.merchantPortalHeartbeat = onCall(rideCallOpts, async (request) =>
  merchantCallables.merchantPortalHeartbeat(request.data, callableContext(request), db),
);
exports.merchantPutStaffMember = onCall(rideCallOpts, async (request) =>
  merchantCallables.merchantPutStaffMember(request.data, callableContext(request), db),
);
exports.adminListMerchants = onCall(rideCallOpts, async (request) =>
  merchantCallables.adminListMerchants(request.data, callableContext(request), db),
);
exports.adminGetMerchant = onCall(rideCallOpts, async (request) =>
  merchantCallables.adminGetMerchant(request.data, callableContext(request), db),
);
exports.adminListMerchantsPage = onCall(rideCallOpts, async (request) =>
  merchantCallables.adminListMerchantsPage(request.data, callableContext(request), db),
);
exports.adminGetMerchantProfile = onCall(rideCallOpts, async (request) =>
  merchantCallables.adminGetMerchantProfile(request.data, callableContext(request), db),
);
exports.adminReviewMerchant = onCall(rideCallOpts, async (request) =>
  merchantCallables.adminReviewMerchant(request.data, callableContext(request), db),
);

exports.adminUpdateMerchantPaymentModel = onCall(rideCallOpts, async (request) =>
  merchantCallables.adminUpdateMerchantPaymentModel(
    request.data,
    callableContext(request),
    db,
  ),
);

exports.adminUpdateMerchantSubscriptionStatus = onCall(rideCallOpts, async (request) =>
  merchantCallables.adminUpdateMerchantSubscriptionStatus(
    request.data,
    callableContext(request),
    db,
  ),
);

exports.recomputeMerchantFinancialModel = onCall(rideCallOpts, async (request) =>
  merchantCallables.recomputeMerchantFinancialModel(
    request.data,
    callableContext(request),
    db,
  ),
);

exports.adminWarnMerchant = onCall(rideCallOpts, async (request) =>
  merchantCallables.adminWarnMerchant(request.data, callableContext(request), db),
);
exports.adminSetMerchantCommissionWithdrawal = onCall(rideCallOpts, async (request) =>
  merchantCallables.adminSetMerchantCommissionWithdrawal(
    request.data,
    callableContext(request),
    db,
  ),
);
exports.adminAppendMerchantInternalNote = onCall(rideCallOpts, async (request) =>
  merchantCallables.adminAppendMerchantInternalNote(
    request.data,
    callableContext(request),
    db,
  ),
);
exports.adminUpdateMerchantLocation = onCall(rideCallOpts, async (request) =>
  merchantCallables.adminUpdateMerchantLocation(request.data, callableContext(request), db),
);

// --- Merchant wallet / billing (Firestore wallet + RTDB withdrawals + Flutterwave) ---
exports.merchantCreateBankTransferTopUp = onCall(rideCallOpts, async (request) =>
  merchantWallet.merchantCreateBankTransferTopUp(
    request.data,
    callableContext(request),
    db,
  ),
);
exports.merchantAttachBankTransferTopUpProof = onCall(rideCallOpts, async (request) =>
  merchantWallet.merchantAttachBankTransferTopUpProof(
    request.data,
    callableContext(request),
    db,
  ),
);
exports.merchantStartWalletTopUpFlutterwave = onCall(
  { region: REGION, secrets: [flutterwaveSecretKey] },
  async (request) =>
    merchantWallet.merchantStartWalletTopUpFlutterwave(
      request.data,
      callableContext(request),
      db,
    ),
);
exports.merchantListWalletLedger = onCall(rideCallOpts, async (request) =>
  merchantWallet.merchantListWalletLedger(
    request.data,
    callableContext(request),
    db,
  ),
);
exports.merchantRequestWithdrawal = onCall(rideCallOpts, async (request) =>
  merchantWallet.merchantRequestWithdrawal(
    request.data,
    callableContext(request),
    db,
  ),
);
exports.merchantRequestPaymentModelChange = onCall(rideCallOpts, async (request) =>
  merchantWallet.merchantRequestPaymentModelChange(
    request.data,
    callableContext(request),
    db,
  ),
);
exports.adminListMerchantBankTopUps = onCall(rideCallOpts, async (request) =>
  merchantWallet.adminListMerchantBankTopUps(
    request.data,
    callableContext(request),
    db,
  ),
);
exports.adminReviewMerchantBankTopUp = onCall(rideCallOpts, async (request) =>
  merchantWallet.adminReviewMerchantBankTopUp(
    request.data,
    callableContext(request),
    db,
  ),
);
exports.adminListMerchantPaymentModelRequests = onCall(rideCallOpts, async (request) =>
  merchantWallet.adminListMerchantPaymentModelRequests(
    request.data,
    callableContext(request),
    db,
  ),
);
exports.adminResolveMerchantPaymentModelRequest = onCall(rideCallOpts, async (request) =>
  merchantWallet.adminResolveMerchantPaymentModelRequest(
    request.data,
    callableContext(request),
    db,
  ),
);

// --- Merchant Phase 4B (menu, orders, rider catalog, linked delivery) ---
const merchantCommerce = require("./merchant/merchant_commerce");
exports.merchantUpsertMenuCategory = onCall(rideCallOpts, async (request) =>
  merchantCommerce.merchantUpsertMenuCategory(request.data, callableContext(request), db),
);
exports.merchantDeleteMenuCategory = onCall(rideCallOpts, async (request) =>
  merchantCommerce.merchantDeleteMenuCategory(request.data, callableContext(request), db),
);
exports.merchantUpsertMenuItem = onCall(rideCallOpts, async (request) =>
  merchantCommerce.merchantUpsertMenuItem(request.data, callableContext(request), db),
);
exports.merchantArchiveMenuItem = onCall(rideCallOpts, async (request) =>
  merchantCommerce.merchantArchiveMenuItem(request.data, callableContext(request), db),
);
exports.merchantListMyMenu = onCall(rideCallOpts, async (request) =>
  merchantCommerce.merchantListMyMenu(request.data, callableContext(request), db),
);
exports.merchantListMyMenuPage = onCall(rideCallOpts, async (request) =>
  merchantCommerce.merchantListMyMenuPage(request.data, callableContext(request), db),
);
exports.merchantAttachMenuOrProfileImage = onCall(rideCallOpts, async (request) =>
  merchantCommerce.merchantAttachMenuOrProfileImage(request.data, callableContext(request), db),
);
exports.riderListApprovedMerchants = onCall(rideCallOpts, async (request) =>
  merchantCommerce.riderListApprovedMerchants(request.data, callableContext(request), db),
);
exports.riderGetMerchantCatalog = onCall(rideCallOpts, async (request) =>
  merchantCommerce.riderGetMerchantCatalog(request.data, callableContext(request), db),
);
exports.riderPlaceMerchantOrder = onCall(rideCallOpts, async (request) =>
  merchantCommerce.riderPlaceMerchantOrder(request.data, callableContext(request), db),
);
exports.merchantListMyOrders = onCall(rideCallOpts, async (request) =>
  merchantCommerce.merchantListMyOrders(request.data, callableContext(request), db),
);
exports.merchantListMyOrdersPage = onCall(rideCallOpts, async (request) =>
  merchantCommerce.merchantListMyOrdersPage(request.data, callableContext(request), db),
);
exports.merchantGetOperationsInsights = onCall(rideCallOpts, async (request) =>
  merchantCommerce.merchantGetOperationsInsights(request.data, callableContext(request), db),
);
exports.merchantUpdateOrderStatus = onCall(rideCallOpts, async (request) =>
  merchantCommerce.merchantUpdateOrderStatus(request.data, callableContext(request), db),
);
exports.adminListMerchantOrders = onCall(rideCallOpts, async (request) =>
  merchantCommerce.adminListMerchantOrders(request.data, callableContext(request), db),
);
exports.riderListMyOrders = onCall(rideCallOpts, async (request) =>
  merchantCommerce.riderListMyOrders(request.data, callableContext(request), db),
);
exports.supportGetMerchantOrderContext = onCall(rideCallOpts, async (request) =>
  merchantCommerce.supportGetMerchantOrderContext(request.data, callableContext(request), db),
);

// --- Merchant Phase 2B (verification documents + readiness) ---
const merchantVerification = require("./merchant/merchant_verification");
exports.merchantUploadVerificationDocument = onCall(rideCallOpts, async (request) =>
  merchantVerification.merchantUploadVerificationDocument(
    request.data,
    callableContext(request),
    db,
  ),
);
exports.merchantListMyVerificationDocuments = onCall(rideCallOpts, async (request) =>
  merchantVerification.merchantListMyVerificationDocuments(
    request.data,
    callableContext(request),
    db,
  ),
);
exports.adminReviewMerchantDocument = onCall(rideCallOpts, async (request) =>
  merchantVerification.adminReviewMerchantDocument(
    request.data,
    callableContext(request),
    db,
  ),
);
exports.adminGetMerchantReadiness = onCall(rideCallOpts, async (request) =>
  merchantVerification.adminGetMerchantReadiness(
    request.data,
    callableContext(request),
    db,
  ),
);
exports.adminRecomputeMerchantReadiness = onCall(rideCallOpts, async (request) =>
  merchantVerification.adminRecomputeMerchantReadiness(
    request.data,
    callableContext(request),
    db,
  ),
);

// --- Phase 2D unified verification center ---
const verificationCenter = require("./verification_center_callables");
exports.adminListVerificationUploads = onCall(rideCallOpts, async (request) =>
  verificationCenter.adminListVerificationUploads(
    request.data,
    callableContext(request),
    db,
  ),
);
exports.adminReviewDriverDocument = onCall(rideCallOpts, async (request) =>
  verificationCenter.adminReviewDriverDocument(
    request.data,
    callableContext(request),
    db,
  ),
);
exports.adminListDriverVerificationDocuments = onCall(rideCallOpts, async (request) =>
  verificationCenter.adminListDriverVerificationDocuments(
    request.data,
    callableContext(request),
    db,
  ),
);
exports.adminReviewRiderDocument = onCall(rideCallOpts, async (request) =>
  verificationCenter.adminReviewRiderDocument(
    request.data,
    callableContext(request),
    db,
  ),
);
exports.adminListRiderVerificationDocuments = onCall(rideCallOpts, async (request) =>
  verificationCenter.adminListRiderVerificationDocuments(
    request.data,
    callableContext(request),
    db,
  ),
);

/** Restored production callables — must stay exported so deploy does not delete remote functions. */
const productionOps = require("./production_ops_callables");
const liveOperationsDashboard = require("./live_operations_dashboard_callable");
const productionHealth = require("./production_health_callable");

exports.adminAssignSupportTicket = onCall(rideCallOpts, async (request) =>
  productionOps.adminAssignSupportTicket(request.data, callableContext(request), db),
);
exports.adminBlockUserTrips = onCall(rideCallOpts, async (request) =>
  productionOps.adminBlockUserTrips(request.data, callableContext(request), db),
);
exports.adminConfirmBankTransferPayment = onCall(rideCallOpts, async (request) =>
  productionOps.adminConfirmBankTransferPayment(request.data, callableContext(request), db),
);
exports.adminDisableUser = onCall(rideCallOpts, async (request) =>
  productionOps.adminDisableUser(request.data, callableContext(request), db),
);
exports.adminDriverSubscriptionManage = onCall(rideCallOpts, async (request) =>
  productionOps.adminDriverSubscriptionManage(request.data, callableContext(request), db),
);
exports.adminEscalateSupportTicket = onCall(rideCallOpts, async (request) =>
  productionOps.adminEscalateSupportTicket(request.data, callableContext(request), db),
);
exports.adminForceDriverOffline = onCall(rideCallOpts, async (request) =>
  productionOps.adminForceDriverOffline(request.data, callableContext(request), db),
);
exports.adminGetOperationsDashboard = onCall(rideCallOpts, async (request) =>
  productionOps.adminGetOperationsDashboard(request.data, callableContext(request), db),
);
exports.adminGetLiveOperationsDashboard = onCall(rideCallOpts, async (request) =>
  liveOperationsDashboard.adminGetLiveOperationsDashboard(
    request.data,
    callableContext(request),
    db,
  ),
);
exports.adminGetProductionHealthSnapshot = onCall(rideCallOpts, async (request) =>
  productionHealth.adminGetProductionHealthSnapshot(
    request.data,
    callableContext(request),
    db,
  ),
);
exports.adminListPaymentIntents = onCall(rideCallOpts, async (request) =>
  adminCallables.adminListPaymentIntents(request.data, callableContext(request), db),
);
exports.adminExpireStaleVaPaymentIntents = onCall(rideCallOpts, async (request) =>
  adminCallables.adminExpireStaleVaPaymentIntents(
    request.data,
    callableContext(request),
    db,
  ),
);
/** Alias for integrations expecting `adminGetDashboard`. */
exports.adminGetDashboard = onCall(rideCallOpts, async (request) =>
  productionOps.adminGetOperationsDashboard(request.data, callableContext(request), db),
);
exports.adminGetPricingConfig = onCall(rideCallOpts, async (request) =>
  productionOps.adminGetPricingConfig(request.data, callableContext(request), db),
);
exports.adminGetSubscriptionOperations = onCall(rideCallOpts, async (request) =>
  productionOps.adminGetSubscriptionOperations(request.data, callableContext(request), db),
);
exports.adminGetSupportTicket = onCall(rideCallOpts, async (request) =>
  productionOps.adminGetSupportTicket(request.data, callableContext(request), db),
);
exports.adminGetTripDetail = onCall(rideCallOpts, async (request) =>
  adminCallables.adminGetTripDetail(request.data, callableContext(request), db),
);
exports.adminGetUserProfile = onCall(rideCallOpts, async (request) =>
  productionOps.adminGetUserProfile(request.data, callableContext(request), db),
);
exports.adminIdentityVerificationDebug = onCall(rideCallOpts, async (request) =>
  productionOps.adminIdentityVerificationDebug(request.data, callableContext(request), db),
);
exports.adminIdentityVerificationSignedUrl = onCall(rideCallOpts, async (request) =>
  productionOps.adminIdentityVerificationSignedUrl(request.data, callableContext(request), db),
);
exports.adminListActiveOperations = onCall(rideCallOpts, async (request) =>
  productionOps.adminListActiveOperations(request.data, callableContext(request), db),
);
exports.adminListAuditLogs = onCall(rideCallOpts, async (request) =>
  productionOps.adminListAuditLogs(request.data, callableContext(request), db),
);
exports.adminListIdentityVerifications = onCall(rideCallOpts, async (request) =>
  productionOps.adminListIdentityVerifications(request.data, callableContext(request), db),
);
exports.adminListMarkets = onCall(rideCallOpts, async (request) =>
  productionOps.adminListMarkets(request.data, callableContext(request), db),
);
exports.adminListReportsAndDisputes = onCall(rideCallOpts, async (request) =>
  productionOps.adminListReportsAndDisputes(request.data, callableContext(request), db),
);
exports.adminListTrips = onCall(rideCallOpts, async (request) =>
  productionOps.adminListTrips(request.data, callableContext(request), db),
);
exports.adminListUsers = onCall(rideCallOpts, async (request) =>
  productionOps.adminListUsers(request.data, callableContext(request), db),
);
exports.adminReplySupportTicket = onCall(rideCallOpts, async (request) =>
  productionOps.adminReplySupportTicket(request.data, callableContext(request), db),
);
exports.adminReviewIdentityVerification = onCall(rideCallOpts, async (request) =>
  productionOps.adminReviewIdentityVerification(request.data, callableContext(request), db),
);
exports.adminSuspendUser = onCall(rideCallOpts, async (request) =>
  productionOps.adminSuspendUser(request.data, callableContext(request), db),
);
exports.adminUnsuspendUser = onCall(rideCallOpts, async (request) =>
  productionOps.adminUnsuspendUser(request.data, callableContext(request), db),
);
exports.adminUpdateMarketEnabled = onCall(rideCallOpts, async (request) =>
  productionOps.adminUpdateMarketEnabled(request.data, callableContext(request), db),
);
exports.adminUpdatePricingConfig = onCall(rideCallOpts, async (request) =>
  productionOps.adminUpdatePricingConfig(request.data, callableContext(request), db),
);
exports.adminUpdateSupportTicketStatus = onCall(rideCallOpts, async (request) =>
  productionOps.adminUpdateSupportTicketStatus(request.data, callableContext(request), db),
);
exports.adminUpdateUserStatus = onCall(rideCallOpts, async (request) =>
  productionOps.adminUpdateUserStatus(request.data, callableContext(request), db),
);
exports.adminWarnUser = onCall(rideCallOpts, async (request) =>
  productionOps.adminWarnUser(request.data, callableContext(request), db),
);
exports.driverConfirmBankTransferPayment = onCall(rideCallOpts, async (request) =>
  productionOps.driverConfirmBankTransferPayment(request.data, callableContext(request), db),
);
exports.driverReportBankTransferNotReceived = onCall(rideCallOpts, async (request) =>
  productionOps.driverReportBankTransferNotReceived(request.data, callableContext(request), db),
);
exports.finalizeBankTransferReceiptUpload = onCall(rideCallOpts, async (request) =>
  productionOps.finalizeBankTransferReceiptUpload(request.data, callableContext(request), db),
);
exports.getBankTransferReceiptSignedUrl = onCall(rideCallOpts, async (request) =>
  productionOps.getBankTransferReceiptSignedUrl(request.data, callableContext(request), db),
);
exports.getDriverSubscriptionSummary = onCall(rideCallOpts, async (request) =>
  productionOps.getDriverSubscriptionSummary(request.data, callableContext(request), db),
);
exports.getPricingConfigForMarket = onCall(rideCallOpts, async (request) =>
  productionOps.getPricingConfigForMarket(request.data, callableContext(request), db),
);
exports.listEnabledServiceMarkets = onCall(rideCallOpts, async (request) =>
  productionOps.listEnabledServiceMarkets(request.data, callableContext(request), db),
);
exports.renewDriverSubscriptionFromWallet = onCall(rideCallOpts, async (request) =>
  productionOps.renewDriverSubscriptionFromWallet(request.data, callableContext(request), db),
);
exports.setDriverSubscriptionAutoRenew = onCall(rideCallOpts, async (request) =>
  productionOps.setDriverSubscriptionAutoRenew(request.data, callableContext(request), db),
);
exports.syncIdentityVerificationSubmission = onCall(rideCallOpts, async (request) =>
  productionOps.syncIdentityVerificationSubmission(request.data, callableContext(request), db),
);

// Single client-facing accept entrypoint: [acceptRide] → ride.acceptRideRequest (implementation).
exports.acceptRide = onCall(rideCallOpts, async (request) =>
  ride.acceptRideRequest(request.data, callableContext(request), db),
);


exports.driverEnroute = onCall(rideCallOpts, async (request) =>
  ride.driverEnroute(request.data, callableContext(request), db),
);

exports.driverArrived = onCall(rideCallOpts, async (request) =>
  ride.driverArrived(request.data, callableContext(request), db),
);

exports.startTrip = onCall(rideCallOpts, async (request) =>
  ride.startTrip(request.data, callableContext(request), db),
);

exports.setDriverOnline = onCall(
  {
    ...rideCallOpts,
    timeoutSeconds: 30,
  },
  async (request) =>
    ride.setDriverOnline(request.data, callableContext(request), db),
);

exports.setDriverOffline = onCall(
  {
    ...rideCallOpts,
    timeoutSeconds: 30,
  },
  async (request) =>
    ride.setDriverOffline(request.data, callableContext(request), db),
);

exports.driverUpdateLiveLocation = onCall(
  {
    ...rideCallOpts,
    timeoutSeconds: 30,
  },
  async (request) =>
    ride.driverUpdateLiveLocation(request.data, callableContext(request), db),
);

exports.withdrawDriverOffer = onCall(rideCallOpts, async (request) =>
  ride.withdrawDriverOffer(request.data, callableContext(request), db),
);

exports.completeTrip = onCall(rideCallOpts, async (request) =>
  ride.completeTrip(request.data, callableContext(request), db),
);

exports.cancelRide = onCall(rideCallOpts, async (request) =>
  ride.cancelRideRequest(request.data, callableContext(request), db),
);

/** Alias — some app builds still call [cancelRideRequest]. */
exports.cancelRideRequest = exports.cancelRide;

/** Alternate client-safe name (deployed parity with Flutter callables). */
exports.requestRide = exports.createRideRequest;

exports.expireRideRequest = onCall(rideCallOpts, async (request) =>
  ride.expireRideRequest(request.data, callableContext(request), db),
);

/**
 * Clear rider-owned active-trip pointers only (does not mutate ride_requests).
 * Used when stale local/RTDB state blocks a fresh request.
 */
exports.cleanupActiveRide = onCall(rideCallOpts, async (request) => {
  const ctx = callableContext(request);
  if (!ctx.auth?.uid) {
    return { success: false, reason: "unauthorized" };
  }
  const riderId = String(ctx.auth.uid || "").trim();
  try {
    const ptrSnap = await db.ref(`rider_active_trip/${riderId}`).get();
    const val = ptrSnap.val();
    let rideHint = "";
    if (typeof val === "string") {
      rideHint = String(val || "").trim();
    } else if (val && typeof val === "object") {
      rideHint = String(
        val.ride_id || val.rideId || "",
      ).trim();
    }
    const updates = {
      [`rider_active_trip/${riderId}`]: null,
    };
    if (rideHint) {
      updates[`active_trips/${rideHint}`] = null;
    }
    await db.ref().update(updates);
    console.log(
      "cleanupActiveRide",
      riderId,
      rideHint ? `hint=${rideHint}` : "no_ride_hint",
    );
    return {
      success: true,
      reason: "cleaned",
      cleared_ride_id_hint: rideHint || null,
    };
  } catch (e) {
    console.log("cleanupActiveRide_FAIL", riderId, e?.message ?? e);
    return { success: false, reason: "cleanup_failed" };
  }
});

exports.patchRideRequestMetadata = onCall(rideCallOpts, async (request) =>
  ride.patchRideRequestMetadata(request.data, callableContext(request), db),
);

exports.createDeliveryRequest = onCall(rideCallOpts, async (request) =>
  delivery.createDeliveryRequest(request.data, callableContext(request), db),
);

exports.acceptDeliveryRequest = onCall(rideCallOpts, async (request) =>
  delivery.acceptDeliveryRequest(request.data, callableContext(request), db),
);

exports.updateDeliveryState = onCall(rideCallOpts, async (request) =>
  delivery.updateDeliveryState(request.data, callableContext(request), db),
);

exports.expireDeliveryRequest = onCall(rideCallOpts, async (request) =>
  delivery.expireDeliveryRequest(request.data, callableContext(request), db),
);

exports.cancelDeliveryRequest = onCall(rideCallOpts, async (request) =>
  delivery.cancelDeliveryRequest(request.data, callableContext(request), db),
);

/** Public tracking — `token` is `ride_requests.track_token` (share link). */
exports.getRideTrackSummary = onCall(
  { region: REGION, invoker: "public" },
  async (request) => trackPublic.getRideTrackSummary(request.data, db),
);

exports.createTripShareToken = onCall(rideCallOpts, async (request) =>
  trackPublic.createTripShareToken(request.data, callableContext(request), db),
);

/** Agora RTC — server-signed token; requires AGORA_APP_ID + AGORA_APP_CERTIFICATE in env. */
exports.getRideCallRtcToken = onCall(
  {
    ...rideCallOpts,
    timeoutSeconds: 30,
    secrets: [agoraAppIdSecret, agoraAppCertificateSecret],
  },
  async (request) =>
  getRideCallRtcToken(request.data, callableContext(request), db),
);

exports.generateAgoraToken = onCall(
  {
    ...rideCallOpts,
    timeoutSeconds: 30,
    secrets: [agoraAppIdSecret, agoraAppCertificateSecret],
  },
  async (request) =>
    generateAgoraToken(request.data, callableContext(request), db),
);

exports.clearStaleRideCall = onCall(rideCallOpts, async (request) =>
  clearStaleRideCall(request.data, callableContext(request), db),
);

exports.adminListLiveRides = onCall(rideCallOpts, async (request) =>
  adminCallables.adminListLiveRides(request.data, callableContext(request), db),
);
exports.adminGetRideDetails = onCall(rideCallOpts, async (request) =>
  adminCallables.adminGetRideDetails(request.data, callableContext(request), db),
);
exports.adminListLiveTrips = onCall(rideCallOpts, async (request) =>
  adminCallables.adminListLiveTrips(request.data, callableContext(request), db),
);
exports.adminCancelTrip = onCall(rideCallOpts, async (request) =>
  adminCallables.adminCancelTrip(request.data, callableContext(request), db),
);
exports.adminMarkTripEmergency = onCall(rideCallOpts, async (request) =>
  adminCallables.adminMarkTripEmergency(request.data, callableContext(request), db),
);
exports.adminResolveTripEmergency = onCall(rideCallOpts, async (request) =>
  adminCallables.adminResolveTripEmergency(request.data, callableContext(request), db),
);
exports.adminListOnlineDrivers = onCall(rideCallOpts, async (request) =>
  adminCallables.adminListOnlineDrivers(request.data, callableContext(request), db),
);
exports.adminApproveWithdrawal = onCall(rideCallOpts, async (request) =>
  adminCallables.adminApproveWithdrawal(request.data, callableContext(request), db),
);
exports.adminRejectWithdrawal = onCall(rideCallOpts, async (request) =>
  adminCallables.adminRejectWithdrawal(request.data, callableContext(request), db),
);
exports.adminVerifyDriver = onCall(rideCallOpts, async (request) =>
  adminCallables.adminVerifyDriver(request.data, callableContext(request), db),
);
exports.adminApproveManualPayment = onCall(rideCallOpts, async (request) =>
  adminCallables.adminApproveManualPayment(request.data, callableContext(request), db),
);
exports.adminSuspendDriver = onCall(rideCallOpts, async (request) =>
  adminCallables.adminSuspendDriver(request.data, callableContext(request), db),
);
exports.adminListSupportTickets = onCall(rideCallOpts, async (request) =>
  adminCallables.adminListSupportTickets(request.data, callableContext(request), db),
);
exports.adminListPendingWithdrawals = onCall(rideCallOpts, async (request) =>
  adminCallables.adminListPendingWithdrawals(request.data, callableContext(request), db),
);
exports.adminListPayments = onCall(rideCallOpts, async (request) =>
  adminCallables.adminListPayments(request.data, callableContext(request), db),
);
exports.adminListDrivers = onCall(rideCallOpts, async (request) =>
  adminCallables.adminListDrivers(request.data, callableContext(request), db),
);
exports.adminFetchDriversTree = onCall(rideCallOpts, async (request) =>
  adminCallables.adminFetchDriversTree(request.data, callableContext(request), db),
);
exports.adminListDriversPage = onCall(rideCallOpts, async (request) =>
  adminCallables.adminListDriversPage(request.data, callableContext(request), db),
);
exports.adminGetDriverProfile = onCall(rideCallOpts, async (request) =>
  adminCallables.adminGetDriverProfile(request.data, callableContext(request), db),
);
exports.adminGetDriverOverview = onCall(rideCallOpts, async (request) =>
  adminCallables.adminGetDriverOverview(request.data, callableContext(request), db),
);
exports.adminGetDriverVerification = onCall(rideCallOpts, async (request) =>
  adminCallables.adminGetDriverVerification(request.data, callableContext(request), db),
);
exports.adminGetDriverWallet = onCall(rideCallOpts, async (request) =>
  adminCallables.adminGetDriverWallet(request.data, callableContext(request), db),
);
exports.adminGetDriverTrips = onCall(rideCallOpts, async (request) =>
  adminCallables.adminGetDriverTrips(request.data, callableContext(request), db),
);
exports.adminGetDriverSubscription = onCall(rideCallOpts, async (request) =>
  adminCallables.adminGetDriverSubscription(request.data, callableContext(request), db),
);
exports.adminGetDriverViolations = onCall(rideCallOpts, async (request) =>
  adminCallables.adminGetDriverViolations(request.data, callableContext(request), db),
);
exports.adminGetDriverNotes = onCall(rideCallOpts, async (request) =>
  adminCallables.adminGetDriverNotes(request.data, callableContext(request), db),
);
exports.adminGetDriverAuditTimeline = onCall(rideCallOpts, async (request) =>
  adminCallables.adminGetDriverAuditTimeline(request.data, callableContext(request), db),
);
exports.adminListRidersPage = onCall(rideCallOpts, async (request) =>
  adminCallables.adminListRidersPage(request.data, callableContext(request), db),
);
exports.adminGetRiderProfile = onCall(rideCallOpts, async (request) =>
  adminCallables.adminGetRiderProfile(request.data, callableContext(request), db),
);
exports.adminListTripsPage = onCall(rideCallOpts, async (request) =>
  adminCallables.adminListTripsPage(request.data, callableContext(request), db),
);
exports.adminListWithdrawalsPage = onCall(rideCallOpts, async (request) =>
  adminCallables.adminListWithdrawalsPage(request.data, callableContext(request), db),
);
exports.adminListSupportTicketsPage = onCall(rideCallOpts, async (request) =>
  adminCallables.adminListSupportTicketsPage(request.data, callableContext(request), db),
);
exports.adminGetSidebarBadgeCounts = onCall(rideCallOpts, async (request) =>
  adminCallables.adminGetSidebarBadgeCounts(request.data, callableContext(request), db),
);
exports.adminListRiders = onCall(rideCallOpts, async (request) =>
  adminCallables.adminListRiders(request.data, callableContext(request), db),
);
exports.adminReviewSubscriptionRequest = onCall(rideCallOpts, async (request) =>
  adminCallables.adminReviewSubscriptionRequest(request.data, callableContext(request), db),
);
exports.adminFetchSubscriptionProofUrl = onCall(rideCallOpts, async (request) =>
  adminCallables.adminFetchSubscriptionProofUrl(request.data, callableContext(request), db),
);
exports.adminSuspendAccount = onCall(rideCallOpts, async (request) =>
  adminCallables.adminSuspendAccount(request.data, callableContext(request), db),
);
exports.adminWarnAccount = onCall(rideCallOpts, async (request) =>
  adminCallables.adminWarnAccount(request.data, callableContext(request), db),
);
exports.adminDeleteAccount = onCall(rideCallOpts, async (request) =>
  adminCallables.adminDeleteAccount(request.data, callableContext(request), db),
);
exports.adminFlagUserForSupportContact = onCall(rideCallOpts, async (request) =>
  adminCallables.adminFlagUserForSupportContact(request.data, callableContext(request), db),
);
exports.adminApproveDriverVerification = onCall(rideCallOpts, async (request) =>
  adminCallables.adminApproveDriverVerification(request.data, callableContext(request), db),
);

exports.adminReviewRiderFirestoreIdentity = onCall(rideCallOpts, async (request) =>
  adminCallables.adminReviewRiderFirestoreIdentity(request.data, callableContext(request), db),
);

exports.supportCreateTicket = onCall(rideCallOpts, async (request) =>
  supportCallables.supportCreateTicket(request.data, callableContext(request), db),
);
exports.supportGetTicket = onCall(rideCallOpts, async (request) =>
  supportCallables.supportGetTicket(request.data, callableContext(request), db),
);
exports.supportSearchRide = onCall(rideCallOpts, async (request) =>
  supportCallables.supportSearchRide(request.data, callableContext(request), db),
);
exports.supportSearchUser = onCall(rideCallOpts, async (request) =>
  supportCallables.supportSearchUser(request.data, callableContext(request), db),
);
exports.supportListTickets = onCall(rideCallOpts, async (request) =>
  supportCallables.supportListTickets(request.data, callableContext(request), db),
);
exports.supportUpdateTicket = onCall(rideCallOpts, async (request) =>
  supportCallables.supportUpdateTicket(request.data, callableContext(request), db),
);
exports.merchantListMySupportTickets = onCall(rideCallOpts, async (request) =>
  supportCallables.merchantListMySupportTickets(request.data, callableContext(request), db),
);
exports.merchantAppendSupportTicketMessage = onCall(rideCallOpts, async (request) =>
  supportCallables.merchantAppendSupportTicketMessage(request.data, callableContext(request), db),
);

exports.setUserRole = onCall(rideCallOpts, async (request) =>
  adminRoles.setUserRole(request.data, callableContext(request), db),
);

exports.bootstrapFirstAdmin = onCall(rideCallOpts, async (request) =>
  adminRoles.bootstrapFirstAdmin(request.data, callableContext(request), db),
);

/**
 * Self-service: invoked by /admin and /support after a successful client-side
 * password change. Clears the `temporaryPassword` claim, revokes refresh tokens
 * (forces sign-out everywhere), and mirrors the cleared flag into RTDB.
 */
exports.rotateAccountAfterPasswordChange = onCall(rideCallOpts, async (request) =>
  accountPassword.rotateAccountAfterPasswordChange(
    request.data,
    callableContext(request),
    db,
  ),
);

exports.registerDevicePushToken = onCall(rideCallOpts, async (request) =>
  pushNotifications.registerDevicePushToken(
    request.data,
    callableContext(request),
    db,
  ),
);

exports.escalateSafetyIncident = onCall(rideCallOpts, async (request) =>
  safetyEscalation.escalateSafetyIncident(
    request.data,
    callableContext(request),
    db,
  ),
);

exports.verifyPayment = onCall(
  { region: REGION, secrets: [flutterwaveSecretKey] },
  async (request) => {
    const reference = String(
      request.data?.reference ??
        request.data?.tx_ref ??
        request.data?.transactionId ??
        request.data?.transaction_id ??
        "",
    ).trim();
    if (!request.auth) {
      return { success: false, reason: "unauthorized" };
    }
    if (!reference) {
      return { success: false, reason: "invalid_reference" };
    }
    return verifyPaymentInternal(reference, normUid(request.auth?.uid));
  },
);

exports.initiateFlutterwavePayment = onCall(
  { region: REGION, secrets: [flutterwaveSecretKey] },
  async (request) =>
    paymentFlow.initiateFlutterwavePayment(
      request.data,
      callableContext(request),
      db,
    ),
);

exports.initiateFlutterwaveMerchantOrderPayment = onCall(
  { region: REGION, secrets: [flutterwaveSecretKey] },
  async (request) =>
    paymentFlow.initiateFlutterwaveMerchantOrderPayment(
      request.data,
      callableContext(request),
      db,
    ),
);

exports.initiateFlutterwaveRideIntent = onCall(
  { region: REGION, secrets: [flutterwaveSecretKey] },
  async (request) =>
    paymentFlow.initiateFlutterwaveRideIntent(
      request.data,
      callableContext(request),
      db,
    ),
);

exports.initiateFlutterwaveCardLinkIntent = onCall(
  { region: REGION, secrets: [flutterwaveSecretKey] },
  async (request) =>
    paymentFlow.initiateFlutterwaveCardLinkIntent(
      request.data,
      callableContext(request),
      db,
    ),
);

exports.abandonFlutterwaveRideIntent = onCall(
  { region: REGION },
  async (request) =>
    paymentFlow.abandonFlutterwaveRideIntent(
      request.data,
      callableContext(request),
      db,
    ),
);

/** Alternate name for hosted-card initialization (Flutter client alias). */
exports.initiatePayment = exports.initiateFlutterwavePayment;

exports.verifyFlutterwavePayment = onCall(
  { region: REGION, secrets: [flutterwaveSecretKey] },
  async (request) =>
    paymentFlow.verifyFlutterwavePayment(
      request.data,
      callableContext(request),
      db,
    ),
);

exports.registerBankTransferPayment = onCall(rideCallOpts, async (request) =>
  paymentFlow.registerBankTransferPayment(
    request.data,
    callableContext(request),
    db,
  ),
);

exports.getNexrideOfficialBankAccount = onCall(rideCallOpts, async (request) =>
  nexrideOfficialBankConfig.getNexrideOfficialBankAccount(
    request.data,
    callableContext(request),
    db,
  ),
);

exports.flutterwaveWebhook = onRequest(
  {
    region: REGION,
    secrets: [flutterwaveWebhookSecret, flutterwaveSecretKey],
    cors: true,
    invoker: "public",
  },
  async (req, res) => paymentFlow.handleFlutterwaveWebhook(req, res, db),
);

exports.createWalletTransaction = onCall(rideCallOpts, async (request) => {
  const ctx = callableContext(request);
  const denyCwt = await adminPerms.enforceCallable(db, ctx, "createWalletTransaction");
  if (denyCwt) return denyCwt;
  const idk = String(request.data?.idempotencyKey ?? "").trim();
  if (!idk) {
    return { success: false, reason: "idempotency_key_required" };
  }
  return createWalletTransactionInternal(db, {
    userId: request.data?.userId,
    amount: request.data?.amount,
    type: request.data?.type,
    idempotencyKey: idk,
  });
});

exports.requestWithdrawal = onCall(rideCallOpts, async (request) =>
  withdrawFlow.requestWithdrawal(request.data, callableContext(request), db),
);

exports.driverGetWithdrawalDestination = onCall(rideCallOpts, async (request) =>
  withdrawFlow.driverGetWithdrawalDestination(request.data, callableContext(request), db),
);

exports.driverUpdateWithdrawalDestination = onCall(rideCallOpts, async (request) =>
  withdrawFlow.driverUpdateWithdrawalDestination(request.data, callableContext(request), db),
);

exports.approveWithdrawal = onCall(rideCallOpts, async (request) =>
  withdrawFlow.approveWithdrawal(request.data, callableContext(request), db),
);

exports.recordTripCompletion = onCall(
  { region: REGION, secrets: [flutterwaveSecretKey] },
  async (request) => {
    const ctx = callableContext(request);
    const denyRtc = await adminPerms.enforceCallable(db, ctx, "recordTripCompletion");
    if (denyRtc) return denyRtc;

    const rideId = String(request.data?.rideId ?? "").trim();
    if (!rideId) {
      return { success: false, reason: "invalid_ride_id" };
    }

    const rideRef = db.ref(`ride_requests/${rideId}`);
    const rideSnap = await rideRef.get();
    const rideVal = rideSnap.val();
    if (!rideVal || typeof rideVal !== "object") {
      return { success: false, reason: "ride_missing" };
    }

    const status = String(rideVal.status || "").toLowerCase();
    const tripState = String(rideVal.trip_state || "").toLowerCase();
    if (
      status !== "completed" &&
      status !== "trip_completed" &&
      tripState !== "trip_completed" &&
      tripState !== "completed"
    ) {
      return { success: false, reason: "trip_not_completed" };
    }

    const paymentReference = String(
      rideVal.customer_transaction_reference || rideVal.payment_reference || ""
    ).trim();
    if (!paymentReference) {
      return { success: false, reason: "missing_payment_reference" };
    }

    const verification = await verifyPaymentInternal(paymentReference);
    if (!verification.success) {
      return { success: false, reason: verification.reason || "verification_failed" };
    }

    const riderId = String(rideVal.rider_id || "").trim();
    const driverId = String(rideVal.driver_id || "").trim();
    if (!riderId || !driverId) {
      return { success: false, reason: "missing_trip_participants" };
    }

    const monetization = await resolveDriverMonetization(db, driverId);
    const commissionPolicy = await resolveCommissionPolicy(db, driverId);
    const feeNgn = commissionPolicy.exempt ? 0 : platformFeeNgn();
    console.log(
      "COMMISSION_EXEMPT",
      `driverId=${driverId}`,
      `exempt=${commissionPolicy.exempt}`,
      `reason=${commissionPolicy.reason}`,
    );
    const totalDeliveryFee = Number(
      rideVal.total_delivery_fee_paid || rideVal.total_delivery_fee || verification.amount || 0
    );
    if (!Number.isFinite(totalDeliveryFee) || totalDeliveryFee <= 0) {
      return { success: false, reason: "invalid_trip_amount" };
    }
    const driverEarning = totalDeliveryFee - feeNgn;
    const completionIdem = `trip_completion_${rideId}`;

    const riderDebit = await createWalletTransactionInternal(db, {
      userId: riderId,
      amount: totalDeliveryFee,
      type: "rider_payment_debit",
      idempotencyKey: `${completionIdem}_rider_debit`,
    });
    if (!riderDebit.success) {
      return { success: false, reason: riderDebit.reason || "rider_debit_failed" };
    }

    if (feeNgn > 0) {
      const platformFeeTx = await createWalletTransactionInternal(db, {
        userId: "nexride_platform",
        amount: feeNgn,
        type: "platform_fee_credit",
        idempotencyKey: `${completionIdem}_platform_fee`,
      });
      if (!platformFeeTx.success) {
        return { success: false, reason: platformFeeTx.reason || "platform_fee_failed" };
      }
    }

    const driverCredit = await createWalletTransactionInternal(db, {
      userId: driverId,
      amount: driverEarning,
      type: "driver_earning_credit",
      idempotencyKey: `${completionIdem}_driver_credit`,
    });
    if (!driverCredit.success) {
      return { success: false, reason: driverCredit.reason || "driver_credit_failed" };
    }

    await rideRef.update({
      payment_verified: true,
      payment_verified_at: Date.now(),
      payment_status: "verified",
      wallet_credit_status: "credited",
      platform_fee_ngn: feeNgn,
      rider_earning_credited: driverEarning,
      monetization_model_applied: monetization.isSubscription ? "subscription" : "commission",
      updated_at: Date.now(),
    });
    await trackPublic.syncRideTrackPublic(db, rideId);

    await db.ref(`driver_earnings/${driverId}/${rideId}`).update({
      rideId,
      amount: driverEarning,
      platformFee: feeNgn,
      grossAmount: totalDeliveryFee,
      monetization_model_applied: monetization.isSubscription ? "subscription" : "commission",
      status: "credited",
      created_at: Date.now(),
      updated_at: Date.now(),
    });

    return {
      success: true,
      reason: "trip_completion_recorded",
      driverEarning,
      platformFee: feeNgn,
    };
  },
);

// --- Merchant order realtime (FCM + public RTDB teaser for riders) ---
const merchantOrderTriggers = require("./merchant_order_triggers");
exports.onMerchantOrderCreatedNotify = merchantOrderTriggers.onMerchantOrderCreatedNotify;
