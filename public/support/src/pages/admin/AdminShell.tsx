import { httpsCallable } from "firebase/functions";
import { onAuthStateChanged, signInWithEmailAndPassword, signOut } from "firebase/auth";
import { useCallback, useEffect, useState } from "react";
import { Link, Route, Routes } from "react-router-dom";
import { get, initNexRideWeb, ref } from "../../lib/firebaseClient";

type LiveRide = {
  ride_id: string;
  trip_state: string | null;
  status: string | null;
  rider_id: string;
  driver_id: string | null;
  fare: number;
  currency: string;
  payment_status: string;
  pickup_area: string;
  updated_at: number;
};

function useAdminSession() {
  const fb = initNexRideWeb();
  const [user, setUser] = useState(fb?.auth.currentUser ?? null);
  const [allowed, setAllowed] = useState(false);
  const [checked, setChecked] = useState(!fb);

  useEffect(() => {
    if (!fb) {
      setChecked(true);
      return;
    }
    const unsub = onAuthStateChanged(fb.auth, async (u) => {
      setUser(u);
      if (!u) {
        setAllowed(false);
        setChecked(true);
        return;
      }
      const idToken = await u.getIdTokenResult();
      const claimAdmin = idToken.claims.admin === true;
      const snap = await get(ref(fb.database, `admins/${u.uid}`));
      setAllowed(claimAdmin || snap.val() === true);
      setChecked(true);
    });
    return () => unsub();
  }, [fb]);

  return { fb, user, allowed, checked };
}

function AdminLogin() {
  const fb = initNexRideWeb();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [err, setErr] = useState<string | null>(null);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setErr(null);
    if (!fb) {
      setErr("Missing web Firebase config (VITE_FIREBASE_*).");
      return;
    }
    try {
      await signInWithEmailAndPassword(fb.auth, email.trim(), password);
    } catch (ex: unknown) {
      setErr(ex instanceof Error ? ex.message : "Sign-in failed");
    }
  };

  if (!fb) {
    return <p style={{ color: "#b00020" }}>Set VITE_FIREBASE_* in web/.env to enable admin login.</p>;
  }

  return (
    <form onSubmit={submit} style={{ maxWidth: 360 }}>
      <h2>Admin sign in</h2>
      <p style={{ color: "#555", fontSize: 14 }}>
        Access requires <code>admins/{"{yourUid}"} = true</code> in Realtime Database and/or custom claim{" "}
        <code>admin: true</code> (Cloud Functions enforce the same server-side).
      </p>
      {err && <p style={{ color: "#b00020" }}>{err}</p>}
      <label style={{ display: "block", marginBottom: 8 }}>
        Email
        <input
          type="email"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          required
          style={{ display: "block", width: "100%", marginTop: 4 }}
        />
      </label>
      <label style={{ display: "block", marginBottom: 12 }}>
        Password
        <input
          type="password"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          required
          style={{ display: "block", width: "100%", marginTop: 4 }}
        />
      </label>
      <button type="submit">Sign in</button>
    </form>
  );
}

function useCall<T, R>(name: string) {
  const fb = initNexRideWeb();
  return useCallback(
    async (data: T): Promise<R> => {
      if (!fb) throw new Error("no firebase");
      const fn = httpsCallable(fb.functions, name);
      const res = await fn(data as object);
      return res.data as R;
    },
    [fb, name],
  );
}

function OverviewPage() {
  const callList = useCall<object, { success?: boolean; rides?: LiveRide[]; reason?: string }>(
    "adminListLiveRides",
  );
  const callWd = useCall<object, { success?: boolean; withdrawals?: unknown[]; reason?: string }>(
    "adminListPendingWithdrawals",
  );
  const [rides, setRides] = useState<LiveRide[]>([]);
  const [pendingWd, setPendingWd] = useState(0);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const [a, b] = await Promise.all([callList({}), callWd({})]);
        if (cancelled) return;
        if (!a.success) setErr(a.reason || "rides failed");
        else setRides(a.rides || []);
        if (b.success && Array.isArray(b.withdrawals)) setPendingWd(b.withdrawals.length);
      } catch (e) {
        if (!cancelled) setErr(e instanceof Error ? e.message : "load failed");
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [callList, callWd]);

  return (
    <div>
      <h2>Overview</h2>
      {err && <p style={{ color: "#b00020" }}>{err}</p>}
      <p>
        <strong>Active trips (sample):</strong> {rides.length}
      </p>
      <p>
        <strong>Pending withdrawals:</strong> {pendingWd}
      </p>
    </div>
  );
}

