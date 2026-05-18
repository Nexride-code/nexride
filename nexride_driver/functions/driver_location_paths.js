/**
 * Canonical RTDB location writes for drivers (GPS vs area mode).
 */

"use strict";

function canonicalDispatchMarket(raw) {
  return String(raw ?? "")
    .trim()
    .toLowerCase()
    .replace(/\s+/g, "_")
    .replace(/-+/g, "_");
}

function normalizeAvailabilityMode(raw) {
  const m = String(raw ?? "")
    .trim()
    .toLowerCase()
    .replace(/-/g, "_");
  if (m === "current_location" || m === "gps" || m === "current") return "current_location";
  if (m === "service_area" || m === "servicearea" || m === "city" || m === "area") {
    return "service_area";
  }
  if (m === "offline") return "offline";
  return "";
}

/** @returns {"gps"|"area"|""} */
function locationModeLabel(availabilityMode) {
  const m = normalizeAvailabilityMode(availabilityMode);
  if (m === "current_location") return "gps";
  if (m === "service_area") return "area";
  return "";
}

/**
 * @param {object} params
 * @returns {Record<string, unknown>}
 */
function buildDriverLocationRecord({
  lat,
  lng,
  availabilityMode,
  serviceRegionId,
  serviceCityId,
  dispatchMarketId,
  updatedAtMs,
  accuracy,
  heading,
}) {
  const mode = locationModeLabel(availabilityMode);
  const market = canonicalDispatchMarket(dispatchMarketId || "");
  const record = {
    lat: Number.isFinite(lat) ? lat : null,
    lng: Number.isFinite(lng) ? lng : null,
    location_mode: mode || null,
    service_area_region_id: String(serviceRegionId ?? "").trim() || null,
    service_area_city_id: String(serviceCityId ?? "").trim() || null,
    dispatch_market_id: market || null,
    updated_at: updatedAtMs,
  };
  if (accuracy != null && Number.isFinite(Number(accuracy))) {
    record.accuracy = Number(accuracy);
  }
  if (heading != null && Number.isFinite(Number(heading))) {
    record.heading = Number(heading);
  }
  return record;
}

/**
 * Multi-path update for drivers/{id}, driver_locations/{id}, online_drivers/{id}.
 * @param {string} driverId
 * @param {object} record from buildDriverLocationRecord
 * @param {object} [driverExtras] merged into drivers/{id}
 */
function locationPathUpdates(driverId, record, driverExtras = {}) {
  const id = String(driverId ?? "").trim();
  if (!id) return {};
  const paths = {};
  const driverMerge = {
    ...driverExtras,
    lat: record.lat,
    lng: record.lng,
    location_mode: record.location_mode,
    service_area_region_id: record.service_area_region_id,
    service_area_city_id: record.service_area_city_id,
    dispatch_market_id: record.dispatch_market_id,
    updated_at: record.updated_at,
  };
  if (record.accuracy != null) driverMerge.location_accuracy = record.accuracy;
  if (record.heading != null) driverMerge.heading = record.heading;
  if (record.location_mode === "gps") {
    driverMerge.last_location =
      Number.isFinite(record.lat) && Number.isFinite(record.lng)
        ? { lat: record.lat, lng: record.lng }
        : null;
    driverMerge.last_location_updated_at = record.updated_at;
  }
  for (const [k, v] of Object.entries(driverMerge)) {
    paths[`drivers/${id}/${k}`] = v;
  }
  paths[`driver_locations/${id}`] = record;
  paths[`online_drivers/${id}`] = {
    is_online: driverExtras.is_online === true || driverExtras.isOnline === true,
    availability_mode: normalizeAvailabilityMode(driverExtras.driver_availability_mode),
    location_mode: record.location_mode,
    dispatch_market_id: record.dispatch_market_id,
    service_area_region_id: record.service_area_region_id,
    service_area_city_id: record.service_area_city_id,
    lat: record.lat,
    lng: record.lng,
    updated_at: record.updated_at,
  };
  return paths;
}

module.exports = {
  normalizeAvailabilityMode,
  locationModeLabel,
  buildDriverLocationRecord,
  locationPathUpdates,
};
