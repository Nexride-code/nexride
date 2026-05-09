import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../site_content.dart';
import '../widgets/narrow_content.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Hero(scheme: scheme, text: text),
          _Section(
            title: 'Why NexRide',
            child: Text(
              'NexRide Africa connects riders and vetted drivers with dispatch built for Lagos traffic, '
              'clear fares, and card or bank-friendly payments. One platform for riders, drivers, and operations.',
              style: text.bodyLarge?.copyWith(height: 1.55),
            ),
          ),
          _FeatureGrid(scheme: scheme, text: text),
          _Section(
            title: 'Real-time tracking',
            child: Text(
              'Share a secure link so friends or colleagues can follow pickup, live movement, and trip status — '
              'without exposing private account details.',
              style: text.bodyLarge?.copyWith(height: 1.55),
            ),
          ),
          _Section(
            title: 'Secure payments',
            child: Text(
              'Card checkout via trusted partners, plus workflows for bank transfer trips with receipt capture where enabled.',
              style: text.bodyLarge?.copyWith(height: 1.55),
            ),
          ),
          _Section(
            title: 'Bank transfer support',
            child: Text(
              'Where bank transfer is offered, riders can complete trips with guided proof-of-payment steps so support can reconcile faster.',
              style: text.bodyLarge?.copyWith(height: 1.55),
            ),
          ),
          _Section(
            title: 'Driver onboarding',
            child: Text(
              'Drivers join through structured verification, vehicle checks, and in-app training touchpoints — '
              'designed for compliance and road safety.',
              style: text.bodyLarge?.copyWith(height: 1.55),
            ),
          ),
          _Section(
            title: 'Customer support',
            child: Text(
              'Reach our team at ${SiteContent.supportEmail} for account or trip help. '
              'For partnerships and press, use ${SiteContent.infoEmail}.',
              style: text.bodyLarge?.copyWith(height: 1.55),
            ),
          ),
          _DownloadCta(scheme: scheme, text: text),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.scheme, required this.text});

  final ColorScheme scheme;
  final TextTheme text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.primaryContainer.withValues(alpha: 0.35),
            scheme.surface,
          ],
        ),
      ),
      child: NarrowContent(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            Text(
              'City mobility,\nengineered for Africa.',
              style: text.displaySmall?.copyWith(
                fontWeight: FontWeight.w900,
                height: 1.05,
                letterSpacing: -1,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'NexRide Africa — ride hailing, dispatch, rider app, and driver app on one secure platform.',
              style: text.titleMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 28),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: () => context.go('/rider'),
                  icon: const Icon(Icons.phone_android),
                  label: const Text('Rider app'),
                ),
                FilledButton.tonalIcon(
                  onPressed: () => context.go('/driver'),
                  icon: const Icon(Icons.local_taxi),
                  label: const Text('Driver app'),
                ),
                OutlinedButton.icon(
                  onPressed: () => context.go('/contact'),
                  icon: const Icon(Icons.mail_outline),
                  label: const Text('Contact sales'),
                ),
              ],
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return NarrowContent(
      child: Padding(
        padding: const EdgeInsets.only(top: 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _FeatureGrid extends StatelessWidget {
  const _FeatureGrid({required this.scheme, required this.text});

  final ColorScheme scheme;
  final TextTheme text;

  @override
  Widget build(BuildContext context) {
    final items = <({IconData icon, String t, String d})>[
      (
        icon: Icons.bolt,
        t: 'Fast dispatch',
        d: 'Matching tuned for dense corridors and peak demand.',
      ),
      (
        icon: Icons.shield_outlined,
        t: 'Trust by design',
        d: 'Verification, trip history, and support workflows.',
      ),
      (
        icon: Icons.payments_outlined,
        t: 'Payments that fit',
        d: 'Cards where enabled, plus bank transfer paths.',
      ),
      (
        icon: Icons.map_outlined,
        t: 'Live visibility',
        d: 'Share-trip links with read-only map updates.',
      ),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 720;
        return NarrowContent(
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: wide ? 2 : 1,
              mainAxisSpacing: 14,
              crossAxisSpacing: 14,
              childAspectRatio: wide ? 1.55 : 1.35,
              children: [
                for (final it in items)
                  _FeatureCard(
                    scheme: scheme,
                    text: text,
                    icon: it.icon,
                    title: it.t,
                    body: it.d,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({
    required this.scheme,
    required this.text,
    required this.icon,
    required this.title,
    required this.body,
  });

  final ColorScheme scheme;
  final TextTheme text;
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: scheme.primary, size: 28),
            const SizedBox(height: 12),
            Text(title, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(body, style: text.bodyMedium?.copyWith(height: 1.45)),
          ],
        ),
      ),
    );
  }
}

class _DownloadCta extends StatelessWidget {
  const _DownloadCta({required this.scheme, required this.text});

  final ColorScheme scheme;
  final TextTheme text;

  @override
  Widget build(BuildContext context) {
    return NarrowContent(
      child: Card(
        elevation: 0,
        color: scheme.primary.withValues(alpha: 0.12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Download',
                style: text.titleLarge?.copyWith(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 8),
              Text(
                'Store listings go live with public launch. Until then, email ${SiteContent.infoEmail} for TestFlight / internal APK distribution.',
                style: text.bodyMedium?.copyWith(height: 1.5),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  FilledButton(
                    onPressed: () => context.go('/rider'),
                    child: const Text('Rider program'),
                  ),
                  FilledButton(
                    onPressed: () => context.go('/driver'),
                    child: const Text('Drive with NexRide'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
