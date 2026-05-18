/**
 * Config-driven dispatch parameters (no hardcoded TTLs in fan-out).
 */

"use strict";

const CONFIG_PATH = "app_config/nexride_dispatch";

const DEFAULTS = {
  driver_offer_lease_ms: 8_000,
  driver_offer_retry_ms: 5_000,
  driver_offer_batch_size: 5,
  driver_offer_max_attempts: 12,
  matching_retry_radius_km: 8,
  stale_driver_heartbeat_ms: 90_000,
  stale_searching_ride_ms: 8 * 60 * 1000,
};

let cache = null;
let cacheAt = 0;
const CACHE_TTL_MS = 4_000;

function clampInt(v, min, max, fallback) {
  const n = Number(v);
  if (!Number.isFinite(n)) return fallback;
  return Math.min(max, Math.max(min, Math.round(n)));
}

function parseConfig(raw) {
  const c = raw && typeof raw === "object" ? raw : {};
  return {
    driver_offer_lease_ms: clampInt(
      c.driver_offer_lease_ms ?? c.driver_offer_ttl_ms,
      3_000,
      120_000,
      DEFAULTS.driver_offer_lease_ms,
    ),
    driver_offer_retry_ms: clampInt(
      c.driver_offer_retry_ms,
      2_000,
      60_000,
      DEFAULTS.driver_offer_retry_ms,
    ),
    driver_offer_batch_size: clampInt(
      c.driver_offer_batch_size,
      1,
      20,
      DEFAULTS.driver_offer_batch_size,
    ),
    driver_offer_max_attempts: clampInt(
      c.driver_offer_max_attempts,
      1,
      50,
      DEFAULTS.driver_offer_max_attempts,
    ),
    matching_retry_radius_km: clampInt(
      c.matching_retry_radius_km,
      1,
      50,
      DEFAULTS.matching_retry_radius_km,
    ),
    stale_driver_heartbeat_ms: clampInt(
      c.stale_driver_heartbeat_ms,
      30_000,
      300_000,
      DEFAULTS.stale_driver_heartbeat_ms,
    ),
    stale_searching_ride_ms: clampInt(
      c.stale_searching_ride_ms,
      60_000,
      30 * 60_000,
      DEFAULTS.stale_searching_ride_ms,
    ),
  };
}

async function loadDispatchConfig(db) {
  const now = Date.now();
  if (cache && now - cacheAt < CACHE_TTL_MS) {
    return cache;
  }
  let parsed = { ...DEFAULTS };
  try {
    const snap = await db.ref(CONFIG_PATH).get();
    if (snap.exists()) {
      parsed = parseConfig(snap.val());
    }
  } catch (_) {
    parsed = { ...DEFAULTS };
  }
  cache = parsed;
  cacheAt = now;
  return parsed;
}

function clearDispatchConfigCache() {
  cache = null;
  cacheAt = 0;
}

module.exports = {
  CONFIG_PATH,
  DEFAULTS,
  loadDispatchConfig,
  clearDispatchConfigCache,
  parseConfig,
};
