import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../models/admin_audit_event.dart';
import '../platform/admin_action_policy.dart';
import '../platform/admin_error_code.dart';
import '../utils/admin_callable_feedback.dart';

/// Standardized failure envelope (Phase 3O / 4R) for UI + logs.
@immutable
class AdminStructuredActionFailure implements Exception {
  const AdminStructuredActionFailure({
    required this.code,
    required this.message,
    this.retryable = false,
    this.adminCode,
  });

  final String code;
  final String message;
  final bool retryable;
  final AdminErrorCode? adminCode;

  factory AdminStructuredActionFailure.staleEntity({String? detail}) {
    return AdminStructuredActionFailure(
      code: AdminErrorCode.staleEntity.wireName,
      message: detail ??
          'This record changed elsewhere. Refresh the page and try again.',
      retryable: true,
      adminCode: AdminErrorCode.staleEntity,
    );
  }

  Map<String, dynamic> toResultMap() {
    return <String, dynamic>{
      'success': false,
      'code': code,
      'message': message,
      'retryable': retryable,
      if (adminCode != null) 'adminCode': adminCode!.wireName,
    };
  }

  @override
  String toString() => 'AdminStructuredActionFailure($code): $message';
}

/// Result of [AdminActionExecutor.run].
@immutable
class AdminActionResult<T> {
  const AdminActionResult({
    required this.ok,
    this.value,
    this.error,
  });

  factory AdminActionResult.success(T value) {
    return AdminActionResult<T>(ok: true, value: value, error: null);
  }

  factory AdminActionResult.failure(Object error) {
    return AdminActionResult<T>(ok: false, value: null, error: error);
  }

  final bool ok;
  final T? value;
  final Object? error;
}

typedef AdminEmitAuditFn = AdminAuditEvent? Function({
  required bool success,
  Object? value,
  Object? error,
  required String correlationId,
});

/// Central place for admin mutations: invoke, log, snackbar, optional refresh.
///
/// Logs: `[AdminAction]`, `[AdminAudit]` (when [emitAudit] returns an event),
/// `[AdminAudit][FAILURE]`, `[AdminAudit][ROLLBACK]` (Phase 4M).
class AdminActionExecutor {
  const AdminActionExecutor();

  static final Map<String, int> _lastRunMs = <String, int>{};

  String _newCorrelationId() {
    final int t = DateTime.now().microsecondsSinceEpoch;
    final int r = math.Random().nextInt(0x7fffffff);
    return 'adm_${t}_$r';
  }

  void _logFailure({
    required String actionName,
    required String correlationId,
    required Object error,
  }) {
    debugPrint(
      '[AdminAudit][FAILURE] action=$actionName correlationId=$correlationId error=$error',
    );
  }

  void _logRollback({
    required String actionName,
    required String correlationId,
    required Object error,
  }) {
    debugPrint(
      '[AdminAudit][ROLLBACK] action=$actionName correlationId=$correlationId error=$error',
    );
  }

