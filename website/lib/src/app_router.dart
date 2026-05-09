import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'pages/about_page.dart';
import 'pages/contact_page.dart';
import 'pages/driver_app_page.dart';
import 'pages/home_page.dart';
import 'pages/legal_privacy_page.dart';
import 'pages/legal_terms_page.dart';
import 'pages/ride_legacy_redirect_page.dart';
import 'pages/rider_app_page.dart';
import 'pages/safety_page.dart';
import 'pages/trip_live_page.dart';
import 'widgets/site_footer.dart';
import 'web_title.dart';

GoRouter buildRouter() {
  return GoRouter(
    initialLocation: '/',
    errorBuilder: (context, state) => Scaffold(
      appBar: AppBar(title: const Text('Page not found')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('We could not find that page.'),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => context.go('/'),
                child: const Text('Back to home'),
              ),
            ],
          ),
        ),
      ),
    ),
    routes: <RouteBase>[
      ShellRoute(
        builder: (context, state, child) {
          setWebTitle(_titleForPath(state.uri.path));
          return SiteShell(location: state.uri.path, child: child);
        },
        routes: <GoRoute>[
          GoRoute(
            path: '/',
            builder: (_, __) => const HomePage(),
          ),
          GoRoute(
            path: '/about',
            builder: (_, __) => const AboutPage(),
          ),
          GoRoute(
            path: '/rider',
            builder: (_, __) => const RiderAppPage(),
          ),
          GoRoute(
            path: '/driver',
            builder: (_, __) => const DriverAppPage(),
          ),
          GoRoute(
            path: '/safety',
            builder: (_, __) => const SafetyPage(),
          ),
          GoRoute(
            path: '/contact',
            builder: (_, __) => const ContactPage(),
          ),
          GoRoute(
            path: '/privacy',
            builder: (_, __) => const LegalPrivacyPage(),
          ),
          GoRoute(
            path: '/terms',
            builder: (_, __) => const LegalTermsPage(),
          ),
        ],
      ),
      GoRoute(
        path: '/trip/:rideId',
        builder: (context, state) {
          setWebTitle('Live trip · NexRide');
          return TripLivePage(
            rideId: state.pathParameters['rideId'] ?? '',
            token: state.uri.queryParameters['token'] ?? '',
          );
        },
      ),
      GoRoute(
        path: '/ride',
        builder: (context, state) {
          return RideLegacyRedirectPage(
            rideId: state.uri.queryParameters['rideId'] ?? '',
            token: state.uri.queryParameters['token'] ?? '',
          );
        },
      ),
    ],
  );
}

String _titleForPath(String path) {
  switch (path) {
    case '/about':
      return 'About · NexRide Africa';
    case '/rider':
      return 'Rider app · NexRide Africa';
    case '/driver':
      return 'Driver app · NexRide Africa';
    case '/safety':
      return 'Safety · NexRide Africa';
    case '/contact':
      return 'Contact · NexRide Africa';
    case '/privacy':
      return 'Privacy · NexRide Africa';
    case '/terms':
      return 'Terms · NexRide Africa';
    default:
      return 'NexRide Africa — Ride hailing & dispatch';
  }
}

class SiteShell extends StatelessWidget {
  const SiteShell({
    super.key,
    required this.location,
    required this.child,
  });

  final String location;
  final Widget child;

  static const _links = <({String path, String label})>[
    (path: '/', label: 'Home'),
    (path: '/about', label: 'About'),
    (path: '/rider', label: 'Rider app'),
    (path: '/driver', label: 'Driver app'),
    (path: '/safety', label: 'Safety'),
    (path: '/contact', label: 'Contact'),
    (path: '/privacy', label: 'Privacy'),
    (path: '/terms', label: 'Terms'),
  ];

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final useRail = w >= 960;
    final scheme = Theme.of(context).colorScheme;

    if (useRail) {
      return Scaffold(
        body: Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  NavigationRail(
                    extended: w >= 1200,
                    backgroundColor:
                        scheme.surfaceContainerHighest.withValues(alpha: 0.35),
                    selectedIndex: _indexFor(location),
                    onDestinationSelected: (i) => context.go(_links[i].path),
                    labelType: w >= 1200
                        ? NavigationRailLabelType.all
                        : NavigationRailLabelType.selected,
                    leading: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 16, 8, 24),
                      child: _BrandMark(compact: w < 1200),
                    ),
                    destinations: [
                      for (final l in _links)
                        NavigationRailDestination(
                          icon: const Icon(Icons.circle_outlined, size: 18),
                          selectedIcon: Icon(Icons.circle, size: 18, color: scheme.primary),
                          label: Text(l.label),
                        ),
                    ],
                  ),
                  VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: scheme.outlineVariant,
                  ),
                  Expanded(child: child),
                ],
              ),
            ),
            const SiteFooter(compact: false),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const _BrandMark(compact: true),
        actions: [
          Builder(
            builder: (ctx) => IconButton(
              tooltip: 'Menu',
              onPressed: () => Scaffold.of(ctx).openDrawer(),
              icon: const Icon(Icons.menu_rounded),
            ),
          ),
        ],
      ),
      drawer: Drawer(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            const DrawerHeader(
              margin: EdgeInsets.zero,
              child: _BrandMark(compact: false),
            ),
            for (final l in _links)
              ListTile(
                selected: _normalize(location) == l.path,
                title: Text(l.label),
                onTap: () {
                  Navigator.pop(context);
                  context.go(l.path);
                },
              ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(child: child),
          const SiteFooter(compact: true),
        ],
      ),
    );
  }

  static int _indexFor(String loc) {
    final n = _normalize(loc);
    final i = _links.indexWhere((e) => e.path == n);
    return i < 0 ? 0 : i;
  }

  static String _normalize(String loc) {
    if (loc.isEmpty || loc == '/') return '/';
    return loc.endsWith('/') ? loc.substring(0, loc.length - 1) : loc;
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.asset(
            'assets/branding/nexride_app_icon.png',
            width: compact ? 36 : 44,
            height: compact ? 36 : 44,
            errorBuilder: (_, __, ___) => Icon(Icons.local_taxi_rounded, color: scheme.primary),
          ),
        ),
        if (!compact) const SizedBox(width: 12),
        if (!compact)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'NexRide',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                    ),
              ),
              Text(
                'Africa',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      letterSpacing: 2,
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                    ),
              ),
            ],
          ),
      ],
    );
  }
}
