/**
 * Production driver offer eligibility — mirrors Flutter driver_verification_restrictions loosely.
 */

function normUid(uid) {
  return String(uid ?? "").trim();
}

function boolTrue(v) {
  return v === true || v === "true" || v === 1 || v === "1";
}

function canonicalMarketSlug(raw) {
  return String(raw ?? "")
    .trim()
    .toLowerCase()
    .replace(/\s+/g, "_")
    .replace(/-+/g, "_");
}

/**
 * Stabilization mode: no verification / subscription / BVN gates.
 * Requires session online + market alignment + optional status/dispatch_state.
 * @returns {{ ok: true } | { ok: false, log: string, detail: string }}
 */
function evaluateDriverForOfferSoft(driverProfile, ridePayload) {
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
  const rideM = canonicalMarketSlug(
    ridePayload.market_pool ?? ridePayload.market ?? "",
  );
  if (!rideM) {
    return { ok: false, log: "NO_RIDE_MARKET", detail: "missing" };
  }
  const dm = canonicalMarketSlug(d.dispatch_market ?? "");
  const mm = canonicalMarketSlug(d.market ?? "");
  const mp = canonicalMarketSlug(d.market_pool ?? "");
  const city = canonicalMarketSlug(d.city ?? d.launch_market_city ?? "");
  const marketOk =
    (dm && dm === rideM) ||
    (mm && mm === rideM) ||
    (mp && mp === rideM) ||
    (city && city === rideM);
  if (!marketOk) {
    return { ok: false, log: "DRIVER_FILTERED_MARKET_SOFT", detail: "market_mismatch" };
  }
  const online =
    d.isOnline === true || d.is_online === true || d.online === true;
  if (!online) {
    return { ok: false, log: "NOT_ONLINE", detail: "session_off" };
  }
  const st = String(d.status ?? "").trim().toLowerCase();
  if (st && st !== "available") {
    return { ok: false, log: "STATUS_NOT_AVAILABLE", detail: st };
  }
  const ds = String(d.dispatch_state ?? "").trim().toLowerCase();
  if (ds && ds !== "available") {
    return { ok: false, log: "DISPATCH_STATE_NOT_AVAILABLE", detail: ds };
  }
  return { ok: true };
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
    .toLowerCase()
    .replace(/\s+/g, "_")
    .replace(/-+/g, "_");
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
    const gates = {
      soft_verification: boolTrue(g.soft_verification),
      require_bvn: boolTrue(g.require_bvn_verification),
    };
    console.log(
      "DISPATCH_GATES_LOADED",
      `soft_verification=${gates.soft_verification}`,
      `require_bvn_verification=${gates.require_bvn}`,
      `app_config_path=app_config/nexride_dispatch`,
      `exists=${snap.exists()}`,
    );
    return gates;
  } catch (e) {
    console.warn(
      "DISPATCH_GATES_LOAD_FAIL",
      e && typeof e === "object" && "message" in e ? e.message : e,
    );
    return { soft_verification: false, require_bvn: false };
  }
}

/**
 * Snapshot fields for MATCH_DRIVER_CANDIDATE / debug logs (must match ride_callables fanout filters).
 * @param {string} driverId
 * @param {Record<string, unknown>} profile
 */
function summarizeDriverForFanout(driverId, profile) {
  const d = profile && typeof profile === "object" ? profile : {};
  const online =
    d.isOnline === true || d.is_online === true || d.online === true;
  const is_online = boolTrue(d.is_online) || boolTrue(d.isOnline);
  const suspended =
    boolTrue(d.suspended) ||
    boolTrue(d.account_suspended) ||
    String(d.driver_status ?? "")
      .trim()
      .toLowerCase() === "suspended";
  const dm = String(d.dispatch_market ?? d.market_pool ?? d.market ?? "")
    .trim()
    .toLowerCase()
    .replace(/\s+/g, "_")
    .replace(/-+/g, "_");
  const status = String(d.status ?? "").trim().toLowerCase();
  const dispatchState = String(d.dispatch_state ?? "").trim().toLowerCase();
  const approved =
    boolTrue(d.nexride_verified) || hasApprovedDocuments(d.verification);
  const market_pool = String(d.market_pool ?? "")
    .trim()
    .toLowerCase()
    .replace(/\s+/g, "_")
    .replace(/-+/g, "_");
  const market = String(d.market ?? "")
    .trim()
    .toLowerCase()
    .replace(/\s+/g, "_")
    .replace(/-+/g, "_");
  const city = String(d.city ?? "").trim();
  return {
    uid: normUid(driverId),
    dispatch_market: dm || "missing",
    market_pool: market_pool || "(empty)",
    market: market || "(empty)",
    city: city || "(empty)",
    online,
    is_online,
    approved,
    suspended,
    status: status || "(empty)",
    dispatch_state: dispatchState || "(empty)",
  };
}

module.exports = {
  normUid,
  evaluateDriverForOffer,
  evaluateDriverForOfferSoft,
  loadDispatchGates,
  summarizeDriverForFanout,
};
