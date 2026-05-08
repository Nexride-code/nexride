/**
 * Callable: generate Agora RTC token for rider/driver on assigned ride only.
 */

function normUid(uid) {
  return String(uid ?? "").trim();
}

function normalizeFirebasePushIdKey(raw) {
  let s = String(raw ?? "").trim();
  if (!s) return "";
  s = s.replace(/[\u2013\u2014\u2212]/g, "-");
  return s.trim();
}

function normRideIdFromCallableData(data) {
  const v =
    data?.rideId ??
    data?.ride_id ??
    data?.rideID ??
    data?.RIDE_ID ??
    data?.rid ??
    data?.requestId ??
    data?.request_id ??
    data?.tripId ??
    data?.trip_id ??
    data?.tripID;
  return normalizeFirebasePushIdKey(normUid(v));
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

function resolveAgoraCredentials() {
  const envAppId = String(process.env.AGORA_APP_ID ?? "").trim();
  const envCert = String(process.env.AGORA_APP_CERTIFICATE ?? "").trim();
  return { appId: envAppId, certificate: envCert, source: "secret_env" };
}

const CALL_STALE_MS = 3 * 60 * 1000;

function parseCallTs(v) {
  const n = Number(v ?? 0);
  if (!Number.isFinite(n) || n <= 0) return 0;
  return Math.trunc(n);
}

function isActiveCallStatus(raw) {
  const s = String(raw ?? "").trim().toLowerCase();
  return s === "calling" || s === "ringing" || s === "accepted";
}

function isCallRecordStale(record, nowMsValue) {
  if (!record || typeof record !== "object") return false;
  const createdAt = parseCallTs(record.createdAt ?? record.created_at);
  const updatedAt = parseCallTs(record.updatedAt ?? record.updated_at);
  const baseline = Math.max(createdAt, updatedAt);
  if (baseline <= 0) return false;
  return nowMsValue - baseline > CALL_STALE_MS;
}

async function clearCallLocksIfNeeded({
  db,
  rideId,
  force,
  forceClearStale,
  caller,
}) {
  const now = Date.now();
  const nodes = [`calls/${rideId}`, `ride_calls/${rideId}`, `active_calls/${rideId}`];
  let blockedByActiveCall = false;

  for (const path of nodes) {
    const snap = await db.ref(path).get();
    const value = snap.val();
    if (!value || typeof value !== "object") {
      continue;
    }

    const stale = isCallRecordStale(value, now);
    const active = isActiveCallStatus(value.status);
    const shouldClearStale = forceClearStale && stale;
    const reason = force ? "force" : shouldClearStale ? "ttl_expired" : "";
    if (reason) {
      await db.ref(path).remove();
      console.log(
        "CALL_RECORD_CLEARED",
        `rideId=${rideId}`,
        `path=${path}`,
        `reason=${reason}`,
        `caller=${caller || "none"}`,
      );
      continue;
    }

    if (active) {
      blockedByActiveCall = true;
      console.log(
        "CALL_RECORD_ACTIVE",
        `rideId=${rideId}`,
        `path=${path}`,
        `status=${String(value.status ?? "")}`,
        `caller=${caller || "none"}`,
      );
    }
  }

  return { blockedByActiveCall };
}

async function clearStaleRideCall(data, context, db) {
  const caller = normUid(context?.auth?.uid);
  if (!caller) {
    return { success: false, reason: "unauthorized" };
  }
  const rideId = normRideIdFromCallableData(data);
  if (!rideId) {
    return { success: false, reason: "invalid_ride_id" };
  }
  const updates = {
    [`ride_calls/${rideId}`]: null,
    [`active_calls/${rideId}`]: null,
    [`ride_call_sessions/${rideId}`]: null,
    [`calls/${rideId}`]: null,
  };
  await db.ref().update(updates);
  console.log("CALL_RECORD_CLEARED_MANUAL", `rideId=${rideId}`, `caller=${caller}`);
  return { success: true, rideId };
}

async function getRideCallRtcToken(data, context, db) {
  const startupCreds = resolveAgoraCredentials();
  console.log(
    "AGORA_SECRET_CHECK",
    `appIdDefined=${startupCreds.appId.length > 0}`,
    `certDefined=${startupCreds.certificate.length > 0}`,
    `appIdLength=${startupCreds.appId.length}`,
  );

  const caller = normUid(context.auth?.uid);
  if (!caller) {
    console.log("CALL_TOKEN_DENIED", "unauthorized");
    return { success: false, reason: "unauthorized" };
  }

  const rideId = normRideIdFromCallableData(data);
  if (!rideId) {
    console.log("CALL_TOKEN_DENIED", "invalid_ride_id");
    return { success: false, reason: "invalid_ride_id" };
  }
  const force = data?.force === true;
  const forceClearStale = data?.force_clear_stale !== false;

  const rs = await db.ref(`ride_requests/${rideId}`).get();
  const ride = rs.val();
  if (!ride || typeof ride !== "object") {
    console.log("CALL_TOKEN_DENIED", rideId, "ride_missing");
    return { success: false, reason: "ride_missing" };
  }

  const rider = normUid(ride.rider_id);
  const rawDriverId = String(ride.driver_id ?? "").trim();
  let driver = normUid(ride.driver_id);
  const waiting = ["waiting", "pending", "", "null"];
  const dLower = rawDriverId.toLowerCase();
  if (!driver || waiting.includes(dLower)) {
    driver = normUid(ride.matched_driver_id);
  }
  if (!driver || waiting.includes(driver.toLowerCase())) {
    console.log("CALL_TOKEN_DENIED", rideId, "no_driver_assigned");
    return { success: false, reason: "no_driver_assigned" };
  }

  if (caller !== rider && caller !== driver) {
    console.log("CALL_TOKEN_DENIED", rideId, caller);
    return { success: false, reason: "forbidden" };
  }

  const callLockResult = await clearCallLocksIfNeeded({
    db,
    rideId,
    force,
    forceClearStale,
    caller,
  });
  if (callLockResult.blockedByActiveCall) {
    console.log("CALL_TOKEN_DENIED", rideId, "call_already_active");
    return { success: false, reason: "call_already_active" };
  }

  const creds = startupCreds;
  const appId = creds.appId;
  const certificate = creds.certificate;
  console.log(
    "AGORA_SECRET_CHECK",
    `appIdDefined=${appId.length > 0}`,
    `appIdLength=${appId.length}`,
    `certDefined=${certificate.length > 0}`,
    `certLength=${certificate.length}`,
  );

  console.log("CALL_TOKEN_REQUESTED", rideId, caller);

  if (!appId || !certificate) {
    console.log(
      "CALL_TOKEN_DENIED",
      rideId,
      "agora_not_configured(server missing AGORA_APP_ID / AGORA_APP_CERTIFICATE secrets)",
      `source=${creds.source}`,
    );
    return {
      success: false,
      reason: "agora_not_configured",
      message: "Voice calling is unavailable. Configure AGORA_APP_ID and AGORA_APP_CERTIFICATE Firebase secrets.",
    };
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
      appId,
      channelName,
      rtcUid: uidForAgora,
      expireAt: expireMs,
      callerRole: caller === rider ? "rider" : "driver",
      peerId,
      credentialSource: creds.source,
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

async function generateAgoraToken(data, context, db) {
  const rideId = normRideIdFromCallableData(data);
  const uid = normUid(data?.uid ?? context?.auth?.uid);
  const requestedChannel = normUid(data?.channelName);

  const tokenResponse = await getRideCallRtcToken(
    {
      ...data,
      rideId,
      ride_id: rideId,
    },
    context,
    db,
  );

  if (tokenResponse?.success !== true || !tokenResponse?.token) {
    return tokenResponse ?? { success: false, reason: "token_unavailable" };
  }

  const creds = resolveAgoraCredentials();
  const channelName =
    requestedChannel ||
    normUid(tokenResponse.channelName) ||
    `nexride_${rideId}`.replace(/[^a-zA-Z0-9_]/g, "_").slice(0, 64);

  return {
    success: true,
    reason: tokenResponse.reason || "ok",
    token: tokenResponse.token,
    appId: creds.appId,
    channelName,
    rtcUid: tokenResponse.rtcUid,
    expireAt: tokenResponse.expireAt,
    callerRole: tokenResponse.callerRole,
    peerId: tokenResponse.peerId,
    uid,
  };
}

module.exports = { getRideCallRtcToken, generateAgoraToken, clearStaleRideCall };
