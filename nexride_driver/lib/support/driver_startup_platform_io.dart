import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

bool get driverStartupIsIosSimulator {
  if (kIsWeb) {
    return false;
  }
  if (!Platform.isIOS) {
    return false;
  }
  return Platform.environment.containsKey('SIMULATOR_DEVICE_NAME') ||
      Platform.environment.containsKey('SIMULATOR_UDID');
}
