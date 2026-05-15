/**
 * Production driver offer eligibility — mirrors Flutter driver_verification_restrictions loosely.
 */

function normUid(uid) {
  return String(uid ?? "").trim();
}

function boolTrue(v) {
  return v === true || v === "true" || v === 1 || v === "1";
}

function canonicalMarketSlug(raw) {
  return String(raw ?? "")
    .trim()
    .toLowerCase()
    .replace(/\s+/g, "_")
    .replace(/-+/g, "_");
}

/** @param {unknown} raw */
function normalizeDriverAvailabilityMode(raw) {
  const m = String(raw ?? "")
    .trim()
    .toLowerCase()
    .replace(/-/g, "_");
  if (m === "current_location" || m === "gps" || m === "current") return "current_location";
  if (m === "service_area" || m === "servicearea" || m === "city") return "service_area";
  if (m === "offline") return "offline";
  return "";
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
function driverLastKnownCoords(driverProfile) {
  const d = driverProfile && typeof driverProfile === "object" ? driverProfile : {};
  const ll = d.last_location && typeof d.last_location === "object" ? d.last_location : {};
  const lat0 = Number(ll.lat ?? ll.latitude ?? "");
  const lng0 = Number(ll.lng ?? ll.longitude ?? "");
  if (
    Number.isFinite(lat0) &&
    Number.isFinite(lng0) &&
    !(lat0 === 0 && lng0 === 0)
  ) {
    return { lat: lat0, lng: lng0 };
  }
  const lat = Number(d.lat ?? d.latitude ?? "");
  const lng = Number(d.lng ?? d.longitude ?? "");
  return { lat, lng };
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
function evaluateDriverGeoAndMode(driverProfile, ridePayload, nowMs) {
  const d = driverProfile && typeof driverProfile === "object" ? driverProfile : {};
  const mode = normalizeDriverAvailabilityMode(
    d.driver_availability_mode ?? d.availability_mode ?? "",
  );
  if (!mode) {
    return { ok: true, log: "GEO_LEGACY", detail: "skipped" };
  }
  if (mode === "offline") {
    return { ok: false, log: "DRIVER_FILTERED_MODE", detail: "offline_mode" };
  }

  if (mode === "service_area") {
    const sel = String(
      d.selected_service_area_id ?? d.rollout_city_id ?? d.service_city_id ?? "",
    ).trim();
    if (!sel) {
      return { ok: false, log: "DRIVER_FILTERED_SERVICE_AREA", detail: "service_area_required" };
    }
    const rideCity = String(
      ridePayload.resolved_service_city_id ??
        ridePayload.service_city_id ??
        ridePayload.rollout_city_id ??
        "",
    ).trim();
    if (!rideCity) {
      return { ok: true, log: "GEO_SERVICE_AREA_FALLBACK", detail: "ride_city_unresolved" };
    }
    if (canonicalMarketSlug(sel) !== canonicalMarketSlug(rideCity)) {
      return { ok: false, log: "DRIVER_FILTERED_SERVICE_AREA", detail: "city_mismatch" };
    }
    return { ok: true };
  }

  if (mode === "current_location") {
    const pickup = pickupCoordsFromRide(ridePayload);
    if (!Number.isFinite(pickup.lat) || !Number.isFinite(pickup.lng)) {
      return { ok: true, log: "GEO_PICKUP_MISSING", detail: "pickup_unavailable" };
    }
    const drv = driverLastKnownCoords(d);
    if (!Number.isFinite(drv.lat) || !Number.isFinite(drv.lng)) {
      return { ok: false, log: "DRIVER_FILTERED_LOCATION", detail: "location_required" };
    }
    const ts = Number(d.last_location_updated_at ?? 0) || 0;
    if (ts > 0 && nowMs - ts > STALE_DRIVER_LOCATION_MS) {
      return { ok: false, log: "DRIVER_FILTERED_STALE_GPS", detail: "stale_location" };
    }
    const dist = haversineKm(drv.lat, drv.lng, pickup.lat, pickup.lng);
    if (!Number.isFinite(dist)) {
      return { ok: false, log: "DRIVER_FILTERED_LOCATION", detail: "location_invalid" };
    }
    if (dist > MAX_DRIVER_PICKUP_DISTANCE_KM) {
      return { ok: false, log: "DRIVER_FILTERED_DISTANCE", detail: "too_far" };
    }
    return { ok: true };
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
  const rideM = canonicalMarketSlug(
    ridePayload.market_pool ?? ridePayload.market ?? "",
  );
  if (!rideM) {
    return { ok: false, log: "NO_RIDE_MARKET", detail: "missing" };
  }
  const dm = canonicalMarketSlug(d.dispatch_market ?? "");
  const mm = canonicalMarketSlug(d.market ?? "");
  const mp = canonicalMarketSlug(d.market_pool ?? "");
  const city = canonicalMarketSlug(d.city ?? d.launch_market_city ?? "");
  const marketOk =
    (dm && dm === rideM) ||
    (mm && mm === rideM) ||
    (mp && mp === rideM) ||
    (city && city === rideM);
  if (!marketOk) {
    return { ok: false, log: "DRIVER_FILTERED_MARKET_SOFT", detail: "market_mismatch" };
  }
  const online =
    d.isOnline === true || d.is_online === true || d.online === true;
  if (!online) {
    return { ok: false, log: "NOT_ONLINE", detail: "session_off" };
  }
  const st = String(d.status ?? "").trim().toLowerCase();
  if (st && st !== "available") {
    return { ok: false, log: "STATUS_NOT_AVAILABLE", detail: st };
  }
  const ds = String(d.dispatch_state ?? "").trim().toLowerCase();
  if (ds && ds !== "available") {
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

  const marketRide = String(
    ridePayload.market_pool ?? ridePayload.market ?? "",
  )
    .trim()
    .toLowerCase()
    .replace(/\s+/g, "_")
    .replace(/-+/g, "_");
  const dm = String(d.dispatch_market ?? d.market ?? d.market_pool ?? "")
    .trim()
    .toLowerCase()
    .replace(/\s+/g, "_")
    .replace(/-+/g, "_");
  if (marketRide && dm && marketRide !== dm) {
    return { ok: false, log: "DRIVER_FILTERED_MARKET", detail: "market_pool_mismatch" };
  }

  return evaluateDriverVerificationForOffer(d, gates, ridePayload);
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
  const dm = String(d.dispatch_market ?? d.market_pool ?? d.market ?? "")
    .trim()
    .toLowerCase()
    .replace(/\s+/g, "_")
    .replace(/-+/g, "_");
  const status = String(d.status ?? "").trim().toLowerCase();
  const dispatchState = String(d.dispatch_state ?? "").trim().toLowerCase();
  const approved =
    boolTrue(d.nexride_verified) || hasApprovedDocuments(d.verification);
  const market_pool = String(d.market_pool ?? "")
    .trim()
    .toLowerCase()
    .replace(/\s+/g, "_")
    .replace(/-+/g, "_");
  const market = String(d.market ?? "")
    .trim()
    .toLowerCase()
    .replace(/\s+/g, "_")
    .replace(/-+/g, "_");
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
  normalizeDriverAvailabilityMode,
  evaluateDriverForOffer,
  evaluateDriverForOfferSoft,
  evaluateDriverVerificationForOffer,
  evaluateDriverGeoAndMode,
  evaluateCarRideVehicleAndCapability,
  loadDispatchGates,
  summarizeDriverForFanout,
  STALE_DRIVER_LOCATION_MS,
  MAX_DRIVER_PICKUP_DISTANCE_KM,
};
