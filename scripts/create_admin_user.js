#!/usr/bin/env node
/**
 * scripts/create_admin_user.js
 *
 * Provision the production NexRide `admin@` and `support@` accounts so that
 * runtime guards (custom claims + RTDB + Firestore) all agree on each user's
 * role.  Mirrors the pattern from `nexride_driver/functions/scripts/grant_roles.js`
 * and `nexride_driver/functions/admin_roles.js`, but is safe to run from the
 * project root and is the canonical onboarding tool for new operators.
 *
 * For each target email, this script will:
 *
 *   1. Find the Firebase Auth user, OR create it with a strong random
 *      password (32 chars, ~190 bits of entropy) generated in-memory.
 *   2. Set custom claims:
 *        admin   -> { admin: true,            role: "admin"          }
 *        support -> { support: true, support_staff: true,
 *                     role: "support_agent"                          }
 *      These are exactly what `nexride_driver/functions/admin_auth.js`,
 *      `firestore.rules` (`isAdmin()` / `isSupport()`), and
 *      `database.rules.json` check on every authenticated request.
 *   3. For NEWLY CREATED users, additionally set:
 *        custom claim   `temporaryPassword: true`
 *        RTDB           /account_security/{uid} = {
 *                          temporaryPassword: true,
 *                          createdAt, lastUpdatedAt,
 *                          reason: "initial_provisioning"
 *                       }
 *      Both the admin and support Flutter portals (see
 *      nexride_driver/lib/portal_security/) check this and force-redirect
 *      the user to the change-password screen on first sign-in.
 *      The flag is cleared by the
 *      `rotateAccountAfterPasswordChange` Cloud Function after the
 *      operator successfully changes their password.
 *   4. Mirror role state into Realtime Database:
 *        admin   -> /admins/{uid} = true
 *        support -> /support_staff/{uid} = { role, enabled, ... }
 *      so the RTDB-document fallback path in AdminShell.tsx / SupportShell.tsx
 *      keeps working even if a fresh ID token has not propagated yet.
 *   5. Mirror role state into Firestore:
 *        support_staff/{uid} = { email, role, enabled: true, updatedAt }
 *      so the `isSupportDocument()` helper in firestore.rules grants reads.
 *   6. NEVER overwrite the password of an existing user. If the account
 *      already exists, only the role bookkeeping is reapplied — the
 *      `temporaryPassword` flag is intentionally NOT re-stamped, because
 *      the user has presumably already rotated their password.
 *
 * Usage:
 *   node scripts/create_admin_user.js
 *   node scripts/create_admin_user.js --admin-email admin@nexride.africa \
 *                                     --support-email support@nexride.africa
 *
 * Credential sources (first match wins):
 *   1. GOOGLE_APPLICATION_CREDENTIALS=/abs/path/serviceAccountKey.json
 *   2. scripts/serviceAccountKey.json   (gitignored)
 *   3. Application Default Credentials  (`gcloud auth application-default login`)
 *
 * Security notes:
 *   - Generated passwords are printed ONCE and never written to disk by this
 *     script. Copy them into a password manager immediately.
 *   - Operators must change the temporary password on first sign-in.
 *   - Audit trail: every role change writes to /admin_audit_logs in RTDB.
 */

"use strict";

const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");

const admin = require("firebase-admin");

const PROJECT_ID = "nexride-8d5bc";
const DATABASE_URL = "https://nexride-8d5bc-default-rtdb.firebaseio.com";

const DEFAULT_ADMIN_EMAIL = "admin@nexride.africa";
const DEFAULT_SUPPORT_EMAIL = "support@nexride.africa";

