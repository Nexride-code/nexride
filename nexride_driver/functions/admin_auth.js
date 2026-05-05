/**
 * Admin / support authorization (custom claims and/or RTDB flags).
 * RTDB: `admins/{uid} === true` and `support_staff/{uid} === true` (Functions-only writes).
 */

function normUid(uid) {
  return String(uid ?? "").trim();
}

async function isNexRideAdmin(db, context) {
  if (!context?.auth?.uid) return false;
  if (context.auth.token?.admin === true) return true;
  const uid = normUid(context.auth.uid);
  if (!uid) return false;
  const snap = await db.ref(`admins/${uid}`).get();
  return snap.val() === true;
}

async function isNexRideSupportStaff(db, context) {
  if (!context?.auth?.uid) return false;
  const tokenRole = String(context.auth.token?.role ?? "").trim().toLowerCase();
  if (
    context.auth.token?.support === true ||
    context.auth.token?.support_staff === true ||
    tokenRole === "support_agent" ||
    tokenRole === "support_manager"
  ) {
    return true;
  }
  const uid = normUid(context.auth.uid);
  if (!uid) return false;
  const snap = await db.ref(`support_staff/${uid}`).get();
  const v = snap.val();
  if (v === true) return true;
  if (v && typeof v === "object") {
    const role = String(v.role ?? "").trim().toLowerCase();
    const disabled = v.disabled === true || v.enabled === false;
    if (!disabled && (role === "support_agent" || role === "support_manager")) {
      return true;
    }
  }
  return false;
}

/** Admin full access, or support (narrower callables enforce field-level safety). */
async function isNexRideAdminOrSupport(db, context) {
  if (await isNexRideAdmin(db, context)) return true;
  return isNexRideSupportStaff(db, context);
}

module.exports = {
  normUid,
  isAdmin: isNexRideAdmin,
  isNexRideAdmin,
  isNexRideSupportStaff,
  isNexRideAdminOrSupport,
};
