/**
 * In-process dispatch counters — console only (no RTDB/Firestore/analytics SDK).
 */

"use strict";

const state = {
  offer_written: 0,
  offer_accepted: 0,
  offer_expired: 0,
  match_timeout: 0,
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
    `offer_accepted=${state.offer_accepted}`,
    `offer_expired=${state.offer_expired}`,
    `match_timeout=${state.match_timeout}`,
    `average_match_ms=${averageMatchMs()}`,
  );
}

function recordOfferWritten(rideCreatedAtMs) {
  state.offer_written += 1;
  const created = Number(rideCreatedAtMs) || 0;
  if (created > 0) {
    const latency = Math.max(0, Date.now() - created);
    state.match_latency_sum_ms += latency;
    state.match_latency_count += 1;
  }
  logMetrics("offer_written");
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

module.exports = {
  recordOfferWritten,
  recordOfferAccepted,
  recordOfferExpired,
  recordMatchTimeout,
  logMetrics,
  averageMatchMs,
};
