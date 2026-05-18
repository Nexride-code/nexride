/**
 * Scheduled recovery — delegates to dispatch_orchestrator (no duplicate mutation logic).
 */

"use strict";

const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");
const { logger } = require("firebase-functions");
const { REGION } = require("../params");
const { runScheduledOrchestratorTick } = require("./dispatch_orchestrator");
const { expireStaleLeasesImpl } = require("./dispatch_offer_lease_engine");
const { orchestrateBatchAdvance } = require("./dispatch_orchestrator");

async function dispatchWatchdogImpl(db) {
  return runScheduledOrchestratorTick(db, "dispatchWatchdog");
}

async function adminExpireRideLeases(data, context, db) {
  const { requireAdmin } = require("../admin_auth");
  const deny = await requireAdmin(db, context, "adminExpireRideLeases");
  if (deny) return deny;

  const rideId = String(data?.rideId ?? data?.ride_id ?? "").trim();
  const result = await expireStaleLeasesImpl(db);
  let advanced = 0;
  if (rideId) {
    const res = await orchestrateBatchAdvance(db, rideId);
    if (res && res.ok) advanced = 1;
  } else if (result.ridesNeedingAdvance?.length) {
    for (const rid of result.ridesNeedingAdvance) {
      const res = await orchestrateBatchAdvance(db, rid);
      if (res && res.ok) advanced += 1;
    }
  }

  return {
    success: true,
    reason: "leases_expired",
    ride_id: rideId || null,
    expired: result.expired,
    advanced,
  };
}

const dispatchWatchdog = onSchedule(
  { schedule: "every 1 minutes", timeZone: "Africa/Lagos", region: REGION },
  async () => {
    const db = admin.database();
    try {
      const stats = await dispatchWatchdogImpl(db);
      logger.info("DISPATCH_WATCHDOG_OK", stats);
    } catch (e) {
      logger.error("DISPATCH_WATCHDOG_FAIL", { error: String(e?.message || e) });
    }
  },
);

module.exports = {
  dispatchWatchdog,
  dispatchWatchdogImpl,
  adminExpireRideLeases,
};
