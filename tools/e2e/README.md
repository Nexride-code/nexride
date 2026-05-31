# NexRide E2E Harness — Phase 0 + Phase 1

Local Firebase Emulator foundation only. **No production Firebase. No deploy.**

## Prerequisites

- Node.js 22+
- JDK 21+ (`brew install openjdk@21`)
- Firebase CLI (`npm i -g firebase-tools`)

## Run Phase 0

From repo root:

```bash
bash tools/e2e/run-phase0.sh
```

## Run RTDB transaction repro (namespace)

```bash
bash tools/e2e/run-rtdb-repro.sh
```

## Run Phase 1 (Ride happy path)

From repo root:

```bash
bash tools/e2e/run-phase1.sh
```

Phase 1 uses the production **prepaid hosted-checkout path**: seed a verified `payment_transactions/{tx_ref}` ride intent, then `createRideRequest({ prepaid_flutterwave_ref })`. Plain `payment_method: flutterwave` is not used (that path requires a linked saved card). No real Flutterwave calls in Phase 1.

## What Phase 0 does

1. Refuses blocked project ids (e.g. `nexride-8d5bc`)
2. Starts Auth, RTDB, Firestore, Functions emulators on `127.0.0.1`
3. Seeds E2E rider/driver + Firestore identity + Lagos rollout region
4. Smoke test: RTDB ping → seed → `createDeliveryRequest` via Functions emulator

## What Phase 1 does

1. Same emulator guardrails as Phase 0
2. Seeds ride-capable driver (car, Lagos, `supports_rides`) + verified prepaid ride intent
3. `createRideRequest({ prepaid_flutterwave_ref })` → driver offer → `acceptRide`
4. Lifecycle: `driverEnroute` → `driverArrived` → `startTrip` → `completeTrip`
5. Asserts `payment_status: paid`, pointers created then cleared, settlement ledger rows exist

## Cost

**$0** — all services run locally via Firebase Emulator Suite; no production GCP/RTDB/Auth/Functions usage.

## Project id

Always `nexride-e2e-local` (never `nexride-8d5bc`).

Emulator config lives at repo root: `firebase.e2e.json` (Firebase requires paths relative to the config file directory).

Functions params for non-interactive emulator startup:
- Template: `tools/e2e/config/functions.env.e2e`
- Secrets template: `tools/e2e/config/functions.secret.local.e2e`
- `run-phase0.sh` installs these into `nexride_driver/functions/.env` and `.secret.local` (restored on exit)

## Phase 1 troubleshooting: `prepaid_consume_tx_abort`

### `RIDER_CREATE_INPUT` timing

In production `createRideRequest`, `RIDER_CREATE_INPUT` (market/payment) is logged **before** the prepaid block merges `payment_transactions/{ref}.ride_intent`. Empty `market=(empty) payment=(empty)` on a prepaid-only body is expected.

### Root cause: RTDB namespace split (`cur_missing`)

Server logs showing `ptx_exists=true` with `databaseURL=...?ns=nexride-e2e-local` but `cur_is_null=true` inside `.transaction()` mean **get() and transaction() are not reading the same emulator namespace storage**.

The Firebase RTDB emulator loads rules on `{projectId}-default-rtdb`. Legacy `?ns={projectId}` can still return rows from `.get()` (harness seed visible to Functions preflight) while `.transaction()` evaluates against the default instance and receives `cur=null`.

**E2E fix (tools/e2e only):**

1. Harness Admin uses `?ns=nexride-e2e-local-default-rtdb` via `tools/e2e/lib/rtdb-namespace.mjs`
2. `tools/e2e/install-functions-env.sh` exports `FIREBASE_CONFIG.databaseURL` with the same `-default-rtdb` host so Functions Admin matches
3. `firebase.e2e.json` sets `"database.instance": "nexride-e2e-local-default-rtdb"`

Repro standalone:

```bash
bash tools/e2e/run-rtdb-repro.sh
```

Expect `E2E_RTDB_TX_REPRO` `default_instance.repro_pass=true` and legacy instance may fail (`get_exists=true`, `tx_cur_is_null=true`).

Phase 1 runs the repro first, then the ride happy path.

### Seed shape

Verified prepaid rows should mirror production:

1. `initiateFlutterwaveRideIntent` pending `.set()` (`verified: false`, `status: "pending"`, `intent: true`, …)
2. `persistVerifiedFlutterwaveCharge` `.update()` merge (`verified: true`, `transaction_id`, …)

See `tools/e2e/seed/seed-prepaid-ride-intent.mjs`.

### Harness diagnostics

| Log | Meaning |
|-----|---------|
| `E2E_*_RESULT` | Callable outcomes (`E2E_ACCEPT_RIDE_RESULT`, lifecycle results, …) |
| `E2E_WAIT_OFFER_OK` | Driver offer appeared |
| `E2E_SETTLEMENT_OK` | Finance settlement assertions passed |
| `E2E_PHASE1_PASS` | Full Phase 1 happy path passed |
| `E2E_PREPAID_SNAPSHOT` | Prepaid row on `createRideRequest` failure only |

### Stale emulators

If ports are in use:

```bash
pkill -f 'firebase.*emulators'
bash tools/e2e/run-phase1.sh
```
