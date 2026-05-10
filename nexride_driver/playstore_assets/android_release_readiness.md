# Android release readiness (driver app)

## R8 / minify / shrink

Release builds keep **`minifyEnabled false`** and **`shrinkResources false`**.

**Reason:** The driver app bundles **Agora RTC** (voice), **Google Maps Flutter**, **geolocator** (foreground location + platform channels), and multiple **Firebase** SDKs. Enabling R8 without a dedicated keep set has caused crashes or missing classes in similar Flutter stacks (JNI, reflection, and JSON/model keep rules are easy to get wrong). We intentionally ship a larger APK/AAB until we can run device-smoke–verified release builds with a curated ProGuard ruleset.

**TODO:** Revisit after a staged rollout: add keep rules for Agora, Maps, Play services, geolocator, Firebase, and Flutter plugins; then enable minify/shrink and validate cold start, map tiles, offer flow, and calls.
