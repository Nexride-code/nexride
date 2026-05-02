/**
 * Production driver offer eligibility — mirrors Flutter driver_verification_restrictions loosely.
 */

function normUid(uid) {
  return String(uid ?? "").trim();
}

function boolTrue(v) {
  return v === true || v === "true" || v === 1 || v === "1";
}

function docEntryApproved(doc) {
  if (!doc || typeof doc !== "object") return false;
  const st = String(
    doc.status ?? doc.verification_status ?? doc.verificationStatus ?? "",
  )
    .trim()
    .toLowerCase();
  return st === "approved" || st === "verified";
}

function hasApprovedDocuments(verificationRoot) {
  const v =
    verificationRoot && typeof verificationRoot === "object" ? verificationRoot : {};
  const docs = v.documents && typeof v.documents === "object" ? v.documents : {};
  return (
    docEntryApproved(docs.nin) &&
    docEntryApproved(docs.drivers_license) &&
    docEntryApproved(docs.vehicle_documents)
  );
}

function bvnApproved(verificationRoot) {
  const v =
    verificationRoot && typeof verificationRoot === "object" ? verificationRoot : {};
  const docs = v.documents && typeof v.documents === "object" ? v.documents : {};
  return docEntryApproved(docs.bvn);
}

/**
 * @returns {{ ok: true } | { ok: false, log: string, detail: string }}
 */
function evaluateDriverForOffer(driverProfile, gates, ridePayload) {
  const d = driverProfile && typeof driverProfile === "object" ? driverProfile : {};

  const suspended =
    boolTrue(d.suspended) ||
    boolTrue(d.account_suspended) ||
    String(d.driver_status ?? "")
      .trim()
      .toLowerCase() === "suspended";
  if (suspended) {
    return { ok: false, log: "DRIVER_FILTERED_SUSPENDED", detail: "suspended" };
  }

  const marketRide = String(
    ridePayload.market_pool ?? ridePayload.market ?? "",
  )
    .trim()
    .toLowerCase();
  const dm = String(d.dispatch_market ?? d.market ?? d.market_pool ?? "")
    .trim()
    .toLowerCase()
    .replace(/\s+/g, "_")
    .replace(/-+/g, "_");
  if (marketRide && dm && marketRide !== dm) {
    return { ok: false, log: "DRIVER_FILTERED_MARKET", detail: "market_pool_mismatch" };
  }

  if (gates.soft_verification === true) {
    return { ok: true };
  }

  if (boolTrue(d.nexride_verified)) {
    const vr = d.verification && typeof d.verification === "object" ? d.verification : {};
    const rest = vr.restrictions && typeof vr.restrictions === "object" ? vr.restrictions : {};
    const svc = String(ridePayload.service_type ?? ridePayload.serviceType ?? "ride").trim();
    const approveSvc = rest[svc];
    if (approveSvc === false) {
      return { ok: false, log: "DRIVER_FILTERED_VERIFICATION", detail: `service_blocked:${svc}` };
    }
    return { ok: true };
  }

  const v = d.verification && typeof d.verification === "object" ? d.verification : {};
  const rest = v.restrictions && typeof v.restrictions === "object" ? v.restrictions : {};

  if (boolTrue(rest.canGoOnline)) {
    const svc = String(ridePayload.service_type ?? ridePayload.serviceType ?? "ride").trim();
    if (rest[svc] === false) {
      return { ok: false, log: "DRIVER_FILTERED_VERIFICATION", detail: `service_blocked:${svc}` };
    }
    return { ok: true };
  }

  if (hasApprovedDocuments(v)) {
    if (gates.require_bvn === true && !bvnApproved(v)) {
      return { ok: false, log: "DRIVER_FILTERED_VERIFICATION", detail: "bvn_required" };
    }
    return { ok: true };
  }

  return { ok: false, log: "DRIVER_FILTERED_VERIFICATION", detail: "documents_incomplete" };
}

async function loadDispatchGates(db) {
  try {
    const snap = await db.ref("app_config/nexride_dispatch").get();
    const g = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
    return {
      soft_verification: boolTrue(g.soft_verification),
      require_bvn: boolTrue(g.require_bvn_verification),
    };
  } catch (_) {
    return { soft_verification: false, require_bvn: false };
  }
}

module.exports = {
  normUid,
  evaluateDriverForOffer,
  loadDispatchGates,
};
