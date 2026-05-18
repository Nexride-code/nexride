/**
 * Central dispatch engine — single entry for matching, leases, recovery.
 */

"use strict";

module.exports = {
  ...require("./dispatch_config_engine"),
  ...require("./dispatch_trip_state_engine"),
  ...require("./dispatch_metrics_engine"),
  ...require("./dispatch_offer_lease_engine"),
  ...require("./dispatch_blocker_engine"),
  ...require("./dispatch_eligibility_engine"),
  ...require("./dispatch_candidate_engine"),
  ...require("./dispatch_health_engine"),
  ...require("./dispatch_pipeline_engine"),
  ...require("./dispatch_recovery_engine"),
  ...require("./dispatch_orchestration_lease_engine"),
  ...require("./dispatch_generation_engine"),
  ...require("./dispatch_pipeline_tokens_engine"),
  ...require("./dispatch_pipeline_events_engine"),
  ...require("./dispatch_fanout_backpressure_engine"),
  ...require("./dispatch_orchestrator"),
  ...require("./dispatch_active_trip_consistency"),
  ...require("./dispatch_shard_engine"),
  ...require("./dispatch_work_queue_engine"),
  ...require("./dispatch_work_queue_processor"),
  ...require("./dispatch_lease_expiry_index_engine"),
  ...require("./dispatch_searching_rides_index"),
  ...require("./dispatch_available_drivers_index"),
  ...require("./dispatch_geohash_engine"),
  ...require("./dispatch_hot_ride_engine"),
  ...require("./dispatch_dead_letter_engine"),
  ...require("./dispatch_snapshot_engine"),
  ...require("./dispatch_fast_recovery_engine"),
  ...require("./dispatch_assignment_lock_engine"),
  ...require("./dispatch_pipeline_timeout_engine"),
  ...require("./dispatch_aggregates_engine"),
  ...require("./dispatch_cost_protection_engine"),
};
