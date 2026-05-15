const test = require("node:test");
const assert = require("node:assert/strict");
const {
  buildFlutterwaveRedirectUrl,
  buildAppDeepLinkFromReturnParams,
} = require("../payment_redirect");

test("buildFlutterwaveRedirectUrl includes merchant context", () => {
  const url = buildFlutterwaveRedirectUrl({
    appContext: "merchant",
    flow: "merchant_topup",
    txRef: "tx123",
    merchantId: "mid1",
    uid: "uid1",
  });
  assert.match(url, /flutterwave-return\.html/);
  assert.match(url, /app=merchant/);
  assert.match(url, /flow=merchant_topup/);
  assert.match(url, /tx_ref=tx123/);
  assert.match(url, /merchantId=mid1/);
});

test("buildAppDeepLinkFromReturnParams routes merchant to nexride-merchant scheme", () => {
  const link = buildAppDeepLinkFromReturnParams({
    app: "merchant",
    tx_ref: "tx123",
    status: "cancelled",
  });
  assert.match(link, /^nexride-merchant:\/\//);
  assert.match(link, /tx_ref=tx123/);
});
