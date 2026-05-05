import { httpsCallable } from "firebase/functions";
import { onAuthStateChanged, signInWithEmailAndPassword, signOut } from "firebase/auth";
import { useCallback, useEffect, useState } from "react";
import { Link, Route, Routes } from "react-router-dom";
import { get, initNexRideWeb, ref } from "../../lib/firebaseClient";

function useSupportSession() {
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
      const claimSupport = idToken.claims.support_staff === true;
      const [admSnap, supSnap] = await Promise.all([
        get(ref(fb.database, `admins/${u.uid}`)),
        get(ref(fb.database, `support_staff/${u.uid}`)),
      ]);
      setAllowed(claimAdmin || claimSupport || admSnap.val() === true || supSnap.val() === true);
      setChecked(true);
    });
    return () => unsub();
  }, [fb]);

  return { fb, user, allowed, checked };
}

function SupportLogin() {
  const fb = initNexRideWeb();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [err, setErr] = useState<string | null>(null);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setErr(null);
    if (!fb) {
      setErr("Missing web Firebase config.");
      return;
    }
    try {
      await signInWithEmailAndPassword(fb.auth, email.trim(), password);
    } catch (ex: unknown) {
      setErr(ex instanceof Error ? ex.message : "Sign-in failed");
    }
  };

  if (!fb) {
    return <p style={{ color: "#b00020" }}>Set VITE_FIREBASE_* in web/.env.</p>;
  }

  return (
    <form onSubmit={submit} style={{ maxWidth: 360 }}>
      <h2>Support sign in</h2>
      <p style={{ color: "#555", fontSize: 14 }}>
        Your account is signed in but does not have access. Contact the NexRide system administrator.
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

function useFn<T, R>(name: string) {
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

function SearchRidePage() {
  const search = useFn<{ rideId: string }, { success?: boolean; ride_summary?: unknown; reason?: string }>(
    "supportSearchRide",
  );
  const [rideId, setRideId] = useState("");
  const [out, setOut] = useState<unknown>(null);
  const [err, setErr] = useState<string | null>(null);

  const run = async () => {
    setErr(null);
    setOut(null);
    try {
      const a = await search({ rideId: rideId.trim() });
      if (!a.success) setErr(a.reason || "not found");
      else setOut(a);
    } catch (e) {
      setErr(e instanceof Error ? e.message : "failed");
    }
  };

  return (
    <div>
      <h2>Search ride</h2>
      <input value={rideId} onChange={(e) => setRideId(e.target.value)} placeholder="ride_requests key" />
      <button type="button" onClick={() => void run()} style={{ marginLeft: 8 }}>
        Search
      </button>
      {err && <p style={{ color: "#b00020" }}>{err}</p>}
      {out && (
        <pre style={{ background: "#f6f6f6", padding: 12, marginTop: 12, fontSize: 13, overflow: "auto" }}>
          {JSON.stringify(out, null, 2)}
        </pre>
      )}
    </div>
  );
}

function SearchUserPage() {
  const search = useFn<{ uid: string }, { success?: boolean; profile?: unknown; reason?: string }>(
    "supportSearchUser",
  );
  const [uid, setUid] = useState("");
  const [out, setOut] = useState<unknown>(null);
  const [err, setErr] = useState<string | null>(null);

  const run = async () => {
    setErr(null);
    setOut(null);
    try {
      const a = await search({ uid: uid.trim() });
      if (!a.success) setErr(a.reason || "failed");
      else setOut(a.profile);
    } catch (e) {
      setErr(e instanceof Error ? e.message : "failed");
    }
  };

  return (
    <div>
      <h2>Search rider / driver</h2>
      <input value={uid} onChange={(e) => setUid(e.target.value)} placeholder="Firebase Auth UID" />
      <button type="button" onClick={() => void run()} style={{ marginLeft: 8 }}>
        Lookup
      </button>
      {err && <p style={{ color: "#b00020" }}>{err}</p>}
      {out && (
        <pre style={{ background: "#f6f6f6", padding: 12, marginTop: 12, fontSize: 13, overflow: "auto" }}>
          {JSON.stringify(out, null, 2)}
        </pre>
      )}
    </div>
  );
}

function TicketsPage() {
  const list = useFn<object, { success?: boolean; tickets?: unknown[]; reason?: string }>("supportListTickets");
  const update = useFn<{ ticketId: string; status?: string; message?: string }, { success?: boolean; reason?: string }>(
    "supportUpdateTicket",
  );
  const [rows, setRows] = useState<unknown[]>([]);
  const [ticketId, setTicketId] = useState("");
  const [status, setStatus] = useState("");
  const [message, setMessage] = useState("");
  const [err, setErr] = useState<string | null>(null);

  const reload = useCallback(async () => {
    const a = await list({});
    if (!a.success) {
      setErr(a.reason || "failed");
      return;
    }
    setErr(null);
    setRows(a.tickets || []);
  }, [list]);

  useEffect(() => {
    void reload();
  }, [reload]);

  return (
    <div>
      <h2>Open tickets</h2>
      {err && <p style={{ color: "#b00020" }}>{err}</p>}
      <button type="button" onClick={() => void reload()} style={{ marginBottom: 12 }}>
        Refresh
      </button>
      <ul style={{ listStyle: "none", padding: 0 }}>
        {rows.map((t) => {
          const row = t as { id?: string; status?: string; subject?: string };
          return (
            <li key={row.id || Math.random()} style={{ border: "1px solid #ddd", padding: 8, marginBottom: 6 }}>
              <code>{String(row.id)}</code> — {String(row.status)} — {String(row.subject || "")}
            </li>
          );
        })}
      </ul>
      <h3 style={{ marginTop: 24 }}>Update ticket</h3>
      <input value={ticketId} onChange={(e) => setTicketId(e.target.value)} placeholder="ticket id" />
      <input value={status} onChange={(e) => setStatus(e.target.value)} placeholder="status (optional)" style={{ marginLeft: 8 }} />
      <div style={{ marginTop: 8 }}>
        <textarea
          value={message}
          onChange={(e) => setMessage(e.target.value)}
          placeholder="message to append"
          rows={3}
          style={{ width: "100%", maxWidth: 480 }}
        />
      </div>
      <button
        type="button"
        onClick={async () => {
          await update({
            ticketId: ticketId.trim(),
            status: status.trim() || undefined,
            message: message.trim() || undefined,
          });
          setMessage("");
          await reload();
        }}
        style={{ marginTop: 8 }}
      >
        Submit update
      </button>
    </div>
  );
}

function RefundsPage() {
  return (
    <div>
      <h2>Refunds / payment status</h2>
      <p style={{ color: "#555" }}>Search a ride, then cross-check payment rows in admin Payments or Flutterwave dashboard.</p>
      <p style={{ color: "#555" }}>
        Automated refunds are not exposed in this console; process adjustments in admin Payments or the Flutterwave
        dashboard following your finance policy.
      </p>
    </div>
  );
}

function EscalationsPage() {
  return (
    <div>
      <h2>Escalations</h2>
      <p style={{ color: "#555" }}>Escalate to ops by updating ticket status and message.</p>
      <p style={{ color: "#555" }}>
        SLA timers and ticket assignment fields are not configured in this build; track response targets in your ops
        playbook until those fields ship.
      </p>
    </div>
  );
}

export function SupportShell() {
  const { fb, user, allowed, checked } = useSupportSession();

  const logout = async () => {
    if (fb) await signOut(fb.auth);
  };

  if (!fb) {
    return (
      <div>
        <h1>Support</h1>
        <p style={{ color: "#b00020" }}>Configure VITE_FIREBASE_* then build again.</p>
      </div>
    );
  }

  if (!checked) {
    return (
      <div>
        <h1>Support</h1>
        <p>Checking session…</p>
      </div>
    );
  }

  if (!user) {
    return (
      <div>
        <h1>Support</h1>
        <SupportLogin />
      </div>
    );
  }

  if (!allowed) {
    return (
      <div>
        <h1>Support</h1>
        <p style={{ color: "#b00020" }}>No support access for {user.email}.</p>
        <button type="button" onClick={() => void logout()}>
          Sign out
        </button>
      </div>
    );
  }

  return (
    <div>
      <h1>Support</h1>
      <p style={{ fontSize: 14 }}>
        {user.email}{" "}
        <button type="button" onClick={() => void logout()}>
          Sign out
        </button>
      </p>
      <nav style={{ display: "flex", gap: 12, flexWrap: "wrap", marginBottom: 16 }}>
        <Link to="/support">Home</Link>
        <Link to="/support/search-ride">Search ride</Link>
        <Link to="/support/search-user">Search user</Link>
        <Link to="/support/tickets">Tickets</Link>
        <Link to="/support/refunds">Refunds</Link>
        <Link to="/support/escalations">Escalations</Link>
      </nav>
      <Routes>
        <Route
          path="/"
          element={
            <div>
              <h2>Support home</h2>
              <p>Use search tools for safe rider/driver summaries (no raw email; masked only).</p>
            </div>
          }
        />
        <Route path="/search-ride" element={<SearchRidePage />} />
        <Route path="/search-user" element={<SearchUserPage />} />
        <Route path="/tickets" element={<TicketsPage />} />
        <Route path="/refunds" element={<RefundsPage />} />
        <Route path="/escalations" element={<EscalationsPage />} />
      </Routes>
    </div>
  );
}