function parseCli(argv) {
  const args = argv.slice(2);
  let adminEmail = DEFAULT_ADMIN_EMAIL;
  let supportEmail = DEFAULT_SUPPORT_EMAIL;
  let onlyAdmin = false;
  let onlySupport = false;
  let verifyOnly = false;
  for (let i = 0; i < args.length; i += 1) {
    const v = args[i];
    if (v === "--admin-email") {
      adminEmail = args[++i];
    } else if (v.startsWith("--admin-email=")) {
      adminEmail = v.split("=").slice(1).join("=");
    } else if (v === "--support-email") {
      supportEmail = args[++i];
    } else if (v.startsWith("--support-email=")) {
      supportEmail = v.split("=").slice(1).join("=");
    } else if (v === "--only-admin") {
      onlyAdmin = true;
    } else if (v === "--only-support") {
      onlySupport = true;
    } else if (v === "--verify-only") {
      verifyOnly = true;
    } else if (v === "--help" || v === "-h") {
      printHelp();
      process.exit(0);
    }
  }
  return { adminEmail, supportEmail, onlyAdmin, onlySupport, verifyOnly };
}

function printHelp() {
  console.log(
    "Usage: node scripts/create_admin_user.js [options]\n" +
      "\n" +
      "  --admin-email <email>     default: admin@nexride.africa\n" +
      "  --support-email <email>   default: support@nexride.africa\n" +
      "  --only-admin              Skip provisioning the support account.\n" +
      "  --only-support            Skip provisioning the admin account.\n" +
      "  --verify-only             Read the current claims / RTDB / Firestore\n" +
      "                            state for the admin and support emails and\n" +
      "                            print a diagnostic. Makes NO writes.\n",
  );
}

function configureCredentials() {
  if (process.env.GOOGLE_APPLICATION_CREDENTIALS) {
    return `env:GOOGLE_APPLICATION_CREDENTIALS=${process.env.GOOGLE_APPLICATION_CREDENTIALS}`;
  }
  const local = path.resolve(__dirname, "serviceAccountKey.json");
  if (fs.existsSync(local)) {
    process.env.GOOGLE_APPLICATION_CREDENTIALS = local;
    return `file:${local}`;
  }
  const adc = path.join(
    process.env.HOME || "",
    ".config/gcloud/application_default_credentials.json",
  );
  if (fs.existsSync(adc)) {
    process.env.GOOGLE_APPLICATION_CREDENTIALS = adc;
    return `file:${adc} (Application Default Credentials)`;
  }
  return null;
}

function generatePassword(length = 32) {
  // Strong: 32 chars from base64url alphabet => well over 180 bits of entropy.
  return crypto
    .randomBytes(length * 2)
    .toString("base64")
    .replace(/[+/=]/g, "")
    .slice(0, length);
}

async function ensureUser(email) {
  try {
    const user = await admin.auth().getUserByEmail(email);
    return { user, created: false, password: null };
  } catch (error) {
    if (error?.code !== "auth/user-not-found") throw error;
    const password = generatePassword(32);
    const user = await admin.auth().createUser({
      email,
      password,
      emailVerified: false,
      disabled: false,
    });
    return { user, created: true, password };
  }
}

async function mergeClaims(uid, patch) {
  const user = await admin.auth().getUser(uid);
  const base =
    user.customClaims && typeof user.customClaims === "object" ? user.customClaims : {};
  const merged = { ...base, ...patch };
  await admin.auth().setCustomUserClaims(uid, merged);
  return merged;
}

async function writeAudit(db, entry) {
  try {
    await db.ref("admin_audit_logs").push().set({ ...entry, created_at: Date.now() });
  } catch (error) {
    console.warn(`[create_admin_user] could not write audit log: ${error?.message || error}`);
  }
}

/**
 * Mark a NEWLY-CREATED account as needing a forced password change on first
 * sign-in. Stamps the `temporaryPassword: true` claim AND writes the matching
 * record to RTDB `/account_security/{uid}` so the Flutter portals (which
 * check both sources) consistently force-redirect the operator into the
 * change-password screen until they rotate their password.
 *
 * The flag is cleared by the `rotateAccountAfterPasswordChange` Cloud
 * Function after a successful password change.
 */
