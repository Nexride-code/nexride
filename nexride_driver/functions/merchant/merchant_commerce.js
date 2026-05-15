/**
 * Phase 4B — merchant menu, rider orders, merchant order ops, linked food delivery.
 * All Firestore writes use Admin SDK (clients use callables only).
 */

const admin = require("firebase-admin");
const { FieldValue, FieldPath } = require("firebase-admin/firestore");
const { logger } = require("firebase-functions");
const { normUid, isNexRideAdminOrSupport } = require("../admin_auth");
const adminPerms = require("../admin_permissions");
const merchantVerification = require("./merchant_verification");
const delivery = require("../delivery_callables");
const ride = require("../ride_callables");
const riderFirestoreIdentity = require("../rider_firestore_identity");
const deliveryRegions = require("../ecosystem/delivery_regions");

function trimStr(v, max = 800) {
  return String(v ?? "")
    .trim()
    .slice(0, max);
}

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

function availabilityModeForMerchant(m) {
  const raw = String(m?.availability_status ?? "")
    .trim()
    .toLowerCase();
  if (raw === "open" || raw === "closed" || raw === "paused") return raw;
  if (raw === "online") return "open";
  if (raw === "offline") return "closed";
  const isOpen = m?.is_open != null ? Boolean(m.is_open) : true;
  const acc = m?.accepting_orders != null ? Boolean(m.accepting_orders) : true;
  if (isOpen && acc) return "open";
  if (isOpen && !acc) return "paused";
  return "closed";
}

function ordersLiveFromMerchantDoc(m) {
  const st = String(m?.merchant_status ?? m?.status ?? "")
    .trim()
    .toLowerCase();
  const isOpen = m?.is_open != null ? Boolean(m.is_open) : true;
  const accepting = m?.accepting_orders != null ? Boolean(m.accepting_orders) : true;
  const mode = availabilityModeForMerchant(m);
  return st === "approved" && isOpen && accepting && mode === "open";
}

function openStatusReasonForMerchant(m) {
  const st = String(m?.merchant_status ?? m?.status ?? "")
    .trim()
    .toLowerCase();
  if (st !== "approved") {
    return "not_approved";
  }
  const mode = availabilityModeForMerchant(m);
  if (mode === "closed" || mode === "offline") {
    return "closed";
  }
  if (mode === "paused") {
    return "paused";
  }
  if (m?.is_open === false) {
    return "closed";
  }
  if (m?.accepting_orders === false) {
    return "paused";
  }
  return null;
}

function defaultPrepMinutesMerchant(m) {
  const configured = Number(
    m?.prep_time_min ?? m?.default_prep_time_min ?? m?.avg_prep_time_min ?? m?.kitchen_prep_time_min,
  );
  if (Number.isFinite(configured) && configured > 0) {
    return Math.min(120, Math.max(5, Math.round(configured)));
  }
  const cat = String(m?.category ?? m?.business_type ?? m?.store_type ?? "")
    .trim()
    .toLowerCase();
  if (cat.includes("grocery") || cat.includes("mart") || cat.includes("supermarket")) {
    return 12;
  }
  if (cat.includes("restaurant") || cat.includes("food") || cat.includes("kitchen") || cat.includes("eatery")) {
    return 22;
  }
  return 18;
}

function travelDeliveryMinutes(distanceKm) {
  if (!Number.isFinite(distanceKm) || distanceKm <= 0) {
    return 20;
  }
  const speedKmh = 18;
  const t = (distanceKm / speedKmh) * 60;
  return Math.min(55, Math.max(8, Math.round(t)));
}

function etaWindowFromDistance(distanceKm, prepMin) {
  const travel = travelDeliveryMinutes(distanceKm);
  const base = prepMin + travel;
  const pad = Math.max(4, Math.round(base * 0.18));
  return {
    eta_min: Math.max(10, base - pad),
    eta_max: Math.min(180, base + pad),
  };
}

function estimateDeliveryFeeNgn(m, distanceKm) {
  if (!Number.isFinite(distanceKm) || distanceKm < 0) {
    return null;
  }
  const base = Number(m?.delivery_fee_base_ngn ?? m?.min_delivery_fee_ngn ?? 500);
  const perKm = Number(m?.delivery_fee_per_km_ngn ?? 180);
  if (Number.isFinite(base) && base > 0 && Number.isFinite(perKm) && perKm >= 0) {
    return Math.round(Math.min(15000, Math.max(300, base + perKm * distanceKm)));
  }
  return Math.round(Math.min(12000, Math.max(400, 500 + 200 * distanceKm)));
}

function buildMerchantDiscoveryRow(m, merchantId, riderLat, riderLng) {
  const plat = Number(m.pickup_lat ?? m.pickupLat);
  const plng = Number(m.pickup_lng ?? m.pickupLng);
  let distanceKm = null;
  if (Number.isFinite(riderLat) && Number.isFinite(riderLng) && Number.isFinite(plat) && Number.isFinite(plng)) {
    distanceKm = Math.round(haversineKm(riderLat, riderLng, plat, plng) * 1000) / 1000;
  }
  const prep = defaultPrepMinutesMerchant(m);
  let etaMin = null;
  let etaMax = null;
  let deliveryFee = null;
  if (distanceKm != null) {
    const win = etaWindowFromDistance(distanceKm, prep);
    etaMin = win.eta_min;
    etaMax = win.eta_max;
    deliveryFee = estimateDeliveryFeeNgn(m, distanceKm);
  }
  const ordersLive = ordersLiveFromMerchantDoc(m);
  return {
    merchant_id: merchantId,
    business_name: String(m.business_name ?? ""),
    business_type: m.business_type != null ? String(m.business_type) : null,
    category: m.category != null ? String(m.category) : null,
    city_id: trimStr(m.city_id ?? m.cityId, 120) || null,
    region_id: m.region_id != null ? String(m.region_id) : null,
    address: m.address != null ? String(m.address) : null,
    pickup_lat: Number.isFinite(plat) ? plat : null,
    pickup_lng: Number.isFinite(plng) ? plng : null,
    prep_time_min_default: prep,
    distance_km: distanceKm,
    eta_min: etaMin,
    eta_max: etaMax,
    delivery_fee_estimate_ngn: deliveryFee,
    orders_live: ordersLive,
    open_status_reason: openStatusReasonForMerchant(m),
  };
}

function nowMs() {
  return Date.now();
}

const ORDER_STATUS = {
  pending_merchant: "pending_merchant",
  merchant_rejected: "merchant_rejected",
  merchant_accepted: "merchant_accepted",
  preparing: "preparing",
  ready_for_pickup: "ready_for_pickup",
  dispatching: "dispatching",
  completed: "completed",
  cancelled: "cancelled",
};

const TERMINAL_ORDER = new Set([ORDER_STATUS.completed, ORDER_STATUS.cancelled, ORDER_STATUS.merchant_rejected]);

function merchantMenuCategoriesCol(fs, merchantId) {
  return fs.collection("merchants").doc(merchantId).collection("menu_categories");
}

function merchantMenuItemsCol(fs, merchantId) {
  return fs.collection("merchants").doc(merchantId).collection("menu_items");
}

