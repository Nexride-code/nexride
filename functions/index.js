const functions = require("firebase-functions");
const {RtcTokenBuilder, RtcRole} = require("agora-token");

exports.generateAgoraToken = functions.https.onRequest((req, res) => {
  try {
    const channelName = req.query.channelName;

    if (!channelName || typeof channelName !== "string") {
      return res.status(400).json({error: "Missing required query parameter: channelName"});
    }

    const uidParam = req.query.uid;
    const uid = uidParam !== undefined ? Number(uidParam) : 0;

    if (!Number.isInteger(uid) || uid < 0) {
      return res.status(400).json({error: "Invalid uid. It must be a non-negative integer."});
    }

    const agoraConfig = functions.config().agora || {};
    const appId = agoraConfig.app_id;
    const appCertificate = agoraConfig.app_certificate;

    if (!appId || !appCertificate) {
      return res.status(500).json({error: "Agora credentials are not configured."});
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
    console.error("Error generating Agora token:", error);
    return res.status(500).json({error: "Failed to generate Agora token"});
  }
});
