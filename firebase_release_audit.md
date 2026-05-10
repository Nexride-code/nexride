# Firebase release audit — NexRide (checklist)

**Project ID:** `nexride-8d5bc` (from `firebase.json` / Firebase options).

This document is an **operator checklist**. Items marked **[VERIFY IN CONSOLE]** must be confirmed in Firebase / Google Cloud; the repo cannot assert live console state.

---

## 1. Firebase Authentication

| Item | Expected for production | Notes |
|------|-------------------------|--------|
| **Anonymous sign-in** | **Enabled** | Required for **public trip tracking** on `https://nexride.africa/trip/...` (website reads RTDB `shared_trips/{token}` with `auth != null`). **[VERIFY IN CONSOLE]** Authentication → Sign-in method → Anonymous. |
| Email/Password, Phone | As product requires | Rider/driver apps. |
| Authorized domains | `nexride.africa`, hosting domain | **[VERIFY]** Authentication → Settings → Authorized domains. |

---

## 2. Realtime Database rules (shared trips)

Anonymous users must satisfy rules on `shared_trips/{token}` (token must match rider’s lookup). Source: `nexride_driver/database.rules.json` — **`auth != null`** and token equality check.

**Action:** Deploy rules after any change:

```bash
firebase deploy --only database
```

**[VERIFY]** RTDB simulator or staging: anonymous token + valid share token reads; invalid token denies.

---

## 3. Firebase Hosting

| Item | Status |
|------|--------|
| **Production deploy** | Run `firebase deploy --only hosting` from CI or locally after `tools/build_hosted_web.sh` |
| **Custom domain** | `nexride.africa` **[VERIFY]** in Hosting → Domains |
| **SSL** | Firebase-managed once domain verified |

**SPA rewrites:** `firebase.json` routes `/privacy`, `/terms`, `/trip/**`, etc. to `index.html`.

---

## 4. APIs & quotas

**[VERIFY IN CONSOLE]** Google Cloud APIs used by apps (Maps, Firebase, Callable Functions, etc.) are enabled and billing is acceptable for launch traffic.

---

## 5. App Check

**[VERIFY]** Firebase App Check: if enforced on Functions/RTDB, ensure **production** Flutter apps register providers (Android Play Integrity / iOS DeviceCheck) or debug builds will fail. If **not** yet enforced, document as roadmap before locking down backends.

---

## 6. Cloud Storage rules

Repo path: `storage.rules`. **[VERIFY]** No overly permissive public writes; uploads only via authenticated paths expected by dispatch/receipt flows.

---

## 7. Cloud Functions

**[VERIFY]** `nexride_driver/functions` and root `functions` deployed to production revision; secrets (Flutterwave, etc.) set via `firebase functions:config` / Secret Manager as per ops runbook—not committed.

---

## 8. Crashlytics / Analytics (optional but recommended)

**[VERIFY]** Enable for release builds; Gradle/CocoaPods configs if added.

---

## 9. FCM

**[VERIFY]** Server keys deprecated; client uses Firebase Cloud Messaging APIs. Rider/driver `google-services.json` / plist match shipped package IDs (`com.nexride.rider`, `com.nexride.driver`).

---

## Summary

Before Play production: confirm **Anonymous Auth**, **Hosting + domain**, **RTDB rules deployed**, **App Check policy**, and **no test-only API keys** in shipping flavor.
