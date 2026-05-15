/**
 * Flutterwave hosted-checkout return URLs and per-app deep links.
 * Hosting page: /pay/flutterwave-return.html (routes by ?app=rider|merchant|driver)
 */

const HOSTING_BASE = String(
  process.env.NEXRIDE_HOSTING_BASE_URL || "https://nexride-8d5bc.web.app",
).replace(/\/$/, "");

const APP_DEEP_LINK = {
  rider: "nexride://card-link-complete",
  merchant: "nexride-merchant://pay/flutterwave-return",
  driver: "nexride-driver://pay/flutterwave-return",
};

function normAppContext(raw) {
  const v = String(raw ?? "")
    .trim()
    .toLowerCase();
  if (v === "merchant" || v === "driver" || v === "rider") {
    return v;
  }
  return "rider";
}

/**
 * @param {object} opts
 * @param {string} opts.appContext rider | merchant | driver
 * @param {string} [opts.flow]
 * @param {string} [opts.txRef]
 * @param {string} [opts.merchantId]
 * @param {string} [opts.uid]
 * @param {string} [opts.status]
 */
function buildFlutterwaveRedirectUrl(opts = {}) {
  const app = normAppContext(opts.appContext);
  const u = new URL(`${HOSTING_BASE}/pay/flutterwave-return.html`);
  u.searchParams.set("app", app);
  const flow = String(opts.flow ?? "").trim();
  if (flow) {
    u.searchParams.set("flow", flow);
  }
  const txRef = String(opts.txRef ?? opts.tx_ref ?? "").trim();
  if (txRef) {
    u.searchParams.set("tx_ref", txRef);
  }
  const merchantId = String(opts.merchantId ?? opts.merchant_id ?? "").trim();
  if (merchantId) {
    u.searchParams.set("merchantId", merchantId);
  }
  const uid = String(opts.uid ?? "").trim();
  if (uid) {
    u.searchParams.set("uid", uid);
  }
  const status = String(opts.status ?? "").trim();
  if (status) {
    u.searchParams.set("status", status);
  }
  return u.toString();
}

/**
 * Deep link opened from flutterwave-return.html (custom scheme per app).
 */
function buildAppDeepLinkFromReturnParams(params = {}) {
  const app = normAppContext(params.app);
  const base = APP_DEEP_LINK[app] || APP_DEEP_LINK.rider;
  const u = new URL(base);
  const txRef = String(params.tx_ref ?? params.txRef ?? "").trim();
  if (txRef) {
    u.searchParams.set("tx_ref", txRef);
  }
  const transactionId = String(params.transaction_id ?? params.transactionId ?? "").trim();
  if (transactionId) {
    u.searchParams.set("transaction_id", transactionId);
  }
  const status = String(params.status ?? "").trim().toLowerCase();
  if (status) {
    u.searchParams.set("status", status);
  }
  const flow = String(params.flow ?? "").trim();
  if (flow) {
    u.searchParams.set("flow", flow);
  }
  const merchantId = String(params.merchantId ?? params.merchant_id ?? "").trim();
  if (merchantId) {
    u.searchParams.set("merchantId", merchantId);
  }
  return u.toString();
}

module.exports = {
  HOSTING_BASE,
  APP_DEEP_LINK,
  normAppContext,
  buildFlutterwaveRedirectUrl,
  buildAppDeepLinkFromReturnParams,
};
