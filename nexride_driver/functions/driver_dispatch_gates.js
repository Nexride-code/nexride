/**
 * Production driver offer eligibility — mirrors Flutter driver_verification_restrictions loosely.
 */

const { locationModeLabel, normalizeAvailabilityMode } = require("./driver_location_paths");
const {
  normalizeDispatchKey,
  resolveCanonicalDispatchMarket,
  assertDriverCanonicalFieldsAligned,
} = require("./dispatch_engine/dispatch_geo_normalizer");
const {
  resolveDriverCoordsForDispatch,
  DISPATCH_ONLINE_LOCATION_GRACE_MS,
} = require("./dispatch_engine/dispatch_driver_location");
const {
  DISPATCH_MODE_GPS,
  DISPATCH_MODE_SERVICE_AREA,
  normalizeDispatchAvailabilityMode,
  resolveDispatchAvailabilityMode,
} = require("./dispatch_engine/dispatch_availability_modes");
const {
  logMatchEligible,
  logMatchReject,
} = require("./dispatch_engine/dispatch_observability");

/** Must stay aligned with setDriverOnline + dispatch_index_engine availability sets. */
const DRIVER_OFFER_AVAILABLE_STATUSES = new Set([
  "available",
  "online_available",
  "online",
]);
const DRIVER_OFFER_AVAILABLE_DISPATCH_STATES = new Set([
  "",
  "available",
  "online_available",
  "online",
]);

function driverOfferStatusAllowsDispatch(raw) {
  const st = String(raw ?? "").trim().toLowerCase();
  if (!st) return true;
  return DRIVER_OFFER_AVAILABLE_STATUSES.has(st);
}

function driverOfferDispatchStateAllowsDispatch(raw) {
  const ds = String(raw ?? "").trim().toLowerCase();
  return DRIVER_OFFER_AVAILABLE_DISPATCH_STATES.has(ds);
}

/**
 * Session is online when explicit flags are set OR status/dispatch_state imply availability
 * (e.g. setDriverOnline writes online_available even if is_online lags).
 */
function driverSessionOnlineForDispatch(profile) {
  const d = profile && typeof profile === "object" ? profile : {};
  if (d.isOnline === true || d.is_online === true || d.online === true) {
    return true;
  }
  const st = String(d.status ?? "").trim().toLowerCase();
  const ds = String(d.dispatch_state ?? "").trim().toLowerCase();
  return (
    driverOfferStatusAllowsDispatch(st) && driverOfferDispatchStateAllowsDispatch(ds)
  );
}

function normUid(uid) {
  return String(uid ?? "").trim();
}

function boolTrue(v) {
  return v === true || v === "true" || v === 1 || v === "1";
}

function canonicalMarketSlug(raw) {
  return normalizeDispatchKey(raw);
}

/** Legacy Flutter tokens for exports. */
function normalizeDriverAvailabilityMode(raw) {
  const mode = normalizeDispatchAvailabilityMode(raw);
  if (mode === DISPATCH_MODE_GPS) return "current_location";
  if (mode === DISPATCH_MODE_SERVICE_AREA) return "service_area";
  if (mode === "offline") return "offline";
  return "";
}

/** @deprecated use resolveDispatchAvailabilityMode — kept for exports */
function resolveDriverAvailabilityMode(driverProfile) {
  const mode = resolveDispatchAvailabilityMode(driverProfile);
  if (mode === DISPATCH_MODE_GPS) return "current_location";
  if (mode === DISPATCH_MODE_SERVICE_AREA) return "service_area";
  return mode;
}

/**
 * Service-area drivers match on canonical market; city is used for ranking only.
 * @param {Record<string, unknown>} driverProfile
 * @param {Record<string, unknown>} ridePayload
 */
