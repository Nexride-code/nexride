/**
 * Rider-facing payment initiation + verification (Flutterwave).
 * Canonical charge rows: payments/{flutterwaveTransactionId|tx_ref}
 * Legacy mirror: payment_transactions/{tx_ref}
 */

const {
  verifyTransactionByReference,
  verifyFlutterwavePaymentStrict,
  createHostedPaymentLink,
} = require("./flutterwave_api");
const { fanOutDriverOffersIfEligible } = require("./ride_callables");
const { fanOutDeliveryOffersIfEligible } = require("./delivery_callables");
const { syncRideTrackPublic } = require("./track_public");

function normUid(uid) {
  return String(uid ?? "").trim();
}

function nowMs() {
  return Date.now();
}

function flutterwaveWebhookDedupeKey(transactionId, txRef) {
  const tid = String(transactionId || "").trim();
  if (tid) {
    return `tid_${tid.replace(/[^a-zA-Z0-9_-]/g, "_").slice(0, 120)}`;
  }
  const tr = String(txRef || "").trim();
  if (tr) {
    return `xref_${tr.replace(/[^a-zA-Z0-9_-]/g, "_").slice(0, 180)}`;
  }
  return "";
}

function extractRideIdFromNexrideTxRef(txRef) {
  const s = String(txRef || "");
  if (!s.startsWith("nexride_")) return "";
  const rest = s.slice("nexride_".length);
  if (rest.startsWith("del_")) return "";
  const i = rest.lastIndexOf("_");
  if (i <= 0) return "";
  return rest.slice(0, i);
}

function extractDeliveryIdFromNexrideTxRef(txRef) {
  const s = String(txRef || "");
  if (!s.startsWith("nexride_del_")) return "";
  const rest = s.slice("nexride_del_".length);
  const i = rest.lastIndexOf("_");
  if (i <= 0) return "";
  return rest.slice(0, i);
}

/**
 * Upsert `payments/{payKey}` and mirror legacy `payment_transactions/{txRef}`.
 * @param {string} payKey Flutterwave transaction id preferred, else tx_ref
 */
async function mirrorPaymentRecords(db, {
  payKey,
  txRef,
  rideId,
  deliveryId,
  riderId,
  verified,
  amount,
  providerStatus,
  payload,
  webhookEvent,
  webhookApplied,
}) {
  const key = String(payKey || "").trim();
  const ref = String(txRef || "").trim() || key;
  if (!key) {
    return;
  }
  const now = nowMs();
  const row = {
    transaction_id: key,
    tx_ref: ref || null,
    ride_id: rideId || null,
    delivery_id: deliveryId || null,
    rider_id: riderId || null,
    verified: !!verified,
    amount: Number(amount || 0) || 0,
    provider_status: providerStatus || "unknown",
    updated_at: now,
  };
  if (webhookEvent) {
    row.webhook_event = webhookEvent;
  }
  if (typeof webhookApplied === "boolean") {
    row.webhook_applied = webhookApplied;
  }
  if (payload && typeof payload === "object") {
    row.provider_payload = payload;
  }
  const updates = {
    [`payments/${key}`]: row,
  };
  if (ref) {
    updates[`payment_transactions/${ref}`] = {
      ...row,
      tx_ref: ref,
    };
  }
  await db.ref().update(updates);
}

