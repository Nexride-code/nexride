/**
 * NexRide rollout regions: Firestore `delivery_regions/{regionId}` + nested `cities/{cityId}`.
 * Only six states are in scope; cities are individually toggleable.
 *
 * Canonical dispatch market ids (RTDB / ride payloads) map via `dispatch_market_id` on the state doc.
 */

const admin = require("firebase-admin");
const { FieldValue } = require("firebase-admin/firestore");
const { logger } = require("firebase-functions");
const { normUid } = require("../admin_auth");
const adminPerms = require("../admin_permissions");
const { writeAdminAuditLog } = require("../admin_audit_log");

function haversineKm(lat1, lng1, lat2, lng2) {
  const R = 6371;
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) * Math.sin(dLng / 2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return R * c;
}

function trim(v, max = 200) {
  return String(v ?? "")
    .trim()
    .slice(0, max);
}

/** @type {readonly string[]} */
const ROLLOUT_REGION_IDS = Object.freeze(["lagos", "abuja", "imo", "edo", "anambra", "delta"]);

/** @type {readonly string[]} */
const ROLLOUT_DISPATCH_MARKET_IDS = Object.freeze(["lagos", "abuja_fct", "imo", "edo", "anambra", "delta"]);

function dispatchMarketToRegionId(marketId) {
  const m = trim(marketId, 80).toLowerCase();
  if (m === "lagos") return "lagos";
  if (m === "abuja_fct" || m === "abuja") return "abuja";
  if (m === "imo") return "imo";
  if (m === "edo") return "edo";
  if (m === "anambra") return "anambra";
  if (m === "delta") return "delta";
  return "";
}

/**
 * Resolve Firestore `delivery_regions` doc id from RTDB `dispatch_market_id` /
 * ride `market_pool` (admin-managed; not hardcoded beyond legacy aliases above).
 * @param {import('firebase-admin').firestore.Firestore} fs
 */
async function resolveRegionIdByDispatchMarket(fs, marketId) {
  const m = trim(marketId, 80).toLowerCase();
  if (!m) return "";
  const legacy = dispatchMarketToRegionId(m);
  if (legacy) return legacy;
  try {
    const snap = await fs.collection("delivery_regions").where("dispatch_market_id", "==", m).limit(8).get();
    for (const d of snap.docs) {
      const row = d.data() || {};
      if (row.enabled !== false) {
        return d.id;
      }
    }
    const snapAny = await fs.collection("delivery_regions").where("dispatch_market_id", "==", m).limit(1).get();
    if (!snapAny.empty) {
      return snapAny.docs[0].id;
    }
  } catch (e) {
    logger.warn("DELIVERY_REGION_RESOLVE_MARKET_FAILED", { marketId: m, error: String(e) });
  }
  return "";
}

/**
 * Nested city seed per rollout state.
 * @type {Array<{
 *   region_id: string,
 *   state: string,
 *   dispatch_market_id: string,
 *   cities: Array<{
 *     city_id: string,
 *     display_name: string,
 *     center_lat: number,
 *     center_lng: number,
 *     service_radius_km: number,
 *   }>,
 * }>}
 */
