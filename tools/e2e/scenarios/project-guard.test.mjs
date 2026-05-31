import assert from "node:assert/strict";
import { test } from "node:test";
import { E2E_PROJECT_ID } from "../config/emulator.mjs";
import { assertE2eProjectSafe, isBlockedProjectId } from "../config/project-guard.mjs";

test("blocks production project id nexride-8d5bc", () => {
  assert.equal(isBlockedProjectId("nexride-8d5bc"), true);
  assert.equal(isBlockedProjectId(E2E_PROJECT_ID), false);
  assert.throws(() => assertE2eProjectSafe("nexride-8d5bc"), /production/);
  assert.doesNotThrow(() => assertE2eProjectSafe(E2E_PROJECT_ID));
});
