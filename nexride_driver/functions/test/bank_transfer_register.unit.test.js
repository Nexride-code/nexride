const test = require("node:test");
const assert = require("node:assert/strict");
const {
  parseOfficialBankObject,
  getNexrideOfficialBankAccount,
} = require("../nexride_official_bank_config");

function makeDb({ bankVal, rideVal }) {
  return {
    ref(path) {
      const p = String(path);
      return {
        get: async () => {
          if (p === "app_config/nexride_official_bank_account") {
            return { val: () => bankVal, exists: () => bankVal != null };
          }
          if (p.startsWith("ride_requests/")) {
            return { val: () => rideVal, exists: () => rideVal != null };
          }
          if (p.startsWith("payment_transactions/")) {
            return {
              set: async (payload) => {
                makeDb._lastTx = payload;
              },
            };
          }
          return {
            get: async () => ({ val: () => null, exists: () => false }),
            set: async () => {},
            update: async (payload) => {
              makeDb._lastRideUpdate = payload;
            },
          };
        },
        update: async (payload) => {
          makeDb._lastRideUpdate = payload;
        },
      };
    },
  };
}

test("getNexrideOfficialBankAccount returns account payload when configured", async () => {
  const db = makeDb({
    bankVal: {
      bank_name: "Zenith",
      account_name: "NexRide Ltd",
      account_number: "1234567890",
    },
    rideVal: null,
  });
  const r = await getNexrideOfficialBankAccount(
    {},
    { auth: { uid: "rider1" } },
    db,
  );
  assert.equal(r.success, true);
  assert.equal(r.bank_name, "Zenith");
  assert.equal(r.account_number, "1234567890");
});

test("getNexrideOfficialBankAccount missing config returns structured error", async () => {
  const db = makeDb({ bankVal: null, rideVal: null });
  const r = await getNexrideOfficialBankAccount(
    {},
    { auth: { uid: "rider1" } },
    db,
  );
  assert.equal(r.success, false);
  assert.equal(r.reason, "official_bank_not_configured");
});

test("parseOfficialBankObject rejects incomplete rows", () => {
  assert.equal(parseOfficialBankObject({ bank_name: "X" }), null);
});

test("registerBankTransferPayment rejects when neither rideId nor deliveryId", async () => {
  const { registerBankTransferPayment } = require("../payment_flow");
  const db = makeDb({
    bankVal: null,
    rideVal: null,
  });
  const r = await registerBankTransferPayment(
    {},
    { auth: { uid: "rider1", token: { email: "a@b.c" } } },
    db,
  );
  assert.equal(r.success, false);
  assert.equal(r.reason, "invalid_input");
});

/** Full VA issuance is covered in integration/deploy smoke (requires Flutterwave + Firestore writes). */
