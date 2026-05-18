import 'package:flutter/material.dart';

import 'legal_contacts.dart';
import 'legal_models.dart';

/// Structured in-app legal library (counsel-review ready; no unverified regulatory claims).
abstract final class LegalPolicyCatalog {
  static final DateTime _updated = DateTime(2026, 5, 1);

  static List<LegalPolicyDocument> documentsFor(LegalAudience audience) {
    return allDocuments
        .where(
          (d) =>
              d.audiences.contains(audience) ||
              d.audiences.contains(LegalAudience.platform),
        )
        .toList();
  }

  static LegalPolicyDocument? byId(LegalPolicyId id) {
    for (final doc in allDocuments) {
      if (doc.id == id) {
        return doc;
      }
    }
    return null;
  }

  static final List<LegalPolicyDocument> allDocuments = <LegalPolicyDocument>[
    _termsOfService(),
    _privacyPolicy(),
    _communityGuidelines(),
    _riderSafety(),
    _driverStandards(),
    _merchantStandards(),
    _refundCancellation(),
    _surgePricing(),
    _dataProtectionNdpc(),
    _kycIdentity(),
    _emergencySos(),
    _fraudPrevention(),
    _accountSuspension(),
    _lawEnforcement(),
    _childSafety(),
    _prohibitedConduct(),
  ];

  static LegalPolicyDocument _termsOfService() {
    return LegalPolicyDocument(
      id: LegalPolicyId.termsOfService,
      title: 'Terms of Service',
      summary:
          'Your agreement with NexRide when using rides, deliveries, and related services in Nigeria.',
      group: LegalPolicyGroup.coreAgreements,
      audiences: {LegalAudience.rider, LegalAudience.driver, LegalAudience.merchant},
      icon: Icons.description_outlined,
      lastUpdated: _updated,
      versionKey: 'terms',
      requiresAcceptance: true,
      externalUrl: 'https://nexride.africa/terms',
      sections: [
        _s(
          'Platform role',
          'NexRide provides a technology platform that connects riders, independent driver partners, and merchant partners. '
          'NexRide is not a motor carrier, employer of drivers, or seller of merchant goods unless expressly stated for a specific product.',
          icon: Icons.hub_outlined,
        ),
        _s(
          'Operating areas',
          'Services may be offered in cities and corridors where NexRide is live, including parts of Lagos State and the Federal Capital Territory (Abuja), '
          'and may expand to other Nigerian locations. Availability, vehicle categories, and features can vary by city.',
          icon: Icons.location_city_outlined,
          keywords: ['Lagos', 'Abuja', 'FCT'],
        ),
        _s(
          'Governing law & disputes',
          'These Terms are governed by the laws of the Federal Republic of Nigeria. '
          'Disputes should first be raised with ${LegalContacts.support}. '
          'Where permitted by law, courts in Lagos State may have jurisdiction, without limiting mandatory consumer protections.',
          icon: Icons.balance_outlined,
        ),
        _s(
          'Consumer protection',
          'NexRide aims to operate fairly and transparently in line with applicable Nigerian consumer protection rules for digital marketplace services. '
          'Nothing here limits non-waivable rights you may have under law.',
          icon: Icons.verified_user_outlined,
        ),
        _s(
          'Payments (CBN-regulated partners)',
          'In-app payments are processed by licensed payment partners in line with Central Bank of Nigeria (CBN) regulations. '
          'You authorise charges you confirm in the app. Failed, reversed, or disputed payments may affect trip or order access.',
          icon: Icons.account_balance_outlined,
          keywords: ['CBN', 'card', 'bank'],
        ),
        _s(
          'Changes to these Terms',
          'We may update these Terms when our services or legal requirements change. '
          'Material updates may require renewed acceptance in the app. Version identifiers are shown in Legal & Trust.',
          icon: Icons.update_outlined,
        ),
      ],
    );
  }

