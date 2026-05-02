import { Link, Navigate, Route, Routes } from "react-router-dom";
import { COPY } from "./content/siteCopy";
import { HomePage } from "./pages/HomePage";
import { StaticPage } from "./pages/StaticPage";
import { TrackRidePage } from "./pages/TrackRidePage";
import { AdminShell } from "./pages/admin/AdminShell";
import { SupportShell } from "./pages/support/SupportShell";

function Layout({ children }: { children: React.ReactNode }) {
  return (
    <div style={{ fontFamily: "system-ui,sans-serif", maxWidth: 900, margin: "0 auto", padding: 24 }}>
      <header style={{ marginBottom: 24 }}>
        <strong>NexRide</strong>
        <nav style={{ marginTop: 12, display: "flex", gap: 16, flexWrap: "wrap" }}>
          <Link to="/">Home</Link>
          <Link to="/about">About</Link>
          <Link to="/safety">Safety</Link>
          <Link to="/drivers">Drivers</Link>
          <Link to="/riders">Riders</Link>
          <Link to="/pricing">Pricing</Link>
          <Link to="/contact">Contact</Link>
          <Link to="/terms">Terms</Link>
          <Link to="/privacy">Privacy</Link>
          <Link to="/support">Support</Link>
          <Link to="/track/sample_token">Track ride</Link>
          <Link to="/admin">Admin</Link>
        </nav>
      </header>
      <main>{children}</main>
    </div>
  );
}

export function App() {
  return (
    <Layout>
      <Routes>
        <Route path="/" element={<HomePage />} />
        <Route path="/about" element={<StaticPage title="About" body={COPY.about} />} />
        <Route path="/safety" element={<StaticPage title="Safety" body={COPY.safety} />} />
        <Route path="/drivers" element={<StaticPage title="Drivers" body={COPY.drivers} />} />
        <Route path="/riders" element={<StaticPage title="Riders" body={COPY.riders} />} />
        <Route path="/pricing" element={<StaticPage title="Pricing" body={COPY.pricing} />} />
        <Route path="/contact" element={<StaticPage title="Contact" body={COPY.contact} />} />
        <Route path="/terms" element={<StaticPage title="Terms" body={COPY.terms} />} />
        <Route path="/privacy" element={<StaticPage title="Privacy" body={COPY.privacy} />} />
        <Route path="/track/:token" element={<TrackRidePage />} />
        <Route path="/admin/*" element={<AdminShell />} />
        <Route path="/support/*" element={<SupportShell />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </Layout>
  );
}
