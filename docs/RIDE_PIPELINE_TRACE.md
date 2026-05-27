# Ride Pipeline End-to-End Trace

Single canonical node: `ride_requests/{rideId}`  
Canonical lifecycle: `trip_state` ∈ `searching|assigned|arrived|on_trip|completed|cancelled|expired`

## Per-stage trace fields

At each stage log:

```
[TRACE]
event=<STAGE>
rideId=
uid=
role=rider|driver
path=
trip_state=
listener_owner=
source=
elapsedMs=
pipeline=<RidePipelineGuard.snapshot()>
```

## Stages

| Stage | event | Expected path | Max listeners |
|-------|-------|---------------|---------------|
| LOGIN | AUTH | — | 0 ride |
| GO ONLINE | DRIVER_ONLINE | `drivers/{uid}` | 0 ride |
| REQUEST RIDE | RIDE_REQUEST | `ride_requests/{id}` (CF write) | 1 ride |
| MATCH | DRIVER_MATCH | `ride_requests/{id}` | 1 ride |
| CHAT | CHAT_* | `ride_chats/{id}/messages` | 1 chat |
| CALL | CALL_* | `calls/{id}` | 1 call |
| ARRIVED | DRIVER_ARRIVED | `ride_requests/{id}/trip_state=arrived` | 1 ride |
| START TRIP | START_TRIP | `trip_state=on_trip` | 1 ride |
| COMPLETE | COMPLETE_TRIP | `trip_state=completed` | 0 ride |
| PAYMENT | PAYMENT | `payment_transactions/*` | — |
| WITHDRAWAL | WITHDRAWAL | wallet CF | — |
| LOGOUT | AUTH_LOGOUT | listeners disposed | 0 |

## Invariants

- Pointers (`rider_active_trip`, `driver_active_ride`) contain **only** `ride_id` + `updated_at`
- UI never writes `trip_state`, `status`, assignment fields
- Arrived UI: `trip_state == arrived` only
- Chat: append via `onChildAdded` / `onChildChanged` — no full-snapshot hash skip
- Debug: duplicate ride listener triggers `assert` in `RidePipelineGuard`
