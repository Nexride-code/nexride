# Admin & Support Role Propagation

This doc is the runbook for the **end-to-end authorization path** that decides whether `admin@nexride.africa` and `support@nexride.africa` can open `/admin` and `/support` respectively. It exists because we hit the classic "signed in but no access" race after rolling out the new password-management flows. This page describes:

1. Every authorization surface a portal session is checked against.
2. How those surfaces are populated by `scripts/create_admin_user.js`.
3. The token-refresh retry path that closes the stale-claim race.
4. How to verify, debug, and roll back.

Read this **alongside** [`docs/admin_password_management.md`](./admin_password_management.md). That doc covers password lifecycle; this one covers role propagation.

---

## 1. Authorization surfaces (server-side)

There are **four** independent surfaces that any authorized operator must end up on, because different runtime checks consult different surfaces:

| Surface                          | Used by                                                                                     | Required value (admin)                  | Required value (support)                                |
| -------------------------------- | ------------------------------------------------------------------------------------------- | --------------------------------------- | ------------------------------------------------------- |
| Firebase Auth **custom claims**  | `AdminAuthService`, `SupportAuthService`, Cloud Functions (`isNexRideAdmin`, etc.), Firestore rules | `{ admin: true, role: "admin" }`        | `{ support: true, support_staff: true, role: "support_agent" }` |
| RTDB **`/admins/{uid}`**         | `AdminAuthService` fallback, `isNexRideAdmin` callable helper                               | `true`                                  | (n/a)                                                   |
| RTDB **`/support_staff/{uid}`**  | `SupportAuthService` fallback, `isNexRideSupportStaff` helper                               | (n/a, but admin can still read tickets) | `{ role: "support_agent", enabled: true, disabled: false, ... }` |
| RTDB **`/users/{uid}/role`**     | `database.rules.json` (`support_queue`, `admin_rides`, `support_tickets`, etc.)             | `"admin"`                               | `"support_agent"`                                       |
| Firestore **`support_staff/{uid}`** | `firestore.rules` `isSupportDocument()`                                                  | `{ role: "admin", enabled: true }`      | `{ role: "support_agent", enabled: true }`              |

Each access check accepts **multiple** equivalent paths. If even one of these surfaces is set correctly, the runtime will grant access — **except** for the deeper RTDB rules (`support_queue`, `admin_rides`, `support_tickets`, `support_ticket_messages`), which historically only honored `/users/{uid}/role`. We fixed that in this change: those rules now also accept the `support`/`support_staff` claims and the `admin: true` claim, so a freshly provisioned operator works even before `/users/{uid}/role` propagates.

> **All five surfaces are kept in sync by `scripts/create_admin_user.js`.** Re-running the script is idempotent and safe — it never overwrites the user's password.

---

## 2. RTDB security rules — what changed

Three additions to `database.rules.json`, none of which weaken existing checks:

### 2a. Self-read on `/admins/{uid}` and `/support_staff/{uid}`

```json
"admins":        { "$uid": { ".read": "auth != null && auth.uid === $uid", ".write": false } },
"support_staff": { "$uid": { ".read": "auth != null && auth.uid === $uid", ".write": false } }
```

The Flutter portals' fallback path looks up the operator's own RTDB record. Before this change, the absence of any rule meant root `.read: false` applied — every fallback read returned `permission-denied`, and the only authorization path left was the custom claim. If the cached ID token was even a minute stale, the operator was silently denied.

The new rules expose **only the operator's own record** (`auth.uid === $uid`). Writes remain server-only (Cloud Functions / scripts use the Admin SDK, which bypasses rules).

### 2b. Token-claim path on support data rules

The four operational support paths (`support_queue`, `admin_rides`, `support_tickets`, `support_ticket_messages`) used to require `root.child('users/' + auth.uid + '/role').val() === 'admin'` or `=== 'support'`. They now **also** accept:

- Custom claims: `auth.token.admin === true`, `auth.token.support === true`, `auth.token.support_staff === true`.
- Newer role values: `auth.token.role === 'support_agent'`, `auth.token.role === 'support_manager'` (in both the claim and `/users/{uid}/role`).
- Explicit RTDB admin flag: `root.child('admins/' + auth.uid).val() === true`.

Every previously accepted path still works — these are pure additions. The script writes both the claim and `/users/{uid}/role`, so any one of them is enough.

---

## 3. The token-refresh retry (closing the stale-claim race)

The `AdminAuthService` and `SupportAuthService` now have a two-phase decision:

