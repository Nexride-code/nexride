"use strict";

const crypto = require("crypto");
const admin = require("firebase-admin");
const { FieldValue } = require("firebase-admin/firestore");
const { normUid } = require("./admin_auth");
const { writeAdminAuditLog } = require("./admin_audit_log");

const DEFAULT_INVITE_MAX_REDEMPTIONS = 50;
const FLEET_SUSPENDED_MESSAGE =
  "Your fleet account is suspended. Contact your fleet owner.";
const ACCOUNT_KIND_DISPATCH_FLEET = "dispatch_fleet";

function nowMs() {
  return Date.now();
}

function trimStr(v, max = 200) {
  return String(v ?? "").trim().slice(0, max);
}

function normalizeOwnershipMode(v) {
  const s = trimStr(v, 64).toLowerCase();
  if (s === "business_managed" || s === "individual") {
    return s;
  }
  return "";
}

function merchantStatusOf(m) {
  return trimStr(m?.merchant_status ?? m?.status, 40).toLowerCase();
}

function accountStatusOf(m) {
  return trimStr(m?.account_status ?? m?.accountStatus, 40).toLowerCase();
}

function isDispatchFleetAccount(m) {
  return (
    trimStr(m?.account_kind ?? m?.accountKind, 64).toLowerCase() ===
    ACCOUNT_KIND_DISPATCH_FLEET
  );
}

/**
 * Normalize invite status; legacy `pending` → active, legacy `redeemed` → expired.
 * @param {Record<string, unknown> | null | undefined} row
 */
function normalizeInviteStatus(row) {
  const s = trimStr(row?.status, 40).toLowerCase();
  if (!s || s === "pending") {
    return "active";
  }
  if (s === "redeemed") {
    return "expired";
  }
  if (s === "active" || s === "revoked" || s === "expired") {
    return s;
  }
  return s;
}

/**
 * @param {Record<string, unknown> | null | undefined} row
 */
function inviteMaxRedemptions(row) {
  const explicit = Number(row?.max_redemptions ?? row?.maxRedemptions ?? NaN);
  if (Number.isFinite(explicit) && explicit >= 1) {
    return Math.floor(explicit);
  }
  const legacyStatus = trimStr(row?.status, 40).toLowerCase();
  const legacyRedeemedBy = row?.redeemed_by;
  if (legacyStatus === "redeemed") {
    return 1;
  }
  if (typeof legacyRedeemedBy === "string" && normUid(legacyRedeemedBy)) {
    return 1;
  }
  return DEFAULT_INVITE_MAX_REDEMPTIONS;
}

/**
 * @param {Record<string, unknown> | null | undefined} row
 */
function inviteRedemptionCount(row) {
  const explicit = Number(row?.redemption_count ?? row?.redemptionCount ?? NaN);
  if (Number.isFinite(explicit) && explicit >= 0) {
    return Math.floor(explicit);
  }
  const map = inviteRedeemedByMap(row);
  return Object.keys(map).length;
}

/**
 * @param {Record<string, unknown> | null | undefined} row
 * @returns {Record<string, { redeemed_at?: number, driver_uid?: string }>}
 */
function inviteRedeemedByMap(row) {
  const rb = row?.redeemed_by ?? row?.redeemedBy;
  if (rb && typeof rb === "object" && !Array.isArray(rb)) {
    return rb;
  }
  if (typeof rb === "string") {
    const uid = normUid(rb);
    if (!uid) {
      return {};
    }
    return {
      [uid]: {
        driver_uid: uid,
        redeemed_at: Number(row?.redeemed_at ?? row?.redeemedAt ?? 0) || nowMs(),
      },
    };
  }
  return {};
}

/**
 * @param {Record<string, unknown> | null | undefined} row
 * @param {number} [now]
 */
