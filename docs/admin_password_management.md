# Admin & Support Password Management

This document is the runbook for **everything related to operator passwords** at NexRide:

- The user-facing password-reset flow (Forgot password)
- The user-facing password-change flow (Change password)
- The forced password-rotation flow on first sign-in
- The Account Security overview page
- Brute-force / rate-limit protection
- The MFA roadmap

It is the companion to [`docs/admin_access.md`](./admin_access.md), which covers how to **provision** new admin/support accounts in the first place. Read that doc first if you're standing up a new operator from scratch.

For the **authorization layer** (how the portal decides whether a signed-in user is allowed in, and how to debug "signed in but no access" errors), see [`docs/admin_role_propagation.md`](./admin_role_propagation.md).

---

## High-level architecture

```
                ┌─────────────────────────────┐
                │  scripts/create_admin_user  │  Admin SDK (server side)
                │   (provision a new user)    │  • merges role claims
                └────────────┬────────────────┘  • sets temporaryPassword=true
                             │                    on the claim AND in RTDB
                             ▼
   ┌──────────────────────────────────────────────────────────┐
   │  /account_security/{uid}   ←   single source of truth     │
   │  { temporaryPassword, passwordChangedAt, ... }            │
   └──────────────┬───────────────────────────────────────────┘
                  │ read by
                  ▼
   ┌──────────────────────────────────────────────────────────┐
   │   AdminAuthService / SupportAuthService                  │
   │   `session.mustChangePassword`                           │
   └──────────────┬───────────────────────────────────────────┘
                  │ consulted by
                  ▼
   ┌──────────────────────────────────────────────────────────┐
   │   AdminGateScreen / SupportGateScreen                    │
   │   force-redirect → /admin/account/change-password        │
   │                  → /support/account/change-password      │
   └──────────────┬───────────────────────────────────────────┘
                  │ on successful rotation
                  ▼
   ┌──────────────────────────────────────────────────────────┐
   │ Cloud Function: rotateAccountAfterPasswordChange         │
   │  1. clear `temporaryPassword` custom claim               │
   │  2. revokeRefreshTokens(uid)  ← signs out other sessions │
   │  3. RTDB /account_security/{uid}.temporaryPassword=false │
   │  4. write /admin_audit_logs entry                        │
   └──────────────────────────────────────────────────────────┘
```

The `temporaryPassword` flag lives in **two** places by design:

| Source | Set by | Cleared by | Why |
| --- | --- | --- | --- |
| Custom claim `temporaryPassword: true` | `scripts/create_admin_user.js` (Admin SDK) | `rotateAccountAfterPasswordChange` Cloud Function | Travels with every ID token request — even server-side checks see the flag without an extra DB read. |
| RTDB `/account_security/{uid}.temporaryPassword: true` | Same script (Admin SDK bypasses rules) | Same Cloud Function | Read by the Flutter clients without forcing an ID-token refresh, and a clear audit anchor (`passwordChangedAt`). |

Either one being `true` causes the gate screens to force-redirect.

---

## 1. Forgot Password (Reset)

**Where:** `/admin/login` and `/support/login` — the "Forgot password?" link below the sign-in button.

**Flow:**

1. Operator opens `https://nexride.africa/admin` (or `/support`) and clicks **Forgot password?**
2. The dialog prefills the email currently in the sign-in form.
3. On submit, the client calls `FirebaseAuth.instance.sendPasswordResetEmail(email)`.
4. The dialog **always** shows the same generic success message:
   > If an account exists for `<email>`, we've sent a password-reset link. Check your inbox (and spam) — links expire in about an hour.

   This is intentional: never reveal whether `<email>` is registered. That would let an attacker enumerate which addresses are admins.
5. The operator opens the link in their email, sets a new password, and signs in normally.

**Rate limit:** `PortalRateLimiter` allows **3 reset emails per email address per 30 minutes** in the local browser session. Firebase Auth itself enforces a separate per-IP and per-account throttle — this is just a UX guard.

**Code map:**
- `nexride_driver/lib/portal_security/portal_forgot_password_dialog.dart` (the dialog widget)
- `nexride_driver/lib/portal_security/portal_password_service.dart#sendPasswordReset`
- `nexride_driver/lib/portal_security/portal_password_logic.dart` (rate limiter)

---

## 2. Change Password

**Where:**
- Direct URL: `https://nexride.africa/admin/account/change-password` (admins) or `https://nexride.africa/support/account/change-password` (support)
- Linked from the Account Security page (see §3)

**Required fields:**
- Current password
- New password (≥ 12 chars, must contain a letter and a digit, must not contain the email handle)
- Confirm new password

**Flow:**

