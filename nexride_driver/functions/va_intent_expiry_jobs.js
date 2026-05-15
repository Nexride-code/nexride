/**
 * Marks overdue Flutterwave virtual-account intents as expired across Firestore +
 * RTDB so booking rows cannot sit in pending_transfer indefinitely.
 */

const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");
const { REGION } = require("./params");
const bankTransferVa = require("./bank_transfer_va");

exports.expireStaleVaPaymentIntents = onSchedule(
  {
    schedule: "every 15 minutes",
    timeZone: "Africa/Lagos",
    region: REGION,
  },
  async () => {
    const db = admin.database();
    const fs = admin.firestore();
    try {
      const r = await bankTransferVa.expireStaleBankTransferVaIntents(fs, db);
      console.log("VA_INTENT_EXPIRE_JOB", JSON.stringify(r));
    } catch (e) {
      console.log("VA_INTENT_EXPIRE_JOB_FAIL", String(e?.message || e));
    }
  },
);
