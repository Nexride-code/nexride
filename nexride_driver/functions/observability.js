/**
 * Lightweight production logging helpers (no external deps).
 */

const { logger } = require("firebase-functions");

function newRequestId(prefix = "req") {
  const t = Date.now();
  const r = Math.floor(Math.random() * 1e9);
  return `${prefix}_${t}_${r}`;
}

function logEvent(level, payload) {
  const line = JSON.stringify({
    severity: level,
    ts: new Date().toISOString(),
    ...payload,
  });
  if (level === "ERROR") {
    logger.error(line);
  } else if (level === "WARNING") {
    logger.warn(line);
  } else {
    logger.info(line);
  }
}

function logCallableStart({ callable, requestId, actorUid, role }) {
  logEvent("INFO", {
    event: "callable_start",
    callable,
    request_id: requestId,
    actor_uid: actorUid || null,
    role: role || null,
  });
}

function logCallableEnd({ callable, requestId, actorUid, ms, success, reasonCode }) {
  logEvent(success ? "INFO" : "WARNING", {
    event: "callable_end",
    callable,
    request_id: requestId,
    actor_uid: actorUid || null,
    latency_ms: ms,
    success: !!success,
    reason_code: reasonCode || null,
  });
}

function logPaymentSummary({ requestId, provider, outcome, amountNgn, txRef }) {
  logEvent(outcome === "ok" ? "INFO" : "WARNING", {
    event: "payment_provider",
    request_id: requestId,
    provider,
    outcome,
    amount_ngn: amountNgn ?? null,
    tx_ref: txRef || null,
  });
}

function logWebhookVerification({ requestId, verified, reason }) {
  logEvent(verified ? "INFO" : "WARNING", {
    event: "webhook_verify",
    request_id: requestId,
    verified: !!verified,
    reason: reason || null,
  });
}

module.exports = {
  newRequestId,
  logEvent,
  logCallableStart,
  logCallableEnd,
  logPaymentSummary,
  logWebhookVerification,
};
