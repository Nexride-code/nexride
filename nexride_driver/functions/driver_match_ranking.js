/**
 * Global ride matching: priority tiers, distance ranking, batch fan-out.
 * Data-driven from dispatch_market_id + service_area_city_id (all rollout regions).
 */

"use strict";

const {
  normUid,
  canonicalMarketSlug,
  resolveDriverAvailabilityMode,
  driverDispatchMarketId,
  rideDispatchMarketId,
  pickupCoordsFromRide,
  driverLastKnownCoords,
  haversineKm,
  buildDriverFanoutFilterTrace,
} = require("./driver_dispatch_gates");
const { locationModeLabel } = require("./driver_location_paths");

/** Drivers offered per fan-out round (Grab/Bolt-style sequential dispatch). */
const FANOUT_BATCH_SIZE = 5;

/**
 * Per-driver offer response window before next batch (production Phase 1).
 * Tune via app_config/nexride_dispatch.driver_offer_ttl_ms when needed.
 */
const DRIVER_OFFER_RESPONSE_TTL_MS = 30_000;

const PRIORITY_GPS_CLOSEST = 1;
const PRIORITY_AREA_SAME_CITY = 2;
const PRIORITY_AREA_SAME_MARKET = 3;
const PRIORITY_FALLBACK = 4;

function serviceCitySlugFromDriver(profile) {
  const d = profile && typeof profile === "object" ? profile : {};
  return canonicalMarketSlug(
    d.service_area_city_id ??
      d.rollout_city_id ??
      d.selected_service_area_id ??
      d.service_city_id ??
      "",
  );
}

function serviceCitySlugFromRide(ridePayload) {
  const r = ridePayload && typeof ridePayload === "object" ? ridePayload : {};
  return canonicalMarketSlug(
    r.resolved_service_city_id ?? r.service_city_id ?? r.rollout_city_id ?? "",
  );
}

/**
 * Distance from driver position (GPS or area center) to ride pickup.
 * @returns {number|null}
 */
function distanceToPickupKm(driverProfile, ridePayload) {
  const pickup = pickupCoordsFromRide(ridePayload);
  if (!Number.isFinite(pickup.lat) || !Number.isFinite(pickup.lng)) {
    return null;
  }
  const drv = driverLastKnownCoords(driverProfile);
  if (!Number.isFinite(drv.lat) || !Number.isFinite(drv.lng)) {
    return null;
  }
  const d = haversineKm(drv.lat, drv.lng, pickup.lat, pickup.lng);
  return Number.isFinite(d) ? d : null;
}

/**
 * Priority tier for offer ordering (lower = offered first).
 * @returns {{ priority_group: number, priority_label: string }}
 */
function computeDriverPriorityGroup(driverProfile, ridePayload) {
  const mode = resolveDriverAvailabilityMode(driverProfile);
  if (mode === "current_location") {
    return { priority_group: PRIORITY_GPS_CLOSEST, priority_label: "gps_closest" };
  }
  if (mode === "service_area") {
    const rideCity = serviceCitySlugFromRide(ridePayload);
    const driverCity = serviceCitySlugFromDriver(driverProfile);
    if (rideCity && driverCity && rideCity === driverCity) {
      return { priority_group: PRIORITY_AREA_SAME_CITY, priority_label: "area_same_city" };
    }
    return {
      priority_group: PRIORITY_AREA_SAME_MARKET,
      priority_label: "area_same_market_cross_city",
    };
  }
  return { priority_group: PRIORITY_FALLBACK, priority_label: "fallback_legacy" };
}

/**
 * Full per-driver match evaluation for fan-out + debug.
 * @param {string} driverId
 * @param {Record<string, unknown>} profile
 * @param {Record<string, unknown>} ridePayload
 * @param {object} gates
 * @param {number} nowMs
 * @param {{ activeRideId?: string|null, useSoft?: boolean }} [ctx]
 */
