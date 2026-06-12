"use strict";

/** Firebase RTDB rejects keys containing any of these characters. */
const RTDB_INVALID_KEY_RE = /[.#$/[\]]/g;

function sanitizeRtdbKey(key) {
  const s = String(key ?? "").trim();
  if (!s) return "_empty";
  return s.replace(RTDB_INVALID_KEY_RE, "_");
}

/**
 * Deep-copy payload with RTDB-safe keys (recursive).
 * @param {unknown} value
 * @param {number} depth
 * @param {number} maxDepth
 */
function sanitizeProviderPayloadForRtdb(value, depth = 0, maxDepth = 8) {
  if (value == null) return value;
  if (depth > maxDepth) {
    return typeof value === "string" ? value.slice(0, 500) : String(value).slice(0, 500);
  }
  if (Array.isArray(value)) {
    return value
      .slice(0, 50)
      .map((item) => sanitizeProviderPayloadForRtdb(item, depth + 1, maxDepth));
  }
  if (typeof value === "object") {
    const out = {};
    let count = 0;
    for (const [k, v] of Object.entries(value)) {
      if (count >= 80) break;
      out[sanitizeRtdbKey(k)] = sanitizeProviderPayloadForRtdb(v, depth + 1, maxDepth);
      count += 1;
    }
    return out;
  }
  if (typeof value === "string") return value.slice(0, 4000);
  return value;
}

function safeJsonSnippet(obj, max = 5000) {
  try {
    const s = JSON.stringify(obj);
    return s.length > max ? `${s.slice(0, max)}…` : s;
  } catch (_) {
    return String(obj).slice(0, max);
  }
}

/**
 * RTDB-safe provider payload fields — never write raw webhook objects with dotted keys.
 * @param {unknown} raw
 */
function providerPayloadFieldsForRtdb(raw) {
  const source = raw && typeof raw === "object" ? raw : { event: String(raw ?? "unknown") };
  const sanitized = sanitizeProviderPayloadForRtdb(source);
  return {
    provider_payload: sanitized,
    sanitized_provider_payload: sanitized,
    provider_payload_snippet: safeJsonSnippet(source),
  };
}

module.exports = {
  sanitizeRtdbKey,
  sanitizeProviderPayloadForRtdb,
  providerPayloadFieldsForRtdb,
  safeJsonSnippet,
};
