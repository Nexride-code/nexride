import 'dart:async';

import 'package:flutter/foundation.dart';

/// Serializes Firebase RTDB native writes (prevents Android plugin OOM).
class RealtimeDatabaseWriteQueue {
  RealtimeDatabaseWriteQueue._();

  static final RealtimeDatabaseWriteQueue instance =
      RealtimeDatabaseWriteQueue._();

  Future<void> _tail = Future<void>.value();
  int _pending = 0;
  final Map<String, Future<dynamic>> _inFlightByDedupeKey =
      <String, Future<dynamic>>{};

  Future<T> run<T>({
    required String source,
    required Future<T> Function() action,
    String? dedupeKey,
  }) {
    final normalizedDedupe = dedupeKey?.trim() ?? '';
    if (normalizedDedupe.isNotEmpty) {
      final existing = _inFlightByDedupeKey[normalizedDedupe];
      if (existing != null) {
        debugPrint(
          'RTDB_WRITE_DEDUPED source=$source dedupeKey=$normalizedDedupe',
        );
        return existing as Future<T>;
      }
    }

    final task = _enqueue(source, action);
    if (normalizedDedupe.isNotEmpty) {
      _inFlightByDedupeKey[normalizedDedupe] = task;
      task.whenComplete(() {
        if (identical(_inFlightByDedupeKey[normalizedDedupe], task)) {
          _inFlightByDedupeKey.remove(normalizedDedupe);
        }
      });
    }
    return task;
  }

  Future<T> _enqueue<T>(String source, Future<T> Function() action) {
    _pending++;
    debugPrint('RTDB_WRITE_QUEUE size=$_pending source=$source');
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      } finally {
        _pending = (_pending - 1).clamp(0, 1 << 30);
      }
    });
    return completer.future;
  }
}

Future<T> runQueuedRealtimeDatabaseWrite<T>({
  required String source,
  required Future<T> Function() action,
  String? dedupeKey,
}) {
  return RealtimeDatabaseWriteQueue.instance.run<T>(
    source: source,
    dedupeKey: dedupeKey,
    action: action,
  );
}
