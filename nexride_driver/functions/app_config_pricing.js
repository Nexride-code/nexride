/**
 * Single source of truth: RTDB `app_config/pricing`.
 * Used by quotes, Flutterwave charge amounts, settlement splits, and admin UI.
 */

const { platformFeeNgn, smallOrderFeeNgn, smallOrderThresholdNgn } = require("./params");

const DEFAULT_COMMISSION_RATE = 0.1;
const BOOKING_FEE_MODES = new Set(["fixed", "percentage", "max_fixed_or_percentage"]);
const DEFAULT_BOOKING_FEE_MODE = "max_fixed_or_percentage";
const DEFAULT_BOOKING_FEE_NGN = 100;
const DEFAULT_BOOKING_FEE_PERCENT = 3;
const DEFAULT_BOOKING_FEE_MIN_NGN = 100;
const DEFAULT_DISPATCH_BOOKING_FEE_MODE = "max_fixed_or_percentage";
const DEFAULT_DISPATCH_BOOKING_FEE_NGN = 150;
const DEFAULT_DISPATCH_BOOKING_FEE_PERCENT = 5;
const DEFAULT_DISPATCH_BOOKING_FEE_MIN_NGN = 150;

const DISPATCH_PRICING_FLOWS = new Set([
  "dispatch_request",
  "dispatch_delivery",
  "delivery",
]);

function isDispatchPricingFlow(flow) {
  return DISPATCH_PRICING_FLOWS.has(String(flow ?? "").trim().toLowerCase());
}

/**
 * @param {object|null|undefined} raw
 * @param {{ mode: string, bookingFeeNgn: number, bookingFeePercent: number, bookingFeeMinNgn: number, bookingFeeMaxNgn: number|null }} defaults
 * @param {object|null|undefined} legacySrc
 */
function normalizeBookingFeePolicy(raw, defaults, legacySrc = null) {
  const src = raw && typeof raw === "object" ? raw : {};
  const legacy = legacySrc && typeof legacySrc === "object" ? legacySrc : {};

  const hasLegacyFlatOnly =
    src.bookingFeeMode == null &&
    src.booking_fee_mode == null &&
    legacy.bookingFeeMode == null &&
    legacy.booking_fee_mode == null &&
    (src.bookingFeeNgn != null ||
      src.booking_fee_ngn != null ||
      legacy.bookingFeeNgn != null ||
      legacy.booking_fee_ngn != null ||
      legacy.platformFeeNgn != null ||
      legacy.platform_fee_ngn != null);

  const bookingFeeRaw = Number(
    src.bookingFeeNgn ??
      src.booking_fee_ngn ??
      legacy.bookingFeeNgn ??
      legacy.booking_fee_ngn ??
      legacy.platformFeeNgn ??
      legacy.platform_fee_ngn,
  );
  const bookingFeeNgn =
    Number.isFinite(bookingFeeRaw) && bookingFeeRaw >= 0
      ? roundNgn(bookingFeeRaw)
      : hasLegacyFlatOnly
        ? platformFeeNgn()
        : defaults.bookingFeeNgn;

  const modeRaw = String(
    src.bookingFeeMode ?? src.booking_fee_mode ?? legacy.bookingFeeMode ?? legacy.booking_fee_mode ?? "",
  )
    .trim()
    .toLowerCase();
  const bookingFeeMode = BOOKING_FEE_MODES.has(modeRaw)
    ? modeRaw
    : hasLegacyFlatOnly
      ? "fixed"
      : defaults.mode;

  const bookingFeePercentRaw = Number(
    src.bookingFeePercent ?? src.booking_fee_percent ?? legacy.bookingFeePercent ?? legacy.booking_fee_percent,
  );
  const bookingFeePercent =
    Number.isFinite(bookingFeePercentRaw) && bookingFeePercentRaw >= 0
      ? bookingFeePercentRaw
      : defaults.bookingFeePercent;

  const bookingFeeMinRaw = Number(
    src.bookingFeeMinNgn ?? src.booking_fee_min_ngn ?? legacy.bookingFeeMinNgn ?? legacy.booking_fee_min_ngn,
  );
  const bookingFeeMinNgn =
    Number.isFinite(bookingFeeMinRaw) && bookingFeeMinRaw >= 0
      ? roundNgn(bookingFeeMinRaw)
      : defaults.bookingFeeMinNgn;

  const bookingFeeMaxRaw =
    src.bookingFeeMaxNgn ??
    src.booking_fee_max_ngn ??
    legacy.bookingFeeMaxNgn ??
    legacy.booking_fee_max_ngn;
  const bookingFeeMaxParsed = Number(bookingFeeMaxRaw);
  const bookingFeeMaxNgn =
    bookingFeeMaxRaw == null || bookingFeeMaxRaw === ""
      ? defaults.bookingFeeMaxNgn ?? null
      : Number.isFinite(bookingFeeMaxParsed) && bookingFeeMaxParsed >= 0
        ? roundNgn(bookingFeeMaxParsed)
        : null;

  return {
    bookingFeeNgn,
    bookingFeeMode,
    booking_fee_mode: bookingFeeMode,
    bookingFeePercent,
    booking_fee_percent: bookingFeePercent,
    bookingFeeMinNgn,
    booking_fee_min_ngn: bookingFeeMinNgn,
    bookingFeeMaxNgn,
    booking_fee_max_ngn: bookingFeeMaxNgn,
  };
}

