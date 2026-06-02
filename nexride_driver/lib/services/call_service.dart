import 'dart:async';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/foundation.dart';

import '../support/call_trace_support.dart';
import '../support/realtime_database_error_support.dart';
import 'ride_cloud_functions_service.dart';

enum RideCallStatus {
  ringing,
  joined,
  ended,
  /// Legacy RTDB tokens mapped to [joined].
  accepted,
  declined,
  missed,
  cancelled,
}

/// UI-facing phase of the local Agora RTC engine.
///
/// Drives the call overlay's "Connecting..." vs duration vs error display
/// independently from the RTDB [RideCallStatus] (which only tracks the
/// signalling lifecycle, not whether audio is actually flowing).
enum AgoraConnectionPhase {
  idle,
  connecting,
  connected,
  reconnecting,
  failed,
}

class RideCallException implements Exception {
  const RideCallException(this.message);

  final String message;

  @override
  String toString() => message;
}

class RideCallSession {
  const RideCallSession({
    required this.rideId,
    required this.callerId,
    required this.receiverId,
    required this.status,
    required this.channelId,
    required this.callerUid,
    this.createdAt,
    this.acceptedAt,
    this.endedAt,
    this.endedBy,
  });

  final String rideId;
  final String callerId;
  final String receiverId;
  final RideCallStatus status;
  final String channelId;
  final String callerUid;
  final int? createdAt;
  final int? acceptedAt;
  final int? endedAt;
  final String? endedBy;

  bool get isCalling => status == RideCallStatus.ringing;
  bool get isRinging => isCalling;
  bool get isAccepted =>
      status == RideCallStatus.joined || status == RideCallStatus.accepted;
  bool get isTerminal =>
      status == RideCallStatus.declined ||
      status == RideCallStatus.ended ||
      status == RideCallStatus.missed ||
      status == RideCallStatus.cancelled;

  DateTime? get createdAtDateTime => createdAt == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(createdAt!);
  DateTime? get acceptedAtDateTime => acceptedAt == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(acceptedAt!);
  DateTime? get endedAtDateTime =>
      endedAt == null ? null : DateTime.fromMillisecondsSinceEpoch(endedAt!);

  static RideCallSession? fromSnapshotValue(String rideId, dynamic value) {
    final map = _asStringDynamicMap(value);
    if (map == null) {
      return null;
    }

    final status = _parseStatus(
      map['state']?.toString() ?? map['status']?.toString(),
    );
    if (status == null) {
      return null;
    }

    final callerId = _resolveCallerId(map);
    final receiverId = _resolveReceiverId(map);
    if (callerId.isEmpty || receiverId.isEmpty) {
      return null;
    }

    return RideCallSession(
      rideId: map['ride_id']?.toString() ?? rideId,
      callerId: callerId,
      receiverId: receiverId,
      status: status,
      channelId:
          map['channelName']?.toString() ??
          map['channel_id']?.toString() ??
          rideId,
      callerUid: callerId,
      createdAt: _asInt(map['createdAt'] ?? map['created_at']),
      acceptedAt: _asInt(map['acceptedAt'] ?? map['accepted_at']),
      endedAt: _asInt(map['endedAt'] ?? map['ended_at']),
      endedBy: map['endedBy']?.toString() ?? map['ended_by']?.toString(),
    );
  }

  static List<RideCallSession> listFromCollectionValue(dynamic value) {
    if (value is! Map) {
      return const <RideCallSession>[];
    }

    final sessions = <RideCallSession>[];
    value.forEach((key, nestedValue) {
      if (key == null) {
        return;
      }

      final session = fromSnapshotValue(key.toString(), nestedValue);
      if (session != null) {
        sessions.add(session);
      }
    });

    sessions.sort((a, b) => (b.createdAt ?? 0).compareTo(a.createdAt ?? 0));
    return sessions;
  }
}

class OutgoingCallRequestResult {
  const OutgoingCallRequestResult({
    required this.created,
    required this.session,
  });

  final bool created;
  final RideCallSession? session;
}

/// Why a participant RTDB write is requested (controls throttle + dedupe).
enum ParticipantUpdateKind {
  callLifecycle,
  avState,
  foreground,
  rtcConnection,
}

class _ParticipantLogicalState {
  const _ParticipantLogicalState({
    required this.joined,
    required this.muted,
    required this.speaker,
    this.foreground,
    this.connectionState,
  });

  final bool joined;
  final bool muted;
  final bool speaker;
  final bool? foreground;
  final String? connectionState;

  bool isEquivalentTo(_ParticipantLogicalState other) {
    return joined == other.joined &&
        muted == other.muted &&
        speaker == other.speaker &&
        foreground == other.foreground &&
        connectionState == other.connectionState;
  }
}

class _VoiceJoinRequest {
  const _VoiceJoinRequest({
    required this.rideId,
    required this.agoraChannelId,
    required this.uid,
    required this.speakerOn,
    required this.muted,
  });

  /// Firebase `calls/{rideId}` and token cache key.
  final String rideId;

  /// Agora `joinChannel` channel name (may differ when using callable tokens).
  final String agoraChannelId;
  final String uid;
  final bool speakerOn;
  final bool muted;
}

class CallService {
  CallService({
    rtdb.FirebaseDatabase? database,
    String? agoraAppId,
    String callTraceRole = '',
  })  : _database = database ?? rtdb.FirebaseDatabase.instance,
        _defaultAgoraAppId = _resolveAgoraAppId(agoraAppId),
        _callTraceRole = callTraceRole.trim();

  final String _callTraceRole;
  final rtdb.FirebaseDatabase _database;
  final String _defaultAgoraAppId;
  String? _callableAgoraAppId;
  static const Duration _kCallReadTimeout = Duration(seconds: 12);
  static const Duration _kCallWriteTimeout = Duration(seconds: 30);
  final String _agoraChannelPrefix = _resolveChannelPrefix();
  final Set<String> _syncedRideIds = <String>{};
  final Set<String> _syncedReceiverIds = <String>{};
  static const Duration _kParticipantWriteThrottle = Duration(seconds: 10);
  static const Set<String> _rtcConnectionStatesWorthPersisting = <String>{
    'connected',
    'disconnected',
    'connection_lost',
  };
  final Map<String, _ParticipantLogicalState> _lastParticipantLogicalState =
      <String, _ParticipantLogicalState>{};
  final Map<String, DateTime> _lastParticipantWriteAt = <String, DateTime>{};

  RtcEngine? _engine;
  RtcEngineEventHandler? _eventHandler;
  bool _engineReady = false;
  String? _engineInitializedAppId;
  bool _disposed = false;
  bool _intentionalLeaveInProgress = false;
  bool _reconnectInProgress = false;
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;
  Timer? _reconnectWatchdogTimer;
  DateTime? _joinAttemptStartedAt;
  Timer? _joinWatchdogTimer;
  String? _joinedChannelId;
  String? _cachedTokenChannelId;
  String? _cachedTokenUserId;
  String? _cachedToken;
  String? _cachedJoinAgoraChannel;
  int? _cachedJoinRtcUid;
  String? _callableAgoraChannelName;
  int? _joinRtcUidOverride;
  Object? _lastAgoraErrorCode;
  String? _lastAgoraErrorMessage;
  ConnectionChangedReasonType? _lastConnectionReason;
  _VoiceJoinRequest? _lastJoinRequest;
  bool _suppressRtcParticipantSync = false;
  bool _participantMirrorSuppressed = false;
  final Set<String> _participantTimeoutLoggedPaths = <String>{};
  bool _invalidTokenHandlingExhausted = false;
  Future<void>? _tokenRefreshInFlight;
  ConnectionStateType _connectionState =
      ConnectionStateType.connectionStateDisconnected;

  /// Public, UI-driven view of the local Agora connection. The overlay reads
  /// this to render `Connecting...` / live duration / `Could not connect call`.
  final ValueNotifier<AgoraConnectionPhase> phaseNotifier =
      ValueNotifier<AgoraConnectionPhase>(AgoraConnectionPhase.idle);
  final ValueNotifier<String?> phaseErrorNotifier =
      ValueNotifier<String?>(null);

