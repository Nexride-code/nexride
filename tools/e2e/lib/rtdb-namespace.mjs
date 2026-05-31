import admin from "firebase-admin";

/** Keep in sync with tools/e2e/config/emulator.mjs */
export const E2E_PROJECT_ID = "nexride-e2e-local";

/** Canonical E2E RTDB namespace — matches Functions emulator Admin SDK (?ns=projectId). */
export const E2E_RTDB_CANONICAL_INSTANCE = E2E_PROJECT_ID;

/** Alternate emulator instance (rules load target); not used by Functions runtime in E2E. */
export const E2E_RTDB_DEFAULT_INSTANCE = `${E2E_PROJECT_ID}-default-rtdb`;

/** Same as canonical; kept for namespace probe / repro comparisons. */
export const E2E_RTDB_LEGACY_INSTANCE = E2E_PROJECT_ID;

function emulatorHostPort() {
  const hostEnv = String(process.env.FIREBASE_DATABASE_EMULATOR_HOST ?? "").trim();
  if (hostEnv.includes(":")) {
    return hostEnv.split(":");
  }
  return ["127.0.0.1", "9001"];
}

/**
 * Canonical RTDB URL for E2E harness seed/read — aligned with Functions emulator
 * FIREBASE_CONFIG (`http://127.0.0.1:9001/?ns=nexride-e2e-local`).
 */
export function resolveE2eRtdbDatabaseUrl() {
  const [rtdbHost, rtdbPort] = emulatorHostPort();
  const namespace = E2E_RTDB_CANONICAL_INSTANCE;

  return {
    databaseURL: `http://${rtdbHost}:${rtdbPort}?ns=${namespace}`,
    namespace,
    alternateNamespace: E2E_RTDB_DEFAULT_INSTANCE,
    emulatorHost: `${rtdbHost}:${rtdbPort}`,
  };
}

export function buildE2eRtdbDatabaseUrl(namespace) {
  const [rtdbHost, rtdbPort] = emulatorHostPort();
  return `http://${rtdbHost}:${rtdbPort}?ns=${namespace}`;
}

export function getAdminForNamespace(namespace) {
  const appName = `e2e-rtdb-${namespace}`;
  try {
    return admin.app(appName);
  } catch {
    return admin.initializeApp(
      {
        projectId: E2E_PROJECT_ID,
        databaseURL: buildE2eRtdbDatabaseUrl(namespace),
      },
      appName,
    );
  }
}

/**
 * Repro: set → get → transaction on the same ref in one namespace.
 */
export async function runRtdbTransactionRepro(namespace, label = namespace) {
  const app = getAdminForNamespace(namespace);
  const db = app.database();
  const path = `e2e_tx_test/${label}_${Date.now()}_${process.pid}`;
  const ref = db.ref(path);

  await ref.set({ x: 1, label, namespace });

  const snap = await ref.get();
  const getExists = snap.exists();
  const getVal = snap.val();

  let txCur = "__not_called__";
  let txCurIsNull = null;
  let txCommitted = false;

  const txResult = await ref.transaction((cur) => {
    txCur = cur;
    txCurIsNull = cur === null;
    console.log("E2E_RTDB_TX_REPRO_CALLBACK", {
      label,
      namespace,
      path,
      cur_is_null: cur === null,
      cur_is_undefined: cur === undefined,
      cur,
    });
    return cur;
  });
  txCommitted = Boolean(txResult.committed);

  const result = {
    label,
    namespace,
    path,
    databaseURL: app.options.databaseURL ?? null,
    get_exists: getExists,
    get_x: getVal?.x ?? null,
    tx_cur_is_null: txCurIsNull,
    tx_cur: txCur,
    tx_committed: txCommitted,
    repro_pass: getExists && txCurIsNull === false && txCommitted,
  };

  console.log("E2E_RTDB_TX_REPRO", result);
  return result;
}

export async function runAllRtdbTransactionRepros() {
  const canonicalResult = await runRtdbTransactionRepro(
    E2E_RTDB_CANONICAL_INSTANCE,
    "canonical_instance",
  );
  const alternateResult = await runRtdbTransactionRepro(
    E2E_RTDB_DEFAULT_INSTANCE,
    "alternate_instance",
  );
  return { canonicalResult, alternateResult };
}