```dart
// 1) Evaluate against the cached ID token.
final firstPass = await _evaluateAccess(user, attempt: 'cached');
if (firstPass.allow) return firstPass.session;

// 2) Force a token refresh (one network round trip) and re-evaluate.
await user.getIdToken(true);
final secondPass = await _evaluateAccess(user, attempt: 'forced-refresh');
return secondPass.allow ? secondPass.session : null;
```

This costs nothing on the happy path (the cached token is valid and the first pass returns `allow: true`) and rescues the unhappy path where claims have just been granted server-side but the local token hasn't been rotated yet (default Firebase ID-token TTL is ~1 hour, which is far longer than the time between provisioning and the operator's first sign-in).

The same pattern is applied to **both** `signIn` and `currentSession` so route changes that trigger a fresh `currentSession` (e.g. landing directly on `/support` via a deep link, or refreshing the page after provisioning) get the same retry.

---

## 4. Structured debug logging

Every authorization attempt now emits a single, greppable line:

```
SUPPORT_AUTH_DEBUG context=signIn attempt=cached
    uid=<uid> email=support@nexride.africa
    allow=false
    reasons=DENY:no_matched_path[attempt=cached]
    claims={temporaryPassword: true, support: true, support_staff: true, role: support_agent}
    rtdbAdmin=false
    supportRecordKeys=[role, enabled, disabled, email, updated_at]
```

Mirror line for admin (`ADMIN_AUTH_DEBUG`). Filter both with:

```
chrome devtools console -> Filter: AUTH_DEBUG
```

Reasons are emitted as a `|`-joined list — each entry corresponds to one accepted path. Examples:

| Reason                                  | Meaning                                                           |
| --------------------------------------- | ----------------------------------------------------------------- |
| `claim:admin=true`                      | Token has the `admin: true` custom claim.                         |
| `claim:support=true`                    | Token has the `support: true` custom claim.                       |
| `claim:support_staff=true`              | Token has the `support_staff: true` custom claim.                 |
| `claim:role=support_agent`              | Token's `role` claim is `support_agent` (or `support_manager`).   |
| `rtdb:/admins/{uid}=true`               | RTDB `/admins/{uid}` is `true` — admin fallback.                  |
| `rtdb:/support_staff/{uid}.role=...`    | RTDB `/support_staff/{uid}.role` is a recognized support role.    |
| `DENY:no_matched_path[attempt=...]`     | None of the above matched; access denied for this evaluation.     |

The `attempt=cached` vs `attempt=forced-refresh` tag tells you whether a `DENY` was rescued by the retry. If you see two consecutive `attempt=forced-refresh allow=false` denies for the same UID, the operator's role was never granted on the server — re-run the provisioning script.

---

## 5. The provisioning script (`scripts/create_admin_user.js`)

### Modes

```bash
# Provision both accounts (idempotent — safe to re-run any time):
node scripts/create_admin_user.js \
    --admin-email   admin@nexride.africa \
    --support-email support@nexride.africa

# Just verify, don't write:
node scripts/create_admin_user.js \
    --verify-only \
    --admin-email   admin@nexride.africa \
    --support-email support@nexride.africa

# Only one account at a time:
node scripts/create_admin_user.js --only-support
node scripts/create_admin_user.js --only-admin
```

### What it writes (idempotent)

For **admin**:

| Surface                                | Value                                                                                |
| -------------------------------------- | ------------------------------------------------------------------------------------ |
| Firebase Auth custom claims            | `{ admin: true, role: "admin" }`, plus `temporaryPassword: true` on first creation. |
| RTDB `/admins/{uid}`                   | `true`                                                                               |
| RTDB `/users/{uid}/role`               | `"admin"`                                                                            |
| RTDB `/users/{uid}/email`              | `"admin@nexride.africa"`                                                             |
| RTDB `/account_security/{uid}`         | `{ temporaryPassword: true, ... }` on first creation only                            |
| Firestore `support_staff/{uid}`        | `{ email, role: "admin", enabled: true, updatedAt }`                                 |

For **support**:

| Surface                                | Value                                                                                |
| -------------------------------------- | ------------------------------------------------------------------------------------ |
| Firebase Auth custom claims            | `{ support: true, support_staff: true, role: "support_agent" }`, plus `temporaryPassword: true` on first creation. |
| RTDB `/support_staff/{uid}`            | `{ email, role: "support_agent", enabled: true, disabled: false, updated_at }`       |
| RTDB `/users/{uid}/role`               | `"support_agent"`                                                                    |
| RTDB `/users/{uid}/email`              | `"support@nexride.africa"`                                                           |
| RTDB `/account_security/{uid}`         | `{ temporaryPassword: true, ... }` on first creation only                            |
| Firestore `support_staff/{uid}`        | `{ email, role: "support_agent", enabled: true, updatedAt }`                         |

