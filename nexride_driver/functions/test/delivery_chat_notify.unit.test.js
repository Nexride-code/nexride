const assert = require("node:assert/strict");
const { test } = require("node:test");
const { notifyDeliveryChatMessage } = require("../delivery_chat_triggers");

function mockDb({ message = {}, delivery = {} } = {}) {
  const store = {
    delivery_chats: { del1: { messages: { m1: message } } },
    delivery_requests: { del1: delivery },
  };
  const ref = (path) => {
    const parts = String(path || "").split("/").filter(Boolean);
    return {
      get: async () => {
        let cur = store;
        for (const p of parts) {
          cur = cur?.[p];
        }
        return { exists: () => cur != null, val: () => cur };
      },
      child: (p) => ref(parts.concat(p).join("/")),
    };
  };
  return { ref: (p) => ref(p), _store: store };
}

test("notifyDeliveryChatMessage rejects non-sender", async () => {
  const db = mockDb({
    message: { sender_id: "drv1", sender_role: "driver", text: "hi" },
    delivery: { customer_id: "c1", matched_driver_id: "drv1" },
  });
  const res = await notifyDeliveryChatMessage(
    { deliveryId: "del1", messageId: "m1" },
    { auth: { uid: "c1" } },
    db,
  );
  assert.equal(res.success, false);
  assert.equal(res.reason, "forbidden");
});
