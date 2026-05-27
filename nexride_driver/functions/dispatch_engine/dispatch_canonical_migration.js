/**
 * One-time RTDB normalization: drivers, rides, online_drivers, dispatch_index.
 * Run via adminMigrateDispatchCanonicalGeography then remove alias query paths.
 */

"use strict";

const {
  normalizeDispatchKey,
  applyCanonicalDispatchGeoToRidePayload,
  applyCanonicalDispatchGeoToDriverUpdates,
  resolveCanonicalDispatchMarket,
} = require("./dispatch_geo_normalizer");
const {
  normalizeDispatchAvailabilityMode,
  DISPATCH_MODE_GPS,
  DISPATCH_MODE_SERVICE_AREA,
} = require("./dispatch_availability_modes");
const { syncDispatchIndexForDriver, clearDispatchIndexForDriver } = require("./dispatch_index_engine");

function normUid(uid) {
  return String(uid ?? "").trim();
}

/**
 * @param {Record<string, unknown>} row
 * @returns {Record<string, unknown>}
 */
function driverCanonicalPatch(row) {
  const d = row && typeof row === "object" ? row : {};
  const market = resolveCanonicalDispatchMarket(d);
  if (!market) return {};
  const mode = normalizeDispatchAvailabilityMode(
    d.dispatch_availability_mode ??
      d.driver_availability_mode ??
      d.availability_mode ??
      (String(d.location_mode ?? "").toLowerCase() === "gps"
        ? DISPATCH_MODE_GPS
        : String(d.location_mode ?? "").toLowerCase() === "area"
          ? DISPATCH_MODE_SERVICE_AREA
          : ""),
  );
  const updates = {};
  applyCanonicalDispatchGeoToDriverUpdates(updates, {
    canonical_market_id: market,
    region_id: d.rollout_region_id ?? d.service_area_region_id,
    city_id: d.rollout_city_id ?? d.service_area_city_id ?? d.canonical_city_id,
    country_code: "ng",
  });
  if (mode) {
    updates.dispatch_availability_mode = mode;
    updates.availability_mode = mode;
    updates.driver_availability_mode =
      mode === DISPATCH_MODE_GPS ? "current_location" : "service_area";
    updates.location_mode = mode === DISPATCH_MODE_GPS ? "gps" : "area";
  }
  const saId = String(
    d.service_area_id ?? d.canonical_service_area_id ?? d.selected_service_area_id ?? "",
  ).trim();
  if (saId) {
    updates.service_area_id = normalizeDispatchKey(saId);
    updates.canonical_service_area_id = updates.service_area_id;
    updates.selected_service_area_id = saId;
  }
  return updates;
}

/**
 * @param {import("firebase-admin/database").Database} db
 * @param {{ dryRun?: boolean, limit?: number }} [options]
 */
async function migrateDispatchCanonicalGeography(db, options = {}) {
  const dryRun = options.dryRun === true;
  const limit = Math.min(Math.max(Number(options.limit) || 5000, 1), 20000);
  const stats = {
    drivers_patched: 0,
    rides_patched: 0,
    online_drivers_patched: 0,
    index_synced: 0,
    index_cleared: 0,
    dry_run: dryRun,
  };
  const batch = {};

  const driversSnap = await db.ref("drivers").limitToFirst(limit).get();
  const drivers =
    driversSnap.exists() && typeof driversSnap.val() === "object" ? driversSnap.val() : {};
  for (const [id, row] of Object.entries(drivers)) {
    const uid = normUid(id);
    if (!uid || !row || typeof row !== "object") continue;
    const patch = driverCanonicalPatch(row);
    if (!Object.keys(patch).length) continue;
    stats.drivers_patched += 1;
    if (!dryRun) {
      for (const [k, v] of Object.entries(patch)) {
        batch[`drivers/${uid}/${k}`] = v;
      }
      const online =
        row.is_online === true || row.online === true || row.isOnline === true;
      const market = resolveCanonicalDispatchMarket({ ...row, ...patch });
      if (online && market) {
        await syncDispatchIndexForDriver(db, uid, market);
        stats.index_synced += 1;
      } else {
        await clearDispatchIndexForDriver(db, uid);
        stats.index_cleared += 1;
      }
    }
  }

  const ridesSnap = await db.ref("ride_requests").limitToFirst(limit).get();
  const rides =
    ridesSnap.exists() && typeof ridesSnap.val() === "object" ? ridesSnap.val() : {};
  for (const [rid, row] of Object.entries(rides)) {
    const rideId = normUid(rid);
    if (!rideId || !row || typeof row !== "object") continue;
    const market = resolveCanonicalDispatchMarket(row);
    if (!market) continue;
    const payload = { ...row };
    applyCanonicalDispatchGeoToRidePayload(payload, {
      canonical_market_id: market,
      region_id: row.resolved_service_region_id ?? row.rollout_region_id,
      city_id: row.resolved_service_city_id ?? row.service_city_id,
      country_code: "ng",
    });
    stats.rides_patched += 1;
    if (!dryRun) {
      batch[`ride_requests/${rideId}`] = payload;
    }
  }

  const onlineSnap = await db.ref("online_drivers").get();
  const online =
    onlineSnap.exists() && typeof onlineSnap.val() === "object" ? onlineSnap.val() : {};
  for (const [id, row] of Object.entries(online)) {
    const uid = normUid(id);
    if (!uid || !row || typeof row !== "object") continue;
    const prof = drivers[uid] || {};
    const merged = { ...prof, ...row };
    const patch = driverCanonicalPatch(merged);
    if (!Object.keys(patch).length) continue;
    stats.online_drivers_patched += 1;
    if (!dryRun) {
      for (const [k, v] of Object.entries(patch)) {
        batch[`online_drivers/${uid}/${k}`] = v;
      }
    }
  }

  if (!dryRun && Object.keys(batch).length) {
    const keys = Object.keys(batch);
    const chunk = 400;
    for (let i = 0; i < keys.length; i += chunk) {
      const slice = {};
      for (const k of keys.slice(i, i + chunk)) {
        slice[k] = batch[k];
      }
      await db.ref().update(slice);
    }
  }

  console.log("DISPATCH_CANONICAL_MIGRATION_DONE", JSON.stringify(stats));
  return { success: true, stats };
}

module.exports = {
  migrateDispatchCanonicalGeography,
  driverCanonicalPatch,
};
