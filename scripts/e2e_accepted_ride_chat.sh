#!/usr/bin/env bash
# E2E seed: rider+driver auth, Firestore identity, RTDB profiles, create ride, accept.
set -euo pipefail

APIKEY='AIzaSyBPKbsKmUCfq0ylIAuekiVko_Gu6wWQse4'
RTDB='https://nexride-8d5bc-default-rtdb.firebaseio.com'
PROJECT='nexride-8d5bc'
REGION='us-central1'
PASS="${E2E_PASS:-E2eTestPass123!}"
TS="${E2E_TS:-$(date +%s)}"
RIDER_EMAIL="${E2E_RIDER_EMAIL:-e2e.rider.${TS}@test.nexride.local}"
DRIVER_EMAIL="${E2E_DRIVER_EMAIL:-e2e.driver.${TS}@test.nexride.local}"
LOG_DIR="${E2E_LOG_DIR:-/tmp/nexride_e2e_${TS}}"
mkdir -p "$LOG_DIR"

sign_up() {
  curl -sS -X POST "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${APIKEY}" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"$1\",\"password\":\"${PASS}\",\"returnSecureToken\":true}"
}

sign_in() {
  curl -sS -X POST "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${APIKEY}" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"$1\",\"password\":\"${PASS}\",\"returnSecureToken\":true}"
}

callable() {
  local token="$1" name="$2" payload="$3"
  curl -sS -X POST "https://${REGION}-${PROJECT}.cloudfunctions.net/${name}" \
    -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/json' \
    -d "{\"data\":${payload}}"
}

rtdb_patch() {
  local token="$1" path="$2" json="$3"
  curl -sS -X PATCH "${RTDB}/${path}.json?auth=${token}" \
    -H 'Content-Type: application/json' \
    -d "$json"
}

firestore_seed_rider() {
  local token="$1" uid="$2"
  curl -sS -X PATCH \
    "https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents/users/${uid}?updateMask.fieldPaths=selfieUploaded&updateMask.fieldPaths=verificationStatus" \
    -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/json' \
    -d '{"fields":{"selfieUploaded":{"booleanValue":true},"verificationStatus":{"stringValue":"approved"}}}' \
    || curl -sS -X POST \
      "https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents/users?documentId=${uid}" \
      -H "Authorization: Bearer ${token}" \
      -H 'Content-Type: application/json' \
      -d '{"fields":{"selfieUploaded":{"booleanValue":true},"verificationStatus":{"stringValue":"approved"}}}'
}

echo "=== E2E seed ts=$TS log_dir=$LOG_DIR ===" | tee "$LOG_DIR/setup.log"

RIDER_JSON=$(sign_up "$RIDER_EMAIL" || sign_in "$RIDER_EMAIL")
DRIVER_JSON=$(sign_up "$DRIVER_EMAIL" || sign_in "$DRIVER_EMAIL")
echo "$RIDER_JSON" > "$LOG_DIR/rider_auth.json"
echo "$DRIVER_JSON" > "$LOG_DIR/driver_auth.json"

RIDER_TOKEN=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["idToken"])' <<<"$RIDER_JSON")
DRIVER_TOKEN=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["idToken"])' <<<"$DRIVER_JSON")
RIDER_UID=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["localId"])' <<<"$RIDER_JSON")
DRIVER_UID=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["localId"])' <<<"$DRIVER_JSON")

echo "RIDER_EMAIL=$RIDER_EMAIL RIDER_UID=$RIDER_UID" | tee -a "$LOG_DIR/setup.log"
echo "DRIVER_EMAIL=$DRIVER_EMAIL DRIVER_UID=$DRIVER_UID" | tee -a "$LOG_DIR/setup.log"
echo "E2E_PASS=$PASS" >> "$LOG_DIR/credentials.txt"
echo "RIDER_EMAIL=$RIDER_EMAIL" >> "$LOG_DIR/credentials.txt"
echo "DRIVER_EMAIL=$DRIVER_EMAIL" >> "$LOG_DIR/credentials.txt"

echo "Seeding Firestore rider identity..." | tee -a "$LOG_DIR/setup.log"
firestore_seed_rider "$RIDER_TOKEN" "$RIDER_UID" | tee "$LOG_DIR/firestore_seed.json"

NOW_MS=$(python3 -c 'import time; print(int(time.time()*1000))')
EXPIRES=$((NOW_MS + 3600000))

