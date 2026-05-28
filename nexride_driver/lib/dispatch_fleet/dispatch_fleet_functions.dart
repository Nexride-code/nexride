import 'package:cloud_functions/cloud_functions.dart';

/// Callable bridge for the Dispatch Fleet portal (fleet account + invites only).
class DispatchFleetFunctions {
  DispatchFleetFunctions({FirebaseFunctions? functions})
      : _fn = functions ??
            FirebaseFunctions.instanceFor(region: 'us-central1');

  final FirebaseFunctions _fn;

  Future<Map<String, dynamic>> dispatchFleetRegister(
    Map<String, dynamic> payload,
  ) async {
    final result = await _fn
        .httpsCallable(
          'dispatchFleetRegister',
          options: HttpsCallableOptions(timeout: const Duration(seconds: 45)),
        )
        .call(payload);
    return _asMap(result.data);
  }

  Future<Map<String, dynamic>> dispatchFleetGetMyAccount() async {
    final result = await _fn
        .httpsCallable(
          'dispatchFleetGetMyAccount',
          options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
        )
        .call(<String, dynamic>{});
    return _asMap(result.data);
  }

  Future<Map<String, dynamic>> fleetListMyVerificationDocuments() async {
    final result = await _fn
        .httpsCallable(
          'fleetListMyVerificationDocuments',
          options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
        )
        .call(<String, dynamic>{});
    return _asMap(result.data);
  }

  Future<Map<String, dynamic>> fleetUploadVerificationDocument({
    required String documentType,
    required String storagePath,
    required String fileName,
    required String contentType,
  }) async {
    final result = await _fn
        .httpsCallable(
          'fleetUploadVerificationDocument',
          options: HttpsCallableOptions(timeout: const Duration(seconds: 45)),
        )
        .call(<String, dynamic>{
          'document_type': documentType,
          'documentType': documentType,
          'storage_path': storagePath,
          'storagePath': storagePath,
          'file_name': fileName,
          'fileName': fileName,
          'content_type': contentType,
          'contentType': contentType,
        });
    return _asMap(result.data);
  }

  Future<Map<String, dynamic>> businessCreateDriverInvite({
    required String dispatchVehicleType,
  }) async {
    final result = await _fn
        .httpsCallable(
          'businessCreateDriverInvite',
          options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
        )
        .call(<String, dynamic>{
          'dispatch_vehicle_type': dispatchVehicleType,
          'dispatchVehicleType': dispatchVehicleType,
        });
    return _asMap(result.data);
  }

  Future<Map<String, dynamic>> fleetListLinkedDriversPage({
    int limit = 25,
    String? cursorDriverId,
    bool includeSummary = false,
  }) async {
    final result = await _fn
        .httpsCallable(
          'fleetListLinkedDriversPage',
          options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
        )
        .call(<String, dynamic>{
          'limit': limit,
          if (cursorDriverId != null && cursorDriverId.isNotEmpty)
            'cursor_driver_id': cursorDriverId,
          if (includeSummary) 'include_summary': true,
        });
    return _asMap(result.data);
  }

  Map<String, dynamic> _asMap(dynamic data) {
    if (data is Map) {
      return data.map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
    }
    return <String, dynamic>{};
  }
}

bool dfSuccess(dynamic value) {
  if (value is bool) {
    return value;
  }
  if (value is num) {
    return value != 0;
  }
  final s = value?.toString().trim().toLowerCase();
  return s == 'true' || s == '1' || s == 'yes';
}

String dfRegisterErrorMessage(String? reason) {
  final r = reason?.trim().toLowerCase() ?? '';
  switch (r) {
    case 'unauthorized':
      return 'You must be signed in to register.';
    case 'invalid_business_name':
      return 'Enter a valid fleet business name.';
    case 'fleet_account_already_exists':
      return 'You already have a Dispatch Fleet application on this account.';
    default:
      if (r.isEmpty) {
        return 'Could not submit your application. Please try again.';
      }
      return 'Could not submit your application ($r).';
  }
}

String dfInviteCreateErrorMessage(String? reason) {
  final r = reason?.trim().toLowerCase() ?? '';
  switch (r) {
    case 'unauthorized':
      return 'You are not signed in. Log out and sign in again.';
    case 'not_found':
    case 'merchant_not_found':
      return 'No Dispatch Fleet account found for this login.';
    case 'fleet_not_approved':
      return 'Your fleet account is not approved yet. You cannot create invites.';
    case 'fleet_suspended':
      return 'Your fleet account is suspended. Contact support.';
    case 'not_dispatch_fleet':
      return 'This login is not linked to a Dispatch Fleet account.';
    case 'invalid_dispatch_vehicle_type':
    case 'invalid_vehicle_type':
      return 'Invalid vehicle type. Choose bike, car, or van.';
    case 'forbidden':
      return 'Your account cannot create fleet invites. Contact support.';
    case 'invite_already_exists':
      return 'An active invite already exists for that code. Try again.';
    default:
      if (r.isEmpty) {
        return 'Could not create invite. Please try again.';
      }
      return 'Could not create invite ($r).';
  }
}

String dfLinkedBikersErrorMessage(String? reason) {
  final r = reason?.trim().toLowerCase() ?? '';
  switch (r) {
    case 'unauthorized':
      return 'You are not signed in. Log out and sign in again.';
    case 'not_found':
      return 'No Dispatch Fleet account found for this login.';
    case 'forbidden':
      return 'Your account cannot view linked bikers.';
    case 'not_dispatch_fleet':
      return 'This login is not linked to a Dispatch Fleet account.';
    default:
      if (r.isEmpty) {
        return 'Could not load linked bikers. Please try again.';
      }
      return 'Could not load linked bikers ($r).';
  }
}
