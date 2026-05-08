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
const { flutterwavePublicKey } = require("./params");
const {
  fanOutDriverOffersIfEligible,
  loadRiderCreateGates,
  coordsFromPickup,
  coordsInNgBox,
  canonicalDispatchMarket,
} = require("./ride_callables");
const { fanOutDeliveryOffersIfEligible } = require("./delivery_callables");
const { syncRideTrackPublic } = require("./track_public");
const DEFAULT_FLUTTERWAVE_REDIRECT_URL =
  "https://nexride-8d5bc.web.app/pay/card-link-complete";

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
  console.log(
    "PAYMENT_INIT_START",
    `rider=${riderId}`,
    `rideId=${rideId || ""}`,
    `deliveryId=${deliveryId || ""}`,
    `amount=${amount}`,
    `currency=${currency}`,
  );
  const txRefKey = db.ref("payment_transactions").push().key;
  const baseTxRef = `nexride_${nowMs()}`;
  const tx_ref = txRefKey ? `${baseTxRef}_${txRefKey}` : baseTxRef;
  if (!tx_ref.trim()) {
    console.log("PAYMENT_INIT_FAIL", "tx_ref_generation_failed");
    return { success: false, reason: "tx_ref_generation_failed" };
  }
  const redirectUrl = String(
    data?.redirect_url ??
      data?.redirectUrl ??
      DEFAULT_FLUTTERWAVE_REDIRECT_URL,
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
    console.log(
      "PAYMENT_INIT_FAIL",
      `reason=${r.reason || "initiate_failed"}`,
      `tx_ref=${tx_ref}`,
      `provider=${JSON.stringify(r.payload || {})}`,
    );
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
  const response = {
    success: true,
    status: "success",
    tx_ref,
    amount,
    currency,
    customer: body.customer,
    public_key: String(flutterwavePublicKey.value() || "").trim(),
    authorization_url: r.link,
    reason: "initiated",
  };
  console.log(
    "PAYMENT_INIT_OK",
    `rideId=${rideId || ""}`,
    `deliveryId=${deliveryId || ""}`,
    `tx_ref=${tx_ref}`,
  );
  console.log(
    "PAYMENT_INIT_SUCCESS",
    `rideId=${rideId || ""}`,
    `deliveryId=${deliveryId || ""}`,
    `tx_ref=${tx_ref}`,
  );
  console.log("PAYMENT_INIT_RESPONSE", JSON.stringify(response));
  return response;
}

/**
 * Card checkout before a ride row exists: stores `ride_intent` on `payment_transactions/{tx_ref}`.
 */