function ordersCol(fs) {
  return fs.collection("merchant_orders");
}

function validMenuPriceNgn(priceNgn) {
  if (!Number.isFinite(priceNgn) || priceNgn <= 0) return false;
  const n = Math.round(priceNgn);
  if (Math.abs(priceNgn - n) > 1e-6) return false;
  if (n > 50_000_000) return false;
  return true;
}

function coordsFromPickup(o) {
  if (!o || typeof o !== "object") {
    return { lat: NaN, lng: NaN };
  }
  const lat = Number(o.lat ?? o.latitude ?? o.Latitude ?? "");
  const lng = Number(o.lng ?? o.longitude ?? o.Longitude ?? "");
  return { lat, lng };
}

async function resolveMerchantOwner(fs, context) {
  return merchantVerification.resolveMerchantForMerchantAuth(fs, context);
}

/**
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {{ data?: Record<string, unknown> }} resolved
 * @param {string[]} roles
 * @returns {{ success: false; reason: string } | null}
 */
function requireMerchantRoles(resolved, context, roles) {
  const uid = normUid(context?.auth?.uid);
  const m = resolved.data || {};
  const g = merchantVerification.assertMerchantPortalAllowed(m, uid, roles);
  if (!g.ok) {
    return { success: false, reason: g.reason };
  }
  return null;
}

function effectiveCommissionFromMerchantDoc(m) {
  const pm = String(m?.payment_model ?? "commission").trim().toLowerCase();
  if (pm === "subscription" || m?.commission_exempt === true) {
    return { commission_rate: 0, withdrawal_percent: 1, commission_exempt: true };
  }
  const cr = Number(m?.commission_rate);
  const wr = Number(m?.withdrawal_percent);
  if (Number.isFinite(cr) && cr >= 0 && cr <= 0.6) {
    const w = Number.isFinite(wr) && wr >= 0 && wr <= 1 ? wr : Math.max(0, 1 - cr);
    return { commission_rate: cr, withdrawal_percent: w, commission_exempt: false };
  }
  return { commission_rate: 0.1, withdrawal_percent: 0.9, commission_exempt: false };
}

function merchantAcceptingLiveOrders(m) {
  if (!m || typeof m !== "object") {
    return false;
  }
  const st = String(m.merchant_status ?? m.status ?? "")
    .trim()
    .toLowerCase();
  if (st !== "approved") {
    return false;
  }
  const isOpen = m.is_open != null ? Boolean(m.is_open) : true;
  const accepting = m.accepting_orders != null ? Boolean(m.accepting_orders) : true;
  if (!isOpen || !accepting) {
    return false;
  }
  const raw = String(m.availability_status ?? "")
    .trim()
    .toLowerCase();
  if (raw === "closed" || raw === "offline" || raw === "paused") {
    return false;
  }
  return true;
}

async function assertFwPaymentForCustomer(db, customerId, fwRef, minAmountNgn) {
  const ref = trimStr(fwRef, 200);
  if (!ref) {
    return { ok: false, reason: "payment_reference_required" };
  }
  const ptxSnap = await db.ref(`payment_transactions/${ref}`).get();
  const ptx = ptxSnap.val();
  if (!ptx || typeof ptx !== "object") {
    return { ok: false, reason: "payment_transaction_missing" };
  }
  if (normUid(ptx.rider_id ?? ptx.customer_id) !== normUid(customerId)) {
    return { ok: false, reason: "payment_forbidden" };
  }
  if (ptx.verified !== true) {
    return { ok: false, reason: "payment_not_verified" };
  }
  const amt = Number(ptx.amount ?? ptx.charged_amount ?? ptx.amount_ngn ?? 0);
  if (Number.isFinite(minAmountNgn) && minAmountNgn > 0 && Number.isFinite(amt) && amt + 0.01 < minAmountNgn) {
    return { ok: false, reason: "payment_amount_mismatch" };
  }
  const tid = String(ptx.transaction_id ?? ptx.flutterwave_transaction_id ?? "").trim();
  if (!tid) {
    return { ok: false, reason: "payment_missing_txn_id" };
  }
  return { ok: true, transaction_id: tid };
}

async function merchantUpsertMenuCategory(data, context, _db) {
  const resolved = await resolveMerchantOwner(admin.firestore(), context);
  if (!resolved.ok) {
    return { success: false, reason: resolved.reason || "not_found" };
  }
  const roleBlock = requireMerchantRoles(resolved, context, ["owner", "manager"]);
  if (roleBlock) {
    return roleBlock;
  }
  const mid = resolved.ref.id;
  const m = resolved.data || {};
  const st = String(m.merchant_status ?? m.status ?? "").toLowerCase();
  if (st === "rejected" || st === "suspended") {
    return { success: false, reason: "merchant_not_allowed" };
  }
  const categoryId = trimStr(data?.category_id ?? data?.categoryId, 80);
  const name = trimStr(data?.name, 120);
  if (name.length < 2) {
    return { success: false, reason: "invalid_name" };
  }
  const sortOrder = Number(data?.sort_order ?? data?.sortOrder ?? 0) || 0;
  if (!Number.isFinite(sortOrder) || sortOrder < -100000 || sortOrder > 100000) {
    return { success: false, reason: "invalid_sort_order" };
  }
  const active = data?.active !== false;
  const imageUrl = trimStr(data?.image_url ?? data?.imageUrl, 2000);
  const fs = admin.firestore();
  const col = merchantMenuCategoriesCol(fs, mid);
  const ref = categoryId ? col.doc(categoryId) : col.doc();
  const prior = await ref.get();
  const ownerUid = normUid(context?.auth?.uid);
  const ts = FieldValue.serverTimestamp();
  const row = {
    category_id: ref.id,
    merchant_id: mid,
    name,
    sort_order: sortOrder,
    active,
    image_url: imageUrl || null,
    updated_at: ts,
    updated_by: ownerUid || null,
  };
  if (!prior.exists) {
    row.created_at = ts;
    row.created_by = ownerUid || null;
  }
  await ref.set(row, { merge: true });
  return { success: true, category_id: ref.id };
}

async function merchantDeleteMenuCategory(data, context, _db) {
  const resolved = await resolveMerchantOwner(admin.firestore(), context);
  if (!resolved.ok) {
    return { success: false, reason: resolved.reason || "not_found" };
  }
  const roleBlock = requireMerchantRoles(resolved, context, ["owner", "manager"]);
  if (roleBlock) {
    return roleBlock;
  }
  const mid = resolved.ref.id;
  const cid = trimStr(data?.category_id ?? data?.categoryId, 80);
  if (!cid) {
    return { success: false, reason: "invalid_category_id" };
  }
  const fs = admin.firestore();
  await merchantMenuCategoriesCol(fs, mid).doc(cid).delete();
  return { success: true };
}

