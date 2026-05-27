/**
 * Healthy available driver index — shard + geohash buckets.
 */

"use strict";

const { normUid } = require("./dispatch_trip_state_engine");
const { normMarket, shardForKey, touchMarketShard } = require("./dispatch_shard_engine");
const { encodeGeohash, geohashNeighbors, haversineKm } = require("./dispatch_geohash_engine");
const { computeDriverHealthScore } = require("./dispatch_health_engine");

const MIN_HEALTH_SCORE = 0.35;

function driverPath(market, shard, driverId) {
  return `dispatch_available_drivers/${market}/${shard}/${driverId}`;
}

function geoBucketPath(market, geohash, driverId) {
  return `dispatch_geo_buckets/${market}/${geohash}/${driverId}`;
}

function isDriverOnline(profile) {
  if (!profile || typeof profile !== "object") return false;
  if (profile.is_online === true || profile.isOnline === true || profile.online === true) {
    return true;
  }
  const status = String(profile.status ?? "").trim().toLowerCase();
  if (status === "online" || status === "available" || status === "online_available") {
    return true;
  }
  const dispatchState = String(profile.dispatch_state ?? "").trim().toLowerCase();
  if (
    dispatchState === "online" ||
    dispatchState === "available" ||
    dispatchState === "online_available"
  ) {
    return true;
  }
  return false;
}

async function upsertAvailableDriver(db, driverId, profile = {}, options = {}) {
  const d = normUid(driverId);
  if (!d || !profile || typeof profile !== "object") return { indexed: false };

  const market = normMarket(
    profile.dispatch_market_id ??
      profile.dispatch_market ??
      profile.market_pool ??
      options.market ??
      "",
  );
  if (!market) return { indexed: false, reason: "no_market" };

  if (!isDriverOnline(profile)) {
    await removeAvailableDriver(db, d, { market });
    return { indexed: false, reason: "offline" };
  }

  const lat = Number(profile.lat ?? profile.latitude ?? profile.location?.lat ?? "");
  const lng = Number(profile.lng ?? profile.longitude ?? profile.location?.lng ?? "");
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
    return { indexed: false, reason: "no_location" };
  }

  const healthScore =
    Number(options.health_score) > 0
      ? Number(options.health_score)
      : await computeDriverHealthScore(db, d, profile);
  if (healthScore < MIN_HEALTH_SCORE && !options.force) {
    await removeAvailableDriver(db, d, { market });
    return { indexed: false, reason: "low_health" };
  }

  const shard = shardForKey(d);
  const geohash = encodeGeohash(lat, lng, 6);
  const now = Date.now();
  const heartbeat = Math.max(
    Number(profile.last_active_at ?? 0) || 0,
    Number(profile.last_seen_at ?? 0) || 0,
    Number(profile.presence_heartbeat_at ?? 0) || 0,
  );

  const row = {
    driver_id: d,
    market,
    shard,
    lat,
    lng,
    geohash,
    health_score: healthScore,
    heartbeat_at_ms: heartbeat || now,
    vehicle_type: String(profile.vehicle_type ?? profile.vehicleType ?? "").trim() || null,
    generation: Number(profile.last_offer_generation ?? 0) || 0,
    indexed_at_ms: now,
  };

  await db.ref(driverPath(market, shard, d)).set(row);
  await db.ref(geoBucketPath(market, geohash, d)).set({
    driver_id: d,
    lat,
    lng,
    health_score: healthScore,
    heartbeat_at_ms: heartbeat,
  });
  await touchMarketShard(db, market, d, "driver", { health_score: healthScore });

  return { indexed: true, market, shard, geohash, health_score: healthScore };
}

async function removeAvailableDriver(db, driverId, options = {}) {
  const d = normUid(driverId);
  if (!d) return;
  const market = normMarket(options.market ?? "");
  if (market) {
    const shard = shardForKey(d);
    const snap = await db.ref(driverPath(market, shard, d)).get();
    const row = snap.val() || {};
    await db.ref(driverPath(market, shard, d)).remove();
    if (row.geohash) {
      await db.ref(geoBucketPath(market, row.geohash, d)).remove();
    }
    return;
  }
  await db.ref(`dispatch_available_drivers`).child(d).remove().catch(() => {});
}

/**
 * Load candidate driver stubs near pickup via geohash + shard.
 */
async function loadAvailableDriversNearPickup(db, market, lat, lng, options = {}) {
  const m = normMarket(market);
  if (!m || !Number.isFinite(Number(lat)) || !Number.isFinite(Number(lng))) {
    return {};
  }

  const radiusKm = Number(options.radiusKm) > 0 ? Number(options.radiusKm) : 12;
  const precision = Number(options.geohashPrecision) || 5;
  const centerHash = encodeGeohash(lat, lng, precision);
  const hashes = geohashNeighbors(centerHash);
  const minHealth = options.fastRecovery
    ? Math.max(MIN_HEALTH_SCORE, 0.5)
    : MIN_HEALTH_SCORE;

  const candidates = new Map();

  for (const gh of hashes) {
    const snap = await db.ref(`dispatch_geo_buckets/${m}/${gh}`).limitToFirst(80).get();
    if (!snap.exists()) continue;
    const rows = snap.val() || {};
    for (const [driverId, row] of Object.entries(rows)) {
      const id = normUid(driverId);
      if (!id || !row) continue;
      const dist = haversineKm(lat, lng, row.lat, row.lng);
      if (dist > radiusKm) continue;
      const hs = Number(row.health_score ?? 0) || 0;
      if (hs < minHealth) continue;
      candidates.set(id, { ...row, distance_km: dist, driver_id: id });
    }
  }

  const pickupShard = shardForKey(`pickup_${lat}_${lng}`);
  const shardSnap = await db
    .ref(`dispatch_available_drivers/${m}/${pickupShard}`)
    .limitToFirst(60)
    .get();
  if (shardSnap.exists()) {
    const rows = shardSnap.val() || {};
    for (const [driverId, row] of Object.entries(rows)) {
      const id = normUid(driverId);
      if (!id || !row) continue;
      const dist = haversineKm(lat, lng, row.lat, row.lng);
      if (dist > radiusKm) continue;
      if ((Number(row.health_score ?? 0) || 0) < minHealth) continue;
      candidates.set(id, { ...row, distance_km: dist, driver_id: id });
    }
  }

  if (candidates.size === 0) return {};

  const profiles = {};
  const ids = [...candidates.keys()].slice(0, 120);
  for (const id of ids) {
    const profSnap = await db.ref(`drivers/${id}`).get();
    const onlineSnap = await db.ref(`online_drivers/${id}`).get();
    const prof = profSnap.val() && typeof profSnap.val() === "object" ? profSnap.val() : {};
    const online =
      onlineSnap.val() && typeof onlineSnap.val() === "object" ? onlineSnap.val() : {};
    profiles[id] = { ...prof, ...online, _index_distance_km: candidates.get(id)?.distance_km };
  }

  return profiles;
}

module.exports = {
  upsertAvailableDriver,
  removeAvailableDriver,
  loadAvailableDriversNearPickup,
  MIN_HEALTH_SCORE,
};
