/**
 * Centralized Firebase params + local overrides via dotenv (see `.env.example`).
 * Secrets: bind `flutterwaveSecretKey` on each function that needs it; Cloud Run
 * injects `process.env.FLUTTERWAVE_SECRET_KEY`. For emulators, use `functions/.env`.
 */

const path = require("path");
require("dotenv").config({ path: path.join(__dirname, ".env") });

const { defineSecret, defineString } = require("firebase-functions/params");

const flutterwaveSecretKey = defineSecret("FLUTTERWAVE_SECRET_KEY");
/** Must match Flutterwave dashboard webhook secret (`verif-hash` header). */
const flutterwaveWebhookSecret = defineSecret("FLUTTERWAVE_WEBHOOK_SECRET");

const nexridePlatformFeeNgn = defineString("NEXRIDE_PLATFORM_FEE_NGN", {
  default: "30",
  description: "Flat platform fee in NGN for trip settlement",
});

const REGION = "us-central1";

function flutterwaveSecretForVerify() {
  return String(process.env.FLUTTERWAVE_SECRET_KEY || "").trim();
}

function platformFeeNgn() {
  const n = Number(nexridePlatformFeeNgn.value());
  return Number.isFinite(n) && n > 0 ? n : 30;
}

module.exports = {
  flutterwaveSecretKey,
  flutterwaveWebhookSecret,
  nexridePlatformFeeNgn,
  REGION,
  flutterwaveSecretForVerify,
  platformFeeNgn,
};
