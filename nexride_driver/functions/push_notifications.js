const admin = require("firebase-admin");

function normUid(uid) {
  return String(uid ?? "").trim();
}

function text(v) {
  return String(v ?? "").trim();
}

function tokenKey(token) {
  return Buffer.from(token).toString("base64url");
}

async function registerDevicePushToken(data, context, db) {
  if (!context?.auth?.uid) {
    return { success: false, reason: "unauthorized" };
  }
  const uid = normUid(context.auth.uid);
  const token = text(data?.token);
  const platform = text(data?.platform).toLowerCase() || "unknown";
  const app = text(data?.app).toLowerCase() || "unknown";
  if (!token) {
    return { success: false, reason: "invalid_token" };
  }
  const now = Date.now();
  const key = tokenKey(token);
  await db.ref(`user_device_tokens/${uid}/${key}`).set({
    token,
    platform,
    app,
    updated_at: now,
    created_at: now,
  });
  await db.ref(`users/${uid}/push_meta`).update({
    last_token_platform: platform,
    last_token_app: app,
    last_token_updated_at: now,
  });
  return { success: true, reason: "registered" };
}

async function tokensForUser(db, uid) {
  const normalized = normUid(uid);
  if (!normalized) return [];
  const snap = await db.ref(`user_device_tokens/${normalized}`).get();
  const raw = snap.val();
  if (!raw || typeof raw !== "object") return [];
  const out = [];
  for (const value of Object.values(raw)) {
    const token = text(value?.token);
    if (token) out.push(token);
  }
  return Array.from(new Set(out));
}

async function sendPushToUser(db, uid, payload) {
  const tokens = await tokensForUser(db, uid);
  if (!tokens.length) {
    return { success: true, reason: "no_tokens", sent: 0 };
  }
  const message = {
    tokens,
    notification: payload.notification,
    data: payload.data || {},
    android: { priority: "high" },
    apns: {
      headers: { "apns-priority": "10" },
      payload: { aps: { sound: "default" } },
    },
  };
  const result = await admin.messaging().sendEachForMulticast(message);
  const invalid = [];
  result.responses.forEach((r, idx) => {
    if (!r.success) {
      const code = text(r.error?.code);
      if (
        code.includes("registration-token-not-registered") ||
        code.includes("invalid-registration-token")
      ) {
        invalid.push(tokens[idx]);
      }
    }
  });
  if (invalid.length) {
    const updates = {};
    for (const bad of invalid) {
      updates[`user_device_tokens/${normUid(uid)}/${tokenKey(bad)}`] = null;
    }
    await db.ref().update(updates);
  }
  return {
    success: true,
    reason: "sent",
    sent: result.successCount,
    failed: result.failureCount,
  };
}

module.exports = {
  registerDevicePushToken,
  sendPushToUser,
};
