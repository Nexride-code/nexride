/**
 * Admin-only HTTPS callables (verify `admins/{uid}` or `auth.token.admin`).
 */

const { logger } = require("firebase-functions");
const { getAuth } = require("firebase-admin/auth");
const { isNexRideAdmin, normUid } = require("./admin_auth");
const withdrawFlow = require("./withdraw_flow");
const { fanOutDriverOffersIfEligible } = require("./ride_callables");
const { fanOutDeliveryOffersIfEligible } = require("./delivery_callables");
const { syncRideTrackPublic } = require("./track_public");
const { sendPushToUser } = require("./push_notifications");

function nowMs() {
  return Date.now();
}

async function writeAdminAudit(db, entry) {
  await db
    .ref("admin_audit_logs")
    .push()
    .set({ ...entry, created_at: nowMs() });
}

function pickupAreaHint(ride) {
  const p = ride?.pickup && typeof ride.pickup === "object" ? ride.pickup : {};
  return (
    String(ride?.pickup_area ?? p.area ?? p.city ?? "").trim().slice(0, 80) || "—"
  );
}

function dropoffAreaHint(ride) {
  const d = ride?.dropoff && typeof ride.dropoff === "object" ? ride.dropoff : {};
  return (
    String(ride?.destination_area ?? ride?.dropoff_area ?? d.area ?? d.city ?? d.address ?? "").trim().slice(0, 80) ||
    "—"
  );
}

async function _adminAccessSnapshot(db, context) {
  const uid = normUid(context?.auth?.uid);
  const token = context?.auth?.token && typeof context.auth.token === "object"
    ? context.auth.token
    : {};
  if (!uid) {
    return { uid: "", email: "", claims: token, rtdbAdmin: false, allowed: false };
  }
  const rtdbAdmin = (await db.ref(`admins/${uid}`).get()).val() === true;
  const allowed = token.admin === true || rtdbAdmin;
  return {
    uid,
    email: String(token.email ?? "").trim().toLowerCase(),
    claims: token,
    rtdbAdmin,
    allowed,
  };
}

async function _requireAdmin(functionName, context, db) {
  const access = await _adminAccessSnapshot(db, context);
  if (!access.allowed) {
    logger.warn(
      `ADMIN_CALL_DENIED function=${functionName} uid=${access.uid || "none"} email=${access.email || "none"} claims=${JSON.stringify(access.claims)} rtdbAdmin=${access.rtdbAdmin}`,
    );
    return false;
  }
  logger.info(
    `ADMIN_CALL_ALLOWED function=${functionName} uid=${access.uid} email=${access.email || "none"} rtdbAdmin=${access.rtdbAdmin}`,
  );
  return true;
}

async function adminListLiveRides(_data, context, db) {
  if (!(await _requireAdmin("adminListLiveRides", context, db))) {
    return { success: false, reason: "unauthorized" };
  }
  const snap = await db.ref("active_trips").get();
  const entries = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  const rideIds = Object.keys(entries).slice(0, 150);
  const rides = [];
  for (const rideId of rideIds) {
    const rSnap = await db.ref(`ride_requests/${rideId}`).get();
    const v = rSnap.val();
    if (!v || typeof v !== "object") continue;
    rides.push({
      ride_id: rideId,
      trip_state: v.trip_state ?? null,
      status: v.status ?? null,
      rider_id: normUid(v.rider_id),
      rider_name: String(v.rider_name ?? "").trim() || null,
      driver_id: normUid(v.driver_id) || null,
      driver_name: String(v.driver_name ?? "").trim() || null,
      fare: Number(v.fare ?? 0) || 0,
      currency: String(v.currency ?? "NGN"),
      payment_status: String(v.payment_status ?? ""),
      payment_method: String(v.payment_method ?? ""),
      receipt_uploaded: v.receipt_uploaded === true,
      bank_transfer_receipt_url: String(v.bank_transfer_receipt_url ?? "").trim() || null,
      pickup_area: pickupAreaHint(v),
      dropoff_area: dropoffAreaHint(v),
      updated_at: Number(v.updated_at ?? 0) || 0,
    });
  }
  rides.sort((a, b) => (b.updated_at || 0) - (a.updated_at || 0));
  return { success: true, rides };
}

