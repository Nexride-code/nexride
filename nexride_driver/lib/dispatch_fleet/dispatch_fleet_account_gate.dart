import 'dispatch_fleet_functions.dart';

/// Routes fleet owners to the correct portal screen from [dispatchFleetGetMyAccount].
enum DispatchFleetAccountDestination {
  signup,
  pending,
  rejected,
  suspended,
  dashboard,
}

Map<String, dynamic>? dfAccountMap(Map<String, dynamic>? response) {
  if (response == null) {
    return null;
  }
  final raw = response['account'];
  if (raw is Map) {
    return raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
  }
  return null;
}

String dfAccountStatus(Map<String, dynamic>? account) {
  return account?['merchant_status']?.toString().trim().toLowerCase() ?? '';
}

DispatchFleetAccountDestination destinationForFleetAccountResponse(
  Map<String, dynamic>? response,
) {
  if (!dfSuccess(response?['success'])) {
    final reason = response?['reason']?.toString().trim().toLowerCase() ?? '';
    if (reason == 'not_found') {
      return DispatchFleetAccountDestination.signup;
    }
    return DispatchFleetAccountDestination.pending;
  }
  final account = dfAccountMap(response);
  if (account == null) {
    return DispatchFleetAccountDestination.signup;
  }
  final status = dfAccountStatus(account);
  if (status == 'approved') {
    return DispatchFleetAccountDestination.dashboard;
  }
  if (status == 'suspended') {
    return DispatchFleetAccountDestination.suspended;
  }
  if (status == 'rejected') {
    return DispatchFleetAccountDestination.rejected;
  }
  return DispatchFleetAccountDestination.pending;
}