function driverServiceAreaCoversRide(driverProfile, ridePayload) {
  const d = driverProfile && typeof driverProfile === "object" ? driverProfile : {};
  const hasArea =
    Boolean(
      String(
        d.service_area_id ??
          d.canonical_service_area_id ??
          d.selected_service_area_id ??
          d.service_area_city_id ??
          d.rollout_city_id ??
          "",
      ).trim(),
    ) || Boolean(d.service_area && typeof d.service_area === "object");
  return hasArea;
}

function driverRideMarketsAligned(driverProfile, ridePayload, auditCtx = {}) {
  const rideMarket = rideDispatchMarketId(ridePayload);
  const driverMarket = driverDispatchMarketId(driverProfile);
  if (!rideMarket) return false;
  if (!driverMarket) return false;
  const aligned = rideMarket === driverMarket;
  if (!aligned && auditCtx.logMismatch) {
    logMatchReject("market_mismatch", {
      rideId: auditCtx.rideId,
      driverId: auditCtx.driverId,
      detail: `ride=${rideMarket} driver=${driverMarket}`,
    });
    try {
      const { recordMarketMismatch } = require("./dispatch_engine/dispatch_production_metrics");
      recordMarketMismatch();
    } catch (_) {}
  }
  return aligned;
}

const STALE_DRIVER_LOCATION_MS = 12 * 60 * 1000;
const MAX_DRIVER_PICKUP_DISTANCE_KM = 45;

function toRad(deg) {
  return (deg * Math.PI) / 180;
}

/**
 * @param {number} lat1
 * @param {number} lon1
 * @param {number} lat2
 * @param {number} lon2
 */
function haversineKm(lat1, lon1, lat2, lon2) {
  if (
    !Number.isFinite(lat1) ||
    !Number.isFinite(lon1) ||
    !Number.isFinite(lat2) ||
    !Number.isFinite(lon2)
  ) {
    return NaN;
  }
  const R = 6371;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) * Math.sin(dLon / 2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return R * c;
}

/**
 * @param {Record<string, unknown>} ridePayload
 * @returns {{ lat: number, lng: number }}
 */
function pickupCoordsFromRide(ridePayload) {
  const r = ridePayload && typeof ridePayload === "object" ? ridePayload : {};
  const p = r.pickup && typeof r.pickup === "object" ? r.pickup : {};
  const lat = Number(p.lat ?? p.latitude ?? p.Latitude ?? "");
  const lng = Number(p.lng ?? p.longitude ?? p.Longitude ?? "");
  return { lat, lng };
}

/**
 * @param {Record<string, unknown>} driverProfile
 * @returns {{ lat: number, lng: number }}
 */
function driverLastKnownCoords(driverProfile, nowMs = Date.now()) {
  const resolved = resolveDriverCoordsForDispatch(driverProfile, nowMs);
  return { lat: resolved.lat, lng: resolved.lng };
}

function driverDispatchMarketId(driverProfile) {
  const d = driverProfile && typeof driverProfile === "object" ? driverProfile : {};
  return normalizeDispatchKey(
    d.canonical_market_id ??
      d.dispatch_market_id ??
      d.rollout_dispatch_market_id ??
      d.dispatch_market ??
      d.market_pool ??
      d.market ??
      "",
  );
}

function rideDispatchMarketId(ridePayload) {
  return resolveCanonicalDispatchMarket(ridePayload);
}

/**
 * @param {Record<string, unknown>} driverProfile
 * @param {Record<string, unknown>} ridePayload
 * @param {number} nowMs
 */
