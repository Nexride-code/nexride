import 'package:flutter/material.dart';

/// Shown when a selfie is required before booking rides or dispatch.
class RiderIdentityVerificationBanner extends StatelessWidget {
  const RiderIdentityVerificationBanner({
    super.key,
    required this.onOpenVerification,
    this.message = 'Please complete identity verification to book a ride.',
    this.actionLabel = 'Verify',
  });

  final VoidCallback onOpenVerification;
  final String message;
  final String actionLabel;

  static const Color _gold = Color(0xFFD4AF37);

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(14),
      color: const Color(0xFF2A2418),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.verified_user_outlined, color: _gold, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
            ),
            TextButton(
              onPressed: onOpenVerification,
              style: TextButton.styleFrom(
                foregroundColor: _gold,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: Text(actionLabel),
            ),
          ],
        ),
      ),
    );
  }
}
