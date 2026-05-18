const { logger } = require("firebase-functions");
const { ServerValue } = require("firebase-admin/database");
const { sendPushToUser } = require("./push_notifications");

function normUid(v) {
  const s = String(v ?? "").trim();
  return s && s !== "waiting" && s !== "null" ? s : "";
}

function roleLabel(role) {
  const r = String(role ?? "").trim().toLowerCase();
  if (r === "customer") return "Customer";
  if (r === "driver") return "Driver";
  if (r === "merchant") return "Merchant";
  if (r === "support" || r === "admin") return "Support";
  return "Someone";
}

/**
 * RTDB onCreate: delivery_chats/{deliveryId}/messages/{messageId}
 * Increments unread for other participants and sends push.
 */
async function onDeliveryChatMessageCreated(event, db) {
  const deliveryId = String(event.params?.deliveryId ?? "").trim();
  const messageId = String(event.params?.messageId ?? "").trim();
  const msg = event.data.val();
  if (!deliveryId || !messageId || !msg || typeof msg !== "object") {
    return null;
  }
  const senderId = normUid(msg.sender_id ?? msg.senderId);
  const senderRole = String(msg.sender_role ?? msg.senderRole ?? "").trim().toLowerCase();
  const preview = String(msg.text ?? "").trim().slice(0, 120) || "New message";
  const now = Date.now();

  let deliveryRow = {};
  try {
    const snap = await db.ref(`delivery_requests/${deliveryId}`).get();
    if (snap.exists()) {
      deliveryRow = snap.val() || {};
    }
  } catch (e) {
    logger.warn("delivery_chat_push_delivery_load_failed", {
      deliveryId,
      err: String(e?.message || e),
    });
  }

  const customerId = normUid(deliveryRow.customer_id);
  const driverId = normUid(
    deliveryRow.matched_driver_id ??
      deliveryRow.accepted_driver_id ??
      deliveryRow.driver_id,
  );
  const merchantId = normUid(deliveryRow.merchant_id ?? deliveryRow.merchantId);

  const recipients = [
    { uid: customerId, role: "customer" },
    { uid: driverId, role: "driver" },
    { uid: merchantId, role: "merchant" },
  ].filter((r) => r.uid && r.uid !== senderId);

  const updates = {};
  for (const r of recipients) {
    updates[`delivery_chats/${deliveryId}/unread/${r.uid}/count`] =
      ServerValue.increment(1);
  }
  updates[`delivery_chats/${deliveryId}/meta/last_message`] = preview;
  updates[`delivery_chats/${deliveryId}/meta/last_message_at`] = now;
  updates[`delivery_chats/${deliveryId}/meta/updated_at`] = now;

  try {
    if (Object.keys(updates).length > 0) {
      await db.ref().update(updates);
    }
  } catch (e) {
    logger.warn("delivery_chat_unread_update_failed", {
      deliveryId,
      err: String(e?.message || e),
    });
  }

  const notification = {
    title: `${roleLabel(senderRole)} message`,
    body: preview,
  };
  const data = {
    type: "delivery_chat_message",
    delivery_id: deliveryId,
    message_id: messageId,
  };

  for (const r of recipients) {
    try {
      await sendPushToUser(db, r.uid, { notification, data });
    } catch (e) {
      logger.warn("delivery_chat_push_failed", {
        deliveryId,
        recipient: r.uid,
        err: String(e?.message || e),
      });
    }
  }
  return null;
}

async function notifyDeliveryChatMessage(data, context, db) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const deliveryId = String(data?.deliveryId ?? data?.delivery_id ?? "").trim();
  const messageId = String(data?.messageId ?? data?.message_id ?? "").trim();
  if (!deliveryId || !messageId) {
    return { success: false, reason: "invalid_input" };
  }
  const snap = await db.ref(`delivery_chats/${deliveryId}/messages/${messageId}`).get();
  if (!snap.exists()) {
    return { success: false, reason: "message_missing" };
  }
  const senderId = normUid(snap.val()?.sender_id ?? snap.val()?.senderId);
  if (senderId !== normUid(context.auth.uid)) {
    return { success: false, reason: "forbidden" };
  }
  await onDeliveryChatMessageCreated(
    {
      params: { deliveryId, messageId },
      data: { val: () => snap.val() },
    },
    db,
  );
  return { success: true };
}

module.exports = {
  onDeliveryChatMessageCreated,
  notifyDeliveryChatMessage,
};
