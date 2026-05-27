import 'package:flutter/foundation.dart';

import 'nex_trace.dart';

/// Enforces Grab-style single-listener-per-ride invariants (debug asserts).
class RidePipelineGuard {
  RidePipelineGuard._();

  static final Map<String, String> _rideListeners = <String, String>{};
  static final Map<String, String> _chatListeners = <String, String>{};
  static final Map<String, String> _callListeners = <String, String>{};

  static void assertRideListenerAttach({
    required String rideId,
    required String owner,
    required String path,
    String? role,
  }) {
    final key = rideId.trim();
    if (key.isEmpty) {
      return;
    }
    final existing = _rideListeners[key];
    if (existing != null && existing != owner) {
      final msg =
          'PIPELINE_VIOLATION duplicate_ride_listener rideId=$key '
          'existing=$existing attempted=$owner path=$path';
      debugPrint(msg);
      assert(false, msg);
    }
    _rideListeners[key] = owner;
    NexTrace.rtdbListenerAttach(
      path: path,
      listenerOwner: owner,
      rideId: key,
      role: role,
      source: 'ride_pipeline_guard',
    );
  }

  static void releaseRideListener({
    required String rideId,
    required String owner,
    required String path,
    String? role,
  }) {
    final key = rideId.trim();
    if (key.isEmpty) {
      return;
    }
    if (_rideListeners[key] == owner) {
      _rideListeners.remove(key);
    }
    NexTrace.rtdbListenerDispose(
      path: path,
      listenerOwner: owner,
      rideId: key,
      role: role,
      source: 'ride_pipeline_guard',
    );
  }

  static void assertChatListenerAttach({
    required String rideId,
    required String owner,
    required String path,
    String? role,
  }) {
    final key = rideId.trim();
    if (key.isEmpty) {
      return;
    }
    final existing = _chatListeners[key];
    if (existing != null && existing != owner) {
      final msg =
          'PIPELINE_VIOLATION duplicate_chat_listener rideId=$key '
          'existing=$existing attempted=$owner';
      debugPrint(msg);
      assert(false, msg);
    }
    _chatListeners[key] = owner;
  }

  static void releaseChatListener({
    required String rideId,
    required String owner,
  }) {
    final key = rideId.trim();
    if (_chatListeners[key] == owner) {
      _chatListeners.remove(key);
    }
  }

  static void assertCallListenerAttach({
    required String rideId,
    required String owner,
  }) {
    final key = rideId.trim();
    if (key.isEmpty) {
      return;
    }
    final existing = _callListeners[key];
    if (existing != null && existing != owner) {
      final msg =
          'PIPELINE_VIOLATION duplicate_call_listener rideId=$key '
          'existing=$existing attempted=$owner';
      debugPrint(msg);
      assert(false, msg);
    }
    _callListeners[key] = owner;
  }

  static void releaseCallListener({
    required String rideId,
    required String owner,
  }) {
    final key = rideId.trim();
    if (_callListeners[key] == owner) {
      _callListeners.remove(key);
    }
  }

  static String snapshot({
    String? rideId,
    String? tripState,
    String? uid,
  }) {
    return 'listeners(ride=${_rideListeners.length} chat=${_chatListeners.length} '
        'call=${_callListeners.length}) rideId=${rideId ?? ""} '
        'trip_state=${tripState ?? ""} uid=${uid ?? ""}';
  }
}
