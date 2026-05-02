import { initializeApp, getApps, type FirebaseApp } from "firebase/app";
import { getAuth, type Auth } from "firebase/auth";
import { getDatabase, ref, onValue, type Database } from "firebase/database";
import { getFunctions, httpsCallable, type Functions } from "firebase/functions";

const REGION = "us-central1";

function readConfig() {
  const apiKey = import.meta.env.VITE_FIREBASE_API_KEY?.trim();
  const databaseURL = import.meta.env.VITE_FIREBASE_DATABASE_URL?.trim();
  const projectId = import.meta.env.VITE_FIREBASE_PROJECT_ID?.trim();
  const authDomain =
    import.meta.env.VITE_FIREBASE_AUTH_DOMAIN?.trim() ||
    (projectId ? `${projectId}.firebaseapp.com` : "");
  if (!apiKey || !databaseURL || !projectId) return null;
  return { apiKey, authDomain, databaseURL, projectId };
}

let app: FirebaseApp | null = null;
let db: Database | null = null;
let auth: Auth | null = null;
let functions: Functions | null = null;

export function initNexRideWeb(): {
  app: FirebaseApp;
  database: Database;
  auth: Auth;
  functions: Functions;
} | null {
  const cfg = readConfig();
  if (!cfg) return null;
  if (!app) {
    app = getApps().length ? getApps()[0]! : initializeApp(cfg);
    db = getDatabase(app);
    auth = getAuth(app);
    functions = getFunctions(app, REGION);
  }
  return { app, database: db!, auth: auth!, functions: functions! };
}

export type RideTrackSummary = {
  trip_status: string;
  trip_phase: string;
  pickup_area: string;
  dropoff_area: string;
  eta_min: number;
  vehicle_label: string;
  driver_first_name: string | null;
  updated_at: number;
};

export async function fetchRideTrackSummary(token: string): Promise<RideTrackSummary | null> {
  const fb = initNexRideWeb();
  if (!fb) return null;
  try {
    const fn = httpsCallable(fb.functions, "getRideTrackSummary");
    const res = await fn({ token: token.trim() });
    const data = res.data as {
      success?: boolean;
      summary?: RideTrackSummary;
    };
    if (!data?.success || !data.summary) return null;
    return data.summary;
  } catch {
    return null;
  }
}

export { ref, onValue, get } from "firebase/database";