async function adminGetRideDetails(data, context, db) {
  if (!(await _requireAdmin("adminGetRideDetails", context, db))) {
    return { success: false, reason: "unauthorized" };
  }
  const rideId = normUid(data?.rideId ?? data?.ride_id);
  if (!rideId) {
    return { success: false, reason: "invalid_ride_id" };
  }
  const rSnap = await db.ref(`ride_requests/${rideId}`).get();
  const ride = rSnap.val();
  if (!ride || typeof ride !== "object") {
    return { success: false, reason: "not_found" };
  }
  const trackToken = String(ride.track_token ?? "").trim() || null;
  const payments = [];
  const refKeys = new Set(
    [ride.payment_reference, ride.customer_transaction_reference]
      .map((x) => String(x ?? "").trim())
      .filter(Boolean),
  );
  for (const refKey of refKeys) {
    const [txSnap, paySnap] = await Promise.all([
      db.ref(`payment_transactions/${refKey}`).get(),
      db.ref(`payments/${refKey}`).get(),
    ]);
    const row = txSnap.val() || paySnap.val();
    if (row && typeof row === "object") {
      payments.push({
        reference: refKey,
        verified: !!row.verified,
        amount: Number(row.amount ?? 0) || 0,
        ride_id: row.ride_id ?? null,
        updated_at: Number(row.updated_at ?? 0) || 0,
      });
    }
  }
  return {
    success: true,
    ride,
    track_token: trackToken,
    payments,
  };
}

async function adminApproveWithdrawal(data, context, db) {
  if (!(await _requireAdmin("adminApproveWithdrawal", context, db))) {
    return { success: false, reason: "unauthorized" };
  }
  return withdrawFlow.approveWithdrawal(
    { ...data, status: "paid" },
    context,
    db,
  );
}

async function adminRejectWithdrawal(data, context, db) {
  if (!(await _requireAdmin("adminRejectWithdrawal", context, db))) {
    return { success: false, reason: "unauthorized" };
  }
  return withdrawFlow.approveWithdrawal(
    { ...data, status: "rejected" },
    context,
    db,
  );
}

async function adminVerifyDriver(data, context, db) {
  if (!(await _requireAdmin("adminVerifyDriver", context, db))) {
    return { success: false, reason: "unauthorized" };
  }
  const driverId = normUid(data?.driverId ?? data?.driver_id ?? data?.uid);
  if (!driverId) {
    return { success: false, reason: "invalid_driver_id" };
  }
  const note = String(data?.note ?? "").trim().slice(0, 500);
  const now = Date.now();
  const dSnap = await db.ref(`drivers/${driverId}`).get();
  const prev = dSnap.val() && typeof dSnap.val() === "object" ? dSnap.val() : {};
  if (prev.nexride_verified === true) {
    return { success: true, reason: "already_verified", driverId, idempotent: true };
  }
  await db.ref(`drivers/${driverId}`).update({
    nexride_verified: true,
    nexride_verified_at: now,
    nexride_verified_by: normUid(context.auth.uid),
    nexride_verification_note: note || null,
    updated_at: now,
  });
  await db.ref(`driver_verifications/${driverId}`).update({
    status: "verified",
    verified_at: now,
    verified_by: normUid(context.auth.uid),
    note: note || null,
  });
  console.log(
    "VERIFICATION_APPROVED",
    driverId,
    "admin=",
    normUid(context.auth.uid),
  );
  logger.info("adminVerifyDriver", { driverId, admin: normUid(context.auth.uid) });
  await writeAdminAudit(db, {
    type: "admin_verify_driver",
    driver_id: driverId,
    actor_uid: normUid(context.auth.uid),
    note: note || null,
  });
  return { success: true, reason: "driver_verified", driverId };
}

