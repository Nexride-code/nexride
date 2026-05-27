#!/usr/bin/env bash
# Capture driver/rider logs for accepted-ride stability + chat E2E.
set -euo pipefail

DURATION_SEC="${1:-330}"
OUT="${2:-/tmp/nexride_e2e_logcat.txt}"

adb logcat -c
echo "logcat_capture_seconds=$DURATION_SEC out=$OUT"
timeout "$DURATION_SEC" adb logcat -v time \
  | tee "$OUT" \
  | grep -E --line-buffered \
    'stale local ride purged|active ride cleared|no_valid_active_ride|FirebaseDatabasePlugin\.update|OutOfMemory|pthread_create|CHAT_WRITE_OK|CHAT_WRITE_FAIL|CHAT_SEND_FAIL|CHAT_PERMISSION_DENIED|ARRIVED_SENT|PAYMENT_CONFIRMED|ACCEPT_SUCCESS|ACTIVE_TRIP_LOADED|flutter \(' \
  || true

echo "=== SUMMARY $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" | tee -a "$OUT.summary"
for pat in \
  'stale local ride purged' \
  'active ride cleared.*no_valid_active_ride' \
  'FirebaseDatabasePlugin.update' \
  'OutOfMemory' \
  'pthread_create' \
  'CHAT_MESSAGE_RECEIVED role=rider' \
  'CHAT_WRITE_OK' \
  'updateChildren at /' \
  'ARRIVED_SENT'; do
  c=$(grep -c "$pat" "$OUT" 2>/dev/null || echo 0)
  echo "$pat count=$c" | tee -a "$OUT.summary"
done
