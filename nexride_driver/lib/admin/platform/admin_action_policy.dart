/// Global admin action / batching policy knobs (Phase 4Q).
abstract final class AdminActionPolicy {
  /// Default spacing between identical named mutations from the same client shell.
  static const Duration defaultMutationCooldown = Duration(seconds: 1);

  /// Heavier flows (verification, finance) should use a longer client-side guard.
  static const Duration verificationActionCooldown = Duration(seconds: 2);

  /// Soft cap for client-driven “bulk preview” style lists (enforced in UI where used).
  static const int maxBulkPreviewRows = 500;
}