function isInviteRedeemable(row, now = nowMs()) {
  if (!row || typeof row !== "object") {
    return { ok: false, reason: "invalid_invite" };
  }
  const max = inviteMaxRedemptions(row);
  const count = inviteRedemptionCount(row);
  if (count >= max) {
    return { ok: false, reason: "invite_max_redemptions" };
  }
  const status = normalizeInviteStatus(row);
  if (status === "revoked") {
    return { ok: false, reason: "invite_revoked" };
  }
  if (status === "expired") {
    return { ok: false, reason: "invite_expired" };
  }
  const expiresAt = Number(row.expires_at ?? row.expiresAt ?? 0);
  if (!(expiresAt > now)) {
    return { ok: false, reason: "invite_expired" };
  }
  return { ok: true, max_redemptions: max, redemption_count: count };
}

/**
 * @param {Record<string, unknown> | null | undefined} m
 */
function fleetMerchantBlocksLinkedDriver(m) {
  if (!m || typeof m !== "object") {
    return { blocked: true, reason: "fleet_not_found" };
  }
  if (!isDispatchFleetAccount(m)) {
    return { blocked: true, reason: "not_dispatch_fleet" };
  }
  const ms = merchantStatusOf(m);
  const acct = accountStatusOf(m);
  if (ms === "suspended" || ms === "deleted" || ms === "disabled") {
    return { blocked: true, reason: "fleet_suspended" };
  }
  if (acct === "suspended" || acct === "deleted" || acct === "disabled") {
    return { blocked: true, reason: "fleet_suspended" };
  }
  if (ms !== "approved") {
    return { blocked: true, reason: "fleet_not_approved" };
  }
  return { blocked: false };
}

function isActiveLinkStatus(statusRaw) {
  const s = trimStr(statusRaw, 40).toLowerCase();
  return !s || s === "active" || s === "approved";
}

/**
 * @param {Record<string, unknown> | null | undefined} profile
 */
function isDriverLinkedToActiveFleet(profile) {
  const p = profile && typeof profile === "object" ? profile : {};
  const mode = normalizeOwnershipMode(p.ownership_mode ?? p.ownershipMode);
  const businessId = trimStr(p.business_id ?? p.businessId, 128);
  const linkStatus = trimStr(p.business_link_status ?? p.businessLinkStatus, 40).toLowerCase();
  if (mode !== "business_managed" || !businessId) {
    return false;
  }
  if (linkStatus === "removed") {
    return false;
  }
  return isActiveLinkStatus(linkStatus);
}

/**
 * @param {Record<string, unknown> | null | undefined} profile
 * @param {string} targetBusinessId
 */
function driverHasConflictingFleetLink(profile, targetBusinessId) {
  const p = profile && typeof profile === "object" ? profile : {};
  if (!isDriverLinkedToActiveFleet(p)) {
    return false;
  }
  const existingBusinessId = trimStr(p.business_id ?? p.businessId, 128);
  return Boolean(existingBusinessId && existingBusinessId !== targetBusinessId);
}

/**
 * @param {import("firebase-admin/database").Database} db
 * @param {import("firebase-admin/firestore").Firestore} fs
 * @param {string} driverId
 * @param {Record<string, unknown>} [profileOverride]
 */
/** @type {import("firebase-admin/firestore").Firestore | null} */
let firestoreOverrideForTests = null;

function resolveFirestoreClient(fsOverride) {
  return fsOverride || firestoreOverrideForTests || admin.firestore();
}

/** @param {import("firebase-admin/firestore").Firestore | null} fs */
function setFirestoreForTests(fs) {
  firestoreOverrideForTests = fs;
}

