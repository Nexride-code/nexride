import 'package:flutter/material.dart';

import '../site_content.dart';
import '../widgets/narrow_content.dart';

class LegalPrivacyPage extends StatelessWidget {
  const LegalPrivacyPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SingleChildScrollView(
      child: NarrowContent(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Privacy policy', style: t.headlineMedium?.copyWith(fontWeight: FontWeight.w900)),
            const SizedBox(height: 16),
            Text(SiteContent.privacyShort, style: t.bodyLarge?.copyWith(height: 1.55)),
            const SizedBox(height: 20),
            Text(
              'Controller contact: ${SiteContent.infoEmail}',
              style: t.titleSmall,
            ),
          ],
        ),
      ),
    );
  }
}
