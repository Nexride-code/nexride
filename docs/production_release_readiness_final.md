# NexRide production release readiness (final)

Pre–App Store / Play Store gate. Mark **PASS** / **FAIL** / **N/A** with evidence.

---

## Security & platform

| Item | PASS/FAIL | Notes |
|------|-----------|-------|
| Production Firebase project (`nexride-8d5bc`) | | |
| Firebase App Check enforced on client callables | | |
| Firestore rules reviewed (admin/rider/driver/merchant) | | |
| RTDB rules reviewed | | |
| Storage rules reviewed | | |
| Webhook `verif-hash` validation (Flutterwave) | | |
| No staging URLs in release builds | | |
| Admin RBAC restricted-role spot check | | |

---

## Payments & pricing (backend-authoritative)

| Item | PASS/FAIL | Notes |
|------|-----------|-------|
| ₦30 platform fee on ride booking (server total) | PASS (backend) / PENDING (rider UI) | `createRideRequest`, `initiateFlutterwaveRideIntent`, payment init use server totals |
| ₦30 platform fee on dispatch request | PASS (module) | Deployed `createDeliveryRequest` |
| ₦30 platform fee on merchant/food orders | PASS (module) | Deployed `riderPlaceMerchantOrder` |
| ₦15 small-order fee below threshold (commerce) | PASS (module) | subtotal &lt; ₦3000 → ₦15 |
| Client cannot override server `total_ngn` | PASS (module) | `pricing_total_mismatch`; optional `RIDER_TEST_EMAIL` callable test |
| No rider wallet / withdrawal in pricing paths | PASS | No `rider_wallet_*` in pricing or health snapshot |
| Payment success simulation (card) | | |
| Payment failure simulation | | |
| Bank transfer pending + admin confirm | | |
| Webhook idempotency (duplicate events) | | |
| Duplicate order creation protection | | |
| Duplicate payout / withdrawal protection | | |

---

## Admin & observability

| Item | PASS/FAIL | Notes |
|------|-----------|-------|
| `/admin/system-health` infrastructure not false RED | **PASS** | 2026-05-15 — Infrastructure GREEN, all backends reachable |
| Subsystem diagnostics visible (status, latency, reason) | **PASS** | RTDB, Firestore, Auth, Storage, Functions; Refresh OK |
| Production verify script (`tools/production_backend_verify.mjs`) | **N/A** | Optional; not blocking — production health confirmed in admin UI |
| Rider app shows backend `fee_breakdown` + `total_ngn` (no client authoritative total) | **NOT RUN** | Code-complete; device smoke R1–R10 not executed by agent |
| Rider device smoke (ride / dispatch / food / mismatch / no wallet) | **NOT RUN** | R11 **PASS** (static: no rider wallet UI); R1–R10 need device |
| App Store / Play Store upload | **BLOCKED** | Until R1–R10 device **PASS** in `production_smoke_test.md` (R11 done) |
| Driver supply segmentation (car/bike/fleet) | **NOT STARTED** | After QA gate clears |
| `/admin/dashboard`, `/live-ops`, `/audit-logs` | | |
| `/admin/service-areas`, `/admin/merchants` | | |
| Callable structured errors (no raw stack to UI) | **PENDING** | Merchant food uses `friendlyFirebaseError`; verify R10 on device |
| Production logs include callable name + latency | | `observability.js` |

---

## Resilience

| Item | PASS/FAIL | Notes |
|------|-----------|-------|
| Low-network / timeout behavior (mobile) | | |
| Stale admin session handling | | |
| Forced logout / disabled admin | | |
| Cold-start acceptable on critical callables | | |
| Offline recovery (driver GPS / trip state) | | |
| Firestore indexes deployed for production queries | | |

---

## Mobile store assets

| Item | PASS/FAIL | Notes |
|------|-----------|-------|
| Android `google-services.json` (production) | | |
| iOS `GoogleService-Info.plist` (production) | | |
| Release signing configured | | |
| Push notifications | | |
| Location permissions copy + behavior | | |
| Background location (driver) documented | | |
| Privacy policy & terms URLs live | | |
| App icons & splash | | |
| No debug banner in release | | |
| Crash-free smoke on physical devices | | |

---

## Sign-off

| Role | Name | Date | Overall |
|------|------|------|---------|
| Engineering | | | |
| Ops | | | |

**Release blocked if:** infrastructure critical on health, payment total mismatch in prod, or any FAIL in Security & Payments sections.
