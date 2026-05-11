import { httpsCallable } from "firebase/functions";
import { useCallback, useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { initNexRideWeb } from "../../lib/firebaseClient";

type MerchantDetail = {
  merchant_id: string;
  owner_uid: string;
  business_name: string;
  status: string;
  contact_email: string | null;
  created_at: number | null;
  updated_at: number | null;
  reviewed_at: number | null;
  reviewed_by: string | null;
  review_note: string | null;
};

type GetResponse = { success?: boolean; merchant?: MerchantDetail; reason?: string };
type ReviewResponse = { success?: boolean; status?: string; reason?: string };

export function MerchantDetailAdminPage() {
  const { merchantId: merchantIdParam } = useParams();
  const merchantId = merchantIdParam ? decodeURIComponent(merchantIdParam) : "";
  const [m, setM] = useState<MerchantDetail | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [note, setNote] = useState("");
  const [msg, setMsg] = useState<string | null>(null);

  const load = useCallback(() => {
    const fb = initNexRideWeb();
    if (!fb || !merchantId) return;
    setErr(null);
    setMsg(null);
    void (async () => {
      try {
        const fn = httpsCallable(fb.functions, "adminGetMerchant");
        const res = await fn({ merchant_id: merchantId });
        const data = res.data as GetResponse;
        if (!data.success) {
          setErr(data.reason || "failed");
          setM(null);
        } else {
          setM(data.merchant ?? null);
        }
      } catch (e) {
        setErr(e instanceof Error ? e.message : "failed");
        setM(null);
      }
    })();
  }, [merchantId]);

  useEffect(() => {
    load();
  }, [load]);

  const review = async (action: "approve" | "reject" | "suspend") => {
    const fb = initNexRideWeb();
    if (!fb || !merchantId) return;
    setMsg(null);
    try {
      const fn = httpsCallable(fb.functions, "adminReviewMerchant");
      const res = await fn({ merchant_id: merchantId, action, note: note.trim() });
      const data = res.data as ReviewResponse;
      if (!data.success) setMsg(data.reason || "failed");
      else {
        setMsg(`Updated to ${data.status ?? action}.`);
        load();
      }
    } catch (e) {
      setMsg(e instanceof Error ? e.message : "failed");
    }
  };

  if (!merchantId) {
    return <p>Missing merchant id.</p>;
  }

  return (
    <div>
      <p>
        <Link to="/admin/merchants">← Merchants</Link>
      </p>
      <h2>Merchant</h2>
      {err && <p style={{ color: "#b00020" }}>{err}</p>}
      {m && (
        <div style={{ marginBottom: 16 }}>
          <p>
            <strong>{m.business_name}</strong> — <code>{m.status}</code>
          </p>
          <p style={{ fontSize: 14, color: "#444" }}>
            Owner UID: <code>{m.owner_uid}</code>
          </p>
          {m.contact_email && (
            <p style={{ fontSize: 14, color: "#444" }}>Contact: {m.contact_email}</p>
          )}
          {m.review_note && (
            <p style={{ fontSize: 14, color: "#444" }}>
              Last note: {m.review_note}
            </p>
          )}
        </div>
      )}
      <label style={{ display: "block", marginBottom: 12 }}>
        Review note (optional)
        <textarea
          value={note}
          onChange={(e) => setNote(e.target.value)}
          rows={3}
          style={{ display: "block", width: "100%", marginTop: 4, maxWidth: 480 }}
        />
      </label>
      <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
        <button type="button" onClick={() => void review("approve")}>
          Approve
        </button>
        <button type="button" onClick={() => void review("reject")}>
          Reject
        </button>
        <button type="button" onClick={() => void review("suspend")}>
          Suspend
        </button>
      </div>
      {msg && <p style={{ marginTop: 12 }}>{msg}</p>}
    </div>
  );
}
