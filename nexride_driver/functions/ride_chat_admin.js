/**
 * Admin-only chat bootstrap for ride participant threads.
 */

function normUid(uid) {
  return String(uid ?? "").trim();
}

async function ensureRideChatThread(db, rideId, riderId, driverId) {
  const rid = normUid(rideId);
  const r = normUid(riderId);
  const d = normUid(driverId);
  if (!rid || !r || !d) {
    return;
  }
  const metaRef = db.ref(`ride_chats/${rid}/meta`);
  const snap = await metaRef.get();
  if (snap.exists()) {
    return;
  }
  const now = Date.now();
  await metaRef.set({
    ride_id: rid,
    rider_id: r,
    driver_id: d,
    created_at: now,
    updated_at: now,
    thread_created_by: "cloud_function_accept",
  });
  console.log("CHAT_THREAD_CREATED", rid);
}

module.exports = { ensureRideChatThread };
