/**
 * Durable trip/order history mirrors — survive active_trips / ride_requests cleanup.
 * RTDB (Admin SDK writes only):
 *   user_trip_history/{riderId}/{rideId}
 *   driver_trip_history/{driverId}/{rideId}
 *   user_order_history/{riderId}/{orderId}
 *   driver_order_history/{driverId}/{orderId}
 */

function normUid(uid) {
  return String(uid ?? "").trim();
}

function isPlaceholderDriverId(v) {
  if (v === null || v === undefined) return true;
  const s = String(v).trim().toLowerCase();
  return s.length === 0 || s === "waiting" || s === "pending" || s === "null";
}

function canonicalAssignedDriverId(row) {
  if (!row || typeof row !== "object") return "";
  for (const k of [
    "assigned_driver_id",
    "assignedDriverId",
    "matched_driver_id",
    "matchedDriverId",
    "accepted_driver_id",
    "acceptedDriverId",
    "driver_id",
    "driverId",
  ]) {
    const id = normUid(row[k]);
    if (id && !isPlaceholderDriverId(row[k])) return id;
  }
  return "";
}

function locationSnapshot(loc, addressHint) {
  const o = loc && typeof loc === "object" ? loc : {};
  const lat = Number(o.lat ?? o.latitude ?? NaN);
  const lng = Number(o.lng ?? o.longitude ?? NaN);
  const address = String(
    o.address ??
      o.formatted_address ??
      o.business_name ??
      o.name ??
      addressHint ??
      "",
  ).trim();
  return {
    lat: Number.isFinite(lat) ? lat : null,
    lng: Number.isFinite(lng) ? lng : null,
    address: address.slice(0, 500) || null,
  };
}

function numOrNull(v) {
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? n : null;
}

function buildRideHistoryRecord(rideId, ride) {
  const rid = normUid(rideId);
  const riderId = normUid(ride.rider_id ?? ride.riderId);
  const driverId = canonicalAssignedDriverId(ride);
  const pickup = locationSnapshot(
    ride.pickup,
    ride.pickup_address ?? ride.pickupAddress ?? ride.pickup_area,
  );
  const destination = locationSnapshot(
    ride.destination ?? ride.dropoff,
    ride.destination_address ??
      ride.final_destination_address ??
      ride.dropoff_area ??
      ride.destination_area,
  );
  const status = String(ride.status ?? "").trim();
  const tripState = String(ride.trip_state ?? ride.tripState ?? "").trim();
  const createdAt = numOrNull(ride.created_at ?? ride.createdAt);
  const startedAt = numOrNull(
    ride.started_at ?? ride.trip_started_at ?? ride.accepted_at ?? ride.acceptedAt,
  );
  const completedAt = numOrNull(ride.completed_at ?? ride.completedAt);
  const cancelledAt = numOrNull(ride.cancelled_at ?? ride.cancelledAt);
  const terminalAt = completedAt ?? cancelledAt ?? numOrNull(ride.updated_at ?? ride.updatedAt);

  return {
    rideId: rid,
    type: "ride",
    status,
    trip_state: tripState,
    pickup,
    destination,
    pickup_address: pickup.address,
    destination_address: destination.address,
    fare: Number(ride.fare ?? ride.trip_fare_ngn ?? 0) || 0,
    distance: Number(ride.distance_km ?? ride.distance ?? 0) || 0,
    createdAt,
    startedAt,
    completedAt,
    cancelledAt,
    riderId: riderId || null,
    driverId: driverId || null,
    service_type: String(ride.service_type ?? ride.serviceType ?? "ride").trim() || "ride",
    cancel_reason: String(ride.cancel_reason ?? ride.cancelReason ?? "").trim().slice(0, 200) || null,
    // Legacy flat keys for existing UI helpers
    trip_id: rid,
    created_at: createdAt,
    started_at: startedAt,
    completed_at: completedAt,
    cancelled_at: cancelledAt,
    timestamp: terminalAt,
    driver_id: driverId || null,
    updated_at: numOrNull(ride.updated_at ?? ride.updatedAt) ?? Date.now(),
  };
}

