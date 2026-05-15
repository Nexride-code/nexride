/**
 * Public storefront snapshot for riders (RTDB) — no secrets; updated from Cloud Functions only.
 * Clients read via database.rules.json (auth required).
 */
const admin = require("firebase-admin");

function availabilityStatusForTeaser(m) {
  const raw = String(m?.availability_status ?? "")
    .trim()
    .toLowerCase();
  if (raw === "open" || raw === "closed" || raw === "paused") return raw;
  const online = String(m?.availability_status ?? "")
    .trim()
    .toLowerCase();
  if (online === "online") return "open";
  if (online === "offline") return "closed";
  const isOpen = m?.is_open != null ? Boolean(m.is_open) : true;
  const acc = m?.accepting_orders != null ? Boolean(m.accepting_orders) : true;
  if (isOpen && acc) return "open";
  if (isOpen && !acc) return "paused";
  return "closed";
}

/**
 * @param {import("firebase-admin/database").Database} db
 * @param {string} merchantId
 * @param {object} [extra] optional fields merged (e.g. last_order_id)
 */
async function syncMerchantPublicTeaserFromMerchantId(db, merchantId, extra = {}) {
  const mid = String(merchantId ?? "").trim();
  if (!mid || !db) return;
  const fs = admin.firestore();
  const snap = await fs.collection("merchants").doc(mid).get();
  if (!snap.exists) return;
  const m = snap.data() || {};
  const st = String(m.merchant_status ?? m.status ?? "")
    .trim()
    .toLowerCase();
  const isOpen = m.is_open != null ? Boolean(m.is_open) : true;
  const accepting = m.accepting_orders != null ? Boolean(m.accepting_orders) : true;
  const mode = availabilityStatusForTeaser(m);
  const ordersLive = st === "approved" && isOpen && accepting && mode === "open";
  const payload = {
    merchant_id: mid,
    business_name: String(m.business_name ?? ""),
    merchant_status: st || "pending",
    is_open: isOpen,
    accepting_orders: accepting,
    availability_status: mode,
    orders_live: ordersLive,
    updated_at_ms: Date.now(),
    ...extra,
  };
  await db.ref(`merchant_public_teaser/${mid}`).update(payload);
}

module.exports = {
  syncMerchantPublicTeaserFromMerchantId,
};
