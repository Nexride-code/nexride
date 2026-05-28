"use strict";

const crypto = require("crypto");
const admin = require("firebase-admin");
const { normUid } = require("./admin_auth");
const { writeAdminAuditLog } = require("./admin_audit_log");
const merchantVerification = require("./merchant/merchant_verification");

const DISPATCH_VEHICLE_TYPES = new Set(["bike", "car", "van"]);
const OWNERSHIP_MODES = new Set(["individual", "business_managed"]);

function nowMs() {
  return Date.now();
}

function trimStr(v, max = 200) {
  return String(v ?? "").trim().slice(0, max);
}

function normalizeDispatchVehicleType(v) {
  const s = trimStr(v, 40).toLowerCase();
  return DISPATCH_VEHICLE_TYPES.has(s) ? s : "";
}

function normalizeOwnershipMode(v) {
  const s = trimStr(v, 64).toLowerCase();
  return OWNERSHIP_MODES.has(s) ? s : "";
}

function buildInviteCode() {
  const raw = crypto.randomBytes(8).toString("hex").toUpperCase();
  return `NXR-${raw}`;
}

function inviteRef(db, inviteCode) {
  return db.ref(`business_driver_invites/${inviteCode}`);
}

function validateDispatchProfileInput(data, opts = {}) {
  const vehicle = normalizeDispatchVehicleType(data?.dispatch_vehicle_type ?? data?.dispatchVehicleType);
  if (!vehicle) {
    return { ok: false, reason: "invalid_dispatch_vehicle_type" };
  }
  const ownership = normalizeOwnershipMode(data?.ownership_mode ?? data?.ownershipMode);
  if (!ownership) {
    return { ok: false, reason: "invalid_ownership_mode" };
  }
  const businessId = trimStr(data?.business_id ?? data?.businessId, 128);
  if (ownership === "business_managed" && !businessId && opts.allowMissingBusinessId !== true) {
    return { ok: false, reason: "business_id_required" };
  }
  if (ownership === "individual" && businessId) {
    return { ok: false, reason: "business_id_not_allowed_for_individual" };
  }
  return {
    ok: true,
    dispatch_vehicle_type: vehicle,
    ownership_mode: ownership,
    business_id: businessId || null,
  };
}

async function businessCreateDriverInvite(data, context, db) {
  if (!context?.auth?.uid) {
    return { success: false, reason: "unauthorized" };
  }
  const fs = admin.firestore();
  const resolved = await merchantVerification.resolveMerchantForMerchantAuth(fs, context);
  if (!resolved.ok) {
    return { success: false, reason: resolved.reason || "forbidden" };
  }
  const actorUid = normUid(context.auth.uid);
  const gate = merchantVerification.assertMerchantPortalAllowed(
    resolved.data || {},
    actorUid,
    ["owner", "manager"],
  );
  if (!gate.ok) {
    return { success: false, reason: gate.reason || "forbidden" };
  }

  const profile = validateDispatchProfileInput(
    {
      dispatch_vehicle_type: data?.dispatch_vehicle_type ?? data?.dispatchVehicleType,
      ownership_mode: "business_managed",
      business_id: resolved.id,
    },
    { allowMissingBusinessId: false },
  );
  if (!profile.ok) {
    return { success: false, reason: profile.reason };
  }

  const code = trimStr(data?.invite_code ?? data?.inviteCode, 64) || buildInviteCode();
  const ttlMs = Number(data?.ttl_ms ?? data?.ttlMs ?? 1000 * 60 * 60 * 24 * 7);
  const expiresAt = nowMs() + Math.max(60 * 1000, Math.min(ttlMs, 1000 * 60 * 60 * 24 * 14));
  const targetDriverId = normUid(data?.driver_id ?? data?.driverId);
  const ref = inviteRef(db, code);
  const existingSnap = await ref.get();
  const existing = existingSnap.val();
  if (existing && typeof existing === "object" && Number(existing.expires_at ?? 0) > nowMs()) {
    return { success: false, reason: "invite_already_exists", invite_code: code };
  }

  const row = {
    invite_code: code,
    business_id: resolved.id,
    owner_uid: actorUid,
    dispatch_vehicle_type: profile.dispatch_vehicle_type,
    ownership_mode: "business_managed",
    target_driver_id: targetDriverId || null,
    status: "pending",
    created_at: nowMs(),
    updated_at: nowMs(),
    expires_at: expiresAt,
    redeemed_by: null,
    redeemed_at: null,
  };
  await ref.set(row);
  await writeAdminAuditLog(db, {
    actor_uid: actorUid,
    action: "business_driver_invite_created",
    entity_type: "business_driver_invite",
    entity_id: code,
    after: row,
    reason: "business_driver_invite_created",
    source: "business_fleet_callables.businessCreateDriverInvite",
    type: "BUSINESS_DRIVER_INVITE_CREATED",
  });
  console.log(
    "BUSINESS_DRIVER_INVITE_CREATED",
    `businessId=${resolved.id}`,
    `inviteCode=${code}`,
    `vehicle=${profile.dispatch_vehicle_type}`,
    `targetDriver=${targetDriverId || ""}`,
  );
  return {
    success: true,
    invite_code: code,
    business_id: resolved.id,
    expires_at: expiresAt,
    dispatch_vehicle_type: profile.dispatch_vehicle_type,
    ownership_mode: "business_managed",
  };
}