const ROLLOUT_SEED = [
  {
    region_id: "lagos",
    state: "Lagos",
    dispatch_market_id: "lagos",
    cities: [
      { city_id: "lekki", display_name: "Lekki", center_lat: 6.4698, center_lng: 3.5852, service_radius_km: 28 },
      { city_id: "victoria_island", display_name: "Victoria Island", center_lat: 6.4281, center_lng: 3.4219, service_radius_km: 12 },
      { city_id: "ikoyi", display_name: "Ikoyi", center_lat: 6.4531, center_lng: 3.4228, service_radius_km: 10 },
      { city_id: "ikeja", display_name: "Ikeja", center_lat: 6.6018, center_lng: 3.3515, service_radius_km: 22 },
      { city_id: "yaba", display_name: "Yaba", center_lat: 6.5144, center_lng: 3.3719, service_radius_km: 14 },
      { city_id: "surulere", display_name: "Surulere", center_lat: 6.5005, center_lng: 3.351, service_radius_km: 16 },
    ],
  },
  {
    region_id: "abuja",
    state: "FCT",
    dispatch_market_id: "abuja_fct",
    cities: [
      { city_id: "wuse", display_name: "Wuse", center_lat: 9.0765, center_lng: 7.3986, service_radius_km: 14 },
      { city_id: "gwarinpa", display_name: "Gwarinpa", center_lat: 9.0, center_lng: 7.32, service_radius_km: 18 },
      { city_id: "maitama", display_name: "Maitama", center_lat: 9.08, center_lng: 7.49, service_radius_km: 10 },
      { city_id: "asokoro", display_name: "Asokoro", center_lat: 9.03, center_lng: 7.53, service_radius_km: 10 },
    ],
  },
  {
    region_id: "imo",
    state: "Imo",
    dispatch_market_id: "imo",
    cities: [{ city_id: "owerri", display_name: "Owerri", center_lat: 5.484, center_lng: 7.033, service_radius_km: 35 }],
  },
  {
    region_id: "edo",
    state: "Edo",
    dispatch_market_id: "edo",
    cities: [{ city_id: "benin_city", display_name: "Benin City", center_lat: 6.335, center_lng: 5.6037, service_radius_km: 40 }],
  },
  {
    region_id: "anambra",
    state: "Anambra",
    dispatch_market_id: "anambra",
    cities: [
      { city_id: "awka", display_name: "Awka", center_lat: 6.2104, center_lng: 7.0741, service_radius_km: 25 },
      { city_id: "onitsha", display_name: "Onitsha", center_lat: 6.1667, center_lng: 6.7833, service_radius_km: 28 },
      { city_id: "nnewi", display_name: "Nnewi", center_lat: 6.02, center_lng: 6.91, service_radius_km: 22 },
    ],
  },
  {
    region_id: "delta",
    state: "Delta",
    dispatch_market_id: "delta",
    cities: [
      { city_id: "asaba", display_name: "Asaba", center_lat: 6.1982, center_lng: 6.7349, service_radius_km: 28 },
      { city_id: "warri", display_name: "Warri", center_lat: 5.516, center_lng: 5.75, service_radius_km: 35 },
    ],
  },
];

function serviceKey(service) {
  const s = trim(service, 20).toLowerCase();
  if (s === "rides" || s === "ride") return "supports_rides";
  if (s === "food") return "supports_food";
  if (s === "package" || s === "parcel") return "supports_package";
  if (s === "merchant") return "supports_merchant";
  if (s === "delivery" || s === "dispatch" || s === "dispatch_delivery") return "supports_delivery";
  return "";
}

/** Explicit `supports_delivery` or legacy food/package toggles. */
function effectiveSupportsDelivery(row) {
  const r = row || {};
  if (r.supports_delivery === true || r.supports_delivery === false) {
    return r.supports_delivery !== false;
  }
  return r.supports_food !== false || r.supports_package !== false;
}

function parentSupports(row, key) {
  if (!key) return false;
  if (key === "supports_delivery") {
    return effectiveSupportsDelivery(row);
  }
  return row[key] !== false;
}

function citySupports(cityRow, key) {
  if (!key) return false;
  if (key === "supports_delivery") {
    return effectiveSupportsDelivery(cityRow);
  }
  return cityRow[key] !== false;
}

async function loadRegionDoc(fs, regionId) {
  const id = trim(regionId, 80);
  if (!id) return null;
  const snap = await fs.collection("delivery_regions").doc(id).get();
  return snap.exists ? { id, ref: snap.ref, data: snap.data() || {} } : null;
}

async function loadCityDoc(fs, regionId, cityId) {
  const rid = trim(regionId, 80);
  const cid = trim(cityId, 80);
  if (!rid || !cid) return null;
  const snap = await fs.collection("delivery_regions").doc(rid).collection("cities").doc(cid).get();
  return snap.exists ? { id: cid, data: snap.data() || {} } : null;
}

/**
 * @param {import('firebase-admin').firestore.Firestore} fs
 * @param {{ region_id: string, city_id: string, dispatch_market_id?: string }} geo
 */
async function buildRiderPickupAreaSuggestion(fs, geo) {
  const rid = trim(geo?.region_id, 80);
  const cid = trim(geo?.city_id, 80);
  if (!rid || !cid) {
    return {};
  }
  const reg = await loadRegionDoc(fs, rid);
  const city = await loadCityDoc(fs, rid, cid);
  const c = city?.data || {};
  const name =
    String(c.display_name ?? c.city_name ?? cid ?? "").trim() || cid;
  const state = String(reg?.data?.state ?? "").trim();
  const dm = String(geo.dispatch_market_id ?? reg?.data?.dispatch_market_id ?? "").trim();
  return {
    suggested_service_area_id: cid,
    suggested_service_area_name: name,
    suggested_service_region_id: rid,
    suggested_state: state,
    suggested_dispatch_market_id: dm,
  };
}

/**
 * Validates region + city exist and services are enabled at both levels.
 */
