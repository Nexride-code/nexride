import 'package:flutter/foundation.dart';

/// Declared payload ceiling for a tab or list surface (Phase 4J / 4H checklist).
@immutable
class AdminEntityPayloadBudget {
  const AdminEntityPayloadBudget({
    this.maxListItems = 200,
    this.maxJsonBytes = 512000,
  });

  final int maxListItems;
  final int maxJsonBytes;

  static const AdminEntityPayloadBudget drawerTab = AdminEntityPayloadBudget(
    maxListItems: 120,
    maxJsonBytes: 400000,
  );

  static const AdminEntityPayloadBudget verificationQueue =
      AdminEntityPayloadBudget(
    maxListItems: 200,
    maxJsonBytes: 600000,
  );

  bool withinItemCount(int n) => n <= maxListItems;

  bool withinByteSize(int bytes) => bytes <= maxJsonBytes;
}
