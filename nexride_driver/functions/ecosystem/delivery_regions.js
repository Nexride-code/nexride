/**
 * NexRide rollout regions: Firestore `delivery_regions/{regionId}` + nested `cities/{cityId}`.
 * Only six states are in scope; cities are individually toggleable.
 *
 * Canonical dispatch market ids (RTDB / ride payloads) map via `dispatch_market_id` on the state doc.
 */

const admin = require("firebase-admin");
const { FieldValue } = require("firebase-admin/firestore");
const { logger } = require("firebase-functions");
const { isNexRideAdmin, normUid } = require("../admin_auth");

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
  return "";
}

function parentSupports(row, key) {
  if (!key) return false;
  return row[key] !== false;
}

function citySupports(cityRow, key) {
  if (!key) return false;
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
 * Validates region + city exist and services are enabled at both levels.
 */
async function validateRolloutSelection(fs, regionId, cityId, opts = {}) {
  const rid = trim(regionId, 80);
  const cid = trim(cityId, 80);
  const sk = serviceKey(opts.service || "merchant");
  if (!ROLLOUT_REGION_IDS.includes(rid)) {
    return { ok: false, reason: "region_not_in_rollout" };
  }
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
  const regionId = dispatchMarketToRegionId(dispatchMarketId);
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
 */
async function assertRolloutWithHints(fs, dispatchMarketId, lat, lng, service, hints = {}) {
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
          logDeliveryRegionBlock("hint_coords_outside_city", { regionHint, cityHint, d_km: d });
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
      dispatch_market_id: v.dispatch_market_id || dispatchMarketToRegionId(dispatchMarketId),
    };
  }
  return assertRolloutGeoForDispatch(fs, dispatchMarketId, lat, lng, service);
}

function logDeliveryRegionBlock(reason, meta) {
  logger.warn("DELIVERY_REGION_BLOCK", { reason, ...meta });
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
  if (!(await isNexRideAdmin(db, context))) {
    return { success: false, reason: "unauthorized" };
  }
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
  if (!(await isNexRideAdmin(db, context))) {
    return { success: false, reason: "unauthorized" };
  }
  const regionId = trim(data?.region_id ?? data?.regionId, 80);
  const cityId = trim(data?.city_id ?? data?.cityId, 120);
  const display_name = trim(data?.display_name ?? data?.displayName, 160);
  if (!regionId || !cityId || !display_name) {
    return { success: false, reason: "invalid_payload" };
  }
  const fs = admin.firestore();
  const enabled = data?.enabled !== false;
  const supports_rides = data?.supports_rides !== false && data?.supports_ride !== false;
  const supports_food = data?.supports_food !== false;
  const supports_package = data?.supports_package !== false;
  const supports_merchant = data?.supports_merchant !== false;
  const center_lat = Number(data?.center_lat ?? data?.centerLat);
  const center_lng = Number(data?.center_lng ?? data?.centerLng);
  const service_radius_km = Number(data?.service_radius_km ?? data?.serviceRadiusKm ?? 25);

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
        center_lat: Number.isFinite(center_lat) ? center_lat : null,
        center_lng: Number.isFinite(center_lng) ? center_lng : null,
        service_radius_km: Number.isFinite(service_radius_km) && service_radius_km > 0 ? service_radius_km : 25,
        updated_at: FieldValue.serverTimestamp(),
        updated_by: normUid(context.auth?.uid),
      },
      { merge: true },
    );
  logger.info("DELIVERY_CITY_UPSERT", { region_id: regionId, city_id: cityId, enabled });
  return { success: true, region_id: regionId, city_id: cityId };
}

async function adminSeedRolloutDeliveryRegions(_data, context, db) {
  if (!(await isNexRideAdmin(db, context))) {
    return { success: false, reason: "unauthorized" };
  }
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
    if (!ROLLOUT_REGION_IDS.includes(doc.id)) {
      continue;
    }
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
  if (!(await isNexRideAdmin(db, context))) {
    return { success: false, reason: "unauthorized" };
  }
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
  ROLLOUT_REGION_IDS,
  ROLLOUT_DISPATCH_MARKET_IDS,
  ROLLOUT_SEED,
  dispatchMarketToRegionId,
  validateRolloutSelection,
  assertRolloutGeoForDispatch,
  assertRolloutWithHints,
  adminUpsertDeliveryRegion,
  adminUpsertDeliveryCity,
  adminSeedRolloutDeliveryRegions,
  adminSeedDefaultNigeriaDeliveryRegions,
  listDeliveryRegions,
  adminListDeliveryRollout,
  validateServiceLocation,
  isRolloutDispatchMarket,
  logDeliveryRegionBlock,
};