function evaluateDriverMatchCandidate(driverId, profile, ridePayload, gates, nowMs, ctx = {}) {
  const trace = buildDriverFanoutFilterTrace(
    driverId,
    profile,
    ridePayload,
    gates,
    nowMs,
    ctx,
  );
  const dist = distanceToPickupKm(profile, ridePayload);
  const base = {
    driverId: normUid(driverId),
    driver_id: normUid(driverId),
    dispatch_market_id: driverDispatchMarketId(profile) || null,
    service_area_city_id: serviceCitySlugFromDriver(profile) || null,
    ride_dispatch_market_id: rideDispatchMarketId(ridePayload) || null,
    ride_service_city_id: serviceCitySlugFromRide(ridePayload) || null,
    location_mode:
      locationModeLabel(profile?.location_mode ?? profile?.driver_availability_mode) ||
      null,
    distance_to_pickup_km: dist,
    allowed: trace.allowed === true,
    filtered_reason: trace.filtered_reason,
    priority_group: null,
    priority_label: null,
    online: trace.online,
    vehicle_type: trace.vehicle_type,
    active_ride: trace.active_ride,
  };
  if (!trace.allowed) {
    return base;
  }
  const pri = computeDriverPriorityGroup(profile, ridePayload);
  return {
    ...base,
    ...pri,
    allowed: true,
    filtered_reason: null,
  };
}

/**
 * Sort key: priority_group asc, then distance asc.
 */
function compareMatchCandidates(a, b) {
  const pgA = Number(a.priority_group ?? 99);
  const pgB = Number(b.priority_group ?? 99);
  if (pgA !== pgB) return pgA - pgB;
  const dA = Number(a.distance_to_pickup_km);
  const dB = Number(b.distance_to_pickup_km);
  const distA = Number.isFinite(dA) ? dA : 99999;
  const distB = Number.isFinite(dB) ? dB : 99999;
  if (distA !== distB) return distA - distB;
  const hbA = Number(a._profile?.last_active_at ?? a._profile?.last_seen_at ?? 0) || 0;
  const hbB = Number(b._profile?.last_active_at ?? b._profile?.last_seen_at ?? 0) || 0;
  if (hbA !== hbB) return hbB - hbA;
  const hA = Number(a.health_score ?? a._healthScore ?? 50);
  const hB = Number(b.health_score ?? b._healthScore ?? 50);
  if (hA !== hB) return hB - hA;
  return String(a.driver_id ?? "").localeCompare(String(b.driver_id ?? ""));
}

function sortEligibleCandidates(candidates) {
  return [...(candidates || [])].filter((c) => c && c.allowed === true).sort(compareMatchCandidates);
}

/**
 * Pick next batch of driver IDs, skipping exhausted / already offered this search.
 * @param {Array<object>} sortedEligible
 * @param {Set<string>} skipDriverIds
 * @param {number} batchSize
 */
function selectNextFanoutBatch(sortedEligible, skipDriverIds, batchSize = FANOUT_BATCH_SIZE) {
  const skip = skipDriverIds instanceof Set ? skipDriverIds : new Set();
  const out = [];
  for (const c of sortedEligible) {
    const id = normUid(c.driver_id);
    if (!id || skip.has(id)) continue;
    out.push({ driverId: id, profile: c._profile, candidate: c });
    if (out.length >= batchSize) break;
  }
  return out;
}

function deriveMatchingState({ eligibleCount, offersWritten, batchRemaining }) {
  if (eligibleCount === 0) return "blocked";
  if (offersWritten > 0) return "offers_active";
  if (batchRemaining > 0) return "waiting_next_batch";
  return "blocked";
}

module.exports = {
  FANOUT_BATCH_SIZE,
  DRIVER_OFFER_RESPONSE_TTL_MS,
  PRIORITY_GPS_CLOSEST,
  PRIORITY_AREA_SAME_CITY,
  PRIORITY_AREA_SAME_MARKET,
  PRIORITY_FALLBACK,
  serviceCitySlugFromDriver,
  serviceCitySlugFromRide,
  distanceToPickupKm,
  computeDriverPriorityGroup,
  evaluateDriverMatchCandidate,
  compareMatchCandidates,
  sortEligibleCandidates,
  selectNextFanoutBatch,
  deriveMatchingState,
};