async function assertFleetLinkedDriverCanOperate(db, fs, driverId, profileOverride) {
  const d = normUid(driverId);
  if (!d) {
    return { ok: false, reason: "unauthorized" };
  }
  let profile = profileOverride;
  if (!profile) {
    const snap = await db.ref(`drivers/${d}`).get();
    profile = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  }
  if (!isDriverLinkedToActiveFleet(profile)) {
    return { ok: true };
  }
  const businessId = trimStr(profile.business_id ?? profile.businessId, 128);
  const fsClient = resolveFirestoreClient(fs);
  if (!businessId || !fsClient) {
    return { ok: false, reason: "fleet_not_found", message: FLEET_SUSPENDED_MESSAGE };
  }
  try {
    const snap = await fsClient.collection("merchants").doc(businessId).get();
    if (!snap.exists) {
      return { ok: false, reason: "fleet_not_found", message: FLEET_SUSPENDED_MESSAGE };
    }
    const gate = fleetMerchantBlocksLinkedDriver(snap.data() || {});
    if (gate.blocked) {
      return {
        ok: false,
        reason: gate.reason || "fleet_suspended",
        message: FLEET_SUSPENDED_MESSAGE,
      };
    }
    return { ok: true, business_id: businessId };
  } catch (_err) {
    return { ok: false, reason: "fleet_read_failed", message: FLEET_SUSPENDED_MESSAGE };
  }
}

function driverDisplayNameFromProfile(d, user) {
  const drv = d && typeof d === "object" ? d : {};
  const u = user && typeof user === "object" ? user : {};
  const display = trimStr(
    drv.display_name ??
      drv.displayName ??
      u.display_name ??
      u.displayName ??
      u.name,
    120,
  );
  if (display) {
    return display;
  }
  const first = trimStr(drv.first_name ?? drv.firstName ?? u.first_name ?? u.firstName, 64);
  const last = trimStr(drv.last_name ?? drv.lastName ?? u.last_name ?? u.lastName, 64);
  const joined = [first, last].filter(Boolean).join(" ");
  return joined || trimStr(drv.name ?? drv.driver_name, 120) || null;
}

/**
 * Attach fleet + biker trust fields for rider/share surfaces.
 * @param {import("firebase-admin/database").Database} db
 * @param {import("firebase-admin/firestore").Firestore} fs
 * @param {string} driverId
 * @param {Record<string, unknown>} [driverProfile]
 */
async function buildFleetDeliveryTrustPatch(db, fs, driverId, driverProfile) {
  const d = normUid(driverId);
  if (!d) {
    return {};
  }
  let drv =
    driverProfile && typeof driverProfile === "object"
      ? driverProfile
      : null;
  if (!drv) {
    const snap = await db.ref(`drivers/${d}`).get();
    drv = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  }
  if (!isDriverLinkedToActiveFleet(drv)) {
    return {};
  }
  const fleetBusinessId = trimStr(drv.business_id ?? drv.businessId, 128);
  if (!fleetBusinessId || !fs) {
    return {};
  }
  let fleetDoc = null;
  try {
    const snap = await fs.collection("merchants").doc(fleetBusinessId).get();
    fleetDoc = snap.exists ? snap.data() || {} : null;
  } catch (_err) {
    fleetDoc = null;
  }
  const fleetBusinessName =
    trimStr(
      drv.business_name ??
        drv.businessName ??
        fleetDoc?.business_name ??
        fleetDoc?.businessName,
      200,
    ) || null;
  const ownerUid = normUid(fleetDoc?.owner_uid ?? fleetDoc?.ownerUid);
  let ownerName = null;
  let ownerPhone = null;
  if (ownerUid) {
    const ownerSnap = await db.ref(`users/${ownerUid}`).get();
    const owner = ownerSnap.val() && typeof ownerSnap.val() === "object" ? ownerSnap.val() : {};
    ownerName = driverDisplayNameFromProfile(owner, owner);
    ownerPhone = trimStr(owner.phone ?? owner.phone_number, 32) || null;
  }
  const userSnap = await db.ref(`users/${d}`).get();
  const user = userSnap.val() && typeof userSnap.val() === "object" ? userSnap.val() : {};
  const driverName = driverDisplayNameFromProfile(drv, user);
  const driverPhone = trimStr(
    drv.phone ??
      drv.phone_number ??
      drv.driver_phone ??
      user.phone ??
      user.phone_number,
    32,
  );
  const vehicle = trimStr(
    drv.dispatch_vehicle_type ?? drv.dispatchVehicleType ?? drv.vehicle_type,
    64,
  );
  const photoRaw = trimStr(
    drv.photo_url ?? drv.profile_photo_url ?? user.photo_url ?? user.profile_photo_url,
    512,
  );
  return {
    assigned_driver_id: d,
    assigned_driver_name: driverName || null,
    assigned_driver_phone: driverPhone || null,
    assigned_driver_vehicle: vehicle || null,
    assigned_driver_photo_url: photoRaw.startsWith("https://") ? photoRaw : null,
    fleet_business_id: fleetBusinessId,
    fleet_business_name: fleetBusinessName,
    fleet_owner_uid: ownerUid || null,
    fleet_owner_name: ownerName,
    fleet_owner_phone: ownerPhone,
    fleet_accountability_enabled: true,
  };
}

