import { useCallback, useEffect, useState } from "react";
import { httpsCallable } from "firebase/functions";
import { initNexRideWeb } from "../../lib/firebaseClient";

type CityRow = {
  city_id?: string;
  display_name?: string;
  enabled?: boolean;
  supports_rides?: boolean;
  supports_food?: boolean;
  supports_package?: boolean;
  supports_merchant?: boolean;
  center_lat?: number;
  center_lng?: number;
  service_radius_km?: number;
};

type RegionRow = {
  region_id?: string;
  state?: string;
  enabled?: boolean;
  supports_rides?: boolean;
  supports_food?: boolean;
  supports_package?: boolean;
  supports_merchant?: boolean;
  dispatch_market_id?: string;
  currency?: string;
  timezone?: string;
  cities?: CityRow[];
};

type ListRes = {
  success?: boolean;
  regions?: RegionRow[];
  metrics_stub?: { region_id?: string }[];
  reason?: string;
};

type RolloutBackfillRes = {
  success?: boolean;
  reason?: string;
  dry_run?: boolean;
  scanned?: number;
  mapped?: number;
  skipped?: number;
  unsupported?: number;
  errors?: number;
  scanned_riders?: number;
  scanned_drivers?: number;
  mapped_riders?: number;
  mapped_drivers?: number;
  skipped_riders?: number;
  skipped_drivers?: number;
  unsupported_riders?: number;
  unsupported_drivers?: number;
  sample_skipped?: string[];
  sample_mapped?: string[];
  next_firestore_cursor?: string | null;
  next_drivers_cursor?: string | null;
  riders_has_more?: boolean;
  drivers_has_more?: boolean;
};

