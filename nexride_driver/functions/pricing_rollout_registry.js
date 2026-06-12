/**
 * Merges Firestore `delivery_regions` (operational registry) into RTDB pricing city rows.
 * Admin pricing + runtime quotes read the merged view; frozen ride snapshots are untouched.
 */

const admin = require("firebase-admin");

const { normalizePricingConfig, normalizeCityRule, pricingCityStorageKey } = require("./app_config_pricing");

/** Default fare template when a rollout region has no saved pricing row yet. */
const DEFAULT_REGION_FARES = Object.freeze({
  lagos: {
    baseFareNgn: 800,
    perKmNgn: 140,
    perMinuteNgn: 18,
    minimumFareNgn: 1400,
  },
  abuja: {
    baseFareNgn: 600,
    perKmNgn: 115,
    perMinuteNgn: 12,
    minimumFareNgn: 1350,
  },
  delta: {
    baseFareNgn: 700,
    perKmNgn: 125,
    perMinuteNgn: 15,
    minimumFareNgn: 1400,
  },
  edo: {
    baseFareNgn: 600,
    perKmNgn: 115,
    perMinuteNgn: 12,
    minimumFareNgn: 1350,
  },
  imo: {
    baseFareNgn: 600,
    perKmNgn: 115,
    perMinuteNgn: 12,
    minimumFareNgn: 1350,
  },
  anambra: {
    baseFareNgn: 600,
    perKmNgn: 115,
    perMinuteNgn: 12,
    minimumFareNgn: 1350,
  },
});

const FALLBACK_FARE = Object.freeze({
  baseFareNgn: 600,
  perKmNgn: 115,
  perMinuteNgn: 12,
  minimumFareNgn: 1350,
  deliveryBaseFareNgn: 600,
  deliveryPerKmNgn: 115,
  deliveryPerMinuteNgn: 12,
  deliveryMinimumFareNgn: 1350,
});

function regionDisplayLabel(regionId, regionData) {
  const state = String(regionData?.state ?? "").trim();
  if (regionId === "abuja") {
    return "Abuja / FCT";
  }
  if (state) {
    return state;
  }
  const name = String(regionData?.display_name ?? regionData?.name ?? "").trim();
  if (name) return name;
  return regionId;
}

function defaultFareForRegion(regionId) {
  const slug = pricingCityStorageKey(regionId);
  return { ...(DEFAULT_REGION_FARES[slug] || FALLBACK_FARE) };
}

function findExistingCityRow(cities, regionId) {
  const slug = pricingCityStorageKey(regionId);
  if (cities[regionId]) return cities[regionId];
  if (cities[slug]) return cities[slug];
  for (const row of Object.values(cities)) {
    if (!row || typeof row !== "object") continue;
    const rid = String(row.region_id ?? row.regionId ?? "").trim();
    if (rid === regionId || pricingCityStorageKey(rid) === slug) {
      return row;
    }
    if (pricingCityStorageKey(row.city) === slug) {
      return row;
    }
  }
  return null;
}

/**
 * @param {import('firebase-admin').firestore.Firestore} fs
 * @param {object|null|undefined} pricingRaw RTDB `app_config/pricing` value
 */
async function mergePricingCitiesWithOperationalRegistry(fs, pricingRaw) {
  const config = normalizePricingConfig(pricingRaw);
  const snap = await fs.collection("delivery_regions").get();
  const merged = { ...config.cities };

  for (const doc of snap.docs) {
    const regionId = String(doc.id || "").trim();
    if (!regionId) continue;
    const region = doc.data() || {};
    const regionEnabled = region.enabled !== false;
    const label = regionDisplayLabel(regionId, region);
    const existing = findExistingCityRow(merged, regionId);
    const template = defaultFareForRegion(regionId);
    const row = normalizeCityRule(
      {
        ...template,
        ...(existing || {}),
        city: String(existing?.city ?? label).trim() || label,
        region_id: regionId,
        rollout_region_enabled: regionEnabled,
        enabled: regionEnabled && (existing?.enabled !== false),
      },
      label,
    );
    merged[regionId] = row;
  }

  return {
    ...config,
    cities: merged,
    rollout_registry_region_count: snap.size,
  };
}

module.exports = {
  DEFAULT_REGION_FARES,
  mergePricingCitiesWithOperationalRegistry,
  regionDisplayLabel,
};