  void _setPhase(AgoraConnectionPhase phase, {String? error}) {
    if (phaseNotifier.value != phase) {
      phaseNotifier.value = phase;
    }
    phaseErrorNotifier.value = error;
  }

  bool get isVoiceConnected =>
      phaseNotifier.value == AgoraConnectionPhase.connected;

  String get _activeAgoraAppId {
    final callable = (_callableAgoraAppId ?? '').trim();
    if (callable.isNotEmpty) {
      return callable;
    }
    return _defaultAgoraAppId;
  }

  bool get hasRtcConfiguration => _activeAgoraAppId.isNotEmpty;

  String get missingConfigurationMessage {
    if (_activeAgoraAppId.isNotEmpty) {
      return 'Voice calling is configured.';
    }
    return 'Voice calling is not configured yet. Add AGORA_APP_ID to enable it.';
  }

  String get unavailableUserMessage =>
      'Calling will be available once secure voice setup is completed.';

  String latestJoinFailureMessage() {
    if (_lastAgoraErrorCode != null) {
      return 'Call connect failed (Agora error $_lastAgoraErrorCode). Please try again.';
    }
    if (_lastConnectionReason != null) {
      return 'Call connect failed (${_lastConnectionReason!.name}). Please try again.';
    }
    return 'Unable to connect the call right now.';
  }

  String channelForRide(String rideId) {
    final normalizedRideId = rideId.trim();
    if (_agoraChannelPrefix.isEmpty) {
      return normalizedRideId;
    }
    return '${_agoraChannelPrefix}_$normalizedRideId';
  }

  void _callTrace(
    String event, {
    required String rideId,
    String? channel,
    String? uid,
    int? remoteUid,
    String? error,
    String? reason,
    int? elapsedMs,
    bool? speakerOn,
    bool? muted,
  }) {
    if (_callTraceRole.isEmpty) {
      return;
    }
    callTraceLog(
      event,
      rideId: rideId,
      role: _callTraceRole,
      channel: channel ?? _activeTraceChannel(rideId),
      uid: uid ?? _lastJoinRequest?.uid,
      remoteUid: remoteUid,
      error: error ?? reason,
      elapsedMs: elapsedMs,
      speakerOn: speakerOn,
      muted: muted,
    );
  }

  void _applyCallableJoinIdentity({
    required String channelName,
    required int rtcUid,
  }) {
    _cachedJoinAgoraChannel = channelName;
    _callableAgoraChannelName = channelName;
    _cachedJoinRtcUid = rtcUid;
    _joinRtcUidOverride = rtcUid;
  }

  String? _activeTraceChannel(String rideId) {
    final joinChannel = _lastJoinRequest?.agoraChannelId.trim();
    if (joinChannel != null && joinChannel.isNotEmpty) {
      return joinChannel;
    }
    final callable = _callableAgoraChannelName?.trim();
    if (callable != null && callable.isNotEmpty) {
      return callable;
    }
    final normalizedRideId = rideId.trim();
    if (normalizedRideId.isEmpty) {
      return null;
    }
    return channelForRide(normalizedRideId);
  }

  Stream<rtdb.DatabaseEvent> observeCall(String rideId) {
    final normalizedRideId = rideId.trim();
    unawaited(_keepRideCallSynced(normalizedRideId));
    return _callRef(normalizedRideId).onValue;
  }

  Stream<rtdb.DatabaseEvent> observeCallsForReceiver(String receiverId) {
    // Root /calls queries are denied — use observeCall(rideId) instead.
    return const Stream<rtdb.DatabaseEvent>.empty();
  }

  Future<RideCallSession?> fetchCall(String rideId) async {
    final normalizedRideId = rideId.trim();
    await _keepRideCallSynced(normalizedRideId);
    rtdb.DataSnapshot? snapshot;
    try {
      snapshot = await runOptionalRealtimeDatabaseRead<rtdb.DataSnapshot>(
        source: 'call_service.fetch_call',
        path: 'calls/$normalizedRideId',
        action: () => _callRef(normalizedRideId).get(),
      ).timeout(_kCallReadTimeout);
    } on TimeoutException {
      throw const RideCallException(
        'Call service timed out. Please try again.',
      );
    }
    if (snapshot == null) {
      return null;
    }
    return RideCallSession.fromSnapshotValue(normalizedRideId, snapshot.value);
  }

  Future<List<RideCallSession>> fetchCallsForReceiver(
    String receiverId, {
    String? activeRideId,
  }) async {
    final rideId = activeRideId?.trim() ?? '';
    if (rideId.isEmpty) {
      debugPrint(
        '[CALL_LOG_LOAD_EMPTY] receiverId=${receiverId.trim()} reason=no_active_ride',
      );
      return const <RideCallSession>[];
    }
    debugPrint('[CALL_LOG_LOAD_START] rideId=$rideId role=driver');
    try {
      final session = await fetchCall(rideId).timeout(
        const Duration(seconds: 8),
      );
      if (session == null) {
        debugPrint('[CALL_LOG_LOAD_EMPTY] rideId=$rideId');
        return const <RideCallSession>[];
      }
      debugPrint(
        '[CALL_LOG_LOAD_OK] rideId=$rideId status=${session.status.name}',
      );
      return <RideCallSession>[session];
    } on TimeoutException {
      debugPrint('[CALL_LOG_LOAD_ERROR] rideId=$rideId reason=timeout');
      return const <RideCallSession>[];
    } catch (error) {
      debugPrint('[CALL_LOG_LOAD_ERROR] rideId=$rideId error=$error');
      return const <RideCallSession>[];
    }
  }

  Future<void> prefetchAgoraToken({
    required String channelId,
    required String uid,
    bool forceRefresh = false,
  }) async {
    final token = await fetchAgoraToken(
      channelId,
      uid,
      forceRefresh: forceRefresh,
    );
    if (token == null || token.isEmpty) {
      throw const RideCallException(
        'Unable to connect voice calling right now. Please try again.',
      );
    }
  }

  Future<OutgoingCallRequestResult> requestOutgoingVoiceCall({
    required String rideId,
    required String riderId,
    required String driverId,
    required String startedBy,
  }) async {
    final normalizedRideId = rideId.trim();
    final normalizedRiderId = riderId.trim();
    final normalizedDriverId = driverId.trim();
    final normalizedStartedBy = startedBy.trim().toLowerCase();
    final callerId = normalizedStartedBy == 'driver'
        ? normalizedDriverId
        : normalizedRiderId;
    final receiverId = normalizedStartedBy == 'driver'
        ? normalizedRiderId
        : normalizedDriverId;

    await _keepRideCallSynced(normalizedRideId);

    late final rtdb.TransactionResult transaction;
    try {
      transaction = await _callRef(normalizedRideId)
          .runTransaction((currentValue) {
            final currentMap = _asStringDynamicMap(currentValue);
            final statusRaw = currentMap?['status']?.toString() ?? '';
            final stateRaw = currentMap?['state']?.toString() ?? '';
            final effectiveStatus = statusRaw.trim().isNotEmpty
                ? statusRaw.trim().toLowerCase()
                : stateRaw.trim().toLowerCase();
            if (_isActiveStatusString(effectiveStatus)) {
              return rtdb.Transaction.abort();
            }
            if (_isTerminalStatusString(effectiveStatus)) {
              _callTrace(
                'CALL_TERMINAL_STATE_RESET_FOR_RESTART',
                rideId: normalizedRideId,
              );
              _callTrace(
                'CALL_RESTART_AFTER_ENDED_OK',
                rideId: normalizedRideId,
              );
            }
            final priorAttempt = switch (currentMap?['callAttempt']) {
              int value => value,
              num value => value.toInt(),
              String value => int.tryParse(value.trim()) ?? 0,
              _ => 0,
            };
            final payload = <String, Object?>{
              'ride_id': normalizedRideId,
              'rider_id': normalizedRiderId,
              'driver_id': normalizedDriverId,
              'started_by': normalizedStartedBy,
              'callerId': callerId,
              'receiverId': receiverId,
              'channelName': channelForRide(normalizedRideId),
              'status': 'ringing',
              'state': 'ringing',
              'sessionId': '${DateTime.now().millisecondsSinceEpoch}',
              'callAttempt': priorAttempt + 1,
              'startedAt': rtdb.ServerValue.timestamp,
              'createdAt': rtdb.ServerValue.timestamp,
              'updatedAt': rtdb.ServerValue.timestamp,
              'acceptedAt': null,
              'endedAt': null,
              'endedBy': null,
            };
            return rtdb.Transaction.success(payload);
          }, applyLocally: false)
          .timeout(_kCallWriteTimeout);
    } on TimeoutException {
      throw const RideCallException(
        'Call request timed out. Please try again.',
      );
    }

    if (transaction.committed) {
      _callTrace('CALL_NEW_SESSION_WRITE_OK', rideId: normalizedRideId);
      _callTrace('CALL_SIGNAL_WRITE_OK', rideId: normalizedRideId);
      clearParticipantWriteCache(rideId: normalizedRideId);
    } else {
      final existing = await fetchCall(normalizedRideId);
      final existingStatus = existing?.status.name ?? '';
      if (_isActiveStatusString(existingStatus)) {
        _callTrace(
          'CALL_START_BLOCKED',
          rideId: normalizedRideId,
          reason: 'active_status_$existingStatus',
        );
      }
    }

    return OutgoingCallRequestResult(
      created: transaction.committed,
      session: await fetchCall(normalizedRideId),
    );
  }

