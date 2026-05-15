const assert = require("node:assert/strict");
const { test } = require("node:test");

function makeFirestoreIntentMock(docData, opts = {}) {
  const audits = [];
  let lastSet = opts.captureSet ? {} : null;
  return {
    collection() {
      return {
        doc() {
          return {
            async get() {
              if (opts.noDoc) {
                return { exists: false, data: () => null };
              }
              return { exists: !!docData, data: () => docData };
            },
            async set(patch) {
              if (lastSet) Object.assign(lastSet, patch);
            },
            collection() {
              return {
                async add(row) {
                  audits.push(row);
                },
              };
            },
          };
        },
      };
    },
    audits,
    lastSet,
  };
}

test("evaluateVaIntentExpiryForSettlement returns pending_review after expiry", async () => {
  const { evaluateVaIntentExpiryForSettlement } = require("../bank_transfer_va");
  const fs = makeFirestoreIntentMock({
    expires_at_ms: Date.now() - 60_000,
    legacy_manual_bank: false,
  });
  const r = await evaluateVaIntentExpiryForSettlement({
    fs,
    txRef: "nexride_va_demo",
    webhookLabel: "charge.completed",
  });
  assert.equal(r.mode, "pending_review");
  assert.equal(fs.audits.some((e) => e.type === "late_transfer_flagged"), true);
});

test("evaluateVaIntentExpiryForSettlement ok when intent doc missing", async () => {
  const { evaluateVaIntentExpiryForSettlement } = require("../bank_transfer_va");
  const fs = makeFirestoreIntentMock(null, { noDoc: true });
  const r = await evaluateVaIntentExpiryForSettlement({
    fs,
    txRef: "missing",
    webhookLabel: "charge.completed",
  });
  assert.equal(r.mode, "ok");
});

test("evaluateVaIntentExpiryForSettlement skips legacy manual rows", async () => {
  const { evaluateVaIntentExpiryForSettlement } = require("../bank_transfer_va");
  const fs = makeFirestoreIntentMock({
    expires_at_ms: Date.now() - 60_000,
    legacy_manual_bank: true,
  });
  const r = await evaluateVaIntentExpiryForSettlement({
    fs,
    txRef: "legacy",
    webhookLabel: "charge.completed",
  });
  assert.equal(r.mode, "ok");
});

test("evaluateVaIntentExpiryForSettlement allows settlement before expiry", async () => {
  const { evaluateVaIntentExpiryForSettlement } = require("../bank_transfer_va");
  const fs = makeFirestoreIntentMock({
    expires_at_ms: Date.now() + 3_600_000,
    legacy_manual_bank: false,
  });
  const r = await evaluateVaIntentExpiryForSettlement({
    fs,
    txRef: "active_va",
    webhookLabel: "charge.completed",
  });
  assert.equal(r.mode, "ok");
});
