#!/usr/bin/env node
/**
 * Temporary operator grant script for NexRide role bootstrap/fix.
 *
 * Usage:
 *   node scripts/grant_roles.js
 *
 * This script uses Google OAuth from local gcloud auth and Admin REST APIs.
 */
const { execSync } = require("node:child_process");
const admin = require("firebase-admin");

const PROJECT_ID = "nexride-8d5bc";
const DATABASE_URL = "https://nexride-8d5bc-default-rtdb.firebaseio.com";

const ADMIN_EMAIL = "admin@nexride.africa";
const SUPPORT_EMAIL = "support@nexride.africa";

function nowMs() {
  return Date.now();
}

function oauthToken() {
  const fromEnv = String(process.env.GOOGLE_OAUTH_ACCESS_TOKEN || "").trim();
  if (fromEnv) return fromEnv;
  return execSync("gcloud auth print-access-token", { encoding: "utf8" }).trim();
}

async function apiPost(url, token, body) {
  const res = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
      "x-goog-user-project": PROJECT_ID,
    },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  let json = {};
  try {
    json = text ? JSON.parse(text) : {};
  } catch (_) {
    json = { raw: text };
  }
  if (!res.ok) {
    throw new Error(`${url} failed (${res.status}): ${JSON.stringify(json)}`);
  }
  return json;
}

async function rtdbPut(path, token, value) {
  const url = `${DATABASE_URL}/${path}.json`;
  const res = await fetch(url, {
    method: "PUT",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
      "x-goog-user-project": PROJECT_ID,
    },
    body: JSON.stringify(value),
  });
  const text = await res.text();
  if (!res.ok) {
    throw new Error(`RTDB PUT ${path} failed (${res.status}): ${text}`);
  }
}

async function rtdbGet(path, token) {
  const url = `${DATABASE_URL}/${path}.json`;
  const res = await fetch(url, {
    method: "GET",
    headers: {
      Authorization: `Bearer ${token}`,
      "x-goog-user-project": PROJECT_ID,
    },
  });
  const text = await res.text();
  if (!res.ok) {
    throw new Error(`RTDB GET ${path} failed (${res.status}): ${text}`);
  }
  return text ? JSON.parse(text) : null;
}

async function findUidByEmail(email, token) {
  const url = `https://identitytoolkit.googleapis.com/v1/projects/${PROJECT_ID}/accounts:lookup`;
  const out = await apiPost(url, token, { email: [email] });
  const users = Array.isArray(out.users) ? out.users : [];
  const uid = String(users[0]?.localId || "").trim();
  if (!uid) {
    throw new Error(`No Firebase Auth user found for email: ${email}`);
  }
  return uid;
}

async function setClaims(uid, claims, token) {
  const url = `https://identitytoolkit.googleapis.com/v1/projects/${PROJECT_ID}/accounts:update`;
  await apiPost(url, token, {
    localId: uid,
    customAttributes: JSON.stringify(claims),
  });
}

