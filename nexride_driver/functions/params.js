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
const agoraAppIdSecret = defineSecret("AGORA_APP_ID");
const agoraAppCertificateSecret = defineSecret("AGORA_APP_CERTIFICATE");

const nexridePlatformFeeNgn = defineString("NEXRIDE_PLATFORM_FEE_NGN", {
  default: "30",
  description: "Mandatory platform/booking fee (NGN) on every rider request",
});
const nexrideSmallOrderFeeNgn = defineString("NEXRIDE_SMALL_ORDER_FEE_NGN", {
  default: "15",
  description: "Small-order surcharge (NGN) for merchant/food/mart orders below threshold",
});
const nexrideSmallOrderThresholdNgn = defineString("NEXRIDE_SMALL_ORDER_THRESHOLD_NGN", {
  default: "3000",
  description: "Subtotal below this (NGN) triggers small-order fee on commerce orders",
});
const flutterwavePublicKey = defineString("FLUTTERWAVE_PUBLIC_KEY", {
  default: "",
  description: "Flutterwave public key returned to rider app for checkout metadata",
});

const REGION = "us-central1";

function flutterwaveSecretForVerify() {
  return String(process.env.FLUTTERWAVE_SECRET_KEY || "").trim();
}

function readParamNumber(paramDef, fallback, { min = 0 } = {}) {
  try {
    const n = Number(paramDef.value());
    if (!Number.isFinite(n) || n <= min) {
      return fallback;
    }
    return n;
  } catch (_) {
    return fallback;
  }
}

function platformFeeNgn() {
  return readParamNumber(nexridePlatformFeeNgn, 30, { min: 0 });
}

function smallOrderFeeNgn() {
  return readParamNumber(nexrideSmallOrderFeeNgn, 15, { min: 0 });
}

function smallOrderThresholdNgn() {
  return readParamNumber(nexrideSmallOrderThresholdNgn, 3000, { min: 0 });
}

module.exports = {
  flutterwaveSecretKey,
  flutterwaveWebhookSecret,
  agoraAppIdSecret,
  agoraAppCertificateSecret,
  nexridePlatformFeeNgn,
  flutterwavePublicKey,
  REGION,
  flutterwaveSecretForVerify,
  platformFeeNgn,
  smallOrderFeeNgn,
  smallOrderThresholdNgn,
  nexrideSmallOrderFeeNgn,
  nexrideSmallOrderThresholdNgn,
};
