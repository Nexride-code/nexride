# NexRide Stability E2E Trace Checklist

Automated/manual validation for the full-system stabilization pass. Each stage must pass **all** checks before proceeding.

## Trace format (required in logs)

```
[TRACE]
event=<STAGE_EVENT>
rideId=
uid=
role=rider|driver
path=
trip_state=
status=
listener_owner=
source=
elapsedMs=
```

## Global invariants (every stage)

- [ ] Exactly **one** `ride_requests/{rideId}` listener per active ride (`listener_owner` unique)
- [ ] `trip_state` is canonical: `searching|assigned|arrived|on_trip|completed|cancelled|expired`
- [ ] No client RTDB writes to `trip_state`, `driver_id`, assignment fields
- [ ] No `RTDB_PERMISSION_DENIED` for lifecycle paths
- [ ] No orphan listeners after stage teardown (`RTDB_LISTENER_DISPOSE` matches `ATTACH`)
- [ ] No `ride_missing` while `trip_state` is restorable
- [ ] Memory: listener count ≤ 30 (`RtdbResourceGuard`)

---

## 1. LOGIN

| Check | Pass |
|-------|------|
| `[TRACE] event=AUTH` logged | |
| No ride listeners attached | |

## 2. GO ONLINE (driver)

| Check | Pass |
|-------|------|
| `[TRACE] event=DRIVER_MATCH` or `RTDB_WRITE` path=`driver_locations/...` only | |
| No `ride_requests` listener | |

## 3. REQUEST RIDE

| Check | Pass |
|-------|------|
| Callable `requestRide` / `createRideRequest` succeeds | |
| `trip_state=searching` within 1 snapshot | |
| Single restore path: `SESSION_RESTORE` → `listenToRide` | |

## 4. MATCH DRIVER

| Check | Pass |
|-------|------|
| `trip_state=assigned` (not legacy `driver_assigned` in new writes) | |
| No duplicate accept authorities | |

## 5. CHAT BOTH DIRECTIONS

| Check | Pass |
|-------|------|
| `CHAT_SEND_START` → `CHAT_WRITE_OK` < 300ms | |
| `CHAT_RECEIVED` / `CHAT_RENDERED` on peer | |
| `CHAT_DUPLICATE_SKIPPED` on replay, not double render | |
| One `ride_chats/{rideId}/messages` listener | |

## 6. CALL BOTH DIRECTIONS

| Check | Pass |
|-------|------|
| Single session at `calls/{rideId}` | |
| States: `ringing` → `joined` → `ended` | |
| No root `/calls` query | |

## 7. DRIVER ARRIVED

| Check | Pass |
|-------|------|
| Callable `driverArrived` only mutation | |
| `trip_state=arrived` in < 1 snapshot | |
| No client `trip_state` write | |

## 8. START TRIP

| Check | Pass |
|-------|------|
| `trip_state=on_trip` | |
| Callable `startTrip` atomic update | |

## 9. COMPLETE TRIP

| Check | Pass |
|-------|------|
| `trip_state=completed` | |
| Pointers cleared (`rider_active_trip`, `driver_active_ride`) | |
| Listeners disposed | |

## 10. PAYMENT

| Check | Pass |
|-------|------|
| `[TRACE] event=PAYMENT` | |
| No lifecycle side effects | |

## 11. WITHDRAWAL

| Check | Pass |
|-------|------|
| `[TRACE] event=WITHDRAWAL` | |
| Wallet paths server-only | |

## 12. LOGOUT

| Check | Pass |
|------|
| All listeners disposed | |
| No stale session restore on next login | |
| Terminal rides (`cancelled|completed|expired`) never restored | |

---

## Regression signals (fail fast)

| Symptom | Likely cause |
|---------|----------------|
| Chat stuck "Sending…" | Optimistic without `CHAT_WRITE_OK` |
| `ride_missing` during active trip | Duplicate restore or stale pointer |
| Arrived UI lag | Client lifecycle mutation blocked; check CF echo |
| Thread explosion | Duplicate chat/ride listeners |
| Permission denied on `trip_state` | Client still writing lifecycle (fix client) |

## Run script

```bash
# After deploy rules + functions:
cd nexride_driver/functions && npm test
cd ../.. && flutter test test/trip_state_machine_test.dart
```
