import 'package:flutter/foundation.dart';

/// Structured admin audit record (Phase 3P). Prefer server-side
/// `admin_audit_logs` writes; this model supports client logging hooks.
@immutable
class AdminAuditEvent {
  const AdminAuditEvent({
    required this.actorUid,
    required this.actorEmail,
    required this.entityType,
    required this.entityId,
    required this.action,
    this.before,
    this.after,
    this.metadata = const <String, dynamic>{},
    this.timestamp,
    this.correlationId,
    this.entityRevision,
    this.entityUpdatedAt,
  });

  final String actorUid;
  final String actorEmail;
  final String entityType;
  final String entityId;
  final String action;
  final Object? before;
  final Object? after;
  final Map<String, dynamic> metadata;
  final DateTime? timestamp;

  /// Cross-service trace id for a single operator gesture (Phase 4M).
  final String? correlationId;

  /// Optional optimistic-concurrency revision from the entity payload (Phase 4N).
  final int? entityRevision;

  /// Optional entity `updatedAt` / `lastModified` from server payloads (Phase 4N).
  final DateTime? entityUpdatedAt;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'actorUid': actorUid,
      'actorEmail': actorEmail,
      'entityType': entityType,
      'entityId': entityId,
      'action': action,
      'before': before,
      'after': after,
      'metadata': metadata,
      'timestamp': (timestamp ?? DateTime.now()).toUtc().toIso8601String(),
      if (correlationId != null) 'correlationId': correlationId,
      if (entityRevision != null) 'entityRevision': entityRevision,
      if (entityUpdatedAt != null)
        'entityUpdatedAt': entityUpdatedAt!.toUtc().toIso8601String(),
    };
  }
}