async function merchantUpsertMenuItem(data, context, _db) {
  const resolved = await resolveMerchantOwner(admin.firestore(), context);
  if (!resolved.ok) {
    return { success: false, reason: resolved.reason || "not_found" };
  }
  const roleBlock = requireMerchantRoles(resolved, context, ["owner", "manager"]);
  if (roleBlock) {
    return roleBlock;
  }
  const mid = resolved.ref.id;
  const m = resolved.data || {};
  const st = String(m.merchant_status ?? m.status ?? "").toLowerCase();
  if (st === "rejected" || st === "suspended") {
    return { success: false, reason: "merchant_not_allowed" };
  }
  const itemId = trimStr(data?.item_id ?? data?.itemId, 80);
  const categoryId = trimStr(data?.category_id ?? data?.categoryId, 80);
  const name = trimStr(data?.name, 200);
  const priceNgn = Number(data?.price_ngn ?? data?.priceNgn ?? 0);
  if (!categoryId || name.length < 2 || !validMenuPriceNgn(priceNgn)) {
    return { success: false, reason: "invalid_item_fields" };
  }
  const fs = admin.firestore();
  const catSnap = await merchantMenuCategoriesCol(fs, mid).doc(categoryId).get();
  if (!catSnap.exists) {
    return { success: false, reason: "category_not_found" };
  }
  const col = merchantMenuItemsCol(fs, mid);
  const ref = itemId ? col.doc(itemId) : col.doc();
  const prior = await ref.get();
  const ownerUid = normUid(context?.auth?.uid);
  const ts = FieldValue.serverTimestamp();
  const prep = Math.min(240, Math.max(0, Number(data?.prep_time_min ?? data?.prepTimeMin ?? 15) || 15));
  const stockStatus = trimStr(data?.stock_status ?? data?.stockStatus ?? "in_stock", 24).toLowerCase();
  const imageUrl = trimStr(data?.image_url ?? data?.imageUrl, 2000);
  const description = trimStr(data?.description ?? data?.item_description, 4000);
  const roundedPrice = Math.round(priceNgn);
  const row = {
    item_id: ref.id,
    merchant_id: mid,
    category_id: categoryId,
    name,
    description: description || null,
    price_ngn: roundedPrice,
    currency: "NGN",
    image_url: imageUrl || null,
    available: data?.available !== false,
    stock_status: stockStatus === "out_of_stock" ? "out_of_stock" : "in_stock",
    prep_time_min: prep,
    archived_at: null,
    updated_at: ts,
    updated_by: ownerUid || null,
  };
  if (!prior.exists) {
    row.created_at = ts;
    row.created_by = ownerUid || null;
  }
  await ref.set(row, { merge: true });
  return { success: true, item_id: ref.id };
}

async function merchantArchiveMenuItem(data, context, _db) {
  const resolved = await resolveMerchantOwner(admin.firestore(), context);
  if (!resolved.ok) {
    return { success: false, reason: resolved.reason || "not_found" };
  }
  const roleBlock = requireMerchantRoles(resolved, context, ["owner", "manager"]);
  if (roleBlock) {
    return roleBlock;
  }
  const mid = resolved.ref.id;
  const iid = trimStr(data?.item_id ?? data?.itemId, 80);
  if (!iid) {
    return { success: false, reason: "invalid_item_id" };
  }
  const fs = admin.firestore();
  const ts = FieldValue.serverTimestamp();
  const ownerUid = normUid(context?.auth?.uid);
  await merchantMenuItemsCol(fs, mid).doc(iid).set(
    {
      available: false,
      archived_at: ts,
      updated_at: ts,
      updated_by: ownerUid || null,
    },
    { merge: true },
  );
  return { success: true };
}

async function merchantListMyMenu(_data, context, _db) {
  const resolved = await resolveMerchantOwner(admin.firestore(), context);
  if (!resolved.ok) {
    return { success: false, reason: resolved.reason || "not_found" };
  }
  const roleBlock = requireMerchantRoles(resolved, context, ["owner", "manager", "cashier"]);
  if (roleBlock) {
    return roleBlock;
  }
  const mid = resolved.ref.id;
  const fs = admin.firestore();
  const cats = await merchantMenuCategoriesCol(fs, mid).orderBy("sort_order").get();
  const items = await merchantMenuItemsCol(fs, mid).limit(500).get();
  return {
    success: true,
    categories: cats.docs.map((d) => ({ id: d.id, ...(d.data() || {}) })),
    items: items.docs.map((d) => ({ id: d.id, ...(d.data() || {}) })),
  };
}

async function merchantListMyMenuPage(data, context, _db) {
  const resolved = await resolveMerchantOwner(admin.firestore(), context);
  if (!resolved.ok) {
    return { success: false, reason: resolved.reason || "not_found" };
  }
  const roleBlock = requireMerchantRoles(resolved, context, ["owner", "manager", "cashier"]);
  if (roleBlock) {
    return roleBlock;
  }
  const mid = resolved.ref.id;
  const fs = admin.firestore();
  const catLimit = Math.min(80, Math.max(1, Number(data?.categories_limit ?? data?.categoryLimit ?? 30) || 30));
  const catCursor = trimStr(data?.categories_cursor ?? data?.categoryCursor, 128);
  let catQ = merchantMenuCategoriesCol(fs, mid).orderBy("sort_order").limit(catLimit + 1);
  if (catCursor) {
    const c0 = await merchantMenuCategoriesCol(fs, mid).doc(catCursor).get();
    if (c0.exists) {
      catQ = catQ.startAfter(c0);
    }
  }
  const catSnap = await catQ.get();
  const hasMoreCategories = catSnap.docs.length > catLimit;
  const catDocs = hasMoreCategories ? catSnap.docs.slice(0, catLimit) : catSnap.docs;
  const categories = catDocs.map((d) => ({ id: d.id, ...(d.data() || {}) }));
  const categoriesNext = hasMoreCategories && catDocs.length ? String(catDocs[catDocs.length - 1].id) : "";

  const categoryId = trimStr(data?.items_category_id ?? data?.category_id ?? data?.categoryId, 128);
  const itemLimit = Math.min(100, Math.max(1, Number(data?.items_limit ?? data?.itemLimit ?? 40) || 40));
  const itemCursor = trimStr(data?.items_cursor ?? data?.itemCursor, 128);
  const search = trimStr(data?.items_search ?? data?.itemSearch, 80).toLowerCase();
  let items = [];
  let itemsNext = "";
  let hasMoreItems = false;
  if (categoryId) {
    let iq = merchantMenuItemsCol(fs, mid)
      .where("category_id", "==", categoryId)
      .orderBy(FieldPath.documentId())
      .limit(itemLimit + 1);
    if (itemCursor) {
      const d0 = await merchantMenuItemsCol(fs, mid).doc(itemCursor).get();
      if (d0.exists) {
        iq = iq.startAfter(d0);
      }
    }
    const iSnap = await iq.get();
    hasMoreItems = iSnap.docs.length > itemLimit;
    const slice = hasMoreItems ? iSnap.docs.slice(0, itemLimit) : iSnap.docs;
    items = slice.map((d) => ({ id: d.id, ...(d.data() || {}) }));
    if (search) {
      items = items.filter((row) => String(row.name ?? "").toLowerCase().includes(search));
    }
    if (hasMoreItems && slice.length) {
      itemsNext = String(slice[slice.length - 1].id);
    }
  }
  return {
    success: true,
    categories,
    categories_next_cursor: categoriesNext,
    has_more_categories: Boolean(hasMoreCategories),
    items,
    items_next_cursor: itemsNext,
    has_more_items: Boolean(hasMoreItems && categoryId),
    search_applied_in_page_only: Boolean(search),
  };
}

