/**
 * Driver coordinates for dispatch matching — no Google APIs.
 * Uses go-online snapshot + grace window when live GPS stream is unavailable.
 */

"use strict";

/** After go-online, keep dispatch-eligible without live GPS updates. */
const DISPATCH_ONLINE_LOCATION_GRACE_MS = 10 * 60 * 1000;

const STALE_DRIVER_LOCATION_MS = 12 * 60 * 1000;

/**
 * @param {Record<string, unknown>|null|undefined} driverProfile
 * @param {number} [nowMs]
 * @returns {{ lat: number, lng: number, source: string, inGrace: boolean, heartbeatMs: number }}
 */
function resolveDriverCoordsForDispatch(driverProfile, nowMs = Date.now()) {
  const d = driverProfile && typeof driverProfile === "object" ? driverProfile : {};
  const heartbeat =
    Number(
      d.last_dispatch_heartbeat ??
        d.presence_heartbeat_at ??
        d.online_session_started_at ??
        d.last_seen_at ??
        0,
    ) || 0;
  const inGrace =
    heartbeat > 0 && nowMs - heartbeat <= DISPATCH_ONLINE_LOCATION_GRACE_MS;

  const candidates = [
    {
      loc: d.current_location ?? d.last_location,
      ts: Number(d.current_location_updated_at ?? d.last_location_updated_at ?? 0) || 0,
      source: "current_location",
    },
    {
      loc: d.last_location,
      ts: Number(d.last_location_updated_at ?? 0) || 0,
      source: "last_location",
    },
    {
      loc: d.last_valid_location,
      ts: Number(d.last_location_ts ?? 0) || 0,
      source: "last_valid_location",
    },
    {
      loc: d.online_start_location,
      ts: Number(d.online_start_location_at ?? d.online_session_started_at ?? 0) || 0,
      source: "online_start_location",
    },
    {
      loc: { lat: d.lat, lng: d.lng },
      ts: heartbeat,
      source: "profile_lat_lng",
    },
  ];

  for (const c of candidates) {
    const loc = c.loc && typeof c.loc === "object" ? c.loc : {};
    const lat = Number(loc.lat ?? loc.latitude ?? "");
    const lng = Number(loc.lng ?? loc.longitude ?? "");
    if (!Number.isFinite(lat) || !Number.isFinite(lng) || (lat === 0 && lng === 0)) {
      continue;
    }
    const locationStale = c.ts > 0 && nowMs - c.ts > STALE_DRIVER_LOCATION_MS;
    if (!locationStale || inGrace) {
      return { lat, lng, source: c.source, inGrace, heartbeatMs: heartbeat };
    }
  }

  return { lat: NaN, lng: NaN, source: "none", inGrace, heartbeatMs: heartbeat };
}

module.exports = {
  DISPATCH_ONLINE_LOCATION_GRACE_MS,
  STALE_DRIVER_LOCATION_MS,
  resolveDriverCoordsForDispatch,
};
