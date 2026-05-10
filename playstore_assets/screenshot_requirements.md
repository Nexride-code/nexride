# Google Play screenshot requirements — NexRide (Rider & Driver)

Reference: [Play Console graphic assets](https://support.google.com/googleplay/android-developer/answer/9866151) (verify current limits in Console; Google occasionally updates specs).

---

## Mandatory formats (phone)

| Asset | Requirement (typical) | Notes |
|--------|------------------------|-------|
| **Phone screenshots** | **2–8** screenshots | PNG or JPEG, **minimum 320px on shortest side**, **maximum 3840px** on longest side; **aspect ratio between 16:9 and 9:16** |
| **Feature graphic** | **1024 × 500** px | JPG or 24-bit PNG (no transparency) |

**Portrait apps:** Screenshots must be **portrait** unless you deliberately support landscape-only (NexRide is primarily **portrait** — capture vertically).

---

## Recommended capture resolutions (Portrait)

Production-quality defaults that satisfy min/max comfortably:

| Target | Resolution (portrait) | Use |
|--------|------------------------|-----|
| **Primary** | **1080 × 1920** (FHD) | Fast to produce; sharp on listings |
| **Optional HD+** | **1080 × 2400** or device-native | Matches modern notch devices |

Export at **72–144 DPI** equivalent; Play cares about pixels, not print DPI.

---

## Tablet / large screens (recommended, not always mandatory)

If you declare tablet support or want stronger conversion:

| Asset | Requirement (typical) |
|--------|------------------------|
| **7" tablet** | At least **1** screenshot (Google may prompt for tablet assets) |
| **10" tablet** | Optional additional set |

**Tablet resolutions (landscape or portrait per your UI):** e.g. **1600 × 2560** portrait or **2560 × 1600** landscape — stay within min/max side lengths above.

---

# RIDER APP — suggested screenshot set (8)

Capture on a **clean account** with **PII redacted** (blur plates/phone if needed).

1. **Onboarding / welcome** — value proposition, permissions explainer, or first-launch hero.
2. **Sign up / log in** — email/phone flow (mask sensitive fields).
3. **Map home** — centered on launch city; idle state with pickup cue.
4. **Pickup / drop-off** — destination entry, pinned pickup, route preview if shown.
5. **Fare estimate** — quote / confirmation panel before confirming request.
6. **Searching driver** — matching/searching animation or status.
7. **Driver assigned** — driver card, ETA, vehicle summary.
8. **Live trip** — on-trip map, progress, safety entry points.

**Stretch (swap in if you exceed 8 or rotate seasonally)**

9. **Payment** — method picker / card / bank-transfer context (no full card numbers).
10. **Trip history** — list of completed trips (blur addresses if policy requires).
11. **Support / help** — support center or ticket entry (no ticket IDs with PII).

---

# DRIVER APP — suggested screenshot set (8)

1. **Onboarding / welcome** — driver value prop or checklist.
2. **Driver login** — sign-in (mask fields).
3. **Go online** — online toggle, coverage / compliance hints.
4. **Incoming request** — offer card with fare/ETA (mock or sandbox ride).
5. **Navigation** — map + route to pickup or drop-off.
6. **Trip active** — on-trip state, rider summary, controls.
7. **Earnings** — summary / trip list (amounts can be demo).
8. **Support** — driver help or queue entry.

**Stretch**

9. **Wallet / payouts** — balance or payout status (demo values).

---

## Quality checklist

- **Same visual language** as production (dark/light as shipped).
- **No debug banners**, internal build labels, or “test” overlays.
- **Consistent status bar / notch** styling (prefer one device series per listing refresh).
- **Localized later:** duplicate sets per locale if you translate store listing.

---

## Optional: Promo video

- **YouTube URL** linked in Play Console; keep under policy (no misleading claims).
