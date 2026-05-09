import 'nexride_contact_constants.dart';

const String kProductionNexRideSupportMessage =
    'Unable to start NexRide. Please check your connection or contact support at $kNexRideSupportEmail.';

/// Shown after in-app retries on cold start still cannot reach Firebase (e.g. very weak EDGE).
const String kDriverBootstrapAfterRetriesMessage =
    "We couldn't finish connecting yet. Your network may be very slow — check signal or Wi‑Fi, "
    'then tap Try again. Contact $kNexRideSupportEmail only if this keeps happening on a strong connection.';

const String kMapUnavailableUserMessage =
    'Map is unavailable right now. Check your connection or try again later.';
