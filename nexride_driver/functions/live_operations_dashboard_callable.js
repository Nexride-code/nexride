/**
 * Admin-only aggregated live operations dashboard (single bounded callable).
 * Reads RTDB + Firestore sources aligned with rider/driver/dispatch flows.
 */

const admin = require("firebase-admin");
const { logger } = require("firebase-functions");
const { normUid } = require("./admin_auth");
const adminPerms = require("./admin_permissions");
const adminCallables = require("./admin_callables");

const firestore = () => admin.firestore();

const SAMPLE_LIMIT = 20;
const DRIVERS_SCAN_CAP = 800;
const MERCHANTS_SCAN_CAP = 200;
const MERCHANT_ORDERS_QUERY_CAP = 80;
const STALE_DRIVER_HEARTBEAT_MS = 180_000;
const STALE_MERCHANT_PORTAL_MS = 600_000;
const MERCHANT_ORDER_DELAYED_MS = 25 * 60 * 1000;
const UNMATCHED_RIDE_ALERT_SEC = 60;
const PORTAL_ONLINE_MS = 120_000;

async function requireAdmin(db, ctx, name) {
  const err = await adminPerms.enforceCallable(db, ctx, name);
  if (err) {
    logger.warn(`${name}_rbac_denied`, { uid: normUid(ctx?.auth?.uid), ...err });
  }
  return err;
}

function nowMs() {
  return Date.now();
}

function takeSample(arr, n = SAMPLE_LIMIT) {
  if (!Array.isArray(arr)) return [];
  return arr.slice(0, n);
}

function isTerminalUiBucket(b) {
  return b === "completed" || b === "cancelled";
}

function bucketOnlineMode(drow) {
  const m = String(
    drow?.online_availability_mode ??
      drow?.availability_mode ??
      drow?.last_availability_intent ??
      "",
  )
    .trim()
    .toLowerCase();
  if (m.includes("service") || m === "area" || m === "city") return "service_area";
  if (m.includes("current") || m === "gps" || m === "live") return "current_location";
  return "unknown";
}

function isDriverRowOnline(drow) {
  return drow?.online === true || drow?.is_online === true || drow?.isOnline === true;
}

function firestoreTsMs(ts) {
  if (!ts) return 0;
  if (typeof ts.toMillis === "function") return Number(ts.toMillis()) || 0;
  if (ts._seconds) return Number(ts._seconds) * 1000 || 0;
  return 0;
}

