#!/bin/zsh

set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname "$0")/.." && pwd)
OUTPUT_ROOT=${1:-"$ROOT_DIR/public"}
DRIVER_DIR="$ROOT_DIR/nexride_driver"

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
echo "  admin   -> $OUTPUT_ROOT/admin"
echo "  support -> $OUTPUT_ROOT/support"
echo "  tracking -> $OUTPUT_ROOT/track.html"