/**
 * Admin-only: mark a pending bank/card payment as verified without re-calling Flutterwave
 * (evidence reviewed out-of-band). Requires audit note + matching payment_transactions row.
 */
async function adminApproveManualPayment(data, context, db) {
  if (!(await _requireAdmin("adminApproveManualPayment", context, db))) {
    return { success: false, reason: "unauthorized" };
  }
  const adminUid = normUid(context.auth.uid);
  const reference = String(
    data?.reference ?? data?.tx_ref ?? data?.transaction_id ?? data?.transactionId ?? "",
  ).trim();
  const note = String(data?.note ?? data?.reason ?? "").trim();
  if (!reference || note.length < 12) {
    return { success: false, reason: "invalid_input" };
  }
  const ptSnap = await db.ref(`payment_transactions/${reference}`).get();
  const pt = ptSnap.val();
  if (!pt || typeof pt !== "object") {
    return { success: false, reason: "payment_transaction_not_found" };
  }
  if (pt.verified === true) {
    return { success: true, reason: "already_verified", idempotent: true };
  }
  const rideId = normUid(pt.ride_id);
  const deliveryId = normUid(pt.delivery_id);
  if (!rideId && !deliveryId) {
    return { success: false, reason: "missing_trip_reference" };
  }
  const payKey = String(pt.transaction_id ?? pt.flutterwave_transaction_id ?? reference).trim() || reference;
  const riderId = normUid(pt.rider_id);
  const amount = Number(pt.amount ?? 0) || 0;
  const currency = String(pt.currency ?? "NGN").trim().toUpperCase() || "NGN";
  const now = nowMs();

  if (rideId) {
    const rSnap = await db.ref(`ride_requests/${rideId}`).get();
    const ride = rSnap.val();
    if (!ride || typeof ride !== "object") {
      return { success: false, reason: "ride_not_found" };
    }
    const expectedRefs = new Set(
      [ride.payment_reference, ride.customer_transaction_reference, reference]
        .map((x) => String(x ?? "").trim())
        .filter(Boolean),
    );
    if (!expectedRefs.has(reference)) {
      return { success: false, reason: "reference_mismatch_ride" };
    }
    if (riderId && normUid(ride.rider_id) !== riderId) {
      return { success: false, reason: "rider_mismatch" };
    }
  }
  if (deliveryId) {
    const dSnap = await db.ref(`delivery_requests/${deliveryId}`).get();
    const del = dSnap.val();
    if (!del || typeof del !== "object") {
      return { success: false, reason: "delivery_not_found" };
    }
    const expectedRefs = new Set(
      [del.payment_reference, del.customer_transaction_reference, reference]
        .map((x) => String(x ?? "").trim())
        .filter(Boolean),
    );
    if (!expectedRefs.has(reference)) {
      return { success: false, reason: "reference_mismatch_delivery" };
    }
    const cust = normUid(del.customer_id);
    if (riderId && cust !== riderId) {
      return { success: false, reason: "customer_mismatch" };
    }
  }

  await db.ref().update({
    [`payment_transactions/${reference}`]: {
      ...pt,
      tx_ref: pt.tx_ref || reference,
      verified: true,
      provider_status: "successful",
      admin_manual_approved: true,
      admin_manual_approved_at: now,
      admin_manual_approved_by: adminUid,
      admin_manual_approval_note: note.slice(0, 800),
      updated_at: now,
    },
    [`payments/${payKey}`]: {
      provider: "manual_admin",
      transaction_id: payKey,
      tx_ref: reference,
      ride_id: rideId || null,
      delivery_id: deliveryId || null,
      rider_id: riderId || null,
      amount,
      currency,
      status: "verified",
      verified_at: now,
      verified: true,
      webhook_applied: true,
      admin_manual: true,
      updated_at: now,
    },
  });

  if (rideId) {
    await db.ref(`ride_requests/${rideId}`).update({
      payment_status: "verified",
      payment_verified_at: now,
      payment_provider: "manual_admin",
      payment_transaction_id: payKey,
      paid_at: now,
      updated_at: now,
    });
    const activeSnap = await db.ref(`active_trips/${rideId}`).get();
    if (activeSnap.exists()) {
      await db.ref(`active_trips/${rideId}`).update({
        payment_status: "verified",
        payment_provider: "manual_admin",
        payment_transaction_id: payKey,
        paid_at: now,
        updated_at: now,
      });
    }
    const fresh = (await db.ref(`ride_requests/${rideId}`).get()).val();
    await fanOutDriverOffersIfEligible(db, rideId, fresh || {});
    await syncRideTrackPublic(db, rideId);
  }
  if (deliveryId) {
    await db.ref(`delivery_requests/${deliveryId}`).update({
      payment_status: "verified",
      payment_verified_at: now,
      payment_provider: "manual_admin",
      payment_transaction_id: payKey,
      paid_at: now,
      updated_at: now,
    });
    const freshDel = (await db.ref(`delivery_requests/${deliveryId}`).get()).val();
    await fanOutDeliveryOffersIfEligible(db, deliveryId, freshDel || {});
  }

  await writeAdminAudit(db, {
    type: "admin_manual_payment_approve",
    reference,
    ride_id: rideId || null,
    delivery_id: deliveryId || null,
    actor_uid: adminUid,
    note: note.slice(0, 800),
  });
  logger.info("adminApproveManualPayment", { reference, rideId, deliveryId, admin: adminUid });
  return { success: true, reason: "approved" };
}

