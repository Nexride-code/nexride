#!/usr/bin/env node
/**
 * Seeds RTDB `app_config/nexride_official_bank_account` for bank-transfer flows.
 *
 * Usage (operator machine with Firebase Admin):
 *   export GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account.json
 *   NEXRIDE_BANK_NAME='Example Bank' \
 *   NEXRIDE_ACCOUNT_NAME='NexRide Ltd' \
 *   NEXRIDE_ACCOUNT_NUMBER='0123456789' \
 *   node tools/seed_nexride_official_bank_account.mjs
 *
 * Dry-run (prints payload only):
 *   node tools/seed_nexride_official_bank_account.mjs --dry-run
 *
 * Resolves `firebase-admin` from `nexride_driver/functions/node_modules` when run
 * from repo root (no separate tools/ package).
 */

import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const functionsPkg = join(__dirname, "../nexride_driver/functions/package.json");
const require = createRequire(functionsPkg);
const admin = require("firebase-admin");

const projectId = process.env.FIREBASE_PROJECT_ID || "nexride-8d5bc";
const path = "app_config/nexride_official_bank_account";
const dryRun = process.argv.includes("--dry-run");

const bankName = (process.env.NEXRIDE_BANK_NAME || "").trim();
const accountName = (process.env.NEXRIDE_ACCOUNT_NAME || "").trim();
const accountNumber = (process.env.NEXRIDE_ACCOUNT_NUMBER || "").trim();

if (!bankName || !accountName || !accountNumber) {
  console.error(
    "Set NEXRIDE_BANK_NAME, NEXRIDE_ACCOUNT_NAME, and NEXRIDE_ACCOUNT_NUMBER.",
  );
  process.exit(1);
}

const payload = {
  bank_name: bankName,
  account_name: accountName,
  account_number: accountNumber,
  updated_at: Date.now(),
  updated_by: "seed_nexride_official_bank_account.mjs",
};

if (dryRun) {
  console.log(JSON.stringify({ path, payload }, null, 2));
  process.exit(0);
}

if (!admin.apps.length) {
  admin.initializeApp({
    credential: admin.credential.applicationDefault(),
    databaseURL: `https://${projectId}-default-rtdb.firebaseio.com`,
  });
}

const db = admin.database();
await db.ref(path).set(payload);
console.log("OK", { projectId, path, bank_name: bankName, account_number: accountNumber.slice(-4).padStart(accountNumber.length, "*") });
