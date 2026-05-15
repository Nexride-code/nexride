# Admin snapshot elimination — migration inventory

**Policy:** `AdminDataService.fetchSnapshot()` is **legacy compatibility only**. New admin work must use **HTTPS callables**, **cursor pagination**, and **lazy detail** loads. Do not add `Future.wait` over large RTDB roots from Flutter admin.

## SECTION | CURRENT SOURCE | TARGET CALLABLE / LOADER | STATUS

| Section | Current source | Target | Status |
|---------|----------------|--------|--------|
| Dashboard (`/admin`) | `fetchDashboardSnapshot` → `adminGetOperationsDashboard` | same | **DONE** |
| Drivers (`/admin/drivers`) | `fetchDriversPageForAdmin` / `adminListDriversPage` (+ profile callable) | same | **DONE** |
| Riders (`/admin/riders`) | Was `fetchSnapshot` on cold start; now `fetchRidersPageForAdmin` | `adminListRidersPage` | **DONE** (init uses paged loader) |
| Withdrawals | `fetchWithdrawalsPageForAdmin` | `adminListWithdrawalsPage` | **DONE** |
| Support inbox | `fetchSupportTicketsPageForAdmin` + detail | `adminListSupportTicketsPage` / `adminGetSupportTicket` | **DONE** |
| Trips (`/admin/trips`) | Live: `adminListLiveTrips`; Browse: `fetchTripsPageForAdmin` | `adminListTripsPage` + `adminGetTripDetail` | **PARTIAL** (no full trip tree in browser; legacy snapshot still builds trips elsewhere if loaded) |
| Merchants (`/admin/merchants`) | `adminListMerchantsPage` + `adminGetMerchantProfile` | same | **DONE** |
| Finance (`/admin/finance`) | `fetchDashboardSnapshot` (lite `AdminPanelSnapshot`) | Rich finance aggregates callable (TBD) | **TBD** |
| Pricing (`/admin/pricing`) | `fetchSnapshot` → `app_config` embedded in monolith | `adminGetPricingConfig` / dedicated app_config callable + no driver fan-out in browser | **TBD** |
| Subscriptions (`/admin/subscriptions`) | `fetchSnapshot` → `subscriptions` from monolith | `adminListSubscriptionRequestsPage` (TBD) + row refresh | **TBD** |
| Verification (`/admin/verification`) | Screen-local / future snapshot hooks | `adminListIdentityVerifications` + review callables | **TBD** |
| Settings (`/admin/settings`) | `fetchSnapshot` | Narrow settings callable or per-field RTDB reads (TBD) | **TBD** |
| Regions (`/admin/regions`) | Screen-local | callable-backed (verify) | **REVIEW** |

## `fetchSnapshot()` / `_loadSnapshot()` callsites (admin_panel_screen)

| Location | Section / trigger | Notes |
|----------|-------------------|--------|
| `initState` `else` | Pricing, subscriptions, verification, settings (only sections not handled above) | **LEGACY** — remove as each section gets a loader |
| `_refresh` default branch | Any section not explicitly listed | **LEGACY** |
| `_refresh` drivers/riders branches | When `_snapshot != null` and paged list null | **LEGACY** hybrid; migrate to always-paged |
| `_buildSubscriptionsTab` Retry | Subscriptions error UI | **LEGACY** |
| `_PricingEditor.onSave` after `updatePricingConfig` | Pricing | **LEGACY** — should refresh pricing slice only + server-side driver sync (Phase 2C) |
| Subscription approve/reject | Subscriptions | **LEGACY** — should reload pending queue only |

## `fetchSnapshot()` implementation (admin_data_service)

- Performs `Future.wait` of many `_rootRef.child(<node>).get()` calls (`users`, `ride_requests`, `withdraw_requests`, `wallets`, …).
- **Must not** be extended; new metrics belong in callables or aggregate endpoints.

## Phase 2B — split `AdminPanelSnapshot` (planned types)

Target decomposition (incremental; types may live in `admin_models.dart` or `lib/admin/state/`):

- `DashboardSnapshot` — metrics + trend/finance slices used by dashboard/finance shell
- `DriverListState` — paged drivers + cursors (already partially modeled as list fields + loaders in UI)
- `RiderListState` — paged riders
- `MerchantListState` — merchant list rows + filters
- `TripListState` — paged trips / live ops buckets
- `WithdrawalListState` — paged withdrawals
- `SupportTicketListState` — paged tickets

Until split is complete, `AdminPanelSnapshot` remains the compatibility carrier for pricing/subscriptions/settings.

## Phase 2C — server-side heavy work (pricing, payouts, …)

- **Pricing driver fan-out:** move off browser entirely (`adminApplyAppConfigPricing…` callable or scheduled job). Client must orchestrate only.
- **Payout reconciliation / commission recompute:** callable or backend job only.
