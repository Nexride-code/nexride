import 'dart:async';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/foundation.dart';

import '../support/call_trace_support.dart';
import '../support/realtime_database_error_support.dart';
import '../support/rtdb_read_support.dart';
import 'call_remote_peer_watchdog.dart';
import 'ride_cloud_functions_service.dart';

enum CallSessionKind {
  ride,
  delivery,
}

const int kDeliveryCallRingTimeoutSeconds = 60;

enum RideCallStatus {
  ringing,
  joined,
  ended,
  /// Legacy RTDB tokens mapped to [joined].
  accepted,
  declined,
  missed,
  cancelled,
  failed,
}

/// UI-facing phase of the local Agora RTC engine.
///
/// Drives the call overlay's "Connecting..." vs duration vs error display
/// independently from the RTDB [RideCallStatus] (which only tracks the
/// signalling lifecycle, not whether audio is actually flowing).
enum AgoraConnectionPhase {
  idle,
  connecting,
  /// Local Agora join succeeded; waiting for remote [onUserJoined].
  waitingForRemote,
  /// Remote peer joined — two-way audio path confirmed.
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
    this.callId,
    this.createdAt,
    this.expiresAt,
    this.acceptedAt,
    this.answeredAt,
    this.endedAt,
    this.endedBy,
  });

  final String rideId;
  final String callerId;
  final String receiverId;
  final RideCallStatus status;
  final String channelId;
  final String callerUid;
  final String? callId;
  final int? createdAt;
  final int? expiresAt;
  final int? acceptedAt;
  final int? answeredAt;
  final int? endedAt;
  final String? endedBy;

  bool get isCalling => status == RideCallStatus.ringing;
  bool get isRinging => isCalling;
  bool get isAccepted =>
      status == RideCallStatus.joined || status == RideCallStatus.accepted;
  bool get isActive => isAccepted;
  bool get isTerminal =>
      status == RideCallStatus.declined ||
      status == RideCallStatus.ended ||
      status == RideCallStatus.missed ||
      status == RideCallStatus.cancelled ||
      status == RideCallStatus.failed;

  DateTime? get createdAtDateTime => createdAt == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(createdAt!);
  DateTime? get expiresAtDateTime => expiresAt == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(expiresAt!);
  DateTime? get acceptedAtDateTime => acceptedAt == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(acceptedAt!);
  DateTime? get answeredAtDateTime {
    final answered = answeredAt ?? acceptedAt;
    return answered == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(answered);
  }
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
      rideId: map['delivery_id']?.toString() ??
          map['ride_id']?.toString() ??
          rideId,
      callerId: callerId,
      receiverId: receiverId,
      status: status,
      channelId:
          map['channelId']?.toString() ??
          map['agora_channel']?.toString() ??
          map['channelName']?.toString() ??
          map['channel_id']?.toString() ??
          rideId,
      callerUid: callerId,
      callId: map['call_id']?.toString() ?? map['sessionId']?.toString(),
      createdAt: _asInt(map['createdAt'] ?? map['created_at'] ?? map['startedAt']),
      expiresAt: _asInt(map['expires_at'] ?? map['expiresAt']),
      acceptedAt: _asInt(map['acceptedAt'] ?? map['accepted_at']),
      answeredAt: _asInt(map['answeredAt'] ?? map['answered_at']),
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
    this.kind = CallSessionKind.ride,
  });

  /// RTDB context id (`call_sessions/{id}`) and token cache key.
  final String rideId;

  /// Agora `joinChannel` channel name (may differ when using callable tokens).
  final String agoraChannelId;
  final String uid;
  final bool speakerOn;
  final bool muted;
  final CallSessionKind kind;
}

class CallService {
  CallService({
    rtdb.FirebaseDatabase? database,
    String? agoraAppId,
    String callTraceRole = '',
  })  : _database = database ?? rtdb.FirebaseDatabase.instance,
        _defaultAgoraAppId = _resolveAgoraAppId(agoraAppId),
        _callTraceRole = callTraceRole.trim();

  static String sessionPath(
    String contextId, {
    required CallSessionKind kind,
  }) {
    final id = contextId.trim();
    if (id.isEmpty) {
      return 'call_sessions/';
    }
    return 'call_sessions/$id';
  }

  /// Canonical mirrored call session node for cross-peer sync.
  /// Canonical shared call state at `calls/{callId}` (both apps listen here).
  static String sharedCallPath(String callId) {
    final id = callId.trim();
    if (id.isEmpty) {
      return 'calls/';
    }
    return 'calls/$id';
  }

  static String rideCallMirrorPath(String rideId, String callId) {
    final rid = rideId.trim();
    final cid = callId.trim();
    if (rid.isEmpty || cid.isEmpty) {
      return 'ride_calls/';
    }
    return 'ride_calls/$rid/$cid';
  }

  static String rideCallMirrorRootPath(String rideId) {
    final rid = rideId.trim();
    if (rid.isEmpty) {
      return 'ride_calls/';
    }
    return 'ride_calls/$rid';
  }

  /// Legacy RTDB paths — read-only fallback when [call_sessions/{id}] is empty.
  static String? legacySessionPath(String contextId, CallSessionKind kind) {
    final id = contextId.trim();
    if (id.isEmpty) {
      return null;
    }
    return switch (kind) {
      CallSessionKind.delivery => 'delivery_call_sessions/$id',
      CallSessionKind.ride => 'calls/$id',
    };
  }

  /// Agora channel name aligned with Cloud Functions `channelNameForRide`.
  static String serverAlignedChannelForContext(String contextId) {
    return _serverAlignedChannelForRide(contextId);
  }

  /// Context id used for RTDB session path and Agora token requests.
  static String callContextId(RideCallSession session) => session.rideId.trim();

