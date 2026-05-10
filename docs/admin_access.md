# Admin & Support Access Runbook

This is the operator manual for everything related to logging into
`https://nexride.africa/admin` and `https://nexride.africa/support`:
how access is enforced, how to recover when you're locked out, how to add
new operators, and the security baseline you should keep in production.

> **Project:** `nexride-8d5bc`
> **Hosted at:** `https://nexride.africa/admin`, `https://nexride.africa/support`
> **Source of truth for guards:** `firestore.rules`, `database.rules.json`,
> `nexride_driver/functions/admin_auth.js`,
> `public/admin/src/pages/admin/AdminShell.tsx`,
> `public/support/src/pages/support/SupportShell.tsx`.

---

## 1. How admin access actually works

NexRide uses Firebase Authentication (email + password) and grants admin
or support powers on top of a normal Firebase user via **three independent
sources**, which the guards check in order. **A single sign-in succeeds
for `/admin` if any one of them grants access.**

| Layer | Backed by | Checked in |
| --- | --- | --- |
| **Firebase custom claims** on the ID token: `admin: true` / `support: true` / `support_staff: true` / `role: "admin" \| "support_agent" \| "support_manager"` | Auth token (1-hour lifetime; refreshed on `getIdToken(true)` after role changes) | `firestore.rules` (`isAdmin()`, `isSupport()`); `nexride_driver/functions/admin_auth.js` (`isNexRideAdmin`, `isNexRideSupportStaff`); `AdminShell.tsx`; `SupportShell.tsx` |
| **RTDB allow-list**: `/admins/{uid} = true` and `/support_staff/{uid} = { role, enabled, ... }` | Realtime Database, function-only writes | Same files as above (RTDB fallback path) |
| **Firestore role document**: `support_staff/{uid} = { role, enabled, ... }` | Firestore | `firestore.rules` (`isSupportDocument()`) |

There's also a fourth, narrower path for some legacy callables and RTDB
rules: `users/{uid}/role === 'admin'` (see `database.rules.json`). New
operators do **not** need this; the three layers above are the canonical
ones.

**This means a brand-new admin needs:**

1. A Firebase Auth user with email + password.
2. `customClaims.admin = true` on that user.
3. `/admins/{uid} = true` in RTDB.
4. *(Recommended)* A `support_staff/{uid}` doc in Firestore with `role: "admin"` and `enabled: true`. This unlocks the document-based path in `firestore.rules` if claims haven't propagated to a fresh ID token yet.

`scripts/create_admin_user.js` does all four in one shot. `scripts/reset_admin_password.js` only resets step 1's password.

### Client-side flow (what users see)

`/admin` and `/support` are React SPAs served by Firebase Hosting from
`public/admin/` and `public/support/`. Their root component:

1. Renders the **sign-in form** if `auth.currentUser` is null.
2. After `signInWithEmailAndPassword`, fetches the new ID token with
   `getIdTokenResult()` and reads `claims.admin` / `claims.support_staff`.
3. In parallel, reads `/admins/{uid}` and `/support_staff/{uid}` from RTDB.
4. If neither claim nor RTDB entry says you're allowed, renders the
   **"signed in but not an admin"** page with a Sign-out button. **There is
   no path to the admin UI without one of those grants.** The admin shell's
   `Routes` block is unreachable until `allowed === true`.
5. Even if a malicious user bypassed the SPA gate (e.g. by hand-crafting
   requests), every Cloud Functions callable used by the admin UI
   re-checks `isNexRideAdmin(db, context)` server-side, and Firestore /
   RTDB / Storage rules independently re-check `isAdmin()` /
   `isSupport()`.

This is layered defense: the client gate is a UX nicety, the real
enforcement happens in security rules and Cloud Functions.

---

## 2. Why we are getting rate-limited

When you (or a bot) hit `signInWithEmailAndPassword` from a browser too
many times — usually on the order of ~10 failed attempts in a few
minutes from the same IP — Firebase Authentication starts returning
`auth/too-many-requests`. The error includes a `retryAfter` and the
**reset-password email flow can also stall** while the throttle is
active because it shares the same anti-abuse signals.

Firebase rate-limits two things separately:

- **Per-IP / per-account sign-in attempts** — what trips first when an
  operator types the wrong password repeatedly or a credential-stuffing
  bot hits the page.
- **Per-account password resets** (the email link flow). This is
  independent of sign-in throttling but Google can throttle the
  email-sending side to defeat enumeration.

There is **no end-user knob** to reset the throttle. Options are:

1. Wait. The lockout window is typically 15 minutes to a few hours; it
   decays on its own.
2. Switch IPs (mobile hotspot / VPN). The account throttle persists, but
   the per-IP component releases.
