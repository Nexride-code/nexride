#!/usr/bin/env zsh

set -euo pipefail

# Set NEXRIDE_SKIP_HOSTING_PREDEPLOY=1 to upload existing `public/` as-is (e.g. `/pay/*.html` only).
if [[ "${NEXRIDE_SKIP_HOSTING_PREDEPLOY:-}" == "1" ]]; then
  echo "Skipping hosting predeploy — uploading current public/ (NEXRIDE_SKIP_HOSTING_PREDEPLOY=1)."
  exit 0
fi

# Resolve repo root from this script's real path (works no matter what cwd is).
TOOLS_DIR="${0:A:h}"
ROOT_DIR="${TOOLS_DIR:h}"
OUTPUT_ROOT=${1:-"$ROOT_DIR/public"}
DRIVER_DIR="$ROOT_DIR/nexride_driver"
WEBSITE_DIR="$ROOT_DIR/website"
SITE_OUT="$ROOT_DIR/build/nexride_site_web"

ADMIN_OUT="$OUTPUT_ROOT/admin"
SUPPORT_OUT="$OUTPUT_ROOT/support"
MERCHANT_OUT="$OUTPUT_ROOT/merchant"

echo "ROOT_DIR=$ROOT_DIR"
echo "DRIVER_DIR=$DRIVER_DIR"
echo "OUTPUT_ROOT=$OUTPUT_ROOT"

echo "=== BUILDING MARKETING SITE (website/) ==="
rm -rf "$SITE_OUT"
(
  cd "$WEBSITE_DIR"
  flutter pub get
  flutter build web --release -o "$SITE_OUT"
)
rsync -a "$SITE_OUT/" "$OUTPUT_ROOT/"

echo "=== BUILDING ADMIN ==="
echo "Target: lib/main_admin.dart"
echo "Output: $ADMIN_OUT"
rm -rf "$ADMIN_OUT"
(
  cd "$DRIVER_DIR"
  flutter build web \
    -t lib/main_admin.dart \
    --release \
    --base-href /admin/ \
    -o "$ADMIN_OUT"
)

if [[ ! -f "$ADMIN_OUT/main.dart.js" ]]; then
  echo "FATAL: admin build did not produce $ADMIN_OUT/main.dart.js" >&2
  exit 1
fi
if [[ ! -f "$ADMIN_OUT/flutter_bootstrap.js" ]]; then
  echo "FATAL: admin build did not produce $ADMIN_OUT/flutter_bootstrap.js" >&2
  exit 1
fi
if [[ ! -f "$ADMIN_OUT/index.html" ]]; then
  echo "FATAL: admin build did not produce $ADMIN_OUT/index.html" >&2
  exit 1
fi
if grep -r "ADMIN BUILD OK" "$ADMIN_OUT" >/dev/null 2>&1; then
  echo "FATAL: admin bundle contains forbidden string ADMIN BUILD OK (stale or bad source)" >&2
  exit 1
fi
echo "OK: admin bundle present under $ADMIN_OUT"

echo "=== BUILDING SUPPORT ==="
echo "Target: lib/main_support.dart"
echo "Output: $SUPPORT_OUT"
rm -rf "$SUPPORT_OUT"
(
  cd "$DRIVER_DIR"
  flutter build web \
    -t lib/main_support.dart \
    --release \
    --base-href /support/ \
    -o "$SUPPORT_OUT"
)

echo "=== BUILDING MERCHANT ==="
echo "Target: lib/main_merchant.dart"
echo "Output: $MERCHANT_OUT"
rm -rf "$MERCHANT_OUT"
(
  cd "$DRIVER_DIR"
  flutter build web \
    -t lib/main_merchant.dart \
    --release \
    --base-href /merchant/ \
    -o "$MERCHANT_OUT"
)

echo "Hosted web assets are ready:"
echo "  site (nexride.africa) -> $OUTPUT_ROOT/"
echo "  admin   -> $ADMIN_OUT"
echo "  support -> $SUPPORT_OUT"
echo "  merchant -> $MERCHANT_OUT"
echo "  legacy track.html -> $OUTPUT_ROOT/track.html (optional)"
