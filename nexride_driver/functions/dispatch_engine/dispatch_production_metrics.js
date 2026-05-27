/**
 * In-process dispatch counters — console only (no RTDB/Firestore/analytics SDK).
 */

"use strict";

const state = {
  offer_written: 0,
  offer_received: 0,
  offer_accepted: 0,
  offer_expired: 0,
  match_timeout: 0,
  market_mismatch: 0,
  geo_reject: 0,
  no_candidate: 0,
  match_latency_sum_ms: 0,
  match_latency_count: 0,
};

function averageMatchMs() {
  if (state.match_latency_count <= 0) return 0;
  return Math.round(state.match_latency_sum_ms / state.match_latency_count);
}

function logMetrics(reason = "snapshot") {
  console.log(
    "DISPATCH_PROD_METRICS",
    `reason=${reason}`,
    `offer_written=${state.offer_written}`,
    `offer_received=${state.offer_received}`,
    `offer_accepted=${state.offer_accepted}`,
    `offer_expired=${state.offer_expired}`,
    `match_timeout=${state.match_timeout}`,
    `market_mismatch=${state.market_mismatch}`,
    `geo_reject=${state.geo_reject}`,
    `no_candidate=${state.no_candidate}`,
    `average_match_ms=${averageMatchMs()}`,
  );
}

function recordOfferWritten(rideCreatedAtMs) {
  state.offer_written += 1;
  state.offer_received += 1;
  const created = Number(rideCreatedAtMs) || 0;
  if (created > 0) {
    const latency = Math.max(0, Date.now() - created);
    state.match_latency_sum_ms += latency;
    state.match_latency_count += 1;
  }
  logMetrics("offer_written");
}

function recordOfferReceived(count = 1) {
  state.offer_received += Math.max(1, Number(count) || 1);
  logMetrics("offer_received");
}

function recordOfferAccepted() {
  state.offer_accepted += 1;
  logMetrics("offer_accepted");
}

function recordOfferExpired(count = 1) {
  state.offer_expired += Math.max(1, Number(count) || 1);
  logMetrics("offer_expired");
}

function recordMatchTimeout(count = 1) {
  state.match_timeout += Math.max(1, Number(count) || 1);
  logMetrics("match_timeout");
}

function recordMarketMismatch(count = 1) {
  state.market_mismatch += Math.max(1, Number(count) || 1);
  logMetrics("market_mismatch");
}

function recordGeoReject(count = 1) {
  state.geo_reject += Math.max(1, Number(count) || 1);
  logMetrics("geo_reject");
}

function recordNoCandidate(count = 1) {
  state.no_candidate += Math.max(1, Number(count) || 1);
  logMetrics("no_candidate");
}

module.exports = {
  recordOfferWritten,
  recordOfferReceived,
  recordOfferAccepted,
  recordOfferExpired,
  recordMatchTimeout,
  recordMarketMismatch,
  recordGeoReject,
  recordNoCandidate,
  logMetrics,
  averageMatchMs,
};
