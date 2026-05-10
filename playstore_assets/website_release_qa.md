# Website QA — nexride.africa (release checklist)

**Production URL:** https://nexride.africa  
**Fallback Firebase URL:** https://nexride-8d5bc.web.app  

## Automated / manual checks

| Check | How | Pass criteria |
|--------|-----|----------------|
| **Home resolves** | Open `/` | Marketing hero loads; navigation works |
| **Responsive** | Resize / device toolbar | Readable on 360px width + desktop rail |
| **SEO** | View source `/` | `<title>`, `meta description`, `keywords`, `og:*` present (`website/web/index.html`) |
| **Privacy** | `/privacy` | Legal copy loads |
| **Terms** | `/terms` | Legal copy loads |
| **Contact** | `/contact` | `support@` / `info@` nexride.africa visible |
| **Social** | Footer | Instagram link works; placeholders disabled |
| **Trip share graceful error** | `/trip/test` (no token) | User sees incomplete-link error + “Back to home”; no JS crash |

## Trip tracking live URL shape

Canonical: **`https://nexride.africa/trip/{rideId}?token={token}`**

`/trip/test` without `?token=` should show the **graceful error** implemented in Flutter web (`TripLivePage`).

## Firebase Hosting behavior

Rewrites send app routes to `index.html` (SPA). **`/.well-known/*`** served as files with JSON content-type (`firebase.json`).

## After Hosting deploy

Re-run smoke tests on **custom domain** (not only `.web.app`) after DNS + SSL provisioning.
