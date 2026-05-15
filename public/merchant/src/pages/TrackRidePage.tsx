import { useEffect, useMemo, useState } from "react";
import { useParams } from "react-router-dom";
import {
  fetchRideTrackSummary,
  initNexRideWeb,
  onValue,
  ref,
  type RideTrackSummary,
} from "../lib/firebaseClient";

/**
 * URL param `token` is the **track token** from `createRideRequest`,
 * not the internal Firebase ride push id. Share: `/track/{trackToken}`.
 */
export function TrackRidePage() {
  const { token: tokenParam } = useParams();
  const token = useMemo(() => String(tokenParam ?? "").trim(), [tokenParam]);

  const [summary, setSummary] = useState<RideTrackSummary | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [configError, setConfigError] = useState(false);

  useEffect(() => {
    if (!token || token.length < 6) {
      setError("Invalid tracking link.");
      setSummary(null);
      return;
    }

    const fb = initNexRideWeb();
    if (!fb) {
      setConfigError(true);
      setError(null);
      void fetchRideTrackSummary(token).then((s) => {
        if (s) setSummary(s);
        else setError("Could not load trip. Check Firebase env (VITE_*) or try again later.");
      });
      return;
    }

    setConfigError(false);
    const r = ref(fb.database, `ride_track_public/${token}`);
    const unsub = onValue(
      r,
      (snap) => {
        const v = snap.val();
        if (!v || typeof v !== "object") {
          setSummary(null);
          setError("Trip not found or link expired.");
          return;
        }
        setError(null);
        setSummary({
          trip_status: String(v.trip_status ?? ""),
          trip_phase: String(v.trip_phase ?? ""),
          pickup_area: String(v.pickup_area ?? ""),
          dropoff_area: String(v.dropoff_area ?? ""),
          eta_min: Number(v.eta_min ?? 0) || 0,
          vehicle_label: String(v.vehicle_label ?? ""),
          driver_first_name:
            v.driver_first_name === null || v.driver_first_name === undefined
              ? null
              : String(v.driver_first_name),
          updated_at: Number(v.updated_at ?? 0) || 0,
        });
      },
      () => {
        setError("Could not connect to live updates.");
      },
    );
    return () => unsub();
  }, [token]);

  if (!token) {
    return (
      <section>
        <h1>Track ride</h1>
        <p>Missing tracking token in URL.</p>
      </section>
    );
  }

  return (
    <section>
      <h1>Track ride</h1>
      <p style={{ color: "#666", fontSize: 14 }}>
        Live status for your trip. We never show phone numbers or email on this page.
      </p>
      {configError && (
        <p style={{ color: "#a60", fontSize: 14 }}>
          Tip: set <code>VITE_FIREBASE_*</code> in <code>web/.env</code> for realtime updates; callable fallback is
          used when RTDB is not configured.
        </p>
      )}
      {error && (
        <p role="alert" style={{ color: "#b00020" }}>
          {error}
        </p>
      )}
      {summary && (
        <dl
          style={{
            display: "grid",
            gridTemplateColumns: "140px 1fr",
            rowGap: 10,
            columnGap: 12,
            marginTop: 20,
          }}
        >
          <dt style={{ fontWeight: 600 }}>Status</dt>
          <dd style={{ margin: 0 }}>{summary.trip_status || "—"}</dd>
          <dt style={{ fontWeight: 600 }}>Pickup area</dt>
          <dd style={{ margin: 0 }}>{summary.pickup_area || "—"}</dd>
          <dt style={{ fontWeight: 600 }}>Drop-off area</dt>
          <dd style={{ margin: 0 }}>{summary.dropoff_area || "—"}</dd>
          <dt style={{ fontWeight: 600 }}>ETA</dt>
          <dd style={{ margin: 0 }}>{summary.eta_min > 0 ? `${summary.eta_min} min` : "—"}</dd>
          <dt style={{ fontWeight: 600 }}>Driver</dt>
          <dd style={{ margin: 0 }}>{summary.driver_first_name ? summary.driver_first_name : "—"}</dd>
          <dt style={{ fontWeight: 600 }}>Vehicle</dt>
          <dd style={{ margin: 0 }}>{summary.vehicle_label?.trim() ? summary.vehicle_label : "—"}</dd>
        </dl>
      )}
    </section>
  );
}
