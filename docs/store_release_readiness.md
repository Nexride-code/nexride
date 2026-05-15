# NexRide store release readiness

Checklist before Apple App Store and Google Play submission. Each item: **PASS** / **FAIL** / **N/A** with evidence link or screenshot path.

---

## Firebase & configuration

| Item | PASS/FAIL | Evidence |
|------|-----------|----------|
| Production Firebase project confirmed (`nexride-8d5bc`) | | |
| Android `google-services.json` points to production | | |
| iOS `GoogleService-Info.plist` points to production | | |
| No staging API keys in release builds | | |
| Cloud Functions region `us-central1` matches client callables | | |

---

## Build & signing

| Item | PASS/FAIL | Evidence |
|------|-----------|----------|
| Android release signing configured (upload key / Play App Signing) | | |
| iOS distribution certificate + provisioning profile valid | | |
| Release mode build (`flutter build apk/appbundle` / Xcode Archive) | | |
| Version/build number bumped per store rules | | |

---

## Permissions & device behavior

| Item | PASS/FAIL | Evidence |
|------|-----------|----------|
| Push notifications verified (FCM token + foreground/background) | | |
| Location permission copy matches store declarations | | |
| Background location behavior documented and tested (driver) | | |
| Camera / photo upload verified (verification, receipts) | | |

---

## Payments & business rules

| Item | PASS/FAIL | Evidence |
|------|-----------|----------|
| Rider card payment flow verified end-to-end | | |
| Rider bank transfer + admin confirmation path verified | | |
| **No rider wallet or withdrawal UI** in production build | | |
| Driver wallet + withdrawal path verified | | |
| Merchant wallet + withdrawal path verified | | |

---

## Legal & support

| Item | PASS/FAIL | Evidence |
|------|-----------|----------|
| Privacy policy URL live and linked in app | | |
| Terms of service URL live and linked | | |
| Support / contact links open correctly | | |

---

## Branding & UX

| Item | PASS/FAIL | Evidence |
|------|-----------|----------|
| App icons (all required sizes) | | |
| Splash / launch screen | | |
| No `debug` banner in release | | |
| No raw Firebase error strings shown to end users | | |

---

## Production stability

| Item | PASS/FAIL | Evidence |
|------|-----------|----------|
| `docs/production_smoke_test.md` completed (critical rows PASS) | | |
| Admin **System health** overall green or acceptable yellow | | |
| `flutter analyze` — no errors | | |
| Backend `npm test` in `nexride_driver/functions` — pass | | |
| Crash-free smoke on physical devices (rider + driver) | | |

---

## Deploy verification

| Item | PASS/FAIL | Evidence |
|------|-----------|----------|
| Hosting deploy: https://nexride.africa/admin/ | | |
| `adminGetProductionHealthSnapshot` deployed | | |
| Hard refresh Chrome after deploy | | |

---

## Release gate

**Do not upload to App Store / Play Console until:**

1. Production smoke test sign-off (no critical FAIL).
2. System health infrastructure cards are not red.
3. RBAC restricted role spot-check passed.
4. This checklist has no unresolved FAIL in Firebase, signing, payments, or stability sections.

| Approver | Role | Date |
|----------|------|------|
| | Product / Ops | |
| | Engineering | |
