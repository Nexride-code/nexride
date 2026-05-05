const { sendPushToUser } = require("./push_notifications");

function normUid(uid) {
  return String(uid ?? "").trim();
}

function text(v) {
  return String(v ?? "").trim();
}

async function findSupportUserIds(db) {
  const [adminsSnap, supportSnap] = await Promise.all([
    db.ref("admins").get(),
    db.ref("support_staff").get(),
  ]);
  const ids = new Set();
  const admins = adminsSnap.val();
  if (admins && typeof admins === "object") {
    for (const [uid, isAdmin] of Object.entries(admins)) {
      if (isAdmin === true) ids.add(normUid(uid));
    }
  }
  const support = supportSnap.val();
  if (support && typeof support === "object") {
    for (const [uid, row] of Object.entries(support)) {
      const role = text(row?.role).toLowerCase();
      const enabled = row?.enabled !== false && row?.disabled !== true;
      if (
        enabled &&
        (role === "support_agent" || role === "support_manager")
      ) {
        ids.add(normUid(uid));
      }
    }
  }
  return Array.from(ids).filter(Boolean);
}

async function escalateSafetyIncident(data, context, db) {
  if (!context?.auth?.uid) {
    return { success: false, reason: "unauthorized" };
  }
  const actorUid = normUid(context.auth.uid);
  const rideId = text(data?.rideId || data?.ride_id);
  const driverId = text(data?.driverId || data?.driver_id);
  const riderId = text(data?.riderId || data?.rider_id);
  const serviceType = text(data?.serviceType || data?.service_type || "ride");
  const flagType = text(data?.flagType || data?.flag_type || "sos");
  const details = text(data?.details || "Emergency assistance requested");
  const severity = "critical";
  const now = Date.now();
  const sourceFlagId = text(data?.sourceFlagId || data?.source_flag_id);

  const dedupeKey = `${rideId || "no_ride"}:${actorUid}:${flagType}`;
  const dedupeRef = db.ref(`sos_escalations/${dedupeKey}`);
  const lock = await dedupeRef.transaction((cur) => {
    if (cur && typeof cur === "object" && now - Number(cur.created_at || 0) < 120000) {
      return;
    }
    return {
      created_at: now,
      actor_uid: actorUid,
      ride_id: rideId || null,
      source_flag_id: sourceFlagId || null,
    };
  });
  if (!lock.committed) {
    return { success: true, reason: "deduped_recent_sos" };
  }

  const ticketRef = db.ref("support_tickets").push();
  const ticketId = normUid(ticketRef.key);
  await ticketRef.set({
    createdByUserId: actorUid,
    subject: `SOS emergency • ${serviceType || "trip"}`,
    status: "open",
    priority: "urgent",
    escalated: true,
    category: "safety_emergency",
    sourceType: "sos",
    ride_id: rideId || null,
    driver_id: driverId || null,
    rider_id: riderId || null,
    createdAt: now,
    created_at: now,
    updatedAt: now,
    updated_at: now,
    last_message: details.slice(0, 500),
    last_message_at: now,
    tripSnapshot: {
      rideId: rideId || null,
      driverId: driverId || null,
      riderId: riderId || null,
      serviceType,
      flagType,
      severity,
      sourceFlagId: sourceFlagId || null,
    },
    tags: ["sos", "safety", "urgent"],
  });

  const msgKey = db.ref("support_ticket_messages").push().key;
  if (msgKey) {
    await db.ref(`support_ticket_messages/${msgKey}`).set({
      ticketId,
      body: details,
      authorUid: actorUid,
      createdAt: now,
      role: "user",
      sourceType: "sos",
    });
  }

  await db.ref("support_logs").push().set({
    type: "sos_escalation",
    ticketId,
    actor_uid: actorUid,
    ride_id: rideId || null,
    driver_id: driverId || null,
    rider_id: riderId || null,
    flagType,
    severity,
    created_at: now,
  });

  const supportIds = await findSupportUserIds(db);
  const participantIds = new Set(supportIds);
  if (riderId) participantIds.add(riderId);
  if (driverId) participantIds.add(driverId);
  participantIds.delete(actorUid);
  await Promise.all(
    Array.from(participantIds).map((uid) =>
      sendPushToUser(db, uid, {
        notification: {
          title: "SOS emergency alert",
          body: `New urgent safety incident (${serviceType})`,
        },
        data: {
          type: "sos_emergency",
          ticketId,
          rideId,
          actorUid,
          severity,
        },
      }),
    ),
  );

  return { success: true, reason: "sos_escalated", ticketId };
}

module.exports = {
  escalateSafetyIncident,
};