echo "Seeding driver RTDB profile..." | tee -a "$LOG_DIR/setup.log"
rtdb_patch "$DRIVER_TOKEN" "drivers/${DRIVER_UID}" "$(cat <<EOF
{
  "uid": "${DRIVER_UID}",
  "market_pool": "lagos",
  "dispatch_market_id": "lagos",
  "rollout_dispatch_market_id": "lagos",
  "nexride_verified": true,
  "verification": {
    "overallStatus": "approved",
    "restrictions": { "canGoOnline": true, "ride": true }
  },
  "businessModel": { "selectedModel": "commission", "canGoOnline": true },
  "driver_status": "online",
  "is_online": true,
  "online": true,
  "lat": 6.5244,
  "lng": 3.3792,
  "last_location_updated_at": ${NOW_MS},
  "last_location": { "lat": 6.5244, "lng": 3.3792 },
  "vehicle_type": "car",
  "updated_at": ${NOW_MS}
}
EOF
)" | tee "$LOG_DIR/driver_profile.json"

echo "Creating ride via createRideRequest..." | tee -a "$LOG_DIR/setup.log"
CREATE_PAYLOAD=$(cat <<EOF
{
  "market": "lagos",
  "city": "lagos",
  "payment_method": "flutterwave",
  "distance_km": 5.2,
  "eta_min": 18,
  "fare": 3200,
  "pickup": {"lat": 6.5244, "lng": 3.3792, "address": "VI Lagos"},
  "dropoff": {"lat": 6.4541, "lng": 3.3947, "address": "Lekki Lagos"},
  "destination": {"lat": 6.4541, "lng": 3.3947, "address": "Lekki Lagos"}
}
EOF
)
CREATE_RES=$(callable "$RIDER_TOKEN" createRideRequest "$CREATE_PAYLOAD")
echo "$CREATE_RES" | tee "$LOG_DIR/create_ride.json"
RIDE_ID=$(python3 -c 'import json,sys; d=json.load(sys.stdin); r=d.get("result",d); print(r.get("rideId") or r.get("ride_id") or "")' <<<"$CREATE_RES")

if [[ -z "$RIDE_ID" ]]; then
  echo "CREATE FAILED" | tee -a "$LOG_DIR/setup.log"
  exit 1
fi
echo "RIDE_ID=$RIDE_ID" | tee -a "$LOG_DIR/setup.log"

sleep 2
echo "Ensuring driver offer queue + fanout bit..." | tee -a "$LOG_DIR/setup.log"
rtdb_patch "$DRIVER_TOKEN" "driver_offer_queue/${DRIVER_UID}/${RIDE_ID}" "$(cat <<EOF
{
  "ride_id": "${RIDE_ID}",
  "market": "lagos",
  "market_pool": "lagos",
  "status": "offered",
  "expires_at": ${EXPIRES},
  "created_at": ${NOW_MS}
}
EOF
)" | tee "$LOG_DIR/offer_queue.json"
rtdb_patch "$DRIVER_TOKEN" "ride_offer_fanout/${RIDE_ID}/${DRIVER_UID}" "true" | tee "$LOG_DIR/fanout.json"

echo "Accepting ride..." | tee -a "$LOG_DIR/setup.log"
ACCEPT_RES=$(callable "$DRIVER_TOKEN" acceptRide "{\"rideId\":\"${RIDE_ID}\",\"accept_started_at\":${NOW_MS}}")
echo "$ACCEPT_RES" | tee "$LOG_DIR/accept_ride.json"

ACCEPT_OK=$(python3 -c 'import json,sys; d=json.load(sys.stdin); r=d.get("result",d); print("1" if r.get("success") else "0")' <<<"$ACCEPT_RES")
if [[ "$ACCEPT_OK" != "1" ]]; then
  echo "ACCEPT FAILED" | tee -a "$LOG_DIR/setup.log"
  exit 1
fi

# Seed chat meta for both participants
MSG_TS=$((NOW_MS + 5000))
echo "Seeding ride_chats meta..." | tee -a "$LOG_DIR/setup.log"
rtdb_patch "$RIDER_TOKEN" "ride_chats/${RIDE_ID}/meta" "$(cat <<EOF
{
  "ride_id": "${RIDE_ID}",
  "status": "active",
  "rider_id": "${RIDER_UID}",
  "driver_id": "${DRIVER_UID}",
  "updated_at": ${MSG_TS}
}
EOF
)"

cat > "$LOG_DIR/env.sh" <<ENV
export E2E_RIDE_ID='${RIDE_ID}'
export E2E_RIDER_UID='${RIDER_UID}'
export E2E_DRIVER_UID='${DRIVER_UID}'
export E2E_RIDER_TOKEN='${RIDER_TOKEN}'
export E2E_DRIVER_TOKEN='${DRIVER_TOKEN}'
export E2E_RIDER_EMAIL='${RIDER_EMAIL}'
export E2E_DRIVER_EMAIL='${DRIVER_EMAIL}'
export E2E_PASS='${PASS}'
export E2E_LOG_DIR='${LOG_DIR}'
ENV

echo "=== Seed complete. Source $LOG_DIR/env.sh ===" | tee -a "$LOG_DIR/setup.log"
cat "$LOG_DIR/env.sh"
