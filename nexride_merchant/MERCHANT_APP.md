# NexRide Merchant (`nexride_merchant`)

Production-oriented Flutter application for **restaurants, grocery stores, and marts** on the shared NexRide Firebase backend. Rider and driver apps are unchanged; this package is a **standalone Android/iOS** entry point.

## Build

```bash
cd /Users/lexemm/Projects/nexride/nexride_merchant
flutter pub get
flutter build apk --release
```

**Prerequisites**

- Flutter SDK (same major line as NexRide driver app; Firebase BoM aligned to `firebase_core` ^3.8 / `cloud_functions` ^5.6).
- Android: `local.properties` with `sdk.dir` and `flutter.sdk` (template checked in; adjust paths on your machine).
- `android/app/google-services.json` — copied from the rider app for the same Firebase **project** during bootstrap. For Play Store release, register a **dedicated** Android app (`com.nexride.merchant`) in Firebase Console and replace `google-services.json` + `lib/firebase_options.dart` via FlutterFire CLI.

## Architecture summary

| Layer | Role |
| --- | --- |
| `lib/main.dart` | `Firebase.initializeApp`, `Provider` for `MerchantAppState`, `MaterialApp` + theme. |
| `lib/state/merchant_app_state.dart` | Auth snapshot + `merchantGetMyMerchant` cache, exposes `MerchantGatewayService`. |
| `lib/services/merchant_gateway_service.dart` | All HTTPS callables (`us-central1`), JSON normalization (same pattern as driver `MerchantPortalFunctions`). |
| `lib/screens/*` | UI routes: bootstrap → login / onboarding / shell; shell uses bottom navigation + pushed routes. |
| `lib/domain/merchant_order_status.dart` | Maps backend `merchant_orders` statuses to labels and legal `merchantUpdateOrderStatus` transitions. |
| `lib/theme/merchant_theme.dart` | NexRide gold / ink / canvas palette (aligned with admin/merchant portal tokens). |

**State management:** `ChangeNotifier` + `provider` (lightweight, consistent with incremental NexRide style; no new global DI framework).

**Security model:** All data access goes through **callable functions**; Firestore/RTDB writes are **not** performed directly from the merchant app except **Firebase Storage** uploads for verification files at the path prefix enforced by `merchantUploadVerificationDocument`.

## Folder structure

```
nexride_merchant/
  lib/
    main.dart
    firebase_options.dart
    domain/merchant_order_status.dart
    models/merchant_profile.dart
    services/merchant_gateway_service.dart
    state/merchant_app_state.dart
    theme/merchant_theme.dart
    widgets/nx_feedback.dart
    screens/   # login, bootstrap, shell, dashboard, orders, menu, profile, verification, support, wallet, subscription, earnings, settings
  android/     # standard Flutter Gradle (Kotlin DSL), applicationId com.nexride.merchant
  MERCHANT_APP.md
  pubspec.yaml
```

## Firebase & callables used

| Callable | Purpose |
| --- | --- |
| `merchantGetMyMerchant` | Resolve `merchantId` + profile, payment model, subscription, verification summary, optional wallet fields. |
| `merchantUpdateMerchantProfile` | Safe owner fields + rollout `region_id` / `city_id`. |
| `merchantListMyOrders` / `merchantUpdateOrderStatus` | Firestore `merchant_orders` lifecycle. |
| `merchantListMyMenu` / `merchantUpsertMenuCategory` / `merchantDeleteMenuCategory` / `merchantUpsertMenuItem` / `merchantArchiveMenuItem` | Menu management. |
| `merchantUploadVerificationDocument` / `merchantListMyVerificationDocuments` | Verification pipeline (Storage path prefix validated server-side). |
| `supportCreateTicket` | Any authenticated user; pass `merchantId` + `userType: merchant`. |
| `supportGetTicket` | Owner or staff; returns `messages` (recent thread slice). |
| `merchantListMySupportTickets` | **New** — lists tickets where `createdByUserId == uid`. |
| `merchantAppendSupportTicketMessage` | **New** — ticket owner follow-up (`role: merchant`). |

**Not used from merchant app (support staff only):** `supportListTickets`, `supportUpdateTicket`, `supportGetMerchantOrderContext` (admin/support tooling).

## Backend changes in this rollout

1. **`merchantGetMyMerchant`** — exposes optional `wallet_balance_ngn` and `withdrawable_earnings_ngn` when present on the merchant document.
2. **`supportCreateTicket`** — stores optional `user_type` on the ticket row.
3. **`supportGetTicket`** — includes recent `messages` for the ticket (capped scan of `support_ticket_messages`).
4. **`merchantListMySupportTickets`** — new export in `index.js`.
5. **`merchantAppendSupportTicketMessage`** — new export in `index.js`.

## Wallet, subscription, Flutterwave (next backend steps)

The UI includes **Wallet**, **Subscription & billing**, and **Earnings & withdrawals** with honest empty/placeholder flows where APIs are not yet exposed. Recommended **new** callables (idempotent, admin-gated where noted):

| Callable | Description |
| --- | --- |
| `merchantStartWalletTopUpFlutterwave` | Creates FW payment session; client opens checkout URL / deep link. |
| `merchantCreateBankTransferTopUp` | Creates RTDB/Firestore top-up request with `expires_at = now+30m`, returns official bank details from Remote Config. |
| `merchantAttachTopUpProof` | Upload metadata / Storage path for manual proof. |
| `merchantListWalletLedger` | Paginated ledger entries for the merchant. |
| `merchantRequestWithdrawal` | Creates withdrawal row for admin approval (reuse driver withdrawal patterns). |
| `merchantRequestPaymentModelChange` | Queue-only; admin approves (`adminUpdateMerchantPaymentModel` already exists server-side). |

## Deployment notes

1. Deploy Cloud Functions after merging `support_callables.js`, `index.js`, and `merchant_callables.js` changes.
2. Add Firebase **Storage rules** so `merchant_uploads/{merchantId}/verification/**` is writable only by the owning merchant auth uid (mirror driver patterns).
3. RTDB rules for `support_tickets` / `support_ticket_messages` must allow **read** for ticket owners for message threads if you ever read from the client (today reads are via callables only — preferred).
4. Register Android package **`com.nexride.merchant`** in Firebase and download fresh `google-services.json` before production signing.

## Security considerations

- **No secrets** in the repo beyond the shared dev `firebase_options` / `google-services` (rotate for merchant-specific apps).
- **Least privilege:** merchant callables resolve `merchantId` from `owner_uid` / contact email via `resolveMerchantForMerchantAuth` — never trust client-supplied `merchantId` for writes.
- **Support tickets:** list/get/append are **scoped to `context.auth.uid`**; staff continue to use separate admin/support surfaces.
- **Verification uploads:** callable verifies Storage object exists under the enforced prefix and size &lt; 12MB before writing Firestore metadata.

## Order status mapping (backend truth)

Backend uses: `pending_merchant`, `merchant_accepted`, `merchant_rejected`, `preparing`, `ready_for_pickup`, `dispatching`, `completed`, `cancelled`. The app labels these for staff readability; only transitions allowed by `MERCHANT_NEXT` in `merchant_commerce.js` are exposed as buttons.
