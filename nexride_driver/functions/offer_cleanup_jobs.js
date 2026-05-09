/**
 * Hourly backup sweep for stale `driver_offer_queue` rows.
 * Primary sweeps already run every 5 minutes via [sweepDispatchHealth];
 * this job reuses the same logic for redundancy and log correlation
 * (`CLEAN_EXPIRED_OFFERS`).
 */
const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");
const { logger } = require("firebase-functions");
const { REGION } = require("./params");
const { sweepStaleDriverOfferQueue } = require("./dispatch_maintenance_jobs");

exports.cleanExpiredDriverOffers = onSchedule(
  {
    schedule: "every 60 minutes",
    timeZone: "Africa/Lagos",
    region: REGION,
  },
  async (_event) => {
    const db = admin.database();
    try {
      await sweepStaleDriverOfferQueue(db);
      logger.info("CLEAN_EXPIRED_OFFERS", { ok: true });
    } catch (e) {
      logger.error("CLEAN_EXPIRED_OFFERS_FAIL", {
        error: String(e?.message || e),
      });
    }
  },
);