The script never overwrites a password. If the user already exists, it just re-stamps the role state and prints the post-write verification block at the end.

### Verification output

Every run (whether `--verify-only` or a normal run) prints, for each operator:

```
uid                   : <uid>
disabled              : false
emailVerified         : false
custom claims         : {"admin":true,"role":"admin", ...}
/admins/{uid}         : true
/support_staff/{uid}  : null
/users/{uid}/role     : "admin"
/account_security/{uid}: {...}
firestore support_staff: {...}
authorized            : true
matched paths         : claim:admin=true, rtdb:/admins/{uid}=true, ...
```

If `authorized = false`, the matched-paths line is empty — re-run the script (without `--verify-only`) to fix.

---

## 6. Deploy commands

After the changes in this PR you must deploy **both** the security rules and the Flutter portals:

```bash
# 1) Push the new RTDB rules (this is the unblock — does NOT require a redeploy
#    of the Flutter app; legacy clients keep working).
cd nexride_driver/functions
firebase deploy --project nexride-8d5bc --only database

# 2) Re-stamp the admin/support accounts so /users/{uid}/role exists. This
#    will not change passwords; it will fill in any missing surfaces.
cd /Users/lexemm/Projects/nexride
node scripts/create_admin_user.js \
    --admin-email   admin@nexride.africa \
    --support-email support@nexride.africa

# 3) Rebuild and redeploy the admin/support portals so the new auth-service
#    retry logic is live.
zsh tools/build_hosted_web.sh
firebase deploy --project nexride-8d5bc --only hosting
```

---

## 7. Verification steps

After deploy:

1. Run `node scripts/create_admin_user.js --verify-only`. Confirm `authorized = true` for both `admin@nexride.africa` and `support@nexride.africa`, and that the matched-paths line includes `claim:role=...`, `rtdb:/admins/{uid}=true` (admin) or `rtdb:/support_staff/{uid}.role=support_agent` (support), and `rtdb:/users/{uid}/role=admin` / `support_agent`.
2. In an incognito window, sign in to `https://nexride.africa/support` with the support credentials.
3. Open Chrome DevTools → Console. You should see, in order:
   - `[SupportAuth] currentSession user=<uid>`
   - `SUPPORT_AUTH_DEBUG context=signIn attempt=cached uid=<uid> allow=true reasons=claim:support=true|claim:support_staff=true|claim:role=support_agent|rtdb:/support_staff/{uid}.role=support_agent`
   - `[SupportAuth] signIn granted ...`
4. Repeat for `https://nexride.africa/admin` with the admin credentials. Look for `ADMIN_AUTH_DEBUG ... allow=true reasons=claim:admin=true|...`.
5. From DevTools, run `await firebase.auth().currentUser.getIdTokenResult(true)` and confirm `claims` contains the expected role keys.
6. Try opening a support ticket from the support portal — the deeper RTDB rules (`support_tickets`, `support_ticket_messages`) should now grant access via the claim path.
7. (Negative test) sign in with `nexrideinfo@gmail.com` (legacy admin). Confirm it still works via the `rtdb:/admins/{uid}=true` path. Do **not** decommission the legacy admin until both new accounts are confirmed working.

---

## 8. Rollback

If anything regresses:

```bash
git revert <this commit's sha>
firebase deploy --project nexride-8d5bc --only database
zsh tools/build_hosted_web.sh
firebase deploy --project nexride-8d5bc --only hosting
```

The previous behavior (claims-only auth, no `/users/{uid}/role` write, no retry) returns. The new RTDB rule self-reads on `/admins/{uid}` and `/support_staff/{uid}` are the safest part of the change — they only expose the operator's own record. Reverting them just makes the fallback path return `permission-denied` again, which the auth services already handle gracefully.

---

## 9. Workspace data layer (the second "no access" surface)

> Heads-up: there are **two** places that can render the
> "Your account is signed in but does not have access" banner.
>
> 1. The **auth gate** (`SupportGateScreen` / `AdminGateScreen`) — if you
>    see this, the page header has no role pill yet. Section 1–4 above
>    apply.
> 2. The **workspace data layer** (`SupportWorkspaceScreen` body) — if
>    you see this, the page header DOES show the role (e.g.
>    `support · Support Agent`). The auth gate granted the session, but
>    a downstream RTDB read/write hit `permission-denied` and was funnelled
>    into the same generic message via
>    `_friendlySupportLoadFailureMessage` in
>    `support_workspace_screen.dart:190-208`.