  static LegalPolicyDocument _privacyPolicy() {
    return LegalPolicyDocument(
      id: LegalPolicyId.privacyPolicy,
      title: 'Privacy Policy',
      summary: 'How NexRide collects, uses, stores, and shares personal data.',
      group: LegalPolicyGroup.coreAgreements,
      audiences: {LegalAudience.rider, LegalAudience.driver, LegalAudience.merchant},
      icon: Icons.privacy_tip_outlined,
      lastUpdated: _updated,
      versionKey: 'privacy',
      requiresAcceptance: true,
      externalUrl: 'https://nexride.africa/privacy',
      sections: [
        _s(
          'Data we collect',
          'Depending on how you use NexRide, we may process: name, phone number, email, profile photo or selfie for verification, '
          'live and historical location for trips and deliveries, trip/order history, in-app messages, device identifiers, '
          'and payment metadata handled by payment processors (not full card numbers stored by NexRide).',
          icon: Icons.fact_check_outlined,
        ),
        _s(
          'Why we use data',
          'We use personal data to provide and improve the service, support safety, prevent fraud, comply with law, and respond to support requests. '
          'Marketing messages, where sent, will rely on appropriate consent or lawful basis under Nigerian law.',
          icon: Icons.settings_suggest_outlined,
        ),
        _s(
          'Storage & subprocessors',
          'Data may be processed using cloud infrastructure (including Google Firebase) and vetted subprocessors. '
          'Servers may be located outside Nigeria; we apply safeguards appropriate to cross-border transfers as required by applicable law.',
          icon: Icons.cloud_outlined,
        ),
        _s(
          'Your rights',
          'You may request access, correction, or deletion of personal data where applicable. Contact ${LegalContacts.privacy} '
          'to exercise privacy rights. We may need to verify your identity before responding.',
          icon: Icons.mail_outline,
        ),
        _s(
          'Retention',
          'Trip, safety, and financial records are retained for periods needed for operations, disputes, and legal obligations—'
          'often up to twenty-four (24) months unless a longer period is required.',
          icon: Icons.schedule_outlined,
        ),
        _s(
          'Contact',
          'Privacy questions: ${LegalContacts.privacy} · General support: ${LegalContacts.support}',
          icon: Icons.contact_mail_outlined,
        ),
      ],
    );
  }

  static LegalPolicyDocument _communityGuidelines() {
    return LegalPolicyDocument(
      id: LegalPolicyId.communityGuidelines,
      title: 'Community Guidelines',
      summary: 'Standards of respect and lawful use for everyone on NexRide.',
      group: LegalPolicyGroup.coreAgreements,
      audiences: {LegalAudience.rider, LegalAudience.driver, LegalAudience.merchant, LegalAudience.platform},
      icon: Icons.groups_outlined,
      lastUpdated: _updated,
      versionKey: 'guidelines',
      requiresAcceptance: true,
      sections: [
        _s('Respect', 'No harassment, hate speech, threats, discrimination, or abusive behaviour toward riders, drivers, merchants, or staff.', icon: Icons.favorite_border),
        _s('Honest use', 'Do not create fraudulent trips or orders, abuse promotions, or misrepresent identity.', icon: Icons.shield_outlined),
        _s('Accurate locations', 'Set pickup and drop-off points accurately to keep partners and road users safe.', icon: Icons.pin_drop_outlined),
        _s('Lawful activity', 'Do not use NexRide for illegal transport, contraband, or unlawful goods.', icon: Icons.gavel_outlined),
        _s('Enforcement', 'Violations may lead to warnings, temporary restrictions, or permanent account removal.', icon: Icons.block_outlined),
      ],
    );
  }

  static LegalPolicyDocument _riderSafety() {
    return LegalPolicyDocument(
      id: LegalPolicyId.riderSafety,
      title: 'Rider Safety',
      summary: 'Practical safety expectations for riders across Nigeria.',
      group: LegalPolicyGroup.safetyConduct,
      audiences: {LegalAudience.rider},
      icon: Icons.health_and_safety_outlined,
      lastUpdated: _updated,
      sections: [
        _s('Before you ride', 'Verify vehicle and driver details shown in the app match the arriving partner. Share trip status with trusted contacts when needed.', icon: Icons.directions_car_outlined),
        _s('During the trip', 'Wear seat belts where available. Follow local traffic rules. Report unsafe driving immediately via in-app support or ${LegalContacts.safety}.', icon: Icons.warning_amber_outlined),
        _s('Night & cash trips', 'Prefer well-lit pickup points. Review fare estimates before confirming. Keep personal belongings secure.', icon: Icons.nightlight_outlined),
        _s('Incidents', 'For emergencies, contact local emergency services first, then NexRide Safety at ${LegalContacts.safety} with trip details.', icon: Icons.emergency_outlined),
      ],
    );
  }

