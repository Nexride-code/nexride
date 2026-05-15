# NexRide production smoke test

Run after each production deploy (hosting + functions). Mark **PASS** / **FAIL** with operator, date, and notes. Do not ship app store builds until critical paths pass.

**Environment:** Production Firebase project `nexride-8d5bc` · https://nexride.africa

---

## Backend deploy (pricing + health) — 2026-05-15

Deployed to `nexride-8d5bc` (batches ~75s apart):

| Batch | Function | Status |
|-------|----------|--------|
| 1 | `adminGetProductionHealthSnapshot` | SUCCESS |
| 2 | `createRideRequest` | SUCCESS |
| 3 | `createDeliveryRequest` | SUCCESS |
| 4 | `initiateFlutterwavePayment` | SUCCESS |
| 5 | `riderPlaceMerchantOrder` | SUCCESS |
| 6 | `initiateFlutterwaveRideIntent` | SUCCESS (ride prepay; charges fare + ₦30 platform) |
| 7 | `initiateFlutterwavePayment`, `initiateFlutterwaveMerchantOrderPayment` | SUCCESS (server `total_ngn` on checkout) |

**Env fix:** Added `NEXRIDE_SMALL_ORDER_FEE_NGN=15` and `NEXRIDE_SMALL_ORDER_THRESHOLD_NGN=3000` to `nexride_driver/functions/.env.nexride-8d5bc` (required for non-interactive deploy).

**Automated verify (run on operator machine with network + Firebase Admin or browser token):**

```bash
cd /Users/lexemm/Projects/nexride
node tools/production_backend_verify.mjs
```

If ADC / service account is unavailable, paste a fresh admin ID token from the browser (DevTools → Network → callable request → `Authorization: Bearer …`):

```bash
ADMIN_ID_TOKEN='eyJhbG…' node tools/production_backend_verify.mjs
```

Optional live tamper test on `createRideRequest`:

```bash
RIDER_TEST_EMAIL='test-rider@email.com' node tools/production_backend_verify.mjs
# or: RIDER_ID_TOKEN='eyJhbG…' node tools/production_backend_verify.mjs
```

**Unit tests:** `cd nexride_driver/functions && npm test` → 94/94 PASS.

### Live verification sign-off (2026-05-15)

| Check | PASS/FAIL | Operator / evidence |
|-------|-----------|---------------------|
| `node tools/production_backend_verify.mjs` (health callable + pricing module) | **N/A** | Optional; pricing module PASS locally; production health confirmed via admin UI |
| `/admin/system-health` UI (Infrastructure + 5 subsystems) | **PASS** | 2026-05-15 — Infrastructure GREEN, all backends reachable, Refresh OK |
| No console errors on system-health refresh | **PASS** | Operator browser verification |
| Rider UI fee wiring (backend `total_ngn` + `fee_breakdown`) | **PENDING** | Code complete; device smoke below |

---

## Rider pricing — production device smoke (release build)

### Current sign-off (QA gate)

| Area | Status |
|------|--------|
| Admin system health | **PASS** |
| Backend pricing (functions + tests) | **PASS** |
| Rider UI fee wiring | **CODE COMPLETE** |
| Rider no-wallet / no-withdrawal (R11) | **PASS** (static) |
| R1–R10 physical device smoke | **PENDING** — operator |
| App Store / Play Store upload | **BLOCKED** until R1–R10 **PASS** |
| Driver supply segmentation (car/bike/fleet) | **NOT STARTED** — after QA gate |

**QA rule:** Report only **FAIL** rows from R1–R10; engineering fixes **only those failures**. No new product features during this gate.

---

### A. Pre-build checklist (operator Mac)

Run from repo root: `/Users/lexemm/Projects/nexride`

```bash
flutter doctor -v
flutter --version
```

Confirm:

- [ ] Flutter stable, Xcode (iOS), Android SDK (Android) OK
- [ ] `android/app/google-services.json` → project **`nexride-8d5bc`**
- [ ] `ios/Runner/GoogleService-Info.plist` → project **`nexride-8d5bc`**
- [ ] `lib/firebase_options.dart` points at production (not staging)
- [ ] Test rider account exists in production Auth (not admin/driver)
- [ ] `android/key.properties` exists for store-signed builds (see `android/key.properties.template`)

Clean build:

```bash
cd /Users/lexemm/Projects/nexride
flutter clean
flutter pub get
cd ios && pod install && cd ..
```

---

### B. Android — release APK & AAB

**App ID:** `com.nexride.rider` · **Version:** `1.0.0+2` (from `pubspec.yaml`)

**APK** (fastest for device sideload / QA):

```bash
cd /Users/lexemm/Projects/nexride
flutter build apk --release
```

Output: `build/app/outputs/flutter-apk/app-release.apk`

**AAB** (Play Console internal testing / production track):

