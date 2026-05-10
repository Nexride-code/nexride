#!/usr/bin/env python3
"""
NexRide premium ad creative generator (raster PNG).
Uses real branding from sources/branding/ (copied from assets/branding/).
Synthesises polished phone UI composites (map / driver / rider) for conversion-quality layouts.
Replace screen layers with device screenshots if desired — see README.
"""
from __future__ import annotations

import math
import os
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

# Brand tokens (rider splash / UI)
GOLD = (212, 175, 55)
GOLD_DIM = (168, 137, 47)
BRONZE = (183, 121, 43)
BLACK = (10, 10, 10)
WHITE = (250, 250, 248)
GRAY_MUTED = (140, 135, 128)

ROOT = Path(__file__).resolve().parent.parent
BRAND = ROOT / "sources" / "branding"
OUT = ROOT / "png_exports"


def _font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    candidates = [
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/Library/Fonts/Arial.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ]
    if not bold:
        candidates = [
            "/System/Library/Fonts/Supplemental/Arial.ttf",
            "/Library/Fonts/Arial.ttf",
            "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        ] + candidates[2:]
    for path in candidates:
        if os.path.isfile(path):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    return ImageFont.load_default()


def linear_gradient(w: int, h: int, top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    base = Image.new("RGB", (w, h))
    pix = base.load()
    for y in range(h):
        t = y / max(h - 1, 1)
        r = int(top[0] * (1 - t) + bottom[0] * t)
        g = int(top[1] * (1 - t) + bottom[1] * t)
        b = int(top[2] * (1 - t) + bottom[2] * t)
        for x in range(w):
            pix[x, y] = (r, g, b)
    return base


def radial_glow(w: int, h: int, cx: int, cy: int, rgb: tuple[int, int, int], falloff: float = 0.45) -> Image.Image:
    """Soft gold glow overlay (RGBA)."""
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    px = layer.load()
    for y in range(h):
        for x in range(w):
            dx, dy = x - cx, y - cy
            d = math.sqrt(dx * dx + dy * dy) / (max(w, h) * falloff)
            a = max(0, int(120 * math.exp(-d * d)))
            px[x, y] = (*rgb, a)
    return layer


def draw_city_silhouette(img: Image.Image, y_base: float, alpha: int = 255) -> None:
    """Minimal Lagos/Abuja-style skyline hint — geometric, no stock photo."""
    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    dr = ImageDraw.Draw(overlay)
    w, h = img.size
    rng = [0.08, 0.12, 0.18, 0.22, 0.15, 0.25, 0.11, 0.19, 0.14, 0.21, 0.17]
    x = 0
    i = 0
    while x < w + 40:
        rw = int(w * rng[i % len(rng)])
        rh = int(h * (0.08 + 0.06 * (i % 3)))
        dr.rectangle([x, y_base - rh, x + rw, y_base + 8], fill=(0, 0, 0, min(alpha, 200)))
        x += rw + 2
        i += 1
    img.alpha_composite(overlay)


def render_map_screen(w: int, h: int, city_label: str = "Lagos") -> Image.Image:
    """Synthetic live-tracking map UI (dark tiles, route, pins)."""
    base = Image.new("RGB", (w, h), (13, 17, 24))
    dr = ImageDraw.Draw(base)
    grid = 42
    for gx in range(0, w, grid):
        dr.line([(gx, 0), (gx, h)], fill=(30, 34, 42), width=1)
    for gy in range(0, h, grid):
        dr.line([(0, gy), (w, gy)], fill=(30, 34, 42), width=1)
    # Route
    pts = []
    for i in range(12):
        t = i / 11.0
        px = int(w * 0.12 + t * w * 0.7 + 8 * math.sin(t * math.pi))
        py = int(h * 0.72 - t * h * 0.45)
        pts.append((px, py))
    for i in range(len(pts) - 1):
        dr.line([pts[i], pts[i + 1]], fill=GOLD, width=5)
    dr.ellipse([pts[0][0] - 10, pts[0][1] - 10, pts[0][0] + 10, pts[0][1] + 10], fill=(46, 204, 113))
    dr.ellipse([pts[-1][0] - 10, pts[-1][1] - 10, pts[-1][0] + 10, pts[-1][1] + 10], fill=GOLD)
    # Top bar
    dr.rounded_rectangle([0, 0, w, int(h * 0.11)], radius=0, fill=(20, 20, 22))
    f = _font(max(18, w // 28))
    dr.text((w * 0.08, h * 0.025), f"{city_label} - ETA 4 min", fill=WHITE, font=f)
    return base


def render_driver_screen(w: int, h: int) -> Image.Image:
    """Synthetic driver incoming-offer UI."""
    base = Image.new("RGB", (w, h), (14, 14, 16))
    dr = ImageDraw.Draw(base)
    header_h = int(h * 0.1)
    dr.rectangle([0, 0, w, header_h], fill=(24, 24, 26))
    dr.text((w * 0.06, h * 0.03), "NexRide Driver", fill=WHITE, font=_font(max(16, w // 26), bold=True))
    mini = render_map_screen(w, int(h * 0.35), "Abuja")
    base.paste(mini, (int(w * 0.08), int(h * 0.14)))
    card_y = int(h * 0.52)
    dr.rounded_rectangle([int(w * 0.06), card_y, int(w * 0.94), int(h * 0.88)], radius=16, fill=(28, 28, 30))
    dr.text((int(w * 0.1), card_y + 16), "New trip request", fill=WHITE, font=_font(max(18, w // 22), bold=True))
    dr.text((int(w * 0.1), card_y + 52), "Ikeja - Victoria Island", fill=GRAY_MUTED, font=_font(max(14, w // 30)))
    btn_y = card_y + 96
    dr.rounded_rectangle([int(w * 0.1), btn_y, int(w * 0.9), btn_y + 52], radius=12, fill=GOLD)
    dr.text((int(w * 0.32), btn_y + 14), "Accept", fill=BLACK, font=_font(max(17, w // 24), bold=True))
    return base


def render_rider_booking_screen(w: int, h: int) -> Image.Image:
    """Synthetic rider destination / booking strip."""
    base = Image.new("RGB", (w, h), (12, 12, 14))
    dr = ImageDraw.Draw(base)
    dr.rounded_rectangle([int(w * 0.05), int(h * 0.08), int(w * 0.95), int(h * 0.22)], radius=14, fill=(28, 28, 30))
    dr.text((int(w * 0.1), int(h * 0.12)), "Where to?", fill=WHITE, font=_font(max(18, w // 24), bold=True))
    dr.text((int(w * 0.1), int(h * 0.72)), "Your driver is on the way", fill=GOLD, font=_font(max(14, w // 28)))
    smap = render_map_screen(w, int(h * 0.48), "Lagos")
    base.paste(smap, (0, int(h * 0.28)))
    return base


def load_logo(max_px: int = 512) -> Image.Image:
    p = BRAND / "nexride_app_icon.png"
    if not p.is_file():
        raise FileNotFoundError(f"Missing {p}")
    im = Image.open(p).convert("RGBA")
    im.thumbnail((max_px, max_px), Image.Resampling.LANCZOS)
    return im


def shadow_layer(w: int, h: int, blur: int = 22) -> Image.Image:
    s = Image.new("L", (w + blur * 2, h + blur * 2), 0)
    d = ImageDraw.Draw(s)
    d.rounded_rectangle([blur, blur, blur + w, blur + h], radius=36, fill=180)
    return s.filter(ImageFilter.GaussianBlur(blur // 2))


def phone_mosaic(
    screen: Image.Image,
    max_w: int,
    max_h: int,
) -> Image.Image:
    """Device frame + screen, PNG with alpha."""
    sw, sh = screen.size
    scale = min(max_w / sw, max_h / sh)
    nw, nh = int(sw * scale), int(sh * scale)
    screen_s = screen.resize((nw, nh), Image.Resampling.LANCZOS)

    bezel = 18
    fw, fh = nw + bezel * 2, nh + bezel * 2
    shadow = shadow_layer(fw, fh, blur=28)
    canvas = Image.new("RGBA", (fw + 80, fh + 100), (0, 0, 0, 0))
    sx, sy = shadow.size
    shadow_drop = Image.new("RGBA", (sx, sy), (0, 0, 0, 255))
    shadow_drop.putalpha(shadow)
    ox, oy = 40 - bezel + 8, 36 - bezel + 8
    canvas.paste(shadow_drop, (ox, oy), shadow_drop)

    frame = Image.new("RGBA", (fw, fh), (0, 0, 0, 0))
    dr = ImageDraw.Draw(frame)
    dr.rounded_rectangle([0, 0, fw - 1, fh - 1], radius=44, fill=(42, 42, 46, 255))
    dr.rounded_rectangle([bezel, bezel, fw - bezel, fh - bezel], radius=32, fill=(0, 0, 0, 255))

    frame.paste(screen_s, (bezel, bezel))
    # reflection sheen (full-frame overlay for composite size match)
    gloss = Image.new("RGBA", (fw, fh), (0, 0, 0, 0))
    gdr = ImageDraw.Draw(gloss)
    gdr.rectangle([0, 0, fw, fh // 3], fill=(255, 255, 255, 40))
    frame = Image.alpha_composite(frame.convert("RGBA"), gloss)

    canvas.paste(frame, (40 - bezel, 30 - bezel), frame)
    return canvas


def paste_headline(
    canvas: Image.Image,
    text: str,
    sub: str | None,
    y: int,
    center_x: int,
    max_width: int,
) -> None:
    dr = ImageDraw.Draw(canvas)
    font_main = _font(52, bold=True)
    font_sub = _font(28)
    # Wrap headline crudely
    words = text.split()
    lines = []
    cur = []
    for word in words:
        trial = " ".join(cur + [word])
        bbox = dr.textbbox((0, 0), trial, font=font_main)
        if bbox[2] - bbox[0] > max_width and cur:
            lines.append(" ".join(cur))
            cur = [word]
        else:
            cur.append(word)
    if cur:
        lines.append(" ".join(cur))
    yy = y
    for line in lines:
        bbox = dr.textbbox((0, 0), line, font=font_main)
        tw = bbox[2] - bbox[0]
        x = center_x - tw // 2
        # subtle shadow for depth
        dr.text((x + 2, yy + 2), line, fill=(0, 0, 0, 160), font=font_main)
        dr.text((x, yy), line, fill=WHITE, font=font_main)
        yy += int((bbox[3] - bbox[1]) * 1.15)
    if sub:
        bbox = dr.textbbox((0, 0), sub, font=font_sub)
        tw = bbox[2] - bbox[0]
        dr.text((center_x - tw // 2, yy + 12), sub, fill=(*GOLD, 255), font=font_sub)
    return


def store_badges_horizontal(canvas: Image.Image, y: int, cx: int) -> None:
    """Text-only store CTAs (use official badge artwork in production)."""
    dr = ImageDraw.Draw(canvas)
    f = _font(18)
    dr.rounded_rectangle([cx - 220, y, cx - 20, y + 44], radius=10, fill=(30, 30, 32, 240))
    dr.rounded_rectangle([cx + 20, y, cx + 220, y + 44], radius=10, fill=(30, 30, 32, 240))
    dr.text((cx - 185, y + 12), "Google Play", fill=WHITE, font=f)
    dr.text((cx + 55, y + 12), "App Store", fill=WHITE, font=f)


# ---- Creatives ----

def build_feed_hero_lagos() -> None:
    w, h = 1080, 1080
    base = linear_gradient(w, h, (18, 16, 12), BLACK).convert("RGBA")
    glow = radial_glow(w, h, w // 2, int(h * 0.35), GOLD_DIM)
    base = Image.alpha_composite(base, glow)
    draw_city_silhouette(base, h * 0.88, alpha=220)

    screen = render_map_screen(900, 1100, "Lagos")
    phone = phone_mosaic(screen, 520, 620)
    pw, ph = phone.size
    base.alpha_composite(phone, (w - pw - 60, h - ph - 40))

    logo = load_logo(140)
    lw, lh = logo.size
    base.paste(logo, (60, 60), logo)

    tmp = Image.new("RGBA", base.size, (0, 0, 0, 0))
    paste_headline(
        tmp,
        "Move smarter across Lagos.",
        "Your city ride, redesigned.",
        200,
        340,
        560,
    )
    base = Image.alpha_composite(base, tmp)
    base = base.convert("RGB")
    out = OUT / "feed" / "feed_01_hero_lagos.png"
    base.save(out, "PNG", optimize=True)
    print("Wrote", out)


def build_feed_premium_africa() -> None:
    w, h = 1080, 1080
    base = linear_gradient(w, h, (26, 22, 14), BLACK).convert("RGBA")
    glow = radial_glow(w, h, w // 2, h // 2, GOLD, 0.55)
    b2 = Image.blend(base, glow, 0.28)

    logo = load_logo(280)
    lw, lh = logo.size
    b2 = b2.convert("RGBA")
    b2.paste(logo, ((w - lw) // 2, 220), logo)

    tmp = Image.new("RGBA", b2.size, (0, 0, 0, 0))
    paste_headline(tmp, "Premium rides built for Africa.", None, 540, w // 2, 900)
    b2 = Image.alpha_composite(b2, tmp)
    dr = ImageDraw.Draw(b2)
    dr.line([(120, 640), (960, 640)], fill=GOLD, width=2)
    dr.text((w // 2 - 200, 670), "Lagos - Abuja - expanding", fill=GRAY_MUTED, font=_font(26))
    b2.convert("RGB").save(OUT / "feed" / "feed_02_premium_africa.png", "PNG", optimize=True)
    print("Wrote", OUT / "feed" / "feed_02_premium_africa.png")


def build_feed_tracking() -> None:
    w, h = 1080, 1080
    base = linear_gradient(w, h, BLACK, (20, 18, 14))
    screen = render_map_screen(980, 1200, "Lagos")
    phone = phone_mosaic(screen, 500, 700)
    base_r = base.convert("RGBA")
    pw, ph = phone.size
    base_r.alpha_composite(phone, ((w - pw) // 2, h - ph - 50))

    logo = load_logo(110)
    base_r.paste(logo, (50, 50), logo)

    tmp = Image.new("RGBA", base_r.size, (0, 0, 0, 0))
    paste_headline(
        tmp,
        "Track every trip in real time.",
        "Verified route. Live ETA. Share trip status.",
        120,
        w // 2,
        800,
    )
    base_r = Image.alpha_composite(base_r, tmp).convert("RGB")
    base_r.save(OUT / "feed" / "feed_03_live_tracking.png", "PNG", optimize=True)
    print("Wrote", OUT / "feed" / "feed_03_live_tracking.png")


def build_feed_verified_safety() -> None:
    w, h = 1080, 1080
    base = linear_gradient(w, h, (14, 14, 16), BLACK).convert("RGBA")

    rider = render_rider_booking_screen(560, 900)
    driver = render_driver_screen(560, 900)
    p1 = phone_mosaic(rider, 340, 520)
    p2 = phone_mosaic(driver, 340, 520)
    base.alpha_composite(p1, (80, 200))
    base.alpha_composite(p2, (w - 80 - p1.size[0], 220))

    logo = load_logo(100)
    base.paste(logo, (50, 50), logo)

    tmp = Image.new("RGBA", base.size, (0, 0, 0, 0))
    paste_headline(
        tmp,
        "Ride safer with verified drivers.",
        "Verified riders. Verified drivers. Built for trust.",
        100,
        w // 2,
        920,
    )
    Image.alpha_composite(base, tmp).convert("RGB").save(
        OUT / "feed" / "feed_04_verified_safety_campaign.png", "PNG", optimize=True
    )
    print("Wrote", OUT / "feed" / "feed_04_verified_safety_campaign.png")


def build_feed_countdown() -> None:
    w, h = 1080, 1080
    base = linear_gradient(w, h, BLACK, (36, 28, 16)).convert("RGBA")
    glow = radial_glow(w, h, w // 2, h // 3, GOLD)
    base = Image.alpha_composite(base, glow)
    logo = load_logo(160)
    base.paste(logo, ((w - logo.size[0]) // 2, 100), logo)

    dr = ImageDraw.Draw(base)
    num_f = _font(160, bold=True)
    dr.text((w // 2 - 120, 380), "07", fill=GOLD, font=num_f)
    dr.text((w // 2 - 220, 520), "days until launch", fill=WHITE, font=_font(38))
    dr.text((w // 2 - 260, 600), "(edit number in script before export)", fill=GRAY_MUTED, font=_font(22))
    store_badges_horizontal(base, 720, w // 2)

    tmp = Image.new("RGBA", base.size, (0, 0, 0, 0))
    paste_headline(tmp, "The wait is almost over.", "Premium mobility - Nigeria first.", 240, w // 2, 900)
    Image.alpha_composite(base, tmp).convert("RGB").save(
        OUT / "feed" / "feed_05_launch_countdown.png", "PNG", optimize=True
    )
    print("Wrote", OUT / "feed" / "feed_05_launch_countdown.png")


def build_feed_drivers_wanted() -> None:
    w, h = 1080, 1080
    base = linear_gradient(w, h, (18, 16, 12), BLACK).convert("RGBA")
    scr = render_driver_screen(720, 1180)
    phone = phone_mosaic(scr, 460, 720)
    base.alpha_composite(phone, (w - phone.size[0] - 50, 120))

    logo = load_logo(120)
    base.paste(logo, (50, 50), logo)

    tmp = Image.new("RGBA", base.size, (0, 0, 0, 0))
    paste_headline(
        tmp,
        "Drivers wanted.",
        "Clear offers. Fair earnings. Professional tools.",
        180,
        320,
        520,
    )
    dr = ImageDraw.Draw(tmp)
    dr.rounded_rectangle([60, 520, 420, 590], radius=14, fill=(*GOLD, 255))
    dr.text((120, 540), "Apply today", fill=BLACK, font=_font(28, bold=True))
    base = Image.alpha_composite(base, tmp).convert("RGB")
    base.save(OUT / "feed" / "feed_06_drivers_wanted_campaign.png", "PNG", optimize=True)
    print("Wrote", OUT / "feed" / "feed_06_drivers_wanted_campaign.png")


# Stories 1080 x 1920

def build_story_01() -> None:
    w, h = 1080, 1920
    base = linear_gradient(w, h, (22, 18, 12), BLACK).convert("RGBA")
    draw_city_silhouette(base, h * 0.92, 180)
    screen = render_map_screen(900, 1400, "Lagos")
    phone = phone_mosaic(screen, 620, 900)
    base.alpha_composite(phone, ((w - phone.size[0]) // 2, 420))
    logo = load_logo(130)
    base.paste(logo, (60, 80), logo)
    tmp = Image.new("RGBA", base.size, (0, 0, 0, 0))
    paste_headline(
        tmp,
        "Your city ride, redesigned.",
        "Move smarter across Lagos & Abuja.",
        200,
        w // 2,
        900,
    )
    store_badges_horizontal(base, 1680, w // 2)
    Image.alpha_composite(base, tmp).convert("RGB").save(
        OUT / "stories" / "story_01_city_hero.png", "PNG", optimize=True
    )
    print("Wrote", OUT / "stories" / "story_01_city_hero.png")


def build_story_02() -> None:
    w, h = 1080, 1920
    base = linear_gradient(w, h, BLACK, (25, 22, 16)).convert("RGBA")
    screen = render_map_screen(960, 1500, "Abuja")
    phone = phone_mosaic(screen, 640, 980)
    base.alpha_composite(phone, ((w - phone.size[0]) // 2, 380))
    logo = load_logo(110)
    base.paste(logo, ((w - logo.size[0]) // 2, 120), logo)
    tmp = Image.new("RGBA", base.size, (0, 0, 0, 0))
    paste_headline(tmp, "Track every trip in real time.", "Live GPS. Share ride status instantly.", 140, w // 2, 880)
    Image.alpha_composite(base, tmp).convert("RGB").save(
        OUT / "stories" / "story_02_tracking_vertical.png", "PNG", optimize=True
    )
    print("Wrote", OUT / "stories" / "story_02_tracking_vertical.png")


def build_story_03() -> None:
    w, h = 1080, 1920
    base = linear_gradient(w, h, (30, 24, 14), BLACK).convert("RGBA")
    glow = radial_glow(w, h, w // 2, 500, GOLD, 0.5)
    base = Image.alpha_composite(base, glow)
    logo = load_logo(220)
    base.paste(logo, ((w - logo.size[0]) // 2, 320), logo)
    tmp = Image.new("RGBA", base.size, (0, 0, 0, 0))
    paste_headline(
        tmp,
        "Premium rides built for Africa.",
        "Black-car calm. Honest pricing.",
        620,
        w // 2,
        880,
    )
    Image.alpha_composite(base, tmp).convert("RGB").save(
        OUT / "stories" / "story_03_premium_vertical.png", "PNG", optimize=True
    )
    print("Wrote", OUT / "stories" / "story_03_premium_vertical.png")


def build_story_04() -> None:
    w, h = 1080, 1920
    base = linear_gradient(w, h, BLACK, (15, 15, 18)).convert("RGBA")
    combined = Image.new("RGB", (520, 1200))
    combined.paste(render_rider_booking_screen(520, 600), (0, 0))
    combined.paste(render_driver_screen(520, 600), (0, 600))
    phone = phone_mosaic(combined, 520, 1120)
    base.alpha_composite(phone, ((w - phone.size[0]) // 2, 400))

    tmp = Image.new("RGBA", base.size, (0, 0, 0, 0))
    paste_headline(
        tmp,
        "Download NexRide.",
        "Rider & Driver - one ecosystem.",
        140,
        w // 2,
        820,
    )
    store_badges_horizontal(base, 1700, w // 2)
    Image.alpha_composite(base, tmp).convert("RGB").save(
        OUT / "stories" / "story_04_download_split.png", "PNG", optimize=True
    )
    print("Wrote", OUT / "stories" / "story_04_download_split.png")


# WhatsApp flyers — 1080 x 1350 (4:5 share card)

def build_wa_01() -> None:
    w, h = 1080, 1350
    base = linear_gradient(w, h, BLACK, (22, 20, 14)).convert("RGBA")
    screen = render_map_screen(840, 1000, "Lagos")
    phone = phone_mosaic(screen, 480, 640)
    base.alpha_composite(phone, ((w - phone.size[0]) // 2, 320))
    logo = load_logo(100)
    base.paste(logo, (50, 50), logo)
    tmp = Image.new("RGBA", base.size, (0, 0, 0, 0))
    paste_headline(tmp, "Share NexRide.", "Smarter rides for your crew in Lagos.", 80, w // 2, 900)
    Image.alpha_composite(base, tmp).convert("RGB").save(
        OUT / "whatsapp" / "whatsapp_01_rider_share_flyer.png", "PNG", optimize=True
    )
    print("Wrote", OUT / "whatsapp" / "whatsapp_01_rider_share_flyer.png")


def build_wa_02() -> None:
    w, h = 1080, 1350
    base = linear_gradient(w, h, (16, 16, 18), BLACK).convert("RGBA")
    scr = render_driver_screen(780, 1020)
    phone = phone_mosaic(scr, 520, 780)
    base.alpha_composite(phone, ((w - phone.size[0]) // 2, 280))
    logo = load_logo(96)
    base.paste(logo, (50, 50), logo)
    tmp = Image.new("RGBA", base.size, (0, 0, 0, 0))
    paste_headline(tmp, "Drive with NexRide.", "We're recruiting pro drivers in Lagos & Abuja.", 90, w // 2, 960)
    Image.alpha_composite(base, tmp).convert("RGB").save(
        OUT / "whatsapp" / "whatsapp_02_drivers_flyer.png", "PNG", optimize=True
    )
    print("Wrote", OUT / "whatsapp" / "whatsapp_02_drivers_flyer.png")


def build_wa_03() -> None:
    w, h = 1080, 1350
    base = linear_gradient(w, h, (28, 22, 10), BLACK).convert("RGBA")
    glow = radial_glow(w, h, w // 2, 200, GOLD, 0.6)
    base = Image.alpha_composite(base, glow)
    logo = load_logo(200)
    base.paste(logo, ((w - logo.size[0]) // 2, 160), logo)
    tmp = Image.new("RGBA", base.size, (0, 0, 0, 0))
    paste_headline(
        tmp,
        "NexRide is launching soon.",
        "Premium rides. Verified network. Built in Nigeria.",
        520,
        w // 2,
        900,
    )
    store_badges_horizontal(base, 1120, w // 2)
    Image.alpha_composite(base, tmp).convert("RGB").save(
        OUT / "whatsapp" / "whatsapp_03_launch_share_flyer.png", "PNG", optimize=True
    )
    print("Wrote", OUT / "whatsapp" / "whatsapp_03_launch_share_flyer.png")


def main() -> int:
    if not BRAND.is_dir():
        print("Missing branding folder:", BRAND, file=sys.stderr)
        return 1
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "feed").mkdir(exist_ok=True)
    (OUT / "stories").mkdir(exist_ok=True)
    (OUT / "whatsapp").mkdir(exist_ok=True)

    build_feed_hero_lagos()
    build_feed_premium_africa()
    build_feed_tracking()
    build_feed_verified_safety()
    build_feed_countdown()
    build_feed_drivers_wanted()
    build_story_01()
    build_story_02()
    build_story_03()
    build_story_04()
    build_wa_01()
    build_wa_02()
    build_wa_03()

    print("Done. 14 PNG files in", OUT)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