  final String _callTraceRole;
  final rtdb.FirebaseDatabase _database;
  final String _defaultAgoraAppId;
  String? _callableAgoraAppId;
  final RideCloudFunctionsService _cloudFunctionsService =
      RideCloudFunctionsService();
  static const Duration _kCallReadTimeout = Duration(seconds: 12);
  static const Duration _kCallWriteTimeout = Duration(seconds: 30);
  final String _agoraChannelPrefix = _resolveChannelPrefix();
  final Set<String> _syncedRideIds = <String>{};
  static const Duration _kParticipantWriteThrottle = Duration(seconds: 10);
  static const Set<String> _rtcConnectionStatesWorthPersisting = <String>{
    'connected',
    'disconnected',
    'connection_lost',
  };
  final Map<String, _ParticipantLogicalState> _lastParticipantLogicalState =
      <String, _ParticipantLogicalState>{};
  final Map<String, DateTime> _lastParticipantWriteAt = <String, DateTime>{};
  final Map<String, String> _callIdByContext = <String, String>{};

  String _activeCallIdForContext(String contextId) =>
      _callIdByContext[contextId.trim()] ?? contextId.trim();

  RtcEngine? _engine;
  RtcEngineEventHandler? _eventHandler;
  bool _engineReady = false;
  String? _engineInitializedAppId;
  bool _disposed = false;
  bool _endingCall = false;
  bool _appLifecycleForeground = true;
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

  static const Duration kRemotePeerJoinWatchdogInterval = Duration(seconds: 13);
  static const Duration kRemotePeerJoinMaxWait = Duration(seconds: 40);
  final RemotePeerWatchdogPolicy _remotePeerWatchdogPolicy =
      const RemotePeerWatchdogPolicy();

  bool _remotePeerJoined = false;
  Timer? _remotePeerJoinWatchdog;
  DateTime? _localAgoraJoinedAt;
  int _remotePeerWatchdogFireCount = 0;

  /// Public, UI-driven view of the local Agora connection. The overlay reads
  /// this to render `Connecting...` / live duration / `Could not connect call`.
  final ValueNotifier<AgoraConnectionPhase> phaseNotifier =
      ValueNotifier<AgoraConnectionPhase>(AgoraConnectionPhase.idle);
  final ValueNotifier<String?> phaseErrorNotifier =
      ValueNotifier<String?>(null);
  final ValueNotifier<bool> remotePeerJoinedNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<String?> remotePeerStatusNotifier =
      ValueNotifier<String?>(null);

  void _setPhase(AgoraConnectionPhase phase, {String? error}) {
    if (phaseNotifier.value != phase) {
      phaseNotifier.value = phase;
    }
    phaseErrorNotifier.value = error;
  }

  bool get isLocalVoiceJoined =>
      _connectionState == ConnectionStateType.connectionStateConnected &&
      (_joinedChannelId?.trim().isNotEmpty ?? false);

  bool get remotePeerJoined => _remotePeerJoined;

  void notifyAppLifecycleForeground(bool foreground) {
    _appLifecycleForeground = foreground;
    if (!foreground) {
      _cancelReconnectWatchdog();
      return;
    }
    if (_lastJoinRequest != null &&
        _connectionState == ConnectionStateType.connectionStateReconnecting) {
      _scheduleReconnect(reason: 'app_resumed', immediate: true);
    }
  }

  /// True only after [onUserJoined] — not merely local [onJoinChannelSuccess].
  bool get isVoiceConnected =>
      _remotePeerJoined &&
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

  Stream<rtdb.DatabaseEvent> observeCall(
    String rideId, {
    CallSessionKind kind = CallSessionKind.ride,
  }) {
    final normalizedRideId = rideId.trim();
    unawaited(_keepCallSynced(normalizedRideId, kind: kind));
    return _callRef(normalizedRideId, kind: kind).onValue;
  }

  Stream<rtdb.DatabaseEvent> observeSharedCall(String callId) {
    final normalizedCallId = callId.trim();
    if (normalizedCallId.isEmpty) {
      return const Stream<rtdb.DatabaseEvent>.empty();
    }
    return _database.ref(CallService.sharedCallPath(normalizedCallId)).onValue;
  }

  /// Whether [calls/{callId}] status is terminal (ended/missed/failed/etc.).
  static bool isSharedCallTerminalStatus(String? raw) {
    return _isTerminalStatusString(raw ?? '');
  }

  /// Reads status/state from a [calls/{callId}] snapshot value.
  static String? sharedCallStatusFromSnapshot(dynamic value) {
    final map = _asStringDynamicMap(value);
    if (map == null) {
      return null;
    }
    final status = _effectiveStatusString(map);
    return status.isEmpty ? null : status;
  }

  Stream<rtdb.DatabaseEvent> observeRideCallMirror(
    String rideId, {
    CallSessionKind kind = CallSessionKind.ride,
  }) {
    final normalizedRideId = rideId.trim();
    if (normalizedRideId.isEmpty) {
      return const Stream<rtdb.DatabaseEvent>.empty();
    }
    return _database
        .ref(CallService.rideCallMirrorRootPath(normalizedRideId))
        .onValue;
  }

  Stream<rtdb.DatabaseEvent> observeCallsForReceiver(String receiverId) {
    // Root /calls queries are denied — use observeCall(rideId) instead.
    return const Stream<rtdb.DatabaseEvent>.empty();
  }

