/**
 * Rider/user discount SSOT (RTDB only).
 * Stores: user_discounts/{uid}/{discountId}, discount_ledger/{uid}/{entryId}
 */

const { normUid } = require("./admin_auth");
const { roundNgn } = require("./pricing_snapshot");

const ACTIVE_STATUSES = new Set(["active"]);
const APPLIES_TO_ALIASES = {
  ride: "ride",
  ride_booking: "ride",
  delivery: "delivery",
  dispatch_request: "delivery",
  dispatch_delivery: "delivery",
  merchant_order: "merchant_order",
  food_order: "merchant_order",
  mart_order: "merchant_order",
  store_order: "merchant_order",
  withdrawal_fee: "withdrawal_fee",
  promo_credit: "promo_credit",
};

function normalizeAppliesTo(raw) {
  const key = String(raw ?? "")
    .trim()
    .toLowerCase();
  return APPLIES_TO_ALIASES[key] || key;
}

function normalizeDiscountType(raw) {
  return String(raw ?? "")
    .trim()
    .toLowerCase();
}

function discountPath(uid, discountId) {
  return `user_discounts/${normUid(uid)}/${String(discountId ?? "").trim()}`;
}

function ledgerPath(uid, entryId) {
  return `discount_ledger/${normUid(uid)}/${String(entryId ?? "").trim()}`;
}

function ledgerIdempotencyKey(entityType, entityId, discountId) {
  return `${String(entityType ?? "")
    .trim()
    .toLowerCase()}_${String(entityId ?? "")
    .trim()}_${String(discountId ?? "").trim()}`
    .replace(/[^a-zA-Z0-9_-]/g, "_")
    .slice(0, 120);
}

function isDiscountActive(row, nowMs = Date.now()) {
  if (!row || typeof row !== "object") return false;
  const status = String(row.status ?? "").trim().toLowerCase();
  if (!ACTIVE_STATUSES.has(status)) return false;
  const expiresAt = Number(row.expires_at ?? row.expiresAt ?? 0) || 0;
  if (expiresAt > 0 && expiresAt < nowMs) return false;
  const remainingUses = Number(row.remaining_uses ?? row.remainingUses ?? 0);
  if (Number.isFinite(remainingUses) && remainingUses <= 0) return false;
  const remainingBalance = Number(row.remaining_balance_ngn ?? row.remainingBalanceNgn ?? 0);
  if (Number.isFinite(remainingBalance) && remainingBalance <= 0 && !row.percent) return false;
  return true;
}

function computeDiscountAmountNgn(row, baseAmountNgn) {
  const base = roundNgn(baseAmountNgn);
  if (base <= 0) return 0;
  const percent = Number(row.percent ?? 0);
  const amountNgn = Number(row.amount_ngn ?? row.amountNgn ?? 0);
  const maxDiscount = Number(row.max_discount_ngn ?? row.maxDiscountNgn ?? 0);
  let discount = 0;
  if (percent > 0) {
    discount = roundNgn((base * percent) / 100);
  } else if (amountNgn > 0) {
    discount = roundNgn(amountNgn);
  } else {
    const balance = Number(row.remaining_balance_ngn ?? row.remainingBalanceNgn ?? 0);
    if (balance > 0) {
      discount = roundNgn(Math.min(balance, base));
    }
  }
  if (maxDiscount > 0) {
    discount = Math.min(discount, roundNgn(maxDiscount));
  }
  discount = Math.min(discount, base);
  const remainingBalance = Number(row.remaining_balance_ngn ?? row.remainingBalanceNgn ?? 0);
  if (remainingBalance > 0 && !percent && !(amountNgn > 0)) {
    discount = Math.min(discount, roundNgn(remainingBalance));
  }
  return Math.max(0, discount);
}

async function listUserDiscounts(db, uid) {
  const id = normUid(uid);
  if (!id) return [];
  const snap = await db.ref(`user_discounts/${id}`).get();
  const val = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  return Object.entries(val)
    .map(([discountId, row]) => ({ discountId, ...(row && typeof row === "object" ? row : {}) }))
    .sort((a, b) => (Number(b.created_at ?? 0) || 0) - (Number(a.created_at ?? 0) || 0));
}

