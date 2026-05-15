import 'package:flutter/material.dart';

import '../models/merchant_profile.dart';
import '../theme/merchant_theme.dart';

enum OnboardingMode { noApplication, pendingReview, error }

class OnboardingStatusScreen extends StatelessWidget {
  const OnboardingStatusScreen({
    super.key,
    required this.mode,
    this.merchant,
    this.message,
    this.onCompleteApplication,
  });

  final OnboardingMode mode;
  final MerchantProfile? merchant;
  final String? message;
  final VoidCallback? onCompleteApplication;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Merchant status')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _title,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: NexrideMerchantColors.ink,
                          ),
                    ),
                    const SizedBox(height: 12),
                    Text(_body, style: Theme.of(context).textTheme.bodyLarge),
                    if (merchant != null) ...<Widget>[
                      const SizedBox(height: 16),
                      Text(
                        'Business: ${merchant!.businessName}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text('Status: ${merchant!.merchantStatus}'),
                      Text('Verification: ${merchant!.verificationStatus ?? '—'}'),
                      if (merchant!.readinessMissing.isNotEmpty)
                        Text('Missing: ${merchant!.readinessMissing.join(', ')}'),
                    ],
                    if (mode == OnboardingMode.noApplication && onCompleteApplication != null) ...<Widget>[
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: onCompleteApplication,
                        child: const Text('Start merchant application'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String get _title {
    switch (mode) {
      case OnboardingMode.noApplication:
        return 'No merchant application';
      case OnboardingMode.pendingReview:
        return 'Awaiting NexRide approval';
      case OnboardingMode.error:
        return 'Something went wrong';
    }
  }

  String get _body {
    switch (mode) {
      case OnboardingMode.noApplication:
        return 'This account is not linked to a merchant record yet. '
            'Use the button below to submit your store details for NexRide review.';
      case OnboardingMode.pendingReview:
        return 'Your store profile is submitted. NexRide operations will review verification '
            'documents and subscription / commission setup. You will be able to use this app '
            'fully once status is Approved.';
      case OnboardingMode.error:
        return message ?? 'Please retry or contact NexRide support.';
    }
  }
}
