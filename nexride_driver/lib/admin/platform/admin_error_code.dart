/// Canonical admin failure codes for UI + logs (Phase 4R).
enum AdminErrorCode {
  unknown,
  permissionDenied,
  staleEntity,
  payloadTooLarge,
  rateLimited,
  validationFailed,
  entityNotFound,
  actionConflict,
  backendTimeout,
  cooldown;

  /// Wire / HTTP-ish snake_case used by backends and structured failures.
  String get wireName {
    switch (this) {
      case AdminErrorCode.unknown:
        return 'unknown';
      case AdminErrorCode.permissionDenied:
        return 'permission_denied';
      case AdminErrorCode.staleEntity:
        return 'stale_entity';
      case AdminErrorCode.payloadTooLarge:
        return 'payload_too_large';
      case AdminErrorCode.rateLimited:
        return 'rate_limited';
      case AdminErrorCode.validationFailed:
        return 'validation_failed';
      case AdminErrorCode.entityNotFound:
        return 'entity_not_found';
      case AdminErrorCode.actionConflict:
        return 'action_conflict';
      case AdminErrorCode.backendTimeout:
        return 'backend_timeout';
      case AdminErrorCode.cooldown:
        return 'cooldown';
    }
  }

  String userMessage(String fallback) {
    switch (this) {
      case AdminErrorCode.permissionDenied:
        return 'You do not have permission for this action.';
      case AdminErrorCode.staleEntity:
        return 'This record changed elsewhere. Refresh and try again.';
      case AdminErrorCode.payloadTooLarge:
        return 'Response or request was too large. Narrow filters or retry.';
      case AdminErrorCode.rateLimited:
      case AdminErrorCode.cooldown:
        return 'Too many attempts. Wait a moment and try again.';
      case AdminErrorCode.validationFailed:
        return 'Validation failed. Check inputs and try again.';
      case AdminErrorCode.entityNotFound:
        return 'That record no longer exists or is not visible.';
      case AdminErrorCode.actionConflict:
        return 'This action conflicts with the current state.';
      case AdminErrorCode.backendTimeout:
        return 'The server took too long to respond. Retry shortly.';
      case AdminErrorCode.unknown:
        return fallback;
    }
  }

  static AdminErrorCode fromWire(String? raw) {
    final String c = (raw ?? '').trim().toLowerCase().replaceAll('-', '_');
    switch (c) {
      case 'permission_denied':
        return AdminErrorCode.permissionDenied;
      case 'stale_entity':
        return AdminErrorCode.staleEntity;
      case 'payload_too_large':
        return AdminErrorCode.payloadTooLarge;
      case 'rate_limited':
      case 'resource_exhausted':
        return AdminErrorCode.rateLimited;
      case 'validation_failed':
      case 'invalid_argument':
        return AdminErrorCode.validationFailed;
      case 'not_found':
      case 'entity_not_found':
        return AdminErrorCode.entityNotFound;
      case 'action_conflict':
      case 'failed_precondition':
      case 'aborted':
        return AdminErrorCode.actionConflict;
      case 'deadline_exceeded':
      case 'unavailable':
      case 'backend_timeout':
        return AdminErrorCode.backendTimeout;
      case 'cooldown':
        return AdminErrorCode.cooldown;
      default:
        return AdminErrorCode.unknown;
    }
  }
}
