import 'package:flutter/material.dart';

import '../site_content.dart';
import '../widgets/narrow_content.dart';

class SafetyPage extends StatelessWidget {
  const SafetyPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SingleChildScrollView(
      child: NarrowContent(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Safety', style: t.headlineMedium?.copyWith(fontWeight: FontWeight.w900)),
            const SizedBox(height: 16),
            Text(SiteContent.safetyLead, style: t.bodyLarge?.copyWith(height: 1.55)),
            const SizedBox(height: 16),
            Text(
              'In an emergency, contact local emergency services first. '
              'Use in-app support after the trip when you can reference your ride ID.',
              style: t.bodyLarge?.copyWith(height: 1.55),
            ),
            const SizedBox(height: 12),
            Text('Support: ${SiteContent.supportEmail}', style: t.titleMedium),
          ],
        ),
      ),
    );
  }
}