function LiveRidesPage() {
  const callList = useCall<object, { success?: boolean; rides?: LiveRide[]; reason?: string }>(
    "adminListLiveRides",
  );
  const [rides, setRides] = useState<LiveRide[]>([]);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    let c = false;
    (async () => {
      try {
        const a = await callList({});
        if (c) return;
        if (!a.success) setErr(a.reason || "failed");
        else setRides(a.rides || []);
      } catch (e) {
        if (!c) setErr(e instanceof Error ? e.message : "failed");
      }
    })();
    return () => {
      c = true;
    };
  }, [callList]);

  return (
    <div>
      <h2>Live rides</h2>
      {err && <p style={{ color: "#b00020" }}>{err}</p>}
      <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 14 }}>
        <thead>
          <tr>
            <th style={{ textAlign: "left", borderBottom: "1px solid #ccc" }}>Ride</th>
            <th style={{ textAlign: "left", borderBottom: "1px solid #ccc" }}>State</th>
            <th style={{ textAlign: "left", borderBottom: "1px solid #ccc" }}>Payment</th>
            <th style={{ textAlign: "left", borderBottom: "1px solid #ccc" }}>Pickup</th>
          </tr>
        </thead>
        <tbody>
          {rides.map((r) => (
            <tr key={r.ride_id}>
              <td style={{ padding: "6px 0", verticalAlign: "top" }}>
                <code>{r.ride_id.slice(0, 12)}…</code>
              </td>
              <td style={{ padding: "6px 0", verticalAlign: "top" }}>
                {r.trip_state ?? "—"} / {r.status ?? "—"}
              </td>
              <td style={{ padding: "6px 0", verticalAlign: "top" }}>{r.payment_status || "—"}</td>
              <td style={{ padding: "6px 0", verticalAlign: "top" }}>{r.pickup_area}</td>
            </tr>
          ))}
        </tbody>
      </table>
      {rides.length === 0 && !err && <p style={{ color: "#666" }}>No active trips in index.</p>}
    </div>
  );
}

function DriversPage() {
  const call = useCall<object, { success?: boolean; drivers?: unknown[]; reason?: string }>("adminListDrivers");
  const [rows, setRows] = useState<unknown[]>([]);
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => {
    let c = false;
    (async () => {
      try {
        const a = await call({});
        if (c) return;
        if (!a.success) setErr(a.reason || "failed");
        else setRows(a.drivers || []);
      } catch (e) {
        if (!c) setErr(e instanceof Error ? e.message : "failed");
      }
    })();
    return () => {
      c = true;
    };
  }, [call]);
  return (
    <div>
      <h2>Drivers</h2>
      {err && <p style={{ color: "#b00020" }}>{err}</p>}
      <pre style={{ background: "#f6f6f6", padding: 12, overflow: "auto", fontSize: 13 }}>
        {JSON.stringify(rows, null, 2)}
      </pre>
    </div>
  );
}

function RidersPage() {
  const call = useCall<object, { success?: boolean; riders?: unknown; reason?: string }>("adminListRidersPage");
  const [rows, setRows] = useState<unknown[]>([]);
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => {
    let c = false;
    (async () => {
      const callableName = "adminListRidersPage";
      const payload = { limit: 200, cursor: "" };
      try {
        const a = await call(payload);
        if (c) return;
        console.debug("[AdminRidersDebug]", { callable: callableName, request: payload, raw: a });
        const ok = a.success === true || a.success === 1;
        if (!ok) {
          setErr(a.reason || "failed");
          setRows([]);
          console.debug("[AdminRidersDebug] callable not ok", { reason: a.reason });
          return;
        }
        const raw = a.riders as unknown;
        const normalized = Array.isArray(raw)
          ? raw
          : raw && typeof raw === "object"
            ? Object.entries(raw as Record<string, unknown>).map(([uid, row]) => ({
                uid,
                ...(typeof row === "object" && row !== null ? (row as Record<string, unknown>) : {}),
              }))
            : [];
        console.debug("[AdminRidersDebug] parsed riders", { count: normalized.length, normalized });
        setErr(null);
        setRows(normalized);
      } catch (e) {
        if (!c) setErr(e instanceof Error ? e.message : "failed");
      }
    })();
    return () => {
      c = true;
    };
  }, [call]);
  return (
    <div>
      <h2>Riders (users)</h2>
      {err && <p style={{ color: "#b00020" }}>{err}</p>}
      <pre style={{ background: "#f6f6f6", padding: 12, overflow: "auto", fontSize: 13 }}>
        {JSON.stringify(rows, null, 2)}
      </pre>
    </div>
  );
}

