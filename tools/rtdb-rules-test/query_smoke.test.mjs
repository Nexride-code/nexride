import test from 'node:test';
import { assertSucceeds, initializeTestEnvironment } from '@firebase/rules-unit-testing';

test('smoke: parent ride_requests .read enables orderByChild query', async () => {
  const testEnv = await initializeTestEnvironment({
    projectId: 'demo-nexride-driver-rtdb-smoke',
    database: {
      rules: JSON.stringify({
        rules: {
          drivers: {
            $uid: {
              '.read': 'auth != null && auth.uid === $uid',
              '.write': false,
            },
          },
          ride_requests: {
            '.read':
              "auth != null && root.child('drivers/' + auth.uid).exists() && query.orderByChild == 'market_pool' && query.startAt != null && query.endAt != null && query.startAt == query.endAt && query.startAt == root.child('drivers/' + auth.uid + '/market').val()",
            '.indexOn': ['market_pool'],
            $rideId: {
              '.read': 'auth != null',
            },
          },
        },
      }),
    },
  });
  try {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await ctx.database().ref('drivers/u1').set({ market: 'lagos' });
      await ctx.database().ref('ride_requests/x').set({ market_pool: 'lagos' });
    });
    const db = testEnv.authenticatedContext('u1').database();
    await assertSucceeds(
      db.ref('ride_requests').orderByChild('market_pool').equalTo('lagos').get(),
    );
  } finally {
    await testEnv.cleanup();
  }
});
