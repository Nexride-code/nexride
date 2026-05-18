/**
 * Canonical trip / matching state helpers (single source for dispatch engine).
 */

"use strict";

const { rideDocumentIsTerminal } = require("../ride_pointer_orphans");

const CANONICAL_TRIP_STATES = new Set([
  "searching",
  "offered",
  "accepted",
  "driver_assigned",
  "driver_arriving",
  "arrived",
  "in_trip",
  "in_progress",
  "completed",
  "cancelled",
  "expired",
  "failed",
]);

const SEARCHING_TOKENS = new Set([
  "searching",
  "requested",
  "matching",
  "searching_driver",
  "awaiting_match",
]);

function normUid(v) {
  return String(v ?? "").trim();
}

function normState(v) {
  return String(v ?? "").trim().toLowerCase();
}

function isPlaceholderDriverId(v) {
  const s = String(v ?? "").trim().toLowerCase();
  return !s || s === "waiting" || s === "pending" || s === "null" || s === "none";
}

function canonicalAssignedDriverId(ride) {
  if (!ride || typeof ride !== "object") return "";
  for (const key of [
    "matched_driver_id",
    "matchedDriverId",
    "accepted_driver_id",
    "acceptedDriverId",
    "driver_id",
    "driverId",
  ]) {
    const raw = ride[key];
    if (isPlaceholderDriverId(raw)) continue;
    const d = normUid(raw);
    if (d) return d;
  }
  return "";
}

function rideIsOpenForMatching(ride) {
  if (!ride || typeof ride !== "object") return false;
  if (rideDocumentIsTerminal(ride)) return false;
  if (canonicalAssignedDriverId(ride)) return false;
  const tokens = [
    normState(ride.trip_state),
    normState(ride.status),
    normState(ride.request_status),
  ].filter(Boolean);
  return tokens.some((t) => SEARCHING_TOKENS.has(t));
}

function rideDispatchStopped(ride) {
  if (!ride || typeof ride !== "object") return true;
  const st = normState(ride.dispatch_state ?? ride.matching_state);
  return st === "matched" || st === "accepted" || st === "completed";
}

module.exports = {
  CANONICAL_TRIP_STATES,
  SEARCHING_TOKENS,
  normUid,
  normState,
  canonicalAssignedDriverId,
  rideIsOpenForMatching,
  rideDispatchStopped,
  isPlaceholderDriverId,
};