async function adminSuspendDriver(data, context, db) {
  if (!(await _requireAdmin("adminSuspendDriver", context, db))) {
    return { success: false, reason: "unauthorized" };
  }
  const driverId = normUid(data?.driverId ?? data?.driver_id ?? data?.uid);
  const reason = String(data?.reason ?? data?.note ?? "").trim().slice(0, 500);
  if (!driverId) {
    return { success: false, reason: "invalid_driver_id" };
  }
  if (reason.length < 8) {
    return { success: false, reason: "reason_required" };
  }
  const now = nowMs();
  const adminUid = normUid(context.auth.uid);
  await db.ref(`drivers/${driverId}`).update({
    suspended: true,
    account_suspended: true,
    admin_suspended_at: now,
    admin_suspended_by: adminUid,
    admin_suspension_reason: reason,
    isOnline: false,
    is_online: false,
    online: false,
    isAvailable: false,
    available: false,
    status: "offline",
    dispatch_state: "offline",
    updated_at: now,
  });
  await writeAdminAudit(db, {
    type: "admin_suspend_driver",
    driver_id: driverId,
    actor_uid: adminUid,
    reason,
  });
  logger.info("adminSuspendDriver", { driverId, admin: adminUid });
  return { success: true, reason: "suspended", driverId };
}

async function adminListSupportTickets(_data, context, db) {
  if (!(await _requireAdmin("adminListSupportTickets", context, db))) {
    return { success: false, reason: "unauthorized" };
  }
  const snap = await db.ref("support_tickets").orderByKey().limitToLast(200).get();
  const val = snap.val() || {};
  const tickets = Object.entries(val).map(([id, t]) => ({
    id,
    status: t?.status ?? null,
    createdByUserId: normUid(t?.createdByUserId),
    subject: String(t?.subject ?? "").slice(0, 200) || null,
    ride_id: normUid(t?.ride_id ?? t?.rideId) || null,
    updatedAt: Number(t?.updatedAt ?? t?.updated_at ?? 0) || 0,
    createdAt: Number(t?.createdAt ?? t?.created_at ?? 0) || 0,
  }));
  tickets.sort((a, b) => b.updatedAt - a.updatedAt);
  return { success: true, tickets };
}

