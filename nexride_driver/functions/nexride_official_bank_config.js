/**
 * NexRide corporate bank account for manual transfers (merchants, riders, subscriptions, etc.).
 *
 * Source of truth (RTDB): prefer `app_config/nexride_official_bank_account` so operators configure
 * one object for all server-side flows. Legacy paths are tried for backward compatibility.
 *
 * Clients should use the authenticated callable `getNexrideOfficialBankAccount` (or fields
 * returned from server flows such as `registerBankTransferPayment`) — never embed account numbers
 * in app source.
 */

const { logger } = require("firebase-functions");

/** Highest priority first. */
const OFFICIAL_BANK_RTDB_PATHS = [
  "app_config/nexride_official_bank_account",
  "app_config/official_bank_account",
  "app_config/merchant_official_bank",
];

function trimStr(v, max = 500) {
  return String(v ?? "")
    .trim()
    .slice(0, max);
}

/**
 * @param {unknown} raw
 * @returns {{ bank_name: string; account_name: string; account_number: string } | null}
 */
function parseOfficialBankObject(raw) {
  if (!raw || typeof raw !== "object") {
    return null;
  }
  /** @type {Record<string, unknown>} */
  let v = /** @type {Record<string, unknown>} */ (raw);
  const nested =
    v.official_bank && typeof v.official_bank === "object"
      ? v.official_bank
      : v.bank && typeof v.bank === "object"
        ? v.bank
        : null;
  if (nested && typeof nested === "object") {
    v = /** @type {Record<string, unknown>} */ (nested);
  }
  const bankName = trimStr(v.bank_name ?? v.bankName ?? v.bank ?? "", 120);
  const accountName = trimStr(v.account_name ?? v.accountName ?? "", 200);
  const accountNumber = trimStr(v.account_number ?? v.accountNumber ?? "", 32);
  if (!bankName || !accountName || !accountNumber) {
    return null;
  }
  return { bank_name: bankName, account_name: accountName, account_number: accountNumber };
}

/**
 * @param {import("firebase-admin/database").Database} db
 * @returns {Promise<{ bank_name: string; account_name: string; account_number: string; source_path: string } | null>}
 */
async function loadNexrideOfficialBankAccountFromRtdb(db) {
  for (const path of OFFICIAL_BANK_RTDB_PATHS) {
    try {
      const snap = await db.ref(path).get();
      const parsed = parseOfficialBankObject(snap.val());
      if (parsed) {
        logger.info("OFFICIAL_BANK_CONFIG_LOADED", { source_path: path });
        return { ...parsed, source_path: path };
      }
    } catch (e) {
      logger.warn("OFFICIAL_BANK_CONFIG_PATH_FAIL", { path, err: String(e?.message || e) });
    }
  }
  return null;
}

/**
 * Any signed-in user (rider, driver, merchant). Returns only public bank transfer fields.
 * @param {object} _data
 * @param {import("firebase-functions").https.CallableContext} context
 * @param {import("firebase-admin/database").Database} db
 */
async function getNexrideOfficialBankAccount(_data, context, db) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const row = await loadNexrideOfficialBankAccountFromRtdb(db);
  if (!row) {
    logger.error("OFFICIAL_BANK_NOT_CONFIGURED", {
      flow: "getNexrideOfficialBankAccount",
      uid: context.auth?.uid || null,
    });
    return { success: false, reason: "official_bank_not_configured" };
  }
  return {
    success: true,
    bank_name: row.bank_name,
    account_name: row.account_name,
    account_number: row.account_number,
  };
}

module.exports = {
  OFFICIAL_BANK_RTDB_PATHS,
  parseOfficialBankObject,
  loadNexrideOfficialBankAccountFromRtdb,
  getNexrideOfficialBankAccount,
};
