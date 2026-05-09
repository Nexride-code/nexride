import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../site_content.dart';
import '../widgets/narrow_content.dart';

class DriverAppPage extends StatelessWidget {
  const DriverAppPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SingleChildScrollView(
      child: NarrowContent(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Driver app', style: t.headlineMedium?.copyWith(fontWeight: FontWeight.w900)),
            const SizedBox(height: 16),
            Text(
              'Accept offers, navigate trips, manage payouts, and stay compliant with verification and subscription flows.',
              style: t.bodyLarge?.copyWith(height: 1.55),
            ),
            const SizedBox(height: 20),
            Text(
              'Onboarding: ${SiteContent.supportEmail}',
              style: t.bodyLarge?.copyWith(height: 1.55),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => context.go('/contact'),
              child: const Text('Start driver onboarding'),
            ),
          ],
        ),
      ),
    );
  }
}
