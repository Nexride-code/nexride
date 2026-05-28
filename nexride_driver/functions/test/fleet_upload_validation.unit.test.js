const assert = require("node:assert/strict");
const { test } = require("node:test");

const fleetVerification = require("../fleet_verification");
const fleet = require("../business_fleet_callables");

const { validateFleetUploadFile, FLEET_UPLOAD_MAX_BYTES } = fleetVerification;

test("validateFleetUploadFile accepts jpeg, png, and pdf within limit", () => {
  const cases = [
    { contentType: "image/jpeg", fileName: "photo.jpg" },
    { contentType: "image/png", fileName: "photo.png" },
    { contentType: "application/pdf", fileName: "doc.pdf" },
  ];
  for (const { contentType, fileName } of cases) {
    const res = validateFleetUploadFile({
      contentType,
      sizeBytes: 1024,
      fileName,
    });
    assert.equal(res.ok, true, contentType);
  }
});

test("validateFleetUploadFile rejects unknown and executable mime types", () => {
  for (const contentType of [
    "application/octet-stream",
    "application/x-msdownload",
    "image/gif",
    "image/webp",
    "text/html",
  ]) {
    const res = validateFleetUploadFile({
      contentType,
      sizeBytes: 100,
      fileName: "file.bin",
    });
    assert.equal(res.ok, false);
    assert.equal(res.reason, "invalid_file_type");
  }
});

test("validateFleetUploadFile rejects blocked extensions", () => {
  const res = validateFleetUploadFile({
    contentType: "image/jpeg",
    sizeBytes: 100,
    fileName: "malware.exe",
  });
  assert.equal(res.ok, false);
  assert.equal(res.reason, "invalid_file_type");
});

test("validateFleetUploadFile rejects extension mismatch with mime", () => {
  const res = validateFleetUploadFile({
    contentType: "image/jpeg",
    sizeBytes: 100,
    fileName: "photo.png",
  });
  assert.equal(res.ok, false);
  assert.equal(res.reason, "invalid_file_type");
});

test("validateFleetUploadFile rejects oversize files", () => {
  const res = validateFleetUploadFile({
    contentType: "image/jpeg",
    sizeBytes: FLEET_UPLOAD_MAX_BYTES + 1,
    fileName: "large.jpg",
  });
  assert.equal(res.ok, false);
  assert.equal(res.reason, "file_too_large");
});

test("validateFleetUploadFile rejects zero-byte files", () => {
  const res = validateFleetUploadFile({
    contentType: "image/png",
    sizeBytes: 0,
    fileName: "empty.png",
  });
  assert.equal(res.ok, false);
  assert.equal(res.reason, "file_too_large");
});

test("validateFleetUploadFile rejects storage metadata type mismatch", () => {
  const res = validateFleetUploadFile({
    contentType: "image/jpeg",
    storageContentType: "application/x-msdownload",
    sizeBytes: 500,
    fileName: "scan.jpg",
  });
  assert.equal(res.ok, false);
  assert.equal(res.reason, "invalid_file_type");
});

function createMockDb(initial = {}) {
  const store = { ...initial };

  function buildObjectForPath(path) {
    const out = {};
    const prefix = `${path}/`;
    for (const [k, v] of Object.entries(store)) {
      if (!k.startsWith(prefix)) {
        continue;
      }
      const rest = k.slice(prefix.length);
      const parts = rest.split("/").filter(Boolean);
      let cur = out;
      for (let i = 0; i < parts.length; i += 1) {
        const part = parts[i];
        if (i === parts.length - 1) {
          cur[part] = v;
        } else {
          if (!cur[part] || typeof cur[part] !== "object") {
            cur[part] = {};
          }
          cur = cur[part];
        }
      }
    }
    return Object.keys(out).length ? out : null;
  }

  function ref(path = "") {
    const p = String(path || "");
    return {
      async get() {
        let val = Object.prototype.hasOwnProperty.call(store, p) ? store[p] : undefined;
        if (val === undefined) {
          val = buildObjectForPath(p);
        }
        return {
          exists: () => val !== undefined && val !== null,
          val: () => (val === undefined ? null : val),
        };
      },
      async set(v) {
        store[p] = v;
      },
      async update(v) {
        const cur = (await this.get()).val();
        if (cur && typeof cur === "object" && v && typeof v === "object") {
          store[p] = { ...cur, ...v };
        } else {
          store[p] = v;
        }
      },
      push() {
        return {
          async set(v) {
            store[`push_${Object.keys(store).length}`] = v;
          },
        };
      },
    };
  }
  return { ref, _store: store };
}

function seedFleetAccount(db, merchants, ownerUid, businessId, merchantRow) {
  db._store[`dispatch_fleet_owner_index/${ownerUid}/${businessId}`] = {
    business_id: businessId,
    account_kind: "dispatch_fleet",
    status: merchantRow.merchant_status ?? "pending_documents",
    created_at: Date.now(),
  };
  merchants[businessId] = {
    owner_uid: ownerUid,
    account_kind: "dispatch_fleet",
    verification_type: "cac_business",
    ...merchantRow,
  };
}

test("fleetUploadVerificationDocument rejects invalid_file_type before storage read", async () => {
  const db = createMockDb();
  const merchants = {};
  seedFleetAccount(db, merchants, "owner_1", "biz_up", {
    merchant_status: "pending_documents",
  });
  let seq = 0;
  const fs = {
    collection(name) {
      if (name !== "merchants") {
        throw new Error(`unexpected: ${name}`);
      }
      return {
        doc(id) {
          const docId = id || `m_${++seq}`;
          return {
            id: docId,
            async get() {
              const data = merchants[docId];
              return { exists: data != null, id: docId, data: () => data };
            },
          };
        },
      };
    },
  };
  fleet.setFirestoreForTests(fs);
  try {
    const res = await fleet.fleetUploadVerificationDocument(
      {
        document_type: "cac_document",
        content_type: "application/x-msdownload",
        storage_path: "fleet_verification_uploads/biz_up/cac_document/evil.exe",
        file_name: "evil.exe",
      },
      { auth: { uid: "owner_1" } },
      db,
    );
    assert.equal(res.success, false);
    assert.equal(res.reason, "invalid_file_type");
  } finally {
    fleet.setFirestoreForTests(null);
  }
});

test("fleetUploadVerificationDocument rejects file_too_large from declared size in validation path", async () => {
  const res = validateFleetUploadFile({
    contentType: "application/pdf",
    sizeBytes: FLEET_UPLOAD_MAX_BYTES + 42,
    fileName: "big.pdf",
  });
  assert.equal(res.reason, "file_too_large");
});
