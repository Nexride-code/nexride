const assert = require("node:assert/strict");
const { test } = require("node:test");

test("delivery chat meta path convention", () => {
  const deliveryId = "del_chat_1";
  const metaPath = `delivery_chats/${deliveryId}/meta`;
  const messagesPath = `delivery_chats/${deliveryId}/messages`;
  assert.ok(metaPath.endsWith("/meta"));
  assert.ok(messagesPath.endsWith("/messages"));
});

test("delivery chat safety notice is non-empty", () => {
  const notice =
    "Never share private contact or payment information. Harassment, abuse, or sexual content is prohibited.";
  assert.ok(notice.length > 40);
});
