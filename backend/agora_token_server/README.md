# Agora Token Server

Shared token backend for both NexRide Flutter apps.

## Endpoint

`GET /agora/token?channel=<rideId>&uid=<numericAgoraUid>`

Health check:

`GET /health`

Response:

```json
{ "token": "<generated_token>" }
```

## Required Environment Variables

- `APP_ID` defaults to `dcbfe108c8c54bee946c7e9b4aac442c`
- `APP_CERTIFICATE`

## Optional Environment Variables

- `PORT` default `4100`
- `TOKEN_EXPIRE_SECONDS` default `3600`
- `CORS_ORIGIN` default `*`

## Run Locally

```bash
cd backend/agora_token_server
cp .env.example .env
npm install
npm start
```

Example local endpoint:

```text
http://localhost:4100/agora/token
```

Example request:

```bash
curl "http://localhost:4100/agora/token?channel=ride_123&uid=10023456"
```

## Flutter App Configuration

Both the rider app and the driver app must use the same backend endpoint.

Example run configuration:

```bash
flutter run \
  --dart-define=AGORA_TOKEN_ENDPOINT=http://localhost:4100/agora/token
```

The Flutter apps already default to `AGORA_APP_ID=dcbfe108c8c54bee946c7e9b4aac442c`, so both apps only need the same `AGORA_TOKEN_ENDPOINT` value.

## Production Notes

- Keep `APP_ID` and `APP_CERTIFICATE` only on the server.
- Put this service behind HTTPS in production.
- Restrict `CORS_ORIGIN` to the origins you actually trust.
- Rotate credentials if they are ever exposed.