async function writeFleetAuditLog(db, businessId, entry) {
  const bid = trimStr(businessId, 128);
  if (!bid) {
    return null;
  }
  const logId = db.ref(`fleet_audit_logs/${bid}`).push().key || crypto.randomBytes(8).toString("hex");
  const row = {
    ...entry,
    business_id: bid,
    created_at: Number(entry?.created_at ?? 0) || nowMs(),
  };
  await db.ref(`fleet_audit_logs/${bid}/${logId}`).set(row);
  return logId;
}

/**
 * @param {import("firebase-admin/database").Database} db
 * @param {import("firebase-admin/firestore").Firestore} fs
 * @param {object} opts
 */
async function unlinkFleetDriver(db, fs, opts) {
  const businessId = trimStr(opts.businessId ?? opts.business_id, 128);
  const driverId = normUid(opts.driverId ?? opts.driver_uid ?? opts.driver_id);
  const actorUid = normUid(opts.actorUid ?? opts.actor_uid);
  const source = trimStr(opts.source, 120) || "fleet_driver_accountability.unlinkFleetDriver";
  const reason = trimStr(opts.reason, 200) || "driver_unlinked";
  if (!businessId || !driverId || !actorUid) {
    return { success: false, reason: "invalid_input" };
  }

  const driverSnap = await db.ref(`drivers/${driverId}`).get();
  const driver = driverSnap.val() && typeof driverSnap.val() === "object" ? driverSnap.val() : {};
  const linkedBusinessId = trimStr(driver.business_id ?? driver.businessId, 128);
  if (linkedBusinessId && linkedBusinessId !== businessId) {
    return { success: false, reason: "driver_not_linked_to_fleet" };
  }

  const now = nowMs();
  const linkSnap = await db.ref(`business_driver_links/${businessId}/${driverId}`).get();
  const linkBefore =
    linkSnap.val() && typeof linkSnap.val() === "object" ? linkSnap.val() : null;

  const updates = {
    [`business_driver_links/${businessId}/${driverId}/status`]: "removed",
    [`business_driver_links/${businessId}/${driverId}/removed_at`]: now,
    [`business_driver_links/${businessId}/${driverId}/removed_by`]: actorUid,
    [`business_driver_links/${businessId}/${driverId}/updated_at`]: now,
    [`drivers/${driverId}/ownership_mode`]: "independent",
    [`drivers/${driverId}/business_link_status`]: "removed",
    [`drivers/${driverId}/business_id`]: null,
    [`drivers/${driverId}/business_name`]: null,
    [`drivers/${driverId}/linked_by_invite_code`]: null,
    [`drivers/${driverId}/updated_at`]: now,
  };
  await db.ref().update(updates);

  await writeAdminAuditLog(db, {
    actor_uid: actorUid,
    action: "fleet_driver_unlinked",
    entity_type: "driver",
    entity_id: driverId,
    before: {
      business_id: linkedBusinessId || businessId,
      ownership_mode: driver.ownership_mode ?? null,
      business_link_status: driver.business_link_status ?? null,
      link_status: linkBefore?.status ?? null,
    },
    after: {
      ownership_mode: "independent",
      business_link_status: "removed",
      business_id: null,
    },
    reason,
    source,
    type: "FLEET_DRIVER_UNLINKED",
  });

  await writeFleetAuditLog(db, businessId, {
    action: "driver_unlinked",
    driver_uid: driverId,
    actor_uid: actorUid,
    reason,
    source,
  });

  return { success: true, business_id: businessId, driver_id: driverId };
}

