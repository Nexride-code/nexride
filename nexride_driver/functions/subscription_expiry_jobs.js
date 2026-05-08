const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");
const { REGION } = require("./params");
const { sendPushToUser } = require("./push_notifications");

function nowMs() {
  return Date.now();
}

function normUid(uid) {
  return String(uid ?? "").trim();
}

async function expireActiveDriverSubscription(db, driverId, expiredAt) {
  const uid = normUid(driverId);
  if (!uid) {
    return;
  }
  const now = nowMs();
  const updates = {
    subscription_status: "expired",
    commission_exempt: false,
    commissionExempt: false,
    effectiveModel: "commission",
    subscription_renewal_reminder_sent: false,
    updated_at: now,
    "businessModel/subscription/status": "expired",
    "businessModel/commissionExempt": false,
    "businessModel/commission_exempt": false,
    "businessModel/effectiveModel": "commission",
  };
  await db.ref(`drivers/${uid}`).update(updates);
  await sendPushToUser(db, uid, {
    notification: {
      title: "Subscription expired",
      body:
        "Your NexRide subscription has expired. You are now on the commission model (10% per trip). Renew your subscription to keep 100% of earnings.",
    },
    data: {
      type: "subscription_expired",
      expired_at: String(expiredAt),
    },
  });
  console.log("SUBSCRIPTION_EXPIRED", `driverId=${uid}`, `expiredAt=${expiredAt}`);
}

exports.monitorSubscriptionExpiry = onSchedule(
  {
    schedule: "0 6 * * *",
    timeZone: "Africa/Lagos",
    region: REGION,
  },
  async (_event) => {
    const db = admin.database();
    const snap = await db.ref("drivers").get();
    const drivers = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
    const now = nowMs();
    const threeDaysMs = 3 * 24 * 60 * 60 * 1000;

    for (const [driverId, row] of Object.entries(drivers)) {
      if (!row || typeof row !== "object") {
        continue;
      }
      const status = String(row.subscription_status ?? "").trim().toLowerCase();
      if (status !== "active") {
        continue;
      }
      const exp = Number(row.subscription_expires_at ?? row.subscriptionExpiresAt ?? 0) || 0;
      if (exp <= 0) {
        continue;
      }

      if (now > exp) {
        await expireActiveDriverSubscription(db, driverId, exp);
        continue;
      }

      const reminderSent = row.subscription_renewal_reminder_sent === true;
      if (!reminderSent && exp > now && exp - now <= threeDaysMs) {
        const daysLeft = Math.max(
          1,
          Math.ceil((exp - now) / (24 * 60 * 60 * 1000)),
        );
        await db.ref(`drivers/${normUid(driverId)}`).update({
          subscription_renewal_reminder_sent: true,
          updated_at: now,
        });
        await sendPushToUser(db, driverId, {
          notification: {
            title: "Subscription expiring soon",
            body: `Your NexRide subscription expires in ${daysLeft} days. Renew now to keep 100% of your earnings.`,
          },
          data: {
            type: "subscription_renewal_reminder",
            expires_at: String(exp),
            days_left: String(daysLeft),
          },
        });
      }
    }
  },
);
