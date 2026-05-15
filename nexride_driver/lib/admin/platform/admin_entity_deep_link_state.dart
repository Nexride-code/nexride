import 'package:flutter/foundation.dart';

/// Normalized entity deep-link state for Router migration (Phase 4O groundwork).
@immutable
class AdminEntityDeepLinkState {
  const AdminEntityDeepLinkState({
    required this.entityType,
    required this.entityId,
    this.tabId,
    this.extraQuery = const <String, String>{},
  });

  final String entityType;
  final String entityId;
  final String? tabId;

  /// Reserved for filters / pagination persistence (e.g. `page`, `status`).
  final Map<String, String> extraQuery;
}
