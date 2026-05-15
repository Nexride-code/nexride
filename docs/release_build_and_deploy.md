# NexRide — release APK build & production deploy

Monorepo root: `/Users/lexemm/Projects/nexride`  
Firebase project: **`nexride-8d5bc`**

| App | Folder | Android applicationId | APK output (after build) |
|-----|--------|----------------------|---------------------------|
| **Rider** | repo root | `com.nexride.rider` | `build/app/outputs/flutter-apk/app-release.apk` |
| **Driver** | `nexride_driver/` | `com.nexride.driver` | `nexride_driver/build/app/outputs/flutter-apk/app-release.apk` |
| **Merchant** | `nexride_merchant/` | `com.nexride.merchant` | `nexride_merchant/build/app/outputs/flutter-apk/app-release.apk` |

---

## 1. One-time prep (each machine)

```bash
cd /Users/lexemm/Projects/nexride
flutter doctor -v
```

- **Android:** SDK installed; USB debugging on test phones optional.
- **Signing:** copy `android/key.properties.template` → `android/key.properties` (and same under `nexride_driver/android/`, `nexride_merchant/android/` if you add release signing there).
- **Firebase config:** each app must use production `google-services.json` for `nexride-8d5bc`.

---

## 2. Build all three release APKs

Run each block from your Mac (not in CI unless Flutter cache is writable).

### Rider

```bash
cd /Users/lexemm/Projects/nexride
flutter clean
flutter pub get
flutter build apk --release
ls -lh build/app/outputs/flutter-apk/app-release.apk
```

### Driver

```bash
cd /Users/lexemm/Projects/nexride/nexride_driver
flutter clean
flutter pub get
flutter build apk --release
ls -lh build/app/outputs/flutter-apk/app-release.apk
```

### Merchant

```bash
cd /Users/lexemm/Projects/nexride/nexride_merchant
flutter clean
flutter pub get
flutter build apk --release
ls -lh build/app/outputs/flutter-apk/app-release.apk
```

### Install on a connected Android device

```bash
adb install -r /Users/lexemm/Projects/nexride/build/app/outputs/flutter-apk/app-release.apk
adb install -r /Users/lexemm/Projects/nexride/nexride_driver/build/app/outputs/flutter-apk/app-release.apk
adb install -r /Users/lexemm/Projects/nexride/nexride_merchant/build/app/outputs/flutter-apk/app-release.apk
```

### Play Store bundles (optional)

```bash
cd /Users/lexemm/Projects/nexride && flutter build appbundle --release
cd /Users/lexemm/Projects/nexride/nexride_driver && flutter build appbundle --release
cd /Users/lexemm/Projects/nexride/nexride_merchant && flutter build appbundle --release
```

---

## 3. Production deploy (Firebase)

All commands from **repo root** unless noted.

### Hosting (admin, support, merchant web, marketing)

Builds via predeploy script, then uploads `public/`:

```bash
cd /Users/lexemm/Projects/nexride
firebase use nexride-8d5bc
firebase deploy --only hosting
```

Admin-only rebuild (faster):

```bash
/Users/lexemm/Projects/nexride/tools/build_admin_hosting_only.sh
firebase deploy --only hosting
```

### Cloud Functions (`nexride_dispatch` codebase)

Full codebase upload (use when shared code changed):

```bash
cd /Users/lexemm/Projects/nexride
firebase deploy --only functions:nexride_dispatch
```

**Pricing / health (already deployed in stabilization — redeploy if needed):**

```bash
firebase deploy --only functions:nexride_dispatch:adminGetProductionHealthSnapshot
firebase deploy --only functions:nexride_dispatch:createRideRequest
firebase deploy --only functions:nexride_dispatch:createDeliveryRequest
firebase deploy --only functions:nexride_dispatch:initiateFlutterwavePayment
firebase deploy --only functions:nexride_dispatch:initiateFlutterwaveMerchantOrderPayment
firebase deploy --only functions:nexride_dispatch:initiateFlutterwaveRideIntent
firebase deploy --only functions:nexride_dispatch:riderPlaceMerchantOrder
```

### Firestore / RTDB / Storage rules (only when rules changed)

```bash
firebase deploy --only firestore:rules
firebase deploy --only database
firebase deploy --only storage
```

### Verify after deploy

- Admin: https://nexride.africa/admin/system-health  
- Rider device smoke: `docs/production_smoke_test.md` (R1–R10)

---

## 4. Save to GitHub

From repo root:

```bash
cd /Users/lexemm/Projects/nexride
git status
git add -A
git status   # confirm no .env*, key.properties, or APK/AAB binaries staged
git commit -m "$(cat <<'EOF'
Stabilize production pricing, admin health, and rider fee UI.

- Backend-authoritative pricing (platform + small-order fees)
- Admin system health subsystem probes
- Rider/dispatch/merchant fee breakdown UI
- Production smoke and release build docs
EOF
)"
git push origin HEAD
```

**Never commit:** `android/key.properties`, `nexride_driver/functions/.env.nexride-8d5bc`, `scripts/serviceAccountKey.json`, release `.apk` / `.aab` under `build/`.

---

## 5. QA gate reminder

- **Store upload:** blocked until rider pricing device smoke **R1–R10 PASS** (`docs/production_smoke_test.md`).
- **Driver supply segmentation** (car/bike/fleet): not started until QA gate clears.