async function riderListApprovedMerchants(data, context, _db) {
  const uid = normUid(context?.auth?.uid);
  if (!uid) {
    return { success: false, reason: "unauthorized" };
  }
  const fs = admin.firestore();
  let cityId = trimStr(
    data?.city_id ?? data?.cityId ?? data?.service_area_id ?? data?.serviceAreaId,
    120,
  );
  const regionId = trimStr(data?.region_id ?? data?.regionId, 80);
  const riderLat = Number(data?.rider_lat ?? data?.lat ?? data?.latitude ?? "");
  const riderLng = Number(data?.rider_lng ?? data?.lng ?? data?.longitude ?? "");
  const marketHint =
    ride.canonicalDispatchMarket(
      data?.market ?? data?.dispatch_market_id ?? data?.dispatchMarketId ?? data?.city ?? "",
    ) || "lagos";

  if (!cityId && regionId && Number.isFinite(riderLat) && Number.isFinite(riderLng)) {
    const geo = await deliveryRegions.assertRolloutGeoForDispatch(
      fs,
      marketHint,
      riderLat,
      riderLng,
      "merchant",
    );
    if (geo.ok) {
      cityId = trimStr(geo.city_id, 120);
    }
  }
  if (!cityId) {
    return { success: false, reason: "city_or_location_required" };
  }

  if (regionId && Number.isFinite(riderLat) && Number.isFinite(riderLng)) {
    const gate = await deliveryRegions.assertRolloutWithHints(
      fs,
      marketHint,
      riderLat,
      riderLng,
      "merchant",
      {
        region_id: regionId,
        city_id: cityId,
      },
    );
    if (!gate.ok) {
      return {
        success: false,
        reason: gate.reason || "rollout_denied",
        message: gate.message || "",
      };
    }
  }

  const snap = await fs.collection("merchants").where("merchant_status", "==", "approved").limit(160).get();

  const orderable = [];
  const nearbyUnavailable = [];
  const riderCoordsOk = Number.isFinite(riderLat) && Number.isFinite(riderLng);

  for (const d of snap.docs) {
    const m = d.data() || {};
    const st = String(m.merchant_status ?? m.status ?? "")
      .trim()
      .toLowerCase();
    if (st !== "approved") {
      continue;
    }
    const cid = trimStr(m.city_id ?? m.cityId, 120);
    if (cid && cid !== cityId) {
      continue;
    }
    const row = buildMerchantDiscoveryRow(m, d.id, riderLat, riderLng);
    const plat = row.pickup_lat;
    const plng = row.pickup_lng;
    const maxRadiusKm = Math.min(
      80,
      Math.max(8, Number(m.delivery_radius_km ?? m.deliveryRadiusKm ?? 22) || 22),
    );
    if (riderCoordsOk) {
      if (!Number.isFinite(plat) || !Number.isFinite(plng)) {
        nearbyUnavailable.push({
          ...row,
          unavailable_reason: "no_store_location",
        });
        continue;
      }
      const dKm = haversineKm(riderLat, riderLng, plat, plng);
      if (dKm > maxRadiusKm) {
        continue;
      }
      row.distance_km = Math.round(dKm * 1000) / 1000;
      const prep = row.prep_time_min_default;
      const win = etaWindowFromDistance(row.distance_km, prep);
      row.eta_min = win.eta_min;
      row.eta_max = win.eta_max;
      row.delivery_fee_estimate_ngn = estimateDeliveryFeeNgn(m, row.distance_km);
    }

    const live = merchantAcceptingLiveOrders(m);
    if (live) {
      orderable.push({ ...row, orders_live: true });
    } else if (riderCoordsOk && Number.isFinite(plat) && Number.isFinite(plng)) {
      const dKm = haversineKm(riderLat, riderLng, plat, plng);
      if (dKm <= maxRadiusKm * 1.15) {
        nearbyUnavailable.push({
          ...row,
          orders_live: false,
          unavailable_reason: row.open_status_reason || "unavailable",
        });
      }
    }
  }

  orderable.sort((a, b) => {
    const da = Number(a.distance_km);
    const db = Number(b.distance_km);
    if (Number.isFinite(da) && Number.isFinite(db)) {
      return da - db;
    }
    if (Number.isFinite(da)) {
      return -1;
    }
    if (Number.isFinite(db)) {
      return 1;
    }
    return String(a.business_name).localeCompare(String(b.business_name));
  });
  nearbyUnavailable.sort((a, b) => {
    const da = Number(a.distance_km);
    const db = Number(b.distance_km);
    if (Number.isFinite(da) && Number.isFinite(db)) {
      return da - db;
    }
    return 0;
  });

  return {
    success: true,
    resolved_city_id: cityId,
    merchants: orderable.slice(0, 40),
    nearby_unavailable: nearbyUnavailable.slice(0, 20),
  };
}

async function riderGetMerchantCatalog(data, context, _db) {
  const uid = normUid(context?.auth?.uid);
  if (!uid) {
    return { success: false, reason: "unauthorized" };
  }
  const merchantId = trimStr(data?.merchant_id ?? data?.merchantId, 128);
  if (!merchantId) {
    return { success: false, reason: "invalid_merchant_id" };
  }
  const riderLat = Number(data?.rider_lat ?? data?.lat ?? data?.latitude ?? "");
  const riderLng = Number(data?.rider_lng ?? data?.lng ?? data?.longitude ?? "");
  const fs = admin.firestore();
  const mSnap = await fs.collection("merchants").doc(merchantId).get();
  if (!mSnap.exists) {
    return { success: false, reason: "not_found" };
  }
  const m = mSnap.data() || {};
  const st = String(m.merchant_status ?? m.status ?? "").toLowerCase();
  if (st !== "approved") {
    return { success: false, reason: "merchant_not_available" };
  }
  if (!merchantAcceptingLiveOrders(m)) {
    return { success: false, reason: "merchant_closed" };
  }
  const cats = await merchantMenuCategoriesCol(fs, merchantId).get();
  const items = await merchantMenuItemsCol(fs, merchantId).limit(400).get();
  const outCats = [];
  for (const d of cats.docs) {
    const c = d.data() || {};
    if (c.active === false) {
      continue;
    }
    outCats.push({ id: d.id, ...c });
  }
  const outItems = [];
  for (const d of items.docs) {
    const it = d.data() || {};
    if (it.archived_at != null) {
      continue;
    }
    if (it.available === false) {
      continue;
    }
    if (String(it.stock_status ?? "").toLowerCase() === "out_of_stock") {
      continue;
    }
    outItems.push({ id: d.id, ...it });
  }
  const disc = buildMerchantDiscoveryRow(m, merchantId, riderLat, riderLng);
  return {
    success: true,
    merchant: {
      merchant_id: merchantId,
      business_name: String(m.business_name ?? ""),
      business_type: m.business_type != null ? String(m.business_type) : null,
      category: m.category != null ? String(m.category) : null,
      address: m.address != null ? String(m.address) : null,
      city_id: m.city_id ?? null,
      region_id: m.region_id ?? null,
      pickup_lat: m.pickup_lat ?? null,
      pickup_lng: m.pickup_lng ?? null,
      prep_time_min: disc.prep_time_min_default,
      store_logo_url: m.store_logo_url != null ? String(m.store_logo_url) : null,
      store_banner_url: m.store_banner_url != null ? String(m.store_banner_url) : null,
      distance_km: disc.distance_km,
      eta_min: disc.eta_min,
      eta_max: disc.eta_max,
      delivery_fee_estimate_ngn: disc.delivery_fee_estimate_ngn,
      orders_live: disc.orders_live,
      open_status_reason: disc.open_status_reason,
    },
    categories: outCats,
    items: outItems,
  };
}

