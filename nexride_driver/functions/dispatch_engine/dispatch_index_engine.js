/**
 * Lightweight per-market driver index for fan-out (no full /drivers scans).
 */

"use strict";

const { normalizeDispatchKey } = require("./dispatch_geo_normalizer");

const KNOWN_MARKETS = ["lagos", "abuja_fct", "imo", "edo", "anambra", "delta"];

const { DISPATCH_ONLINE_LOCATION_GRACE_MS } = require("./dispatch_driver_location");

/** Only remove indexed drivers after explicit offline / busy / unavailable — not GPS blips. */
const STALE_INDEX_HEARTBEAT_MS = 12 * 60 * 1000;
const AVAILABLE_STATUSES = new Set(["available", "online_available"]);
const AVAILABLE_DISPATCH_STATES = new Set(["available", "online_available", ""]);

function normUid(uid) {
  return String(uid ?? "").trim();
}

function driverShouldBeInDispatchIndex(profile, onlineRow) {
  const d = profile && typeof profile === "object" ? profile : {};
  const on = onlineRow && typeof onlineRow === "object" ? onlineRow : {};
  const online = d.is_online === true || d.isOnline === true || d.online === true || on.is_online === true;
  if (!online) return false;

  const status = String(d.status ?? on.status ?? "").trim().toLowerCase();
  const dispatchState = String(d.dispatch_state ?? on.dispatch_state ?? "").trim().toLowerCase();
  if (status && !AVAILABLE_STATUSES.has(status)) return false;
  if (dispatchState && !AVAILABLE_DISPATCH_STATES.has(dispatchState)) return false;

  const activeRide = normUid(
    d.activeRideId ?? d.currentRideId ?? d.active_ride_id ?? on.active_ride_id,
  );
  if (activeRide) return false;

  const canonical = normalizeDispatchKey(
    d.canonical_market_id ?? d.dispatch_market_id ?? d.market_pool ?? "",
  );
  if (!canonical) return false;

  return true;
}

/**
 * Clear driver from all known market index buckets, then set the active bucket.
 * @param {import("firebase-admin/database").Database} db
 * @param {string} driverId
 * @param {string} canonicalMarketId
 */
async function syncDispatchIndexForDriver(db, driverId, canonicalMarketId) {
  const d = normUid(driverId);
  const m = normalizeDispatchKey(canonicalMarketId);
  if (!d || !m) return { ok: false, reason: "invalid_input" };

  const updates = {};
  for (const known of KNOWN_MARKETS) {
    updates[`dispatch_index/${known}/${d}`] = null;
  }
  updates[`dispatch_index/${m}/${d}`] = true;
  await db.ref().update(updates);
  console.log("DISPATCH_INDEX_INSERT", `driverId=${d}`, `market=${m}`);
  return { ok: true, market: m };
}

/**
 * @param {import("firebase-admin/database").Database} db
 * @param {string} driverId
 */
async function clearDispatchIndexForDriver(db, driverId) {
  const d = normUid(driverId);
  if (!d) return;
  const updates = {};
  for (const known of KNOWN_MARKETS) {
    updates[`dispatch_index/${known}/${d}`] = null;
  }
  await db.ref().update(updates);
}

/**
 * Remove index entry when driver is offline, busy, blocked, or missing canonical market.
 * @param {import("firebase-admin/database").Database} db
 * @param {string} driverId
 * @param {string} [reason]
 */
async function removeDriverFromDispatchIndexWhenUnavailable(db, driverId, reason = "") {
  const d = normUid(driverId);
  if (!d) return;
  await clearDispatchIndexForDriver(db, d);
  if (reason) {
    console.log("DISPATCH_INDEX_REMOVE", `driverId=${d}`, `reason=${reason}`);
  }
}

/**
 * Load driver profiles for fan-out from dispatch_index/{market} only.
 * @param {import("firebase-admin/database").Database} db
 * @param {string} canonicalMarketId
 */