3. **Use the Admin SDK to reset the password directly** —
   `scripts/reset_admin_password.js`. This is the safe, audited bypass
   because it runs as a service account on your laptop, not as the
   end-user from a browser.

The Admin-SDK path is what the rest of this document focuses on. It also
revokes refresh tokens, so any in-flight session that was hijacked or
forgotten is invalidated.

---

## 3. One-time setup

### 3.1 Service-account credential

Both scripts need a credential that can mint Admin SDK tokens for the
`nexride-8d5bc` project. Pick **one** of:

**Option A (recommended for laptops):** Application Default Credentials.

```bash
gcloud auth application-default login
```

This drops `~/.config/gcloud/application_default_credentials.json`. The
scripts auto-detect it. Your gcloud account must have **Firebase Admin**
or **Owner** role on the `nexride-8d5bc` project.

**Option B (recommended for CI / shared machines):** dedicated service
account.

1. Firebase Console → Project Settings → Service accounts → **Generate new private key**.
2. Save the JSON to `scripts/serviceAccountKey.json` (already gitignored).
3. The scripts auto-detect it.

If neither is found, the scripts exit with a clear error.

### 3.2 Install dependencies

```bash
cd scripts
npm install
```

This installs `firebase-admin@^12` into `scripts/node_modules/` (also
gitignored). You only need to do this once per checkout.

---

## 4. Reset a locked-out admin password

Use this when an operator is hard-locked out of `/admin` or `/support`,
or when you need to rotate `nexrideinfo@gmail.com`.

```bash
# Preferred: pass the password via env var so it never lands in shell history.
NEW_PASSWORD='YourStrongTempPassword!' \
  node scripts/reset_admin_password.js nexrideinfo@gmail.com
```

What the script does, in order:

1. Loads service-account credentials.
2. `admin.auth().getUserByEmail(email)` → user UID.
3. `admin.auth().updateUser(uid, { password })`.
4. `admin.auth().revokeRefreshTokens(uid)` — every existing browser/app
   session is now invalid.
5. Prints a single success block. If you let the script generate a
   random password (omit `NEW_PASSWORD`), it prints it once. Copy it
   into 1Password / Bitwarden **before** closing the terminal — there
   is no second copy.

**Right after the reset:**

- Visit `https://nexride.africa/admin` and sign in with the new
  password.
- Open the user's Firebase Auth detail page in the console and confirm
  `lastSignInTime` updated.
- Have the operator change the password to something only they know
  (Account → Security in Firebase Auth, or via "forgot password" once
  rate limit clears).

---

## 5. Create production admin / support accounts

The canonical command:

```bash
node scripts/create_admin_user.js
```

That provisions both:

- `admin@nexride.africa` → role `admin`, custom claim `{ admin: true, role: "admin" }`, RTDB `/admins/{uid} = true`, Firestore `support_staff/{uid} = { role: "admin", enabled: true }`.
- `support@nexride.africa` → role `support_agent`, custom claim `{ support: true, support_staff: true, role: "support_agent" }`, RTDB `/support_staff/{uid} = { role: "support_agent", enabled: true, ... }`, Firestore `support_staff/{uid}`.

If a user already exists, the password is **not** touched — only the
role bookkeeping is reapplied (idempotent). If a user is created fresh,
a 32-character random password is generated, printed once to stdout,
and **never written to disk**. Save it to a secrets manager
immediately.

**Selectors:**

```bash
# Just the admin account
node scripts/create_admin_user.js --only-admin

# Just the support account
node scripts/create_admin_user.js --only-support

# Custom emails (e.g. ops@nexride.africa as a second admin)
node scripts/create_admin_user.js --admin-email ops@nexride.africa --only-admin
```

After the script finishes, every change is mirrored into
`/admin_audit_logs` in RTDB so you have a tamper-evident record of who
was provisioned and when.

### Adding a new admin in the future (the safe pattern)

1. Run `node scripts/create_admin_user.js --admin-email new.admin@nexride.africa --only-admin`.
2. Hand the operator their **email + temporary password** through a
   trustworthy out-of-band channel (1Password sharing, Signal). Never
   email it as plaintext.
3. Have them change the password from the admin UI's sign-in flow on
   first use.
4. Confirm the new account works at `https://nexride.africa/admin`,
   then **revoke old / unused operators** by removing their
   `/admins/{uid}` entry in RTDB and clearing their `admin` custom
   claim. The fastest way is a small ad-hoc Admin-SDK snippet:

   ```js
   await admin.auth().setCustomUserClaims(uid, {});
   await admin.database().ref(`admins/${uid}`).remove();
   ```

Until that revocation is run, any leaked credentials for the old
operator still grant admin access — claims are not auto-revoked when
you "delete" a user from the Console UI's perspective.