function matchLocationAuditPayload(driverProfile, ridePayload, geoResult, nowMs) {
  const d = driverProfile && typeof driverProfile === "object" ? driverProfile : {};
  const mode =
    locationModeLabel(d.location_mode ?? d.driver_availability_mode ?? d.availability_mode) ||
    locationModeLabel(d.driver_availability_mode);
  const coords = driverLastKnownCoords(d);
  const pickup = pickupCoordsFromRide(ridePayload);
  let distanceKm = null;
  if (
    Number.isFinite(coords.lat) &&
    Number.isFinite(coords.lng) &&
    Number.isFinite(pickup.lat) &&
    Number.isFinite(pickup.lng)
  ) {
    distanceKm = haversineKm(coords.lat, coords.lng, pickup.lat, pickup.lng);
    if (!Number.isFinite(distanceKm)) distanceKm = null;
  }
  return {
    location_mode: mode || null,
    lat: Number.isFinite(coords.lat) ? coords.lat : null,
    lng: Number.isFinite(coords.lng) ? coords.lng : null,
    updated_at: Number(d.last_location_updated_at ?? d.updated_at ?? 0) || null,
    service_area_region_id:
      String(d.service_area_region_id ?? d.rollout_region_id ?? "").trim() || null,
    service_area_city_id:
      String(
        d.service_area_city_id ?? d.rollout_city_id ?? d.selected_service_area_id ?? "",
      ).trim() || null,
    dispatch_market_id: driverDispatchMarketId(d) || null,
    distance_to_pickup_km: distanceKm,
    eligible: geoResult?.ok === true,
    filter_reason: geoResult?.ok ? null : String(geoResult?.detail ?? geoResult?.log ?? ""),
  };
}

/**
 * @param {import("firebase-functions").logger} logger
 */
function logMatchLocationSource(logger, driverId, driverProfile, ridePayload, geoResult, nowMs) {
  const audit = matchLocationAuditPayload(driverProfile, ridePayload, geoResult, nowMs);
  const payload = { driverId: normUid(driverId), ...audit };
  if (logger && typeof logger.info === "function") {
    logger.info("MATCH_LOCATION_SOURCE", payload);
  } else {
    console.log("MATCH_LOCATION_SOURCE", JSON.stringify(payload));
  }
}

/**
 * Availability mode + distance / service-city alignment for fan-out.
 * Legacy drivers (no `driver_availability_mode`) keep prior market-only behaviour.
 *
 * @param {Record<string, unknown>} driverProfile
 * @param {Record<string, unknown>} ridePayload
 * @param {number} nowMs
 * @returns {{ ok: true } | { ok: false, log: string, detail: string }}
 */
