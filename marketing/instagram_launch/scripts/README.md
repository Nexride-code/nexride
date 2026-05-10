# PNG batch export — Instagram launch

Exports all launch SVGs to raster PNGs using **Inkscape** on the command line.

## 1. Install Inkscape

- **macOS:** [Inkscape downloads](https://inkscape.org/release/) — install the app (default: `/Applications/Inkscape.app`). The script falls back to that path if `inkscape` is not on your `PATH`.  
  To expose the CLI globally, you can add a symlink or add the Inkscape `bin` folder to `PATH`, depending on your install method ([Homebrew](https://formulae.brew.sh/cask/inkscape): `brew install --cask inkscape`).
- **Linux:** `sudo apt install inkscape` or your distro equivalent.
- **Windows:** Install Inkscape and ensure `inkscape.exe` is on `PATH`.

## 2. Make the script executable

From the repo root (or anywhere):

```bash
chmod +x marketing/instagram_launch/scripts/export_png.sh
```

## 3. Run the export

```bash
cd marketing/instagram_launch/scripts
./export_png.sh
```

Or:

```bash
./marketing/instagram_launch/scripts/export_png.sh
```

## Output layout

PNG files are written under **`marketing/instagram_launch/png_exports/`**:

| Directory | Sources | PNG size |
|-----------|---------|-----------|
| `png_exports/posts/` | `../posts/*.svg` | **1080 × 1080** |
| `png_exports/stories/` | `../stories/*.svg` | **1080 × 1920** |
| `png_exports/highlights/` | `../highlights/*.svg` | **1080 × 1080** |
| `png_exports/misc/` | `../misc/*.svg` | **1080 × 1080** |
| `png_exports/play_store/` | `../play_store/*.svg` | **1024 × 500** |

Logo and blank templates are **not** included automatically (they live under `logo/` and `templates/`). Add those folders to `export_png.sh` if you want them in the same pipeline.

---

## Encoding cleanup (before export)

If Inkscape reports invalid XML / bad UTF-8, normalize every SVG under `instagram_launch/` (UTF-8, no BOM; safe ASCII punctuation):

```bash
python3 marketing/instagram_launch/scripts/sanitize_svg_encoding.py
```

Dry-run (parse check only, no writes):

```bash
python3 marketing/instagram_launch/scripts/sanitize_svg_encoding.py --dry-run
```

Then run `./export_png.sh` again.
