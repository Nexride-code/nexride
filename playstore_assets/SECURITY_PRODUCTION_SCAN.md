# Production security string scan (automated pass)

**Scope:** Dart/JS/JSON/XML/kts in repo (January 2026 pass). Third-party `node_modules/**`, `**/NOTICES`, and large vendored dirs excluded from remediation.

## Findings (intentionally left)

| Pattern | Occurrence | Action |
|---------|-------------|--------|
| `localhost` / `127.0.0.1` | `nexride_driver/test/admin_app_test.dart` (URLs for web tests), `firebase.json` emulators (`127.0.0.1`) | **Keep** — test / local dev only, not shipped in APK. |
| `TODO` / `FIXME` | Scattered in app code historically (not exhaustive in this run) | Track in backlog; none forced-edited during release prep without product review. |
| Google Maps keys in **`AndroidManifest.xml`** | Rider uses manifest meta-data placeholder; real key typically from CI `local.properties` / env | Confirm **restricted API key** + package fingerprint in GCP. |
| **Road route tests** (`test/services/road_route_service_test.dart`) | Logs include **Directions API key shape** used in fixtures | Recommend **restrict keys** server-side & avoid committing **new** unrestricted keys; tests are dev-only artifacts. |

## Cleared previously

| Pattern | Status |
|---------|--------|
| `nexrideinfo@gmail.com` / legacy NexRide Gmail branding | Removed from product/scripts in prior commits. |
| Official contact | `*.nexride.africa` in website + support copy. |

## Not searched / manual

- **Play Console** access, **keystore** custody, **Stripe/Flutterwave** server secrets (must stay in Secret Manager / env).

