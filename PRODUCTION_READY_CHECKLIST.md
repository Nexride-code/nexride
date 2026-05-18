# NexRide Production Ready Checklist

Controlled pilot gate — run before enabling production traffic or rebuilding store APKs.

## Ride flows

- [ ] 20 ride request flows (mix of markets and payment methods)
- [ ] 10 accept flows end-to-end (rider assigned, driver active trip, chat available)
- [ ] 5 decline → second driver accept flows
- [ ] 5 app-kill / reopen with active ride (driver + rider restore logs: `DRIVER_RESTORE_ACTIVE`, `RIDER_RESTORE_ACTIVE`)
- [ ] 3 weak-network flows (airplane mode toggle, accept timeout reconcile)
- [ ] 3 rider cancel during search / after assign
- [ ] 3 driver cancel / report flows

## Delivery flows

- [ ] 10 delivery flows (food + parcel)
- [ ] Merchant sees assigned driver on order detail (`MERCHANT_RESTORE_ACTIVE_DELIVERY`)
- [ ] Customer sees assigned driver (no stuck “Creating request” overlay)
- [ ] Driver pickup → complete lifecycle
- [ ] Merchant chat / call / report actions visible

## Admin recovery (no Firebase console)

- [ ] System Health → Matching drilldown shows `candidate_driver_samples` / `rejected_driver_samples`
- [ ] Active Operations / Rides drilldown opens trip
- [ ] Deliveries drilldown opens delivery + chat transcript
- [ ] Clear stale driver ride pointer (`adminClearDriverStaleActiveRide`)
- [ ] Rerun ride / delivery matching
- [ ] Cancel stale search
- [ ] Support ticket assign + resolve / escalate
- [ ] Offer audit visible (`driver_offer_audit/{rideId}/{driverId}`)

## Self-healing (backend scheduled)

After deploy, verify Cloud Scheduler / Functions logs for:

- [ ] `cleanStaleDriverActivePointers` — `PRODUCTION_CLEANUP` counts
- [ ] `cleanStaleSearchingRides`
- [ ] `cleanExpiredDriverOffers`
- [ ] `cleanOrphanActiveTrips`
- [ ] `cleanStaleDeliveryPointers`

## Automated tests (run locally)

```bash
cd nexride_driver/functions && npm test
cd /Users/lexemm/Projects/nexride/nexride_driver && flutter analyze
cd /Users/lexemm/Projects/nexride && flutter analyze
cd /Users/lexemm/Projects/nexride/nexride_merchant && flutter analyze
```

## Deploy order (when approved)

1. Deploy Cloud Functions (`production_cleanup_jobs`, `driver_active_pointer_guard`, matching fanout, admin health).
2. Verify scheduled jobs registered in Firebase console.
3. Rebuild and distribute: rider, driver, merchant APKs only after checklist pass.

## Known non-blockers

- App Check placeholder token in local dev — expected until App Check is configured for release builds.