  static LegalPolicyDocument _driverStandards() {
    return LegalPolicyDocument(
      id: LegalPolicyId.driverStandards,
      title: 'Driver Partner Standards',
      summary: 'Operational and conduct standards for independent driver partners.',
      group: LegalPolicyGroup.platformRoles,
      audiences: {LegalAudience.driver},
      icon: Icons.local_taxi_outlined,
      lastUpdated: _updated,
      sections: [
        _s('Licence & vehicle', 'Drivers must hold valid licences and permits required for their vehicle class and city of operation.', icon: Icons.badge_outlined),
        _s('Professional conduct', 'Courteous communication, safe driving, and compliance with NexRide dispatch and cancellation rules.', icon: Icons.thumb_up_outlined),
        _s('Identity checks', 'Drivers may be asked to complete identity and vehicle verification steps before going online.', icon: Icons.verified_outlined),
        _s('Quality & removal', 'Repeated safety complaints, fraud, or policy breaches may lead to temporary or permanent deactivation.', icon: Icons.flag_outlined),
      ],
    );
  }

  static LegalPolicyDocument _merchantStandards() {
    return LegalPolicyDocument(
      id: LegalPolicyId.merchantStandards,
      title: 'Merchant Partner Standards',
      summary: 'Food and retail partners on NexRide delivery.',
      group: LegalPolicyGroup.platformRoles,
      audiences: {LegalAudience.merchant},
      icon: Icons.storefront_outlined,
      lastUpdated: _updated,
      sections: [
        _s('Accurate listings', 'Menus, prices, and item availability should be kept current.', icon: Icons.menu_book_outlined),
        _s('Food safety', 'Merchants are responsible for hygienic preparation and packaging consistent with local regulations.', icon: Icons.restaurant_outlined),
        _s('Order fulfilment', 'Prepare orders within stated times; communicate delays through merchant tools where available.', icon: Icons.timer_outlined),
        _s('Payouts', 'Settlement timelines and fees are defined in merchant onboarding materials and may vary by agreement.', icon: Icons.payments_outlined),
      ],
    );
  }

  static LegalPolicyDocument _refundCancellation() {
    return LegalPolicyDocument(
      id: LegalPolicyId.refundCancellation,
      title: 'Refunds & Cancellation',
      summary: 'How cancellations, no-shows, and refunds may be handled.',
      group: LegalPolicyGroup.paymentsPricing,
      audiences: {LegalAudience.rider, LegalAudience.driver},
      icon: Icons.receipt_long_outlined,
      lastUpdated: _updated,
      sections: [
        _s('Rider cancellation window', 'Where shown in-app, riders may cancel within two (2) minutes of requesting a trip before a driver is assigned without a fee.', icon: Icons.timer_off_outlined),
        _s('After assignment', 'Cancellations after driver assignment or outside the free window may incur fees shown before you confirm.', icon: Icons.cancel_outlined),
        _s('Refunds', 'Eligible refunds are returned through the original payment method where possible. Processing times depend on banks and payment partners.', icon: Icons.currency_exchange_outlined),
        _s('Disputes', 'Contact ${LegalContacts.support} with trip ID and details. NexRide may review GPS, chat, and status logs where available.', icon: Icons.support_agent_outlined),
      ],
    );
  }

  static LegalPolicyDocument _surgePricing() {
    return LegalPolicyDocument(
      id: LegalPolicyId.surgePricing,
      title: 'Surge & Dynamic Pricing',
      summary: 'Transparency on fares that change with demand and conditions.',
      group: LegalPolicyGroup.paymentsPricing,
      audiences: {LegalAudience.rider, LegalAudience.driver},
      icon: Icons.trending_up_outlined,
      lastUpdated: _updated,
      sections: [
        _s('Estimate before you book', 'Fares are shown before you confirm a trip or delivery. Surge or dynamic multipliers, when applied, appear in the estimate.', icon: Icons.price_check_outlined),
        _s('Factors', 'Pricing may reflect demand, distance, time, traffic, city rules, and promotional discounts.', icon: Icons.insights_outlined),
        _s('No hidden confirmation', 'You will not be charged for a standard ride until you confirm the request at the displayed price (subject to route changes disclosed in-app).', icon: Icons.check_circle_outline),
      ],
    );
  }