function evaluateDriverGeoAndMode(driverProfile, ridePayload, nowMs, auditCtx = {}) {
  const d = driverProfile && typeof driverProfile === "object" ? driverProfile : {};
  const mode = resolveDispatchAvailabilityMode(d);
  const rideId = String(auditCtx.rideId ?? ridePayload?.ride_id ?? "").trim();
  const driverId = String(auditCtx.driverId ?? "").trim();
  const audit = { rideId, driverId, mode };

  if (!mode) {
    if (!driverRideMarketsAligned(d, ridePayload, { ...auditCtx, logMismatch: true })) {
      return { ok: false, log: "DRIVER_FILTERED_MARKET", detail: "market_mismatch" };
    }
    return { ok: true, log: "GEO_LEGACY", detail: "skipped" };
  }
  if (mode === "offline") {
    logMatchReject("unavailable", { ...audit, detail: "offline_mode" });
    return { ok: false, log: "DRIVER_FILTERED_MODE", detail: "offline_mode" };
  }

  if (!driverRideMarketsAligned(d, ridePayload, { ...auditCtx, logMismatch: true })) {
    return { ok: false, log: "DRIVER_FILTERED_MARKET", detail: "market_mismatch" };
  }

  assertDriverCanonicalFieldsAligned(d, driverId);

  if (mode === DISPATCH_MODE_SERVICE_AREA) {
    if (!driverServiceAreaCoversRide(d, ridePayload)) {
      logMatchReject("service_area_mismatch", audit);
      return {
        ok: false,
        log: "DRIVER_FILTERED_SERVICE_AREA",
        detail: "service_area_mismatch",
      };
    }
    logMatchEligible(DISPATCH_MODE_SERVICE_AREA, audit);
    return {
      ok: true,
      log: "GEO_SERVICE_AREA",
      detail: "service_area_market_match_no_gps_required",
    };
  }

  if (mode === DISPATCH_MODE_GPS) {
    const pickup = pickupCoordsFromRide(ridePayload);
    const pickupOk = Number.isFinite(pickup.lat) && Number.isFinite(pickup.lng);
    if (!pickupOk) {
      return { ok: true, log: "GEO_PICKUP_MISSING", detail: "pickup_unavailable" };
    }
    const resolved = resolveDriverCoordsForDispatch(d, nowMs);
    if (!Number.isFinite(resolved.lat) || !Number.isFinite(resolved.lng)) {
      logMatchReject("gps_unavailable_for_gps_mode", {
        ...audit,
        detail: "coords_missing",
      });
      return {
        ok: false,
        log: "DRIVER_FILTERED_LOCATION",
        detail: "gps_unavailable_for_gps_mode",
      };
    }
    const ts = Number(d.last_location_updated_at ?? d.last_location_ts ?? 0) || 0;
    if (
      !resolved.inGrace &&
      ts > 0 &&
      nowMs - ts > STALE_DRIVER_LOCATION_MS
    ) {
      logMatchReject("gps_unavailable_for_gps_mode", { ...audit, detail: "stale_gps" });
      return { ok: false, log: "DRIVER_FILTERED_STALE_GPS", detail: "stale_location" };
    }
    const dist = haversineKm(resolved.lat, resolved.lng, pickup.lat, pickup.lng);
    if (!Number.isFinite(dist)) {
      logMatchReject("gps_unavailable_for_gps_mode", { ...audit, detail: "location_invalid" });
      return { ok: false, log: "DRIVER_FILTERED_LOCATION", detail: "location_invalid" };
    }
    if (dist > MAX_DRIVER_PICKUP_DISTANCE_KM) {
      logMatchReject("geo_radius_fail", { ...audit, detail: `distance_km=${dist.toFixed(2)}` });
      try {
        const { recordGeoReject } = require("./dispatch_engine/dispatch_production_metrics");
        recordGeoReject();
      } catch (_) {}
      return { ok: false, log: "DRIVER_FILTERED_DISTANCE", detail: "geo_radius_fail" };
    }
    logMatchEligible(DISPATCH_MODE_GPS, {
      ...audit,
      detail: `coord_source=${resolved.source}`,
    });
    return { ok: true, log: "GEO_GPS", detail: resolved.source };
  }

  return { ok: true, log: "GEO_UNKNOWN_MODE", detail: "skipped" };
}

/**
 * Stabilization mode: no verification / subscription / BVN gates.
 * Requires session online + market alignment + optional status/dispatch_state.
 * @returns {{ ok: true } | { ok: false, log: string, detail: string }}
 */
function evaluateDriverForOfferSoft(driverProfile, ridePayload, gates = {}) {
  const d = driverProfile && typeof driverProfile === "object" ? driverProfile : {};
  const suspended =
    boolTrue(d.suspended) ||
    boolTrue(d.account_suspended) ||
    String(d.driver_status ?? "")
      .trim()
      .toLowerCase() === "suspended";
  if (suspended) {
    return { ok: false, log: "DRIVER_FILTERED_SUSPENDED", detail: "suspended" };
  }
  const rideMarket = rideDispatchMarketId(ridePayload);
  if (!rideMarket) {
    return { ok: false, log: "NO_RIDE_MARKET", detail: "missing_canonical_market" };
  }
  if (!driverRideMarketsAligned(d, ridePayload)) {
    return { ok: false, log: "DRIVER_FILTERED_MARKET_SOFT", detail: "market_mismatch" };
  }
  if (!driverSessionOnlineForDispatch(d)) {
    return { ok: false, log: "NOT_ONLINE", detail: "session_off" };
  }
  const st = String(d.status ?? "").trim().toLowerCase();
  if (!driverOfferStatusAllowsDispatch(st)) {
    return { ok: false, log: "STATUS_NOT_AVAILABLE", detail: st };
  }
  const ds = String(d.dispatch_state ?? "").trim().toLowerCase();
  if (!driverOfferDispatchStateAllowsDispatch(ds)) {
    return { ok: false, log: "DISPATCH_STATE_NOT_AVAILABLE", detail: ds };
  }
  const verifyGates = {
    soft_verification: false,
    require_bvn: gates.require_bvn === true,
  };
  const vEl = evaluateDriverVerificationForOffer(d, verifyGates, ridePayload);
  if (!vEl.ok) {
    return vEl;
  }
  return { ok: true };
}

