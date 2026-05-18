/**
 * Fast recovery mode when market dispatch latency exceeds threshold.
 */

"use strict";

const { readMarketPressure, patchMarketPressure } = require("./dispatch_fanout_backpressure_engine");
const { normMarket } = require("./dispatch_shard_engine");

const LATENCY_THRESHOLD_MS = 25_000;
const P95_SAMPLE_THRESHOLD_MS = 30_000;

async function evaluateFastRecoveryMode(db, market) {
  const m = normMarket(market);
  if (!m) {
    return { active: false, batchSizeAdjust: 0, radiusExpandKm: 0, skipLowHealth: false };
  }

  const pressure = await readMarketPressure(db, m);
  const avg = Number(pressure.avg_dispatch_latency_ms ?? 0) || 0;
  const queueDepth = Number(pressure.queue_depth ?? 0) || 0;
  const searching = Number(pressure.active_searching ?? 0) || 0;

  const active =
    avg >= LATENCY_THRESHOLD_MS ||
    queueDepth > 40 ||
    (searching > 80 && avg > 12_000);

  if (active) {
    console.log(
      "PIPELINE_TIMEOUT_RECOVERY",
      `market=${m}`,
      `mode=fast_recovery`,
      `avgLatencyMs=${avg}`,
      `queueDepth=${queueDepth}`,
    );
    await patchMarketPressure(db, m, { fast_recovery_active: true, fast_recovery_at_ms: Date.now() });
  }

  return {
    active,
    batchSizeAdjust: active ? 1 : 0,
    radiusExpandKm: active ? 4 : 0,
    skipLowHealth: active,
    reduceBatchWait: active,
    aggressiveRerun: active && queueDepth > 60,
  };
}

module.exports = {
  evaluateFastRecoveryMode,
  LATENCY_THRESHOLD_MS,
  P95_SAMPLE_THRESHOLD_MS,
};