async function initiateFlutterwaveRideIntent(data, context, db) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const riderId = normUid(context.auth.uid);
  const riderGates = await loadRiderCreateGates(db);
  const pickup = data?.pickup;
  if (!pickup || typeof pickup !== "object") {
    return { success: false, reason: "invalid_pickup" };
  }
  const pCoord = coordsFromPickup(pickup);
  if (riderGates.require_ng_pickup && !coordsInNgBox(pCoord.lat, pCoord.lng)) {
    return { success: false, reason: "pickup_location_out_of_region" };
  }
  const dropoff = data?.dropoff;
  if (dropoff && typeof dropoff === "object") {
    const dCoord = coordsFromPickup(dropoff);
    if (
      riderGates.require_ng_pickup &&
      Number.isFinite(dCoord.lat) &&
      Number.isFinite(dCoord.lng) &&
      !coordsInNgBox(dCoord.lat, dCoord.lng)
    ) {
      return { success: false, reason: "dropoff_location_out_of_region" };
    }
  }
  const fare = Number(data?.fare ?? 0);
  if (!Number.isFinite(fare) || fare <= 0) {
    return { success: false, reason: "invalid_fare" };
  }
  if (fare > riderGates.max_fare_ngn) {
    return { success: false, reason: "fare_above_limit" };
  }
  const currency = String(data?.currency ?? "NGN").trim().toUpperCase() || "NGN";
  const distanceKm = Number(data?.distance_km ?? data?.distanceKm ?? 0) || 0;
  const etaMin = Number(data?.eta_min ?? data?.etaMin ?? 0) || 0;
  if (!Number.isFinite(distanceKm) || distanceKm < 0 || distanceKm > 3500) {
    return { success: false, reason: "invalid_distance" };
  }
  if (!Number.isFinite(etaMin) || etaMin < 0 || etaMin > 36 * 60) {
    return { success: false, reason: "invalid_eta" };
  }
  const marketRaw = data?.market ?? data?.city ?? "";
  const market = canonicalDispatchMarket(marketRaw) || "lagos";
  const marketPool = canonicalDispatchMarket(data?.market_pool ?? data?.marketPool ?? market) || market;
  const email = String(
    data?.email ?? context.auth.token?.email ?? `${riderId}@nexride.local`,
  ).trim();
  console.log(
    "PAYMENT_INTENT_START",
    `rider=${riderId}`,
    `amount=${fare}`,
    `currency=${currency}`,
    `market=${market}`,
  );
  const txRefKey = db.ref("payment_transactions").push().key;
  const baseTxRef = `nexride_intent_${nowMs()}`;
  const tx_ref = txRefKey ? `${baseTxRef}_${txRefKey}` : baseTxRef;
  if (!tx_ref.trim()) {
    console.log("PAYMENT_INTENT_FAIL", "tx_ref_generation_failed");
    return { success: false, reason: "tx_ref_generation_failed" };
  }
  /** @type {Record<string, unknown>} */
  const rideIntent = {
    pickup,
    fare,
    currency,
    distance_km: distanceKm,
    eta_min: etaMin,
    market,
    market_pool: marketPool,
    service_type: String(data?.service_type ?? data?.serviceType ?? "ride").trim(),
  };
  if (dropoff && typeof dropoff === "object") {
    rideIntent.dropoff = dropoff;
  }
  const mdRaw = data?.ride_metadata ?? data?.rideMetadata;
  if (mdRaw && typeof mdRaw === "object" && !Array.isArray(mdRaw)) {
    rideIntent.ride_metadata = mdRaw;
  }
  const redirectUrl = String(
    data?.redirect_url ??
      data?.redirectUrl ??
      DEFAULT_FLUTTERWAVE_REDIRECT_URL,
  ).trim();
  const body = {
    tx_ref,
    amount: fare,
    currency,
    redirect_url: redirectUrl,
    payment_options: "card",
    customer: {
      email: email || `${riderId}@nexride.local`,
      name: String(data?.customer_name ?? "NexRide rider").trim(),
    },
    meta: { rider_id: riderId, ride_intent: "1" },
    customizations: { title: "NexRide trip" },
  };
  const r = await createHostedPaymentLink(body);
  if (!r.ok) {
    console.log(
      "PAYMENT_INTENT_FAIL",
      `reason=${r.reason || "initiate_failed"}`,
      `tx_ref=${tx_ref}`,
      `provider=${JSON.stringify(r.payload || {})}`,
    );
    return {
      success: false,
      reason: r.reason || "payment_init_failed",
      provider: r.payload,
    };
  }
  const now = nowMs();
  await db.ref(`payment_transactions/${tx_ref}`).set({
    tx_ref,
    rider_id: riderId,
    ride_id: null,
    amount: fare,
    currency,
    ride_intent: rideIntent,
    status: "pending",
    intent: true,
    provider_link: r.link,
    verified: false,
    created_at: now,
    updated_at: now,
  });
  const response = {
    success: true,
    status: "success",
    tx_ref,
    amount: fare,
    currency,
    customer: body.customer,
    public_key: String(flutterwavePublicKey.value() || "").trim(),
    authorization_url: r.link,
    reason: "intent_initiated",
  };
  console.log("PAYMENT_INTENT_OK", `tx_ref=${tx_ref}`, `rider=${riderId}`);
  return response;
}

/** Minimum card tokenization charge (NGN); Flutterwave often requires a positive amount. */
const CARD_LINK_CHARGE_NGN = 100;

