const { test } = require("node:test");

/**
 * Merchant order lifecycle should mirror ride_callables canonical assignment:
 * order row → merchant notify → accept/reject → rider sync → admin ops bucket.
 * Full integration tests pending — see merchant_commerce.js accept/reject handlers.
 */
test("TODO: merchant accept writes canonical order_status and rider-visible state", {
  skip: "merchant lifecycle parity tracked separately",
});

test("TODO: merchant reject keeps rider order visible with rejected status", {
  skip: "merchant lifecycle parity tracked separately",
});