async function initiateFlutterwavePayment(data, context, db) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const riderId = normUid(context.auth.uid);
  const rideId = normUid(data?.rideId ?? data?.ride_id);
  const deliveryId = normUid(data?.deliveryId ?? data?.delivery_id);
  const amount = Number(data?.amount ?? 0);
  const currency = String(data?.currency ?? "NGN").trim().toUpperCase() || "NGN";
  const email = String(
    data?.email ?? context.auth.token?.email ?? `${riderId}@nexride.local`,
  ).trim();
  if ((!rideId && !deliveryId) || !Number.isFinite(amount) || amount <= 0) {
    return { success: false, reason: "invalid_input" };
  }
  if (rideId && deliveryId) {
    return { success: false, reason: "invalid_input" };
  }
  let ride = null;
  let delivery = null;
  if (rideId) {
    const rideSnap = await db.ref(`ride_requests/${rideId}`).get();
    ride = rideSnap.val();
    if (!ride || typeof ride !== "object" || normUid(ride.rider_id) !== riderId) {
      return { success: false, reason: "forbidden" };
    }
  } else {
    const delSnap = await db.ref(`delivery_requests/${deliveryId}`).get();
    delivery = delSnap.val();
    if (!delivery || typeof delivery !== "object" || normUid(delivery.customer_id) !== riderId) {
      return { success: false, reason: "forbidden" };
    }
  }
  const txRefKey = db.ref("payment_transactions").push().key;
  const tx_ref = deliveryId
    ? `nexride_del_${deliveryId}_${txRefKey}`
    : `nexride_${rideId}_${txRefKey}`;
  const redirectUrl = String(
    data?.redirect_url ?? data?.redirectUrl ?? "https://nexride.app/pay/return",
  ).trim();
  const body = {
    tx_ref,
    amount,
    currency,
    redirect_url: redirectUrl,
    payment_options: "card",
    customer: {
      email: email || `${riderId}@nexride.local`,
      name: String(data?.customer_name ?? "NexRide rider").trim(),
    },
    meta: deliveryId
      ? { delivery_id: deliveryId, rider_id: riderId }
      : { ride_id: rideId, rider_id: riderId },
    customizations: { title: deliveryId ? "NexRide delivery" : "NexRide trip" },
  };
  const r = await createHostedPaymentLink(body);
  if (!r.ok) {
    return {
      success: false,
      reason: r.reason || "payment_init_failed",
      provider: r.payload,
    };
  }
  const now = nowMs();
  await db.ref(`payment_transactions/${tx_ref}`).set({
    tx_ref,
    ride_id: rideId || null,
    delivery_id: deliveryId || null,
    rider_id: riderId,
    amount,
    currency,
    status: "pending",
    provider_link: r.link,
    verified: false,
    created_at: now,
    updated_at: now,
  });
  if (rideId) {
    await db.ref(`ride_requests/${rideId}`).update({
      payment_reference: tx_ref,
      customer_transaction_reference: tx_ref,
      payment_status: "pending",
      updated_at: now,
    });
    await syncRideTrackPublic(db, rideId);
  } else {
    await db.ref(`delivery_requests/${deliveryId}`).update({
      payment_reference: tx_ref,
      customer_transaction_reference: tx_ref,
      payment_status: "pending",
      updated_at: now,
    });
  }
  return {
    success: true,
    tx_ref,
    authorization_url: r.link,
    reason: "initiated",
  };
}

/**
 * Rider bank transfer — registers `payment_transactions/{tx_ref}` for admin/manual verification.
 * Dispatch stays blocked until `payment_status === "verified"` (e.g. adminApproveManualPayment).
 */
async function registerBankTransferPayment(data, context, db) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const riderId = normUid(context.auth.uid);
  const rideId = normUid(data?.rideId ?? data?.ride_id);
  if (!rideId) {
    return { success: false, reason: "invalid_input" };
  }
  const rideSnap = await db.ref(`ride_requests/${rideId}`).get();
  const ride = rideSnap.val();
  if (!ride || typeof ride !== "object") {
    return { success: false, reason: "ride_missing" };
  }
  if (normUid(ride.rider_id) !== riderId) {
    return { success: false, reason: "forbidden" };
  }
  const rawPm = String(ride.payment_method ?? "")
    .trim()
    .toLowerCase()
    .replace(/[\s-]+/g, "_");
  if (rawPm !== "bank_transfer") {
    return { success: false, reason: "payment_method_not_bank_transfer" };
  }
  const fare = Number(ride.fare ?? 0);
  if (!Number.isFinite(fare) || fare <= 0) {
    return { success: false, reason: "invalid_fare" };
  }
  const currency = String(ride.currency ?? "NGN").trim().toUpperCase() || "NGN";

  const key = db.ref("payment_transactions").push().key;
  if (!key) {
    return { success: false, reason: "key_alloc_failed" };
  }
  const tx_ref = `nexride_bt_${rideId}_${key}`;
  const now = nowMs();
  await db.ref(`payment_transactions/${tx_ref}`).set({
    tx_ref,
    ride_id: rideId,
    delivery_id: null,
    rider_id: riderId,
    amount: fare,
    currency,
    status: "pending_bank_transfer",
    verified: false,
    provider: "bank_transfer",
    created_at: now,
    updated_at: now,
  });
  await db.ref(`ride_requests/${rideId}`).update({
    payment_reference: tx_ref,
    customer_transaction_reference: tx_ref,
    payment_status: "pending",
    updated_at: now,
  });
  await syncRideTrackPublic(db, rideId);
  return {
    success: true,
    reason: "registered",
    tx_ref,
    amount: fare,
    currency,
    instructions:
      "Put this reference in your transfer narration. NexRide verifies bank transfers before drivers are matched.",
  };
}