  Future<bool> acceptCall({required String rideId, String? receiverId}) async {
    final committed = await _transitionCallStatus(
      rideId: rideId,
      nextStatus: 'accepted',
      allowedStatuses: const <String>{'calling', 'ringing'},
      requiredParticipantField: 'receiverId',
      requiredParticipantId: receiverId,
      setAcceptedAt: true,
    );
    if (committed) {
      _callTrace('CALL_SIGNAL_WRITE_OK', rideId: rideId);
    }
    return committed;
  }

  Future<void> declineCall({
    required String rideId,
    required String endedBy,
    String? receiverId,
  }) async {
    final committed = await _transitionCallStatus(
      rideId: rideId,
      nextStatus: 'declined',
      endedBy: endedBy,
      requiredParticipantField: 'receiverId',
      requiredParticipantId: receiverId,
      allowedStatuses: const <String>{'calling', 'ringing'},
    );
    if (committed) {
      _callTrace('CALL_END_RTDB_OK', rideId: rideId);
    }
  }

  Future<void> cancelOutgoingCall({
    required String rideId,
    required String endedBy,
    String? callerId,
  }) async {
    final committed = await _transitionCallStatus(
      rideId: rideId,
      nextStatus: 'cancelled',
      endedBy: endedBy,
      requiredParticipantField: 'callerId',
      requiredParticipantId: callerId,
      allowedStatuses: const <String>{'calling', 'ringing'},
    );
    if (committed) {
      _callTrace('CALL_END_RTDB_OK', rideId: rideId);
    }
  }

  Future<bool> endAcceptedCall({
    required String rideId,
    required String endedBy,
  }) async {
    return endCallFromUserTap(rideId: rideId, endedBy: endedBy);
  }

  Future<bool> endCallFromUserTap({
    required String rideId,
    required String endedBy,
  }) async {
    final committed = await _transitionCallStatus(
      rideId: rideId,
      nextStatus: 'ended',
      endedBy: endedBy,
      allowedStatuses: const <String>{
        'calling',
        'ringing',
        'accepted',
        'joined',
      },
    );
    if (committed) {
      _callTrace('CALL_END_RTDB_OK', rideId: rideId);
    }
    return committed;
  }

  Future<void> endCallForRideLifecycle({
    required String rideId,
    required String endedBy,
  }) async {
    final committed = await _transitionCallStatus(
      rideId: rideId,
      nextStatus: 'ended',
      endedBy: endedBy,
      allowedStatuses: const <String>{
        'calling',
        'ringing',
        'accepted',
        'joined',
      },
    );
    if (committed) {
      _callTrace('CALL_END_RTDB_OK', rideId: rideId);
    }
  }

  Future<void> markMissedIfUnanswered({required String rideId}) async {
    await _transitionCallStatus(
      rideId: rideId,
      nextStatus: 'missed',
      endedBy: 'system',
      allowedStatuses: const <String>{'calling', 'ringing'},
    );
  }

  Future<void> updateParticipantState({
    required String rideId,
    required String uid,
    required bool joined,
    required bool muted,
    required bool speaker,
    bool? foreground,
    String? connectionState,
    ParticipantUpdateKind updateKind = ParticipantUpdateKind.avState,
    bool force = false,
  }) async {
    final normalizedRideId = rideId.trim();
    final normalizedUid = uid.trim();
    if (normalizedRideId.isEmpty || normalizedUid.isEmpty) {
      return;
    }
    if (_participantMirrorSuppressed) {
      return;
    }

    final normalizedConnectionState = connectionState?.trim();
    final effectiveConnectionState =
        normalizedConnectionState != null &&
                normalizedConnectionState.isNotEmpty
            ? normalizedConnectionState
            : null;

    if (updateKind == ParticipantUpdateKind.rtcConnection) {
      final cs = effectiveConnectionState ?? '';
      if (cs.isNotEmpty &&
          !_rtcConnectionStatesWorthPersisting.contains(cs)) {
        return;
      }
      if (_lastJoinRequest == null) {
        return;
      }
    }

    final participantPath =
        'calls/$normalizedRideId/participants/${_participantKey(normalizedUid)}';
    final cacheKey = '$normalizedRideId|${normalizedUid}';
    final nextLogical = _ParticipantLogicalState(
      joined: joined,
      muted: muted,
      speaker: speaker,
      foreground: foreground,
      connectionState: effectiveConnectionState,
    );
    final previousLogical = _lastParticipantLogicalState[cacheKey];

    if (!force &&
        previousLogical != null &&
        previousLogical.isEquivalentTo(nextLogical)) {
      debugPrint(
        'CALL_PARTICIPANT_UPDATE_SKIP_UNCHANGED path=$participantPath',
      );
      return;
    }

    final lastWriteAt = _lastParticipantWriteAt[cacheKey];
    final now = DateTime.now();
    if (!force &&
        updateKind != ParticipantUpdateKind.callLifecycle &&
        lastWriteAt != null &&
        now.difference(lastWriteAt) < _kParticipantWriteThrottle) {
      debugPrint(
        'CALL_PARTICIPANT_UPDATE_SKIP_THROTTLED path=$participantPath '
        'kind=${updateKind.name} ageMs=${now.difference(lastWriteAt).inMilliseconds}',
      );
      return;
    }

    final payload = <String, Object?>{
      'uid': normalizedUid,
      'joined': joined,
      'muted': muted,
      'speaker': speaker,
      'updatedAt': rtdb.ServerValue.timestamp,
    };

    if (foreground != null) {
      payload['foreground'] = foreground;
    }
    if (effectiveConnectionState != null) {
      payload['connectionState'] = effectiveConnectionState;
    }

    debugPrint(
      'CALL_PARTICIPANT_UPDATE path=$participantPath kind=${updateKind.name}',
    );

    try {
      await _participantRef(normalizedRideId, normalizedUid)
          .update(payload)
          .timeout(const Duration(seconds: 12));
      _lastParticipantLogicalState[cacheKey] = nextLogical;
      _lastParticipantWriteAt[cacheKey] = now;
    } on TimeoutException {
      if (_participantTimeoutLoggedPaths.add(participantPath)) {
        debugPrint(
          'CALL_PARTICIPANT_UPDATE_TIMEOUT path=$participantPath '
          'kind=${updateKind.name}',
        );
      }
    } catch (error) {
      if (isRealtimeDatabasePermissionDenied(error)) {
        debugPrint(
          'CALL_PARTICIPANT_UPDATE_DENIED path=$participantPath error=$error',
        );
        return;
      }
      rethrow;
    }
  }

