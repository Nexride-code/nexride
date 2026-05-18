/**
 * Per-driver dispatch health signals for ranking deprioritization.
 */

"use strict";

const { normUid } = require("./dispatch_trip_state_engine");
const { loadDispatchConfig } = require("./dispatch_config_engine");

async function readDriverDispatchHealth(db, driverId) {
  const d = normUid(driverId);
  if (!d) return null;
  const snap = await db.ref(`driver_dispatch_health/${d}`).get();
  return snap.exists() && typeof snap.val() === "object" ? snap.val() : null;
}

async function patchDriverDispatchHealth(db, driverId, patch) {
  const d = normUid(driverId);
  if (!d || !patch || typeof patch !== "object") return;
  const now = Date.now();
  await db.ref(`driver_dispatch_health/${d}`).update({
    ...patch,
    updated_at_ms: now,
  });
}

/**
 * Score 0–100 (higher = healthier). Used as tie-break deprioritization.
 */
async function computeDriverHealthScore(db, driverId, profile, now = Date.now()) {
  const cfg = await loadDispatchConfig(db);
  const d = normUid(driverId);
  const prof = profile && typeof profile === "object" ? profile : {};
  const health = (await readDriverDispatchHealth(db, d)) || {};

  let score = 100;
  const lastSeen = Math.max(
    Number(prof.last_active_at ?? 0) || 0,
    Number(prof.last_seen_at ?? 0) || 0,
    Number(prof.presence_heartbeat_at ?? 0) || 0,
    Number(health.last_heartbeat_ms ?? 0) || 0,
  );
  if (lastSeen > 0) {
    const age = now - lastSeen;
    if (age > cfg.stale_driver_heartbeat_ms) score -= 60;
    else if (age > cfg.stale_driver_heartbeat_ms / 2) score -= 25;
  } else {
    score -= 40;
  }

  const reconnects = Number(health.reconnect_count ?? 0) || 0;
  if (reconnects > 5) score -= 15;

  const staleRepairs = Number(health.stale_repair_count ?? 0) || 0;
  if (staleRepairs > 3) score -= 10;

  const ignored = Number(health.ignored_offer_count ?? 0) || 0;
  if (ignored > 8) score -= 15;

  const popupAckRate = Number(health.popup_ack_rate ?? 1) || 1;
  if (popupAckRate < 0.3) score -= 20;
  else if (popupAckRate < 0.6) score -= 10;

  const acceptanceRate = Number(health.acceptance_rate ?? 1) || 1;
  if (acceptanceRate < 0.2) score -= 15;

  return Math.max(0, Math.min(100, score));
}

/**
 * Attach health_score to candidate for ranking (0-100).
 */
async function applyHealthScoreToCandidate(db, driverId, profile, candidate) {
  const score = await computeDriverHealthScore(db, driverId, profile);
  return { ...candidate, health_score: score, _healthScore: score };
}

async function recordDriverReconnect(db, driverId) {
  const d = normUid(driverId);
  if (!d) return;
  const snap = await db.ref(`driver_dispatch_health/${d}/reconnect_count`).get();
  const cur = Number(snap.val() ?? 0) || 0;
  await patchDriverDispatchHealth(db, d, {
    reconnect_count: cur + 1,
    last_reconnect_at_ms: Date.now(),
  });
}

module.exports = {
  readDriverDispatchHealth,
  patchDriverDispatchHealth,
  computeDriverHealthScore,
  applyHealthScoreToCandidate,
  recordDriverReconnect,
};
