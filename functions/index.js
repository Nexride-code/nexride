const {onRequest} = require("firebase-functions/v2/https");
const {defineSecret} = require("firebase-functions/params");
const {RtcTokenBuilder, RtcRole} = require("agora-access-token");

const AGORA_APP_ID = defineSecret("AGORA_APP_ID");
const AGORA_APP_CERTIFICATE = defineSecret("AGORA_APP_CERTIFICATE");

function badRequest(res, message) {
  return res.status(400).json({
    success: false,
    error: message,
  });
}

function validateRequest(req) {
  const rawChannelName = req.query.channelName;
  if (typeof rawChannelName !== "string" || rawChannelName.trim().length === 0) {
    return {ok: false, error: "channelName is required and must be a string."};
  }

  const uidParam = req.query.uid;
  if (uidParam === undefined || uidParam === null || uidParam === "") {
    return {ok: false, error: "uid is required and must be a non-negative integer."};
  }

  const uid = Number(uidParam);
  if (!Number.isInteger(uid) || uid < 0) {
    return {ok: false, error: "uid is required and must be a non-negative integer."};
  }

  return {
    ok: true,
    channelName: rawChannelName.trim(),
    uid,
  };
}

function buildAgoraRtcToken({appId, appCertificate, channelName, uid}) {
  const currentTimestamp = Math.floor(Date.now() / 1000);
  const privilegeExpireTime = currentTimestamp + 3600;

  return RtcTokenBuilder.buildTokenWithUid(
      appId,
      appCertificate,
      channelName,
      uid,
      RtcRole.PUBLISHER,
      privilegeExpireTime,
  );
}

