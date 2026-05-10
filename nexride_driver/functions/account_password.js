/**
 * account_password.js
 *
 * Self-service password lifecycle helpers for admin / support operators.
 *
 * Exposes `rotateAccountAfterPasswordChange` — a callable invoked by the
 * Flutter portal AFTER `updatePassword(...)` succeeds on the client. It:
 *
 *   1. Clears the `temporaryPassword` custom claim (if set), so subsequent
 *      ID-token refreshes no longer carry the forced-change flag.
 *   2. Revokes ALL existing refresh tokens for the user — every other
 *      device / browser session is invalidated immediately.
 *   3. Mirrors the cleared flag into RTDB `/account_security/{uid}` and
 *      stamps `passwordChangedAt = Date.now()` so the client and audit
 *      surfaces can read it without waiting for a token refresh.
 *   4. Writes an entry to `/admin_audit_logs` for traceability.
 *
 * Authorization: the callable acts ONLY on the caller's own UID. Anyone
 * authenticated can invoke it for themselves; nobody can rotate someone
 * else's claims through this entry point.
 *
 * Pairs with:
 *   - scripts/create_admin_user.js (which stamps temporaryPassword=true
 *     on initial provisioning).
 *   - nexride_driver/lib/portal_security/portal_password_service.dart
 *     (the Flutter caller).
 *   - database.rules.json /account_security rules.
 */

"use strict";

const admin = require("firebase-admin");

function nowMs() {
  return Date.now();
}

function normUid(uid) {
  return String(uid ?? "").trim();
}

/**
 * Strip a single key from a custom-claims object, returning a new object.
 * Returns null when the resulting claims map is structurally identical
 * to the input (no rewrite needed).
 */
function withoutClaim(claims, key) {
  if (!claims || typeof claims !== "object") return null;
  if (!(key in claims)) return null;
  const next = {};
  for (const k of Object.keys(claims)) {
    if (k === key) continue;
    next[k] = claims[k];
  }
  return next;
}

async function rotateAccountAfterPasswordChange(_data, context, db) {
  if (!context?.auth?.uid) {
    return { success: false, reason: "unauthorized" };
  }
  const uid = normUid(context.auth.uid);
  if (!uid) {
    return { success: false, reason: "unauthorized" };
  }

  let claimCleared = false;
  try {
    const user = await admin.auth().getUser(uid);
    const next = withoutClaim(user.customClaims, "temporaryPassword");
    if (next !== null) {
      await admin.auth().setCustomUserClaims(uid, next);
      claimCleared = true;
    }
  } catch (error) {
    // If we can't read the user, surface the error — something is wrong
    // and we don't want to silently mark the rotation as successful.
    return {
      success: false,
      reason: "claim_clear_failed",
      detail: String(error?.message ?? error),
    };
  }

  let refreshTokensRevoked = false;
  try {
    await admin.auth().revokeRefreshTokens(uid);
    refreshTokensRevoked = true;
  } catch (error) {
    return {
      success: false,
      reason: "revoke_failed",
      detail: String(error?.message ?? error),
    };
  }

  const ts = nowMs();
  try {
    await db.ref(`account_security/${uid}`).update({
      temporaryPassword: false,
      passwordChangedAt: ts,
      lastUpdatedAt: ts,
    });
  } catch (error) {
    // Mirror failure is non-fatal: claims+revoke already succeeded, so the
    // primary security guarantees hold. Surface the warning so the client
    // can log it.
    console.warn("[rotateAccountAfterPasswordChange] mirror failed", error);
  }

  try {
    await db.ref("admin_audit_logs").push().set({
      type: "password_rotated_self",
      target_uid: uid,
      actor_uid: uid,
      claim_cleared: claimCleared,
      refresh_tokens_revoked: refreshTokensRevoked,
      created_at: ts,
    });
  } catch (error) {
    console.warn("[rotateAccountAfterPasswordChange] audit log failed", error);
  }

  return {
    success: true,
    uid,
    claim_cleared: claimCleared,
    refresh_tokens_revoked: refreshTokensRevoked,
    password_changed_at: ts,
  };
}

module.exports = {
  rotateAccountAfterPasswordChange,
};
