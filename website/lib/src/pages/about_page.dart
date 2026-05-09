import 'package:flutter/material.dart';

import '../site_content.dart';
import '../widgets/narrow_content.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SingleChildScrollView(
      child: NarrowContent(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('About NexRide Africa', style: t.headlineMedium?.copyWith(fontWeight: FontWeight.w900)),
            const SizedBox(height: 16),
            Text(SiteContent.aboutLead, style: t.bodyLarge?.copyWith(height: 1.55)),
            const SizedBox(height: 20),
            Text(
              'We focus on dispatch reliability, honest ETAs, and driver economics — because sustainable '
              'mobility needs both sides of the marketplace to win.',
              style: t.bodyLarge?.copyWith(height: 1.55),
            ),
            const SizedBox(height: 20),
            Text(
              'Keywords: NexRide, NexRide Africa, ride hailing Africa, taxi booking, dispatch platform, '
              'driver app, rider app, Lagos mobility.',
              style: t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
