import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';

import 'config/rider_app_config.dart';
import 'config/rtdb_ride_request_contract.dart';
import 'services/dispatch_photo_upload_service.dart';
import 'services/rider_trust_bootstrap_service.dart';
import 'services/rider_trust_rules_service.dart';
import 'services/trip_safety_service.dart';
import 'service_type.dart';
import 'support/rider_fare_support.dart';
import 'support/rtdb_flow_debug_log.dart';
import 'support/startup_rtdb_support.dart';
import 'trip_sync/trip_state_machine.dart';

class DispatchRequestScreen extends StatefulWidget {
  const DispatchRequestScreen({super.key});

  @override
  State<DispatchRequestScreen> createState() => _DispatchRequestScreenState();
}

enum _DispatchItemPhotoSource { camera, gallery }

class _DispatchRequestScreenState extends State<DispatchRequestScreen> {
  static const Color _gold = Color(0xFFB57A2A);
  static const Duration _searchTimeoutDuration = Duration(seconds: 90);
  static const Duration _restoreReadTimeout = Duration(seconds: 6);
  static const int _maxRestorePasses = 3;

  final TextEditingController _pickupController = TextEditingController();
  final TextEditingController _dropoffController = TextEditingController();
  final TextEditingController _packageController = TextEditingController();
  final TextEditingController _recipientNameController =
      TextEditingController();
  final TextEditingController _recipientPhoneController =
      TextEditingController();
  final ImagePicker _dispatchPhotoPicker = ImagePicker();

  final rtdb.DatabaseReference _rideRequestsRef = rtdb.FirebaseDatabase.instance
      .ref('ride_requests');
  final rtdb.DatabaseReference _usersRef = rtdb.FirebaseDatabase.instance.ref(
    'users',
  );
  final rtdb.DatabaseReference _driversRef = rtdb.FirebaseDatabase.instance.ref(
    'drivers',
  );
  final rtdb.DatabaseReference _driverActiveRideRef = rtdb
      .FirebaseDatabase
      .instance
      .ref('driver_active_rides');
  final RiderTrustBootstrapService _bootstrapService =
      const RiderTrustBootstrapService();
  final RiderTrustRulesService _trustRulesService =
      const RiderTrustRulesService();
  final DispatchPhotoUploadService _dispatchPhotoUploadService =
      const DispatchPhotoUploadService();
  final TripSafetyTelemetryService _tripSafetyService =
      TripSafetyTelemetryService();

