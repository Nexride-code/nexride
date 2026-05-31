#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

E2E_PROJECT_ID="nexride-e2e-local"

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
  return 1
}

if ! java_home="$(resolve_java21)"; then
  echo "e2e: SKIP (need JDK 21+ for Firebase emulators)" >&2
  exit 0
fi

export JAVA_HOME="$java_home"
export PATH="$JAVA_HOME/bin:$PATH"

bash tools/e2e/install-functions-env.sh \
  firebase emulators:exec \
  --project "$E2E_PROJECT_ID" \
  --config firebase.e2e.json \
  --only database \
  "cd tools/e2e && npm run test:rtdb-repro"
