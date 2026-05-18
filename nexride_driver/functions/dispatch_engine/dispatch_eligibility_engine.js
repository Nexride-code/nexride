/**
 * Driver eligibility filtering for matching pipeline.
 */

"use strict";

const { evaluateDriverMatchCandidate } = require("../driver_match_ranking");
const {
  resolveValidatedBlockingTripForDriver,
} = require("../driver_active_pointer_guard");
const { normUid } = require("./dispatch_trip_state_engine");

async function evaluateDriverForMatching(
  db,
  driverId,
  profile,
  ridePayload,
  gates,
  now,
  rideId,
  ctx = {},
) {
  const d = normUid(driverId);
  let busyRid = null;
  const resolved = await resolveValidatedBlockingTripForDriver(
    db,
    d,
    "dispatch_eligibility",
    normUid(rideId),
  );
  busyRid = resolved.blockingTripId;
  const cand = evaluateDriverMatchCandidate(d, profile, ridePayload, gates, now, {
    activeRideId: busyRid,
    useSoft: ctx.useSoft === true,
    driverLastSeenMs:
      Number(profile?.last_active_at ?? profile?.last_seen_at ?? 0) || null,
  });
  cand._profile = profile;
  cand._blockerCleared = resolved.cleared;
  const { applyHealthScoreToCandidate } = require("./dispatch_health_engine");
  return applyHealthScoreToCandidate(db, d, profile, cand);
}

module.exports = {
  evaluateDriverForMatching,
  evaluateDriverMatchCandidate,
};
