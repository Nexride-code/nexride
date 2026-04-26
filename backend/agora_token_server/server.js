require('dotenv').config();

const express = require('express');

const app = express();
app.disable('x-powered-by');

const PORT = parseInt(process.env.PORT || '4100', 10);
const FIREBASE_FUNCTION_URL =
  'https://us-central1-nexride-8d5bc.cloudfunctions.net/generateAgoraToken';

app.get('/health', (req, res) => {
  return res.json({
    status: 'deprecated',
    service: 'agora_token_server',
    message: 'Deprecated: token issuance is handled by Firebase Cloud Function only.',
    firebaseFunctionEndpoint: FIREBASE_FUNCTION_URL,
  });
});

app.get('/agora/token', (req, res) => {
  console.warn(
    `[AgoraToken][DEPRECATED] request blocked rawQuery=${JSON.stringify(req.query)}`,
  );
  return res.status(410).json({
    error: 'deprecated_endpoint',
    message: 'Use Firebase Cloud Function generateAgoraToken instead.',
    endpoint: FIREBASE_FUNCTION_URL,
  });
});

app.listen(PORT, () => {
  console.log(
    `[AgoraToken][DEPRECATED] server listening port=${PORT}; Firebase Function endpoint=${FIREBASE_FUNCTION_URL}`,
  );
});
