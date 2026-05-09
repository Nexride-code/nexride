import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../site_content.dart';
import '../widgets/narrow_content.dart';

class RiderAppPage extends StatelessWidget {
  const RiderAppPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SingleChildScrollView(
      child: NarrowContent(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Rider app', style: t.headlineMedium?.copyWith(fontWeight: FontWeight.w900)),
            const SizedBox(height: 16),
            Text(
              'Book rides, track your driver, pay with card where enabled, and manage trip safety tools from one app.',
              style: t.bodyLarge?.copyWith(height: 1.55),
            ),
            const SizedBox(height: 20),
            Text(
              'Need access? Email ${SiteContent.infoEmail} with your city and phone number.',
              style: t.bodyLarge?.copyWith(height: 1.55),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => context.go('/contact'),
              child: const Text('Request rider access'),
            ),
          ],
        ),
      ),
    );
  }
}
