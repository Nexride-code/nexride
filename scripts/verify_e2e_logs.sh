#!/usr/bin/env bash
# Capture and assert NexRide E2E log patterns after manual test flow.
# Usage:
#   Terminal 1: flutter run ... 2>&1 | tee /tmp/rider.log
#   Terminal 2: cd nexride_driver && flutter run ... 2>&1 | tee /tmp/driver.log
#   Run the test flow, then: ./scripts/verify_e2e_logs.sh

set -euo pipefail

RIDER_LOG="${RIDER_LOG:-/tmp/rider.log}"
DRIVER_LOG="${DRIVER_LOG:-/tmp/driver.log}"
FILTER='SHARE_TRIP|CALL_|COMPLETE_TRIP|CANCEL|permission|ERROR'

echo "=== Filtered rider + driver logs ==="
if [[ -f "$RIDER_LOG" ]]; then
  echo "--- rider ($RIDER_LOG) ---"
  grep -E "$FILTER" "$RIDER_LOG" || true
fi
if [[ -f "$DRIVER_LOG" ]]; then
  echo "--- driver ($DRIVER_LOG) ---"
  grep -E "$FILTER" "$DRIVER_LOG" || true
fi

echo ""
echo "=== Pass / fail checks ==="
fail=0

check_absent() {
  local label="$1"
  shift
  for f in "$RIDER_LOG" "$DRIVER_LOG"; do
    [[ -f "$f" ]] || continue
    if grep -E "$@" "$f" >/dev/null 2>&1; then
      echo "FAIL: $label (found in $f)"
      fail=1
    fi
  done
}

check_present() {
  local label="$1"
  shift
  local ok=0
  for f in "$RIDER_LOG" "$DRIVER_LOG"; do
    [[ -f "$f" ]] || continue
    if grep -E "$@" "$f" >/dev/null 2>&1; then
      ok=1
    fi
  done
  if [[ "$ok" -eq 0 ]]; then
    echo "FAIL: $label (not found)"
    fail=1
  else
    echo "OK: $label"
  fi
}

check_present "SHARE_TRIP_CALLABLE_OK" 'SHARE_TRIP_CALLABLE_OK'
check_present "SHARE_TRIP_URL" 'SHARE_TRIP_URL'
check_present "SHARE_TRIP_SHEET_OPENED" 'SHARE_TRIP_SHEET_OPENED'
check_absent "no SHARE_TRIP_RTDB_WRITE_FAIL" 'SHARE_TRIP_RTDB_WRITE_FAIL'
check_absent "no sharePositionOrigin error" 'sharePositionOrigin'
check_absent "no share permission-denied" 'SHARE_TRIP.*permission-denied'

check_present "CALL_JOIN_OK driver" 'CALL_JOIN_OK.*role=driver'
check_present "CALL_JOIN_OK rider" 'CALL_JOIN_OK.*role=rider'
check_present "CALL_END_RTDB_OK" 'CALL_END_RTDB_OK'
check_present "CALL_REMOTE_ENDED_RECEIVED" 'CALL_REMOTE_ENDED_RECEIVED'
check_present "COMPLETE_TRIP_SUCCESS" 'COMPLETE_TRIP_SUCCESS'
check_present "COMPLETE_TRIP_VERIFY completed" 'COMPLETE_TRIP_VERIFY_STATE.*trip_state=completed'

check_absent "no driver_cancelled on complete" 'driver_cancelled'
check_absent "no no_route_logs cancel" 'cancel_reason=no_route_logs'
check_absent "no setup null cleanup" 'call_snapshot_null'
check_absent "no rtdb_null_or_unparseable" 'rtdb_null_or_unparseable'

# Callable should run at most once per ride (heuristic: count START)
if [[ -f "$RIDER_LOG" ]]; then
  starts=$(grep -c 'SHARE_TRIP_CALLABLE_START' "$RIDER_LOG" 2>/dev/null || echo 0)
  if [[ "$starts" -gt 2 ]]; then
    echo "WARN: SHARE_TRIP_CALLABLE_START count=$starts (expect 1-2 for retaps after cache clear)"
  else
    echo "OK: SHARE_TRIP_CALLABLE_START count=$starts"
  fi
fi

if [[ "$fail" -eq 0 ]]; then
  echo ""
  echo "ALL CHECKS PASSED"
  exit 0
fi
echo ""
echo "SOME CHECKS FAILED"
exit 1
