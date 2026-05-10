# Logo export — Instagram profile & transparent PNG

## Files

| File | Purpose |
|------|---------|
| `nexride_icon_mark.svg` | **Transparent** centred mark · export as PNG for profile sticker / watermark |
| `nexride_wordmark_on_dark.svg` | Wordmark on dark (for decks, not IG profile transparency) |

## Instagram profile (circular crop)

1. Export `nexride_icon_mark.svg` to **PNG 1080×1080** (or 512×512) with **transparent** background — your exporter should omit the SVG “page” background if none is drawn (`nexride_icon_mark` has **no background rect**).

2. In Instagram, the circle crops corners — keep the monogram comfortably inside ~**70%** of the square’s width.

3. Recommended: add **88px inner padding** in Figma/Inkscape so the glyph isn’t clipped when circled.

## Quick PNG export

- **Inkscape:** open SVG → Export PNG → set dimensions.
- **Figma:** paste SVG → export 3x PNG (360 logical → 1080 px) if using vector scaling.

Bundled raster: **`nexride_logo_1080_transparent.png`** — **1080×1080**, alpha channel, centred mark with padding for Instagram’s circular crop. Source-of-truth vectors remain the `.svg` files.