async function verifyFlutterwavePayment(data, context, db) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const rideId = normUid(data?.rideId ?? data?.ride_id);
  const deliveryId = normUid(data?.deliveryId ?? data?.delivery_id);
  const reference = String(data?.reference ?? data?.tx_ref ?? data?.transactionId ?? data?.transaction_id ?? "").trim();
  if ((!rideId && !deliveryId) || !reference) {
    return { success: false, reason: "invalid_input" };
  }
  if (rideId && deliveryId) {
    return { success: false, reason: "invalid_input" };
  }
  const uid = normUid(context.auth.uid);
  let row = null;
  let entityRef = null;
  if (rideId) {
    entityRef = db.ref(`ride_requests/${rideId}`);
    const rideSnap = await entityRef.get();
    row = rideSnap.val();
    if (!row || typeof row !== "object" || normUid(row.rider_id) !== uid) {
      return { success: false, reason: "forbidden" };
    }
  } else {
    entityRef = db.ref(`delivery_requests/${deliveryId}`);
    const delSnap = await entityRef.get();
    row = delSnap.val();
    if (!row || typeof row !== "object" || normUid(row.customer_id) !== uid) {
      return { success: false, reason: "forbidden" };
    }
  }
  const expectedTx = String(
    row.customer_transaction_reference ?? row.payment_reference ?? reference,
  ).trim();
  const expectCur = String(row.currency ?? "NGN").trim().toUpperCase() || "NGN";
  const minFare = Number(row.fare ?? row.total_delivery_fee ?? 0);
  const v = await verifyFlutterwavePaymentStrict({
    transactionId: /^\d+$/.test(reference) ? reference : "",
    txRef: reference,
    expect: {
      expectedTxRef: expectedTx || undefined,
      expectedCurrency: expectCur,
      minAmount: Number.isFinite(minFare) && minFare > 0 ? minFare : undefined,
    },
  });
  const now = nowMs();
  const payKey = String(v.flwTransactionId || reference || "").trim();
  if (!v.ok) {
    await mirrorPaymentRecords(db, {
      payKey,
      txRef: reference,
      rideId: rideId || null,
      deliveryId: deliveryId || null,
      riderId: normUid(row.rider_id ?? row.customer_id),
      verified: false,
      amount: v.amount ?? 0,
      providerStatus: v.providerStatus || "unknown",
      payload: v.payload,
      webhookEvent: "callable_verify",
      webhookApplied: false,
    });
    await entityRef.update({
      payment_status: "failed",
      updated_at: now,
    });
    if (rideId) {
      await syncRideTrackPublic(db, rideId);
    }
    return { success: false, reason: v.reason || "verification_failed" };
  }
  await persistVerifiedFlutterwaveCharge(db, {
    transactionId: payKey,
    txRef: String(v.tx_ref || reference).trim(),
    rideId: rideId || null,
    deliveryId: deliveryId || null,
    riderId: normUid(row.rider_id ?? row.customer_id),
    driverId: normUid(row.driver_id) || null,
    amount: v.amount ?? 0,
    currency: v.currency || expectCur,
    rawStatus: String(v.payload?.data?.status ?? ""),
    webhookBody: { event: "callable_verify", data: v.payload?.data },
  });
  await entityRef.update({
    payment_status: "verified",
    payment_verified_at: now,
    payment_provider: "flutterwave",
    payment_transaction_id: payKey,
    paid_at: now,
    updated_at: now,
  });
  if (rideId) {
    const fresh = (await db.ref(`ride_requests/${rideId}`).get()).val();
    await fanOutDriverOffersIfEligible(db, rideId, fresh || row);
    await syncRideTrackPublic(db, rideId);
  } else {
    const freshDel = (await db.ref(`delivery_requests/${deliveryId}`).get()).val() || {};
    await fanOutDeliveryOffersIfEligible(db, deliveryId, freshDel);
  }
  return { success: true, reason: "verified", amount: v.amount, transaction_id: payKey };
}

