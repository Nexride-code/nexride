import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../dispatch_fleet_account_gate.dart';
import '../dispatch_fleet_routes.dart';
import '../dispatch_fleet_support.dart';

class DispatchFleetSuspendedScreen extends StatefulWidget {
  const DispatchFleetSuspendedScreen({super.key});

  @override
  State<DispatchFleetSuspendedScreen> createState() =>
      _DispatchFleetSuspendedScreenState();
}

class _DispatchFleetSuspendedScreenState extends State<DispatchFleetSuspendedScreen> {
  Map<String, dynamic>? _account;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is Map) {
        final response = args.map((k, v) => MapEntry(k.toString(), v));
        setState(() => _account = dfAccountMap(response));
      }
    });
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

  @override
  Widget build(BuildContext context) {
    final account = _account;
    final businessName = account?['business_name']?.toString() ?? 'Fleet business';
    final reason = account?['rejection_reason']?.toString().trim();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Account suspended'),
        actions: <Widget>[
          TextButton(onPressed: _logout, child: const Text('Log out')),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Icon(
                  Icons.pause_circle_outline,
                  size: 56,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  businessName,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Your Dispatch Fleet account is suspended. '
                  'You cannot create biker invites or access fleet invite tools until NexRide reinstates your account.',
                  textAlign: TextAlign.center,
                ),
                if (reason != null && reason.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('Note: $reason'),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                const DispatchFleetSupportSection(
                  subject: 'Dispatch Fleet account suspension',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