  static LegalPolicyDocument _dataProtectionNdpc() {
    return LegalPolicyDocument(
      id: LegalPolicyId.dataProtectionNdpc,
      title: 'Data Protection (NDPC)',
      summary: 'Nigeria-focused data protection information.',
      group: LegalPolicyGroup.privacyData,
      audiences: {LegalAudience.platform},
      icon: Icons.security_outlined,
      lastUpdated: _updated,
      sections: [
        _s('Nigerian framework', 'NexRide processes personal data in line with the Nigeria Data Protection Act 2023 and applicable NDPC guidance.', icon: Icons.policy_outlined, keywords: ['NDPC', 'NDPA']),
        _s('Lawful processing', 'We document purposes such as contract performance, consent (where required), legal obligation, and legitimate interests assessed for each processing activity.', icon: Icons.rule_folder_outlined),
        _s('DPIA & vendors', 'High-risk processing may be reviewed internally; subprocessors are bound by data protection terms appropriate to their role.', icon: Icons.fact_check_outlined),
        _s('Complaints', 'Contact ${LegalContacts.privacy} first. You may also refer complaints to the Nigeria Data Protection Commission where applicable.', icon: Icons.report_outlined),
      ],
    );
  }

  static LegalPolicyDocument _kycIdentity() {
    return LegalPolicyDocument(
      id: LegalPolicyId.kycIdentity,
      title: 'KYC & Identity Verification',
      summary: 'When and why NexRide may verify your identity.',
      group: LegalPolicyGroup.trustIdentity,
      audiences: {LegalAudience.rider, LegalAudience.driver},
      icon: Icons.face_retouching_natural_outlined,
      lastUpdated: _updated,
      sections: [
        _s('When required', 'Verification may be requested for first-time booking, high-risk signals, regulatory needs, or account recovery.', icon: Icons.assignment_ind_outlined),
        _s('What you provide', 'This may include a selfie, government ID (such as NIN or BVN where supported), and liveness checks via approved providers.', icon: Icons.document_scanner_outlined),
        _s('Review', 'Automated and human review may apply. Outcomes include approval, rejection with reason, or request for resubmission.', icon: Icons.rate_review_outlined),
        _s('Data handling', 'Verification media is stored securely and accessed only for fraud prevention, safety, and compliance.', icon: Icons.lock_outline),
      ],
    );
  }

  static LegalPolicyDocument _emergencySos() {
    return LegalPolicyDocument(
      id: LegalPolicyId.emergencySos,
      title: 'Emergency & SOS',
      summary: 'What to do in an emergency during a NexRide trip.',
      group: LegalPolicyGroup.safetyConduct,
      audiences: {LegalAudience.rider, LegalAudience.driver},
      icon: Icons.sos_outlined,
      lastUpdated: _updated,
      sections: [
        _s('Call emergency services first', 'In immediate danger, contact Nigerian emergency services (e.g. 112 / 767 / 199) before contacting NexRide.', icon: Icons.phone_in_talk_outlined),
        _s('NexRide Safety', 'Email ${LegalContacts.safety} with trip ID, city, and description. In-app SOS tools may be rolled out by city.', icon: Icons.mark_email_read_outlined),
        _s('Aftercare', 'We may follow up for safety documentation. We cooperate with authorities when legally required.', icon: Icons.support_outlined),
      ],
    );
  }

  static LegalPolicyDocument _fraudPrevention() {
    return LegalPolicyDocument(
      id: LegalPolicyId.fraudPrevention,
      title: 'Fraud Prevention',
      summary: 'How NexRide detects and responds to misuse.',
      group: LegalPolicyGroup.trustIdentity,
      audiences: {LegalAudience.platform},
      icon: Icons.phishing_outlined,
      lastUpdated: _updated,
      sections: [
        _s('Signals', 'We may analyse device, payment, location, and behaviour patterns to detect promo abuse, fake trips, and account takeover.', icon: Icons.analytics_outlined),
        _s('Actions', 'Accounts may be challenged with extra verification, temporarily frozen, or permanently removed.', icon: Icons.pause_circle_outline),
        _s('Reporting', 'Report suspected fraud to ${LegalContacts.support} with evidence where available.', icon: Icons.report_gmailerrorred_outlined),
      ],
    );
  }

