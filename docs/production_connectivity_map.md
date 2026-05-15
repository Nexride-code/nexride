# NexRide production connectivity map

Store-readiness reference: how each actor’s UI reaches backend state and where admins observe it.

**Business rule:** Riders pay by linked card or bank transfer only — no rider wallets or withdrawals. Driver and merchant wallets support withdrawals.

---

## Rider

| Flow | Client source | Callable / API | RTDB / Firestore | Admin surface | Latency (typical) | Failure codes | Manual test |
|------|---------------|----------------|------------------|---------------|-------------------|---------------|-------------|
| Profile | Rider app profile screens | Auth + Firestore profile reads | `users/{uid}`, Firestore `users/{uid}` | Admin → Riders → profile drawer | 1–3s | `unauthorized`, `not_found` | Sign in as rider; open profile; confirm in admin rider detail |
| Service area | Service area picker | Rollout / geo validation callables | `delivery_regions/{region}/cities/{city}` | Admin → Service areas | 1–2s | `service_area_unsupported`, `no_service_area_for_pickup` | Select city; request ride from pickup inside area |
| Ride request | Request ride UI | `createRideRequest` (ride callables) | `ride_requests/{id}`, `active_trips/{id}` | Admin → Trips / Live ops | 2–8s | `payment_required`, `service_area_unsupported` | Create ride; see row in admin live trips |
| Food / store discovery | Discovery / merchant list | Merchant catalog callables | Firestore `merchants`, RTDB teasers | Admin → Merchants | 2–5s | `merchant_closed`, `region_not_live` | Browse stores in rider app |
| Food order | Checkout | Order + payment callables | `merchant_orders/{id}` | Admin → Live ops merchant orders | 3–10s | `payment_failed`, `merchant_unavailable` | Place order; confirm in admin |
| Linked card payment | Card checkout | Payment init / verify callables | `ride_requests` / order `payment_status` | Admin → System health (failed card count), Finance | 5–30s | `payment_init_failed`, `failed` | Pay with card; confirm `payment_status` not `failed` |
| Bank transfer confirmation | Bank transfer UI + receipt upload | `updateRidePayment` / bank flow | `payment_status: pending_manual_confirmation` | Admin → System health; `adminConfirmBankTransferPayment` | Minutes–hours | `pending_manual_confirmation` | Upload receipt; admin confirms |
| Support | Support screen | Support ticket callables | `support_tickets/{id}` | Admin → Support | 2–5s | `invalid_ticket` | Open ticket; see in admin inbox |
| Suspension / warning received | In-app banner | Push + RTDB user flags | `users/{uid}/warnings`, account flags | Admin → Riders (actions) | Real-time–minutes | `user_disabled`, `trips_blocked` | Admin warns rider; rider sees message |

---

## Driver

| Flow | Client source | Callable / API | RTDB / Firestore | Admin surface | Latency | Failure codes | Manual test |
|------|---------------|----------------|------------------|---------------|---------|---------------|-------------|
| Login / bootstrap | Auth + driver bootstrap | Auth, driver profile | `drivers/{uid}` | Admin → Drivers | 2–5s | `user-disabled` | Driver signs in |
| Verification | Verification wizard | Verification upload callables | `driver_verifications/{uid}`, Firestore `identity_verifications` | Admin → Verification | Minutes | `verification_pending` | Submit docs; approve in admin |
| Online / offline | Go online toggle | Availability callables | `drivers/{uid}.online`, `online_drivers/{uid}` | Admin → Live ops / System health | 1–3s | `subscription_required` | Toggle online; admin sees online count |
| GPS / service-area mode | Mode selector | Dispatch gates | `drivers/{uid}.online_availability_mode` | Admin → Live ops drivers table | 1–2s | `location_permission_denied` | Switch GPS vs service area |
| Trip offers | Offer modal | Dispatch / offer RTDB | `driver_offers/{uid}`, offer queue | Admin → Trips | Sub-second–5s | `offer_expired` | Driver online; rider requests |
| Active trip | Trip screen | Trip state callables | `active_trips/{id}`, `ride_requests/{id}` | Admin → Trips live | Real-time | `stale_trip_state` | Accept and progress trip |
| Wallet | Wallet screen | Wallet read paths | `drivers/{uid}/wallet` (pattern) | Admin → Driver drawer → wallet | 2–4s | `insufficient_balance` | View balance after trip |
| Withdrawal destination | Payout settings | Destination save callables | Withdrawal account on driver profile | Admin → Withdrawals list | 2–5s | `invalid_account` | Save bank details |
| Withdrawal request | Withdraw CTA | `requestWithdrawal` flow | `withdraw_requests/{id}` `entity_type: driver` | Admin → Withdrawals; System health | 2–5s | `missing_destination` | Request payout; appears pending |
| Suspension / force offline | Push + flags | Admin `adminForceDriverOffline`, warn | `drivers/{uid}`, notifications | Admin → Drivers actions | Seconds | `driver_suspended` | Admin force offline; driver dropped |