async function validateRolloutSelection(fs, regionId, cityId, opts = {}) {
  const rid = trim(regionId, 80);
  const cid = trim(cityId, 80);
  const sk = serviceKey(opts.service || "merchant");
  const reg = await loadRegionDoc(fs, rid);
  if (!reg || reg.data.enabled === false) {
    return { ok: false, reason: "region_disabled" };
  }
  if (sk && !parentSupports(reg.data, sk)) {
    return { ok: false, reason: "region_service_disabled" };
  }
  const city = await loadCityDoc(fs, rid, cid);
  if (!city || city.data.enabled === false) {
    return { ok: false, reason: "city_disabled" };
  }
  if (sk && !citySupports(city.data, sk)) {
    return { ok: false, reason: "city_service_disabled" };
  }
  return {
    ok: true,
    region_id: rid,
    city_id: cid,
    state_label: String(reg.data.state || ""),
    city_label: String(city.data.display_name || city.data.city_name || cid),
    dispatch_market_id: String(reg.data.dispatch_market_id || "").trim(),
  };
}

/**
 * Pickup / driver position: must fall inside an enabled city service bubble for the service.
 */
async function assertRolloutGeoForDispatch(fs, dispatchMarketId, lat, lng, service) {
  let regionId = dispatchMarketToRegionId(dispatchMarketId);
  if (!regionId) {
    regionId = await resolveRegionIdByDispatchMarket(fs, dispatchMarketId);
  }
  if (!regionId) {
    logDeliveryRegionBlock("dispatch_market_not_in_rollout", { dispatch_market_id: dispatchMarketId });
    return { ok: false, reason: "service_area_unsupported", message: "NexRide is not available in your area yet." };
  }
  const reg = await loadRegionDoc(fs, regionId);
  if (!reg || reg.data.enabled === false) {
    logDeliveryRegionBlock("region_doc_missing_or_disabled", { region_id: regionId });
    return { ok: false, reason: "service_area_unsupported", message: "NexRide is not available in your area yet." };
  }
  const sk = serviceKey(service);
  if (sk && !parentSupports(reg.data, sk)) {
    logDeliveryRegionBlock("parent_service_off", { region_id: regionId, service: sk });
    return { ok: false, reason: "service_area_unsupported", message: "NexRide is not available in your area yet." };
  }
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
    logDeliveryRegionBlock("missing_coordinates", { region_id: regionId, service });
    return { ok: false, reason: "location_required_for_service_area" };
  }

  const citiesSnap = await fs.collection("delivery_regions").doc(regionId).collection("cities").get();
  let matchedCity = "";
  for (const doc of citiesSnap.docs) {
    const c = doc.data() || {};
    if (c.enabled === false) {
      continue;
    }
    if (sk && !citySupports(c, sk)) {
      continue;
    }
    const clat = Number(c.center_lat ?? c.centerLat);
    const clng = Number(c.center_lng ?? c.centerLng);
    const rad = Number(c.service_radius_km ?? c.serviceRadiusKm ?? 25);
    if (!Number.isFinite(clat) || !Number.isFinite(clng) || !Number.isFinite(rad) || rad <= 0) {
      continue;
    }
    const d = haversineKm(lat, lng, clat, clng);
    if (d <= rad) {
      matchedCity = doc.id;
      break;
    }
  }
  if (!matchedCity) {
    logDeliveryRegionBlock("no_city_bubble_match", {
      region_id: regionId,
      dispatch_market_id: dispatchMarketId,
      service: sk,
    });
    return { ok: false, reason: "pickup_outside_enabled_city", message: "NexRide is not available in your area yet." };
  }
  return {
    ok: true,
    region_id: regionId,
    city_id: matchedCity,
    dispatch_market_id: String(reg.data.dispatch_market_id || dispatchMarketId),
  };
}

/**
 * When client passes explicit rollout ids, verify coords lie in that city bubble (or skip coords if strict=false).
 * @param {{ strict_ride_request_hints?: boolean }} [opts]
 */
