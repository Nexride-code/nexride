import 'dart:async';

import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/foundation.dart';

import '../services/call_service.dart';

typedef SharedCallTerminalHandler = Future<void> Function({
  required String callId,
  required String contextId,
  required String status,
  String? endedBy,
});

/// One realtime listener on [calls/{callId}] for cross-peer terminal sync.
class SharedCallStateListener {
  SharedCallStateListener(this.callService);

  final CallService callService;
  StreamSubscription<rtdb.DatabaseEvent>? _subscription;
  String? _callId;

  void attach({
    required String callId,
    required String contextId,
    required String uid,
    required SharedCallTerminalHandler onTerminal,
  }) {
    final normalizedCallId = callId.trim();
    if (normalizedCallId.isEmpty || _callId == normalizedCallId) {
      return;
    }
    detach();
    _callId = normalizedCallId;
    debugPrint(
      'CALL_STATE_LISTENER_ATTACHED callId=$normalizedCallId uid=$uid',
    );
    _subscription = callService.observeSharedCall(normalizedCallId).listen(
      (event) {
        final status =
            CallService.sharedCallStatusFromSnapshot(event.snapshot.value);
        if (status == null || !CallService.isSharedCallTerminalStatus(status)) {
          return;
        }
        final value = event.snapshot.value;
        String? endedBy;
        if (value is Map) {
          endedBy = (value['ended_by'] ?? value['endedBy'])?.toString();
        }
        debugPrint(
          'CALL_ENDED_REMOTE callId=$normalizedCallId uid=$uid '
          'status=$status endedBy=${endedBy ?? ''} source=shared_call',
        );
        unawaited(
          onTerminal(
            callId: normalizedCallId,
            contextId: contextId,
            status: status,
            endedBy: endedBy,
          ),
        );
      },
      onError: (Object error) {
        debugPrint(
          'CALL_ERROR path=${CallService.sharedCallPath(normalizedCallId)} '
          'reason=$error',
        );
      },
    );
  }

  void detach() {
    _subscription?.cancel();
    _subscription = null;
    _callId = null;
  }
}
