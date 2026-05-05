const admin = require("firebase-admin");
const { isNexRideAdmin, normUid } = require("./admin_auth");

const SUPPORT_ROLES = new Set(["support_agent", "support_manager"]);

function nowMs() {
  return Date.now();
}

async function mergeUserClaims(uid, patch) {
  const user = await admin.auth().getUser(uid);
  const base = (user.customClaims && typeof user.customClaims === "object")
    ? user.customClaims
    : {};
  const merged = { ...base, ...patch };
  await admin.auth().setCustomUserClaims(uid, merged);
  return merged;
}

/**
 * Admin-only: assign admin/support roles and claims.
 * Input: { uid, role } where role in ["admin", "support_agent", "support_manager"].
 */
async function setUserRole(data, context, db) {
  if (!context?.auth?.uid) {
    return { success: false, reason: "unauthorized" };
  }
  if (!(await isNexRideAdmin(db, context))) {
    return { success: false, reason: "forbidden" };
  }
  const callerUid = normUid(context.auth.uid);
  const targetUid = normUid(data?.uid);
  const role = String(data?.role ?? "").trim().toLowerCase();
  if (!targetUid || !role) {
    return { success: false, reason: "invalid_input" };
  }
  if (role !== "admin" && !SUPPORT_ROLES.has(role)) {
    return { success: false, reason: "invalid_role" };
  }

  const ts = nowMs();
  if (role === "admin") {
    await db.ref(`admins/${targetUid}`).set(true);
    await mergeUserClaims(targetUid, { admin: true });
    await db.ref("admin_audit_logs").push().set({
      type: "set_user_role",
      role: "admin",
      target_uid: targetUid,
      actor_uid: callerUid,
      created_at: ts,
    });
    return { success: true, uid: targetUid, role: "admin" };
  }

  await db.ref(`support_staff/${targetUid}`).set({
    role,
    enabled: true,
    disabled: false,
    updated_at: ts,
    updated_by: callerUid,
  });
  await mergeUserClaims(targetUid, {
    support: true,
    support_staff: true,
    role,
  });
  await db.ref("admin_audit_logs").push().set({
    type: "set_user_role",
    role,
    target_uid: targetUid,
    actor_uid: callerUid,
    created_at: ts,
  });
  return { success: true, uid: targetUid, role };
}

/**
 * One-time bootstrap: first authenticated user can become admin if admins node is empty.
 * After any admin exists, this callable is permanently blocked.
 */
async function bootstrapFirstAdmin(_data, context, db) {
  if (!context?.auth?.uid) {
    return { success: false, reason: "unauthorized" };
  }
  const uid = normUid(context.auth.uid);
  if (!uid) {
    return { success: false, reason: "unauthorized" };
  }

  const adminsSnap = await db.ref("admins").limitToFirst(1).get();
  if (adminsSnap.exists()) {
    return { success: false, reason: "already_bootstrapped" };
  }

  await db.ref(`admins/${uid}`).set(true);
  await mergeUserClaims(uid, { admin: true });
  await db.ref("admin_audit_logs").push().set({
    type: "bootstrap_first_admin",
    target_uid: uid,
    actor_uid: uid,
    created_at: nowMs(),
  });
  return { success: true, uid, role: "admin", bootstrap: true };
}

module.exports = {
  setUserRole,
  bootstrapFirstAdmin,
};
