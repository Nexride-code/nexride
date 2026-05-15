/**
 * Helpers for admin rider lists / dashboards: distinguish placeholder `drivers/{uid}`
 * rows from committed driver profiles so rider-only accounts are not hidden.
 */

function driverProfileLooksCommittedForRiderExclusion(row) {
  if (!row || typeof row !== "object") {
    return false;
  }
  const plate = String(row.plateNumber ?? row.plate ?? row.vehiclePlate ?? "").trim();
  if (plate.length >= 3) {
    return true;
  }
  const vehicle = row.vehicle && typeof row.vehicle === "object" ? row.vehicle : {};
  const vehicleLabel = String(vehicle.make ?? vehicle.model ?? vehicle.name ?? "").trim();
  if (vehicleLabel.length >= 2) {
    return true;
  }
  const model = String(row.vehicleModel ?? row.carModel ?? row.vehicleType ?? "").trim();
  if (model.length >= 2) {
    return true;
  }
  if (row.driver_profile_complete === true) {
    return true;
  }
  const stage = String(row.onboarding_stage ?? row.onboardingStep ?? "").toLowerCase();
  if (stage.includes("complete") || stage.includes("verified")) {
    return true;
  }
  if (row.is_verified === true || row.nexride_verified === true) {
    return true;
  }
  return false;
}


async function countAuthUsersExcludingCommittedDrivers(listUsers, driversVal, opts) {
  const maxPages = Math.min(30, Math.max(1, Number(opts?.maxPages ?? 10) || 10));
  let pageToken;
  let counted = 0;
  for (let page = 0; page < maxPages; page += 1) {
    const res = await listUsers(1000, pageToken);
    for (const u of res.users) {
      const uid = u.uid;
      const dRow = driversVal[uid];
      if (driverProfileLooksCommittedForRiderExclusion(dRow)) {
        continue;
      }
      counted += 1;
    }
    if (!res.pageToken) {
      return { counted, capped: false };
    }
    pageToken = res.pageToken;
  }
  return { counted, capped: true };
}

module.exports = {
  driverProfileLooksCommittedForRiderExclusion,
  countAuthUsersExcludingCommittedDrivers,
};