function docEntryApproved(doc) {
  if (!doc || typeof doc !== "object") return false;
  const st = String(
    doc.status ?? doc.verification_status ?? doc.verificationStatus ?? "",
  )
    .trim()
    .toLowerCase();
  return st === "approved" || st === "verified";
}

function hasApprovedDocuments(verificationRoot) {
  const v =
    verificationRoot && typeof verificationRoot === "object" ? verificationRoot : {};
  const docs = v.documents && typeof v.documents === "object" ? v.documents : {};
  return (
    docEntryApproved(docs.nin) &&
    docEntryApproved(docs.drivers_license) &&
    docEntryApproved(docs.vehicle_documents)
  );
}

function bvnApproved(verificationRoot) {
  const v =
    verificationRoot && typeof verificationRoot === "object" ? verificationRoot : {};
  const docs = v.documents && typeof v.documents === "object" ? v.documents : {};
  return docEntryApproved(docs.bvn);
}

/**
 * Verification-only leg (used by strict + soft dispatch paths).
 * @returns {{ ok: true } | { ok: false, log: string, detail: string }}
 */
function evaluateDriverVerificationForOffer(driverProfile, gates, ridePayload) {
  const d = driverProfile && typeof driverProfile === "object" ? driverProfile : {};

  if (gates.soft_verification === true) {
    return { ok: true };
  }

  if (boolTrue(d.nexride_verified)) {
    const vr = d.verification && typeof d.verification === "object" ? d.verification : {};
    const rest = vr.restrictions && typeof vr.restrictions === "object" ? vr.restrictions : {};
    const svc = String(ridePayload.service_type ?? ridePayload.serviceType ?? "ride").trim();
    const approveSvc = rest[svc];
    if (approveSvc === false) {
      return { ok: false, log: "DRIVER_FILTERED_VERIFICATION", detail: `service_blocked:${svc}` };
    }
    return { ok: true };
  }

  const v = d.verification && typeof d.verification === "object" ? d.verification : {};
  const rest = v.restrictions && typeof v.restrictions === "object" ? v.restrictions : {};

  if (boolTrue(rest.canGoOnline)) {
    const svc = String(ridePayload.service_type ?? ridePayload.serviceType ?? "ride").trim();
    if (rest[svc] === false) {
      return { ok: false, log: "DRIVER_FILTERED_VERIFICATION", detail: `service_blocked:${svc}` };
    }
    return { ok: true };
  }

  if (hasApprovedDocuments(v)) {
    if (gates.require_bvn === true && !bvnApproved(v)) {
      return { ok: false, log: "DRIVER_FILTERED_VERIFICATION", detail: "bvn_required" };
    }
    return { ok: true };
  }

  return { ok: false, log: "DRIVER_FILTERED_VERIFICATION", detail: "documents_incomplete" };
}

/**
 * @returns {{ ok: true } | { ok: false, log: string, detail: string }}
 */
function evaluateDriverForOffer(driverProfile, gates, ridePayload) {
  const d = driverProfile && typeof driverProfile === "object" ? driverProfile : {};

  const suspended =
    boolTrue(d.suspended) ||
    boolTrue(d.account_suspended) ||
    String(d.driver_status ?? "")
      .trim()
      .toLowerCase() === "suspended";
  if (suspended) {
    return { ok: false, log: "DRIVER_FILTERED_SUSPENDED", detail: "suspended" };
  }

  if (!driverRideMarketsAligned(d, ridePayload)) {
    return { ok: false, log: "DRIVER_FILTERED_MARKET", detail: "market_pool_mismatch" };
  }

  return evaluateDriverVerificationForOffer(d, gates, ridePayload);
}