async function assertRolloutWithHints(fs, dispatchMarketId, lat, lng, service, hints = {}, opts = {}) {
  const strictRideRequestHints = opts.strict_ride_request_hints === true;
  const regionHint = trim(hints.region_id ?? hints.rollout_region_id, 80);
  const cityHint = trim(hints.city_id ?? hints.service_city_id ?? hints.rollout_city_id, 80);
  if (regionHint && cityHint) {
    const v = await validateRolloutSelection(fs, regionHint, cityHint, { service });
    if (!v.ok) {
      logDeliveryRegionBlock("hint_validation_failed", { reason: v.reason, regionHint, cityHint });
      return { ok: false, reason: v.reason || "rollout_hint_invalid", message: "NexRide is not available in your area yet." };
    }
    if (Number.isFinite(lat) && Number.isFinite(lng)) {
      const cityRow = await loadCityDoc(fs, regionHint, cityHint);
      const c = cityRow?.data || {};
      const clat = Number(c.center_lat ?? c.centerLat);
      const clng = Number(c.center_lng ?? c.centerLng);
      const rad = Number(c.service_radius_km ?? c.serviceRadiusKm ?? 25);
      if (Number.isFinite(clat) && Number.isFinite(clng) && Number.isFinite(rad) && rad > 0) {
        const d = haversineKm(lat, lng, clat, clng);
        if (d > rad) {
          logDeliveryRegionBlock("hint_coords_outside_city_try_geo", {
            regionHint,
            cityHint,
            d_km: d,
            dispatch_market_id: dispatchMarketId,
          });
          const geo = await assertRolloutGeoForDispatch(fs, dispatchMarketId, lat, lng, service);
          const sk = serviceKey(service);
          if (strictRideRequestHints && sk === "supports_rides") {
            if (geo.ok && (geo.region_id !== regionHint || geo.city_id !== cityHint)) {
              const sug = await buildRiderPickupAreaSuggestion(fs, geo);
              logDeliveryRegionBlock("ride_hint_mismatch_suggest_area", {
                regionHint,
                cityHint,
                suggested_region: sug.suggested_service_region_id,
                suggested_city: sug.suggested_service_area_id,
              });
              return {
                ok: false,
                reason: "pickup_outside_selected_service_area",
                message: "Your pickup is in a different NexRide service area than the one you selected.",
                ...sug,
              };
            }
            if (!geo.ok) {
              logDeliveryRegionBlock("ride_hint_geo_no_active_bubble", {
                regionHint,
                cityHint,
                geo_reason: geo.reason || null,
              });
              return {
                ok: false,
                reason: "no_service_area_for_pickup",
                message: "NexRide is not available in this pickup area yet.",
              };
            }
            return geo;
          }
          if (geo.ok) {
            return geo;
          }
          logDeliveryRegionBlock("hint_coords_outside_city_geo_failed", {
            regionHint,
            cityHint,
            d_km: d,
            geo_reason: geo.reason || null,
          });
          return {
            ok: false,
            reason: "pickup_mismatch_service_city",
            message: "Selected area does not match your pickup location.",
          };
        }
      }
    }
    return {
      ok: true,
      region_id: regionHint,
      city_id: cityHint,
      dispatch_market_id:
        v.dispatch_market_id ||
        String((await loadRegionDoc(fs, regionHint))?.data?.dispatch_market_id || "").trim() ||
        trim(dispatchMarketId, 80),
    };
  }
  return assertRolloutGeoForDispatch(fs, dispatchMarketId, lat, lng, service);
}

function logDeliveryRegionBlock(reason, meta) {
  logger.warn("DELIVERY_REGION_BLOCK", { reason, ...meta });
}

function validateGeoInputs(center_lat, center_lng, service_radius_km) {
  const lat = Number(center_lat);
  const lng = Number(center_lng);
  const rad = Number(service_radius_km);
  if (!Number.isFinite(lat) || lat < -90 || lat > 90) {
    return { ok: false, reason: "invalid_center_lat" };
  }
  if (!Number.isFinite(lng) || lng < -180 || lng > 180) {
    return { ok: false, reason: "invalid_center_lng" };
  }
  if (!Number.isFinite(rad) || rad <= 0 || rad > 500) {
    return { ok: false, reason: "invalid_service_radius_km" };
  }
  return { ok: true };
}

function isRolloutDispatchMarket(marketId) {
  const m = trim(marketId, 80).toLowerCase();
  if (ROLLOUT_DISPATCH_MARKET_IDS.includes(m)) return true;
  return dispatchMarketToRegionId(m) !== "";
}

/**
 * @param {import('firebase-admin').firestore.Firestore} fs
 */
async function adminUpsertDeliveryRegion(data, context, db) {
  const denyUr = await adminPerms.enforceCallable(db, context, "adminUpsertDeliveryRegion");
  if (denyUr) return denyUr;
  const regionId = trim(data?.region_id ?? data?.regionId, 80);
  if (!regionId) {
    return { success: false, reason: "invalid_payload" };
  }
  const state = trim(data?.state, 80);
  const dispatch_market_id = trim(data?.dispatch_market_id ?? data?.dispatchMarketId, 80);
  if (!state || !dispatch_market_id) {
    return { success: false, reason: "invalid_payload" };
  }
  const fs = admin.firestore();
  const enabled = data?.enabled !== false;
  const supports_rides = data?.supports_rides !== false && data?.supports_ride !== false;
  const supports_food = data?.supports_food !== false;
  const supports_package = data?.supports_package !== false;
  const supports_merchant = data?.supports_merchant !== false;
  const supports_delivery = data?.supports_delivery !== false && data?.supportsDelivery !== false;
  const currency = trim(data?.currency, 8) || "NGN";
  const timezone = trim(data?.timezone, 64) || "Africa/Lagos";

  await fs
    .collection("delivery_regions")
    .doc(regionId)
    .set(
      {
        region_id: regionId,
        country: trim(data?.country, 80) || "Nigeria",
        state,
        enabled,
        supports_rides,
        supports_food,
        supports_package,
        supports_merchant,
        supports_delivery,
        dispatch_market_id,
        currency,
        timezone,
        updated_at: FieldValue.serverTimestamp(),
        updated_by: normUid(context.auth?.uid),
      },
      { merge: true },
    );
  logger.info("DELIVERY_REGION_UPSERT", { region_id: regionId, enabled, state });
  return { success: true, region_id: regionId };
}