function PaymentsPage() {
  const call = useCall<object, { success?: boolean; payments?: unknown[]; reason?: string }>("adminListPayments");
  const [rows, setRows] = useState<unknown[]>([]);
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => {
    let c = false;
    (async () => {
      try {
        const a = await call({});
        if (c) return;
        if (!a.success) setErr(a.reason || "failed");
        else setRows(a.payments || []);
      } catch (e) {
        if (!c) setErr(e instanceof Error ? e.message : "failed");
      }
    })();
    return () => {
      c = true;
    };
  }, [call]);
  return (
    <div>
      <h2>Payments</h2>
      {err && <p style={{ color: "#b00020" }}>{err}</p>}
      <pre style={{ background: "#f6f6f6", padding: 12, overflow: "auto", fontSize: 13 }}>
        {JSON.stringify(rows, null, 2)}
      </pre>
    </div>
  );
}

function WithdrawalsPage() {
  const list = useCall<object, { success?: boolean; withdrawals?: Record<string, unknown>[]; reason?: string }>(
    "adminListPendingWithdrawals",
  );
  const approve = useCall<{ withdrawalId: string }, { success?: boolean; reason?: string }>("adminApproveWithdrawal");
  const reject = useCall<{ withdrawalId: string }, { success?: boolean; reason?: string }>("adminRejectWithdrawal");
  const [rows, setRows] = useState<Record<string, unknown>[]>([]);
  const [err, setErr] = useState<string | null>(null);

  const reload = useCallback(async () => {
    const a = await list({});
    if (!a.success) {
      setErr(a.reason || "failed");
      return;
    }
    setErr(null);
    setRows(a.withdrawals || []);
  }, [list]);

  useEffect(() => {
    void reload();
  }, [reload]);

  return (
    <div>
      <h2>Withdrawals</h2>
      {err && <p style={{ color: "#b00020" }}>{err}</p>}
      <button type="button" onClick={() => void reload()} style={{ marginBottom: 12 }}>
        Refresh
      </button>
      <ul style={{ listStyle: "none", padding: 0 }}>
        {rows.map((w) => {
          const id = String(w.id ?? "");
          return (
            <li
              key={id}
              style={{ border: "1px solid #ddd", padding: 12, marginBottom: 8, borderRadius: 6 }}
            >
              <code>{id}</code> — {String(w.status)} — {String(w.amount)} —{" "}
              {JSON.stringify(w.withdrawalAccount ?? {})}
              <div style={{ marginTop: 8, display: "flex", gap: 8 }}>
                <button
                  type="button"
                  onClick={async () => {
                    await approve({ withdrawalId: id });
                    await reload();
                  }}
                >
                  Mark paid
                </button>
                <button
                  type="button"
                  onClick={async () => {
                    await reject({ withdrawalId: id });
                    await reload();
                  }}
                >
                  Reject
                </button>
              </div>
            </li>
          );
        })}
      </ul>
      {rows.length === 0 && !err && <p style={{ color: "#666" }}>No pending withdrawals.</p>}
    </div>
  );
}

function TicketsPage() {
  return (
    <div>
      <h2>Support tickets</h2>
      <p style={{ color: "#555" }}>
        Use the <Link to="/support/tickets">support desk</Link> for ticket threads, or call{" "}
        <code>supportListTickets</code> from a support-signed-in session.
      </p>
      <p style={{ color: "#555" }}>
        In-app ticket listing for admins is planned; until then, use the support desk link above or callables from an
        authenticated support session.
      </p>
    </div>
  );
}