async function stampTemporaryPasswordFlag(db, { uid, email, role }) {
  const ts = Date.now();
  const merged = await mergeClaims(uid, { temporaryPassword: true });
  await db.ref(`account_security/${uid}`).set({
    temporaryPassword: true,
    email,
    role,
    reason: "initial_provisioning",
    createdAt: ts,
    lastUpdatedAt: ts,
  });
  return merged;
}

/**
 * Mirror role state into RTDB `/users/{uid}` so the legacy RTDB rules
 * that read `users/{uid}/role` (support_queue, admin_rides,
 * support_tickets, support_ticket_messages) grant access. Only writes
 * the role + email fields and never touches user-owned data, so it's
 * safe to re-run.
 *
 * NOTE: support gets `role: "support_agent"` (matches the custom claim
 * value); the RTDB rules were extended (database.rules.json) to accept
 * both the legacy `'support'` literal and the new `support_agent` /
 * `support_manager` values, so this stays aligned with claims.
 */
async function stampUsersRole(db, { uid, email, role }) {
  await db.ref(`users/${uid}/role`).set(role);
  await db.ref(`users/${uid}/email`).set(email);
  await db.ref(`users/${uid}/role_updated_at`).set(Date.now());
}

async function provisionAdmin(email, db, fsdb) {
  const { user, created, password } = await ensureUser(email);
  await db.ref(`admins/${user.uid}`).set(true);
  await stampUsersRole(db, { uid: user.uid, email, role: "admin" });
  let claims = await mergeClaims(user.uid, { admin: true, role: "admin" });
  if (created) {
    claims = await stampTemporaryPasswordFlag(db, {
      uid: user.uid,
      email,
      role: "admin",
    });
  }
  await fsdb.collection("support_staff").doc(user.uid).set(
    {
      email,
      role: "admin",
      enabled: true,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true },
  );
  await writeAudit(db, {
    type: "provision_admin_via_script",
    target_uid: user.uid,
    target_email: email,
    actor: "scripts/create_admin_user.js",
    created_user: created,
    temporary_password_set: created,
  });
  return { kind: "admin", email, uid: user.uid, created, password, claims };
}

async function provisionSupport(email, db, fsdb) {
  const { user, created, password } = await ensureUser(email);
  const ts = Date.now();
  await db.ref(`support_staff/${user.uid}`).set({
    email,
    role: "support_agent",
    enabled: true,
    disabled: false,
    updated_at: ts,
  });
  await stampUsersRole(db, { uid: user.uid, email, role: "support_agent" });
  let claims = await mergeClaims(user.uid, {
    support: true,
    support_staff: true,
    role: "support_agent",
  });
  if (created) {
    claims = await stampTemporaryPasswordFlag(db, {
      uid: user.uid,
      email,
      role: "support_agent",
    });
  }
  await fsdb.collection("support_staff").doc(user.uid).set(
    {
      email,
      role: "support_agent",
      enabled: true,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true },
  );
  await writeAudit(db, {
    type: "provision_support_via_script",
    target_uid: user.uid,
    target_email: email,
    actor: "scripts/create_admin_user.js",
    created_user: created,
    temporary_password_set: created,
  });
  return { kind: "support_agent", email, uid: user.uid, created, password, claims };
}

/**
 * READ-ONLY diagnostic. Reads the current claims, RTDB role mirrors,
 * and Firestore support_staff doc for an email and returns a structured
 * snapshot the caller can pretty-print. Used by `--verify-only` to
 * validate a previously provisioned operator without rewriting state.
 *
 * Returns null when the Auth user does not exist.
 */