/**
 * @param {import('firebase-admin').firestore.Firestore} fs
 */
async function adminUpsertDeliveryCity(data, context, db) {
  const denyUc = await adminPerms.enforceCallable(db, context, "adminUpsertDeliveryCity");
  if (denyUc) return denyUc;
  const regionId = trim(data?.region_id ?? data?.regionId, 80);
  const cityId = trim(data?.city_id ?? data?.cityId, 120);
  let display_name = trim(data?.display_name ?? data?.displayName, 160);
  if (!regionId || !cityId) {
    return { success: false, reason: "invalid_payload" };
  }
  const fs = admin.firestore();
  const existing = (await loadCityDoc(fs, regionId, cityId))?.data || {};
  if (!display_name) {
    display_name = trim(existing.display_name ?? existing.city_name ?? cityId, 160) || cityId;
  }
  const enabled = data?.enabled !== false;
  const supports_rides = data?.supports_rides !== false && data?.supports_ride !== false;
  const supports_food = data?.supports_food !== false;
  const supports_package = data?.supports_package !== false;
  const supports_merchant = data?.supports_merchant !== false;
  const supports_delivery = data?.supports_delivery !== false && data?.supportsDelivery !== false;

  const center_lat = Number(data?.center_lat ?? data?.centerLat ?? existing.center_lat ?? existing.centerLat);
  const center_lng = Number(data?.center_lng ?? data?.centerLng ?? existing.center_lng ?? existing.centerLng);
  const service_radius_km = Number(
    data?.service_radius_km ?? data?.serviceRadiusKm ?? existing.service_radius_km ?? existing.serviceRadiusKm ?? 25,
  );

  const geo = validateGeoInputs(center_lat, center_lng, service_radius_km);
  if (!geo.ok) {
    return { success: false, reason: geo.reason || "invalid_geo" };
  }

  await fs
    .collection("delivery_regions")
    .doc(regionId)
    .collection("cities")
    .doc(cityId)
    .set(
      {
        city_id: cityId,
        display_name,
        enabled,
        supports_rides,
        supports_food,
        supports_package,
        supports_merchant,
        supports_delivery,
        center_lat: Number.isFinite(center_lat) ? center_lat : null,
        center_lng: Number.isFinite(center_lng) ? center_lng : null,
        service_radius_km: Number.isFinite(service_radius_km) && service_radius_km > 0 ? service_radius_km : 25,
        updated_at: FieldValue.serverTimestamp(),
        updated_by: normUid(context.auth?.uid),
      },
      { merge: true },
    );
  logger.info("DELIVERY_CITY_UPSERT", { region_id: regionId, city_id: cityId, enabled });
  const adminUid = normUid(context.auth?.uid);
  const prevEnabled = existing.enabled !== false;
  const afterEnabled = enabled !== false;
  let action = "update_service_area";
  if (!prevEnabled && afterEnabled) {
    action = "enable_service_area";
  } else if (prevEnabled && !afterEnabled) {
    action = "disable_service_area";
  }
  const beforeRow = {
    display_name: existing.display_name ?? existing.displayName ?? existing.city_name ?? null,
    enabled: prevEnabled,
    center_lat: existing.center_lat ?? existing.centerLat ?? null,
    center_lng: existing.center_lng ?? existing.centerLng ?? null,
    service_radius_km: existing.service_radius_km ?? existing.serviceRadiusKm ?? null,
  };
  const afterRow = {
    display_name,
    enabled: afterEnabled,
    center_lat: Number.isFinite(center_lat) ? center_lat : null,
    center_lng: Number.isFinite(center_lng) ? center_lng : null,
    service_radius_km: Number.isFinite(service_radius_km) && service_radius_km > 0 ? service_radius_km : 25,
  };
  await writeAdminAuditLog(db, {
    actor_uid: adminUid,
    action,
    entity_type: "service_area",
    entity_id: `${regionId}/${cityId}`,
    before: beforeRow,
    after: afterRow,
    reason: trim(data?.reason ?? data?.note ?? "", 500) || null,
    source: "delivery_regions.adminUpsertDeliveryCity",
    type: `admin_${action}`,
    created_at: Date.now(),
  });
  return { success: true, region_id: regionId, city_id: cityId };
}

