import 'nexride_contact_constants.dart';

/// User-facing copy for production; technical details belong in logs only.
const String kProductionNexRideSupportMessage =
    'Unable to start NexRide. Please check your connection or contact support at $kNexRideSupportEmail.';

const String kProductionRiderLoginSupportMessage =
    'Unable to finish signing in. Please check your connection or contact support at $kNexRideSupportEmail.';

/// Shown when the Google Map surface fails; technical details only in debug logs.
const String kMapUnavailableUserMessage =
    'Map is unavailable right now. Check your connection or try again later.';
