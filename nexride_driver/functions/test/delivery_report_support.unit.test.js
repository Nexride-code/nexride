const assert = require("node:assert/strict");
const { test } = require("node:test");
const { createDeliverySupportTicket } = require("../delivery_callables");

function mockDb({ deliveryRow = {}, ticketExists = false } = {}) {
  const store = {
    delivery_requests: { del1: deliveryRow },
    support_tickets: {},
    support_reports: { deliveries: { del1: { rep1: { status: "pending" } } } },
  };
  const ref = (path) => {
    const parts = String(path || "").split("/").filter(Boolean);
    const api = {
      get: async () => {
        let cur = store;
        for (const p of parts) {
          cur = cur?.[p];
        }
        return {
          exists: () => cur != null && typeof cur === "object",
          val: () => cur,
        };
      },
      set: async (v) => {
        let cur = store;
        for (let i = 0; i < parts.length - 1; i++) {
          const p = parts[i];
          cur[p] = cur[p] || {};
          cur = cur[p];
        }
        cur[parts[parts.length - 1]] = v;
      },
      update: async (patch) => {
        let cur = store;
        for (let i = 0; i < parts.length - 1; i++) {
          const p = parts[i];
          cur[p] = cur[p] || {};
          cur = cur[p];
        }
        Object.assign(cur, patch);
      },
      child: (p) => ref(parts.concat(p).join("/")),
    };
    return api;
  };
  return {
    ref: (path) => ref(path),
    _store: store,
  };
}

test("createDeliverySupportTicket writes support ticket with delivery context", async () => {
  const db = mockDb({
    deliveryRow: {
      customer_id: "cust1",
      matched_driver_id: "drv1",
      merchant_id: "mer1",
      delivery_state: "driver_assigned",
      payment_status: "paid",
    },
  });
  const res = await createDeliverySupportTicket(
    {
      deliveryId: "del1",
      reportId: "rep1",
      reason: "late",
      message: "Driver very late",
      reporterRole: "customer",
    },
    { auth: { uid: "cust1" } },
    db,
  );
  assert.equal(res.success, true);
  assert.ok(res.ticketId);
  const ticket = db._store.support_tickets[res.ticketId];
  assert.equal(ticket.delivery_id, "del1");
  assert.equal(ticket.driver_id, "drv1");
  assert.equal(ticket.merchant_id, "mer1");
});
