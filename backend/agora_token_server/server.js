require('dotenv').config();

const cors = require('cors');
const express = require('express');
const { RtcTokenBuilder, RtcRole } = require('agora-token');

const app = express();
app.disable('x-powered-by');

const DEFAULT_APP_ID = 'dcbfe108c8c54bee946c7e9b4aac442c';
const APP_ID = (process.env.APP_ID || DEFAULT_APP_ID).trim();
const APP_CERTIFICATE = (process.env.APP_CERTIFICATE || '').trim();
const PORT = parseInt(process.env.PORT || '4100', 10);
const TOKEN_EXPIRE_SECONDS = Math.max(
  parseInt(process.env.TOKEN_EXPIRE_SECONDS || '3600', 10) || 3600,
  60,
);
const corsOrigin = (process.env.CORS_ORIGIN || '*').trim();

if (!APP_ID || !APP_CERTIFICATE) {
  console.error(
    '[AgoraToken] startup failed error=missing APP_ID or APP_CERTIFICATE',
  );
  process.exit(1);
}

app.use(
  cors({
    origin:
      corsOrigin === '*'
        ? true
        : corsOrigin
            .split(',')
            .map((value) => value.trim())
            .filter(Boolean),
  }),
);

app.get('/health', (req, res) => {
  return res.json({
    status: 'ok',
    service: 'agora_token_server',
    appIdConfigured: Boolean(APP_ID),
    certificateConfigured: Boolean(APP_CERTIFICATE),
    tokenExpireSeconds: TOKEN_EXPIRE_SECONDS,
  });
});

app.get('/agora/token', (req, res) => {
  const channel = String(req.query.channel || '').trim();
  const uidRaw = String(req.query.uid || '').trim();

  if (!channel || !uidRaw) {
    console.warn(
      `[AgoraToken] invalid request channel=${channel || 'missing'} uid=${uidRaw || 'missing'}`,
    );
    return res.status(400).json({
      error: 'channel_and_uid_required',
    });
  }

  const uid = Number.parseInt(uidRaw, 10);
  if (!Number.isInteger(uid) || uid <= 0) {
    console.warn(`[AgoraToken] invalid uid channel=${channel} uid=${uidRaw}`);
    return res.status(400).json({
      error: 'uid_must_be_positive_integer',
    });
  }

  try {
    const issuedAt = Math.floor(Date.now() / 1000);
    const privilegeExpiredTs = issuedAt + TOKEN_EXPIRE_SECONDS;
    const token = RtcTokenBuilder.buildTokenWithUid(
      APP_ID,
      APP_CERTIFICATE,
      channel,
      uid,
      RtcRole.PUBLISHER,
      privilegeExpiredTs,
    );

    console.log(
      `[AgoraToken] token request channel=${channel} uid=${uid} expiresAt=${privilegeExpiredTs}`,
    );

    return res.json({ token });
  } catch (error) {
    console.error(
      `[AgoraToken] token generation failed channel=${channel} uid=${uid} error=${error.message || error}`,
    );
    return res.status(500).json({
      error: 'token_generation_failed',
    });
  }
});

app.listen(PORT, () => {
  console.log(`[AgoraToken] server listening port=${PORT}`);
});