async function findBestEligibleDiscount(db, uid, appliesTo, baseAmountNgn, nowMs = Date.now()) {
  const target = normalizeAppliesTo(appliesTo);
  const rows = await listUserDiscounts(db, uid);
  let best = null;
  let bestAmount = 0;
  for (const row of rows) {
    if (!isDiscountActive(row, nowMs)) continue;
    const rowApplies = normalizeAppliesTo(row.applies_to ?? row.appliesTo);
    if (rowApplies !== target && rowApplies !== "all") continue;
    const amount = computeDiscountAmountNgn(row, baseAmountNgn);
    if (amount > bestAmount) {
      bestAmount = amount;
      best = { ...row, discountId: row.discountId || row.id };
    }
  }
  return best ? { discount: best, discount_amount_ngn: bestAmount } : null;
}

function enrichPricingSnapshotWithDiscount(snapshot, discountCtx) {
  if (!snapshot || !discountCtx?.discount) return snapshot;
  const discountNgn = roundNgn(discountCtx.discount_amount_ngn ?? 0);
  if (discountNgn <= 0) return snapshot;
  const baseTotal = roundNgn(snapshot.total_ngn ?? 0);
  const nextTotal = Math.max(0, baseTotal - discountNgn);
  return Object.freeze({
    ...snapshot,
    discount_applied_ngn: discountNgn,
    discount_id: discountCtx.discount.discountId || discountCtx.discount.id || null,
    discount_type: discountCtx.discount.discount_type ?? discountCtx.discount.discountType ?? null,
    applies_to: normalizeAppliesTo(discountCtx.discount.applies_to ?? discountCtx.discount.appliesTo),
    pre_discount_total_ngn: baseTotal,
    total_ngn: nextTotal,
  });
}

async function consumeDiscount(db, uid, discountId, ctx = {}) {
  const userId = normUid(uid);
  const id = String(discountId ?? "").trim();
  if (!userId || !id) return { ok: false, reason: "invalid_input" };

  const entityType = String(ctx.entity_type ?? ctx.entityType ?? "").trim();
  const entityId = String(ctx.entity_id ?? ctx.entityId ?? "").trim();
  const idemKey =
    String(ctx.idempotency_key ?? ctx.idempotencyKey ?? "").trim() ||
    (entityType && entityId ? ledgerIdempotencyKey(entityType, entityId, id) : "");
  if (idemKey) {
    const idemRef = db.ref(ledgerPath(userId, idemKey));
    const idemSnap = await idemRef.get();
    if (idemSnap.exists()) {
      const prior = idemSnap.val() && typeof idemSnap.val() === "object" ? idemSnap.val() : {};
      return {
        ok: true,
        idempotent: true,
        entryId: idemKey,
        applied_amount_ngn: roundNgn(prior.applied_amount_ngn ?? 0),
      };
    }
  }

  const ref = db.ref(discountPath(userId, id));
  const snap = await ref.get();
  if (!snap.exists()) return { ok: false, reason: "not_found" };
  const row = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  if (!isDiscountActive(row)) return { ok: false, reason: "not_active" };

  const appliedNgn = roundNgn(ctx.applied_amount_ngn ?? ctx.appliedAmountNgn ?? 0);
  const now = Number(ctx.at ?? Date.now()) || Date.now();
  const remainingUsesRaw = row.remaining_uses ?? row.remainingUses;
  const remainingBalanceRaw = row.remaining_balance_ngn ?? row.remainingBalanceNgn;
  const patch = { updated_at: now, updatedAt: now };
  if (Number.isFinite(Number(remainingUsesRaw))) {
    const nextUses = Math.max(0, Number(remainingUsesRaw) - 1);
    patch.remaining_uses = nextUses;
    patch.remainingUses = nextUses;
    if (nextUses <= 0) {
      patch.status = "used";
    }
  }
  if (Number.isFinite(Number(remainingBalanceRaw)) && appliedNgn > 0) {
    const nextBal = Math.max(0, roundNgn(Number(remainingBalanceRaw) - appliedNgn));
    patch.remaining_balance_ngn = nextBal;
    patch.remainingBalanceNgn = nextBal;
    if (nextBal <= 0 && !row.percent && !(Number(row.amount_ngn ?? 0) > 0)) {
      patch.status = "used";
    }
  }

  const entryId = idemKey || db.ref(`discount_ledger/${userId}`).push().key;
  if (!entryId) return { ok: false, reason: "ledger_key_failed" };
  const ledgerRow = {
    discount_id: id,
    discount_type: row.discount_type ?? row.discountType ?? null,
    applies_to: normalizeAppliesTo(row.applies_to ?? row.appliesTo),
    applied_amount_ngn: appliedNgn,
    entity_type: entityType || null,
    entity_id: entityId || null,
    idempotency_key: idemKey || null,
    reason: String(ctx.reason ?? row.reason ?? "").trim().slice(0, 500) || null,
    created_at: now,
    createdAt: now,
    created_by: ctx.actor_uid ?? ctx.actorUid ?? "system",
  };
  await db.ref().update({
    [discountPath(userId, id)]: { ...row, ...patch },
    [ledgerPath(userId, entryId)]: ledgerRow,
  });
  return { ok: true, entryId, applied_amount_ngn: appliedNgn, idempotent: false };
}

