"use strict";

const assert = require("node:assert/strict");
const {
  matchingStatusFromCounts,
  isRecentOpenMatchingTripRow,
  isMatchingDispatchFailure,
  ACTIVE_OPEN_MATCHING_MAX_AGE_MS,
} = require("../matching_health");

assert.equal(
  matchingStatusFromCounts({ open: 2, withOffers: 1, noOffers: 1, eligibleOnline: 3 }),
  "red",
);
assert.equal(
  matchingStatusFromCounts({ open: 2, withOffers: 1, noOffers: 1, eligibleOnline: 0 }),
  "yellow",
);
assert.equal(
  matchingStatusFromCounts({ open: 2, withOffers: 2, noOffers: 0, eligibleOnline: 3 }),
  "green",
);
assert.equal(
  matchingStatusFromCounts({ open: 1, withOffers: 0, noOffers: 1, eligibleOnline: 0 }),
  "yellow",
);
assert.equal(
  matchingStatusFromCounts({ open: 0, withOffers: 0, noOffers: 0, eligibleOnline: 0 }),
  "green",
);
assert.equal(
  matchingStatusFromCounts({
    open: 2,
    withOffers: 1,
    noOffers: 1,
    eligibleOnline: 3,
    dispatchFailures: 1,
  }),
  "red",
);

const now = Date.now();
assert.equal(
  isRecentOpenMatchingTripRow({ trip_state: "searching", created_at: now - 60_000 }, now),
  true,
);
assert.equal(
  isRecentOpenMatchingTripRow(
    { trip_state: "searching", created_at: now - 3 * 60 * 60 * 1000 },
    now,
  ),
  false,
);

const staleNoOfferRow = {
  trip_state: "searching",
  created_at: now - ACTIVE_OPEN_MATCHING_MAX_AGE_MS - 60_000,
  payment_status: "pending",
  match_debug: {
    eligible_driver_count: 5,
    offers_written: 0,
    matching_state: "blocked",
    queue_write_success: false,
  },
};
assert.equal(isRecentOpenMatchingTripRow(staleNoOfferRow, now), false);
assert.equal(
  matchingStatusFromCounts({ open: 0, withOffers: 0, noOffers: 0, eligibleOnline: 5 }),
  "green",
);

const dispatchFailureRow = {
  trip_state: "searching",
  created_at: now - 60_000,
  payment_status: "pending",
};
const dispatchFailureMd = {
  eligible_driver_count: 3,
  offers_written: 0,
  matching_state: "blocked",
  queue_write_success: false,
};
assert.equal(
  isMatchingDispatchFailure(dispatchFailureRow, dispatchFailureMd, { offersWritten: 0 }, now),
  true,
);

const waitingBatchRow = {
  trip_state: "searching",
  created_at: now - 60_000,
  payment_status: "pending",
};
const waitingBatchMd = {
  eligible_driver_count: 3,
  offers_written: 0,
  matching_state: "waiting_next_batch",
  no_eligible_reason: "waiting_next_batch",
};
assert.equal(
  isMatchingDispatchFailure(waitingBatchRow, waitingBatchMd, { offersWritten: 0 }, now),
  false,
);

console.log("matching_health_status.unit.test.js OK");
