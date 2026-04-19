# NexRide Admin Portal

This repo now includes a standalone Flutter web entrypoint for NexRide Admin.

## Local run

Preferred Chrome run:

```bash
flutter run -d chrome -t lib/main_admin.dart
```

Explicit web-server run:

```bash
flutter run -d web-server -t lib/main_admin.dart --web-hostname 127.0.0.1 --web-port 7357
```

## Local routes

- `/` -> admin login when signed out, dashboard when an admin session already exists
- `/login` -> admin login
- `/dashboard` -> admin dashboard
- `/riders`
- `/drivers`
- `/trips`
- `/finance`
- `/withdrawals`
- `/pricing`
- `/subscriptions`
- `/verification`
- `/support`
- `/settings`

## Build admin web

Preferred production build for a dedicated admin host such as `admin.nexride.com`:

```bash
flutter build web -t lib/main_admin.dart --release -o build/admin_web
```

Fallback build for serving the standalone admin portal from `/admin` on an existing host:

```bash
flutter build web -t lib/main_admin.dart --release -o build/admin_web --base-href /admin/
```

## Deploy to Firebase Hosting

Map the Firebase Hosting target once:

```bash
firebase target:apply hosting admin YOUR_ADMIN_SITE_ID
```

Then deploy the admin portal:

```bash
firebase deploy --only hosting:admin
```

The repo-level hosting rewrite in `firebase.json` is configured as an SPA rewrite so direct browser refreshes for `/login`, `/dashboard`, and all admin routes resolve to `index.html`.

## Firebase web config

The current code reads web Firebase settings from `lib/firebase_options.dart`. If you have a dedicated Firebase web app for production, pass its values at build time:

```bash
flutter build web -t lib/main_admin.dart --release -o build/admin_web \
  --dart-define=NEXRIDE_FIREBASE_WEB_API_KEY=YOUR_WEB_API_KEY \
  --dart-define=NEXRIDE_FIREBASE_WEB_APP_ID=YOUR_WEB_APP_ID \
  --dart-define=NEXRIDE_FIREBASE_WEB_AUTH_DOMAIN=YOUR_AUTH_DOMAIN \
  --dart-define=NEXRIDE_FIREBASE_WEB_DATABASE_URL=YOUR_DATABASE_URL
```

## Admin access

Admin authentication uses Firebase Auth email/password. Authorization accepts either of these:

- Realtime Database allowlist: `/admins/{uid} = true`
- Firebase custom claims: `admin: true`

The standalone admin app never boots the driver shell, never restores the driver workspace, and never routes into the driver map flow.
