"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  validateDriverWithdrawalDestinationInput,
  driverWithdrawalRecordHasPayoutDestination,
} = require("../withdraw_flow");

test("validateDriverWithdrawalDestinationInput accepts canonical payload", () => {
  const r = validateDriverWithdrawalDestinationInput({
    bank_name: "Guaranty Trust Bank",
    account_number: "0123456789",
    account_holder_name: "Ada Rider",
    bank_code: "058",
  });
  assert.equal(r.ok, true);
  assert.equal(r.value.bank_name, "Guaranty Trust Bank");
  assert.equal(r.value.account_number, "0123456789");
  assert.equal(r.value.account_holder_name, "Ada Rider");
  assert.equal(r.value.bank_code, "058");
});

test("validateDriverWithdrawalDestinationInput strips non-digits from account number", () => {
  const r = validateDriverWithdrawalDestinationInput({
    bankName: "Access Bank",
    accountNumber: " 0123-4567-8901 ",
    account_holder_name: "Sam Driver",
  });
  assert.equal(r.ok, true);
  assert.equal(r.value.account_number, "012345678901");
});

test("validateDriverWithdrawalDestinationInput rejects short account", () => {
  const r = validateDriverWithdrawalDestinationInput({
    bank_name: "Bank",
    account_number: "1234567",
    account_holder_name: "X",
  });
  assert.equal(r.ok, false);
});

test("driverWithdrawalRecordHasPayoutDestination reads withdrawal_destination_snapshot", () => {
  assert.equal(
    driverWithdrawalRecordHasPayoutDestination({
      withdrawal_destination_snapshot: {
        bank_name: "Zenith",
        account_number: "2087654321",
        account_holder_name: "Jane Doe",
      },
    }),
    true,
  );
  assert.equal(
    driverWithdrawalRecordHasPayoutDestination({
      withdrawal_destination_snapshot: {
        bank_name: "Zenith",
        account_number: "",
        account_holder_name: "Jane Doe",
      },
    }),
    false,
  );
});

test("driverWithdrawalRecordHasPayoutDestination reads legacy withdrawalAccount", () => {
  assert.equal(
    driverWithdrawalRecordHasPayoutDestination({
      withdrawalAccount: {
        bankName: "UBA",
        accountNumber: "1022334455",
        accountName: "Legacy Holder",
      },
    }),
    true,
  );
});
