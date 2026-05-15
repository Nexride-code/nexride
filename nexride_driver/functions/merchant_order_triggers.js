/**
 * Firestore triggers for merchant_orders — push + public teaser (riders read RTDB).
 */
const admin = require("firebase-admin");
const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { logger } = require("firebase-functions");
const { normUid } = require("./admin_auth");
const pushNotifications = require("./push_notifications");
const { syncMerchantPublicTeaserFromMerchantId } = require("./merchant_public_sync");
const { REGION } = require("./params");

exports.onMerchantOrderCreatedNotify = onDocumentCreated(
  { document: "merchant_orders/{orderId}", region: REGION },
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const orderId = event.params.orderId;
    const data = snap.data() || {};
    const merchantId = String(data.merchant_id ?? "").trim();
    if (!merchantId) return;
    const db = admin.database();
    const fs = admin.firestore();
    try {
      const mSnap = await fs.collection("merchants").doc(merchantId).get();
      const m = mSnap.exists ? mSnap.data() || {} : {};
      const ownerUid = normUid(m.owner_uid ?? m.ownerUid);
      const staffUids = Array.isArray(m.staff_uids) ? m.staff_uids : [];
      const title = "New NexRide order";
      const body = `Order ${orderId.slice(0, 8)}… — open the merchant app to accept.`;
      const payload = {
        notification: { title, body },
        data: {
          type: "merchant_new_order",
          order_id: orderId,
          merchant_id: merchantId,
        },
      };
      if (ownerUid) {
        await pushNotifications.sendPushToUser(db, ownerUid, payload);
      }
      for (const suid of staffUids) {
        const u = normUid(suid);
        if (u && u !== ownerUid) {
          await pushNotifications.sendPushToUser(db, u, payload);
        }
      }
      await syncMerchantPublicTeaserFromMerchantId(db, merchantId, {
        last_order_id: orderId,
        last_order_status: String(data.order_status ?? ""),
        last_order_at_ms: Date.now(),
      });
    } catch (e) {
      logger.warn("onMerchantOrderCreatedNotify failed", {
        err: String(e?.message || e),
        merchantId,
        orderId,
      });
    }
  },
);
