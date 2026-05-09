/** Marketing copy for public NexRide pages (replace contact details for your deployment). */

export const SITE = {
  contactEmail: "info@nexride.africa",
  contactPhone: "+234 (0) 000 000 0000",
};

export const COPY = {
  about: `NexRide connects riders with vetted drivers in your city. Trips are matched and settled through our backend so fares, payments, and driver offers stay consistent and auditable. We focus on reliability, clear pricing, and support when something goes wrong.`,
  safety: `Safety is built into our operations: backend-controlled ride states, verified payments for card trips, and tools for riders and drivers to report issues. In an emergency, use local emergency services first, then in-app support. We review incidents with context from trip data (not public tracking links).`,
  drivers: `Drive on NexRide with transparent earnings, in-app trip flow, and wallet payouts after admin-approved withdrawals. You accept trips only through the official driver app using secured actions—no manual tampering with trip status in the database.`,
  riders: `Request rides through the NexRide rider app. Your trip is created on the server, matched to a driver, and paid securely when you use card checkout (Flutterwave). Cash and bank-transfer modes follow the same lifecycle rules in the app.`,
  pricing: `Fares depend on distance, time, and local market rules shown before you confirm a trip. Platform and payment fees, if any, are disclosed at checkout. Surge or promotions will appear clearly in the rider app when applicable.`,
  contact: `Reach the NexRide team at ${SITE.contactEmail} or ${SITE.contactPhone}. For trip issues, use in-app support so we can reference your ride securely.`,
  terms: `These Terms of Use govern access to NexRide mobile applications, websites, and related services in Nigeria. By creating an account or taking a trip you agree to comply with these terms, applicable law, and our driver and rider conduct standards. NexRide may suspend or terminate access where required for safety, fraud prevention, or regulatory compliance. Liability is limited to the fullest extent permitted by law. For the latest version or questions, contact ${SITE.contactEmail}.`,
  privacy: `NexRide processes personal data necessary to operate rides, payments (including card processing through our payment partners), support, and safety. We minimize data on public trip links: shared tracking shows only coarse pickup and destination areas, first name, vehicle summary, and trip status—never your full phone number or email. You may request account or data inquiries through ${SITE.contactEmail}. We retain information as needed for legal, tax, and dispute resolution purposes in line with the Nigeria Data Protection Act and good industry practice.`,
};
