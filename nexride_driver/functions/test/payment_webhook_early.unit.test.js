const assert = require("node:assert/strict");
const { test, after } = require("node:test");

after(() => {
  delete process.env.FLUTTERWAVE_WEBHOOK_SECRET;
});

function createRtdbMock(seed = {}) {
  const store = { ...seed };
  return {
    ref(path) {
      const p = String(path || "");
      return {
        async get() {
          return {
            exists: () => Object.prototype.hasOwnProperty.call(store, p) && store[p] != null,
            val: () => store[p],
          };
        },
        async set(v) {
          store[p] = v;
        },
      };
    },
  };
}

test("handleFlutterwaveWebhook rejects invalid webhook signature", async () => {
  process.env.FLUTTERWAVE_WEBHOOK_SECRET = "good";
  const { handleFlutterwaveWebhook } = require("../payment_flow");
  const req = {
    headers: { "verif-hash": "bad" },
    body: { event: "charge.completed", data: { id: "1", status: "successful" } },
  };
  let statusCode;
  let body;
  const res = {
    status(n) {
      statusCode = n;
      return this;
    },
    send(s) {
      body = s;
    },
    json() {},
  };
  await handleFlutterwaveWebhook(req, res, createRtdbMock());
  assert.equal(statusCode, 401);
  assert.equal(body, "invalid signature");
});

test("handleFlutterwaveWebhook short-circuits duplicate delivery by webhookDedupeKey", async () => {
  process.env.FLUTTERWAVE_WEBHOOK_SECRET = "secret";
  const db = createRtdbMock({
    "webhook_applied/flutterwave_webhook/tid_88110022": { applied_at: 1 },
  });
  const { handleFlutterwaveWebhook } = require("../payment_flow");
  const req = {
    headers: { "verif-hash": "secret" },
    body: {
      event: "charge.completed",
      data: {
        id: "88110022",
        tx_ref: "nexride_va_x",
        status: "successful",
        amount: 100,
        currency: "NGN",
      },
    },
  };
  let statusCode;
  let body;
  const res = {
    status(n) {
      statusCode = n;
      return this;
    },
    send(s) {
      body = s;
    },
    json() {},
  };
  await handleFlutterwaveWebhook(req, res, db);
  assert.equal(statusCode, 200);
  assert.equal(body, "ok-duplicate-webhook");
});
