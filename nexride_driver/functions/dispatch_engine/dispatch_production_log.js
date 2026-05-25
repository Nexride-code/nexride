/**
 * Gated dispatch/discovery console traces (off in production by default).
 * Production metrics use dispatch_production_metrics.js only.
 */

"use strict";

const dispatchVerboseLogsEnabled =
  process.env.DISPATCH_VERBOSE_LOGS === "1" ||
  process.env.FUNCTIONS_EMULATOR === "true";

function dispatchVerboseLog(...parts) {
  if (!dispatchVerboseLogsEnabled) return;
  console.log(...parts);
}

module.exports = {
  dispatchVerboseLog,
  dispatchVerboseLogsEnabled,
};
