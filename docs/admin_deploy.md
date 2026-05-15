# NexRide Admin Portal — deploy & operations

Official hosted admin: **`https://nexride.africa/admin`** (Flutter entrypoint `lib/main_admin.dart`).

## Official deploy (hosting + predeploy build)

From the **monorepo root** (`nexride/`, where `firebase.json` lives):

```bash
cd /Users/lexemm/Projects/nexride
firebase deploy --only hosting
```

`firebase.json` **predeploy** runs `zsh tools/build_hosted_web.sh`, which:

1. Builds the marketing site → `public/`
2. **`rm -rf public/admin`**, then builds **admin** with  
   `-t lib/main_admin.dart --release --base-href /admin/ -o <public>/admin`
3. Builds support and merchant into `public/support` and `public/merchant`
4. **Fails with exit 1** if `public/admin` is missing `index.html`, `flutter_bootstrap.js`, or `main.dart.js`
5. **Fails with exit 1** if the built tree contains **`ADMIN BUILD OK`** (guards stale / wrong bundles)

## If a removed UI strip still appears in the browser

The recovery strip was removed from **`lib/admin/admin_app.dart`**. If production still shows **ADMIN BUILD OK**:

1. **Source:** `grep -R "ADMIN BUILD OK" nexride_driver/lib` — must be empty.
2. **Build output:** after building admin, `grep -R "ADMIN BUILD OK" public/admin` — must be empty before deploy.
3. **Clean output:** `rm -rf public/admin`, rebuild, redeploy hosting.
4. **Browser:** clear site data for `nexride.africa` (cached `main.dart.js` / service worker can keep old JS).

Admin-only rebuild (no full site):

```bash
/Users/lexemm/Projects/nexride/tools/build_admin_hosting_only.sh
cd /Users/lexemm/Projects/nexride
firebase deploy --only hosting
```

## Critical: never publish the wrong Flutter app to `/admin`

Do **not** run a bare `flutter build web` from `nexride_driver` for production admin unless you pass **all** of:

```text
-t lib/main_admin.dart
--release
--base-href /admin/
-o ../public/admin
```

The build log **must** contain:

```text
Compiling lib/main_admin.dart for the Web...
```

If you see `main_merchant.dart`, `main.dart`, or `main_driver.dart`, **stop** — you are not building the admin bundle.

## Audit logs callable

Audit UI uses **only** the callable **`adminListAuditLogs`** (see `AdminDataService.adminListAuditLogs`). Deploy or verify the function when changing backend behavior:

```bash
firebase deploy --only functions:nexride_dispatch:adminListAuditLogs
```

## Architecture (official control center)

- **Admin portal UI** → **HTTPS Cloud Functions** (`admin*` callables) for privileged and section-specific operations.
- **Cloud Functions** → Firestore, RTDB, Auth, Storage, payments, etc., with server-side checks.
- The admin app **must not** use client Firebase paths to bypass functions for privileged operations.

Some **legacy** dashboard paths may still use client RTDB reads during migration; new work should use callable-backed loaders.

## Backend visibility principle

Operational truth should live in backends the admin can surface: rider/driver/merchant profiles, wallets and withdrawals, trips and store orders, service areas, online/offline status, verification, warnings/suspensions, support issues, etc.

## Drawer / sections checklist

Drawer order is defined in code by `kAdminSidebarNavOrder` (`lib/admin/admin_config.dart`):

- Dashboard, Riders, Drivers, Trips, Live operations, Finance, Withdrawals, Pricing, Subscriptions, Verification, Support, Regions, Service areas, Merchants, Audit logs, Settings.

## Production smoke test (after deploy)

Use a **fresh profile** or clear site data for `nexride.africa`, then check:

- `https://nexride.africa/admin/login`
- `https://nexride.africa/admin/dashboard`
- `https://nexride.africa/admin/live-ops`
- `https://nexride.africa/admin/audit-logs`
- `https://nexride.africa/admin/service-areas`
- `https://nexride.africa/admin/merchants`

**Expected:** no white screen; drawer and refresh work; errors show cards, not blank pages.

**Stop feature work** until these checks pass.

## Next phase (not in this doc)

Admin **RBAC** (e.g. super_admin, ops_admin, finance_admin, support_admin, verification_admin, merchant_ops_admin) with Cloud Function enforcement and UI disable/hide rules.
