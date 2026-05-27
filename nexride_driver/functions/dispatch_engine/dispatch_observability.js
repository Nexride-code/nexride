/**
 * Production dispatch observability — console only.
 */

"use strict";

const { dispatchModeLogLabel } = require("./dispatch_availability_modes");
const { resolveCanonicalDispatchMarket } = require("./dispatch_geo_normalizer");

/**
 * @param {string} rideId
 * @param {Record<string, unknown>} ride
 */
function logDispatchRideContext(rideId, ride) {
  const r = ride && typeof ride === "object" ? ride : {};
  console.log(
    "DISPATCH_RIDE_CONTEXT",
    `rideId=${String(rideId ?? r.ride_id ?? "").trim()}`,
    `canonical_market_id=${resolveCanonicalDispatchMarket(r) || "(empty)"}`,
    `service_area_id=${String(r.resolved_service_city_id ?? r.service_city_id ?? "").trim() || "(empty)"}`,
  );
}

/**
 * @param {string} driverId
 * @param {Record<string, unknown>} driver
 * @param {{ source?: string, inGrace?: boolean, gpsActive?: boolean }} [coords]
 */
function logDispatchDriverContext(driverId, driver, coords = {}) {
  const d = driver && typeof driver === "object" ? driver : {};
  const mode = String(d.dispatch_availability_mode ?? d.availability_mode ?? "").trim();
  const usingFallback = Boolean(
    coords.source &&
      coords.source !== "current_location" &&
      coords.source !== "last_location",
  );
  console.log(
    "DISPATCH_DRIVER_CONTEXT",
    `driverId=${String(driverId ?? "").trim()}`,
    `canonical_market_id=${resolveCanonicalDispatchMarket(d) || "(empty)"}`,
    `availabilityMode=${dispatchModeLogLabel(mode) || "(legacy)"}`,
    `gps_active=${d.gps_active === true ? "true" : "false"}`,
    `using_fallback_coords=${usingFallback ? "true" : "false"}`,
    `coord_source=${coords.source || "none"}`,
    `in_grace=${coords.inGrace === true ? "true" : "false"}`,
  );
}

/**
 * Map internal filter trace to production rejection reason keys.
 * @param {string} filteredReason
 */
function canonicalMatchRejectReason(filteredReason) {
  const r = String(filteredReason ?? "").trim().toLowerCase();
  if (!r) return "unknown";
  if (r.includes("market_mismatch") || r.includes("dispatch_market_mismatch")) {
    return "market_mismatch";
  }
  if (r.includes("service_area")) return "service_area_mismatch";
  if (r.includes("gps_unavailable")) return "gps_unavailable_for_gps_mode";
  if (r.includes("geo_radius") || r.includes("too_far") || r.includes("distance")) {
    return "geo_radius_fail";
  }
  if (r.includes("stale_gps") || r.includes("stale_location") || r.includes("coords_missing")) {
    return "gps_unavailable_for_gps_mode";
  }
  return "other";
}

/**
 * @param {"gps"|"service_area"} mode
 * @param {{ driverId?: string, rideId?: string }} ctx
 */
function logMatchEligible(mode, ctx = {}) {
  console.log(
    "MATCH_ELIGIBLE",
    `mode=${dispatchModeLogLabel(mode)}`,
    `driverId=${String(ctx.driverId ?? "").trim()}`,
    `rideId=${String(ctx.rideId ?? "").trim()}`,
  );
}

/**
 * @param {string} reason
 * @param {{ driverId?: string, rideId?: string, mode?: string, detail?: string }} ctx
 */
function logMatchReject(reason, ctx = {}) {
  console.log(
    "MATCH_REJECT",
    `reason=${reason}`,
    `mode=${ctx.mode ? dispatchModeLogLabel(ctx.mode) : ""}`,
    `driverId=${String(ctx.driverId ?? "").trim()}`,
    `rideId=${String(ctx.rideId ?? "").trim()}`,
    ctx.detail ? `detail=${ctx.detail}` : "",
  );
}

/**
 * @param {{
 *   rideId: string,
 *   market: string,
 *   indexed_driver_count: number,
 *   eligible_count: number,
 *   rejected_count: number,
 *   rejection_reason_breakdown: Record<string, number>,
 * }} summary
 */
function logDispatchFanoutSummary(summary) {
  console.log(
    "DISPATCH_FANOUT_SUMMARY",
    `rideId=${summary.rideId}`,
    `canonical_market_id=${summary.market}`,
    `indexed_driver_count=${summary.indexed_driver_count}`,
    `eligible_count=${summary.eligible_count}`,
    `rejected_count=${summary.rejected_count}`,
    `rejection_reason_breakdown=${JSON.stringify(summary.rejection_reason_breakdown || {})}`,
  );
}

module.exports = {
  logDispatchRideContext,
  logDispatchDriverContext,
  logMatchEligible,
  logMatchReject,
  logDispatchFanoutSummary,
  canonicalMatchRejectReason,
};
