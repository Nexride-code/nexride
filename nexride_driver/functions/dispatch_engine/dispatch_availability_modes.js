/**
 * Backend-authoritative driver dispatch availability modes.
 * Client may send legacy tokens; storage and matching use canonical values only.
 */

"use strict";

/** Canonical stored / logged mode for GPS-based matching. */
const DISPATCH_MODE_GPS = "gps";

/** Canonical stored / logged mode for admin service-area matching. */
const DISPATCH_MODE_SERVICE_AREA = "service_area";

const DISPATCH_MODE_OFFLINE = "offline";

/**
 * @param {unknown} raw
 * @returns {"gps"|"service_area"|"offline"|""}
 */
function normalizeDispatchAvailabilityMode(raw) {
  const m = String(raw ?? "")
    .trim()
    .toLowerCase()
    .replace(/-/g, "_");
  if (
    m === "gps" ||
    m === "current_location" ||
    m === "current" ||
    m === "currentlocation"
  ) {
    return DISPATCH_MODE_GPS;
  }
  if (m === "service_area" || m === "servicearea" || m === "area" || m === "city") {
    return DISPATCH_MODE_SERVICE_AREA;
  }
  if (m === "offline") {
    return DISPATCH_MODE_OFFLINE;
  }
  return "";
}

/**
 * Resolve mode from driver RTDB row (Flutter may write location_mode gps/area).
 * @param {Record<string, unknown>} driverProfile
 * @returns {"gps"|"service_area"|"offline"|""}
 */
function resolveDispatchAvailabilityMode(driverProfile) {
  const d = driverProfile && typeof driverProfile === "object" ? driverProfile : {};
  const fromCanonical = normalizeDispatchAvailabilityMode(
    d.dispatch_availability_mode ?? d.availability_mode ?? "",
  );
  if (fromCanonical) return fromCanonical;
  const fromLegacy = normalizeDispatchAvailabilityMode(
    d.driver_availability_mode ?? "",
  );
  if (fromLegacy) return fromLegacy;
  const loc = String(d.location_mode ?? "").trim().toLowerCase();
  if (loc === "gps") return DISPATCH_MODE_GPS;
  if (loc === "area") return DISPATCH_MODE_SERVICE_AREA;
  return "";
}

/**
 * @param {"gps"|"service_area"|"offline"|""} mode
 */
function dispatchModeLogLabel(mode) {
  if (mode === DISPATCH_MODE_GPS) return "gps";
  if (mode === DISPATCH_MODE_SERVICE_AREA) return "service_area";
  return mode || "unknown";
}

module.exports = {
  DISPATCH_MODE_GPS,
  DISPATCH_MODE_SERVICE_AREA,
  DISPATCH_MODE_OFFLINE,
  normalizeDispatchAvailabilityMode,
  resolveDispatchAvailabilityMode,
  dispatchModeLogLabel,
};