async function main() {
  const adcPath = String(
    process.env.GOOGLE_APPLICATION_CREDENTIALS ||
      `${process.env.HOME || ""}/.config/gcloud/application_default_credentials.json`,
  ).trim();
  if (!process.env.GOOGLE_APPLICATION_CREDENTIALS && adcPath) {
    process.env.GOOGLE_APPLICATION_CREDENTIALS = adcPath;
  }

  // Primary path (as requested): use firebase-admin getUserByEmail + RTDB writes.
  try {
    admin.initializeApp({
      projectId: PROJECT_ID,
      databaseURL: DATABASE_URL,
    });
    const db = admin.database();
    const adminUser = await admin.auth().getUserByEmail(ADMIN_EMAIL);
    const supportUser = await admin.auth().getUserByEmail(SUPPORT_EMAIL);
    const adminUid = String(adminUser.uid || "").trim();
    const supportUid = String(supportUser.uid || "").trim();
    if (!adminUid || !supportUid) {
      throw new Error("Failed to resolve target UIDs by email");
    }

    await db.ref(`admins/${adminUid}`).set(true);
    await db.ref(`support_staff/${supportUid}`).set({
      role: "support_agent",
      enabled: true,
      email: SUPPORT_EMAIL,
      updated_at: nowMs(),
    });
    await admin.auth().setCustomUserClaims(adminUid, { admin: true });
    await admin.auth().setCustomUserClaims(supportUid, {
      support: true,
      support_staff: true,
      role: "support_agent",
    });

    const [adminSnap, supportSnap, adminAfter, supportAfter] = await Promise.all([
      db.ref(`admins/${adminUid}`).get(),
      db.ref(`support_staff/${supportUid}`).get(),
      admin.auth().getUser(adminUid),
      admin.auth().getUser(supportUid),
    ]);

    console.log(
      JSON.stringify(
        {
          projectId: PROJECT_ID,
          mode: "firebase-admin",
          admin: {
            email: ADMIN_EMAIL,
            uid: adminUid,
            claimAdmin: adminAfter.customClaims?.admin === true,
            rtdbAdmin: adminSnap.val() === true,
          },
          support: {
            email: SUPPORT_EMAIL,
            uid: supportUid,
            claimSupport: supportAfter.customClaims?.support === true,
            claimSupportStaff: supportAfter.customClaims?.support_staff === true,
            claimRole: String(supportAfter.customClaims?.role ?? ""),
            rtdbSupport: supportSnap.exists() ? supportSnap.val() : null,
          },
        },
        null,
        2,
      ),
    );
    return;
  } catch (_error) {
    // Fallback path for machines where firebase-admin ADC cannot mint tokens.
    if (admin.apps.length > 0) {
      await admin.app().delete();
    }
  }

  // Fallback path: Google OAuth + Admin REST APIs.
  const token = oauthToken();
  const adminUid = await findUidByEmail(ADMIN_EMAIL, token);
  const supportUid = await findUidByEmail(SUPPORT_EMAIL, token);
  if (!adminUid || !supportUid) {
    throw new Error("Failed to resolve target UIDs by email");
  }

  await rtdbPut(`admins/${adminUid}`, token, true);
  await rtdbPut(`support_staff/${supportUid}`, token, {
    role: "support_agent",
    enabled: true,
    email: SUPPORT_EMAIL,
    updated_at: nowMs(),
  });

  await setClaims(adminUid, { admin: true }, token);
  await setClaims(supportUid, {
    support: true,
    support_staff: true,
    role: "support_agent",
  }, token);

  const [adminSnap, supportSnap, adminAfter, supportAfter] = await Promise.all([
    rtdbGet(`admins/${adminUid}`, token),
    rtdbGet(`support_staff/${supportUid}`, token),
    apiPost(`https://identitytoolkit.googleapis.com/v1/projects/${PROJECT_ID}/accounts:lookup`, token, {
      localId: [adminUid],
    }),
    apiPost(`https://identitytoolkit.googleapis.com/v1/projects/${PROJECT_ID}/accounts:lookup`, token, {
      localId: [supportUid],
    }),
  ]);
  const adminClaims = JSON.parse(adminAfter.users?.[0]?.customAttributes || "{}");
  const supportClaims = JSON.parse(supportAfter.users?.[0]?.customAttributes || "{}");

  const summary = {
    projectId: PROJECT_ID,
    admin: {
      email: ADMIN_EMAIL,
      uid: adminUid,
      claimAdmin: adminClaims.admin === true,
      rtdbAdmin: adminSnap === true,
    },
    support: {
      email: SUPPORT_EMAIL,
      uid: supportUid,
      claimSupport: supportClaims.support === true,
      claimSupportStaff: supportClaims.support_staff === true,
      claimRole: String(supportClaims.role ?? ""),
      rtdbSupport: supportSnap,
    },
  };

  console.log(JSON.stringify(summary, null, 2));
}

main().catch((error) => {
  console.error("[grant_roles] failed:", error?.message || error);
  process.exit(1);
});