/**
 * Per-driver fan-out trace for MATCH_DRIVER_FILTER_TRACE logs and match_debug samples.
 * @param {string} driverId
 * @param {Record<string, unknown>} profile
 * @param {Record<string, unknown>} ridePayload
 * @param {object} gates
 * @param {number} nowMs
 * @param {{ activeRideId?: string|null, useSoft?: boolean }} [ctx]
 */
function buildDriverFanoutFilterTrace(driverId, profile, ridePayload, gates, nowMs, ctx = {}) {
  const d = normUid(driverId);
  const snap = summarizeDriverForFanout(d, profile || {});
  const prof = profile && typeof profile === "object" ? profile : {};
  const rideCity = String(
    ridePayload?.resolved_service_city_id ??
      ridePayload?.service_city_id ??
      ridePayload?.rollout_city_id ??
      "",
  ).trim();
  const trace = {
    driver_id: d,
    online: snap.online,
    is_online: snap.is_online,
    driver_dispatch_market_id: driverDispatchMarketId(prof) || null,
    driver_service_area_city_id:
      String(prof.service_area_city_id ?? prof.rollout_city_id ?? "").trim() || null,
    ride_dispatch_market_id: rideDispatchMarketId(ridePayload) || null,
    ride_pickup_city: rideCity || null,
    location_mode:
      locationModeLabel(prof.location_mode ?? prof.driver_availability_mode) || null,
    driver_availability_mode: resolveDriverAvailabilityMode(prof) || snap.driver_availability_mode,
    vehicle_type: snap.vehicle_type,
    verification_status: snap.approved ? "approved" : "pending",
    payment_status: String(ridePayload?.payment_status ?? "").trim().toLowerCase() || null,
    active_ride: ctx.activeRideId ?? null,
    allowed: false,
    filtered_reason: null,
  };
  if (snap.suspended) {
    trace.filtered_reason = "suspended";
    logMatchReject("unavailable", { driverId: d, rideId: ridePayload?.ride_id, detail: "suspended" });
    return trace;
  }
  const { STALE_DRIVER_HEARTBEAT_MS } = require("./driver_active_pointer_guard");
  const lastSeen =
    Number(ctx.driverLastSeenMs ?? prof.last_active_at ?? prof.last_seen_at ?? 0) || 0;
  const dispatchHb =
    Number(prof.last_dispatch_heartbeat ?? prof.presence_heartbeat_at ?? 0) || 0;
  const hbForStale = Math.max(lastSeen, dispatchHb);
  const inOnlineGrace =
    dispatchHb > 0 && nowMs - dispatchHb <= DISPATCH_ONLINE_LOCATION_GRACE_MS;
  if (hbForStale > 0 && nowMs - hbForStale > STALE_DRIVER_HEARTBEAT_MS && !inOnlineGrace) {
    trace.filtered_reason = "stale_heartbeat";
    trace.driver_last_seen_ms = hbForStale;
    logMatchReject("unavailable", { driverId: d, rideId: ridePayload?.ride_id, detail: trace.filtered_reason });
    return trace;
  }
  const vc = evaluateCarRideVehicleAndCapability(prof, ridePayload);
  if (!vc.ok) {
    trace.filtered_reason = `${vc.log}:${vc.detail}`;
    return trace;
  }
  if (ctx.activeRideId) {
    trace.filtered_reason = "driver_active_ride_busy";
    return trace;
  }
  if (ctx.useSoft) {
    const softEl = evaluateDriverForOfferSoft(prof, ridePayload, gates);
    if (!softEl.ok) {
      trace.filtered_reason = `${softEl.log}:${softEl.detail}`;
      return trace;
    }
  } else {
    const ds = String(prof.dispatch_state ?? "").trim().toLowerCase();
    if (!driverOfferDispatchStateAllowsDispatch(ds)) {
      trace.filtered_reason = `dispatch_state_not_available:${ds}`;
      return trace;
    }
    const st = String(prof.status ?? "").trim().toLowerCase();
    if (!driverOfferStatusAllowsDispatch(st)) {
      trace.filtered_reason = `status_not_available:${st}`;
      return trace;
    }
    if (!driverSessionOnlineForDispatch(prof)) {
      trace.filtered_reason = "not_online";
      return trace;
    }
    const eligibility = evaluateDriverForOffer(prof, gates, ridePayload);
    if (!eligibility.ok) {
      trace.filtered_reason = `${eligibility.log}:${eligibility.detail}`;
      return trace;
    }
  }
  const geo = evaluateDriverGeoAndMode(prof, ridePayload, nowMs, {
    rideId: ridePayload?.ride_id,
    driverId: d,
  });
  if (!geo.ok) {
    trace.filtered_reason = `${geo.log}:${geo.detail}`;
    return trace;
  }
  trace.allowed = true;
  trace.filtered_reason = null;
  return trace;
}