  void clearParticipantWriteCache({String? rideId, String? uid}) {
    if (rideId == null && uid == null) {
      _lastParticipantLogicalState.clear();
      _lastParticipantWriteAt.clear();
      return;
    }
    final ridePrefix = rideId?.trim();
    final uidKey = uid?.trim();
    final keys = _lastParticipantLogicalState.keys.toList();
    for (final key in keys) {
      final parts = key.split('|');
      if (parts.length != 2) {
        continue;
      }
      if (ridePrefix != null &&
          ridePrefix.isNotEmpty &&
          parts[0] != ridePrefix) {
        continue;
      }
      if (uidKey != null && uidKey.isNotEmpty && parts[1] != uidKey) {
        continue;
      }
      _lastParticipantLogicalState.remove(key);
      _lastParticipantWriteAt.remove(key);
    }
  }

  Future<void> ensureJoinedVoiceChannel({
    required String channelId,
    required String uid,
    required bool speakerOn,
    required bool muted,
  }) async {
    if (!hasRtcConfiguration) {
      debugPrint('[CALL_CONFIG_MISSING] rideId=$channelId');
      throw RideCallException(unavailableUserMessage);
    }

    _disposed = false;
    _invalidTokenHandlingExhausted = false;
    _participantMirrorSuppressed = false;
    final normalizedRide = channelId.trim();

    final token = await fetchAgoraToken(normalizedRide, uid);
    if (token == null || token.isEmpty) {
      debugPrint(
        '[RideCall] join failed rideId=$normalizedRide error=token_unavailable',
      );
      throw const RideCallException(
        'Unable to connect voice calling right now. Please try again.',
      );
    }
    if (_callableAgoraChannelName != null &&
        _callableAgoraChannelName!.trim().isNotEmpty) {
      _lastJoinRequest = _VoiceJoinRequest(
        rideId: normalizedRide,
        agoraChannelId: _callableAgoraChannelName!.trim(),
        uid: uid,
        speakerOn: speakerOn,
        muted: muted,
      );
    }

    final desiredAgoraAppId = _activeAgoraAppId;
    final needsRecreateEngine =
        _engineReady &&
        _engine != null &&
        (_engineInitializedAppId ?? '').trim() != desiredAgoraAppId.trim();
    if (needsRecreateEngine) {
      await dispose();
      _disposed = false;
      _cancelReconnectTimer();
    }

    await _ensureRtcEngine();

    if (_lastJoinRequest?.rideId == normalizedRide &&
        _connectionState == ConnectionStateType.connectionStateConnected) {
      await setSpeakerOn(speakerOn);
      await setMuted(muted);
      return;
    }

    _cancelReconnectTimer();

    if (_lastJoinRequest != null && _lastJoinRequest!.rideId != normalizedRide) {
      await leaveVoiceChannel();
      await _ensureRtcEngine();
    }

    final joinChannel = _callableAgoraChannelName?.trim();
    if (joinChannel == null || joinChannel.isEmpty || _joinRtcUidOverride == null) {
      throw const RideCallException(
        'Voice call token is missing channel or rtc uid. Please try again.',
      );
    }

    _lastJoinRequest = _VoiceJoinRequest(
      rideId: normalizedRide,
      agoraChannelId: joinChannel,
      uid: uid,
      speakerOn: speakerOn,
      muted: muted,
    );

    _joinAttemptStartedAt = DateTime.now();
    _callTrace(
      'CALL_JOIN_START',
      rideId: normalizedRide,
      channel: _lastJoinRequest?.agoraChannelId,
      uid: uid,
    );
    debugPrint('[CALL_SERVICE] using agora appId: $desiredAgoraAppId');
    _setPhase(AgoraConnectionPhase.connecting);

    try {
      await _joinChannelWithToken(token: token, request: _lastJoinRequest!);
      _joinWatchdogTimer?.cancel();
      _joinWatchdogTimer = Timer(const Duration(seconds: 15), () {
        if (_connectionState != ConnectionStateType.connectionStateConnected) {
          const failureMessage = 'Could not connect call. Please try again.';
          _lastAgoraErrorMessage = failureMessage;
          final startedAt = _joinAttemptStartedAt;
          _callTrace(
            'CALL_JOIN_TIMEOUT',
            rideId: normalizedRide,
            channel: _lastJoinRequest?.agoraChannelId,
            uid: uid,
            elapsedMs: startedAt == null
                ? null
                : DateTime.now().difference(startedAt).inMilliseconds,
          );
          unawaited(
            _abortJoinAfterFailure(
              rideId: normalizedRide,
              uid: uid,
              error: failureMessage,
            ),
          );
        }
      });
    } catch (error) {
      await _abortJoinAfterFailure(
        rideId: normalizedRide,
        uid: uid,
        error: error,
      );
      rethrow;
    }
  }

