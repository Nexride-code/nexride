#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

E2E_PROJECT_ID="nexride-e2e-local"
BLOCKED_PROJECT="nexride-8d5bc"

if [[ "${GCLOUD_PROJECT:-}" == "$BLOCKED_PROJECT" || "${GOOGLE_CLOUD_PROJECT:-}" == "$BLOCKED_PROJECT" ]]; then
  echo "e2e: refused — production project env detected ($BLOCKED_PROJECT)" >&2
  exit 1
fi

resolve_java21() {
  if [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]]; then
    if "${JAVA_HOME}/bin/java" -version 2>&1 | grep -q 'version "21'; then
      echo "$JAVA_HOME"
      return 0
    fi
  fi
  local brew21="/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"
  if [[ -x "${brew21}/bin/java" ]] && "${brew21}/bin/java" -version 2>&1 | grep -q 'version "21'; then
    echo "$brew21"
    return 0
  fi
  local mac21
  mac21="$(/usr/libexec/java_home -v 21 2>/dev/null || true)"
  if [[ -n "$mac21" && -x "${mac21}/bin/java" ]] && "${mac21}/bin/java" -version 2>&1 | grep -q 'version "21'; then
    echo "$mac21"
    return 0
  fi
  return 1
}

if ! java_home="$(resolve_java21)"; then
  echo "e2e: SKIP (need JDK 21+ for Firebase emulators). Install: brew install openjdk@21" >&2
  exit 0
fi

export JAVA_HOME="$java_home"
export PATH="$JAVA_HOME/bin:$PATH"

if [[ ! -d tools/e2e/node_modules ]]; then
  echo "e2e: installing tools/e2e dependencies..."
  npm install --prefix tools/e2e --no-audit --no-fund
fi

if [[ ! -d nexride_driver/functions/node_modules ]]; then
  echo "e2e: installing nexride_driver/functions dependencies..."
  npm install --prefix nexride_driver/functions --no-audit --no-fund
fi

# Avoid accidental production Admin SDK usage during emulator runs.
unset GOOGLE_APPLICATION_CREDENTIALS || true

preflight_emulator_ports() {
  local blocked=0
  for spec in "9098:auth" "8081:firestore" "9001:database" "5002:functions"; do
    local port="${spec%%:*}"
    local name="${spec##*:}"
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      echo "e2e: warning — port $port ($name) already in use; stop stale emulators first" >&2
      lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | head -3 >&2 || true
      blocked=1
    fi
  done
  if [[ "$blocked" == "1" ]]; then
    echo "e2e: hint — pkill -f 'firebase.*emulators' or kill stale java/node emulator PIDs, then retry" >&2
    exit 1
  fi
}

preflight_emulator_ports

echo "e2e: starting Firebase emulators (project=${E2E_PROJECT_ID})..."

bash tools/e2e/install-functions-env.sh \
  firebase emulators:exec \
  --project "$E2E_PROJECT_ID" \
  --config firebase.e2e.json \
  --only auth,database,firestore,functions \
  "cd tools/e2e && npm run test:phase0"
