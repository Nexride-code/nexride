# NexRide — Instagram Launch Branding Kit

Professional assets for feed posts, Stories, Highlights, Play Store visuals, and campaign copy. **Brand:** premium African mobility, **palette** black · gold · white, mobile-first layouts.

---

## Folder map

| Path | Contents |
|------|----------|
| `logo/` | Wordmark + icon SVGs + **`nexride_logo_1080_transparent.png`** (profile-ready) |
| `posts/` | Nine launch creatives + reusable square template (**1080×1080**) |
| `stories/` | Matching Story layouts (**1080×1920**) + blank story template |
| `highlights/` | Circular-safe cover art (**1080×1080**, keep key art in centre ~600×600) |
| `templates/` | Blank feed + Story frames for reuse |
| `misc/` | Rider safety, driver onboarding, coming soon, launch announcement, **Play Store IG** square |
| `play_store/` | Feature graphic (**1024×500** viewBox per Google Play specs) |
| `captions/` | **Captions, hashtags**, and bios (also `bios_standalone.txt`) |
| `scripts/` | **`export_png.sh`** + `README.md` — batch PNG export via Inkscape |
| `png_exports/` | Generated PNGs (created when you run **`scripts/export_png.sh`**) |

All artwork is delivered as **SVG** for crisp scaling. Export to PNG at the exact pixels Instagram expects.

---

## Instagram export sizes

| Asset | Dimensions | Notes |
|-------|------------|-------|
| Feed post | **1080 × 1080** | JPG or PNG |
| Story | **1080 × 1920** | Safe area: leave ~250px bottom clear for taps |
| Profile photo | **320 × 320** min (Instagram crops circle) — design at **1080×1080** and scale down |
| Transparent logo | **PNG**, square canvas e.g. **512×512** or **1080×1080** with mark centred | SVG has no baked background |

### Batch export (Inkscape CLI)

Automated PNGs → **`png_exports/`** (posts, stories, highlights, misc, play_store):

1. Install Inkscape (`brew install --cask inkscape` on macOS, or see [Inkscape downloads](https://inkscape.org/release/)).  
2. `chmod +x marketing/instagram_launch/scripts/export_png.sh`  
3. `./marketing/instagram_launch/scripts/export_png.sh`

Full steps and sizes: **`scripts/README.md`**.

### Single-file export (macOS — Inkscape)

```bash
INK=/Applications/Inkscape.app/Contents/MacOS/inkscape
cd marketing/instagram_launch/posts
$INK 01_logo_intro.svg --export-type=png --export-filename=export/01_logo_intro.png -w 1080 -h 1080
```

Alternatively use **Figma / Canva**: import SVG, export at 1× to the dimensions above.

### Batch in other tools

Use your design tool’s batch export: set artboards to **1080×1080**, **1080×1920**, or **1024×500** to match each file’s `width`/`height`.

---

## Nine launch posts (file → theme)

1. `01_logo_intro.svg` — Logo intro  
2. `02_coming_soon.svg` — Coming soon  
3. `03_rider_app.svg` — Rider app  
4. `04_driver_app.svg` — Driver app  
5. `05_live_tracking.svg` — Live tracking  
6. `06_safety_verification.svg` — Safety verification  
7. `07_support.svg` — Support  
8. `08_secure_payments.svg` — Secure payments  
9. `09_launch_countdown.svg` — Launch countdown  

Full **captions and hashtags** live in `captions/posts_captions_hashtags.md`.

---

## Legal / QA

Replace placeholder store links and `@nexride` handle with production values before publishing. Compress PNGs if file size matters (TinyPNG, ImageOptim).
