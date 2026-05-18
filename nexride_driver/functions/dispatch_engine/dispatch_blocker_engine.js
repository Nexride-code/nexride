/**
 * Stale driver blocker repair — delegates to repair module, unified logging.
 */

"use strict";

const {
  repairDriverDispatchBlockers,
  evaluateDriverBlocker,
  collectDriversToRepairForRide,
} = require("../repair_driver_dispatch_blockers");
const { incrementMetric } = require("./dispatch_metrics_engine");
const { normUid } = require("./dispatch_trip_state_engine");

async function repairDriverBlockers(db, driverId, options = {}) {
  const result = await repairDriverDispatchBlockers(db, driverId, options);
  const incoming = normUid(options.incomingRideId);
  if (incoming && result.cleared) {
    await incrementMetric(db, incoming, "stale_blocker_count", result.clearedTripIds?.length || 1);
    await incrementMetric(db, incoming, "repair_count", 1);
  }
  return result;
}

module.exports = {
  repairDriverDispatchBlockers: repairDriverBlockers,
  evaluateDriverBlocker,
  collectDriversToRepairForRide,
};
