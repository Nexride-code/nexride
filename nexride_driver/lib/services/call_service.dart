import 'dart:async';
import 'dart:convert';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuth;
import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../support/realtime_database_error_support.dart';

enum RideCallStatus { ringing, accepted, declined, ended, missed, cancelled }

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
  bool get isAccepted => status == RideCallStatus.accepted;
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

    final status = _parseStatus(map['status']?.toString());
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
      channelId: map['channelName']?.toString() ??
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

    sessions.sort(
      (a, b) => (b.createdAt ?? 0).compareTo(a.createdAt ?? 0),
    );
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

class _VoiceJoinRequest {
  const _VoiceJoinRequest({
    required this.channelId,
    required this.uid,
    required this.speakerOn,
    required this.muted,
  });

  final String channelId;
  final String uid;
  final bool speakerOn;
  final bool muted;
}

class CallService {
  CallService({
    rtdb.FirebaseDatabase? database,
    String? agoraAppId,
    String? tokenEndpoint,
  })  : _database = database ?? rtdb.FirebaseDatabase.instance,
        _agoraAppId = _resolveAgoraAppId(agoraAppId),
        _agoraTokenEndpoint = _resolveTokenEndpoint(tokenEndpoint);

  final rtdb.FirebaseDatabase _database;
  final String _agoraAppId;
  final String _agoraTokenEndpoint;
  final String _agoraChannelPrefix = _resolveChannelPrefix();
  final Set<String> _syncedRideIds = <String>{};
  final Set<String> _syncedReceiverIds = <String>{};

  RtcEngine? _engine;
  RtcEngineEventHandler? _eventHandler;
  bool _engineReady = false;
  bool _disposed = false;
  bool _intentionalLeaveInProgress = false;
  bool _reconnectInProgress = false;
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;
  Timer? _reconnectWatchdogTimer;
  String? _joinedChannelId;
  String? _cachedTokenChannelId;
  String? _cachedTokenUserId;
  String? _cachedToken;
  _VoiceJoinRequest? _lastJoinRequest;
  ConnectionStateType _connectionState =
      ConnectionStateType.connectionStateDisconnected;

  bool get hasRtcConfiguration =>
      _agoraAppId.isNotEmpty && _agoraTokenEndpoint.isNotEmpty;

  String get missingConfigurationMessage {
    final missing = <String>[];
    if (_agoraAppId.isEmpty) {
      missing.add('AGORA_APP_ID');
    }
    if (_agoraTokenEndpoint.isEmpty) {
      missing.add('AGORA_TOKEN_ENDPOINT');
    }

    if (missing.isEmpty) {
      return 'Voice calling is configured.';
    }

    if (missing.length == 1) {
      return 'Voice calling is not configured yet. Add ${missing.first} to enable it.';
    }

    return 'Voice calling is not configured yet. Add ${missing.join(' and ')} to enable it.';
  }

  String get unavailableUserMessage =>
      'Calling will be available once secure voice setup is completed.';

  String channelForRide(String rideId) {
    final normalizedRideId = rideId.trim();
    if (_agoraChannelPrefix.isEmpty) {
      return normalizedRideId;
    }
    return '${_agoraChannelPrefix}_$normalizedRideId';
  }

  Stream<rtdb.DatabaseEvent> observeCall(String rideId) {
    final normalizedRideId = rideId.trim();
    unawaited(_keepRideCallSynced(normalizedRideId));
    return _callRef(normalizedRideId).onValue;
  }

  Stream<rtdb.DatabaseEvent> observeCallsForReceiver(String receiverId) {
    final normalizedReceiverId = receiverId.trim();
    unawaited(_keepReceiverCallsSynced(normalizedReceiverId));
    return _callsByReceiverQuery(normalizedReceiverId).onValue;
  }