function computeBookingFeeFromPolicy(policy, tripFareNgn) {
  const tripFare = roundNgn(tripFareNgn);
  const percentageFee = roundNgn((tripFare * policy.bookingFeePercent) / 100);
  let fee;
  switch (policy.bookingFeeMode) {
    case "fixed":
      fee = policy.bookingFeeNgn;
      break;
    case "percentage":
      fee = Math.max(policy.bookingFeeMinNgn, percentageFee);
      break;
    case "max_fixed_or_percentage":
    default:
      fee = Math.max(policy.bookingFeeNgn, percentageFee, policy.bookingFeeMinNgn);
      break;
  }
  if (policy.bookingFeeMaxNgn != null && policy.bookingFeeMaxNgn > 0) {
    fee = Math.min(fee, policy.bookingFeeMaxNgn);
  }
  return roundNgn(fee);
}

function roundNgn(n) {
  return Math.round(Math.max(0, Number(n) || 0));
}

function pricingCityStorageKey(cityName) {
  const s = String(cityName ?? "")
    .trim()
    .toLowerCase();
  if (s === "abuja_fct" || s.startsWith("abuja")) return "abuja";
  if (s.startsWith("lagos")) return "lagos";
  if (s.startsWith("delta")) return "delta";
  if (s.startsWith("edo")) return "edo";
  if (s.startsWith("imo")) return "imo";
  if (s.startsWith("anambra")) return "anambra";
  return s.replace(/[^a-z0-9]+/g, "_").replace(/^_|_$/g, "") || "unknown";
}

function normalizeCityRule(raw, fallbackCity = "City") {
  const row = raw && typeof raw === "object" ? raw : {};
  const city = String(row.city ?? row.name ?? fallbackCity).trim() || fallbackCity;
  const read = (a, b) => {
    const n = Number(row[a] ?? row[b] ?? 0);
    return Number.isFinite(n) && n >= 0 ? roundNgn(n) : 0;
  };
  const out = {
    city,
    slug: pricingCityStorageKey(city),
    region_id: String(row.region_id ?? row.regionId ?? "").trim() || undefined,
    baseFareNgn: read("baseFareNgn", "base_fare_ngn"),
    perKmNgn: read("perKmNgn", "per_km_ngn"),
    perMinuteNgn: read("perMinuteNgn", "per_minute_ngn"),
    minimumFareNgn: read("minimumFareNgn", "minimum_fare_ngn"),
    deliveryBaseFareNgn: read("deliveryBaseFareNgn", "delivery_base_fare_ngn"),
    deliveryPerKmNgn: read("deliveryPerKmNgn", "delivery_per_km_ngn"),
    deliveryPerMinuteNgn: read("deliveryPerMinuteNgn", "delivery_per_minute_ngn"),
    deliveryMinimumFareNgn: read("deliveryMinimumFareNgn", "delivery_minimum_fare_ngn"),
    enabled: row.enabled !== false,
  };
  if (row.rollout_region_enabled !== undefined || row.rolloutRegionEnabled !== undefined) {
    out.rollout_region_enabled =
      row.rollout_region_enabled !== false && row.rolloutRegionEnabled !== false;
  }
  return out;
}