async function persistVerifiedFlutterwaveCharge(db, {
  transactionId,
  txRef,
  rideId,
  deliveryId,
  riderId,
  driverId,
  amount,
  currency,
  rawStatus,
  webhookBody,
}) {
  const now = nowMs();
  const tId = String(transactionId || "").trim();
  if (!tId) return;
  const ref = String(txRef || "").trim();
  const row = {
    provider: "flutterwave",
    transaction_id: tId,
    tx_ref: ref || null,
    ride_id: rideId || null,
    delivery_id: deliveryId || null,
    rider_id: riderId || null,
    driver_id: driverId || null,
    amount: Number(amount) || 0,
    currency: String(currency || "NGN").trim().toUpperCase() || "NGN",
    status: "verified",
    raw_status: rawStatus || null,
    verified_at: now,
    created_at: now,
    verified: true,
    webhook_applied: true,
    provider_status: "successful",
    provider_payload: webhookBody && typeof webhookBody === "object" ? webhookBody : {},
    updated_at: now,
  };
  const updates = {
    [`payments/${tId}`]: row,
  };
  if (ref) {
    updates[`payment_transactions/${ref}`] = {
      ...row,
      tx_ref: ref,
      flutterwave_transaction_id: tId,
    };
  }
  await db.ref().update(updates);
}

/**
 * Flutterwave charge webhook — verify `verif-hash` header.
 * Idempotent: `webhook_applied/flutterwave/{transactionId}` + strict API verify.
 */
