import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../dispatch_fleet_account_gate.dart';
import '../dispatch_fleet_routes.dart';
import '../dispatch_fleet_support.dart';

class DispatchFleetRejectedScreen extends StatefulWidget {
  const DispatchFleetRejectedScreen({super.key});

  @override
  State<DispatchFleetRejectedScreen> createState() =>
      _DispatchFleetRejectedScreenState();
}

class _DispatchFleetRejectedScreenState extends State<DispatchFleetRejectedScreen> {
  Map<String, dynamic>? _account;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is Map) {
        final response = args.map((k, v) => MapEntry(k.toString(), v));
        setState(() {
          _account = dfAccountMap(response);
        });
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
    final reason = account?['rejection_reason']?.toString().trim();
    final businessName = account?['business_name']?.toString() ?? 'Fleet business';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Application not approved'),
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
                  Icons.cancel_outlined,
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
                  'Your Dispatch Fleet application was not approved. '
                  'Contact NexRide Support if you believe this is a mistake.',
                  textAlign: TextAlign.center,
                ),
                if (reason != null && reason.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(reason),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                const DispatchFleetSupportSection(
                  subject: 'Dispatch Fleet application rejected',
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: _logout,
                  child: const Text('Log out'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