function cardLinkArtifactsFromProviderPayload(payload) {
  const data = payload?.data && typeof payload.data === "object" ? payload.data : {};
  const card =
    data.card && typeof data.card === "object" ? data.card : {};
  const authorization =
    data.authorization && typeof data.authorization === "object"
      ? data.authorization
      : {};
  let lastDigits = String(card.last_4digits ?? card.last4 ?? "").trim();
  if (lastDigits.length > 4) {
    lastDigits = lastDigits.slice(-4);
  }
  const brand = String(card.type ?? card.brand ?? card.issuer ?? "Card").trim() || "Card";
  const authorizationCode = String(authorization.authorization_code ?? "").trim();
  return { lastDigits, brand, authorizationCode, rawCard: card };
}

/**
 * Hosted checkout to save a card (token) without manual PAN entry.
 */
async function initiateFlutterwaveCardLinkIntent(data, context, db) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const riderId = normUid(context.auth.uid);
  const currency = String(data?.currency ?? "NGN").trim().toUpperCase() || "NGN";
  const email = String(
    data?.email ?? context.auth.token?.email ?? `${riderId}@nexride.local`,
  ).trim();
  const amount = CARD_LINK_CHARGE_NGN;
  const txRefKey = db.ref("payment_transactions").push().key;
  const baseTxRef = `nexride_cardlink_${nowMs()}`;
  const tx_ref = txRefKey ? `${baseTxRef}_${txRefKey}` : baseTxRef;
  if (!tx_ref.trim()) {
    return { success: false, reason: "tx_ref_generation_failed" };
  }
  const redirectUrl = String(
    data?.redirect_url ??
      data?.redirectUrl ??
      DEFAULT_FLUTTERWAVE_REDIRECT_URL,
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
    meta: { rider_id: riderId, card_link_intent: "1" },
    customizations: { title: "Save card on NexRide" },
  };
  let r;
  try {
    r = await createHostedPaymentLink(body);
  } catch (error) {
    console.log(
      "CARD_LINK_INIT_EXCEPTION",
      `rider=${riderId}`,
      `tx_ref=${tx_ref}`,
      `error=${error?.message || error}`,
      `stack=${error?.stack || "no_stack"}`,
    );
    return { success: false, reason: "payment_init_failed_exception" };
  }
  if (!r?.ok) {
    console.log(
      "CARD_LINK_INIT_FAIL",
      `rider=${riderId}`,
      `tx_ref=${tx_ref}`,
      `reason=${r?.reason || "initiate_failed"}`,
      `provider=${JSON.stringify(r?.payload || {})}`,
    );
    return {
      success: false,
      reason: r?.reason || "payment_init_failed",
      provider: r?.payload,
    };
  }
  const now = nowMs();
  await db.ref(`payment_transactions/${tx_ref}`).set({
    tx_ref,
    rider_id: riderId,
    ride_id: null,
    amount,
    currency,
    card_link_intent: { amount, currency },
    status: "pending",
    intent: true,
    card_link: true,
    provider_link: r.link,
    verified: false,
    created_at: now,
    updated_at: now,
  });
  return {
    success: true,
    status: "success",
    tx_ref,
    amount,
    currency,
    customer: body.customer,
    public_key: String(flutterwavePublicKey.value() || "").trim(),
    authorization_url: r.link,
    reason: "card_link_initiated",
    note: `A small ${amount} ${currency} charge authorizes your card and saves it for future trips.`,
  };
}

/**
 * Verify card-link payment and persist `users/{uid}/payment_methods/{id}` (server-side).
 */