### What the workspace touches on every dashboard load

| Step                        | RTDB path                                                | Op    | Required by                                  |
| --------------------------- | -------------------------------------------------------- | ----- | -------------------------------------------- |
| `forceTokenRefresh()`       | (Firebase Auth — no RTDB)                                | -     | Picks up freshly granted custom claims       |
| `touchStaffPresence`        | `/support_staff/{uid}/{displayName,accessMode,lastActiveAt,updatedAt}` | write | Directory "last active" indicator            |
| `fetchPortalSnapshot` (1)   | `/support_tickets`                                       | read  | Ticket inbox; falls back to `supportListTickets` callable on permission-denied |
| `fetchPortalSnapshot` (2)   | `/support_staff`                                         | read  | Operator directory                           |
| `fetchPortalSnapshot` (3)   | `/support_logs`                                          | read  | Activity feed                                |
| `addReply` / status changes | `/support_logs/{ticketId}/{logId}`                       | write | Audit trail; `actorId` must equal `auth.uid` |

### What the rules grant (after this PR)

- `/support_staff` parent `.read` for any signed-in admin/support (claim-based or `/users/{uid}/role`-based). Used by the directory listing in the workspace.
- `/support_staff/{uid}/{displayName,accessMode,lastActiveAt,updatedAt}` self-write only (`auth.uid === $uid`), with `.validate` on type/length. **`role`, `enabled`, `disabled`, `email` remain server-only** (Cloud Functions / `scripts/create_admin_user.js` write them via the Admin SDK, which bypasses rules).
- `/support_tickets` parent `.read` for any signed-in admin/support. The workspace's primary read path; the legacy `supportListTickets` callable remains as a fallback for callers that don't have the parent read (e.g. older admin code).
- `/support_logs` parent `.read` for any signed-in admin/support; per-log `.write` requires the writer's `actorId` to equal `auth.uid` (prevents forging another operator's audit entry).

### Defense-in-depth: presence write is non-fatal

`SupportTicketService.touchStaffPresence` is wrapped in `try/catch` (see `nexride_driver/lib/support_portal/services/support_ticket_service.dart`). If a future rules change ever blocks this write again, the worst-case symptom is a stale "last active" timestamp in the operator directory — the dashboard itself **always** continues to render. The catch logs `[SupportTicketService] touchStaffPresence skipped uid=… error=…` so the regression is visible in DevTools.

### Smoke test for the workspace path

After deploying the rules:

1. Open `https://nexride.africa/support` (incognito), sign in as `support@nexride.africa`.
2. The header shows `support · Support Agent` AND the body shows the dashboard skeleton (no "no access" banner).
3. In DevTools console, run:
   ```js
   firebase.database().ref('support_staff/' + firebase.auth().currentUser.uid).once('value').then(s => s.val())
   ```
   You should get back the operator's record (their own).
4. Run:
   ```js
   firebase.database().ref('support_staff').once('value').then(s => Object.keys(s.val()))
   ```
   You should get back the array of all support UIDs (parent-read works).
5. Click **Refresh** in the workspace header. The dashboard re-renders without the "no access" banner.

If step 2 still shows the banner, search the console for `permission-denied` — the failing path is logged either by `[SupportTicketService] touchStaffPresence skipped …` (now harmless) or by a deeper data fetch (which would surface as `_friendlySupportLoadFailureMessage`).

---

## 10. Related files

- `database.rules.json` — RTDB rules with the new self-reads and extended support-path checks.
- `scripts/create_admin_user.js` — provisioning + `--verify-only` mode.
- `nexride_driver/lib/admin/services/admin_auth_service.dart` — admin auth service with refresh retry.
- `nexride_driver/lib/support_portal/services/support_auth_service.dart` — support auth service with refresh retry + `SupportAuthDecision`.
- `nexride_driver/functions/admin_auth.js` — server-side `isNexRideAdmin` / `isNexRideSupportStaff`.
- `nexride_driver/functions/admin_roles.js` — `setUserRole` callable (alternate way to grant a role from the admin panel).
- `nexride_driver/functions/account_password.js` — `rotateAccountAfterPasswordChange` callable (preserves all role claims, only strips `temporaryPassword`).
- `firestore.rules` — `isSupport()` / `isSupportDocument()` helpers; unchanged in this PR.
