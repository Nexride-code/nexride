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
const rulesPath = join(__dirname, '..', '..', 'nexride_driver', 'database.rules.json');
const rules = readFileSync(rulesPath, 'utf8');

test('driver popup RTDB reads: offer queue, active ride marker, canonical ride', async () => {
  const testEnv = await initializeTestEnvironment({
    projectId: 'demo-nexride-driver-offer-popup',
    database: { rules },
  });

  try {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      const admin = ctx.database();
      await admin.ref('driver_offer_queue/driver1/ride_a').set({
        status: 'open',
        market: 'lagos',
        created_at: Date.now(),
        expires_at: Date.now() + 60000,
      });
      await admin.ref('driver_active_ride/driver1').set({
        ride_id: 'ride_stale',
        updated_at: Date.now(),
      });
      await admin.ref('ride_requests/ride_a').set({
        ride_id: 'ride_a',
        rider_id: 'rider1',
        driver_id: 'waiting',
        market: 'lagos',
        status: 'searching',
        trip_state: 'searching_driver',
      });
    });

    const driverDb = testEnv.authenticatedContext('driver1').database();

    await assertSucceeds(driverDb.ref('driver_offer_queue/driver1').get());
    await assertSucceeds(driverDb.ref('driver_active_ride/driver1').get());
    await assertSucceeds(driverDb.ref('ride_requests/ride_a').get());

    await assertFails(driverDb.ref('driver_offer_queue/driver2').get());
    await assertFails(driverDb.ref('ride_requests/ride_a').get());
  } finally {
    await testEnv.cleanup();
  }
});

test('driver cannot read ride_requests without offer queue membership', async () => {
  const testEnv = await initializeTestEnvironment({
    projectId: 'demo-nexride-driver-offer-no-queue',
    database: { rules },
  });

  try {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await ctx.database().ref('ride_requests/ride_b').set({
        ride_id: 'ride_b',
        rider_id: 'rider2',
        driver_id: 'waiting',
        status: 'searching',
      });
    });

    const driverDb = testEnv.authenticatedContext('driver1').database();
    await assertFails(driverDb.ref('ride_requests/ride_b').get());
  } finally {
    await testEnv.cleanup();
  }
});
