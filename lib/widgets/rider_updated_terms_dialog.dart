import 'package:flutter/material.dart';

import '../services/rider_compliance_service.dart'
    show RiderComplianceService, RiderPolicyDocumentKind;
import 'rider_policy_bottom_sheet.dart';

/// Blocks interaction until the user re-accepts current Terms / age gate.
Future<void> showRiderUpdatedTermsDialog({
  required BuildContext context,
  required String riderId,
}) async {
  if (!context.mounted) {
    return;
  }
  var termsChecked = false;
  var ageChecked = false;

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (context, setLocal) {
          final ready = termsChecked && ageChecked;
          return AlertDialog(
            backgroundColor: const Color(0xFF111111),
            title: const Text(
              'Updated terms',
              style: TextStyle(color: Color(0xFFD4AF37)),
            ),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Our Terms, Privacy Policy, and Community Guidelines have been updated. '
                    'Please review and accept to continue using NexRide.',
                    style: TextStyle(color: Colors.white70, height: 1.45),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 4,
                    children: [
                      TextButton(
                        onPressed: () => showRiderPolicyBottomSheet(
                          context,
                          RiderPolicyDocumentKind.terms,
                        ),
                        child: const Text(
                          'Terms of Service',
                          style: TextStyle(
                            color: Color(0xFFD4AF37),
                            fontSize: 13,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => showRiderPolicyBottomSheet(
                          context,
                          RiderPolicyDocumentKind.privacy,
                        ),
                        child: const Text(
                          'Privacy Policy',
                          style: TextStyle(
                            color: Color(0xFFD4AF37),
                            fontSize: 13,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => showRiderPolicyBottomSheet(
                          context,
                          RiderPolicyDocumentKind.community,
                        ),
                        child: const Text(
                          'Community Guidelines',
                          style: TextStyle(
                            color: Color(0xFFD4AF37),
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  CheckboxListTile(
                    value: termsChecked,
                    onChanged: (v) =>
                        setLocal(() => termsChecked = v ?? false),
                    activeColor: const Color(0xFFD4AF37),
                    checkColor: Colors.black,
                    title: const Text(
                      'I have read and agree to the Terms of Service, Privacy Policy, and Community Guidelines.',
                      style: TextStyle(color: Colors.white, fontSize: 13),
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                  ),
                  CheckboxListTile(
                    value: ageChecked,
                    onChanged: (v) => setLocal(() => ageChecked = v ?? false),
                    activeColor: const Color(0xFFD4AF37),
                    checkColor: Colors.black,
                    title: const Text(
                      'I confirm I am 18 years or older.',
                      style: TextStyle(color: Colors.white, fontSize: 13),
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: ready
                    ? () async {
                        await RiderComplianceService.instance
                            .saveUpdatedTermsAcceptance(uid: riderId);
                        if (context.mounted) {
                          Navigator.of(ctx).pop();
                        }
                      }
                    : null,
                child: Text(
                  'Accept & continue',
                  style: TextStyle(
                    color: ready ? const Color(0xFFD4AF37) : Colors.white24,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          );
        },
      );
    },
  );
}