async function riderPlaceMerchantOrder(data, context, db) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const customerId = normUid(context.auth.uid);
  const merchantId = trimStr(data?.merchant_id ?? data?.merchantId, 128);
  const fwRef = trimStr(
    data?.prepaid_flutterwave_ref ?? data?.prepaidFlutterwaveRef ?? data?.payment_reference ?? "",
    200,
  );
  const dropoff = data?.dropoff;
  const cart = data?.cart ?? data?.items;
  if (!merchantId || !dropoff || typeof dropoff !== "object" || !Array.isArray(cart) || cart.length === 0) {
    return { success: false, reason: "invalid_input" };
  }
  const riderGates = await ride.loadRiderCreateGates(db);
  if (!(await ride.riderProfileRequirementOk(db, customerId, riderGates, context.auth))) {
    return { success: false, reason: "user_profile_required" };
  }
  const identityGate = await riderFirestoreIdentity.evaluateRiderFirestoreIdentityForBooking(
    admin.firestore(),
    customerId,
  );
  if (!identityGate.ok) {
    return { success: false, reason: identityGate.reason || "identity_denied" };
  }

  const fs = admin.firestore();
  const mSnap = await fs.collection("merchants").doc(merchantId).get();
  if (!mSnap.exists) {
    return { success: false, reason: "merchant_not_found" };
  }
  const merchant = mSnap.data() || {};
  const st = String(merchant.merchant_status ?? merchant.status ?? "").toLowerCase();
  if (st !== "approved") {
    return { success: false, reason: "merchant_not_available" };
  }
  if (!merchantAcceptingLiveOrders(merchant)) {
    return { success: false, reason: "merchant_closed" };
  }

  const marketRaw = data?.market ?? data?.city ?? merchant.city_id ?? "";
  const market = ride.canonicalDispatchMarket(marketRaw);
  if (!market) {
    return { success: false, reason: "invalid_market" };
  }
  const dCoord = coordsFromPickup(dropoff);
  const rolloutGate = await deliveryRegions.assertRolloutWithHints(
    fs,
    market,
    dCoord.lat,
    dCoord.lng,
    "rides",
    {
      region_id: data?.service_region_id ?? data?.rollout_region_id ?? merchant.region_id,
      city_id: data?.service_city_id ?? data?.rollout_city_id ?? merchant.city_id,
    },
  );
  if (!rolloutGate.ok) {
    return {
      success: false,
      reason: rolloutGate.reason || "service_area_unsupported",
      message: rolloutGate.message || "",
    };
  }

  const lineItems = [];
  let subtotal = 0;
  for (const row of cart) {
    const itemId = trimStr(row?.item_id ?? row?.itemId, 80);
    const qty = Math.min(50, Math.max(1, Number(row?.qty ?? row?.quantity ?? 1) || 1));
    if (!itemId) {
      return { success: false, reason: "invalid_cart_line" };
    }
    const iSnap = await merchantMenuItemsCol(fs, merchantId).doc(itemId).get();
    if (!iSnap.exists) {
      return { success: false, reason: "item_not_found", item_id: itemId };
    }
    const it = iSnap.data() || {};
    if (it.available === false || it.archived_at != null) {
      return { success: false, reason: "item_unavailable", item_id: itemId };
    }
    const unit = Number(it.price_ngn ?? 0);
    if (!Number.isFinite(unit) || unit <= 0) {
      return { success: false, reason: "invalid_item_price", item_id: itemId };
    }
    const nameSnapshot = String(it.name ?? "");
    subtotal += unit * qty;
    lineItems.push({ item_id: itemId, name_snapshot: nameSnapshot, unit_price_ngn: unit, qty });
  }

  const deliveryFee = Math.max(0, Number(data?.delivery_fee_ngn ?? data?.deliveryFeeNgn ?? 0) || 0);
  const { computeRiderPricing, assertClientTotalMatches } = require("../pricing_calculator");
  const orderFlow = String(data?.order_flow ?? data?.orderFlow ?? "food_order").trim().toLowerCase();
  const pricing = computeRiderPricing({
    flow: orderFlow === "mart_order" || orderFlow === "store_order" ? orderFlow : "food_order",
    subtotal_ngn: subtotal,
    delivery_fee_ngn: deliveryFee,
  });
  const totalMismatch = assertClientTotalMatches(
    pricing,
    data?.total_ngn ?? data?.totalNgn ?? data?.amount,
  );
  if (!totalMismatch.ok) {
    return {
      success: false,
      reason: totalMismatch.reason,
      reason_code: totalMismatch.reason_code,
      message: totalMismatch.message,
      retryable: totalMismatch.retryable,
      pricing: totalMismatch.fee_breakdown,
    };
  }
  const total = pricing.total_ngn;
  const fin = effectiveCommissionFromMerchantDoc(merchant);
  const commissionNgn = fin.commission_exempt ? 0 : Math.round(subtotal * fin.commission_rate);
  const merchantNet = subtotal - commissionNgn;

  const payCheck = await assertFwPaymentForCustomer(db, customerId, fwRef, total);
  if (!payCheck.ok) {
    return { success: false, reason: payCheck.reason || "payment_failed" };
  }

  const plat = Number(merchant.pickup_lat ?? merchant.pickupLat);
  const plng = Number(merchant.pickup_lng ?? merchant.pickupLng);
  if (!Number.isFinite(plat) || !Number.isFinite(plng)) {
    return { success: false, reason: "merchant_pickup_coords_required" };
  }
  const pickupAddr = String(merchant.address ?? merchant.business_name ?? "Merchant pickup").slice(0, 500);
  const pickup = {
    lat: plat,
    lng: plng,
    address: pickupAddr,
  };
  const dropAddr = String(dropoff.address ?? dropoff.formatted_address ?? "Dropoff").slice(0, 500);
  const drop = {
    lat: Number(dropoff.lat ?? dropoff.latitude),
    lng: Number(dropoff.lng ?? dropoff.longitude),
    address: dropAddr,
  };
  if (!Number.isFinite(drop.lat) || !Number.isFinite(drop.lng)) {
    return { success: false, reason: "invalid_dropoff" };
  }

  const orderRef = ordersCol(fs).doc();
  const oid = orderRef.id;
  const ts = FieldValue.serverTimestamp();
  const recipientName = trimStr(data?.recipient_name ?? data?.recipientName ?? context.auth?.token?.name, 120);
  const recipientPhone = trimStr(data?.recipient_phone ?? data?.recipientPhone ?? "", 24);

  await orderRef.set({
    order_id: oid,
    merchant_id: merchantId,
    customer_uid: customerId,
    city_id: merchant.city_id ?? null,
    region_id: merchant.region_id ?? null,
    market,
    line_items: lineItems,
    subtotal_ngn: subtotal,
    delivery_fee_ngn: deliveryFee,
    platform_fee_ngn: pricing.platform_fee_ngn,
    small_order_fee_ngn: pricing.small_order_fee_ngn,
    total_ngn: total,
    fee_breakdown: pricing.fee_breakdown,
    commission_rate: fin.commission_rate,
    commission_exempt: fin.commission_exempt,
    commission_ngn: commissionNgn,
    merchant_net_ngn: merchantNet,
    withdrawal_percent_snapshot: fin.withdrawal_percent,
    order_status: ORDER_STATUS.pending_merchant,
    payment_method: "flutterwave",
    payment_status: "verified",
    payment_transaction_id: payCheck.transaction_id,
    prepaid_flutterwave_ref: fwRef,
    pickup_snapshot: { ...pickup, business_name: String(merchant.business_name ?? "") },
    dropoff_snapshot: drop,
    recipient_name: recipientName || "Customer",
    recipient_phone: recipientPhone || "",
    delivery_id: null,
    created_at: ts,
    updated_at: ts,
  });

  await db.ref("admin_audit_logs").push().set({
    type: "merchant_order_create",
    merchant_id: merchantId,
    order_id: oid,
    customer_uid: customerId,
    created_at: nowMs(),
  });

  try {
    const { syncMerchantPublicTeaserFromMerchantId } = require("../merchant_public_sync");
    await syncMerchantPublicTeaserFromMerchantId(db, merchantId, {
      last_order_id: oid,
      last_order_status: ORDER_STATUS.pending_merchant,
      last_order_at_ms: Date.now(),
    });
  } catch (e) {
    logger.warn("MERCHANT_ORDER_TEASER_SYNC_FAILED", { err: String(e?.message || e), merchantId, oid });
  }

  return { success: true, order_id: oid, total_ngn: total };
}