async function finalizeFlutterwaveCardLink(db, reference, uid) {
  const ref = String(reference || "").trim();
  if (!ref) {
    return { success: false, reason: "invalid_input" };
  }
  const txSnap = await db.ref(`payment_transactions/${ref}`).get();
  const pt = txSnap.val();
  if (!pt || typeof pt !== "object") {
    return { success: false, reason: "transaction_missing" };
  }
  if (normUid(pt.rider_id) !== normUid(uid)) {
    return { success: false, reason: "forbidden" };
  }
  if (!pt.card_link_intent || typeof pt.card_link_intent !== "object") {
    return { success: false, reason: "not_card_link" };
  }
  if (String(pt.card_link_consumed_at ?? "").trim()) {
    return { success: false, reason: "already_used" };
  }
  if (pt.verified === true && String(pt.linked_payment_method_id ?? "").trim()) {
    return {
      success: true,
      reason: "already_linked",
      method_id: String(pt.linked_payment_method_id).trim(),
    };
  }
  const intent = pt.card_link_intent;
  const expectAmt = Number(intent.amount ?? pt.amount ?? CARD_LINK_CHARGE_NGN);
  const expectCur = String(intent.currency ?? pt.currency ?? "NGN").trim().toUpperCase() || "NGN";
  const expectedTx = String(pt.tx_ref ?? ref).trim();
  const v = await verifyFlutterwavePaymentStrict({
    transactionId: /^\d+$/.test(ref) ? ref : "",
    txRef: ref,
    expect: {
      expectedTxRef: expectedTx || undefined,
      expectedCurrency: expectCur,
      minAmount: Number.isFinite(expectAmt) && expectAmt > 0 ? expectAmt : CARD_LINK_CHARGE_NGN,
    },
  });
  const payKey = String(v.flwTransactionId || ref || "").trim();
  if (!v.ok || !payKey) {
    return { success: false, reason: v.reason || "verification_failed" };
  }
  await persistVerifiedFlutterwaveCharge(db, {
    transactionId: payKey,
    txRef: String(v.tx_ref || ref).trim(),
    rideId: null,
    deliveryId: null,
    riderId: normUid(pt.rider_id),
    driverId: null,
    amount: v.amount ?? 0,
    currency: v.currency || expectCur,
    rawStatus: String(v.payload?.data?.status ?? ""),
    webhookBody: { event: "callable_verify_card_link", data: v.payload?.data },
  });
  const { lastDigits, brand, authorizationCode } = cardLinkArtifactsFromProviderPayload(v.payload);
  const tokenStored = authorizationCode || payKey;
  if (!tokenStored || tokenStored.length < 4) {
    return { success: false, reason: "missing_authorization_payload" };
  }
  /** @type {string} */
  let lastNorm = lastDigits.replace(/\D/g, "");
  if (lastNorm.length > 4) {
    lastNorm = lastNorm.slice(-4);
  }
  if (lastNorm.length < 3 || lastNorm.length > 4) {
    return { success: false, reason: "invalid_card_last_digits" };
  }
  const methodsRef = db.ref(`users/${normUid(pt.rider_id)}/payment_methods`);
  const snap = await methodsRef.get();
  const existing = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  let shouldMakeDefault = true;
  for (const k of Object.keys(existing)) {
    const row = existing[k];
    if (row && typeof row === "object" && row.isDefault === true) {
      shouldMakeDefault = false;
      break;
    }
    if (row && typeof row === "object" && row.is_default === true) {
      shouldMakeDefault = false;
      break;
    }
  }
  const pushKey = methodsRef.push().key;
  if (!pushKey) {
    return { success: false, reason: "method_id_failed" };
  }
  const now = nowMs();
  const maskedDetails =
    lastNorm.length <= 4 ? `•••• ${lastNorm}` : `•••• ${lastNorm.slice(-4)}`;
  const updates = {};
  updates[`payment_transactions/${ref}/card_link_consumed_at`] = now;
  updates[`payment_transactions/${ref}/linked_payment_method_id`] = pushKey;
  updates[`payment_transactions/${ref}/authorization_code_saved`] =
    authorizationCode ? "1" : "0";
  if (shouldMakeDefault) {
    for (const k of Object.keys(existing)) {
      const row = existing[k];
      if (row && typeof row === "object") {
        updates[`users/${normUid(pt.rider_id)}/payment_methods/${k}/isDefault`] = false;
        updates[`users/${normUid(pt.rider_id)}/payment_methods/${k}/is_default`] = false;
        updates[`users/${normUid(pt.rider_id)}/payment_methods/${k}/updatedAt`] = now;
        updates[`users/${normUid(pt.rider_id)}/payment_methods/${k}/updated_at`] = now;
      }
    }
    updates[`users/${normUid(pt.rider_id)}/defaultPaymentMethodId`] = pushKey;
    updates[`users/${normUid(pt.rider_id)}/paymentMethodsEnabled`] = true;
  }
  updates[`users/${normUid(pt.rider_id)}/payment_methods/${pushKey}`] = {
    brand,
    last4: lastNorm,
    provider: "flutterwave",
    token_ref: tokenStored.slice(0, 180),
    provider_reference: ref.slice(0, 240),
    type: "card",
    card_link_tx_ref: ref,
    maskedDetails,
    displayTitle: `${brand} card`,
    detailLabel: [maskedDetails, brand, "flutterwave"].join(" • "),
    status: "linked",
    payment_transaction_id: payKey,
    isDefault: shouldMakeDefault,
    is_default: shouldMakeDefault,
    country: "NG",
    createdAt: now,
    updatedAt: now,
    created_at: now,
    updated_at: now,
  };
  updates[`users/${normUid(pt.rider_id)}/updated_at`] = now;
  await db.ref().update(updates);
  console.log("CARD_LINK_OK", ref, pushKey);
  return {
    success: true,
    reason: "card_linked",
    method_id: pushKey,
    last4: lastNorm,
    brand,
  };
}

