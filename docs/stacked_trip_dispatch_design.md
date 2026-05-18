# Stacked trip dispatch (design only)

**Status:** Design review required — do **not** ship stacked-trip assignment until this document, backend statuses, and integration tests are approved.

## Problem

When a driver is already on an active trip and a nearby rider requests a ride, NexRide may want to offer that trip only if the rider accepts waiting for the driver to finish the current drop-off first.

## Goals

- Show the incoming request popup to a busy driver (no silent drop).
- Ask the new rider explicitly whether they will wait.
- Assign the busy driver only after the rider accepts waiting.
- If the rider declines, continue matching other eligible drivers.
- Use structured backend statuses for observability and admin tooling.

## Non-goals (this phase)

- Full stacked-trip UX in rider/driver apps.
- Automatic multi-stop routing optimization.
- Wallet or payout changes.

## Rider experience

When dispatch targets a driver who is `on_trip` with a nearby drop-off:

1. Rider sees: **"Driver is completing a nearby drop-off first. Are you willing to wait?"**
2. Actions:
   - **I will wait** → proceed with busy-driver offer flow.
   - **Find another driver** / **Cancel this driver** → `rider_declined_wait`; re-enter matching pool.

## Driver experience

- Driver already on trip receives a normal request popup (same surface as today).
- Popup indicates this is a **stacked / wait** offer (copy TBD in implementation).
- Driver may accept only after rider confirms waiting (server-gated).

## Backend statuses

| Status | Meaning |
|--------|---------|
| `pending_driver_busy_acceptance` | Offer sent to busy driver; awaiting driver tap and rider wait consent coordination. |
| `rider_waiting_for_driver_first_drop` | Rider accepted wait; driver assigned or reserved for after first drop-off. |
| `rider_declined_wait` | Rider declined wait; offer released; matching continues for other drivers. |

Additional fields (implementation detail):

- `stacked_parent_ride_id` — active trip ride id on driver.
- `stacked_candidate_ride_id` — incoming request ride id.
- `stacked_rider_wait_decision` — `accepted` \| `declined` \| `timeout`.
- Timestamps: `stacked_offered_at`, `stacked_rider_decided_at`, `stacked_driver_decided_at`.

## Matching rules (proposed)

1. Only consider drivers with `on_trip` when drop-off is within **N km** and **M minutes** of new pickup (config in RTDB `app_config/stacked_dispatch`).
2. Rider wait prompt must complete before `assignDriver` for that driver.
3. If rider declines or times out (e.g. 90s), exclude that driver for this ride id for **T minutes**.
4. Never block the busy driver’s active trip completion flow.

## Callable / RTDB touchpoints (future)

- `offerStackedRideToBusyDriver` (internal or callable with strict auth).
- `riderRespondStackedWait` (rider callable).
- RTDB `ride_requests/{id}/stacked_dispatch` envelope.
- Admin audit log entries for each transition.

## Failure modes

| Case | Behavior |
|------|----------|
| Rider timeout | Treat as decline; continue matching. |
| Driver offline mid-wait | Release offer; notify rider; rematch. |
| First trip cancelled | Cancel stacked offer; notify waiting rider. |
| Official payment not confirmed | Do not enter stacked wait for unpaid bookings. |

## Test plan (before ship)

- Unit: status transitions and illegal transitions rejected.
- Integration: rider accept → driver assigned after drop-off marker.
- Integration: rider decline → next driver receives offer.
- Device smoke: busy driver + new rider in same market (staging only).

## Rollout

1. Merge this doc + review.
2. Implement backend statuses behind feature flag `stacked_dispatch_enabled`.
3. Add admin health counter for stuck `pending_driver_busy_acceptance`.
4. Device smoke on staging, then limited production pilot.
