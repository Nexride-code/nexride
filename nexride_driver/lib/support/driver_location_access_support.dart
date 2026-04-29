import 'package:geolocator/geolocator.dart';

import '../config/driver_app_config.dart';

class DriverLocationCapability {
  const DriverLocationCapability({
    required this.canBrowseDriverApp,
    required this.canGoOnline,
    required this.locationServiceEnabled,
    required this.permission,
    required this.title,
    required this.message,
    required this.recommendOpenSettings,
  });

  final bool canBrowseDriverApp;
  final bool canGoOnline;
  final bool locationServiceEnabled;
  final LocationPermission permission;
  final String title;
  final String message;
  final bool recommendOpenSettings;

  bool get hasLocationAccess =>
      permission == LocationPermission.always ||
      permission == LocationPermission.whileInUse;
}

Future<DriverLocationCapability> evaluateDriverLocationCapability() async {
  if (DriverLocationPolicy.useTestDriverLocation) {
    return DriverLocationCapability(
      canBrowseDriverApp: true,
      canGoOnline: true,
      locationServiceEnabled: true,
      permission: LocationPermission.whileInUse,
      title: 'Test location ready',
      message:
          'A temporary ${DriverLaunchScope.labelForCity(DriverLocationPolicy.testDriverCity)} test location is active while you verify driver and rider trip sync.',
      recommendOpenSettings: false,
    );
  }

  bool locationServiceEnabled = false;
  try {
    locationServiceEnabled = await Geolocator.isLocationServiceEnabled();
  } catch (_) {
    locationServiceEnabled = false;
  }

  LocationPermission permission;
  try {
    permission = await Geolocator.checkPermission();
  } catch (_) {
    permission = LocationPermission.denied;
  }

  const canBrowseDriverApp = DriverLocationPolicy.allowBrowseWithoutLocation;
  final hasPermission = permission == LocationPermission.always ||
      permission == LocationPermission.whileInUse;
  final canGoOnline = !DriverLocationPolicy.requireLocationForGoOnline ||
      (locationServiceEnabled && hasPermission);

  if (!locationServiceEnabled) {
    return DriverLocationCapability(
      canBrowseDriverApp: canBrowseDriverApp,
      canGoOnline: canGoOnline,
      locationServiceEnabled: false,
      permission: permission,
      title: 'Location required to go online',
      message:
          'Turn on Location Services when you are ready to receive live trips in ${DriverLaunchScope.launchCitiesLabel}.',
      recommendOpenSettings: true,
    );
  }

  if (permission == LocationPermission.denied) {
    return DriverLocationCapability(
      canBrowseDriverApp: canBrowseDriverApp,
      canGoOnline: false,
      locationServiceEnabled: true,
      permission: permission,
      title: 'Location access required',
      message:
          'Allow location access when you are ready to receive live trips in ${DriverLaunchScope.launchCitiesLabel}.',
      recommendOpenSettings: false,
    );
  }

  if (permission == LocationPermission.deniedForever) {
    return DriverLocationCapability(
      canBrowseDriverApp: canBrowseDriverApp,
      canGoOnline: false,
      locationServiceEnabled: true,
      permission: permission,
      title: 'Location access required',
      message:
          'Enable location again from app settings before you go online in ${DriverLaunchScope.launchCitiesLabel}.',
      recommendOpenSettings: true,
    );
  }

  return DriverLocationCapability(
    canBrowseDriverApp: canBrowseDriverApp,
    canGoOnline: true,
    locationServiceEnabled: true,
    permission: permission,
    title: 'Location ready',
    message: DriverLaunchScope.goOnlineLocationMessage,
    recommendOpenSettings: false,
  );
}
