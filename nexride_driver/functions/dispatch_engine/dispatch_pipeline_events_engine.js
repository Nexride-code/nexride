/**
 * Immutable dispatch pipeline events for production debugging.
 */

"use strict";

const { normUid } = require("./dispatch_trip_state_engine");

function newEventId(db) {
  try {
    const key = db.ref().push?.()?.key;
    if (key) return key;
  } catch (_) {}
  return `evt_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
}

async function emitPipelineEvent(db, rideId, payload = {}) {
  const rid = normUid(rideId);
  if (!rid) return null;
  const eventId = newEventId(db);
  const now = Date.now();
  const row = {
    event_id: eventId,
    ride_id: rid,
    stage: String(payload.stage ?? "unknown"),
    timestamp_ms: now,
    generation: Number(payload.generation ?? 0) || null,
    lease_id: payload.lease_id ?? null,
    driver_id: normUid(payload.driver_id ?? payload.driverId) || null,
    reason: payload.reason ?? null,
    latency_ms: Number(payload.latency_ms ?? 0) || null,
    extra: payload.extra && typeof payload.extra === "object" ? payload.extra : null,
  };
  await db.ref(`dispatch_pipeline_events/${rid}/${eventId}`).set(row);
  return eventId;
}

async function pruneOldPipelineEvents(db, rideId, keep = 80) {
  const rid = normUid(rideId);
  if (!rid) return;
  const snap = await db.ref(`dispatch_pipeline_events/${rid}`).get();
  if (!snap.exists()) return;
  const events = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  const keys = Object.keys(events).sort((a, b) => {
    const ta = Number(events[a]?.timestamp_ms ?? 0) || 0;
    const tb = Number(events[b]?.timestamp_ms ?? 0) || 0;
    return ta - tb;
  });
  if (keys.length <= keep) return;
  const updates = {};
  for (let i = 0; i < keys.length - keep; i++) {
    updates[`dispatch_pipeline_events/${rid}/${keys[i]}`] = null;
  }
  if (Object.keys(updates).length) {
    await db.ref().update(updates);
  }
}

module.exports = {
  emitPipelineEvent,
  pruneOldPipelineEvents,
};
