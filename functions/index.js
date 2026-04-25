const functions = require("firebase-functions");
const {RtcTokenBuilder, RtcRole} = require("agora-token");

exports.generateAgoraToken = functions.https.onRequest((req, res) => {
  try {
    const channelName = String(
        req.query.channelName || req.query.channel || "",
    ).trim();

    if (!channelName) {
      console.error("[generateAgoraToken] invalid request: missing channelName");
      return res.status(400).json({
        error: "Missing required query parameter: channelName",
      });
    }

    const uidParam = req.query.uid;
    const uid = uidParam !== undefined ? Number(uidParam) : 0;

    if (!Number.isInteger(uid) || uid < 0) {
      console.error("[generateAgoraToken] invalid uid", uidParam);
      return res.status(400).json({
        error: "Invalid uid. It must be a non-negative integer.",
      });
    }

    const agoraConfig = functions.config().agora || {};
    const appId = (
      process.env.AGORA_APP_ID ||
      process.env.APP_ID ||
      agoraConfig.app_id ||
      ""
    ).trim();
    const appCertificate = (
      process.env.AGORA_APP_CERTIFICATE ||
      process.env.APP_CERTIFICATE ||
      agoraConfig.app_certificate ||
      ""
    ).trim();

    if (!appId || !appCertificate) {
      console.error(
          "[generateAgoraToken] missing Agora credentials " +
          "(expected env AGORA_APP_ID/AGORA_APP_CERTIFICATE or runtime config agora.app_id/agora.app_certificate)",
      );
      return res.status(500).json({
        error: "Agora credentials are not configured.",
      });
    }

    const role = RtcRole.PUBLISHER;
    const currentTimestamp = Math.floor(Date.now() / 1000);
    const privilegeExpireTime = currentTimestamp + 3600;

    const token = RtcTokenBuilder.buildTokenWithUid(
        appId,
        appCertificate,
        channelName,
        uid,
        role,
        privilegeExpireTime,
    );

    return res.status(200).json({token});
  } catch (error) {
    console.error("[generateAgoraToken] token generation error:", error);
    return res.status(500).json({error: "Failed to generate Agora token"});
  }
});