1. Validate locally (complexity, match, must differ from current).
2. Check `PortalRateLimiter` — at most **5 attempts per uid per 15 minutes**. After 5 failed attempts, the form is locked out for the remainder of the window.
3. `EmailAuthProvider.credential(email, currentPassword)` → `user.reauthenticateWithCredential(...)` — proves possession of the existing password.
4. `user.updatePassword(newPassword)` — Firebase rotates the credential server-side.
5. Call the **`rotateAccountAfterPasswordChange`** Cloud Function (`nexride_driver/functions/account_password.js`) which:
   - Strips `temporaryPassword` from the custom claims (via `setCustomUserClaims`)
   - Calls `admin.auth().revokeRefreshTokens(uid)` — invalidates **every** refresh token issued before this moment
   - Updates `/account_security/{uid}` with `temporaryPassword: false, passwordChangedAt: Date.now()`
   - Writes a `password_rotated_self` entry to `/admin_audit_logs`
6. **Force sign-out** locally — the calling session's refresh token was just revoked, so the next refresh will fail anyway. We sign out cleanly and bounce the operator back to the login screen with a confirmation message: *"Password updated. Sign in again with your new password to continue."*

After step 6, every other browser, tab, and device that was signed into this account is forced to re-authenticate the next time they hit a protected route.

**Code map:**
- `nexride_driver/lib/portal_security/portal_change_password_screen.dart`
- `nexride_driver/lib/portal_security/portal_password_service.dart#changePassword`
- `nexride_driver/functions/account_password.js`
- `nexride_driver/functions/index.js` (callable registration)

---

## 3. Account Security page

**Where:** `https://nexride.africa/admin/account/security` and `https://nexride.africa/support/account/security`.

Read-only summary of:

- Email + UID
- Last sign-in time (Firebase Auth `User.metadata.lastSignInTime`)
- Account created (Firebase Auth `User.metadata.creationTime`)
- Password last changed (RTDB `account_security/{uid}.passwordChangedAt`)
- MFA status placeholder (currently always "Not enrolled — coming soon" until we ship the rollout — see §6)
- Active claims, filtered to a safe set: `admin`, `super_admin`, `support`, `support_staff`, `role`, `supportRole`, `temporaryPassword`

Action buttons: **Change password**, **Refresh**, **Sign out**.

If the account is currently flagged with `temporaryPassword=true`, a yellow banner appears at the top of the page urging the operator to rotate.

**Code map:** `nexride_driver/lib/portal_security/portal_account_security_screen.dart`

---

## 4. Forced password-change flow

When the gate (`AdminGateScreen` or `SupportGateScreen`) resolves a session, it asks `PortalPasswordService.readMustChangePassword(user)` which returns `true` if **either** source is set:

- `idToken.claims.temporaryPassword === true`, OR
- RTDB `account_security/{uid}.temporaryPassword === true`

If `mustChangePassword` is true, the gate skips rendering the dashboard and force-redirects (via `Navigator.pushReplacementNamed`) to:

- `/admin/account/change-password`, or
- `/support/account/change-password`

The change-password screen receives `forced: true`, which:
- Hides the back button on the AppBar (no escape hatch to other routes)
- Renders a banner explaining why the rotation is required
- Otherwise behaves identically to the opportunistic flow

After a successful rotation, the screen forces a sign-out and bounces back to the login page with a friendly message — the operator types their new password, sees a clean session (no claim, no banner), and lands on the dashboard.

**Code map:**
- `nexride_driver/lib/admin/services/admin_auth_service.dart` (computes `mustChangePassword` in `_sessionForUser`)
- `nexride_driver/lib/support_portal/services/support_auth_service.dart` (same)
- `nexride_driver/lib/admin/screens/admin_gate_screen.dart` (force-redirect)
- `nexride_driver/lib/support_portal/screens/support_gate_screen.dart` (force-redirect)

---

## 5. Provisioning new operators with a temporary password

Use the existing script — it now stamps the temporary-password flag automatically when it creates a fresh user:

```bash
node scripts/create_admin_user.js \
    --admin-email   admin@nexride.africa \
    --support-email support@nexride.africa
```

What the script does for a NEWLY CREATED user:

1. `admin.auth().createUser({ email, password: <strong random 32 chars> })`
2. Merge the role claims (`admin: true, role: "admin"` or `support: true, support_staff: true, role: "support_agent"`)
3. **Stamp the temporary-password flag**:
   - Adds `temporaryPassword: true` to the custom claims
   - Writes `account_security/{uid} = { temporaryPassword: true, email, role, reason: "initial_provisioning", createdAt, lastUpdatedAt }`
