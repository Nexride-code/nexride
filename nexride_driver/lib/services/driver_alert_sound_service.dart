import 'package:audioplayers/audioplayers.dart';

import '../config/driver_app_config.dart';

class DriverAlertSoundService {
  /// Singleton players: avoids repeated native media-player churn.
  static final AudioPlayer _rideAlertPlayer = AudioPlayer();
  static final AudioPlayer _chatAlertPlayer = AudioPlayer();

  static bool _playersDisposed = false;
  static bool _callAlertActive = false;
  static bool _notificationAssetLoadFailed = false;
  static ReleaseMode? _notificationReleaseMode;

  bool get isCallAlertActive => _callAlertActive;

  Future<bool> _playNotificationAsset({required ReleaseMode releaseMode}) async {
    if (_notificationAssetLoadFailed) {
      return false;
    }
    try {
      if (_notificationReleaseMode != releaseMode) {
        await _rideAlertPlayer.setReleaseMode(releaseMode);
        _notificationReleaseMode = releaseMode;
      }
      await _rideAlertPlayer.stop();
      await _rideAlertPlayer.play(
        AssetSource(DriverAlertSoundConfig.alertAssetPath),
      );
      return true;
    } catch (_) {
      _notificationAssetLoadFailed = true;
      return false;
    }
  }

  Future<void> playRideRequestAlert() async {
    if (!DriverAlertSoundConfig.enableRideRequestAlerts || _callAlertActive) {
      return;
    }
    await _playNotificationAsset(releaseMode: ReleaseMode.release);
  }

  Future<void> startIncomingCallAlert() async {
    if (!DriverAlertSoundConfig.enableIncomingCallAlerts || _callAlertActive) {
      return;
    }

    final played = await _playNotificationAsset(releaseMode: ReleaseMode.loop);
    if (played) {
      _callAlertActive = true;
    }
  }

  Future<void> stopIncomingCallAlert() async {
    try {
      await _rideAlertPlayer.stop();
      if (_notificationReleaseMode != ReleaseMode.release) {
        await _rideAlertPlayer.setReleaseMode(ReleaseMode.release);
        _notificationReleaseMode = ReleaseMode.release;
      }
    } finally {
      _callAlertActive = false;
    }
  }

  Future<void> playChatAlert() async {
    if (!DriverAlertSoundConfig.enableChatAlerts) {
      return;
    }

    try {
      await _chatAlertPlayer.stop();
      await _chatAlertPlayer.play(
        AssetSource(DriverAlertSoundConfig.alertAssetPath),
      );
    } catch (_) {
      return;
    }
  }

  Future<void> dispose() async {
    if (_playersDisposed) return;
    _playersDisposed = true;
    await stopIncomingCallAlert();
    await _rideAlertPlayer.dispose();
    await _chatAlertPlayer.dispose();
  }
}