async function loadDispatchGates(db) {
  try {
    const snap = await db.ref("app_config/nexride_dispatch").get();
    const g = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
    const gates = {
      soft_verification: boolTrue(g.soft_verification),
      require_bvn: boolTrue(g.require_bvn_verification),
    };
    console.log(
      "DISPATCH_GATES_LOADED",
      `soft_verification=${gates.soft_verification}`,
      `require_bvn_verification=${gates.require_bvn}`,
      `app_config_path=app_config/nexride_dispatch`,
      `exists=${snap.exists()}`,
    );
    return gates;
  } catch (e) {
    console.warn(
      "DISPATCH_GATES_LOAD_FAIL",
      e && typeof e === "object" && "message" in e ? e.message : e,
    );
    return { soft_verification: false, require_bvn: false };
  }
}

/**
 * Snapshot fields for MATCH_DRIVER_CANDIDATE / debug logs (must match ride_callables fanout filters).
 * @param {string} driverId
 * @param {Record<string, unknown>} profile
 */
function summarizeDriverForFanout(driverId, profile) {
  const d = profile && typeof profile === "object" ? profile : {};
  const online =
    d.isOnline === true || d.is_online === true || d.online === true;
  const is_online = boolTrue(d.is_online) || boolTrue(d.isOnline);
  const suspended =
    boolTrue(d.suspended) ||
    boolTrue(d.account_suspended) ||
    String(d.driver_status ?? "")
      .trim()
      .toLowerCase() === "suspended";
  const dm = normalizeDispatchKey(
    d.canonical_market_id ??
      d.dispatch_market_id ??
      d.dispatch_market ??
      d.market_pool ??
      d.market ??
      "",
  );
  const status = String(d.status ?? "").trim().toLowerCase();
  const dispatchState = String(d.dispatch_state ?? "").trim().toLowerCase();
  const approved =
    boolTrue(d.nexride_verified) || hasApprovedDocuments(d.verification);
  const market_pool = normalizeDispatchKey(d.market_pool ?? "");
  const market = normalizeDispatchKey(d.market ?? "");
  const city = String(d.city ?? "").trim();
  const availabilityMode = normalizeDriverAvailabilityMode(
    d.driver_availability_mode ?? d.availability_mode ?? "",
  );
  const lastLocTs = Number(d.last_location_updated_at ?? 0) || 0;
  const vehicleType = String(d.vehicle_type ?? d.vehicleType ?? "")
    .trim()
    .toLowerCase();
  return {
    uid: normUid(driverId),
    dispatch_market: dm || "missing",
    market_pool: market_pool || "(empty)",
    market: market || "(empty)",
    city: city || "(empty)",
    online,
    is_online,
    approved,
    suspended,
    status: status || "(empty)",
    dispatch_state: dispatchState || "(empty)",
    driver_availability_mode: availabilityMode || "(legacy)",
    last_location_updated_at: lastLocTs,
    selected_service_area_id: String(d.selected_service_area_id ?? "").trim() || "(empty)",
    vehicle_type: vehicleType || "(empty)",
  };
}