  Future<RideCallSession?> fetchCall(String rideId) async {
    final normalizedRideId = rideId.trim();
    await _keepRideCallSynced(normalizedRideId);
    debugPrint(
      '[MATCH_DEBUG][QUERY_GET:calls/$normalizedRideId] fetchCall '
      '(caller must not overlap observeCall on same ref)',
    );
    final snapshot = await runOptionalRealtimeDatabaseRead<rtdb.DataSnapshot>(
      source: 'driver_call.fetch_call',
      path: 'calls/$normalizedRideId',
      action: () => _callRef(normalizedRideId).get(),
    );
    if (snapshot == null) {
      return null;
    }
    return RideCallSession.fromSnapshotValue(normalizedRideId, snapshot.value);
  }

  Future<List<RideCallSession>> fetchCallsForReceiver(String receiverId) async {
    final normalizedReceiverId = receiverId.trim();
    await _keepReceiverCallsSynced(normalizedReceiverId);
    debugPrint(
      '[MATCH_DEBUG][QUERY_GET:calls?orderByChild=receiverId&equalTo=$normalizedReceiverId] '
      'fetchCallsForReceiver (caller must not overlap observeCallsForReceiver)',
    );
    final snapshot = await runOptionalRealtimeDatabaseRead<rtdb.DataSnapshot>(
      source: 'driver_call.fetch_calls_for_receiver',
      path: 'calls[orderByChild=receiverId,equalTo=$normalizedReceiverId]',
      action: () => _callsByReceiverQuery(normalizedReceiverId).get(),
    );
    if (snapshot == null) {
      return const <RideCallSession>[];
    }
    return RideCallSession.listFromCollectionValue(snapshot.value);
  }