/**
 * @param {import("firebase-admin/database").Database} db
 * @param {import("firebase-admin/firestore").Firestore} fs
 * @param {object} opts
 */
async function recordFleetLinkedDeliveryIncident(db, fs, opts) {
  const deliveryId = trimStr(opts.deliveryId ?? opts.delivery_id, 128);
  const driverId = normUid(opts.driverId ?? opts.driver_uid ?? opts.driver_id);
  const riderUid = normUid(opts.riderUid ?? opts.rider_uid ?? opts.customer_id);
  const issueType = trimStr(opts.issueType ?? opts.issue_type ?? opts.reason, 80) || "delivery_report";
  const severity = trimStr(opts.severity, 40).toLowerCase() || "normal";
  const description = trimStr(opts.description ?? opts.message, 2000);
  const actorUid = normUid(opts.actorUid ?? opts.actor_uid);
  const ticketId = trimStr(opts.ticketId ?? opts.support_ticket_id, 128) || null;
  if (!deliveryId || !driverId) {
    return { success: false, reason: "invalid_input" };
  }

  const driverSnap = await db.ref(`drivers/${driverId}`).get();
  const driver = driverSnap.val() && typeof driverSnap.val() === "object" ? driverSnap.val() : {};
  if (!isDriverLinkedToActiveFleet(driver)) {
    return { success: false, reason: "not_fleet_linked", skipped: true };
  }

  const businessId = trimStr(driver.business_id ?? driver.businessId, 128);
  if (!businessId) {
    return { success: false, reason: "missing_business_id", skipped: true };
  }

  let businessName = trimStr(driver.business_name ?? driver.businessName, 200);
  if (!businessName && fs) {
    try {
      const snap = await fs.collection("merchants").doc(businessId).get();
      businessName = trimStr(
        snap.data()?.business_name ?? snap.data()?.businessName,
        200,
      );
    } catch (_err) {
      /* ignore */
    }
  }

  const userSnap = await db.ref(`users/${driverId}`).get();
  const user = userSnap.val() && typeof userSnap.val() === "object" ? userSnap.val() : {};
  const driverName = driverDisplayNameFromProfile(driver, user) || driverId;
  const now = nowMs();
  const incidentId =
    db.ref(`fleet_incidents/${businessId}`).push().key || crypto.randomBytes(8).toString("hex");

  const incident = {
    incident_id: incidentId,
    business_id: businessId,
    business_name: businessName || null,
    driver_uid: driverId,
    driver_name: driverName,
    delivery_id: deliveryId,
    rider_uid: riderUid || null,
    issue_type: issueType,
    severity,
    description: description || null,
    created_at: now,
    status: "open",
    support_ticket_id: ticketId,
    fine_amount_ngn: null,
    reported_by: actorUid || riderUid || null,
  };

  await db.ref(`fleet_incidents/${businessId}/${incidentId}`).set(incident);
  await db.ref(`driver_incidents/${driverId}/${incidentId}`).set({
    ...incident,
    fleet_incident_path: `fleet_incidents/${businessId}/${incidentId}`,
  });

  await writeAdminAuditLog(db, {
    actor_uid: actorUid || riderUid || "system",
    action: "fleet_delivery_incident_created",
    entity_type: "fleet_incident",
    entity_id: incidentId,
    after: incident,
    reason: issueType,
    source: "fleet_driver_accountability.recordFleetLinkedDeliveryIncident",
    type: "FLEET_DELIVERY_INCIDENT_CREATED",
  });

  await writeFleetAuditLog(db, businessId, {
    action: "delivery_incident_created",
    incident_id: incidentId,
    driver_uid: driverId,
    delivery_id: deliveryId,
    issue_type: issueType,
    actor_uid: actorUid || riderUid || null,
  });

  let ownerUid = null;
  if (fs) {
    try {
      const merchantSnap = await fs.collection("merchants").doc(businessId).get();
      ownerUid = normUid(
        merchantSnap.data()?.owner_uid ?? merchantSnap.data()?.ownerUid,
      );
    } catch (_err) {
      /* ignore */
    }
  }

  return {
    success: true,
    incident_id: incidentId,
    business_id: businessId,
    driver_id: driverId,
    fleet_owner_uid: ownerUid || null,
    incident,
  };
}

