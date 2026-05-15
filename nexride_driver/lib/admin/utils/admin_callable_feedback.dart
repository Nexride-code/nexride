import 'package:flutter/foundation.dart';

/// User-facing text for HTTPS callable JSON envelopes (`success: false`).
String adminCallableFailureMessage(Map<String, dynamic> data) {
  final String code = '${data['reason_code'] ?? ''}'.trim();
  if (code == 'admin_permission_denied') {
    return 'You do not have permission for this action.';
  }
  final String reason = '${data['reason'] ?? ''}'.trim();
  if (reason.isNotEmpty) {
    return reason;
  }
  return 'Request failed.';
}

/// Thrown when a callable returns `{ success: false, ... }` so UI can show
/// [adminCallableFailureMessage] (including RBAC `admin_permission_denied`).
@immutable
class AdminCallableResultException implements Exception {
  const AdminCallableResultException(this.data);

  final Map<String, dynamic> data;

  String get userMessage => adminCallableFailureMessage(data);

  bool get isPermissionDenied =>
      '${data['reason_code'] ?? ''}'.trim() == 'admin_permission_denied';

  @override
  String toString() => userMessage;
}

void ensureAdminCallableSuccess(Map<String, dynamic> data) {
  if (data['success'] == true || data['success'] == 1) {
    return;
  }
  throw AdminCallableResultException(Map<String, dynamic>.from(data));
}
