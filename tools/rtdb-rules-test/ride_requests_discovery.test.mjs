import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';

const __dirname = dirname(fileURLToPath(import.meta.url));
const rulesPath = join(__dirname, '..', '..', 'database.rules.json');
const rules = readFileSync(rulesPath, 'utf8');

test('ride_requests discovery (market_pool)', async (t) => {
  const testEnv = await initializeTestEnvironment({
    // Use a dedicated demo namespace for the emulator (avoids multi-namespace conflicts).
    projectId: 'demo-nexride-driver-rtdb',
    database: { rules },
  });

  try {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      const admin = ctx.database();
      await admin.ref('drivers/driver1').set({ uid: 'driver1', market: 'lagos' });
      await admin.ref('ride_requests/open_lagos_pending').set({
        ride_id: 'open_lagos_pending',
        rider_id: 'rider99',
        driver_id: 'waiting',
        market: 'lagos',
        market_pool: 'lagos',
        status: 'requesting',
        trip_state: 'requesting',
      });
      await admin.ref('ride_requests/completed_elsewhere').set({
        ride_id: 'completed_elsewhere',
        rider_id: 'rider88',
        driver_id: 'waiting',
        market: 'lagos',
        market_pool: 'abuja',
        status: 'completed',
        trip_state: 'trip_completed',
      });
      await admin.ref('ride_requests/cancelled_ride').set({
        ride_id: 'cancelled_ride',
        rider_id: 'rider66',
        driver_id: 'waiting',
        market: 'lagos',
        market_pool: 'lagos',
        status: 'cancelled',
        trip_state: 'cancelled',
      });
      await admin.ref('ride_requests/expired_ride').set({
        ride_id: 'expired_ride',
        rider_id: 'rider55',
        driver_id: 'waiting',
        market: 'lagos',
        market_pool: 'lagos',
        status: 'expired',
        trip_state: 'expired',
      });
      await admin.ref('ride_requests/rejected_ride').set({
        ride_id: 'rejected_ride',
        rider_id: 'rider44',
        driver_id: 'waiting',
        market: 'lagos',
        market_pool: 'lagos',
        status: 'rejected',
        trip_state: 'rejected',
      });
      await admin.ref('ride_requests/completed_lagos_terminal').set({
        ride_id: 'completed_lagos_terminal',
        rider_id: 'rider33',
        driver_id: 'waiting',
        market: 'lagos',
        market_pool: 'lagos',
        status: 'completed',
        trip_state: 'trip_completed',
      });
      await admin.ref('users/riderOnly').set({ role: 'rider' });
    });

    await t.test('driver can read own drivers/{uid} profile', async () => {
      const db = testEnv.authenticatedContext('driver1').database();
      await assertSucceeds(db.ref('drivers/driver1').get());
    });

    await t.test('driver cannot directly read open lagos ride (query-only discovery)', async () => {
      const db = testEnv.authenticatedContext('driver1').database();
      await assertFails(db.ref('ride_requests/open_lagos_pending').get());
    });

    await t.test('driver can read market_pool=lagos discovery query', async () => {
      const db = testEnv.authenticatedContext('driver1').database();
      const q = db.ref('ride_requests').orderByChild('market_pool').equalTo('lagos');
      await assertSucceeds(q.get());
    });

    await t.test('terminal rides in lagos do not break the discovery query', async () => {
      const db = testEnv.authenticatedContext('driver1').database();
      const q = db.ref('ride_requests').orderByChild('market_pool').equalTo('lagos');
      await assertSucceeds(q.get());
    });

    await t.test('unauthenticated user cannot read discovery query', async () => {
      const db = testEnv.unauthenticatedContext().database();
      const q = db.ref('ride_requests').orderByChild('market_pool').equalTo('lagos');
      await assertFails(q.get());
    });

    await t.test('authenticated rider without drivers profile cannot read discovery query', async () => {
      const db = testEnv.authenticatedContext('riderOnly').database();
      const q = db.ref('ride_requests').orderByChild('market_pool').equalTo('lagos');
      await assertFails(q.get());
    });

    await t.test('driver cannot read terminal completed ride by direct path', async () => {
      const db = testEnv.authenticatedContext('driver1').database();
      await assertFails(db.ref('ride_requests/completed_elsewhere').get());
    });

    await t.test('driver cannot read terminal cancelled/expired/rejected rides by direct path', async () => {
      const db = testEnv.authenticatedContext('driver1').database();
      await assertFails(db.ref('ride_requests/cancelled_ride').get());
      await assertFails(db.ref('ride_requests/expired_ride').get());
      await assertFails(db.ref('ride_requests/rejected_ride').get());
    });

    await t.test('driver cannot shallow-read entire ride_requests without query', async () => {
      const db = testEnv.authenticatedContext('driver1').database();
      await assertFails(db.ref('ride_requests').get());
    });

    await t.test('driver with mismatched market cannot run lagos discovery query', async () => {
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await ctx.database().ref('drivers/driver2').set({ uid: 'driver2', market: 'abuja' });
        await ctx.database().ref('ride_requests/only_lagos').set({
          ride_id: 'only_lagos',
          rider_id: 'rider77',
          driver_id: 'waiting',
          market: 'lagos',
          market_pool: 'lagos',
          status: 'requesting',
          trip_state: 'requesting',
        });
      });
      const db = testEnv.authenticatedContext('driver2').database();
      const q = db.ref('ride_requests').orderByChild('market_pool').equalTo('lagos');
      await assertFails(q.get());
    });
  } finally {
    await testEnv.cleanup();
  }
});