4. Mirror role state into RTDB (`/admins/{uid}` or `/support_staff/{uid}`) and Firestore (`support_staff/{uid}`)
5. Write `provision_admin_via_script` / `provision_support_via_script` audit entry
6. Print the generated password ONCE to stdout

**Important:** the script does **not** re-stamp the flag on existing users — once you've rotated, you've rotated.

To clear the flag manually (rare; only if a script run misfired):

```bash
firebase --project nexride-8d5bc database:remove "/account_security/<uid>"
```

…and then either ask the operator to sign in once (their next ID-token refresh will pick up cleared claims if you used the `setCustomUserClaims` route), or use the existing `setUserRole` callable to re-merge claims without `temporaryPassword`.

---

## 6. Brute-force protection (depth in layers)

| Layer | What it does | Status |
| --- | --- | --- |
| **Client-side rate limit** (`PortalRateLimiter`) | 5 password-change attempts / 15 min per uid; 3 reset emails / 30 min per email | Shipped (this PR) |
| **Firebase Auth per-account throttle** | After ~5 failed sign-ins from one device, exponential back-off; blocks for hours after sustained abuse | Built-in (no config) |
| **Firebase Auth per-IP throttle** | Aggregates across accounts from one IP and starts dropping requests | Built-in (no config) |
| **Cloud Function `revokeRefreshTokens`** | After a successful rotation, every existing session is forced to re-auth | Shipped (this PR) |
| **Generic forgot-password response** | UI never reveals which addresses are registered | Shipped (this PR) |
| **Cloudflare in front of `nexride.africa`** | Optional: WAF rules + bot management on `/admin/*` and `/support/*` | **Recommended** — see *Optional hardening* below |
| **reCAPTCHA Enterprise on the sign-in form** | Optional: invisible challenge before invoking Firebase Auth | **Recommended** — see *Optional hardening* below |
| **Firebase App Check** | Optional: only Flutter web bundles served from `nexride.africa` can call the rotate Cloud Function | **Recommended** for v2 |
| **Audit log alerting** | Optional: notify Slack when more than N `password_rotated_self` events fire in a short window | **Recommended** for v2 |

### Optional hardening

#### Cloudflare

If you front `nexride.africa` with Cloudflare:

1. Enable **Bot Fight Mode** for `/admin/*` and `/support/*` (Security → Bots).
2. Add a **rate-limit rule**: `(http.request.uri.path matches "^/(admin|support)/login")` → 10 requests per IP per 5 min, action: managed challenge.
3. Add a **WAF rule** to block requests with no `User-Agent` or with known credential-stuffing patterns to `/admin/*` and `/support/*`.

#### reCAPTCHA Enterprise

Firebase Auth supports reCAPTCHA Enterprise for `signInWithPassword` and `sendPasswordResetEmail`. Enable it in the Firebase console (Authentication → Settings → reCAPTCHA Enterprise) — no client code changes required. Add a `firebase-functions/v2/scheduler` task to alert if challenge fail-rate exceeds 5% in any 15-min window.

#### App Check

`rotateAccountAfterPasswordChange` is currently authorized via `request.auth` only (any signed-in user can rotate their own password). To also restrict the callable to the official admin/support web bundles, enable Firebase App Check (reCAPTCHA Enterprise provider for web) and gate the callable with `consumeAppCheckToken: true` in `onCall` options.

---

## 7. MFA roadmap

The Account Security page already shows `MFA: Not enrolled — coming soon`. Rolling out MFA in the future requires:

1. **Enable Multi-factor authentication** in Firebase Console (Authentication → Sign-in method → Multi-factor authentication).
2. **Enroll a phone factor** (`PhoneMultiFactorGenerator.assertionForEnrollment(...)`) on a new "Add MFA" button on the Account Security page.
3. **Require MFA at sign-in for accounts that have it enrolled** — `signInWithEmailAndPassword` will throw `auth/multi-factor-auth-required`; resolve via `error.resolver.resolveSignIn(...)`.
4. **Optionally enforce MFA** for the `admin` role (refuse to render the dashboard until `multiFactor.getEnrolledFactors().isNotEmpty`). Implementation hint: extend `AdminSession.mustEnrollMfa` and gate redirects similarly to `mustChangePassword`.
5. **Hardware key support (TOTP/passkeys)** — Firebase has WebAuthn in beta as of late 2025. Plan to migrate `admin@nexride.africa` to a passkey-only flow once GA.

Until MFA ships, the controls in §6 — long random temporary passwords, forced rotation on first sign-in, server-side `revokeRefreshTokens` after every rotation, and Firebase Auth's built-in throttling — are the layered defense.

---

## 8. Verification checklist

