import 'package:flutter/material.dart';

import '../admin_config.dart';

/// Confirmation for destructive or financially sensitive admin mutations.
/// Returns trimmed reason text, or `null` if cancelled.
Future<String?> showAdminSensitiveActionDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  int minReasonLength = 8,
}) async {
  final TextEditingController controller = TextEditingController();
  final String? result = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext ctx) {
      return AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              message,
              style: const TextStyle(
                color: AdminThemeTokens.slate,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              maxLines: 4,
              decoration: InputDecoration(
                labelText:
                    'Reason (required, at least $minReasonLength characters)',
                alignLabelWithHint: true,
                border: const OutlineInputBorder(),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(
                    color: AdminThemeTokens.gold,
                    width: 1.4,
                  ),
                ),
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AdminThemeTokens.gold,
              foregroundColor: Colors.black,
            ),
            onPressed: () {
              final String t = controller.text.trim();
              if (t.length < minReasonLength) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Enter a reason of at least $minReasonLength characters.',
                    ),
                  ),
                );
                return;
              }
              Navigator.pop(ctx, t);
            },
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return result;
}