export function DeliveryRegionsAdminPage() {
  const fb = initNexRideWeb();
  const [rows, setRows] = useState<RegionRow[]>([]);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [bfBusy, setBfBusy] = useState(false);
  const [bfResult, setBfResult] = useState<RolloutBackfillRes | null>(null);

  const load = useCallback(async () => {
    if (!fb) return;
    setErr(null);
    const fn = httpsCallable(fb.functions, "adminListDeliveryRollout");
    const res = await fn({});
    const data = res.data as ListRes;
    if (!data.success) {
      setErr(data.reason || "load_failed");
      return;
    }
    setRows(data.regions || []);
  }, [fb]);

  useEffect(() => {
    void load();
  }, [load]);

  const patchRegion = async (r: RegionRow, patch: Record<string, unknown>) => {
    if (!fb) return;
    setBusy(true);
    try {
      const fn = httpsCallable(fb.functions, "adminUpsertDeliveryRegion");
      await fn({
        region_id: r.region_id,
        state: r.state,
        dispatch_market_id: r.dispatch_market_id,
        ...patch,
      });
      await load();
    } catch (e) {
      setErr(e instanceof Error ? e.message : "update_failed");
    } finally {
      setBusy(false);
    }
  };

  const patchCity = async (regionId: string, c: CityRow, patch: Record<string, unknown>) => {
    if (!fb) return;
    setBusy(true);
    try {
      const fn = httpsCallable(fb.functions, "adminUpsertDeliveryCity");
      await fn({
        region_id: regionId,
        city_id: c.city_id,
        display_name: c.display_name,
        center_lat: c.center_lat,
        center_lng: c.center_lng,
        service_radius_km: c.service_radius_km,
        ...patch,
      });
      await load();
    } catch (e) {
      setErr(e instanceof Error ? e.message : "city_update_failed");
    } finally {
      setBusy(false);
    }
  };

  const seed = async () => {
    if (!fb) return;
    setBusy(true);
    try {
      const fn = httpsCallable(fb.functions, "adminSeedRolloutDeliveryRegions");
      await fn({});
      await load();
    } catch (e) {
      setErr(e instanceof Error ? e.message : "seed_failed");
    } finally {
      setBusy(false);
    }
  };

  const runRolloutBackfill = async (dryRun: boolean) => {
    if (!fb) return;
    setBfBusy(true);
    setBfResult(null);
    try {
      const fn = httpsCallable(fb.functions, "backfillUserRolloutRegions");
      const res = await fn({
        dryRun,
        maxRiderBatch: 80,
        maxDriverBatch: 80,
      });
      setBfResult(res.data as RolloutBackfillRes);
    } catch (e) {
      setBfResult({
        success: false,
        reason: e instanceof Error ? e.message : "backfill_failed",
      });
    } finally {
      setBfBusy(false);
    }
  };

  if (!fb) {
    return <p>Firebase not configured.</p>;
  }

  return (
    <div>
      <h2>Delivery regions (rollout)</h2>
      <p style={{ color: "#555", fontSize: 14 }}>
        States and cities are loaded from Firestore. Use seed once per environment, then toggle availability. Metrics
        columns are placeholders until wired to analytics.
      </p>
      {err && <p style={{ color: "#b00020" }}>{err}</p>}
      <p>
        <button type="button" disabled={busy} onClick={() => void seed()}>
          Seed / refresh default rollout (6 states + cities)
        </button>{" "}
        <button type="button" disabled={busy} onClick={() => void load()}>
          Reload
        </button>
      </p>
      <section style={{ marginBottom: 24, padding: 14, background: "#f7f7f7", borderRadius: 8 }}>
        <h3 style={{ marginTop: 0 }}>Maintenance: rollout backfill</h3>
        <p style={{ fontSize: 13, color: "#444", marginTop: 0 }}>
          Infers <code>rollout_region_id</code> / <code>rollout_city_id</code> / <code>rollout_dispatch_market_id</code>{" "}
          from legacy city/market fields for riders (Firestore <code>users</code>) and drivers (RTDB <code>drivers</code>).
          Port Harcourt / Rivers is left unsupported. Default is dry-run (no writes).
        </p>
        <p>
          <button type="button" disabled={bfBusy} onClick={() => void runRolloutBackfill(true)}>
            Dry-run rollout backfill
          </button>{" "}
          <button type="button" disabled={bfBusy} onClick={() => void runRolloutBackfill(false)}>
            Apply rollout backfill
          </button>
        </p>
        {bfResult && (
          <div style={{ fontSize: 13 }}>
            {bfResult.success === false && (
              <p style={{ color: "#b00020" }}>{bfResult.reason || "backfill_failed"}</p>
            )}
            {bfResult.success === true && (
              <>
                <p>
                  <strong>dry_run:</strong> {String(bfResult.dry_run ?? true)} · <strong>scanned:</strong>{" "}
                  {bfResult.scanned ?? "—"} · <strong>mapped:</strong> {bfResult.mapped ?? "—"} ·{" "}
                  <strong>skipped:</strong> {bfResult.skipped ?? "—"} · <strong>unsupported:</strong>{" "}
                  {bfResult.unsupported ?? "—"} · <strong>errors:</strong> {bfResult.errors ?? "—"}
                </p>
                <p style={{ marginBottom: 4 }}>
                  <strong>Riders</strong> scanned {bfResult.scanned_riders ?? 0}, mapped {bfResult.mapped_riders ?? 0},
                  skipped {bfResult.skipped_riders ?? 0}, unsupported {bfResult.unsupported_riders ?? 0}
                </p>
                <p style={{ marginBottom: 4 }}>
                  <strong>Drivers</strong> scanned {bfResult.scanned_drivers ?? 0}, mapped{" "}
                  {bfResult.mapped_drivers ?? 0}, skipped {bfResult.skipped_drivers ?? 0}, unsupported{" "}
                  {bfResult.unsupported_drivers ?? 0}
                </p>
                <p style={{ marginBottom: 4 }}>
                  <strong>Next cursors</strong> Firestore: <code>{bfResult.next_firestore_cursor ?? "null"}</code> ·
                  drivers: <code>{bfResult.next_drivers_cursor ?? "null"}</code>
                </p>
                {(bfResult.sample_skipped?.length ?? 0) > 0 && (
                  <details>
                    <summary>Sample skipped / unsupported</summary>
                    <ul>
                      {(bfResult.sample_skipped ?? []).map((s) => (
                        <li key={s}>
                          <code>{s}</code>
                        </li>
                      ))}
                    </ul>
                  </details>
                )}
                {(bfResult.sample_mapped?.length ?? 0) > 0 && (
                  <details>
                    <summary>Sample mapped</summary>
                    <ul>
                      {(bfResult.sample_mapped ?? []).map((s) => (
                        <li key={s}>
                          <code>{s}</code>
                        </li>
                      ))}
                    </ul>
                  </details>
                )}
              </>
            )}
          </div>
        )}
      </section>
      {rows.map((r) => (
        <section key={r.region_id} style={{ marginBottom: 28, borderBottom: "1px solid #ddd", paddingBottom: 12 }}>
          <h3 style={{ marginBottom: 4 }}>
            {r.state} <code>({r.region_id})</code>
          </h3>
          <p style={{ fontSize: 13, marginTop: 0 }}>
            Dispatch market: <code>{r.dispatch_market_id}</code> · Currency {r.currency ?? "NGN"} · TZ{" "}
            {r.timezone ?? "Africa/Lagos"}
          </p>
          <label style={{ fontSize: 14 }}>
            <input
              type="checkbox"
              checked={r.enabled !== false}
              disabled={busy}
              onChange={(e) => void patchRegion(r, { enabled: e.target.checked })}
            />{" "}
            State enabled
          </label>
          <div style={{ marginTop: 8, display: "flex", gap: 12, flexWrap: "wrap" }}>
            {["supports_rides", "supports_food", "supports_package", "supports_merchant"].map((k) => (
              <label key={k} style={{ fontSize: 13 }}>
                <input
                  type="checkbox"
                  checked={(r as Record<string, boolean>)[k] !== false}
                  disabled={busy}
                  onChange={(e) => void patchRegion(r, { [k]: e.target.checked })}
                />{" "}
                {k.replace("supports_", "")}
              </label>
            ))}
          </div>
          <h4 style={{ marginTop: 16 }}>Cities</h4>
          <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 13 }}>
            <thead>
              <tr>
                <th style={{ textAlign: "left", borderBottom: "1px solid #ccc" }}>City</th>
                <th style={{ textAlign: "left", borderBottom: "1px solid #ccc" }}>Enabled</th>
                <th style={{ textAlign: "left", borderBottom: "1px solid #ccc" }}>Rides</th>
                <th style={{ textAlign: "left", borderBottom: "1px solid #ccc" }}>Food</th>
                <th style={{ textAlign: "left", borderBottom: "1px solid #ccc" }}>Pkg</th>
                <th style={{ textAlign: "left", borderBottom: "1px solid #ccc" }}>Merchant</th>
              </tr>
            </thead>
            <tbody>
              {(r.cities || []).map((c) => (
                <tr key={c.city_id}>
                  <td style={{ padding: "4px 0" }}>
                    {c.display_name} <code>({c.city_id})</code>
                  </td>
                  <td>
                    <input
                      type="checkbox"
                      checked={c.enabled !== false}
                      disabled={busy || !r.region_id}
                      onChange={(e) => void patchCity(String(r.region_id), c, { enabled: e.target.checked })}
                    />
                  </td>
                  {(["supports_rides", "supports_food", "supports_package", "supports_merchant"] as const).map(
                    (k) => (
                      <td key={k}>
                        <input
                          type="checkbox"
                          checked={(c as Record<string, boolean>)[k] !== false}
                          disabled={busy || !r.region_id}
                          onChange={(e) =>
                            void patchCity(String(r.region_id), c, { [k]: e.target.checked })
                          }
                        />
                      </td>
                    ),
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      ))}
      {rows.length === 0 && !err && <p style={{ color: "#666" }}>No regions loaded. Run seed.</p>}
    </div>
  );
}
