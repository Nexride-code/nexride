/**
 * Canonical dispatch geography — single normalized key for matching/fan-out.
 * Admin Firestore delivery_regions.dispatch_market_id is source of truth.
 */

"use strict";

/** Legacy client aliases → canonical dispatch_market_id from admin config. */
const MARKET_ALIASES = Object.freeze({
  abuja: "abuja_fct",
  fct: "abuja_fct",
  "abuja_fct": "abuja_fct",
  lagos: "lagos",
});

/**
 * @param {unknown} value
 * @returns {string}
 */
function normalizeDispatchKey(value) {
  let s = String(value ?? "")
    .trim()
    .toLowerCase()
    .replace(/\s+/g, "_")
    .replace(/-+/g, "_");
  while (s.includes("__")) {
    s = s.replace(/__/g, "_");
  }
  s = s.replace(/^_+|_+$/g, "");
  if (!s) return "";
  return MARKET_ALIASES[s] || s;
}

/**
 * @param {Record<string, unknown>|null|undefined} payload
 * @returns {Record<string, unknown>}
 */
function normalizeServiceArea(payload) {
  const p = payload && typeof payload === "object" ? payload : {};
  const nested =
    p.service_area && typeof p.service_area === "object" ? p.service_area : p;
  const canonicalMarket = normalizeDispatchKey(
    nested.canonical_market_id ??
      nested.dispatch_market_id ??
      nested.market ??
      p.canonical_market_id ??
      p.dispatch_market_id ??
      p.market_pool ??
      p.market ??
      "",
  );
  const canonicalCity = normalizeDispatchKey(
    nested.canonical_city_id ??
      nested.service_area_city_id ??
      nested.city_id ??
      p.service_area_city_id ??
      p.rollout_city_id ??
      p.selected_service_area_id ??
      "",
  );
  const countryCode = String(
    nested.country_code ?? nested.countryCode ?? p.country_code ?? p.countryCode ?? "ng",
  )
    .trim()
    .toLowerCase()
    .slice(0, 8);

  return {
    canonical_market_id: canonicalMarket,
    canonical_city_id: canonicalCity,
    country_code: countryCode || "ng",
    market: canonicalMarket,
    region_id: String(
      nested.region_id ??
        nested.service_area_region_id ??
        p.service_area_region_id ??
        p.rollout_region_id ??
        "",
    ).trim(),
    city_id: canonicalCity,
  };
}

/**
 * Resolve canonical dispatch market from ride or driver row (resolved_* first).
 * @param {Record<string, unknown>|null|undefined} payload
 * @returns {string}
 */
function resolveCanonicalDispatchMarket(payload) {
  const p = payload && typeof payload === "object" ? payload : {};
  return normalizeDispatchKey(
    p.resolved_dispatch_market_id ??
      p.canonical_market_id ??
      p.dispatch_market_id ??
      p.market_pool ??
      p.dispatch_market ??
      p.market ??
      p.city ??
      "",
  );
}

/**
 * Apply canonical geography onto a ride_requests payload (mutates in place).
 * @param {Record<string, unknown>} ridePayload
 * @param {{
 *   canonical_market_id: string,
 *   region_id?: string,
 *   city_id?: string,
 *   country_code?: string,
 * }} rollout
 */
function applyCanonicalDispatchGeoToRidePayload(ridePayload, rollout) {
  const m = normalizeDispatchKey(rollout?.canonical_market_id ?? "");
  if (!m || !ridePayload || typeof ridePayload !== "object") {
    return ridePayload;
  }
  const serviceArea = normalizeServiceArea({
    canonical_market_id: m,
    canonical_city_id: rollout?.city_id,
    region_id: rollout?.region_id,
    country_code: rollout?.country_code ?? "ng",
  });

  ridePayload.market = m;
  ridePayload.market_pool = m;
  ridePayload.dispatch_market_id = m;
  ridePayload.resolved_dispatch_market_id = m;
  ridePayload.canonical_market_id = m;
  ridePayload.service_area = serviceArea;

  for (const scopeKey of ["pickup_scope", "destination_scope", "pickup", "destination", "dropoff"]) {
    const scope = ridePayload[scopeKey];
    if (!scope || typeof scope !== "object") continue;
    scope.market = m;
    scope.canonical_market_id = m;
    scope.country_code = serviceArea.country_code;
  }

  if (ridePayload.match_debug && typeof ridePayload.match_debug === "object") {
    ridePayload.match_debug.dispatch_market_id = m;
    ridePayload.match_debug.resolved_dispatch_market_id = m;
    ridePayload.match_debug.canonical_market_id = m;
  }

  return ridePayload;
}