  Future<RideCallSession?> fetchCall(
    String rideId, {
    CallSessionKind kind = CallSessionKind.ride,
  }) async {
    final normalizedRideId = rideId.trim();
    await _keepCallSynced(normalizedRideId, kind: kind);
    final sessionPath = CallService.sessionPath(normalizedRideId, kind: kind);
    rtdb.DataSnapshot? snapshot;
    try {
      snapshot = await runRtdbQueryGetOrNull(
        query: _callRef(normalizedRideId, kind: kind),
        path: sessionPath,
        source: 'call_service.fetch_call',
      ).timeout(_kCallReadTimeout);
    } on TimeoutException {
      throw const RideCallException(
        'Call service timed out. Please try again.',
      );
    }
    var session = snapshot == null
        ? null
        : RideCallSession.fromSnapshotValue(normalizedRideId, snapshot.value);
    if (session != null) {
      return session;
    }

    final legacyPath = legacySessionPath(normalizedRideId, kind);
    if (legacyPath == null) {
      return null;
    }
    try {
      final legacySnapshot = await runRtdbQueryGetOrNull(
        query: _database.ref(legacyPath),
        path: legacyPath,
        source: 'call_service.fetch_call_legacy',
      ).timeout(_kCallReadTimeout);
      session = legacySnapshot == null
          ? null
          : RideCallSession.fromSnapshotValue(
              normalizedRideId,
              legacySnapshot.value,
            );
      if (session != null) {
        debugPrint(
          'CALL_LEGACY_READ contextId=$normalizedRideId path=$legacyPath kind=${kind.name}',
        );
      }
    } on TimeoutException {
      throw const RideCallException(
        'Call service timed out. Please try again.',
      );
    }
    return session;
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
    debugPrint('[CALL_LOG_LOAD_START] rideId=$rideId role=rider');
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
    CallSessionKind kind = CallSessionKind.ride,
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
    final callerRole = normalizedStartedBy == 'driver' ? 'driver' : 'rider';
    final calleeRole = normalizedStartedBy == 'driver' ? 'rider' : 'driver';
    final sessionPath = CallService.sessionPath(normalizedRideId, kind: kind);

    await _keepCallSynced(normalizedRideId, kind: kind);

    if (kind == CallSessionKind.delivery) {
      if (normalizedStartedBy == 'driver') {
        debugPrint(
          'CALL_START deliveryId=$normalizedRideId caller=driver callee=rider path=$sessionPath',
        );
      } else {
        debugPrint(
          'CALL_START deliveryId=$normalizedRideId caller=rider callee=driver path=$sessionPath',
        );
      }
    } else {
      debugPrint(
        'CALL_START rideId=$normalizedRideId caller=$callerId callee=$receiverId path=$sessionPath',
      );
    }

    final plannedChannelId =
        CallService.serverAlignedChannelForContext(normalizedRideId);

    late final rtdb.TransactionResult transaction;
    try {
      transaction = await _callRef(normalizedRideId, kind: kind)
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
            final callId = '${DateTime.now().millisecondsSinceEpoch}';
            final channelName = plannedChannelId;
            final expiresAt = DateTime.now().millisecondsSinceEpoch +
                (kDeliveryCallRingTimeoutSeconds * 1000);
            final payload = <String, Object?>{
              'call_id': callId,
              'ride_id': normalizedRideId,
              'rider_id': normalizedRiderId,
              'driver_id': normalizedDriverId,
              'started_by': normalizedStartedBy,
              'callerId': callerId,
              'receiverId': receiverId,
              'callerUid': callerId,
              'calleeUid': receiverId,
              'channelId': channelName,
              'channelName': channelName,
              'status': 'ringing',
              'state': 'ringing',
              'sessionId': callId,
              'callAttempt': priorAttempt + 1,
              'startedAt': rtdb.ServerValue.timestamp,
              'createdAt': rtdb.ServerValue.timestamp,
              'updatedAt': rtdb.ServerValue.timestamp,
              'acceptedAt': null,
              'answeredAt': null,
              'endedAt': null,
              'endedBy': null,
            };
            if (kind == CallSessionKind.delivery) {
              payload['delivery_id'] = normalizedRideId;
              payload['caller_uid'] = callerId;
              payload['callee_uid'] = receiverId;
              payload['caller_role'] = callerRole;
              payload['callee_role'] = calleeRole;
              payload['agora_channel'] = channelName;
              payload['created_at'] = rtdb.ServerValue.timestamp;
              payload['expires_at'] = expiresAt;
            }
            return rtdb.Transaction.success(payload);
          }, applyLocally: false)
          .timeout(_kCallWriteTimeout);
    } on TimeoutException {
      debugPrint(
        'CALL_ERROR rideId=$normalizedRideId reason=request_outgoing_timeout',
      );
      throw const RideCallException(
        'Call request timed out. Please try again.',
      );
    }

    if (transaction.committed) {
      debugPrint(
        'CALL_RINGING contextId=$normalizedRideId channelId=$plannedChannelId callerUid=$callerId calleeUid=$receiverId kind=${kind.name}',
      );
      _callTrace('CALL_NEW_SESSION_WRITE_OK', rideId: normalizedRideId);
      _callTrace('CALL_SIGNAL_WRITE_OK', rideId: normalizedRideId);
      clearParticipantWriteCache(rideId: normalizedRideId);
      final committedMap = _asStringDynamicMap(transaction.snapshot.value);
      final mirrorCallId =
          committedMap?['call_id']?.toString().trim() ?? normalizedRideId;
      _callIdByContext[normalizedRideId] = mirrorCallId;
      debugPrint(
        'CALL_START callId=$mirrorCallId contextId=$normalizedRideId '
        'caller=$callerId callee=$receiverId call_type=${kind.name}',
      );
      unawaited(
        _syncSharedCallRecord(
          contextId: normalizedRideId,
          callId: mirrorCallId,
          status: 'ringing',
          riderId: normalizedRiderId,
          driverId: normalizedDriverId,
          kind: kind,
        ),
      );
    } else {
      final existing = await fetchCall(normalizedRideId, kind: kind);
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
      session: await fetchCall(normalizedRideId, kind: kind),
    );
  }

  Future<bool> acceptCall({
    required String rideId,
    String? receiverId,
    CallSessionKind kind = CallSessionKind.ride,
  }) async {
    debugPrint(
      'CALL_ANSWER rideId=${rideId.trim()} receiverId=${receiverId?.trim() ?? ''}',
    );
    final committed = await _transitionCallStatus(
      rideId: rideId,
      nextStatus: 'active',
      allowedStatuses: const <String>{'calling', 'ringing'},
      requiredParticipantId: receiverId,
      setAnsweredAt: true,
      kind: kind,
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
    CallSessionKind kind = CallSessionKind.ride,
  }) async {
    final committed = await _transitionCallStatus(
      rideId: rideId,
      nextStatus: 'declined',
      endedBy: endedBy,
      requiredParticipantField: 'receiverId',
      requiredParticipantId: receiverId,
      allowedStatuses: const <String>{'calling', 'ringing'},
      kind: kind,
    );
    if (committed) {
      _callTrace('CALL_END_RTDB_OK', rideId: rideId);
    }
  }

  Future<void> cancelOutgoingCall({
    required String rideId,
    required String endedBy,
    String? callerId,
    CallSessionKind kind = CallSessionKind.ride,
  }) async {
    final committed = await _transitionCallStatus(
      rideId: rideId,
      nextStatus: 'cancelled',
      endedBy: endedBy,
      requiredParticipantField: 'callerId',
      requiredParticipantId: callerId,
      allowedStatuses: const <String>{'calling', 'ringing'},
      kind: kind,
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
    String endedBy = '',
    String? endedByUid,
    String? endedByRole,
    String endReason = 'user_ended',
    CallSessionKind kind = CallSessionKind.ride,
  }) async {
    final normalizedRideId = rideId.trim();
    final uid = (endedByUid ?? '').trim().isNotEmpty
        ? endedByUid!.trim()
        : endedBy.trim();
    final role = (endedByRole ?? '').trim().isNotEmpty
        ? endedByRole!.trim().toLowerCase()
        : _inferEndedByRole(endedBy);
    final existing = await fetchCall(normalizedRideId, kind: kind);
    if (existing != null && existing.isTerminal) {
      debugPrint(
        'CALL_LEAVE_CHANNEL rideId=$normalizedRideId reason=already_terminal status=${existing.status.name}',
      );
      return true;
    }
    final callId = existing?.callId ?? normalizedRideId;
    final sessionPath = CallService.sessionPath(normalizedRideId, kind: kind);
    final priorStatus = existing?.status.name ?? 'unknown';
    final callerId = existing?.callerId ?? '';
    final receiverId = existing?.receiverId ?? '';
    debugPrint(
      'CALL_END_LOCAL_WRITE path=$sessionPath rideId=$normalizedRideId callId=$callId '
      'status=$priorStatus callerId=$callerId receiverId=$receiverId '
      'ended_by=$uid ended_by_role=$role end_reason=$endReason',
    );
    final committed = await _transitionCallStatus(
      rideId: normalizedRideId,
      nextStatus: 'ended',
      endedBy: uid,
      endedByRole: role.isNotEmpty ? role : null,
      endReason: endReason,
      allowedStatuses: const <String>{
        'calling',
        'ringing',
        'accepted',
        'active',
        'joined',
        'connecting',
      },
      kind: kind,
    );
    if (committed) {
      _callTrace('CALL_END_RTDB_OK', rideId: normalizedRideId);
      debugPrint(
        'CALL_ENDED_LOCAL callId=$callId contextId=$normalizedRideId endedBy=$uid',
      );
    }
    return committed;
  }

  Future<void> endCallForRideLifecycle({
    required String rideId,
    required String endedBy,
    CallSessionKind kind = CallSessionKind.ride,
  }) async {
    final normalizedRideId = rideId.trim();
    final existing = await fetchCall(normalizedRideId, kind: kind);
    if (existing != null && existing.isTerminal) {
      return;
    }
    final committed = await _transitionCallStatus(
      rideId: normalizedRideId,
      nextStatus: 'ended',
      endedBy: endedBy,
      allowedStatuses: const <String>{
        'calling',
        'ringing',
        'accepted',
        'active',
        'joined',
        'connecting',
      },
      kind: kind,
    );
    if (committed) {
      _callTrace('CALL_END_RTDB_OK', rideId: normalizedRideId);
    }
  }

  Future<bool> cancelCallIfStillRinging({
    required String rideId,
    required String endedBy,
    CallSessionKind kind = CallSessionKind.ride,
  }) async {
    return _transitionCallStatus(
      rideId: rideId,
      nextStatus: 'cancelled',
      endedBy: endedBy,
      allowedStatuses: const <String>{'calling', 'ringing'},
      kind: kind,
    );
  }

  Future<bool> failCallIfStillRinging({
    required String rideId,
    String endedBy = 'system',
    CallSessionKind kind = CallSessionKind.ride,
  }) async {
    return _transitionCallStatus(
      rideId: rideId,
      nextStatus: 'failed',
      endedBy: endedBy,
      allowedStatuses: const <String>{'calling', 'ringing'},
      kind: kind,
    );
  }

  Future<void> markMissedIfUnanswered({
    required String rideId,
    CallSessionKind kind = CallSessionKind.ride,
  }) async {
    await failCallIfStillRinging(rideId: rideId, kind: kind);
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
    CallSessionKind kind = CallSessionKind.ride,
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
        '${CallService.sessionPath(normalizedRideId, kind: kind)}/participants/${_participantKey(normalizedUid)}';
    final cacheKey = '$normalizedRideId|$normalizedUid';
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
      await _participantRef(normalizedRideId, normalizedUid, kind: kind)
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
    CallSessionKind kind = CallSessionKind.ride,
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
    await _logAgoraChannelSessionAlignment(normalizedRide);
    if (_callableAgoraChannelName != null &&
        _callableAgoraChannelName!.trim().isNotEmpty) {
      _lastJoinRequest = _VoiceJoinRequest(
        rideId: normalizedRide,
        agoraChannelId: _callableAgoraChannelName!.trim(),
        uid: uid,
        speakerOn: speakerOn,
        muted: muted,
        kind: kind,
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
      kind: kind,
    );

    _joinAttemptStartedAt = DateTime.now();
    debugPrint(
      'CALL_JOIN_CHANNEL contextId=$normalizedRide channelId=${_callableAgoraChannelName ?? channelForRide(normalizedRide)} uid=$uid',
    );
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

  /// Blocks until Agora reports local channel join or join is aborted.
  Future<void> waitForVoiceJoinConnected({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (isLocalVoiceJoined) {
        return;
      }
      if (_lastJoinRequest == null) {
        throw const RideCallException('Call ended before connect.');
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

  /// Blocks until [onUserJoined] confirms the remote peer is in-channel.
  Future<void> waitForRemotePeerConnected({
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_remotePeerJoined && isVoiceConnected) {
        return;
      }
      if (phaseNotifier.value == AgoraConnectionPhase.failed) {
        throw RideCallException(
          phaseErrorNotifier.value ??
              'The other party could not connect.',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw const RideCallException(
      'The other party could not connect.',
    );
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
    _resetRemotePeerWatchdogState();
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
      await engine.enableLocalAudio(true);
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

  void _resetRemotePeerWatchdogState({bool clearStatus = true}) {
    _remotePeerJoinWatchdog?.cancel();
    _remotePeerJoinWatchdog = null;
    _remotePeerJoined = false;
    _localAgoraJoinedAt = null;
    _remotePeerWatchdogFireCount = 0;
    remotePeerJoinedNotifier.value = false;
    if (clearStatus) {
      remotePeerStatusNotifier.value = null;
    }
  }

  void _startRemotePeerJoinWatchdog() {
    _remotePeerJoinWatchdog?.cancel();
    _remotePeerWatchdogFireCount = 0;
    _remotePeerJoinWatchdog = Timer(
      kRemotePeerJoinWatchdogInterval,
      () => unawaited(_handleRemotePeerJoinWatchdogFired()),
    );
  }

  void _cancelRemotePeerJoinWatchdog() {
    _remotePeerJoinWatchdog?.cancel();
    _remotePeerJoinWatchdog = null;
  }

  void _scheduleRemotePeerJoinWatchdogTick() {
    _remotePeerJoinWatchdog?.cancel();
    _remotePeerJoinWatchdog = Timer(
      kRemotePeerJoinWatchdogInterval,
      () => unawaited(_handleRemotePeerJoinWatchdogFired()),
    );
  }

  Future<void> _handleRemotePeerJoinWatchdogFired() async {
    if (_disposed || _remotePeerJoined || _lastJoinRequest == null) {
      return;
    }
    if (!_appLifecycleForeground) {
      _scheduleRemotePeerJoinWatchdogTick();
      return;
    }

    _remotePeerWatchdogFireCount++;
    final request = _lastJoinRequest!;
    final contextId = request.rideId.trim();
    if (contextId.isEmpty) {
      return;
    }

    final channelId =
        _joinedChannelId?.trim() ?? request.agoraChannelId.trim();
    debugPrint(
      'CALL_REMOTE_JOIN_TIMEOUT contextId=$contextId channelId=$channelId '
      'fireCount=$_remotePeerWatchdogFireCount',
    );

    final elapsed = _localAgoraJoinedAt == null
        ? Duration.zero
        : DateTime.now().difference(_localAgoraJoinedAt!);
    final tick = _remotePeerWatchdogPolicy.evaluateTick(
      fireCount: _remotePeerWatchdogFireCount,
      elapsedSinceLocalJoin: elapsed,
    );

    if (tick.statusMessage != null) {
      remotePeerStatusNotifier.value = tick.statusMessage;
    }
    if (_connectionState == ConnectionStateType.connectionStateConnected) {
      _setPhase(AgoraConnectionPhase.waitingForRemote);
    }

    if (tick.shouldFail) {
      await _failCallForRemotePeerNotJoined(contextId, kind: request.kind);
      return;
    }

    final session = await fetchCall(contextId, kind: request.kind);
    if (session == null || session.isTerminal) {
      _cancelRemotePeerJoinWatchdog();
      return;
    }

    if (_remotePeerWatchdogFireCount == 1) {
      unawaited(
        _logBothActiveNoRemotePeerMismatch(
          contextId: contextId,
          kind: request.kind,
          session: session,
        ),
      );
    }

    _scheduleRemotePeerJoinWatchdogTick();
  }

  Future<void> _logBothActiveNoRemotePeerMismatch({
    required String contextId,
    required CallSessionKind kind,
    RideCallSession? session,
  }) async {
    session ??= await fetchCall(contextId, kind: kind);
    final rtdbChannelId = session?.channelId.trim() ?? '';
    final tokenChannelName = _callableAgoraChannelName?.trim() ?? '';
    final localUid = _lastJoinRequest?.uid.trim() ?? '';
    final callerUid = session?.callerId.trim() ?? '';
    final calleeUid = session?.receiverId.trim() ?? '';
    debugPrint(
      'CALL_SYNC_MISMATCH reason=both_active_no_remote_peer '
      'contextId=$contextId rtdbChannelId=$rtdbChannelId '
      'tokenChannelName=$tokenChannelName localUid=$localUid '
      'callerUid=$callerUid calleeUid=$calleeUid',
    );
  }

  Future<void> _failCallForRemotePeerNotJoined(
    String contextId, {
    required CallSessionKind kind,
  }) async {
    _cancelRemotePeerJoinWatchdog();
    debugPrint(
      'CALL_FAILED contextId=$contextId reason=remote_peer_not_joined endedBy=system',
    );
    await _transitionCallStatus(
      rideId: contextId,
      nextStatus: 'missed',
      endedBy: 'system',
      endReason: 'remote_peer_not_joined',
      allowedStatuses: const <String>{
        'calling',
        'ringing',
        'accepted',
        'active',
        'joined',
        'connecting',
      },
      kind: kind,
    );
    _setPhase(
      AgoraConnectionPhase.failed,
      error: 'The other party could not connect.',
    );
    await leaveVoiceChannel();
  }

  void _onRemotePeerJoined({
    required RtcConnection connection,
    required int remoteUid,
    required int elapsed,
  }) {
    if (_remotePeerJoined) {
      return;
    }

    _remotePeerJoined = true;
    remotePeerJoinedNotifier.value = true;
    remotePeerStatusNotifier.value = null;
    _cancelRemotePeerJoinWatchdog();

    final firebaseRide = _lastJoinRequest?.rideId ?? '';
    if (firebaseRide.isEmpty) {
      return;
    }

    debugPrint(
      'CALL_REMOTE_JOIN contextId=$firebaseRide channel=${connection.channelId} '
      'remoteUid=$remoteUid elapsedMs=$elapsed',
    );
    _callTrace(
      'CALL_REMOTE_JOINED',
      rideId: firebaseRide,
      channel: connection.channelId,
      remoteUid: remoteUid,
      elapsedMs: elapsed,
    );
    _setPhase(AgoraConnectionPhase.connected);
    debugPrint(
      'CALL_CONNECTED_CONFIRMED contextId=$firebaseRide remoteUid=$remoteUid',
    );
    unawaited(
      _syncRtcParticipantState(
        joined: true,
        connectionState: 'connected',
      ),
    );
    unawaited(() async {
      final kind = _lastJoinRequest?.kind ?? CallSessionKind.ride;
      final snap = await _callRef(firebaseRide, kind: kind).get();
      final map = _asStringDynamicMap(snap.value);
      if (map == null) {
        return;
      }
      final callId =
          map['call_id']?.toString().trim() ?? _activeCallIdForContext(firebaseRide);
      final riderId = map['rider_id']?.toString().trim() ??
          map['callerId']?.toString().trim() ??
          '';
      final driverId = map['driver_id']?.toString().trim() ??
          map['receiverId']?.toString().trim() ??
          '';
      await _syncSharedCallRecord(
        contextId: firebaseRide,
        callId: callId,
        status: 'active',
        riderId: riderId,
        driverId: driverId,
        kind: kind,
      );
    }());
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
    _remotePeerJoined = false;
    remotePeerJoinedNotifier.value = false;
    remotePeerStatusNotifier.value =
        RemotePeerWatchdogPolicy.connectingToRemoteMessage;
    _localAgoraJoinedAt = DateTime.now();
    _setPhase(AgoraConnectionPhase.waitingForRemote);
    final firebaseRide = _lastJoinRequest?.rideId ?? '';
    debugPrint(
      'CALL_ACTIVE contextId=$firebaseRide channel=$agoraCh uid=${_lastJoinRequest?.uid}',
    );
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
    _startRemotePeerJoinWatchdog();
    debugPrint(
      '[RideCall] join success rideId=$firebaseRide agoraChannel=$agoraCh',
    );
  }

  Future<void> leaveVoiceChannel() async {
    if (_endingCall) {
      return;
    }
    _endingCall = true;
    _participantMirrorSuppressed = true;
    _cancelReconnectTimer();
    _cancelReconnectWatchdog();
    _joinWatchdogTimer?.cancel();
    _joinWatchdogTimer = null;
    _reconnectInProgress = false;
    _reconnectAttempt = 0;
    final endedRideId = _lastJoinRequest?.rideId;
    final endedUid = _lastJoinRequest?.uid;
    if (endedRideId != null) {
      debugPrint(
        'CALL_LEAVE_CHANNEL contextId=$endedRideId uid=$endedUid channel=${_joinedChannelId ?? ''}',
      );
      debugPrint(
        'CALL_AGORA_LEFT callId=${_activeCallIdForContext(endedRideId)} contextId=$endedRideId uid=$endedUid',
      );
    }
    _lastJoinRequest = null;
    if (endedRideId != null && endedUid != null) {
      clearParticipantWriteCache(rideId: endedRideId, uid: endedUid);
      _callIdByContext.remove(endedRideId.trim());
    }
    _resetRemotePeerWatchdogState();
    _setPhase(AgoraConnectionPhase.idle);

    if (_engine == null || _joinedChannelId == null) {
      _joinedChannelId = null;
      _connectionState = ConnectionStateType.connectionStateDisconnected;
      if (endedRideId != null) {
        debugPrint(
          'CALL_CLEANUP_DONE callId=${_activeCallIdForContext(endedRideId)} contextId=$endedRideId uid=${endedUid ?? ''}',
        );
      }
      _endingCall = false;
      return;
    }

    await _leaveEngineChannel();
    _joinedChannelId = null;
    _connectionState = ConnectionStateType.connectionStateDisconnected;
    if (endedRideId != null) {
      debugPrint(
        'CALL_CLEANUP_DONE callId=${_activeCallIdForContext(endedRideId)} contextId=$endedRideId uid=${endedUid ?? ''}',
      );
    }
    _endingCall = false;
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
    _cancelRemotePeerJoinWatchdog();
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
      return _cloudFunctionsService
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
            kind: _lastJoinRequest!.kind,
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
    String? endedByRole,
    String? endReason,
    String? requiredParticipantField,
    String? requiredParticipantId,
    bool setAcceptedAt = false,
    bool setAnsweredAt = false,
    CallSessionKind kind = CallSessionKind.ride,
  }) async {
    final normalizedRideId = rideId.trim();
    await _keepCallSynced(normalizedRideId, kind: kind);

    late final rtdb.TransactionResult result;
    try {
      result = await _callRef(normalizedRideId, kind: kind)
          .runTransaction((currentValue) {
            final currentMap = _asStringDynamicMap(currentValue);
            if (currentMap == null) {
              return rtdb.Transaction.abort();
            }

            final currentStatus = _effectiveStatusString(currentMap);
            if (_isTerminalStatusString(currentStatus)) {
              if (_isTerminalStatusString(nextStatus) &&
                  currentStatus == nextStatus.trim().toLowerCase()) {
                return rtdb.Transaction.success(currentMap);
              }
              return rtdb.Transaction.abort();
            }
            if (!allowedStatuses.contains(currentStatus)) {
              return rtdb.Transaction.abort();
            }

            final expectedParticipantId = requiredParticipantId?.trim() ?? '';
            if (expectedParticipantId.isNotEmpty) {
              final participantIds = <String>{
                currentMap['callerId']?.toString().trim() ?? '',
                currentMap['receiverId']?.toString().trim() ?? '',
                currentMap['callerUid']?.toString().trim() ?? '',
                currentMap['caller_uid']?.toString().trim() ?? '',
                currentMap['calleeUid']?.toString().trim() ?? '',
                currentMap['callee_uid']?.toString().trim() ?? '',
              }..removeWhere((String value) => value.isEmpty);
              if (!participantIds.contains(expectedParticipantId)) {
                if (requiredParticipantField != null) {
                  final actualParticipantId =
                      currentMap[requiredParticipantField]?.toString().trim() ??
                          '';
                  if (actualParticipantId != expectedParticipantId) {
                    return rtdb.Transaction.abort();
                  }
                } else {
                  return rtdb.Transaction.abort();
                }
              }
            }

            final nextMap = Map<String, Object?>.from(currentMap)
              ..['status'] = nextStatus
              ..['state'] = nextStatus
              ..['updatedAt'] = rtdb.ServerValue.timestamp;

            if (setAcceptedAt || setAnsweredAt) {
              nextMap['acceptedAt'] = rtdb.ServerValue.timestamp;
              nextMap['answeredAt'] = rtdb.ServerValue.timestamp;
              nextMap['endedAt'] = null;
              nextMap['endedBy'] = null;
            } else if (_isTerminalStatusString(nextStatus)) {
              nextMap['endedAt'] = rtdb.ServerValue.timestamp;
              nextMap['ended_at'] = rtdb.ServerValue.timestamp;
              nextMap['endedBy'] = endedBy;
              nextMap['ended_by'] = endedBy;
              final role = (endedByRole ?? '').trim().toLowerCase();
              if (role.isNotEmpty) {
                nextMap['ended_by_role'] = role;
              }
              final reason = (endReason ?? '').trim();
              if (reason.isNotEmpty) {
                nextMap['end_reason'] = reason;
              }
            }

            return rtdb.Transaction.success(nextMap);
          }, applyLocally: _isTerminalStatusString(nextStatus))
          .timeout(_kCallWriteTimeout);
    } on TimeoutException {
      debugPrint(
        'CALL_ERROR rideId=$normalizedRideId reason=transition_timeout nextStatus=$nextStatus',
      );
      return false;
    } catch (error) {
      debugPrint(
        'CALL_ERROR rideId=$normalizedRideId reason=transition_failed nextStatus=$nextStatus error=$error',
      );
      return false;
    }

    if (result.committed) {
      debugPrint(
        'DELIVERY_CALL_STATUS_CHANGED callId=${_asStringDynamicMap(result.snapshot.value)?['call_id']?.toString() ?? normalizedRideId} '
        'status=$nextStatus contextId=$normalizedRideId',
      );
      if (nextStatus.trim().toLowerCase() == 'active') {
        debugPrint(
          'CALL_ACCEPTED contextId=$normalizedRideId kind=${kind.name}',
        );
      }
      if (_isTerminalStatusString(nextStatus)) {
        debugPrint(
          'CALL_ENDED contextId=$normalizedRideId status=$nextStatus endedBy=${endedBy ?? ''} kind=${kind.name}',
        );
      }
      final committedMap = _asStringDynamicMap(result.snapshot.value);
      final mirrorCallId =
          committedMap?['call_id']?.toString().trim() ?? normalizedRideId;
      if (mirrorCallId.isNotEmpty) {
        _callIdByContext[normalizedRideId] = mirrorCallId;
      }
      final riderId = committedMap?['rider_id']?.toString().trim() ??
          committedMap?['callerId']?.toString().trim() ??
          '';
      final driverId = committedMap?['driver_id']?.toString().trim() ??
          committedMap?['receiverId']?.toString().trim() ??
          '';
      unawaited(
        _syncSharedCallRecord(
          contextId: normalizedRideId,
          callId: mirrorCallId,
          status: nextStatus,
          riderId: riderId,
          driverId: driverId,
          endedBy: endedBy,
          endedByRole: endedByRole,
          kind: kind,
        ),
      );
    }

    return result.committed;
  }

  String _canonicalSharedCallStatus(String rawStatus) {
    final s = rawStatus.trim().toLowerCase();
    return switch (s) {
      'calling' || 'ringing' => 'ringing',
      'accepted' || 'active' || 'joined' => 'connecting',
      'declined' || 'cancelled' => 'ended',
      'timeout' => 'missed',
      _ => s,
    };
  }

  Future<void> _syncSharedCallRecord({
    required String contextId,
    required String callId,
    required String status,
    required String riderId,
    required String driverId,
    String? endedBy,
    String? endedByRole,
    CallSessionKind kind = CallSessionKind.ride,
  }) async {
    final normalizedContextId = contextId.trim();
    final normalizedCallId = callId.trim();
    if (normalizedCallId.isEmpty) {
      return;
    }
    final sharedStatus = _canonicalSharedCallStatus(status);
    final callType = kind == CallSessionKind.delivery ? 'delivery' : 'ride';
    final patch = <String, Object?>{
      'call_id': normalizedCallId,
      'status': sharedStatus,
      'state': sharedStatus,
      'rider_id': riderId,
      'driver_id': driverId,
      'call_type': callType,
      'updated_at': rtdb.ServerValue.timestamp,
    };
    if (kind == CallSessionKind.delivery) {
      patch['delivery_id'] = normalizedContextId;
    } else {
      patch['ride_id'] = normalizedContextId;
    }
    if (_isTerminalStatusString(status)) {
      patch['ended_at'] = rtdb.ServerValue.timestamp;
      patch['ended_by'] = endedBy ?? 'system';
      final role = (endedByRole ?? '').trim().toLowerCase();
      if (role.isNotEmpty) {
        patch['ended_by_role'] = role;
      }
    }
    try {
      await _database
          .ref(CallService.sharedCallPath(normalizedCallId))
          .update(patch)
          .timeout(_kCallWriteTimeout);
    } catch (error) {
      debugPrint(
        'CALL_SHARED_SYNC_FAIL callId=$normalizedCallId contextId=$normalizedContextId error=$error',
      );
    }

    if (normalizedContextId.isEmpty) {
      return;
    }
    final mirrorStatus = switch (sharedStatus) {
      'connecting' => 'active',
      'ringing' => 'ringing',
      'ended' || 'failed' || 'missed' => 'ended',
      _ => sharedStatus,
    };
    final mirrorPatch = <String, Object?>{
      'call_id': normalizedCallId,
      'ride_id': normalizedContextId,
      'status': mirrorStatus,
      'updated_at': rtdb.ServerValue.timestamp,
    };
    if (kind == CallSessionKind.delivery) {
      mirrorPatch['delivery_id'] = normalizedContextId;
    }
    if (mirrorStatus == 'ended') {
      final role = (endedByRole ?? '').trim().toLowerCase();
      mirrorPatch['ended_by'] = role == 'rider' || role == 'driver'
          ? role
          : (_inferEndedByRole(endedBy ?? '') == 'rider' ||
                  _inferEndedByRole(endedBy ?? '') == 'driver'
              ? _inferEndedByRole(endedBy ?? '')
              : 'system');
      mirrorPatch['ended_at'] = rtdb.ServerValue.timestamp;
    }
    try {
      await _database
          .ref(
            CallService.rideCallMirrorPath(normalizedContextId, normalizedCallId),
          )
          .update(mirrorPatch)
          .timeout(_kCallWriteTimeout);
      if (mirrorStatus == 'ended') {
        debugPrint(
          'CALL_SESSION_ENDED_SYNCED contextId=$normalizedContextId callId=$normalizedCallId '
          'ended_by=${mirrorPatch['ended_by']}',
        );
      }
    } catch (error) {
      debugPrint(
        'CALL_MIRROR_FAIL contextId=$normalizedContextId callId=$normalizedCallId error=$error',
      );
    }
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
            if (_remotePeerJoined) {
              _setPhase(AgoraConnectionPhase.connected);
            } else if (_localAgoraJoinedAt != null) {
              _setPhase(AgoraConnectionPhase.waitingForRemote);
            } else {
              _setPhase(AgoraConnectionPhase.connecting);
            }
            break;
          case ConnectionStateType.connectionStateConnecting:
            if (phaseNotifier.value != AgoraConnectionPhase.connected &&
                phaseNotifier.value != AgoraConnectionPhase.waitingForRemote) {
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
          if (!_appLifecycleForeground) {
            return;
          }
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
        _onRemotePeerJoined(
          connection: connection,
          remoteUid: remoteUid,
          elapsed: elapsed,
        );
      },
      onUserOffline: (connection, remoteUid, reason) {
        final request = _lastJoinRequest;
        final firebaseRide = request?.rideId ?? '';
        debugPrint(
          'CALL_REMOTE_LEAVE contextId=$firebaseRide remoteUid=$remoteUid reason=${reason.name}',
        );
        if (firebaseRide.isEmpty || request == null || _endingCall) {
          return;
        }
        final callId = _activeCallIdForContext(firebaseRide);
        debugPrint(
          'CALL_ENDED_REMOTE callId=$callId contextId=$firebaseRide uid=${request.uid} '
          'reason=agora_offline',
        );
        unawaited(() async {
          await _transitionCallStatus(
            rideId: firebaseRide,
            nextStatus: 'ended',
            endedBy: 'system',
            endReason: 'remote_agora_offline',
            allowedStatuses: const <String>{
              'calling',
              'ringing',
              'accepted',
              'active',
              'joined',
              'connecting',
            },
            kind: request.kind,
          );
          await leaveVoiceChannel();
        }());
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
          kind: request.kind,
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
      kind: request.kind,
    );
  }

  rtdb.DatabaseReference _callRef(
    String rideId, {
    CallSessionKind kind = CallSessionKind.ride,
  }) {
    return _database.ref(CallService.sessionPath(rideId, kind: kind));
  }

  rtdb.DatabaseReference _participantRef(
    String rideId,
    String uid, {
    CallSessionKind kind = CallSessionKind.ride,
  }) {
    return _callRef(
      rideId,
      kind: kind,
    ).child('participants/${_participantKey(uid.trim())}');
  }

  Future<void> _logAgoraChannelSessionAlignment(String contextId) async {
    final joinChannel = _callableAgoraChannelName?.trim() ?? '';
    if (joinChannel.isEmpty) {
      return;
    }
    try {
      final snapshot = await runRtdbQueryGet(
        query: _callRef(contextId),
        path: CallService.sessionPath(contextId, kind: CallSessionKind.ride),
        source: 'call_service.channel_alignment',
      ).timeout(
        const Duration(seconds: 4),
      );
      final session = RideCallSession.fromSnapshotValue(
        contextId,
        snapshot.value,
      );
      final sessionChannel = session?.channelId.trim() ?? '';
      if (sessionChannel.isEmpty) {
        return;
      }
      if (sessionChannel != joinChannel) {
        debugPrint(
          'CALL_SYNC_MISMATCH contextId=$contextId '
          'sessionChannel=$sessionChannel joinChannel=$joinChannel',
        );
        return;
      }
      debugPrint(
        'CALL_CHANNEL_ALIGNED contextId=$contextId channel=$joinChannel',
      );
    } catch (_) {
      /* alignment log is best-effort */
    }
  }

  Future<void> _keepCallSynced(
    String rideId, {
    CallSessionKind kind = CallSessionKind.ride,
  }) async {
    final normalizedRideId = rideId.trim();
    final syncKey = '${kind.name}|$normalizedRideId';
    if (normalizedRideId.isEmpty || !_syncedRideIds.add(syncKey)) {
      return;
    }

    try {
      await _callRef(normalizedRideId, kind: kind).keepSynced(true);
    } catch (error) {
      _syncedRideIds.remove(syncKey);
      debugPrint(
        '[RideCall] keepSynced failed rideId=$normalizedRideId kind=${kind.name} error=$error',
      );
    }
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
    case 'active':
    case 'connecting':
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
    case 'failed':
    case 'timeout':
      return RideCallStatus.failed;
    default:
      return null;
  }
}

String _effectiveStatusString(Map<String, dynamic> map) {
  final status = map['status']?.toString().trim().toLowerCase() ?? '';
  if (status.isNotEmpty) {
    return status;
  }
  return map['state']?.toString().trim().toLowerCase() ?? '';
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

  final callerUid = map['callerUid']?.toString().trim() ??
      map['caller_uid']?.toString().trim() ??
      '';
  if (callerUid.isNotEmpty) {
    return callerUid;
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

  final calleeUid = map['calleeUid']?.toString().trim() ??
      map['callee_uid']?.toString().trim() ??
      '';
  if (calleeUid.isNotEmpty) {
    return calleeUid;
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
      normalized == 'accepted' ||
      normalized == 'active' ||
      normalized == 'joined' ||
      normalized == 'connecting';
}

bool _isTerminalStatusString(String rawStatus) {
  final normalized = rawStatus.trim().toLowerCase();
  return normalized == 'declined' ||
      normalized == 'ended' ||
      normalized == 'missed' ||
      normalized == 'cancelled' ||
      normalized == 'failed' ||
      normalized == 'timeout';
}

String _inferEndedByRole(String endedBy) {
  final normalized = endedBy.trim().toLowerCase();
  if (normalized == 'rider' || normalized == 'driver') {
    return normalized;
  }
  return '';
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