async function adminListPendingWithdrawals(_data, context, db) {
  if (!(await _requireAdmin("adminListPendingWithdrawals", context, db))) {
    return { success: false, reason: "unauthorized" };
  }
  const snap = await db.ref("withdraw_requests").orderByChild("status").equalTo("pending").limitToFirst(80).get();
  const raw = snap.val() || {};
  const rows = Object.entries(raw).map(([id, w]) => ({
    id,
    ...w,
  }));
  rows.sort((a, b) => (b.updated_at || b.requestedAt || 0) - (a.updated_at || a.requestedAt || 0));
  return { success: true, withdrawals: rows };
}

async function adminListPayments(_data, context, db) {
  if (!(await _requireAdmin("adminListPayments", context, db))) {
    return { success: false, reason: "unauthorized" };
  }
  const snap = await db.ref("payments").orderByKey().limitToLast(50).get();
  const val = snap.val() || {};
  const rows = Object.entries(val).map(([transaction_id, row]) => ({
    transaction_id,
    verified: !!row?.verified,
    amount: Number(row?.amount ?? 0) || 0,
    ride_id: row?.ride_id ?? null,
    rider_id: row?.rider_id ?? null,
    updated_at: Number(row?.updated_at ?? 0) || 0,
  }));
  rows.sort((a, b) => (b.updated_at || 0) - (a.updated_at || 0));
  return { success: true, payments: rows };
}

async function adminFetchDriversTree(_data, context, db) {
  if (!(await _requireAdmin("adminFetchDriversTree", context, db))) {
    return { success: false, reason: "unauthorized" };
  }
  const snap = await db.ref("drivers").get();
  const val = snap.val();
  const drivers = val && typeof val === "object" ? val : {};
  return { success: true, drivers, count: Object.keys(drivers).length };
}

async function adminListDrivers(_data, context, db) {
  if (!(await _requireAdmin("adminListDrivers", context, db))) {
    return { success: false, reason: "unauthorized" };
  }
  const snap = await db.ref("drivers").limitToFirst(120).get();
  const val = snap.val() || {};
  let drivers = Object.entries(val).map(([uid, d]) => ({
    uid,
    name: String(d?.name ?? d?.driverName ?? "").trim() || null,
    car: String(d?.car ?? "").trim() || null,
    market: String(d?.dispatch_market ?? d?.market ?? "").trim() || null,
    is_online: !!(d?.isOnline ?? d?.is_online),
    nexride_verified: !!d?.nexride_verified,
  }));

  // Fallback for environments where driver records are user-profile based.
  if (drivers.length === 0) {
    const userSnap = await db.ref("users").limitToFirst(300).get();
    const users = userSnap.val() || {};
    drivers = Object.entries(users)
      .filter(([, u]) => {
        const role = String(u?.role ?? u?.account_role ?? "").trim().toLowerCase();
        return role === "driver";
      })
      .map(([uid, u]) => ({
        uid,
        name: String(u?.displayName ?? u?.name ?? "").trim() || null,
        car: String(u?.car ?? "").trim() || null,
        market: String(u?.dispatch_market ?? u?.market ?? "").trim() || null,
        is_online: !!(u?.isOnline ?? u?.is_online),
        nexride_verified: !!(u?.nexride_verified ?? u?.kyc_approved),
      }));
  }
  return { success: true, drivers };
}

async function adminListRiders(_data, context, db) {
  if (!(await _requireAdmin("adminListRiders", context, db))) {
    return { success: false, reason: "unauthorized" };
  }
  const snap = await db.ref("users").limitToFirst(120).get();
  const val = snap.val() || {};
  const riders = Object.entries(val).map(([uid, u]) => ({
    uid,
    displayName: String(u?.displayName ?? "").trim() || null,
    email: String(u?.email ?? "").trim() || null,
  }));
  return { success: true, riders };
}