---

## Merchant

| Flow | Client source | Callable / API | RTDB / Firestore | Admin surface | Latency | Failure codes | Manual test |
|------|---------------|----------------|------------------|---------------|---------|---------------|-------------|
| Onboarding / profile | Merchant portal | Merchant callables | Firestore `merchants/{id}` | Admin → Merchants | 3–10s | `merchant_not_found` | Complete onboarding |
| Verification | KYC screens | Merchant verification | Firestore merchant fields | Admin → Merchants / Verification | Minutes | `verification_pending` | Submit; review in admin |
| Open / closed / orders_live | Store toggle | `merchantUpdateAvailability` | `merchants/{id}.is_open`, `orders_live` | Admin → Live ops / System health | 1–3s | `merchant_closed` | Open store; admin sees open + orders_live |
| Catalog | Menu management | Catalog callables | Firestore products / menu | Admin → Merchants detail | 2–8s | `catalog_empty` | Add item; visible to rider |
| Order lifecycle | Orders inbox | Order status callables | `merchant_orders/{id}` | Admin → Live ops merchant orders | Real-time | `invalid_transition` | Accept → prepare → ready |
| Wallet / topups | Wallet UI | `merchant_wallet` | Merchant wallet docs | Admin → Merchants / Finance | 2–5s | `payment_init_failed` | Top up wallet |
| Withdrawal request | Payout UI | Merchant withdrawal | `withdraw_requests` `entity_type: merchant` | Admin → Withdrawals; System health | 2–5s | `missing_destination` | Request withdrawal |
| Admin notes / warnings | N/A (receive) | Admin write callables | Merchant doc + audit | Admin → Merchants | Seconds | `forbidden` | Post admin note; merchant notified |

---

## Admin

| Area | Route | Primary callable(s) | Permission |
|------|-------|---------------------|------------|
| Dashboard | `/admin/dashboard` | `adminGetOperationsDashboard` | `dashboard.read` |
| Live ops | `/admin/live-ops` | `adminGetLiveOperationsDashboard` | `trips.read` |
| System health | `/admin/system-health` | `adminGetProductionHealthSnapshot` | `dashboard.read` |
| Audit logs | `/admin/audit-logs` | `adminListAuditLogs` | `audit_logs.read` |
| Service areas | `/admin/service-areas` | `adminListServiceAreas`, upsert/enable | `service_areas.read` / `.write` |
| Verification | `/admin/verification` | Verification center callables | `verification.read` |
| Withdrawals | `/admin/withdrawals` | `adminListWithdrawalsPage`, `approveWithdrawal` | `withdrawals.read` / `.approve` |
| Merchants | `/admin/merchants` | Merchant admin callables | `merchants.read` |
| Support | `/admin/support` | Support ticket callables | `support.read` |

**Health snapshot** aggregates infrastructure probes, live driver/merchant heartbeats, rider **payment** issues (not wallets), withdrawal queues (driver + merchant only), verifications, support backlog, and service-area configuration warnings.

---

## Observability

- Callable denials: `ADMIN_CALL_DENIED` / `*_rbac_denied` logs with `required_permission`.
- Health UI: visible error card + Retry on callable failure (no blank page).
- Structured failure: `{ success: false, reason_code, message, retryable }` for health when live dashboard sub-call fails.