async function grantUserDiscount(db, input = {}) {
  const uid = normUid(input.uid ?? input.user_id ?? input.userId);
  if (!uid) return { ok: false, reason: "invalid_uid" };
  const discountId = String(input.discount_id ?? input.discountId ?? "").trim() || db.ref(`user_discounts/${uid}`).push().key;
  if (!discountId) return { ok: false, reason: "discount_id_failed" };
  const now = Number(input.created_at ?? Date.now()) || Date.now();
  const appliesTo = normalizeAppliesTo(input.applies_to ?? input.appliesTo ?? "ride");
  const row = {
    discount_type: normalizeDiscountType(input.discount_type ?? input.discountType ?? appliesTo),
    amount_ngn: roundNgn(input.amount_ngn ?? input.amountNgn ?? 0) || null,
    percent: Number(input.percent ?? 0) > 0 ? Number(input.percent) : null,
    max_discount_ngn: roundNgn(input.max_discount_ngn ?? input.maxDiscountNgn ?? 0) || null,
    remaining_uses:
      input.remaining_uses != null
        ? Math.max(0, Number(input.remaining_uses) || 0)
        : input.remainingUses != null
          ? Math.max(0, Number(input.remainingUses) || 0)
          : 1,
    remaining_balance_ngn:
      roundNgn(input.remaining_balance_ngn ?? input.remainingBalanceNgn ?? input.amount_ngn ?? 0) || null,
    applies_to: appliesTo,
    status: "active",
    created_by: normUid(input.created_by ?? input.createdBy ?? input.actor_uid),
    created_at: now,
    createdAt: now,
    expires_at: Number(input.expires_at ?? input.expiresAt ?? 0) || null,
    expiresAt: Number(input.expires_at ?? input.expiresAt ?? 0) || null,
    reason: String(input.reason ?? "").trim().slice(0, 500) || null,
  };
  await db.ref(discountPath(uid, discountId)).set(row);
  return { ok: true, uid, discountId, discount: row };
}

async function revokeUserDiscount(db, uid, discountId, actorUid, reason = "") {
  const userId = normUid(uid);
  const id = String(discountId ?? "").trim();
  if (!userId || !id) return { ok: false, reason: "invalid_input" };
  const now = Date.now();
  await db.ref(discountPath(userId, id)).update({
    status: "revoked",
    revoked_at: now,
    revokedAt: now,
    revoked_by: normUid(actorUid),
    revoke_reason: String(reason ?? "").trim().slice(0, 500) || null,
    updated_at: now,
    updatedAt: now,
  });
  return { ok: true, uid: userId, discountId: id };
}

async function listDiscountLedger(db, uid, limit = 40) {
  const userId = normUid(uid);
  if (!userId) return [];
  const snap = await db.ref(`discount_ledger/${userId}`).orderByKey().limitToLast(limit).get();
  const val = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  return Object.entries(val)
    .map(([entryId, row]) => ({ entryId, ...(row && typeof row === "object" ? row : {}) }))
    .sort((a, b) => (Number(b.created_at ?? 0) || 0) - (Number(a.created_at ?? 0) || 0));
}

module.exports = {
  normalizeAppliesTo,
  isDiscountActive,
  computeDiscountAmountNgn,
  listUserDiscounts,
  findBestEligibleDiscount,
  enrichPricingSnapshotWithDiscount,
  consumeDiscount,
  ledgerIdempotencyKey,
  grantUserDiscount,
  revokeUserDiscount,
  listDiscountLedger,
};