function buildDeliveryOrderHistoryRecord(deliveryId, row) {
  const did = normUid(deliveryId);
  const merchantOrderId = normUid(row.merchant_order_id ?? row.merchantOrderId);
  const orderId = merchantOrderId || did;
  const riderId = normUid(row.customer_id ?? row.rider_id ?? row.customerId);
  const driverId = canonicalAssignedDriverId(row);
  const pickup = locationSnapshot(row.pickup, row.pickup_address ?? row.pickup_area);
  const destination = locationSnapshot(
    row.dropoff ?? row.destination,
    row.dropoff_address ?? row.destination_address ?? row.dropoff_area,
  );
  const deliveryState = String(row.delivery_state ?? "").trim();
  const status = String(row.status ?? deliveryState).trim();
  const tripState = String(row.trip_state ?? row.tripState ?? "").trim();
  const createdAt = numOrNull(row.created_at ?? row.createdAt);
  const startedAt = numOrNull(row.accepted_at ?? row.picked_up_at);
  const completedAt = numOrNull(row.completed_at ?? row.completedAt);
  const cancelledAt = numOrNull(row.cancelled_at ?? row.cancelledAt);
  const terminalAt = completedAt ?? cancelledAt ?? numOrNull(row.updated_at);

  return {
    orderId,
    deliveryId: did,
    merchant_order_id: merchantOrderId || null,
    merchant_id: normUid(row.merchant_id ?? row.merchantId) || null,
    type: "order",
    status,
    trip_state: tripState,
    delivery_state: deliveryState,
    pickup,
    destination,
    pickup_address: pickup.address,
    destination_address: destination.address,
    fare: Number(row.total_ngn ?? row.fare ?? 0) || 0,
    distance: Number(row.distance_km ?? row.distance ?? 0) || 0,
    createdAt,
    startedAt,
    completedAt,
    cancelledAt,
    riderId: riderId || null,
    driverId: driverId || null,
    service_type: String(row.service_type ?? row.serviceType ?? "dispatch_delivery").trim(),
    cancel_reason: String(row.cancel_reason ?? row.cancelReason ?? "").trim().slice(0, 200) || null,
    food_order_summary: String(row.food_order_summary ?? "").trim().slice(0, 500) || null,
    trip_id: orderId,
    order_id: orderId,
    created_at: createdAt,
    started_at: startedAt,
    completed_at: completedAt,
    cancelled_at: cancelledAt,
    timestamp: terminalAt,
    driver_id: driverId || null,
    updated_at: numOrNull(row.updated_at ?? row.updatedAt) ?? Date.now(),
  };
}

function buildMerchantOrderHistoryRecord(orderId, order) {
  const oid = normUid(orderId);
  const riderId = normUid(order.customer_uid ?? order.customerUid);
  const pickup = locationSnapshot(
    order.pickup_snapshot,
    order.pickup_snapshot?.business_name ?? order.merchant_name,
  );
  const destination = locationSnapshot(order.dropoff_snapshot, order.recipient_name);
  const status = String(order.order_status ?? "").trim();
  const createdAt = numOrNull(
    order.created_at?.toMillis?.() ?? (order.created_at?._seconds ?? 0) * 1000 ?? order.created_at,
  );
  const completedAt =
    status === "completed"
      ? numOrNull(
          order.completed_at?.toMillis?.() ??
            (order.completed_at?._seconds ?? 0) * 1000 ??
            order.completed_at,
        ) ?? Date.now()
      : null;
  const cancelledAt =
    status === "cancelled" || status === "merchant_rejected"
      ? numOrNull(
          order.cancelled_at?.toMillis?.() ??
            (order.cancelled_at?._seconds ?? 0) * 1000 ??
            order.updated_at?.toMillis?.() ??
            (order.updated_at?._seconds ?? 0) * 1000,
        ) ?? Date.now()
      : null;
  const terminalAt = completedAt ?? cancelledAt ?? createdAt;

  return {
    orderId: oid,
    deliveryId: normUid(order.delivery_id ?? order.deliveryId) || null,
    merchant_order_id: oid,
    merchant_id: normUid(order.merchant_id ?? order.merchantId) || null,
    type: "order",
    status,
    trip_state: status,
    pickup,
    destination,
    pickup_address: pickup.address,
    destination_address: destination.address,
    fare: Number(order.total_ngn ?? order.totalNgn ?? 0) || 0,
    distance: Number(order.distance_km ?? 0) || 0,
    createdAt,
    startedAt: null,
    completedAt,
    cancelledAt,
    riderId: riderId || null,
    driverId: null,
    service_type: String(order.order_flow ?? order.orderFlow ?? "food_order").trim() || "food_order",
    cancel_reason:
      status === "merchant_rejected"
        ? "merchant_rejected"
        : status === "cancelled"
          ? "cancelled"
          : null,
    trip_id: oid,
    order_id: oid,
    created_at: createdAt,
    completed_at: completedAt,
    cancelled_at: cancelledAt,
    timestamp: terminalAt,
    driver_id: null,
    updated_at: Date.now(),
  };
}

