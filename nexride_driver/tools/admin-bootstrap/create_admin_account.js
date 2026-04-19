#!/usr/bin/env node

'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const admin = require('firebase-admin');

const DEFAULT_SERVICE_ACCOUNT_PATH = path.join(__dirname, 'service-account.json');
const DEFAULT_FIREBASE_TOOLS_PATH = path.join(
  process.env.HOME || '',
  '.config',
  'configstore',
  'firebase-tools.json',
);
const DEFAULT_ADMIN_EMAIL = 'admin@nexride.com';
const DEFAULT_ADMIN_DISPLAY_NAME = 'NexRide Admin';

function parseArgs(argv) {
  const args = {
    verbose: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const entry = argv[index];
    const next = argv[index + 1];

    switch (entry) {
      case '--email':
        args.email = next;
        index += 1;
        break;
      case '--password':
        args.password = next;
        index += 1;
        break;
      case '--display-name':
        args.displayName = next;
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
Create a NexRide default admin account

Usage:
  node create_admin_account.js
  node create_admin_account.js --email ops@nexride.com --password "StrongPass123!"

Options:
  --email <email>             Admin email address (default: ${DEFAULT_ADMIN_EMAIL})
  --password <password>       Password to set. If omitted, a secure password is generated.
  --display-name <name>       Display name (default: "${DEFAULT_ADMIN_DISPLAY_NAME}")
  --service-account <path>    Path to a Firebase service account JSON
  --database-url <url>        Override the RTDB URL
  --project-id <id>           Override the Firebase project ID
  --verbose                   Print extra debug information
  --help                      Show this help text
`);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    printHelp();
    return;
  }

  const email = (args.email || DEFAULT_ADMIN_EMAIL).trim().toLowerCase();
  const password = (args.password || generatePassword()).trim();
  const displayName = (args.displayName || DEFAULT_ADMIN_DISPLAY_NAME).trim();

  if (!email || !email.includes('@')) {
    throw new Error('Provide a valid admin email address.');
  }

  if (password.length < 8) {
    throw new Error('Use a password with at least 8 characters.');
  }

  const appContext = initializeFirebase(args);
  if (args.verbose) {
    console.log(`Using Firebase project: ${appContext.projectId}`);
    console.log(`Using database URL: ${appContext.databaseUrl}`);
    console.log(`Credential source: ${appContext.credentialSource}`);
  }

  const created = await createOrUpdateAdminUser({
    email,
    password,
    displayName,
  });

  await Promise.all([
    updateAdminsAllowlist(created.user.uid, true),
    updateCustomClaim(created.user, true),
  ]);

  const verification = await verifyState(created.user.uid);

  console.log('');
  console.log(created.wasCreated ? 'Default admin account created.' : 'Default admin account updated.');
  console.log(`Email: ${email}`);
  console.log(`Password: ${password}`);
  console.log(`UID: ${created.user.uid}`);
  console.log(`Display name: ${displayName}`);
  console.log(`Realtime Database /admins/${created.user.uid}: ${String(verification.allowlistValue)}`);
  console.log(`Firebase Auth custom claim admin: ${String(verification.claimValue)}`);
  console.log('');
  console.log('Use this account to sign in at:');
  console.log('- /admin/login');
  console.log('- /support/login');
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
    const firebaseToolsCredential = loadFirebaseToolsCredential();
    if (!firebaseToolsCredential) {
      throw new Error(
        'No Firebase admin credentials were found. ' +
          'Place a service account JSON at tools/admin-bootstrap/service-account.json, ' +
          'set GOOGLE_APPLICATION_CREDENTIALS / FIREBASE_SERVICE_ACCOUNT_PATH, ' +
          'or sign into the Firebase CLI on this machine.',
      );
    }
    credential = admin.credential.refreshToken(firebaseToolsCredential);
    credentialSource = DEFAULT_FIREBASE_TOOLS_PATH;
  }

  if (!projectId) {
    projectId = inferProjectIdFromFirebaseTools();
  }

  if (!projectId) {
    projectId = 'nexride-8d5bc';
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

function loadFirebaseToolsCredential() {
  if (!DEFAULT_FIREBASE_TOOLS_PATH || !fs.existsSync(DEFAULT_FIREBASE_TOOLS_PATH)) {
    return null;
  }

  try {
    const config = JSON.parse(fs.readFileSync(DEFAULT_FIREBASE_TOOLS_PATH, 'utf8'));
    const refreshToken = config?.tokens?.refresh_token;
    const clientId = resolveFirebaseToolsClientId();
    const clientSecret = resolveFirebaseToolsClientSecret();

    if (!refreshToken || !clientId || !clientSecret) {
      return null;
    }

    return {
      type: 'authorized_user',
      client_id: clientId,
      client_secret: clientSecret,
      refresh_token: refreshToken,
    };
  } catch (error) {
    throw new Error(`Unable to read Firebase CLI credentials: ${error.message}`);
  }
}

function inferProjectIdFromFirebaseTools() {
  if (!DEFAULT_FIREBASE_TOOLS_PATH || !fs.existsSync(DEFAULT_FIREBASE_TOOLS_PATH)) {
    return '';
  }

  try {
    const config = JSON.parse(fs.readFileSync(DEFAULT_FIREBASE_TOOLS_PATH, 'utf8'));
    const activeProjects = config?.activeProjects || {};
    return (
      activeProjects['/Users/lexemm/nexride'] ||
      activeProjects[process.cwd()] ||
      activeProjects.default ||
      ''
    );
  } catch (error) {
    return '';
  }
}

let cachedFirebaseToolsApiConfig = null;

function resolveFirebaseToolsClientId() {
  return loadFirebaseToolsApiConfig().clientId || '';
}

function resolveFirebaseToolsClientSecret() {
  return loadFirebaseToolsApiConfig().clientSecret || '';
}

function loadFirebaseToolsApiConfig() {
  if (cachedFirebaseToolsApiConfig) {
    return cachedFirebaseToolsApiConfig;
  }

  const firebaseToolsApiPath = resolveFirebaseToolsApiModule();
  if (!firebaseToolsApiPath) {
    cachedFirebaseToolsApiConfig = {};
    return cachedFirebaseToolsApiConfig;
  }

  try {
    const firebaseToolsApi = require(firebaseToolsApiPath);
    cachedFirebaseToolsApiConfig = {
      clientId: safeInvoke(firebaseToolsApi.clientId),
      clientSecret: safeInvoke(firebaseToolsApi.clientSecret),
    };
    return cachedFirebaseToolsApiConfig;
  } catch (error) {
    cachedFirebaseToolsApiConfig = {};
    return cachedFirebaseToolsApiConfig;
  }
}

function resolveFirebaseToolsApiModule() {
  for (const candidate of [
    '/opt/homebrew/lib/node_modules/firebase-tools/lib/api.js',
    '/usr/local/lib/node_modules/firebase-tools/lib/api.js',
  ]) {
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }
  return null;
}

function safeInvoke(value) {
  if (typeof value !== 'function') {
    return '';
  }
  try {
    return value() || '';
  } catch (error) {
    return '';
  }
}

async function createOrUpdateAdminUser({ email, password, displayName }) {
  try {
    const existing = await admin.auth().getUserByEmail(email);
    const updated = await admin.auth().updateUser(existing.uid, {
      password,
      displayName,
      disabled: false,
    });
    return { user: updated, wasCreated: false };
  } catch (error) {
    if (isUserNotFound(error)) {
      const created = await admin.auth().createUser({
        email,
        password,
        displayName,
      });
      return { user: created, wasCreated: true };
    }
    throw error;
  }
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

function generatePassword() {
  return `NexRide!${crypto.randomBytes(6).toString('base64url')}`;
}

function isUserNotFound(error) {
  const code = (error && error.code) || '';
  return code === 'auth/user-not-found' || code === 'user-not-found';
}

main().catch((error) => {
  console.error('');
  console.error('NexRide default admin bootstrap failed.');
  console.error(error.message || error);
  console.error('');
  process.exitCode = 1;
});
