/**
 * Server-side enforcement for admin Settings active_request_service_types.
 */

const { loadOperationalDispatchGates } = require("./settings_config_registry");

const SERVICE_TYPE_ALIASES = Object.freeze({
  ride: "ride",
  car_ride: "ride",
  dispatch_delivery: "dispatch_delivery",
  delivery: "delivery",
  package_delivery: "delivery",
  groceries_mart: "groceries_mart",
  grocery: "groceries_mart",
  mart: "groceries_mart",
  restaurants_food: "restaurants_food",
  restaurant: "restaurants_food",
  food: "restaurants_food",
  merchant_food_order: "merchant_food_order",
  merchant_order: "merchant_food_order",
});

function normalizeActiveServiceType(raw) {
  const s = String(raw ?? "")
    .trim()
    .toLowerCase();
  if (!s) return "ride";
  return SERVICE_TYPE_ALIASES[s] || s;
}

function isActiveRequestServiceEnabled(gates, serviceType) {
  const svc = normalizeActiveServiceType(serviceType);
  const enabled = gates?.active_request_service_types;
  if (!Array.isArray(enabled) || !enabled.length) return true;
  return enabled.includes(svc);
}

/**
 * @param {import("firebase-admin/database").Database} db
 */
async function assertActiveRequestServiceEnabled(db, serviceType) {
  const gates = await loadOperationalDispatchGates(db);
  const svc = normalizeActiveServiceType(serviceType);
  if (!isActiveRequestServiceEnabled(gates, svc)) {
    return {
      ok: false,
      reason: "service_disabled",
      service_type: svc,
      message: `The ${svc} service is temporarily unavailable.`,
    };
  }
  return { ok: true, service_type: svc };
}

function inferMerchantOrderServiceType(merchant) {
  const m = merchant && typeof merchant === "object" ? merchant : {};
  const cat = String(m.category ?? m.business_type ?? m.store_type ?? "")
    .trim()
    .toLowerCase();
  if (cat.includes("grocery") || cat.includes("mart") || cat.includes("supermarket")) {
    return "groceries_mart";
  }
  if (
    cat.includes("restaurant") ||
    cat.includes("food") ||
    cat.includes("kitchen") ||
    cat.includes("eatery")
  ) {
    return "restaurants_food";
  }
  return "merchant_food_order";
}

module.exports = {
  normalizeActiveServiceType,
  isActiveRequestServiceEnabled,
  assertActiveRequestServiceEnabled,
  inferMerchantOrderServiceType,
};
