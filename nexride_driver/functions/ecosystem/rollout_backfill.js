/**
 * Admin migration: infer Firestore/RTDB rollout_* fields from legacy market/city hints.
 * Port Harcourt / Rivers → unsupported (no rollout write).
 */

const admin = require("firebase-admin");
const { FieldPath } = require("firebase-admin/firestore");
const { logger } = require("firebase-functions");
const { isNexRideAdmin } = require("../admin_auth");

function norm(s) {
  return String(s ?? "")
    .trim()
    .toLowerCase()
    .replace(/\s+/g, " ");
}

function haystackFromHints(h) {
  const parts = [];
  const add = (v) => {
    const t = norm(v);
    if (t) {
      parts.push(t);
    }
  };
  add(h.market);
  add(h.market_pool);
  add(h.dispatch_market);
  add(h.city);
  add(h.launch_market_city);
  add(h.area);
  add(h.zone);
  add(h.community);
  return parts.join(" | ");
}

/**
 * Pure inference for tests and callable.
 * @returns {{ status: 'mapped', region_id: string, city_id: string, dispatch_market_id: string }
 *   | { status: 'unsupported', reason: string }
 *   | { status: 'skipped', reason: string }}
 */
function inferRolloutFromLegacyHints(h) {
  const s = haystackFromHints(h);
  if (!s) {
    return { status: "skipped", reason: "no_legacy_signals" };
  }

  const compact = s.replace(/[^a-z0-9]+/gi, " ").replace(/\s+/g, " ").trim();

  if (
    /\brivers\b/.test(compact) ||
    /\bport\s*harcourt\b/.test(compact) ||
    /\bportharcourt\b/.test(compact) ||
    /\boyigbo\b/.test(compact) ||
    /\bgokana\b/.test(compact)
  ) {
    return { status: "unsupported", reason: "ph_rivers" };
  }

  const has = (...tokens) => tokens.some((t) => compact.includes(t));

  if (has("nnewi")) {
    return { status: "mapped", region_id: "anambra", city_id: "nnewi", dispatch_market_id: "anambra" };
  }
  if (has("onitsha", "nkpor", "fegge")) {
    return { status: "mapped", region_id: "anambra", city_id: "onitsha", dispatch_market_id: "anambra" };
  }
  if (has("awka", "amawbia", "aroma")) {
    return { status: "mapped", region_id: "anambra", city_id: "awka", dispatch_market_id: "anambra" };
  }
  if (has("anambra")) {
    return { status: "mapped", region_id: "anambra", city_id: "awka", dispatch_market_id: "anambra" };
  }

  if (has("warri", "effurun", "jakpa")) {
    return { status: "mapped", region_id: "delta", city_id: "warri", dispatch_market_id: "delta" };
  }
  if (has("asaba", "okpanam", "ibusa")) {
    return { status: "mapped", region_id: "delta", city_id: "asaba", dispatch_market_id: "delta" };
  }
  if (has("delta", "sapele", "ughelli")) {
    return { status: "mapped", region_id: "delta", city_id: "asaba", dispatch_market_id: "delta" };
  }

  if (has("benin", "edo state", "edo")) {
    return { status: "mapped", region_id: "edo", city_id: "benin_city", dispatch_market_id: "edo" };
  }

  if (has("owerri", "imo state", "imo")) {
    return { status: "mapped", region_id: "imo", city_id: "owerri", dispatch_market_id: "imo" };
  }

  if (has("gwarinpa")) {
    return { status: "mapped", region_id: "abuja", city_id: "gwarinpa", dispatch_market_id: "abuja_fct" };
  }
  if (has("maitama")) {
    return { status: "mapped", region_id: "abuja", city_id: "maitama", dispatch_market_id: "abuja_fct" };
  }
  if (has("asokoro")) {
    return { status: "mapped", region_id: "abuja", city_id: "asokoro", dispatch_market_id: "abuja_fct" };
  }
  if (has("wuse", "fct", "abuja", "federal capital", "abuja fct", "abuja_fct")) {
    return { status: "mapped", region_id: "abuja", city_id: "wuse", dispatch_market_id: "abuja_fct" };
  }

  if (has("lekki", "chevron", "ajah", "sangotedo")) {
    return { status: "mapped", region_id: "lagos", city_id: "lekki", dispatch_market_id: "lagos" };
  }
  if (has("victoria island", "vi ", " vi", "ahmadu bello")) {
    return { status: "mapped", region_id: "lagos", city_id: "victoria_island", dispatch_market_id: "lagos" };
  }
  if (has("ikoyi", "banana island")) {
    return { status: "mapped", region_id: "lagos", city_id: "ikoyi", dispatch_market_id: "lagos" };
  }
  if (has("yaba", "unilag", "akoka", "sabo")) {
    return { status: "mapped", region_id: "lagos", city_id: "yaba", dispatch_market_id: "lagos" };
  }
  if (has("surulere", "adeniran", "bode thomas")) {
    return { status: "mapped", region_id: "lagos", city_id: "surulere", dispatch_market_id: "lagos" };
  }
  if (has("ikeja", "alausa", "computer village", "maryland", "gbagada")) {
    return { status: "mapped", region_id: "lagos", city_id: "ikeja", dispatch_market_id: "lagos" };
  }
  if (has("lagos", "mushin", "ikorodu", "apapa")) {
    return { status: "mapped", region_id: "lagos", city_id: "ikeja", dispatch_market_id: "lagos" };
  }

  return { status: "skipped", reason: "unknown_or_ambiguous" };
}