const MERCHANT_NEXT = {
  [ORDER_STATUS.pending_merchant]: new Set([ORDER_STATUS.merchant_accepted, ORDER_STATUS.merchant_rejected]),
  [ORDER_STATUS.merchant_accepted]: new Set([ORDER_STATUS.preparing]),
  [ORDER_STATUS.preparing]: new Set([ORDER_STATUS.ready_for_pickup]),
  [ORDER_STATUS.ready_for_pickup]: new Set([ORDER_STATUS.dispatching]),
};

async function merchantListMyOrders(_data, context, _db) {
  const resolved = await resolveMerchantOwner(admin.firestore(), context);
  if (!resolved.ok) {
    return { success: false, reason: resolved.reason || "not_found" };
  }
  const roleBlock = requireMerchantRoles(resolved, context, ["owner", "manager", "cashier"]);
  if (roleBlock) {
    return roleBlock;
  }
  const mid = resolved.ref.id;
  const m = resolved.data || {};
  const merchantStatus = String(m.merchant_status ?? m.status ?? "")
    .trim()
    .toLowerCase();
  if (merchantStatus !== "approved") {
    return {
      success: false,
      reason: "merchant_not_approved",
      reason_code: "merchant_not_approved",
      user_message:
        "Your store is not approved yet. Orders will appear after NexRide approves your business.",
    };
  }
  const fs = admin.firestore();
  const snap = await ordersCol(fs).where("merchant_id", "==", mid).limit(50).get();
  const orders = snap.docs
    .map((d) => ({ order_id: d.id, ...(d.data() || {}) }))
    .sort((a, b) => {
      const ta = a.created_at?.toMillis?.() ?? a.created_at?._seconds * 1000 ?? 0;
      const tb = b.created_at?.toMillis?.() ?? b.created_at?._seconds * 1000 ?? 0;
      return tb - ta;
    });
  return { success: true, orders };
}

async function merchantListMyOrdersPage(data, context, _db) {
  const resolved = await resolveMerchantOwner(admin.firestore(), context);
  if (!resolved.ok) {
    return { success: false, reason: resolved.reason || "not_found" };
  }
  const roleBlock = requireMerchantRoles(resolved, context, ["owner", "manager", "cashier"]);
  if (roleBlock) {
    return roleBlock;
  }
  const mid = resolved.ref.id;
  const fs = admin.firestore();
  const limit = Math.min(50, Math.max(5, Number(data?.limit ?? data?.page_size ?? 20) || 20));
  const cursor = trimStr(data?.cursor_order_id ?? data?.cursorOrderId, 128);
  let q = ordersCol(fs).where("merchant_id", "==", mid).orderBy("created_at", "desc").limit(limit);
  if (cursor) {
    const cdoc = await ordersCol(fs).doc(cursor).get();
    if (cdoc.exists) {
      q = q.startAfter(cdoc);
    }
  }
  const snap = await q.get();
  const orders = snap.docs.map((d) => ({ order_id: d.id, ...(d.data() || {}) }));
  const last = orders.length ? String(orders[orders.length - 1].order_id ?? "") : "";
  return {
    success: true,
    orders,
    next_cursor_order_id: last,
    has_more: orders.length >= limit,
  };
}

async function merchantGetOperationsInsights(_data, context, _db) {
  const resolved = await resolveMerchantOwner(admin.firestore(), context);
  if (!resolved.ok) {
    return { success: false, reason: resolved.reason || "not_found" };
  }
  const roleBlock = requireMerchantRoles(resolved, context, ["owner", "manager"]);
  if (roleBlock) {
    return roleBlock;
  }
  const mid = resolved.ref.id;
  const fs = admin.firestore();
  const snap = await ordersCol(fs).where("merchant_id", "==", mid).limit(500).get();
  const start = new Date();
  start.setHours(0, 0, 0, 0);
  const startMs = start.getTime();
  let total = 0;
  let completed = 0;
  let cancelled = 0;
  let todayRevenue = 0;
  /** @type {Record<string, number>} */
  const itemCounts = {};
  for (const d of snap.docs) {
    const o = d.data() || {};
    total += 1;
    const st = String(o.order_status ?? "").toLowerCase();
    if (st === "completed") completed += 1;
    if (st === "cancelled" || st === "merchant_rejected") cancelled += 1;
    const created =
      o.created_at?.toMillis?.() ?? (o.created_at?._seconds ? o.created_at._seconds * 1000 : 0);
    if (created >= startMs && st !== "cancelled" && st !== "merchant_rejected") {
      todayRevenue += Number(o.total_ngn ?? 0) || 0;
    }
    const lines = Array.isArray(o.line_items) ? o.line_items : [];
    for (const li of lines) {
      const iid = trimStr(li?.item_id ?? li?.itemId, 80);
      if (!iid) continue;
      const qv = Math.min(500, Math.max(1, Number(li?.qty ?? li?.quantity ?? 1) || 1));
      itemCounts[iid] = (itemCounts[iid] || 0) + qv;
    }
  }
  const topIds = Object.entries(itemCounts)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 15)
    .map(([item_id, units_sold]) => ({ item_id, units_sold }));
  const top_items = [];
  for (const row of topIds) {
    const ds = await merchantMenuItemsCol(fs, mid).doc(row.item_id).get();
    const name = ds.exists ? String((ds.data() || {}).name ?? row.item_id).slice(0, 120) : row.item_id;
    top_items.push({ ...row, name });
  }
  return {
    success: true,
    total_orders: total,
    completed_orders: completed,
    cancelled_orders: cancelled,
    today_revenue_ngn: Math.round(todayRevenue),
    top_items,
  };
}

