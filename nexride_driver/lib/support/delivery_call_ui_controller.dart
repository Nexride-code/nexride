import 'dart:async';

import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/material.dart';

import '../services/call_permissions.dart';
import '../services/call_service.dart';
import '../trip_sync/delivery_state_machine.dart';
import 'delivery_call_support.dart';
import 'shared_call_listener_support.dart';

/// Manages in-app delivery voice calls on the driver / biker map screen.
class DeliveryCallUiController with WidgetsBindingObserver {
  DeliveryCallUiController({
    required this.callService,
    required this.getOverlayContext,
    required this.onBusyChanged,
    this.remoteDisplayName = 'Customer',
  });

  final CallService callService;
  final BuildContext? Function() getOverlayContext;
  final ValueChanged<bool> onBusyChanged;
  String remoteDisplayName;

  static const CallSessionKind _kind = CallSessionKind.delivery;
  static const Color _gold = Color(0xFFD4AF37);
  static const Color _canvas = Color(0xFF08111F);
  static const Color _surface = Color(0xFF111827);

  final CallPermissions _callPermissions = const CallPermissions();
  late final SharedCallStateListener _sharedCallListener =
      SharedCallStateListener(callService);

  StreamSubscription<rtdb.DatabaseEvent>? _subscription;
  String? _deliveryId;
  String? _localUid;
  RideCallSession? _session;
  OverlayEntry? _overlayEntry;
  Timer? _ringTimeoutTimer;
  Timer? _durationTimer;
  Duration _callDuration = Duration.zero;
  bool _joinedChannel = false;
  bool _joinInFlight = false;
  bool _muted = false;
  bool _speakerOn = true;
  bool _isStartingCall = false;
  bool _isEndingCall = false;
  String? _terminalOverlayMessage;
  VoidCallback? _remotePeerListener;
  VoidCallback? _remotePeerStatusListener;

  bool get isStartingCall => _isStartingCall;

  void _ensureCallUiListeners() {
    _remotePeerListener ??= () {
      if (callService.remotePeerJoined && (_session?.isActive ?? false)) {
        _startDurationTicker(
          _session?.answeredAtDateTime ??
              _session?.acceptedAtDateTime ??
              DateTime.now(),
        );
        _refreshOverlay();
      } else if (callService.isLocalVoiceJoined) {
        _refreshOverlay();
      }
    };
    _remotePeerStatusListener ??= _refreshOverlay;
    callService.remotePeerJoinedNotifier.addListener(_remotePeerListener!);
    callService.remotePeerStatusNotifier.addListener(_remotePeerStatusListener!);
  }

  void _removeCallUiListeners() {
    if (_remotePeerListener != null) {
      callService.remotePeerJoinedNotifier.removeListener(_remotePeerListener!);
    }
    if (_remotePeerStatusListener != null) {
      callService.remotePeerStatusNotifier
          .removeListener(_remotePeerStatusListener!);
    }
  }

  void attach({
    required String deliveryId,
    required String driverUid,
    required String customerUid,
    String? remoteName,
  }) {
    final id = deliveryId.trim();
    final local = driverUid.trim();
    final remote = customerUid.trim();
    if (id.isEmpty || local.isEmpty || remote.isEmpty) {
      return;
    }
    if (remoteName?.trim().isNotEmpty ?? false) {
      remoteDisplayName = remoteName!.trim();
    }
    if (_deliveryId == id && _subscription != null) {
      return;
    }
    _subscription?.cancel();
    _deliveryId = id;
    _localUid = local;
    _ensureCallUiListeners();
    final path = CallService.sessionPath(id, kind: _kind);
    _subscription = callService.observeCall(id, kind: _kind).listen(
      (event) {
        final session = RideCallSession.fromSnapshotValue(
          id,
          event.snapshot.value,
        );
        unawaited(_handleSessionUpdate(session));
      },
      onError: (Object error) {
        debugPrint('CALL_ERROR path=$path reason=$error');
      },
    );
  }

  void detachListener() {
    _subscription?.cancel();
    _subscription = null;
    _sharedCallListener.detach();
    _deliveryId = null;
  }

  Future<void> detach({bool endCall = false}) async {
    final session = _session;
    final localUid = _localUid ?? '';
    if (endCall && session != null && !session.isTerminal && localUid.isNotEmpty) {
      await callService.endCallFromUserTap(
        rideId: session.rideId,
        endedByUid: localUid,
        endedByRole: 'driver',
        kind: _kind,
      );
    }
    _cancelRingTimeout();
    _stopDurationTicker();
    detachListener();
    await _leaveVoiceAndCloseUi(reason: 'detach');
  }