async function adminSeedRolloutDeliveryRegions(_data, context, db) {
  const denySeed = await adminPerms.enforceCallable(db, context, "adminSeedRolloutDeliveryRegions");
  if (denySeed) return denySeed;
  const fs = admin.firestore();
  const adminUid = normUid(context.auth?.uid);
  for (const row of ROLLOUT_SEED) {
    const { cities } = row;
    const regionId = row.region_id;
    await fs
      .collection("delivery_regions")
      .doc(regionId)
      .set(
        {
          region_id: regionId,
          country: "Nigeria",
          state: row.state,
          enabled: true,
          supports_rides: true,
          supports_food: true,
          supports_package: true,
          supports_merchant: true,
          supports_delivery: true,
          dispatch_market_id: row.dispatch_market_id,
          currency: "NGN",
          timezone: "Africa/Lagos",
          seeded_at: FieldValue.serverTimestamp(),
          seeded_by: adminUid,
          updated_at: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
    for (const c of cities) {
      await fs
        .collection("delivery_regions")
        .doc(regionId)
        .collection("cities")
        .doc(c.city_id)
        .set(
          {
            city_id: c.city_id,
            display_name: c.display_name,
            enabled: true,
            supports_rides: true,
            supports_food: true,
            supports_package: true,
            supports_merchant: true,
            supports_delivery: true,
            center_lat: c.center_lat,
            center_lng: c.center_lng,
            service_radius_km: c.service_radius_km,
            seeded_at: FieldValue.serverTimestamp(),
            updated_at: FieldValue.serverTimestamp(),
          },
          { merge: true },
        );
    }
  }
  logger.info("DELIVERY_REGION_SEED_ROLLOUT", { regions: ROLLOUT_SEED.length });
  return { success: true, regions: ROLLOUT_SEED.length };
}

/** @deprecated use adminSeedRolloutDeliveryRegions */
async function adminSeedDefaultNigeriaDeliveryRegions(data, context, db) {
  return adminSeedRolloutDeliveryRegions(data, context, db);
}

/**
 * Authenticated clients: nested regions with enabled cities only.
 */
async function listDeliveryRegions(data, context) {
  if (!context?.auth?.uid) {
    return { success: false, reason: "unauthorized" };
  }
  const fs = admin.firestore();
  const snap = await fs.collection("delivery_regions").where("enabled", "==", true).get();
  const regions = [];
  for (const doc of snap.docs) {
    const m = doc.data() || {};
    const citiesSnap = await doc.ref.collection("cities").where("enabled", "==", true).get();
    const cities = [];
    citiesSnap.forEach((cd) => {
      const c = cd.data() || {};
      cities.push({
        city_id: cd.id,
        display_name: c.display_name ?? cd.id,
        enabled: c.enabled !== false,
        supports_rides: c.supports_rides !== false,
        supports_food: c.supports_food !== false,
        supports_package: c.supports_package !== false,
        supports_merchant: c.supports_merchant !== false,
        supports_delivery: effectiveSupportsDelivery(c),
        center_lat: c.center_lat ?? c.centerLat ?? null,
        center_lng: c.center_lng ?? c.centerLng ?? null,
        service_radius_km: c.service_radius_km ?? c.serviceRadiusKm ?? null,
      });
    });
    regions.push({
      region_id: doc.id,
      country: m.country ?? "Nigeria",
      state: m.state ?? "",
      enabled: m.enabled !== false,
      supports_rides: m.supports_rides !== false,
      supports_food: m.supports_food !== false,
      supports_package: m.supports_package !== false,
      supports_merchant: m.supports_merchant !== false,
      supports_delivery: effectiveSupportsDelivery(m),
      dispatch_market_id: m.dispatch_market_id ?? "",
      currency: m.currency ?? "NGN",
      timezone: m.timezone ?? "Africa/Lagos",
      cities,
    });
  }
  regions.sort((a, b) => String(a.state).localeCompare(String(b.state)));
  return { success: true, regions, items: regions };
}

async function adminListDeliveryRollout(data, context, db) {
  const denyLdr = await adminPerms.enforceCallable(db, context, "adminListDeliveryRollout");
  if (denyLdr) return denyLdr;
  const fs = admin.firestore();
  const snap = await fs.collection("delivery_regions").get();
  const regions = [];
  for (const doc of snap.docs) {
    const m = doc.data() || {};
    const cs = await doc.ref.collection("cities").get();
    const cities = [];
    cs.forEach((cd) => {
      const c = cd.data() || {};
      cities.push({
        city_id: cd.id,
        ...c,
        updated_at: c.updated_at?.toMillis?.() ?? null,
      });
    });
    regions.push({
      region_id: doc.id,
      ...m,
      cities,
      updated_at: m.updated_at?.toMillis?.() ?? null,
      seeded_at: m.seeded_at?.toMillis?.() ?? null,
    });
  }
  regions.sort((a, b) => String(a.region_id).localeCompare(String(b.region_id)));
  return {
    success: true,
    regions,
    metrics_stub: regions.map((r) => ({
      region_id: r.region_id,
      active_drivers: 0,
      active_merchants: 0,
      orders_today: 0,
      rides_today: 0,
      cancellations_today: 0,
      revenue_ngn_today: 0,
    })),
  };
}

function tsMillis(v) {
  if (v == null) return null;
  if (typeof v.toMillis === "function") return v.toMillis();
  if (typeof v === "number" && Number.isFinite(v)) return v;
  return null;
}

/** One flattened row per city service bubble (admin + API consumers). */
function normalizeServiceAreaRow(regionDocId, regionRow, cityDocId, cityRow) {
  const r = regionRow || {};
  const c = cityRow || {};
  return {
    region_id: regionDocId,
    city_id: cityDocId,
    display_name: String(c.display_name ?? c.city_name ?? cityDocId),
    state: String(r.state ?? ""),
    country: String(r.country ?? "Nigeria"),
    dispatch_market_id: String(r.dispatch_market_id ?? "").trim(),
    center_lat: c.center_lat ?? c.centerLat ?? null,
    center_lng: c.center_lng ?? c.centerLng ?? null,
    service_radius_km: c.service_radius_km ?? c.serviceRadiusKm ?? null,
    supports_rides: c.supports_rides !== false,
    supports_delivery: effectiveSupportsDelivery(c),
    supports_merchant: c.supports_merchant !== false,
    supports_food: c.supports_food !== false,
    supports_package: c.supports_package !== false,
    region_enabled: r.enabled !== false,
    enabled: c.enabled !== false,
    updated_at: tsMillis(c.updated_at),
    updated_by: String(c.updated_by ?? "").trim(),
    currency: r.currency ?? "NGN",
    timezone: r.timezone ?? "Africa/Lagos",
  };
}

async function adminListServiceAreas(data, context, db) {
  const denyLsa = await adminPerms.enforceCallable(db, context, "adminListServiceAreas");
  if (denyLsa) return denyLsa;
  const roll = await adminListDeliveryRollout(data, context, db);
  if (!roll.success) {
    return roll;
  }
  const areas = [];
  for (const reg of roll.regions || []) {
    const rid = trim(reg.region_id, 80);
    if (!rid) {
      continue;
    }
    for (const c of reg.cities || []) {
      const cid = trim(c.city_id ?? c.cityId, 120);
      if (!cid) {
        continue;
      }
      areas.push(normalizeServiceAreaRow(rid, reg, cid, c));
    }
  }
  areas.sort((a, b) => {
    const s = String(a.state).localeCompare(String(b.state));
    if (s !== 0) return s;
    return String(a.display_name).localeCompare(String(b.display_name));
  });
  return { success: true, areas, regions: roll.regions };
}

async function adminGetServiceArea(data, context, db) {
  const denyGsa = await adminPerms.enforceCallable(db, context, "adminGetServiceArea");
  if (denyGsa) return denyGsa;
  const regionId = trim(data?.region_id ?? data?.regionId, 80);
  const cityId = trim(data?.city_id ?? data?.cityId, 120);
  if (!regionId) {
    return { success: false, reason: "invalid_payload" };
  }
  const fs = admin.firestore();
  const reg = await loadRegionDoc(fs, regionId);
  if (!reg) {
    return { success: false, reason: "region_not_found" };
  }
  const rPayload = {
    ...reg.data,
    region_id: regionId,
    updated_at: tsMillis(reg.data.updated_at),
    seeded_at: tsMillis(reg.data.seeded_at),
  };
  if (!cityId) {
    return { success: true, region: rPayload };
  }
  const city = await loadCityDoc(fs, regionId, cityId);
  if (!city) {
    return { success: false, reason: "city_not_found" };
  }
  return {
    success: true,
    region: rPayload,
    area: normalizeServiceAreaRow(regionId, reg.data, cityId, city.data),
  };
}

async function adminUpsertServiceArea(data, context, db) {
  const denyUsa = await adminPerms.enforceCallable(db, context, "adminUpsertServiceArea");
  if (denyUsa) return denyUsa;
  const regionId = trim(data?.region_id ?? data?.regionId, 80);
  const cityId = trim(data?.city_id ?? data?.cityId, 120);
  const state = trim(data?.state, 80);
  const dispatch_market_id = trim(data?.dispatch_market_id ?? data?.dispatchMarketId, 80);
  if (!regionId || !cityId || !state || !dispatch_market_id) {
    return { success: false, reason: "invalid_payload" };
  }
  const regionPayload = {
    region_id: regionId,
    state,
    country: trim(data?.country, 80) || "Nigeria",
    dispatch_market_id,
    enabled: data?.region_enabled !== false && data?.regionEnabled !== false,
    supports_rides: data?.supports_rides,
    supports_food: data?.supports_food,
    supports_package: data?.supports_package,
    supports_merchant: data?.supports_merchant,
    supports_delivery: data?.supports_delivery,
    currency: data?.currency,
    timezone: data?.timezone,
  };
  const r = await adminUpsertDeliveryRegion(regionPayload, context, db);
  if (!r.success) {
    return r;
  }
  const cityPayload = {
    region_id: regionId,
    city_id: cityId,
    display_name: trim(data?.display_name ?? data?.displayName, 160),
    enabled: data?.enabled !== false && data?.city_enabled !== false && data?.cityEnabled !== false,
    center_lat: data?.center_lat ?? data?.centerLat,
    center_lng: data?.center_lng ?? data?.centerLng,
    service_radius_km: data?.service_radius_km ?? data?.serviceRadiusKm,
    supports_rides: data?.supports_rides,
    supports_food: data?.supports_food,
    supports_package: data?.supports_package,
    supports_merchant: data?.supports_merchant,
    supports_delivery: data?.supports_delivery,
  };
  return adminUpsertDeliveryCity(cityPayload, context, db);
}

async function adminEnableServiceArea(data, context, db) {
  const denyEna = await adminPerms.enforceCallable(db, context, "adminEnableServiceArea");
  if (denyEna) return denyEna;
  const regionId = trim(data?.region_id ?? data?.regionId, 80);
  const cityId = trim(data?.city_id ?? data?.cityId, 120);
  if (!regionId || !cityId) {
    return { success: false, reason: "invalid_payload" };
  }
  return adminUpsertDeliveryCity(
    {
      region_id: regionId,
      city_id: cityId,
      enabled: true,
      reason: trim(data?.reason ?? data?.note, 500) || null,
    },
    context,
    db,
  );
}

async function adminDisableServiceArea(data, context, db) {
  const denyDis = await adminPerms.enforceCallable(db, context, "adminDisableServiceArea");
  if (denyDis) return denyDis;
  const regionId = trim(data?.region_id ?? data?.regionId, 80);
  const cityId = trim(data?.city_id ?? data?.cityId, 120);
  if (!regionId || !cityId) {
    return { success: false, reason: "invalid_payload" };
  }
  return adminUpsertDeliveryCity(
    {
      region_id: regionId,
      city_id: cityId,
      enabled: false,
      reason: trim(data?.reason ?? data?.note, 500) || null,
    },
    context,
    db,
  );
}

async function validateServiceLocation(data, context) {
  if (!context?.auth?.uid) {
    return { success: false, reason: "unauthorized" };
  }
  const fs = admin.firestore();
  const v = await validateRolloutSelection(fs, data?.region_id, data?.city_id, {
    service: data?.service || "rides",
  });
  if (!v.ok) {
    return { success: false, reason: v.reason || "invalid" };
  }
  return { success: true, ...v };
}

module.exports = {
  normalizeServiceAreaRow,
  ROLLOUT_REGION_IDS,
  ROLLOUT_DISPATCH_MARKET_IDS,
  ROLLOUT_SEED,
  dispatchMarketToRegionId,
  resolveRegionIdByDispatchMarket,
  validateGeoInputs,
  validateRolloutSelection,
  assertRolloutGeoForDispatch,
  assertRolloutWithHints,
  adminUpsertDeliveryRegion,
  adminUpsertDeliveryCity,
  adminSeedRolloutDeliveryRegions,
  adminSeedDefaultNigeriaDeliveryRegions,
  listDeliveryRegions,
  adminListDeliveryRollout,
  adminListServiceAreas,
  adminGetServiceArea,
  adminUpsertServiceArea,
  adminEnableServiceArea,
  adminDisableServiceArea,
  validateServiceLocation,
  isRolloutDispatchMarket,
  logDeliveryRegionBlock,
};
