#!/usr/bin/env bash
# Install emulator-safe Functions env files for non-interactive startup.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FUNCS_DIR="$ROOT/nexride_driver/functions"
ENV_E2E="$ROOT/tools/e2e/config/functions.env.e2e"
SECRET_E2E="$ROOT/tools/e2e/config/functions.secret.local.e2e"
ENV_TARGET="$FUNCS_DIR/.env"
SECRET_TARGET="$FUNCS_DIR/.secret.local"
BACKUP_DIR="$ROOT/tools/e2e/.tmp/env-backup-$$"

mkdir -p "$BACKUP_DIR"

if [[ -f "$ENV_TARGET" ]]; then
  cp "$ENV_TARGET" "$BACKUP_DIR/.env"
fi
if [[ -f "$SECRET_TARGET" ]]; then
  cp "$SECRET_TARGET" "$BACKUP_DIR/.secret.local"
fi

cp "$ENV_E2E" "$ENV_TARGET"
cp "$SECRET_E2E" "$SECRET_TARGET"

echo "e2e: installed $ENV_TARGET and $SECRET_TARGET from tools/e2e/config/*"

restore_env_files() {
  if [[ -f "$BACKUP_DIR/.env" ]]; then
    mv "$BACKUP_DIR/.env" "$ENV_TARGET"
  else
    rm -f "$ENV_TARGET"
  fi
  if [[ -f "$BACKUP_DIR/.secret.local" ]]; then
    mv "$BACKUP_DIR/.secret.local" "$SECRET_TARGET"
  else
    rm -f "$SECRET_TARGET"
  fi
  rm -rf "$BACKUP_DIR"
}

trap restore_env_files EXIT

# Export for child processes (Functions emulator + dotenv redundancy).
set -a
# shellcheck disable=SC1090
source "$ENV_E2E"
# shellcheck disable=SC1090
source "$SECRET_E2E"
set +a

export GCLOUD_PROJECT="${GCLOUD_PROJECT:-nexride-e2e-local}"
export GOOGLE_CLOUD_PROJECT="${GOOGLE_CLOUD_PROJECT:-nexride-e2e-local}"

exec "$@"
