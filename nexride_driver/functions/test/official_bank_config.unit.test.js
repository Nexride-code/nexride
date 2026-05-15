const test = require("node:test");
const assert = require("node:assert/strict");
const {
  parseOfficialBankObject,
  OFFICIAL_BANK_RTDB_PATHS,
  getNexrideOfficialBankAccount,
} = require("../nexride_official_bank_config");

test("parseOfficialBankObject accepts snake_case", () => {
  const o = parseOfficialBankObject({
    bank_name: "Test Bank",
    account_name: "Test Ltd",
    account_number: "1234567890",
  });
  assert.equal(o.bank_name, "Test Bank");
  assert.equal(o.account_number, "1234567890");
});

test("parseOfficialBankObject accepts nested official_bank", () => {
  const o = parseOfficialBankObject({
    official_bank: {
      bankName: "B",
      accountName: "A",
      accountNumber: "1",
    },
  });
  assert.ok(o);
  assert.equal(o.bank_name, "B");
});

test("canonical path is listed first", () => {
  assert.match(OFFICIAL_BANK_RTDB_PATHS[0], /nexride_official_bank_account/);
});

test("getNexrideOfficialBankAccount requires auth", async () => {
  const r = await getNexrideOfficialBankAccount({}, { auth: null }, {});
  assert.equal(r.success, false);
  assert.equal(r.reason, "unauthorized");
});