  Future<void> waitForVoiceJoinConnected({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_connectionState ==
          ConnectionStateType.connectionStateConnected) {
        return;
      }
      if (_invalidTokenHandlingExhausted) {
        throw RideCallException(
          _lastAgoraErrorMessage ??
              'Could not connect call. Please try again.',
        );
      }
      if (_lastJoinRequest == null &&
          phaseNotifier.value == AgoraConnectionPhase.idle &&
          (phaseErrorNotifier.value?.trim().isNotEmpty ?? false)) {
        throw RideCallException(
          phaseErrorNotifier.value ??
              'Could not connect call. Please try again.',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final request = _lastJoinRequest;
    if (request != null &&
        _connectionState !=
            ConnectionStateType.connectionStateConnected) {
      const failureMessage = 'Could not connect call. Please try again.';
      await _abortJoinAfterFailure(
        rideId: request.rideId,
        uid: request.uid,
        error: failureMessage,
      );
      throw const RideCallException(failureMessage);
    }
  }

  Future<void> _abortJoinAfterFailure({
    required String rideId,
    required String uid,
    required Object error,
  }) async {
    _joinWatchdogTimer?.cancel();
    _joinWatchdogTimer = null;
    _cancelReconnectTimer();
    _cancelReconnectWatchdog();
    _reconnectInProgress = false;
    _reconnectAttempt = 0;
    _invalidTokenHandlingExhausted = true;
    _tokenRefreshInFlight = null;

    _callTrace(
      'CALL_JOIN_FAIL',
      rideId: rideId,
      channel: _lastJoinRequest?.agoraChannelId,
      uid: uid,
      error: error.toString(),
    );

    const failureMessage = 'Could not connect call. Please try again.';
    _lastAgoraErrorMessage = failureMessage;
    _suppressRtcParticipantSync = true;
    _intentionalLeaveInProgress = true;
    try {
      if (_engine != null &&
          (_joinedChannelId != null ||
              _connectionState !=
                  ConnectionStateType.connectionStateDisconnected)) {
        await _leaveEngineChannel();
      }
    } catch (leaveError) {
      debugPrint(
        '[RideCall] join abort leave failed rideId=$rideId error=$leaveError',
      );
    } finally {
      _intentionalLeaveInProgress = false;
      _suppressRtcParticipantSync = false;
    }

    _joinedChannelId = null;
    _connectionState = ConnectionStateType.connectionStateDisconnected;
    _lastJoinRequest = null;
    _joinRtcUidOverride = null;
    _setPhase(AgoraConnectionPhase.idle, error: failureMessage);
  }

  Future<void> _applyAudioRouteAfterJoin() async {
    final request = _lastJoinRequest;
    final engine = _engine;
    if (request == null || engine == null) {
      return;
    }
    if (_connectionState != ConnectionStateType.connectionStateConnected) {
      return;
    }

    try {
      await engine.setEnableSpeakerphone(request.speakerOn);
      await engine.muteLocalAudioStream(request.muted);
      _callTrace(
        'CALL_JOIN_AUDIO_READY',
        rideId: request.rideId,
        channel: request.agoraChannelId,
        uid: request.uid,
        speakerOn: request.speakerOn,
        muted: request.muted,
      );
      _callTrace(
        'CALL_AUDIO_ROUTE',
        rideId: request.rideId,
        speakerOn: request.speakerOn,
        muted: request.muted,
      );
    } catch (error) {
      debugPrint(
        '[RideCall] audio route after join failed rideId=${request.rideId} '
        'error=$error',
      );
    }
  }

  void _onJoinChannelSuccessCommon(RtcConnection connection, int elapsed) {
    final agoraCh = connection.channelId?.trim() ?? '';
    if (agoraCh.isEmpty) {
      return;
    }

    _joinedChannelId = agoraCh;
    _connectionState = ConnectionStateType.connectionStateConnected;
    _invalidTokenHandlingExhausted = false;
    _reconnectAttempt = 0;
    _cancelReconnectTimer();
    _cancelReconnectWatchdog();
    _joinWatchdogTimer?.cancel();
    _joinWatchdogTimer = null;
    _setPhase(AgoraConnectionPhase.connected);
    final firebaseRide = _lastJoinRequest?.rideId ?? '';
    _callTrace(
      'CALL_JOIN_OK',
      rideId: firebaseRide,
      channel: agoraCh,
      uid: _lastJoinRequest?.uid,
      elapsedMs: elapsed,
    );
    unawaited(_applyAudioRouteAfterJoin());
    unawaited(
      _syncRtcParticipantState(
        joined: true,
        connectionState: 'connected',
      ),
    );
    debugPrint(
      '[RideCall] join success rideId=$firebaseRide agoraChannel=$agoraCh',
    );
  }

  Future<void> leaveVoiceChannel() async {
    _participantMirrorSuppressed = true;
    _cancelReconnectTimer();
    _cancelReconnectWatchdog();
    _joinWatchdogTimer?.cancel();
    _joinWatchdogTimer = null;
    _reconnectInProgress = false;
    _reconnectAttempt = 0;
    final endedRideId = _lastJoinRequest?.rideId;
    final endedUid = _lastJoinRequest?.uid;
    _lastJoinRequest = null;
    if (endedRideId != null && endedUid != null) {
      clearParticipantWriteCache(rideId: endedRideId, uid: endedUid);
    }
    _setPhase(AgoraConnectionPhase.idle);

    if (_engine == null || _joinedChannelId == null) {
      _joinedChannelId = null;
      _connectionState = ConnectionStateType.connectionStateDisconnected;
      return;
    }

    await _leaveEngineChannel();
    _joinedChannelId = null;
    _connectionState = ConnectionStateType.connectionStateDisconnected;
  }

  Future<void> setMuted(bool muted) async {
    if (_engine == null) {
      return;
    }
    _updateJoinRequest(muted: muted);
    if (_connectionState != ConnectionStateType.connectionStateConnected) {
      return;
    }
    await _engine!.muteLocalAudioStream(muted);
    final rideId = _lastJoinRequest?.rideId ?? '';
    if (rideId.isNotEmpty) {
      _callTrace(
        'CALL_AUDIO_ROUTE',
        rideId: rideId,
        muted: muted,
        speakerOn: _lastJoinRequest?.speakerOn,
      );
    }
  }

  Future<void> setSpeakerOn(bool enabled) async {
    if (_engine == null) {
      return;
    }
    _updateJoinRequest(speakerOn: enabled);
    if (_connectionState != ConnectionStateType.connectionStateConnected) {
      return;
    }
    await _engine!.setEnableSpeakerphone(enabled);
    final rideId = _lastJoinRequest?.rideId ?? '';
    if (rideId.isNotEmpty) {
      _callTrace(
        'CALL_AUDIO_ROUTE',
        rideId: rideId,
        speakerOn: enabled,
        muted: _lastJoinRequest?.muted,
      );
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _cancelReconnectTimer();
    _cancelReconnectWatchdog();
    _joinWatchdogTimer?.cancel();
    _joinWatchdogTimer = null;
    _cachedTokenChannelId = null;
    _cachedTokenUserId = null;
    _cachedToken = null;
    _cachedJoinAgoraChannel = null;
    _cachedJoinRtcUid = null;
    _callableAgoraChannelName = null;
    _joinRtcUidOverride = null;
    _lastAgoraErrorCode = null;
    _lastAgoraErrorMessage = null;
    _lastConnectionReason = null;

    await leaveVoiceChannel();

    if (_engine != null && _eventHandler != null) {
      _engine!.unregisterEventHandler(_eventHandler!);
    }
    if (_engine != null) {
      await _engine!.release(sync: true);
    }

    _engine = null;
    _eventHandler = null;
    _engineReady = false;
    _engineInitializedAppId = null;
    _connectionState = ConnectionStateType.connectionStateDisconnected;
  }

  Future<String?> fetchAgoraToken(
    String channelId,
    String uid, {
    bool forceRefresh = false,
  }) async {
    final rideId = channelId.trim();
    final normalizedUserId = uid.trim();
    _callableAgoraChannelName = null;
    _joinRtcUidOverride = null;

    if (!hasRtcConfiguration) {
      debugPrint('[CALL_CONFIG_MISSING] rideId=$rideId');
      return null;
    }

    if (!forceRefresh &&
        _cachedToken != null &&
        _cachedToken!.isNotEmpty &&
        _cachedTokenChannelId == rideId &&
        _cachedTokenUserId == normalizedUserId) {
      _callableAgoraChannelName = _cachedJoinAgoraChannel;
      _joinRtcUidOverride = _cachedJoinRtcUid;
      return _cachedToken;
    }

    _callTrace(
      'CALL_TOKEN_REQUEST_START',
      rideId: rideId,
      channel: _serverAlignedChannelForRide(rideId),
      uid: normalizedUserId,
    );
    debugPrint('[CALL_SERVICE] invoking getRideCallRtcToken rideId=$rideId');

    Future<Map<String, dynamic>> requestToken({required bool force}) {
      return RideCloudFunctionsService()
          .getRideCallRtcToken(
            rideId: rideId,
            uid: normalizedUserId,
            force: force,
            forceClearStale: true,
          )
          .timeout(const Duration(seconds: 30));
    }

    try {
      var responseMap = await requestToken(force: forceRefresh);
      debugPrint('[CALL_SERVICE] callable response: $responseMap');
      final firstReason = responseMap['reason']?.toString().trim() ?? '';
      if (firstReason == 'call_already_active') {
        responseMap = await requestToken(force: true);
        debugPrint(
          '[CALL_SERVICE] callable retry (force) response: $responseMap',
        );
      }

      final ok = responseMap['success'] == true;
      final token = responseMap['token']?.toString().trim() ?? '';
      final callableAppId = responseMap['appId']?.toString().trim();
      if (callableAppId != null && callableAppId.isNotEmpty) {
        _callableAgoraAppId = callableAppId;
      }
      if (ok && token.isNotEmpty) {
        final channelName = responseMap['channelName']?.toString().trim() ?? '';
        final rtcUid = _parseRtcUidFromTokenResponse(responseMap['rtcUid']);
        if (channelName.isEmpty || rtcUid == null || rtcUid <= 0) {
          debugPrint(
            '[CALL_TOKEN_INVALID_RESPONSE] rideId=$rideId '
            'channelEmpty=${channelName.isEmpty} rtcUid=$rtcUid',
          );
          return null;
        }
        _applyCallableJoinIdentity(channelName: channelName, rtcUid: rtcUid);

        _cachedTokenChannelId = rideId;
        _cachedTokenUserId = normalizedUserId;
        _cachedToken = token;

        if (_lastJoinRequest?.rideId == rideId) {
          _lastJoinRequest = _VoiceJoinRequest(
            rideId: rideId,
            agoraChannelId: channelName,
            uid: normalizedUserId,
            speakerOn: _lastJoinRequest!.speakerOn,
            muted: _lastJoinRequest!.muted,
          );
        }

        _callTrace(
          'CALL_TOKEN_REQUEST_OK',
          rideId: rideId,
          channel: channelName,
          uid: rtcUid.toString(),
        );
        return token;
      }

      debugPrint(
        'RIDE_CALL_TOKEN_FAIL rideId=$rideId source=callable '
        'reason=${responseMap['reason']}',
      );
    } catch (error) {
      debugPrint('[CALL_TOKEN_FETCH_FAIL] rideId=$rideId source=callable error=$error');
    }

    _cachedTokenChannelId = null;
    _cachedTokenUserId = null;
    _cachedToken = null;
    _cachedJoinAgoraChannel = null;
    _cachedJoinRtcUid = null;
    return null;
  }

  Future<bool> _transitionCallStatus({
    required String rideId,
    required String nextStatus,
    required Set<String> allowedStatuses,
    String? endedBy,
    String? requiredParticipantField,
    String? requiredParticipantId,
    bool setAcceptedAt = false,
  }) async {
    final normalizedRideId = rideId.trim();
    await _keepRideCallSynced(normalizedRideId);

    late final rtdb.TransactionResult result;
    try {
      result = await _callRef(normalizedRideId)
          .runTransaction((currentValue) {
            final currentMap = _asStringDynamicMap(currentValue);
            final status = currentMap?['status']?.toString() ?? '';
            if (currentMap == null ||
                !allowedStatuses.contains(status.trim().toLowerCase())) {
              return rtdb.Transaction.abort();
            }

            final expectedParticipantId = requiredParticipantId?.trim() ?? '';
            if (requiredParticipantField != null &&
                expectedParticipantId.isNotEmpty) {
              final actualParticipantId =
                  currentMap[requiredParticipantField]?.toString().trim() ?? '';
              if (actualParticipantId != expectedParticipantId) {
                return rtdb.Transaction.abort();
              }
            }

            final nextMap = Map<String, Object?>.from(currentMap)
              ..['status'] = nextStatus
              ..['state'] = nextStatus
              ..['updatedAt'] = rtdb.ServerValue.timestamp;

            if (setAcceptedAt) {
              nextMap['acceptedAt'] = rtdb.ServerValue.timestamp;
              nextMap['endedAt'] = null;
              nextMap['endedBy'] = null;
            } else if (_isTerminalStatusString(nextStatus)) {
              nextMap['endedAt'] = rtdb.ServerValue.timestamp;
              nextMap['endedBy'] = endedBy;
            }

            return rtdb.Transaction.success(nextMap);
          }, applyLocally: false)
          .timeout(_kCallWriteTimeout);
    } on TimeoutException {
      throw const RideCallException(
        'Call update timed out. Please try again.',
      );
    }

    return result.committed;
  }

  Future<void> _ensureRtcEngine() async {
    if (_engineReady && _engine != null) {
      return;
    }

    final engine = _engine ?? createAgoraRtcEngine();
    final handler = RtcEngineEventHandler(
      onJoinChannelSuccess: (connection, elapsed) {
        _onJoinChannelSuccessCommon(connection, elapsed);
      },
      onRejoinChannelSuccess: (connection, elapsed) {
        _onJoinChannelSuccessCommon(connection, elapsed);
      },
      onLeaveChannel: (connection, stats) {
        _connectionState = ConnectionStateType.connectionStateDisconnected;
        _cancelReconnectWatchdog();
        _joinWatchdogTimer?.cancel();
        _joinWatchdogTimer = null;
        if (_lastJoinRequest == null) {
          _setPhase(AgoraConnectionPhase.idle);
        }
        if (!_suppressRtcParticipantSync && !_intentionalLeaveInProgress) {
          unawaited(
            _syncRtcParticipantState(
              joined: false,
              connectionState: 'disconnected',
            ),
          );
        }
        if (_intentionalLeaveInProgress || _lastJoinRequest == null) {
          _joinedChannelId = null;
        }
      },
      onConnectionLost: (connection) {
        final rideId = _lastJoinRequest?.rideId ?? '';
        if (rideId.isNotEmpty) {
          debugPrint('[RideCall] connection lost rideId=$rideId');
        }
        unawaited(
          _syncRtcParticipantState(
            joined: true,
            connectionState: 'connection_lost',
          ),
        );
        _scheduleReconnectWatchdog(reason: 'connection_lost');
        _scheduleReconnect(reason: 'connection_lost');
      },
      onConnectionStateChanged: (connection, state, reason) {
        _lastConnectionReason = reason;
        debugPrint('[CALL_STATE] $state reason=$reason');
        _connectionState = state;
        switch (state) {
          case ConnectionStateType.connectionStateConnected:
            _setPhase(AgoraConnectionPhase.connected);
            break;
          case ConnectionStateType.connectionStateConnecting:
            if (phaseNotifier.value != AgoraConnectionPhase.connected) {
              _setPhase(AgoraConnectionPhase.connecting);
            }
            break;
          case ConnectionStateType.connectionStateReconnecting:
            _setPhase(AgoraConnectionPhase.reconnecting);
            break;
          case ConnectionStateType.connectionStateFailed:
            _setPhase(
              AgoraConnectionPhase.failed,
              error: 'Could not connect call. Please try again.',
            );
            break;
          case ConnectionStateType.connectionStateDisconnected:
            if (_lastJoinRequest == null) {
              _setPhase(AgoraConnectionPhase.idle);
            }
            break;
        }
        final rideId = _lastJoinRequest?.rideId ?? '';
        if (rideId.isNotEmpty) {
          debugPrint(
            '[RideCall] connection state rideId=$rideId state=$state reason=$reason',
          );
        }

        if (state == ConnectionStateType.connectionStateConnected) {
          _reconnectAttempt = 0;
          _cancelReconnectTimer();
          _cancelReconnectWatchdog();
          unawaited(
            _syncRtcParticipantState(
              joined: true,
              connectionState: 'connected',
            ),
          );
          return;
        }

        if (reason ==
                ConnectionChangedReasonType.connectionChangedInvalidToken ||
            reason ==
                ConnectionChangedReasonType.connectionChangedTokenExpired) {
          unawaited(_handleInvalidTokenOnce(reason: reason.name));
          return;
        }

        if (_intentionalLeaveInProgress || _lastJoinRequest == null) {
          return;
        }

        final joined =
            state != ConnectionStateType.connectionStateDisconnected &&
            state != ConnectionStateType.connectionStateFailed;
        unawaited(
          _syncRtcParticipantState(
            joined: joined,
            connectionState: _connectionStateLabel(state),
          ),
        );

        if (state == ConnectionStateType.connectionStateReconnecting) {
          _scheduleReconnectWatchdog(reason: reason.name);
          return;
        }

        if (!_invalidTokenHandlingExhausted &&
            (state == ConnectionStateType.connectionStateFailed ||
                state == ConnectionStateType.connectionStateDisconnected)) {
          _scheduleReconnect(
            reason: reason.name,
            immediate: state == ConnectionStateType.connectionStateFailed,
          );
        }
      },
      onRequestToken: (connection) {
        unawaited(_renewAgoraToken(forceRefresh: true));
      },
      onTokenPrivilegeWillExpire: (connection, token) {
        unawaited(_renewAgoraToken(forceRefresh: true));
      },
      onError: (err, msg) {
        _lastAgoraErrorCode = err;
        _lastAgoraErrorMessage = msg;
        debugPrint('[CALL_ERROR] $err: $msg');
        debugPrint('[RideCall] agora error code=$err message=$msg');
        if (err == ErrorCodeType.errInvalidToken) {
          unawaited(_handleInvalidTokenOnce(reason: 'errInvalidToken'));
        }
      },
      onUserJoined: (connection, remoteUid, elapsed) {
        final firebaseRide = _lastJoinRequest?.rideId ?? '';
        if (firebaseRide.isNotEmpty) {
          _callTrace(
            'CALL_REMOTE_JOINED',
            rideId: firebaseRide,
            channel: connection.channelId,
            remoteUid: remoteUid,
            elapsedMs: elapsed,
          );
          if (phaseNotifier.value != AgoraConnectionPhase.connected) {
            _setPhase(AgoraConnectionPhase.connected);
            unawaited(
              _syncRtcParticipantState(
                joined: true,
                connectionState: 'connected',
              ),
            );
          }
        }
      },
      onUserOffline: (connection, remoteUid, reason) {
        debugPrint('[CALL_REMOTE_LEFT] uid=$remoteUid reason=$reason');
      },
    );

    _engine = engine;
    _eventHandler = handler;

    await engine.initialize(
      RtcEngineContext(
        appId: _activeAgoraAppId,
        channelProfile: ChannelProfileType.channelProfileCommunication,
      ),
    );
    _engineInitializedAppId = _activeAgoraAppId;
    engine.registerEventHandler(handler);
    await engine.enableAudio();
    await engine.disableVideo();
    await engine.setClientRole(role: ClientRoleType.clientRoleBroadcaster);

    _engineReady = true;
  }

  Future<void> _joinChannelWithToken({
    required String token,
    required _VoiceJoinRequest request,
  }) async {
    final engine = _engine;
    if (engine == null) {
      throw const RideCallException(
        'Unable to connect voice calling right now. Please try again.',
      );
    }

    final rtcUid = _joinRtcUidOverride;
    if (rtcUid == null) {
      throw const RideCallException(
        'Voice call token is missing rtc uid. Please try again.',
      );
    }
    final tokenPreview = token.length > 20 ? '${token.substring(0, 20)}...' : token;
    final appId = _activeAgoraAppId;
    debugPrint(
      '[CALL] appId=${appId.length} chars, channel=${request.agoraChannelId}, '
      'rtcUid=$rtcUid firebaseUid=${request.uid}, token=$tokenPreview',
    );
    debugPrint(
      '[CALL_SERVICE] joining channel: ${request.agoraChannelId} with uid: $rtcUid',
    );
    _callTrace(
      'CALL_JOIN_ENGINE_READY',
      rideId: request.rideId,
      channel: request.agoraChannelId,
      uid: request.uid,
    );
    await engine.joinChannel(
      token: token,
      channelId: request.agoraChannelId,
      uid: rtcUid,
      options: const ChannelMediaOptions(
        channelProfile: ChannelProfileType.channelProfileCommunication,
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
        autoSubscribeAudio: true,
        autoSubscribeVideo: false,
        publishMicrophoneTrack: true,
        enableAudioRecordingOrPlayout: true,
      ),
    );

    _joinedChannelId = request.agoraChannelId;
    _connectionState = ConnectionStateType.connectionStateConnecting;
  }

  Future<void> _handleInvalidTokenOnce({required String reason}) async {
    if (_invalidTokenHandlingExhausted ||
        _disposed ||
        _intentionalLeaveInProgress) {
      return;
    }
    final request = _lastJoinRequest;
    final engine = _engine;
    if (request == null || engine == null) {
      return;
    }

    _cancelReconnectTimer();
    _cancelReconnectWatchdog();

    if (_tokenRefreshInFlight != null) {
      await _tokenRefreshInFlight;
      return;
    }

    _tokenRefreshInFlight = _handleInvalidTokenOnceBody(
      request: request,
      engine: engine,
      reason: reason,
    );
    try {
      await _tokenRefreshInFlight;
    } finally {
      _tokenRefreshInFlight = null;
    }
  }

  Future<void> _handleInvalidTokenOnceBody({
    required _VoiceJoinRequest request,
    required RtcEngine engine,
    required String reason,
  }) async {
    _callTrace(
      'CALL_TOKEN_INVALID',
      rideId: request.rideId,
      channel: request.agoraChannelId,
      uid: request.uid,
      error: reason,
    );

    try {
      final token = await fetchAgoraToken(
        request.rideId,
        request.uid,
        forceRefresh: true,
      );
      if (token == null || token.isEmpty) {
        throw const RideCallException(
          'Unable to refresh voice call token.',
        );
      }
      await engine.renewToken(token);
      debugPrint(
        '[RideCall] invalid-token refresh rideId=${request.rideId} reason=$reason',
      );
      for (var attempt = 0; attempt < 15; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        if (_connectionState ==
            ConnectionStateType.connectionStateConnected) {
          return;
        }
      }
      throw const RideCallException('Voice call token was rejected by Agora.');
    } catch (error) {
      _invalidTokenHandlingExhausted = true;
      await _abortJoinAfterFailure(
        rideId: request.rideId,
        uid: request.uid,
        error: error,
      );
    }
  }

  Future<void> _renewAgoraToken({required bool forceRefresh}) async {
    if (_invalidTokenHandlingExhausted) {
      return;
    }
    if (_tokenRefreshInFlight != null) {
      await _tokenRefreshInFlight;
      return;
    }

    final request = _lastJoinRequest;
    final engine = _engine;
    if (_disposed || request == null || engine == null) {
      return;
    }

    _tokenRefreshInFlight = _renewAgoraTokenBody(
      request: request,
      engine: engine,
      forceRefresh: forceRefresh,
    );
    try {
      await _tokenRefreshInFlight;
    } finally {
      _tokenRefreshInFlight = null;
    }
  }

  Future<void> _renewAgoraTokenBody({
    required _VoiceJoinRequest request,
    required RtcEngine engine,
    required bool forceRefresh,
  }) async {
    final token = await fetchAgoraToken(
      request.rideId,
      request.uid,
      forceRefresh: forceRefresh,
    );
    if (token == null || token.isEmpty) {
      if (!_invalidTokenHandlingExhausted) {
        _invalidTokenHandlingExhausted = true;
        await _abortJoinAfterFailure(
          rideId: request.rideId,
          uid: request.uid,
          error: 'token_refresh_failed',
        );
      }
      return;
    }

    try {
      await engine.renewToken(token);
      debugPrint('[RideCall] token renewed rideId=${request.rideId}');
    } catch (error) {
      debugPrint(
        '[RideCall] token renew failed rideId=${request.rideId} error=$error',
      );
      if (!_invalidTokenHandlingExhausted) {
        await _handleInvalidTokenOnce(reason: 'renew_token_failed');
      }
    }
  }

  void _scheduleReconnect({required String reason, bool immediate = false}) {
    if (_invalidTokenHandlingExhausted ||
        _disposed ||
        _intentionalLeaveInProgress ||
        _lastJoinRequest == null ||
        _engine == null) {
      return;
    }

    if (_connectionState == ConnectionStateType.connectionStateConnected ||
        _connectionState == ConnectionStateType.connectionStateConnecting ||
        _connectionState == ConnectionStateType.connectionStateReconnecting ||
        _reconnectInProgress ||
        (_reconnectTimer?.isActive ?? false)) {
      return;
    }

    final delays = <int>[1, 2, 4, 8, 15];
    final delayIndex = _reconnectAttempt >= delays.length
        ? delays.length - 1
        : _reconnectAttempt;
    final delay = immediate
        ? Duration.zero
        : Duration(seconds: delays[delayIndex]);

    debugPrint(
      '[RideCall] reconnect scheduled rideId=${_lastJoinRequest?.rideId ?? ''} '
      'reason=$reason delayMs=${delay.inMilliseconds}',
    );

    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      unawaited(_attemptReconnect(reason: reason));
    });
  }

  Future<void> _attemptReconnect({required String reason}) async {
    if (_invalidTokenHandlingExhausted) {
      return;
    }
    final request = _lastJoinRequest;
    final engine = _engine;
    if (_disposed || request == null || engine == null) {
      return;
    }

    if (_connectionState == ConnectionStateType.connectionStateConnected ||
        _connectionState == ConnectionStateType.connectionStateConnecting ||
        _connectionState == ConnectionStateType.connectionStateReconnecting) {
      return;
    }

    _reconnectInProgress = true;
    _reconnectAttempt += 1;

    try {
      final token = await fetchAgoraToken(
        request.rideId,
        request.uid,
        forceRefresh: true,
      );
      if (token == null || token.isEmpty) {
        throw const RideCallException(
          'Unable to connect voice calling right now. Please try again.',
        );
      }

      var joinRequest = request;
      if (_callableAgoraChannelName != null &&
          _callableAgoraChannelName!.trim().isNotEmpty) {
        joinRequest = _VoiceJoinRequest(
          rideId: request.rideId,
          agoraChannelId: _callableAgoraChannelName!.trim(),
          uid: request.uid,
          speakerOn: request.speakerOn,
          muted: request.muted,
        );
        _lastJoinRequest = joinRequest;
      }

      await _leaveEngineChannel();
      await _joinChannelWithToken(token: token, request: joinRequest);

      debugPrint(
        '[RideCall] reconnect attempt started rideId=${request.rideId} '
        'reason=$reason attempt=$_reconnectAttempt',
      );
    } catch (error) {
      debugPrint(
        '[RideCall] reconnect failed rideId=${request.rideId} '
        'reason=$reason error=$error',
      );
      _scheduleReconnect(reason: 'retry_$reason');
    } finally {
      _reconnectInProgress = false;
    }
  }

  Future<void> _leaveEngineChannel() async {
    final engine = _engine;
    if (engine == null) {
      return;
    }

    _intentionalLeaveInProgress = true;
    try {
      await engine.leaveChannel();
    } catch (error) {
      debugPrint('[RideCall] leave failed error=$error');
    } finally {
      _intentionalLeaveInProgress = false;
    }
  }

  void _cancelReconnectTimer() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  void _scheduleReconnectWatchdog({required String reason}) {
    if (_disposed ||
        _intentionalLeaveInProgress ||
        _lastJoinRequest == null ||
        _engine == null ||
        (_reconnectWatchdogTimer?.isActive ?? false)) {
      return;
    }

    _reconnectWatchdogTimer = Timer(const Duration(seconds: 8), () {
      _reconnectWatchdogTimer = null;

      if (_disposed ||
          _intentionalLeaveInProgress ||
          _lastJoinRequest == null ||
          _engine == null) {
        return;
      }

      if (_connectionState == ConnectionStateType.connectionStateConnected) {
        return;
      }

      _scheduleReconnect(reason: 'watchdog_$reason', immediate: true);
    });
  }

  void _cancelReconnectWatchdog() {
    _reconnectWatchdogTimer?.cancel();
    _reconnectWatchdogTimer = null;
  }

  Future<void> _syncRtcParticipantState({
    required bool joined,
    required String connectionState,
  }) async {
    if (_suppressRtcParticipantSync) {
      return;
    }
    final request = _lastJoinRequest;
    if (request == null) {
      return;
    }

    try {
      await updateParticipantState(
        rideId: request.rideId,
        uid: request.uid,
        joined: joined,
        muted: request.muted,
        speaker: request.speakerOn,
        connectionState: connectionState,
        updateKind: ParticipantUpdateKind.rtcConnection,
      );
    } catch (error) {
      debugPrint(
        '[RideCall] participant sync failed rideId=${request.rideId} '
        'uid=${request.uid} error=$error',
      );
    }
  }

  void _updateJoinRequest({bool? muted, bool? speakerOn}) {
    final request = _lastJoinRequest;
    if (request == null) {
      return;
    }

    _lastJoinRequest = _VoiceJoinRequest(
      rideId: request.rideId,
      agoraChannelId: request.agoraChannelId,
      uid: request.uid,
      speakerOn: speakerOn ?? request.speakerOn,
      muted: muted ?? request.muted,
    );
  }

  rtdb.DatabaseReference _callRef(String rideId) {
    return _database.ref('calls/${rideId.trim()}');
  }

  rtdb.DatabaseReference _participantRef(String rideId, String uid) {
    return _callRef(
      rideId,
    ).child('participants/${_participantKey(uid.trim())}');
  }

  rtdb.Query _callsByReceiverQuery(String receiverId) {
    return _database
        .ref('calls')
        .orderByChild('receiverId')
        .equalTo(receiverId.trim())
        .limitToLast(25);
  }

  Future<void> _keepRideCallSynced(String rideId) async {
    final normalizedRideId = rideId.trim();
    if (normalizedRideId.isEmpty || !_syncedRideIds.add(normalizedRideId)) {
      return;
    }

    try {
      await _callRef(normalizedRideId).keepSynced(true);
    } catch (error) {
      _syncedRideIds.remove(normalizedRideId);
      debugPrint(
        '[RideCall] keepSynced failed rideId=$normalizedRideId error=$error',
      );
    }
  }

  Future<void> _keepReceiverCallsSynced(String receiverId) async {
    // No-op: root /calls keepSynced is denied; ride-scoped sync only.
  }
}

String _resolveAgoraAppId(String? override) {
  final explicit = (override ?? '').trim();
  if (explicit.isNotEmpty) {
    return explicit;
  }

  const appId = String.fromEnvironment(
    'AGORA_APP_ID',
    defaultValue: 'dcbfe108c8c54bee946c7e9b4aac442c',
  );
  return appId.trim();
}

String _resolveChannelPrefix() {
  const prefix = String.fromEnvironment('AGORA_CHANNEL_PREFIX');
  return prefix.trim();
}

RideCallStatus? _parseStatus(String? raw) {
  switch ((raw ?? '').trim().toLowerCase()) {
    case 'calling':
    case 'ringing':
      return RideCallStatus.ringing;
    case 'joined':
    case 'accepted':
    case 'connected':
      return RideCallStatus.joined;
    case 'rejected':
    case 'declined':
      return RideCallStatus.declined;
    case 'ended':
      return RideCallStatus.ended;
    case 'missed':
      return RideCallStatus.missed;
    case 'cancelled':
      return RideCallStatus.cancelled;
    default:
      return null;
  }
}

Map<String, dynamic>? _asStringDynamicMap(dynamic value) {
  if (value is! Map) {
    return null;
  }

  return value.map<String, dynamic>(
    (key, nestedValue) => MapEntry(key.toString(), nestedValue),
  );
}

int? _asInt(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value);
  }
  return null;
}