function riderNeedsRollout(data) {
  const rr = norm(data?.rollout_region_id);
  return !rr;
}

function driverNeedsRollout(data) {
  const rr = norm(data?.rollout_region_id);
  return !rr;
}

async function readRtdbUserHints(db, uid) {
  try {
    const snap = await db.ref(`users/${uid}`).get();
    if (!snap.exists() || typeof snap.val() !== "object") {
      return {};
    }
    const u = snap.val();
    return {
      launch_market_city: u.launch_market_city ?? u.launchMarket ?? u.selectedCity,
      market: u.market ?? u.market_pool,
      city: u.city,
      area: u.area ?? u.zone ?? u.community,
      zone: u.zone,
      community: u.community,
    };
  } catch (_) {
    return {};
  }
}

/**
 * @param {any} data
 * @param {import("firebase-functions/v2/https").CallableRequest} context
 * @param {import("firebase-admin/database").Database} db
 * @param {{ getFirestore?: () => import("firebase-admin/firestore").Firestore; isNexRideAdmin?: typeof isNexRideAdmin }} [options]
 */
async function adminBackfillUserRolloutRegions(data, context, db, options = {}) {
  const assertAdmin = options.isNexRideAdmin ?? isNexRideAdmin;
  if (!(await assertAdmin(db, context))) {
    return { success: false, reason: "unauthorized" };
  }

  const dryRun = data?.dryRun !== false && data?.dry_run !== false;
  const maxRiders = Math.min(Number(data?.maxRiderBatch ?? data?.max_rider_batch ?? 80), 500);
  const maxDrivers = Math.min(Number(data?.maxDriverBatch ?? data?.max_driver_batch ?? 80), 500);
  const fsStart = String(data?.firestoreStartAfter ?? data?.firestore_start_after ?? "").trim();
  const drvStart = String(data?.driversStartAfter ?? data?.drivers_start_after ?? "").trim();

  const fs = (options.getFirestore ?? (() => admin.firestore()))();
  const counts = {
    scanned_riders: 0,
    scanned_drivers: 0,
    mapped_riders: 0,
    mapped_drivers: 0,
    skipped_riders: 0,
    skipped_drivers: 0,
    unsupported_riders: 0,
    unsupported_drivers: 0,
    errors: 0,
  };
  /** @type {string[]} */
  const sample_skipped = [];
  /** @type {string[]} */
  const sample_mapped = [];

  let nextFs = null;
  let nextDrv = null;
  let ridersHasMore = false;
  let driversHasMore = false;

  try {
    let q = fs.collection("users").orderBy(FieldPath.documentId()).limit(maxRiders);
    if (fsStart) {
      q = q.startAfter(fsStart);
    }
    const userSnap = await q.get();
    ridersHasMore = !userSnap.empty && userSnap.size >= maxRiders;
    const lastUserDoc = userSnap.docs[userSnap.docs.length - 1];
    nextFs = lastUserDoc ? lastUserDoc.id : null;

    for (const doc of userSnap.docs) {
      counts.scanned_riders += 1;
      const uid = doc.id;
      const d = doc.data() || {};
      if (!riderNeedsRollout(d)) {
        counts.skipped_riders += 1;
        continue;
      }
      const rtdbHints = await readRtdbUserHints(db, uid);
      const infer = inferRolloutFromLegacyHints({
        market: d.market ?? d.dispatch_market ?? d.market_pool,
        market_pool: d.market_pool,
        dispatch_market: d.dispatch_market ?? d.rollout_dispatch_market_id,
        city: d.city,
        launch_market_city: d.launch_market_city ?? d.launch_market,
        area: d.area ?? d.service_area?.area,
        zone: d.zone,
        community: d.community,
        ...rtdbHints,
      });

      if (infer.status === "unsupported") {
        counts.unsupported_riders += 1;
        if (sample_skipped.length < 8) {
          sample_skipped.push(`${uid}:unsupported:${infer.reason}`);
        }
        continue;
      }
      if (infer.status === "skipped") {
        counts.skipped_riders += 1;
        if (sample_skipped.length < 12) {
          sample_skipped.push(`${uid}:skipped:${infer.reason}`);
        }
        continue;
      }

      counts.mapped_riders += 1;
      if (sample_mapped.length < 6) {
        sample_mapped.push(`${uid}→${infer.region_id}/${infer.city_id}`);
      }

      if (!dryRun) {
        await doc.ref.set(
          {
            rollout_region_id: infer.region_id,
            rollout_city_id: infer.city_id,
            rollout_dispatch_market_id: infer.dispatch_market_id,
          },
          { merge: true },
        );
        try {
          await db.ref(`users/${uid}`).update({
            launch_market_city: infer.dispatch_market_id,
            launch_market_updated_at: admin.database.ServerValue.TIMESTAMP,
            updated_at: admin.database.ServerValue.TIMESTAMP,
          });
        } catch (e) {
          logger.warn("backfill_rider_rtdb_mirror_failed", { uid, err: String(e?.message || e) });
        }
      }
    }
  } catch (e) {
    counts.errors += 1;
    logger.error("backfill_riders_fail", { err: String(e?.message || e) });
  }

  try {
    let ref = db.ref("drivers").orderByKey();
    if (drvStart) {
      ref = ref.startAfter(drvStart);
    }
    ref = ref.limitToFirst(maxDrivers);
    const drvSnap = await ref.get();
    if (drvSnap.exists() && typeof drvSnap.val() === "object") {
      const entries = Object.entries(drvSnap.val());
      for (const [did, raw] of entries) {
        if (!raw || typeof raw !== "object") {
          continue;
        }
        counts.scanned_drivers += 1;
        const v = /** @type {Record<string, unknown>} */ (raw);
        if (!driverNeedsRollout(v)) {
          counts.skipped_drivers += 1;
          continue;
        }
        const infer = inferRolloutFromLegacyHints({
          market: v.market ?? v.market_pool,
          market_pool: v.market_pool,
          dispatch_market: v.dispatch_market,
          city: v.city,
          launch_market_city: v.launch_market_city,
          area: v.area ?? v.zone ?? v.community,
          zone: v.zone,
          community: v.community,
        });

        if (infer.status === "unsupported") {
          counts.unsupported_drivers += 1;
          if (sample_skipped.length < 14) {
            sample_skipped.push(`driver:${did}:unsupported:${infer.reason}`);
          }
          continue;
        }
        if (infer.status === "skipped") {
          counts.skipped_drivers += 1;
          if (sample_skipped.length < 16) {
            sample_skipped.push(`driver:${did}:skipped:${infer.reason}`);
          }
          continue;
        }

        counts.mapped_drivers += 1;
        if (sample_mapped.length < 10) {
          sample_mapped.push(`driver:${did}→${infer.region_id}/${infer.city_id}`);
        }

        if (!dryRun) {
          const dm = infer.dispatch_market_id;
          await db.ref(`drivers/${did}`).update({
            rollout_region_id: infer.region_id,
            rollout_city_id: infer.city_id,
            rollout_dispatch_market_id: dm,
            market: dm,
            market_pool: dm,
            dispatch_market: dm,
            city: dm,
            launch_market_city: dm,
            launch_market_updated_at: admin.database.ServerValue.TIMESTAMP,
            updated_at: admin.database.ServerValue.TIMESTAMP,
          });
        }
      }
      nextDrv = entries.length ? entries[entries.length - 1][0] : null;
      driversHasMore = entries.length >= maxDrivers;
    }
  } catch (e) {
    counts.errors += 1;
    logger.error("backfill_drivers_fail", { err: String(e?.message || e) });
  }

  logger.info("BACKFILL_USER_ROLLOUT", { dryRun, ...counts });

  const scanned = counts.scanned_riders + counts.scanned_drivers;
  const mapped = counts.mapped_riders + counts.mapped_drivers;
  const skipped = counts.skipped_riders + counts.skipped_drivers;
  const unsupported = counts.unsupported_riders + counts.unsupported_drivers;

  return {
    success: true,
    dry_run: dryRun,
    scanned,
    mapped,
    skipped,
    unsupported,
    ...counts,
    sample_skipped,
    sample_mapped,
    next_firestore_cursor: nextFs,
    next_drivers_cursor: nextDrv,
    riders_has_more: ridersHasMore,
    drivers_has_more: driversHasMore,
  };
}

module.exports = {
  inferRolloutFromLegacyHints,
  adminBackfillUserRolloutRegions,
};
