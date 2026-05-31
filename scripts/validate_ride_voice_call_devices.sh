#!/usr/bin/env bash
# Real-device ride voice call validation helper (rider + driver builds).
# Does not mutate dispatch/matching/payment — inspects logs + RTDB call node only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RTDB="${RTDB:-https://nexride-8d5bc-default-rtdb.firebaseio.com}"
LOG_DIR="${CALL_VALIDATION_LOG_DIR:-/tmp/nexride_call_validation_$(date +%Y%m%d_%H%M%S)}"

marker_pattern() {
  case "$1" in
    CALL_START) echo 'CALL_START_TAP|RIDE_CALL_START|\[CALL_START\]' ;;
    CALL_INCOMING) echo 'CALL_INCOMING_RECEIVED' ;;
    CALL_ACCEPT) echo 'CALL_ACCEPT_TAP' ;;
    CALL_JOIN_START) echo 'CALL_JOIN_START' ;;
    CALL_JOIN_OK) echo 'CALL_JOIN_OK' ;;
    CALL_REMOTE_JOINED) echo 'CALL_REMOTE_JOINED' ;;
    CALL_END_TAP) echo 'CALL_END_TAP' ;;
    CALL_END_LOCAL_CLEANUP_OK) echo 'CALL_END_LOCAL_CLEANUP_OK' ;;
    CALL_END_RTDB_OK) echo 'CALL_END_RTDB_OK' ;;
    *) echo "$1" ;;
  esac
}

count_marker() {
  local logfile="$1"
  local role_filter="$2"
  local pattern="$3"
  if [[ "$role_filter" == "both" ]]; then
    grep -E "$pattern" "$logfile" 2>/dev/null | wc -l | tr -d ' '
  else
    grep -E "$pattern" "$logfile" 2>/dev/null | grep -F "role=$role_filter" | wc -l | tr -d ' '
  fi
}

report_marker_line() {
  local label="$1"
  local logfile="$2"
  local role="$3"
  local pattern
  pattern="$(marker_pattern "$label")"
  local hits
  hits="$(count_marker "$logfile" "$role" "$pattern")"
  if [[ "$hits" == "0" ]]; then
    echo "  MISSING  $label"
    return 1
  fi
  echo "  OK       $label  count=$hits"
  return 0
}

failure_markers() {
  local logfile="$1"
  echo "--- failure markers ---"
  grep -E 'CALL_JOIN_FAIL|CALL_JOIN_TIMEOUT|CALL_TOKEN_INVALID|call_already_active|RIDE_CALL_TOKEN_FAIL' "$logfile" 2>/dev/null | tail -5 || echo "(none)"
}

usage() {
  cat <<'EOF'
Usage:
  bash scripts/validate_ride_voice_call_devices.sh matrix
  bash scripts/validate_ride_voice_call_devices.sh log-help
  bash scripts/validate_ride_voice_call_devices.sh grep-markers <logfile> [role=rider|driver|both]
  bash scripts/validate_ride_voice_call_devices.sh check-rtdb <rideId> [authToken]
  bash scripts/validate_ride_voice_call_devices.sh summarize-scenario <1|2|3|4> <rider_log> <driver_log> <rideId> [authToken]
  bash scripts/validate_ride_voice_call_devices.sh record <scenario_name> <logfile>

Env (optional):
  E2E_RIDE_ID, E2E_RIDER_TOKEN — from scripts/e2e_accepted_ride_chat.sh output env.sh
  RTDB — default production RTDB URL above
  CALL_VALIDATION_LOG_DIR — where scenario logs are copied

Device test matrix (run manually on two physical devices):
  1 rider calls driver, rider ends
  2 rider calls driver, driver ends
  3 driver calls rider, driver ends
  4 driver calls rider, rider ends

After each scenario:
  1. grep-markers on rider + driver log captures
  2. check-rtdb — calls/{rideId} must be terminal (ended|declined|cancelled|missed) or absent
  3. Both apps must show no stuck call overlay
EOF
}

print_matrix() {
  cat <<'EOF'
=== Ride voice call — real device validation matrix ===

Prerequisites:
  - Rider + driver debug/release builds from dispatch-stabilization-phase2 (eca6118+)
  - Active assigned ride (accept complete); chat tab reachable on both devices
  - Microphone permission granted on both devices
  - Optional seed: bash scripts/e2e_accepted_ride_chat.sh && source /tmp/nexride_e2e_*/env.sh

Capture logs while testing:
  Android rider:  adb logcat -c && adb logcat -v time | tee /tmp/call-rider.log
  Android driver: adb -s <driver_serial> logcat ... | tee /tmp/call-driver.log
  iOS: Xcode console or: flutter logs (filter CALL_)

--- Scenario 1: Rider calls, driver accepts, rider ends ---
--- Scenario 2: Rider calls, driver accepts, driver ends ---
--- Scenario 3: Driver calls, rider accepts, driver ends ---
--- Scenario 4: Driver calls, rider accepts, rider ends ---

Post-scenario RTDB (must not stay ringing/accepted):
  bash scripts/validate_ride_voice_call_devices.sh check-rtdb "$E2E_RIDE_ID" "$E2E_RIDER_TOKEN"

Failure signals to watch:
  CALL_JOIN_FAIL, CALL_JOIN_TIMEOUT, CALL_TOKEN_INVALID, call_already_active
  Stuck UI after CALL_END_LOCAL_CLEANUP_OK missing on either device
  calls/{rideId}.status in {ringing, accepted} after hangup
EOF
}