/**
 * @param {object|null|undefined} raw
 */
function normalizePricingConfig(raw) {
  const src = raw && typeof raw === "object" ? raw : {};
  const citiesRaw = src.cities && typeof src.cities === "object" ? src.cities : {};
  const cities = {};
  for (const [key, value] of Object.entries(citiesRaw)) {
    if (!value || typeof value !== "object") continue;
    const rule = normalizeCityRule(value, key);
    cities[rule.slug || pricingCityStorageKey(key)] = rule;
  }

  const commissionRateRaw = Number(src.commissionRate ?? src.commission_rate ?? DEFAULT_COMMISSION_RATE);
  const commissionRate =
    Number.isFinite(commissionRateRaw) && commissionRateRaw >= 0 && commissionRateRaw <= 1
      ? commissionRateRaw
      : DEFAULT_COMMISSION_RATE;

  const rideDefaults = {
    mode: DEFAULT_BOOKING_FEE_MODE,
    bookingFeeNgn: DEFAULT_BOOKING_FEE_NGN,
    bookingFeePercent: DEFAULT_BOOKING_FEE_PERCENT,
    bookingFeeMinNgn: DEFAULT_BOOKING_FEE_MIN_NGN,
    bookingFeeMaxNgn: null,
  };
  const dispatchDefaults = {
    mode: DEFAULT_DISPATCH_BOOKING_FEE_MODE,
    bookingFeeNgn: DEFAULT_DISPATCH_BOOKING_FEE_NGN,
    bookingFeePercent: DEFAULT_DISPATCH_BOOKING_FEE_PERCENT,
    bookingFeeMinNgn: DEFAULT_DISPATCH_BOOKING_FEE_MIN_NGN,
    bookingFeeMaxNgn: null,
  };
  const rides = normalizeBookingFeePolicy(
    src.rides && typeof src.rides === "object" ? src.rides : {},
    rideDefaults,
    src,
  );
  const dispatch = normalizeBookingFeePolicy(
    src.dispatch && typeof src.dispatch === "object" ? src.dispatch : {},
    dispatchDefaults,
    null,
  );

  const fleetOwnerCommissionRateRaw = Number(
    src.fleetOwnerCommissionRate ??
      src.fleet_owner_commission_rate ??
      src.fleetCommissionRate ??
      src.fleet_commission_rate ??
      src.fleetLinkedBikerCommissionRate ??
      src.fleet_linked_biker_commission_rate ??
      src.dispatchFleetCommissionRate ??
      src.dispatch_fleet_commission_rate ??
      commissionRate,
  );
  const fleetOwnerCommissionRate =
    Number.isFinite(fleetOwnerCommissionRateRaw) &&
    fleetOwnerCommissionRateRaw >= 0 &&
    fleetOwnerCommissionRateRaw <= 1
      ? fleetOwnerCommissionRateRaw
      : commissionRate;

  const fleetWeeklySubscriptionNgn = roundNgn(
    src.fleetWeeklySubscriptionNgn ??
      src.fleet_weekly_subscription_ngn ??
      src.weeklySubscriptionNgn ??
      src.weekly_subscription_ngn ??
      0,
  );
  const fleetMonthlySubscriptionNgn = roundNgn(
    src.fleetMonthlySubscriptionNgn ??
      src.fleet_monthly_subscription_ngn ??
      src.monthlySubscriptionNgn ??
      src.monthly_subscription_ngn ??
      0,
  );
  // Derived alias — billing uses weekly/monthly; legacy amount keys fold into monthly.
  const fleetSubscriptionAmountNgn = fleetMonthlySubscriptionNgn;

  return {
    cities,
    commissionRate,
    fleetOwnerCommissionRate,
    rides,
    dispatch,
    // Legacy ride aliases for older clients/readers.
    bookingFeeNgn: rides.bookingFeeNgn,
    bookingFeeMode: rides.bookingFeeMode,
    booking_fee_mode: rides.bookingFeeMode,
    bookingFeePercent: rides.bookingFeePercent,
    booking_fee_percent: rides.bookingFeePercent,
    bookingFeeMinNgn: rides.bookingFeeMinNgn,
    booking_fee_min_ngn: rides.bookingFeeMinNgn,
    bookingFeeMaxNgn: rides.bookingFeeMaxNgn,
    booking_fee_max_ngn: rides.bookingFeeMaxNgn,
    weeklySubscriptionNgn: roundNgn(src.weeklySubscriptionNgn ?? src.weekly_subscription_ngn ?? 0),
    monthlySubscriptionNgn: roundNgn(src.monthlySubscriptionNgn ?? src.monthly_subscription_ngn ?? 0),
    fleetWeeklySubscriptionNgn,
    fleetMonthlySubscriptionNgn,
    fleetSubscriptionAmountNgn,
    smallOrderFeeNgn: roundNgn(src.smallOrderFeeNgn ?? src.small_order_fee_ngn ?? smallOrderFeeNgn()),
    smallOrderThresholdNgn: roundNgn(
      src.smallOrderThresholdNgn ?? src.small_order_threshold_ngn ?? smallOrderThresholdNgn(),
    ),
    updatedAt: Number(src.updatedAt ?? src.updated_at ?? 0) || 0,
    updatedBy: String(src.updatedBy ?? src.updated_by ?? "").trim() || null,
  };
}

