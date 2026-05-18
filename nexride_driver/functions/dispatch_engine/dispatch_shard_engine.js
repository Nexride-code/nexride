/**
 * Market partitions — consistent hashing into 32 shards (0–31).
 */

"use strict";

const SHARD_COUNT = 32;

function normMarket(market) {
  return String(market ?? "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9_-]/g, "_");
}

function shardForKey(key) {
  const s = String(key ?? "");
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return (h >>> 0) % SHARD_COUNT;
}

function shardPath(market, key) {
  const m = normMarket(market);
  if (!m) return null;
  return { market: m, shard: shardForKey(key) };
}

function allShardIds() {
  return Array.from({ length: SHARD_COUNT }, (_, i) => i);
}

/**
 * Touch shard membership row for a ride or driver.
 */
async function touchMarketShard(db, market, key, kind, payload = {}) {
  const p = shardPath(market, key);
  if (!p) return null;
  const id = String(key ?? "").trim();
  if (!id) return null;
  await db.ref(`dispatch_market_shards/${p.market}/${p.shard}/${id}`).update({
    kind,
    updated_at_ms: Date.now(),
    ...payload,
  });
  await db.ref(`dispatch_active_markets/${p.market}`).update({
    last_touch_at_ms: Date.now(),
  });
  return p;
}

async function removeMarketShard(db, market, key) {
  const p = shardPath(market, key);
  if (!p) return;
  const id = String(key ?? "").trim();
  if (!id) return;
  await db.ref(`dispatch_market_shards/${p.market}/${p.shard}/${id}`).remove();
}

async function listActiveMarkets(db, limit = 64) {
  const snap = await db.ref("dispatch_active_markets").limitToFirst(limit).get();
  if (!snap.exists()) return [];
  const rows = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  return Object.keys(rows).map(normMarket).filter(Boolean);
}

module.exports = {
  SHARD_COUNT,
  normMarket,
  shardForKey,
  shardPath,
  allShardIds,
  touchMarketShard,
  removeMarketShard,
  listActiveMarkets,
};
