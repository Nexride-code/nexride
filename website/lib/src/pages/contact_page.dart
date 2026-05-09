import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../site_content.dart';
import '../widgets/narrow_content.dart';

class ContactPage extends StatelessWidget {
  const ContactPage({super.key});

  Future<void> _mail(String email) async {
    final u = Uri.parse('mailto:$email');
    if (await canLaunchUrl(u)) {
      await launchUrl(u);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      child: NarrowContent(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Contact', style: t.headlineMedium?.copyWith(fontWeight: FontWeight.w900)),
            const SizedBox(height: 16),
            Text(
              'Operations & general: ${SiteContent.infoEmail}\n'
              'Support & trips: ${SiteContent.supportEmail}\n'
              'Administration: ${SiteContent.adminEmail}',
              style: t.bodyLarge?.copyWith(height: 1.6),
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton(
                  onPressed: () => _mail(SiteContent.infoEmail),
                  child: const Text('Email info'),
                ),
                FilledButton.tonal(
                  onPressed: () => _mail(SiteContent.supportEmail),
                  child: const Text('Email support'),
                ),
              ],
            ),
            const SizedBox(height: 32),
            Text('Web', style: t.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            SelectableText(SiteContent.domain, style: t.bodyLarge?.copyWith(color: scheme.primary)),
          ],
        ),
      ),
    );
  }
}