async function verifyFlutterwaveRideIntent(db, reference, uid) {
  const ref = String(reference || "").trim();
  if (!ref) {
    return { success: false, reason: "invalid_input" };
  }
  const txSnap = await db.ref(`payment_transactions/${ref}`).get();
  const pt = txSnap.val();
  if (!pt || typeof pt !== "object") {
    return { success: false, reason: "transaction_missing" };
  }
  if (normUid(pt.rider_id) !== normUid(uid)) {
    return { success: false, reason: "forbidden" };
  }
  if (String(pt.intent_abandoned_at ?? "").trim()) {
    return { success: false, reason: "intent_abandoned" };
  }
  if (String(pt.consumed_ride_id ?? "").trim()) {
    return { success: false, reason: "already_used" };
  }
  if (!pt.ride_intent || typeof pt.ride_intent !== "object") {
    return { success: false, reason: "not_ride_intent" };
  }
  if (pt.verified === true) {
    const tid = String(pt.transaction_id ?? pt.flutterwave_transaction_id ?? "").trim();
    if (tid) {
      return { success: true, reason: "already_verified", transaction_id: tid };
    }
  }
  const intent = pt.ride_intent;
  const fare = Number(intent.fare ?? pt.amount ?? 0);
  const expectCur = String(intent.currency ?? pt.currency ?? "NGN").trim().toUpperCase() || "NGN";
  const expectedTx = String(pt.tx_ref ?? ref).trim();
  const v = await verifyFlutterwavePaymentStrict({
    transactionId: /^\d+$/.test(ref) ? ref : "",
    txRef: ref,
    expect: {
      expectedTxRef: expectedTx || undefined,
      expectedCurrency: expectCur,
      minAmount: Number.isFinite(fare) && fare > 0 ? fare : undefined,
    },
  });
  const payKey = String(v.flwTransactionId || ref || "").trim();
  if (!v.ok) {
    console.log("PAYMENT_INTENT_VERIFY_FAIL", ref, v.reason || "");
    return { success: false, reason: v.reason || "verification_failed" };
  }
  await persistVerifiedFlutterwaveCharge(db, {
    transactionId: payKey,
    txRef: String(v.tx_ref || ref).trim(),
    rideId: null,
    deliveryId: null,
    riderId: normUid(pt.rider_id),
    driverId: null,
    amount: v.amount ?? 0,
    currency: v.currency || expectCur,
    rawStatus: String(v.payload?.data?.status ?? ""),
    webhookBody: { event: "callable_verify_intent", data: v.payload?.data },
  });
  console.log("PAYMENT_INTENT_VERIFY_OK", ref, payKey);
  return { success: true, reason: "intent_verified", transaction_id: payKey };
}

/**
 * Rider-abandoned prepaid card intent — blocks verify/create so a new checkout can start.
 * Does not refund automatically; ops may reconcile out-of-band.
 */
