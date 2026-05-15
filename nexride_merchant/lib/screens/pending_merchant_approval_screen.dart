import 'package:flutter/material.dart';

import '../models/merchant_profile.dart';

/// Full-screen gate after registration while NexRide reviews the application.
class PendingMerchantApprovalScreen extends StatelessWidget {
  const PendingMerchantApprovalScreen({
    super.key,
    required this.merchant,
    required this.onContinueToPortal,
  });

  final MerchantProfile merchant;
  final VoidCallback onContinueToPortal;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Application submitted')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Icon(Icons.hourglass_top_outlined, size: 56, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 20),
                Text(
                  'Awaiting NexRide approval',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 12),
                Text(
                  'Your store “${merchant.businessName}” is linked to your account and is in '
                  '${merchant.merchantStatus} review. You will not receive live customer orders until NexRide approves your business.\n\n'
                  'You can still prepare your menu, upload verification documents, and complete your profile.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 28),
                FilledButton(
                  onPressed: onContinueToPortal,
                  child: const Text('Continue to merchant portal'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
