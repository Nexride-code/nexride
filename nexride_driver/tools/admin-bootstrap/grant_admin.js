#!/usr/bin/env node

'use strict';

const fs = require('fs');
const path = require('path');
const admin = require('firebase-admin');

const DEFAULT_SERVICE_ACCOUNT_PATH = path.join(__dirname, 'service-account.json');

function parseArgs(argv) {
  const args = {
    mode: 'both',
    revoke: false,
    verbose: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const entry = argv[index];
    const next = argv[index + 1];

    switch (entry) {
      case '--uid':
        args.uid = next;
        index += 1;
        break;
      case '--email':
        args.email = next;
        index += 1;
        break;
      case '--service-account':
        args.serviceAccount = next;
        index += 1;
        break;
      case '--database-url':
        args.databaseUrl = next;
        index += 1;
        break;
      case '--project-id':
        args.projectId = next;
        index += 1;
        break;
      case '--db-only':
        args.mode = 'database';
        break;
      case '--claims-only':
        args.mode = 'claims';
        break;
      case '--both':
        args.mode = 'both';
        break;
      case '--revoke':
        args.revoke = true;
        break;
      case '--verbose':
        args.verbose = true;
        break;
      case '--help':
      case '-h':
        args.help = true;
        break;
      default:
        if (entry.startsWith('--')) {
          throw new Error(`Unknown argument: ${entry}`);
        }
    }
  }

  return args;
}

function printHelp() {
  console.log(`
NexRide admin bootstrap

Usage:
  node grant_admin.js --uid <firebase_uid> [--both|--db-only|--claims-only]
  node grant_admin.js --email <firebase_email> [--both|--db-only|--claims-only]
  node grant_admin.js --uid <firebase_uid> --revoke [--both|--db-only|--claims-only]

Options:
  --uid <uid>                Firebase Auth user UID
  --email <email>            Firebase Auth email; resolves the user UID first
  --db-only                  Only write /admins/{uid} in Realtime Database
  --claims-only              Only set the Firebase Auth custom claim admin: true
  --both                     Do both operations (default)
  --revoke                   Remove admin access instead of granting it
  --service-account <path>   Path to a Firebase service account JSON
  --database-url <url>       Override the RTDB URL
  --project-id <id>          Override the Firebase project ID
  --verbose                  Print extra debug information
  --help                     Show this help text
`);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    printHelp();
    return;
  }

  if (!args.uid && !args.email) {
    throw new Error('Provide --uid or --email so the admin utility can find the user.');
  }

  const appContext = initializeFirebase(args);
  if (args.verbose) {
    console.log(`Using Firebase project: ${appContext.projectId}`);
    console.log(`Using database URL: ${appContext.databaseUrl}`);
    console.log(`Credential source: ${appContext.credentialSource}`);
  }

  const userRecord = await resolveUser(args);
  const desiredAdminValue = !args.revoke;
  const operations = [];

  if (args.mode === 'database' || args.mode === 'both') {
    operations.push(updateAdminsAllowlist(userRecord.uid, desiredAdminValue));
  }

  if (args.mode === 'claims' || args.mode === 'both') {
    operations.push(updateCustomClaim(userRecord, desiredAdminValue));
  }

  await Promise.all(operations);

  const verification = await verifyState(userRecord.uid);

  console.log('');
  console.log(args.revoke ? 'Admin access revoked.' : 'Admin access granted.');
  console.log(`User UID: ${userRecord.uid}`);
  console.log(`User email: ${userRecord.email || '(no email on auth record)'}`);
  console.log(`Realtime Database /admins/${userRecord.uid}: ${String(verification.allowlistValue)}`);
  console.log(`Firebase Auth custom claim admin: ${String(verification.claimValue)}`);
  console.log('');
  console.log('Current app gate support:');
  console.log('- Realtime Database allowlist via /admins/{uid}');
  console.log('- Firebase custom claim via admin: true');
  console.log('');
  console.log('Recommended production path: use custom claims as the primary control.');
  console.log('Optional fallback: also write /admins/{uid} = true for operational recovery or transition.');
}

function initializeFirebase(args) {
  const serviceAccountPath =
    args.serviceAccount ||
    process.env.FIREBASE_SERVICE_ACCOUNT_PATH ||
    process.env.GOOGLE_APPLICATION_CREDENTIALS ||
    DEFAULT_SERVICE_ACCOUNT_PATH;

  let credential;
  let credentialSource;
  let projectId = args.projectId || process.env.FIREBASE_PROJECT_ID || '';

  if (serviceAccountPath && fs.existsSync(serviceAccountPath)) {
    const serviceAccount = JSON.parse(fs.readFileSync(serviceAccountPath, 'utf8'));
    credential = admin.credential.cert(serviceAccount);
    credentialSource = path.resolve(serviceAccountPath);
    projectId = projectId || serviceAccount.project_id || '';
  } else if (process.env.GOOGLE_APPLICATION_CREDENTIALS) {
    credential = admin.credential.applicationDefault();
    credentialSource = 'application_default_credentials';
  } else {
    throw new Error(
      'No Firebase service account credentials were found. ' +
        'Place a service account JSON at tools/admin-bootstrap/service-account.json ' +
        'or set GOOGLE_APPLICATION_CREDENTIALS / FIREBASE_SERVICE_ACCOUNT_PATH.',
    );
  }

  if (!projectId) {
    throw new Error(
      'Could not determine the Firebase project ID. Pass --project-id or use a service account JSON with project_id.',
    );
  }

  const databaseUrl =
    args.databaseUrl ||
    process.env.FIREBASE_DATABASE_URL ||
    `https://${projectId}-default-rtdb.firebaseio.com`;

  if (!admin.apps.length) {
    admin.initializeApp({
      credential,
      projectId,
      databaseURL: databaseUrl,
    });
  }

  return {
    credentialSource,
    projectId,
    databaseUrl,
  };
}

async function resolveUser(args) {
  if (args.uid && args.email) {
    const user = await admin.auth().getUser(args.uid);
    if ((user.email || '').toLowerCase() !== args.email.toLowerCase()) {
      throw new Error(
        `UID/email mismatch. UID ${args.uid} belongs to ${user.email || 'a user without an email'}, not ${args.email}.`,
      );
    }
    return user;
  }

  if (args.uid) {
    return admin.auth().getUser(args.uid);
  }

  return admin.auth().getUserByEmail(args.email);
}

async function updateAdminsAllowlist(uid, shouldGrant) {
  const ref = admin.database().ref(`admins/${uid}`);
  if (shouldGrant) {
    await ref.set(true);
    return;
  }
  await ref.remove();
}

async function updateCustomClaim(userRecord, shouldGrant) {
  const currentClaims = { ...(userRecord.customClaims || {}) };
  if (shouldGrant) {
    currentClaims.admin = true;
  } else {
    delete currentClaims.admin;
  }
  await admin.auth().setCustomUserClaims(userRecord.uid, currentClaims);
}

async function verifyState(uid) {
  const [allowlistSnapshot, userRecord] = await Promise.all([
    admin.database().ref(`admins/${uid}`).get(),
    admin.auth().getUser(uid),
  ]);

  return {
    allowlistValue: allowlistSnapshot.exists() ? allowlistSnapshot.val() : null,
    claimValue: Boolean(userRecord.customClaims && userRecord.customClaims.admin === true),
  };
}

main().catch((error) => {
  console.error('');
  console.error('NexRide admin bootstrap failed.');
  console.error(error.message || error);
  console.error('');
  process.exitCode = 1;
});