log_help() {
  cat <<'EOF'
=== Log capture ===

Unified grep (after saving device logs):
  grep -E 'CALL_START_TAP|CALL_INCOMING_RECEIVED|CALL_ACCEPT_TAP|CALL_JOIN_START|CALL_JOIN_OK|CALL_REMOTE_JOINED|CALL_END_TAP|CALL_END_LOCAL_CLEANUP_OK|CALL_END_RTDB_OK|CALL_JOIN_FAIL|CALL_JOIN_TIMEOUT|CALL_TOKEN_INVALID|\[RideCall\]|RIDE_CALL_' your.log

Android (single device):
  adb logcat -c
  adb logcat -v time Flutter:V agora:V '*:S' | tee /tmp/call-device.log

Android (two serials):
  adb -s RIDER_SERIAL logcat ... | tee /tmp/call-rider.log &
  adb -s DRIVER_SERIAL logcat ... | tee /tmp/call-driver.log &

Flutter attached:
  flutter logs 2>&1 | tee /tmp/call-flutter.log

Functions (token / stale clear):
  firebase functions:log --only getRideCallRtcToken,clearStaleRideCall
  Look for: CALL_TOKEN_BUILD, CALL_RECORD_CLEARED, CALL_RECORD_JOIN_ALLOWED
EOF
}

grep_markers() {
  local logfile="${1:?logfile required}"
  local role_filter="${2:-both}"
  if [[ ! -f "$logfile" ]]; then
    echo "missing log file: $logfile" >&2
    exit 1
  fi

  echo "=== Marker report: $logfile (filter=$role_filter) ==="
  local missing=0
  for marker in CALL_START CALL_INCOMING CALL_ACCEPT CALL_JOIN_START CALL_JOIN_OK CALL_REMOTE_JOINED CALL_END_TAP CALL_END_LOCAL_CLEANUP_OK CALL_END_RTDB_OK; do
    pattern="$(marker_pattern "$marker")"
    local hits
    hits="$(count_marker "$logfile" "$role_filter" "$pattern")"
    if [[ "$hits" == "0" ]]; then
      echo "MISSING  $marker  (pattern: $pattern)"
      missing=$((missing + 1))
    else
      echo "OK       $marker  count=$hits"
      if [[ "$role_filter" == "both" ]]; then
        grep -E "$pattern" "$logfile" 2>/dev/null | head -2
      else
        grep -E "$pattern" "$logfile" 2>/dev/null | grep -F "role=$role_filter" | head -2
      fi
    fi
  done

  failure_markers "$logfile"

  if [[ "$missing" -gt 0 ]]; then
    echo "RESULT: INCOMPLETE ($missing expected markers missing)"
    return 1
  fi
  echo "RESULT: all expected markers present in log"
}

check_rtdb() {
  local ride_id="${1:?rideId required}"
  local token="${2:-${E2E_RIDER_TOKEN:-}}"
  local url="${RTDB}/calls/${ride_id}.json"
  if [[ -n "$token" ]]; then
    url="${url}?auth=${token}"
  fi

  echo "=== RTDB calls/${ride_id} ==="
  local body
  body=$(curl -sS "$url")
  echo "$body" | python3 -m json.tool 2>/dev/null || echo "$body"

  python3 - <<'PY' "$body"
import json, sys
raw = sys.argv[1].strip()
if raw in ("null", ""):
    print("RTDB_CALL_NODE: absent (OK if cleanup removed node)")
    sys.exit(0)
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    print("RTDB_CALL_NODE: unreadable response")
    sys.exit(1)
if not isinstance(data, dict):
    print("RTDB_CALL_NODE: unexpected shape")
    sys.exit(1)
status = str(data.get("status", "")).strip().lower()
terminal = {"ended", "declined", "cancelled", "missed", "failed"}
print(f"RTDB_CALL_STATUS: {status or '(empty)'}")
if status in terminal:
    print("RTDB_CALL_CHECK: PASS (terminal)")
    sys.exit(0)
if status in {"ringing", "calling", "accepted", "joined"}:
    print("RTDB_CALL_CHECK: FAIL (stuck active call node)")
    sys.exit(2)
print("RTDB_CALL_CHECK: WARN (unknown status — inspect manually)")
PY
}