/** Bike / two-wheel modes must not receive rider car-hailing (`service_type: ride`) offers. */
const NON_CAR_RIDE_VEHICLE_TYPES = new Set([
  "bike",
  "bicycle",
  "ebike",
  "e_bike",
  "motorcycle",
  "motorbike",
  "okada",
  "tricycle",
  "dispatch_bike",
]);

const CAR_RIDE_VEHICLE_TYPES = new Set([
  "car",
  "sedan",
  "suv",
  "van",
  "minivan",
  "mpv",
  "saloon",
  "hatchback",
  "wagon",
]);

/**
 * Car-hailing ride offers: driver must not be a bike/dispatch-only profile; `service_capabilities.ride`
 * may opt out. Legacy drivers with no `vehicle_type` stay eligible (treated as car fleet).
 *
 * @param {Record<string, unknown>} driverProfile
 * @param {Record<string, unknown>} ridePayload
 * @returns {{ ok: true } | { ok: false, log: string, detail: string }}
 */
function evaluateCarRideVehicleAndCapability(driverProfile, ridePayload) {
  const svc = String(ridePayload?.service_type ?? ridePayload?.serviceType ?? "ride")
    .trim()
    .toLowerCase();
  if (svc !== "ride") {
    return { ok: true };
  }

  const requested = String(
    ridePayload?.vehicle_type ?? ridePayload?.requested_vehicle_type ?? "car",
  )
    .trim()
    .toLowerCase();
  if (requested && requested !== "car") {
    return { ok: false, log: "RIDE_FILTER_VEHICLE_CLASS", detail: `ride_requests_non_car:${requested}` };
  }

  const d = driverProfile && typeof driverProfile === "object" ? driverProfile : {};
  const caps =
    d.service_capabilities && typeof d.service_capabilities === "object"
      ? d.service_capabilities
      : {};
  if (caps.ride === false) {
    return { ok: false, log: "DRIVER_FILTERED_CAPABILITIES", detail: "ride_capability_false" };
  }

  const vt = String(d.vehicle_type ?? d.vehicleType ?? "")
    .trim()
    .toLowerCase()
    .replace(/[\s-]+/g, "_");
  if (!vt) {
    return { ok: true };
  }
  if (NON_CAR_RIDE_VEHICLE_TYPES.has(vt)) {
    return { ok: false, log: "DRIVER_FILTERED_VEHICLE", detail: `non_car:${vt}` };
  }
  if (CAR_RIDE_VEHICLE_TYPES.has(vt)) {
    return { ok: true };
  }
  return { ok: false, log: "DRIVER_FILTERED_VEHICLE", detail: `vehicle_not_car_class:${vt}` };
}

module.exports = {
  normUid,
  canonicalMarketSlug,
  normalizeDriverAvailabilityMode,
  resolveDriverAvailabilityMode,
  driverRideMarketsAligned,
  evaluateDriverForOffer,
  evaluateDriverForOfferSoft,
  evaluateDriverVerificationForOffer,
  evaluateDriverGeoAndMode,
  buildDriverFanoutFilterTrace,
  logMatchLocationSource,
  matchLocationAuditPayload,
  driverDispatchMarketId,
  rideDispatchMarketId,
  pickupCoordsFromRide,
  driverLastKnownCoords,
  haversineKm,
  evaluateCarRideVehicleAndCapability,
  loadDispatchGates,
  summarizeDriverForFanout,
  driverSessionOnlineForDispatch,
  STALE_DRIVER_LOCATION_MS,
  MAX_DRIVER_PICKUP_DISTANCE_KM,
};
