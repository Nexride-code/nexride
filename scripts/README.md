# scripts/

Out-of-band operator tools for NexRide. They run locally on an operator's
laptop with a Firebase service-account credential; they are **not** deployed.

| File | Purpose |
| --- | --- |
| `reset_admin_password.js` | Reset a Firebase Auth user's password using the Admin SDK. The right tool when `/admin` or `/support` rate-limits a real operator. |
| `create_admin_user.js`    | Provision the canonical `admin@nexride.africa` and `support@nexride.africa` accounts, set custom claims, and mirror the role state into RTDB and Firestore. |

See [`docs/admin_access.md`](../docs/admin_access.md) for the full runbook,
including service-account setup, brute-force defenses, and the reasons
`nexrideinfo@gmail.com` should not stay as the primary admin.

## Quick install

```bash
cd scripts
npm install
```

## Quick reset (locked-out owner account)

```bash
NEW_PASSWORD='<a-strong-temp-password>' \
  node scripts/reset_admin_password.js nexrideinfo@gmail.com
```

If `NEW_PASSWORD` is omitted, the script generates a strong random password
and prints it once to stdout.

## Quick provisioning (production accounts)

```bash
node scripts/create_admin_user.js
```

This creates `admin@nexride.africa` and `support@nexride.africa` if they
don't already exist, prints any generated passwords once, and writes:

- custom claims (`admin: true` / `support: true, support_staff: true, role: "support_agent"`)
- `/admins/{uid} = true`  or  `/support_staff/{uid} = {role, enabled, ...}` (RTDB)
- `support_staff/{uid} = {role, enabled, ...}` (Firestore)
- an entry in `/admin_audit_logs` (RTDB)

## Never commit

`.gitignore` blocks the obvious foot-guns (`scripts/serviceAccountKey.json`,
`scripts/.env*`, `scripts/node_modules/`), but the rule is simple: **no
credential or password ever goes into git**. If it's a secret, use a password
manager or an environment variable.
