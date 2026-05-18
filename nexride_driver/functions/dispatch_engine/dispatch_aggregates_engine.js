/**
 * Per-market dispatch metric aggregation for dashboards + auto-throttle.
 */

"use strict";

const { normMarket } = require("./dispatch_shard_engine");
const { readMarketPressure } = require("./dispatch_fanout_backpressure_engine");

async function recordDispatchOutcome(db, market, outcome = {}) {
  const m = normMarket(market);
  if (!m) return;

  const ref = db.ref(`dispatch_aggregates/${m}`);
  const snap = await ref.get();
  const cur = snap.exists() && typeof snap.val() === "object" ? snap.val() : {};

  const samples = Number(cur.latency_samples ?? 0) || 0;
  const prevAvg = Number(cur.avg_match_latency_ms ?? 0) || 0;
  const latency = Number(outcome.match_latency_ms ?? 0) || 0;
  const nextSamples = samples + (latency > 0 ? 1 : 0);
  const nextAvg =
    latency > 0
      ? Math.round((prevAvg * samples + latency) / nextSamples)
      : prevAvg;

  const popupAck = Number(outcome.popup_acked ?? 0) || 0;
  const popupSent = Number(outcome.popup_sent ?? 0) || 0;
  const dupPopup = Number(outcome.duplicate_popup ?? 0) || 0;
  const staleRepair = Number(outcome.stale_repair ?? 0) || 0;
  const rerun = Number(outcome.rerun ?? 0) || 0;
  const orphan = Number(outcome.orphan_cleanup ?? 0) || 0;

  const totalPopups = (Number(cur.popup_sent_total ?? 0) || 0) + popupSent;
  const totalAck = (Number(cur.popup_ack_total ?? 0) || 0) + popupAck;
  const totalDup = (Number(cur.duplicate_popup_total ?? 0) || 0) + dupPopup;
  const totalRepairs = (Number(cur.stale_repair_total ?? 0) || 0) + staleRepair;
  const totalReruns = (Number(cur.rerun_total ?? 0) || 0) + rerun;
  const totalOrphans = (Number(cur.orphan_cleanup_total ?? 0) || 0) + orphan;

  await ref.update({
    avg_match_latency_ms: nextAvg,
    latency_samples: nextSamples,
    p95_dispatch_latency_ms: Number(outcome.p95_latency_ms ?? cur.p95_dispatch_latency_ms ?? nextAvg),
    popup_ack_pct: totalPopups > 0 ? Math.round((100 * totalAck) / totalPopups) : cur.popup_ack_pct ?? 0,
    duplicate_popup_pct:
      totalPopups > 0 ? Math.round((100 * totalDup) / totalPopups) : cur.duplicate_popup_pct ?? 0,
    stale_repair_pct:
      totalReruns > 0
        ? Math.round((100 * totalRepairs) / Math.max(1, totalReruns))
        : cur.stale_repair_pct ?? 0,
    rerun_pct: totalReruns,
    orphan_cleanup_pct: totalOrphans,
    healthy_driver_ratio: Number(outcome.healthy_driver_ratio ?? cur.healthy_driver_ratio ?? 0),
    updated_at_ms: Date.now(),
    popup_sent_total: totalPopups,
    popup_ack_total: totalAck,
    duplicate_popup_total: totalDup,
    stale_repair_total: totalRepairs,
    rerun_total: totalReruns,
    orphan_cleanup_total: totalOrphans,
  });

  const pressure = await readMarketPressure(db, m);
  await db.ref(`dispatch_market_pressure/${m}`).update({
    avg_dispatch_latency_ms: nextAvg,
    active_searching: pressure.active_searching,
  });
}

async function readMarketAggregates(db, market) {
  const m = normMarket(market);
  if (!m) return null;
  const snap = await db.ref(`dispatch_aggregates/${m}`).get();
  return snap.exists() ? snap.val() : null;
}

module.exports = {
  recordDispatchOutcome,
  readMarketAggregates,
};
