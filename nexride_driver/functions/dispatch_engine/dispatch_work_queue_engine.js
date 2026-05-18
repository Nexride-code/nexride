/**
 * Shard-aware dispatch work queues — schedulers process items only.
 */

"use strict";

const { normUid } = require("./dispatch_trip_state_engine");
const { normMarket, shardForKey, touchMarketShard } = require("./dispatch_shard_engine");

const QUEUES = Object.freeze([
  "matching",
  "recovery",
  "orphan_cleanup",
  "rerun",
  "lease_expiry",
]);

const DEFAULT_TTL_MS = 30 * 60_000;
const MAX_ATTEMPTS = 6;

function newWorkId(db) {
  try {
    const k = db.ref().push?.()?.key;
    if (k) return k;
  } catch (_) {}
  return `work_${Date.now()}_${Math.random().toString(36).slice(2, 10)}`;
}

function workPath(queue, workId) {
  return `dispatch_work_queue/${queue}/${workId}`;
}

/**
 * Enqueue idempotent work (dedupe by ride + queue + reason when ride present).
 */
async function enqueueDispatchWork(db, queue, item = {}) {
  const q = String(queue ?? "").trim();
  if (!QUEUES.includes(q)) {
    return { ok: false, reason: "invalid_queue" };
  }

  const rideId = normUid(item.ride_id ?? item.rideId);
  const market = normMarket(item.market);
  const reason = String(item.reason ?? "unspecified").slice(0, 120);
  const shard =
    item.shard != null ? Number(item.shard) || 0 : rideId ? shardForKey(rideId) : 0;

  let workId = String(item.work_id ?? "").trim();
  if (!workId && rideId) {
    workId = `${q}_${rideId}_${reason}`.replace(/[^a-zA-Z0-9_-]/g, "_").slice(0, 120);
  }
  if (!workId) workId = newWorkId(db);

  const ref = db.ref(workPath(q, workId));
  const existing = await ref.get();
  if (existing.exists()) {
    const cur = existing.val() || {};
    if (cur.status === "completed") {
      await ref.remove();
    } else if (cur.status === "pending" || cur.status === "processing") {
      return { ok: true, workId, deduped: true };
    }
  }

  const now = Date.now();
  const row = {
    work_id: workId,
    ride_id: rideId || null,
    market: market || null,
    shard,
    created_at: now,
    expires_at: now + (Number(item.ttl_ms) > 0 ? Number(item.ttl_ms) : DEFAULT_TTL_MS),
    priority: Math.min(10, Math.max(1, Number(item.priority) || 5)),
    reason,
    generation: Number(item.generation ?? 0) || 0,
    attempts: 0,
    status: "pending",
    queue: q,
  };

  await ref.set(row);
  if (market && rideId) {
    await touchMarketShard(db, market, rideId, "work", { queue: q, work_id: workId });
  }

  console.log(
    "DISPATCH_WORK_ITEM_CREATED",
    `queue=${q}`,
    `workId=${workId}`,
    `rideId=${rideId || "none"}`,
    `market=${market || "none"}`,
    `shard=${shard}`,
    `reason=${reason}`,
  );

  return { ok: true, workId, row };
}

async function claimWorkItem(db, queue, workId) {
  const ref = db.ref(workPath(queue, workId));
  let claimed = null;
  const tx = await ref.transaction((cur) => {
    if (!cur || typeof cur !== "object") return;
    if (cur.status !== "pending") return;
    if (Number(cur.expires_at ?? 0) > 0 && Date.now() > Number(cur.expires_at)) {
      return { ...cur, status: "expired" };
    }
    claimed = {
      ...cur,
      status: "processing",
      processing_at: Date.now(),
      attempts: (Number(cur.attempts) || 0) + 1,
    };
    return claimed;
  });
  if (!tx.committed || !claimed) return null;
  return claimed;
}

async function completeWorkItem(db, queue, workId, result = {}) {
  const ref = db.ref(workPath(queue, workId));
  await ref.update({
    status: "completed",
    completed_at: Date.now(),
    result: result && typeof result === "object" ? result : { ok: true },
  });
  console.log(
    "DISPATCH_WORK_ITEM_PROCESSED",
    `queue=${queue}`,
    `workId=${workId}`,
    `ok=${result?.ok !== false}`,
  );
  setTimeout(() => {
    ref.remove().catch(() => {});
  }, 5_000);
}

async function failWorkItem(db, queue, workId, reason) {
  const ref = db.ref(workPath(queue, workId));
  const snap = await ref.get();
  if (!snap.exists()) return;
  const cur = snap.val() || {};
  const attempts = Number(cur.attempts) || 0;
  if (attempts >= MAX_ATTEMPTS) {
    await ref.update({ status: "dead", failed_reason: reason, failed_at: Date.now() });
    const { createDeadLetter } = require("./dispatch_dead_letter_engine");
    await createDeadLetter(db, {
      ride_id: cur.ride_id,
      market: cur.market,
      reason: `work_queue_exhausted:${queue}`,
      detail: { workId, attempts, reason },
    });
    return;
  }
  await ref.update({
    status: "pending",
    last_error: String(reason).slice(0, 200),
    retry_after_ms: Date.now() + Math.min(60_000, 2000 * attempts),
  });
}

async function listPendingWork(db, queue, limit = 40) {
  const snap = await db.ref(`dispatch_work_queue/${queue}`).limitToFirst(limit * 3).get();
  if (!snap.exists()) return [];
  const rows = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  return Object.entries(rows)
    .map(([workId, row]) => ({ workId, ...(row || {}) }))
    .filter((r) => r.status === "pending")
    .filter((r) => !r.retry_after_ms || Date.now() >= Number(r.retry_after_ms))
    .sort((a, b) => (Number(b.priority) || 0) - (Number(a.priority) || 0))
    .slice(0, limit);
}

async function sweepExpiredWorkItems(db) {
  const now = Date.now();
  let removed = 0;
  for (const q of QUEUES) {
    const snap = await db.ref(`dispatch_work_queue/${q}`).limitToFirst(200).get();
    if (!snap.exists()) continue;
    const rows = snap.val() || {};
    const updates = {};
    for (const [workId, row] of Object.entries(rows)) {
      if (!row || typeof row !== "object") continue;
      const exp = Number(row.expires_at ?? 0) || 0;
      if (exp > 0 && now > exp) {
        updates[workId] = null;
        removed += 1;
      }
    }
    if (Object.keys(updates).length) {
      await db.ref(`dispatch_work_queue/${q}`).update(updates);
    }
  }
  return { removed };
}

module.exports = {
  QUEUES,
  enqueueDispatchWork,
  claimWorkItem,
  completeWorkItem,
  failWorkItem,
  listPendingWork,
  sweepExpiredWorkItems,
};