record_scenario() {
  local name="${1:?scenario name}"
  local logfile="${2:?logfile}"
  mkdir -p "$LOG_DIR"
  local dest="$LOG_DIR/${name}-$(basename "$logfile")"
  cp "$logfile" "$dest"
  echo "Recorded $dest"
  grep_markers "$dest" both || true
}

# Role-specific required markers per scenario (caller/callee/end-er nuances).
summarize_scenario() {
  local scenario="${1:?scenario 1-4}"
  local rider_log="${2:?rider log}"
  local driver_log="${3:?driver log}"
  local ride_id="${4:?rideId}"
  local token="${5:-${E2E_RIDER_TOKEN:-}}"

  local title=""
  local end_role=""
  case "$scenario" in
    1) title="Rider calls → driver accepts → rider ends"; end_role="rider" ;;
    2) title="Rider calls → driver accepts → driver ends"; end_role="driver" ;;
    3) title="Driver calls → rider accepts → driver ends"; end_role="driver" ;;
    4) title="Driver calls → rider accepts → rider ends"; end_role="rider" ;;
    *) echo "scenario must be 1-4" >&2; exit 1 ;;
  esac

  echo "========== Scenario $scenario: $title =========="
  echo "rideId=$ride_id"
  echo ""
  echo "RIDER LOG: $rider_log"
  local rider_missing=0
  case "$scenario" in
    1|2)
      for m in CALL_START CALL_JOIN_START CALL_JOIN_OK CALL_REMOTE_JOINED CALL_END_LOCAL_CLEANUP_OK CALL_END_RTDB_OK; do
        report_marker_line "$m" "$rider_log" rider || rider_missing=$((rider_missing + 1))
      done
      if [[ "$end_role" == "rider" ]]; then
        report_marker_line CALL_END_TAP "$rider_log" rider || rider_missing=$((rider_missing + 1))
      fi
      ;;
    3|4)
      for m in CALL_INCOMING CALL_ACCEPT CALL_JOIN_START CALL_JOIN_OK CALL_REMOTE_JOINED CALL_END_LOCAL_CLEANUP_OK CALL_END_RTDB_OK; do
        report_marker_line "$m" "$rider_log" rider || rider_missing=$((rider_missing + 1))
      done
      if [[ "$end_role" == "rider" ]]; then
        report_marker_line CALL_END_TAP "$rider_log" rider || rider_missing=$((rider_missing + 1))
      fi
      ;;
  esac
  failure_markers "$rider_log"
  echo ""
  echo "DRIVER LOG: $driver_log"
  local driver_missing=0
  case "$scenario" in
    1|2)
      for m in CALL_INCOMING CALL_ACCEPT CALL_JOIN_START CALL_JOIN_OK CALL_REMOTE_JOINED CALL_END_LOCAL_CLEANUP_OK CALL_END_RTDB_OK; do
        report_marker_line "$m" "$driver_log" driver || driver_missing=$((driver_missing + 1))
      done
      if [[ "$end_role" == "driver" ]]; then
        report_marker_line CALL_END_TAP "$driver_log" driver || driver_missing=$((driver_missing + 1))
      fi
      ;;
    3|4)
      for m in CALL_START CALL_JOIN_START CALL_JOIN_OK CALL_REMOTE_JOINED CALL_END_LOCAL_CLEANUP_OK CALL_END_RTDB_OK; do
        report_marker_line "$m" "$driver_log" driver || driver_missing=$((driver_missing + 1))
      done
      if [[ "$end_role" == "driver" ]]; then
        report_marker_line CALL_END_TAP "$driver_log" driver || driver_missing=$((driver_missing + 1))
      fi
      ;;
  esac
  failure_markers "$driver_log"
  echo ""
  check_rtdb "$ride_id" "$token" || true
  echo ""
  echo "MANUAL (record after test):"
  echo "  two_way_audio: yes|no"
  echo "  stuck_ui: none|rider|driver|both"
  echo ""
  if [[ "$rider_missing" -eq 0 && "$driver_missing" -eq 0 ]]; then
    echo "SCENARIO_${scenario}_MARKERS: PASS"
  else
    echo "SCENARIO_${scenario}_MARKERS: FAIL (rider_missing=$rider_missing driver_missing=$driver_missing)"
    return 1
  fi
}

cmd="${1:-matrix}"
shift || true
case "$cmd" in
  matrix) print_matrix ;;
  log-help) log_help ;;
  grep-markers) grep_markers "$@" ;;
  check-rtdb) check_rtdb "$@" ;;
  summarize-scenario) summarize_scenario "$@" ;;
  record) record_scenario "$@" ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