String _resolveCallerId(Map<String, dynamic> map) {
  final explicit = map['callerId']?.toString().trim() ?? '';
  if (explicit.isNotEmpty) {
    return explicit;
  }

  final riderId = map['rider_id']?.toString().trim() ??
      map['riderId']?.toString().trim() ??
      '';
  final driverId = map['driver_id']?.toString().trim() ??
      map['driverId']?.toString().trim() ??
      '';
  final startedBy = map['started_by']?.toString().trim().toLowerCase() ?? '';

  if (startedBy == 'driver') {
    return driverId;
  }
  if (startedBy == 'rider') {
    return riderId;
  }

  return '';
}

String _resolveReceiverId(Map<String, dynamic> map) {
  final explicit = map['receiverId']?.toString().trim() ?? '';
  if (explicit.isNotEmpty) {
    return explicit;
  }

  final riderId = map['rider_id']?.toString().trim() ??
      map['riderId']?.toString().trim() ??
      '';
  final driverId = map['driver_id']?.toString().trim() ??
      map['driverId']?.toString().trim() ??
      '';
  final startedBy = map['started_by']?.toString().trim().toLowerCase() ?? '';

  if (startedBy == 'driver') {
    return riderId;
  }
  if (startedBy == 'rider') {
    return driverId;
  }

  return '';
}

