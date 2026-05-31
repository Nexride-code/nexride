/**
 * Poll RTDB until predicate passes or timeout.
 */
export async function waitForRef(db, path, predicate, { timeoutMs = 20_000, intervalMs = 250, label = path } = {}) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const snap = await db.ref(path).get();
    const val = snap.exists() ? snap.val() : null;
    if (predicate(val, snap)) {
      return { val, snap, elapsedMs: Date.now() - started };
    }
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  throw new Error(`waitForRef timeout after ${timeoutMs}ms: ${label}`);
}

export async function waitUntilNull(db, path, opts = {}) {
  return waitForRef(
    db,
    path,
    (val) => val == null,
    { label: `${path} cleared`, ...opts },
  );
}
