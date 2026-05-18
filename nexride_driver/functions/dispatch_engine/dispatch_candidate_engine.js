/**
 * Candidate ranking and batch selection.
 */

"use strict";

const {
  sortEligibleCandidates,
  selectNextFanoutBatch,
  compareMatchCandidates,
} = require("../driver_match_ranking");
const { loadDispatchConfig } = require("./dispatch_config_engine");

async function selectBatchFromCandidates(sortedEligible, skipDriverIds, db) {
  const cfg = await loadDispatchConfig(db);
  return selectNextFanoutBatch(
    sortedEligible,
    skipDriverIds,
    cfg.driver_offer_batch_size,
  );
}

module.exports = {
  sortEligibleCandidates,
  selectBatchFromCandidates,
  compareMatchCandidates,
};
