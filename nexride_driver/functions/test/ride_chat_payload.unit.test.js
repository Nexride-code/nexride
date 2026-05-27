const assert = require("node:assert/strict");
const { test } = require("node:test");

test("ride chat canonical path convention", () => {
  const rideId = "-OtZSt97zv57tCJdN331";
  const messageId = "msg_1";
  const path = `ride_chats/${rideId}/messages/${messageId}`;
  assert.ok(path.startsWith("ride_chats/"));
  assert.ok(path.endsWith(`/messages/${messageId}`));
});

test("ride chat payload includes senderId for RTDB rules", () => {
  const payload = {
    id: "msg_1",
    message_id: "msg_1",
    ride_id: "-OtZSt97zv57tCJdN331",
    senderId: "rider_uid",
    sender_id: "rider_uid",
    senderRole: "rider",
    sender_role: "rider",
    text: "hello",
    status: "sent",
    client_message_id: "msg_1",
    timestamp: 1,
    created_at: 1,
  };
  assert.equal(payload.senderId, payload.sender_id);
  assert.equal(payload.senderRole, payload.sender_role);
  assert.equal(payload.status, "sent");
  assert.ok(payload.client_message_id.length > 0);
});