  Future<void> prefetchAgoraToken({
    required String channelId,
    required String uid,
  }) async {
    final token = await fetchAgoraToken(
      channelId,
      uid,
      forceRefresh: true,
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
    await _keepReceiverCallsSynced(receiverId);

    final payload = <String, Object?>{
      'ride_id': normalizedRideId,
      'rider_id': normalizedRiderId,
      'driver_id': normalizedDriverId,
      'started_by': normalizedStartedBy,
      'callerId': callerId,
      'receiverId': receiverId,
      'channelName': channelForRide(normalizedRideId),
      'status': 'ringing',
      'createdAt': rtdb.ServerValue.timestamp,
      'updatedAt': rtdb.ServerValue.timestamp,
      'acceptedAt': null,
      'endedAt': null,
      'endedBy': null,
    };

    final transaction = await _callRef(normalizedRideId).runTransaction(
      (currentValue) {
        final currentMap = _asStringDynamicMap(currentValue);
        final status = currentMap?['status']?.toString() ?? '';
        if (_isActiveStatusString(status)) {
          return rtdb.Transaction.abort();
        }
        return rtdb.Transaction.success(payload);
      },
      applyLocally: false,
    );

    return OutgoingCallRequestResult(
      created: transaction.committed,
      session: await fetchCall(normalizedRideId),
    );
  }

  Future<bool> acceptCall({
    required String rideId,
    String? receiverId,
  }) async {
    return _transitionCallStatus(
      rideId: rideId,
      nextStatus: 'accepted',
      allowedStatuses: const <String>{'calling', 'ringing'},
      requiredParticipantField: 'receiverId',
      requiredParticipantId: receiverId,
      setAcceptedAt: true,
    );
  }

  Future<void> declineCall({
    required String rideId,
    required String endedBy,
    String? receiverId,
  }) async {
    await _transitionCallStatus(
      rideId: rideId,
      nextStatus: 'declined',
      endedBy: endedBy,
      requiredParticipantField: 'receiverId',
      requiredParticipantId: receiverId,
      allowedStatuses: const <String>{'calling', 'ringing'},
    );
  }

  Future<void> cancelOutgoingCall({
    required String rideId,
    required String endedBy,
    String? callerId,
  }) async {
    await _transitionCallStatus(
      rideId: rideId,
      nextStatus: 'cancelled',
      endedBy: endedBy,
      requiredParticipantField: 'callerId',
      requiredParticipantId: callerId,
      allowedStatuses: const <String>{'calling', 'ringing'},
    );
  }

  Future<void> endAcceptedCall({
    required String rideId,
    required String endedBy,
  }) async {
    await _transitionCallStatus(
      rideId: rideId,
      nextStatus: 'ended',
      endedBy: endedBy,
      allowedStatuses: const <String>{'accepted'},
    );
  }

  Future<void> endCallForRideLifecycle({
    required String rideId,
    required String endedBy,
  }) async {
    await _transitionCallStatus(
      rideId: rideId,
      nextStatus: 'ended',
      endedBy: endedBy,
      allowedStatuses: const <String>{'calling', 'ringing', 'accepted'},
    );
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
  }) async {
    final normalizedRideId = rideId.trim();
    final normalizedUid = uid.trim();
    if (normalizedRideId.isEmpty || normalizedUid.isEmpty) {
      return;
    }

    final authenticatedUid = FirebaseAuth.instance.currentUser?.uid.trim();
    if (authenticatedUid == null || authenticatedUid.isEmpty) {
      debugPrint(
        '[RideCall] participant sync skipped rideId=$normalizedRideId '
        'uid=$normalizedUid reason=unauthenticated',
      );
      return;
    }

    if (authenticatedUid != normalizedUid) {
      debugPrint(
        '[RideCall] participant sync skipped rideId=$normalizedRideId '
        'uid=$normalizedUid reason=auth_uid_mismatch authUid=$authenticatedUid',
      );
      return;
    }

    await _keepRideCallSynced(normalizedRideId);

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

    final normalizedConnectionState = connectionState?.trim();
    if (normalizedConnectionState != null &&
        normalizedConnectionState.isNotEmpty) {
      payload['connectionState'] = normalizedConnectionState;
    }

    try {
      await _participantRef(normalizedRideId, normalizedUid).update(payload);
    } catch (error, stackTrace) {
      if (isRealtimeDatabasePermissionDenied(error)) {
        debugPrint(
          '[RideCall] participant sync skipped rideId=$normalizedRideId '
          'uid=$normalizedUid reason=permission_denied error=$error',
        );
        debugPrintStack(
          label: '[RideCall] participant sync permission denied',
          stackTrace: stackTrace,
        );
        return;
      }
      rethrow;
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
    _lastJoinRequest = _VoiceJoinRequest(
      channelId: channelId,
      uid: uid,
      speakerOn: speakerOn,
      muted: muted,
    );

    await _ensureRtcEngine();

    if (_joinedChannelId == channelId &&
        _connectionState == ConnectionStateType.connectionStateConnected) {
      await setSpeakerOn(speakerOn);
      await setMuted(muted);
      return;
    }

    _cancelReconnectTimer();

    if (_joinedChannelId != null && _joinedChannelId != channelId) {
      await leaveVoiceChannel();
      await _ensureRtcEngine();
      _lastJoinRequest = _VoiceJoinRequest(
        channelId: channelId,
        uid: uid,
        speakerOn: speakerOn,
        muted: muted,
      );
    }

    final token = await fetchAgoraToken(channelId, uid);
    if (token == null || token.isEmpty) {
      debugPrint(
        '[RideCall] join failed rideId=$channelId error=token_unavailable',
      );
      throw const RideCallException(
        'Unable to connect voice calling right now. Please try again.',
      );
    }

    debugPrint('[CALL_JOIN_START] rideId=$channelId');

    try {
      await _engine!.setEnableSpeakerphone(speakerOn);
      await _engine!.muteLocalAudioStream(muted);
      await _joinChannelWithToken(
        token: token,
        request: _lastJoinRequest!,
      );
    } catch (error) {
      debugPrint('[CALL_JOIN_FAIL] rideId=$channelId error=$error');
      rethrow;
    }
  }

  Future<void> leaveVoiceChannel() async {
    _cancelReconnectTimer();
    _cancelReconnectWatchdog();
    _reconnectInProgress = false;
    _reconnectAttempt = 0;
    _lastJoinRequest = null;

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
    await _engine!.muteLocalAudioStream(muted);
    _updateJoinRequest(
      muted: muted,
    );
  }

  Future<void> setSpeakerOn(bool enabled) async {
    if (_engine == null) {
      return;
    }
    await _engine!.setEnableSpeakerphone(enabled);
    _updateJoinRequest(
      speakerOn: enabled,
    );
  }

  Future<void> dispose() async {
    _disposed = true;
    _cancelReconnectTimer();
    _cancelReconnectWatchdog();
    _cachedTokenChannelId = null;
    _cachedTokenUserId = null;
    _cachedToken = null;

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
    _connectionState = ConnectionStateType.connectionStateDisconnected;
  }

  Future<String?> fetchAgoraToken(
    String channelId,
    String uid, {
    bool forceRefresh = false,
  }) async {
    final rideId = channelId.trim();
    final normalizedUserId = uid.trim();
    final agoraUid = _agoraUid(normalizedUserId).toString();

    if (!hasRtcConfiguration) {
      debugPrint('[CALL_CONFIG_MISSING] rideId=$rideId');
      return null;
    }

    if (!forceRefresh &&
        _cachedToken != null &&
        _cachedToken!.isNotEmpty &&
        _cachedTokenChannelId == rideId &&
        _cachedTokenUserId == normalizedUserId) {
      return _cachedToken;
    }

    debugPrint('[CALL_TOKEN_FETCH_START] rideId=$rideId uid=$agoraUid');

    final uri = Uri.parse(_agoraTokenEndpoint).replace(
      queryParameters: <String, String>{'channel': rideId, 'uid': agoraUid},
    );

    try {
      final response = await http.get(
        uri,
        headers: const <String, String>{'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 10));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('status_${response.statusCode}');
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        throw const FormatException('invalid_json');
      }

      final responseMap = decoded.map<String, dynamic>(
        (key, value) => MapEntry(key.toString(), value),
      );
      final token = responseMap['token']?.toString().trim() ?? '';
      if (token.isEmpty) {
        throw const FormatException('missing_token');
      }

      _cachedTokenChannelId = rideId;
      _cachedTokenUserId = normalizedUserId;
      _cachedToken = token;

      debugPrint('[CALL_TOKEN_FETCH_OK] rideId=$rideId');
      return token;
    } catch (error) {
      _cachedTokenChannelId = null;
      _cachedTokenUserId = null;
      _cachedToken = null;
      debugPrint('[CALL_TOKEN_FETCH_FAIL] rideId=$rideId error=$error');
      return null;
    }
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

    final result = await _callRef(normalizedRideId).runTransaction((
      currentValue,
    ) {
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
    }, applyLocally: false);

    return result.committed;
  }

  Future<void> _ensureRtcEngine() async {
    if (_engineReady && _engine != null) {
      return;
    }

    final engine = _engine ?? createAgoraRtcEngine();
    final handler = RtcEngineEventHandler(
      onJoinChannelSuccess: (connection, elapsed) {
        final rideId = connection.channelId?.trim().isNotEmpty == true
            ? connection.channelId!.trim()
            : _lastJoinRequest?.channelId ?? _joinedChannelId ?? '';
        if (rideId.isNotEmpty) {
          _joinedChannelId = rideId;
          _connectionState = ConnectionStateType.connectionStateConnected;
          _reconnectAttempt = 0;
          _cancelReconnectTimer();
          _cancelReconnectWatchdog();
          unawaited(
            _syncRtcParticipantState(
              joined: true,
              connectionState: 'connected',
            ),
          );
          debugPrint('[RideCall] join success rideId=$rideId');
        }
      },
      onRejoinChannelSuccess: (connection, elapsed) {
        final rideId = connection.channelId?.trim().isNotEmpty == true
            ? connection.channelId!.trim()
            : _lastJoinRequest?.channelId ?? _joinedChannelId ?? '';
        if (rideId.isNotEmpty) {
          _joinedChannelId = rideId;
          _connectionState = ConnectionStateType.connectionStateConnected;
          _reconnectAttempt = 0;
          _cancelReconnectTimer();
          _cancelReconnectWatchdog();
          unawaited(
            _syncRtcParticipantState(
              joined: true,
              connectionState: 'connected',
            ),
          );
          debugPrint('[RideCall] rejoin success rideId=$rideId');
        }
      },
      onLeaveChannel: (connection, stats) {
        _connectionState = ConnectionStateType.connectionStateDisconnected;
        _cancelReconnectWatchdog();
        unawaited(
          _syncRtcParticipantState(
            joined: false,
            connectionState: 'disconnected',
          ),
        );
        if (_intentionalLeaveInProgress || _lastJoinRequest == null) {
          _joinedChannelId = null;
        }
      },
      onConnectionLost: (connection) {
        final rideId = _lastJoinRequest?.channelId ?? _joinedChannelId ?? '';
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
        _connectionState = state;
        final rideId = _lastJoinRequest?.channelId ?? _joinedChannelId ?? '';
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
          unawaited(
            _syncRtcParticipantState(
              joined: true,
              connectionState: 'token_refresh',
            ),
          );
          unawaited(_renewAgoraToken(forceRefresh: true));
          _scheduleReconnect(
            reason: reason.name,
            immediate: true,
          );
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

        if (state == ConnectionStateType.connectionStateFailed ||
            state == ConnectionStateType.connectionStateDisconnected) {
          _scheduleReconnect(
            reason: reason.name,
            immediate: state == ConnectionStateType.connectionStateFailed,
          );
        }
      },
      onRequestToken: (connection) {
        unawaited(
          _syncRtcParticipantState(
            joined: true,
            connectionState: 'token_requested',
          ),
        );
        unawaited(_renewAgoraToken(forceRefresh: true));
      },
      onTokenPrivilegeWillExpire: (connection, token) {
        unawaited(
          _syncRtcParticipantState(
            joined: true,
            connectionState: 'token_expiring',
          ),
        );
        unawaited(_renewAgoraToken(forceRefresh: true));
      },
      onError: (err, msg) {
        debugPrint('[RideCall] agora error code=$err message=$msg');
      },
    );

    _engine = engine;
    _eventHandler = handler;

    await engine.initialize(
      RtcEngineContext(
        appId: _agoraAppId,
        channelProfile: ChannelProfileType.channelProfileCommunication,
      ),
    );
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

    await engine.joinChannel(
      token: token,
      channelId: request.channelId,
      uid: _agoraUid(request.uid),
      options: const ChannelMediaOptions(
        channelProfile: ChannelProfileType.channelProfileCommunication,
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
        autoSubscribeAudio: true,
        autoSubscribeVideo: false,
        publishMicrophoneTrack: true,
        enableAudioRecordingOrPlayout: true,
      ),
    );

    _joinedChannelId = request.channelId;
    _connectionState = ConnectionStateType.connectionStateConnecting;
  }

  Future<void> _renewAgoraToken({required bool forceRefresh}) async {
    final request = _lastJoinRequest;
    final engine = _engine;
    if (_disposed || request == null || engine == null) {
      return;
    }

    final token = await fetchAgoraToken(
      request.channelId,
      request.uid,
      forceRefresh: forceRefresh,
    );
    if (token == null || token.isEmpty) {
      _scheduleReconnect(reason: 'token_refresh_failed');
      return;
    }

    try {
      await engine.renewToken(token);
      debugPrint('[RideCall] token renewed rideId=${request.channelId}');
    } catch (error) {
      debugPrint(
        '[RideCall] token renew failed rideId=${request.channelId} error=$error',
      );
      _scheduleReconnect(
        reason: 'renew_token_failed',
        immediate: true,
      );
    }
  }

  void _scheduleReconnect({
    required String reason,
    bool immediate = false,
  }) {
    if (_disposed ||
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
    final delay =
        immediate ? Duration.zero : Duration(seconds: delays[delayIndex]);

    debugPrint(
      '[RideCall] reconnect scheduled rideId=${_lastJoinRequest?.channelId ?? ''} '
      'reason=$reason delayMs=${delay.inMilliseconds}',
    );

    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      unawaited(_attemptReconnect(reason: reason));
    });
  }

  Future<void> _attemptReconnect({required String reason}) async {
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
        request.channelId,
        request.uid,
        forceRefresh: true,
      );
      if (token == null || token.isEmpty) {
        throw const RideCallException(
          'Unable to connect voice calling right now. Please try again.',
        );
      }

      await _leaveEngineChannel();
      await engine.setEnableSpeakerphone(request.speakerOn);
      await engine.muteLocalAudioStream(request.muted);
      await _joinChannelWithToken(
        token: token,
        request: request,
      );

      debugPrint(
        '[RideCall] reconnect attempt started rideId=${request.channelId} '
        'reason=$reason attempt=$_reconnectAttempt',
      );
    } catch (error) {
      debugPrint(
        '[RideCall] reconnect failed rideId=${request.channelId} '
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

      _scheduleReconnect(
        reason: 'watchdog_$reason',
        immediate: true,
      );
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
    final request = _lastJoinRequest;
    if (request == null) {
      return;
    }

    try {
      await updateParticipantState(
        rideId: request.channelId,
        uid: request.uid,
        joined: joined,
        muted: request.muted,
        speaker: request.speakerOn,
        connectionState: connectionState,
      );
    } catch (error) {
      debugPrint(
        '[RideCall] participant sync failed rideId=${request.channelId} '
        'uid=${request.uid} error=$error',
      );
    }
  }

  void _updateJoinRequest({
    bool? muted,
    bool? speakerOn,
  }) {
    final request = _lastJoinRequest;
    if (request == null) {
      return;
    }

    _lastJoinRequest = _VoiceJoinRequest(
      channelId: request.channelId,
      uid: request.uid,
      speakerOn: speakerOn ?? request.speakerOn,
      muted: muted ?? request.muted,
    );
  }

  rtdb.DatabaseReference _callRef(String rideId) {
    return _database.ref('calls/${rideId.trim()}');
  }

  rtdb.DatabaseReference _participantRef(String rideId, String uid) {
    return _callRef(rideId).child(
      'participants/${_participantKey(uid.trim())}',
    );
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
    final normalizedReceiverId = receiverId.trim();
    if (normalizedReceiverId.isEmpty ||
        !_syncedReceiverIds.add(normalizedReceiverId)) {
      return;
    }

    try {
      await _callsByReceiverQuery(normalizedReceiverId).keepSynced(true);
    } catch (error) {
      _syncedReceiverIds.remove(normalizedReceiverId);
      debugPrint(
        '[RideCall] keepSynced failed receiverId=$normalizedReceiverId error=$error',
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

String _resolveTokenEndpoint(String? override) {
  final explicit = (override ?? '').trim();
  if (explicit.isNotEmpty) {
    return explicit;
  }

  const endpoint = String.fromEnvironment('AGORA_TOKEN_ENDPOINT');
  if (endpoint.trim().isNotEmpty) {
    return endpoint.trim();
  }

  // Rider/legacy builds may expose one of these compile-time keys.
  const fallbackCallToken = String.fromEnvironment('CALL_TOKEN_ENDPOINT');
  if (fallbackCallToken.trim().isNotEmpty) {
    return fallbackCallToken.trim();
  }

  const fallbackAgoraToken = String.fromEnvironment('AGORA_CALL_TOKEN_ENDPOINT');
  return fallbackAgoraToken.trim();
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
    case 'accepted':
      return RideCallStatus.accepted;
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

  final riderId = map['rider_id']?.toString().trim() ?? '';
  final driverId = map['driver_id']?.toString().trim() ?? '';
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

  final riderId = map['rider_id']?.toString().trim() ?? '';
  final driverId = map['driver_id']?.toString().trim() ?? '';
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

int _agoraUid(String source) {
  var hash = 0;
  for (final codeUnit in source.codeUnits) {
    hash = ((hash * 31) + codeUnit) & 0x7fffffff;
  }
  return hash == 0 ? 1 : hash;
}
