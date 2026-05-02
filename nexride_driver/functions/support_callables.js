/**
 * Support staff callables — `support_staff/{uid}` or `auth.token.support_staff`.
 */

const { logger } = require("firebase-functions");
const { isNexRideAdminOrSupport, normUid } = require("./admin_auth");

function maskEmail(email) {
  const e = String(email || "").trim();
  if (!e.includes("@")) return null;
  const [u, d] = e.split("@");
  if (!d) return null;
  if (!u.length) return `*@${d}`;
  return `${u[0]}***@${d}`;
}

function pickupAreaHint(ride) {
  const p = ride?.pickup && typeof ride.pickup === "object" ? ride.pickup : {};
  return String(ride?.pickup_area ?? p.area ?? p.city ?? "").trim().slice(0, 80) || "—";
}

async function supportSearchRide(data, context, db) {
  if (!(await isNexRideAdminOrSupport(db, context))) {
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
  const riderId = normUid(ride.rider_id);
  const driverId = normUid(ride.driver_id);
  const [riderUserSnap, driverUserSnap, driverProfSnap] = await Promise.all([
    riderId ? db.ref(`users/${riderId}`).get() : Promise.resolve(null),
    driverId ? db.ref(`users/${driverId}`).get() : Promise.resolve(null),
    driverId ? db.ref(`drivers/${driverId}`).get() : Promise.resolve(null),
  ]);
  const ru = riderUserSnap ? riderUserSnap.val() : null;
  const du = driverUserSnap ? driverUserSnap.val() : null;
  const dp = driverProfSnap ? driverProfSnap.val() : null;

  return {
    success: true,
    ride_id: rideId,
    ride_summary: {
      trip_state: ride.trip_state ?? null,
      status: ride.status ?? null,
      fare: Number(ride.fare ?? 0) || 0,
      currency: String(ride.currency ?? "NGN"),
      payment_status: String(ride.payment_status ?? ""),
      pickup_area: pickupAreaHint(ride),
      track_token: String(ride.track_token ?? "").trim() || null,
    },
    rider_safe: riderId
      ? {
          uid_suffix: riderId.slice(-6),
          display_name: String(ru?.displayName ?? "").trim() || null,
          email_masked: maskEmail(ru?.email),
        }
      : null,
    driver_safe: driverId
      ? {
          uid_suffix: driverId.slice(-6),
          display_name: String(du?.displayName ?? dp?.name ?? "").trim() || null,
          email_masked: maskEmail(du?.email),
          vehicle_label: String(dp?.car ?? "").trim().slice(0, 80) || null,
        }
      : null,
  };
}

async function supportListTickets(_data, context, db) {
  if (!(await isNexRideAdminOrSupport(db, context))) {
    return { success: false, reason: "unauthorized" };
  }
  const snap = await db.ref("support_tickets").orderByKey().limitToLast(60).get();
  const val = snap.val() || {};
  const tickets = Object.entries(val).map(([id, t]) => ({
    id,
    status: t?.status ?? null,
    createdByUserId: t?.createdByUserId ?? null,
    subject: String(t?.subject ?? "").slice(0, 200) || null,
    updatedAt: Number(t?.updatedAt ?? t?.updated_at ?? 0) || 0,
  }));
  tickets.sort((a, b) => b.updatedAt - a.updatedAt);
  return { success: true, tickets };
}

async function supportUpdateTicket(data, context, db) {
  if (!(await isNexRideAdminOrSupport(db, context))) {
    return { success: false, reason: "unauthorized" };
  }
  const ticketId = normUid(data?.ticketId ?? data?.ticket_id);
  const status = String(data?.status ?? "").trim();
  const message = String(data?.message ?? "").trim().slice(0, 2000);
  if (!ticketId) {
    return { success: false, reason: "invalid_ticket_id" };
  }
  const now = Date.now();
  const actor = normUid(context.auth.uid);
  const updates = {
    updatedAt: now,
    updated_at: now,
    last_updated_by: actor,
  };
  if (status) updates.status = status;
  if (message) {
    updates.last_message = message;
    updates.last_message_at = now;
  }
  await db.ref(`support_tickets/${ticketId}`).update(updates);
  if (message) {
    const msgKey = db.ref("support_ticket_messages").push().key;
    if (msgKey) {
      await db.ref(`support_ticket_messages/${msgKey}`).set({
        ticketId,
        body: message,
        authorUid: actor,
        createdAt: now,
        role: "support",
      });
    }
  }
  logger.info("supportUpdateTicket", { ticketId, actor, status: status || undefined });
  return { success: true, reason: "updated", ticketId };
}

async function supportSearchUser(data, context, db) {
  if (!(await isNexRideAdminOrSupport(db, context))) {
    return { success: false, reason: "unauthorized" };
  }
  const uid = normUid(data?.uid ?? data?.userId ?? data?.user_id);
  if (!uid) {
    return { success: false, reason: "invalid_uid" };
  }
  const [uSnap, dSnap] = await Promise.all([
    db.ref(`users/${uid}`).get(),
    db.ref(`drivers/${uid}`).get(),
  ]);
  const u = uSnap.val();
  const d = dSnap.val();
  return {
    success: true,
    profile: {
      uid_suffix: uid.slice(-6),
      display_name: String(u?.displayName ?? d?.name ?? "").trim() || null,
      email_masked: maskEmail(u?.email),
      driver_car: d ? String(d.car ?? "").trim() || null : null,
      nexride_verified: !!d?.nexride_verified,
    },
  };
}

module.exports = {
  supportSearchRide,
  supportSearchUser,
  supportListTickets,
  supportUpdateTicket,
};