/**
 * Apply canonical geography onto driver online updates (mutates in place).
 * @param {Record<string, unknown>} updates
 * @param {{
 *   canonical_market_id: string,
 *   region_id?: string,
 *   city_id?: string,
 *   country_code?: string,
 * }} rollout
 */
function applyCanonicalDispatchGeoToDriverUpdates(updates, rollout) {
  const m = normalizeDispatchKey(rollout?.canonical_market_id ?? "");
  if (!m || !updates || typeof updates !== "object") {
    return updates;
  }
  const serviceArea = normalizeServiceArea({
    canonical_market_id: m,
    canonical_city_id: rollout?.city_id,
    region_id: rollout?.region_id,
    country_code: rollout?.country_code ?? "ng",
  });

  updates.canonical_market_id = m;
  updates.dispatch_market_id = m;
  updates.dispatch_market = m;
  updates.market_pool = m;
  updates.market = m;
  updates.canonical_city_id = serviceArea.canonical_city_id || null;
  updates.service_area = serviceArea;
  updates.service_area_region_id = serviceArea.region_id || null;
  updates.service_area_city_id = serviceArea.city_id || null;
  updates.rollout_region_id = serviceArea.region_id || null;
  updates.rollout_city_id = serviceArea.city_id || null;

  const mode = String(rollout?.availability_mode ?? "").trim();
  if (mode) {
    updates.dispatch_availability_mode = mode;
    updates.availability_mode = mode;
    updates.driver_availability_mode =
      mode === "gps" ? "current_location" : mode === "service_area" ? "service_area" : mode;
    updates.location_mode = mode === "gps" ? "gps" : mode === "service_area" ? "area" : null;
    updates.gps_active = mode === "gps";
  }
  const saId = String(rollout?.service_area_id ?? rollout?.city_id ?? "").trim();
  if (saId) {
    updates.service_area_id = normalizeDispatchKey(saId) || saId;
    updates.canonical_service_area_id = updates.service_area_id;
  }
  const saName = String(rollout?.service_area_name ?? "").trim();
  if (saName) {
    updates.service_area_name = saName.slice(0, 200);
  }

  return updates;
}

/** Ride fields locked after createRideRequest (write-once canonical geography). */
const CANONICAL_RIDE_MARKET_FIELD_KEYS = Object.freeze([
  "canonical_market_id",
  "dispatch_market_id",
  "resolved_dispatch_market_id",
  "market_pool",
  "market",
  "city",
  "dispatch_market",
]);

/** Driver fields that must only be set via backend online/callables. */
const CANONICAL_DRIVER_MARKET_FIELD_KEYS = Object.freeze([
  "canonical_market_id",
  "dispatch_market_id",
  "market_pool",
  "market",
  "city",
  "dispatch_market",
]);

const CANONICAL_SCOPE_KEYS = Object.freeze([
  "service_area",
  "pickup_scope",
  "destination_scope",
  "pickup",
  "destination",
  "dropoff",
]);

/**
 * @param {Record<string, unknown>} patch
 * @returns {string[]} rejected field keys
 */
function findCanonicalMarketMutationKeys(patch) {
  const rejected = [];
  if (!patch || typeof patch !== "object") {
    return rejected;
  }
  for (const [k, v] of Object.entries(patch)) {
    if (CANONICAL_RIDE_MARKET_FIELD_KEYS.includes(k)) {
      rejected.push(k);
      continue;
    }
    if (!CANONICAL_SCOPE_KEYS.includes(k)) {
      continue;
    }
    if (!v || typeof v !== "object") {
      continue;
    }
    for (const scopeKey of ["market", "canonical_market_id", "dispatch_market_id"]) {
      if (scopeKey in v) {
        rejected.push(`${k}.${scopeKey}`);
      }
    }
  }
  return rejected;
}

