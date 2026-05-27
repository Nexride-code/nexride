const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  isCardPaymentMethod,
  cardPaymentAllowsMatching,
  CARD_AUTHORIZED_STATUSES,
  CARD_BLOCKED_MATCH_STATUSES,
} = require("../card_payment_flow");

test("isCardPaymentMethod recognizes card family", () => {
  assert.equal(isCardPaymentMethod("card"), true);
  assert.equal(isCardPaymentMethod("flutterwave"), true);
  assert.equal(isCardPaymentMethod("bank_transfer"), false);
});

test("cardPaymentAllowsMatching requires authorized status", () => {
  assert.equal(
    cardPaymentAllowsMatching({
      payment_method: "card",
      payment_status: "card_authorized",
      payment_transaction_id: "12345",
    }),
    true,
  );
  assert.equal(
    cardPaymentAllowsMatching({
      payment_method: "card",
      payment_status: "pending",
    }),
    false,
  );
  assert.equal(
    cardPaymentAllowsMatching({
      payment_method: "card",
      payment_status: "card_authorization_failed",
    }),
    false,
  );
});

test("status sets include required card lifecycle values", () => {
  for (const status of [
    "card_authorized",
    "preauthorized",
    "card_captured",
    "card_authorizing",
    "card_authorization_failed",
    "card_voided",
  ]) {
    const inAuthorized = CARD_AUTHORIZED_STATUSES.has(status);
    const inBlocked = CARD_BLOCKED_MATCH_STATUSES.has(status);
    assert.equal(inAuthorized || inBlocked, true, status);
  }
});
