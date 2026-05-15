/**
 * Firestore-backed rider identity checks (selfie approval gate for booking).
 * Booking unlocks ONLY when selfieUploaded && verificationStatus == "approved" (Admin SDK elsewhere).
 */

const admin = require("firebase-admin");
const { FieldValue } = require("firebase-admin/firestore");

function normUid(uid) {
  return String(uid ?? "").trim();
}

function normStatus(s) {
  return String(s ?? "").trim().toLowerCase();
}

/**
 * @param {FirebaseFirestore.Firestore} firestore
 * @param {string} riderId
 * @returns {Promise<{ok: boolean, reason: string}>}
 */
async function evaluateRiderFirestoreIdentityForBooking(firestore, riderId) {
  const id = normUid(riderId);
  if (!id) {
    return { ok: false, reason: "identity_selfie_missing" };
  }

  let snap;
  try {
    snap = await firestore.collection("users").doc(id).get();
  } catch (err) {
    console.warn("evaluateRiderFirestoreIdentityForBooking read failed", id, String(err?.message || err));
    return { ok: false, reason: "identity_gate_unavailable" };
  }

  if (!snap.exists) {
    return { ok: false, reason: "identity_selfie_missing" };
  }

  const data = snap.data() || {};
  const selfieOk =
    data.selfieUploaded === true || normStatus(data.selfieUploaded) === "true";
  if (!selfieOk) {
    return { ok: false, reason: "identity_selfie_missing" };
  }

  const st = normStatus(data.verificationStatus);
  if (st === "approved") {
    return { ok: true, reason: "ok" };
  }
  if (st === "rejected") {
    return { ok: false, reason: "identity_rejected" };
  }
  return { ok: false, reason: "identity_pending_review" };
}

/**
 * Rider callable — sets queue status after selfie upload (no client-controlled approval).
 */
async function riderNotifySelfieSubmittedForReview(_data, context) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const uid = normUid(context.auth.uid);
  if (!uid) {
    return { success: false, reason: "unauthorized" };
  }

  const firestore = admin.firestore();

  let snap;
  try {
    snap = await firestore.collection("users").doc(uid).get();
  } catch (err) {
    console.warn("riderNotifySelfieSubmittedForReview read failed", uid, String(err?.message || err));
    return { success: false, reason: "firestore_error" };
  }

  const data = snap.exists ? snap.data() || {} : {};
  const selfieOk =
    data.selfieUploaded === true || normStatus(data.selfieUploaded) === "true";
  if (!selfieOk) {
    return { success: false, reason: "identity_selfie_missing" };
  }

  const cur = normStatus(data.verificationStatus);
  if (cur === "approved") {
    return { success: true, skipped: true };
  }

  // Verify selfie exists — check identity_verifications Firestore doc first for the
  // actual storage path (rider_verification_uploads/), then fall back to legacy path.
  try {
    const ivSnap = await firestore.collection("identity_verifications").doc(uid).get();
    const storagePath = ivSnap.exists ? String(ivSnap.data()?.selfie_storage_path ?? "").trim() : "";
    const bucket = admin.storage().bucket();
    if (storagePath) {
      const [exists] = await bucket.file(storagePath).exists();
      if (!exists) {
        return { success: false, reason: "selfie_file_missing" };
      }
    } else {
      // Legacy fallback path
      const legacyRef = bucket.file(`user_verification/${uid}/selfie.jpg`);
      const [legacyExists] = await legacyRef.exists();
      if (!legacyExists) {
        return { success: false, reason: "selfie_file_missing" };
      }
    }
  } catch (checkErr) {
    console.warn("riderNotifySelfieSubmittedForReview selfie exists check skipped", uid, String(checkErr?.message || checkErr));
    // Don't fail hard — let the admin review queue the selfie anyway.
  }

  try {
    await firestore.collection("users").doc(uid).set(
      {
        verificationStatus: "pending_review",
        selfieReviewQueuedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
  } catch (writeErr) {
    console.warn("riderNotifySelfieSubmittedForReview write failed", uid, String(writeErr?.message || writeErr));
    return { success: false, reason: "firestore_write_failed" };
  }

  return { success: true };
}

module.exports = {
  evaluateRiderFirestoreIdentityForBooking,
  riderNotifySelfieSubmittedForReview,
};
