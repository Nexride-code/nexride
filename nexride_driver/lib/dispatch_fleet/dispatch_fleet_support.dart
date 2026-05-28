import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../support/nexride_contact_constants.dart';

Future<void> openDispatchFleetSupportEmail({String? subject}) async {
  final uri = Uri(
    scheme: 'mailto',
    path: kNexRideSupportEmail,
    queryParameters: <String, String>{
      if (subject != null && subject.trim().isNotEmpty) 'subject': subject.trim(),
    },
  );
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri);
  }
}

class DispatchFleetSupportSection extends StatelessWidget {
  const DispatchFleetSupportSection({
    super.key,
    this.subject,
    this.compact = false,
  });

  final String? subject;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return TextButton.icon(
        onPressed: () => openDispatchFleetSupportEmail(subject: subject),
        icon: const Icon(Icons.mail_outline),
        label: const Text('Contact NexRide Support'),
      );
    }
    return OutlinedButton.icon(
      onPressed: () => openDispatchFleetSupportEmail(subject: subject),
      icon: const Icon(Icons.mail_outline),
      label: const Text('Contact NexRide Support'),
    );
  }
}
