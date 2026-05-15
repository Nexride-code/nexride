import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../merchant_portal_routes.dart';

/// Shown when a signed-in user has no Firestore merchant row.
class MerchantNoApplicationScreen extends StatelessWidget {
  const MerchantNoApplicationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Merchant portal'),
        actions: <Widget>[
          TextButton(
            onPressed: () => FirebaseAuth.instance.signOut(),
            child: const Text('Log out'),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  'No merchant application found',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 12),
                Text(
                  'There is no merchant profile linked to this account yet. '
                  'Start an application to submit your business details.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 28),
                FilledButton(
                  onPressed: () {
                    Navigator.of(context).pushReplacementNamed(
                      MerchantPortalRoutes.onboarding,
                    );
                  },
                  child: const Text('Start merchant application'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
