# Flutterwave payment webhook — manual testing

Prerequisites: `FLUTTERWAVE_WEBHOOK_SECRET` and `FLUTTERWAVE_SECRET_KEY` are set as Functions secrets; webhook URL is the deployed `flutterwaveWebhook` HTTPS URL.

## 1) Health check (`event: test`)

```bash
curl -X POST "https://<YOUR_REGION>-<PROJECT>.cloudfunctions.net/flutterwaveWebhook" \
  -H "Content-Type: application/json" \
  -H "verif-hash: <FLUTTERWAVE_WEBHOOK_SECRET>" \
  -d '{"event":"test"}'
```

Expected HTTP **200** body: `{"ok":true,"message":"webhook alive"}`.

Expected logs (order):

- `WEBHOOK_RECEIVED`
- `WEBHOOK_EVENT: test`
- `WEBHOOK_HASH_OK`
- `WEBHOOK_TEST_MODE`

## 2) Simulated `charge.completed` (structure only)

Use a **real** `tx_ref` and numeric `id` from a test payment if you want verification to succeed; placeholders below will hit **`PAYMENT_VERIFY_FAIL`** after `PAYMENT_VERIFY_OK` is skipped — that is still useful to confirm parsing and hash.

```bash
curl -X POST "https://<WEBHOOK_URL>" \
  -H "Content-Type: application/json" \
  -H "verif-hash: <FLUTTERWAVE_WEBHOOK_SECRET>" \
  -d '{
    "event": "charge.completed",
    "data": {
      "id": 123456789,
      "tx_ref": "nexride_<RIDE_ID>_<SUFFIX>",
      "status": "successful",
      "amount": 1500,
      "currency": "NGN",
      "meta": { "ride_id": "<RIDE_ID>", "rider_id": "<RIDER_UID>" }
    }
  }'
```

- If Flutterwave API rejects the id → **`PAYMENT_VERIFY_FAIL`** (HTTP still **200** with body `verify-failed`).
- If verify succeeds and ride matches → **`PAYMENT_APPLY_START`** → **`PAYMENT_APPLIED`**.

## 3) Real Flutterwave checkout (recommended)

1. In the rider app (or test harness), call **`initiateFlutterwavePayment`** for a `rideId` / amount.
2. Open the returned **`authorization_url`** and complete payment with Flutterwave test card.
3. Flutterwave sends **`charge.completed`** to your webhook URL with **`verif-hash`**.
4. Backend verifies with **`GET /v3/transactions/{id}/verify`**, then writes **`payments/{transactionId}`**, updates **`ride_requests/{rideId}`** (`payment_status`, `payment_transaction_id`, `paid_at`, …), updates **`active_trips/{rideId}`** if present, and **`PAYMENT_APPLIED`** is logged.
5. Driver completes trip via **`completeTrip`**: wallet credit runs **once** with idempotency key **`{rideId}_fare_credit`** and ledger node **`driver_wallet_ledger/{driverId}/{rideId}_fare_credit`**.

## 4) Duplicate webhook

Send the same `charge.completed` payload twice (same transaction id). Second request should log **`PAYMENT_DUPLICATE_IGNORED`** and return **200** without double-updating the ride.

## 5) RTDB nodes to inspect

| Path | After successful webhook |
|------|---------------------------|
| `webhook_applied/flutterwave/{transactionId}` | Claim marker `{ applied_at, ride_id }` |
| `payments/{transactionId}` | `provider`, `status: "verified"`, `ride_id`, `tx_ref`, amounts, etc. |
| `payment_transactions/{tx_ref}` | Mirror of payment row |
| `ride_requests/{rideId}` | `payment_status: "verified"`, `payment_transaction_id`, `payment_provider`, `paid_at` |
| `active_trips/{rideId}` | Same payment fields if trip was active |
| `driver_wallet_ledger/{driverId}/{rideId}_fare_credit` | After **`completeTrip`** only (wallet credit path) |

## 6) Logs checklist

| Step | Log line |
|------|-----------|
| Request received | `WEBHOOK_RECEIVED`, `WEBHOOK_EVENT:` |
| Hash OK | `WEBHOOK_HASH_OK` |
| API verify | `PAYMENT_VERIFY_START` → `PAYMENT_VERIFY_OK` or `PAYMENT_VERIFY_FAIL` |
| Apply | `PAYMENT_APPLY_START` → `PAYMENT_APPLIED` |
| Apply exception (rare) | `PAYMENT_APPLY_FAIL` (HTTP 500, webhook claim rolled back) |
| Duplicate | `PAYMENT_DUPLICATE_IGNORED` |
| Trip complete + wallet | `WALLET_CREDITED` or `WALLET_CREDIT_DUPLICATE_IGNORED` |

## 7) `firebase functions:log`

```bash
firebase functions:log --only flutterwaveWebhook
firebase functions:log --only completeTrip
```