async function loadDriversFromDispatchIndex(db, canonicalMarketId) {
  const m = normalizeDispatchKey(canonicalMarketId);
  if (!m) return {};

  const indexSnap = await db.ref(`dispatch_index/${m}`).get();
  const index =
    indexSnap.exists() && typeof indexSnap.val() === "object" ? indexSnap.val() : {};
  const driverIds = Object.keys(index).filter((id) => normUid(id));
  if (driverIds.length === 0) {
    return {};
  }

  const [driversSnap, onlineSnap] = await Promise.all([
    db.ref("drivers").get(),
    db.ref("online_drivers").get(),
  ]);
  const allDrivers =
    driversSnap.exists() && typeof driversSnap.val() === "object" ? driversSnap.val() : {};
  const online =
    onlineSnap.exists() && typeof onlineSnap.val() === "object" ? onlineSnap.val() : {};

  const raw = {};
  for (const id of driverIds) {
    const prof = allDrivers[id];
    const on = online[id];
    if (!prof || typeof prof !== "object") continue;
    if (!driverShouldBeInDispatchIndex(prof, on)) continue;
    const dm = normalizeDispatchKey(
      prof.canonical_market_id ??
        prof.dispatch_market_id ??
        prof.dispatch_market ??
        prof.market_pool ??
        "",
    );
    if (dm !== m) continue;
    raw[id] = { ...prof, ...(on && typeof on === "object" ? on : {}) };
  }
  return raw;
}

/**
 * Low-frequency TTL sweep for stale dispatch_index rows.
 * @param {import("firebase-admin/database").Database} db
 */
async function sweepDispatchIndexes(db) {
  const now = Date.now();
  const updates = {};
  let scanned = 0;
  let removed = 0;

  for (const market of KNOWN_MARKETS) {
    const indexSnap = await db.ref(`dispatch_index/${market}`).get();
    const index =
      indexSnap.exists() && typeof indexSnap.val() === "object" ? indexSnap.val() : {};
    for (const driverId of Object.keys(index)) {
      const d = normUid(driverId);
      if (!d) continue;
      scanned += 1;
      let remove = false;
      let removeReason = "stale_index";

      const [profSnap, onSnap] = await Promise.all([
        db.ref(`drivers/${d}`).get(),
        db.ref(`online_drivers/${d}`).get(),
      ]);
      const prof =
        profSnap.exists() && typeof profSnap.val() === "object" ? profSnap.val() : null;
      const on =
        onSnap.exists() && typeof onSnap.val() === "object" ? onSnap.val() : null;

      if (!prof) {
        remove = true;
        removeReason = "driver_missing";
      } else if (!driverShouldBeInDispatchIndex(prof, on)) {
        remove = true;
        const activeRide = normUid(
          prof.activeRideId ?? prof.currentRideId ?? prof.active_ride_id,
        );
        if (activeRide) {
          removeReason = "active_ride";
        } else if (!(prof.is_online === true || prof.online === true)) {
          removeReason = "offline";
        } else {
          const st = String(prof.status ?? "").trim().toLowerCase();
          const ds = String(prof.dispatch_state ?? "").trim().toLowerCase();
          removeReason = `status_${st || ds || "unavailable"}`;
        }
      } else {
        const heartbeat =
          Number(
            prof.last_dispatch_heartbeat ??
              prof.presence_heartbeat_at ??
              prof.online_session_started_at ??
              0,
          ) || 0;
        const inGrace =
          heartbeat > 0 && now - heartbeat <= DISPATCH_ONLINE_LOCATION_GRACE_MS;
        if (!inGrace && heartbeat > 0 && now - heartbeat > STALE_INDEX_HEARTBEAT_MS) {
          remove = true;
          removeReason = "heartbeat_stale";
        } else if (!inGrace) {
          const lastSeen =
            Number(prof.last_active_at ?? prof.last_seen_at ?? 0) || 0;
          if (lastSeen > 0 && now - lastSeen > STALE_INDEX_HEARTBEAT_MS) {
            remove = true;
            removeReason = "last_seen_stale";
          }
        }
        const dm = normalizeDispatchKey(
          prof.canonical_market_id ?? prof.dispatch_market_id ?? prof.market_pool ?? "",
        );
        if (dm && dm !== market) {
          remove = true;
          removeReason = "market_drift";
        }
      }

      if (remove) {
        updates[`dispatch_index/${market}/${d}`] = null;
        removed += 1;
        console.log(
          "DISPATCH_INDEX_SWEEP_REMOVE",
          `driverId=${d}`,
          `market=${market}`,
          `reason=${removeReason}`,
        );
      }
    }
  }

  if (Object.keys(updates).length) {
    await db.ref().update(updates);
  }
  console.log("DISPATCH_INDEX_SWEEP_DONE", `scanned=${scanned}`, `removed=${removed}`);
  return { scanned, removed };
}

module.exports = {
  KNOWN_MARKETS,
  syncDispatchIndexForDriver,
  clearDispatchIndexForDriver,
  removeDriverFromDispatchIndexWhenUnavailable,
  loadDriversFromDispatchIndex,
  sweepDispatchIndexes,
  driverShouldBeInDispatchIndex,
};