function normUid(uid) {
  return String(uid ?? "").trim();
}

function driverOwnershipMode(profile) {
  if (!profile || typeof profile !== "object") return "individual";
  return String(profile.ownership_mode ?? profile.ownershipMode ?? "individual")
    .trim()
    .toLowerCase();
}

function fleetBusinessIdFromDriverProfile(profile) {
  if (driverOwnershipMode(profile) !== "business_managed") return "";
  return normUid(profile.business_id ?? profile.businessId);
}

async function loadNormalizedPricingConfig(db) {
  const snap = await db.ref("app_config/pricing").get();
  return normalizePricingConfig(snap.val());
}

/**
 * Dispatch fleet delivery settlement commission — always Admin → Pricing global
 * `fleetOwnerCommissionRate` (app_config/pricing). Ignores merchants/{id}
 * commission_exempt, subscription payment_model, and legacy commission_rate: 0
 * signup defaults so existing fleets pick up global changes without migration.
 */
async function resolveFleetOwnerCommissionRate(db, _fleetBusinessId, _fsOverride) {
  const cfg = await loadNormalizedPricingConfig(db);
  return cfg.fleetOwnerCommissionRate;
}

/**
 * @deprecated Alias — fleet-owned delivery earnings use fleet owner commission only.
 */
async function resolveFleetLinkedBikerCommissionRate(db, fleetBusinessId, fsOverride) {
  return resolveFleetOwnerCommissionRate(db, fleetBusinessId, fsOverride);
}

async function resolveIndependentDriverCommissionRate(db) {
  const cfg = await loadNormalizedPricingConfig(db);
  return cfg.commissionRate;
}

/**
 * Delivery settlement commission for assigned driver.
 * Independent drivers → commissionRate; fleet-owned → fleetOwnerCommissionRate.
 */
async function resolveDeliveryCommissionRateForDriver(db, driverId, fsOverride) {
  const did = normUid(driverId);
  if (!did) {
    return (await loadNormalizedPricingConfig(db)).commissionRate;
  }
  const driverSnap = await db.ref(`drivers/${did}`).get();
  const profile =
    driverSnap.val() && typeof driverSnap.val() === "object" ? driverSnap.val() : {};
  const fleetId = fleetBusinessIdFromDriverProfile(profile);
  if (fleetId) {
    return resolveFleetOwnerCommissionRate(db, fleetId, fsOverride);
  }
  return resolveIndependentDriverCommissionRate(db);
}

