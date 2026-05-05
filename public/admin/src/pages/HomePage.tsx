import { Link } from "react-router-dom";
import { SITE } from "../content/siteCopy";

export function HomePage() {
  return (
    <section>
      <h1>NexRide</h1>
      <p style={{ fontSize: "1.1rem", lineHeight: 1.5 }}>
        Reliable rides with backend-controlled matching, transparent fares, and secure payments. Drivers and riders use
        dedicated apps; trip state and payouts are enforced on the server—not by editing the database from clients.
      </p>
      <ul style={{ lineHeight: 1.7 }}>
        <li>
          <Link to="/riders">Riders</Link> — request trips, pay with Flutterwave when you choose card checkout.
        </li>
        <li>
          <Link to="/drivers">Drivers</Link> — accept offers, run trips, track wallet and withdrawals.
        </li>
        <li>
          <Link to="/safety">Safety</Link> — how we think about incidents and data exposure (including public tracking).
        </li>
        <li>
          <Link to="/pricing">Pricing</Link> — what goes into a fare.
        </li>
      </ul>
      <p>
        <strong>Contact:</strong> {SITE.contactEmail}
      </p>
    </section>
  );
}
