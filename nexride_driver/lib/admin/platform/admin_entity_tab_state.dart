import 'package:flutter/foundation.dart';

/// Load lifecycle for a single entity tab (Phase 4K — mirrors drawer runtime).
enum AdminEntityTabLoadPhase {
  idle,
  loading,
  ready,
  error,
}

@immutable
class AdminEntityTabState {
  const AdminEntityTabState({
    required this.tabId,
    required this.phase,
    this.lastResolvedAtMs,
    this.lastError,
    this.epoch = 0,
  });

  final String tabId;
  final AdminEntityTabLoadPhase phase;
  final int? lastResolvedAtMs;
  final Object? lastError;
  final int epoch;

  AdminEntityTabState copyWith({
    AdminEntityTabLoadPhase? phase,
    int? lastResolvedAtMs,
    Object? lastError,
    int? epoch,
  }) {
    return AdminEntityTabState(
      tabId: tabId,
      phase: phase ?? this.phase,
      lastResolvedAtMs: lastResolvedAtMs ?? this.lastResolvedAtMs,
      lastError: lastError ?? this.lastError,
      epoch: epoch ?? this.epoch,
    );
  }
}