function LookupPage() {
  const getRide = useCall<{ rideId: string }, { success?: boolean; ride?: unknown; reason?: string }>(
    "adminGetRideDetails",
  );
  const [rideId, setRideId] = useState("");
  const [out, setOut] = useState<unknown>(null);
  const [err, setErr] = useState<string | null>(null);

  const run = async () => {
    setErr(null);
    setOut(null);
    try {
      const a = await getRide({ rideId: rideId.trim() });
      if (!a.success) setErr(a.reason || "failed");
      else setOut(a);
    } catch (e) {
      setErr(e instanceof Error ? e.message : "failed");
    }
  };

  return (
    <div>
      <h2>Ride lookup</h2>
      <input value={rideId} onChange={(e) => setRideId(e.target.value)} placeholder="ride_requests key" />
      <button type="button" onClick={() => void run()} style={{ marginLeft: 8 }}>
        Load
      </button>
      {err && <p style={{ color: "#b00020" }}>{err}</p>}
      {out && (
        <pre style={{ background: "#f6f6f6", padding: 12, marginTop: 12, fontSize: 12, overflow: "auto" }}>
          {JSON.stringify(out, null, 2)}
        </pre>
      )}
    </div>
  );
}

function VerificationPage() {
  const verify = useCall<{ driverId: string }, { success?: boolean; reason?: string }>("adminVerifyDriver");
  const [driverId, setDriverId] = useState("");
  const [msg, setMsg] = useState<string | null>(null);

  return (
    <div>
      <h2>Driver verification</h2>
      <input value={driverId} onChange={(e) => setDriverId(e.target.value)} placeholder="Driver UID" />
      <button
        type="button"
        onClick={async () => {
          setMsg(null);
          try {
            const r = await verify({ driverId: driverId.trim() });
            setMsg(r.success ? "Verified." : r.reason || "failed");
          } catch (e) {
            setMsg(e instanceof Error ? e.message : "failed");
          }
        }}
        style={{ marginLeft: 8 }}
      >
        Mark verified
      </button>
      {msg && <p>{msg}</p>}
    </div>
  );
}

function SettingsPage() {
  return (
    <div>
      <h2>Settings</h2>
      <p style={{ color: "#555" }}>
        Platform fee, Flutterwave mode, and feature flags are controlled in Firebase (Remote Config / RTDB app config),
        not in this web shell. Confirm values in the Firebase console before changing live pricing.
      </p>
    </div>
  );
}

export function AdminShell() {
  const { fb, user, allowed, checked } = useAdminSession();

  const logout = async () => {
    if (fb) await signOut(fb.auth);
  };

  if (!fb) {
    return (
      <div>
        <h1>Admin</h1>
        <p style={{ color: "#b00020" }}>Configure VITE_FIREBASE_* then build again.</p>
      </div>
    );
  }

  if (!checked) {
    return (
      <div>
        <h1>Admin</h1>
        <p>Checking session…</p>
      </div>
    );
  }

  if (!user) {
    return (
      <div>
        <h1>Admin</h1>
        <AdminLogin />
      </div>
    );
  }

  if (!allowed) {
    return (
      <div>
        <h1>Admin</h1>
        <p style={{ color: "#b00020" }}>
          Signed in as {user.email}, but this account is not an admin (no <code>admin</code> claim and no{" "}
          <code>admins/{"{uid}"}</code> flag).
        </p>
        <button type="button" onClick={() => void logout()}>
          Sign out
        </button>
      </div>
    );
  }

  return (
    <div>
      <h1>Admin</h1>
      <p style={{ fontSize: 14 }}>
        {user.email}{" "}
        <button type="button" onClick={() => void logout()}>
          Sign out
        </button>
      </p>
      <nav style={{ display: "flex", gap: 12, flexWrap: "wrap", marginBottom: 16 }}>
        <Link to="/admin">Overview</Link>
        <Link to="/admin/rides">Live rides</Link>
        <Link to="/admin/riders">Riders</Link>
        <Link to="/admin/drivers">Drivers</Link>
        <Link to="/admin/payments">Payments</Link>
        <Link to="/admin/withdrawals">Withdrawals</Link>
        <Link to="/admin/tickets">Support tickets</Link>
        <Link to="/admin/lookup">Ride lookup</Link>
        <Link to="/admin/verification">Driver verification</Link>
        <Link to="/admin/settings">Settings</Link>
      </nav>
      <Routes>
        <Route path="/" element={<OverviewPage />} />
        <Route path="/rides" element={<LiveRidesPage />} />
        <Route path="/riders" element={<RidersPage />} />
        <Route path="/drivers" element={<DriversPage />} />
        <Route path="/payments" element={<PaymentsPage />} />
        <Route path="/withdrawals" element={<WithdrawalsPage />} />
        <Route path="/tickets" element={<TicketsPage />} />
        <Route path="/lookup" element={<LookupPage />} />
        <Route path="/verification" element={<VerificationPage />} />
        <Route path="/settings" element={<SettingsPage />} />
      </Routes>
    </div>
  );
}
