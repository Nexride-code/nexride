import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

/** NexRide E2E emulator constants — local only. */
export const E2E_PROJECT_ID = "nexride-e2e-local";

export const EMULATOR = {
  authHost: "127.0.0.1",
  authPort: 9098,
  rtdbHost: "127.0.0.1",
  rtdbPort: 9001,
  firestoreHost: "127.0.0.1",
  firestorePort: 8081,
  functionsHost: "127.0.0.1",
  functionsPort: 5002,
  functionsRegion: "us-central1",
  flutterwaveStubHost: "127.0.0.1",
  flutterwaveStubPort: 9199,
};

export {
  E2E_RTDB_CANONICAL_INSTANCE,
  E2E_RTDB_DEFAULT_INSTANCE,
  E2E_RTDB_LEGACY_INSTANCE,
  resolveE2eRtdbDatabaseUrl,
} from "../lib/rtdb-namespace.mjs";

export const E2E_RTDB_INSTANCES = {
  canonical: E2E_PROJECT_ID,
  alternate: `${E2E_PROJECT_ID}-default-rtdb`,
};

export const ACTORS = {
  riderId: "e2e_rider_1",
  riderEmail: "e2e-rider@nexride.local",
  driverId: "e2e_driver_1",
  driverEmail: "e2e-driver@nexride.local",
};

export const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), "../../..");
