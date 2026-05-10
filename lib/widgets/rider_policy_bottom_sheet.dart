import 'package:flutter/material.dart';

import '../services/rider_compliance_service.dart';

Future<void> showRiderPolicyBottomSheet(
  BuildContext context,
  RiderPolicyDocumentKind kind,
) async {
  await riderComplianceLogPolicyView(kind);
  if (!context.mounted) {
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.black,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) {
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        minChildSize: 0.45,
        maxChildSize: 0.95,
        builder: (context, scrollController) {
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        riderPolicyDocumentTitle(kind),
                        style: const TextStyle(
                          color: Color(0xFFD4AF37),
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white70),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Colors.white24),
              Expanded(
                child: SingleChildScrollView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                  child: SelectableText(
                    riderPolicyDocumentBody(kind),
                    style: const TextStyle(
                      color: Colors.white70,
                      height: 1.5,
                      fontSize: 14,
                    ),
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
