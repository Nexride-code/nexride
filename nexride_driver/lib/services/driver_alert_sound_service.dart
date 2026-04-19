import 'package:audioplayers/audioplayers.dart';

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

    await _notificationPlayer.stop();
    await _notificationPlayer.setReleaseMode(ReleaseMode.release);
    await _notificationPlayer.play(
      AssetSource(DriverAlertSoundConfig.alertAssetPath),
    );
  }

  Future<void> startIncomingCallAlert() async {
    if (!DriverAlertSoundConfig.enableIncomingCallAlerts || _callAlertActive) {
      return;
    }

    await _notificationPlayer.setReleaseMode(ReleaseMode.loop);
    await _notificationPlayer.stop();
    await _notificationPlayer.play(
      AssetSource(DriverAlertSoundConfig.alertAssetPath),
    );
    _callAlertActive = true;
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

    await _chatPlayer.stop();
    await _chatPlayer.play(AssetSource(DriverAlertSoundConfig.alertAssetPath));
  }

  Future<void> dispose() async {
    await stopIncomingCallAlert();
    await _notificationPlayer.dispose();
    await _chatPlayer.dispose();
  }
}
