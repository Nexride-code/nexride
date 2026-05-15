/**
 * Admin / support authorization (custom claims and/or RTDB flags).
 * RTDB: `admins/{uid} === true` and `support_staff/{uid} === true` (Functions-only writes).
 */

function normUid(uid) {
  return String(uid ?? "").trim();
}

/**
 * RTDB `admins/{uid}` may be `true` (legacy) or an object with role metadata.
 * @param {unknown} val
 */
function adminsEntryAllowsPortal(val) {
  if (val === true) return true;
  if (!val || typeof val !== "object") return false;
  if (val.enabled === false || val.disabled === true) return false;
  return val.admin === true || val.enabled === true || val.admin_role != null || val.role != null;
}

async function isNexRideAdmin(db, context) {
  if (!context?.auth?.uid) return false;
  if (context.auth.token?.admin === true) return true;
  const tokenRole = String(context.auth.token?.role ?? "")
    .trim()
    .toLowerCase();
  if (tokenRole === "admin") return true;
  const uid = normUid(context.auth.uid);
  if (!uid) return false;
  const snap = await db.ref(`admins/${uid}`).get();
  return adminsEntryAllowsPortal(snap.val());
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
  adminsEntryAllowsPortal,
  isAdmin: isNexRideAdmin,
  isNexRideAdmin,
  isNexRideSupportStaff,
  isNexRideAdminOrSupport,
};
