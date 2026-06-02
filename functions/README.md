# Deprecated deploy root

Firebase Cloud Functions deploy from the repo root uses **`nexride_driver/functions`** (see `firebase.json`).

This `functions/` directory is not uploaded on deploy. Canonical implementations:

- `completeTrip`, ride callables → `nexride_driver/functions/ride_callables.js`
- `driverConfirmBankTransferPayment` → `nexride_driver/functions/production_ops_callables.js`
- `createTripShareToken` → `nexride_driver/functions/track_public.js`
- Exports → `nexride_driver/functions/index.js`

Deploy example:

```bash
cd ~/Projects/nexride
firebase deploy --only functions:createTripShareToken,functions:completeTrip,functions:driverConfirmBankTransferPayment
```
