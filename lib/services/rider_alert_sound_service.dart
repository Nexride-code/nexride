import 'dart:async';

import 'package:flutter/services.dart';

import '../config/rider_app_config.dart';

class RiderAlertSoundService {
  Timer? _incomingCallAlertTimer;
  bool _incomingCallAlertActive = false;

  bool get isIncomingCallAlertActive => _incomingCallAlertActive;

  Future<void> playChatAlert() async {
    if (!RiderAlertSoundConfig.enableChatAlerts) {
      return;
    }

    await _playPlatformAlert();
  }

  Future<void> playRideStatusAlert(String status) async {
    if (!RiderAlertSoundConfig.shouldPlayRideStatusAlert(status)) {
      return;
    }

    await _playPlatformAlert();
  }

  Future<void> startIncomingCallAlert() async {
    if (!RiderAlertSoundConfig.enableIncomingCallAlerts ||
        _incomingCallAlertActive) {
      return;
    }

    _incomingCallAlertActive = true;
    await _playPlatformAlert();
    _incomingCallAlertTimer = Timer.periodic(
      RiderAlertSoundConfig.incomingCallRepeatInterval,
      (_) {
        unawaited(_playPlatformAlert());
      },
    );
  }

  Future<void> stopIncomingCallAlert() async {
    _incomingCallAlertTimer?.cancel();
    _incomingCallAlertTimer = null;
    _incomingCallAlertActive = false;
  }

  void dispose() {
    _incomingCallAlertTimer?.cancel();
    _incomingCallAlertTimer = null;
    _incomingCallAlertActive = false;
  }

  Future<void> _playPlatformAlert() async {
    if (!RiderAlertSoundConfig.enableNotifications) {
      return;
    }

    await SystemSound.play(SystemSoundType.alert);
  }
}
