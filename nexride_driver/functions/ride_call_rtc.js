/**
 * Callable: generate Agora RTC token for rider/driver on assigned ride only.
 */

function normUid(uid) {
  return String(uid ?? "").trim();
}

function deterministicRtcUid(uid) {
  const s = String(uid || "");
  let h = 1;
  for (let i = 0; i < s.length; i += 1) {
    h = Math.imul(31, h) + s.charCodeAt(i);
  }
  const n = Math.abs(h % 4294967290) || 10001;
  return n >>> 0;
}

async function getRideCallRtcToken(data, context, db) {
  const caller = normUid(context.auth?.uid);
  if (!caller) {
    console.log("CALL_TOKEN_DENIED", "unauthorized");
    return { success: false, reason: "unauthorized" };
  }

  const rideId = normUid(data?.rideId ?? data?.ride_id);
  if (!rideId) {
    console.log("CALL_TOKEN_DENIED", "invalid_ride_id");
    return { success: false, reason: "invalid_ride_id" };
  }

  const rs = await db.ref(`ride_requests/${rideId}`).get();
  const ride = rs.val();
  if (!ride || typeof ride !== "object") {
    console.log("CALL_TOKEN_DENIED", rideId, "ride_missing");
    return { success: false, reason: "ride_missing" };
  }

  const rider = normUid(ride.rider_id);
  const driver = normUid(ride.driver_id);
  const waiting = ["waiting", "pending", "", "null"];
  const dLower = String(ride.driver_id ?? "").trim().toLowerCase();
  if (!driver || waiting.includes(dLower)) {
    console.log("CALL_TOKEN_DENIED", rideId, "no_driver_assigned");
    return { success: false, reason: "no_driver_assigned" };
  }

  if (caller !== rider && caller !== driver) {
    console.log("CALL_TOKEN_DENIED", rideId, caller);
    return { success: false, reason: "forbidden" };
  }

  const appId = String(process.env.AGORA_APP_ID ?? "").trim();
  const certificate = String(process.env.AGORA_APP_CERTIFICATE ?? "").trim();

  console.log("CALL_TOKEN_REQUESTED", rideId, caller);

  if (!appId || !certificate) {
    console.log(
      "CALL_TOKEN_DENIED",
      rideId,
      "agora_not_configured(server missing AGORA_APP_ID / AGORA_APP_CERTIFICATE)",
    );
    return { success: false, reason: "agora_not_configured" };
  }

  try {
    const { RtcTokenBuilder, RtcRole } = require("agora-token");
    const channelName = `nexride_${rideId}`.replace(/[^a-zA-Z0-9_]/g, "_").slice(0, 64);
    const uidForAgora = deterministicRtcUid(caller);
    const tokenExpireSec = 3600;
    const token = RtcTokenBuilder.buildTokenWithUid(
      appId,
      certificate,
      channelName,
      uidForAgora,
      RtcRole.PUBLISHER,
      tokenExpireSec,
      tokenExpireSec,
    );
    const expireMs = Date.now() + tokenExpireSec * 1000;
    const peerId = caller === rider ? driver : rider;
    return {
      success: true,
      reason: "ok",
      token,
      channelName,
      rtcUid: uidForAgora,
      expireAt: expireMs,
      callerRole: caller === rider ? "rider" : "driver",
      peerId,
    };
  } catch (e) {
    console.log(
      "CALL_TOKEN_DENIED",
      rideId,
      String(e?.message || e || "token_build_failed"),
    );
    return { success: false, reason: "token_build_failed" };
  }
}

module.exports = { getRideCallRtcToken };
