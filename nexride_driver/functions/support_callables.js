/**
 * Support staff callables — `support_staff/{uid}` or `auth.token.support_staff`.
 */

const { logger } = require("firebase-functions");
const { isNexRideAdminOrSupport, normUid } = require("./admin_auth");
const { sendPushToUser } = require("./push_notifications");

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

async function _supportAccessSnapshot(db, context) {
  const uid = normUid(context?.auth?.uid);
  const token = context?.auth?.token && typeof context.auth.token === "object"
    ? context.auth.token
    : {};
  const claimRole = String(token.role ?? "").trim().toLowerCase();
  if (!uid) {
    return {
      uid: "",
      email: "",
      claims: token,
      supportRecord: null,
      rtdbAdmin: false,
      allowed: false,
    };
  }
  const [adminSnap, supportSnap] = await Promise.all([
    db.ref(`admins/${uid}`).get(),
    db.ref(`support_staff/${uid}`).get(),
  ]);
  const rtdbAdmin = adminSnap.val() === true;
  const supportRecord = supportSnap.val();
  const supportRole = String(supportRecord?.role ?? "").trim().toLowerCase();
  const supportEnabled = !!supportRecord && supportRecord.enabled !== false && supportRecord.disabled !== true;
  const supportRoleValid = supportRole === "support_agent" || supportRole === "support_manager";
  const claimSupport = token.support === true || token.support_staff === true;
  const claimRoleValid = claimRole === "support_agent" || claimRole === "support_manager";
  const allowed = token.admin === true || rtdbAdmin || claimSupport || claimRoleValid || (supportEnabled && supportRoleValid);
  return {
    uid,
    email: String(token.email ?? "").trim().toLowerCase(),
    claims: token,
    supportRecord: supportRecord ?? null,
    rtdbAdmin,
    allowed,
  };
}

async function _requireSupport(functionName, context, db) {
  const access = await _supportAccessSnapshot(db, context);
  if (!access.allowed) {
    logger.warn(
      `SUPPORT_CALL_DENIED function=${functionName} uid=${access.uid || "none"} email=${access.email || "none"} claims=${JSON.stringify(access.claims)} supportRecord=${JSON.stringify(access.supportRecord)} rtdbAdmin=${access.rtdbAdmin}`,
    );
    return false;
  }
  logger.info(
    `SUPPORT_CALL_ALLOWED function=${functionName} uid=${access.uid} email=${access.email || "none"} rtdbAdmin=${access.rtdbAdmin}`,
  );
  return true;
}

async function supportCreateTicket(data, context, db) {
  if (!context.auth?.uid) {
    return { success: false, reason: "unauthorized" };
  }
  const uid = normUid(context.auth.uid);
  const subject = String(data?.subject ?? "").trim().slice(0, 200);
  const body = String(data?.body ?? data?.message ?? "").trim().slice(0, 8000);
  const rideId = normUid(data?.rideId ?? data?.ride_id);
  if (subject.length < 4) {
    return { success: false, reason: "invalid_subject" };
  }
  const now = Date.now();
  const ticketRef = db.ref("support_tickets").push();
  const ticketId = normUid(ticketRef.key);
  if (!ticketId) {
    return { success: false, reason: "ticket_id_failed" };
  }
  await ticketRef.set({
    createdByUserId: uid,
    subject,
    status: "open",
    ride_id: rideId || null,
    createdAt: now,
    created_at: now,
    updatedAt: now,
    updated_at: now,
    last_message: body ? body.slice(0, 500) : null,
    last_message_at: body ? now : null,
  });
  if (body) {
    const msgKey = db.ref("support_ticket_messages").push().key;
    if (msgKey) {
      await db.ref(`support_ticket_messages/${msgKey}`).set({
        ticketId,
        body,
        authorUid: uid,
        createdAt: now,
        role: "user",
      });
    }
  }
  logger.info("supportCreateTicket", { ticketId, uid });
  return { success: true, reason: "created", ticketId };
}

async function supportGetTicket(data, context, db) {
  if (!context.auth?.uid) {
    return { success: false, reason: "unauthorized" };
  }
  const uid = normUid(context.auth.uid);
  const ticketId = normUid(data?.ticketId ?? data?.ticket_id);
  if (!ticketId) {
    return { success: false, reason: "invalid_ticket_id" };
  }
  const snap = await db.ref(`support_tickets/${ticketId}`).get();
  const row = snap.val();
  if (!row || typeof row !== "object") {
    return { success: false, reason: "not_found" };
  }
  const owner = normUid(row.createdByUserId);
  const staff = await isNexRideAdminOrSupport(db, context);
  if (owner !== uid && !staff) {
    return { success: false, reason: "forbidden" };
  }
  return { success: true, ticket: row, ticketId };
}

async function supportSearchRide(data, context, db) {
  if (!(await _requireSupport("supportSearchRide", context, db))) {
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
  if (!(await _requireSupport("supportListTickets", context, db))) {
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
  if (!(await _requireSupport("supportUpdateTicket", context, db))) {
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
  const ticketSnap = await db.ref(`support_tickets/${ticketId}`).get();
  const ticket = ticketSnap.val() && typeof ticketSnap.val() === "object" ? ticketSnap.val() : {};
  const ownerUid = normUid(ticket.createdByUserId);
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
  if (ownerUid && (message || status)) {
    await sendPushToUser(db, ownerUid, {
      notification: {
        title: "Support ticket updated",
        body: message
          ? "NexRide support replied to your ticket."
          : `Ticket status updated to ${status}.`,
      },
      data: {
        type: "support_ticket_update",
        ticketId,
        status: status || "",
      },
    });
  }
  return { success: true, reason: "updated", ticketId };
}

async function supportSearchUser(data, context, db) {
  if (!(await _requireSupport("supportSearchUser", context, db))) {
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
  supportCreateTicket,
  supportGetTicket,
  supportSearchRide,
  supportSearchUser,
  supportListTickets,
  supportUpdateTicket,
};
