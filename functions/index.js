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

exports.generateAgoraToken = onRequest({
  region: "us-central1",
  timeoutSeconds: 60,
  memory: "256MiB",
  cors: true,
  secrets: [AGORA_APP_ID, AGORA_APP_CERTIFICATE],
}, async (req, res) => {
  if (req.method !== "GET") {
    return res.status(405).json({
      success: false,
      error: "Method not allowed.",
    });
  }

  const validation = validateRequest(req);
  if (!validation.ok) {
    return badRequest(res, validation.error);
  }

  const appId = AGORA_APP_ID.value().trim();
  const appCertificate = AGORA_APP_CERTIFICATE.value().trim();

  console.log("[generateAgoraToken] request", {
    hasAgoraAppId: appId.length > 0,
    hasAgoraAppCertificate: appCertificate.length > 0,
    channelName: validation.channelName,
    uid: validation.uid,
  });

  if (!appId || !appCertificate) {
    console.error("[generateAgoraToken] missing Agora secret values");
    return res.status(500).json({
      success: false,
      error: "Agora credentials are not configured.",
    });
  }

  try {
    const token = buildAgoraRtcToken({
      appId,
      appCertificate,
      channelName: validation.channelName,
      uid: validation.uid,
    });

    return res.status(200).json({
      success: true,
      token,
      appId,
    });
  } catch (error) {
    console.error("[generateAgoraToken] token generation error", {
      channelName: validation.channelName,
      uid: validation.uid,
      error: error instanceof Error ? error.message : String(error),
    });
    return res.status(500).json({
      success: false,
      error: "Failed to generate Agora token.",
    });
  }
});