async function resolveFleetSubscriptionPricesNgn(db, fleetBusinessId, fsOverride) {
  const cfg = await loadNormalizedPricingConfig(db);
  const bid = normUid(fleetBusinessId);
  let weekly = cfg.fleetWeeklySubscriptionNgn;
  let monthly = cfg.fleetMonthlySubscriptionNgn;
  let subscriptionAmount = cfg.fleetSubscriptionAmountNgn;
  if (bid) {
    const admin = require("firebase-admin");
    const fs = fsOverride || admin.firestore();
    try {
      const snap = await fs.collection("merchants").doc(bid).get();
      if (snap.exists) {
        const m = snap.data() || {};
        const w = roundNgn(m.weekly_subscription_ngn ?? m.weeklySubscriptionNgn ?? 0);
        const mo = roundNgn(m.monthly_subscription_ngn ?? m.monthlySubscriptionNgn ?? 0);
        const subAmt = roundNgn(m.subscription_amount ?? m.subscriptionAmount ?? 0);
        if (w > 0) weekly = w;
        if (mo > 0) monthly = mo;
        if (subAmt > 0) subscriptionAmount = subAmt;
      }
    } catch (_err) {
      /* global fallback */
    }
  }
  return {
    weekly_subscription_ngn: weekly > 0 ? weekly : cfg.weeklySubscriptionNgn,
    monthly_subscription_ngn: monthly > 0 ? monthly : cfg.monthlySubscriptionNgn,
    subscription_amount_ngn:
      subscriptionAmount > 0 ? subscriptionAmount : monthly > 0 ? monthly : cfg.monthlySubscriptionNgn,
    global_fallback_path: "app_config/pricing",
    fleet_override_path: bid ? `merchants/${bid}` : null,
  };
}

async function loadAppPricingConfig(db) {
  const snap = await db.ref("app_config/pricing").get();
  const admin = require("firebase-admin");
  const fs = admin.firestore();
  const { mergePricingCitiesWithOperationalRegistry } = require("./pricing_rollout_registry");
  return mergePricingCitiesWithOperationalRegistry(fs, snap.val());
}

function resolveCityRule(config, cityOrMarket) {
  const cfg = config && typeof config === "object" ? config : normalizePricingConfig(null);
  const slug = pricingCityStorageKey(cityOrMarket);
  const rule = cfg.cities?.[slug];
  if (rule) {
    return rule;
  }
  const lagos = cfg.cities?.lagos;
  if (lagos) {
    return lagos;
  }
  const first = Object.values(cfg.cities || {})[0];
  return (
    first ||
    normalizeCityRule(
      {
        city: "Lagos",
        baseFareNgn: 800,
        perKmNgn: 140,
        perMinuteNgn: 18,
        minimumFareNgn: 1400,
        enabled: true,
      },
      "lagos",
    )
  );
}

function deliveryRuleFromCityRule(rule) {
  const base = rule.deliveryBaseFareNgn > 0 ? rule.deliveryBaseFareNgn : rule.baseFareNgn;
  const perKm = rule.deliveryPerKmNgn > 0 ? rule.deliveryPerKmNgn : rule.perKmNgn;
  const perMinute = rule.deliveryPerMinuteNgn > 0 ? rule.deliveryPerMinuteNgn : rule.perMinuteNgn;
  const minimum =
    rule.deliveryMinimumFareNgn > 0 ? rule.deliveryMinimumFareNgn : rule.minimumFareNgn;
  return { baseFareNgn: base, perKmNgn: perKm, perMinuteNgn: perMinute, minimumFareNgn: minimum };
}

function pricingSnapshotFromConfig(config, tripFareNgn, totalNgn, cityOrMarket = "lagos", flow = "ride") {
  const { buildCompletePricingSnapshot } = require("./pricing_snapshot");
  return buildCompletePricingSnapshot({
    config,
    cityOrMarket,
    flow,
    tripFareNgn,
    totalNgn,
  });
}

