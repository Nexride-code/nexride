#!/bin/zsh

set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname "$0")/.." && pwd)
OUTPUT_ROOT=${1:-"$ROOT_DIR/public"}
DRIVER_DIR="$ROOT_DIR/nexride_driver"
WEBSITE_DIR="$ROOT_DIR/website"
SITE_OUT="$ROOT_DIR/build/nexride_site_web"

echo "Building NexRide marketing site (Flutter web) → $OUTPUT_ROOT"
rm -rf "$SITE_OUT"
(
  cd "$WEBSITE_DIR"
  flutter pub get
  flutter build web --release -o "$SITE_OUT"
)
rsync -a "$SITE_OUT/" "$OUTPUT_ROOT/"

echo "Building NexRide admin portal into $OUTPUT_ROOT/admin"
(
  cd "$DRIVER_DIR"
  flutter build web \
    -t lib/main_admin.dart \
    --release \
    --base-href /admin/ \
    -o "$OUTPUT_ROOT/admin"
)

echo "Building NexRide support portal into $OUTPUT_ROOT/support"
(
  cd "$DRIVER_DIR"
  flutter build web \
    -t lib/main_support.dart \
    --release \
    --base-href /support/ \
    -o "$OUTPUT_ROOT/support"
)

echo "Hosted web assets are ready:"
echo "  site (nexride.africa) -> $OUTPUT_ROOT/"
echo "  admin   -> $OUTPUT_ROOT/admin"
echo "  support -> $OUTPUT_ROOT/support"
echo "  legacy track.html -> $OUTPUT_ROOT/track.html (optional)"
