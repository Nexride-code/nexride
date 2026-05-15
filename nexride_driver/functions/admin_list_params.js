/**
 * Shared query parsing for paginated admin list HTTPS callables.
 * @param {object} data
 * @returns {{
 *   limit: number,
 *   cursor: string,
 *   search: string,
 *   city: string,
 *   stateOrRegion: string,
 *   status: string,
 *   verificationStatus: string,
 *   createdFrom: number,
 *   createdTo: number,
 *   profileCompleteness: 'completed' | 'incomplete' | 'all',
 * }}
 */
function parseAdminListParams(data) {
  const limitRaw = Number(data?.limit ?? data?.pageSize ?? 50);
  const limit = Math.min(100, Math.max(1, Number.isFinite(limitRaw) ? Math.floor(limitRaw) : 50));
  const cursor = typeof data?.cursor === "string" ? data.cursor.trim() : "";
  const search = String(data?.search ?? "").trim().toLowerCase();
  const city = String(data?.city ?? "").trim().toLowerCase();
  const stateOrRegion = String(
    data?.stateOrRegion ?? data?.state_or_region ?? data?.state ?? "",
  )
    .trim()
    .toLowerCase();
  const status = String(data?.status ?? "").trim().toLowerCase();
  const verificationStatus = String(
    data?.verificationStatus ?? data?.verification_status ?? "",
  )
    .trim()
    .toLowerCase();
  const createdFrom = Number(data?.createdFrom ?? data?.created_from ?? 0) || 0;
  const createdTo = Number(data?.createdTo ?? data?.created_to ?? 0) || 0;
  const monetizationModel = String(
    data?.monetizationModel ?? data?.monetization_model ?? data?.payment_model ?? "",
  )
    .trim()
    .toLowerCase();
  let profileCompleteness = String(
    data?.profileCompleteness ?? data?.profile_completeness ?? "",
  )
    .trim()
    .toLowerCase();
  if (!profileCompleteness) {
    const showAll =
      data?.showIncompleteProfiles === true ||
      data?.show_incomplete_profiles === true ||
      data?.includeIncompleteRegistrations === true ||
      data?.include_incomplete_registrations === true;
    profileCompleteness = showAll ? "all" : "completed";
  }
  if (!["completed", "incomplete", "all"].includes(profileCompleteness)) {
    profileCompleteness = "completed";
  }
  return {
    limit,
    cursor,
    search,
    city,
    stateOrRegion,
    status,
    verificationStatus,
    createdFrom,
    createdTo,
    monetizationModel,
    profileCompleteness,
  };
}

module.exports = { parseAdminListParams };
