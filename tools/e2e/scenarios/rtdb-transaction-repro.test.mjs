import assert from "node:assert/strict";
import { after, test } from "node:test";
import admin from "firebase-admin";
import { assertNotProductionRuntime } from "../config/project-guard.mjs";
import {
  E2E_RTDB_CANONICAL_INSTANCE,
  E2E_RTDB_DEFAULT_INSTANCE,
  runAllRtdbTransactionRepros,
} from "../lib/rtdb-namespace.mjs";

console.log("E2E_RTDB_REPRO_TEST_START");

function snapshotProcessActivity(label) {
  const handles =
    typeof process._getActiveHandles === "function" ? process._getActiveHandles() : [];
  const requests =
    typeof process._getActiveRequests === "function" ? process._getActiveRequests() : [];
  const adminApps = admin.apps.map((app) => ({
    name: app.name,
    databaseURL: app.options.databaseURL ?? null,
  }));

  console.log(label, {
    active_handles: handles.length,
    active_requests: requests.length,
    handle_types: handles.map((h) => h?.constructor?.name ?? typeof h),
    admin_app_count: adminApps.length,
    admin_apps: adminApps,
  });

  return { handles, requests, adminApps };
}

after(async () => {
  const beforeDelete = snapshotProcessActivity("E2E_RTDB_REPRO_AFTER_BEFORE_DELETE");

  const appsToDelete = [...admin.apps];
  await Promise.all(appsToDelete.map((app) => app.delete()));

  const afterDelete = snapshotProcessActivity("E2E_RTDB_REPRO_AFTER_AFTER_DELETE");

  console.log("E2E_RTDB_REPRO_ADMIN_DELETE_DONE", {
    deleted_app_count: beforeDelete.adminApps.length,
    admin_app_count_remaining: afterDelete.adminApps.length,
  });
});

test("RTDB emulator: transaction must see data that get() sees (namespace repro)", async () => {
  assertNotProductionRuntime();

  const { canonicalResult, alternateResult } = await runAllRtdbTransactionRepros();

  console.log("E2E_RTDB_TX_REPRO_SUMMARY", {
    canonical_instance: E2E_RTDB_CANONICAL_INSTANCE,
    alternate_instance: E2E_RTDB_DEFAULT_INSTANCE,
    canonical_repro_pass: canonicalResult.repro_pass,
    alternate_repro_pass: alternateResult.repro_pass,
  });

  assert.equal(
    canonicalResult.repro_pass,
    true,
    `canonical RTDB instance (Functions-aligned) must pass set/get/transaction repro: ${JSON.stringify(canonicalResult)}`,
  );

  if (!alternateResult.repro_pass) {
    console.log("E2E_RTDB_TX_REPRO_ALTERNATE_NOTE", {
      note: "alternate -default-rtdb instance is not used by Functions emulator in E2E",
      alternateResult,
    });
  }

  console.log("E2E_RTDB_REPRO_TEST_BODY_END");
});

process.on("beforeExit", (code) => {
  console.log("E2E_RTDB_REPRO_PROCESS_BEFORE_EXIT", { code });
});

process.on("exit", (code) => {
  console.log("E2E_RTDB_REPRO_PROCESS_EXIT", { code });
});
