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

function callableContext(request) {
  return { auth: request.auth };
}

const { isNexRideAdmin } = require("./admin_auth");
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

async function verifyPaymentInternal(reference) {
  const ref = String(reference || "").trim();
  const txRef = db.ref(`payment_transactions/${ref}`);
  const existingSnap = await txRef.get();
  const existing = existingSnap.val() || {};
  if (existing.verified === true) {
    return {
      success: true,
      reason: "already_verified",
      amount: Number(existing.amount || 0),
      providerStatus: String(existing.provider_status || "successful"),
    };
  }

  let rideId = String(existing.ride_id || "").trim();
  let deliveryId = String(existing.delivery_id || "").trim();
  const riderId = String(existing.rider_id || "").trim();
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
    return { success: false, reason: v.reason || "verification_failed" };
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
exports.validateServiceLocation = onCall(rideCallOpts, async (request) =>
  ecosystemDelivery.validateServiceLocation(request.data, callableContext(request)),
);
exports.backfillUserRolloutRegions = onCall(rideCallOpts, async (request) =>
  rolloutBackfill.adminBackfillUserRolloutRegions(request.data, callableContext(request), db),
);

// --- Merchant Phase 1 (registration + admin review only; no orders/menus/wallets) ---
const merchantCallables = require("./merchant/merchant_callables");
exports.merchantRegister = onCall(rideCallOpts, async (request) =>
  merchantCallables.merchantRegister(request.data, callableContext(request), db),
);
exports.adminListMerchants = onCall(rideCallOpts, async (request) =>
  merchantCallables.adminListMerchants(request.data, callableContext(request), db),
);
exports.adminGetMerchant = onCall(rideCallOpts, async (request) =>
  merchantCallables.adminGetMerchant(request.data, callableContext(request), db),
);
exports.adminReviewMerchant = onCall(rideCallOpts, async (request) =>
  merchantCallables.adminReviewMerchant(request.data, callableContext(request), db),
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
      [`active_trips/${riderId}`]: null,
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
    return verifyPaymentInternal(reference);
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
  if (!ctx.auth || !(await isNexRideAdmin(db, ctx))) {
    return { success: false, reason: "unauthorized" };
  }
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

exports.approveWithdrawal = onCall(rideCallOpts, async (request) =>
  withdrawFlow.approveWithdrawal(request.data, callableContext(request), db),
);

exports.recordTripCompletion = onCall(
  { region: REGION, secrets: [flutterwaveSecretKey] },
  async (request) => {
    const ctx = callableContext(request);
    if (!ctx.auth || !(await isNexRideAdmin(db, ctx))) {
      return { success: false, reason: "unauthorized" };
    }

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
