/// Offline-safe policy copy (placeholders — TODO for counsel review).
class RiderPolicyText {
  RiderPolicyText._();

  static const String contactEmail = 'privacy@nexride.africa';

  static const String termsOfService = '''
NexRide — Terms of Service (Rider)

Last updated: placeholder — TODO: lawyer review before production.

1. The NexRide platform connects riders with independent drivers. NexRide is not a carrier.

2. Governing law — These Terms are governed by the laws of the Federal Republic of Nigeria.

3. Disputes — You agree that courts located in Lagos State, Nigeria have jurisdiction over disputes arising from these Terms or your use of the app, subject to any mandatory consumer protections.

4. Nigeria Data Protection Commission (NDPC) — We process personal data in line with applicable Nigerian law. See our Privacy Policy for details, lawful bases, and your rights.

5. Consumer protection — We aim to comply with the Consumer Protection Act and related regulations applicable to digital marketplace services in Nigeria. Nothing in these Terms limits non-waivable statutory rights.

6. Payments (CBN regulations) — Card and bank transfers may be processed by licensed payment partners. You authorize charges you initiate in-app. Failed or reversed payments may affect trip access.

7. Ride cancellation by rider — You may cancel a requested ride within two (2) minutes of placement at no charge where the driver has not yet been assigned; after assignment or after two minutes, fees or penalties described in-app may apply.

8. Surge / dynamic pricing — Fares may vary based on demand, distance, time, and city rules. You will see the fare before you confirm a trip.

9. Driver screening — Drivers are subject to background checks and platform rules as described in our policies. Screening reduces but cannot eliminate all risks.

10. Conduct — You agree to follow our Community Guidelines and applicable law.

TODO: Replace with final counsel-approved Terms.
''';

  static String get privacyPolicy => '''
NexRide — Privacy Policy (Rider)

Last updated: placeholder — TODO: lawyer review before production.

Contact: $contactEmail

1. Data we collect — Name, phone number, email address, live and historical location for trips, trip history, in-app messages, payment method metadata (via payment processors), device information, and a one-time selfie for identity verification when required.

2. Where data is stored — Data is processed using Google Firebase and other subprocessors. Servers may be located outside Nigeria; we apply appropriate safeguards as required by law.

3. Lawful basis (NDPC / Article 2.1 context) — We rely on contract (providing rides), consent (marketing/optional features where applicable), legal obligation, and legitimate interests (fraud prevention, safety), assessed in line with Nigerian data protection requirements.

4. Your rights — You may request access, correction, or deletion of your personal data where applicable. Email $contactEmail to exercise rights.

5. Retention — Trip and related records are typically retained for two (2) years for safety, disputes, and regulatory needs, unless a longer period is required by law.

6. Children — The service is not intended for users under 18.

TODO: Replace with final counsel-approved Privacy Policy.
''';

  static const String communityGuidelines = '''
NexRide — Community Guidelines

Last updated: placeholder — TODO: lawyer review before production.

1. Respect — No harassment, discrimination, threats, or abusive behaviour toward drivers, riders, or support staff.

2. Honest use — Do not create fraudulent ride or delivery requests or misuse promotions.

3. Accurate pickup — Set pickup and drop-off locations accurately to keep drivers and other road users safe.

4. Legal use — Do not use NexRide to arrange illegal transportation, contraband, or unlawful activity.

5. Enforcement — Violations may lead to warnings, temporary suspension, or permanent account termination.

TODO: Replace with final counsel-approved Community Guidelines.
''';
}