async function verifyAccount(email, db, fsdb) {
  let user;
  try {
    user = await admin.auth().getUserByEmail(email);
  } catch (error) {
    if (error?.code === "auth/user-not-found") {
      return null;
    }
    throw error;
  }
  const claims =
    user.customClaims && typeof user.customClaims === "object"
      ? user.customClaims
      : {};

  const [adminFlagSnap, supportRecordSnap, usersRoleSnap, accountSecuritySnap] =
    await Promise.all([
      db.ref(`admins/${user.uid}`).get(),
      db.ref(`support_staff/${user.uid}`).get(),
      db.ref(`users/${user.uid}/role`).get(),
      db.ref(`account_security/${user.uid}`).get(),
    ]);

  let firestoreSupport = null;
  try {
    const doc = await fsdb.collection("support_staff").doc(user.uid).get();
    firestoreSupport = doc.exists ? doc.data() : null;
  } catch (error) {
    firestoreSupport = { _error: String(error?.message ?? error) };
  }

  return {
    email,
    uid: user.uid,
    disabled: user.disabled,
    emailVerified: user.emailVerified,
    claims,
    rtdb: {
      admins: adminFlagSnap.val(),
      support_staff: supportRecordSnap.val(),
      users_role: usersRoleSnap.val(),
      account_security: accountSecuritySnap.val(),
    },
    firestore: {
      support_staff: firestoreSupport,
    },
  };
}

function evaluateAccess(snapshot) {
  if (!snapshot) {
    return { allowed: false, reasons: ["auth_user_missing"] };
  }
  const reasons = [];
  const claims = snapshot.claims ?? {};
  const rtdb = snapshot.rtdb ?? {};
  if (claims.admin === true) reasons.push("claim:admin=true");
  if (claims.support === true) reasons.push("claim:support=true");
  if (claims.support_staff === true) reasons.push("claim:support_staff=true");
  if (claims.role === "admin") reasons.push("claim:role=admin");
  if (claims.role === "support_agent") reasons.push("claim:role=support_agent");
  if (claims.role === "support_manager") reasons.push("claim:role=support_manager");
  if (rtdb.admins === true) reasons.push("rtdb:/admins/{uid}=true");
  if (rtdb.support_staff && typeof rtdb.support_staff === "object") {
    const role = String(rtdb.support_staff.role ?? "").toLowerCase();
    const enabled =
      rtdb.support_staff.enabled !== false &&
      rtdb.support_staff.disabled !== true;
    if (
      enabled &&
      (role === "support_agent" || role === "support_manager")
    ) {
      reasons.push(`rtdb:/support_staff/{uid}.role=${role}`);
    }
  }
  if (
    rtdb.users_role === "admin" ||
    rtdb.users_role === "support" ||
    rtdb.users_role === "support_agent" ||
    rtdb.users_role === "support_manager"
  ) {
    reasons.push(`rtdb:/users/{uid}/role=${rtdb.users_role}`);
  }
  return { allowed: reasons.length > 0, reasons };
}

function printVerification(snapshot) {
  if (!snapshot) {
    console.log("  STATUS: NO AUTH USER (run without --verify-only to create)");
    return;
  }
  const evaluation = evaluateAccess(snapshot);
  console.log(`  uid                   : ${snapshot.uid}`);
  console.log(`  disabled              : ${snapshot.disabled}`);
  console.log(`  emailVerified         : ${snapshot.emailVerified}`);
  console.log(`  custom claims         : ${JSON.stringify(snapshot.claims)}`);
  console.log(
    `  /admins/{uid}         : ${JSON.stringify(snapshot.rtdb.admins ?? null)}`,
  );
  console.log(
    `  /support_staff/{uid}  : ${JSON.stringify(snapshot.rtdb.support_staff ?? null)}`,
  );
  console.log(
    `  /users/{uid}/role     : ${JSON.stringify(snapshot.rtdb.users_role ?? null)}`,
  );
  console.log(
    `  /account_security/{uid}: ${JSON.stringify(snapshot.rtdb.account_security ?? null)}`,
  );
  console.log(
    `  firestore support_staff: ${JSON.stringify(snapshot.firestore.support_staff ?? null)}`,
  );
  console.log(`  authorized            : ${evaluation.allowed}`);
  console.log(`  matched paths         : ${evaluation.reasons.join(", ") || "(none)"}`);
}