async function adminReviewSubscriptionRequest(data, context, db) {
  if (!(await _requireAdmin("adminReviewSubscriptionRequest", context, db))) {
    return { success: false, reason: "unauthorized" };
  }
  let driverId = "";
  let action = "";
  try {
    driverId = normUid(data?.driverId ?? data?.driver_id ?? data?.uid);
    action = String(data?.action ?? "").trim().toLowerCase();
    logger.info("ADMIN_REVIEW_START", { driverId, action });
    if (!driverId || (action !== "approve" && action !== "reject")) {
      logger.info("ADMIN_REVIEW_INVALID_INPUT", { driverId, action });
      return { success: false, reason: "invalid_input" };
    }
    const now = nowMs();
    const driverSnap = await db.ref(`drivers/${driverId}`).get();
    const driverExists =
      typeof driverSnap.exists === "function"
        ? driverSnap.exists()
        : !!driverSnap.exists;
    logger.info("ADMIN_REVIEW_DRIVER_READ", {
      exists: driverExists,
      driverId,
    });
    const driver =
      driverSnap.val() && typeof driverSnap.val() === "object" ? driverSnap.val() : null;
    if (!driver) {
      logger.warn("ADMIN_REVIEW_DRIVER_MISSING", { driverId });
      return { success: false, reason: "driver_not_found" };
    }
    const planType = String(
      driver.subscription_type ??
        driver?.businessModel?.subscription?.planType ??
        "monthly",
    )
      .trim()
      .toLowerCase() === "weekly"
      ? "weekly"
      : "monthly";
    const durationDays = planType === "weekly" ? 7 : 30;
    const expiresAt = now + durationDays * 24 * 60 * 60 * 1000;
    logger.info("ADMIN_REVIEW_COMPUTING", { action, planType, expiresAt });
    const expiryDateLabel = new Date(expiresAt).toLocaleDateString("en-NG", {
      day: "2-digit",
      month: "short",
      year: "numeric",
    });
    const updates = {
      [`drivers/${driverId}/subscription_pending`]: false,
      [`drivers/${driverId}/updated_at`]: now,
      [`drivers/${driverId}/businessModel/selectedModel`]: "subscription",
      [`drivers/${driverId}/businessModel/subscription/planType`]: planType,
      [`drivers/${driverId}/businessModel/subscription/updatedAt`]: now,
      [`drivers/${driverId}/businessModel/updatedAt`]: now,
    };
    if (action === "approve") {
      updates[`drivers/${driverId}/subscription_status`] = "active";
      updates[`drivers/${driverId}/commission_exempt`] = true;
      updates[`drivers/${driverId}/subscription_renewal_reminder_sent`] = false;
      updates[`drivers/${driverId}/subscription_expires_at`] = expiresAt;
      updates[`drivers/${driverId}/businessModel/subscription/status`] = "active";
      updates[`drivers/${driverId}/businessModel/subscription/paymentStatus`] = "paid";
      updates[`drivers/${driverId}/businessModel/commissionExempt`] = true;
      updates[`drivers/${driverId}/businessModel/commission_exempt`] = true;
    } else {
      updates[`drivers/${driverId}/subscription_status`] = "rejected";
      updates[`drivers/${driverId}/commission_exempt`] = false;
      updates[`drivers/${driverId}/businessModel/subscription/status`] = "rejected";
      updates[`drivers/${driverId}/businessModel/subscription/paymentStatus`] = "rejected";
      updates[`drivers/${driverId}/businessModel/commissionExempt`] = false;
      updates[`drivers/${driverId}/businessModel/commission_exempt`] = false;
    }
    await db.ref().update(updates);
    logger.info("ADMIN_REVIEW_RTDB_WRITTEN", { driverId, action });
    if (action === "approve") {
      await sendPushToUser(db, driverId, {
        notification: {
          title: "Subscription Approved!",
          body: `You now keep 100% of your trip earnings. Your plan is active until ${expiryDateLabel}.`,
        },
        data: {
          type: "subscription_status",
          status: "active",
          expires_at: String(expiresAt),
        },
      });
    } else {
      await sendPushToUser(db, driverId, {
        notification: {
          title: "Subscription Update",
          body: "Your subscription request was not approved. Please contact NexRide support for assistance.",
        },
        data: {
          type: "subscription_status",
          status: "rejected",
        },
      });
    }
    logger.info("ADMIN_REVIEW_FCM_SENT", { driverId });
    await writeAdminAudit(db, {
      type: "admin_subscription_review",
      driver_id: driverId,
      action,
      actor_uid: normUid(context.auth.uid),
      plan_type: planType,
      expires_at: action === "approve" ? expiresAt : null,
    });
    logger.info("ADMIN_REVIEW_COMPLETE", {
      driverId,
      action,
      success: true,
    });
    return { success: true, action, driverId };
  } catch (error) {
    logger.error("ADMIN_REVIEW_UNHANDLED_ERROR", {
      message: error?.message,
      stack: error?.stack,
      driverId,
      action,
    });
    throw error;
  }
}

