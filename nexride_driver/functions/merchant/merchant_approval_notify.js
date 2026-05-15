const { logger } = require("firebase-functions");
const { sendPushToUser } = require("../push_notifications");

function trim(v) {
  return String(v ?? "").trim();
}

/**
 * Notify merchant owner after admin approval (push always attempted; email optional via Resend).
 * @param {import("firebase-admin/database").Database} db
 * @param {{ ownerUid?: string, contactEmail?: string, businessName?: string }} params
 */
async function notifyMerchantApproval(db, params) {
  const uid = trim(params?.ownerUid);
  const biz =
    trim(params?.businessName).length > 0 ? trim(params.businessName) : "Your business";
  const body = `${biz} is approved on NexRide. Open the app to continue.`;

  if (uid) {
    try {
      await sendPushToUser(db, uid, {
        notification: { title: "Merchant approved", body },
        data: {
          type: "merchant_approved",
          merchant_status: "approved",
        },
      });
    } catch (e) {
      logger.warn("MERCHANT_APPROVAL_PUSH_FAILED", { uid, err: String(e) });
    }
  }

  const to = trim(params?.contactEmail);
  const apiKey = trim(process.env.RESEND_API_KEY);
  const from = trim(process.env.RESEND_FROM_EMAIL);
  if (!apiKey || !from || !to) {
    return { push_attempted: Boolean(uid), email_sent: false };
  }

  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from,
        to: [to],
        subject: `NexRide: ${biz} is approved`,
        text:
          `Your merchant application for "${biz}" has been approved.\n\n` +
          `Sign in to the NexRide merchant app to complete any remaining steps.\n\n` +
          `— NexRide`,
      }),
    });
    if (!res.ok) {
      const t = await res.text();
      logger.warn("MERCHANT_APPROVAL_EMAIL_FAILED", {
        status: res.status,
        body: String(t).slice(0, 500),
      });
      return { push_attempted: Boolean(uid), email_sent: false };
    }
    return { push_attempted: Boolean(uid), email_sent: true };
  } catch (e) {
    logger.warn("MERCHANT_APPROVAL_EMAIL_ERR", { err: String(e) });
    return { push_attempted: Boolean(uid), email_sent: false };
  }
}

module.exports = { notifyMerchantApproval };