---

## 6. Why `nexrideinfo@gmail.com` should not stay as the primary admin

Treat this account as the **break-glass owner** only, not as a daily
driver. Reasons, ranked by severity:

1. **It's a personal Gmail.** If the inbox is compromised (phishing,
   SIM-swap, password reuse), the attacker also owns the Firebase
   project — they can reset *any* admin password, deploy malicious
   Cloud Functions, and exfiltrate user PII. There is no recovery from
   that short of re-provisioning the project.
2. **No role separation.** Day-to-day support work and "I-broke-prod"
   firefighting share the same login, so audit logs can't tell whether
   a destructive action came from the founder, a contractor, or a
   support agent.
3. **Single point of failure.** If the Gmail account gets locked
   (Google's automated abuse systems regularly lock accounts that look
   suspicious), there's no fallback admin and you're locked out of
   production.
4. **No least-privilege.** A support agent doesn't need Firestore
   rules-bypass, Storage delete, or the ability to set custom claims
   on other users — but `admin: true` grants all of those.

**Target end-state:**

- `admin@nexride.africa` and `support@nexride.africa` are the only
  accounts with admin / support claims (created by the script above).
- `nexrideinfo@gmail.com` becomes an **emergency break-glass** account:
  remove its `admin` claim and `/admins/{uid}` entry, but keep the
  Google account around as the project Owner in Cloud IAM. That's the
  layer Google falls back to if you lose your Firebase Auth admin
  users.
- Each human operator who needs admin gets their own Firebase Auth
  user with their own password and 2FA on the email side. Don't share
  logins.

---

## 7. Production security recommendations

In rough priority order.

1. **Enforce strong passwords + MFA on `admin@nexride.africa` and
   `support@nexride.africa`.** Firebase Authentication supports TOTP
   MFA on email/password; enable it: Firebase Console → Authentication
   → Settings → Multi-factor authentication. Make it mandatory for any
   account that ever holds the `admin` claim.
2. **Rotate the service-account JSON quarterly.** Old keys keep
   working forever unless explicitly disabled (Google Cloud Console →
   IAM & Admin → Service Accounts → Keys → revoke). Generate the new
   key, replace `scripts/serviceAccountKey.json`, then disable the
   old.
3. **Cap who can mint claims.** `admin_roles.js` already gates
   `setUserRole` on `isNexRideAdmin`, so only existing admins can
   promote others. Don't add unauthenticated provisioning callables.
4. **Audit logs are first-class.** `/admin_audit_logs` already records
   role changes; export it to BigQuery via Firebase Realtime Database
   integration if you need long-term retention.
5. **Run `npm audit` against `scripts/` and the functions codebase**
   before each release. Critical advisories on `firebase-admin` matter
   more here than in the rider/driver app, because this code talks
   directly to the credential.
6. **Don't deploy `scripts/` to Firebase Hosting.** They're operator
   tools; they have no place in any built artifact. (`firebase.json`
   only deploys `public/**`, so this is already the case — keep it
   that way.)
7. **Treat the rider client's `users/{uid}/role === 'admin'` rule
   (in `database.rules.json`) as legacy.** Eventually migrate every
   path to the claim/RTDB-allowlist model so a compromised user
   document can't elevate itself.

---

## 8. Brute-force protection

### What Firebase already does

- **Per-account exponential backoff** on `signInWithEmailAndPassword`.
  After ~5 wrong passwords, subsequent attempts return
  `auth/too-many-requests` for that email until a cool-down expires.
- **Per-IP throttling** on Identity Toolkit endpoints. Visible as
  `auth/too-many-requests` from a single client IP making many sign-in
  or password-reset requests.
- **Anti-enumeration** on the sign-up endpoint: a wrong email and a
  wrong password return the same error code (you can't enumerate
  registered admins).

This stops casual brute force but does **not** stop a distributed
credential-stuffing attack (different IPs, different accounts). For
that you need the layers below.

### Recommended additions

#### a) **Cloudflare in front of `nexride.africa`** (cheapest, biggest win)

Firebase Hosting serves through Google's CDN, but Cloudflare can sit in
front of the apex domain and:

- **Block obvious sign-in floods** with a Rate-Limiting Rule scoped to
  `path = "/admin/*" OR path = "/support/*"`. A starting policy:
  `> 30 requests per 1 minute per IP → JS challenge`.
- **Country / ASN allow-list** for `/admin/*` if your operators are all
  in known regions (e.g. allow only NG / GH / KE / your home office IP
  range). Keep `/support/*` open.
- **Bot Fight Mode** on `/admin/*`. This blocks headless browsers and
  scripted clients that don't run JS.
- **Page Rules → Always Use HTTPS** on the apex.

