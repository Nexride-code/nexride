#!/usr/bin/env bash
# Batch-export Instagram launch SVGs to PNG via Inkscape CLI.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/png_exports"

detect_inkscape() {
	if command -v inkscape >/dev/null 2>&1; then
		command -v inkscape
		return
	fi
	local mac_candidates=(
		"/Applications/Inkscape.app/Contents/MacOS/inkscape"
		"/Applications/Inkscape/Inkscape.app/Contents/MacOS/inkscape"
	)
	for candidate in "${mac_candidates[@]}"; do
		if [[ -x "$candidate" ]]; then
			printf '%s' "$candidate"
			return
		fi
	done
	return 1
}

INKSCAPE=""
if ! INKSCAPE="$(detect_inkscape)" || [[ -z "$INKSCAPE" ]]; then
	echo "Error: Inkscape not found. Install Inkscape and ensure it's on PATH, or install the macOS app under /Applications/Inkscape.app" >&2
	echo "See: marketing/instagram_launch/scripts/README.md" >&2
	exit 1
fi

export_one() {
	local src="$1"
	local dest="$2"
	local width="$3"
	local height="$4"
	mkdir -p "$(dirname "$dest")"
	echo "Export $width x $height: $(basename "$src") -> $(basename "$dest")"
	"$INKSCAPE" "$src" --export-type=png --export-filename="$dest" -w "$width" -h "$height"
}

shopt -s nullglob

mkdir -p "$OUT/posts" "$OUT/stories" "$OUT/highlights" "$OUT/misc" "$OUT/play_store"

for svg in "$ROOT/posts"/*.svg; do
	export_one "$svg" "$OUT/posts/$(basename "${svg%.svg}.png")" 1080 1080
done

for svg in "$ROOT/stories"/*.svg; do
	export_one "$svg" "$OUT/stories/$(basename "${svg%.svg}.png")" 1080 1920
done

for svg in "$ROOT/highlights"/*.svg; do
	export_one "$svg" "$OUT/highlights/$(basename "${svg%.svg}.png")" 1080 1080
done

for svg in "$ROOT/misc"/*.svg; do
	export_one "$svg" "$OUT/misc/$(basename "${svg%.svg}.png")" 1080 1080
done

for svg in "$ROOT/play_store"/*.svg; do
	export_one "$svg" "$OUT/play_store/$(basename "${svg%.svg}.png")" 1024 500
done

echo "Done. PNGs written under: $OUT"