async function handleFlutterwaveWebhook(req, res, db) {
  console.log("WEBHOOK_RECEIVED");
  console.log("WEBHOOK_EVENT:", req.body?.event);

  let body = req.body;
  if (typeof body === "string") {
    try {
      body = JSON.parse(body || "{}");
    } catch (_) {
      body = {};
    }
  }
  if (!body || typeof body !== "object") {
    body = {};
  }

  const signature = String(req.headers["verif-hash"] ?? req.headers["verif_hash"] ?? "").trim();
  const expected = String(process.env.FLUTTERWAVE_WEBHOOK_SECRET || "").trim();

  if (!expected || signature !== expected) {
    console.log("WEBHOOK_HASH_FAIL");
    res.status(401).send("invalid signature");
    return;
  }

  console.log("WEBHOOK_HASH_OK");

  if (body?.event === "test") {
    console.log("WEBHOOK_TEST_MODE");
    res.status(200).json({ ok: true, message: "webhook alive" });
    return;
  }

  const event = String(body?.event ?? "").trim().toLowerCase();
  if (event !== "charge.completed") {
    res.status(200).send("ignored-event");
    return;
  }

  const data = body?.data && typeof body.data === "object" ? body.data : {};
  const transactionId = String(data?.id ?? "").trim();
  const txRef = String(data?.tx_ref ?? data?.txRef ?? "").trim();
  const chargeStatus = String(data?.status ?? "").trim().toLowerCase();
  const hookAmount = Number(data?.amount ?? 0);
  const hookCurrency = String(data?.currency ?? "").trim().toUpperCase();

  if (chargeStatus !== "successful") {
    res.status(200).send("ignored-not-successful");
    return;
  }

  if (!transactionId && !txRef) {
    res.status(200).send("ignored-no-id");
    return;
  }

  const webhookDedupeKey = flutterwaveWebhookDedupeKey(transactionId, txRef);
  if (webhookDedupeKey) {
    const seenSnap = await db.ref(`webhook_applied/flutterwave_webhook/${webhookDedupeKey}`).get();
    if (seenSnap.exists()) {
      res.status(200).send("ok-duplicate-webhook");
      return;
    }
  }

  const meta = data?.meta && typeof data.meta === "object" ? data.meta : {};
  const ptSnap = txRef ? await db.ref(`payment_transactions/${txRef}`).get() : null;
  const pt = ptSnap ? ptSnap.val() : null;
  let rideId = String(meta?.ride_id ?? meta?.rideId ?? "").trim();
  if (!rideId) {
    rideId = extractRideIdFromNexrideTxRef(txRef);
  }
  if (!rideId && pt && typeof pt === "object") {
    rideId = String(pt.ride_id ?? "").trim();
  }

  let deliveryId = String(meta?.delivery_id ?? meta?.deliveryId ?? "").trim();
  if (!deliveryId) {
    deliveryId = extractDeliveryIdFromNexrideTxRef(txRef);
  }
  if (!deliveryId && pt && typeof pt === "object") {
    deliveryId = String(pt.delivery_id ?? "").trim();
  }

  const rideSnap = rideId ? await db.ref(`ride_requests/${rideId}`).get() : null;
  const ride = rideSnap ? rideSnap.val() : null;
  const deliverySnap = deliveryId ? await db.ref(`delivery_requests/${deliveryId}`).get() : null;
  const deliveryRecord =
    deliverySnap && deliverySnap.val() && typeof deliverySnap.val() === "object"
      ? deliverySnap.val()
      : null;

  let expectedTxFromEntity = "";
  if (ride && typeof ride === "object") {
    expectedTxFromEntity = String(
      ride.customer_transaction_reference ?? ride.payment_reference ?? "",
    ).trim();
  } else if (deliveryRecord) {
    expectedTxFromEntity = String(
      deliveryRecord.customer_transaction_reference ??
        deliveryRecord.payment_reference ??
        "",
    ).trim();
  }
  const expectedTxRefForVerify =
    (expectedTxFromEntity || txRef || "").trim() || undefined;
  const expectedCurrency = String(
    (ride && ride.currency) ||
      (deliveryRecord && deliveryRecord.currency) ||
      (pt && pt.currency) ||
      hookCurrency ||
      "NGN",
  )
    .trim()
    .toUpperCase() || "NGN";
  let minAmount;
  if (ride && typeof ride === "object") {
    const f = Number(ride.fare ?? ride.total_delivery_fee ?? 0);
    if (Number.isFinite(f) && f > 0) minAmount = f;
  }
  if (minAmount == null && deliveryRecord) {
    const f = Number(deliveryRecord.fare ?? 0);
    if (Number.isFinite(f) && f > 0) minAmount = f;
  }
  if (minAmount == null && pt && typeof pt === "object") {
    const a = Number(pt.amount ?? 0);
    if (Number.isFinite(a) && a > 0) minAmount = a;
  }
  if (minAmount == null && Number.isFinite(hookAmount) && hookAmount > 0) {
    minAmount = hookAmount;
  }

  console.log("PAYMENT_VERIFY_START", transactionId || txRef);
  const expectOpts = {
    expectedTxRef: expectedTxRefForVerify,
    expectedCurrency,
  };
  if (minAmount != null && Number.isFinite(minAmount)) {
    expectOpts.minAmount = minAmount;
  }
  const v = await verifyFlutterwavePaymentStrict({
    transactionId,
    txRef,
    expect: expectOpts,
  });

  if (!v.ok) {
    console.log("PAYMENT_VERIFY_FAIL", transactionId || txRef, v.reason || "");
    res.status(200).send("verify-failed");
    return;
  }
  console.log("PAYMENT_VERIFY_OK", transactionId || txRef);

  const payTid = String(v.flwTransactionId || transactionId || "").trim();
  if (!payTid) {
    res.status(200).send("ignored-no-pay-id");
    return;
  }

  const claimRef = db.ref(`webhook_applied/flutterwave/${payTid}`);
  const tr = await claimRef.transaction((cur) => {
    if (cur != null && cur !== undefined) {
      return undefined;
    }
    return { applied_at: nowMs(), ride_id: rideId || null };
  });
  if (!tr.committed) {
    console.log("PAYMENT_DUPLICATE_IGNORED", payTid);
    res.status(200).send("ok-duplicate");
    return;
  }

  try {
    const riderId = String(
      (meta?.rider_id ??
        meta?.riderId ??
        (ride && ride.rider_id) ??
        (deliveryRecord && deliveryRecord.customer_id) ??
        (pt && pt.rider_id) ??
        ""),
    ).trim();
    const driverId = String(
      (ride && ride.driver_id) || (deliveryRecord && deliveryRecord.driver_id) || "",
    ).trim();
    const finalTxRef = String(v.tx_ref || txRef || "").trim();

    console.log("PAYMENT_APPLY_START", payTid);
    const now = nowMs();
    await persistVerifiedFlutterwaveCharge(db, {
      transactionId: payTid,
      txRef: finalTxRef,
      rideId: rideId || null,
      deliveryId: deliveryId || null,
      riderId: riderId || null,
      driverId: driverId || null,
      amount: v.amount ?? hookAmount,
      currency: v.currency || hookCurrency || expectedCurrency,
      rawStatus: String(data?.status ?? ""),
      webhookBody: body,
    });

    if (rideId) {
      await db.ref(`ride_requests/${rideId}`).update({
        payment_status: "verified",
        payment_provider: "flutterwave",
        payment_transaction_id: payTid,
        payment_verified_at: now,
        paid_at: now,
        updated_at: now,
      });
      const activeSnap = await db.ref(`active_trips/${rideId}`).get();
      if (activeSnap.exists()) {
        await db.ref(`active_trips/${rideId}`).update({
          payment_status: "verified",
          payment_provider: "flutterwave",
          payment_transaction_id: payTid,
          paid_at: now,
          updated_at: now,
        });
      }
      const fresh = (await db.ref(`ride_requests/${rideId}`).get()).val();
      await fanOutDriverOffersIfEligible(db, rideId, fresh || ride || {});
      await syncRideTrackPublic(db, rideId);
    }
    if (deliveryId) {
      await db.ref(`delivery_requests/${deliveryId}`).update({
        payment_status: "verified",
        payment_provider: "flutterwave",
        payment_transaction_id: payTid,
        payment_verified_at: now,
        paid_at: now,
        updated_at: now,
      });
      const freshDel = (await db.ref(`delivery_requests/${deliveryId}`).get()).val();
      await fanOutDeliveryOffersIfEligible(db, deliveryId, freshDel || deliveryRecord || {});
    }

    if (webhookDedupeKey) {
      await db.ref(`webhook_applied/flutterwave_webhook/${webhookDedupeKey}`).set({
        applied_at: now,
        flutterwave_transaction_id: payTid,
        tx_ref: finalTxRef || txRef || null,
        ride_id: rideId || null,
        delivery_id: deliveryId || null,
      });
    }

    console.log("PAYMENT_APPLIED", payTid);
    res.status(200).send("ok");
  } catch (err) {
    try {
      await claimRef.remove();
    } catch (_) {
      /* ignore */
    }
    console.log("PAYMENT_APPLY_FAIL", payTid, String(err?.message || err));
    res.status(500).send("apply-error");
  }
}

module.exports = {
  initiateFlutterwavePayment,
  registerBankTransferPayment,
  verifyFlutterwavePayment,
  handleFlutterwaveWebhook,
  mirrorPaymentRecords,
  persistVerifiedFlutterwaveCharge,
  extractRideIdFromNexrideTxRef,
  extractDeliveryIdFromNexrideTxRef,
};
