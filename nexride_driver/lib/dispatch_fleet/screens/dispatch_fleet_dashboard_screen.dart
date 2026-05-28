import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../dispatch_fleet_account_gate.dart';
import '../dispatch_fleet_functions.dart';
import '../dispatch_fleet_routes.dart';
import '../dispatch_fleet_support.dart';

class DispatchFleetDashboardScreen extends StatefulWidget {
  const DispatchFleetDashboardScreen({super.key});

  @override
  State<DispatchFleetDashboardScreen> createState() =>
      _DispatchFleetDashboardScreenState();
}

class _DispatchFleetDashboardScreenState extends State<DispatchFleetDashboardScreen> {
  final DispatchFleetFunctions _fleet = DispatchFleetFunctions();

  Map<String, dynamic>? _account;
  int _totalLinked = 0;
  int _activeLinked = 0;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshOnce());
  }

  Future<void> _refreshOnce() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (!mounted) {
        return;
      }
      await Navigator.of(context).pushReplacementNamed(DispatchFleetRoutes.login);
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final accountRes = await _fleet.dispatchFleetGetMyAccount();
      if (!mounted) {
        return;
      }
      final dest = destinationForFleetAccountResponse(accountRes);
      if (dest != DispatchFleetAccountDestination.dashboard) {
        final route = switch (dest) {
          DispatchFleetAccountDestination.rejected => DispatchFleetRoutes.rejected,
          DispatchFleetAccountDestination.suspended => DispatchFleetRoutes.suspended,
          DispatchFleetAccountDestination.signup => DispatchFleetRoutes.signup,
          _ => DispatchFleetRoutes.pending,
        };
        await Navigator.of(context).pushNamedAndRemoveUntil(
          route,
          (Route<dynamic> route) => false,
          arguments: accountRes,
        );
        return;
      }

      final listRes = await _fleet.fleetListLinkedDriversPage(
        limit: 1,
        includeSummary: true,
      );
      if (!mounted) {
        return;
      }

      final summary = listRes['summary'];
      var total = 0;
      var active = 0;
      if (summary is Map) {
        total = int.tryParse(summary['total_linked_bikers']?.toString() ?? '') ?? 0;
        active = int.tryParse(summary['active_linked_bikers']?.toString() ?? '') ?? 0;
      }

      setState(() {
        _account = dfAccountMap(accountRes);
        _totalLinked = total;
        _activeLinked = active;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = 'Could not load dashboard. Pull to refresh or try again.';
      });
    }
  }

  Future<void> _logout() async {
    await FirebaseAuth.instance.signOut();
    if (!mounted) {
      return;
    }
    await Navigator.of(context).pushNamedAndRemoveUntil(
      DispatchFleetRoutes.root,
      (Route<dynamic> route) => false,
    );
  }

  String get _businessName =>
      _account?['business_name']?.toString().trim().isNotEmpty == true
          ? _account!['business_name'].toString()
          : 'Your fleet business';

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Fleet Dashboard'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _refreshOnce,
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: 'Sign out',
            onPressed: _logout,
            icon: const Icon(Icons.logout_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshOnce,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(20),
          children: <Widget>[
            Text(
              _businessName,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: 6),
            Text(
              'Manage linked dispatch riders and invites.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.black.withValues(alpha: 0.65),
                  ),
            ),
            const SizedBox(height: 24),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...<Widget>[
              if (_error != null) ...<Widget>[
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                const SizedBox(height: 16),
              ],
              Row(
                children: <Widget>[
                  Expanded(
                    child: _StatCard(
                      label: 'Total linked bikers',
                      value: '$_totalLinked',
                      icon: Icons.two_wheeler_outlined,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _StatCard(
                      label: 'Active linked bikers',
                      value: '$_activeLinked',
                      icon: Icons.verified_user_outlined,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Text(
                'Quick actions',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(height: 12),
              _ActionTile(
                icon: Icons.qr_code_2_outlined,
                title: 'Create Invite',
                subtitle: 'Generate a code for a dispatch rider to link.',
                onTap: () => Navigator.of(context).pushNamed(DispatchFleetRoutes.invites),
              ),
              _ActionTile(
                icon: Icons.people_outline,
                title: 'View Bikers',
                subtitle: 'See riders linked to your fleet business.',
                onTap: () => Navigator.of(context).pushNamed(DispatchFleetRoutes.bikers),
              ),
              _ActionTile(
                icon: Icons.upload_file_outlined,
                title: 'Upload Documents',
                subtitle: 'Submit or update fleet verification documents.',
                onTap: () async {
                  final response = await _fleet.dispatchFleetGetMyAccount();
                  if (!context.mounted) {
                    return;
                  }
                  await Navigator.of(context).pushNamed(
                    DispatchFleetRoutes.pending,
                    arguments: response,
                  );
                },
              ),
              const SizedBox(height: 24),
              const DispatchFleetSupportSection(
                subject: 'Dispatch Fleet dashboard support',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(icon, size: 22),
            const SizedBox(height: 12),
            Text(
              value,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.black.withValues(alpha: 0.62),
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: Icon(icon),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: onTap,
      ),
    );
  }
}
