/**
 * Idempotent dispatch run tokens — stale retries cannot overwrite fresh state.
 */

"use strict";

const { normUid } = require("./dispatch_trip_state_engine");
const { ensureDispatchMetrics, patchDispatchMetrics } = require("./dispatch_metrics_engine");

function newRunId(db) {
  try {
    const key = db.ref().push?.()?.key;
    if (key) return key;
  } catch (_) {}
  return `run_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
}

/**
 * Start a new dispatch run; bumps recovery_generation.
 */
async function beginDispatchRun(db, rideId, source = "pipeline") {
  const rid = normUid(rideId);
  if (!rid) {
    return {
      dispatch_run_id: "",
      attempt_id: "",
      recovery_generation: 0,
    };
  }

  const metrics = (await ensureDispatchMetrics(db, rid)) || {};
  const prevGen = Number(metrics.recovery_generation ?? 0) || 0;
  const recovery_generation = prevGen + 1;
  const dispatch_run_id = newRunId(db);
  const attempt_id = `att_${recovery_generation}`;

  await patchDispatchMetrics(db, rid, {
    dispatch_run_id,
    attempt_id,
    recovery_generation,
    active_dispatch_run_id: dispatch_run_id,
    last_run_source: String(source).slice(0, 80),
    last_run_started_at_ms: Date.now(),
  });

  return { dispatch_run_id, attempt_id, recovery_generation };
}

async function readActiveRunToken(db, rideId) {
  const rid = normUid(rideId);
  if (!rid) return null;
  const snap = await db.ref(`dispatch_metrics/${rid}`).get();
  if (!snap.exists()) return null;
  const m = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  return {
    dispatch_run_id: String(m.dispatch_run_id ?? m.active_dispatch_run_id ?? ""),
    attempt_id: String(m.attempt_id ?? ""),
    recovery_generation: Number(m.recovery_generation ?? 0) || 0,
  };
}

/**
 * Returns true if incoming run is stale vs active metrics.
 */
async function isStaleDispatchRun(db, rideId, runToken) {
  const rid = normUid(rideId);
  if (!rid || !runToken) return true;
  const active = await readActiveRunToken(db, rid);
  if (!active) return false;
  const inGen = Number(runToken.recovery_generation ?? 0) || 0;
  const actGen = Number(active.recovery_generation ?? 0) || 0;
  if (inGen > 0 && actGen > 0 && inGen < actGen) {
    console.log(
      "DISPATCH_RUN_IGNORED_STALE",
      `rideId=${rid}`,
      `incomingGen=${inGen}`,
      `activeGen=${actGen}`,
    );
    return true;
  }
  if (
    runToken.dispatch_run_id &&
    active.dispatch_run_id &&
    runToken.dispatch_run_id !== active.dispatch_run_id
  ) {
    return true;
  }
  return false;
}

module.exports = {
  beginDispatchRun,
  readActiveRunToken,
  isStaleDispatchRun,
};