async function abandonFlutterwaveRideIntent(data, context, db) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const riderId = normUid(context.auth.uid);
  const refKey = String(data?.reference ?? data?.tx_ref ?? data?.txRef ?? "").trim();
  if (!refKey) {
    return { success: false, reason: "invalid_input" };
  }
  const txSnap = await db.ref(`payment_transactions/${refKey}`).get();
  const pt = txSnap.val();
  if (!pt || typeof pt !== "object") {
    return { success: false, reason: "transaction_missing" };
  }
  if (normUid(pt.rider_id) !== riderId) {
    return { success: false, reason: "forbidden" };
  }
  if (!pt.ride_intent || typeof pt.ride_intent !== "object") {
    return { success: false, reason: "not_ride_intent" };
  }
  if (String(pt.consumed_ride_id ?? "").trim()) {
    return { success: false, reason: "already_used" };
  }
  const now = nowMs();
  await db.ref(`payment_transactions/${refKey}`).update({
    intent_abandoned_at: now,
    intent_abandoned_by: riderId,
    updated_at: now,
  });
  console.log("PAYMENT_INTENT_ABANDON_OK", refKey, riderId);
  return { success: true, reason: "intent_abandoned" };
}

/**
 * Rider bank transfer — registers `payment_transactions/{tx_ref}` for admin/manual verification.
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

  const rideIdCompact = String(rideId).replace(/[^a-zA-Z0-9]/g, "");
  const tx_ref = rideIdCompact
    ? `nexride_bt_${rideIdCompact}`
    : "";
  if (!tx_ref.trim()) {
    return { success: false, reason: "invalid_ride_id" };
  }
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
    payment_recipient: "nexride",
    created_at: now,
    updated_at: now,
  });
  await db.ref(`ride_requests/${rideId}`).update({
    payment_reference: tx_ref,
    customer_transaction_reference: tx_ref,
    payment_recipient: "nexride",
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
      "Transfer to NexRide official account, include this reference exactly in narration, then upload your payment proof after the trip.",
  };
}

async function verifyFlutterwavePayment(data, context, db) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const intentOnly = Boolean(data?.verify_intent_only ?? data?.verifyIntentOnly);
  const cardLinkOnly = Boolean(data?.verify_card_link_only ?? data?.verifyCardLinkOnly);
  const rideId = normUid(data?.rideId ?? data?.ride_id);
  const deliveryId = normUid(data?.deliveryId ?? data?.delivery_id);
  const reference = String(data?.reference ?? data?.tx_ref ?? data?.transactionId ?? data?.transaction_id ?? "").trim();

  if (intentOnly && cardLinkOnly) {
    return { success: false, reason: "invalid_input" };
  }
  if (cardLinkOnly) {
    if (!reference || rideId || deliveryId || intentOnly) {
      return { success: false, reason: "invalid_input" };
    }
    return finalizeFlutterwaveCardLink(db, reference, normUid(context.auth.uid));
  }

  if (intentOnly) {
    if (!reference || rideId || deliveryId) {
      return { success: false, reason: "invalid_input" };
    }
    return verifyFlutterwaveRideIntent(db, reference, normUid(context.auth.uid));
  }

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
    let ptPrev = {};
    try {
      const ptSnap = await db.ref(`payment_transactions/${ref}`).get();
      if (ptSnap.val() && typeof ptSnap.val() === "object") {
        ptPrev = ptSnap.val();
      }
    } catch (_) {
      ptPrev = {};
    }
    updates[`payment_transactions/${ref}`] = {
      ...ptPrev,
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
  initiateFlutterwaveRideIntent,
  initiateFlutterwaveCardLinkIntent,
  abandonFlutterwaveRideIntent,
  registerBankTransferPayment,
  verifyFlutterwavePayment,
  handleFlutterwaveWebhook,
  mirrorPaymentRecords,
  persistVerifiedFlutterwaveCharge,
  extractRideIdFromNexrideTxRef,
  extractDeliveryIdFromNexrideTxRef,
};