async function adminGetLiveOperationsDashboard(data, context, db) {
  const name = "adminGetLiveOperationsDashboard";
  const denyLod = await requireAdmin(db, context, name);
  if (denyLod) return denyLod;

  const includeDebug = data && data.includeDebugMetrics === true;
  const t0 = nowMs();
  const source_debug = includeDebug
    ? {
        started_ms: t0,
        caps: {
          drivers_scan: DRIVERS_SCAN_CAP,
          merchants_scan: MERCHANTS_SCAN_CAP,
          merchant_orders_query: MERCHANT_ORDERS_QUERY_CAP,
          sample_rows: SAMPLE_LIMIT,
        },
        paths: [],
      }
    : null;

  const pushPath = (p) => {
    if (source_debug && source_debug.paths.length < 40) {
      source_debug.paths.push(p);
    }
  };

  const [liveTripsRes, onlineDriversRes, onlineDrvMirrorSnap, driversScanSnap] = await Promise.all([
    adminCallables.adminListLiveTrips({}, context, db),
    adminCallables.adminListOnlineDrivers({}, context, db),
    db.ref("online_drivers").limitToFirst(500).get(),
    db.ref("drivers").orderByKey().limitToFirst(DRIVERS_SCAN_CAP).get(),
  ]);
  pushPath("ride_requests+delivery_requests (via adminListLiveTrips)");
  pushPath("active_trips+active_deliveries+drivers (via adminListOnlineDrivers)");
  pushPath("online_drivers (mirror, capped)");
  pushPath(`drivers (scan cap=${DRIVERS_SCAN_CAP})`);

  if (!liveTripsRes.success) {
    return { success: false, reason: liveTripsRes.reason || "live_trips_failed" };
  }
  if (!onlineDriversRes.success) {
    return { success: false, reason: onlineDriversRes.reason || "online_drivers_failed" };
  }

  const trips = Array.isArray(liveTripsRes.trips) ? liveTripsRes.trips : [];
  const onlineList = Array.isArray(onlineDriversRes.drivers) ? onlineDriversRes.drivers : [];

  const rideRows = trips.filter((t) => t && (t.trip_kind === "ride" || t.trip_kind === "delivery"));

  let active = 0;
  let requesting = 0;
  let matched = 0;
  let inProgress = 0;
  let unmatchedOver60 = 0;
  let noDriverRecent = 0;
  const matchedBuckets = new Set(["accepted", "driver_arriving", "arrived", "arrived_pickup"]);

  const n = nowMs();
  for (const t of rideRows) {
    const b = String(t.ui_bucket || "").trim();
    if (isTerminalUiBucket(b)) continue;
    active += 1;
    if (b === "searching") {
      requesting += 1;
      const ageSec = Math.floor((Number(t.elapsed_ms) || 0) / 1000);
      if (ageSec > UNMATCHED_RIDE_ALERT_SEC) unmatchedOver60 += 1;
      else noDriverRecent += 1;
    }
    if (matchedBuckets.has(b)) matched += 1;
    if (b === "in_progress") inProgress += 1;
  }

  const ridesSample = takeSample(
    rideRows
      .filter((t) => !isTerminalUiBucket(String(t.ui_bucket || "").trim()))
      .sort((a, b) => (Number(b.updated_at) || 0) - (Number(a.updated_at) || 0)),
  );

  const onlineMirror =
    onlineDrvMirrorSnap.val() && typeof onlineDrvMirrorSnap.val() === "object"
      ? onlineDrvMirrorSnap.val()
      : {};

  const rawDrivers =
    driversScanSnap.val() && typeof driversScanSnap.val() === "object" ? driversScanSnap.val() : {};

  let total = 0;
  let online = 0;
  let offline = 0;
  let current_location_mode = 0;
  let service_area_mode = 0;
  let stale_heartbeat = 0;
  let active_trip = 0;
  let idle_online = 0;

  const staleDriverRows = [];
  const driverSampleScratch = [];

  const busyIds = new Set(
    onlineList.filter((d) => d && d.active_trip_id).map((d) => normUid(d.driver_id)).filter(Boolean),
  );
  for (const row of onlineList) {
    if (row?.active_trip_id) active_trip += 1;
    else idle_online += 1;
  }

  for (const [uid, drow] of Object.entries(rawDrivers)) {
    if (!drow || typeof drow !== "object") continue;
    total += 1;
    const id = normUid(uid);
    const on = isDriverRowOnline(drow);
    if (on) {
      online += 1;
      const mode = bucketOnlineMode(drow);
      if (mode === "current_location") current_location_mode += 1;
      else if (mode === "service_area") service_area_mode += 1;

      const drvUpdated = Number(drow.updated_at ?? 0) || 0;
      const mirrorRow = onlineMirror[id];
      const mirrorTs = mirrorRow && typeof mirrorRow === "object" ? Number(mirrorRow.updated_at ?? 0) || 0 : 0;
      const heartbeatMs = Math.max(drvUpdated, mirrorTs);
      const stale = heartbeatMs > 0 && n - heartbeatMs > STALE_DRIVER_HEARTBEAT_MS;
      if (stale) {
        stale_heartbeat += 1;
        staleDriverRows.push({
          driver_id: id,
          name: String(drow.name ?? drow.full_name ?? drow.display_name ?? "").trim() || null,
          updated_at: drvUpdated || null,
          online_drivers_updated_at: mirrorTs || null,
          market: String(drow.dispatch_market ?? drow.market ?? drow.market_pool ?? "").trim() || null,
          region_id: String(drow.dispatch_market_id ?? drow.region_id ?? drow.market_pool ?? "").trim() || null,
          age_seconds: heartbeatMs > 0 ? Math.floor((n - heartbeatMs) / 1000) : null,
        });
      }
      driverSampleScratch.push({
        driver_id: id,
        name: String(drow.name ?? drow.full_name ?? drow.display_name ?? "").trim() || null,
        online: true,
        driver_class: busyIds.has(id) ? "busy" : "idle",
        market: String(drow.dispatch_market ?? drow.market ?? drow.market_pool ?? "").trim() || null,
        region_id: String(drow.dispatch_market_id ?? drow.region_id ?? "").trim() || null,
        updated_at: drvUpdated || null,
        mirror_updated_at: mirrorTs || null,
        stale_heartbeat: stale,
      });
    } else {
      offline += 1;
    }
  }

  staleDriverRows.sort((a, b) => (b.age_seconds || 0) - (a.age_seconds || 0));
  const driversSample = [];
  const sampleSeen = new Set();
  for (const s of staleDriverRows) {
    if (driversSample.length >= SAMPLE_LIMIT) break;
    if (sampleSeen.has(s.driver_id)) continue;
    sampleSeen.add(s.driver_id);
    driversSample.push({ ...s, sample_reason: "stale_heartbeat" });
  }
  const restOnline = [...driverSampleScratch].sort(
    (a, b) => (Number(b.updated_at) || 0) - (Number(a.updated_at) || 0),
  );
  for (const d of restOnline) {
    if (driversSample.length >= SAMPLE_LIMIT) break;
    if (sampleSeen.has(d.driver_id)) continue;
    sampleSeen.add(d.driver_id);
    driversSample.push(d);
  }

  /** Merchants + portal (Firestore, bounded scan). */
  let merchantsTotal = 0;
  let merchantsOpen = 0;
  let merchantsClosed = 0;
  let orders_live = 0;
  let portal_online = 0;
  let stale_portal = 0;
  const merchantPortalSample = [];

  try {
    const cnt = await firestore().collection("merchants").count().get();
    merchantsTotal = Number(cnt.data().count) || 0;
    pushPath("firestore:merchants.count()");
  } catch (e) {
    logger.warn(`${name}: merchants count failed`, { err: String(e?.message || e) });
  }

  try {
    const q = await firestore().collection("merchants").limit(MERCHANTS_SCAN_CAP).get();
    pushPath(`firestore:merchants.scan(limit=${MERCHANTS_SCAN_CAP})`);
    for (const doc of q.docs) {
      const m = doc.data() || {};
      const open =
        m.is_open == null ? true : Boolean(m.is_open);
      const av = String(m.availability_status ?? "").trim().toLowerCase();
      const effOpen = open && av !== "closed" && av !== "offline";
      if (effOpen) merchantsOpen += 1;
      else merchantsClosed += 1;
      const ol = Number(m.orders_live ?? 0) || 0;
      if (ol > 0) orders_live += 1;
      const pls = m.portal_last_seen_ms != null ? Number(m.portal_last_seen_ms) : null;
      const portalOk = pls != null && n - pls < PORTAL_ONLINE_MS;
      if (portalOk) portal_online += 1;
      if (effOpen && pls != null && n - pls > STALE_MERCHANT_PORTAL_MS) stale_portal += 1;

      merchantPortalSample.push({
        merchant_id: doc.id,
        business_name: String(m.business_name ?? m.name ?? "").trim() || null,
        is_open: open,
        availability_status: av || null,
        portal_last_seen_ms: pls,
        orders_live: ol,
        region_id: m.region_id != null ? String(m.region_id) : null,
      });
    }
  } catch (e) {
    logger.warn(`${name}: merchants scan failed`, { err: String(e?.message || e) });
  }

  /** merchant_orders aggregate (Firestore). */
  const mo = {
    active: 0,
    pending: 0,
    accepted: 0,
    preparing: 0,
    ready: 0,
    delayed: 0,
    sample: [],
  };
  const TERMINAL_ORDER_STATUSES = ["completed", "cancelled", "merchant_rejected"];
  const delayedOrdersScratch = [];
  try {
    const fs = firestore();
    const ordersSnap = await fs
      .collection("merchant_orders")
      .where("order_status", "not-in", TERMINAL_ORDER_STATUSES)
      .orderBy("order_status")
      .orderBy("created_at", "desc")
      .limit(MERCHANT_ORDERS_QUERY_CAP)
      .get();
    pushPath(`firestore:merchant_orders(not-in terminal, cap=${MERCHANT_ORDERS_QUERY_CAP})`);
    for (const doc of ordersSnap.docs) {
      const o = doc.data() || {};
      const ost = String(o.order_status ?? "").trim().toLowerCase();
      if (TERMINAL_ORDER_STATUSES.includes(ost)) continue;
      mo.active += 1;
      if (ost === "pending_merchant") mo.pending += 1;
      if (ost === "merchant_accepted") mo.accepted += 1;
      if (ost === "preparing") mo.preparing += 1;
      if (ost === "ready_for_pickup" || ost === "dispatching") mo.ready += 1;
      const updatedMs = firestoreTsMs(o.updated_at) || firestoreTsMs(o.created_at);
      if (updatedMs && n - updatedMs > MERCHANT_ORDER_DELAYED_MS) {
        mo.delayed += 1;
        delayedOrdersScratch.push({
          order_id: doc.id,
          merchant_id: normUid(o.merchant_id),
          order_status: ost,
          updated_at: updatedMs,
          region_id: o.region_id != null ? String(o.region_id) : (o.market != null ? String(o.market) : null),
          age_seconds: Math.floor((n - updatedMs) / 1000),
        });
      }
    }
    const attention = delayedOrdersScratch.concat(
      ordersSnap.docs
        .map((d) => {
          const o = d.data() || {};
          const ost = String(o.order_status ?? "").trim().toLowerCase();
          if (TERMINAL_ORDER_STATUSES.includes(ost)) return null;
          const updatedMs = firestoreTsMs(o.updated_at) || firestoreTsMs(o.created_at);
          return {
            order_id: d.id,
            merchant_id: normUid(o.merchant_id),
            order_status: ost,
            updated_at: updatedMs,
            region_id: o.region_id != null ? String(o.region_id) : null,
            age_seconds: updatedMs ? Math.floor((n - updatedMs) / 1000) : null,
          };
        })
        .filter(Boolean),
    );
    const seen = new Set();
    const merged = [];
    for (const row of attention) {
      if (seen.has(row.order_id)) continue;
      seen.add(row.order_id);
      merged.push(row);
    }
    merged.sort((a, b) => (b.age_seconds || 0) - (a.age_seconds || 0));
    mo.sample = takeSample(merged);
  } catch (e) {
    logger.warn(`${name}: merchant_orders query failed`, { err: String(e?.message || e) });
  }

  /** Optional: RTDB merchant_public_teaser keys (bounded). */
  let teaser_keys = 0;
  try {
    const ts = await db.ref("merchant_public_teaser").limitToFirst(120).get();
    const v = ts.val() && typeof ts.val() === "object" ? ts.val() : {};
    teaser_keys = Object.keys(v).length;
    pushPath("merchant_public_teaser(limitToFirst 120)");
  } catch (e) {
    logger.warn(`${name}: merchant_public_teaser read failed`, { err: String(e?.message || e) });
  }

  /** Withdrawals / support (lightweight, same paths as adminGetOperationsDashboard). */
  let pending_withdrawals = 0;
  let support_open = 0;
  try {
    const wdSnap = await db.ref("withdraw_requests").orderByChild("status").equalTo("pending").limitToFirst(200).get();
    const wdVal = wdSnap.val() && typeof wdSnap.val() === "object" ? wdSnap.val() : {};
    pending_withdrawals = Object.keys(wdVal).length;
    pushPath("withdraw_requests(status=pending)");
  } catch (_) {}
  try {
    const tSnap = await db.ref("support_tickets").orderByChild("status").equalTo("open").limitToFirst(200).get();
    const tVal = tSnap.val() && typeof tSnap.val() === "object" ? tSnap.val() : {};
    support_open = Object.keys(tVal).length;
    pushPath("support_tickets(status=open)");
  } catch (_) {}

  const merchantsSample = takeSample(
    merchantPortalSample
      .filter((x) => x.portal_last_seen_ms != null)
      .sort((a, b) => (b.portal_last_seen_ms || 0) - (a.portal_last_seen_ms || 0)),
  );

  /** Alerts (Phase 3) — computed only, no new collections. */
  const alerts = [];

  for (const s of staleDriverRows.slice(0, 12)) {
    alerts.push({
      type: "stale_driver_heartbeat",
      severity: "warning",
      title: "Stale driver heartbeat",
      message: `Driver ${s.driver_id} online flag set but heartbeat is old.`,
      entity_id: s.driver_id,
      region_id: s.region_id || null,
      age_seconds: s.age_seconds ?? 0,
    });
  }

  const unmatchedAlertIds = new Set();
  for (const t of rideRows) {
    const b = String(t.ui_bucket || "").trim();
    if (b !== "searching") continue;
    const ageSec = Math.floor((Number(t.elapsed_ms) || 0) / 1000);
    if (ageSec <= UNMATCHED_RIDE_ALERT_SEC) continue;
    const tid = String(t.trip_id || "");
    if (!tid || unmatchedAlertIds.has(tid)) continue;
    if (unmatchedAlertIds.size >= 15) break;
    unmatchedAlertIds.add(tid);
    const reg = t.region ? String(t.region).trim() : "";
    alerts.push({
      type: "unmatched_ride_request",
      severity: ageSec > 300 ? "critical" : "warning",
      title: "Unmatched ride request",
      message: `${t.trip_kind || "ride"} ${t.trip_id} still searching (${ageSec}s).`,
      entity_id: tid,
      region_id: reg && reg !== "—" ? reg : null,
      age_seconds: ageSec,
    });
  }

  for (const ord of delayedOrdersScratch.slice(0, 12)) {
    alerts.push({
      type: "merchant_order_delayed",
      severity: "warning",
      title: "Merchant order delayed",
      message: `Order ${ord.order_id} in status ${ord.order_status} exceeded SLA window.`,
      entity_id: ord.order_id,
      region_id: ord.region_id || null,
      age_seconds: ord.age_seconds ?? 0,
    });
  }

  for (const m of merchantPortalSample) {
    const pls = m.portal_last_seen_ms;
    const open = m.is_open !== false && String(m.availability_status ?? "").trim().toLowerCase() !== "closed";
    if (!open || pls == null) continue;
    if (n - pls <= STALE_MERCHANT_PORTAL_MS) continue;
    if (alerts.filter((a) => a.type === "merchant_portal_stale").length >= 12) break;
    alerts.push({
      type: "merchant_portal_stale",
      severity: "info",
      title: "Merchant portal stale",
      message: `${m.business_name || m.merchant_id} portal last seen is old while store appears open.`,
      entity_id: m.merchant_id,
      region_id: m.region_id || null,
      age_seconds: Math.floor((n - pls) / 1000),
    });
  }

  if (includeDebug) {
    source_debug.finished_ms = nowMs();
    source_debug.duration_ms = source_debug.finished_ms - source_debug.started_ms;
    source_debug.pending_withdrawals = pending_withdrawals;
    source_debug.support_tickets_open = support_open;
    source_debug.teaser_keys_sample = teaser_keys;
    source_debug.drivers_scan_total = total;
    source_debug.drivers_scan_capped = total >= DRIVERS_SCAN_CAP;
    source_debug.merchants_scan_capped = merchantPortalSample.length >= MERCHANTS_SCAN_CAP;
  }

  return {
    success: true,
    now_ms: n,
    drivers: {
      total,
      online,
      offline,
      current_location_mode,
      service_area_mode,
      stale_heartbeat,
      active_trip,
      idle_online,
      sample: driversSample,
    },
    rides: {
      active,
      requesting,
      matched,
      in_progress: inProgress,
      unmatched_over_60s: unmatchedOver60,
      no_driver_recent: noDriverRecent,
      sample: ridesSample,
    },
    merchants: {
      total: merchantsTotal,
      open: merchantsOpen,
      closed: merchantsClosed,
      orders_live,
      portal_online,
      stale_portal,
      sample: takeSample(merchantsSample),
    },
    merchant_orders: mo,
    alerts: takeSample(alerts, 50),
    ...(includeDebug ? { source_debug } : {}),
  };
}

module.exports = {
  adminGetLiveOperationsDashboard,
};
