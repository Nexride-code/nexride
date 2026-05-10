# Deep links — post–Play Console setup

NexRide uses **Firebase Hosting** for `assetlinks.json` and **optional** Universal Links scaffolding. Rider Android manifest declares **https://nexride.africa/trip/...** and **nexride://trip** (`android/app/src/main/AndroidManifest.xml`).

---

## 1. Obtain Play App Signing certificate SHA-256

**Preferred (production App Links verification):**

1. Open [Google Play Console](https://play.google.com/) → your app → **Setup** → **App integrity**.
2. Under **Play app signing**, copy **SHA-256 certificate fingerprint** for the **app signing key** (not necessarily the upload key).

**Alternative (local upload keystore)** — only if you need fingerprint of the key you sign with locally (Play may still serve a different app signing key):

```bash
keytool -list -v -keystore /path/to/your-upload.keystore -alias YOUR_ALIAS
```

Use the **SHA256** line from the output.

---

## 2. Update `assetlinks.json`

**Source file in repo:** `website/web/.well-known/assetlinks.json` (copied to `public/.well-known/` on web build).

Replace:

```json
"REPLACE_WITH_RELEASE_SHA256_FROM_PLAY_CONSOLE_OR_KEYTOOL"
```

with the **Play App Signing** SHA-256 (format: `AA:BB:CC:...` colons included, as shown in Play Console).

Ensure `package_name` matches the **published** application id:

- Rider: `com.nexride.rider`

Rebuild web / redeploy hosting (see §4).

**Optional:** add a second `{ "relation": [...], "target": {...} }` block if you also need the **driver** package (`com.nexride.driver`) on the **same domain** paths (usually only rider needs `/trip/`).

---

## 3. Apple Universal Links (`apple-app-site-association`)

**Source:** `website/web/.well-known/apple-app-site-association`.

Replace **`TEAMID`** with your Apple Developer **Team ID** (10 characters).

Confirm **bundle ID** matches the iOS app (placeholder: `com.nexride.rider`).

Host must serve the file **without** `.json` extension, with **`Content-Type: application/json`** — already set in root `firebase.json` headers.

---

## 4. Firebase Hosting redeploy

From repo root (requires Firebase CLI logged in):

```bash
firebase deploy --only hosting
```

`predeploy` runs `tools/build_hosted_web.sh`, which rebuilds the marketing site into `public/`.

Verify live:

```text
https://nexride.africa/.well-known/assetlinks.json
https://nexride.africa/.well-known/apple-app-site-association
```

---

## 5. Verify Android App Links

1. Install release (or Play internal track) build on device.
2. Use **adb** Statement List Generator / verifier, or:

```bash
adb shell pm get-app-links com.nexride.rider
```

3. Trigger a verification reset (Android 11+ varies):

```bash
adb shell pm verify-app-links --re-verify com.nexride.rider
```

4. Open in Chrome: `https://nexride.africa/trip/TEST_RIDE_ID?token=TEST` — **Open with** should offer NexRide when verified.

**Common failures:** wrong SHA-256 (upload vs app signing), wrong package name, `assetlinks.json` not HTTPS, or JSON syntax error.

---

## 6. Verify iOS Universal Links

1. Install build from Xcode or TestFlight with **Associated Domains** capability: `applinks:nexride.africa` (exact entitlement depends on Xcode setup — must be configured in `.entitlements`; not automated in this doc).
2. Long-press or tap a **`https://nexride.africa/trip/...`** link in Notes/Mail/Safari; should jump into app if entitlement + AASA match.

**Common failures:** Team ID typo, bundle id mismatch, AASA cached (wait or reinstall), paths not matching `paths` in AASA JSON.

---

## 7. Flutter `app_links` (rider)

`lib/main.dart` currently wires **`nexride://card-link-complete`** Flutterwave completion. **`nexride://trip`** and **`https://nexride.africa/trip/...`** should be handled in-app (e.g. open map / deep link router) once product flow is finalized — manifest + Hosting are preparation; **in-app routing** must consume the URI.