function commissionRateFromEntity(entity) {
  const snap = entity?.pricing_snapshot;
  if (snap && typeof snap === "object") {
    const r = Number(snap.commission_rate);
    if (Number.isFinite(r) && r >= 0 && r <= 1) {
      return r;
    }
  }
  const legacy = Number(entity?.commission_rate);
  if (Number.isFinite(legacy) && legacy >= 0 && legacy <= 1) {
    return legacy;
  }
  return DEFAULT_COMMISSION_RATE;
}

/**
 * Compute booking fee from admin pricing rules.
 * @param {object|null|undefined} config
 * @param {number} tripFareNgn
 * @param {string} [flow]
 */
function computeBookingFeeNgn(config, tripFareNgn, flow = "ride_booking") {
  const cfg = normalizePricingConfig(config);
  const policy = isDispatchPricingFlow(flow) ? cfg.dispatch : cfg.rides;
  return computeBookingFeeFromPolicy(policy, tripFareNgn);
}

function isDeliveryEntity(entity) {
  if (!entity || typeof entity !== "object") return false;
  if (String(entity.delivery_id ?? entity.deliveryId ?? "").trim()) return true;
  if (String(entity.delivery_state ?? entity.deliveryState ?? "").trim()) return true;
  const serviceType = String(entity.service_type ?? entity.serviceType ?? "")
    .trim()
    .toLowerCase();
  return serviceType === "dispatch_delivery" || serviceType === "dispatch_request";
}

function bookingFeeFromEntity(entity, config = null) {
  const snap = entity?.pricing_snapshot;
  if (snap && typeof snap === "object") {
    const b = Number(snap.booking_fee_ngn);
    if (Number.isFinite(b) && b >= 0) {
      return roundNgn(b);
    }
  }
  const rowFee = Number(entity?.platform_fee_ngn ?? entity?.booking_fee_ngn ?? 0);
  if (Number.isFinite(rowFee) && rowFee > 0) {
    return roundNgn(rowFee);
  }
  if (config) {
    const tripFare = roundNgn(
      entity?.fare ?? entity?.trip_fare_ngn ?? entity?.total_delivery_fee ?? entity?.delivery_fee_ngn ?? 0,
    );
    const flow = isDeliveryEntity(entity) ? "dispatch_request" : "ride_booking";
    return computeBookingFeeNgn(config, tripFare, flow);
  }
  return platformFeeNgn();
}

module.exports = {
  DEFAULT_COMMISSION_RATE,
  BOOKING_FEE_MODES,
  DEFAULT_BOOKING_FEE_MODE,
  DEFAULT_BOOKING_FEE_NGN,
  DEFAULT_BOOKING_FEE_PERCENT,
  DEFAULT_BOOKING_FEE_MIN_NGN,
  DEFAULT_DISPATCH_BOOKING_FEE_MODE,
  DEFAULT_DISPATCH_BOOKING_FEE_NGN,
  DEFAULT_DISPATCH_BOOKING_FEE_PERCENT,
  DEFAULT_DISPATCH_BOOKING_FEE_MIN_NGN,
  DISPATCH_PRICING_FLOWS,
  isDispatchPricingFlow,
  isDeliveryEntity,
  normalizeBookingFeePolicy,
  computeBookingFeeFromPolicy,
  pricingCityStorageKey,
  normalizeCityRule,
  normalizePricingConfig,
  computeBookingFeeNgn,
  loadAppPricingConfig,
  loadNormalizedPricingConfig,
  resolveCityRule,
  deliveryRuleFromCityRule,
  pricingSnapshotFromConfig,
  commissionRateFromEntity,
  bookingFeeFromEntity,
  roundNgn,
  normUid,
  driverOwnershipMode,
  fleetBusinessIdFromDriverProfile,
  resolveFleetOwnerCommissionRate,
  resolveFleetLinkedBikerCommissionRate,
  resolveIndependentDriverCommissionRate,
  resolveDeliveryCommissionRateForDriver,
  resolveFleetSubscriptionPricesNgn,
};