Before removing the legacy `nexrideinfo@gmail.com` admin entry, walk through this end-to-end:

- [ ] `flutter analyze nexride_driver/lib/portal_security nexride_driver/lib/admin nexride_driver/lib/support_portal` is clean for the new files.
- [ ] `node --check nexride_driver/functions/account_password.js` is clean.
- [ ] `firebase deploy --only functions:rotateAccountAfterPasswordChange,database` from `nexride_driver/functions/` succeeds.
- [ ] Sign in to `/admin` as `admin@nexride.africa` with the temporary password generated by the script. Confirm you are redirected to `/admin/account/change-password` automatically.
- [ ] Rotate the password. Confirm you are signed out and the login screen shows the green "Password updated. Sign in again…" callout.
- [ ] Sign back in with the new password. Confirm you go straight to `/admin/dashboard` (no banner, no redirect).
- [ ] In another browser, sign in to `/admin` as the same user with the OLD password. Confirm sign-in is rejected.
- [ ] Repeat the four steps above for `support@nexride.africa` against `/support`.
- [ ] On the `/admin/login` screen, click **Forgot password?**, enter `admin@nexride.africa`, submit. Confirm an email arrives within ~1 minute.
- [ ] On `/admin/login`, click **Forgot password?**, enter `definitely-not-an-admin@example.com`, submit. Confirm the same generic success message appears (no leak that the email is unregistered).
- [ ] In the Firebase console, open `admin_audit_logs` and confirm both `provision_*_via_script` and `password_rotated_self` entries are present for the test user.
- [ ] Only after all of the above pass: remove `nexrideinfo@gmail.com` from `/admins`, clear its custom claim via `setUserRole({ uid, role: "" })`, and disable the user in Firebase Auth.

---

## Appendix A — File map

```
nexride_driver/
  functions/
    account_password.js                                ← rotate callable
    index.js                                           ← callable registration
  lib/
    portal_security/
      portal_password_logic.dart                       ← validators, rate limiter
      portal_password_service.dart                     ← Firebase wiring
      portal_security_theme.dart                       ← color tokens
      portal_change_password_screen.dart               ← change UI
      portal_account_security_screen.dart              ← security page UI
      portal_forgot_password_dialog.dart               ← forgot dialog
    admin/
      admin_app.dart                                   ← route registration
      admin_config.dart                                ← portalSecurityTheme + routes
      models/admin_models.dart                         ← AdminSession.mustChangePassword
      screens/admin_gate_screen.dart                   ← force-redirect
      screens/admin_login_screen.dart                  ← Forgot password? link
      services/admin_auth_service.dart                 ← reads must-change
    support_portal/
      support_app.dart                                 ← route registration
      support_config.dart                              ← portalSecurityTheme + routes
      models/support_models.dart                       ← SupportSession.mustChangePassword
      screens/support_gate_screen.dart                 ← force-redirect
      screens/support_login_screen.dart                ← Forgot password? link
      services/support_auth_service.dart               ← reads must-change

scripts/
  create_admin_user.js                                 ← stamps temp flag on creation

database.rules.json                                    ← /account_security/$uid rule
docs/admin_password_management.md                      ← this file
docs/admin_access.md                                   ← provisioning runbook (companion)
```

---

## Appendix B — Useful CLI commands

```bash
# Reset the temporaryPassword flag for a single user (admin SDK; bypasses rules):
node -e '
const admin = require("firebase-admin");
admin.initializeApp({ projectId: "nexride-8d5bc",
  databaseURL: "https://nexride-8d5bc-default-rtdb.firebaseio.com" });
(async () => {
  const uid = process.env.UID;
  const u = await admin.auth().getUser(uid);
  const next = { ...(u.customClaims ?? {}) };
  delete next.temporaryPassword;
  await admin.auth().setCustomUserClaims(uid, next);
  await admin.database().ref(`account_security/${uid}`).update({
    temporaryPassword: false,
    lastUpdatedAt: Date.now(),
  });
  console.log("cleared", uid);
})();
'

# Force sign-out everywhere for a user (server-side revoke):
firebase --project nexride-8d5bc auth:export users.json
# locate the uid in the export, then:
node -e '
const admin = require("firebase-admin");
admin.initializeApp({ projectId: "nexride-8d5bc" });
admin.auth().revokeRefreshTokens(process.env.UID).then(() => console.log("revoked"));
'

# Check the rotate callable directly with curl (auth required):
TOKEN=$(firebase --project nexride-8d5bc auth:print-access-token)
curl -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  https://us-central1-nexride-8d5bc.cloudfunctions.net/rotateAccountAfterPasswordChange \
  -d '{"data":{}}'
```