/**
 * Reject client/backend patches that attempt to change canonical ride geography.
 * @param {Record<string, unknown>} patch
 * @param {{ rideId?: string, source?: string }} [ctx]
 * @returns {{ ok: true } | { ok: false, reason: string, fields: string[] }}
 */
function rejectCanonicalMarketMutation(patch, ctx = {}) {
  const fields = findCanonicalMarketMutationKeys(patch);
  if (fields.length === 0) {
    return { ok: true };
  }
  console.log(
    "MARKET_MUTATION_REJECTED",
    `rideId=${String(ctx.rideId ?? "").trim() || "(unknown)"}`,
    `source=${String(ctx.source ?? "unknown").trim()}`,
    `fields=${fields.join(",")}`,
  );
  return { ok: false, reason: "market_immutable", fields };
}

/**
 * Strip canonical market keys from an update object (defensive for mixed patches).
 * @param {Record<string, unknown>} updates
 */
function stripCanonicalMarketFieldsFromUpdate(updates) {
  if (!updates || typeof updates !== "object") {
    return updates;
  }
  for (const k of CANONICAL_RIDE_MARKET_FIELD_KEYS) {
    delete updates[k];
  }
  for (const scopeKey of CANONICAL_SCOPE_KEYS) {
    const scope = updates[scopeKey];
    if (!scope || typeof scope !== "object") {
      continue;
    }
    delete scope.market;
    delete scope.canonical_market_id;
    delete scope.dispatch_market_id;
  }
  return updates;
}

/**
 * @param {Record<string, unknown>|null|undefined} ride
 * @param {string} [rideId]
 * @returns {boolean} true when aligned
 */
function assertRideCanonicalFieldsAligned(ride, rideId = "") {
  const r = ride && typeof ride === "object" ? ride : {};
  const canonical = resolveCanonicalDispatchMarket(r);
  if (!canonical) {
    return false;
  }
  let aligned = true;
  for (const field of CANONICAL_RIDE_MARKET_FIELD_KEYS) {
    const raw = r[field];
    if (raw === null || raw === undefined || String(raw).trim() === "") {
      continue;
    }
    const normalized = normalizeDispatchKey(raw);
    if (normalized && normalized !== canonical) {
      aligned = false;
      console.log(
        "DISPATCH_CANONICAL_MISMATCH",
        `entity=ride`,
        `rideId=${String(rideId ?? r.ride_id ?? "").trim()}`,
        `field=${field}`,
        `value=${normalized}`,
        `canonical=${canonical}`,
      );
    }
  }
  return aligned;
}

/**
 * @param {Record<string, unknown>|null|undefined} driver
 * @param {string} [driverId]
 * @returns {boolean}
 */
function assertDriverCanonicalFieldsAligned(driver, driverId = "") {
  const d = driver && typeof driver === "object" ? driver : {};
  const canonical = normalizeDispatchKey(
    d.canonical_market_id ?? d.dispatch_market_id ?? "",
  );
  if (!canonical) {
    return false;
  }
  let aligned = true;
  for (const field of CANONICAL_DRIVER_MARKET_FIELD_KEYS) {
    const raw = d[field];
    if (raw === null || raw === undefined || String(raw).trim() === "") {
      continue;
    }
    const normalized = normalizeDispatchKey(raw);
    if (normalized && normalized !== canonical) {
      aligned = false;
      console.log(
        "DISPATCH_CANONICAL_MISMATCH",
        `entity=driver`,
        `driverId=${String(driverId ?? "").trim()}`,
        `field=${field}`,
        `value=${normalized}`,
        `canonical=${canonical}`,
      );
    }
  }
  return aligned;
}

module.exports = {
  MARKET_ALIASES,
  CANONICAL_RIDE_MARKET_FIELD_KEYS,
  CANONICAL_DRIVER_MARKET_FIELD_KEYS,
  normalizeDispatchKey,
  normalizeServiceArea,
  resolveCanonicalDispatchMarket,
  applyCanonicalDispatchGeoToRidePayload,
  applyCanonicalDispatchGeoToDriverUpdates,
  findCanonicalMarketMutationKeys,
  rejectCanonicalMarketMutation,
  stripCanonicalMarketFieldsFromUpdate,
  assertRideCanonicalFieldsAligned,
  assertDriverCanonicalFieldsAligned,
};
