/**
 * Market-level fan-out pressure — throttle under load.
 */

"use strict";

const { normUid } = require("./dispatch_trip_state_engine");

const DEFAULT_MAX_CONCURRENT_FANOUTS = 12;
const HIGH_PRESSURE_BATCH_REDUCTION = 2;

async function readMarketPressure(db, market) {
  const m = normUid(market).toLowerCase();
  if (!m) {
    return {
      active_searching: 0,
      active_fanouts: 0,
      rerun_count: 0,
      queue_depth: 0,
      avg_dispatch_latency_ms: 0,
    };
  }
  const snap = await db.ref(`dispatch_market_pressure/${m}`).get();
  if (!snap.exists()) {
    return {
      active_searching: 0,
      active_fanouts: 0,
      rerun_count: 0,
      queue_depth: 0,
      avg_dispatch_latency_ms: 0,
    };
  }
  const row = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  return {
    active_searching: Number(row.active_searching ?? 0) || 0,
    active_fanouts: Number(row.active_fanouts ?? 0) || 0,
    rerun_count: Number(row.rerun_count ?? 0) || 0,
    queue_depth: Number(row.queue_depth ?? 0) || 0,
    avg_dispatch_latency_ms: Number(row.avg_dispatch_latency_ms ?? 0) || 0,
  };
}

async function patchMarketPressure(db, market, patch) {
  const m = normUid(market).toLowerCase();
  if (!m || !patch) return;
  await db.ref(`dispatch_market_pressure/${m}`).update({
    ...patch,
    updated_at_ms: Date.now(),
  });
}

async function beginMarketFanout(db, market) {
  const m = normUid(market).toLowerCase();
  if (!m) return { allowed: true, batchSizeAdjust: 0 };

  const pressure = await readMarketPressure(db, m);
  const activeFanouts = Number(pressure.active_fanouts ?? 0) || 0;

  if (activeFanouts >= DEFAULT_MAX_CONCURRENT_FANOUTS) {
    console.log(
      "FANOUT_BACKPRESSURE",
      `market=${m}`,
      `reason=max_concurrent_fanouts`,
      `active=${activeFanouts}`,
    );
    return { allowed: false, reason: "market_fanout_saturated", batchSizeAdjust: 0 };
  }

  const searching = Number(pressure.active_searching ?? 0) || 0;
  if (searching > 120 && activeFanouts > DEFAULT_MAX_CONCURRENT_FANOUTS * 0.75) {
    console.log(
      "SHARD_PRESSURE_HIGH",
      `market=${m}`,
      `active_searching=${searching}`,
      `active_fanouts=${activeFanouts}`,
    );
  }

  await patchMarketPressure(db, m, {
    active_fanouts: activeFanouts + 1,
  });

  let batchSizeAdjust = 0;
  if (activeFanouts > DEFAULT_MAX_CONCURRENT_FANOUTS / 2) {
    batchSizeAdjust = -HIGH_PRESSURE_BATCH_REDUCTION;
    console.log(
      "FANOUT_BACKPRESSURE",
      `market=${m}`,
      `reason=elevated_pressure`,
      `batchReduce=${HIGH_PRESSURE_BATCH_REDUCTION}`,
    );
  }

  return { allowed: true, batchSizeAdjust };
}

async function endMarketFanout(db, market) {
  const m = normUid(market).toLowerCase();
  if (!m) return;
  const pressure = await readMarketPressure(db, m);
  const next = Math.max(0, (Number(pressure.active_fanouts ?? 0) || 0) - 1);
  await patchMarketPressure(db, m, { active_fanouts: next });
}

module.exports = {
  readMarketPressure,
  patchMarketPressure,
  beginMarketFanout,
  endMarketFanout,
  DEFAULT_MAX_CONCURRENT_FANOUTS,
};
