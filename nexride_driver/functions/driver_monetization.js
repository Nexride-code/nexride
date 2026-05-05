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
  const isSubscription = selectedModel === "subscription";
  return {
    selectedModel,
    effectiveModel,
    isSubscription,
    source: "drivers_business_model",
  };
}

module.exports = {
  resolveDriverMonetization,
};
