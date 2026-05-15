import 'package:flutter/material.dart';

/// Lightweight placeholder rows for loading states (no extra packages).
class NxSkeletonList extends StatelessWidget {
  const NxSkeletonList({super.key, this.count = 6});

  final int count;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).colorScheme.surfaceContainerHighest;
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: count,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, __) {
        return Card(
          child: ListTile(
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: base, borderRadius: BorderRadius.circular(8)),
            ),
            title: Container(height: 14, decoration: BoxDecoration(color: base, borderRadius: BorderRadius.circular(4))),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Container(
                height: 12,
                width: 120,
                decoration: BoxDecoration(color: base, borderRadius: BorderRadius.circular(4)),
              ),
            ),
          ),
        );
      },
    );
  }
}
