/**
 * Admin-only HTTPS callables (verify `admins/{uid}` or `auth.token.admin`).
 */

const { logger } = require("firebase-functions");
const { isNexRideAdmin, normUid } = require("./admin_auth");
const withdrawFlow = require("./withdraw_flow");

function pickupAreaHint(ride) {
  const p = ride?.pickup && typeof ride.pickup === "object" ? ride.pickup : {};
  return (
    String(ride?.pickup_area ?? p.area ?? p.city ?? "").trim().slice(0, 80) || "—"
  );
}

async function adminListLiveRides(_data, context, db) {
  if (!(await isNexRideAdmin(db, context))) {
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
      driver_id: normUid(v.driver_id) || null,
      fare: Number(v.fare ?? 0) || 0,
      currency: String(v.currency ?? "NGN"),
      payment_status: String(v.payment_status ?? ""),
      pickup_area: pickupAreaHint(v),
      updated_at: Number(v.updated_at ?? 0) || 0,
    });
  }
  rides.sort((a, b) => (b.updated_at || 0) - (a.updated_at || 0));
  return { success: true, rides };
}

async function adminGetRideDetails(data, context, db) {
  if (!(await isNexRideAdmin(db, context))) {
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
  if (!(await isNexRideAdmin(db, context))) {
    return { success: false, reason: "unauthorized" };
  }
  return withdrawFlow.approveWithdrawal(
    { ...data, status: "paid" },
    context,
    db,
  );
}

async function adminRejectWithdrawal(data, context, db) {
  if (!(await isNexRideAdmin(db, context))) {
    return { success: false, reason: "unauthorized" };
  }
  return withdrawFlow.approveWithdrawal(
    { ...data, status: "rejected" },
    context,
    db,
  );
}

async function adminVerifyDriver(data, context, db) {
  if (!(await isNexRideAdmin(db, context))) {
    return { success: false, reason: "unauthorized" };
  }
  const driverId = normUid(data?.driverId ?? data?.driver_id ?? data?.uid);
  if (!driverId) {
    return { success: false, reason: "invalid_driver_id" };
  }
  const note = String(data?.note ?? "").trim().slice(0, 500);
  const now = Date.now();
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
  return { success: true, reason: "driver_verified", driverId };
}

async function adminListPendingWithdrawals(_data, context, db) {
  if (!(await isNexRideAdmin(db, context))) {
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
  if (!(await isNexRideAdmin(db, context))) {
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

async function adminListDrivers(_data, context, db) {
  if (!(await isNexRideAdmin(db, context))) {
    return { success: false, reason: "unauthorized" };
  }
  const snap = await db.ref("drivers").limitToFirst(120).get();
  const val = snap.val() || {};
  const drivers = Object.entries(val).map(([uid, d]) => ({
    uid,
    name: String(d?.name ?? d?.driverName ?? "").trim() || null,
    car: String(d?.car ?? "").trim() || null,
    market: String(d?.dispatch_market ?? d?.market ?? "").trim() || null,
    is_online: !!(d?.isOnline ?? d?.is_online),
    nexride_verified: !!d?.nexride_verified,
  }));
  return { success: true, drivers };
}

async function adminListRiders(_data, context, db) {
  if (!(await isNexRideAdmin(db, context))) {
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

module.exports = {
  adminListLiveRides,
  adminGetRideDetails,
  adminApproveWithdrawal,
  adminRejectWithdrawal,
  adminVerifyDriver,
  adminListPendingWithdrawals,
  adminListPayments,
  adminListDrivers,
  adminListRiders,
};
