function text(v) {
  return String(v ?? "").trim().toLowerCase();
}

function asObj(v) {
  return v && typeof v === "object" ? v : {};
}

function resolveSelectedModel(row) {
  const selected = text(row.selectedModel || row.selected_model);
  return selected === "subscription" ? "subscription" : "commission";
}

function resolveEffectiveModel(row) {
  const explicit = text(row.effectiveModel || row.effective_model);
  if (explicit === "subscription" || explicit === "commission") {
    return explicit;
  }
  return resolveSelectedModel(row);
}

async function resolveDriverMonetization(db, driverId) {
  const uid = String(driverId ?? "").trim();
  if (!uid) {
    return {
      selectedModel: "commission",
      effectiveModel: "commission",
      isSubscription: false,
      source: "missing_driver_id",
    };
  }

  const snap = await db.ref(`drivers/${uid}/businessModel`).get();
  const raw = asObj(snap.val());
  const selectedModel = resolveSelectedModel(raw);
  const effectiveModel = resolveEffectiveModel(raw);
  const commissionExempt =
    raw.commissionExempt === true || raw.commission_exempt === true;
  const isSubscription = effectiveModel === "subscription" || commissionExempt;
  return {
    selectedModel,
    effectiveModel,
    isSubscription,
    commissionExempt,
    source: "drivers_business_model",
  };
}

async function resolveCommissionPolicy(db, driverId) {
  const uid = String(driverId ?? "").trim();
  if (!uid) {
    return { exempt: false, reason: "missing_driver_id" };
  }
  const driverSnap = await db.ref(`drivers/${uid}`).get();
  const driver = asObj(driverSnap.val());
  const commissionExempt = driver.commission_exempt === true || driver.commissionExempt === true;
  const expiresAt = Number(driver.subscription_expires_at ?? driver.subscriptionExpiresAt ?? 0) || 0;
  const now = Date.now();
  const activeSubscription = commissionExempt && expiresAt > now;
  if (commissionExempt && expiresAt > 0 && expiresAt <= now) {
    await db.ref(`drivers/${uid}`).update({
      commission_exempt: false,
      commissionExempt: false,
      subscription_status: "expired",
      effectiveModel: "commission",
      subscription_renewal_reminder_sent: false,
      updated_at: now,
      "businessModel/subscription/status": "expired",
      "businessModel/commissionExempt": false,
      "businessModel/commission_exempt": false,
      "businessModel/effectiveModel": "commission",
    });
    return { exempt: false, reason: "expired" };
  }
  if (activeSubscription) {
    return { exempt: true, reason: "subscription", expiresAt };
  }
  return { exempt: false, reason: commissionExempt ? "expired" : "not_subscribed", expiresAt };
}

module.exports = {
  resolveDriverMonetization,
  resolveCommissionPolicy,
};
