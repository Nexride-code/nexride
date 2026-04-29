import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../config/driver_app_config.dart';

class DriverAlertSoundService {
  final AudioPlayer _notificationPlayer = AudioPlayer();
  final AudioPlayer _chatPlayer = AudioPlayer();
  bool _callAlertActive = false;

  bool get isCallAlertActive => _callAlertActive;

  Future<void> playRideRequestAlert() async {
    if (!DriverAlertSoundConfig.enableRideRequestAlerts || _callAlertActive) {
      return;
    }

    try {
      await _notificationPlayer.stop();
      await _notificationPlayer.setReleaseMode(ReleaseMode.release);
      await _notificationPlayer.play(
        AssetSource(DriverAlertSoundConfig.alertAssetPath),
      );
    } catch (error, stackTrace) {
      debugPrint(
        '[DriverAlertSound] playRideRequestAlert failed asset=${DriverAlertSoundConfig.alertAssetPath} error=$error',
      );
      debugPrintStack(
        label: '[DriverAlertSound] playRideRequestAlert',
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> startIncomingCallAlert() async {
    if (!DriverAlertSoundConfig.enableIncomingCallAlerts || _callAlertActive) {
      return;
    }

    try {
      await _notificationPlayer.setReleaseMode(ReleaseMode.loop);
      await _notificationPlayer.stop();
      await _notificationPlayer.play(
        AssetSource(DriverAlertSoundConfig.alertAssetPath),
      );
      _callAlertActive = true;
    } catch (error, stackTrace) {
      debugPrint(
        '[DriverAlertSound] startIncomingCallAlert failed asset=${DriverAlertSoundConfig.alertAssetPath} error=$error',
      );
      debugPrintStack(
        label: '[DriverAlertSound] startIncomingCallAlert',
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> stopIncomingCallAlert() async {
    try {
      await _notificationPlayer.stop();
      await _notificationPlayer.setReleaseMode(ReleaseMode.release);
    } finally {
      _callAlertActive = false;
    }
  }

  Future<void> playChatAlert() async {
    if (!DriverAlertSoundConfig.enableChatAlerts) {
      return;
    }

    try {
      await _chatPlayer.stop();
      await _chatPlayer.play(AssetSource(DriverAlertSoundConfig.alertAssetPath));
    } catch (error, stackTrace) {
      debugPrint(
        '[DriverAlertSound] playChatAlert failed asset=${DriverAlertSoundConfig.alertAssetPath} error=$error',
      );
      debugPrintStack(
        label: '[DriverAlertSound] playChatAlert',
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> dispose() async {
    await stopIncomingCallAlert();
    await _notificationPlayer.dispose();
    await _chatPlayer.dispose();
  }
}