  void registerLifecycle() {
    WidgetsBinding.instance.addObserver(this);
    _ensureCallUiListeners();
  }

  void unregisterLifecycle() {
    WidgetsBinding.instance.removeObserver(this);
    _removeCallUiListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_session != null && !_session!.isTerminal) {
      unawaited(
        callService.updateParticipantState(
          rideId: _session!.rideId,
          uid: _localUid ?? '',
          joined: _session!.isActive && _joinedChannel,
          muted: _muted,
          speaker: _speakerOn,
          foreground: state == AppLifecycleState.resumed,
          kind: _kind,
          updateKind: ParticipantUpdateKind.foreground,
        ),
      );
    }
  }

  Future<void> dispose() async {
    unregisterLifecycle();
    await detach(endCall: false);
  }

  Future<void> startOutgoingCall({
    required String deliveryId,
    required Map<String, dynamic>? delivery,
    required String driverUid,
    required DeliveryLifecycleState state,
  }) async {
    if (_isStartingCall) {
      return;
    }
    final normalizedDriver = driverUid.trim();
    final customerUid = deliveryCallCustomerId(delivery);
    if (normalizedDriver.isEmpty ||
        customerUid.isEmpty ||
        !isActiveDeliveryCallEligible(
          activeDeliveryId: deliveryId,
          delivery: delivery,
          state: state,
          driverId: normalizedDriver,
        )) {
      throw const RideCallException('In-app call is not available yet.');
    }
    _isStartingCall = true;
    onBusyChanged(true);
    try {
      attach(
        deliveryId: deliveryId,
        driverUid: normalizedDriver,
        customerUid: customerUid,
      );
      if (!callService.hasRtcConfiguration) {
        throw RideCallException(callService.unavailableUserMessage);
      }
      final mic = await _callPermissions.requestMicrophonePermission();
      if (!mic.isGranted) {
        throw const RideCallException(
          'Microphone access is required to place this call.',
        );
      }
      final contextId = deliveryId.trim();
      await callService.prefetchAgoraToken(
        channelId: contextId,
        uid: normalizedDriver,
      );
      final result = await callService.requestOutgoingVoiceCall(
        rideId: contextId,
        riderId: customerUid,
        driverId: normalizedDriver,
        startedBy: 'driver',
        kind: _kind,
      );
      if (result.session != null) {
        await _handleSessionUpdate(result.session);
      }
    } finally {
      _isStartingCall = false;
      onBusyChanged(false);
    }
  }

  Future<void> _handleSessionUpdate(RideCallSession? session) async {
    if (session == null) {
      if (_session != null && !_session!.isTerminal) {
        final contextId = (_deliveryId ?? _session!.rideId).trim();
        if (contextId.isNotEmpty) {
          final refetched = await callService.fetchCall(contextId, kind: _kind);
          if (refetched != null) {
            await _handleSessionUpdate(refetched);
            return;
          }
        }
        return;
      }
      await _leaveVoiceAndCloseUi(reason: 'remote_session_null');
      return;
    }

    if (session.isTerminal) {
      debugPrint(
        'CALL_TERMINAL_SNAPSHOT_RECEIVED rideId=${session.rideId} '
        'status=${session.status.name} callerId=${session.callerId} '
        'receiverId=${session.receiverId} ended_by=${session.endedBy ?? ''} '
        'source=delivery_call_ui',
      );
      debugPrint(
        'CALL_SESSION_TERMINAL_REMOTE rideId=${session.rideId} '
        'status=${session.status.name} ended_by=${session.endedBy ?? ''}',
      );
      debugPrint(
        'CALL_TERMINAL_OBEYED rideId=${session.rideId} status=${session.status.name} '
        'callerId=${session.callerId} receiverId=${session.receiverId} '
        'source=delivery_call_ui',
      );
      _cancelRingTimeout();
      _stopDurationTicker();
      await _leaveVoiceAndCloseUi(
        reason: 'remote_terminal_${session.status.name}',
        session: session,
      );
      return;
    }

    final localUid = _localUid ?? '';
    if (localUid.isEmpty ||
        (session.callerId != localUid && session.receiverId != localUid)) {
      return;
    }

    _session = session;
    _attachSharedCallListener(session);

    if (session.isRinging) {
      if (session.callerId == localUid) {
        _scheduleOutgoingRingTimeout(session);
      } else if (session.receiverId == localUid) {
        _scheduleIncomingRingTimeout(session);
      }
      _refreshOverlay();
      return;
    }

    if (session.isActive) {
      _cancelRingTimeout();
      if (callService.remotePeerJoined) {
        _startDurationTicker(
          session.answeredAtDateTime ??
              session.acceptedAtDateTime ??
              DateTime.now(),
        );
      }
      _refreshOverlay();
      if (!_joinedChannel && !_joinInFlight) {
        await _joinVoice(session);
      }
      _refreshOverlay();
      return;
    }
  }

  void _attachSharedCallListener(RideCallSession session) {
    final callId = session.callId?.trim() ?? '';
    final contextId = session.rideId.trim();
    if (callId.isEmpty || contextId.isEmpty || session.isTerminal) {
      return;
    }
    _sharedCallListener.attach(
      callId: callId,
      contextId: contextId,
      uid: _localUid ?? '',
      onTerminal: _handleSharedCallTerminal,
    );
  }

  Future<void> _handleSharedCallTerminal({
    required String callId,
    required String contextId,
    required String status,
    String? endedBy,
  }) async {
    if (_session?.isTerminal ?? false) {
      return;
    }
    _terminalOverlayMessage = 'Call ended';
    _cancelRingTimeout();
    _stopDurationTicker();
    _refreshOverlay();
    final confirmed = await callService.fetchCall(contextId, kind: _kind);
    if (confirmed != null && confirmed.isTerminal) {
      await _handleSessionUpdate(confirmed);
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await _leaveVoiceAndCloseUi(
      reason: 'shared_call_$status',
      session: _session,
    );
    _terminalOverlayMessage = null;
  }

  bool _isIncoming(RideCallSession session) {
    final localUid = _localUid ?? '';
    return session.isRinging && session.receiverId == localUid;
  }

  bool _isOutgoing(RideCallSession session) {
    final localUid = _localUid ?? '';
    return session.isRinging && session.callerId == localUid;
  }

  void _scheduleOutgoingRingTimeout(RideCallSession session) {
    _ringTimeoutTimer?.cancel();
    final deadline = session.expiresAtDateTime ??
        (session.createdAtDateTime ?? DateTime.now()).add(
          const Duration(seconds: kDeliveryCallRingTimeoutSeconds),
        );
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      unawaited(_timeoutOutgoingCall(session));
      return;
    }
    _ringTimeoutTimer = Timer(remaining, () {
      unawaited(_timeoutOutgoingCall(session));
    });
  }

  void _scheduleIncomingRingTimeout(RideCallSession session) {
    _scheduleOutgoingRingTimeout(session);
  }

  Future<void> _timeoutOutgoingCall(RideCallSession session) async {
    final localUid = _localUid ?? '';
    if (localUid.isEmpty) {
      return;
    }
    if (_session?.isRinging ?? false) {
      if (_isOutgoing(session)) {
        await callService.cancelCallIfStillRinging(
          rideId: session.rideId,
          endedBy: localUid,
          kind: _kind,
        );
      } else {
        await callService.failCallIfStillRinging(
          rideId: session.rideId,
          kind: _kind,
        );
      }
    }
  }

  void _cancelRingTimeout() {
    _ringTimeoutTimer?.cancel();
    _ringTimeoutTimer = null;
  }

  Future<void> _joinVoice(RideCallSession session) async {
    final localUid = _localUid ?? '';
    if (localUid.isEmpty || _joinedChannel || _joinInFlight) {
      return;
    }
    _joinInFlight = true;
    final contextId = CallService.callContextId(session);
    try {
      await callService.prefetchAgoraToken(
        channelId: contextId,
        uid: localUid,
      );
      await callService.ensureJoinedVoiceChannel(
        channelId: contextId,
        uid: localUid,
        speakerOn: _speakerOn,
        muted: _muted,
        kind: _kind,
      );
      if (_session?.isTerminal ?? false) {
        await callService.leaveVoiceChannel();
        return;
      }
      await callService.waitForVoiceJoinConnected();
      if (_session?.isTerminal ?? false) {
        await callService.leaveVoiceChannel();
        return;
      }
      _joinedChannel = true;
      _refreshOverlay();
    } catch (error) {
      debugPrint('CALL_ERROR contextId=$contextId reason=join_failed error=$error');
      final localUid = _localUid ?? '';
      if (localUid.isNotEmpty) {
        if (session.isActive) {
          await callService.endCallFromUserTap(
            rideId: session.rideId,
            endedByUid: localUid,
            endedByRole: 'driver',
            kind: _kind,
          );
        } else if (session.isRinging) {
          if (_isOutgoing(session)) {
            await callService.cancelCallIfStillRinging(
              rideId: session.rideId,
              endedBy: localUid,
              kind: _kind,
            );
          } else {
            await callService.declineCall(
              rideId: session.rideId,
              endedBy: localUid,
              receiverId: localUid,
              kind: _kind,
            );
          }
        }
      }
      await _leaveVoiceAndCloseUi(reason: 'join_failed');
    } finally {
      _joinInFlight = false;
    }
  }

  Future<void> _acceptIncoming() async {
    final session = _session;
    final localUid = _localUid ?? '';
    if (session == null || localUid.isEmpty) {
      return;
    }
    final mic = await _callPermissions.requestMicrophonePermission();
    if (!mic.isGranted) {
      return;
    }
    final accepted = await callService.acceptCall(
      rideId: session.rideId,
      receiverId: localUid,
      kind: _kind,
    );
    if (!accepted) {
      return;
    }
    _cancelRingTimeout();
    _refreshOverlay();
    final updated = await callService.fetchCall(session.rideId, kind: _kind);
    if (updated != null) {
      await _handleSessionUpdate(updated);
    }
  }

  Future<void> _declineIncoming() async {
    final session = _session;
    final localUid = _localUid ?? '';
    if (session == null || localUid.isEmpty) {
      return;
    }
    await callService.declineCall(
      rideId: session.rideId,
      endedBy: localUid,
      receiverId: localUid,
      kind: _kind,
    );
  }

  Future<void> _cancelOutgoing() async {
    final session = _session;
    final localUid = _localUid ?? '';
    if (session == null || localUid.isEmpty) {
      return;
    }
    await callService.cancelCallIfStillRinging(
      rideId: session.rideId,
      endedBy: localUid,
      kind: _kind,
    );
  }

  Future<void> _endCall() async {
    if (_isEndingCall) {
      return;
    }
    _isEndingCall = true;
    try {
      final session = _session;
      final localUid = _localUid ?? '';
      if (session == null || localUid.isEmpty) {
        return;
      }
      debugPrint(
        'CALL_END_TAP rideId=${session.rideId} role=driver',
      );
      await callService.endCallFromUserTap(
        rideId: session.rideId,
        endedByUid: localUid,
        endedByRole: 'driver',
        kind: _kind,
      );
      await _leaveVoiceAndCloseUi(
        reason: 'local_end_tap',
        session: session,
      );
    } finally {
      _isEndingCall = false;
    }
  }

  Future<void> _toggleMute() async {
    final nextMuted = !_muted;
    _muted = nextMuted;
    await callService.setMuted(nextMuted);
    _refreshOverlay();
  }

  Future<void> _toggleSpeaker() async {
    final nextSpeaker = !_speakerOn;
    _speakerOn = nextSpeaker;
    await callService.setSpeakerOn(nextSpeaker);
    _refreshOverlay();
  }

  Future<void> _leaveVoiceAndCloseUi({
    required String reason,
    RideCallSession? session,
  }) async {
    final activeSession = session ?? _session;
    final contextId = activeSession?.rideId ?? _deliveryId ?? '';
    try {
      await callService.leaveVoiceChannel();
      if (contextId.isNotEmpty) {
        debugPrint(
          'CALL_LEAVE_CHANNEL rideId=$contextId source=$reason',
        );
      }
    } catch (_) {
      // Local teardown must continue even if Agora was never connected.
    }
    _joinedChannel = false;
    _joinInFlight = false;
    _removeOverlay();
    if (contextId.isNotEmpty) {
      debugPrint(
        'CALL_OVERLAY_CLOSE rideId=$contextId source=$reason',
      );
      debugPrint(
        'CALL_CLEANUP_DONE rideId=$contextId '
        'status=${activeSession?.status.name ?? 'cleared'} '
        'callerId=${activeSession?.callerId ?? ''} '
        'receiverId=${activeSession?.receiverId ?? ''} source=$reason',
      );
    }
    _session = null;
    _terminalOverlayMessage = null;
    _cancelRingTimeout();
    _stopDurationTicker();
  }

  void _startDurationTicker(DateTime startAt) {
    _durationTimer?.cancel();
    _callDuration = DateTime.now().difference(startAt);
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _callDuration = DateTime.now().difference(startAt);
      _overlayEntry?.markNeedsBuild();
    });
  }

  void _stopDurationTicker() {
    _durationTimer?.cancel();
    _durationTimer = null;
    _callDuration = Duration.zero;
  }

  String _formatDuration(Duration duration) {
    final totalSeconds = duration.inSeconds;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  void _refreshOverlay() {
    final context = getOverlayContext();
    if (context == null || !context.mounted) {
      return;
    }
    if (_terminalOverlayMessage != null) {
      final overlay = Overlay.maybeOf(context, rootOverlay: true);
      if (overlay == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _refreshOverlay());
        return;
      }
      _overlayEntry ??= OverlayEntry(builder: (_) => _buildOverlay());
      if (!_overlayEntry!.mounted) {
        overlay.insert(_overlayEntry!);
      } else {
        _overlayEntry!.markNeedsBuild();
      }
      return;
    }
    final session = _session;
    if (session == null || session.isTerminal) {
      _removeOverlay();
      return;
    }

    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _refreshOverlay());
      return;
    }

    _overlayEntry ??= OverlayEntry(builder: (_) => _buildOverlay());
    if (!_overlayEntry!.mounted) {
      overlay.insert(_overlayEntry!);
    } else {
      _overlayEntry!.markNeedsBuild();
    }
  }

  void _removeOverlay() {
    final entry = _overlayEntry;
    _overlayEntry = null;
    if (entry != null && entry.mounted) {
      entry.remove();
    }
  }

  Widget _buildOverlay() {
    final terminalMessage = _terminalOverlayMessage;
    if (terminalMessage != null) {
      return _buildFullScreenShell(
        title: remoteDisplayName,
        subtitle: terminalMessage,
        body: const SizedBox.shrink(),
      );
    }

    final session = _session;
    if (session == null || session.isTerminal) {
      return const SizedBox.shrink();
    }

    if (_isIncoming(session)) {
      return _buildFullScreenShell(
        title: remoteDisplayName,
        subtitle: 'Incoming call',
        body: Row(
          children: [
            Expanded(
              child: _buildActionButton(
                label: 'Decline',
                icon: Icons.call_end_rounded,
                color: const Color(0xFFE85D4C),
                onPressed: () => unawaited(_declineIncoming()),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildActionButton(
                label: 'Accept',
                icon: Icons.call_rounded,
                color: const Color(0xFF22A45D),
                onPressed: () => unawaited(_acceptIncoming()),
              ),
            ),
          ],
        ),
      );
    }

    final isOutgoingRinging = _isOutgoing(session);
    final statusText = isOutgoingRinging
        ? 'Calling'
        : callService.isVoiceConnected
            ? 'Connected ${_formatDuration(_callDuration)}'
            : callService.isLocalVoiceJoined
                ? (callService.remotePeerStatusNotifier.value ??
                    'Connecting to other party…')
                : session.isActive
                    ? 'Connecting...'
                    : 'Connecting...';

    final controls = isOutgoingRinging
        ? _buildActionButton(
            label: 'Cancel',
            icon: Icons.call_end_rounded,
            color: const Color(0xFFE85D4C),
            onPressed: () => unawaited(_cancelOutgoing()),
          )
        : Row(
            children: [
              Expanded(
                child: _buildControlChip(
                  label: _muted ? 'Unmute' : 'Mute',
                  icon: _muted ? Icons.mic_off_rounded : Icons.mic_none_rounded,
                  onTap: () => unawaited(_toggleMute()),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildControlChip(
                  label: _speakerOn ? 'Speaker' : 'Earpiece',
                  icon: _speakerOn
                      ? Icons.volume_up_rounded
                      : Icons.hearing_rounded,
                  onTap: () => unawaited(_toggleSpeaker()),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildControlChip(
                  label: 'End',
                  icon: Icons.call_end_rounded,
                  color: const Color(0xFFE85D4C),
                  onTap: _isEndingCall ? null : () => unawaited(_endCall()),
                ),
              ),
            ],
          );

    return _buildFullScreenShell(
      title: remoteDisplayName,
      subtitle: statusText,
      body: controls,
    );
  }

  Widget _buildFullScreenShell({
    required String title,
    required String subtitle,
    required Widget body,
  }) {
    return Material(
      color: _canvas,
      child: SafeArea(
        child: Scaffold(
          backgroundColor: _canvas,
          body: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: Column(
              children: [
                const Spacer(flex: 2),
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    color: _gold.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: const Icon(
                    Icons.person_rounded,
                    color: _gold,
                    size: 48,
                  ),
                ),
                const SizedBox(height: 28),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 28,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  subtitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(flex: 3),
                SizedBox(width: double.infinity, child: body),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return FilledButton.icon(
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
      style: FilledButton.styleFrom(
        backgroundColor: color,
        minimumSize: const Size.fromHeight(52),
      ),
    );
  }

  Widget _buildControlChip({
    required String label,
    required IconData icon,
    required VoidCallback? onTap,
    Color? color,
  }) {
    return Material(
      color: color ?? _surface,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white),
              const SizedBox(height: 6),
              Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
