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

const RIDE_CALL_CHANNEL_PREFIX = "nexride";
const RIDE_CALL_TOKEN_EXPIRE_SEC = 3600;

function channelNameForRide(rideId) {
  const normalizedRideId = normRideIdFromCallableData({ rideId });
  if (!normalizedRideId) {
    return "";
  }
  return `${RIDE_CALL_CHANNEL_PREFIX}_${normalizedRideId}`
    .replace(/[^a-zA-Z0-9_]/g, "_")
    .slice(0, 64);
}

function rtcUidForFirebaseUid(uid) {
  const s = String(uid || "");
  let h = 1;
  for (let i = 0; i < s.length; i += 1) {
    h = Math.imul(31, h) + s.charCodeAt(i);
  }
  const n = Math.abs(h % 4294967290) || 10001;
  return n >>> 0;
}

function buildRideCallRtcToken({ appId, certificate, rideId, caller }) {
  const { RtcTokenBuilder, RtcRole } = require("agora-token");
  const channelName = channelNameForRide(rideId);
  const rtcUid = rtcUidForFirebaseUid(caller);
  const tokenExpireSec = Math.max(
    RIDE_CALL_TOKEN_EXPIRE_SEC,
    Number(process.env.AGORA_TOKEN_EXPIRE_SEC) || RIDE_CALL_TOKEN_EXPIRE_SEC,
  );
  const expireTs = Math.floor(Date.now() / 1000) + tokenExpireSec;
  const role = RtcRole.PUBLISHER;

  console.log(
    "CALL_TOKEN_BUILD",
    `rideId=${rideId}`,
    `channel=${channelName}`,
    `rtcUid=${rtcUid}`,
    `role=publisher`,
    `expireTs=${expireTs}`,
    `appIdLength=${appId.length}`,
    `certLength=${certificate.length}`,
  );

  const token = RtcTokenBuilder.buildTokenWithUid(
    appId,
    certificate,
    channelName,
    rtcUid,
    role,
    tokenExpireSec,
    tokenExpireSec,
  );

  return {
    token,
    channelName,
    rtcUid,
    expireAt: expireTs * 1000,
    tokenExpireSec,
    role: "publisher",
  };
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

function callRecordInvolvesUid(record, uid) {
  if (!record || typeof record !== "object" || !uid) {
    return false;
  }
  const ids = [
    record.callerId,
    record.caller_id,
    record.receiverId,
    record.receiver_id,
    record.rider_id,
    record.riderId,
    record.driver_id,
    record.driverId,
    record.started_by,
    record.startedBy,
  ];
  return ids.some((raw) => normUid(raw) === uid);
}

function sameRideCalleeMayJoinActiveCall({ record, caller, rider, driver }) {
  if (!record || typeof record !== "object") {
    return false;
  }
  if (!isActiveCallStatus(record.status)) {
    return false;
  }
  if (caller !== rider && caller !== driver) {
    return false;
  }
  return callRecordInvolvesUid(record, rider) && callRecordInvolvesUid(record, driver);
}

async function hasActiveCallOnOtherRide({ db, rideId, caller, rider, driver }) {
  const snap = await db.ref("active_calls").get();
  const all = snap.val();
  if (!all || typeof all !== "object") {
    return false;
  }
  const now = Date.now();
  for (const [otherRideId, record] of Object.entries(all)) {
    if (otherRideId === rideId || !record || typeof record !== "object") {
      continue;
    }
    if (!isActiveCallStatus(record.status) || isCallRecordStale(record, now)) {
      continue;
    }
    if (!callRecordInvolvesUid(record, caller)) {
      continue;
    }
    console.log(
      "CALL_RECORD_ACTIVE_OTHER_RIDE",
      `rideId=${rideId}`,
      `otherRideId=${otherRideId}`,
      `caller=${caller || "none"}`,
    );
    return true;
  }
  return false;
}

async function clearCallLocksIfNeeded({
  db,
  rideId,
  force,
  forceClearStale,
  caller,
  rider,
  driver,
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
      if (sameRideCalleeMayJoinActiveCall({ record: value, caller, rider, driver })) {
        console.log(
          "CALL_RECORD_JOIN_ALLOWED",
          `rideId=${rideId}`,
          `path=${path}`,
          `status=${String(value.status ?? "")}`,
          `caller=${caller || "none"}`,
        );
        continue;
      }
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

  let rs = await db.ref(`ride_requests/${rideId}`).get();
  let ride = rs.val();
  let isDelivery = false;
  if (!ride || typeof ride !== "object") {
    const ds = await db.ref(`delivery_requests/${rideId}`).get();
    ride = ds.val();
    isDelivery = Boolean(ride && typeof ride === "object");
    if (!isDelivery) {
      console.log("CALL_TOKEN_DENIED", rideId, "ride_missing");
      return { success: false, reason: "ride_missing" };
    }
  }

  const rider = normUid(ride.rider_id ?? ride.riderId ?? ride.customer_id);
  const rawDriverId = String(ride.driver_id ?? "").trim();
  let driver = normUid(ride.driver_id);
  const waiting = ["waiting", "pending", "", "null"];
  const dLower = rawDriverId.toLowerCase();
  if (!driver || waiting.includes(dLower)) {
    driver = normUid(ride.matched_driver_id ?? ride.accepted_driver_id);
  }
  if (!driver || waiting.includes(driver.toLowerCase())) {
    console.log("CALL_TOKEN_DENIED", rideId, "no_driver_assigned");
    return { success: false, reason: "no_driver_assigned" };
  }

  const merchantId = normUid(ride.merchant_id ?? ride.merchantId);
  if (caller !== rider && caller !== driver && (!isDelivery || caller !== merchantId)) {
    console.log("CALL_TOKEN_DENIED", rideId, caller);
    return { success: false, reason: "forbidden" };
  }

  const callLockResult = await clearCallLocksIfNeeded({
    db,
    rideId,
    force,
    forceClearStale,
    caller,
    rider,
    driver,
  });
  if (callLockResult.blockedByActiveCall) {
    console.log("CALL_TOKEN_DENIED", rideId, "call_already_active");
    return { success: false, reason: "call_already_active" };
  }
  const blockedOtherRide = await hasActiveCallOnOtherRide({
    db,
    rideId,
    caller,
    rider,
    driver,
  });
  if (blockedOtherRide) {
    console.log("CALL_TOKEN_DENIED", rideId, "call_already_active", "other_ride");
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

  console.log("RIDE_CALL_TOKEN_REQUEST", rideId, caller);

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
    const built = buildRideCallRtcToken({
      appId,
      certificate,
      rideId,
      caller,
    });
    const peerId = caller === rider ? driver : rider;
    return {
      success: true,
      reason: "ok",
      token: built.token,
      appId,
      channelName: built.channelName,
      rtcUid: built.rtcUid,
      expireAt: built.expireAt,
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

  const channelName = String(tokenResponse.channelName ?? "").trim();
  const rtcUid = Number(tokenResponse.rtcUid);
  if (!channelName || !Number.isFinite(rtcUid) || rtcUid <= 0) {
    console.log(
      "CALL_TOKEN_DENIED",
      rideId,
      "token_response_missing_join_identity",
    );
    return { success: false, reason: "token_build_failed" };
  }

  return {
    success: true,
    reason: tokenResponse.reason || "ok",
    token: tokenResponse.token,
    appId: tokenResponse.appId,
    channelName,
    rtcUid,
    expireAt: tokenResponse.expireAt,
    callerRole: tokenResponse.callerRole,
    peerId: tokenResponse.peerId,
    uid,
  };
}

module.exports = {
  getRideCallRtcToken,
  generateAgoraToken,
  clearStaleRideCall,
  channelNameForRide,
  rtcUidForFirebaseUid,
  buildRideCallRtcToken,
};
