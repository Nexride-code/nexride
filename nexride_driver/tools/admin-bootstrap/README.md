# NexRide Admin Bootstrap

This utility promotes a Firebase Auth user to a NexRide admin without using client-side app code.

It supports both admin paths that are already wired into the app:

- Realtime Database allowlist: `/admins/{uid} = true`
- Firebase Auth custom claim: `admin: true`

Recommended production path:

- Use the Firebase custom claim as the primary admin control.
- Optionally also write `/admins/{uid} = true` as an operational fallback.

## Current app support

The current admin gate accepts both:

- `/admins/{uid}` in Realtime Database
- `admin: true` in Firebase custom claims

That means this app is currently wired for both methods, not just one.

## Files

- Script: `tools/admin-bootstrap/grant_admin.js`
- Script: `tools/admin-bootstrap/create_admin_account.js`
- Package manifest: `tools/admin-bootstrap/package.json`

## 1. Install the backend dependency

Run this once:

```bash
cd /Users/lexemm/nexride/nexride_driver/tools/admin-bootstrap
npm install
```

## 2. Add Firebase service account credentials

Put a Firebase service account JSON in one of these ways:

Preferred:

```bash
export GOOGLE_APPLICATION_CREDENTIALS="/absolute/path/to/service-account.json"
```

Or place it directly at:

```bash
/Users/lexemm/nexride/nexride_driver/tools/admin-bootstrap/service-account.json
```

Optional overrides:

```bash
export FIREBASE_SERVICE_ACCOUNT_PATH="/absolute/path/to/service-account.json"
export FIREBASE_DATABASE_URL="https://nexride-8d5bc-default-rtdb.firebaseio.com"
export FIREBASE_PROJECT_ID="nexride-8d5bc"
```

Important:

- Never commit the service account file
- The repo `.gitignore` already ignores `tools/admin-bootstrap/service-account.json`

## 3. Grant admin access

### By UID, both methods

```bash
cd /Users/lexemm/nexride/nexride_driver/tools/admin-bootstrap
node grant_admin.js --uid YOUR_FIREBASE_UID --both
```

### By email, both methods

```bash
cd /Users/lexemm/nexride/nexride_driver/tools/admin-bootstrap
node grant_admin.js --email you@example.com --both
```

### Only write Realtime Database allowlist

```bash
cd /Users/lexemm/nexride/nexride_driver/tools/admin-bootstrap
node grant_admin.js --uid YOUR_FIREBASE_UID --db-only
```

This writes:

```json
{
  "admins": {
    "YOUR_FIREBASE_UID": true
  }
}
```

### Only set Firebase custom claim

```bash
cd /Users/lexemm/nexride/nexride_driver/tools/admin-bootstrap
node grant_admin.js --uid YOUR_FIREBASE_UID --claims-only
```

This sets:

```json
{
  "admin": true
}
```

## 4. Revoke admin access

### Revoke both methods

```bash
cd /Users/lexemm/nexride/nexride_driver/tools/admin-bootstrap
node grant_admin.js --uid YOUR_FIREBASE_UID --both --revoke
```

### Revoke only allowlist

```bash
cd /Users/lexemm/nexride/nexride_driver/tools/admin-bootstrap
node grant_admin.js --uid YOUR_FIREBASE_UID --db-only --revoke
```

### Revoke only custom claim

```bash
cd /Users/lexemm/nexride/nexride_driver/tools/admin-bootstrap
node grant_admin.js --uid YOUR_FIREBASE_UID --claims-only --revoke
```

## 5. Verify the admin was created

The script prints both verification results after it runs:

- Realtime Database `/admins/{uid}`
- Firebase Auth custom claim `admin`

You can also verify manually:

### Realtime Database

Check:

```json
{
  "admins": {
    "YOUR_FIREBASE_UID": true
  }
}
```

### Custom claims

Use the Firebase Console or Admin SDK to confirm the user has:

```json
{
  "admin": true
}
```

### App-level verification

1. Start the app
2. Open `/admin/login`
3. Sign in with that Firebase Auth user
4. You should be redirected to `/admin`

If you changed custom claims on an already signed-in user, sign out and sign back in so a fresh ID token is issued.

## Quick examples

Create or update the default admin account:

```bash
cd /Users/lexemm/nexride/nexride_driver/tools/admin-bootstrap
node create_admin_account.js
```

Create a specific admin account with a fixed password:

```bash
cd /Users/lexemm/nexride/nexride_driver/tools/admin-bootstrap
node create_admin_account.js --email ops@nexride.com --password "StrongPass123!"
```

Grant admin by email using both methods:

```bash
cd /Users/lexemm/nexride/nexride_driver/tools/admin-bootstrap
node grant_admin.js --email admin@nexride.com --both
```

Grant only `/admins/{uid}`:

```bash
cd /Users/lexemm/nexride/nexride_driver/tools/admin-bootstrap
node grant_admin.js --uid YOUR_FIREBASE_UID --db-only
```

Grant only custom claim:

```bash
cd /Users/lexemm/nexride/nexride_driver/tools/admin-bootstrap
node grant_admin.js --uid YOUR_FIREBASE_UID --claims-only
```
