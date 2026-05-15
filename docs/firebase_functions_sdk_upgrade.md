# Firebase Functions SDK upgrade (maintenance)

**Branch/task:** `chore/firebase-functions-sdk-v5` (recommended)  
**Date:** 2026-05-15  
**Scope:** Dependency-only upgrade for `nexride_dispatch` codebase (`nexride_driver/functions`). No business logic, callable signatures, Gen 1/2 layout, or Node runtime changes.

---

## Versions

| Package | Before | After |
|---------|--------|-------|
| `firebase-functions` | `^4.9.0` → lock **4.9.0** | `^5.1.1` → lock **5.1.1** |
| `firebase-admin` | `^12.7.0` → lock **12.7.0** | `^12.7.0` → lock **12.7.0** (unchanged) |
| Node (engines) | `22` | `22` (unchanged) |

**Imports unchanged:** `firebase-functions/v2/https`, `v2/scheduler`, `v2/firestore`, `firebase-functions/params`, and `firebase-functions` logger — no migration to a new major or Gen 1 rewrite.

---

## Commands run

```bash
cd nexride_driver/functions

# Upgrade (conservative)
npm install firebase-functions@^5.1.0 firebase-admin@^12.7.0

# Verify
npm test

# Canary deploy (nexride_dispatch codebase)
cd /Users/lexemm/Projects/nexride
firebase deploy --only functions:nexride_dispatch:adminGetProductionHealthSnapshot --debug
```

---

## Test results

```text
npm test
ℹ tests 87
ℹ pass 87
ℹ fail 0
```

All unit tests in `nexride_driver/functions/test/*.test.js` passed after upgrade.

---

## Deploy results

### Canary function

| Item | Value |
|------|--------|
| Function | `adminGetProductionHealthSnapshot` |
| Codebase | `nexride_dispatch` |
| Region | `us-central1` |
| Runtime | `nodejs22` (unchanged) |
| Result | **Successful update** (~93s) |
| URL | `https://us-central1-nexride-8d5bc.cloudfunctions.net/adminGetProductionHealthSnapshot` |

Deploy completed with exit code `0`. No `firebase-functions@4.9.0` outdated warning observed in this deploy log.

### Runtime canary verification

| Check | Result |
|-------|--------|
| `/admin/system-health` loads (super_admin / ops_admin) | **PASS** |
| Refresh works | **PASS** |
| No red console errors | **PASS** |
| Infrastructure cards (RTDB / Firestore / Auth / Storage) | **PASS** |
| Allowed role — no permission error | **PASS** |
| Restricted role without `dashboard.read` blocked | **PASS** |

Verified: 2026-05-15 (operator sign-off after SDK v5 canary deploy).

---

## Staged rollout (nexride_dispatch, SDK v5)

Wait **60–90 seconds** between batches. On **429**: wait 10 minutes, retry **only** failed functions.

### Batch 1 — admin dashboards + audit

```bash
firebase deploy --only functions:nexride_dispatch:adminGetLiveOperationsDashboard,functions:nexride_dispatch:adminGetOperationsDashboard,functions:nexride_dispatch:adminListAuditLogs
```

| Batch | Functions | Status | Time (UTC) |
|-------|-----------|--------|------------|
| 1 | `adminGetLiveOperationsDashboard`, `adminGetOperationsDashboard`, `adminListAuditLogs` | **PASS** | 2026-05-15 |

### Batch 2 — users + account moderation

```bash
firebase deploy --only functions:nexride_dispatch:adminListUsers,functions:nexride_dispatch:adminWarnAccount,functions:nexride_dispatch:adminSuspendAccount
```

| Batch | Status | Time (UTC) |
|-------|--------|------------|
| 2 | `adminListUsers`, `adminWarnAccount`, `adminSuspendAccount` | **PASS** | 2026-05-15 |

### Batch 3 — driver verification

```bash
firebase deploy --only functions:nexride_dispatch:adminVerifyDriver,functions:nexride_dispatch:adminApproveDriverVerification,functions:nexride_dispatch:adminListDriverVerificationDocuments
```

| Batch | Status | Time (UTC) |
|-------|--------|------------|
| 3 | `adminVerifyDriver`, `adminApproveDriverVerification`, `adminListDriverVerificationDocuments` | **PASS** | 2026-05-15 |

### Batch 4 — withdrawals

```bash
firebase deploy --only functions:nexride_dispatch:adminApproveWithdrawal,functions:nexride_dispatch:adminRejectWithdrawal,functions:nexride_dispatch:driverUpdateWithdrawalDestination
```

| Batch | Status | Time (UTC) |
|-------|--------|------------|
| 4 | `adminApproveWithdrawal`, `adminRejectWithdrawal`, `driverUpdateWithdrawalDestination` | **PASS** | 2026-05-15 |

### Batch 5 — merchants

```bash
firebase deploy --only functions:nexride_dispatch:adminListMerchants,functions:nexride_dispatch:adminReviewMerchant,functions:nexride_dispatch:adminUpdateMerchantPaymentModel
```

| Batch | Status | Time (UTC) |
|-------|--------|------------|
| 5 | `adminListMerchants`, `adminReviewMerchant`, `adminUpdateMerchantPaymentModel` | **PASS** | 2026-05-15 |

### Batch 6 — rider catalog + payments

```bash
firebase deploy --only functions:nexride_dispatch:riderGetMerchantCatalog,functions:nexride_dispatch:initiateFlutterwavePayment,functions:nexride_dispatch:flutterwaveWebhook
```

| Batch | Status | Time (UTC) |
|-------|--------|------------|
| 6 | `riderGetMerchantCatalog`, `initiateFlutterwavePayment`, `flutterwaveWebhook` | **PASS** | 2026-05-15 |

**Note:** Many other `nexride_dispatch` exports were already on SDK v5 from the shared source upload during these deploys. Remaining functions not in batches 1–6 can be rolled with `firebase deploy --only functions:nexride_dispatch` when quota allows, or in additional small batches if needed.

### Post-rollout admin smoke (manual)

- `/admin/dashboard`
- `/admin/system-health`
- `/admin/live-ops`
- `/admin/audit-logs`
- `/admin/service-areas`
- `/admin/merchants`

Do **not** ship mobile app store builds until smoke rows pass.

---

## Rollback

If deploy or production runtime fails:

```bash
git restore nexride_driver/functions/package.json nexride_driver/functions/package-lock.json

cd nexride_driver/functions
npm install

cd /Users/lexemm/Projects/nexride
firebase deploy --only functions:nexride_dispatch:adminGetProductionHealthSnapshot
```

Then redeploy additional functions if you had already rolled forward other batches.

---

## Files changed

- `nexride_driver/functions/package.json`
- `nexride_driver/functions/package-lock.json`

**Not changed:** `index.js`, callable handlers, RBAC, Flutter admin, hosting.

---

## Sign-off

| Step | Status | Operator | Date |
|------|--------|----------|------|
| `npm test` | PASS (87/87) | | 2026-05-15 |
| Canary deploy | PASS | | 2026-05-15 |
| `/admin/system-health` runtime | **PASS** | operator | 2026-05-15 |
| Staged batches 1–6 | **PASS** (18 functions) | agent | 2026-05-15 |
| Post-rollout admin smoke (6 routes) | _pending operator_ | | |
