#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

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
  echo "rtdb-rules-test: SKIP (need JDK 21+ for firebase emulators). Install: brew install openjdk@21" >&2
  exit 0
fi

export JAVA_HOME="$java_home"
export PATH="$JAVA_HOME/bin:$PATH"

firebase emulators:exec --only database -- "cd tools/rtdb-rules-test && node --test ride_requests_discovery.test.mjs query_smoke.test.mjs"
