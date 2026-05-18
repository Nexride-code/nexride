/**
 * Dead-letter queue for impossible / corrupted dispatch states.
 */

"use strict";

const { normUid } = require("./dispatch_trip_state_engine");
const { normMarket, shardForKey } = require("./dispatch_shard_engine");

function newLetterId(db) {
  try {
    const k = db.ref().push?.()?.key;
    if (k) return k;
  } catch (_) {}
  return `dl_${Date.now()}_${Math.random().toString(36).slice(2, 10)}`;
}

async function createDeadLetter(db, payload = {}) {
  const rideId = normUid(payload.ride_id ?? payload.rideId);
  const market = normMarket(payload.market);
  const letterId = newLetterId(db);
  const now = Date.now();

  const row = {
    letter_id: letterId,
    ride_id: rideId || null,
    driver_id: normUid(payload.driver_id ?? payload.driverId) || null,
    market: market || null,
    shard: rideId ? shardForKey(rideId) : null,
    reason: String(payload.reason ?? "unknown").slice(0, 200),
    detail: payload.detail && typeof payload.detail === "object" ? payload.detail : null,
    created_at_ms: now,
    status: "open",
  };

  await db.ref(`dispatch_dead_letters/${letterId}`).set(row);
  if (rideId) {
    await db.ref(`dispatch_dead_letters_by_ride/${rideId}/${letterId}`).set(true);
  }

  console.log(
    "DEAD_LETTER_CREATED",
    `letterId=${letterId}`,
    `rideId=${rideId || "none"}`,
    `reason=${row.reason}`,
  );

  return { letterId, row };
}

async function listDeadLetters(db, limit = 50) {
  const snap = await db.ref("dispatch_dead_letters").limitToLast(limit).get();
  if (!snap.exists()) return [];
  const rows = snap.val() || {};
  return Object.entries(rows)
    .map(([id, row]) => ({ letter_id: id, ...(row || {}) }))
    .sort((a, b) => (Number(b.created_at_ms) || 0) - (Number(a.created_at_ms) || 0));
}

module.exports = {
  createDeadLetter,
  listDeadLetters,
};