/**
 * @param {import("firebase-admin/firestore").Firestore} fs
 * @param {import("firebase-admin/database").Database} db
 * @param {object} opts
 */
async function applyFleetRatingForDelivery(fs, db, opts) {
  const businessId = trimStr(opts.businessId ?? opts.business_id ?? opts.fleetBusinessId, 128);
  const driverId = normUid(opts.driverId ?? opts.driver_uid);
  const deliveryId = trimStr(opts.deliveryId ?? opts.delivery_id, 128);
  const rating = Math.round(Number(opts.rating ?? 0));
  const riderUid = normUid(opts.riderUid ?? opts.rider_uid);
  if (!businessId || !driverId || rating < 1 || rating > 5) {
    return { success: false, reason: "invalid_input" };
  }

  const now = nowMs();
  const ratingId =
    db.ref(`fleet_ratings/${businessId}`).push().key || crypto.randomBytes(8).toString("hex");
  const ledgerRow = {
    rating_id: ratingId,
    business_id: businessId,
    driver_uid: driverId,
    delivery_id: deliveryId || null,
    rider_uid: riderUid || null,
    rating,
    created_at: now,
  };
  await db.ref(`fleet_ratings/${businessId}/${ratingId}`).set(ledgerRow);

  const merchantRef = fs.collection("merchants").doc(businessId);
  await fs.runTransaction(async (tx) => {
    const snap = await tx.get(merchantRef);
    const prior = snap.exists ? snap.data() || {} : {};
    const priorCount = Number(prior.fleet_rating_count ?? 0);
    const priorAvg = Number(prior.fleet_rating_avg ?? 0);
    const count = priorCount + 1;
    const sum = priorAvg * priorCount + rating;
    const avg = Math.round((sum / count) * 10) / 10;
    tx.set(
      merchantRef,
      {
        fleet_rating_avg: avg,
        fleet_rating_count: count,
        fleet_last_rating_at: now,
      },
      { merge: true },
    );
  });

  return { success: true, rating_id: ratingId, business_id: businessId };
}

module.exports = {
  DEFAULT_INVITE_MAX_REDEMPTIONS,
  FLEET_SUSPENDED_MESSAGE,
  normalizeInviteStatus,
  inviteMaxRedemptions,
  inviteRedemptionCount,
  inviteRedeemedByMap,
  isInviteRedeemable,
  fleetMerchantBlocksLinkedDriver,
  isActiveLinkStatus,
  isDriverLinkedToActiveFleet,
  driverHasConflictingFleetLink,
  assertFleetLinkedDriverCanOperate,
  buildFleetDeliveryTrustPatch,
  unlinkFleetDriver,
  recordFleetLinkedDeliveryIncident,
  applyFleetRatingForDelivery,
  writeFleetAuditLog,
  setFirestoreForTests,
  resolveFirestoreClient,
  driverDisplayNameFromProfile,
};
