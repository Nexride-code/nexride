/**
 * Resolve canonical ride_requests RTDB keys from admin/ops input.
 * Supports Firebase push ids with or without a leading "-".
 */

function normUid(v) {
  return String(v ?? "").trim();
}

/** Ordered ride_requests lookup candidates per input (exact, then dash-prefixed). */
function rideIdLookupCandidates(raw) {
  const input = normUid(raw);
  if (!input) return [];
  const out = [input];
  if (!input.startsWith("-")) {
    out.push(`-${input}`);
  }
  return [...new Set(out)];
}

/** All equivalent string forms for payment row matching. */
function rideIdEquivalentForms(raw) {
  const input = normUid(raw);
  if (!input) return [];
  const out = [input];
  if (input.startsWith("-")) {
    const stripped = input.slice(1);
    if (stripped) out.push(stripped);
  } else {
    out.push(`-${input}`);
  }
  return [...new Set(out)];
}

function rideIdsMatch(a, b) {
  const left = normUid(a);
  const right = normUid(b);
  if (!left || !right) return false;
  if (left === right) return true;
  return rideIdEquivalentForms(left).includes(right);
}

async function rideExists(db, rideId) {
  const snap = await db.ref(`ride_requests/${rideId}`).get();
  return snap.exists() ? snap.val() : null;
}

async function confirmRideRequestKey(db, rideId) {
  const candidates = rideIdLookupCandidates(rideId);
  for (const candidate of candidates) {
    const row = await rideExists(db, candidate);
    if (row) {
      return { ok: true, rideId: candidate, ride: row };
    }
  }
  return { ok: false };
}

async function rideIdFromPaymentRow(db, row) {
  if (!row || typeof row !== "object") {
    return { ok: false };
  }

  const fromRideId = normUid(row.ride_id);
  if (fromRideId) {
    const confirmed = await confirmRideRequestKey(db, fromRideId);
    if (confirmed.ok) {
      return confirmed;
    }
  }

  const txRef = normUid(row.tx_ref);
  if (txRef) {
    const confirmed = await confirmRideRequestKey(db, txRef);
    if (confirmed.ok) {
      return confirmed;
    }
  }

  return { ok: false };
}

async function queryPaymentTransactionsByChild(db, childKey, value) {
  try {
    const qSnap = await db
      .ref("payment_transactions")
      .orderByChild(childKey)
      .equalTo(value)
      .limitToFirst(1)
      .get();
    if (!qSnap.exists()) {
      return null;
    }
    const val = qSnap.val();
    if (!val || typeof val !== "object") {
      return null;
    }
    const rows = Object.values(val);
    return rows.length ? rows[0] : null;
  } catch (_) {
    return null;
  }
}

async function queryPaymentsByRideId(db, rideId) {
  try {
    const qSnap = await db.ref("payments").orderByChild("ride_id").equalTo(rideId).limitToFirst(1).get();
    if (!qSnap.exists()) {
      return null;
    }
    const val = qSnap.val();
    if (!val || typeof val !== "object") {
      return null;
    }
    const rows = Object.values(val);
    return rows.length ? rows[0] : null;
  } catch (_) {
    return null;
  }
}

/**
 * Resolve canonical ride_requests key.
 * 1) ride_requests/{input}
 * 2) ride_requests/-{input} when input has no leading dash
 * 3) payment_transactions / payments hints (ride_id or tx_ref)
 */
async function resolveRideRequestId(db, rawInput) {
  const input = normUid(rawInput);
  if (!input) {
    return { ok: false, reason: "invalid_ride_id" };
  }

  for (const candidate of rideIdLookupCandidates(input)) {
    const row = await rideExists(db, candidate);
    if (row) {
      return {
        ok: true,
        rideId: candidate,
        ride: row,
        input,
        resolved_via: "ride_requests",
      };
    }
  }

  const forms = rideIdEquivalentForms(input);

  for (const candidate of forms) {
    const ptSnap = await db.ref(`payment_transactions/${candidate}`).get();
    if (ptSnap.exists()) {
      const fromPayment = await rideIdFromPaymentRow(db, ptSnap.val());
      if (fromPayment.ok) {
        return {
          ok: true,
          rideId: fromPayment.rideId,
          ride: fromPayment.ride,
          input,
          resolved_via: "payment_transactions_tx_ref",
        };
      }
    }
  }

  for (const candidate of forms) {
    const byRideId = await queryPaymentTransactionsByChild(db, "ride_id", candidate);
    if (byRideId) {
      const fromPayment = await rideIdFromPaymentRow(db, byRideId);
      if (fromPayment.ok) {
        return {
          ok: true,
          rideId: fromPayment.rideId,
          ride: fromPayment.ride,
          input,
          resolved_via: "payment_transactions_ride_id",
        };
      }
    }
  }

  for (const candidate of forms) {
    const byTxRef = await queryPaymentTransactionsByChild(db, "tx_ref", candidate);
    if (byTxRef) {
      const fromPayment = await rideIdFromPaymentRow(db, byTxRef);
      if (fromPayment.ok) {
        return {
          ok: true,
          rideId: fromPayment.rideId,
          ride: fromPayment.ride,
          input,
          resolved_via: "payment_transactions_tx_ref_field",
        };
      }
    }
  }

  for (const candidate of forms) {
    const paymentRow = await queryPaymentsByRideId(db, candidate);
    if (paymentRow) {
      const fromPayment = await rideIdFromPaymentRow(db, paymentRow);
      if (fromPayment.ok) {
        return {
          ok: true,
          rideId: fromPayment.rideId,
          ride: fromPayment.ride,
          input,
          resolved_via: "payments_ride_id",
        };
      }
    }
  }

  return {
    ok: false,
    reason: "ride_missing",
    input,
    tried: forms,
  };
}

module.exports = {
  normUid,
  rideIdLookupCandidates,
  rideIdEquivalentForms,
  rideIdsMatch,
  resolveRideRequestId,
};