async function adminFetchSubscriptionProofUrl(data, context, db) {
  if (!(await _requireAdmin("adminFetchSubscriptionProofUrl", context, db))) {
    return { success: false, reason: "unauthorized" };
  }
  const driverId = normUid(data?.driverId ?? data?.driver_id ?? data?.uid);
  if (!driverId) {
    return { success: false, reason: "invalid_driver_id" };
  }
  const snap = await db.ref(`drivers/${driverId}/subscription_proof_url`).get();
  const proofUrl = String(snap.val() ?? "").trim();
  if (!proofUrl) {
    return { success: false, reason: "no_proof_url" };
  }
  logger.info("adminFetchSubscriptionProofUrl", { driverId, admin: normUid(context.auth.uid) });
  return { success: true, proofUrl };
}

async function adminSuspendAccount(data, context, db) {
  if (!(await _requireAdmin("adminSuspendAccount", context, db))) {
    return { success: false, reason: "unauthorized" };
  }
  const uid = normUid(data?.uid ?? data?.userId);
  const role = String(data?.role ?? "").trim().toLowerCase();
  const reason = String(data?.reason ?? "").trim().slice(0, 500);
  if (!uid || (role !== "driver" && role !== "rider")) {
    return { success: false, reason: "invalid_input" };
  }
  if (reason.length < 8) {
    return { success: false, reason: "reason_required" };
  }
  const adminUid = normUid(context.auth.uid);
  const now = nowMs();
  if (role === "driver") {
    await db.ref(`drivers/${uid}`).update({
      suspended: true,
      account_suspended: true,
      account_status: "suspended",
      accountStatus: "suspended",
      admin_suspended_at: now,
      admin_suspended_by: adminUid,
      admin_suspension_reason: reason,
      isOnline: false,
      is_online: false,
      online: false,
      isAvailable: false,
      available: false,
      status: "offline",
      dispatch_state: "offline",
      updated_at: now,
    });
    await sendPushToUser(db, uid, {
      notification: {
        title: "Account suspended",
        body: "Your account has been suspended. Contact support.",
      },
    });
  } else {
    await db.ref(`users/${uid}`).update({
      status: "suspended",
      account_status: "suspended",
      admin_suspended_at: now,
      admin_suspended_by: adminUid,
      admin_suspension_reason: reason,
      updated_at: now,
      "trustSummary/accountStatus": "suspended",
    });
    await sendPushToUser(db, uid, {
      notification: {
        title: "Account suspended",
        body: "Your account has been suspended. Contact support.",
      },
    });
  }
  await writeAdminAudit(db, {
    type: "admin_suspend_account",
    uid,
    role,
    actor_uid: adminUid,
    reason,
  });
  logger.info("adminSuspendAccount", { uid, role, admin: adminUid });
  return { success: true, uid, role };
}

