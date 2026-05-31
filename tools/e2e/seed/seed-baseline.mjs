import { ACTORS, E2E_PROJECT_ID } from "../config/emulator.mjs";
import { auth, firestore, rtdb } from "../lib/admin.mjs";

const LAGOS_CENTER = { lat: 6.5244, lng: 3.3792 };

export async function seedBaseline() {
  const db = rtdb();
  const fs = firestore();
  const now = Date.now();

  await auth().createUser({
    uid: ACTORS.riderId,
    email: ACTORS.riderEmail,
    emailVerified: true,
    displayName: "E2E Rider",
  }).catch((err) => {
    if (String(err?.code ?? "") !== "auth/uid-already-exists") throw err;
  });

  await auth().createUser({
    uid: ACTORS.driverId,
    email: ACTORS.driverEmail,
    emailVerified: true,
    displayName: "E2E Driver",
  }).catch((err) => {
    if (String(err?.code ?? "") !== "auth/uid-already-exists") throw err;
  });

  await fs.collection("users").doc(ACTORS.riderId).set(
    {
      selfieUploaded: true,
      verificationStatus: "approved",
      displayName: "E2E Rider",
      email: ACTORS.riderEmail,
      updated_at: now,
    },
    { merge: true },
  );

  await fs.collection("delivery_regions").doc("lagos").set(
    {
      enabled: true,
      state: "Lagos",
      dispatch_market_id: "lagos",
      supports_package: true,
      supports_delivery: true,
      supports_rides: true,
      updated_at: now,
    },
    { merge: true },
  );

  await fs
    .collection("delivery_regions")
    .doc("lagos")
    .collection("cities")
    .doc("lagos_island")
    .set(
      {
        enabled: true,
        display_name: "Lagos Island E2E",
        city_name: "Lagos Island E2E",
        center_lat: LAGOS_CENTER.lat,
        center_lng: LAGOS_CENTER.lng,
        service_radius_km: 80,
        supports_package: true,
        supports_delivery: true,
        supports_rides: true,
        updated_at: now,
      },
      { merge: true },
    );

  await db.ref(`drivers/${ACTORS.driverId}`).set({
    uid: ACTORS.driverId,
    dispatch_market: "lagos",
    dispatch_market_id: "lagos",
    canonical_market_id: "lagos",
    active_services: ["dispatch_delivery", "dispatch_ride"],
    service_capabilities: { ride: true, delivery: true },
    vehicle_type: "car",
    dispatch_vehicle_type: "car",
    nexride_verified: true,
    isOnline: true,
    is_online: true,
    status: "available",
    dispatch_state: "available",
    last_active_at: now,
    last_seen_at: now,
    lat: LAGOS_CENTER.lat,
    lng: LAGOS_CENTER.lng,
    updated_at: now,
  });

  await db.ref(`online_drivers/${ACTORS.driverId}`).set({
    is_online: true,
    dispatch_market: "lagos",
    dispatch_market_id: "lagos",
    lat: LAGOS_CENTER.lat,
    lng: LAGOS_CENTER.lng,
    updated_at: now,
  });

  await db.ref(`users/${ACTORS.riderId}`).set({
    uid: ACTORS.riderId,
    role: "rider",
    email: ACTORS.riderEmail,
    displayName: "E2E Rider",
    created_at: now,
    provisioned_via: "e2e_seed",
  });

  await db.ref("e2e/meta").set({
    project_id: E2E_PROJECT_ID,
    seeded_at: now,
    rider_id: ACTORS.riderId,
    driver_id: ACTORS.driverId,
  });

  return { riderId: ACTORS.riderId, driverId: ACTORS.driverId, seededAt: now };
}