bool _isActiveStatusString(String rawStatus) {
  final normalized = rawStatus.trim().toLowerCase();
  return normalized == 'calling' ||
      normalized == 'ringing' ||
      normalized == 'accepted';
}

bool _isTerminalStatusString(String rawStatus) {
  final normalized = rawStatus.trim().toLowerCase();
  return normalized == 'declined' ||
      normalized == 'ended' ||
      normalized == 'missed' ||
      normalized == 'cancelled';
}

String _participantKey(String uid) {
  return uid
      .replaceAll('.', '_')
      .replaceAll('#', '_')
      .replaceAll('\$', '_')
      .replaceAll('[', '_')
      .replaceAll(']', '_')
      .replaceAll('/', '_');
}

String _connectionStateLabel(ConnectionStateType state) {
  return switch (state) {
    ConnectionStateType.connectionStateConnected => 'connected',
    ConnectionStateType.connectionStateConnecting => 'connecting',
    ConnectionStateType.connectionStateReconnecting => 'reconnecting',
    ConnectionStateType.connectionStateDisconnected => 'disconnected',
    ConnectionStateType.connectionStateFailed => 'failed',
  };
}

int? _parseRtcUidFromTokenResponse(Object? raw) {
  if (raw is int) {
    return raw;
  }
  if (raw is num) {
    return raw.toInt();
  }
  if (raw is String) {
    return int.tryParse(raw.trim());
  }
  return null;
}

String _serverAlignedChannelForRide(String rideId) {
  final normalized = rideId.trim();
  var channel = 'nexride_$normalized'.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
  if (channel.length > 64) {
    channel = channel.substring(0, 64);
  }
  return channel;
}
