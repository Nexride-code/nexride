# Firebase Functions params for E2E emulators

Source of truth for Phase 0 non-interactive startup:

| File | Installed to | Purpose |
|------|--------------|---------|
| `tools/e2e/config/functions.env.e2e` | `nexride_driver/functions/.env` | `defineString` + dotenv overrides |
| `tools/e2e/config/functions.secret.local.e2e` | `nexride_driver/functions/.secret.local` | `defineSecret` emulator runtime |

Installed by `tools/e2e/install-functions-env.sh` (called from `run-phase0.sh`). Original files restored on exit.

## Firebase `defineString` params (`params.js`)

| Param | Mandatory at emulator startup | Default in code | E2E value |
|-------|------------------------------|-----------------|-----------|
| `NEXRIDE_PLATFORM_FEE_NGN` | **Yes** (CLI prompts if missing from `.env`) | `30` | `30` |
| `NEXRIDE_SMALL_ORDER_FEE_NGN` | **Yes** | `15` | `15` |
| `NEXRIDE_SMALL_ORDER_THRESHOLD_NGN` | **Yes** | `3000` | `3000` |
| `FLUTTERWAVE_PUBLIC_KEY` | **Yes** | `""` | `e2e-flw-public-key` |

## Firebase `defineSecret` params (`params.js`)

Bound on various exports in `index.js`. Emulator reads from `.secret.local` (and env).

| Secret | Mandatory at startup | Required for Phase 0 smoke | E2E value |
|--------|---------------------|----------------------------|-----------|
| `FLUTTERWAVE_SECRET_KEY` | **Yes** (functions with `secrets: [...]` load) | No (create path is pending payment) | `e2e-local-dummy-secret` |
| `FLUTTERWAVE_WEBHOOK_SECRET` | **Yes** | No | `e2e-local-dummy-webhook` |
| `AGORA_APP_ID` | **Yes** | No | `e2e-agora-app-id` |
| `AGORA_APP_CERTIFICATE` | **Yes** | No | `e2e-agora-app-cert` |
| `WORKER_IDENTITY_CLAIM_PEPPER` | **Yes** | No | `e2e-local-identity-pepper` |

## Plain `process.env` (not Firebase params)

| Variable | Mandatory | Phase 0 | E2E value |
|----------|-----------|---------|-----------|
| `FLUTTERWAVE_SECRET_KEY` | Recommended | Fallback for `flutterwaveSecretForVerify()` | same as secret |
| `FLUTTERWAVE_WEBHOOK_SECRET` | Optional | Webhook tests only | dummy |
| `FLUTTERWAVE_PUBLIC_KEY` | Optional | Payment init callables | dummy public key |
| `AGORA_APP_ID` / `AGORA_APP_CERTIFICATE` | Optional | RTC callables only | dummy or empty |
| `WORKER_IDENTITY_CLAIM_PEPPER` | Optional | Identity observe callables | dummy pepper |
| `RESEND_API_KEY` / `RESEND_FROM_EMAIL` | Optional | Merchant approval email | empty |
| `NEXRIDE_RBAC_LEGACY_SUPER_EMAILS` | Optional | Admin RBAC legacy | `admin@nexride.local` |
| `AGORA_TOKEN_EXPIRE_SEC` | Optional | RTC token TTL | omit |
| `DISPATCH_VERBOSE_LOGS` | Optional | Logging | omit |

## Emulator-injected (do not set manually)

- `FIREBASE_AUTH_EMULATOR_HOST`
- `FIREBASE_DATABASE_EMULATOR_HOST`
- `FIRESTORE_EMULATOR_HOST`
- `FIREBASE_FUNCTIONS_EMULATOR_HOST`
- `GCLOUD_PROJECT` / `GOOGLE_CLOUD_PROJECT` → `nexride-e2e-local`

## Do not use in E2E

- Production project `nexride-8d5bc`
- Real Flutterwave keys
- `GOOGLE_APPLICATION_CREDENTIALS` (unset by `run-phase0.sh`)
