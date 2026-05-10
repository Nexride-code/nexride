# NexRide Play Store pipeline — condensed summary

**Branch:** operator fills at release time  
**Firebase project:** `nexride-8d5bc`

## Artefact staging (local, not git)

Copy outputs after each release build:

- `builds/nexride_rider_release.{apk,aab}`
- `builds/nexride_driver_release.{apk,aab}`

Rebuild command pattern:

```bash
mkdir -p builds
(cd /path/to/nexride && flutter build apk --release && flutter build appbundle --release && cp build/app/outputs/flutter-apk/app-release.apk builds/nexride_rider_release.apk && cp build/app/outputs/bundle/release/app-release.aab builds/nexride_rider_release.aab)
(cd /path/to/nexride/nexride_driver && flutter build apk --release && flutter build appbundle --release && cp build/app/outputs/flutter-apk/app-release.apk ../builds/nexride_driver_release.apk && cp build/app/outputs/bundle/release/app-release.aab ../builds/nexride_driver_release.aab)
```

## Store listing payloads

Plain text + markdown under `playstore_assets/` (`*_description.txt`, `screenshot_requirements.md`, URLs, etc.) — paste into Play Console.

## Estimated readiness

| Area | Approx. weight | Notes |
|------|----------------|-------|
| **Build & versioning** | 90% | Release builds succeeded; bump `pubspec` `+BUILD` each upload |
| **Signing** | Depends on CI | Requires `android/key.properties` + keystore on build agent |
| **Play listing** | 85% | Copy ready; screenshots + feature graphic still needed |
| **Policy URLs** | 95% | Privacy/Terms on `nexride.africa`; verify domain DNS |
| **Quality / tests** | 45% | `flutter test` currently failing (see release report) |
| **App Links** | 40% | Placeholder `assetlinks.json`; needs Play SHA-256 |
| **FCM notification icon** | 60% | Dedicated `ic_stat_*` not confirmed |
| **Trip deep link in rider app** | 50% | Manifest prepared; `lib/main.dart` only handles card-link today |

**Blended “ready to upload first internal track” (binary + listing only): ~75%**  
**“Ready for production review” (tests + links + polish): ~55%** — fix tests and App Links first.