  static LegalPolicyDocument _accountSuspension() {
    return LegalPolicyDocument(
      id: LegalPolicyId.accountSuspension,
      title: 'Account Suspension',
      summary: 'When access may be limited or ended.',
      group: LegalPolicyGroup.trustIdentity,
      audiences: {LegalAudience.platform},
      icon: Icons.no_accounts_outlined,
      lastUpdated: _updated,
      sections: [
        _s('Reasons', 'Safety incidents, payment abuse, repeated cancellations, guideline violations, or legal requests.', icon: Icons.list_alt_outlined),
        _s('Notice', 'Where practicable, we notify you in-app or by email with a summary reason.', icon: Icons.notifications_outlined),
        _s('Appeals', 'Contact ${LegalContacts.support} within the timeframe stated in your notice. Not all decisions are appealable.', icon: Icons.question_answer_outlined),
      ],
    );
  }

  static LegalPolicyDocument _lawEnforcement() {
    return LegalPolicyDocument(
      id: LegalPolicyId.lawEnforcement,
      title: 'Law Enforcement Requests',
      summary: 'How NexRide handles valid legal requests.',
      group: LegalPolicyGroup.privacyData,
      audiences: {LegalAudience.platform},
      icon: Icons.policy_outlined,
      lastUpdated: _updated,
      sections: [
        _s('Valid process', 'We respond to court orders, subpoenas, and lawful requests from Nigerian authorities consistent with applicable law.', icon: Icons.gavel_outlined),
        _s('Emergency disclosure', 'We may disclose information without delay when necessary to prevent imminent harm, as permitted by law.', icon: Icons.emergency_share_outlined),
        _s('Contact', 'Law enforcement and regulatory enquiries: ${LegalContacts.privacy} (mark subject “Law enforcement”).', icon: Icons.mail_lock_outlined),
      ],
    );
  }

  static LegalPolicyDocument _childSafety() {
    return LegalPolicyDocument(
      id: LegalPolicyId.childSafety,
      title: 'Child Safety & Minimum Age',
      summary: 'Age requirements and protection of minors.',
      group: LegalPolicyGroup.safetyConduct,
      audiences: {LegalAudience.platform},
      icon: Icons.child_care_outlined,
      lastUpdated: _updated,
      sections: [
        _s('Minimum age', 'NexRide accounts are intended for users aged eighteen (18) and above.', icon: Icons.cake_outlined),
        _s('Minors on trips', 'Adults must accompany minors and remain responsible for their conduct and safety.', icon: Icons.family_restroom_outlined),
        _s('Reporting', 'Report concerns involving minors to ${LegalContacts.safety}.', icon: Icons.report_outlined),
      ],
    );
  }

  static LegalPolicyDocument _prohibitedConduct() {
    return LegalPolicyDocument(
      id: LegalPolicyId.prohibitedConduct,
      title: 'Prohibited Conduct',
      summary: 'Activities that are not allowed on NexRide.',
      group: LegalPolicyGroup.safetyConduct,
      audiences: {LegalAudience.platform},
      icon: Icons.do_not_disturb_on_outlined,
      lastUpdated: _updated,
      sections: [
        _s('Violence & weapons', 'No violence, threats, or unauthorised weapons in vehicles or deliveries.', icon: Icons.dangerous_outlined),
        _s('Illegal goods', 'No transport of illegal drugs, stolen goods, or other contraband.', icon: Icons.inventory_2_outlined),
        _s('Discrimination', 'No refusal of service based on protected characteristics where prohibited by law.', icon: Icons.diversity_3_outlined),
        _s('Platform abuse', 'No scraping, reverse engineering, or interference with NexRide systems.', icon: Icons.bug_report_outlined),
      ],
    );
  }

  static LegalPolicySection _s(
    String title,
    String body, {
    IconData? icon,
    List<String> keywords = const <String>[],
  }) {
    return LegalPolicySection(
      title: title,
      body: body,
      icon: icon,
      keywords: keywords,
    );
  }
}
