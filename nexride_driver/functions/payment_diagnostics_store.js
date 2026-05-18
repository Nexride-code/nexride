/**
 * In-process ring buffer of recent payment / Flutterwave diagnostics for admin tooling.
 * Resets on cold start (intentional — use Cloud Logging for durable history).
 */

"use strict";

const RING_MAX = 12;

/** @type {Array<object>} */
let _vaRing = [];
/** @type {Array<object>} */
let _cardRing = [];
/** @type {Array<object>} */
let _verifyRing = [];

let _lastWebhookReceivedAtMs = null;

function _push(ring, entry) {
  ring.unshift({ ...entry, recorded_at_ms: Date.now() });
  if (ring.length > RING_MAX) {
    ring.length = RING_MAX;
  }
}

function recordVaCreateFailure(entry) {
  _push(_vaRing, { kind: "va_create", ...entry });
}

function recordCardInitFailure(entry) {
  _push(_cardRing, { kind: "card_init", ...entry });
}

function recordVerifyFailure(entry) {
  _push(_verifyRing, { kind: "verify", ...entry });
}

function touchWebhookReceived() {
  _lastWebhookReceivedAtMs = Date.now();
}

function getDiagnosticsSnapshot() {
  return {
    last_webhook_received_at_ms: _lastWebhookReceivedAtMs,
    last_va_create_errors: _vaRing.slice(0, 5),
    last_card_init_errors: _cardRing.slice(0, 5),
    last_verify_errors: _verifyRing.slice(0, 5),
  };
}

module.exports = {
  recordVaCreateFailure,
  recordCardInitFailure,
  recordVerifyFailure,
  touchWebhookReceived,
  getDiagnosticsSnapshot,
};