async function merchantUpdateOrderStatus(data, context, db) {
  const resolved = await resolveMerchantOwner(admin.firestore(), context);
  if (!resolved.ok) {
    return { success: false, reason: resolved.reason || "not_found" };
  }
  const roleBlock = requireMerchantRoles(resolved, context, ["owner", "manager", "cashier"]);
  if (roleBlock) {
    return roleBlock;
  }
  const mid = resolved.ref.id;
  const orderId = trimStr(data?.order_id ?? data?.orderId, 128);
  const next = trimStr(data?.status ?? data?.order_status, 48).toLowerCase();
  if (!orderId || !next) {
    return { success: false, reason: "invalid_input" };
  }
  if (next === ORDER_STATUS.merchant_rejected) {
    const rejectGate = requireMerchantRoles(resolved, context, ["owner", "manager"]);
    if (rejectGate) {
      return rejectGate;
    }
  }
  const fs = admin.firestore();
  const ref = ordersCol(fs).doc(orderId);
  const snap = await ref.get();
  if (!snap.exists) {
    return { success: false, reason: "not_found" };
  }
  const o = snap.data() || {};
  if (trimStr(o.merchant_id, 128) !== mid) {
    return { success: false, reason: "forbidden" };
  }
  const cur = String(o.order_status ?? "").toLowerCase();
  if (TERMINAL_ORDER.has(cur)) {
    return { success: false, reason: "order_terminal" };
  }
  const allowed = MERCHANT_NEXT[cur];
  if (!allowed || !allowed.has(next)) {
    return { success: false, reason: "invalid_transition", from: cur, to: next };
  }

  const ts = FieldValue.serverTimestamp();
  const updates = { order_status: next, updated_at: ts };

  if (next === ORDER_STATUS.merchant_accepted && !o.merchant_accepted_at) {
    updates.merchant_accepted_at = ts;
  }
  if (next === ORDER_STATUS.preparing && !o.preparing_started_at) {
    updates.preparing_started_at = ts;
  }
  if (next === ORDER_STATUS.ready_for_pickup && !o.ready_for_pickup_at) {
    updates.ready_for_pickup_at = ts;
  }

  if (next === ORDER_STATUS.dispatching) {
    const customerId = normUid(o.customer_uid);
    const payOk =
      String(o.payment_status ?? "").toLowerCase() === "verified" &&
      Boolean(String(o.payment_transaction_id ?? "").trim());
    if (!payOk) {
      return { success: false, reason: "payment_not_verified" };
    }
    const pickup = o.pickup_snapshot || {};
    const dropoff = o.dropoff_snapshot || {};
    const pkg = lineItemsToPackageDescription(o.line_items || []);
    const deliveryFare = Math.max(500, Number(o.delivery_fee_ngn ?? 0) || 1500);
    const exp = nowMs() + 180000;
    const delRef = db.ref("delivery_requests").push();
    const deliveryId = normUid(delRef.key);
    if (!deliveryId) {
      return { success: false, reason: "delivery_id_failed" };
    }
    const built = {
      delivery_id: deliveryId,
      customer_id: customerId,
      market: String(o.market ?? "lagos"),
      market_pool: String(o.market ?? "lagos"),
      pickup,
      dropoff,
      package_description: pkg,
      recipient_name: String(o.recipient_name ?? "Customer").slice(0, 120),
      recipient_phone: String(o.recipient_phone ?? "000").slice(0, 20),
      fare: deliveryFare,
      currency: "NGN",
      distance_km: Number(data?.distance_km ?? 3) || 3,
      eta_minutes: Number(data?.eta_minutes ?? 15) || 15,
      payment_method: "flutterwave",
      payment_status: "verified",
      payment_transaction_id: String(o.payment_transaction_id ?? "").trim(),
      merchant_id: mid,
      merchant_order_id: orderId,
      food_order_summary: pkg.slice(0, 500),
      expires_at: exp,
      search_timeout_at: exp,
      request_expires_at: exp,
    };
    const r = await delivery.createFoodDeliveryForMerchantOrder(db, built);
    if (!r.ok) {
      return { success: false, reason: r.reason || "delivery_create_failed" };
    }
    updates.delivery_id = r.deliveryId;
  }

  await ref.update(updates);
  await db.ref("admin_audit_logs").push().set({
    type: "merchant_order_status",
    merchant_id: mid,
    order_id: orderId,
    status: next,
    actor_uid: normUid(context?.auth?.uid),
    created_at: nowMs(),
  });
  return { success: true, order_id: orderId, order_status: next, delivery_id: updates.delivery_id ?? o.delivery_id };
}

function lineItemsToPackageDescription(lines) {
  if (!Array.isArray(lines)) {
    return "Food order";
  }
  return lines
    .map((l) => `${l.qty}× ${l.name_snapshot || l.item_id}`)
    .join("; ")
    .slice(0, 1900);
}

async function adminListMerchantOrders(data, context, db) {
  const denyLmo = await adminPerms.enforceCallable(db, context, "adminListMerchantOrders");
  if (denyLmo) return denyLmo;
  const merchantId = trimStr(data?.merchant_id ?? data?.merchantId, 128);
  if (!merchantId) {
    return { success: false, reason: "invalid_merchant_id" };
  }
  const fs = admin.firestore();
  const snap = await ordersCol(fs).where("merchant_id", "==", merchantId).limit(80).get();
  const orders = snap.docs
    .map((d) => ({ order_id: d.id, ...(d.data() || {}) }))
    .sort((a, b) => {
      const ta = a.created_at?.toMillis?.() ?? a.created_at?._seconds * 1000 ?? 0;
      const tb = b.created_at?.toMillis?.() ?? b.created_at?._seconds * 1000 ?? 0;
      return tb - ta;
    });
  return { success: true, orders };
}

async function riderListMyOrders(_data, context, _db) {
  const uid = normUid(context?.auth?.uid);
  if (!uid) {
    return { success: false, reason: "unauthorized" };
  }
  const fs = admin.firestore();
  const snap = await ordersCol(fs)
    .where("customer_uid", "==", uid)
    .limit(30)
    .get();
  const orders = snap.docs
    .map((d) => ({ order_id: d.id, ...(d.data() || {}) }))
    .sort((a, b) => {
      const ta = a.created_at?.toMillis?.() ?? (a.created_at?._seconds ?? 0) * 1000;
      const tb = b.created_at?.toMillis?.() ?? (b.created_at?._seconds ?? 0) * 1000;
      return tb - ta;
    });
  return { success: true, orders };
}

