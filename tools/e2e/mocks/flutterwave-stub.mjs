import http from "node:http";
import { EMULATOR } from "../config/emulator.mjs";

export const FLUTTERWAVE_STUB_BASE = `http://${EMULATOR.flutterwaveStubHost}:${EMULATOR.flutterwaveStubPort}`;

function parseTxRef(url) {
  const match = String(url.pathname || "").match(/\/v3\/transactions\/(\d+)\/verify$/);
  if (match) {
    return { txRef: null, numericId: match[1] };
  }
  return { txRef: url.searchParams.get("tx_ref"), numericId: null };
}

function successPayload({ txRef, numericId, amount = 5030 }) {
  const ref = String(txRef || `e2e_flw_${numericId || Date.now()}`).trim();
  const amt = Number(amount);
  const resolvedAmount = Number.isFinite(amt) && amt > 0 ? amt : 5030;
  return {
    status: "success",
    message: "Transaction verified",
    data: {
      id: numericId || "999888777",
      tx_ref: ref,
      flw_ref: `FLW-e2e-${ref}`,
      status: "successful",
      currency: "NGN",
      amount: resolvedAmount,
      charged_amount: resolvedAmount,
      app_fee: 0,
      merchant_fee: 0,
      processor_response: "Approved",
      payment_type: "card",
    },
  };
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => {
      try {
        const raw = Buffer.concat(chunks).toString("utf8").trim();
        resolve(raw ? JSON.parse(raw) : {});
      } catch (err) {
        reject(err);
      }
    });
    req.on("error", reject);
  });
}

export function startFlutterwaveStub() {
  /** @type {Map<string, number>} */
  const amountByTxRef = new Map();

  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url || "/", FLUTTERWAVE_STUB_BASE);

    if (req.method === "POST" && url.pathname === "/v3/payments") {
      try {
        const body = await readJsonBody(req);
        const txRef = String(body?.tx_ref ?? "").trim();
        const amount = Number(body?.amount ?? 5030);
        if (txRef) {
          amountByTxRef.set(txRef, amount);
        }
        const link = `${FLUTTERWAVE_STUB_BASE}/e2e-checkout${txRef ? `?tx_ref=${encodeURIComponent(txRef)}` : ""}`;
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(
          JSON.stringify({
            status: "success",
            message: "Hosted link",
            data: { link },
          }),
        );
      } catch (err) {
        res.writeHead(400, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ status: "error", message: String(err?.message || err) }));
      }
      return;
    }

    if (req.method !== "GET") {
      res.writeHead(405, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ status: "error", message: "method_not_allowed" }));
      return;
    }

    const { txRef, numericId } = parseTxRef(url);
    const amount = txRef ? amountByTxRef.get(txRef) : undefined;
    const body = successPayload({ txRef, numericId, amount });

    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify(body));
  });

  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(EMULATOR.flutterwaveStubPort, EMULATOR.flutterwaveStubHost, () => {
      resolve(server);
    });
  });
}

const isMain = import.meta.url === `file://${process.argv[1]}`;
if (isMain) {
  startFlutterwaveStub()
    .then((server) => {
      console.log("E2E_FLUTTERWAVE_STUB_LISTENING", FLUTTERWAVE_STUB_BASE);
      process.on("SIGINT", () => server.close(() => process.exit(0)));
      process.on("SIGTERM", () => server.close(() => process.exit(0)));
    })
    .catch((err) => {
      console.error("E2E_FLUTTERWAVE_STUB_FAIL", err?.message || err);
      process.exit(1);
    });
}