```bash
flutter build appbundle --release
```

Output: `build/app/outputs/bundle/release/app-release.aab`

**Install APK on connected device:**

```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Or copy APK to phone and install (enable “Install unknown apps” if needed).

**Verify release build:** no debug banner; login reaches map; Firebase project in logs is `nexride-8d5bc`.

---

### C. iOS — release / TestFlight checklist

**Bundle ID:** `com.nexride.rider`

1. Open `ios/Runner.xcworkspace` in Xcode (not `.xcodeproj`).
2. Select **Runner** → **Signing & Capabilities** → Team + distribution certificate.
3. Scheme: **Runner** · Configuration: **Release**.
4. Bump **Build** in Xcode if re-uploading same version string.
5. **Product → Archive** → **Distribute App** → App Store Connect → Upload.
6. In App Store Connect → **TestFlight** → add internal/external testers.
7. Install **TestFlight** build on device; sign in with **test rider** (production).

CLI IPA (optional, requires signing setup):

```bash
cd /Users/lexemm/Projects/nexride
flutter build ipa --release
```

Output under `build/ios/ipa/`.

---

### D. Install & test on device

| Step | Action |
|------|--------|
| 1 | Install release APK, TestFlight, or `adb install` build |
| 2 | Use a **dedicated test rider** account (production) |
| 3 | Enable location; pick a **supported service area** (same as prod rollout) |
| 4 | Keep admin portal open: https://nexride.africa/admin/live-ops |
| 5 | Optional: merchant portal for R9 |
| 6 | For card tests use Flutterwave **test/small amounts**; note tx_ref / ride_id / order_id |

**Do not** use admin or driver accounts for rider flows.

---

### E. R1–R10 operator checklist + evidence

For each row: run steps → mark **PASS** or **FAIL** in the table below → save evidence.

| # | What to do | Pass criteria | Evidence to capture |
|---|------------|---------------|---------------------|
| **R1** | Map: set pickup + dropoff, wait for route | Trip preview shows **trip fare**, **₦30 platform/booking fee**, **estimated total** | Screenshot of trip preview / breakdown card |
| **R2** | Request ride (card or bank transfer path you use in prod) | Payment or bank instruction amount = **fare + ₦30** (not fare alone) | Screenshot Flutterwave amount **or** bank-transfer chat showing total |
| **R3** | After R2 | Admin **Live ops** shows new ride; status sensible | Screenshot live-ops row + ride id note |
| **R4** | Dispatch: pickup, dropoff, package, **Send** | UI shows **delivery fare + ₦30 + total** (on form or active card) | Screenshot dispatch breakdown |
| **R5** | Complete dispatch Flutterwave | Checkout amount = **server total** (`fare + ₦30`) | Screenshot Flutterwave + delivery id |
| **R6** | After R5 | Admin live-ops shows dispatch | Screenshot live-ops |
| **R7** | Food: cart **subtotal &lt; ₦3,000**, checkout | Lines: subtotal, delivery, **₦30**, **₦15 small-order**, total; **Pay ₦X** dialog = Flutterwave | 2 screenshots (checkout + Pay dialog + Flutterwave) |
| **R8** | Food: cart **subtotal ≥ ₦3,000** | **No ₦15** line; **₦30** present; total correct | Screenshot checkout + Pay dialog |
| **R9** | Complete R7 or R8 payment → place order | Merchant receives order; admin sees merchant order | Screenshot merchant order + admin (order id) |
| **R10** | (Optional) Force stale total / retry after price change | Friendly **reload/retry** message; **no** white screen; **no** raw `FirebaseFunctionsException` text | Screenshot error snackbar/dialog |
| **R11** | Browse Profile, Payment methods, Home | **No** rider wallet balance or withdrawal screens | Screenshot menus (already **PASS** static) |

**Optional tamper for R10:** start checkout, change delivery fee in sheet without refreshing, continue — expect safe mismatch message (not crash).

---

### F. Results table (fill after device run)

| # | Scenario | Expected | PASS/FAIL | Notes / screenshot |
|---|----------|----------|-----------|-------------------|
| R1 | **Ride booking** — route preview | Trip fare, ₦30 platform/booking fee, estimated total visible | **PENDING** | |
| R2 | **Ride booking** — request + payment | Flutterwave/card/bank amount = server total (fare + ₦30); no client-only total | **PENDING** | |
| R3 | **Ride booking** — admin | Live-ops shows request; audit/payment logs sane | **PENDING** | |
| R4 | **Dispatch** — create | UI shows delivery fare + ₦30 platform + total (during/after submit) | **PENDING** | |
| R5 | **Dispatch** — payment | Flutterwave amount = `total_ngn` on delivery row | **PENDING** | |
| R6 | **Dispatch** — admin | Live-ops shows dispatch | **PENDING** | |
| R7 | **Food order** — subtotal &lt; ₦3,000 | Checkout: subtotal, delivery, ₦30 platform, ₦15 small-order, server total; Pay dialog matches | **PENDING** | |
| R8 | **Food order** — subtotal ≥ ₦3,000 | No ₦15 small-order line; ₦30 platform + correct total | **PENDING** | |
| R9 | **Food order** — E2E | Payment amount = total; merchant receives order; admin sees order | **PENDING** | |
| R10 | **pricing_total_mismatch** | Friendly retry/reload message; no crash / white screen / raw Firebase error | **PENDING** | Optional |
| R11 | **No rider wallet** | No rider wallet balance or withdrawal UI in rider app | **PASS** | Static audit 2026-05-15 |

**When reporting FAIL:** send row id (e.g. R7), device (Android/iOS), build (`1.0.0+2`), screenshot, and one-line expected vs actual. Only failed rows will be fixed.

**After all R1–R10 = PASS:** update this table, then unblock store readiness in `production_release_readiness_final.md`. Next product tranche: **Driver Supply Segmentation** (car / bike dispatch / fleet — not started).

---

## Admin portal

| # | Step | Expected | PASS/FAIL | Notes |
|---|------|----------|-----------|-------|
| 1 | Admin login | Email/password sign-in; session granted for authorized admin | | |
| 2 | Dashboard loads | `/admin/dashboard` metrics without white screen | | |
| 3 | Live ops loads | `/admin/live-ops` cards and tables populate | | |
| 4 | Audit logs load | `/admin/audit-logs` list or empty state (not error card) | | |
| 5 | Service areas load | `/admin/service-areas` region/city list | | |
| 6 | System health loads | `/admin/system-health` Infrastructure not false RED; subsystem cards: RTDB, Firestore, Auth, Storage, Functions; each shows status + latency; any RED shows `failure_reason`; Refresh works; no console errors | **PASS** | 2026-05-15 operator sign-off |

---

## Driver flow

| # | Step | Expected | PASS/FAIL | Notes |
|---|------|----------|-----------|-------|
| 7 | Driver login | Driver app reaches home | | |
| 8 | Driver goes online | `drivers/{uid}` online; mirror in `online_drivers` | | |
| 9 | Admin sees driver online | Live ops + System health show online count / heartbeat | | |

---

## Rider ride flow

| # | Step | Expected | PASS/FAIL | Notes |
|---|------|----------|-----------|-------|
| 10 | Rider login | Rider app authenticated | | |
| 11 | Rider creates ride request | `ride_requests` row; active trip pointer | | |
| 12 | Admin sees ride | Admin Trips or Live ops shows searching/active ride | | |
| 13 | Driver receives offer | Offer UI on driver device | | |
| 14 | Driver accepts | Trip status advances (accepted / arriving) | | |
| 15 | Admin sees status update | Live ops trip row bucket updates | | |
| 16 | Ride completes or cancels cleanly | Terminal state; no orphan `active_trips` | | |
| 17 | Rider payment visible | Card paid OR bank `pending_manual_confirmation` / confirmed in admin health counts | | |

---

## Merchant flow

| # | Step | Expected | PASS/FAIL | Notes |
|---|------|----------|-----------|-------|
| 18 | Merchant login | Merchant portal session | | |
| 19 | Merchant opens store | `is_open` / `orders_live` true | | |
| 20 | Admin sees merchant open | Live ops / System health merchant section | | |
| 21 | Merchant order lifecycle in admin | Order appears in live merchant orders sample | | |

---

## Finance & compliance

| # | Step | Expected | PASS/FAIL | Notes |
|---|------|----------|-----------|-------|
| 22 | Driver withdrawal in admin | Pending row in Withdrawals; health pending driver count | | |
| 23 | Merchant withdrawal in admin | Pending merchant row (no rider withdrawal) | | |
| 24 | Admin action writes audit log | Action appears in Audit logs within ~1 min | | |
| 25 | Restricted RBAC blocked | e.g. support_admin cannot approve withdrawal; UI disabled + callable forbidden | | |

---

## Cross-browser

| # | Step | Expected | PASS/FAIL | Notes |
|---|------|----------|-----------|-------|
| 26 | Chrome direct routes | `/admin/dashboard`, `/admin/live-ops`, `/admin/audit-logs`, `/admin/system-health` | | |
| 27 | Firefox same routes | No blank page; auth gate works | | |
| 28 | Mobile browser | Admin login + dashboard usable (compact shell) | | |

---

## Sign-off

| Role | Name | Date | Overall |
|------|------|------|---------|
| Ops | | | |
| Engineering | | | |

**Blockers for store upload:** Any FAIL on rows 1–6, 7–16, 22–25, rider pricing **R1–R10**, or infrastructure **red** on System health. (R11 already PASS.)