async function driverRedeemBusinessInvite(data, context, db) {
  if (!context?.auth?.uid) {
    return { success: false, reason: "unauthorized" };
  }
  const driverId = normUid(context.auth.uid);
  const inviteCode = trimStr(data?.invite_code ?? data?.inviteCode, 64);
  if (!inviteCode) {
    return { success: false, reason: "invalid_invite_code" };
  }
  const ref = inviteRef(db, inviteCode);
  const now = nowMs();
  let invite = null;
  let txReason = "unknown";
  let txAlreadyRedeemedBySameDriver = false;
  const tx = await ref.transaction((cur) => {
    if (!cur || typeof cur !== "object") {
      txReason = "invalid_invite";
      return;
    }
    const expiresAt = Number(cur.expires_at ?? 0);
    if (!(expiresAt > now)) {
      txReason = "invite_expired";
      return;
    }
    const targetDriver = normUid(cur.target_driver_id);
    if (targetDriver && targetDriver !== driverId) {
      txReason = "invite_not_for_driver";
      return;
    }
    const status = trimStr(cur.status, 40).toLowerCase();
    const redeemedBy = normUid(cur.redeemed_by);
    if (status === "redeemed") {
      if (redeemedBy === driverId) {
        txAlreadyRedeemedBySameDriver = true;
        txReason = "already_redeemed_by_same_driver";
        invite = cur;
        return cur;
      }
      txReason = "invite_already_redeemed";
      return;
    }
    const businessId = trimStr(cur.business_id, 128);
    const profile = validateDispatchProfileInput({
      dispatch_vehicle_type: cur.dispatch_vehicle_type,
      ownership_mode: "business_managed",
      business_id: businessId,
    });
    if (!profile.ok) {
      txReason = profile.reason;
      return;
    }
    invite = {
      ...cur,
      status: "redeemed",
      redeemed_by: driverId,
      redeemed_at: now,
      updated_at: now,
    };
    txReason = "redeemed";
    return invite;
  });
  if (!tx.committed) {
    console.log("BUSINESS_DRIVER_LINK_REJECTED", `driverId=${driverId}`, `inviteCode=${inviteCode}`, `reason=${txReason}`);
    await writeAdminAuditLog(db, {
      actor_uid: driverId,
      action: "business_driver_link_rejected",
      entity_type: "business_driver_invite",
      entity_id: inviteCode,
      after: {
        invite_code: inviteCode,
      },
      reason: txReason,
      source: "business_fleet_callables.driverRedeemBusinessInvite",
      type: "BUSINESS_DRIVER_LINK_REJECTED",
    });
    return { success: false, reason: txReason === "unknown" ? "invalid_invite" : txReason };
  }
  if (!invite || typeof invite !== "object") {
    const txVal = tx.snapshot?.val?.();
    invite = txVal && typeof txVal === "object" ? txVal : null;
  }
  if (!invite || typeof invite !== "object") {
    return { success: false, reason: "invalid_invite" };
  }
  const businessId = trimStr(invite.business_id, 128);
  const profile = validateDispatchProfileInput({
    dispatch_vehicle_type: invite.dispatch_vehicle_type,
    ownership_mode: "business_managed",
    business_id: businessId,
  });
  if (!profile.ok) {
    return { success: false, reason: profile.reason };
  }

  const driverSnap = await db.ref(`drivers/${driverId}`).get();
  const existing = driverSnap.val() && typeof driverSnap.val() === "object" ? driverSnap.val() : {};
  const existingBusinessId = trimStr(existing.business_id ?? existing.businessId, 128);
  const existingMode = normalizeOwnershipMode(existing.ownership_mode ?? existing.ownershipMode);
  if (
    existingMode === "business_managed" &&
    existingBusinessId &&
    existingBusinessId !== businessId
  ) {
    console.log(
      "BUSINESS_DRIVER_LINK_REJECTED",
      `driverId=${driverId}`,
      `inviteCode=${inviteCode}`,
      "reason=driver_linked_to_another_business",
    );
    return { success: false, reason: "driver_linked_to_another_business" };
  }
  const alreadyLinked =
    existingMode === "business_managed" &&
    existingBusinessId === businessId &&
    existing.business_link_status === "approved";

  const updates = {
    [`drivers/${driverId}/dispatch_vehicle_type`]: profile.dispatch_vehicle_type,
    [`drivers/${driverId}/ownership_mode`]: "business_managed",
    [`drivers/${driverId}/business_id`]: businessId,
    [`drivers/${driverId}/dispatch_verified`]: Boolean(existing.dispatch_verified === true),
    [`drivers/${driverId}/dispatch_verification_status`]:
      trimStr(existing.dispatch_verification_status, 40) || "pending",
    [`drivers/${driverId}/business_link_status`]: "approved",
    [`drivers/${driverId}/updated_at`]: now,
    [`business_driver_links/${businessId}/${driverId}`]: {
      driver_id: driverId,
      business_id: businessId,
      status: "approved",
      ownership_mode: "business_managed",
      dispatch_vehicle_type: profile.dispatch_vehicle_type,
      linked_at: now,
      linked_by: normUid(invite.owner_uid) || null,
      invite_code: inviteCode,
      updated_at: now,
    },
  };
  await db.ref().update(updates);
  await writeAdminAuditLog(db, {
    actor_uid: driverId,
    action: "business_driver_link_redeemed",
    entity_type: "driver",
    entity_id: driverId,
    before: {
      ownership_mode: existingMode || null,
      business_id: existingBusinessId || null,
      business_link_status: trimStr(existing.business_link_status, 40) || null,
    },
    after: {
      ownership_mode: "business_managed",
      business_id: businessId,
      invite_code: inviteCode,
      target_driver_id: driverId,
      business_link_status: "approved",
      dispatch_vehicle_type: profile.dispatch_vehicle_type,
    },
    reason: "business_driver_link_redeemed",
    source: "business_fleet_callables.driverRedeemBusinessInvite",
    type: "BUSINESS_DRIVER_LINK_REDEEMED",
  });
  console.log(
    "BUSINESS_DRIVER_LINK_REDEEMED",
    `driverId=${driverId}`,
    `businessId=${businessId}`,
    `inviteCode=${inviteCode}`,
    `idempotent=${alreadyLinked}`,
  );
  return {
    success: true,
    reason: alreadyLinked ? "already_linked" : "linked",
    business_id: businessId,
    driver_id: driverId,
    ownership_mode: "business_managed",
    dispatch_vehicle_type: profile.dispatch_vehicle_type,
    idempotent: alreadyLinked || txAlreadyRedeemedBySameDriver,
  };
}

module.exports = {
  DISPATCH_VEHICLE_TYPES,
  OWNERSHIP_MODES,
  normalizeDispatchVehicleType,
  normalizeOwnershipMode,
  validateDispatchProfileInput,
  businessCreateDriverInvite,
  driverRedeemBusinessInvite,
};

