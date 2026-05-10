# NexRide — Instagram launch creatives (v2)

Premium, **raster-first** advertising kit: real app branding, phone mockups with depth (shadow + bezel + light sheen), Lagos/Abuja cues, and black + gold aligned with rider UI (`Color(0xFFD4AF37)` / splash).

## Real brand assets (source of truth)

Copied into `sources/branding/` from the monorepo:

| File | Origin |
|------|--------|
| `nexride_app_icon.png` | `assets/branding/nexride_app_icon.png` (also used on website) |
| `nexride_launcher.png` | `assets/branding/nexride_launcher.png` (splash/launcher family) |

Update these copies when design refreshes the master assets, then re-run the generator.

## What gets generated

All outputs are **PNG** under **`png_exports/`** (no SVG posters).

| Set | Size | Count | Folder |
|-----|------|-------|--------|
| Feed | **1080 × 1080** | 6 | `png_exports/feed/` |
| Stories | **1080 × 1920** | 4 | `png_exports/stories/` |
| WhatsApp share flyers | **1080 × 1350** (4:5) | 3 | `png_exports/whatsapp/` |

**Feed themes**

1. `feed_01_hero_lagos` — urban hero + map phone + “Move smarter across Lagos.”  
2. `feed_02_premium_africa` — logo-forward luxury + “Premium rides built for Africa.”  
3. `feed_03_live_tracking` — tracking + “Track every trip in real time.”  
4. `feed_04_verified_safety_campaign` — dual phone (rider + driver UI) + verified copy.  
5. `feed_05_launch_countdown` — countdown block + store CTAs (text pills; swap for official badges).  
6. `feed_06_drivers_wanted_campaign` — driver UI + recruitment line.

**Stories** — vertical variants: city hero, tracking, premium, split rider/driver download.

**WhatsApp** — rider share, driver recruitment, launch teaser.

### Phone “screens”

The script **renders composite UI** (map grid, route, pins, driver offer card, rider strip) to read as live product—not flat typographic posters. For **pixel-perfect OS screenshots**, capture from emulator/device and swap layers (see script header + future `sources/screenshots/` optional workflow).

### Store badges

Shown as **styled text pills** (“Google Play” / “App Store”) for layout only. For production, replace with **official** badge artwork from Google and Apple brand guidelines.

## Build

```bash
cd marketing/instagram_launch_v2
chmod +x scripts/generate.sh   # once
./scripts/generate.sh
```

Or manually:

```bash
cd marketing/instagram_launch_v2
python3 -m venv .venv
. .venv/bin/activate
pip install -r scripts/requirements.txt
python3 scripts/build_ad_creatives.py
```

Fonts: uses **Arial** from macOS Supplemental paths, or **DejaVu** on Linux. Adjust `_font()` if you want a custom TTF bundled under `sources/fonts/`.

## Tweaks

- **Countdown digit** — edit `"07"` in `build_feed_countdown()` in `scripts/build_ad_creatives.py`.  
- **City labels** — `render_map_screen(..., city_label=...)`.  
- Colours: `GOLD`, `BRONZE`, `BLACK` at top of script.

## Relation to `instagram_launch/`

The older folder holds copy decks + optional SVG export tooling. This **v2** folder is the **conversion-focused PNG pipeline** tied to real branding files in the repo.
