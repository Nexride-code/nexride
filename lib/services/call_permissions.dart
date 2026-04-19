import 'package:permission_handler/permission_handler.dart';

class MicrophonePermissionResult {
  const MicrophonePermissionResult({
    required this.isGranted,
    required this.shouldOpenSettings,
  });

  final bool isGranted;
  final bool shouldOpenSettings;
}

class CallPermissions {
  const CallPermissions();

  Future<MicrophonePermissionResult> requestMicrophonePermission() async {
    final currentStatus = await Permission.microphone.status;
    if (currentStatus.isGranted) {
      return const MicrophonePermissionResult(
        isGranted: true,
        shouldOpenSettings: false,
      );
    }

    final requestedStatus = await Permission.microphone.request();
    return MicrophonePermissionResult(
      isGranted: requestedStatus.isGranted,
      shouldOpenSettings: requestedStatus.isPermanentlyDenied,
    );
  }

  Future<bool> openSettings() {
    return openAppSettings();
  }
}
