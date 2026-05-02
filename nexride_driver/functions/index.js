require("./params");
const { onCall, onRequest } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { verifyFlutterwavePaymentStrict } = require("./flutterwave_api");
const { createWalletTransactionInternal } = require("./wallet_core");
const {
  flutterwaveSecretKey,
  flutterwaveWebhookSecret,
  REGION,
  platformFeeNgn,
} = require("./params");

admin.initializeApp();
const db = admin.database();

function callableContext(request) {
  return { auth: request.auth };
}

const { isNexRideAdmin } = require("./admin_auth");
const ride = require("./ride_callables");
const paymentFlow = require("./payment_flow");
const withdrawFlow = require("./withdraw_flow");
const trackPublic = require("./track_public");
const adminCallables = require("./admin_callables");
const supportCallables = require("./support_callables");
const { getRideCallRtcToken } = require("./ride_call_rtc");

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

  const rideId = String(existing.ride_id || "").trim();
  const riderId = String(existing.rider_id || "").trim();
  const rideSnap = rideId ? await db.ref(`ride_requests/${rideId}`).get() : null;
  const rideRow = rideSnap && rideSnap.val() && typeof rideSnap.val() === "object" ? rideSnap.val() : null;
  const expectedTx = String(
    rideRow
      ? (rideRow.customer_transaction_reference ?? rideRow.payment_reference ?? ref)
      : ref,
  ).trim();
  const expectCur = String(
    rideRow?.currency ?? existing.currency ?? "NGN",
  )
    .trim()
    .toUpperCase() || "NGN";
  let minFare;
  if (rideRow) {
    const f = Number(rideRow.fare ?? rideRow.total_delivery_fee ?? 0);
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
  const driverId = rideRow ? String(rideRow.driver_id || "").trim() : "";
  await paymentFlow.persistVerifiedFlutterwaveCharge(db, {
    transactionId: payKey,
    txRef: String(v.tx_ref || ref).trim(),
    rideId: rideId || null,
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

exports.acceptRide = onCall(rideCallOpts, async (request) =>
  ride.acceptRideRequest(request.data, callableContext(request), db),
);

/** @deprecated Prefer acceptRide — kept for older client builds */
exports.acceptRideRequest = exports.acceptRide;

exports.driverEnroute = onCall(rideCallOpts, async (request) =>
  ride.driverEnroute(request.data, callableContext(request), db),
);

exports.driverArrived = onCall(rideCallOpts, async (request) =>
  ride.driverArrived(request.data, callableContext(request), db),
);

exports.startTrip = onCall(rideCallOpts, async (request) =>
  ride.startTrip(request.data, callableContext(request), db),
);

exports.completeTrip = onCall(rideCallOpts, async (request) =>
  ride.completeTrip(request.data, callableContext(request), db),
);

exports.cancelRide = onCall(rideCallOpts, async (request) =>
  ride.cancelRideRequest(request.data, callableContext(request), db),
);

/** @deprecated Prefer cancelRide */
exports.cancelRideRequest = exports.cancelRide;

exports.expireRideRequest = onCall(rideCallOpts, async (request) =>
  ride.expireRideRequest(request.data, callableContext(request), db),
);

exports.patchRideRequestMetadata = onCall(rideCallOpts, async (request) =>
  ride.patchRideRequestMetadata(request.data, callableContext(request), db),
);

/** Public tracking — `token` is `ride_requests.track_token` (share link). */
exports.getRideTrackSummary = onCall(
  { region: REGION, invoker: "public" },
  async (request) => trackPublic.getRideTrackSummary(request.data, db),
);

/** Agora RTC — server-signed token; requires AGORA_APP_ID + AGORA_APP_CERTIFICATE in env. */
exports.getRideCallRtcToken = onCall(rideCallOpts, async (request) =>
  getRideCallRtcToken(request.data, callableContext(request), db),
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
exports.adminListPendingWithdrawals = onCall(rideCallOpts, async (request) =>
  adminCallables.adminListPendingWithdrawals(request.data, callableContext(request), db),
);
exports.adminListPayments = onCall(rideCallOpts, async (request) =>
  adminCallables.adminListPayments(request.data, callableContext(request), db),
);
exports.adminListDrivers = onCall(rideCallOpts, async (request) =>
  adminCallables.adminListDrivers(request.data, callableContext(request), db),
);
exports.adminListRiders = onCall(rideCallOpts, async (request) =>
  adminCallables.adminListRiders(request.data, callableContext(request), db),
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

exports.verifyFlutterwavePayment = onCall(
  { region: REGION, secrets: [flutterwaveSecretKey] },
  async (request) =>
    paymentFlow.verifyFlutterwavePayment(
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
  return createWalletTransactionInternal(db, {
    userId: request.data?.userId,
    amount: request.data?.amount,
    type: request.data?.type,
    idempotencyKey: request.data?.idempotencyKey,
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

    const feeNgn = platformFeeNgn();

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

    const totalDeliveryFee = Number(
      rideVal.total_delivery_fee_paid || rideVal.total_delivery_fee || verification.amount || 0
    );
    if (!Number.isFinite(totalDeliveryFee) || totalDeliveryFee <= feeNgn) {
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

    const platformFeeTx = await createWalletTransactionInternal(db, {
      userId: "nexride_platform",
      amount: feeNgn,
      type: "platform_fee_credit",
      idempotencyKey: `${completionIdem}_platform_fee`,
    });
    if (!platformFeeTx.success) {
      return { success: false, reason: platformFeeTx.reason || "platform_fee_failed" };
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
      updated_at: Date.now(),
    });
    await trackPublic.syncRideTrackPublic(db, rideId);

    await db.ref(`driver_earnings/${driverId}/${rideId}`).update({
      rideId,
      amount: driverEarning,
      platformFee: feeNgn,
      grossAmount: totalDeliveryFee,
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
