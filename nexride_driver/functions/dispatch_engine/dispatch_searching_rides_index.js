/**
 * Active searching rides index — shard-aware, no ride_requests full scans.
 */

"use strict";

const { normUid, rideIsOpenForMatching, canonicalAssignedDriverId } = require("./dispatch_trip_state_engine");
const { normMarket, shardForKey, touchMarketShard, removeMarketShard } = require("./dispatch_shard_engine");
const { getDispatchGeneration } = require("./dispatch_generation_engine");

function searchingPath(market, shard, rideId) {
  return `dispatch_searching_rides/${market}/${shard}/${rideId}`;
}

async function indexSearchingRide(db, rideId, ride = {}) {
  const rid = normUid(rideId);
  if (!rid) return { indexed: false };

  const market = normMarket(
    ride.market_pool ?? ride.market ?? ride.dispatch_market_id ?? "",
  );
  if (!market) return { indexed: false, reason: "no_market" };

  if (!rideIsOpenForMatching(ride) || canonicalAssignedDriverId(ride)) {
    await removeSearchingRide(db, rideId, ride);
    return { indexed: false, reason: "not_searching" };
  }

  const shard = shardForKey(rid);
  const generation = Number(ride.dispatch_generation ?? 0) || (await getDispatchGeneration(db, rid));
  const row = {
    ride_id: rid,
    market,
    shard,
    created_at_ms: Number(ride.created_at_ms ?? ride.created_at ?? Date.now()) || Date.now(),
    generation,
    trip_state: String(ride.trip_state ?? ride.status ?? "").trim(),
    updated_at_ms: Date.now(),
  };

  await db.ref(searchingPath(market, shard, rid)).set(row);
  await touchMarketShard(db, market, rid, "searching", { generation });

  return { indexed: true, market, shard, generation };
}

async function removeSearchingRide(db, rideId, ride = {}) {
  const rid = normUid(rideId);
  if (!rid) return;

  const market = normMarket(
    ride.market_pool ??
      ride.market ??
      ride.dispatch_market_id ??
      ride._dispatch_market ??
      "",
  );

  if (market) {
    const shard = shardForKey(rid);
    await db.ref(searchingPath(market, shard, rid)).remove();
    await removeMarketShard(db, market, rid);
    return;
  }

  const snap = await db.ref("dispatch_searching_rides").get();
  if (!snap.exists()) return;
  const markets = snap.val() || {};
  for (const [m, shards] of Object.entries(markets)) {
    if (!shards || typeof shards !== "object") continue;
    for (const [shard, rides] of Object.entries(shards)) {
      if (rides && typeof rides === "object" && rides[rid]) {
        await db.ref(`dispatch_searching_rides/${m}/${shard}/${rid}`).remove();
      }
    }
  }
}

/**
 * List searching rides from index (shard iteration).
 */
async function listSearchingRidesFromIndex(db, options = {}) {
  const maxPerShard = Math.min(50, Math.max(1, Number(options.maxPerShard) || 8));
  const maxMarkets = Math.min(32, Math.max(1, Number(options.maxMarkets) || 16));
  const { listActiveMarkets, allShardIds } = require("./dispatch_shard_engine");

  const markets = options.markets || (await listActiveMarkets(db, maxMarkets));
  const out = [];

  for (const market of markets.slice(0, maxMarkets)) {
    for (const shard of allShardIds()) {
      if (out.length >= maxPerShard * maxMarkets) break;
      const snap = await db
        .ref(`dispatch_searching_rides/${market}/${shard}`)
        .limitToFirst(maxPerShard)
        .get();
      if (!snap.exists()) continue;
      const rows = snap.val() || {};
      for (const [rideId, meta] of Object.entries(rows)) {
        out.push({
          rideId: normUid(rideId),
          market,
          shard,
          meta: meta && typeof meta === "object" ? meta : {},
        });
      }
    }
  }

  return out;
}

/**
 * Legacy fallback — capped ride_requests scan when index is cold.
 */
async function legacyScanSearchingRides(db, cap = 80) {
  const { rideIsOpenForMatching, canonicalAssignedDriverId, normUid: norm } = require("./dispatch_trip_state_engine");
  const snap = await db.ref("ride_requests").limitToFirst(cap * 4).get();
  const rides = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  const out = [];
  for (const [rideId, ride] of Object.entries(rides)) {
    if (out.length >= cap) break;
    const rid = norm(rideId);
    if (!rid || !ride || typeof ride !== "object") continue;
    if (!rideIsOpenForMatching(ride)) continue;
    if (canonicalAssignedDriverId(ride)) continue;
    out.push({
      rideId: rid,
      market: normMarket(ride.market_pool ?? ride.market ?? ride.dispatch_market_id ?? ""),
      shard: shardForKey(rid),
      meta: { created_at_ms: ride.created_at_ms ?? ride.created_at },
      legacy: true,
    });
  }
  return out;
}

async function listSearchingRidesForTick(db, options = {}) {
  const indexed = await listSearchingRidesFromIndex(db, options);
  if (indexed.length > 0) return indexed;
  return legacyScanSearchingRides(db, options.cap || 80);
}

module.exports = {
  indexSearchingRide,
  removeSearchingRide,
  listSearchingRidesFromIndex,
  listSearchingRidesForTick,
  legacyScanSearchingRides,
};