  StreamSubscription<rtdb.DatabaseEvent>? _activeRequestSubscription;
  String? _activeRequestId;
  Map<String, dynamic>? _activeRequest;
  Map<String, dynamic> _verification = <String, dynamic>{};
  Map<String, dynamic> _riskFlags = <String, dynamic>{};
  Map<String, dynamic> _paymentFlags = <String, dynamic>{};
  Map<String, dynamic> _reputation = <String, dynamic>{};
  Map<String, dynamic> _trustSummary = <String, dynamic>{};
  DispatchPhotoSelectedAsset? _packagePhotoAsset;
  String _selectedLaunchCity = RiderLaunchScope.defaultBrowseCity;
  bool _loading = true;
  bool _submitting = false;
  bool _restoringActiveRequest = false;
  double _packagePhotoUploadProgress = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_hydrateRiderTrustState(persist: true));
    unawaited(_restoreActiveDispatchRequest());
  }

  @override
  void dispose() {
    _activeRequestSubscription?.cancel();
    _pickupController.dispose();
    _dropoffController.dispose();
    _packageController.dispose();
    _recipientNameController.dispose();
    _recipientPhoneController.dispose();
    super.dispose();
  }

  bool get _hasActiveRequest {
    final status = TripStateMachine.uiStatusFromSnapshot(_activeRequest);
    return _activeRequestId != null &&
        status.isNotEmpty &&
        status != 'completed' &&
        status != 'cancelled';
  }

  String _preferredLaunchCityFromUser(Map<String, dynamic> userData) {
    final saved = RiderLaunchScope.normalizeSupportedCity(
      userData['launch_market_city'] ??
          userData['launchMarket'] ??
          userData['launch_market'] ??
          userData['selectedCity'],
    );
    return saved ?? _selectedLaunchCity;
  }

  Future<void> _hydrateRiderTrustState({bool persist = false}) async {
    final riderId = FirebaseAuth.instance.currentUser?.uid;
    if (riderId == null || riderId.isEmpty) {
      return;
    }

    try {
      final userSnapshot = await runOptionalStartupRead<rtdb.DataSnapshot>(
        source: 'dispatch_request.user_profile',
        path: 'users/$riderId',
        action: () => _usersRef.child(riderId).get(),
      );
      final existingUser = userSnapshot?.value is Map
          ? Map<String, dynamic>.from(userSnapshot!.value as Map)
          : <String, dynamic>{};
      final preferredLaunchCity = _preferredLaunchCityFromUser(existingUser);
      final bundle = await _bootstrapService.ensureRiderTrustState(
        riderId: riderId,
        existingUser: existingUser,
        fallbackName: FirebaseAuth.instance.currentUser?.email
            ?.split('@')
            .first,
        fallbackEmail: FirebaseAuth.instance.currentUser?.email,
      );

      if (persist) {
        await persistRiderOwnedBootstrap(
          rootRef: _usersRef.root,
          riderId: riderId,
          userProfile: <String, dynamic>{
            ...existingUser,
            ...bundle.userProfile,
            'created_at':
                existingUser['created_at'] ?? rtdb.ServerValue.timestamp,
          },
          verification: bundle.verification,
          deviceFingerprints: bundle.deviceFingerprints,
          source: 'dispatch_request.bootstrap_write',
        );
      }

      if (!mounted) {
        _selectedLaunchCity = preferredLaunchCity;
        _verification = bundle.verification;
        _riskFlags = bundle.riskFlags;
        _paymentFlags = bundle.paymentFlags;
        _reputation = bundle.reputation;
        _trustSummary = bundle.trustSummary;
        return;
      }

      setState(() {
        _selectedLaunchCity = preferredLaunchCity;
        _verification = bundle.verification;
        _riskFlags = bundle.riskFlags;
        _paymentFlags = bundle.paymentFlags;
        _reputation = bundle.reputation;
        _trustSummary = bundle.trustSummary;
      });
    } catch (error, stackTrace) {
      debugPrint('[Dispatch] trust hydrate failed: $error');
      debugPrintStack(
        label: '[Dispatch] trust hydrate stack',
        stackTrace: stackTrace,
      );
    }
  }

  void _showRestoreFailureMessage(String message) {
    if (!mounted) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.hideCurrentSnackBar();
      messenger?.showSnackBar(SnackBar(content: Text(message)));
    });
  }

  Future<void> _restoreActiveDispatchRequest() async {
    if (_restoringActiveRequest) {
      debugPrint(
        '[Dispatch] restore skipped because another restore is running',
      );
      return;
    }

    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null || userId.isEmpty) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
      });
      return;
    }

    debugPrint('[Dispatch] restore active request userId=$userId');
    _restoringActiveRequest = true;

    try {
      for (var pass = 0; pass < _maxRestorePasses; pass++) {
        debugPrint('[Dispatch] restore pass=${pass + 1} userId=$userId');
        final snapshot = await runOptionalStartupRead<rtdb.DataSnapshot>(
          source: 'dispatch_request.restore_active',
          path: 'ride_requests[orderByChild=rider_id,equalTo=$userId]',
          action: () => _rideRequestsRef
              .orderByChild('rider_id')
              .equalTo(userId)
              .get()
              .timeout(_restoreReadTimeout),
        );
        if (snapshot == null) {
          debugPrint('[Dispatch] restore read failed or timed out');
          if (!mounted) {
            return;
          }
          setState(() {
            _loading = false;
          });
          _showRestoreFailureMessage(
            'Dispatch could not load your last request. You can create a new one now.',
          );
          return;
        }

        String? latestRequestId;
        Map<String, dynamic>? latestRequest;
        var latestCreatedAt = 0;

        if (snapshot.value is Map) {
          final requests = Map<Object?, Object?>.from(snapshot.value as Map);
          requests.forEach((rawKey, rawValue) {
            final request = _asStringDynamicMap(rawValue);
            if (request == null) {
              return;
            }

            final serviceType = riderServiceTypeFromKey(
              request['service_type']?.toString(),
            );
            final status = TripStateMachine.uiStatusFromSnapshot(request);
            final createdAt = _parseTimestamp(request['created_at']);

            if (serviceType != RiderServiceType.dispatchDelivery) {
              return;
            }
            if (status == 'completed' || status == 'cancelled') {
              return;
            }
            if (createdAt < latestCreatedAt) {
              return;
            }

            latestCreatedAt = createdAt;
            latestRequestId = rawKey?.toString();
            latestRequest = request;
          });
        }

        if (!mounted) {
          return;
        }

        if (latestRequestId == null || latestRequest == null) {
          setState(() {
            _loading = false;
          });
          return;
        }

        final assignmentReleased =
            await _releaseExpiredAssignedDispatchRequestIfNeeded(
              latestRequestId!,
              latestRequest,
            );
        if (assignmentReleased) {
          debugPrint(
            '[Dispatch] restore retry requestId=$latestRequestId reason=assignment_released',
          );
          continue;
        }

        final timedOut = await _cancelTimedOutDispatchRequestIfNeeded(
          latestRequestId!,
          latestRequest,
        );
        if (timedOut) {
          setState(() {
            _loading = false;
          });
          return;
        }

        _watchRequest(latestRequestId!);
        setState(() {
          _activeRequestId = latestRequestId;
          _activeRequest = latestRequest;
          _loading = false;
        });
        return;
      }

      debugPrint('[Dispatch] restore exhausted retry budget');
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
      });
      _showRestoreFailureMessage(
        'We could not restore your last dispatch request. You can create a new one now.',
      );
    } catch (error, stackTrace) {
      debugPrint('[Dispatch] restore failed: $error');
      debugPrintStack(
        label: '[Dispatch] restore stack',
        stackTrace: stackTrace,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
      });
      _showRestoreFailureMessage(
        'Dispatch could not load your last request. You can create a new one now.',
      );
    } finally {
      _restoringActiveRequest = false;
    }
  }

  Map<String, dynamic>? _asStringDynamicMap(dynamic value) {
    if (value is Map) {
      return value.map<String, dynamic>(
        (dynamic key, dynamic entryValue) =>
            MapEntry(key.toString(), entryValue),
      );
    }
    return null;
  }

  int _parseTimestamp(dynamic rawValue) {
    if (rawValue is num) {
      return rawValue.toInt();
    }
    return int.tryParse(rawValue?.toString() ?? '') ?? 0;
  }

  Future<void> _restoreDriverAvailabilityIfRideMatches({
    required String requestId,
    required String driverId,
    required String reason,
  }) async {
    if (driverId.isEmpty || driverId == 'waiting') {
      return;
    }

    final snapshots = await Future.wait(<Future<rtdb.DataSnapshot>>[
      _driversRef.child(driverId).get(),
      _driverActiveRideRef.child(driverId).get(),
    ]);
    final driverRecord = _asStringDynamicMap(snapshots[0].value);
    final activeRideRecord = _asStringDynamicMap(snapshots[1].value);
    final activeRideId =
        activeRideRecord?['ride_id']?.toString().trim().isNotEmpty == true
        ? activeRideRecord!['ride_id'].toString().trim()
        : (driverRecord?['activeRideId']?.toString().trim().isNotEmpty == true
              ? driverRecord!['activeRideId'].toString().trim()
              : driverRecord?['currentRideId']?.toString().trim() ?? '');
    if (activeRideId != requestId) {
      return;
    }

    final isOnline =
        driverRecord?['isOnline'] == true || driverRecord?['online'] == true;
    await _rideRequestsRef.root.update(<String, dynamic>{
      'drivers/$driverId/isAvailable': isOnline,
      'drivers/$driverId/available': isOnline,
      'drivers/$driverId/status': isOnline ? 'idle' : 'offline',
      'drivers/$driverId/activeRideId': null,
      'drivers/$driverId/currentRideId': null,
      'drivers/$driverId/updated_at': rtdb.ServerValue.timestamp,
      'driver_active_rides/$driverId': null,
    });
    debugPrint(
      '[Dispatch] driver availability restored requestId=$requestId driverId=$driverId reason=$reason',
    );
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }

    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) {
      return;
    }

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _dispatchPackagePhotoUrl(Map<String, dynamic>? request) {
    final dispatchDetails = _asStringDynamicMap(request?['dispatch_details']);
    final nestedUrl =
        dispatchDetails?['packagePhotoUrl']?.toString().trim() ?? '';
    if (nestedUrl.isNotEmpty) {
      return nestedUrl;
    }
    return request?['packagePhotoUrl']?.toString().trim() ?? '';
  }

  String _dispatchRecipientSummary(Map<String, dynamic>? request) {
    final dispatchDetails = _asStringDynamicMap(request?['dispatch_details']);
    final recipientName =
        dispatchDetails?['recipient_name']?.toString().trim() ?? '';
    final recipientPhone =
        dispatchDetails?['recipient_phone']?.toString().trim() ?? '';
    return <String>[
      if (recipientName.isNotEmpty) recipientName,
      if (recipientPhone.isNotEmpty) recipientPhone,
    ].join(' • ');
  }

  String _mimeTypeForPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) {
      return 'image/png';
    }
    if (lower.endsWith('.heic')) {
      return 'image/heic';
    }
    if (lower.endsWith('.heif')) {
      return 'image/heif';
    }
    return 'image/jpeg';
  }

  String _formatFileSize(int bytes) {
    if (bytes >= 1000000) {
      return '${(bytes / 1000000).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1000) {
      return '${(bytes / 1000).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }

  Future<DispatchPhotoSelectedAsset?> _pickPackagePhotoAsset(
    _DispatchItemPhotoSource source,
  ) async {
    if (source == _DispatchItemPhotoSource.camera) {
      final permission = await Permission.camera.request();
      if (!permission.isGranted) {
        _showMessage('Camera permission is required to add an item photo.');
        return null;
      }
    }

    final image = await _dispatchPhotoPicker.pickImage(
      source: source == _DispatchItemPhotoSource.camera
          ? ImageSource.camera
          : ImageSource.gallery,
      maxWidth: 1800,
      imageQuality: 88,
    );
    if (image == null) {
      return null;
    }

    return DispatchPhotoSelectedAsset(
      localPath: image.path,
      fileName: image.name.isNotEmpty ? image.name : image.path.split('/').last,
      mimeType: _mimeTypeForPath(image.path),
      fileSizeBytes: File(image.path).lengthSync(),
      source: source == _DispatchItemPhotoSource.camera ? 'camera' : 'gallery',
    );
  }

  Future<_DispatchItemPhotoSource?> _showPackagePhotoSourceSheet() async {
    if (!mounted) {
      return null;
    }

    return showModalBottomSheet<_DispatchItemPhotoSource>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (BuildContext sheetContext) {
        Widget buildSourceTile({
          required IconData icon,
          required String title,
          required String subtitle,
          required _DispatchItemPhotoSource source,
        }) {
          return Material(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
            child: InkWell(
              borderRadius: BorderRadius.circular(22),
              onTap: () {
                Navigator.of(sheetContext).pop(source);
              },
              child: Ink(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: Colors.black.withValues(alpha: 0.06),
                  ),
                ),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: _gold.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(icon, color: _gold),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            title,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            subtitle,
                            style: TextStyle(
                              color: Colors.black.withValues(alpha: 0.62),
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded),
                  ],
                ),
              ),
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
          child: SafeArea(
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFFF7F2EA),
                borderRadius: BorderRadius.circular(28),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    'Add item photo',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Attach a clear package photo so the driver can confirm the item at pickup.',
                    style: TextStyle(
                      color: Colors.black.withValues(alpha: 0.64),
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 18),
                  buildSourceTile(
                    icon: Icons.photo_camera_outlined,
                    title: 'Take photo',
                    subtitle: 'Use the camera to capture the package now.',
                    source: _DispatchItemPhotoSource.camera,
                  ),
                  const SizedBox(height: 12),
                  buildSourceTile(
                    icon: Icons.photo_library_outlined,
                    title: 'Choose from gallery',
                    subtitle: 'Select an existing item photo from your device.',
                    source: _DispatchItemPhotoSource.gallery,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _selectPackagePhoto() async {
    final source = await _showPackagePhotoSourceSheet();
    if (source == null) {
      return;
    }

    final asset = await _pickPackagePhotoAsset(source);
    if (asset == null || !mounted) {
      return;
    }

    setState(() {
      _packagePhotoAsset = asset;
    });
  }

  Future<void> _showPhotoPreview({
    required String title,
    required ImageProvider imageProvider,
  }) async {
    if (!mounted) {
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 24,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420, maxHeight: 620),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: Colors.black87,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () {
                          Navigator.of(dialogContext).pop();
                        },
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(22),
                      child: Container(
                        color: const Color(0xFFF7F2EA),
                        child: InteractiveViewer(
                          child: Image(
                            image: imageProvider,
                            fit: BoxFit.contain,
                            width: double.infinity,
                            errorBuilder: (context, error, stackTrace) {
                              return Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: Text(
                                    'Unable to load this image right now.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Colors.black.withValues(
                                        alpha: 0.64,
                                      ),
                                      height: 1.45,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _watchRequest(String requestId) async {
    await _activeRequestSubscription?.cancel();
    _activeRequestSubscription = _rideRequestsRef
        .child(requestId)
        .onValue
        .listen(
          (rtdb.DatabaseEvent event) async {
            final data = _asStringDynamicMap(event.snapshot.value);
            debugPrint(
              '[Dispatch] request update requestId=$requestId status=${data?['status']}',
            );

            if (data != null) {
              final assignmentReleased =
                  await _releaseExpiredAssignedDispatchRequestIfNeeded(
                    requestId,
                    data,
                  );
              if (assignmentReleased) {
                return;
              }
              final timedOut = await _cancelTimedOutDispatchRequestIfNeeded(
                requestId,
                data,
              );
              if (timedOut) {
                return;
              }
            }

            if (!mounted) {
              return;
            }

            setState(() {
              _activeRequestId = requestId;
              _activeRequest = data;
            });
          },
          onError: (Object error) {
            debugPrint('[Dispatch] request listener failed: $error');
          },
        );
  }

  /// Dispatch search window only — same keys as ride create; avoid unrelated
  /// `expires_at` / `timeout_at` fields that can false-trigger immediate timeout.
  int _requestTimeoutAt(Map<String, dynamic>? request) {
    if (request == null) {
      return 0;
    }
    for (final key in <String>['search_timeout_at', 'request_expires_at']) {
      final value = _parseTimestamp(request[key]);
      if (value > 0) {
        return value;
      }
    }
    return 0;
  }

  bool _requestHasTimedOut(Map<String, dynamic>? request) {
    final timeoutAt = _requestTimeoutAt(request);
    return timeoutAt > 0 && DateTime.now().millisecondsSinceEpoch >= timeoutAt;
  }

  int _assignmentTimeoutAt(Map<String, dynamic>? request) {
    if (request == null) {
      return 0;
    }
    for (final key in <String>[
      'assignment_expires_at',
      'driver_response_timeout_at',
    ]) {
      final value = _parseTimestamp(request[key]);
      if (value > 0) {
        return value;
      }
    }
    return 0;
  }

  bool _assignmentHasTimedOut(Map<String, dynamic>? request) {
    final timeoutAt = _assignmentTimeoutAt(request);
    return timeoutAt > 0 && DateTime.now().millisecondsSinceEpoch >= timeoutAt;
  }

  Future<bool> _releaseExpiredAssignedDispatchRequestIfNeeded(
    String requestId,
    Map<String, dynamic>? request,
  ) async {
    if (request == null ||
        !TripStateMachine.isPendingDriverAssignmentState(
          TripStateMachine.canonicalStateFromSnapshot(request),
        ) ||
        !_assignmentHasTimedOut(request)) {
      return false;
    }

    if (_requestHasTimedOut(request)) {
      return _cancelTimedOutDispatchRequestIfNeeded(requestId, request);
    }

    final transactionResult = await _rideRequestsRef
        .child(requestId)
        .runTransaction((currentData) {
          final currentRequest = _asStringDynamicMap(currentData);
          if (currentRequest == null ||
              !TripStateMachine.isPendingDriverAssignmentState(
                TripStateMachine.canonicalStateFromSnapshot(currentRequest),
              ) ||
              !_assignmentHasTimedOut(currentRequest)) {
            return rtdb.Transaction.abort();
          }

          final timedOutDriverId =
              currentRequest['driver_id']?.toString() ?? '';
          final updates = TripStateMachine.buildTransitionUpdate(
            currentRide: currentRequest,
            nextCanonicalState: TripLifecycleState.searchingDriver,
            timestampValue: rtdb.ServerValue.timestamp,
            transitionSource: 'assignment_timeout_cleanup',
            transitionActor: 'system',
          );
          return rtdb.Transaction.success(
            Map<String, dynamic>.from(currentRequest)
              ..addAll(updates)
              ..addAll(<String, dynamic>{
                'driver_id': 'waiting',
                'driver_name': null,
                'car': null,
                'plate': null,
                'rating': null,
                'driver_lat': null,
                'driver_lng': null,
                'driver_heading': null,
                'assignment_expires_at': null,
                'assignment_timeout_ms': null,
                'last_assignment_driver_id': timedOutDriverId,
                'last_assignment_release_reason': 'driver_response_timeout',
              }),
          );
        }, applyLocally: false);

    if (!transactionResult.committed) {
      return false;
    }

    final timedOutDriverId = request['driver_id']?.toString() ?? '';
    await _restoreDriverAvailabilityIfRideMatches(
      requestId: requestId,
      driverId: timedOutDriverId,
      reason: 'driver_response_timeout',
    );
    debugPrint(
      '[Dispatch] assignment timeout released requestId=$requestId reason=driver_response_timeout',
    );
    return true;
  }

  Future<bool> _cancelTimedOutDispatchRequestIfNeeded(
    String requestId,
    Map<String, dynamic>? request,
  ) async {
    if (request == null ||
        TripStateMachine.uiStatusFromSnapshot(request) != 'searching' ||
        !_requestHasTimedOut(request)) {
      return false;
    }

    final updates = TripStateMachine.buildTransitionUpdate(
      currentRide: request,
      nextCanonicalState: TripLifecycleState.tripCancelled,
      timestampValue: rtdb.ServerValue.timestamp,
      transitionSource: 'system_search_timeout',
      transitionActor: 'system',
      cancellationActor: 'system',
      cancellationReason: 'no_drivers_available',
    );
    updates['cancel_source'] = 'system_search_timeout';
    await _rideRequestsRef.child(requestId).update(updates);
    final driverId = request['driver_id']?.toString() ?? '';
    await _restoreDriverAvailabilityIfRideMatches(
      requestId: requestId,
      driverId: driverId,
      reason: 'system_search_timeout',
    );
    debugPrint(
      '[Dispatch] request timeout requestId=$requestId reason=no_drivers_available',
    );
    return true;
  }

  Future<({double lat, double lng})> _resolveCoordinates(String address) async {
    for (final query in RiderLaunchScope.buildSearchQueries(
      address,
      preferredCity: _selectedLaunchCity,
    )) {
      try {
        final locations = await locationFromAddress(query);
        if (locations.isNotEmpty) {
          final location = locations.first;
          return (lat: location.latitude, lng: location.longitude);
        }
      } catch (_) {
        // Try the next query variant before failing the dispatch flow.
      }
    }
    throw const FormatException('address_not_found');
  }

  String? _normalizeCity(String? rawValue) {
    return RiderLaunchScope.normalizeSupportedCity(rawValue);
  }

  String? _normalizeArea(String? rawValue, {String? city}) {
    return RiderLaunchScope.normalizeSupportedArea(rawValue, city: city);
  }

  String _serviceAreaFromCandidates({
    required String city,
    required Iterable<String?> candidates,
  }) {
    for (final candidate in candidates) {
      final normalized = _normalizeArea(candidate, city: city);
      if (normalized != null && normalized.isNotEmpty) {
        return normalized;
      }
    }
    return '';
  }

  Future<String> _resolveAreaFromPoint(
    double lat,
    double lng, {
    required String city,
    String? addressHint,
  }) async {
    final directMatch = _serviceAreaFromCandidates(
      city: city,
      candidates: <String?>[addressHint],
    );
    if (directMatch.isNotEmpty) {
      return directMatch;
    }

    try {
      final placemarks = await placemarkFromCoordinates(lat, lng);
      for (final placemark in placemarks) {
        final match = _serviceAreaFromCandidates(
          city: city,
          candidates: <String?>[
            placemark.subLocality,
            placemark.locality,
            placemark.subAdministrativeArea,
            placemark.administrativeArea,
            placemark.street,
            placemark.thoroughfare,
            placemark.name,
          ],
        );
        if (match.isNotEmpty) {
          return match;
        }
      }
    } catch (_) {}

    return '';
  }

  Map<String, String> _buildServiceAreaFields({
    required String city,
    String? area,
  }) {
    return RiderLaunchScope.buildServiceAreaFields(city: city, area: area);
  }

  Future<String?> _resolveServiceCity({
    required String pickupAddress,
    required String dropoffAddress,
    required double pickupLat,
    required double pickupLng,
  }) async {
    final textMatch =
        _normalizeCity(pickupAddress) ?? _normalizeCity(dropoffAddress);
    if (textMatch != null) {
      return textMatch;
    }

    final placemarks = await placemarkFromCoordinates(pickupLat, pickupLng);
    for (final placemark in placemarks) {
      final city = _normalizeCity(
        placemark.locality ??
            placemark.subAdministrativeArea ??
            placemark.administrativeArea,
      );
      if (city != null) {
        return city;
      }
    }

    return null;
  }

  String _statusLabel(String status) {
    return riderServiceStatusLabel(RiderServiceType.dispatchDelivery, status);
  }

  String _formatTime(dynamic rawValue) {
    final timestamp = _parseTimestamp(rawValue);
    if (timestamp <= 0) {
      return 'Pending';
    }

    return DateFormat(
      'dd MMM yyyy, hh:mm a',
    ).format(DateTime.fromMillisecondsSinceEpoch(timestamp).toLocal());
  }

  Future<void> _submitDispatchRequest() async {
    if (_submitting || _hasActiveRequest) {
      return;
    }

    FocusScope.of(context).unfocus();

    final pickupAddress = _pickupController.text.trim();
    final dropoffAddress = _dropoffController.text.trim();
    final packageDetails = _packageController.text.trim();
    final recipientName = _recipientNameController.text.trim();
    final recipientPhone = _recipientPhoneController.text.trim();
    final packagePhotoAsset = _packagePhotoAsset;

    if (pickupAddress.isEmpty ||
        dropoffAddress.isEmpty ||
        packageDetails.isEmpty) {
      _showMessage('Pickup, dropoff, and package details are required.');
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _showMessage('Please log in again to send a request.');
      return;
    }

    final accessDecision = await _trustRulesService.evaluateForRider(user.uid);
    if (!accessDecision.canRequestTrips) {
      if (!mounted) {
        return;
      }
      _showMessage(accessDecision.message);
      return;
    }

    await _hydrateRiderTrustState();

    setState(() {
      _submitting = true;
      _packagePhotoUploadProgress = packagePhotoAsset == null ? 0 : 0.05;
    });

    debugPrint('[Dispatch] submit tapped');

    try {
      final pickup = await _resolveCoordinates(pickupAddress);
      final dropoff = await _resolveCoordinates(dropoffAddress);
      final city = await _resolveServiceCity(
        pickupAddress: pickupAddress,
        dropoffAddress: dropoffAddress,
        pickupLat: pickup.lat,
        pickupLng: pickup.lng,
      );

      if (city == null) {
        throw const FormatException('unsupported_city');
      }
      final dispatchMarket = RiderServiceAreaConfig.marketForCity(city).city;
      final dispatchSlug =
          normalizeRideMarketSlug(dispatchMarket) ?? dispatchMarket.trim().toLowerCase();

      final requestRef = _rideRequestsRef.push();
      final requestId = requestRef.key;
      if (requestId == null || requestId.isEmpty) {
        throw StateError('dispatch_request_id_missing');
      }

      DispatchUploadedPhoto? uploadedPackagePhoto;
      if (packagePhotoAsset != null) {
        uploadedPackagePhoto = await _dispatchPhotoUploadService
            .uploadRidePhoto(
              rideId: requestId,
              actorId: user.uid,
              category: 'package_photo',
              asset: packagePhotoAsset,
              onProgress: (double progress) {
                if (!mounted) {
                  _packagePhotoUploadProgress = progress.clamp(0.08, 0.94);
                  return;
                }
                setState(() {
                  _packagePhotoUploadProgress = progress.clamp(0.08, 0.94);
                });
              },
            );
      }

      final distanceKm =
          Geolocator.distanceBetween(
            pickup.lat,
            pickup.lng,
            dropoff.lat,
            dropoff.lng,
          ) /
          1000;
      final fareBreakdown = calculateRiderFare(
        serviceKey: RiderServiceType.dispatchDelivery.key,
        city: dispatchSlug,
        distanceKm: distanceKm,
      );
      final pickupArea = await _resolveAreaFromPoint(
        pickup.lat,
        pickup.lng,
        city: dispatchSlug,
        addressHint: pickupAddress,
      );
      final destinationArea = await _resolveAreaFromPoint(
        dropoff.lat,
        dropoff.lng,
        city: dispatchSlug,
        addressHint: dropoffAddress,
      );
      final rideScope = _buildServiceAreaFields(city: dispatchSlug, area: pickupArea);
      final pickupScope = _buildServiceAreaFields(city: dispatchSlug, area: pickupArea);
      final destinationScope = _buildServiceAreaFields(
        city: dispatchSlug,
        area: destinationArea,
      );
      final packagePhotoUrl = uploadedPackagePhoto?.fileUrl ?? '';
      final packagePhotoSubmittedAt = uploadedPackagePhoto == null
          ? 0
          : rtdb.ServerValue.timestamp;
      final dispatchDetails = <String, dynamic>{
        'package_details': packageDetails,
        'recipient_name': recipientName,
        'recipient_phone': recipientPhone,
        'packagePhotoUrl': packagePhotoUrl,
        'packagePhotoSubmittedAt': packagePhotoSubmittedAt,
        'deliveryProofPhotoUrl': '',
        'deliveryProofSubmittedAt': 0,
        'pickupConfirmedAt': 0,
        'deliveredAt': 0,
        'deliveryProofStatus': 'pending',
      };

      final payload = <String, dynamic>{
        'service_type': RiderServiceType.dispatchDelivery.key,
        RtdbRideRequestFields.rideId: requestId,
        'rider_id': user.uid,
        'driver_id': 'waiting',
        'status': 'searching',
        'trip_state': TripLifecycleState.searchingDriver,
        'state_machine_version': TripStateMachine.schemaVersion,
        'market': dispatchSlug,
        'city': dispatchSlug,
        RtdbRideRequestFields.marketPool: dispatchSlug,
        'country': rideScope['country'],
        'country_code': rideScope['country_code'],
        'area': rideScope['area'],
        'zone': rideScope['zone'],
        'community': rideScope['community'],
        'pickup_area': pickupScope['area'],
        'pickup_zone': pickupScope['zone'],
        'pickup_community': pickupScope['community'],
        'destination_area': destinationScope['area'],
        'destination_zone': destinationScope['zone'],
        'destination_community': destinationScope['community'],
        'service_area': rideScope,
        'pickup_scope': pickupScope,
        'destination_scope': destinationScope,
        'pickup': <String, dynamic>{
          'lat': pickup.lat,
          'lng': pickup.lng,
          ...pickupScope,
        },
        'destination': <String, dynamic>{
          'lat': dropoff.lat,
          'lng': dropoff.lng,
          ...destinationScope,
        },
        'final_destination': <String, dynamic>{
          'lat': dropoff.lat,
          'lng': dropoff.lng,
          ...destinationScope,
        },
        'pickup_address': pickupAddress,
        'destination_address': dropoffAddress,
        'final_destination_address': dropoffAddress,
        'stops': <Map<String, dynamic>>[],
        'stop_count': 1,
        'fare': fareBreakdown.totalFare,
        'distance_km': fareBreakdown.distanceKm,
        'duration_min': fareBreakdown.durationMin,
        RtdbRideRequestFields.etaMin: fareBreakdown.durationMin,
        'dropoff': <String, dynamic>{
          'lat': dropoff.lat,
          'lng': dropoff.lng,
          ...destinationScope,
        },
        'payment_method': 'cash',
        RtdbRideRequestFields.paymentStatus: 'not_required',
        'settlement_status': 'pending',
        'support_status': 'normal',
        'accepted_at': null,
        'cancelled_at': null,
        'completed_at': null,
        'cancel_reason': '',
        'fare_breakdown': fareBreakdown.toMap(),
        'rider_trust_snapshot': <String, dynamic>{
          'verificationStatus':
              (_trustSummary['verificationStatus']?.toString().isNotEmpty ??
                  false)
              ? _trustSummary['verificationStatus']
              : _verification['overallStatus'],
          'verifiedBadge': _trustSummary['verifiedBadge'] == true,
          'rating': _reputation['averageRating'] ?? 5.0,
          'ratingCount': _reputation['ratingCount'] ?? 0,
          'cashAccessStatus':
              _trustSummary['cashAccessStatus'] ??
              _paymentFlags['cashAccessStatus'] ??
              'enabled',
          'riskStatus':
              _trustSummary['riskStatus'] ?? _riskFlags['status'] ?? 'clear',
        },
        'route_basis': <String, dynamic>{
          'country': rideScope['country'],
          'country_code': rideScope['country_code'],
          'market': dispatchSlug,
          'area': rideScope['area'],
          'zone': rideScope['zone'],
          'community': rideScope['community'],
          'pickup_scope': pickupScope,
          'destination_scope': destinationScope,
          'pickup_address': pickupAddress,
          'destination_address': dropoffAddress,
          'stops': <Map<String, dynamic>>[],
          'stop_count': 1,
          'distance_km': fareBreakdown.distanceKm,
          'duration_min': fareBreakdown.durationMin,
          'fare_estimate': fareBreakdown.totalFare,
          'fare_breakdown': fareBreakdown.toMap(),
          'expected_route_points': <Map<String, double>>[
            <String, double>{'lat': pickup.lat, 'lng': pickup.lng},
            <String, double>{'lat': dropoff.lat, 'lng': dropoff.lng},
          ],
        },
        'created_at': rtdb.ServerValue.timestamp,
        'requested_at': rtdb.ServerValue.timestamp,
        'search_started_at': rtdb.ServerValue.timestamp,
        'updated_at': rtdb.ServerValue.timestamp,
        'search_timeout_at':
            DateTime.now().millisecondsSinceEpoch +
            _searchTimeoutDuration.inMilliseconds,
        'request_expires_at':
            DateTime.now().millisecondsSinceEpoch +
            _searchTimeoutDuration.inMilliseconds,
        RtdbRideRequestFields.expiresAt:
            DateTime.now().millisecondsSinceEpoch +
            _searchTimeoutDuration.inMilliseconds,
        'packagePhotoUrl': packagePhotoUrl,
        'packagePhotoSubmittedAt': packagePhotoSubmittedAt,
        'deliveryProofPhotoUrl': '',
        'deliveryProofSubmittedAt': 0,
        'pickupConfirmedAt': 0,
        'deliveredAt': 0,
        'deliveryProofStatus': 'pending',
        'dispatch_details': dispatchDetails,
      };

      rtdbFlowLog(
        '[NEXRIDE_RIDER_RTDB][DISPATCH_CREATE]',
        'requestId=$requestId uid=${user.uid} market_pool=$dispatchSlug',
      );
      debugPrint(
        '[RIDER_CREATE] rideId=$requestId rider_id=${user.uid} '
        'status=${payload['status']} trip_state=${payload['trip_state']} '
        'market=${payload['market']} market_pool=${payload[RtdbRideRequestFields.marketPool]}',
      );
      await requestRef.set(payload);
      try {
        final payloadDriverId = payload['driver_id']?.toString().trim() ?? '';
        final payloadMarket = payload['market']?.toString().trim() ?? '';
        final payloadStatus = payload['status']?.toString().trim() ?? '';
        final payloadTripState = payload['trip_state']?.toString().trim() ?? '';
        final payloadPaymentMethod =
            payload['payment_method']?.toString().trim() ?? '';
        final payloadPaymentStatus =
            payload['payment_status']?.toString().trim() ?? '';
        final payloadSettlementStatus =
            payload['settlement_status']?.toString().trim() ?? '';
        final payloadSupportStatus =
            payload['support_status']?.toString().trim() ?? '';
        final payloadCancelReason =
            payload['cancel_reason']?.toString().trim() ?? '';
        await requestRef.root.update(<String, dynamic>{
          'admin_rides/$requestId/summary/ride_id': requestId,
          'admin_rides/$requestId/summary/rider_id': user.uid,
          'admin_rides/$requestId/summary/driver_id': payloadDriverId,
          'admin_rides/$requestId/summary/market': payloadMarket,
          'admin_rides/$requestId/summary/status': payloadStatus,
          'admin_rides/$requestId/summary/trip_state': payloadTripState,
          'admin_rides/$requestId/summary/payment_method': payloadPaymentMethod,
          'admin_rides/$requestId/summary/payment_status': payloadPaymentStatus,
          'admin_rides/$requestId/summary/settlement_status': payloadSettlementStatus,
          'admin_rides/$requestId/summary/support_status': payloadSupportStatus,
          'admin_rides/$requestId/summary/created_at': payload['created_at'],
          'admin_rides/$requestId/summary/accepted_at': payload['accepted_at'],
          'admin_rides/$requestId/summary/cancelled_at': payload['cancelled_at'],
          'admin_rides/$requestId/summary/completed_at': payload['completed_at'],
          'admin_rides/$requestId/summary/cancel_reason': payloadCancelReason,
          'admin_rides/$requestId/summary/updated_at': rtdb.ServerValue.timestamp,
          'support_queue/$requestId/ride_id': requestId,
          'support_queue/$requestId/rider_id': user.uid,
          'support_queue/$requestId/driver_id': payloadDriverId,
          'support_queue/$requestId/status': payloadStatus,
          'support_queue/$requestId/trip_state': payloadTripState,
          'support_queue/$requestId/payment_status': payloadPaymentStatus,
          'support_queue/$requestId/settlement_status': payloadSettlementStatus,
          'support_queue/$requestId/support_status': payloadSupportStatus,
          'support_queue/$requestId/created_at': payload['created_at'],
          'support_queue/$requestId/accepted_at': payload['accepted_at'],
          'support_queue/$requestId/cancelled_at': payload['cancelled_at'],
          'support_queue/$requestId/completed_at': payload['completed_at'],
          'support_queue/$requestId/cancel_reason': payloadCancelReason,
          'support_queue/$requestId/last_event': 'rider_create_dispatch',
          'support_queue/$requestId/updated_at': rtdb.ServerValue.timestamp,
        });
      } catch (error) {
        debugPrint(
          '[OPS_MIRROR] dispatch_create sync_failed rideId=$requestId error=$error',
        );
      }
      debugPrint('[Dispatch] request created requestId=$requestId');
      await _tripSafetyService.registerRideRequest(
        rideId: requestId,
        riderId: user.uid,
        serviceType: RiderServiceType.dispatchDelivery.key,
        ridePayload: payload,
        expectedRoutePoints: <LatLng>[
          LatLng(pickup.lat, pickup.lng),
          LatLng(dropoff.lat, dropoff.lng),
        ],
      );

      await _watchRequest(requestId);

      if (!mounted) {
        return;
      }

      setState(() {
        _activeRequestId = requestId;
        _activeRequest = payload;
      });

      _showMessage('Dispatch request sent successfully.');
    } on FormatException catch (error) {
      final message = error.message == 'unsupported_city'
          ? RiderLaunchScope.tripRequestAvailabilityMessage
          : 'Please use clearer pickup and dropoff addresses.';
      if (!mounted) {
        return;
      }
      _showMessage(message);
    } catch (error, stackTrace) {
      debugPrint('[Dispatch] submit failed: $error');
      debugPrintStack(label: '[Dispatch] submit stack', stackTrace: stackTrace);
      if (!mounted) {
        return;
      }
      _showMessage('Unable to send your dispatch request right now.');
    } finally {
      if (mounted) {
        setState(() {
          _submitting = false;
          _loading = false;
          _packagePhotoUploadProgress = 0;
        });
      } else {
        _packagePhotoUploadProgress = 0;
      }
    }
  }

  Future<void> _resetRequestComposer() async {
    await _activeRequestSubscription?.cancel();
    if (!mounted) {
      return;
    }
    setState(() {
      _activeRequestId = null;
      _activeRequest = null;
      _packagePhotoAsset = null;
      _packagePhotoUploadProgress = 0;
    });
    _pickupController.clear();
    _dropoffController.clear();
    _packageController.clear();
    _recipientNameController.clear();
    _recipientPhoneController.clear();
  }

  Widget _buildPackagePhotoComposerCard() {
    final selectedAsset = _packagePhotoAsset;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F2EA),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: _gold.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(Icons.photo_camera_back_outlined, color: _gold),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Package photo',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: Colors.black87,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            selectedAsset == null
                ? 'Add item photo so your driver can quickly confirm the parcel at pickup.'
                : 'Your selected item photo will be attached to this dispatch request.',
            style: TextStyle(
              color: Colors.black.withValues(alpha: 0.64),
              height: 1.45,
            ),
          ),
          if (selectedAsset != null) ...<Widget>[
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Image.file(
                File(selectedAsset.localPath),
                height: 190,
                width: double.infinity,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              selectedAsset.fileName,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              '${_formatFileSize(selectedAsset.fileSizeBytes)} • ${selectedAsset.source}',
              style: TextStyle(color: Colors.black.withValues(alpha: 0.56)),
            ),
          ],
          if (_submitting && selectedAsset != null) ...<Widget>[
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                minHeight: 7,
                value: _packagePhotoUploadProgress <= 0
                    ? null
                    : _packagePhotoUploadProgress,
                backgroundColor: Colors.black.withValues(alpha: 0.08),
                valueColor: const AlwaysStoppedAnimation<Color>(_gold),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Uploading package photo...',
              style: TextStyle(
                color: Colors.black.withValues(alpha: 0.62),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.black,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
              onPressed: _submitting ? null : _selectPackagePhoto,
              icon: const Icon(Icons.add_a_photo_outlined),
              label: const Text(
                'Add item photo',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
          if (selectedAsset != null) ...<Widget>[
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.black87,
                      side: BorderSide(
                        color: Colors.black.withValues(alpha: 0.12),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                    onPressed: _submitting
                        ? null
                        : () {
                            unawaited(
                              _showPhotoPreview(
                                title: 'Package photo',
                                imageProvider: FileImage(
                                  File(selectedAsset.localPath),
                                ),
                              ),
                            );
                          },
                    child: const Text(
                      'View package photo',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextButton(
                    onPressed: _submitting
                        ? null
                        : () {
                            setState(() {
                              _packagePhotoAsset = null;
                            });
                          },
                    child: const Text(
                      'Remove photo',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActiveRequestCard() {
    final activeRequest = _activeRequest ?? <String, dynamic>{};
    final status = activeRequest['status']?.toString() ?? 'searching';
    final driverName = activeRequest['driver_name']?.toString().trim() ?? '';
    final dispatchDetails = _asStringDynamicMap(
      activeRequest['dispatch_details'],
    );
    final recipientSummary = _dispatchRecipientSummary(activeRequest);
    final packagePhotoUrl = _dispatchPackagePhotoUrl(activeRequest);

    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(26),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 18,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: _gold.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  'Dispatch / Delivery',
                  style: const TextStyle(
                    color: Color(0xFF8A6424),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Spacer(),
              Text(
                _statusLabel(status),
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            'Request ID: ${_activeRequestId ?? ''}',
            style: TextStyle(
              fontSize: 12,
              color: Colors.black.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(height: 16),
          _DispatchInfoRow(
            icon: Icons.my_location,
            label: 'Pickup',
            value: activeRequest['pickup_address']?.toString() ?? 'Pending',
            iconColor: Colors.green,
          ),
          const SizedBox(height: 12),
          _DispatchInfoRow(
            icon: Icons.location_on_outlined,
            label: 'Dropoff',
            value:
                activeRequest['destination_address']?.toString() ?? 'Pending',
            iconColor: Colors.redAccent,
          ),
          if ((dispatchDetails?['package_details']?.toString().trim() ?? '')
              .isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            _DispatchInfoRow(
              icon: Icons.inventory_2_outlined,
              label: 'Package details',
              value: dispatchDetails!['package_details'].toString(),
            ),
          ],
          if (recipientSummary.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            _DispatchInfoRow(
              icon: Icons.person_pin_circle_outlined,
              label: 'Recipient details',
              value: recipientSummary,
            ),
          ],
          if (packagePhotoUrl.isNotEmpty) ...<Widget>[
            const SizedBox(height: 14),
            _DispatchMediaCard(
              title: 'Package photo',
              subtitle: 'Your item photo is attached to this dispatch request.',
              actionLabel: 'View package photo',
              onPressed: () {
                unawaited(
                  _showPhotoPreview(
                    title: 'Package photo',
                    imageProvider: NetworkImage(packagePhotoUrl),
                  ),
                );
              },
            ),
          ],
          const SizedBox(height: 12),
          _DispatchInfoRow(
            icon: Icons.schedule_outlined,
            label: 'Created',
            value: _formatTime(
              activeRequest['updated_at'] ?? activeRequest['created_at'],
            ),
          ),
          if (driverName.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            _DispatchInfoRow(
              icon: Icons.person_outline,
              label: 'Driver',
              value: driverName,
            ),
          ],
          if (!_hasActiveRequest) ...<Widget>[
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.black87,
                  side: BorderSide(color: Colors.black.withValues(alpha: 0.18)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                onPressed: _resetRequestComposer,
                child: const Text(
                  'Create another dispatch request',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F2EA),
      appBar: AppBar(
        backgroundColor: _gold,
        foregroundColor: Colors.black,
        centerTitle: true,
        title: const Text('Dispatch / Delivery'),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(20),
                children: <Widget>[
                  Container(
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'Dispatch requests',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        SizedBox(height: 10),
                        Text(
                          'Send a delivery request with pickup, dropoff, package details, and an optional item photo. You will see live status updates here after a driver accepts it.',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 14,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  const SizedBox.shrink(),
                  if (_activeRequestId != null && _activeRequest != null) ...[
                    _buildActiveRequestCard(),
                    const SizedBox(height: 18),
                  ],
                  if (!_hasActiveRequest) ...[
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(26),
                      ),
                      child: Column(
                        children: <Widget>[
                          TextField(
                            controller: _pickupController,
                            textInputAction: TextInputAction.next,
                            decoration: _inputDecoration(
                              label: 'Pickup address',
                              icon: Icons.my_location,
                            ),
                          ),
                          const SizedBox(height: 14),
                          TextField(
                            controller: _dropoffController,
                            textInputAction: TextInputAction.next,
                            decoration: _inputDecoration(
                              label: 'Dropoff address',
                              icon: Icons.location_on_outlined,
                            ),
                          ),
                          const SizedBox(height: 14),
                          TextField(
                            controller: _packageController,
                            textInputAction: TextInputAction.next,
                            maxLines: 3,
                            decoration: _inputDecoration(
                              label: 'Package details',
                              icon: Icons.inventory_2_outlined,
                            ),
                          ),
                          const SizedBox(height: 14),
                          _buildPackagePhotoComposerCard(),
                          const SizedBox(height: 14),
                          TextField(
                            controller: _recipientNameController,
                            textInputAction: TextInputAction.next,
                            decoration: _inputDecoration(
                              label: 'Recipient name (optional)',
                              icon: Icons.person_outline,
                            ),
                          ),
                          const SizedBox(height: 14),
                          TextField(
                            controller: _recipientPhoneController,
                            textInputAction: TextInputAction.done,
                            keyboardType: TextInputType.phone,
                            decoration: _inputDecoration(
                              label: 'Recipient phone (optional)',
                              icon: Icons.call_outlined,
                            ),
                          ),
                          const SizedBox(height: 20),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _gold,
                                foregroundColor: Colors.black,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                              ),
                              onPressed: _submitting
                                  ? null
                                  : _submitDispatchRequest,
                              child: _submitting
                                  ? const SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.2,
                                      ),
                                    )
                                  : const Text(
                                      'Send dispatch request',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
      ),
    );
  }

  InputDecoration _inputDecoration({
    required String label,
    required IconData icon,
  }) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(18)),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: _gold, width: 1.4),
      ),
    );
  }
}

class _DispatchInfoRow extends StatelessWidget {
  const _DispatchInfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.iconColor,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 19, color: iconColor ?? Colors.black87),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                label,
                style: TextStyle(
                  color: Colors.black.withValues(alpha: 0.55),
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DispatchMediaCard extends StatelessWidget {
  const _DispatchMediaCard({
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.onPressed,
  });

  final String title;
  final String subtitle;
  final String actionLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F2EA),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(
                Icons.photo_camera_back_outlined,
                color: Color(0xFFB57A2A),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: Colors.black87,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            subtitle,
            style: TextStyle(
              color: Colors.black.withValues(alpha: 0.64),
              height: 1.45,
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.black87,
                side: BorderSide(color: Colors.black.withValues(alpha: 0.12)),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
              onPressed: onPressed,
              child: Text(
                actionLabel,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
