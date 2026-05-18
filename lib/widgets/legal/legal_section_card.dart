import 'package:flutter/material.dart';

import '../../legal/legal_models.dart';
import '../../legal/legal_theme.dart';

class LegalSectionCard extends StatelessWidget {
  const LegalSectionCard({super.key, required this.section});

  final LegalPolicySection section;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: LegalTheme.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: LegalTheme.divider),
        boxShadow: [
          BoxShadow(
            color: LegalTheme.ink.withValues(alpha: 0.04),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (section.icon != null) ...[
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: LegalTheme.goldSoft.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(section.icon, color: LegalTheme.goldDark, size: 20),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Text(
                  section.title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SelectableText(
            section.body,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}
