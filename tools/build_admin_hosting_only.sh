#!/usr/bin/env zsh
# Builds ONLY the hosted admin app (not merchant/driver/support).
# Output: repo-root/public/admin — matches Firebase hosting for /admin/*
set -euo pipefail

TOOLS_DIR="${0:A:h}"
ROOT_DIR="${TOOLS_DIR:h}"
DRIVER_DIR="$ROOT_DIR/nexride_driver"
OUT_DIR="$ROOT_DIR/public/admin"

echo "ROOT_DIR=$ROOT_DIR"
echo "=== BUILDING ADMIN ==="
echo "Target: lib/main_admin.dart"
echo "Output: $OUT_DIR"

rm -rf "$OUT_DIR"
(
  cd "$DRIVER_DIR"
  flutter build web \
    -t lib/main_admin.dart \
    --release \
    --base-href /admin/ \
    -o "$OUT_DIR"
)

if [[ ! -f "$OUT_DIR/main.dart.js" ]]; then
  echo "FATAL: admin build did not produce $OUT_DIR/main.dart.js" >&2
  exit 1
fi
if [[ ! -f "$OUT_DIR/flutter_bootstrap.js" ]]; then
  echo "FATAL: admin build did not produce $OUT_DIR/flutter_bootstrap.js" >&2
  exit 1
fi
if [[ ! -f "$OUT_DIR/index.html" ]]; then
  echo "FATAL: admin build did not produce $OUT_DIR/index.html" >&2
  exit 1
fi
if grep -r "ADMIN BUILD OK" "$OUT_DIR" >/dev/null 2>&1; then
  echo "FATAL: admin bundle contains forbidden string ADMIN BUILD OK" >&2
  exit 1
fi
echo "OK: admin bundle present (main.dart.js, flutter_bootstrap.js, index.html; no recovery strip)."

echo "Done."
echo "Deploy: cd $ROOT_DIR && firebase deploy --only hosting"
