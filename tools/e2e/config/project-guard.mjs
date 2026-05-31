import { E2E_PROJECT_ID } from "./emulator.mjs";

/** Known production / staging project ids that must never run E2E against live Firebase. */
const BLOCKED_PROJECT_IDS = new Set([
  "nexride-8d5bc",
]);

const BLOCKED_PROJECT_PATTERNS = [/nexride-8d5bc/i, /-prod$/i, /production/i];

export function isBlockedProjectId(projectId) {
  const id = String(projectId ?? "").trim();
  if (!id) return true;
  if (BLOCKED_PROJECT_IDS.has(id)) return true;
  return BLOCKED_PROJECT_PATTERNS.some((re) => re.test(id));
}

export function assertE2eProjectSafe(projectId = E2E_PROJECT_ID) {
  const id = String(projectId ?? "").trim();
  if (isBlockedProjectId(id)) {
    throw new Error(
      `E2E refused: project id "${id}" looks like production. Use ${E2E_PROJECT_ID} with emulators only.`,
    );
  }
  if (id !== E2E_PROJECT_ID) {
    throw new Error(
      `E2E refused: expected project id "${E2E_PROJECT_ID}", got "${id}".`,
    );
  }
}

export function assertEmulatorEnv() {
  const rtdb = String(process.env.FIREBASE_DATABASE_EMULATOR_HOST ?? "").trim();
  const auth = String(process.env.FIREBASE_AUTH_EMULATOR_HOST ?? "").trim();
  const fs = String(process.env.FIRESTORE_EMULATOR_HOST ?? "").trim();
  if (!rtdb || !auth || !fs) {
    throw new Error(
      "E2E refused: emulator env vars missing. Run via tools/e2e/run-phase0.sh (firebase emulators:exec).",
    );
  }
  if (/firebaseio\.com/i.test(rtdb) || /googleapis\.com/i.test(rtdb)) {
    throw new Error(`E2E refused: FIREBASE_DATABASE_EMULATOR_HOST looks like production: ${rtdb}`);
  }
}

export function assertNotProductionRuntime(projectId = E2E_PROJECT_ID) {
  assertE2eProjectSafe(projectId);
  assertEmulatorEnv();
  for (const key of ["GCLOUD_PROJECT", "GOOGLE_CLOUD_PROJECT", "FIREBASE_CONFIG"]) {
    const val = String(process.env[key] ?? "").trim();
    if (val && isBlockedProjectId(val)) {
      throw new Error(`E2E refused: ${key}=${val} is a blocked production project.`);
    }
  }
}
