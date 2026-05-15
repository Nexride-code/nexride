/**
 * Central admin audit trail for RTDB `admin_audit_logs/{logId}`.
 *
 * Schema (success rows):
 * - log_id, actor_uid, actor_email, action, entity_type, entity_id,
 *   before, after, reason, source, created_at
 * - type: legacy display key (often `admin_<action>`) for older UIs
 */

"use strict";

const { logger } = require("firebase-functions");
const { getAuth } = require("firebase-admin/auth");
const adminPerms = require("./admin_permissions");

function nowMs() {
  return Date.now();
}

function normUid(uid) {
  return String(uid ?? "").trim();
}

/**
 * @param {unknown} obj
 * @param {number} maxBytes
 * @returns {unknown}
 */
function slimJson(obj, maxBytes) {
  if (obj == null) {
    return null;
  }
  try {
    let s = JSON.stringify(obj);
    if (Buffer.byteLength(s, "utf8") <= maxBytes) {
      return JSON.parse(s);
    }
    let lo = 0;
    let hi = s.length;
    while (lo < hi) {
      const mid = Math.floor((lo + hi + 1) / 2);
      const chunk = s.slice(0, mid);
      if (Buffer.byteLength(chunk, "utf8") <= maxBytes) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return {
      _truncated: true,
      approx_bytes: Buffer.byteLength(s, "utf8"),
      preview: s.slice(0, lo),
    };
  } catch (e) {
    return { _error: String(e?.message || e) };
  }
}

/**
 * @param {import("firebase-admin/database").Database} db
 * @param {{
 *   actor_uid?: string|null,
 *   actor_email?: string|null,
 *   action: string,
 *   entity_type?: string|null,
 *   entity_id?: string|null,
 *   before?: unknown,
 *   after?: unknown,
 *   reason?: string|null,
 *   source?: string|null,
 *   created_at?: number,
 *   type?: string|null,
 * }} params
 * @returns {Promise<string>} log id
 */
async function writeAdminAuditLog(db, params) {
  const ref = db.ref("admin_audit_logs").push();
  const logId = ref.key;
  const actorUid = normUid(params.actor_uid);
  let actorEmail = params.actor_email != null ? String(params.actor_email).trim().slice(0, 320) : "";
  if (!actorEmail && actorUid) {
    try {
      const u = await getAuth().getUser(actorUid);
      actorEmail = String(u.email ?? "").trim().slice(0, 320);
    } catch (_) {
      actorEmail = "";
    }
  }
  const createdAt =
    typeof params.created_at === "number" && Number.isFinite(params.created_at)
      ? params.created_at
      : nowMs();
  const action = String(params.action ?? "").trim().slice(0, 120) || "unknown_action";
  const legacyType =
    params.type != null && String(params.type).trim()
      ? String(params.type).trim().slice(0, 160)
      : `admin_${action}`.replace(/^admin_admin_/, "admin_");

  const row = {
    log_id: logId,
    actor_uid: actorUid || null,
    actor_email: actorEmail || null,
    action,
    entity_type:
      params.entity_type == null
        ? null
        : String(params.entity_type).trim().slice(0, 64) || null,
    entity_id:
      params.entity_id == null ? null : String(params.entity_id).trim().slice(0, 256) || null,
    before: slimJson(params.before, 20000),
    after: slimJson(params.after, 20000),
    reason: params.reason == null ? null : String(params.reason).trim().slice(0, 2000),
    source: String(params.source ?? "callable").trim().slice(0, 128),
    created_at: createdAt,
    type: legacyType,
  };

  await ref.set(row);
  logger.info("[AdminAuditLog]", { logId, action, entity_type: row.entity_type });
  return logId;
}

/**
 * Maps historical `writeAdminAudit(db, { type, ... })` payloads to unified rows.
 * @param {Record<string, unknown>} entry
 */
function fromLegacyAuditEntry(entry) {
  const e = entry && typeof entry === "object" ? entry : {};
  const actor_uid = normUid(e.actor_uid ?? e.admin_uid) || null;
  const created_at = Number(e.created_at) || nowMs();
  const type = String(e.type ?? "admin_audit").trim();
  const action = type.startsWith("admin_") ? type.slice(6) : type;
  let entity_type = e.entity_type != null ? String(e.entity_type).trim() : null;
  let entity_id = e.entity_id != null ? String(e.entity_id).trim() : null;
  if (!entity_id) {
    if (e.driver_id) {
      entity_type = entity_type || "driver";
      entity_id = String(e.driver_id).trim();
    } else if (e.uid) {
      const role = String(e.role ?? "").trim().toLowerCase();
      entity_type = entity_type || (role === "rider" ? "rider" : "driver");
      entity_id = String(e.uid).trim();
    } else if (e.merchant_id) {
      entity_type = "merchant";
      entity_id = String(e.merchant_id).trim();
    } else if (e.rider_id) {
      entity_type = "rider";
      entity_id = String(e.rider_id).trim();
    } else if (e.trip_id || e.tripId) {
      entity_type = "trip";
      entity_id = String(e.trip_id ?? e.tripId).trim();
    } else if (e.withdrawalId || e.withdrawal_id) {
      entity_type = "withdrawal";
      entity_id = String(e.withdrawalId ?? e.withdrawal_id).trim();
    }
  }
  const reason =
    e.reason ??
    e.note ??
    e.message ??
    e.admin_note ??
    e.reject_reason ??
    e.rejection_reason ??
    null;
  const copy = { ...e };
  delete copy.actor_uid;
  delete copy.admin_uid;
  delete copy.created_at;
  return {
    actor_uid,
    actor_email: e.actor_email != null ? String(e.actor_email).trim().slice(0, 320) : null,
    action,
    entity_type,
    entity_id,
    before: null,
    after: slimJson(copy, 12000),
    reason: reason == null ? null : String(reason).trim().slice(0, 2000),
    source: "legacy_mapper",
    created_at,
    type,
  };
}

/**
 * @param {object} data
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} db
 */
async function adminListAuditLogs(data, context, db) {
  const denyAl = await adminPerms.enforceCallable(db, context, "adminListAuditLogs");
  if (denyAl) return denyAl;
  const limit = Math.min(Math.max(Number(data?.limit) || 200, 1), 800);
  const actionFilter = String(data?.action ?? "").trim().toLowerCase();
  const entityTypeFilter = String(data?.entity_type ?? data?.entityType ?? "")
    .trim()
    .toLowerCase();
  const actorEmailFilter = String(data?.actor_email ?? data?.actorEmail ?? "")
    .trim()
    .toLowerCase();
  const fromMs = Number(data?.from_ms ?? data?.fromMs ?? 0) || 0;
  const toMs = Number(data?.to_ms ?? data?.toMs ?? 0) || 0;

  const snap = await db.ref("admin_audit_logs").orderByKey().limitToLast(Math.min(limit * 4, 2000)).get();
  const val = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  /** @type {Array<Record<string, unknown>>} */
  const rows = [];
  for (const [k, v] of Object.entries(val)) {
    if (!v || typeof v !== "object") continue;
    const row = { log_id: v.log_id ?? k, id: k, ...v };
    const ts = Number(row.created_at) || 0;
    if (fromMs > 0 && ts > 0 && ts < fromMs) continue;
    if (toMs > 0 && ts > 0 && ts > toMs) continue;
    const act = String(row.action ?? row.type ?? "").toLowerCase();
    if (actionFilter && !act.includes(actionFilter)) continue;
    const et = String(row.entity_type ?? "").toLowerCase();
    if (entityTypeFilter && et !== entityTypeFilter) continue;
    const em = String(row.actor_email ?? "").toLowerCase();
    if (actorEmailFilter && !em.includes(actorEmailFilter)) continue;
    rows.push(row);
  }
  rows.sort((a, b) => (Number(b.created_at) || 0) - (Number(a.created_at) || 0));
  const trimmed = rows.slice(0, limit);
  return {
    success: true,
    reason: "ok",
    logs: trimmed,
    meta: { count: trimmed.length, scanned: rows.length },
  };
}

module.exports = {
  writeAdminAuditLog,
  fromLegacyAuditEntry,
  adminListAuditLogs,
  slimJson,
};