function printSummary(results, credSource) {
  const banner = "=".repeat(64);
  console.log(banner);
  console.log("ADMIN / SUPPORT PROVISIONING SUMMARY");
  console.log(banner);
  console.log(`project        : ${PROJECT_ID}`);
  console.log(`credentials    : ${credSource}`);
  console.log("");
  for (const info of results) {
    console.log(`role           : ${info.kind}`);
    console.log(`email          : ${info.email}`);
    console.log(`uid            : ${info.uid}`);
    console.log(
      `created now    : ${
        info.created ? "yes" : "no  (existing user reused — password unchanged)"
      }`,
    );
    console.log(`claims         : ${JSON.stringify(info.claims)}`);
    if (info.created && info.password) {
      console.log("");
      console.log("  >>> generated temporary password (copy to a secret manager NOW,");
      console.log("  >>> never paste it back into Cursor or commit it):");
      console.log(`  >>> ${info.password}`);
      console.log("");
      console.log("  This account is flagged temporaryPassword=true (claim + RTDB).");
      console.log("  The portal will force a password change on first sign-in.");
    }
    console.log(banner);
  }
  console.log("");
  console.log("Next steps:");
  console.log("  1. Save any generated passwords to 1Password / Bitwarden.");
  console.log("  2. Operator signs in at https://nexride.africa/admin or /support.");
  console.log("     The portal will redirect them to the Change Password screen.");
  console.log("     After a successful change, the temporaryPassword flag is");
  console.log("     cleared and ALL refresh tokens are revoked (other sessions");
  console.log("     are signed out automatically).");
  console.log("  3. Once both new accounts work, remove the personal-Gmail entry");
  console.log("     from /admins in RTDB and clear its custom claim. See");
  console.log("     docs/admin_access.md and docs/admin_password_management.md");
  console.log("     for the offboarding runbook.");
}

async function main() {
  const credSource = configureCredentials();
  if (!credSource) {
    console.error(
      "[create_admin_user] No service-account credentials found.\n" +
        "Provide one of:\n" +
        "  - GOOGLE_APPLICATION_CREDENTIALS=/abs/path/serviceAccountKey.json\n" +
        "  - scripts/serviceAccountKey.json   (gitignored)\n" +
        "  - gcloud auth application-default login\n" +
        "\n" +
        "See docs/admin_access.md for how to download a service-account key.",
    );
    process.exit(2);
  }

  const { adminEmail, supportEmail, onlyAdmin, onlySupport, verifyOnly } =
    parseCli(process.argv);

  admin.initializeApp({ projectId: PROJECT_ID, databaseURL: DATABASE_URL });
  const db = admin.database();
  const fsdb = admin.firestore();

  if (verifyOnly) {
    const banner = "=".repeat(64);
    console.log(banner);
    console.log("ADMIN / SUPPORT ROLE VERIFICATION (read-only, no writes)");
    console.log(banner);
    console.log(`project        : ${PROJECT_ID}`);
    console.log(`credentials    : ${credSource}`);
    console.log("");

    const targets = [];
    if (!onlySupport) targets.push({ kind: "admin", email: adminEmail });
    if (!onlyAdmin) targets.push({ kind: "support", email: supportEmail });

    for (const target of targets) {
      console.log(`role           : ${target.kind}`);
      console.log(`email          : ${target.email}`);
      const snap = await verifyAccount(target.email, db, fsdb);
      printVerification(snap);
      console.log(banner);
    }
    return;
  }

  const results = [];
  if (!onlySupport) {
    results.push(await provisionAdmin(adminEmail, db, fsdb));
  }
  if (!onlyAdmin) {
    results.push(await provisionSupport(supportEmail, db, fsdb));
  }

  printSummary(results, credSource);

  // Always print a fresh post-write verification so the operator can confirm
  // every authorization surface ended up in the expected state — same shape
  // produced by --verify-only.
  console.log("");
  console.log("Post-write verification:");
  for (const r of results) {
    const snap = await verifyAccount(r.email, db, fsdb);
    console.log(`\nrole : ${r.kind}\nemail: ${r.email}`);
    printVerification(snap);
  }
}

main().catch((error) => {
  console.error("[create_admin_user] failed:", error?.message || error);
  process.exit(1);
});