async function adminWarnAccount(data, context, db) {
  if (!(await _requireAdmin("adminWarnAccount", context, db))) {
    return { success: false, reason: "unauthorized" };
  }
  const uid = normUid(data?.uid ?? data?.userId);
  const role = String(data?.role ?? "").trim().toLowerCase();
  const reason = String(data?.reason ?? "").trim().slice(0, 500);
  const message = String(data?.message ?? "").trim().slice(0, 500);
  if (!uid || (role !== "driver" && role !== "rider")) {
    return { success: false, reason: "invalid_input" };
  }
  if (reason.length < 4) {
    return { success: false, reason: "reason_required" };
  }
  const adminUid = normUid(context.auth.uid);
  const now = nowMs();
  const warnPath = role === "driver" ? `drivers/${uid}/warnings` : `users/${uid}/warnings`;
  await db.ref(warnPath).push().set({
    created_at: now,
    reason,
    message: message || null,
    admin_uid: adminUid,
  });
  await sendPushToUser(db, uid, {
    notification: {
      title: "NexRide notice",
      body: "You have received a warning from NexRide.",
    },
    data: {
      kind: "admin_warning",
      reason: reason.slice(0, 200),
    },
  });
  await writeAdminAudit(db, {
    type: "admin_warn_account",
    uid,
    role,
    actor_uid: adminUid,
    reason,
    message: message || null,
  });
  logger.info("adminWarnAccount", { uid, role, admin: adminUid });
  return { success: true, uid, role };
}

async function adminDeleteAccount(data, context, db) {
  if (!(await _requireAdmin("adminDeleteAccount", context, db))) {
    return { success: false, reason: "unauthorized" };
  }
  const uid = normUid(data?.uid ?? data?.userId);
  const role = String(data?.role ?? "").trim().toLowerCase();
  if (!uid || (role !== "driver" && role !== "rider")) {
    return { success: false, reason: "invalid_input" };
  }
  const adminUid = normUid(context.auth.uid);
  if (uid === adminUid) {
    return { success: false, reason: "cannot_delete_self" };
  }
  const updates = {};
  updates[`user_device_tokens/${uid}`] = null;
  if (role === "driver") {
    updates[`drivers/${uid}`] = null;
    updates[`users/${uid}`] = null;
  } else {
    updates[`users/${uid}`] = null;
  }
  await db.ref().update(updates);
  try {
    await getAuth().deleteUser(uid);
  } catch (err) {
    logger.warn("adminDeleteAccount: auth deleteUser failed", {
      uid,
      err: String(err?.message || err),
    });
  }
  await writeAdminAudit(db, {
    type: "admin_delete_account",
    uid,
    role,
    actor_uid: adminUid,
  });
  logger.info("adminDeleteAccount", { uid, role, admin: adminUid });
  return { success: true, uid, role };
}

async function adminApproveDriverVerification(data, context, db) {
  if (!(await _requireAdmin("adminApproveDriverVerification", context, db))) {
    return { success: false, reason: "unauthorized" };
  }
  const driverId = normUid(data?.driverId ?? data?.driver_id ?? data?.uid);
  if (!driverId) {
    return { success: false, reason: "invalid_driver_id" };
  }
  const now = nowMs();
  const adminUid = normUid(context.auth.uid);
  await db.ref(`drivers/${driverId}`).update({
    verification_status: "approved",
    is_verified: true,
    verification_approved_at: now,
    verification_approved_by: adminUid,
    "verification/overallStatus": "approved",
    updated_at: now,
  });
  await writeAdminAudit(db, {
    type: "admin_approve_driver_verification",
    driver_id: driverId,
    actor_uid: adminUid,
  });
  logger.info("adminApproveDriverVerification", { driverId, admin: adminUid });
  return { success: true, driverId };
}

module.exports = {
  adminListLiveRides,
  adminGetRideDetails,
  adminApproveWithdrawal,
  adminRejectWithdrawal,
  adminVerifyDriver,
  adminApproveManualPayment,
  adminSuspendDriver,
  adminListSupportTickets,
  adminListPendingWithdrawals,
  adminListPayments,
  adminListDrivers,
  adminFetchDriversTree,
  adminListRiders,
  adminReviewSubscriptionRequest,
  adminFetchSubscriptionProofUrl,
  adminSuspendAccount,
  adminWarnAccount,
  adminDeleteAccount,
  adminApproveDriverVerification,
};
