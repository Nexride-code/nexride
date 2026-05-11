import { httpsCallable } from "firebase/functions";
import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { initNexRideWeb } from "../../lib/firebaseClient";

type MerchantRow = {
  merchant_id: string;
  owner_uid: string;
  business_name: string;
  status: string;
  contact_email: string | null;
  created_at: number | null;
};

type ListResponse = { success?: boolean; merchants?: MerchantRow[]; reason?: string };

export function MerchantsAdminListPage() {
  const [rows, setRows] = useState<MerchantRow[]>([]);
  const [err, setErr] = useState<string | null>(null);
  const [status, setStatus] = useState<string>("");

  useEffect(() => {
    const fb = initNexRideWeb();
    if (!fb) {
      setErr("Missing Firebase config");
      return;
    }
    let c = false;
    (async () => {
      try {
        const fn = httpsCallable(fb.functions, "adminListMerchants");
        const res = await fn({ limit: 80, status: status || undefined });
        const data = res.data as ListResponse;
        if (c) return;
        if (!data.success) setErr(data.reason || "failed");
        else setRows(data.merchants || []);
      } catch (e) {
        if (!c) setErr(e instanceof Error ? e.message : "failed");
      }
    })();
    return () => {
      c = true;
    };
  }, [status]);

  return (
    <div>
      <h2>Merchants</h2>
      <p style={{ color: "#555", fontSize: 14 }}>
        Phase 1: applications and review only. No menus, orders, or wallets.
      </p>
      <label style={{ display: "inline-flex", alignItems: "center", gap: 8, marginBottom: 12 }}>
        Status
        <select value={status} onChange={(e) => setStatus(e.target.value)}>
          <option value="">All (recent)</option>
          <option value="pending">Pending</option>
          <option value="approved">Approved</option>
          <option value="rejected">Rejected</option>
          <option value="suspended">Suspended</option>
        </select>
      </label>
      {err && <p style={{ color: "#b00020" }}>{err}</p>}
      <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 14 }}>
        <thead>
          <tr>
            <th style={{ textAlign: "left", borderBottom: "1px solid #ccc" }}>Business</th>
            <th style={{ textAlign: "left", borderBottom: "1px solid #ccc" }}>Status</th>
            <th style={{ textAlign: "left", borderBottom: "1px solid #ccc" }}>Owner</th>
            <th style={{ textAlign: "left", borderBottom: "1px solid #ccc" }} />
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.merchant_id}>
              <td style={{ padding: "6px 0", verticalAlign: "top" }}>{r.business_name}</td>
              <td style={{ padding: "6px 0", verticalAlign: "top" }}>{r.status}</td>
              <td style={{ padding: "6px 0", verticalAlign: "top" }}>
                <code>{r.owner_uid.slice(0, 10)}…</code>
              </td>
              <td style={{ padding: "6px 0", verticalAlign: "top" }}>
                <Link to={`/admin/merchants/${encodeURIComponent(r.merchant_id)}`}>Open</Link>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      {rows.length === 0 && !err && <p style={{ color: "#666" }}>No merchants loaded.</p>}
    </div>
  );
}