  Future<AdminActionResult<T>> run<T>({
    required BuildContext context,
    required String actionName,
    required Future<T> Function() invoke,
    String? successMessage,
    bool showSuccessSnackBar = true,
    void Function(T value)? onSuccess,
    void Function()? applyOptimistic,
    void Function()? rollbackOptimistic,
    AdminEmitAuditFn? emitAudit,
    Duration cooldown = Duration.zero,
    bool mapFunctionsExceptionToStructured = true,
    bool useDefaultMutationThrottle = false,
    String? correlationId,
    int? entityRevision,
    DateTime? entityUpdatedAt,
  }) async {
    final String cid = correlationId ?? _newCorrelationId();
    final Duration effectiveCooldown = cooldown > Duration.zero
        ? cooldown
        : (useDefaultMutationThrottle
            ? AdminActionPolicy.defaultMutationCooldown
            : Duration.zero);

    final int t0 = DateTime.now().millisecondsSinceEpoch;
    debugPrint('[AdminAction] start name=$actionName correlationId=$cid');
    if (effectiveCooldown > Duration.zero) {
      final int now = DateTime.now().millisecondsSinceEpoch;
      final int last = _lastRunMs[actionName] ?? 0;
      if (now - last < effectiveCooldown.inMilliseconds) {
        final AdminStructuredActionFailure err = AdminStructuredActionFailure(
          code: AdminErrorCode.cooldown.wireName,
          message:
              'Please wait before repeating $actionName (${effectiveCooldown.inSeconds}s throttle).',
          retryable: true,
          adminCode: AdminErrorCode.cooldown,
        );
        debugPrint('[AdminAction] cooldown name=$actionName correlationId=$cid');
        _logFailure(actionName: actionName, correlationId: cid, error: err);
        final AdminAuditEvent? audit = emitAudit?.call(
          success: false,
          value: null,
          error: err,
          correlationId: cid,
        );
        if (audit != null) {
          debugPrint('[AdminAudit] ${jsonEncode(audit.toJson())}');
        }
        if (context.mounted) {
          final String text =
              err.adminCode?.userMessage(err.message) ?? err.message;
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text('$actionName: $text')),
          );
        }
        return AdminActionResult.failure(err);
      }
      _lastRunMs[actionName] = now;
    }

    applyOptimistic?.call();
    try {
      final T value = await invoke();
      final int ms = DateTime.now().millisecondsSinceEpoch - t0;
      debugPrint('[AdminAction] ok name=$actionName ${ms}ms correlationId=$cid');
      onSuccess?.call(value);
      final AdminAuditEvent? audit = emitAudit?.call(
        success: true,
        value: value,
        error: null,
        correlationId: cid,
      );
      if (audit != null) {
        debugPrint('[AdminAudit] ${jsonEncode(_auditJson(audit, entityRevision, entityUpdatedAt))}');
      }
      if (showSuccessSnackBar && context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(successMessage ?? '$actionName completed'),
          ),
        );
      }
      return AdminActionResult.success(value);
    } catch (error, stackTrace) {
      final int ms = DateTime.now().millisecondsSinceEpoch - t0;
      debugPrint(
        '[AdminAction] fail name=$actionName ${ms}ms correlationId=$cid error=$error',
      );
      debugPrintStack(
        label: '[AdminAction] stack',
        stackTrace: stackTrace,
      );
      _logFailure(actionName: actionName, correlationId: cid, error: error);
      if (rollbackOptimistic != null) {
        rollbackOptimistic();
        _logRollback(actionName: actionName, correlationId: cid, error: error);
      }
      final AdminAuditEvent? audit = emitAudit?.call(
        success: false,
        value: null,
        error: error,
        correlationId: cid,
      );
      if (audit != null) {
        debugPrint('[AdminAudit] ${jsonEncode(_auditJson(audit, entityRevision, entityUpdatedAt))}');
      }

      Object snackError = error;
      if (mapFunctionsExceptionToStructured && error is FirebaseFunctionsException) {
        final String code = error.code;
        final bool retryable =
            code == 'unavailable' || code == 'deadline-exceeded' || code == 'resource-exhausted';
        String norm = code;
        if (code == 'permission-denied') {
          norm = 'permission_denied';
        }
        final AdminErrorCode ac = AdminErrorCode.fromWire(norm);
        snackError = AdminStructuredActionFailure(
          code: norm,
          message: error.message ?? error.toString(),
          retryable: retryable,
          adminCode: ac,
        );
      } else if (error is AdminStructuredActionFailure) {
        snackError = error;
      } else if (error is AdminCallableResultException) {
        snackError = error;
      }

      if (context.mounted) {
        final String text;
        final SnackBarAction? retryAction;
        switch (snackError) {
          case AdminCallableResultException ace:
            text = ace.userMessage;
            retryAction = null;
          case AdminStructuredActionFailure f:
            text = f.adminCode?.userMessage(f.message) ?? f.message;
            retryAction = f.retryable
                ? SnackBarAction(
                    label: 'Retry',
                    textColor: Colors.white,
                    onPressed: () {
                      unawaited(
                        run<T>(
                          context: context,
                          actionName: actionName,
                          invoke: invoke,
                          successMessage: successMessage,
                          showSuccessSnackBar: showSuccessSnackBar,
                          onSuccess: onSuccess,
                          applyOptimistic: applyOptimistic,
                          rollbackOptimistic: rollbackOptimistic,
                          emitAudit: emitAudit,
                          cooldown: cooldown,
                          mapFunctionsExceptionToStructured:
                              mapFunctionsExceptionToStructured,
                          useDefaultMutationThrottle:
                              useDefaultMutationThrottle,
                          correlationId: _newCorrelationId(),
                          entityRevision: entityRevision,
                          entityUpdatedAt: entityUpdatedAt,
                        ),
                      );
                    },
                  )
                : null;
          default:
            text = '$error';
            retryAction = null;
        }
        final bool permissionDenied = switch (snackError) {
          AdminCallableResultException e => e.isPermissionDenied,
          _ => false,
        };
        final String body = permissionDenied ? text : '$actionName failed: $text';
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(body),
            backgroundColor: permissionDenied
                ? Theme.of(context).colorScheme.inverseSurface
                : Colors.red.shade800,
            duration: permissionDenied ? const Duration(seconds: 8) : const Duration(seconds: 4),
            action: retryAction,
          ),
        );
      }
      return AdminActionResult.failure(snackError);
    }
  }

  Map<String, dynamic> _auditJson(
    AdminAuditEvent audit,
    int? entityRevision,
    DateTime? entityUpdatedAt,
  ) {
    final Map<String, dynamic> j = Map<String, dynamic>.from(audit.toJson());
    if (audit.entityRevision == null && entityRevision != null) {
      j['entityRevision'] = entityRevision;
    }
    if (audit.entityUpdatedAt == null && entityUpdatedAt != null) {
      j['entityUpdatedAt'] = entityUpdatedAt.toUtc().toIso8601String();
    }
    return j;
  }
}