Setup steps (high level): point `nexride.africa` NS to Cloudflare,
proxy the apex A/AAAA record (orange cloud) to Firebase Hosting's
target, then add the rate-limit rule under **Security → WAF**.

#### b) **reCAPTCHA Enterprise on the admin/support sign-in form**

Firebase Authentication has first-party support for reCAPTCHA
Enterprise on email-password sign-in (called "Identity Platform App
Check / reCAPTCHA Enterprise integration"). Steps:

1. Enable reCAPTCHA Enterprise on the GCP side; create a key for
   `nexride.africa`.
2. In Firebase Console → Authentication → Settings → "Email
   enumeration protection" + "reCAPTCHA Enterprise score-based
   protection" → enable for sign-in.
3. Update `public/admin/src/pages/admin/AdminShell.tsx` and
   `public/support/src/pages/support/SupportShell.tsx` to render the
   invisible reCAPTCHA widget around the `signInWithEmailAndPassword`
   call. The Firebase SDK takes care of the token exchange — you just
   pass `forceRecaptchaFlowForTesting` off in production.
4. In the Firebase Auth settings, set the score threshold to deny
   below 0.4 (start liberal, tune down).

This is the single highest-leverage defense against credential
stuffing, because it requires the attacker to either solve a reCAPTCHA
or pay a CAPTCHA-farm — at which point your password complexity and
MFA become the gating factors.

#### c) **App Check on every admin Cloud Function**

Cloud Functions called from the admin SPA (`adminListLiveRides`,
`setUserRole`, etc.) should require **App Check** so requests can only
come from your hosted SPA, not from a curl loop in a hostile network.
Add `enforceAppCheck: true` to each callable definition in
`nexride_driver/functions/index.js` once you've confirmed the SPA
correctly attaches the App Check token.

#### d) **Alert on suspicious auth events**

Pipe Firebase Auth events into Cloud Logging and create a log-based
metric for:

- `>= 10 auth/too-many-requests` per minute on `/admin` paths.
- New IP geographies signing in successfully as `admin` for the first
  time.
- Any change to `/admins` in RTDB (use a Realtime Database trigger
  Cloud Function that pushes to PagerDuty / email).

---

## 9. Quick reference

```bash
# 0. One-time setup
gcloud auth application-default login   # or drop scripts/serviceAccountKey.json
cd scripts && npm install && cd ..

# 1. Reset a locked-out user (no rate limit applies — Admin SDK)
NEW_PASSWORD='Strong!Temp#2026' \
  node scripts/reset_admin_password.js nexrideinfo@gmail.com

# 2. Provision admin@ and support@ (idempotent; never overwrites passwords)
node scripts/create_admin_user.js

# 3. Provision only one
node scripts/create_admin_user.js --only-admin
node scripts/create_admin_user.js --only-support

# 4. Provision a custom admin email
node scripts/create_admin_user.js --admin-email ops@nexride.africa --only-admin
```

Confirmed safe: every command above runs locally, prints the
generated/changed credentials only to your terminal, and writes
nothing sensitive to git or to disk. The `.gitignore` blocks
`scripts/serviceAccountKey.json`, `scripts/.env*`, and
`scripts/node_modules/` so an accidental `git add scripts/` is a
no-op for secrets.

---

## 10. Files that this runbook touches

| File | Role |
| --- | --- |
| `scripts/reset_admin_password.js` | Admin-SDK password reset tool. |
| `scripts/create_admin_user.js`    | Admin-SDK provisioning tool. |
| `scripts/package.json`            | Pins `firebase-admin@^12.7.0`. |
| `scripts/README.md`               | One-screen quick-start; links here. |
| `.gitignore`                      | Blocks service-account JSON, `.env`, `node_modules/`. |
| `docs/admin_access.md`            | This document. |

The runtime guards (referenced but **not modified**):

| File | Role |
| --- | --- |
| `nexride_driver/functions/admin_auth.js`   | Server-side `isNexRideAdmin` / `isNexRideSupportStaff`. |
| `nexride_driver/functions/admin_roles.js`  | Callable that grants/revokes roles (admin-only). |
| `nexride_driver/functions/scripts/grant_roles.js` | Legacy bootstrap script; superseded by `scripts/create_admin_user.js`. Keep for reference. |
| `firestore.rules`                          | `isAdmin()`, `isSupport()`, `support_staff` doc rules. |
| `database.rules.json`                      | RTDB role checks (`users/{uid}/role`, `/admins`, `/support_staff`). |
| `storage.rules`                            | Storage `isAdmin()` checks. |
| `public/admin/src/pages/admin/AdminShell.tsx`     | `/admin` SPA gate. |
| `public/support/src/pages/support/SupportShell.tsx` | `/support` SPA gate. |