const MAX_MENU_IMAGE_BYTES = 10 * 1024 * 1024;

/**
 * Validates a Storage object uploaded by the merchant, then writes a signed HTTPS URL
 * onto the matching Firestore menu row or merchant profile.
 */
async function merchantAttachMenuOrProfileImage(data, context, _db) {
  const resolved = await resolveMerchantOwner(admin.firestore(), context);
  if (!resolved.ok) {
    return { success: false, reason: resolved.reason || "not_found" };
  }
  const roleBlock = requireMerchantRoles(resolved, context, ["owner", "manager"]);
  if (roleBlock) {
    return roleBlock;
  }
  const mid = resolved.ref.id;
  const m = resolved.data || {};
  const st = String(m.merchant_status ?? m.status ?? "").toLowerCase();
  if (st === "rejected" || st === "suspended") {
    return { success: false, reason: "merchant_not_allowed" };
  }
  const kind = trimStr(data?.kind ?? data?.image_kind, 24).toLowerCase();
  const storagePath = trimStr(data?.storage_path ?? data?.storagePath, 1024);
  const entityId = trimStr(
    data?.entity_id ?? data?.entityId ?? data?.category_id ?? data?.categoryId ?? data?.item_id ?? data?.itemId,
    128,
  );
  if (!storagePath || storagePath.includes("..")) {
    return { success: false, reason: "invalid_storage_path" };
  }
  let prefix = "";
  if (kind === "category") {
    if (!entityId) {
      return { success: false, reason: "invalid_entity_id" };
    }
    prefix = `merchant_uploads/${mid}/menu/categories/${entityId}/`;
  } else if (kind === "item") {
    if (!entityId) {
      return { success: false, reason: "invalid_entity_id" };
    }
    prefix = `merchant_uploads/${mid}/menu/items/${entityId}/`;
  } else if (kind === "logo" || kind === "banner") {
    const base = `merchant_uploads/${mid}/profile/`;
    if (!storagePath.startsWith(base)) {
      return { success: false, reason: "path_mismatch" };
    }
    const rel = storagePath.slice(base.length);
    if (!rel || rel.includes("..")) {
      return { success: false, reason: "invalid_storage_path" };
    }
    const okLegacy = kind === "logo" ? /^logo_\d+\.[^/]+$/i.test(rel) : /^banner_\d+\.[^/]+$/i.test(rel);
    const okNested =
      (kind === "logo" && rel.startsWith("logo/") && !rel.slice(5).includes("/")) ||
      (kind === "banner" && rel.startsWith("banner/") && !rel.slice(7).includes("/"));
    if (!(okLegacy || okNested)) {
      return { success: false, reason: "invalid_storage_path" };
    }
    prefix = ""; // profile paths validated above (nested or legacy flat file)
  } else {
    return { success: false, reason: "invalid_kind" };
  }
  if (prefix) {
    if (!storagePath.startsWith(prefix)) {
      return { success: false, reason: "path_mismatch" };
    }
    const tail = storagePath.slice(prefix.length);
    if (!tail || tail.includes("/")) {
      return { success: false, reason: "invalid_storage_path" };
    }
  }
  const bucket = admin.storage().bucket();
  const file = bucket.file(storagePath);
  const [exists] = await file.exists();
  if (!exists) {
    return { success: false, reason: "storage_object_missing" };
  }
  const [meta] = await file.getMetadata();
  const ct = String(meta.contentType || "").toLowerCase();
  if (!ct.startsWith("image/")) {
    return { success: false, reason: "invalid_content_type" };
  }
  const size = Number(meta.size || 0);
  if (size <= 0 || size > MAX_MENU_IMAGE_BYTES) {
    return { success: false, reason: "invalid_file_size" };
  }
  const [signed] = await file.getSignedUrl({
    action: "read",
    expires: new Date(Date.now() + 86400000 * 365),
  });
  const fs = admin.firestore();
  const ts = FieldValue.serverTimestamp();
  if (kind === "category") {
    const cref = merchantMenuCategoriesCol(fs, mid).doc(entityId);
    const cs = await cref.get();
    if (!cs.exists) {
      return { success: false, reason: "category_not_found" };
    }
    await cref.set(
      {
        image_url: signed,
        image_storage_path: storagePath,
        updated_at: ts,
      },
      { merge: true },
    );
  } else if (kind === "item") {
    const iref = merchantMenuItemsCol(fs, mid).doc(entityId);
    const is = await iref.get();
    if (!is.exists) {
      return { success: false, reason: "item_not_found" };
    }
    await iref.set(
      {
        image_url: signed,
        image_storage_path: storagePath,
        updated_at: ts,
      },
      { merge: true },
    );
  } else if (kind === "logo") {
    await resolved.ref.set(
      {
        store_logo_url: signed,
        store_logo_storage_path: storagePath,
        updated_at: ts,
      },
      { merge: true },
    );
  } else if (kind === "banner") {
    await resolved.ref.set(
      {
        store_banner_url: signed,
        store_banner_storage_path: storagePath,
        updated_at: ts,
      },
      { merge: true },
    );
  }
  return { success: true, image_url: signed, storage_path: storagePath, kind };
}

async function supportGetMerchantOrderContext(data, context, db) {
  if (!(await isNexRideAdminOrSupport(db, context))) {
    return { success: false, reason: "unauthorized" };
  }
  const orderId = trimStr(data?.order_id ?? data?.orderId, 128);
  if (!orderId) {
    return { success: false, reason: "invalid_order_id" };
  }
  const fs = admin.firestore();
  const oSnap = await ordersCol(fs).doc(orderId).get();
  if (!oSnap.exists) {
    return { success: false, reason: "not_found" };
  }
  const o = oSnap.data() || {};
  const mSnap = await fs.collection("merchants").doc(String(o.merchant_id ?? "")).get();
  return {
    success: true,
    order: { order_id: orderId, ...o },
    merchant: mSnap.exists ? { merchant_id: mSnap.id, ...(mSnap.data() || {}) } : null,
  };
}

module.exports = {
  ORDER_STATUS,
  merchantUpsertMenuCategory,
  merchantDeleteMenuCategory,
  merchantUpsertMenuItem,
  merchantArchiveMenuItem,
  merchantListMyMenu,
  merchantListMyMenuPage,
  riderListApprovedMerchants,
  riderGetMerchantCatalog,
  riderPlaceMerchantOrder,
  riderListMyOrders,
  merchantListMyOrders,
  merchantListMyOrdersPage,
  merchantGetOperationsInsights,
  merchantUpdateOrderStatus,
  merchantAttachMenuOrProfileImage,
  adminListMerchantOrders,
  supportGetMerchantOrderContext,
  effectiveCommissionFromMerchantDoc,
  assertFwPaymentForCustomer,
};
