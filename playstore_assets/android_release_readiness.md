# Android release readiness — NexRide Rider & Driver

### Package IDs
| App | Application ID |
|-----|----------------|
| Rider | `com.nexride.rider` |
| Driver | `com.nexride.driver` |

Configured in respective `android/app/build.gradle.kts` (`defaultConfig.applicationId`).

### Versioning
Flutter `pubspec.yaml` → `version: x.y.z+BUILD` maps to **`versionName`** + **`versionCode`**.

Current release prep uses **`1.0.0+2`** (bump **`+`** for **every Play upload**).

### Signing (release)
- Both apps use `android/key.properties` + `release` signing when `key.properties` exists.
- **Never commit:** `key.properties`, `.keystore`, `.jks` (already in `.gitignore`).
- If `key.properties` is **missing**, release build **falls back to debug signing** — OK for CI smoke tests **not** OK for Play production.

### App labels (`strings.xml`)
- Rider: `NexRide`
- Driver: `NexRide Driver`

### Launcher icons
- Flutter Launcher Icons driven from `pubspec.yaml` (`assets/branding/nexride_app_icon.png`).
- Rider: `nexride/pubspec.yaml` — run `dart run flutter_launcher_icons`.
- Driver: confirm `nexride_driver/pubspec.yaml` has equivalent if icons drift.

### Notification icon (FCM small icon)
Neither app defines a dedicated **white-transparent** notification drawable named in `AndroidManifest`; FCM defaults to launcher icon unless `meta-data`/channel icon is set elsewhere.

**Play readiness:** Add `drawable/ic_stat_nexride.xml` (vector) + reference from `FirebaseMessagingService` manifest or default notification builder per [Android notification icon guidelines](https://developer.android.com/develop/ui/views/notifications#CreateNotification).

### Proguard / minify
- **Rider:** `isMinifyEnabled = true`, `isShrinkResources = true`, Play core dependency present.
- **Driver:** minify/shrink **false** — consider enabling after R8 testing to reduce APK size.

### Firebase configs
- `google-services.json` must match package name and Firebase project (**do not commit** if policy forbids — team standard).
- Rider `GoogleService-Info.plist` / driver equivalents for future iOS.
