/**
 * Active trip / assignment consistency repairs.
 */

"use strict";

const { normUid, rideIsOpenForMatching, canonicalAssignedDriverId } = require("./dispatch_trip_state_engine");
const { rideDocumentIsTerminal } = require("../ride_pointer_orphans");
const { emitPipelineEvent } = require("./dispatch_pipeline_events_engine");

async function repairRideActiveTripMismatch(db, rideId, ride, activeTrip, reason) {
  const rid = normUid(rideId);
  if (!rid) return false;
  const assigned = canonicalAssignedDriverId(ride);
  const updates = {};

  if (rideIsOpenForMatching(ride) && activeTrip) {
    const atDriver = normUid(activeTrip.driver_id ?? activeTrip.driverId);
    if (!assigned || (atDriver && atDriver !== assigned)) {
      updates[`active_trips/${rid}`] = null;
    }
  }

  if (assigned && !activeTrip && !rideIsOpenForMatching(ride)) {
    updates[`active_trips/${rid}/driver_id`] = assigned;
    updates[`active_trips/${rid}/trip_state`] =
      ride.trip_state ?? ride.status ?? "driver_assigned";
    updates[`active_trips/${rid}/repaired_at_ms`] = Date.now();
  }

  if (ride && rideDocumentIsTerminal(ride) && activeTrip) {
    updates[`active_trips/${rid}`] = null;
  }

  if (!Object.keys(updates).length) return false;

  await db.ref().update(updates);
  console.log(
    "ACTIVE_TRIP_CONSISTENCY_REPAIR",
    `rideId=${rid}`,
    `reason=${reason}`,
    `keys=${Object.keys(updates).length}`,
  );
  await emitPipelineEvent(db, rid, {
    stage: "ACTIVE_TRIP_CONSISTENCY_REPAIR",
    reason,
  });
  return true;
}

async function sweepActiveTripConsistency(db, limit = 150) {
  let scanned = 0;
  let repaired = 0;

  const [ridesSnap, activeSnap] = await Promise.all([
    db.ref("ride_requests").limitToFirst(limit).get(),
    db.ref("active_trips").limitToFirst(limit).get(),
  ]);

  const rides = ridesSnap.val() && typeof ridesSnap.val() === "object" ? ridesSnap.val() : {};
  const active =
    activeSnap.val() && typeof activeSnap.val() === "object" ? activeSnap.val() : {};

  const rideIds = new Set([...Object.keys(rides), ...Object.keys(active)]);

  for (const rideId of rideIds) {
    const rid = normUid(rideId);
    if (!rid) continue;
    scanned += 1;
    const ride = rides[rideId] && typeof rides[rideId] === "object" ? rides[rideId] : null;
    const activeTrip =
      active[rideId] && typeof active[rideId] === "object" ? active[rideId] : null;
    if (!ride && !activeTrip) continue;

    const did = await repairRideActiveTripMismatch(
      db,
      rid,
      ride || {},
      activeTrip,
      "scheduled_sweep",
    );
    if (did) repaired += 1;
  }

  return { scanned, repaired };
}

module.exports = {
  repairRideActiveTripMismatch,
  sweepActiveTripConsistency,
};
