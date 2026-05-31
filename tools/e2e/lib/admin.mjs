import admin from "firebase-admin";
import { E2E_PROJECT_ID, resolveE2eRtdbDatabaseUrl } from "./rtdb-namespace.mjs";
import { assertNotProductionRuntime } from "../config/project-guard.mjs";

let initialized = false;
let rtdbTarget = null;

export function getE2eRtdbTarget() {
  if (!rtdbTarget) {
    rtdbTarget = resolveE2eRtdbDatabaseUrl();
  }
  return rtdbTarget;
}

export function initE2eAdmin() {
  assertNotProductionRuntime();
  if (initialized) {
    return admin;
  }
  const target = getE2eRtdbTarget();
  if (!admin.apps.length) {
    admin.initializeApp({
      projectId: E2E_PROJECT_ID,
      databaseURL: target.databaseURL,
    });
  }
  initialized = true;
  return admin;
}

export function rtdb() {
  return initE2eAdmin().database();
}

export function firestore() {
  return initE2eAdmin().firestore();
}

export function auth() {
  return initE2eAdmin().auth();
}