async function applyHistoryUpdates(db, updates) {
  if (!updates || typeof updates !== "object" || !Object.keys(updates).length) {
    return;
  }
  await db.ref().update(updates);
}

/**
 * Persist completed/cancelled/expired ride to durable history nodes.
 * @param {import("firebase-admin/database").Database} db
 * @param {string} rideId
 * @param {Record<string, unknown>} ride
 */
async function persistRideTerminalHistory(db, rideId, ride) {
  if (!ride || typeof ride !== "object") return;
  const record = buildRideHistoryRecord(rideId, ride);
  const riderId = record.riderId;
  const driverId = record.driverId;
  const updates = {};
  if (riderId) {
    updates[`user_trip_history/${riderId}/${record.rideId}`] = record;
    updates[`rider_trips/${riderId}/${record.rideId}`] = record;
  }
  if (driverId) {
    updates[`driver_trip_history/${driverId}/${record.rideId}`] = record;
    updates[`driver_trips/${driverId}/${record.rideId}`] = record;
  }
  if (!Object.keys(updates).length) return;
  await applyHistoryUpdates(db, updates);
  console.log(
    "TRIP_HISTORY_PERSIST_OK",
    `rideId=${record.rideId}`,
    `type=ride`,
    `rider=${Boolean(riderId)}`,
    `driver=${Boolean(driverId)}`,
    `status=${record.status}`,
  );
}

/**
 * @param {import("firebase-admin/database").Database} db
 * @param {string} deliveryId
 * @param {Record<string, unknown>} row
 */
async function persistDeliveryTerminalHistory(db, deliveryId, row) {
  if (!row || typeof row !== "object") return;
  const record = buildDeliveryOrderHistoryRecord(deliveryId, row);
  const riderId = record.riderId;
  const driverId = record.driverId;
  const orderId = record.orderId;
  const updates = {};
  if (riderId && orderId) {
    updates[`user_order_history/${riderId}/${orderId}`] = record;
  }
  if (driverId && orderId) {
    updates[`driver_order_history/${driverId}/${orderId}`] = record;
  }
  if (!Object.keys(updates).length) return;
  await applyHistoryUpdates(db, updates);
  console.log(
    "TRIP_HISTORY_PERSIST_OK",
    `orderId=${orderId}`,
    `deliveryId=${record.deliveryId}`,
    `type=order`,
    `rider=${Boolean(riderId)}`,
    `driver=${Boolean(driverId)}`,
    `status=${record.status}`,
  );
}

/**
 * @param {import("firebase-admin/database").Database} db
 * @param {string} orderId
 * @param {Record<string, unknown>} order
 */
async function persistMerchantOrderTerminalHistory(db, orderId, order) {
  if (!order || typeof order !== "object") return;
  const record = buildMerchantOrderHistoryRecord(orderId, order);
  const riderId = record.riderId;
  const orderKey = record.orderId;
  if (!riderId || !orderKey) return;
  const updates = {
    [`user_order_history/${riderId}/${orderKey}`]: record,
  };
  await applyHistoryUpdates(db, updates);
  console.log(
    "TRIP_HISTORY_PERSIST_OK",
    `orderId=${orderKey}`,
    `type=merchant_order`,
    `rider=${Boolean(riderId)}`,
    `status=${record.status}`,
  );
}

module.exports = {
  buildRideHistoryRecord,
  buildDeliveryOrderHistoryRecord,
  buildMerchantOrderHistoryRecord,
  persistRideTerminalHistory,
  persistDeliveryTerminalHistory,
  persistMerchantOrderTerminalHistory,
};
