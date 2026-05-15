import 'dart:async';
import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'config/rider_app_config.dart';
import 'config/rider_trip_status_messages.dart';
import 'config/rtdb_ride_request_contract.dart';
import 'services/call_permissions.dart';
import 'services/call_service.dart';
import 'services/dispatch_photo_upload_service.dart';
import 'services/native_places_service.dart';
import 'services/road_route_service.dart';
import 'services/rider_alert_sound_service.dart';
import 'services/rider_active_trip_session_service.dart';
import 'services/rider_trust_bootstrap_service.dart';
import 'services/rider_trust_rules_service.dart';
import 'services/rider_ride_cloud_functions_service.dart';
import 'services/nexride_official_bank_account_service.dart';
import 'services/rider_push_notification_service.dart';
import 'services/rider_prepaid_intent_recovery_store.dart';
import 'services/trip_safety_service.dart';
import 'services/payment_methods_service.dart';
import 'payment_methods_screen.dart';
import 'bank_transfer_receipt_screen.dart';
import 'service_type.dart';
import 'share_trip_rtdb.dart';
import 'support/rider_backend_pricing.dart';
import 'support/rider_fare_support.dart';
import 'support/ride_chat_support.dart';
import 'support/rider_trust_support.dart';
import 'support/ride_create_metadata.dart';
import 'support/rtdb_flow_debug_log.dart';
import 'support/friendly_firebase_errors.dart';
import 'support/nexride_contact_constants.dart';
import 'support/production_user_messages.dart';
import 'support/startup_rtdb_support.dart';
import 'trip_sync/trip_state_machine.dart';
import 'widgets/native_places_autocomplete_field.dart';
import 'widgets/ride_chat_sheet.dart';
import 'onboarding/rider_selfie_verification_screen.dart';
import 'services/rider_compliance_service.dart';
import 'services/region_pricing_service.dart';
import 'widgets/rider_identity_verification_banner.dart';
import 'widgets/rider_updated_terms_dialog.dart';
import 'widgets/rider_rollout_area_sheet.dart';

import 'compliance/rider_identity_booking_gate.dart';
import 'config/rollout_copy.dart';
import 'models/rollout_delivery_region_model.dart';
import 'services/rider_rollout_profile_store.dart';

void safeShowSnackBar(BuildContext context, String message) {
  SchedulerBinding.instance.addPostFrameCallback((_) {
    if (!context.mounted) {
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  });
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key, this.initialOpenRideId});

  /// When set (e.g. shared-trip deep link), attaches the ride listener after first frame.
  final String? initialOpenRideId;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _RiderRideStatusDecision {
  const _RiderRideStatusDecision({
    required this.status,
    required this.driverData,
    this.reason,
  });

  final String status;
  final Map<String, dynamic>? driverData;
  final String? reason;
}

enum _ActiveTripPrecheckOutcome {
  noPointer,
  staleCleared,
  resumed,
}

class _MapScreenState extends State<MapScreen> with WidgetsBindingObserver {
  final rtdb.DatabaseReference _rideRequestsRef = rtdb.FirebaseDatabase.instance
      .ref('ride_requests');
  final rtdb.DatabaseReference _driverActiveRideRef = rtdb
      .FirebaseDatabase
      .instance
      .ref('driver_active_rides');
  final rtdb.DatabaseReference _driversRef = rtdb.FirebaseDatabase.instance.ref(
    'drivers',
  );
  final rtdb.DatabaseReference _usersRef = rtdb.FirebaseDatabase.instance.ref(
    'users',
  );
  final CallService _callService = CallService();
  final CallPermissions _callPermissions = const CallPermissions();
  final RiderAlertSoundService _alertSoundService = RiderAlertSoundService();
  final RiderActiveTripSessionService _activeTripSessionService =
      RiderActiveTripSessionService.instance;
  static const Duration _staleSearchingRestoreTimeout = Duration(minutes: 3);
  String _lastRequestUiStateLog = '';
  final ShareTripRtdbService _shareTripRtdbService = ShareTripRtdbService();
  final PaymentMethodsService _paymentMethodsService =
      const PaymentMethodsService();
  final RiderTrustBootstrapService _bootstrapService =
      const RiderTrustBootstrapService();
  final RiderTrustRulesService _trustRulesService =
      const RiderTrustRulesService();
  final RiderRideCloudFunctionsService _rideCloud =
      RiderRideCloudFunctionsService();
  final TripSafetyTelemetryService _tripSafetyService =
      TripSafetyTelemetryService();
  final NativePlacesService _nativePlacesService = NativePlacesService.instance;
  final RoadRouteService _roadRouteService = RoadRouteService();
  final ImagePicker _riderChatImagePicker = ImagePicker();
  final DispatchPhotoUploadService _dispatchPhotoUploadService =
      const DispatchPhotoUploadService();
  final ValueNotifier<int> _mapLayerVersion = ValueNotifier<int>(0);
  final TextEditingController _pickupController = TextEditingController();
  final TextEditingController _destinationController = TextEditingController();
  final List<TextEditingController> _additionalStopControllers =
      List<TextEditingController>.generate(2, (_) => TextEditingController());

  GoogleMapController? _mapController;
  bool _mapReady = false;
  bool _mapPlatformSurfaceFailed = false;
  int _mapRenderRefreshGeneration = 0;
  bool _iosMapCameraIdleObserved = false;
  int _iosMapTileRecoveryCount = 0;
  int _routePreviewComputationGeneration = 0;

  LatLng _riderLocation = const LatLng(
    RiderServiceAreaConfig.defaultMapLatitude,
    RiderServiceAreaConfig.defaultMapLongitude,
  );
  LatLng? _pickupLocation;
  LatLng? _destinationLocation;
  final List<LatLng?> _additionalStopLocations = List<LatLng?>.filled(2, null);
  final List<LatLng> _expectedRoutePoints = <LatLng>[];
  LatLng? _lastDriverLocation;
  LatLng? _lastDriverPosition;
  LatLng? _lastSafetyCheckLocation;
  LatLng? _lastTelemetryCheckpointPosition;
  DateTime? _lastTelemetryCheckpointAt;

  final Set<Marker> _markers = <Marker>{};
  Set<Polyline> _polylines = <Polyline>{};

  String _pickupAddress = '';
  String _destinationAddress = '';
  final List<String> _additionalStopAddresses = List<String>.filled(2, '');
  String _rideStatus = 'idle';
  String? _currentRideId;
  String? _activeRideListenerRideId;
  String? _recoverableActiveRideId;

  double _distanceKm = 0;
  double _estimatedDurationMin = 0;
  double _fare = 0;
  double _lastBearing = 0;
  String? _routePreviewError;

  bool _isCreatingRide = false;
  bool _isSubmittingRideRequest = false;
  bool _isCancellingRide = false;
  /// Rider tapped cancel while [createRideRequest] is in flight (write / verify).
  bool _rideRequestUserAborted = false;
  bool _searchingDriver = false;
  bool _driverFound = false;
  bool _tripStarted = false;
  bool _waitingCharged = false;
  bool _isRiderChatOpen = false;
  bool _isSharingTrip = false;
  bool _hasHydratedRiderChatMessages = false;
  bool _safetyMonitoringActive = false;
  bool _safetyPopupVisible = false;

  /// Backend-owned pointer `rider_active_trip/{uid}` → `{ ride_id, phase }`.
  StreamSubscription<rtdb.DatabaseEvent>? _riderActiveRidePointerSubscription;

  int _countdown = 300;
  int _extraStopFieldCount = 0;
  int _riderUnreadChatCount = 0;
  /// Missed incoming voice call (this user was receiver) — cleared when chat/call is opened.
  bool _riderMissedCallNotice = false;
  DateTime? _lastRiderChatNoticeAt;
  int _routeDeviationStrikeCount = 0;
  String? _pendingRideRequestSubmissionId;
  final RiderPrepaidIntentRecoveryStore _prepaidRecoveryStore =
      RiderPrepaidIntentRecoveryStore();
  bool _hostedCheckoutProcessing = false;
  bool _identityComplianceLoaded = false;
  bool _selfieBlocksBooking = false;
  RiderComplianceSnapshot? _riderFirestoreCompliance;

  Map<String, dynamic>? _driverData;
  Map<String, dynamic>? _currentRideSnapshot;
  Marker? _driverMarker;
  DateTime? _lastMoveTime;
  DateTime? _lastSafetyPromptAt;
  DateTime? _lastRiderSpeedSampleAt;
  double? _lastRiderImpliedSpeedKmh;
  int? _lastConsumedRiderSafetyAlertIssuedAt;
  int _driverAnimationGeneration = 0;
  String _lastRenderedRouteSignature = '';

  Timer? _timer;
  Timer? _rideSearchTimeoutTimer;
  Timer? _callDurationTimer;
  Timer? _callRingTimeoutTimer;
  StreamSubscription<rtdb.DatabaseEvent>? _rideListener;
  StreamSubscription<rtdb.DatabaseEvent>? _driversSubscription;
  final List<StreamSubscription<rtdb.DatabaseEvent>> _riderChatSubscriptions =
      <StreamSubscription<rtdb.DatabaseEvent>>[];
  final Map<String, RideChatMessage> _riderChatMessagesById =
      <String, RideChatMessage>{};
  final Map<String, String> _riderChatDraftByRide = <String, String>{};
  StreamSubscription<rtdb.DatabaseEvent>? _callSubscription;
  StreamSubscription<rtdb.DatabaseEvent>? _incomingCallSubscription;
  String? _incomingCallListenerUid;
  OverlayEntry? _callOverlayEntry;
  RideCallSession? _currentCallSession;
  String? _callListenerRideId;
  DateTime? _callAcceptedAt;
  Duration _callDuration = Duration.zero;
  AppLifecycleState _appLifecycleState = AppLifecycleState.resumed;
  bool _callMuted = false;
  bool _callSpeakerOn = true;
  bool _callJoinedChannel = false;
  bool _isStartingVoiceCall = false;
  bool _isRiderTripSheetExpanded = false;
  bool _deviceLocationAvailable = false;
  bool _deviceLocationOutsideLaunchArea = false;
  bool _launchCityChosenManually = false;
  final ValueNotifier<List<RideChatMessage>> _riderChatMessages =
      ValueNotifier<List<RideChatMessage>>(<RideChatMessage>[]);
  final Set<String> _loggedRiderChatMessageIds = <String>{};
  String? _riderChatListenerRideId;
  String? _lastRiderChatErrorNoticeKey;
  Map<String, dynamic> _verification = buildRiderVerificationDefaults(null);
  Map<String, dynamic> _riskFlags = buildRiderRiskFlagsDefaults(null);
  Map<String, dynamic> _paymentFlags = buildRiderPaymentFlagsDefaults(null);
  Map<String, dynamic> _reputation = buildRiderReputationDefaults(null);
  Map<String, dynamic> _trustSummary = <String, dynamic>{};
  Map<String, dynamic> _trustRulesConfig = const <String, dynamic>{};
  String _selectedLaunchCity = RiderLaunchScope.defaultBrowseCity;
  List<RolloutDeliveryRegionModel> _rolloutCatalog = const <RolloutDeliveryRegionModel>[];
  bool _rolloutCatalogLoading = false;
  bool _rolloutCatalogHydrated = false;
  Object? _rolloutCatalogError;
  String? _rolloutRegionId;
  String? _rolloutCityId;
  String? _rolloutDispatchMarketId;
  StreamSubscription<User?>? _riderAuthRolloutSubscription;
  /// `flutterwave` / `bank_transfer` — must match Cloud Function allow-list.
  String _riderTripPaymentMethod = 'flutterwave';

  static const Color _gold = Color(0xFFD4AF37);
  static const Color _routeGold = Color(0xFFB8892D);
  static const Color _routeShadow = Color(0xFF8A6424);
  static const Color _panelBackground = Color(0xFFFFFBF5);
  static const Color _panelBorder = Color(0xFFE7D7BC);
  static const Color _panelInk = Color(0xFF1E160D);
  static const Color _panelMutedInk = Color(0xFF726555);
  static const Color _panelSuccess = Color(0xFF247A59);
  static const Color _panelWarning = Color(0xFFD47A2A);
  static const Color _panelDanger = Color(0xFFD95842);
  static const Duration _countdownDuration = Duration(minutes: 5);
  static const Duration _rideSearchTimeoutDuration = Duration(seconds: 180);
  static const Duration _driverAnimationDuration = Duration(milliseconds: 700);
  static const Duration _longStopDuration = Duration(minutes: 3);
  static const Duration _safetyPopupCooldown = Duration(minutes: 3);
  static const double _driverAnimationSnapDistanceMeters = 160;
  static const double _routeDeviationThresholdMeters = 250;
  static const double _stopMovementThresholdMeters = 18;
  static const double _expectedStopRadiusMeters = 120;
  static const double _suddenStopMinPriorKmh = 32;
  static const double _suddenStopMaxAfterKmh = 14;
  static const double _suddenStopDropKmh = 22;
  static const double _suddenStopMinDtSec = 0.35;
  static const double _suddenStopMaxDtSec = 8;
  static const Set<String> _rideTrackingStatuses = <String>{
    'searching',
    'pending_driver_action',
    'assigned',
    'accepted',
    'arriving',
    'arrived',
    'on_trip',
  };

  double get _telemetryCheckpointMinDistanceMeters =>
      (_asDouble(_trustRulesConfig['telemetryCheckpointMinDistanceMeters']) ??
              120)
          .toDouble();

  int get _telemetryCheckpointMinSeconds =>
      _asInt(_trustRulesConfig['telemetryCheckpointMinSeconds']) ?? 45;

  double get _configuredRouteDeviationToleranceMeters =>
      (_asDouble(_trustRulesConfig['offRouteToleranceMeters']) ??
              _routeDeviationThresholdMeters)
          .toDouble();

  int get _configuredRouteDeviationStrikeThreshold =>
      _asInt(_trustRulesConfig['offRouteStrikeThreshold']) ?? 3;
  static const int _maxDropOffs = 3;
  static const Set<String> _restorableRideStatuses = <String>{
    'searching',
    'pending_driver_action',
    'assigned',
    'accepted',
    'arriving',
    'arrived',
    'on_trip',
  };
  static const Duration _rideChatSendTimeout = Duration(seconds: 10);

  void _logRideFlow(String message) {
    debugPrint('[RiderRTDB] $message');
  }

  /// Rider → RTDB discovery chain (filter logcat by `[DISCOVERY]`).
  void _logDiscoveryRideRequestPayload(
    String phase,
    String rideId,
    Map<String, dynamic> data,
  ) {
    final pickup = _asStringDynamicMap(data['pickup']);
    final destination = _asStringDynamicMap(data['destination']);
    final plat = pickup?['lat'];
    final plng = pickup?['lng'];
    final dlat = destination?['lat'];
    final dlng = destination?['lng'];
    String projectId = 'unavailable';
    String databaseUrl = 'unavailable';
    try {
      final opts = Firebase.app().options;
      projectId = opts.projectId;
      databaseUrl = opts.databaseURL ?? 'null';
    } catch (_) {
      // Firebase not initialized yet (should not happen on this path).
    }
    debugPrint(
      '[DISCOVERY] rtdb_payload $phase rideId=$rideId market=${data['market']} '
      'status=${data['status']} trip_state=${data['trip_state']} '
      'driver_id=${data['driver_id']} service_type=${data['service_type']} '
      'pickup_lat=$plat pickup_lng=$plng dest_lat=$dlat dest_lng=$dlng '
      'firebase_project=$projectId databaseURL=$databaseUrl',
    );
  }

  void _logRiderMap(String message) {
    debugPrint('[RiderMap] $message');
  }

  void _logRideCall(String message) {
    debugPrint('[RideCall] $message');
  }

  Future<void> _syncRideOperationalViews({
    required String rideId,
    required Map<String, dynamic> rideData,
    required String lastEvent,
  }) async {
    final normalizedRideId = rideId.trim();
    if (normalizedRideId.isEmpty) {
      return;
    }
    // admin_rides / support_queue mirrors are server-owned; rider client must not
    // multi-path update the RTDB root (denied under production rules).
    _logRideFlow(
      '[OPS_MIRROR] skipped rideId=$normalizedRideId last_event=$lastEvent '
      '(rider client)',
    );
  }

  /// After [rider_active_trip], the server returns an existing [rideId] but a
  /// one-shot [DatabaseReference.get] can stall waiting on the server socket
  /// while the UI already showed "Resuming…". Prefer the realtime channel,
  /// which often delivers the cached row immediately.
  Future<Map<String, dynamic>> _awaitRideSnapshotForActiveTripResume(
    String rideId,
  ) async {
    final normalized = rideId.trim();
    if (normalized.isEmpty) {
      throw StateError('ride_missing_after_create');
    }
    _logRideFlow(
      '[RIDER_REQ] resume_snapshot_listener_first rideId=$normalized',
    );
    try {
      return await _rideRequestsRef
          .child(normalized)
          .onValue
          .expand((rtdb.DatabaseEvent event) {
            if (!event.snapshot.exists || event.snapshot.value is! Map) {
              return const Iterable<Map<String, dynamic>>.empty();
            }
            return <Map<String, dynamic>>[
              Map<String, dynamic>.from(event.snapshot.value as Map),
            ];
          })
          .first
          .timeout(const Duration(seconds: 30));
    } on TimeoutException catch (e) {
      _logRideFlow(
        '[RIDER_REQ] resume_snapshot_listener_timeout rideId=$normalized err=$e',
      );
      throw StateError('ride_resume_snapshot_timeout');
    }
  }

  void _showSnackBar(String message) {
    if (!mounted) {
      return;
    }

    safeShowSnackBar(context, message);
  }

  void _showRideRequestRetrySnackBar(String message) {
    if (!mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) {
      return;
    }
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        action: SnackBarAction(
          label: 'RETRY',
          onPressed: () {
            unawaited(handlePrimaryRideAction());
          },
        ),
      ),
    );
  }

  void _setStateSafely(VoidCallback apply) {
    if (!mounted) {
      return;
    }
    setState(apply);
  }

  LatLng get _nigeriaMarketCenter => const LatLng(
    RiderServiceAreaConfig.defaultMapLatitude,
    RiderServiceAreaConfig.defaultMapLongitude,
  );

  LatLng get _selectedLaunchCityCenter => LatLng(
    RiderLaunchScope.latitudeForCity(_selectedLaunchCity),
    RiderLaunchScope.longitudeForCity(_selectedLaunchCity),
  );

  String get _defaultTestRiderCity =>
      _normalizeServiceCity(RiderLocationPolicy.testRiderCity) ??
      RiderLaunchScope.defaultBrowseCity;

  String? get _configuredTestRiderCity {
    if (!RiderLocationPolicy.useTestRiderLocation) {
      return null;
    }
    return _defaultTestRiderCity;
  }

  LatLng get _fallbackBrowseLocation {
    final fallbackCity = RiderLocationPolicy.useTestRiderLocation
        ? (_normalizeServiceCity(_selectedLaunchCity) ?? _defaultTestRiderCity)
        : null;
    if (fallbackCity == null) {
      return _nigeriaMarketCenter;
    }
    return LatLng(
      RiderLaunchScope.latitudeForCity(fallbackCity),
      RiderLaunchScope.longitudeForCity(fallbackCity),
    );
  }

  /// Driver-matching window source of truth.
  /// Prefer `request_expires_at`, then fallback `expires_at`.
  int _rideSearchTimeoutAt(Map<String, dynamic>? rideData) {
    if (rideData == null) {
      return 0;
    }

    for (final key in <String>['request_expires_at', 'expires_at']) {
      final value = _asInt(rideData[key]);
      if (value != null && value > 0) {
        final createdAt = _asInt(rideData['created_at']) ?? 0;
        final maxSearchWindow = createdAt > 0
            ? createdAt + const Duration(minutes: 5).inMilliseconds
            : 0;
        if (maxSearchWindow > 0 && value > maxSearchWindow) {
          return maxSearchWindow;
        }
        return value;
      }
    }

    final createdAt = _asInt(rideData['created_at']) ?? 0;
    if (createdAt > 0) {
      return createdAt + const Duration(minutes: 5).inMilliseconds;
    }
    return 0;
  }

  bool _rideHasTimedOut(Map<String, dynamic>? rideData) {
    final timeoutAt = _rideSearchTimeoutAt(rideData);
    return timeoutAt > 0 && DateTime.now().millisecondsSinceEpoch >= timeoutAt;
  }

  int _rideAssignmentExpiresAt(Map<String, dynamic>? rideData) {
    if (rideData == null) {
      return 0;
    }

    for (final key in <String>[
      'assignment_expires_at',
      'driver_response_timeout_at',
    ]) {
      final value = _asInt(rideData[key]);
      if (value != null && value > 0) {
        return value;
      }
    }

    return 0;
  }

  bool _rideAssignmentHasTimedOut(Map<String, dynamic>? rideData) {
    final assignmentExpiresAt = _rideAssignmentExpiresAt(rideData);
    return assignmentExpiresAt > 0 &&
        DateTime.now().millisecondsSinceEpoch >= assignmentExpiresAt;
  }

  bool _rideStatusNeedsAssignedDriver(String status) {
    return status == 'pending_driver_action' ||
        status == 'assigned' ||
        status == 'accepted' ||
        status == 'arriving' ||
        status == 'arrived' ||
        status == 'on_trip';
  }

  void _clearRideSearchTimeout({String reason = 'cleared'}) {
    final timer = _rideSearchTimeoutTimer;
    if (timer == null) {
      return;
    }

    timer.cancel();
    _rideSearchTimeoutTimer = null;
    _logRideFlow('search timeout timer cleared reason=$reason');
  }

  void _scheduleRideSearchTimeout({
    required String rideId,
    required Map<String, dynamic> rideData,
  }) {
    final timeoutAt = _rideSearchTimeoutAt(rideData);
    if (timeoutAt <= 0) {
      _clearRideSearchTimeout(reason: 'missing_timeout');
      return;
    }

    final delayMs = timeoutAt - DateTime.now().millisecondsSinceEpoch;
    if (delayMs <= 0) {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      _logRideFlow(
        '[RIDE_LIFECYCLE] search_timeout_timer_fire_immediate rideId=$rideId '
        'timeoutAt=$timeoutAt nowMs=$nowMs delayMs=$delayMs',
      );
      unawaited(_handleRideSearchTimeout(rideId));
      return;
    }

    _clearRideSearchTimeout(reason: 'rescheduled');
    _rideSearchTimeoutTimer = Timer(
      Duration(milliseconds: delayMs),
      () => unawaited(_handleRideSearchTimeout(rideId)),
    );
    _logRideFlow(
      'search timeout timer scheduled rideId=$rideId timeoutAt=$timeoutAt',
    );
  }

  Future<void> _handleRideSearchTimeout(String rideId) async {
    if (_currentRideId != rideId) {
      return;
    }
    // Belt-and-suspenders: once a ride has progressed past the searching phase
    // the rider must NEVER be flipped back into matching. Local UI state is the
    // first line of defense; the snapshot check below is the second.
    if (!_searchingDriver || _driverFound || _tripStarted) {
      _clearRideSearchTimeout(reason: 'rider_no_longer_searching_local');
      return;
    }

    try {
      final snapshot = await _rideRequestsRef.child(rideId).get();
      final rideData = _asStringDynamicMap(snapshot.value);
      if (rideData == null) {
        return;
      }

      final status = _normalizedRideStatus(_valueAsText(rideData['status']));
      final decision = await _resolveVisibleRideStatus(
        rideId: rideId,
        rideData: rideData,
        source: 'search_timeout',
      );
      if (decision.status != 'searching') {
        _clearRideSearchTimeout(reason: 'snapshot_status_$status');
        return;
      }

      if (!_rideHasTimedOut(rideData)) {
        _scheduleRideSearchTimeout(rideId: rideId, rideData: rideData);
        return;
      }

      _logRideFlow(
        '[RIDE_LIFECYCLE] mark_no_drivers source=search_timeout_handler '
        'rideId=$rideId force=${status != 'searching'} '
        'timeoutAt=${_rideSearchTimeoutAt(rideData)} '
        'trip_state=${rideData['trip_state']} status=${rideData['status']}',
      );
      await _markRideNoDriversAvailable(
        rideId: rideId,
        rideData: rideData,
        force: status != 'searching',
      );
    } catch (error) {
      _logRideFlow(
        'search timeout handling failed rideId=$rideId error=$error',
      );
    }
  }

  Future<void> _markRideNoDriversAvailable({
    required String rideId,
    required Map<String, dynamic> rideData,
    bool force = false,
  }) async {
    final status = _canonicalRiderUiStatus(rideData);
    final driverId = _valueAsText(rideData['driver_id']);
    _logRideFlow(
      '[RIDE_LIFECYCLE] cancel_no_drivers_enter rideId=$rideId force=$force '
      'uiStatus=$status trip_state=${rideData['trip_state']} raw_status=${rideData['status']}',
    );
    if (status == 'cancelled' || status == 'completed') {
      return;
    }

    if (!force &&
        driverId.isNotEmpty &&
        driverId != 'waiting' &&
        status != 'searching') {
      return;
    }

    Map<String, dynamic>? expireRes;
    try {
      expireRes = await _rideCloud.expireRideRequest(rideId: rideId);
    } catch (error) {
      _logRideFlow(
        '[RIDE_LIFECYCLE] expireRideRequest failed rideId=$rideId error=$error',
      );
    }
    if (!riderRideCallableSucceeded(expireRes)) {
      try {
        await _rideCloud.cancelRideRequest(
          rideId: rideId,
          cancelReason: 'no_drivers_available',
        );
      } catch (error) {
        _logRideFlow(
          '[RIDE_LIFECYCLE] cancelRideRequest failed rideId=$rideId error=$error',
        );
      }
    }
    Map<String, dynamic> merged = Map<String, dynamic>.from(rideData);
    try {
      final snap = await _rideRequestsRef.child(rideId).get();
      final live = _asStringDynamicMap(snap.value);
      if (live != null) {
        merged = live;
      }
    } catch (_) {}
    await _syncRideOperationalViews(
      rideId: rideId,
      rideData: merged,
      lastEvent: 'system_search_timeout',
    );
    await _restoreDriverAvailabilityIfRideMatches(
      rideId: rideId,
      driverId: driverId,
      reason: 'system_search_timeout',
    );
    _logRideFlow(
      'ride search timed out ts=${DateTime.now().toIso8601String()} rideId=$rideId status=cancelled driverId=$driverId',
    );
    await _clearStaleActiveTripArtifacts(
      rideId: rideId,
      reason: 'search_timeout_auto_expire',
    );
    if (mounted) {
      _showSnackBar(
        "We couldn't find a driver nearby in time. You're back on the map — please try again shortly.",
      );
    }
    await _resetRideState(clearDestination: true);
  }

  Future<void> _restoreDriverAvailabilityIfRideMatches({
    required String rideId,
    required String driverId,
    required String reason,
  }) async {
    if (driverId.isEmpty || driverId == 'waiting') {
      return;
    }
    // Driver availability is server-owned; rider must not write drivers/* or
    // driver_active_rides/*.
    _logRideFlow(
      '[RIDER] skip restore_driver_availability rideId=$rideId '
      'driverId=$driverId reason=$reason',
    );
  }

  String _cancelledSettlementStatus(Map<String, dynamic> rideData) {
    final settlement = _asStringDynamicMap(rideData['settlement']);
    final normalizedExistingStatus = _valueAsText(
      settlement?['settlementStatus'],
    ).toLowerCase();
    if (normalizedExistingStatus.isNotEmpty &&
        normalizedExistingStatus != 'none' &&
        normalizedExistingStatus != 'reversed') {
      return 'reversed';
    }
    return settlement == null || settlement.isEmpty ? 'none' : 'reversed';
  }

  Map<String, dynamic> _cancelledSettlementPayload(
    Map<String, dynamic> rideData,
  ) {
    final paymentMethod = _firstNonEmptyText(<dynamic>[
      _asStringDynamicMap(rideData['settlement'])?['paymentMethod'],
      rideData['payment_method'],
      _asStringDynamicMap(rideData['payment_context'])?['method'],
    ], fallback: 'unspecified');
    return <String, dynamic>{
      'settlementStatus': _cancelledSettlementStatus(rideData),
      'completionState': 'trip_cancelled',
      'paymentMethod': paymentMethod,
      'grossFareNgn': 0,
      'grossFare': 0,
      'commissionAmountNgn': 0,
      'commissionAmount': 0,
      'commission': 0,
      'driverPayoutNgn': 0,
      'driverPayout': 0,
      'netEarningNgn': 0,
      'netEarning': 0,
      'countsTowardWallet': false,
    };
  }

  Map<String, dynamic> _cancelledRideMetadata({
    required Map<String, dynamic> rideData,
    required String cancelSource,
    int? effectiveAt,
    bool invalidTrip = false,
    String? invalidReason,
  }) {
    final effectiveCancelAt = effectiveAt != null && effectiveAt > 0
        ? effectiveAt
        : DateTime.now().millisecondsSinceEpoch;
    return <String, dynamic>{
      'cancel_source': cancelSource,
      'cancelled_effective_at': effectiveCancelAt,
      'cancelled_recorded_at': rtdb.ServerValue.timestamp,
      'search_timeout_at': null,
      'request_expires_at': null,
      'assignment_expires_at': null,
      'driver_response_timeout_at': null,
      'assignment_timeout_ms': null,
      'start_timeout_at': null,
      'route_log_timeout_at': null,
      'settlement': _cancelledSettlementPayload(rideData),
      'commission': 0,
      'commissionAmount': 0,
      'driverPayout': 0,
      'netEarning': 0,
      'trip_invalid': invalidTrip,
      'trip_invalid_reason': invalidTrip ? (invalidReason ?? '') : null,
    };
  }

  Future<bool> _autoCancelRideForLifecycleTimeoutIfNeeded({
    required String rideId,
    required Map<String, dynamic> rideData,
    required String source,
  }) async {
    final decision = TripStateMachine.timeoutCancellationDecision(rideData);
    if (decision == null) {
      return false;
    }

    _logRideFlow(
      '[RIDE_LIFECYCLE] lifecycle_timeout_cancel_attempt rideId=$rideId '
      'source=$source reason=${decision.reason} canonical=${decision.canonicalState} '
      'effectiveAt=${decision.effectiveAt}',
    );

    final transactionResult = await _rideRequestsRef
        .child(rideId)
        .runTransaction((currentData) {
          final currentRide = _asStringDynamicMap(currentData);
          if (currentRide == null) {
            return rtdb.Transaction.abort();
          }

          final currentDecision = TripStateMachine.timeoutCancellationDecision(
            currentRide,
          );
          if (currentDecision == null) {
            return rtdb.Transaction.abort();
          }

          final updates =
              TripStateMachine.buildTransitionUpdate(
                currentRide: currentRide,
                nextCanonicalState: TripLifecycleState.tripCancelled,
                timestampValue: rtdb.ServerValue.timestamp,
                transitionSource: currentDecision.transitionSource,
                transitionActor: 'system',
                cancellationActor: 'system',
                cancellationReason: currentDecision.reason,
              )..addAll(
                _cancelledRideMetadata(
                  rideData: currentRide,
                  cancelSource: currentDecision.cancelSource,
                  effectiveAt: currentDecision.effectiveAt,
                  invalidTrip: currentDecision.invalidTrip,
                  invalidReason: currentDecision.reason,
                ),
              );

          return rtdb.Transaction.success(
            Map<String, dynamic>.from(currentRide)..addAll(updates),
          );
        }, applyLocally: false);

    if (!transactionResult.committed) {
      return false;
    }

    final committedRide =
        _asStringDynamicMap(transactionResult.snapshot.value) ?? rideData;
    await _restoreDriverAvailabilityIfRideMatches(
      rideId: rideId,
      driverId: _valueAsText(committedRide['driver_id']),
      reason: decision.reason,
    );
    _logRideFlow(
      'ride auto-cancelled ts=${DateTime.now().toIso8601String()} source=$source rideId=$rideId reason=${decision.reason} effectiveAt=${decision.effectiveAt}',
    );
    return true;
  }

  /// When RTDB still uses legacy `status: cancelled`, infer who cancelled for UI + copy.
  String? _riderRefinedTerminalCancelStatus(Map<String, dynamic> rideData) {
    return TripStateMachine.refinedRiderTerminalCancelStatus(rideData);
  }

  String _rideCancellationMessage({
    required String cancelReason,
    required String terminalStatus,
  }) {
    if (terminalStatus == 'driver_cancelled') {
      return 'Your driver cancelled. Looking for another driver...';
    }
    if (terminalStatus == 'rider_cancelled') {
      return 'You cancelled this trip.';
    }
    if (terminalStatus == 'expired') {
      return 'This trip request expired. Please request again.';
    }
    return switch (cancelReason.trim().toLowerCase()) {
      'no_drivers_available' => 'No drivers available right now.',
      'driver_cancelled' => 'Your driver cancelled. Looking for another driver...',
      'rider_cancelled' || 'user_cancelled' => 'Ride cancelled by the rider.',
      'driver_start_timeout' =>
        'Ride cancelled because pickup did not start in time.',
      'no_route_logs' =>
        'Ride cancelled because no trip movement was recorded.',
      'driver_offline' || 'driver_status_offline' || 'driver_session_lost' =>
        'Ride cancelled because the driver went offline.',
      _ => 'Ride cancelled.',
    };
  }

  String _canonicalRiderUiStatus(Map<String, dynamic> rideData) {
    return TripStateMachine.riderUiStatusFromRideData(rideData);
  }

  Future<bool> _releaseExpiredAssignedRideIfNeeded({
    required String rideId,
    required Map<String, dynamic> rideData,
    required String source,
  }) async {
    final canonicalState = TripStateMachine.canonicalStateFromSnapshot(rideData);
    if (canonicalState != TripLifecycleState.driverAssigned) {
      return false;
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;

    // Already past server-side start timeout → stale.
    final timeoutDecision = TripStateMachine.timeoutCancellationDecision(rideData);
    if (timeoutDecision != null) {
      _logRideFlow(
        'STALE_ASSIGNED_CLEARED source=$source rideId=$rideId '
        'reason=${timeoutDecision.reason}',
      );
      await _clearStaleActiveTripArtifacts(
        rideId: rideId,
        reason: 'expired_assignment_$source',
        clearRideRequestNode: false,
      );
      return true;
    }

    // No accepted_at — driver was assigned but never confirmed. If last activity
    // is more than 15 minutes old, treat as stale.
    const kUnconfirmedAssignmentStalenessMs = 15 * 60 * 1000;
    final activityTs = _rideActivityTimestamp(rideData);
    if (activityTs > 0 &&
        nowMs - activityTs > kUnconfirmedAssignmentStalenessMs) {
      final acceptedAt = _asInt(rideData['accepted_at']) ??
          _asInt(rideData['acceptedAt']) ??
          0;
      if (acceptedAt <= 0) {
        _logRideFlow(
          'STALE_UNCONFIRMED_ASSIGNMENT_CLEARED source=$source rideId=$rideId '
          'ageMs=${nowMs - activityTs}',
        );
        await _clearStaleActiveTripArtifacts(
          rideId: rideId,
          reason: 'unconfirmed_assignment_stale_$source',
          clearRideRequestNode: false,
        );
        return true;
      }
    }

    return false;
  }

  Future<String?> _assignedDriverInvalidReason({
    required String rideId,
    required Map<String, dynamic> rideData,
    required String status,
  }) async {
    final canonicalState = TripStateMachine.canonicalStateFromSnapshot(rideData);
    final driverId = _valueAsText(rideData['driver_id']);
    if (driverId.isEmpty || driverId == 'waiting') {
      return 'driver_missing';
    }

    final lifecycleProofReason = TripStateMachine.lifecycleProofReason(
      rideData,
      canonicalState: canonicalState,
    );
    if (lifecycleProofReason != null) {
      return lifecycleProofReason;
    }

    final snapshots = await Future.wait(<Future<rtdb.DataSnapshot>>[
      _driversRef.child(driverId).get(),
      _driverActiveRideRef.child(driverId).get(),
    ]);

    final driverRecord = _asStringDynamicMap(snapshots[0].value);
    final activeRideRecord = _asStringDynamicMap(snapshots[1].value);
    if (driverRecord == null) {
      return 'driver_record_missing';
    }

    final isOnline =
        _asBool(driverRecord['isOnline']) || _asBool(driverRecord['online']);
    if (!isOnline) {
      return 'driver_offline';
    }

    final driverAvailabilityFlagPresent =
        driverRecord.containsKey('isAvailable') ||
        driverRecord.containsKey('available');
    final isAvailable = driverAvailabilityFlagPresent
        ? (_asBool(driverRecord['isAvailable']) ||
              _asBool(driverRecord['available']))
        : false;
    if (TripStateMachine.isDriverActiveState(canonicalState) && isAvailable) {
      return 'driver_marked_available_during_active_trip';
    }

    final activeRideId = _firstNonEmptyText(<dynamic>[
      activeRideRecord?['ride_id'],
      driverRecord['activeRideId'],
      driverRecord['currentRideId'],
    ]);
    if (activeRideId != rideId) {
      return 'driver_active_rides_mismatch';
    }

    final driverStatus = _normalizedRideStatus(
      _valueAsText(driverRecord['status']),
    );
    if (driverStatus == 'offline' ||
        driverStatus == 'inactive' ||
        driverStatus == 'suspended') {
      return 'driver_status_offline';
    }

    return null;
  }

  Future<_RiderRideStatusDecision> _resolveVisibleRideStatus({
    required String rideId,
    required Map<String, dynamic> rideData,
    required String source,
  }) async {
    final terminalCanonical =
        TripStateMachine.canonicalStateFromSnapshot(rideData);
    if (TripStateMachine.isTerminal(terminalCanonical)) {
      var terminalStatus = TripStateMachine.uiStatusFromSnapshot(rideData);
      if (terminalStatus == 'cancelled') {
        final refined = _riderRefinedTerminalCancelStatus(rideData);
        if (refined != null) {
          terminalStatus = refined;
        }
      }
      return _RiderRideStatusDecision(
        status: terminalStatus,
        driverData: _extractDriverData(rideData),
      );
    }

    var status = TripStateMachine.uiStatusFromSnapshot(rideData);
    if (status == 'cancelled') {
      final refined = _riderRefinedTerminalCancelStatus(rideData);
      if (refined != null) {
        status = refined;
      }
    }
    if (!_rideStatusNeedsAssignedDriver(status)) {
      return _RiderRideStatusDecision(
        status: status,
        driverData: _extractDriverData(rideData),
      );
    }

    final canonicalFromRide =
        TripStateMachine.canonicalStateFromSnapshot(rideData);
    // After accept, `ride_requests` is authoritative. Cross-checking
    // `drivers/` + `driver_active_rides/` can briefly lag and incorrectly
    // collapse the UI back to "searching".
    if (TripStateMachine.isDriverActiveState(canonicalFromRide)) {
      _logRideFlow(
        '[MATCH_DEBUG][SEARCH_STATE_REJECTED_BECAUSE_ASSIGNED] rideId=$rideId '
        'source=$source trip_state=$canonicalFromRide '
        'driver_id=${_valueAsText(rideData['driver_id'])}',
      );
      _logRideFlow(
        '[MATCH_DEBUG][RIDER_STATUS_STABLE] rideId=$rideId source=$source '
        'phase=driver_active_trip trip_state=$canonicalFromRide',
      );
      return _RiderRideStatusDecision(
        status: status,
        driverData: _extractDriverData(rideData),
      );
    }

    if (TripStateMachine.isPendingDriverAssignmentState(canonicalFromRide)) {
      final assignedId = _valueAsText(rideData['driver_id']);
      final assignedOk =
          assignedId.isNotEmpty && assignedId.toLowerCase() != 'waiting';
      if (assignedOk && !_rideAssignmentHasTimedOut(rideData)) {
        _logRideFlow(
          '[MATCH_DEBUG][SEARCH_STATE_REJECTED_BECAUSE_ASSIGNED] rideId=$rideId '
          'source=$source trip_state=$canonicalFromRide driver_id=$assignedId',
        );
        _logRideFlow(
          '[MATCH_DEBUG][RIDER_STATUS_STABLE] rideId=$rideId source=$source '
          'phase=pending_driver_action trip_state=$canonicalFromRide',
        );
        return _RiderRideStatusDecision(
          status: status,
          driverData: _extractDriverData(rideData),
        );
      }
    }

    final invalidReason = await _assignedDriverInvalidReason(
      rideId: rideId,
      rideData: rideData,
      status: status,
    );
    if (invalidReason == null) {
      return _RiderRideStatusDecision(
        status: status,
        driverData: _extractDriverData(rideData),
      );
    }

    _logRideFlow(
      'ride validation blocked ts=${DateTime.now().toIso8601String()} source=$source rideId=$rideId rawStatus=$status driverId=${_valueAsText(rideData["driver_id"])} reason=$invalidReason',
    );
    return const _RiderRideStatusDecision(
      status: 'searching',
      driverData: null,
      reason: 'invalid_assigned_driver',
    );
  }

  Map<String, dynamic> _sanitizedRideSnapshotForDecision({
    required Map<String, dynamic> rideData,
    required _RiderRideStatusDecision decision,
  }) {
    // RTDB + Cloud Functions are the source of truth; never fabricate a return
    // to "searching" when the server has already assigned a driver.
    return Map<String, dynamic>.from(rideData);
  }

  bool get _hasActiveRide =>
      _currentRideId != null &&
      <String>{
        'pending_driver_action',
        'assigned',
        'accepted',
        'arriving',
        'arrived',
        'on_trip',
      }.contains(_effectiveRideStatus);

  /// Open-pool / driver-assignment phase (not yet an accepted on-trip ride for controls).
  bool get _isRiderRequestMatchingPhase {
    final hasRideContext =
        (_currentRideId != null && _currentRideId!.trim().isNotEmpty) ||
            _searchingDriver;
    if (!hasRideContext) {
      return false;
    }
    final snap = _currentRideSnapshot;
    if (snap == null || snap.isEmpty) {
      return false;
    }
    final canonical = TripStateMachine.canonicalStateFromSnapshot(snap);
    // Only true "pool search" — not driver_assigned (aliases like [pendingDriverAction]
    // point at the same string as [driverAssigned]).
    return canonical == TripLifecycleState.searching;
  }

  /// Hide the primary ride control during matching so only **Cancel request** shows.
  bool get _hidePrimaryRideDuringMatchingOnly =>
      false;

  bool get _canChat {
    if (_currentRideId == null) {
      return false;
    }
    final snapshot = _currentRideSnapshot;
    if (snapshot == null || snapshot.isEmpty) {
      return TripStateMachine.isChatEligibleUiStatus(_effectiveRideStatus);
    }
    return TripStateMachine.isChatEligibleRideSnapshot(snapshot);
  }

  void _syncRiderPaymentMethodFromRide(Map<String, dynamic> rideData) {
    final pm = _valueAsText(rideData['payment_method']).toLowerCase();
    if (pm == 'bank_transfer') {
      _riderTripPaymentMethod = 'bank_transfer';
    } else if (pm == 'card' ||
        pm == 'credit_card' ||
        pm == 'debit_card' ||
        pm == 'flutterwave') {
      _riderTripPaymentMethod = pm == 'flutterwave' ? 'flutterwave' : 'card';
    }
  }

  bool get _isTripPaymentSelectionLocked =>
      (_currentRideId != null && _currentRideId!.trim().isNotEmpty) ||
      _hasActiveRide;

  bool _ridePaymentVerified(Map<String, dynamic> ride) {
    final ps = _valueAsText(
      ride[RtdbRideRequestFields.paymentStatus] ?? ride['payment_status'],
    ).toLowerCase();
    final ptid = _valueAsText(ride['payment_transaction_id']);
    return (ps == 'verified' || ps == 'paid') && ptid.isNotEmpty;
  }

  bool _rideNeedsBankTransferReceipt(Map<String, dynamic>? ride) {
    if (ride == null || ride.isEmpty) {
      return false;
    }
    final pm = _valueAsText(ride['payment_method'])
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[\s-]+'), '_');
    if (pm != 'bank_transfer') {
      return false;
    }
    final status = _normalizedRideStatus(_valueAsText(ride['status']));
    if (status != 'completed') {
      return false;
    }
    if (ride['receipt_uploaded'] == true) {
      return false;
    }
    return true;
  }


  String _bankTransferReferenceFromRide(Map<String, dynamic>? ride) {
    if (ride == null || ride.isEmpty) {
      return '';
    }
    final direct = _valueAsText(ride['payment_reference']);
    if (direct.isNotEmpty) {
      return direct;
    }
    final ctr = _valueAsText(ride['customer_transaction_reference']);
    if (ctr.isNotEmpty) {
      return ctr;
    }
    return _valueAsText(ride['ride_id']);
  }

  Future<bool> _riderHasLinkedPaymentMethod(String uid) async {
    final methods = await _paymentMethodsService.fetchPaymentMethods(uid);
    return methods.isNotEmpty;
  }

  Future<void> _showLinkCardRequiredDialog() async {
    if (!mounted) {
      return;
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Link a card in your profile'),
        content: const Text(
          'Add or select a saved card under Profile → Payment methods before requesting a ride. '
          'We no longer open a browser to take payment when you tap Request ride.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PaymentMethodsScreen(riderId: user.uid),
                ),
              );
            },
            child: const Text('Open payment methods'),
          ),
        ],
      ),
    );
  }

  Future<void> _seedBankTransferInstructionIfNeeded({
    required String rideId,
    required Map<String, dynamic> rideData,
  }) async {
    final pm = _valueAsText(rideData['payment_method'])
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[\s-]+'), '_');
    if (pm != 'bank_transfer') {
      return;
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return;
    }
    final ref = _rideChatMessagesRef(rideId).child('nexride_bank_transfer_intro');
    try {
      final snap = await ref.get();
      if (snap.exists) {
        return;
      }
    } catch (_) {}
    final pricingQuote = RiderBackendPricingQuote.tryFromMap(rideData);
    final fare = _asDouble(rideData['fare']) ?? _fare;
    final serverTotal = pricingQuote?.totalNgn ?? 0;
    final transferNgn = serverTotal > 0
        ? serverTotal
        : fare.round() + RiderBackendPricingQuote.policyPlatformFeeNgn;
    final refText = _bankTransferReferenceFromRide(rideData);
    NexrideOfficialBankAccount? official;
    try {
      official = await NexrideOfficialBankAccountService.instance.fetch();
    } catch (_) {}
    final text = StringBuffer()
      ..writeln('Official NexRide bank transfer')
      ..writeln('')
      ..writeln(
        'Transfer ₦$transferNgn to (trip fare + platform fee):',
      )
      ..writeln('');
    if (official != null) {
      text
        ..writeln(official.bankName)
        ..writeln(official.accountName)
        ..writeln(official.accountNumber)
        ..writeln('');
    } else {
      text
        ..writeln(
          'Bank details are not available in the app right now. '
          'Contact NexRide support at support@nexride.africa for official transfer instructions.',
        )
        ..writeln('');
    }
    text
      ..writeln('Reference / narration (required): $refText')
      ..writeln('')
      ..writeln(
        'Upload your payment receipt in this chat during the trip. Your driver will see it here.',
      );
    final now = DateTime.now().millisecondsSinceEpoch;
    final payload = <String, dynamic>{
      'senderId': 'nexride_system',
      'senderRole': 'system',
      'type': 'text',
      'text': text.toString(),
      'timestamp': rtdb.ServerValue.timestamp,
      'server_ack': true,
      'status': 'sent',
    };
    try {
      await ref.setWithPriority(payload, -now);
      await _rideRequestsRef.root.update(<String, dynamic>{
        '${canonicalRideChatMetaPath(rideId)}/rideId': rideId,
        '${canonicalRideChatMetaPath(rideId)}/rider_id': user.uid,
        '${canonicalRideChatMetaPath(rideId)}/updated_at':
            rtdb.ServerValue.timestamp,
        '${canonicalRideChatMetaPath(rideId)}/last_message':
            'Bank transfer instructions',
        '${canonicalRideChatMetaPath(rideId)}/last_message_sender_id':
            'nexride_system',
        '${canonicalRideChatMetaPath(rideId)}/last_message_at':
            rtdb.ServerValue.timestamp,
        '${canonicalRideChatMetaPath(rideId)}/status': 'active',
      });
    } catch (error) {
      _logRideFlow('bank transfer chat seed failed rideId=$rideId error=$error');
    }
  }

  Future<void> _ensureUserPendingReceiptPointer({
    required String uid,
    required String rideId,
  }) async {
    try {
      await _usersRef
          .child(uid)
          .child('pending_bank_transfer_receipt_ride_id')
          .set(rideId);
    } catch (_) {}
  }

  Future<void> _reconcileStaleBankReceiptFlag(String uid) async {
    try {
      final snap =
          await _usersRef.child(uid).child('pending_bank_transfer_receipt_ride_id').get();
      final rideId = snap.value?.toString().trim() ?? '';
      if (rideId.isEmpty) {
        return;
      }
      final rs = await _rideRequestsRef.child(rideId).get();
      final data = _asStringDynamicMap(rs.value);
      if (data == null || _valueAsText(data['rider_id']) != uid) {
        await _usersRef.child(uid).child('pending_bank_transfer_receipt_ride_id').remove();
        return;
      }
      if (!_rideNeedsBankTransferReceipt(data)) {
        await _usersRef.child(uid).child('pending_bank_transfer_receipt_ride_id').remove();
      }
    } catch (_) {}
  }

  Future<bool> _blockIfBankTransferReceiptPending(String uid) async {
    await _reconcileStaleBankReceiptFlag(uid);
    try {
      final snap =
          await _usersRef.child(uid).child('pending_bank_transfer_receipt_ride_id').get();
      final rideId = snap.value?.toString().trim() ?? '';
      if (rideId.isEmpty) {
        return false;
      }
      final rs = await _rideRequestsRef.child(rideId).get();
      final data = _asStringDynamicMap(rs.value);
      if (!_rideNeedsBankTransferReceipt(data)) {
        await _usersRef.child(uid).child('pending_bank_transfer_receipt_ride_id').remove();
        return false;
      }
      if (!mounted) {
        return true;
      }
      _showSnackBar(
        'Please upload your bank transfer receipt before requesting another ride.',
      );
      await _openBankTransferReceiptScreen(rideId: rideId);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _showMandatoryBankReceiptRequirementSheet() {
    if (!mounted) {
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Please upload your bank transfer receipt to complete this ride.',
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openBankTransferReceiptScreen({
    required String rideId,
    String? ratingDriverId,
    String bankTransferReference = '',
  }) async {
    if (!mounted) {
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (ctx) => BankTransferReceiptScreen(
        rideId: rideId,
        onUploaded: () {
          if (mounted) {
            _showSnackBar('Receipt saved. Thank you.');
          }
        },
        onBlockedPopAttempt: () {
          if (!mounted) {
            return;
          }
          _showMandatoryBankReceiptRequirementSheet();
        },
        bankTransferReference: bankTransferReference,
      ),
    ));
    final d = ratingDriverId?.trim() ?? '';
    if (d.isNotEmpty && d != 'waiting' && mounted) {
      unawaited(Future<void>.microtask(() => _showRatingDialog(d)));
    }
  }

  Future<void> _runStartupPaymentAndReceiptChecks() async {
    final uid = _currentRiderUid;
    if (uid == null || uid.isEmpty || !mounted) {
      return;
    }
    if (_isCreatingRide || _isSubmittingRideRequest) {
      return;
    }

    await _reconcileStaleBankReceiptFlag(uid);

    final tripInProgress = (_currentRideId != null &&
            _currentRideId!.trim().isNotEmpty) &&
        <String>{
          'searching',
          'pending_driver_action',
          'assigned',
          'accepted',
          'arriving',
          'arrived',
          'on_trip',
        }.contains(_effectiveRideStatus);

    if (tripInProgress) {
      unawaited(_maybePromptOrphanVerifiedPrepaidIntent(uid));
      return;
    }

    try {
      final pendingReceiptSnap =
          await _usersRef.child(uid).child('pending_bank_transfer_receipt_ride_id').get();
      final pendingReceiptRide = pendingReceiptSnap.value?.toString().trim() ?? '';
      if (pendingReceiptRide.isNotEmpty && mounted) {
        final rs = await _rideRequestsRef.child(pendingReceiptRide).get();
        final data = _asStringDynamicMap(rs.value);
        if (_rideNeedsBankTransferReceipt(data)) {
          _showSnackBar(
            'Please upload your bank transfer receipt for your last trip.',
          );
          await _openBankTransferReceiptScreen(rideId: pendingReceiptRide);
          return;
        }
      }
    } catch (_) {}

    unawaited(_maybePromptOrphanVerifiedPrepaidIntent(uid));
  }

  Future<void> _maybePromptOrphanVerifiedPrepaidIntent(String uid) async {
    if (!mounted || _hostedCheckoutProcessing || _isCreatingRide) {
      return;
    }
    final txRef = await _prepaidRecoveryStore.readPendingTxRef();
    if (txRef == null || txRef.isEmpty) {
      return;
    }

    try {
      final snap =
          await rtdb.FirebaseDatabase.instance.ref('payment_transactions/$txRef').get();
      final pt = _asStringDynamicMap(snap.value);
      if (pt == null) {
        await _prepaidRecoveryStore.clearPendingTxRef();
        return;
      }
      if (_valueAsText(pt['rider_id']) != uid) {
        await _prepaidRecoveryStore.clearPendingTxRef();
        return;
      }
      if (_valueAsText(pt['intent_abandoned_at']).isNotEmpty) {
        await _prepaidRecoveryStore.clearPendingTxRef();
        return;
      }
      if (_valueAsText(pt['consumed_ride_id']).trim().isNotEmpty) {
        await _prepaidRecoveryStore.clearPendingTxRef();
        return;
      }
      if (pt['verified'] != true) {
        return;
      }
    } catch (_) {
      return;
    }

    if (!mounted) {
      return;
    }
    final action = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Finish your trip'),
        content: Text(
          'Your card payment completed, but the trip setup did not finish. '
          'Tap complete trip to continue, or discard to start over. '
          'If money left your account and you discard, save your bank receipt and contact support at $kNexRideSupportEmail.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'abandon'),
            child: const Text('Discard'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'complete'),
            child: const Text('Complete trip'),
          ),
        ],
      ),
    );

    if (action == 'complete') {
      await _completeRecoveredPrepaidRideRequest(txRef);
    } else if (action == 'abandon') {
      try {
        final res =
            await _rideCloud.abandonFlutterwaveRideIntent(reference: txRef);
        if (res['success'] == true) {
          await _prepaidRecoveryStore.clearPendingTxRef();
          if (mounted) {
            _showSnackBar(
              'Pending payment cleared. You can start a new trip when ready.',
            );
          }
        } else if (mounted) {
          _showSnackBar(
            'Could not discard that pending payment. Please contact support at $kNexRideSupportEmail.',
          );
        }
      } catch (_) {
        if (mounted) {
          _showSnackBar('Something went wrong. Please try again.');
        }
      }
    }
  }

  Future<void> _completeRecoveredPrepaidRideRequest(String txRef) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || !mounted) {
      return;
    }
    setState(() {
      _isSubmittingRideRequest = true;
      _hostedCheckoutProcessing = true;
    });
    try {
      final createRes = await _rideCloud.createRideRequest(<String, dynamic>{
        'prepaid_flutterwave_ref': txRef,
        'payment_method': 'flutterwave',
        'rider_name': _firstNonEmptyText(
          <dynamic>[
            _trustSummary['displayName'],
            _trustSummary['name'],
            user.displayName,
            user.email?.split('@').first,
          ],
          fallback: 'Rider',
        ),
      });
      if (!riderRideCallableSucceeded(createRes)) {
        if (mounted) {
          final reason = riderRideCallableReason(createRes);
          if (kDebugMode) {
            debugPrint(
              '[RiderPayment][prepaid_recovery] createRideRequest failed reason=$reason',
            );
          }
          if (!_handleRideCreateStructuredFailure(
            Map<String, dynamic>.from(createRes),
          )) {
            _showSnackBar(
              riderIdentityServerRejectionUserMessage(reason) ??
                  'We could not finish your trip request. Please try again shortly.',
            );
          }
        }
        return;
      }
      await _prepaidRecoveryStore.clearPendingTxRef();
      final rideId = _firstNonEmptyText(<dynamic>[
        createRes['rideId'],
        createRes['ride_id'],
      ]);
      if (rideId.isEmpty) {
        return;
      }
      final verifySnapshot =
          await _rideRequestsRef.child(rideId).get().timeout(
                const Duration(seconds: 18),
              );
      final parsed = _asStringDynamicMap(verifySnapshot.value);
      if (parsed == null) {
        return;
      }
      final committed = Map<String, dynamic>.from(parsed);
      await _syncRideOperationalViews(
        rideId: rideId,
        rideData: committed,
        lastEvent: 'prepaid_recovery',
      );
      _enterSearchingStateAfterCreate(rideId: rideId, rideData: committed);
      _showSnackBar(RiderTripStatusMessages.searchingForDriver);
      unawaited(
        _tripSafetyService
            .registerRideRequest(
              rideId: rideId,
              riderId: user.uid,
              serviceType: RiderServiceType.ride.key,
              ridePayload: committed,
              expectedRoutePoints: <LatLng>[],
            )
            .catchError((Object _) {}),
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[RiderPayment][prepaid_recovery] exception $e');
      }
      if (mounted) {
        _showSnackBar(
          'We could not finish your trip request. Please try again. (${e.runtimeType})',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSubmittingRideRequest = false;
          _hostedCheckoutProcessing = false;
        });
      } else {
        _isSubmittingRideRequest = false;
        _hostedCheckoutProcessing = false;
      }
    }
  }

  /// Registers bank transfer metadata and shows one reference snackbar.
  /// This is non-blocking for rider matching; creation should continue immediately.
  Future<bool> _registerBankTransferAndPoll(String rideId) async {
    final reg = await _rideCloud.registerBankTransferPayment(rideId: rideId);
    if (reg['success'] != true) {
      final reason = riderRideCallableReason(reg);
      if (kDebugMode) {
        debugPrint('[RiderPayment] registerBankTransfer failed reason=$reason');
      }
      _showSnackBar(
        'Bank transfer could not be registered (${reason.replaceAll('_', ' ')}). '
        'Please try again or pick another payment method.',
      );
      return false;
    }
    final txRef = _firstNonEmptyText(<dynamic>[reg['tx_ref'], reg['txRef']]);
    if (txRef.isEmpty) {
      _showSnackBar('Missing payment reference — try again.');
      return false;
    }
    _showSnackBar(
      'Payment reference ready: "$txRef". Transfer to NexRide official account and include this exactly in your narration.',
    );
    return true;
  }

  String? get _currentRiderUid => FirebaseAuth.instance.currentUser?.uid.trim();

  Future<void> _refreshIdentityCompliance() async {
    final uid = _currentRiderUid;
    if (uid == null || uid.isEmpty) {
      if (mounted) {
        setState(() {
          _identityComplianceLoaded = true;
          _riderFirestoreCompliance = null;
          _selfieBlocksBooking = true;
        });
      }
      return;
    }
    final snap = await RiderComplianceService.instance.fetchSnapshot(uid);
    if (!mounted) {
      return;
    }
    setState(() {
      _identityComplianceLoaded = true;
      _riderFirestoreCompliance = snap;
      _selfieBlocksBooking = snap.blocksRideBooking;
    });
  }

  Future<void> _maybePromptUpdatedTermsOnMap() async {
    final uid = _currentRiderUid;
    if (uid == null || uid.isEmpty) {
      return;
    }
    final snap = await RiderComplianceService.instance.fetchSnapshot(uid);
    if (!mounted || !snap.needsTermsAcceptance) {
      return;
    }
    await showRiderUpdatedTermsDialog(context: context, riderId: uid);
    if (mounted) {
      await _refreshIdentityCompliance();
    }
  }

  String get _currentDriverIdForRide => _firstNonEmptyText(<dynamic>[
    _driverData?['id'],
    _currentRideSnapshot?['driver_id'],
    _currentRideSnapshot?['matched_driver_id'],
  ]);

  String get _currentDriverNameForRide => _firstNonEmptyText(<dynamic>[
    _driverData?['name'],
    _currentRideSnapshot?['driver_name'],
  ], fallback: 'Driver');

  String? get _activeRideInteractionId {
    final rideId = _firstNonEmptyText(<dynamic>[
      _currentRideId,
      _riderChatListenerRideId,
      _callListenerRideId,
    ]);
    return rideId.isEmpty ? null : rideId;
  }

  bool _isRiderChatSessionActive(String rideId) {
    final normalizedRideId = rideId.trim();
    if (normalizedRideId.isEmpty) {
      return false;
    }

    return normalizedRideId == _currentRideId ||
        normalizedRideId == _riderChatListenerRideId ||
        normalizedRideId == _callListenerRideId;
  }

  String _rideChatPreview(String text, {int maxLength = 96}) {
    final trimmed = text.trim();
    if (trimmed.length <= maxLength) {
      return trimmed;
    }

    return '${trimmed.substring(0, maxLength - 1)}...';
  }

  bool get _canStartRideCall =>
      _canChat &&
      (_currentRiderUid?.isNotEmpty ?? false) &&
      _currentDriverIdForRide.isNotEmpty &&
      _currentDriverIdForRide != 'waiting';

  bool get _showRideCallButton => _canStartRideCall;

  bool get _isRideCallButtonEnabled =>
      _showRideCallButton &&
      !_isStartingVoiceCall &&
      (_currentCallSession == null || _currentCallSession!.isTerminal);

  bool get _hasRoutePreviewReady =>
      _expectedRoutePoints.length >= 2 &&
      _distanceKm > 0 &&
      _fare > 0 &&
      _routePreviewError == null;

  /// Cancel the open matching / search request (mutually exclusive with trip cancel).
  bool get _showCancelRequestOnly =>
      _isRiderRequestMatchingPhase ||
      ((_isCreatingRide || _isSubmittingRideRequest) &&
          (_pendingRideRequestSubmissionId?.isNotEmpty ?? false));

  /// Cancel after the driver has committed (trip-level cancel on primary).
  bool get _showCancelRideOnly =>
      !_isRiderRequestMatchingPhase &&
      _currentRideId != null &&
      _currentRideId!.trim().isNotEmpty &&
      <String>{
        'accepted',
        'arriving',
        'arrived',
        'on_trip',
      }.contains(_effectiveRideStatus);

  /// Cancel while preparing/writing, or after request is live but not yet matched.
  bool get _canShowCancelRequestButton => _showCancelRequestOnly;

  bool get _canShareTrip =>
      !_isRiderRequestMatchingPhase &&
      _currentRideId != null &&
      _effectiveRideStatus != 'idle' &&
      _effectiveRideStatus != 'cancelled' &&
      _effectiveRideStatus != 'driver_cancelled' &&
      _effectiveRideStatus != 'rider_cancelled' &&
      _effectiveRideStatus != 'expired' &&
      _effectiveRideStatus != 'completed';

  String get _primaryRideButtonLabel {
    if (_isCancellingRide) {
      return 'CANCELLING...';
    }
    if (_isSubmittingRideRequest || _isCreatingRide) {
      return 'REQUESTING...';
    }
    if (_showCancelRideOnly) {
      return 'CANCEL RIDE';
    }
    if (_isRiderRequestMatchingPhase) {
      return 'SEARCHING…';
    }
    if (_hasActiveRide) {
      return 'TRIP IN PROGRESS';
    }

    return 'REQUEST RIDE';
  }

  bool get _primaryRideButtonEnabled {
    return !_isSubmittingRideRequest && !_isCreatingRide;
  }

  bool get _isPrimaryRideButtonBusy =>
      _isSubmittingRideRequest || _isCreatingRide || _isCancellingRide;

  bool get _isPrimaryRideButtonPendingMatch =>
      <String>{'pending_driver_action', 'assigned'}.contains(_effectiveRideStatus);

  bool get _isPrimaryRideButtonCancelMode =>
      _isCancellingRide || _showCancelRideOnly;

  String get _currentCanonicalRideState {
    final snap = _currentRideSnapshot;
    // Empty snapshot must not imply "matching" — that mismatched `_effectiveRideStatus`
    // when the session intentionally maps stale "searching" to `idle` for UX.
    if (snap == null || snap.isEmpty) {
      return TripLifecycleState.planning;
    }
    return TripStateMachine.canonicalStateFromSnapshot(snap);
  }

  String get _effectiveRideStatus {
    final snapshot = _currentRideSnapshot;
    if (snapshot != null && snapshot.isNotEmpty) {
      return _canonicalRiderUiStatus(snapshot);
    }
    final session = _activeTripSessionService.currentSession;
    if (session != null && session.status.trim().isNotEmpty) {
      final sessionStatus = session.status.trim().toLowerCase();
      // When stale restore is ignored, treat open-pool fallback session as idle.
      if (sessionStatus == 'searching' ||
          sessionStatus == 'requested' ||
          sessionStatus == 'pending_driver_action') {
        return 'idle';
      }
      return sessionStatus;
    }
    return _rideStatus;
  }

  void _logRequestUiState() {
    final tripState = _valueAsText(_currentRideSnapshot?['trip_state']);
    final lifecycleState = _currentCanonicalRideState;
    final showRequestButton = !_hidePrimaryRideDuringMatchingOnly;
    final logLine =
        '[RIDER_REQUEST_UI_STATE] hasActiveTrip=$_hasActiveRide '
        'trip_state=${tripState.isEmpty ? 'idle' : tripState} '
        'lifecycleState=$lifecycleState showRequestButton=$showRequestButton';
    if (_lastRequestUiStateLog == logLine) {
      return;
    }
    _lastRequestUiStateLog = logLine;
    debugPrint(logLine);
  }

  Color get _rideStateAccentColor {
    return switch (_currentCanonicalRideState) {
      TripLifecycleState.searchingDriver => _gold,
      TripLifecycleState.driverAccepted => _panelSuccess,
      TripLifecycleState.driverArriving => _panelSuccess,
      TripLifecycleState.driverArrived => _panelWarning,
      TripLifecycleState.tripStarted => _panelInk,
      TripLifecycleState.tripCompleted => _panelSuccess,
      TripLifecycleState.tripCancelled => _panelDanger,
      TripLifecycleState.expired => _panelDanger,
      _ => _gold,
    };
  }

  Color get _rideStateTintColor => switch (_currentCanonicalRideState) {
    TripLifecycleState.tripStarted => const Color(0xFFF3E5CC),
    TripLifecycleState.tripCancelled => const Color(0xFFFBE8E3),
    TripLifecycleState.tripCompleted => const Color(0xFFEAF7F1),
    TripLifecycleState.driverAccepted ||
    TripLifecycleState.driverArriving => const Color(0xFFEDF8F2),
    TripLifecycleState.driverArrived => const Color(0xFFFFF1E3),
    TripLifecycleState.expired => const Color(0xFFFBE8E3),
    _ => const Color(0xFFF9F0E0),
  };

  IconData get _rideStateIcon => switch (_currentCanonicalRideState) {
    TripLifecycleState.searchingDriver => Icons.radar_rounded,
    TripLifecycleState.driverAccepted => Icons.verified_user_rounded,
    TripLifecycleState.driverArriving => Icons.local_taxi_rounded,
    TripLifecycleState.driverArrived => Icons.place_rounded,
    TripLifecycleState.tripStarted => Icons.alt_route_rounded,
    TripLifecycleState.tripCompleted => Icons.check_circle_rounded,
    TripLifecycleState.tripCancelled => Icons.do_not_disturb_on_rounded,
    _ => Icons.route_rounded,
  };

  String get _rideStateEyebrow => switch (_currentCanonicalRideState) {
    TripLifecycleState.searchingDriver => 'MATCHING YOUR RIDE',
    TripLifecycleState.driverAccepted => 'DRIVER ASSIGNED',
    TripLifecycleState.driverArriving => 'ON THE WAY',
    TripLifecycleState.driverArrived => 'DRIVER ARRIVED',
    TripLifecycleState.tripStarted => 'TRIP STARTED',
    TripLifecycleState.tripCompleted => 'TRIP COMPLETED',
    TripLifecycleState.tripCancelled => 'REQUEST CLOSED',
    TripLifecycleState.expired => 'REQUEST EXPIRED',
    _ => _hasRoutePreviewReady ? 'READY TO REQUEST' : 'PLAN YOUR RIDE',
  };

  String get _rideStateSupportText {
    if (_isSubmittingRideRequest || _isCreatingRide) {
      return RiderTripStatusMessages.creatingRide;
    }

    return switch (_currentCanonicalRideState) {
      TripLifecycleState.searchingDriver =>
        RiderTripStatusMessages.searchingForDriver,
      TripLifecycleState.driverAccepted =>
        RiderTripStatusMessages.driverAssigned,
      TripLifecycleState.driverArriving =>
        RiderTripStatusMessages.driverArriving,
      TripLifecycleState.driverArrived =>
        _waitingCharged
            ? 'Your driver is waiting at pickup and the waiting charge has started.'
            : 'Meet your driver at the pickup point to begin the trip.',
      TripLifecycleState.tripStarted =>
        'Your ride is in progress. Keep the trip open for live updates.',
      TripLifecycleState.tripCompleted =>
        'This ride is complete. You can plan another trip anytime.',
      TripLifecycleState.tripCancelled =>
        RiderTripStatusMessages.cancelled,
      TripLifecycleState.expired => RiderTripStatusMessages.cancelled,
      _ =>
        _routePreviewError != null
            ? _routePreviewError!
            : _hasRoutePreviewReady
            ? 'Your road route, distance, fare, and ETA are ready to request.'
            : _pickupLocation == null || _pickupAddress.trim().isEmpty
            ? 'Choose your pickup point to start building the trip.'
            : _orderedDropOffLocations().isEmpty ||
                  _orderedDropOffAddresses().any(
                    (String address) => address.trim().isEmpty,
                  )
            ? 'Add a destination to load the live road route, fare, and ETA.'
            : 'We are calculating the best road route and fare for this trip.',
    };
  }

  double get _primaryRideButtonOpacity => 1.0;

  Color get _primaryRideButtonBorderColor {
    if (_isPrimaryRideButtonCancelMode) {
      return _primaryRideButtonEnabled
          ? _gold.withValues(alpha: 0.82)
          : const Color(0xFF8E7C57);
    }

    return _primaryRideButtonEnabled
        ? const Color(0xFF8A6424)
        : const Color(0xFFC4A35A);
  }

  Color get _primaryRideButtonForegroundColor {
    if (_isPrimaryRideButtonCancelMode) {
      return _primaryRideButtonEnabled ? _gold : const Color(0xFFE6D8B3);
    }

    return const Color(0xFF15110B);
  }

  LinearGradient get _primaryRideButtonGradient {
    if (_isPrimaryRideButtonCancelMode) {
      return LinearGradient(
        colors: _primaryRideButtonEnabled
            ? <Color>[const Color(0xFF1F160C), const Color(0xFF342410)]
            : <Color>[const Color(0xFF5E523E), const Color(0xFF78694B)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );
    }

    if (!_primaryRideButtonEnabled) {
      return const LinearGradient(
        colors: <Color>[Color(0xFFF3E3BA), Color(0xFFE2C277)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );
    }

    return const LinearGradient(
      colors: <Color>[Color(0xFFFFE289), Color(0xFFD4AF37), Color(0xFFB8811C)],
      stops: <double>[0, 0.58, 1],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );
  }

  IconData get _primaryRideButtonIcon {
    if (_isCancellingRide) {
      return Icons.close_rounded;
    }
    if (_isSubmittingRideRequest || _isCreatingRide) {
      return Icons.local_taxi_rounded;
    }
    if (_showCancelRideOnly) {
      return Icons.close_rounded;
    }
    if (_isPrimaryRideButtonPendingMatch && _isRiderRequestMatchingPhase) {
      return Icons.pending_actions_rounded;
    }
    if (_isRiderRequestMatchingPhase) {
      return Icons.radar_rounded;
    }
    if (_hasActiveRide) {
      return Icons.check_circle_outline_rounded;
    }
    return Icons.local_taxi_rounded;
  }

  Future<RiderTrustAccessDecision?> _ensureTripRequestAllowed() async {
    final riderId = _currentRiderUid;
    if (riderId == null || riderId.isEmpty) {
      _logRideFlow(
        'REQUEST RIDE validation result canSubmit=false reason=missing_rider_session',
      );
      _showSnackBar('Please log in before requesting a ride.');
      return null;
    }

    final rules = _trustRulesConfig.isEmpty
        ? RiderTrustRulesService.defaultRules
        : Map<String, dynamic>.from(_trustRulesConfig);
    final decision = _trustRulesService.evaluateAccess(
      verification: _verification,
      riskFlags: _riskFlags,
      paymentFlags: _paymentFlags,
      rules: rules,
    );
    _logRideFlow(
      'REQUEST RIDE validation result canSubmit=${decision.canRequestTrips} '
      'restriction=${decision.restrictionCode} cashAllowed=${decision.canUseCash}',
    );
    if (_trustRulesConfig.isEmpty) {
      _logRideFlow(
        'REQUEST RIDE using default trust rules while background refresh runs',
      );
      unawaited(
        _refreshRiderTrustState().catchError((
          Object error,
          StackTrace stackTrace,
        ) {
          _logRideFlow(
            'REQUEST RIDE trust refresh fallback failed riderId=$riderId error=$error',
          );
          debugPrintStack(
            label: '[RiderRTDB] REQUEST RIDE trust refresh fallback stack',
            stackTrace: stackTrace,
          );
        }),
      );
    }
    if (!decision.canRequestTrips) {
      _showSnackBar(decision.message);
      return null;
    }
    return decision;
  }

  String _rideRequestErrorMessage(Object error) {
    if (kDebugMode && error is FirebaseFunctionsException) {
      debugPrint(
        '[RIDER_CALLABLE_TECH] code=${error.code} message=${error.message} details=${error.details}',
      );
    }
    if (isPermissionDeniedError(error)) {
      if (kDebugMode) {
        rtdbFlowLog(
          '[NEXRIDE_RIDER_RTDB][PERMISSION]',
          'ride_request_create denied raw=$error',
        );
      }
      return friendlyFirebaseError(error, debugLabel: 'rideRequest.rtdb');
    }
    if (error is TimeoutException) {
      return friendlyFirebaseError(error, debugLabel: 'rideRequest.timeout');
    }
    if (error is StateError) {
      if (error.message == 'ride_resume_snapshot_timeout') {
        return 'We could not load your active trip. Check your connection, then try again '
            'or open your trip from the home screen.';
      }
      if (error.message == 'total_mismatch' ||
          error.message == 'pricing_total_mismatch') {
        return RiderBackendPricingQuote.pricingMismatchUserMessage();
      }
      final mapped = riderIdentityServerRejectionUserMessage(error.message);
      if (mapped != null) {
        return mapped;
      }
    }
    return friendlyFirebaseError(error, debugLabel: 'rideRequest');
  }

  Future<void> _ensureRiderProfileExistsBeforeRequest(String uid) async {
    final riderUid = uid.trim();
    if (riderUid.isEmpty) {
      return;
    }
    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      final email = currentUser?.email?.trim() ?? '';
      final displayName = _firstNonEmptyText(
        <dynamic>[
          currentUser?.displayName,
          email.isNotEmpty ? email.split('@').first : '',
        ],
        fallback: 'Rider',
      );
      await _usersRef.child(riderUid).update(<String, dynamic>{
        'uid': riderUid,
        'role': 'rider',
        'displayName': displayName,
        if (email.isNotEmpty) 'email': email,
        'updated_at': rtdb.ServerValue.timestamp,
      });
      if (kDebugMode) {
        debugPrint(
          '[RIDER_PROFILE_ENSURE] ok path=users/$riderUid displayName=$displayName',
        );
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[RIDER_PROFILE_ENSURE] fail path=users/$riderUid error=$error');
      }
    }
  }

  Future<void> _logCreateRideFailureDiagnostics({
    required Object error,
    required StackTrace stackTrace,
    required Map<String, dynamic>? payload,
  }) async {
    if (!kDebugMode) {
      return;
    }
    final uid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    final paymentMethod = _riderTripPaymentMethod.trim();
    Map<String, dynamic>? activeTripPointer;
    try {
      if (uid.isNotEmpty) {
        final ptrSnap = await rtdb.FirebaseDatabase.instance
            .ref('$_riderActiveTripPointerPath/$uid')
            .get();
        activeTripPointer = _asStringDynamicMap(ptrSnap.value);
      }
    } catch (pointerError) {
      debugPrint(
        '[RIDER_CREATE_DEBUG] pointer_read_fail '
        'path=$_riderActiveTripPointerPath/$uid error=$pointerError',
      );
    }
    debugPrint(
      '[RIDER_CREATE_DEBUG] failure '
      'uid=$uid payment_method=$paymentMethod '
      'error_type=${error.runtimeType} error=$error',
    );
    debugPrint('[RIDER_CREATE_DEBUG] failure_stack=$stackTrace');
    debugPrint(
      '[RIDER_CREATE_DEBUG] failure_payload '
      'path=functions:createRideRequest payload=${payload ?? <String, dynamic>{}}',
    );
    debugPrint(
      '[RIDER_CREATE_DEBUG] active_trip_pointer '
      'path=$_riderActiveTripPointerPath/$uid value=${activeTripPointer ?? <String, dynamic>{}}',
    );
    if (error is FirebaseFunctionsException) {
      debugPrint(
        '[RIDER_CREATE_DEBUG] firebase_functions_exception '
        'code=${error.code} message=${error.message} details=${error.details}',
      );
    }
    if (error is FirebaseException) {
      debugPrint(
        '[RIDER_CREATE_DEBUG] firebase_exception '
        'plugin=${error.plugin} code=${error.code} message=${error.message}',
      );
    }
  }

  void _enterSearchingStateAfterCreate({
    required String rideId,
    required Map<String, dynamic> rideData,
  }) {
    if (mounted) {
      setState(() {
        _currentRideId = rideId;
        _pendingRideRequestSubmissionId = null;
        _currentRideSnapshot = Map<String, dynamic>.from(rideData);
        _rideStatus = 'searching';
        _searchingDriver = true;
        _riderUnreadChatCount = 0;
        _isRiderChatOpen = false;
      });
    } else {
      _currentRideId = rideId;
      _pendingRideRequestSubmissionId = null;
      _currentRideSnapshot = Map<String, dynamic>.from(rideData);
      _rideStatus = 'searching';
      _searchingDriver = true;
      _riderUnreadChatCount = 0;
      _isRiderChatOpen = false;
    }
    _logRideFlow(
      'REQUEST RIDE state transition after request rideId=$rideId status=$_rideStatus',
    );
    _logRideFlow('rider moved to searching rideId=$rideId');
    try {
      _startRiderChatListener(rideId);
      unawaited(
        _seedBankTransferInstructionIfNeeded(rideId: rideId, rideData: rideData),
      );
      _startCallListener(rideId);
      _scheduleRideSearchTimeout(
        rideId: rideId,
        rideData: rideData,
      );
      listenToRide(rideId);
      _logRideFlow('[RIDER_LISTENER_ATTACHED] rideId=$rideId');
    } catch (error, stackTrace) {
      _logRideFlow(
        'REQUEST RIDE local attach failed rideId=$rideId error=$error',
      );
      debugPrintStack(
        label: '[RiderRTDB] REQUEST RIDE local attach stack',
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _discardInFlightRideRequestSubmission({
    String? rideId,
  }) async {
    _clearRideSearchTimeout(reason: 'user_abort_before_write');
    final id = rideId?.trim() ?? '';
    if (id.isNotEmpty) {
      try {
        debugPrint('RIDER_CANCEL_START rideId=$id reason=rider_abort_before_submit');
        await _rideCloud.cancelRideRequest(
          rideId: id,
          cancelReason: 'rider_abort_before_submit',
        );
        debugPrint('RIDER_CANCEL_SUCCESS rideId=$id');
      } catch (error) {
        _logRideFlow(
          'discard submission cancel failed rideId=$id error=$error',
        );
        debugPrint('RIDER_CANCEL_FAIL rideId=$id error=$error');
      }
    }
    _pendingRideRequestSubmissionId = null;
    _rideRequestUserAborted = false;
    if (mounted) {
      setState(() {
        _rideStatus = 'idle';
        _searchingDriver = false;
        _driverFound = false;
        _tripStarted = false;
        _currentRideId = null;
        _currentRideSnapshot = null;
      });
    } else {
      _rideStatus = 'idle';
      _searchingDriver = false;
      _driverFound = false;
      _tripStarted = false;
      _currentRideId = null;
      _currentRideSnapshot = null;
    }
  }

  Future<void> _performRiderRtdbCancellationUpdate({
    required String rideId,
    required Map<String, dynamic> currentRide,
    required String transitionSource,
    required String cancelMetadataSource,
    required String cancellationReasonDisplay,
  }) async {
    debugPrint(
      'RIDER_CANCEL_START rideId=$rideId reason=$cancellationReasonDisplay',
    );
    final cancelRes = await _rideCloud
        .cancelRideRequest(
          rideId: rideId,
          cancelReason: cancellationReasonDisplay,
        )
        .timeout(const Duration(seconds: 22));
    if (!riderRideCallableSucceeded(cancelRes)) {
      final reason = riderRideCallableReason(cancelRes);
      debugPrint('RIDER_CANCEL_FAIL rideId=$rideId reason=$reason');
      if (reason == 'ride_missing' && transitionSource == 'rider_cancel') {
        await _resetRideState(clearDestination: true);
        return;
      }
      throw StateError(reason);
    }
    debugPrint('RIDER_CANCEL_SUCCESS rideId=$rideId');
    Map<String, dynamic> merged = Map<String, dynamic>.from(currentRide);
    try {
      final snap = await _rideRequestsRef.child(rideId).get();
      final live = _asStringDynamicMap(snap.value);
      if (live != null) {
        merged = live;
      }
    } catch (_) {}
    await _syncRideOperationalViews(
      rideId: rideId,
      rideData: merged,
      lastEvent: 'rider_cancel',
    );
    _logRideFlow(
      '[RIDE_LIFECYCLE] rider_cancel_rtdb rideId=$rideId source=$transitionSource '
      'cancelMeta=$cancelMetadataSource trip_state_before=${currentRide['trip_state']} '
      'status_before=${currentRide['status']}',
    );
    _logRideFlow(
      '[MATCH_DEBUG][RIDER_CANCEL_WRITE] rideId=$rideId '
      'next_status=cancelled next_trip_state=${TripLifecycleState.tripCancelled}',
    );
    await _clearStaleActiveTripArtifacts(
      rideId: rideId,
      reason: 'rider_cancel',
    );
  }

  void _setSubmittingRideRequest(bool value) {
    if (_isSubmittingRideRequest == value) {
      return;
    }

    if (mounted) {
      setState(() {
        _isSubmittingRideRequest = value;
      });
      return;
    }

    _isSubmittingRideRequest = value;
  }

  Future<void> _refreshRiderTrustState({bool persist = false}) async {
    final riderId = _currentRiderUid;
    if (riderId == null || riderId.isEmpty) {
      return;
    }
    if (kDebugMode) {
      debugPrint(
        '[RIDER_PROFILE_LOAD] start riderId=$riderId persist=$persist path=users/$riderId',
      );
    }

    try {
      final userSnapshot = await runOptionalStartupRead<rtdb.DataSnapshot>(
        source: 'map_screen.user_profile',
        path: 'users/$riderId',
        action: () => _usersRef.child(riderId).get(),
      );
      final existingUser = userSnapshot?.value is Map
          ? Map<String, dynamic>.from(userSnapshot!.value as Map)
          : <String, dynamic>{};
      if (kDebugMode) {
        debugPrint(
          '[RIDER_PROFILE_LOAD] snapshot_exists=${existingUser.isNotEmpty} riderId=$riderId',
        );
      }
      final storedLaunchCity = _normalizeServiceCity(
        existingUser['launch_market_city'] ??
            existingUser['launchMarket'] ??
            existingUser['launch_market'] ??
            existingUser['selectedCity'],
      );
      final preferredLaunchCity =
          storedLaunchCity ??
          _normalizeServiceCity(_selectedLaunchCity) ??
          _defaultTestRiderCity;
      final hasStoredLaunchCity = storedLaunchCity != null;
      final bundle = await _bootstrapService.ensureRiderTrustState(
        riderId: riderId,
        existingUser: existingUser,
        fallbackName: FirebaseAuth.instance.currentUser?.email
            ?.split('@')
            .first,
        fallbackEmail: FirebaseAuth.instance.currentUser?.email,
      );
      final rules = await _trustRulesService.fetchRules();

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
          source: 'map_screen.bootstrap_write',
        );
      }

      if (!mounted) {
        _selectedLaunchCity = preferredLaunchCity;
        _launchCityChosenManually = hasStoredLaunchCity;
        if (!_deviceLocationAvailable || _deviceLocationOutsideLaunchArea) {
          _riderLocation = _fallbackBrowseLocation;
        }
        _verification = bundle.verification;
        _riskFlags = bundle.riskFlags;
        _paymentFlags = bundle.paymentFlags;
        _reputation = bundle.reputation;
        _trustSummary = bundle.trustSummary;
        _trustRulesConfig = rules;
        return;
      }

      setState(() {
        _selectedLaunchCity = preferredLaunchCity;
        _launchCityChosenManually = hasStoredLaunchCity;
        if (!_deviceLocationAvailable || _deviceLocationOutsideLaunchArea) {
          _riderLocation = _fallbackBrowseLocation;
        }
        _verification = bundle.verification;
        _riskFlags = bundle.riskFlags;
        _paymentFlags = bundle.paymentFlags;
        _reputation = bundle.reputation;
        _trustSummary = bundle.trustSummary;
        _trustRulesConfig = rules;
      });
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('[RIDER_PROFILE_LOAD] fail riderId=$riderId error=$error');
      }
      _logRideFlow('trust refresh failed riderId=$riderId error=$error');
      debugPrintStack(
        label: '[RiderTrust] refresh stack',
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _maybeLogTelemetryCheckpoint(
    String rideId,
    Map<String, dynamic> rideData,
    LatLng driverPosition,
  ) async {
    if (!_rideTrackingStatuses.contains(_rideStatus)) {
      return;
    }

    final now = DateTime.now();
    if (_lastTelemetryCheckpointPosition != null &&
        _lastTelemetryCheckpointAt != null) {
      final distanceSinceLast = Geolocator.distanceBetween(
        _lastTelemetryCheckpointPosition!.latitude,
        _lastTelemetryCheckpointPosition!.longitude,
        driverPosition.latitude,
        driverPosition.longitude,
      );
      final secondsSinceLast = now
          .difference(_lastTelemetryCheckpointAt!)
          .inSeconds;
      if (distanceSinceLast < _telemetryCheckpointMinDistanceMeters &&
          secondsSinceLast < _telemetryCheckpointMinSeconds) {
        return;
      }
    }

    _lastTelemetryCheckpointPosition = driverPosition;
    _lastTelemetryCheckpointAt = now;
    await _tripSafetyService.logCheckpoint(
      rideId: rideId,
      riderId: _currentRiderUid ?? '',
      driverId: rideData['driver_id']?.toString() ?? '',
      serviceType:
          rideData['service_type']?.toString() ?? RiderServiceType.ride.key,
      status: _rideStatus,
      position: driverPosition,
      source: 'rider_map',
    );
  }

  @override
  void initState() {
    super.initState();
    debugPrint('[RideType] MapScreen initState');
    _riderAuthRolloutSubscription =
        FirebaseAuth.instance.authStateChanges().listen((User? user) {
      if (user == null || user.uid.trim().isEmpty) {
        return;
      }
      unawaited(_loadRolloutCatalogForRider());
    });
    WidgetsBinding.instance.addObserver(this);
    _riderLocation = _selectedLaunchCityCenter;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _prepareBrowseLocationContext();
      unawaited(_loadRolloutCatalogForRider());
      if (mounted) {
        await _refreshRiderTrustState(persist: true);
      }
      await _refreshIdentityCompliance();
      if (mounted) {
        await _maybePromptUpdatedTermsOnMap();
      }
    });
    _loadDrivers();
    _startIncomingCallListener();
    unawaited(_resyncIncomingCallState());
    unawaited(_restoreActiveRideIfAny());
    unawaited(
      _activeTripSessionService.restoreActiveTripForCurrentUser(
        source: 'map_screen.init',
      ),
    );
    _ensureRiderActiveRidePointerListener();
    unawaited(RiderPushNotificationService.instance.registerCurrentUserToken());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_runStartupPaymentAndReceiptChecks());
    });

    final deepLinkRideId = widget.initialOpenRideId?.trim() ?? '';
    if (deepLinkRideId.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        if (!mounted) {
          return;
        }
        listenToRide(deepLinkRideId);
      });
    }
  }

  int _rideActivityTimestamp(Map<String, dynamic> rideData) {
    for (final key in <String>['updated_at', 'accepted_at', 'created_at']) {
      final timestamp = _asInt(rideData[key]);
      if (timestamp != null && timestamp > 0) {
        return timestamp;
      }
    }

    return 0;
  }

  bool _shouldIgnoreStaleSearchingRestore(
    Map<String, dynamic> rideData, {
    required String status,
    required String canonicalState,
  }) {
    if (status != 'searching' &&
        status != 'requested' &&
        canonicalState != TripLifecycleState.searchingDriver &&
        canonicalState != TripLifecycleState.requested) {
      return false;
    }
    final assignedDriver = _valueAsText(rideData['driver_id']);
    if (assignedDriver.isNotEmpty &&
        assignedDriver.toLowerCase() != 'waiting') {
      return false;
    }
    final ts = _rideActivityTimestamp(rideData);
    if (ts <= 0) {
      return false;
    }
    final ageMs = DateTime.now().millisecondsSinceEpoch - ts;
    return ageMs > _staleSearchingRestoreTimeout.inMilliseconds;
  }

  void _setStartingVoiceCall(bool value) {
    if (_isStartingVoiceCall == value) {
      return;
    }

    if (mounted) {
      setState(() {
        _isStartingVoiceCall = value;
      });
      return;
    }

    _isStartingVoiceCall = value;
  }

  void _ensureRiderActiveRidePointerListener() {
    _riderActiveRidePointerSubscription?.cancel();
    _riderActiveRidePointerSubscription = null;
    final uid = _currentRiderUid?.trim() ?? '';
    if (uid.isEmpty) {
      return;
    }
    final ref = rtdb.FirebaseDatabase.instance.ref('rider_active_trip/$uid');
    _riderActiveRidePointerSubscription = ref.onValue.listen((event) {
      unawaited(_handleRiderActiveRidePointerEvent(event));
    });
  }

  Future<void> _handleRiderActiveRidePointerEvent(rtdb.DatabaseEvent event) async {
    final uid = _currentRiderUid?.trim() ?? '';
    if (uid.isEmpty) {
      return;
    }
    final raw = event.snapshot.value;
    if (raw is! Map) {
      debugPrint('RIDER_ACTIVE_POINTER_UPDATE uid=$uid rideId=(cleared)');
      if (_recoverableActiveRideId != null && _currentRideId == null && mounted) {
        setState(() {
          _recoverableActiveRideId = null;
        });
      } else {
        _recoverableActiveRideId = null;
      }
      return;
    }
    final m = Map<String, dynamic>.from(raw);
    final ptrRideId = _firstNonEmptyText(<dynamic>[
      m['ride_id'],
      m['rideId'],
    ]);
    final phase = _valueAsText(m['phase']);
    debugPrint(
      'RIDER_ACTIVE_POINTER_UPDATE uid=$uid rideId=$ptrRideId phase=$phase',
    );
    if (ptrRideId.isEmpty) {
      if (_recoverableActiveRideId != null && _currentRideId == null && mounted) {
        setState(() {
          _recoverableActiveRideId = null;
        });
      } else {
        _recoverableActiveRideId = null;
      }
      return;
    }
    if (_currentRideId == null && _recoverableActiveRideId != ptrRideId) {
      if (mounted) {
        setState(() {
          _recoverableActiveRideId = ptrRideId;
        });
      } else {
        _recoverableActiveRideId = ptrRideId;
      }
    }
    if (ptrRideId == _activeRideListenerRideId && _rideListener != null) {
      return;
    }
    listenToRide(ptrRideId);
  }

  Future<void> _restoreActiveRideIfAny() async {
    final riderUid = _currentRiderUid;
    if (riderUid == null || riderUid.isEmpty || _currentRideId != null) {
      return;
    }

    try {
      final snapshot = await runOptionalStartupRead<rtdb.DataSnapshot>(
        source: 'map_screen.restore_active_ride',
        path: 'ride_requests[orderByChild=rider_id,equalTo=$riderUid]',
        action: () =>
            _rideRequestsRef.orderByChild('rider_id').equalTo(riderUid).get(),
      );
      if (!mounted ||
          _currentRideId != null ||
          _isSubmittingRideRequest ||
          _isCreatingRide) {
        return;
      }

      Map<String, dynamic>? rides = _asStringDynamicMap(snapshot?.value);
      final ptrSnap = await runOptionalStartupRead<rtdb.DataSnapshot>(
        source: 'map_screen.rider_active_trip_pointer',
        path: 'rider_active_trip/$riderUid',
        action: () => rtdb.FirebaseDatabase.instance
            .ref('rider_active_trip/$riderUid')
            .get(),
      );
      final ptrMap = _asStringDynamicMap(ptrSnap?.value);
      final pointerRideId = _firstNonEmptyText(<dynamic>[
        ptrMap?['ride_id'],
        ptrMap?['rideId'],
      ]);
      if (pointerRideId.isNotEmpty) {
        final directSnap = await _rideRequestsRef.child(pointerRideId).get();
        final directData = _asStringDynamicMap(directSnap.value);
        if (directData != null) {
          rides ??= <String, dynamic>{};
          rides[pointerRideId] = directData;
          _logRideFlow(
          'active ride restore merged rider_active_trip pointer rideId=$pointerRideId',
          );
        }
      }
      if (pointerRideId.isNotEmpty) {
        final pointerRideMap = _asStringDynamicMap(rides?[pointerRideId]);
        if (pointerRideMap == null) {
          _logRideFlow(
            'ACTIVE_TRIP_STALE source=startup rideId=$pointerRideId reason=pointer_missing_ride_map',
          );
          await _clearStaleActiveTripArtifacts(
            rideId: pointerRideId,
            reason: 'startup_pointer_missing_ride_map',
          );
        } else {
          final pointerStatus =
              TripStateMachine.uiStatusFromSnapshot(pointerRideMap);
          _logRideFlow(
            'ACTIVE_TRIP_FOUND source=startup rideId=$pointerRideId status=$pointerStatus',
          );
          if (!_isStatusBlockingRideCreation(pointerStatus)) {
            _logRideFlow(
              'ACTIVE_TRIP_STALE source=startup rideId=$pointerRideId status=$pointerStatus reason=non_blocking_pointer_status',
            );
            await _clearStaleActiveTripArtifacts(
              rideId: pointerRideId,
              reason: 'startup_pointer_non_blocking_status_$pointerStatus',
            );
            rides?.remove(pointerRideId);
          } else {
            _logRideFlow(
              'ACTIVE_TRIP_RECOVERED source=startup rideId=$pointerRideId status=$pointerStatus',
            );
          }
        }
      }
      if (rides == null) {
        _logRideFlow('active ride restore found no rides riderId=$riderUid');
        if (_rideStatus != 'idle' ||
            _effectiveRideStatus != 'idle' ||
            _searchingDriver ||
            _driverFound ||
            _tripStarted) {
          await _resetRideState(clearDestination: false);
        }
        _recoverableActiveRideId = null;
        return;
      }

      String? restoredRideId;
      Map<String, dynamic>? restoredRideData;
      var restoredRideTimestamp = -1;

      rides.forEach((rideId, rawRideData) {
        final rideData = _asStringDynamicMap(rawRideData);
        if (rideData == null) {
          return;
        }

        final canonicalState = TripStateMachine.canonicalStateFromSnapshot(
          rideData,
        );
        final status = TripStateMachine.uiStatusFromSnapshot(rideData);
        if (!_isStatusBlockingRideCreation(status)) {
          unawaited(
            _clearStaleActiveTripArtifacts(
              rideId: rideId,
              reason: 'startup_recovery_non_blocking_$status',
            ),
          );
          return;
        }
        if (!_restorableRideStatuses.contains(status) ||
            !TripStateMachine.isRestorable(canonicalState)) {
          return;
        }
        if (_shouldIgnoreStaleSearchingRestore(
          rideData,
          status: status,
          canonicalState: canonicalState,
        )) {
          _logRideFlow(
            'active ride restore ignoring stale searching ride rideId=$rideId '
            'status=$status canonical=$canonicalState',
          );
          return;
        }

        final activityTimestamp = _rideActivityTimestamp(rideData);
        if (activityTimestamp <= 0) {
          return;
        }
        if ((canonicalState == TripLifecycleState.searchingDriver ||
                canonicalState == TripLifecycleState.pendingDriverAction) &&
            _rideSearchTimeoutAt(rideData) <= 0) {
          return;
        }

        if (restoredRideData == null ||
            activityTimestamp >= restoredRideTimestamp) {
          restoredRideId = rideId;
          restoredRideData = Map<String, dynamic>.from(rideData);
          restoredRideTimestamp = activityTimestamp;
        }
      });

      final rideId = restoredRideId;
      final rideData = restoredRideData;
      if (rideId == null || rideData == null) {
        _logRideFlow(
          'active ride restore found no active ride riderId=$riderUid',
        );
        if (_rideStatus != 'idle' ||
            _effectiveRideStatus != 'idle' ||
            _searchingDriver ||
            _driverFound ||
            _tripStarted) {
          await _resetRideState(clearDestination: false);
        }
        _recoverableActiveRideId = null;
        return;
      }

      if (_rideHasTimedOut(rideData) &&
          TripStateMachine.uiStatusFromSnapshot(rideData) == 'searching') {
        await _markRideNoDriversAvailable(rideId: rideId, rideData: rideData);
        return;
      }

      if (await _releaseExpiredAssignedRideIfNeeded(
        rideId: rideId,
        rideData: rideData,
        source: 'restore',
      )) {
        await _restoreActiveRideIfAny();
        return;
      }

      if (await _autoCancelRideForLifecycleTimeoutIfNeeded(
        rideId: rideId,
        rideData: rideData,
        source: 'restore',
      )) {
        return;
      }

      final decision = await _resolveVisibleRideStatus(
        rideId: rideId,
        rideData: rideData,
        source: 'restore',
      );
      final visibleRideData = _sanitizedRideSnapshotForDecision(
        rideData: rideData,
        decision: decision,
      );
      final status = decision.status;
      _logRideFlow(
        'restoring active ride rideId=$rideId rawStatus=${_valueAsText(rideData["status"])} visibleStatus=$status',
      );

      setState(() {
        _currentRideId = rideId;
        _recoverableActiveRideId = null;
        _currentRideSnapshot = visibleRideData;
        _rideStatus = status;
        _driverData = decision.driverData;
        _riderUnreadChatCount = 0;
        _isRiderChatOpen = false;
        _applyRideStatus(status);
      });
      await _activeTripSessionService.attachToRide(
        rideId,
        seedData: visibleRideData,
        source: 'map_screen.restore',
      );

      if (status == 'searching') {
        _scheduleRideSearchTimeout(rideId: rideId, rideData: rideData);
      } else {
        _clearRideSearchTimeout(reason: 'restore_non_searching');
      }

      _startRiderChatListener(rideId);
      _startCallListener(rideId);
      listenToRide(rideId);
    } catch (error) {
      _logRideFlow('active ride restore failed riderId=$riderUid error=$error');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _rideSearchTimeoutTimer?.cancel();
    _callDurationTimer?.cancel();
    _callRingTimeoutTimer?.cancel();
    _rideListener?.cancel();
    _riderAuthRolloutSubscription?.cancel();
    _riderActiveRidePointerSubscription?.cancel();
    _driversSubscription?.cancel();
    _stopRiderChatListener();
    _callSubscription?.cancel();
    _incomingCallSubscription?.cancel();
    _incomingCallListenerUid = null;
    _removeCallOverlayEntry();
    _alertSoundService.dispose();
    unawaited(_callService.dispose());
    _pickupController.dispose();
    _destinationController.dispose();
    for (final controller in _additionalStopControllers) {
      controller.dispose();
    }
    _riderChatMessages.dispose();
    _mapLayerVersion.dispose();
    _mapController?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appLifecycleState = state;

    if (state != AppLifecycleState.resumed) {
      unawaited(_handleCallAppBackgrounded());
      return;
    }

    unawaited(_refreshIdentityCompliance());

    _startIncomingCallListener();
    unawaited(_resyncIncomingCallState());
    unawaited(_syncCallForegroundState(foreground: true));
    unawaited(_runStartupPaymentAndReceiptChecks());

    final rideId = _activeRideInteractionId;
    if (rideId == null || rideId.isEmpty) {
      _logRideFlow('[RIDER_NAV_RESUME_ACTIVE_TRIP] source=map_screen action=restore');
      unawaited(
        _activeTripSessionService.restoreActiveTripForCurrentUser(
          source: 'map_screen.resume',
        ),
      );
      unawaited(_restoreActiveRideIfAny());
      return;
    }

    _startRiderChatListener(rideId);
    listenToRide(rideId);
    if (_callListenerRideId != rideId || _callSubscription == null) {
      _startCallListener(rideId);
      return;
    }

    unawaited(_resyncCallState(rideId));
  }

  String _normalizedRideStatus(String status) {
    final normalized = status.trim().toLowerCase();
    if (normalized == 'ontrip' ||
        normalized == 'in_progress' ||
        normalized == 'trip_started') {
      return 'on_trip';
    }
    if (normalized == 'driver_arriving' || normalized == 'heading_to_pickup') {
      return 'arriving';
    }
    if (normalized == 'driver_assigned' ||
        normalized == 'assigned' ||
        normalized == 'matched' ||
        normalized == 'pending_driver_acceptance' ||
        normalized == 'pending_driver_action') {
      return 'pending_driver_action';
    }
    if (normalized == 'driver_accepted') {
      return 'accepted';
    }
    if (normalized == 'driver_arrived') {
      return 'arrived';
    }
    if (normalized == 'trip_completed') {
      return 'completed';
    }
    if (normalized == 'trip_cancelled' || normalized == 'canceled') {
      return 'cancelled';
    }
    return normalized;
  }

  String? _normalizeServiceCity(dynamic city) {
    return RiderLaunchScope.normalizeSupportedCity(city?.toString());
  }

  String? _normalizeServiceArea(dynamic area, {String? city}) {
    return RiderLaunchScope.normalizeSupportedArea(
      area?.toString(),
      city: city,
    );
  }

  Future<void> _selectLaunchCity(
    String city, {
    bool manual = true,
    bool persist = true,
    bool moveCamera = true,
  }) async {
    final normalizedCity = _normalizeServiceCity(city) ?? _selectedLaunchCity;
    if (!mounted) {
      _selectedLaunchCity = normalizedCity;
      _launchCityChosenManually = manual;
    } else {
      setState(() {
        _selectedLaunchCity = normalizedCity;
        _launchCityChosenManually = manual;
      });
    }

    if (moveCamera &&
        !_hasActiveRide &&
        (_pickupLocation == null || _deviceLocationOutsideLaunchArea)) {
      final center = _selectedLaunchCityCenter;
      _riderLocation = center;
      unawaited(_moveCameraToSelectedPoint(center));
    }

    _loadDrivers();

    if (!persist) {
      return;
    }

    final riderId = _currentRiderUid;
    if (riderId == null || riderId.isEmpty) {
      return;
    }

    try {
      await _usersRef.child(riderId).update(<String, dynamic>{
        'launch_market_city': normalizedCity,
        'launch_market_country': RiderLaunchScope.countryName,
        'market_pool': normalizedCity,
        'launch_market_updated_at': rtdb.ServerValue.timestamp,
      });
      debugPrint(
        '[NEXRIDE_RIDER_LOCATION] persisted launch_market_city=$normalizedCity market_pool=$normalizedCity',
      );
    } catch (error) {
      _logRideFlow(
        'launch market persist failed riderId=$riderId city=$normalizedCity error=$error',
      );
    }
  }

  Future<String?> _resolveServiceCityCandidate({
    String? addressHint,
    LatLng? point,
  }) async {
    final addressMatch = _normalizeServiceCity(addressHint);
    if (addressMatch != null) {
      return addressMatch;
    }

    if (point != null) {
      return _resolveLaunchCityFromPoint(point);
    }

    return null;
  }

  Future<void> _syncLaunchCityFromSelection({
    required String source,
    String? addressHint,
    LatLng? point,
  }) async {
    final resolvedCity = await _resolveServiceCityCandidate(
      addressHint: addressHint,
      point: point,
    );
    if (resolvedCity == null || resolvedCity == _selectedLaunchCity) {
      return;
    }

    await _selectLaunchCity(
      resolvedCity,
      manual: true,
      persist: true,
      moveCamera: false,
    );
    _logRideFlow('launch city synced source=$source city=$resolvedCity');
  }

  Future<String?> _resolveLaunchCityFromPoint(LatLng point) async {
    try {
      final placemarks = await placemarkFromCoordinates(
        point.latitude,
        point.longitude,
      );

      for (final placemark in placemarks) {
        final city = _normalizeServiceCity(
          placemark.locality ??
              placemark.subAdministrativeArea ??
              placemark.administrativeArea,
        );
        if (city != null) {
          return city;
        }
      }
    } catch (error) {
      _logRideFlow(
        'launch city reverse-geocode failed point=${_formatLatLng(point)} error=$error',
      );
    }

    return null;
  }

  String _serviceAreaFromCandidates({
    required String city,
    required Iterable<String?> candidates,
  }) {
    for (final candidate in candidates) {
      final normalized = _normalizeServiceArea(candidate, city: city);
      if (normalized != null && normalized.isNotEmpty) {
        return normalized;
      }
    }
    return '';
  }

  // Retained for future callable-only metadata enrichment; previously used by
  // removed client-side ride_requests patch path.
  // ignore: unused_element
  Future<String> _resolveServiceAreaFromPoint(
    LatLng point, {
    required String city,
    String? addressHint,
    Iterable<String?> additionalHints = const <String?>[],
  }) async {
    final normalizedCity = _normalizeServiceCity(city) ?? _selectedLaunchCity;
    final directMatch = _serviceAreaFromCandidates(
      city: normalizedCity,
      candidates: <String?>[addressHint, ...additionalHints],
    );
    if (directMatch.isNotEmpty) {
      return directMatch;
    }

    try {
      final placemarks = await placemarkFromCoordinates(
        point.latitude,
        point.longitude,
      );
      for (final placemark in placemarks) {
        final placemarkMatch = _serviceAreaFromCandidates(
          city: normalizedCity,
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
        if (placemarkMatch.isNotEmpty) {
          return placemarkMatch;
        }
      }
    } catch (error) {
      _logRideFlow(
        'service area resolution failed city=$normalizedCity point=${_formatLatLng(point)} error=$error',
      );
    }

    return '';
  }

  Map<String, String> _buildServiceAreaFields({
    required String city,
    String? area,
  }) {
    return RiderLaunchScope.buildServiceAreaFields(city: city, area: area);
  }

  double? _asDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }

    if (value is String) {
      return double.tryParse(value);
    }

    return null;
  }

  int? _asInt(dynamic value) {
    if (value is int) {
      return value;
    }

    if (value is num) {
      return value.toInt();
    }

    if (value is String) {
      return int.tryParse(value);
    }

    return null;
  }

  bool _asBool(dynamic value) {
    if (value is bool) {
      return value;
    }

    final normalized = value?.toString().trim().toLowerCase();
    return normalized == 'true' || normalized == '1' || normalized == 'yes';
  }

  Map<String, dynamic>? _asStringDynamicMap(dynamic value) {
    if (value is! Map) {
      return null;
    }

    return value.map<String, dynamic>(
      (key, nestedValue) => MapEntry(key.toString(), nestedValue),
    );
  }

  String _valueAsText(dynamic value) {
    return value?.toString().trim() ?? '';
  }

  String _firstNonEmptyText(List<dynamic> candidates, {String fallback = ''}) {
    for (final candidate in candidates) {
      final text = candidate?.toString().trim() ?? '';
      if (text.isNotEmpty) {
        return text;
      }
    }

    return fallback;
  }

  void _notifyMapLayerChanged() {
    if (!mounted) {
      return;
    }

    _mapLayerVersion.value += 1;
  }

  void _scheduleIosMapStabilization({required GoogleMapController controller}) {
    final refreshGeneration = ++_mapRenderRefreshGeneration;
    _iosMapCameraIdleObserved = false;

    Future<void>.delayed(const Duration(milliseconds: 250), () {
      if (!mounted ||
          _mapController != controller ||
          refreshGeneration != _mapRenderRefreshGeneration) {
        return;
      }

      _logRiderMap(
        'map refresh applied platform=ios city=$_selectedLaunchCity markers=${_markers.length} polylines=${_polylines.length}',
      );
      _notifyMapLayerChanged();
      _moveCamera();
      unawaited(_nudgeIosMapTiles(controller, reason: 'ios_post_create'));
    });

    Future<void>.delayed(const Duration(milliseconds: 900), () {
      if (!mounted ||
          _mapController != controller ||
          refreshGeneration != _mapRenderRefreshGeneration) {
        return;
      }

      _logRiderMap(
        'map follow-up refresh platform=ios city=$_selectedLaunchCity markers=${_markers.length} polylines=${_polylines.length}',
      );
      _notifyMapLayerChanged();
      _moveCamera();
      unawaited(_nudgeIosMapTiles(controller, reason: 'ios_follow_up'));
    });
  }

  void _scheduleIosMapTileRecovery({required GoogleMapController controller}) {
    Future<void> runRecovery(int delayMs, String phase) async {
      await Future<void>.delayed(Duration(milliseconds: delayMs));
      if (!mounted || _mapController != controller) {
        return;
      }
      if (_iosMapCameraIdleObserved) {
        return;
      }
      _iosMapTileRecoveryCount += 1;
      _logRiderMap(
        'ios map tile recovery started phase=$phase recovery=$_iosMapTileRecoveryCount city=$_selectedLaunchCity',
      );
      _notifyMapLayerChanged();
      _moveCamera();
      await _nudgeIosMapTiles(controller, reason: 'ios_tile_recovery_$phase');
      _logRiderMap(
        'ios map tile recovery applied phase=$phase recovery=$_iosMapTileRecoveryCount',
      );
    }

    unawaited(runRecovery(1200, 't1'));
    unawaited(runRecovery(2600, 't2'));
    unawaited(runRecovery(4200, 't3'));
  }

  Future<void> _nudgeIosMapTiles(
    GoogleMapController controller, {
    required String reason,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.iOS ||
        _mapController != controller) {
      return;
    }

    final dropOffs = _orderedDropOffLocations();
    final target = _tripStarted && _lastDriverLocation != null
        ? _lastDriverLocation!
        : _pickupLocation ??
              (dropOffs.isNotEmpty
                  ? dropOffs.last
                  : _deviceLocationAvailable
                  ? _riderLocation
                  : _selectedLaunchCityCenter);
    final baseZoom = _pickupLocation == null && dropOffs.isEmpty
        ? RiderServiceAreaConfig.defaultMapZoom
        : 15.0;

    try {
      await controller.animateCamera(
        CameraUpdate.newLatLngZoom(target, baseZoom + 0.2),
      );
      await controller.animateCamera(
        CameraUpdate.newLatLngZoom(target, baseZoom),
      );
      _logRiderMap(
        'map tile nudge applied platform=ios reason=$reason target=${_formatLatLng(target)}',
      );
    } catch (error) {
      _logRiderMap(
        'map tile nudge skipped platform=ios reason=$reason error=$error',
      );
    }
  }

  String _formatLatLng(LatLng? point) {
    if (point == null) {
      return 'null';
    }

    return '(${point.latitude}, ${point.longitude})';
  }

  bool _callMatchesCurrentRide(RideCallSession session) {
    final riderUid = _currentRiderUid;
    final driverId = _currentDriverIdForRide;
    if (riderUid == null || riderUid.isEmpty) {
      return false;
    }

    final currentRideId = _activeRideInteractionId;
    if (currentRideId != null &&
        currentRideId.isNotEmpty &&
        session.rideId != currentRideId) {
      return false;
    }

    final participantIds = <String>{session.callerId, session.receiverId};
    if (!participantIds.contains(riderUid)) {
      return false;
    }

    if (driverId.isEmpty || driverId == 'waiting') {
      return true;
    }

    return participantIds.contains(driverId);
  }

  bool _isIncomingCall(RideCallSession session) {
    final riderUid = _currentRiderUid;
    return riderUid != null &&
        riderUid.isNotEmpty &&
        session.isRinging &&
        session.receiverId == riderUid;
  }

  bool _isOutgoingCall(RideCallSession session) {
    final riderUid = _currentRiderUid;
    return riderUid != null &&
        riderUid.isNotEmpty &&
        session.isRinging &&
        session.callerId == riderUid;
  }

  String _formatCallDuration(Duration duration) {
    final totalSeconds = duration.inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;

    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }

    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Future<bool> _ensureMicrophonePermission({
    required String actionLabel,
  }) async {
    final result = await _callPermissions.requestMicrophonePermission();
    if (result.isGranted) {
      return true;
    }

    if (!mounted) {
      return false;
    }

    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result.shouldOpenSettings
              ? 'Microphone access is blocked. Enable it in Settings to $actionLabel.'
              : 'Microphone access is required to $actionLabel.',
        ),
        action: result.shouldOpenSettings
            ? SnackBarAction(
                label: 'SETTINGS',
                onPressed: () {
                  unawaited(_callPermissions.openSettings());
                },
              )
            : null,
      ),
    );
    return false;
  }

  void _startIncomingCallListener() {
    final riderUid = _currentRiderUid;
    if (riderUid == null || riderUid.isEmpty) {
      _incomingCallSubscription?.cancel();
      _incomingCallSubscription = null;
      _incomingCallListenerUid = null;
      return;
    }

    if (_incomingCallSubscription != null &&
        _incomingCallListenerUid == riderUid) {
      return;
    }

    _incomingCallSubscription?.cancel();
    _incomingCallSubscription = null;
    _incomingCallListenerUid = riderUid;

    _incomingCallSubscription = _callService
        .observeCallsForReceiver(riderUid)
        .listen(
          (event) {
            final nextSession = _pickIncomingCallForRider(
              RideCallSession.listFromCollectionValue(event.snapshot.value),
            );

            if (nextSession == null) {
              final session = _currentCallSession;
              if (session != null && _isIncomingCall(session)) {
                unawaited(_resyncCallState(session.rideId));
              }
              return;
            }

            _startCallListener(nextSession.rideId);
            unawaited(
              _handleCallSnapshotUpdate(nextSession.rideId, nextSession),
            );
          },
          onError: (Object error) {
            _logRideCall(
              'incoming listener error riderId=$riderUid error=$error',
            );
          },
        );
  }

  Future<void> _resyncIncomingCallState() async {
    final riderUid = _currentRiderUid;
    if (riderUid == null || riderUid.isEmpty) {
      return;
    }

    final sessions = await _callService.fetchCallsForReceiver(riderUid);
    if (!mounted) {
      return;
    }

    final nextSession = _pickIncomingCallForRider(sessions);
    if (nextSession == null) {
      final session = _currentCallSession;
      if (session != null && _isIncomingCall(session)) {
        await _resyncCallState(session.rideId);
      }
      return;
    }

    _startCallListener(nextSession.rideId);
    await _handleCallSnapshotUpdate(nextSession.rideId, nextSession);
  }

  RideCallSession? _pickIncomingCallForRider(List<RideCallSession> sessions) {
    final riderUid = _currentRiderUid;
    if (riderUid == null || riderUid.isEmpty) {
      return null;
    }

    final activeRideId = _activeRideInteractionId;
    RideCallSession? fallback;

    for (final session in sessions) {
      if (session.receiverId != riderUid) {
        continue;
      }
      if (!session.isRinging && !session.isAccepted) {
        continue;
      }
      if (activeRideId != null &&
          activeRideId.isNotEmpty &&
          session.rideId == activeRideId) {
        return session;
      }
      fallback ??= session;
    }

    return activeRideId == null || activeRideId.isEmpty ? fallback : null;
  }

  void _startCallListener(String rideId) {
    if (_callListenerRideId == rideId && _callSubscription != null) {
      return;
    }

    _callSubscription?.cancel();
    _callSubscription = null;
    _callListenerRideId = rideId;

    _callSubscription = _callService
        .observeCall(rideId)
        .listen(
          (event) {
            if (_callListenerRideId != rideId) {
              return;
            }

            final session = RideCallSession.fromSnapshotValue(
              rideId,
              event.snapshot.value,
            );
            unawaited(_handleCallSnapshotUpdate(rideId, session));
          },
          onError: (Object error) {
            _logRideCall('listener error rideId=$rideId error=$error');
          },
        );
  }

  Future<void> _resyncCallState(String rideId) async {
    final session = await _callService.fetchCall(rideId);
    if (!mounted || _callListenerRideId != rideId) {
      return;
    }

    await _handleCallSnapshotUpdate(rideId, session);
  }

  Future<void> _handleCallSnapshotUpdate(
    String rideId,
    RideCallSession? nextSession,
  ) async {
    final previousSession = _currentCallSession;
    final previousStatus = previousSession?.status;

    if (nextSession != null && !_callMatchesCurrentRide(nextSession)) {
      return;
    }

    _currentCallSession = nextSession;

    if (nextSession == null) {
      await _performLocalCallCleanup(rideId: rideId, logCleanup: false);
      return;
    }

    if (nextSession.isRinging) {
      _scheduleCallRingTimeout(nextSession);
      _stopCallDurationTicker();
      _callAcceptedAt = null;
      _callDuration = Duration.zero;
      unawaited(
        _syncCallForegroundState(
          foreground: _appLifecycleState == AppLifecycleState.resumed,
        ),
      );

      if (_isIncomingCall(nextSession) &&
          previousStatus != RideCallStatus.ringing) {
        _logRideCall(
          'incoming call shown rideId=$rideId caller=${nextSession.callerUid}',
        );
      }

      if (_isIncomingCall(nextSession)) {
        await _alertSoundService.startIncomingCallAlert();
      } else {
        await _alertSoundService.stopIncomingCallAlert();
      }

      _refreshCallOverlayEntry();
      return;
    }

    if (nextSession.isAccepted) {
      _cancelCallRingTimeout();
      _startCallDurationTicker(nextSession.acceptedAtDateTime);
      await _alertSoundService.stopIncomingCallAlert();
      unawaited(
        _syncCallForegroundState(
          foreground: _appLifecycleState == AppLifecycleState.resumed,
        ),
      );

      if (previousStatus != RideCallStatus.accepted) {
        _logRideCall('call accepted rideId=$rideId');
      }

      if (!_callJoinedChannel) {
        final uid = _currentRiderUid;
        if (uid != null && uid.isNotEmpty) {
          await _joinAcceptedCall(rideId: rideId, uid: uid);
        }
      }

      _refreshCallOverlayEntry();
      return;
    }

    _cancelCallRingTimeout();
    await _alertSoundService.stopIncomingCallAlert();

    if (nextSession.status == RideCallStatus.declined &&
        previousStatus != RideCallStatus.declined) {
      _logRideCall('call declined rideId=$rideId');
    } else if (nextSession.status == RideCallStatus.missed &&
        previousStatus != RideCallStatus.missed) {
      _logRideCall('call missed rideId=$rideId');
      final uid = _currentRiderUid;
      if (uid != null &&
          uid.isNotEmpty &&
          nextSession.receiverId == uid) {
        if (mounted) {
          setState(() {
            _riderMissedCallNotice = true;
          });
        } else {
          _riderMissedCallNotice = true;
        }
      }
    } else if ((nextSession.status == RideCallStatus.ended ||
            nextSession.status == RideCallStatus.cancelled) &&
        previousStatus != nextSession.status) {
      _logRideCall(
        'call ended rideId=$rideId by=${nextSession.endedBy ?? 'system'}',
      );
    }

    await _performLocalCallCleanup(rideId: rideId);
  }

  Future<void> _joinAcceptedCall({
    required String rideId,
    required String uid,
  }) async {
    try {
      _logRideCall('[CALL_JOIN_START] rideId=$rideId');
      await _callService.ensureJoinedVoiceChannel(
        channelId: rideId,
        uid: uid,
        speakerOn: _callSpeakerOn,
        muted: _callMuted,
      ).timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw RideCallException(
          _callService.latestJoinFailureMessage(),
        ),
      );
      _callJoinedChannel = true;
      _logRideCall('[CALL_JOIN_OK] rideId=$rideId');
      await _callService.updateParticipantState(
        rideId: rideId,
        uid: uid,
        joined: true,
        muted: _callMuted,
        speaker: _callSpeakerOn,
        foreground: _appLifecycleState == AppLifecycleState.resumed,
      );
    } catch (error) {
      _logRideCall('[CALL_JOIN_FAIL] rideId=$rideId error=$error');
      await _callService.endAcceptedCall(rideId: rideId, endedBy: 'system');
      if (mounted) {
        final message = error is RideCallException
            ? error.message
            : 'Unable to connect the call right now.';
        _showSnackBar(message);
      }
    }
  }

  void _scheduleCallRingTimeout(RideCallSession session) {
    _cancelCallRingTimeout();
    final createdAt = session.createdAtDateTime ?? DateTime.now();
    final remaining =
        const Duration(seconds: 30).inMilliseconds -
        DateTime.now().difference(createdAt).inMilliseconds;

    if (remaining <= 0) {
      unawaited(_callService.markMissedIfUnanswered(rideId: session.rideId));
      return;
    }

    _callRingTimeoutTimer = Timer(Duration(milliseconds: remaining), () {
      unawaited(_callService.markMissedIfUnanswered(rideId: session.rideId));
    });
  }

  void _cancelCallRingTimeout() {
    _callRingTimeoutTimer?.cancel();
    _callRingTimeoutTimer = null;
  }

  void _startCallDurationTicker(DateTime? acceptedAt) {
    final startAt = acceptedAt ?? DateTime.now();
    _callAcceptedAt = startAt;
    _stopCallDurationTicker();
    _callDuration = DateTime.now().difference(startAt);
    _callDurationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final anchor = _callAcceptedAt;
      if (anchor == null) {
        return;
      }

      _callDuration = DateTime.now().difference(anchor);
      _callOverlayEntry?.markNeedsBuild();
    });
  }

  void _stopCallDurationTicker() {
    _callDurationTimer?.cancel();
    _callDurationTimer = null;
  }

  Future<void> _handleCallAppBackgrounded() async {
    _removeCallOverlayEntry();
    await _syncCallForegroundState(foreground: false);
  }

  Future<void> _syncCallForegroundState({required bool foreground}) async {
    final session = _currentCallSession;
    final uid = _currentRiderUid;
    if (session == null || session.isTerminal || uid == null || uid.isEmpty) {
      return;
    }

    try {
      await _callService.updateParticipantState(
        rideId: session.rideId,
        uid: uid,
        joined: session.isAccepted && _callJoinedChannel,
        muted: _callMuted,
        speaker: _callSpeakerOn,
        foreground: foreground,
      );
    } catch (error) {
      _logRideCall(
        'foreground sync failed rideId=${session.rideId} '
        'foreground=$foreground error=$error',
      );
    }
  }

  Future<void> _performLocalCallCleanup({
    required String rideId,
    bool logCleanup = true,
  }) async {
    final hadVisibleCallState =
        _currentCallSession != null ||
        _callJoinedChannel ||
        _callOverlayEntry != null ||
        _callDurationTimer != null ||
        _callRingTimeoutTimer != null;

    final uid = _currentRiderUid;
    if (uid != null && uid.isNotEmpty && rideId.isNotEmpty) {
      unawaited(
        _callService.updateParticipantState(
          rideId: rideId,
          uid: uid,
          joined: false,
          muted: _callMuted,
          speaker: _callSpeakerOn,
          foreground: _appLifecycleState == AppLifecycleState.resumed,
        ),
      );
    }

    _cancelCallRingTimeout();
    _stopCallDurationTicker();
    await _alertSoundService.stopIncomingCallAlert();
    _callAcceptedAt = null;
    _callDuration = Duration.zero;
    _callMuted = false;
    _callSpeakerOn = true;
    _currentCallSession = null;

    try {
      await _callService.leaveVoiceChannel();
    } catch (error) {
      _logRideCall('leave failed rideId=$rideId error=$error');
    }

    _callJoinedChannel = false;
    _removeCallOverlayEntry();

    if (logCleanup && hadVisibleCallState) {
      _logRideCall('local cleanup completed rideId=$rideId');
    }
  }

  Future<void> _startVoiceCallFromChat() async {
    if (_isStartingVoiceCall) {
      return;
    }

    final rideId = _activeRideInteractionId;
    final riderUid = _currentRiderUid;
    final driverId = _currentDriverIdForRide;
    if (rideId == null ||
        riderUid == null ||
        riderUid.isEmpty ||
        !_canStartRideCall ||
        driverId.isEmpty) {
      _showSnackBar('Voice call is available only for your active ride.');
      return;
    }

    if (mounted) {
      _setStateSafely(() {
        _riderMissedCallNotice = false;
      });
    } else {
      _riderMissedCallNotice = false;
    }

    _setStartingVoiceCall(true);
    try {
      _logRideCall('[CALL_START] rideId=$rideId initiator=rider');
      if (_currentCallSession != null && !_currentCallSession!.isTerminal) {
        _refreshCallOverlayEntry();
        _showSnackBar('Unable to start the call right now. Please try again.');
        return;
      }

      if (!_callService.hasRtcConfiguration) {
        _logRideCall('[CALL_CONFIG_MISSING] rideId=$rideId');
        _showSnackBar(_callService.unavailableUserMessage);
        return;
      }

      final permissionGranted = await _ensureMicrophonePermission(
        actionLabel: 'place this call',
      );
      if (!permissionGranted) {
        return;
      }

      try {
        _logRideCall('[CALL_TOKEN_FETCH_START] rideId=$rideId');
        await _callService.prefetchAgoraToken(channelId: rideId, uid: riderUid);
        _logRideCall('[CALL_TOKEN_FETCH_OK] rideId=$rideId');
      } on RideCallException catch (error) {
        _logRideCall('[CALL_TOKEN_FETCH_FAIL] rideId=$rideId error=$error');
        _showSnackBar(error.message);
        return;
      }

      _startCallListener(rideId);
      _logRideCall('outgoing call requested rideId=$rideId by=$riderUid');

      OutgoingCallRequestResult result;
      try {
        result = await _callService.requestOutgoingVoiceCall(
          rideId: rideId,
          riderId: riderUid,
          driverId: driverId,
          startedBy: 'rider',
        );
      } on RideCallException catch (error) {
        _logRideCall('[CALL_START_FAIL] rideId=$rideId error=$error');
        _showSnackBar(error.message);
        return;
      }

      if (!result.created) {
        _showSnackBar('Unable to start the call right now. Please try again.');
        if (result.session != null) {
          await _handleCallSnapshotUpdate(rideId, result.session);
        }
        return;
      }

      if (result.session != null) {
        await _handleCallSnapshotUpdate(rideId, result.session);
      }
    } finally {
      _setStartingVoiceCall(false);
    }
  }

  Future<void> _acceptIncomingCall() async {
    final session = _currentCallSession;
    if (session == null || !_isIncomingCall(session)) {
      return;
    }

    if (!_callService.hasRtcConfiguration) {
      _logRideCall('[CALL_CONFIG_MISSING] rideId=${session.rideId}');
      _showSnackBar(_callService.unavailableUserMessage);
      return;
    }

    final permissionGranted = await _ensureMicrophonePermission(
      actionLabel: 'answer this call',
    );
    if (!permissionGranted) {
      return;
    }

    final riderUid = _currentRiderUid;
    if (riderUid == null || riderUid.isEmpty) {
      _showSnackBar('Unable to confirm your rider identity for this call.');
      return;
    }

    try {
      _logRideCall('[CALL_TOKEN_FETCH_START] rideId=${session.rideId}');
      await _callService.prefetchAgoraToken(
        channelId: session.rideId,
        uid: riderUid,
      );
      _logRideCall('[CALL_TOKEN_FETCH_OK] rideId=${session.rideId}');
    } on RideCallException catch (error) {
      _logRideCall('[CALL_TOKEN_FETCH_FAIL] rideId=${session.rideId} error=$error');
      _showSnackBar(error.message);
      return;
    }

    final accepted = await _callService.acceptCall(
      rideId: session.rideId,
      receiverId: riderUid,
    );
    if (!accepted) {
      _showSnackBar('This call is no longer available.');
    }
  }

  Future<void> _declineIncomingCall() async {
    final session = _currentCallSession;
    if (session == null || !_isIncomingCall(session)) {
      return;
    }

    await _callService.declineCall(
      rideId: session.rideId,
      endedBy: 'rider',
      receiverId: _currentRiderUid,
    );
  }

  Future<void> _cancelOutgoingCall() async {
    final session = _currentCallSession;
    if (session == null || !_isOutgoingCall(session)) {
      return;
    }

    await _callService.cancelOutgoingCall(
      rideId: session.rideId,
      endedBy: 'rider',
      callerId: _currentRiderUid,
    );
  }

  Future<void> _endOngoingCall() async {
    final session = _currentCallSession;
    if (session == null || !session.isAccepted) {
      return;
    }

    await _callService.endAcceptedCall(
      rideId: session.rideId,
      endedBy: 'rider',
    );
  }

  Future<void> _toggleCallMute() async {
    final session = _currentCallSession;
    final uid = _currentRiderUid;
    if (session == null || !session.isAccepted || uid == null || uid.isEmpty) {
      return;
    }

    final nextMuted = !_callMuted;
    _callMuted = nextMuted;
    _callOverlayEntry?.markNeedsBuild();

    try {
      await _callService.setMuted(nextMuted);
      await _callService.updateParticipantState(
        rideId: session.rideId,
        uid: uid,
        joined: _callJoinedChannel,
        muted: nextMuted,
        speaker: _callSpeakerOn,
        foreground: _appLifecycleState == AppLifecycleState.resumed,
      );
    } catch (error) {
      _callMuted = !nextMuted;
      _callOverlayEntry?.markNeedsBuild();
      _showSnackBar('Unable to update mute right now.');
      _logRideCall('mute toggle failed rideId=${session.rideId} error=$error');
    }
  }

  Future<void> _toggleSpeaker() async {
    final session = _currentCallSession;
    final uid = _currentRiderUid;
    if (session == null || !session.isAccepted || uid == null || uid.isEmpty) {
      return;
    }

    final nextSpeakerState = !_callSpeakerOn;
    _callSpeakerOn = nextSpeakerState;
    _callOverlayEntry?.markNeedsBuild();

    try {
      await _callService.setSpeakerOn(nextSpeakerState);
      await _callService.updateParticipantState(
        rideId: session.rideId,
        uid: uid,
        joined: _callJoinedChannel,
        muted: _callMuted,
        speaker: nextSpeakerState,
        foreground: _appLifecycleState == AppLifecycleState.resumed,
      );
    } catch (error) {
      _callSpeakerOn = !nextSpeakerState;
      _callOverlayEntry?.markNeedsBuild();
      _showSnackBar('Unable to switch audio output right now.');
      _logRideCall(
        'speaker toggle failed rideId=${session.rideId} error=$error',
      );
    }
  }

  Future<void> _endCallForRideLifecycle({required String rideId}) async {
    await _callService.endCallForRideLifecycle(
      rideId: rideId,
      endedBy: 'system',
    );
    await _performLocalCallCleanup(rideId: rideId);
  }

  void _refreshCallOverlayEntry() {
    if (!mounted) {
      return;
    }

    if (_appLifecycleState != AppLifecycleState.resumed) {
      _removeCallOverlayEntry();
      return;
    }

    final session = _currentCallSession;
    final shouldShow = session != null && !session.isTerminal;
    if (!shouldShow) {
      _removeCallOverlayEntry();
      return;
    }

    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _refreshCallOverlayEntry();
      });
      return;
    }

    _callOverlayEntry ??= OverlayEntry(
      builder: (context) => _buildRideCallOverlay(),
    );

    if (!_callOverlayEntry!.mounted) {
      overlay.insert(_callOverlayEntry!);
      return;
    }

    _callOverlayEntry!.markNeedsBuild();
  }

  void _removeCallOverlayEntry() {
    _callOverlayEntry?.remove();
    _callOverlayEntry = null;
  }

  Widget _buildRideCallOverlay() {
    final session = _currentCallSession;
    if (session == null || session.isTerminal) {
      return const SizedBox.shrink();
    }

    return ValueListenableBuilder<AgoraConnectionPhase>(
      valueListenable: _callService.phaseNotifier,
      builder: (context, phase, _) {
        return ValueListenableBuilder<String?>(
          valueListenable: _callService.phaseErrorNotifier,
          builder: (context, phaseError, _) {
            return _buildRideCallOverlayContent(
              session: session,
              phase: phase,
              phaseError: phaseError,
            );
          },
        );
      },
    );
  }

  Widget _buildRideCallOverlayContent({
    required RideCallSession session,
    required AgoraConnectionPhase phase,
    required String? phaseError,
  }) {
    final isIncoming = _isIncomingCall(session);
    final isOutgoing = _isOutgoingCall(session);
    final title = _currentDriverNameForRide;
    final isFailed = phase == AgoraConnectionPhase.failed;
    final isReconnecting = phase == AgoraConnectionPhase.reconnecting;
    final isConnecting = phase == AgoraConnectionPhase.connecting ||
        (session.isAccepted && phase != AgoraConnectionPhase.connected);
    final subtitle = isIncoming
        ? 'Incoming call'
        : isOutgoing
            ? 'Calling...'
            : isFailed
                ? (phaseError ?? 'Could not connect call. Please try again.')
                : isReconnecting
                    ? 'Reconnecting...'
                    : isConnecting
                        ? 'Connecting...'
                        : _formatCallDuration(_callDuration);

    return Material(
      color: Colors.black.withValues(alpha: 0.56),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Container(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 22),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 28,
                      offset: Offset(0, 18),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 76,
                      height: 76,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF6E7CF),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: const Icon(
                        Icons.call_outlined,
                        size: 34,
                        color: _gold,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      subtitle,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: session.isAccepted ? 18 : 16,
                        fontWeight: FontWeight.w600,
                        color: isFailed
                            ? const Color(0xFFE85D4C)
                            : (session.isAccepted &&
                                    phase == AgoraConnectionPhase.connected)
                                ? _gold
                                : Colors.black54,
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (isIncoming)
                      Row(
                        children: [
                          Expanded(
                            child: _buildCallActionButton(
                              label: 'Decline',
                              icon: Icons.call_end_rounded,
                              backgroundColor: const Color(0xFFE85D4C),
                              onPressed: _declineIncomingCall,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildCallActionButton(
                              label: 'Accept',
                              icon: Icons.call_rounded,
                              backgroundColor: const Color(0xFF22A45D),
                              onPressed: _acceptIncomingCall,
                            ),
                          ),
                        ],
                      )
                    else if (isOutgoing)
                      SizedBox(
                        width: double.infinity,
                        child: _buildCallActionButton(
                          label: 'Cancel',
                          icon: Icons.call_end_rounded,
                          backgroundColor: const Color(0xFFE85D4C),
                          onPressed: _cancelOutgoingCall,
                        ),
                      )
                    else
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _buildCallControlChip(
                            label: _callMuted ? 'Unmute' : 'Mute',
                            icon: _callMuted
                                ? Icons.mic_off_rounded
                                : Icons.mic_none_rounded,
                            active: _callMuted,
                            onTap: _toggleCallMute,
                          ),
                          _buildCallControlChip(
                            label: _callSpeakerOn ? 'Speaker' : 'Earpiece',
                            icon: _callSpeakerOn
                                ? Icons.volume_up_rounded
                                : Icons.hearing_rounded,
                            active: _callSpeakerOn,
                            onTap: _toggleSpeaker,
                          ),
                          _buildCallControlChip(
                            label: 'End',
                            icon: Icons.call_end_rounded,
                            active: true,
                            backgroundColor: const Color(0xFFE85D4C),
                            foregroundColor: Colors.white,
                            onTap: _endOngoingCall,
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCallActionButton({
    required String label,
    required IconData icon,
    required Color backgroundColor,
    required Future<void> Function() onPressed,
  }) {
    return ElevatedButton.icon(
      style: ElevatedButton.styleFrom(
        backgroundColor: backgroundColor,
        foregroundColor: Colors.white,
        minimumSize: const Size(double.infinity, 54),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      onPressed: () {
        unawaited(onPressed());
      },
      icon: Icon(icon),
      label: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
    );
  }

  Widget _buildPrimaryRideButton() {
    final foregroundColor = _primaryRideButtonForegroundColor;
    final borderColor = _primaryRideButtonBorderColor;
    final enabled = _primaryRideButtonEnabled;

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: _primaryRideButtonOpacity,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: enabled
              ? () async {
                  print('RIDER_REQUEST_BUTTON_TAPPED');
                  await handlePrimaryRideAction();
                }
              : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: 56),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            decoration: BoxDecoration(
              gradient: _primaryRideButtonGradient,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: borderColor, width: 1.4),
              boxShadow: [
                BoxShadow(
                  color: borderColor.withValues(
                    alpha: _primaryRideButtonEnabled ? 0.28 : 0.16,
                  ),
                  blurRadius: _primaryRideButtonEnabled ? 22 : 16,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_isPrimaryRideButtonBusy)
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        foregroundColor,
                      ),
                    ),
                  )
                else
                  Icon(
                    _primaryRideButtonIcon,
                    size: 20,
                    color: foregroundColor,
                  ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    _primaryRideButtonLabel,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: foregroundColor,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPanelCard({
    required Widget child,
    Color backgroundColor = Colors.white,
    Color? borderColor,
    EdgeInsetsGeometry padding = const EdgeInsets.all(16),
  }) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: borderColor ?? _panelBorder),
        boxShadow: [
          BoxShadow(
            color: _routeShadow.withValues(alpha: 0.08),
            blurRadius: 24,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _buildMetricPill({
    required IconData icon,
    required String label,
    required String value,
    Color? accentColor,
  }) {
    final effectiveAccent = accentColor ?? _gold;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: effectiveAccent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: effectiveAccent.withValues(alpha: 0.16)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: effectiveAccent),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label.toUpperCase(),
                style: TextStyle(
                  color: _panelMutedInk,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.45,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: const TextStyle(
                  color: _panelInk,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRideStatusHeroCard(String headline) {
    final accent = _rideStateAccentColor;
    return _buildPanelCard(
      backgroundColor: _rideStateTintColor,
      borderColor: accent.withValues(alpha: 0.22),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(_rideStateIcon, color: accent, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _rideStateEyebrow,
                  style: TextStyle(
                    color: accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.85,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  headline,
                  style: const TextStyle(
                    color: _panelInk,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _rideStateSupportText,
                  style: const TextStyle(
                    color: _panelMutedInk,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRouteSummaryCard({
    required bool showRouteSummary,
    required List<String> stopAddresses,
  }) {
    if (!showRouteSummary) {
      return _buildPanelCard(
        backgroundColor: Colors.white,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: const [
                Icon(Icons.auto_awesome_rounded, color: _gold, size: 18),
                SizedBox(width: 8),
                Text(
                  'Trip preview',
                  style: TextStyle(
                    color: _panelInk,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Add your pickup and destination to load the live road route, fare, and ETA.',
              style: TextStyle(color: _panelMutedInk, height: 1.4),
            ),
          ],
        ),
      );
    }

    final title = _hasActiveRide ? 'Live trip basis' : 'Trip preview';
    final etaText = _estimatedDurationMin > 0
        ? '${_estimatedDurationMin.toStringAsFixed(0)} min'
        : '--';

    return _buildPanelCard(
      backgroundColor: Colors.white,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: _gold.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.route_rounded, color: _gold, size: 17),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: _panelInk,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildMetricPill(
                icon: Icons.straighten_rounded,
                label: 'Distance',
                value: '${_distanceKm.toStringAsFixed(2)} km',
              ),
              _buildMetricPill(
                icon: Icons.schedule_rounded,
                label: 'ETA',
                value: etaText,
                accentColor: _routeShadow,
              ),
              _buildMetricPill(
                icon: Icons.credit_card_rounded,
                label: 'Trip fare',
                value: '₦${_fare.toStringAsFixed(0)}',
                accentColor: _gold,
              ),
            ],
          ),
          if (_fare > 0) ...[
            const SizedBox(height: 12),
            RiderBackendPricingBreakdown(
              quote: RiderBackendPricingQuote.previewTripFare(_fare.round()),
              compact: true,
            ),
          ],
          if (stopAddresses.length > 1) ...[
            const SizedBox(height: 14),
            Text(
              'Stops: ${stopAddresses.join(' • ')}',
              style: const TextStyle(
                color: _panelMutedInk,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTripPaymentMethodSelectorCard() {
    final locked = _isTripPaymentSelectionLocked;
    return _buildPanelCard(
      backgroundColor: Colors.white,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.wallet_outlined, color: _gold, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Payment for this trip',
                  style: TextStyle(
                    color: _panelInk,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            locked
                ? 'Payment method is fixed for this request.'
                : _riderTripPaymentMethod
                          .trim()
                          .toLowerCase()
                          .replaceAll(RegExp(r'[\s-]+'), '_') ==
                      'bank_transfer'
                  ? 'Pay by transfer to NexRide’s official account. Upload your receipt in trip chat; your driver can confirm from chat.'
                  : 'We charge your linked card after the trip. Add a card under Profile → Payment methods—we do not open a payment page when you request a ride.',
            style: const TextStyle(
              color: _panelMutedInk,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: const Text('Card (saved)'),
                selected: _riderTripPaymentMethod
                        .trim()
                        .toLowerCase()
                        .replaceAll(RegExp(r'[\s-]+'), '_') !=
                    'bank_transfer',
                onSelected: locked
                    ? (_) {}
                    : (selected) {
                        if (!selected) {
                          return;
                        }
                        setState(() => _riderTripPaymentMethod = 'flutterwave');
                      },
                selectedColor: _gold.withValues(alpha: 0.22),
                labelStyle: const TextStyle(
                  color: _panelInk,
                  fontWeight: FontWeight.w700,
                ),
                side: BorderSide(color: _gold),
              ),
              ChoiceChip(
                label: const Text('Bank transfer'),
                selected: _riderTripPaymentMethod
                        .trim()
                        .toLowerCase()
                        .replaceAll(RegExp(r'[\s-]+'), '_') ==
                    'bank_transfer',
                onSelected: locked
                    ? (_) {}
                    : (selected) {
                        if (!selected) {
                          return;
                        }
                        setState(() => _riderTripPaymentMethod = 'bank_transfer');
                      },
                selectedColor: _gold.withValues(alpha: 0.22),
                labelStyle: const TextStyle(
                  color: _panelInk,
                  fontWeight: FontWeight.w700,
                ),
                side: BorderSide(color: _gold),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRouteErrorCard() {
    return _buildPanelCard(
      backgroundColor: const Color(0xFFFFF4EF),
      borderColor: _panelDanger.withValues(alpha: 0.18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.route_outlined, size: 18, color: _panelDanger),
              SizedBox(width: 8),
              Text(
                'Route preview needs attention',
                style: TextStyle(color: _panelInk, fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _routePreviewError!,
            style: const TextStyle(color: _panelMutedInk, height: 1.4),
          ),
          const SizedBox(height: 12),
          _buildSecondaryRideActionButton(
            label: 'Retry route',
            icon: Icons.refresh_rounded,
            onPressed: () {
              unawaited(_ensureRouteMetrics());
            },
            expanded: false,
          ),
        ],
      ),
    );
  }

  Widget _buildDriverAssignmentCard() {
    final ratingText = '${_driverData!['rating'] ?? 5.0}';
    final driverPhoneRaw = _firstNonEmptyText(<dynamic>[
      _driverData!['phone'],
      _currentRideSnapshot?['driver_phone'],
      _currentRideSnapshot?['driverPhone'],
    ]);
    final driverPhone = driverPhoneRaw.isNotEmpty
        ? driverPhoneRaw
        : 'Contact via chat';
    return _buildPanelCard(
      backgroundColor: Colors.white,
      child: Row(
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: _gold.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Icon(Icons.person_rounded, color: _gold, size: 28),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _firstNonEmptyText(
                    <dynamic>[
                      _driverData!['name'],
                      _driverData!['driver_name'],
                      _currentRideSnapshot?['driver_name'],
                      _currentRideSnapshot?['driverName'],
                    ],
                    fallback: 'Driver',
                  ),
                  style: const TextStyle(
                    color: _panelInk,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _driverData!['car']?.toString() ?? '',
                  style: const TextStyle(
                    color: _panelMutedInk,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if ((_driverData!['plate']?.toString() ?? '').isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      _driverData!['plate']?.toString() ?? '',
                      style: TextStyle(
                        color: _routeShadow,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.35,
                      ),
                    ),
                  ),
                const SizedBox(height: 4),
                Text(
                  driverPhone,
                  style: const TextStyle(
                    color: _panelMutedInk,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF5D8),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                const Icon(Icons.star_rounded, color: _gold, size: 18),
                const SizedBox(width: 6),
                Text(
                  ratingText,
                  style: const TextStyle(
                    color: _panelInk,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCollapsedMetric({
    required String label,
    required String value,
  }) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: _panelMutedInk,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              color: _panelInk,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildArrivalCountdownCard() {
    return _buildPanelCard(
      backgroundColor: const Color(0xFFFFF3E6),
      borderColor: _panelWarning.withValues(alpha: 0.2),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: _panelWarning.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(
              Icons.access_time_filled_rounded,
              color: _panelWarning,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _waitingCharged
                  ? 'Waiting charge applied to this pickup.'
                  : 'Driver waiting timer ${_formatCountdown(_countdown)}',
              style: const TextStyle(
                color: _panelInk,
                fontWeight: FontWeight.w700,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSecondaryRideActionButton({
    required String label,
    required IconData icon,
    required VoidCallback? onPressed,
    bool filled = false,
    bool busy = false,
    bool expanded = true,
    String? badgeText,
  }) {
    final enabled = onPressed != null && !busy;
    final backgroundColor = filled ? _gold : _gold.withValues(alpha: 0.08);
    final foregroundColor = filled ? _panelInk : _panelInk;
    final borderColor = filled ? _gold : _gold.withValues(alpha: 0.22);

    final button = AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: enabled ? 1 : 0.58,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: enabled ? onPressed : null,
          child: Container(
            width: expanded ? double.infinity : null,
            constraints: const BoxConstraints(minHeight: 50),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: backgroundColor,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: borderColor, width: 1.25),
            ),
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
                  children: [
                    if (busy)
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            foregroundColor,
                          ),
                        ),
                      )
                    else
                      Icon(icon, color: foregroundColor, size: 18),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        label.toUpperCase(),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: foregroundColor,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.45,
                        ),
                      ),
                    ),
                  ],
                ),
                if (badgeText != null)
                  Positioned(
                    right: 0,
                    top: -6,
                    child: Container(
                      constraints: const BoxConstraints(
                        minWidth: 22,
                        minHeight: 22,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: _panelDanger,
                        borderRadius: BorderRadius.circular(11),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        badgeText,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    return expanded ? SizedBox(width: double.infinity, child: button) : button;
  }

  Widget _buildCallControlChip({
    required String label,
    required IconData icon,
    required bool active,
    required Future<void> Function() onTap,
    Color? backgroundColor,
    Color? foregroundColor,
  }) {
    final effectiveBackground =
        backgroundColor ??
        (active ? const Color(0xFFF6E7CF) : const Color(0xFFF4F4F5));
    final effectiveForeground =
        foregroundColor ?? (active ? const Color(0xFF8A6424) : Colors.black87);

    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () {
        unawaited(onTap());
      },
      child: Container(
        width: 88,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
        decoration: BoxDecoration(
          color: effectiveBackground,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: effectiveForeground),
            const SizedBox(height: 8),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: effectiveForeground,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _rideStatusLabel(String status) {
    if (_isSubmittingRideRequest || _isCreatingRide) {
      return RiderTripStatusMessages.creatingRide;
    }

    if (status.trim().toLowerCase() == 'idle') {
      if (_pickupLocation == null || _pickupAddress.trim().isEmpty) {
        return 'Choose your pickup to begin';
      }
      if (_orderedDropOffLocations().isEmpty ||
          _orderedDropOffAddresses().any(
            (String address) => address.trim().isEmpty,
          )) {
        return 'Add your destination to preview the route and fare';
      }
      if (_routePreviewError != null) {
        return 'Retry route preview to continue';
      }
      if (_hasRoutePreviewReady) {
        return 'Ready to request your ride';
      }
      return 'Calculating your route and fare';
    }

    if (status == 'driver_cancelled') {
      return 'Your driver cancelled. Looking for another driver...';
    }
    if (status == 'rider_cancelled') {
      return 'You cancelled this trip.';
    }
    if (status == 'expired') {
      return 'This trip request expired.';
    }

    final canonicalState = TripStateMachine.canonicalStateFromSnapshot(
      _currentRideSnapshot ?? const <String, dynamic>{},
    );
    return switch (canonicalState) {
      TripLifecycleState.searchingDriver =>
        RiderTripStatusMessages.searchingForDriver,
      TripLifecycleState.driverAccepted =>
        RiderTripStatusMessages.driverAssigned,
      TripLifecycleState.driverArriving =>
        RiderTripStatusMessages.driverArriving,
      TripLifecycleState.driverArrived => RiderTripStatusMessages.arrived,
      TripLifecycleState.tripStarted => RiderTripStatusMessages.tripStarted,
      TripLifecycleState.tripCompleted => RiderTripStatusMessages.tripCompleted,
      TripLifecycleState.tripCancelled => RiderTripStatusMessages.cancelled,
      TripLifecycleState.expired => RiderTripStatusMessages.cancelled,
      _ => 'Ready when you are',
    };
  }

  Map<String, dynamic> _locationPayload({
    required Map<String, dynamic>? rideLocation,
    required LatLng? fallbackLocation,
    required String address,
  }) {
    final lat = _asDouble(rideLocation?['lat']) ?? fallbackLocation?.latitude;
    final lng = _asDouble(rideLocation?['lng']) ?? fallbackLocation?.longitude;

    return <String, dynamic>{'lat': lat, 'lng': lng, 'address': address.trim()};
  }

  Map<String, dynamic>? _liveLocationPayloadFromRide(
    Map<String, dynamic>? rideData,
  ) {
    final lat = _asDouble(rideData?['driver_lat']);
    final lng = _asDouble(rideData?['driver_lng']);

    if (lat == null || lng == null) {
      return null;
    }

    return <String, dynamic>{
      'lat': lat,
      'lng': lng,
      'heading': _asDouble(rideData?['driver_heading']) ?? 0,
      'updated_at': _asInt(rideData?['updated_at']),
    };
  }

  ShareTripPayload? _buildShareTripPayload({
    required String rideId,
    Map<String, dynamic>? rideData,
  }) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return null;
    }

    final currentRideData = rideData ?? _currentRideSnapshot;
    final pickupData = _asStringDynamicMap(currentRideData?['pickup']);
    final destinationData =
        _asStringDynamicMap(currentRideData?['final_destination']) ??
        _asStringDynamicMap(currentRideData?['destination']);
    final orderedDropOffs = _orderedDropOffLocations();
    final finalDropOffLocation = orderedDropOffs.isNotEmpty
        ? orderedDropOffs.last
        : _destinationLocation;
    final rideStops = _buildIntermediateStopsPayload(_buildStopsPayload());
    final normalizedStops = _normalizeStopsForShare(currentRideData);
    final rideStatus = currentRideData == null
        ? _rideStatus
        : TripStateMachine.uiStatusFromSnapshot(currentRideData);
    final rideDriverId = _firstNonEmptyText(<dynamic>[
      currentRideData?['driver_id'],
      _driverData?['id'],
    ]);
    final rideDriverData = <String, dynamic>{
      'id': rideDriverId,
      'name': _firstNonEmptyText(<dynamic>[
        currentRideData?['driver_name'],
        _driverData?['name'],
      ]),
      'car': _firstNonEmptyText(<dynamic>[
        currentRideData?['car'],
        _driverData?['car'],
      ]),
      'plate': _firstNonEmptyText(<dynamic>[
        currentRideData?['plate'],
        _driverData?['plate'],
      ]),
      'rating':
          _asDouble(currentRideData?['rating']) ??
          _asDouble(_driverData?['rating']),
    };

    return ShareTripPayload(
      rideId: rideId,
      riderId: user.uid,
      status: rideStatus,
      pickup: _locationPayload(
        rideLocation: pickupData,
        fallbackLocation: _pickupLocation,
        address: _firstNonEmptyText(<dynamic>[
          currentRideData?['pickup_address'],
          _pickupAddress,
        ]),
      ),
      destination: _locationPayload(
        rideLocation: destinationData,
        fallbackLocation: finalDropOffLocation,
        address: _firstNonEmptyText(<dynamic>[
          currentRideData?['final_destination_address'],
          currentRideData?['destination_address'],
          _lastDropOffAddress(),
          _destinationAddress,
        ]),
      ),
      stops: normalizedStops.isNotEmpty ? normalizedStops : rideStops,
      driverId: rideDriverId,
      driver: rideDriverData,
      liveLocation: _liveLocationPayloadFromRide(currentRideData),
      rideData: currentRideData,
    );
  }

  List<Map<String, dynamic>> _normalizeStopsForShare(
    Map<String, dynamic>? rideData,
  ) {
    final rawStops = rideData?['stops'];
    if (rawStops is! List) {
      return <Map<String, dynamic>>[];
    }

    final stops = <Map<String, dynamic>>[];
    for (var index = 0; index < rawStops.length; index++) {
      final stop = _asStringDynamicMap(rawStops[index]);
      if (stop == null) {
        continue;
      }

      final lat = _asDouble(stop['lat']);
      final lng = _asDouble(stop['lng']);
      if (lat == null || lng == null) {
        continue;
      }

      stops.add(<String, dynamic>{
        'order': _asInt(stop['order']) ?? (index + 1),
        'address': stop['address']?.toString().trim() ?? '',
        'lat': lat,
        'lng': lng,
      });
    }

    stops.sort((a, b) {
      final first = _asInt(a['order']) ?? 0;
      final second = _asInt(b['order']) ?? 0;
      return first.compareTo(second);
    });

    return stops;
  }

  String _stopsSignature(dynamic rawStops) {
    if (rawStops is! List) {
      return '';
    }

    return rawStops
        .map((rawStop) {
          final stop = _asStringDynamicMap(rawStop);
          if (stop == null) {
            return '';
          }

          return [
            _asInt(stop['order'])?.toString() ?? '',
            stop['address']?.toString().trim() ?? '',
            _asDouble(stop['lat'])?.toStringAsFixed(5) ?? '',
            _asDouble(stop['lng'])?.toStringAsFixed(5) ?? '',
          ].join(':');
        })
        .join('|');
  }

  String _driverUiSignature(Map<String, dynamic>? driverData) {
    if (driverData == null) {
      return '';
    }

    return <String>[
      driverData['id']?.toString().trim() ?? '',
      driverData['name']?.toString().trim() ?? '',
      driverData['car']?.toString().trim() ?? '',
      driverData['plate']?.toString().trim() ?? '',
      _asDouble(driverData['rating'])?.toStringAsFixed(2) ?? '',
    ].join('|');
  }

  String _rideUiSignature({
    required String rideId,
    required String status,
    required Map<String, dynamic>? rideData,
    required Map<String, dynamic>? driverData,
  }) {
    return <String>[
      rideId,
      status,
      rideData?['pickup_address']?.toString().trim() ?? '',
      rideData?['destination_address']?.toString().trim() ?? '',
      rideData?['final_destination_address']?.toString().trim() ?? '',
      _stopsSignature(rideData?['stops']),
      _driverUiSignature(driverData),
    ].join('||');
  }

  Future<Map<String, dynamic>?> _fetchLatestRideSnapshot(String rideId) async {
    final snapshot = await _rideRequestsRef.child(rideId).get();
    return _asStringDynamicMap(snapshot.value);
  }

  Future<void> _syncShareTripSnapshot({
    required String rideId,
    required Map<String, dynamic> rideData,
  }) async {
    final shareData = _asStringDynamicMap(rideData['share']);
    final token = shareData?['token']?.toString().trim() ?? '';
    final enabled = shareData?['enabled'] == true;
    final expiresAt = _asInt(shareData?['expires_at']) ?? 0;

    if (!enabled || token.isEmpty) {
      return;
    }

    if (expiresAt > 0 && expiresAt <= DateTime.now().millisecondsSinceEpoch) {
      return;
    }

    final payload = _buildShareTripPayload(rideId: rideId, rideData: rideData);
    if (payload == null) {
      return;
    }

    try {
      await _shareTripRtdbService.syncExistingShare(payload);
    } catch (error) {
      _logRideFlow('share sync failed rideId=$rideId error=$error');
    }
  }

  String _formatCountdown(int totalSeconds) {
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  String _riderUnreadBadgeText() {
    if (_riderUnreadChatCount > 9) {
      return '9+';
    }

    return '$_riderUnreadChatCount';
  }

  List<LatLng> _orderedDropOffLocations() {
    final stops = <LatLng>[];

    if (_destinationLocation != null) {
      stops.add(_destinationLocation!);
    }

    for (final location in _additionalStopLocations) {
      if (location != null) {
        stops.add(location);
      }
    }

    return stops;
  }

  List<String> _orderedDropOffAddresses() {
    final addresses = <String>[];
    final primaryAddress = _destinationAddress.trim();

    if (_destinationLocation != null || primaryAddress.isNotEmpty) {
      addresses.add(primaryAddress.isEmpty ? 'Stop 1' : primaryAddress);
    }

    for (var i = 0; i < _additionalStopAddresses.length; i++) {
      final address = _additionalStopAddresses[i].trim();
      if (_additionalStopLocations[i] != null || address.isNotEmpty) {
        addresses.add(address.isEmpty ? 'Stop ${i + 2}' : address);
      }
    }

    return addresses;
  }

  String _lastDropOffAddress() {
    final addresses = _orderedDropOffAddresses();
    if (addresses.isEmpty) {
      return '';
    }

    return addresses.last;
  }

  List<Map<String, dynamic>> _buildStopsPayload() {
    final stops = <Map<String, dynamic>>[];

    if (_destinationLocation != null) {
      stops.add({
        'order': 1,
        'address': _destinationAddress.trim(),
        'lat': _destinationLocation!.latitude.toDouble(),
        'lng': _destinationLocation!.longitude.toDouble(),
      });
    }

    for (var i = 0; i < _additionalStopLocations.length; i++) {
      final location = _additionalStopLocations[i];
      if (location == null) {
        continue;
      }

      stops.add({
        'order': stops.length + 1,
        'address': _additionalStopAddresses[i].trim(),
        'lat': location.latitude.toDouble(),
        'lng': location.longitude.toDouble(),
      });
    }

    return stops;
  }

  List<Map<String, dynamic>> _buildIntermediateStopsPayload(
    List<Map<String, dynamic>> orderedStops,
  ) {
    if (orderedStops.length <= 1) {
      return <Map<String, dynamic>>[];
    }

    return orderedStops
        .take(orderedStops.length - 1)
        .map((stop) => Map<String, dynamic>.from(stop))
        .toList();
  }

  Map<String, dynamic>? _buildRideRequestLocationPayload({
    required double? lat,
    required double? lng,
    required String address,
    required String fieldLabel,
  }) {
    if (lat == null || lng == null) {
      _logRideFlow(
        'request blocked: $fieldLabel lat/lng missing lat=$lat lng=$lng',
      );
      _showSnackBar(
        'Choose a valid $fieldLabel location before requesting a ride.',
      );
      return null;
    }

    return <String, dynamic>{
      'lat': lat.toDouble(),
      'lng': lng.toDouble(),
      'address': address.trim(),
    };
  }

  void _syncTripLocationMarkers() {
    _markers.removeWhere((marker) {
      final markerId = marker.markerId.value;
      return markerId == 'pickup' ||
          markerId == 'destination' ||
          markerId.startsWith('stop_');
    });

    final pickup = _pickupLocation;
    if (pickup != null) {
      _markers.add(
        Marker(markerId: const MarkerId('pickup'), position: pickup),
      );
    }

    final dropOffs = _orderedDropOffLocations();
    for (var i = 0; i < dropOffs.length; i++) {
      final markerId = i == 0 ? 'destination' : 'stop_${i + 1}';
      final title = i == 0 ? 'Stop 1' : 'Stop ${i + 1}';
      _markers.add(
        Marker(
          markerId: MarkerId(markerId),
          position: dropOffs[i],
          infoWindow: InfoWindow(title: title),
          icon: BitmapDescriptor.defaultMarkerWithHue(
            i == 0 ? BitmapDescriptor.hueRed : BitmapDescriptor.hueOrange,
          ),
        ),
      );
    }

    _notifyMapLayerChanged();
  }

  Future<void> _playChatNotificationSound() async {
    try {
      await _alertSoundService.playChatAlert();
      await HapticFeedback.lightImpact();
    } catch (error) {
      _logRideFlow('chat notification sound failed error=$error');
    }
  }

  void _showRiderIncomingChatNotice() {
    final now = DateTime.now();
    if (_lastRiderChatNoticeAt != null &&
        now.difference(_lastRiderChatNoticeAt!) < const Duration(seconds: 2)) {
      return;
    }
    _lastRiderChatNoticeAt = now;
    if (!mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) {
      return;
    }
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: const Text('New message from driver'),
        action: SnackBarAction(
          label: 'Open',
          onPressed: _openChat,
        ),
      ),
    );
  }

  Future<String> _addressFromCoordinates(LatLng point) async {
    try {
      final placemarks = await placemarkFromCoordinates(
        point.latitude,
        point.longitude,
      );

      if (placemarks.isEmpty) {
        return '${point.latitude}, ${point.longitude}';
      }

      final placemark = placemarks.first;
      final parts = <String>[
        if (placemark.street != null && placemark.street!.trim().isNotEmpty)
          placemark.street!,
        if (placemark.subLocality != null &&
            placemark.subLocality!.trim().isNotEmpty)
          placemark.subLocality!,
        if (placemark.locality != null && placemark.locality!.trim().isNotEmpty)
          placemark.locality!,
        if (placemark.administrativeArea != null &&
            placemark.administrativeArea!.trim().isNotEmpty)
          placemark.administrativeArea!,
      ];

      if (parts.isEmpty) {
        return '${point.latitude}, ${point.longitude}';
      }

      return parts.join(', ');
    } catch (error) {
      _logRideFlow(
        'address lookup failed point=${_formatLatLng(point)} error=$error',
      );
      return '${point.latitude}, ${point.longitude}';
    }
  }

  Future<String?> _resolveServiceCity() async {
    final pickupCity = await _resolveServiceCityCandidate(
      addressHint: _pickupAddress,
      point: _pickupLocation,
    );
    final destinationCity = await _resolveServiceCityCandidate(
      addressHint: _destinationAddress,
      point: _destinationLocation,
    );

    if (pickupCity != null &&
        destinationCity != null &&
        pickupCity != destinationCity) {
      _logRideFlow(
        'service city mismatch pickupCity=$pickupCity destinationCity=$destinationCity',
      );
      return null;
    }

    return pickupCity ?? destinationCity;
  }

  String _rideRequestAddressLabel(String address, {required String fallback}) {
    final trimmed = address.trim();
    if (trimmed.isNotEmpty) {
      return trimmed;
    }
    return fallback;
  }

  Future<void> _prepareBrowseLocationContext() async {
    try {
      final configuredTestCity = _configuredTestRiderCity;
      if (configuredTestCity != null) {
        if (!_launchCityChosenManually &&
            configuredTestCity != _selectedLaunchCity) {
          await _selectLaunchCity(
            configuredTestCity,
            manual: false,
            persist: false,
            moveCamera: false,
          );
        }
        _logRideFlow(
          'browse location using configured test city=$configuredTestCity',
        );
        final fallbackLocation = _fallbackBrowseLocation;
        if (!mounted) {
          _deviceLocationAvailable = false;
          _deviceLocationOutsideLaunchArea = false;
          _riderLocation = fallbackLocation;
          return;
        }
        setState(() {
          _deviceLocationAvailable = false;
          _deviceLocationOutsideLaunchArea = false;
          _riderLocation = fallbackLocation;
        });
        unawaited(_moveCameraToSelectedPoint(fallbackLocation));
        return;
      }

      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      final canUseDeviceLocation =
          serviceEnabled &&
          (permission == LocationPermission.always ||
              permission == LocationPermission.whileInUse);

      if (!canUseDeviceLocation) {
        _logRideFlow(
          '[NEXRIDE_RIDER_LOCATION] unavailable serviceEnabled=$serviceEnabled permission=$permission',
        );
        if (mounted) {
          final messenger = ScaffoldMessenger.maybeOf(context);
          if (!serviceEnabled) {
            messenger?.showSnackBar(
              SnackBar(
                content: const Text(
                  'Turn on device location so NexRide can set your city and pickup from GPS, or choose addresses manually.',
                ),
                action: SnackBarAction(
                  label: 'Retry',
                  onPressed: () {
                    unawaited(_prepareBrowseLocationContext());
                  },
                ),
              ),
            );
          } else if (permission == LocationPermission.deniedForever) {
            messenger?.showSnackBar(
              SnackBar(
                content: const Text(
                  'Location permission is denied for NexRide. Open Settings to allow access, or set pickup manually.',
                ),
                action: SnackBarAction(
                  label: 'Retry',
                  onPressed: () {
                    unawaited(_prepareBrowseLocationContext());
                  },
                ),
              ),
            );
          } else if (permission == LocationPermission.denied) {
            messenger?.showSnackBar(
              SnackBar(
                content: const Text(
                  'Allow location access so your market and map match where you are.',
                ),
                action: SnackBarAction(
                  label: 'Retry',
                  onPressed: () {
                    unawaited(_prepareBrowseLocationContext());
                  },
                ),
              ),
            );
          }
        }
        if (!mounted) {
          _deviceLocationAvailable = false;
          _riderLocation = _fallbackBrowseLocation;
          return;
        }
        setState(() {
          _deviceLocationAvailable = false;
          _deviceLocationOutsideLaunchArea = false;
          _riderLocation = _fallbackBrowseLocation;
        });
        return;
      }

      final position = await Geolocator.getCurrentPosition();
      final detectedCity = await _resolveLaunchCityFromPoint(
        LatLng(position.latitude, position.longitude),
      );
      if (detectedCity == null) {
        _logRideFlow(
          'browse location outside launch area lat=${position.latitude} lng=${position.longitude} selectedLaunchCity=$_selectedLaunchCity',
        );
        if (!mounted) {
          _deviceLocationAvailable = false;
          _deviceLocationOutsideLaunchArea = false;
          _riderLocation = _fallbackBrowseLocation;
          return;
        }
        setState(() {
          _deviceLocationAvailable = false;
          _deviceLocationOutsideLaunchArea = false;
          _riderLocation = _fallbackBrowseLocation;
        });
        unawaited(_moveCameraToSelectedPoint(_fallbackBrowseLocation));
        return;
      }

      _deviceLocationOutsideLaunchArea = false;
      if (!_launchCityChosenManually && detectedCity != _selectedLaunchCity) {
        await _selectLaunchCity(
          detectedCity,
          manual: false,
          persist: true,
          moveCamera: false,
        );
      }
      final pool = RiderServiceAreaConfig.marketForCity(_selectedLaunchCity).city;
      debugPrint(
        '[NEXRIDE_RIDER_LOCATION] lat=${position.latitude} lng=${position.longitude} '
        'detected_city=$detectedCity selected_launch_city=$_selectedLaunchCity '
        'market_pool=$pool',
      );
      await _applyCurrentLocationAsPickup(
        position,
        moveCamera: false,
        autoFillPickup: true,
      );
    } catch (error) {
      _logRideFlow('prepare browse location failed error=$error');
      if (!mounted) {
        _deviceLocationAvailable = false;
        _riderLocation = _fallbackBrowseLocation;
        return;
      }
      setState(() {
        _deviceLocationAvailable = false;
        _deviceLocationOutsideLaunchArea = false;
        _riderLocation = _fallbackBrowseLocation;
      });
    }
  }

  Future<void> _applyCurrentLocationAsPickup(
    Position position, {
    bool moveCamera = true,
    bool autoFillPickup = false,
  }) async {
    _riderLocation = LatLng(position.latitude, position.longitude);
    _deviceLocationAvailable = true;
    _deviceLocationOutsideLaunchArea = false;

    if (autoFillPickup || _pickupLocation == null) {
      _pickupLocation = _riderLocation;
      _pickupAddress = await _addressFromCoordinates(_riderLocation);
      _pickupController.text = _pickupAddress;
    }

    _resetMarkersForIdleState();

    if (mounted) {
      setState(() {});
    }

    if (moveCamera) {
      _moveCamera();
    }

    final syncPoint = _pickupLocation ?? _riderLocation;
    unawaited(_maybeSyncRolloutSelectionToPickup(syncPoint));
  }

  void _resetMarkersForIdleState() {
    _markers.removeWhere((marker) {
      final markerId = marker.markerId.value;
      return markerId == 'driver' ||
          markerId == 'pickup' ||
          markerId == 'destination' ||
          markerId.startsWith('stop_');
    });
    _driverAnimationGeneration++;
    _driverMarker = null;
    _syncTripLocationMarkers();
  }

  String _routeSignature(List<LatLng> route) {
    return route
        .map(
          (point) =>
              '${point.latitude.toStringAsFixed(5)},${point.longitude.toStringAsFixed(5)}',
        )
        .join('|');
  }

  bool _isRoutePreviewComputationCurrent(int generation) {
    return generation == _routePreviewComputationGeneration;
  }

  Set<Polyline> _premiumRoutePolylines(List<LatLng> route) {
    if (route.isEmpty) {
      return <Polyline>{};
    }

    return <Polyline>{
      Polyline(
        polylineId: const PolylineId('route_shadow'),
        points: route,
        width: 9,
        color: _routeShadow,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        jointType: JointType.round,
        zIndex: 1,
      ),
      Polyline(
        polylineId: const PolylineId('route_gold'),
        points: route,
        width: 7,
        color: _routeGold,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        jointType: JointType.round,
        zIndex: 2,
      ),
    };
  }

  Future<void> _ensureRouteMetrics() async {
    final routeComputationGeneration = ++_routePreviewComputationGeneration;
    final pickup = _pickupLocation;
    final dropOffs = List<LatLng>.from(_orderedDropOffLocations());
    if (pickup == null || dropOffs.isEmpty) {
      if (!_isRoutePreviewComputationCurrent(routeComputationGeneration)) {
        return;
      }
      _distanceKm = 0;
      _estimatedDurationMin = 0;
      _fare = 0;
      _routePreviewError = null;
      _expectedRoutePoints.clear();
      _lastRenderedRouteSignature = '';
      _polylines = <Polyline>{};
      _syncTripLocationMarkers();
      _notifyMapLayerChanged();

      if (mounted) {
        setState(() {});
      }
      _logRideFlow('search route reset reason=missing_points fare=$_fare');
      return;
    }

    var totalDistanceKm = 0.0;
    var totalDurationSeconds = 0;
    final route = <LatLng>[];
    var legStart = pickup;
    _routePreviewError = null;

    for (var i = 0; i < dropOffs.length; i++) {
      final stop = dropOffs[i];
      final fallbackLegDistanceKm =
          Geolocator.distanceBetween(
            legStart.latitude,
            legStart.longitude,
            stop.latitude,
            stop.longitude,
          ) /
          1000;
      var resolvedLegDistanceKm = fallbackLegDistanceKm;

      try {
        final result = await _roadRouteService.fetchDrivingRoute(
          origin: legStart,
          destination: stop,
        );
        if (!_isRoutePreviewComputationCurrent(routeComputationGeneration)) {
          return;
        }
        final legRoute = result.points;
        _logRideFlow(
          'route fetch result leg=${i + 1} points=${legRoute.length} origin=${_formatLatLng(legStart)} destination=${_formatLatLng(stop)}',
        );
        if (result.distanceMeters > 0) {
          resolvedLegDistanceKm = result.distanceMeters / 1000;
        }

        if (legRoute.isEmpty) {
          _routePreviewError =
              result.errorMessage ??
              'We could not load the live road route yet. Retry to continue.';
          _logRideFlow(
            'route fetch empty polyline leg=${i + 1} blocking preview',
          );
          break;
        }
        if (route.isEmpty) {
          route.addAll(legRoute);
        } else {
          route.addAll(legRoute.skip(1));
        }

        if (result.durationSeconds > 0) {
          totalDurationSeconds += result.durationSeconds;
        } else {
          totalDurationSeconds +=
              (estimateRiderDurationMinutes(distanceKm: resolvedLegDistanceKm) *
                      60)
                  .round();
        }
      } catch (error) {
        if (!_isRoutePreviewComputationCurrent(routeComputationGeneration)) {
          return;
        }
        _logRideFlow('route calculation failed stop=${i + 1} error=$error');
        _routePreviewError =
            'We could not load the live road route yet. Retry to continue.';
        break;
      }

      if (_routePreviewError != null) {
        break;
      }
      totalDistanceKm += resolvedLegDistanceKm;
      legStart = stop;
    }

    if (!_isRoutePreviewComputationCurrent(routeComputationGeneration)) {
      return;
    }

    if (_routePreviewError != null || route.isEmpty) {
      _distanceKm = 0;
      _estimatedDurationMin = 0;
      _fare = 0;
      _expectedRoutePoints.clear();
      _lastRenderedRouteSignature = '';
      _polylines = <Polyline>{};
      _syncTripLocationMarkers();
      _notifyMapLayerChanged();

      if (mounted) {
        setState(() {});
      }

      _logRideFlow(
        'search route unavailable pickup=${_formatLatLng(pickup)} stops=${dropOffs.length} reason=${_routePreviewError ?? 'empty_route'}',
      );
      _moveCamera();
      return;
    }

    final city = await _resolveServiceCity();
    if (!_isRoutePreviewComputationCurrent(routeComputationGeneration)) {
      return;
    }
    if (city != null) {
      RiderFareRule? liveRule;
      try {
        liveRule = await RegionPricingService.instance.ruleForCity(city);
      } catch (_) {
        liveRule = RiderFareSettings.maybeForCity(city);
      }
      if (!_isRoutePreviewComputationCurrent(routeComputationGeneration)) {
        return;
      }
      final fareBreakdown = calculateRiderFare(
        serviceKey: RiderServiceType.ride.key,
        city: city,
        distanceKm: totalDistanceKm,
        durationSeconds: totalDurationSeconds,
        liveRule: liveRule,
      );
      _distanceKm = fareBreakdown.distanceKm;
      _estimatedDurationMin = fareBreakdown.durationMin;
      _fare =
          fareBreakdown.totalFare +
          (_waitingCharged ? RiderFareSettings.waitingCharge : 0);
    } else {
      _distanceKm = double.parse(totalDistanceKm.toStringAsFixed(2));
      _estimatedDurationMin = double.parse(
        (totalDurationSeconds / 60).toStringAsFixed(2),
      );
      _fare = _waitingCharged ? RiderFareSettings.waitingCharge : 0;
    }
    _routePreviewError = null;
    final routeSignature = _routeSignature(route);
    _expectedRoutePoints
      ..clear()
      ..addAll(route);
    final routeChanged = routeSignature != _lastRenderedRouteSignature;
    if (routeChanged) {
      _lastRenderedRouteSignature = routeSignature;
      _polylines = _premiumRoutePolylines(route);
      _notifyMapLayerChanged();
    }
    _syncTripLocationMarkers();

    if (mounted) {
      setState(() {});
    }

    _logRideFlow(
      'search route updated pickup=${_formatLatLng(pickup)} stops=${dropOffs.length} polylinePoints=${route.length} distanceKm=${_distanceKm.toStringAsFixed(2)} durationMin=${_estimatedDurationMin.toStringAsFixed(1)} fare=$_fare',
    );
    _moveCamera();
  }

  Future<LatLng?> _resolvePlaceLocation({
    required NativePlaceSuggestion suggestion,
    required String description,
  }) async {
    if (suggestion.isManualSuggestion) {
      final manualLocations = await _lookupAddressLocations(
        suggestion.fullText,
      );
      if (manualLocations.isNotEmpty) {
        _logRideFlow(
          'manual place resolved placeId=${suggestion.placeId} lat=${manualLocations.first.latitude} lng=${manualLocations.first.longitude}',
        );
        return LatLng(
          manualLocations.first.latitude,
          manualLocations.first.longitude,
        );
      }
    }

    final details = await _nativePlacesService.fetchPlaceDetails(
      suggestion.placeId,
    );
    if (details != null) {
      _logRideFlow(
        'place details resolved placeId=${details.placeId} lat=${details.latitude} lng=${details.longitude}',
      );
      return LatLng(details.latitude, details.longitude);
    }

    final locations = await _lookupAddressLocations(description);
    if (locations.isEmpty) {
      return null;
    }

    _logRideFlow(
      'place geocode fallback resolved placeId=${suggestion.placeId} lat=${locations.first.latitude} lng=${locations.first.longitude}',
    );
    return LatLng(locations.first.latitude, locations.first.longitude);
  }

  Future<List<Location>> _lookupAddressLocations(String rawAddress) async {
    final queries = RiderLaunchScope.buildSearchQueries(
      rawAddress,
      preferredCity: _selectedLaunchCity,
    );

    for (final query in queries) {
      try {
        final locations = await locationFromAddress(query);
        if (locations.isNotEmpty) {
          return locations;
        }
      } catch (error) {
        _logRideFlow('address lookup failed query="$query" error=$error');
      }
    }

    return const <Location>[];
  }

  List<NativePlaceSuggestion> _fallbackPlaceSuggestions(String query) {
    final suggestions = RiderLaunchScope.buildFallbackSearchSuggestions(
      query,
      preferredCity: _selectedLaunchCity,
    );
    return suggestions
        .map(
          (suggestion) => NativePlaceSuggestion.manual(
            primaryText: suggestion.primaryText,
            secondaryText: suggestion.secondaryText,
            fullText: suggestion.fullText,
          ),
        )
        .toList(growable: false);
  }

  Future<void> _moveCameraToSelectedPoint(LatLng point) async {
    if (_mapReady && _mapController != null) {
      await _mapController!.animateCamera(
        CameraUpdate.newLatLngZoom(point, 16),
      );
    }
  }

  Future<void> _handleAdditionalStopSelection({
    required NativePlaceSuggestion suggestion,
    required int extraStopIndex,
  }) async {
    final description = suggestion.fullText.trim();
    if (description.isEmpty) {
      return;
    }

    try {
      final point = await _resolvePlaceLocation(
        suggestion: suggestion,
        description: description,
      );
      if (point == null) {
        _showSnackBar('Unable to resolve that location.');
        return;
      }

      _additionalStopAddresses[extraStopIndex] = description;
      _additionalStopLocations[extraStopIndex] = point;
      _additionalStopControllers[extraStopIndex].text = description;
      await _syncLaunchCityFromSelection(
        source: 'stop_${extraStopIndex + 2}',
        addressHint: description,
        point: point,
      );
      _syncTripLocationMarkers();

      if (mounted) {
        setState(() {});
      }

      await _ensureRouteMetrics();
      if (_pickupLocation == null || _orderedDropOffLocations().isEmpty) {
        await _moveCameraToSelectedPoint(point);
      }
    } catch (error) {
      _logRideFlow(
        'place selection failed field=stop_${extraStopIndex + 2} error=$error',
      );
      _showSnackBar('Unable to use that location right now.');
    }
  }

  Future<void> _handlePlaceSelection({
    required NativePlaceSuggestion suggestion,
    required bool isPickup,
  }) async {
    final description = suggestion.fullText.trim();
    _logRideFlow(
      'search selection tapped field=${isPickup ? 'pickup' : 'destination'} query="$description" placeId=${suggestion.placeId}',
    );
    if (description.isEmpty) {
      return;
    }

    try {
      final point = await _resolvePlaceLocation(
        suggestion: suggestion,
        description: description,
      );
      if (point == null) {
        _showSnackBar('Unable to resolve that location.');
        return;
      }

      if (isPickup) {
        _pickupAddress = description;
        _pickupLocation = point;
        _pickupController.text = description;
      } else {
        _destinationAddress = description;
        _destinationLocation = point;
        _destinationController.text = description;
      }

      await _syncLaunchCityFromSelection(
        source: isPickup ? 'pickup' : 'destination',
        addressHint: description,
        point: point,
      );
      if (isPickup) {
        unawaited(_maybeSyncRolloutSelectionToPickup(point));
      }
      _syncTripLocationMarkers();

      if (mounted) {
        setState(() {});
      }

      await _ensureRouteMetrics();
      _logRideFlow(
        'search selection applied field=${isPickup ? 'pickup' : 'destination'} point=${_formatLatLng(point)} fare=$_fare distanceKm=${_distanceKm.toStringAsFixed(2)}',
      );
      if (_pickupLocation == null || _orderedDropOffLocations().isEmpty) {
        await _moveCameraToSelectedPoint(point);
      }
    } catch (error) {
      _logRideFlow(
        'place selection failed field=${isPickup ? 'pickup' : 'destination'} error=$error',
      );
      _showSnackBar('Unable to use that location right now.');
    }
  }

  void _addStopField() {
    if (_extraStopFieldCount >= _additionalStopControllers.length) {
      _logRideFlow('multi-stop validation blocked max=$_maxDropOffs');
      _showSnackBar('You can add up to 3 total drop-offs.');
      return;
    }

    if (mounted) {
      setState(() {
        _extraStopFieldCount += 1;
      });
    } else {
      _extraStopFieldCount += 1;
    }
  }

  Future<void> _removeAdditionalStopField(int extraStopIndex) async {
    if (extraStopIndex < 0 || extraStopIndex >= _extraStopFieldCount) {
      return;
    }

    for (
      var i = extraStopIndex;
      i < _additionalStopControllers.length - 1;
      i++
    ) {
      if (i + 1 >= _extraStopFieldCount) {
        break;
      }

      _additionalStopControllers[i].text =
          _additionalStopControllers[i + 1].text;
      _additionalStopAddresses[i] = _additionalStopAddresses[i + 1];
      _additionalStopLocations[i] = _additionalStopLocations[i + 1];
    }

    final lastVisibleIndex = _extraStopFieldCount - 1;
    _additionalStopControllers[lastVisibleIndex].clear();
    _additionalStopAddresses[lastVisibleIndex] = '';
    _additionalStopLocations[lastVisibleIndex] = null;

    if (mounted) {
      setState(() {
        _extraStopFieldCount = max(0, _extraStopFieldCount - 1);
      });
    } else {
      _extraStopFieldCount = max(0, _extraStopFieldCount - 1);
    }

    await _ensureRouteMetrics();
  }

  bool get _rolloutSelectionComplete =>
      (_rolloutRegionId ?? '').trim().isNotEmpty &&
      (_rolloutCityId ?? '').trim().isNotEmpty &&
      (_rolloutDispatchMarketId ?? '').trim().isNotEmpty;

  Future<void> _loadRolloutCatalogForRider() async {
    final uid = FirebaseAuth.instance.currentUser?.uid.trim();
    if (uid == null || uid.isEmpty) {
      return;
    }
    if (mounted) {
      setState(() {
        _rolloutCatalogLoading = true;
        _rolloutCatalogError = null;
      });
    } else {
      _rolloutCatalogLoading = true;
      _rolloutCatalogError = null;
    }
    try {
      final raw = await _rideCloud
          .listDeliveryRegions()
          .timeout(const Duration(seconds: 22));
      final regions = parseRolloutRegionsResponse(raw);
      if (raw['success'] != true) {
        throw StateError('listDeliveryRegions_failed');
      }
      final saved = await RiderRolloutProfileStore.instance.fetchSelection(uid);
      var rid = saved?[RiderRolloutProfileStore.kRegionId] ?? '';
      var cid = saved?[RiderRolloutProfileStore.kCityId] ?? '';
      var dm = saved?[RiderRolloutProfileStore.kDispatchMarketId] ?? '';
      if (rid.isNotEmpty &&
          regions.any((r) => r.regionId == rid)) {
        final reg = regions.firstWhere((r) => r.regionId == rid);
        if (!reg.cities.any((c) => c.cityId == cid)) {
          cid = '';
        }
        if (reg.dispatchMarketId.trim().isNotEmpty) {
          dm = reg.dispatchMarketId.trim();
        }
      } else {
        rid = '';
        cid = '';
        dm = '';
      }
      if (!mounted) {
        _rolloutCatalog = regions;
        _rolloutRegionId = rid.isEmpty ? null : rid;
        _rolloutCityId = cid.isEmpty ? null : cid;
        _rolloutDispatchMarketId = dm.isEmpty ? null : dm;
        _rolloutCatalogLoading = false;
        _rolloutCatalogHydrated = true;
        _rolloutCatalogError = null;
        if (_rolloutSelectionComplete) {
          _selectedLaunchCity =
              RiderServiceAreaConfig.marketForCity(_rolloutDispatchMarketId).city;
        }
        return;
      }
      setState(() {
        _rolloutCatalog = regions;
        _rolloutRegionId = rid.isEmpty ? null : rid;
        _rolloutCityId = cid.isEmpty ? null : cid;
        _rolloutDispatchMarketId = dm.isEmpty ? null : dm;
        _rolloutCatalogLoading = false;
        _rolloutCatalogHydrated = true;
        _rolloutCatalogError = null;
        if (_rolloutSelectionComplete) {
          _selectedLaunchCity =
              RiderServiceAreaConfig.marketForCity(_rolloutDispatchMarketId).city;
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _rolloutCatalogLoading = false;
          _rolloutCatalogHydrated = true;
          _rolloutCatalogError = e;
        });
      } else {
        _rolloutCatalogLoading = false;
        _rolloutCatalogHydrated = true;
        _rolloutCatalogError = e;
      }
    }
  }

  Future<void> _openRiderRolloutAreaSheet() async {
    if (!mounted) {
      return;
    }
    await RiderRolloutAreaSheet.show(
      context,
      regions: _rolloutCatalog,
      initialRegionId: _rolloutRegionId,
      initialCityId: _rolloutCityId,
      onReloadCatalog: () async {
        final uid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
        if (uid.isEmpty) {
          return const <RolloutDeliveryRegionModel>[];
        }
        final raw = await _rideCloud
            .listDeliveryRegions()
            .timeout(const Duration(seconds: 22));
        if (raw['success'] != true) {
          throw StateError('listDeliveryRegions_failed');
        }
        final regions = parseRolloutRegionsResponse(raw);
        if (mounted) {
          setState(() {
            _rolloutCatalog = regions;
            _rolloutCatalogError = null;
          });
        }
        return regions;
      },
    );
    await _refreshRiderRolloutAfterSheetSave();
  }

  Future<void> _refreshRiderRolloutAfterSheetSave() async {
    await _loadRolloutCatalogForRider();
    if (!mounted || !_rolloutSelectionComplete) {
      return;
    }
    try {
      final vr = await _rideCloud
          .validateServiceLocation(
            regionId: _rolloutRegionId!.trim(),
            cityId: _rolloutCityId!.trim(),
            service: 'rides',
          )
          .timeout(const Duration(seconds: 20));
      if (!mounted) {
        return;
      }
      if (riderRideCallableSucceeded(vr)) {
        _showSnackBar('Service area saved.');
      } else {
        _showSnackBar(RolloutCopy.notAvailableInArea);
      }
    } catch (_) {
      if (mounted) {
        _showSnackBar(
          'Could not verify your area yet. Check connection and try again.',
        );
      }
    }
    if (mounted) {
      setState(() {});
    }
  }

  /// When the server resolves a rollout from GPS (hint bubble mismatch), persist it so
  /// the next request uses the same service city the backend enforced.
  Future<void> _persistResolvedRolloutFromServerResponse(
    Map<String, dynamic> res,
  ) async {
    final uid = FirebaseAuth.instance.currentUser?.uid.trim();
    if (uid == null || uid.isEmpty) {
      return;
    }
    final region = _firstNonEmptyText(<dynamic>[
      res['resolved_service_region_id'],
      res['resolved_rollout_region_id'],
    ]);
    final city = _firstNonEmptyText(<dynamic>[
      res['resolved_service_city_id'],
      res['resolved_rollout_city_id'],
    ]);
    final market = _firstNonEmptyText(<dynamic>[
      res['resolved_dispatch_market_id'],
    ]);
    if (region.isEmpty || city.isEmpty || market.isEmpty) {
      return;
    }
    try {
      await RiderRolloutProfileStore.instance.saveSelection(
        uid: uid,
        regionId: region,
        cityId: city,
        dispatchMarketId: market,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _rolloutRegionId = region;
        _rolloutCityId = city;
        _rolloutDispatchMarketId = market;
        _selectedLaunchCity =
            RiderServiceAreaConfig.marketForCity(market).city;
      });
    } catch (error) {
      _logRideFlow('resolved rollout persist skipped error=$error');
    }
  }

  Future<void> _maybeSyncRolloutSelectionToPickup(LatLng point) async {
    if (!_rolloutCatalogHydrated ||
        _rolloutCatalog.isEmpty ||
        !_rolloutSelectionComplete) {
      return;
    }
    final match = matchRideAreaForPickupCoordinates(
      _rolloutCatalog,
      lat: point.latitude,
      lng: point.longitude,
    );
    if (match == null) {
      return;
    }
    final curR = (_rolloutRegionId ?? '').trim();
    final curC = (_rolloutCityId ?? '').trim();
    if (curR == match.regionId && curC == match.cityId) {
      return;
    }
    final uid = FirebaseAuth.instance.currentUser?.uid.trim();
    if (uid == null || uid.isEmpty) {
      return;
    }
    try {
      await RiderRolloutProfileStore.instance.saveSelection(
        uid: uid,
        regionId: match.regionId,
        cityId: match.cityId,
        dispatchMarketId: match.dispatchMarketId,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _rolloutRegionId = match.regionId;
        _rolloutCityId = match.cityId;
        _rolloutDispatchMarketId = match.dispatchMarketId;
        _selectedLaunchCity =
            RiderServiceAreaConfig.marketForCity(match.dispatchMarketId).city;
      });
      _logRideFlow(
        'rollout auto-synced to pickup city=${match.cityId} region=${match.regionId}',
      );
    } catch (e) {
      _logRideFlow('rollout auto-sync skipped error=$e');
    }
  }

  Future<void> _applySuggestedServiceAreaFromCreateResponse(
    Map<String, dynamic> res,
  ) async {
    final uid = FirebaseAuth.instance.currentUser?.uid.trim();
    if (uid == null || uid.isEmpty) {
      return;
    }
    final region = _firstNonEmptyText(<dynamic>[
      res['suggested_service_region_id'],
    ]);
    final city = _firstNonEmptyText(<dynamic>[
      res['suggested_service_area_id'],
    ]);
    final market = _firstNonEmptyText(<dynamic>[
      res['suggested_dispatch_market_id'],
    ]);
    if (region.isEmpty || city.isEmpty || market.isEmpty) {
      return;
    }
    try {
      await RiderRolloutProfileStore.instance.saveSelection(
        uid: uid,
        regionId: region,
        cityId: city,
        dispatchMarketId: market,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _rolloutRegionId = region;
        _rolloutCityId = city;
        _rolloutDispatchMarketId = market;
        _selectedLaunchCity = RiderServiceAreaConfig.marketForCity(market).city;
      });
    } catch (e) {
      _logRideFlow('apply suggested rollout failed error=$e');
    }
  }

  Future<void> _applySuggestedServiceAreaThenAck(Map<String, dynamic> res) async {
    await _applySuggestedServiceAreaFromCreateResponse(res);
    if (!mounted) {
      return;
    }
    _showSnackBar(
      'Service area updated to match your pickup. Request your ride again when ready.',
    );
  }

  bool _handleRideCreateStructuredFailure(Map<String, dynamic> res) {
    final reason = riderRideCallableReason(res);
    if (reason == 'pickup_outside_selected_service_area') {
      final areaName = _firstNonEmptyText(<dynamic>[
        res['suggested_service_area_name'],
        res['suggested_service_area_id'],
      ], fallback: 'another NexRide area');
      if (!mounted) {
        return true;
      }
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) {
        return true;
      }
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Switch to the service area that contains this pickup ($areaName).',
          ),
          action: SnackBarAction(
            label: 'SWITCH AREA',
            onPressed: () {
              unawaited(_applySuggestedServiceAreaThenAck(res));
            },
          ),
        ),
      );
      return true;
    }
    if (reason == 'no_service_area_for_pickup') {
      _showSnackBar(
        riderIdentityServerRejectionUserMessage(reason) ??
            'NexRide is not available in this pickup area yet.',
      );
      return true;
    }
    if (reason == 'location_required_for_service_area' ||
        reason == 'location_required') {
      _showSnackBar(
        riderIdentityServerRejectionUserMessage(reason) ??
            RiderLaunchScope.currentLocationPrompt,
      );
      return true;
    }
    if (RiderBackendPricingQuote.isPricingTotalMismatch(res)) {
      _showSnackBar(RiderBackendPricingQuote.pricingMismatchUserMessage(res));
      unawaited(_refreshRoutePreviewAfterPricingMismatch());
      return true;
    }
    return false;
  }

  Future<void> _refreshRoutePreviewAfterPricingMismatch() async {
    if (_pickupLocation == null || _destinationLocation == null) {
      return;
    }
    await _ensureRouteMetrics();
  }

  Future<String?> _validateRideCreationInputs() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      _logRideFlow('request blocked: current user missing');
      _showSnackBar('Please log in before requesting a ride.');
      return null;
    }

    if (!_rolloutCatalogHydrated) {
      await _loadRolloutCatalogForRider();
    }
    if (_rolloutCatalogHydrated) {
      if (_rolloutCatalogError != null) {
        _showSnackBar(
          'Could not load service areas. Tap “Your area” to retry.',
        );
        return null;
      }
      if (_rolloutCatalog.isEmpty) {
        _showSnackBar(RolloutCopy.notAvailableInArea);
        return null;
      }
      if (!_rolloutSelectionComplete) {
        _showSnackBar('Select your service area before requesting a ride.');
        return null;
      }
    }

    if (_pickupLocation != null &&
        _rolloutCatalogHydrated &&
        _rolloutCatalog.isNotEmpty &&
        _rolloutSelectionComplete) {
      await _maybeSyncRolloutSelectionToPickup(_pickupLocation!);
    }

    final typedPickup = _pickupController.text.trim();
    if (_pickupLocation == null) {
      _logRideFlow('request blocked: pickup location missing');
      _showSnackBar(
        typedPickup.isEmpty
            ? RiderLaunchScope.currentLocationPrompt
            : 'Choose a valid pickup location in ${RiderLaunchScope.launchCitiesLabel} before requesting a ride.',
      );
      return null;
    }

    if (_destinationLocation == null) {
      _logRideFlow('request blocked: destination location missing');
      _showSnackBar(
        'Choose a valid destination in ${RiderLaunchScope.launchCitiesLabel} before requesting a ride.',
      );
      return null;
    }

    for (var i = 0; i < _extraStopFieldCount; i++) {
      final rawText = _additionalStopControllers[i].text.trim();
      if (rawText.isNotEmpty && _additionalStopLocations[i] == null) {
        _logRideFlow('request blocked: stop_${i + 2} location missing');
        _showSnackBar(
          'Choose a valid location in ${RiderLaunchScope.launchCitiesLabel} for Stop ${i + 2}.',
        );
        return null;
      }
    }

    final selectedCity = RiderLaunchScope.normalizeSupportedCity(
      _selectedLaunchCity,
    );
    final pickupMatch = matchRideAreaForPickupCoordinates(
      _rolloutCatalog,
      lat: _pickupLocation!.latitude,
      lng: _pickupLocation!.longitude,
    );
    final destMatch = matchRideAreaForPickupCoordinates(
      _rolloutCatalog,
      lat: _destinationLocation!.latitude,
      lng: _destinationLocation!.longitude,
    );

    String? pickupCity;
    String? destinationCity;
    if (pickupMatch != null && destMatch != null) {
      if (pickupMatch.dispatchMarketId != destMatch.dispatchMarketId) {
        _logRideFlow(
          'request blocked: cross-market trip pickup_market=${pickupMatch.dispatchMarketId} '
          'destination_market=${destMatch.dispatchMarketId}',
        );
        _showSnackBar(
          'Pickup and destination must stay within the same launch city for now.',
        );
        return null;
      }
      pickupCity =
          RiderServiceAreaConfig.marketForCity(pickupMatch.dispatchMarketId).city;
      destinationCity = pickupCity;
    } else {
      pickupCity = _normalizeServiceCity(_pickupAddress) ?? selectedCity;
      destinationCity =
          _normalizeServiceCity(_destinationAddress) ??
          pickupCity ??
          selectedCity;
      if (pickupCity == null || destinationCity == null) {
        _logRideFlow(
          'request blocked: unsupported city pickup=$pickupCity destination=$destinationCity selected=$selectedCity',
        );
        _showSnackBar(
          'Pickup and destination must both be in ${RiderLaunchScope.launchCitiesLabel} before requesting a ride.',
        );
        return null;
      }
      if (pickupCity != destinationCity) {
        _logRideFlow(
          'request blocked: cross-city trip pickup=$pickupCity destination=$destinationCity',
        );
        _showSnackBar(
          'Pickup and destination must stay within the same launch city for now.',
        );
        return null;
      }
    }

    return pickupCity;
  }

  Future<void> createRideRequest() async {
    print('CREATE_RIDE_REQUEST_START');
    print('CHECKING BLOCKERS');
    if (_isCreatingRide) {
      print('BLOCKED_REASON: isCreatingRide');
      _logRideFlow(
        'createRideRequest skipped isCreatingRide=$_isCreatingRide '
        'currentRideId=$_currentRideId status=$_rideStatus',
      );
      return;
    }

    final accessDecision = await _ensureTripRequestAllowed();
    if (accessDecision == null) {
      print('BLOCKED_REASON: trust_validation');
      _logRideFlow(
        'REQUEST RIDE validation failed reason=trust_validation',
      );
      return;
    }

    if (_selfieBlocksBooking) {
      final msg = _riderFirestoreCompliance != null
          ? riderRequestButtonIdentityBlockSubtitle(_riderFirestoreCompliance!)
          : 'Complete identity verification before booking.';
      _showSnackBar(msg);
      _logRideFlow('createRideRequest blocked reason=identity_gate');
      return;
    }

    final city = await _validateRideCreationInputs();
    if (city == null) {
      print('BLOCKED_REASON: input_validation');
      _logRideFlow(
        'REQUEST RIDE validation failed reason=input_validation',
      );
      return;
    }

    if (_rolloutSelectionComplete) {
      try {
        final vr = await _rideCloud
            .validateServiceLocation(
              regionId: _rolloutRegionId!.trim(),
              cityId: _rolloutCityId!.trim(),
              service: 'rides',
            )
            .timeout(const Duration(seconds: 20));
        if (!riderRideCallableSucceeded(vr)) {
          _showSnackBar(RolloutCopy.notAvailableInArea);
          _logRideFlow('createRideRequest blocked reason=rollout_validate');
          return;
        }
      } catch (e) {
        _showSnackBar(
          'Could not verify your area. Check connection and try again.',
        );
        _logRideFlow('createRideRequest blocked reason=rollout_validate_error');
        return;
      }
    }

    final orderedStops = _buildStopsPayload();
    if (orderedStops.isEmpty) {
      print('BLOCKED_REASON: stops_payload_empty');
      _logRideFlow('request blocked: unable to build stops payload');
      _showSnackBar('Choose a valid destination before requesting a ride.');
      return;
    }

    final finalStop = orderedStops.last;
    final pickupPayloadBase = _buildRideRequestLocationPayload(
      lat: _pickupLocation?.latitude,
      lng: _pickupLocation?.longitude,
      address: _pickupAddress,
      fieldLabel: 'pickup',
    );
    if (pickupPayloadBase == null) {
      print('BLOCKED_REASON: pickup_payload_invalid');
      return;
    }

    final destinationPayloadBase = _buildRideRequestLocationPayload(
      lat: _asDouble(finalStop['lat']),
      lng: _asDouble(finalStop['lng']),
      address: finalStop['address']?.toString() ?? '',
      fieldLabel: 'destination',
    );
    if (destinationPayloadBase == null) {
      print('BLOCKED_REASON: destination_payload_invalid');
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      print('BLOCKED_REASON: no_auth_user');
      _logRideFlow('createRideRequest blocked reason=no_auth_user');
      rtdbFlowLog(
        '[NEXRIDE_RIDER_RTDB][AUTH]',
        'createRideRequest blocked reason=no_auth_user',
      );
      _showSnackBar('Please sign in before requesting a ride.');
      return;
    }

    if (await _blockIfBankTransferReceiptPending(user.uid)) {
      return;
    }

    setState(() {
      _isCreatingRide = true;
      _driverFound = false;
      _tripStarted = false;
    });

    String? rideId;
    Map<String, dynamic>? debugCreatePayload;
    var resumedExistingActiveTrip = false;
    try {
      _rideRequestUserAborted = false;
      await _ensureRiderProfileExistsBeforeRequest(user.uid);
      _logRideFlow(
        'REQUEST RIDE validation passed city=$city routeReady=$_hasRoutePreviewReady fare=$_fare distanceKm=$_distanceKm durationMin=$_estimatedDurationMin',
      );
      _logRideFlow('request validation passed city=$city');

      // Safety: if an active trip pointer exists, resume or clear stale pointer before creating a new ride.
      final precheck = await _precheckRiderActiveTripPointerBeforeCreate();
      if (precheck == _ActiveTripPrecheckOutcome.resumed) {
        _logRideFlow('REQUEST RIDE precheck outcome=resumed_active_trip');
        return;
      }
      // Canonical slug must match driver `orderByChild('market_pool').equalTo(...)` byte-for-byte.
      var dispatchMarket =
          RiderServiceAreaConfig.marketForCity(city).city.trim().toLowerCase();
      if (_rolloutSelectionComplete &&
          (_rolloutDispatchMarketId ?? '').trim().isNotEmpty) {
        dispatchMarket = RiderServiceAreaConfig.marketForCity(
          _rolloutDispatchMarketId,
        ).city.trim().toLowerCase();
      }
      if (dispatchMarket.isEmpty) {
        dispatchMarket = 'lagos';
      }
      if (dispatchMarket != city) {
        _logRideFlow(
          'REQUEST RIDE market canonicalized for RTDB from=$city to=$dispatchMarket',
        );
      }
      final normalizedPaymentMethod = _riderTripPaymentMethod.trim().isEmpty
          ? 'flutterwave'
          : _riderTripPaymentMethod.trim().toLowerCase();
      if (normalizedPaymentMethod != _riderTripPaymentMethod.trim().toLowerCase() &&
          kDebugMode) {
        debugPrint(
          '[RIDER_CREATE_DEBUG] payment method defaulted '
          'from=${_riderTripPaymentMethod.trim()} to=$normalizedPaymentMethod',
        );
      }
      if (_routePreviewError != null ||
          _expectedRoutePoints.length < 2 ||
          _distanceKm <= 0 ||
          _estimatedDurationMin <= 0 ||
          _fare <= 0) {
        print('BLOCKED_REASON: route_or_fare_not_ready');
        _showSnackBar(
          'We could not load the live road route yet. Please retry.',
        );
        if (mounted) {
          setState(() {
            _rideStatus = 'idle';
            _searchingDriver = false;
            _isCreatingRide = false;
          });
        } else {
          _rideStatus = 'idle';
          _searchingDriver = false;
          _isCreatingRide = false;
        }
        return;
      }

      final pmGate =
          normalizedPaymentMethod.replaceAll(RegExp(r'[\s-]+'), '_');
      if (pmGate != 'bank_transfer') {
        final linked = await _riderHasLinkedPaymentMethod(user.uid);
        if (!linked) {
          if (mounted) {
            setState(() {
              _isCreatingRide = false;
            });
          } else {
            _isCreatingRide = false;
          }
          await _showLinkCardRequiredDialog();
          return;
        }
      }

      await _rideListener?.cancel();
      _rideListener = null;
      _activeRideListenerRideId = null;
      _pendingRideRequestSubmissionId = null;

      final stops = _buildIntermediateStopsPayload(orderedStops);
      final stopCount = orderedStops.length;
      final pickupAddress = _rideRequestAddressLabel(
        _pickupAddress,
        fallback: 'Selected pickup',
      );
      final destinationAddress = _rideRequestAddressLabel(
        finalStop['address']?.toString() ?? _destinationAddress,
        fallback: 'Selected destination',
      );
      final expectedRoutePoints = List<LatLng>.from(_expectedRoutePoints);
      final expectedRoutePayload = expectedRoutePoints
          .map(
            (LatLng point) => <String, double>{
              'lat': point.latitude,
              'lng': point.longitude,
            },
          )
          .toList();

      _logRideFlow('creating ride stopCount=$stopCount');
      _logRideFlow(
        'destination set to final stop lat=${finalStop['lat']} lng=${finalStop['lng']}',
      );
      _logRideFlow('stops count=${stops.length}');
      final searchTimeoutAt =
          DateTime.now().millisecondsSinceEpoch +
          _rideSearchTimeoutDuration.inMilliseconds;
      RiderFareRule? livePricingRule;
      try {
        livePricingRule = await RegionPricingService.instance.ruleForCity(dispatchMarket);
      } catch (_) {
        livePricingRule = RiderFareSettings.maybeForCity(dispatchMarket);
      }
      final fareBreakdown = calculateRiderFare(
        serviceKey: RiderServiceType.ride.key,
        city: dispatchMarket,
        distanceKm: _distanceKm,
        durationMin: _estimatedDurationMin,
        liveRule: livePricingRule,
      );
      final pickupScope = _buildServiceAreaFields(city: dispatchMarket, area: '');
      final destinationScope =
          _buildServiceAreaFields(city: dispatchMarket, area: '');
      final rideScope = _buildServiceAreaFields(city: dispatchMarket, area: '');
      final pickupPayload = <String, dynamic>{
        ...pickupPayloadBase,
        'address': pickupAddress,
        ...pickupScope,
      };
      final destinationPayload = <String, dynamic>{
        ...destinationPayloadBase,
        'address': destinationAddress,
        ...destinationScope,
      };

      final canonicalSeed = <String, dynamic>{
        'service_type': RiderServiceType.ride.key,
        'rider_id': user.uid,
        'driver_id': 'waiting',
        // Keep rider discovery seed aligned with driver query and post-filter expectations.
        'status': 'requesting',
        'trip_state': 'requesting',
        'state_machine_version': TripStateMachine.schemaVersion,
        'market': dispatchMarket,
        RtdbRideRequestFields.marketPool: dispatchMarket,
        // Same canonical slug as [market]; driver discovery uses [market_pool].
        'city': dispatchMarket,
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
        'pickup': pickupPayload,
        'destination': destinationPayload,
        'final_destination': {'lat': finalStop['lat'], 'lng': finalStop['lng']},
        'pickup_address': pickupAddress,
        'destination_address': destinationAddress,
        'final_destination_address': destinationAddress,
        'stops': stops,
        'stop_count': stopCount,
        'fare': fareBreakdown.totalFare,
        'distance_km': fareBreakdown.distanceKm,
        'duration_min': fareBreakdown.durationMin,
        RtdbRideRequestFields.etaMin: fareBreakdown.durationMin,
        'dropoff': destinationPayload,
        'payment_method': normalizedPaymentMethod,
        RtdbRideRequestFields.paymentStatus: 'pending',
        'settlement_status': 'pending',
        'support_status': 'normal',
        'accepted_at': null,
        'cancelled_at': null,
        'completed_at': null,
        'cancel_reason': '',
        'fare_breakdown': fareBreakdown.toMap(),
        'rider_trust_snapshot': <String, dynamic>{
          'verificationStatus':
              accessDecision.toMap()['restrictionCode'] == '' &&
                  (_trustSummary['verificationStatus']?.toString().isNotEmpty ??
                      false)
              ? _trustSummary['verificationStatus']
              : _verification['overallStatus'],
          'verifiedBadge': _trustSummary['verifiedBadge'] == true,
          'rating': _reputation['averageRating'] ?? 5.0,
          'ratingCount': _reputation['ratingCount'] ?? 0,
          'cashAccessStatus': 'restricted',
          'riskStatus':
              _trustSummary['riskStatus'] ?? _riskFlags['status'] ?? 'clear',
        },
        'route_basis': <String, dynamic>{
          'country': rideScope['country'],
          'country_code': rideScope['country_code'],
          'market': dispatchMarket,
          'area': rideScope['area'],
          'zone': rideScope['zone'],
          'community': rideScope['community'],
          'pickup_scope': pickupScope,
          'destination_scope': destinationScope,
          'pickup_address': pickupAddress,
          'destination_address': destinationAddress,
          'stops': stops,
          'stop_count': stopCount,
          'distance_km': fareBreakdown.distanceKm,
          'duration_min': fareBreakdown.durationMin,
          'fare_estimate': fareBreakdown.totalFare,
          'fare_breakdown': fareBreakdown.toMap(),
          'expected_route_points': expectedRoutePayload,
        },
        'created_at': rtdb.ServerValue.timestamp,
        'requested_at': rtdb.ServerValue.timestamp,
        'updated_at': rtdb.ServerValue.timestamp,
        'payment_context': <String, dynamic>{
          'method': normalizedPaymentMethod,
          'channel': normalizedPaymentMethod == 'bank_transfer'
              ? 'bank_transfer'
              : 'card',
        },
      };

      _logRideFlow('createRideRequest before write uid=${user.uid}');
      _logRideFlow(
        'createRideRequest before write pickup=${_formatLatLng(_pickupLocation)}',
      );
      _logRideFlow(
        'createRideRequest before write destination=${_formatLatLng(_destinationLocation)}',
      );
      _logRideFlow(
        'createRideRequest before write pickupPayload=$pickupPayload',
      );
      _logRideFlow(
        'createRideRequest before write destinationPayload=$destinationPayload',
      );
      _logRideFlow(
        'createRideRequest before write city=$city dispatchMarket=$dispatchMarket',
      );
      final searchTransition = TripStateMachine.buildTransitionUpdate(
        currentRide: canonicalSeed,
        nextCanonicalState: TripLifecycleState.searchingDriver,
        timestampValue: DateTime.now().millisecondsSinceEpoch,
        transitionSource: 'rider_request_search_start',
        transitionActor: 'rider',
      );
      final searchingPayload = <String, dynamic>{
        ...canonicalSeed,
        ...searchTransition,
        'search_timeout_at': searchTimeoutAt,
        'request_expires_at': searchTimeoutAt,
        RtdbRideRequestFields.expiresAt: searchTimeoutAt,
      };
      searchingPayload['driver_id'] = 'waiting';
      searchingPayload['market'] = dispatchMarket;
      searchingPayload['market_pool'] = dispatchMarket;
      rtdbFlowLog(
        '[NEXRIDE_RIDER_RTDB][CREATE_START]',
        'rideId=pending_callable uid=${user.uid} market=$dispatchMarket market_pool=$dispatchMarket',
      );
      _logRideFlow(
        '[RIDER_CREATE_START] rideId=pending_callable rider_id=${user.uid} '
        'market=$dispatchMarket status=${searchingPayload[RtdbRideRequestFields.status]} '
        'trip_state=${searchingPayload[RtdbRideRequestFields.tripState]}',
      );
      _logRideFlow('createRideRequest before callable (server assigns ride_id)');
      _logRideFlow('request payload prepared for callable');
      _logRideFlow('createRideRequest local preview payload=$searchingPayload');
      _logRideFlow(
        'REQUEST RIDE callable payload preview=$searchingPayload',
      );
      _logRideFlow(
        '[RIDER_CREATE] preview=$searchingPayload',
      );
      _logRideFlow(
        'REQUEST RIDE createRideRequest started (callable)',
      );
      _logRideFlow(
        '[MATCH_DEBUG][RIDER_CALLABLE_CREATE] '
        'status=${searchingPayload['status']} trip_state=${searchingPayload['trip_state']} '
        'market=${searchingPayload['market']} market_pool=${searchingPayload['market_pool']}',
      );
      if (_rideRequestUserAborted) {
        _logRideFlow(
          'createRideRequest user aborted before callable',
        );
        await _discardInFlightRideRequestSubmission();
        return;
      }
      _showSnackBar(RiderTripStatusMessages.creatingRide);
      _logRideFlow(
        '[RIDER_REQ] create_pre_callable '
        'market=${searchingPayload['market']} '
        'market_pool=${searchingPayload[RtdbRideRequestFields.marketPool]} '
        'status=${searchingPayload['status']} trip_state=${searchingPayload['trip_state']} '
        'driver_id=${searchingPayload['driver_id']} '
        'expires_at=${searchingPayload[RtdbRideRequestFields.expiresAt]} '
        'search_timeout_at=${searchingPayload['search_timeout_at']} '
        'request_expires_at=${searchingPayload['request_expires_at']}',
      );
      _logDiscoveryRideRequestPayload(
        'before_callable',
        'pending_callable',
        Map<String, dynamic>.from(searchingPayload),
      );
      debugPrint(
        'RIDER_CREATE_CALLABLE_START uid=${user.uid} market=$dispatchMarket '
        'fare=${fareBreakdown.totalFare} payment=${searchingPayload['payment_method']}',
      );
      final createPayload = <String, dynamic>{
        'market': dispatchMarket,
        'market_pool': dispatchMarket,
        if (_rolloutSelectionComplete) ...<String, dynamic>{
          'service_region_id': _rolloutRegionId!.trim(),
          'service_city_id': _rolloutCityId!.trim(),
          'rollout_region_id': _rolloutRegionId!.trim(),
          'rollout_city_id': _rolloutCityId!.trim(),
        },
        'rider_id': user.uid,
        'rider_name': _firstNonEmptyText(
          <dynamic>[
            _trustSummary['displayName'],
            _trustSummary['name'],
            FirebaseAuth.instance.currentUser?.displayName,
            FirebaseAuth.instance.currentUser?.email?.split('@').first,
          ],
          fallback: 'Rider',
        ),
        'pickup': pickupPayload,
        'dropoff': destinationPayload,
        'fare': fareBreakdown.totalFare,
        'currency': 'NGN',
        'distance_km': fareBreakdown.distanceKm,
        'eta_min': fareBreakdown.durationMin,
        'eta_minutes': fareBreakdown.durationMin,
        'payment_method': normalizedPaymentMethod,
        'status': 'requesting',
        'trip_state': 'requesting',
        'expires_at': searchTimeoutAt,
        'service_type': RiderServiceType.ride.key,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'ride_metadata': rideMetadataSubset(searchingPayload),
      };
      debugCreatePayload = Map<String, dynamic>.from(createPayload);
      if (kDebugMode) {
        debugPrint(
          '[RIDER_CREATE_DEBUG] callable_payload '
          'path=createRideRequest market=$dispatchMarket market_pool=$dispatchMarket '
          'payment=$normalizedPaymentMethod rider_id=${user.uid}',
        );
      }
      Map<String, dynamic> createRes;
      try {
        createRes = await _rideCloud
            .createRideRequest(createPayload)
            .timeout(const Duration(seconds: 45));
        if (_rideRequestUserAborted) {
          _logRideFlow(
            'createRideRequest user aborted right after callable',
          );
          final rid = _firstNonEmptyText(<dynamic>[
            createRes['rideId'],
            createRes['ride_id'],
          ]);
          if (rid.isNotEmpty) {
            await _discardInFlightRideRequestSubmission(rideId: rid);
          } else {
            await _discardInFlightRideRequestSubmission();
          }
          return;
        }
      } catch (error) {
        if (kDebugMode) {
          debugPrint(
            '[RIDER_CREATE_DEBUG] callable_exception '
            'type=${error.runtimeType} error=$error payload=$createPayload',
          );
        }
        rethrow;
      }
      if (kDebugMode) {
        debugPrint('[RIDER_CREATE_DEBUG] callable_response=$createRes');
      }
      if (!riderRideCallableSucceeded(createRes)) {
        if (_handleRideCreateStructuredFailure(
          Map<String, dynamic>.from(createRes),
        )) {
          return;
        }
        var reason = riderRideCallableReason(createRes);
        final recoveredRideId = _firstNonEmptyText(<dynamic>[
          createRes['rideId'],
          createRes['ride_id'],
        ]);
        if (kDebugMode) {
          debugPrint('RIDER_CREATE_CALLABLE_FAIL reason=$reason');
        }
        if (reason == 'rider_active_trip') {
          // Never crash the rider app on missing/invalid pointers.
          // If server returned a rideId, validate and resume it. Otherwise consult the RTDB pointer and resume/clear as needed.
          final effectiveRideId = recoveredRideId.isNotEmpty
              ? recoveredRideId
              : await _resolveRideIdFromRiderActiveTripPointer();
          if (effectiveRideId.isNotEmpty) {
            final recoveredSnap =
                await _rideRequestsRef.child(effectiveRideId).get();
            final recoveredData = _asStringDynamicMap(recoveredSnap.value);
            final recoveredCanonical =
                TripStateMachine.canonicalStateFromSnapshot(recoveredData);
            final recoveredRiderId = _valueAsText(recoveredData?['rider_id']);
            final recoveredStillOpen = recoveredData != null &&
                recoveredRiderId == user.uid &&
                !TripStateMachine.isTerminal(recoveredCanonical);
            if (recoveredStillOpen) {
              _logRideFlow(
                '[RIDER_REQ] create_recover_existing_ride '
                'reason=$reason rideId=$effectiveRideId',
              );
              rideId = effectiveRideId;
              resumedExistingActiveTrip = true;
              _showSnackBar('You already have an active ride. Resuming it now.');
            } else {
              _logRideFlow(
                '[RIDER_REQ] create_recover_existing_ride skipped '
                'reason=stale_or_terminal recoveredRideId=$effectiveRideId canonical=$recoveredCanonical',
              );
              await _clearRiderActiveTripPointerBestEffort();
              _showSnackBar('Refreshing trip session, please wait...');
              try {
                createRes = await _rideCloud
                    .createRideRequest(createPayload)
                    .timeout(const Duration(seconds: 45));
              } catch (error) {
                if (kDebugMode) {
                  debugPrint(
                    '[RIDER_CREATE_DEBUG] callable_retry_exception '
                    'type=${error.runtimeType} error=$error payload=$createPayload',
                  );
                }
                rethrow;
              }
              if (!riderRideCallableSucceeded(createRes)) {
                final retryReason = riderRideCallableReason(createRes);
                _logRideFlow(
                  '[RIDER_REQ] create_retry_failed reason=$retryReason',
                );
                if (_handleRideCreateStructuredFailure(
                  Map<String, dynamic>.from(createRes),
                )) {
                  return;
                }
                _showSnackBar(
                  _rideRequestErrorMessage(StateError(retryReason)),
                );
                return;
              }
              rideId = _firstNonEmptyText(<dynamic>[
                createRes['rideId'],
                createRes['ride_id'],
              ]);
            }
          } else {
            // Pointer missing: treat as no active trip; retry once.
            await _clearRiderActiveTripPointerBestEffort();
            try {
              createRes = await _rideCloud
                  .createRideRequest(createPayload)
                  .timeout(const Duration(seconds: 45));
            } catch (error) {
              if (kDebugMode) {
                debugPrint(
                  '[RIDER_CREATE_DEBUG] callable_retry_no_pointer_exception '
                  'type=${error.runtimeType} error=$error payload=$createPayload',
                );
              }
              rethrow;
            }
            if (!riderRideCallableSucceeded(createRes)) {
              final retryReason = riderRideCallableReason(createRes);
              _logRideFlow('[RIDER_REQ] create_retry_failed reason=$retryReason');
              if (_handleRideCreateStructuredFailure(
                Map<String, dynamic>.from(createRes),
              )) {
                return;
              }
              _showSnackBar(_rideRequestErrorMessage(StateError(retryReason)));
              return;
            }
            rideId = _firstNonEmptyText(<dynamic>[
              createRes['rideId'],
              createRes['ride_id'],
            ]);
          }
        } else {
          if (_handleRideCreateStructuredFailure(
            Map<String, dynamic>.from(createRes),
          )) {
            return;
          }
          throw StateError(reason);
        }
      } else {
        if (kDebugMode) {
          debugPrint('RIDER_CREATE_CALLABLE_SUCCESS response=$createRes');
        }
        rideId = _firstNonEmptyText(<dynamic>[
          createRes['rideId'],
          createRes['ride_id'],
        ]);
      }
      unawaited(
        _persistResolvedRolloutFromServerResponse(
          Map<String, dynamic>.from(createRes),
        ),
      );
      if (rideId.isEmpty) {
        throw StateError('missing_ride_id_in_create_response');
      }
      if (_rideRequestUserAborted) {
        _logRideFlow(
          'createRideRequest user aborted after callable rideId=$rideId',
        );
        await _discardInFlightRideRequestSubmission(rideId: rideId);
        return;
      }
      await _prepaidRecoveryStore.clearPendingTxRef();
      _pendingRideRequestSubmissionId = rideId;
      var movedToSearching = false;
      Map<String, dynamic> committedRideData;
      if (resumedExistingActiveTrip) {
        committedRideData = await _awaitRideSnapshotForActiveTripResume(rideId);
      } else {
        final verifySnapshot = await _rideRequestsRef.child(rideId).get().timeout(
              const Duration(seconds: 18),
            );
        if (!verifySnapshot.exists) {
          throw StateError('ride_missing_after_create');
        }
        final parsed = _asStringDynamicMap(verifySnapshot.value);
        if (parsed == null) {
          throw StateError('ride_invalid_after_create');
        }
        committedRideData = parsed;
      }
      await _syncRideOperationalViews(
        rideId: rideId,
        rideData: Map<String, dynamic>.from(committedRideData),
        lastEvent: 'rider_create',
      );
      if (_rideRequestUserAborted) {
        _logRideFlow(
          'createRideRequest user aborted after sync rideId=$rideId',
        );
        await _discardInFlightRideRequestSubmission(rideId: rideId);
        return;
      }
      _logDiscoveryRideRequestPayload(
        'after_callable',
        rideId,
        Map<String, dynamic>.from(committedRideData),
      );
      {
        final eff = Map<String, dynamic>.from(
          committedRideData,
        );
        _logRideFlow(
          '[RIDER_REQ] create_post_write_payment_lock_subset rideId=$rideId '
          'payment_method=${eff['payment_method']} '
          'payment_status=${eff[RtdbRideRequestFields.paymentStatus]} '
          'status=${eff['status']} trip_state=${eff['trip_state']} '
          'driver_id=${eff['driver_id']} market=${eff['market']} '
          'market_pool=${eff[RtdbRideRequestFields.marketPool]}',
        );
      }
      if (!_ridePaymentVerified(committedRideData)) {
        final pmNorm = _valueAsText(committedRideData['payment_method'])
            .trim()
            .toLowerCase()
            .replaceAll(RegExp(r'[\s-]+'), '_');
        if (pmNorm == 'bank_transfer') {
          final bankOk = await _registerBankTransferAndPoll(rideId);
          if (!bankOk) {
            await _clearStaleActiveTripArtifacts(
              rideId: rideId,
              reason: 'bank_transfer_abandoned',
            );
            _clearRideSearchTimeout(reason: 'bank_transfer_registration_failed');
            _pendingRideRequestSubmissionId = null;
            await _resetRideState(clearDestination: true);
            return;
          }
          final postBankSnap = await _rideRequestsRef.child(rideId).get().timeout(
                const Duration(seconds: 18),
              );
          final postBankParsed = _asStringDynamicMap(postBankSnap.value);
          if (postBankParsed != null) {
            committedRideData = postBankParsed;
          }
          final bankPaymentStatus = _valueAsText(
            committedRideData['payment_status'],
          ).toLowerCase();
          if (bankPaymentStatus != 'pending_manual_confirmation' &&
              bankPaymentStatus != 'pending_review' &&
              bankPaymentStatus != 'pending') {
            _logRideFlow(
              'RIDER_BANK_TRANSFER_INVALID_PAYMENT_STATUS rideId=$rideId payment_status=$bankPaymentStatus',
            );
            await _clearStaleActiveTripArtifacts(
              rideId: rideId,
              reason: 'bank_transfer_invalid_payment_status',
            );
            _clearRideSearchTimeout(
              reason: 'bank_transfer_invalid_payment_status',
            );
            _pendingRideRequestSubmissionId = null;
            await _resetRideState(clearDestination: true);
            _showSnackBar(
              'Unable to confirm bank transfer reference right now. Please try again.',
            );
            return;
          }
          _enterSearchingStateAfterCreate(
            rideId: rideId,
            rideData: committedRideData,
          );
          movedToSearching = true;
          _showSnackBar(RiderTripStatusMessages.searchingForDriver);
        } else {
          final psNorm = _valueAsText(
            committedRideData[RtdbRideRequestFields.paymentStatus] ??
                committedRideData['payment_status'],
          ).toLowerCase();
          final linked = await _riderHasLinkedPaymentMethod(user.uid);
          final isCardFamily = pmNorm == 'flutterwave' ||
              pmNorm == 'card' ||
              pmNorm == 'credit_card' ||
              pmNorm == 'debit_card';
          if (isCardFamily && psNorm == 'pending' && linked) {
            _enterSearchingStateAfterCreate(
              rideId: rideId,
              rideData: committedRideData,
            );
            movedToSearching = true;
            _showSnackBar(RiderTripStatusMessages.searchingForDriver);
          } else {
            _logRideFlow(
              'RIDER_POST_CREATE_NON_BANK_UNVERIFIED rideId=$rideId pm=$pmNorm '
              'ps=$psNorm linked=$linked',
            );
            await _clearStaleActiveTripArtifacts(
              rideId: rideId,
              reason: 'unexpected_payment_state',
            );
            _clearRideSearchTimeout(reason: 'unexpected_payment_state');
            _pendingRideRequestSubmissionId = null;
            await _resetRideState(clearDestination: true);
            _showSnackBar(
              linked
                  ? 'Could not start your request right now. Please try again.'
                  : 'Link a card under Profile → Payment methods before requesting a ride.',
            );
            return;
          }
        }
      }
      if (_rideRequestUserAborted) {
        _logRideFlow(
          'createRideRequest user aborted after write rideId=$rideId',
        );
        try {
          await _performRiderRtdbCancellationUpdate(
            rideId: rideId,
            currentRide: Map<String, dynamic>.from(
              committedRideData,
            ),
            transitionSource: 'rider_cancel',
            cancelMetadataSource: 'rider_abort_during_submit',
            cancellationReasonDisplay: 'Change of plans',
          );
        } catch (abortError) {
          _logRideFlow(
            'abort cancel update failed rideId=$rideId error=$abortError',
          );
        }
        _clearRideSearchTimeout(reason: 'user_abort_after_write');
        _pendingRideRequestSubmissionId = null;
        _rideRequestUserAborted = false;
        await _resetRideState(clearDestination: true);
        return;
      }
      _logRideFlow('REQUEST RIDE createRideRequest succeeded rideId=$rideId');
      _logRideFlow('RTDB snapshot confirmed rideId=$rideId');
      _logRideFlow(
        '[MATCH_DEBUG][RIDER_CREATE_OK] rideId=$rideId path=ride_requests/$rideId '
        'status=${committedRideData['status']} '
        'trip_state=${committedRideData['trip_state']}',
      );
      _logRideFlow(
        '[RIDER_CREATE_OK] rideId=$rideId',
      );
      _logRideFlow(
        'REQUEST RIDE driver matching started rideId=$rideId searchTimeoutAt=$searchTimeoutAt',
      );
      unawaited(
        _tripSafetyService
            .registerRideRequest(
              rideId: rideId,
              riderId: user.uid,
              serviceType: RiderServiceType.ride.key,
              ridePayload: committedRideData,
              expectedRoutePoints: expectedRoutePoints,
            )
            .catchError((Object error) {
              if (isPermissionDeniedError(error)) {
                debugPrint(
                  'RIDER_TELEMETRY_SKIPPED_PERMISSION_DENIED rideId=$rideId',
                );
              } else {
                _logRideFlow(
                  'ride request telemetry registration failed rideId=$rideId error=$error',
                );
              }
            }),
      );

      _logRideFlow('createRideRequest callable success rideId=$rideId');
      {
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        final eff = Map<String, dynamic>.from(
          committedRideData,
        );
        final sto = _asInt(eff['search_timeout_at']);
        final reo = _asInt(eff['request_expires_at']);
        _logRideFlow(
          '[RIDE_LIFECYCLE] ride_created rideId=$rideId nowMs=$nowMs '
          'search_timeout_at=$sto request_expires_at=$reo '
          'deltaSearchTimeoutMs=${sto != null ? sto - nowMs : 'n/a'} '
          'trip_state=${eff['trip_state']} status=${eff['status']}',
        );
      }

      if (!movedToSearching) {
        _enterSearchingStateAfterCreate(
          rideId: rideId,
          rideData: committedRideData,
        );
        _showSnackBar(RiderTripStatusMessages.searchingForDriver);
      }
    } catch (error, stackTrace) {
      if (_rideRequestUserAborted) {
        _logRideFlow(
          'createRideRequest aborted in catch rideId=${rideId ?? 'unknown'} error=$error',
        );
        if (rideId != null && rideId.isNotEmpty) {
          await _discardInFlightRideRequestSubmission(rideId: rideId);
        } else {
          _pendingRideRequestSubmissionId = null;
          _rideRequestUserAborted = false;
        }
        return;
      }
      debugPrint('RIDER_CREATE_CALLABLE_FAIL error=$error');
      _logRideFlow(
        'createRideRequest failed error=$error rideId=${rideId ?? 'unknown'}',
      );
      _logRideFlow(
        'REQUEST RIDE create failed rideId=${rideId ?? 'unknown'} exact_error_type=${error.runtimeType} exact_error=$error',
      );
      _logRideFlow('createRideRequest callable failure error=$error');
      _logRideFlow('REQUEST RIDE caught exception error=$error');
      _logRideFlow(
        '[RIDER_CREATE_FAIL] rideId=${rideId ?? 'unknown'} error=$error',
      );
      await _logCreateRideFailureDiagnostics(
        error: error,
        stackTrace: stackTrace,
        payload: debugCreatePayload,
      );
      debugPrintStack(
        label: '[RiderRTDB] REQUEST RIDE exception stack',
        stackTrace: stackTrace,
      );
      _clearRideSearchTimeout(reason: 'create_request_failed');
      _pendingRideRequestSubmissionId = null;
      _showRideRequestRetrySnackBar(_rideRequestErrorMessage(error));
      if (mounted) {
        setState(() {
          _rideStatus = 'idle';
          _searchingDriver = false;
          _driverFound = false;
          _tripStarted = false;
          _currentRideId = null;
          _riderUnreadChatCount = 0;
        });
      } else {
        _rideStatus = 'idle';
        _searchingDriver = false;
        _driverFound = false;
        _tripStarted = false;
        _currentRideId = null;
        _riderUnreadChatCount = 0;
      }
    } finally {
      if (mounted) {
        setState(() {
          _isCreatingRide = false;
        });
      } else {
        _isCreatingRide = false;
      }
    }
  }

  static const String _riderActiveTripPointerPath = 'rider_active_trip';
  static const Set<String> _activeBlockingStatuses = <String>{
    'searching',
    'matched',
    'accepted',
    'arrived',
    'in_progress',
  };

  bool _isStatusBlockingRideCreation(String status) =>
      _activeBlockingStatuses.contains(status.trim().toLowerCase());

  Future<String> _resolveRideIdFromRiderActiveTripPointer() async {
    final uid = _currentRiderUid?.trim() ?? '';
    if (uid.isEmpty) {
      return '';
    }
    try {
      final snap = await rtdb.FirebaseDatabase.instance
          .ref('$_riderActiveTripPointerPath/$uid')
          .get();
      final m = _asStringDynamicMap(snap.value);
      return _firstNonEmptyText(<dynamic>[m?['ride_id'], m?['rideId']]);
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          '[RIDER_ACTIVE_TRIP_POINTER] resolve_failed uid=$uid error=$error',
        );
      }
      return '';
    }
  }

  Future<void> _clearStaleActiveTripArtifacts({
    required String rideId,
    required String reason,
    bool clearRideRequestNode = true,
  }) async {
    final uid = _currentRiderUid?.trim() ?? '';
    final normalizedRideId = rideId.trim();
    _logRideFlow(
      'ACTIVE_TRIP_CLEARED reason=$reason uid=${uid.isEmpty ? 'none' : uid} rideId=${normalizedRideId.isEmpty ? 'none' : normalizedRideId} '
      'clearRideRequestNode=$clearRideRequestNode',
    );
    _logRideFlow(
      'ACTIVE_TRIP_CLEANED reason=$reason uid=${uid.isEmpty ? 'none' : uid} rideId=${normalizedRideId.isEmpty ? 'none' : normalizedRideId}',
    );
    if (uid.isNotEmpty) {
      try {
        await rtdb.FirebaseDatabase.instance
            .ref('$_riderActiveTripPointerPath/$uid')
            .remove();
      } catch (error) {
        _logRideFlow(
          'ACTIVE_TRIP_CLEARED pointer_clear_failed uid=$uid error=$error',
        );
      }
      try {
        await rtdb.FirebaseDatabase.instance.ref('active_trips/$uid').remove();
      } catch (error) {
        _logRideFlow(
          'ACTIVE_TRIP_CLEARED active_trips_uid_clear_failed uid=$uid error=$error',
        );
      }
    }
    if (normalizedRideId.isNotEmpty) {
      try {
        await rtdb.FirebaseDatabase.instance
            .ref('active_trips/$normalizedRideId')
            .remove();
      } catch (error) {
        _logRideFlow(
          'ACTIVE_TRIP_CLEARED active_trips_ride_clear_failed rideId=$normalizedRideId error=$error',
        );
      }
      if (clearRideRequestNode) {
        try {
          await _rideRequestsRef.child(normalizedRideId).remove();
        } catch (error) {
          _logRideFlow(
            'ACTIVE_TRIP_CLEARED ride_request_clear_failed rideId=$normalizedRideId error=$error',
          );
        }
      }
    }
  }

  Future<void> _clearRiderActiveTripPointerBestEffort() async {
    await _clearStaleActiveTripArtifacts(
      rideId: '',
      reason: 'pointer_only_best_effort',
      clearRideRequestNode: false,
    );
  }

  Future<_ActiveTripPrecheckOutcome> _precheckRiderActiveTripPointerBeforeCreate() async {
    final uid = _currentRiderUid?.trim() ?? '';
    if (uid.isEmpty) {
      return _ActiveTripPrecheckOutcome.noPointer;
    }
    try {
      final snap = await rtdb.FirebaseDatabase.instance
          .ref('$_riderActiveTripPointerPath/$uid')
          .get();
      if (!snap.exists || snap.value == null) {
        return _ActiveTripPrecheckOutcome.noPointer;
      }
      final ptr = _asStringDynamicMap(snap.value);
      final rideId = _firstNonEmptyText(<dynamic>[ptr?['ride_id'], ptr?['rideId']]);
      _logRideFlow(
        'ACTIVE_TRIP_FOUND source=precheck uid=$uid rideId=${rideId.isEmpty ? 'missing' : rideId}',
      );
      if (rideId.isEmpty) {
        _logRideFlow('ACTIVE_TRIP_STALE source=precheck reason=missing_ride_id');
        await _clearStaleActiveTripArtifacts(
          rideId: '',
          reason: 'precheck_missing_ride_id',
          clearRideRequestNode: false,
        );
        return _ActiveTripPrecheckOutcome.staleCleared;
      }
      final rideSnap = await _rideRequestsRef.child(rideId).get();
      final rideData = _asStringDynamicMap(rideSnap.value);
      if (rideData == null) {
        _logRideFlow(
          'ACTIVE_TRIP_STALE source=precheck rideId=$rideId reason=missing_ride_node',
        );
        await _clearStaleActiveTripArtifacts(
          rideId: rideId,
          reason: 'precheck_missing_ride_node',
        );
        return _ActiveTripPrecheckOutcome.staleCleared;
      }
      final riderId = _valueAsText(rideData['rider_id']);
      final status = TripStateMachine.uiStatusFromSnapshot(rideData);
      final isActive = riderId == uid && _isStatusBlockingRideCreation(status);
      if (!isActive) {
        _logRideFlow(
          'ACTIVE_TRIP_STALE source=precheck rideId=$rideId reason=status_not_blocking status=$status',
        );
        await _clearStaleActiveTripArtifacts(
          rideId: rideId,
          reason: 'precheck_terminal_or_invalid_status_$status',
        );
        return _ActiveTripPrecheckOutcome.staleCleared;
      }
      _logRideFlow(
        'ACTIVE_TRIP_RECOVERED source=precheck rideId=$rideId status=$status',
      );
      _showSnackBar('You already have an active ride. Resuming it now.');
      listenToRide(rideId);
      unawaited(
        _activeTripSessionService.attachToRide(
          rideId,
          seedData: Map<String, dynamic>.from(rideData),
          source: 'precheck:pointer',
        ),
      );
      return _ActiveTripPrecheckOutcome.resumed;
    } catch (error) {
      if (isPermissionDeniedError(error)) {
        if (kDebugMode) {
          debugPrint(
            '[RIDER_ACTIVE_TRIP_PRECHECK] permission_denied uid=$uid error=$error '
            'action=fail_open_continue_create',
          );
        }
        return _ActiveTripPrecheckOutcome.noPointer;
      }
      if (kDebugMode) {
        debugPrint('[RIDER_ACTIVE_TRIP_PRECHECK] failed uid=$uid error=$error');
      }
      // Fail open: allow creating a new request if precheck fails for non-permission reasons.
      return _ActiveTripPrecheckOutcome.noPointer;
    }
  }

  void listenToRide(String rideId) {
    if (_activeRideListenerRideId == rideId && _rideListener != null) {
      _logRideFlow('listenToRide skipped duplicate listener rideId=$rideId');
      return;
    }

    _rideListener?.cancel();
    _rideListener = null;
    _activeRideListenerRideId = rideId;

    _logRideFlow('ride listener attached rideId=$rideId');
    _logRideFlow('[RIDER_LISTENER_ATTACHED] rideId=$rideId');

    final rideRef = _rideRequestsRef.child(rideId);
    _rideListener = rideRef.onValue.listen(
      (event) async {
        if (!event.snapshot.exists) {
          _logRideFlow('ride listener missing node rideId=$rideId');
          if (_currentRideId == rideId || _activeRideListenerRideId == rideId) {
            _activeTripSessionService.clearSession(
              reason: 'ride_node_deleted',
              source: 'map_listener',
            );
            await _resetRideState(clearDestination: false);
          }
          return;
        }

        final raw = event.snapshot.value;
        if (raw is! Map) {
          _logRideFlow('ride listener invalid payload rideId=$rideId raw=$raw');
          if (_currentRideId == rideId || _activeRideListenerRideId == rideId) {
            _activeTripSessionService.clearSession(
              reason: 'ride_payload_invalid',
              source: 'map_listener',
            );
            await _resetRideState(clearDestination: false);
          }
          return;
        }

        final data = Map<String, dynamic>.from(raw);
        final previousStatus = _rideStatus;
        final rawStatus = TripStateMachine.uiStatusFromSnapshot(data);
        if (_rideHasTimedOut(data) && rawStatus == 'searching') {
          final nowMs = DateTime.now().millisecondsSinceEpoch;
          final tAt = _rideSearchTimeoutAt(data);
          _logRideFlow(
            '[RIDE_LIFECYCLE] listener_timeout_cancel rideId=$rideId '
            'prevLocalStatus=$previousStatus rawUiStatus=$rawStatus '
            'trip_state=${data['trip_state']} raw_status=${data['status']} '
            'search_timeout_at=${data['search_timeout_at']} request_expires_at=${data['request_expires_at']} '
            'effectiveTimeoutAt=$tAt nowMs=$nowMs',
          );
          _logRideFlow(
            '[MATCH_DEBUG][RIDE_EXPIRED] rideId=$rideId status=$rawStatus '
            'search_timeout_at=${data['search_timeout_at']} request_expires_at=${data['request_expires_at']}',
          );
          await _markRideNoDriversAvailable(rideId: rideId, rideData: data);
          return;
        }

        if (await _releaseExpiredAssignedRideIfNeeded(
          rideId: rideId,
          rideData: data,
          source: 'listener',
        )) {
          return;
        }

        if (await _autoCancelRideForLifecycleTimeoutIfNeeded(
          rideId: rideId,
          rideData: data,
          source: 'listener',
        )) {
          return;
        }

        final decision = await _resolveVisibleRideStatus(
          rideId: rideId,
          rideData: data,
          source: 'listener',
        );
        await _maybeHandleRemoteRiderSafetyAlert(
          rideId: rideId,
          rideData: data,
        );
        final visibleRideData = _sanitizedRideSnapshotForDecision(
          rideData: data,
          decision: decision,
        );
        final status = decision.status;
        final nextDriverData = decision.driverData;
        final previousUiSignature = _rideUiSignature(
          rideId: _currentRideId ?? '',
          status: _rideStatus,
          rideData: _currentRideSnapshot,
          driverData: _driverData,
        );
        final nextUiSignature = _rideUiSignature(
          rideId: rideId,
          status: status,
          rideData: visibleRideData,
          driverData: nextDriverData,
        );

        _logRideFlow(
          'ride listener update rideId=$rideId rawStatus=$rawStatus visibleStatus=$status',
        );
        _logRideFlow(
          '[MATCH_DEBUG][RIDER_LISTENER] rideId=$rideId rawStatus=$rawStatus '
          'visibleStatus=$status trip_state=${data['trip_state']} '
          'driver_id=${data['driver_id']}',
        );
        _logRideFlow(
          '[RIDER_LISTENER] rideId=$rideId raw_status=${data['status']} '
          'trip_state=${data['trip_state']} visible_status=$status '
          'driver_id=${data['driver_id']}',
        );
        if (previousStatus != status) {
          debugPrint(
            '[RIDER_REQUEST_STATUS_UPDATED] rideId=$rideId '
            'from=$previousStatus to=$status '
            'trip_state=${data['trip_state']} raw_status=${data['status']}',
          );
          _logRideFlow(
            '[RIDE_LIFECYCLE] status_transition rideId=$rideId '
            'prev=$previousStatus next=$status '
            'trip_state=${data['trip_state']} raw_status=${data['status']}',
          );
          _logRideFlow(
            '[MATCH_DEBUG][RIDER_STATUS_UPDATE] rideId=$rideId '
            'from=$previousStatus to=$status '
            'trip_state=${visibleRideData['trip_state']} '
            'raw_status=${data['status']} driver_id=${data['driver_id']}',
          );
          _logRideFlow(
            '[RIDE_STATUS_CHANGE] rideId=$rideId from=$previousStatus to=$status '
            'trip_state=${visibleRideData['trip_state']} driver_id=${data['driver_id']}',
          );
        }

        _currentRideId = rideId;
        _rideStatus = status;
        _currentRideSnapshot = visibleRideData;
        _syncRiderPaymentMethodFromRide(Map<String, dynamic>.from(data));
        _driverData = nextDriverData;
        if (nextDriverData != null) {
          final nextDriverId = _firstNonEmptyText(<dynamic>[nextDriverData['id']]);
          if (nextDriverId.isNotEmpty && nextDriverId != 'waiting') {
            unawaited(_enrichDriverDataProfile(nextDriverId));
          }
        }
        _activeTripSessionService.updateFromRideSnapshot(
          rideId,
          visibleRideData,
          source: 'map_listener',
        );
        _startCallListener(rideId);
        _applyRideStatus(status);
        if (previousStatus != status) {
          debugPrint(
            'RIDER_RIDE_STATE_UPDATE rideId=$rideId '
            'from=$previousStatus to=$status '
            'trip_state=${data['trip_state']} raw_status=${data['status']}',
          );
        }
        if ((previousStatus == 'searching' || previousStatus == 'requested') &&
            (status == 'assigned' ||
                status == 'accepted' ||
                status == 'pending_driver_action' ||
                status == 'arriving' ||
                status == 'arrived' ||
                status == 'on_trip')) {
          debugPrint(
            'RIDER_MATCHED_NAVIGATE rideId=$rideId from=$previousStatus to=$status',
          );
        }

        if (status == 'searching') {
          _scheduleRideSearchTimeout(rideId: rideId, rideData: data);
        } else {
          _clearRideSearchTimeout(reason: 'listener_status_$status');
        }

        if (mounted &&
            (previousUiSignature != nextUiSignature ||
                previousStatus != status)) {
          setState(() {});
        }

        final driverLat = _asDouble(data['driver_lat']);
        final driverLng = _asDouble(data['driver_lng']);
        if (nextDriverData != null && driverLat != null && driverLng != null) {
          final driverPosition = LatLng(driverLat, driverLng);
          final driverHeading = _asDouble(data['driver_heading']) ?? 0;
          await _animateDriverSmart(driverPosition, driverHeading);
          _checkSafety(driverPosition);
          await _maybeLogTelemetryCheckpoint(rideId, data, driverPosition);
        }

        await _syncShareTripSnapshot(rideId: rideId, rideData: visibleRideData);

        if (status != previousStatus) {
          _logRideFlow(
            'ride status change ts=${DateTime.now().toIso8601String()} rideId=$rideId from=$previousStatus to=$status driverId=${_valueAsText(data["driver_id"])}',
          );
          unawaited(_alertSoundService.playRideStatusAlert(status));
          unawaited(
            _tripSafetyService.logRideStateChange(
              rideId: rideId,
              riderId: _currentRiderUid ?? '',
              driverId: data['driver_id']?.toString() ?? '',
              serviceType:
                  data['service_type']?.toString() ?? RiderServiceType.ride.key,
              status: status,
              source: 'rider_listener',
              rideData: visibleRideData,
            ),
          );
        }

        if (status == 'arrived' && previousStatus != 'arrived') {
          _startCountdown();
        } else if (previousStatus == 'arrived' && status != 'arrived') {
          final reason = switch (status) {
            'on_trip' => 'trip_started',
            'cancelled' => 'trip_cancelled',
            'completed' => 'trip_completed',
            _ => 'status_changed:$status',
          };
          _clearArrivalCountdown(reason: reason);
        }

        if (status == 'on_trip' && previousStatus != 'on_trip') {
          _startSafetyMonitoring();
        } else if (previousStatus == 'on_trip' && status != 'on_trip') {
          _stopSafetyMonitoring();
        }

        if (status == 'completed') {
          _logRideFlow('ride completed rideId=$rideId');
          await _endCallForRideLifecycle(rideId: rideId);
          await _saveRiderTrip(rideId, data);
          await _clearStaleActiveTripArtifacts(
            rideId: rideId,
            reason: 'ride_completed',
          );
          if (_currentRiderUid?.isNotEmpty ?? false) {
            unawaited(
              _trustRulesService.recordTripCompletion(
                riderId: _currentRiderUid!,
              ),
            );
          }
          final completedDriverId = data['driver_id']?.toString();
          final riderUid = _currentRiderUid;
          final completionSnapshot = _asStringDynamicMap(data);
          final needsBankReceipt = riderUid != null &&
              _rideNeedsBankTransferReceipt(completionSnapshot);
          if (needsBankReceipt) {
            await _ensureUserPendingReceiptPointer(
              uid: riderUid,
              rideId: rideId,
            );
          }
          await _resetRideState(clearDestination: true);
          _logRideFlow(
            'trip completion reset rideId=$rideId distance=0.0 fare=0.0 unreadCount=0',
          );

          final rateDriverId = completedDriverId != null &&
                  completedDriverId.isNotEmpty &&
                  completedDriverId != 'waiting'
              ? completedDriverId
              : null;
          if (needsBankReceipt && mounted) {
            unawaited(
              _openBankTransferReceiptScreen(
                rideId: rideId,
                ratingDriverId: rateDriverId,
                bankTransferReference: _bankTransferReferenceFromRide(
                  completionSnapshot,
                ),
              ),
            );
          } else if (rateDriverId != null && mounted) {
            Future<void>.microtask(() => _showRatingDialog(rateDriverId));
          }
        } else if (status == 'cancelled' ||
            status == 'driver_cancelled' ||
            status == 'rider_cancelled' ||
            status == 'expired') {
          _logRideFlow('ride cancelled rideId=$rideId');
          _logRideFlow(
            '[MATCH_DEBUG][RIDE_CANCELLED] rideId=$rideId '
            'cancel_reason=${_valueAsText(data['cancel_reason'])}',
          );
          await _endCallForRideLifecycle(rideId: rideId);
          if (_valueAsText(data['cancel_reason']) == 'driver_cancelled') {
            _logRideFlow('[RIDER_DRIVER_CANCELLED] rideId=$rideId');
          }
          _logRideFlow('[RIDER_TERMINAL_STATE] rideId=$rideId status=cancelled');
          _activeTripSessionService.clearSession(
            reason: 'cancelled',
            source: 'map_listener',
          );
          await _clearStaleActiveTripArtifacts(
            rideId: rideId,
            reason: 'ride_terminal_$status',
          );
          await _resetRideState(clearDestination: true);
          final cancelReason = _valueAsText(data['cancel_reason']);
          _showSnackBar(
            _rideCancellationMessage(
              cancelReason: cancelReason,
              terminalStatus: status,
            ),
          );
        }
      },
      onError: (Object error) {
        _logRideFlow('ride listener error rideId=$rideId error=$error');
      },
    );
  }

  Map<String, dynamic>? _extractDriverData(Map<String, dynamic> data) {
    final driverId = data['driver_id']?.toString() ?? '';
    if (driverId.isEmpty || driverId == 'waiting') {
      return null;
    }

    return <String, dynamic>{
      'id': driverId,
      'name': _firstNonEmptyText(<dynamic>[
        data['driver_name'],
        data['driverName'],
        data['name'],
      ]),
      'phone': _firstNonEmptyText(<dynamic>[
        data['driver_phone'],
        data['driverPhone'],
        data['phone'],
      ]),
      'car': data['car'],
      'plate': data['plate'],
      'rating': data['rating'],
    };
  }

  Future<void> _enrichDriverDataProfile(String driverId) async {
    final normalizedDriverId = driverId.trim();
    if (normalizedDriverId.isEmpty || normalizedDriverId == 'waiting') {
      return;
    }

    final current = _driverData;
    if (current == null) {
      return;
    }

    try {
      final snap = await _rideRequestsRef.root
          .child('drivers/$normalizedDriverId')
          .get();
      final driverProfile = snap.value is Map
          ? Map<String, dynamic>.from(snap.value as Map)
          : const <String, dynamic>{};

      final profileName = _firstNonEmptyText(<dynamic>[
        driverProfile['name'],
        driverProfile['full_name'],
      ]).trim();
      final profilePhone = _firstNonEmptyText(<dynamic>[
        driverProfile['phone'],
        driverProfile['phone_number'],
      ]).trim();

      if (profileName.isEmpty && profilePhone.isEmpty) {
        return;
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _driverData = <String, dynamic>{
          ...?_driverData,
          if (profileName.isNotEmpty) 'name': profileName,
          if (profilePhone.isNotEmpty) 'phone': profilePhone,
        };
      });
    } catch (error) {
      _logRideFlow(
        '[DRIVER_PROFILE_ENRICH_FAIL] driverId=$normalizedDriverId error=$error',
      );
    }
  }

  void _applyRideStatus(String status) {
    switch (status) {
      case 'searching':
        _searchingDriver = true;
        _driverFound = false;
        _tripStarted = false;
        break;
      case 'pending_driver_action':
      case 'assigned':
        _searchingDriver = false;
        _driverFound = true;
        _tripStarted = false;
        break;
      case 'accepted':
        _searchingDriver = false;
        _driverFound = true;
        _tripStarted = false;
        break;
      case 'arriving':
        _searchingDriver = false;
        _driverFound = true;
        _tripStarted = false;
        break;
      case 'arrived':
        _searchingDriver = false;
        _driverFound = true;
        _tripStarted = false;
        break;
      case 'on_trip':
        _searchingDriver = false;
        _driverFound = true;
        _tripStarted = true;
        break;
      case 'completed':
      case 'cancelled':
      case 'driver_cancelled':
      case 'rider_cancelled':
      case 'idle':
        _searchingDriver = false;
        _driverFound = false;
        _tripStarted = false;
        break;
      default:
        _searchingDriver = false;
        _driverFound = false;
        _tripStarted = false;
        break;
    }
  }

  Future<void> _cancelRideRequestFromPanel() async {
    if (_isCreatingRide || _isSubmittingRideRequest) {
      _rideRequestUserAborted = true;
      _logRideFlow('rider cancel_request flagged during submit');
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text('Cancelling your request…'),
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }
    await cancelRide();
  }

  static const List<String> _kRiderCancelReasons = <String>[
    'Change of plans',
    'Driver too far',
    'Wait time too long',
    'Wrong pickup',
    'Other',
  ];

  Future<String?> _pickRiderCancelReason() async {
    if (!mounted) {
      return null;
    }
    return showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Text('Cancel ride'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Select a reason to cancel this request or trip.',
                  style: TextStyle(fontSize: 13, height: 1.35),
                ),
                const SizedBox(height: 12),
                ..._kRiderCancelReasons.map(
                  (label) => ListTile(
                    dense: true,
                    title: Text(label),
                    onTap: () {
                      Navigator.of(dialogContext).pop(label);
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(null),
              child: const Text('KEEP RIDE'),
            ),
          ],
        );
      },
    );
  }

  Future<void> cancelRide() async {
    final rideId = (_currentRideId != null && _currentRideId!.trim().isNotEmpty)
        ? _currentRideId!.trim()
        : _pendingRideRequestSubmissionId?.trim();
    if (rideId == null || rideId.isEmpty) {
      _logRideFlow('cancelRide skipped: no active ride');
      return;
    }

    final displayReason = await _pickRiderCancelReason();
    if (displayReason == null || displayReason.trim().isEmpty) {
      _logRideFlow('[CANCEL] actor=rider rideId=$rideId dismissed');
      return;
    }

    _logRideFlow(
      '[CANCEL] actor=rider rideId=$rideId reason=$displayReason start',
    );
    final riderId = _currentRiderUid;
    final statusBeforeCancel = _rideStatus;

    if (mounted) {
      setState(() {
        _isCancellingRide = true;
      });
    } else {
      _isCancellingRide = true;
    }

    try {
      Map<String, dynamic> currentRide;
      if (_currentRideSnapshot != null && _currentRideId == rideId) {
        currentRide = Map<String, dynamic>.from(_currentRideSnapshot!);
      } else {
        final snap = await _rideRequestsRef
            .child(rideId)
            .get()
            .timeout(const Duration(seconds: 14));
        final remote = _asStringDynamicMap(snap.value);
        if (remote == null) {
          _logRideFlow('cancelRide no remote ride node rideId=$rideId');
          await _resetRideState(clearDestination: false);
          return;
        }
        currentRide = remote;
      }
      final serviceType =
          currentRide['service_type']?.toString() ?? RiderServiceType.ride.key;
      final driverId = currentRide['driver_id']?.toString();
      await _performRiderRtdbCancellationUpdate(
        rideId: rideId,
        currentRide: currentRide,
        transitionSource: 'rider_cancel',
        cancelMetadataSource: 'rider_cancel',
        cancellationReasonDisplay: displayReason.trim(),
      );
      final listenerAttached =
          _rideListener != null && _activeRideListenerRideId == rideId;
      if (!listenerAttached) {
        await _resetRideState(clearDestination: true);
      }
      _logRideFlow(
        '[CANCEL] actor=rider rideId=$rideId reason=$displayReason success',
      );
      if (riderId != null && riderId.isNotEmpty) {
        unawaited(
          _trustRulesService.recordRideCancellation(
            riderId: riderId,
            rideId: rideId,
            serviceType: serviceType,
            statusBeforeCancel: statusBeforeCancel,
            driverId: driverId,
          ),
        );
      }
    } catch (error) {
      _logRideFlow(
        '[CANCEL] actor=rider rideId=$rideId reason=$displayReason fail error=$error',
      );
      _logRideFlow('cancel failure rideId=$rideId error=$error');
      _showSnackBar('Unable to cancel this ride right now.');
    } finally {
      if (mounted) {
        setState(() {
          _isCancellingRide = false;
        });
      } else {
        _isCancellingRide = false;
      }
    }
  }

  Future<void> handlePrimaryRideAction() async {
    print('HANDLE_PRIMARY_RIDE_ACTION');
    debugPrint(
      '[RIDER_REQUEST_BUTTON_TAPPED] rideStatus=$_rideStatus '
      'currentRideId=$_currentRideId',
    );
    _logRideFlow('request button tapped action=request_ride');
    _logRideFlow(
      'rider tap fired action=request_ride status=$_rideStatus currentRideId=$_currentRideId',
    );

    if (_isSubmittingRideRequest || _isCreatingRide) {
      _logRideFlow(
        'REQUEST RIDE ignored because submission is already in flight',
      );
      return;
    }

    _logRideFlow('REQUEST RIDE temporary bypass forcing request creation');
    _setSubmittingRideRequest(true);
    try {
      await createRideRequest();
    } finally {
      _setSubmittingRideRequest(false);
    }
  }

  Future<void> _resetRideState({required bool clearDestination}) async {
    _logRideFlow('resetRideState clearDestination=$clearDestination');
    final rideId = _currentRideId ?? _callListenerRideId ?? '';

    _clearArrivalCountdown(reason: 'reset');
    _clearRideSearchTimeout(reason: 'reset');
    _stopSafetyMonitoring();
    _rideListener?.cancel();
    _rideListener = null;
    _activeRideListenerRideId = null;
    _stopRiderChatListener();
    _callSubscription?.cancel();
    _callSubscription = null;
    _callListenerRideId = null;
    await _performLocalCallCleanup(rideId: rideId, logCleanup: false);
    _loggedRiderChatMessageIds.clear();
    _hasHydratedRiderChatMessages = false;
    _riderChatListenerRideId = null;
    _lastRiderChatErrorNoticeKey = null;
    _riderChatMessages.value = const <RideChatMessage>[];
    _riderMissedCallNotice = false;

    final retainedPickup = _pickupLocation ?? _riderLocation;
    if (clearDestination) {
      _destinationLocation = null;
      _destinationAddress = '';
      _destinationController.clear();
      for (var i = 0; i < _additionalStopControllers.length; i++) {
        _additionalStopControllers[i].clear();
        _additionalStopLocations[i] = null;
        _additionalStopAddresses[i] = '';
      }
      _extraStopFieldCount = 0;
    }

    _pickupLocation = retainedPickup;
    if (_pickupAddress.trim().isEmpty) {
      _pickupAddress = await _addressFromCoordinates(retainedPickup);
      _pickupController.text = _pickupAddress;
    } else {
      _pickupController.text = _pickupAddress;
    }

    _expectedRoutePoints.clear();
    _lastTelemetryCheckpointPosition = null;
    _lastTelemetryCheckpointAt = null;
    _lastRenderedRouteSignature = '';
    _routePreviewError = null;
    _polylines = <Polyline>{};
    _resetMarkersForIdleState();
    _pendingRideRequestSubmissionId = null;
    _activeTripSessionService.clearSession(
      reason: 'reset_ride_state',
      source: 'map_screen',
    );

    if (mounted) {
      setState(() {
        _currentRideId = null;
        _currentRideSnapshot = null;
        _rideStatus = 'idle';
        _isCreatingRide = false;
        _searchingDriver = false;
        _driverFound = false;
        _tripStarted = false;
        _isSharingTrip = false;
        _driverData = null;
        _driverMarker = null;
        _lastDriverLocation = null;
        _lastDriverPosition = null;
        _lastSafetyCheckLocation = null;
        _lastMoveTime = null;
        _lastSafetyPromptAt = null;
        _driverAnimationGeneration++;
        _lastBearing = 0;
        _countdown = _countdownDuration.inSeconds;
        _waitingCharged = false;
        _distanceKm = 0;
        _estimatedDurationMin = 0;
        _fare = 0;
        _riderUnreadChatCount = 0;
        _isRiderChatOpen = false;
        _safetyMonitoringActive = false;
        _safetyPopupVisible = false;
        _routeDeviationStrikeCount = 0;
        _routePreviewError = null;
        _lastRiderSpeedSampleAt = null;
        _lastRiderImpliedSpeedKmh = null;
        _lastConsumedRiderSafetyAlertIssuedAt = null;
      });
    }
  }

  void _clearArrivalCountdown({required String reason}) {
    final remainingSeconds = _countdown;
    final hadTimer =
        _timer != null || remainingSeconds != _countdownDuration.inSeconds;
    _timer?.cancel();
    _timer = null;
    _countdown = _countdownDuration.inSeconds;

    if (hadTimer) {
      _logRiderMap(
        'countdown cancelled rideId=$_currentRideId reason=$reason seconds=$remainingSeconds',
      );
      _logRideFlow(
        'countdown cleared rideId=$_currentRideId reason=$reason seconds=$remainingSeconds',
      );
    }
  }

  void _startCountdown() {
    if (_timer?.isActive == true) {
      _logRideFlow(
        'countdown start skipped duplicate rideId=$_currentRideId seconds=$_countdown',
      );
      return;
    }

    _timer?.cancel();
    _timer = null;
    _countdown = _countdownDuration.inSeconds;
    _waitingCharged = false;
    _logRiderMap(
      'countdown started rideId=$_currentRideId seconds=$_countdown',
    );
    _logRideFlow(
      'countdown started rideId=$_currentRideId seconds=$_countdown',
    );

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        _timer = null;
        return;
      }

      if (_rideStatus != 'arrived') {
        timer.cancel();
        _timer = null;
        return;
      }

      if (_countdown > 0) {
        setState(() {
          _countdown--;
        });
        _logRiderMap(
          'countdown tick rideId=$_currentRideId seconds=$_countdown',
        );
        _logRideFlow(
          'countdown tick rideId=$_currentRideId seconds=$_countdown',
        );

        if (_countdown == 0) {
          timer.cancel();
          _timer = null;
          _logRideFlow('countdown expired rideId=$_currentRideId');

          if (!_waitingCharged) {
            setState(() {
              _waitingCharged = true;
              _fare += RiderFareSettings.waitingCharge;
            });
            unawaited(_persistWaitingChargeToRide());
          }
        }
      } else {
        timer.cancel();
        _timer = null;
      }
    });
  }

  Future<void> _persistWaitingChargeToRide() async {
    final rideId = _currentRideId;
    if (rideId == null || rideId.isEmpty) {
      return;
    }

    final currentRideData = _currentRideSnapshot ?? const <String, dynamic>{};
    final fareBreakdown =
        Map<String, dynamic>.from(
          _asStringDynamicMap(currentRideData['fare_breakdown']) ??
              const <String, dynamic>{},
        )..addAll(<String, dynamic>{
          'waitingCharge': RiderFareSettings.waitingCharge,
          'finalFare': _fare,
          'totalFare': _fare,
        });
    final routeBasis = Map<String, dynamic>.from(
      _asStringDynamicMap(currentRideData['route_basis']) ??
          const <String, dynamic>{},
    );
    final routeFareBreakdown =
        Map<String, dynamic>.from(
          _asStringDynamicMap(routeBasis['fare_breakdown']) ??
              const <String, dynamic>{},
        )..addAll(<String, dynamic>{
          'waitingCharge': RiderFareSettings.waitingCharge,
          'finalFare': _fare,
          'totalFare': _fare,
        });
    routeBasis['fare_estimate'] = _fare;
    routeBasis['fare_breakdown'] = routeFareBreakdown;

    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final patchRes = await _rideCloud.patchRideRequestMetadata(
        rideId: rideId,
        patch: <String, dynamic>{
          'fare': _fare,
          'fare_breakdown': fareBreakdown,
          'route_basis/fare_estimate': _fare,
          'route_basis/fare_breakdown': routeFareBreakdown,
          'duration_min': _estimatedDurationMin,
          'updated_at': now,
        },
      );
      if (!riderRideCallableSucceeded(patchRes)) {
        _logRideFlow(
          'waiting charge patch failed rideId=$rideId reason=${riderRideCallableReason(patchRes)}',
        );
        return;
      }

      _currentRideSnapshot = <String, dynamic>{
        ...currentRideData,
        'fare': _fare,
        'fare_breakdown': fareBreakdown,
        'route_basis': routeBasis,
      };
      _logRideFlow('waiting charge persisted rideId=$rideId fare=$_fare');
    } catch (error) {
      _logRideFlow(
        'waiting charge persist failed rideId=$rideId fare=$_fare error=$error',
      );
    }
  }

  Future<void> _animateDriverSmart(LatLng newPosition, double bearing) async {
    final targetBearing = _normalizeBearing(bearing);
    if (_driverMarker == null || _lastDriverPosition == null) {
      _updateDriverMarker(newPosition, targetBearing);
      _lastDriverPosition = newPosition;
      _lastBearing = targetBearing;
      return;
    }

    final start = _lastDriverPosition!;
    final distanceMeters = Geolocator.distanceBetween(
      start.latitude,
      start.longitude,
      newPosition.latitude,
      newPosition.longitude,
    );

    if (distanceMeters >= _driverAnimationSnapDistanceMeters) {
      _driverAnimationGeneration++;
      _updateDriverMarker(newPosition, targetBearing);
      _lastDriverPosition = newPosition;
      _lastBearing = targetBearing;
      return;
    }

    final generation = ++_driverAnimationGeneration;
    final stopwatch = Stopwatch()..start();
    final startBearing = _lastBearing;

    while (stopwatch.elapsed < _driverAnimationDuration) {
      if (generation != _driverAnimationGeneration) {
        return;
      }

      final rawProgress =
          stopwatch.elapsedMicroseconds /
          _driverAnimationDuration.inMicroseconds;
      final progress = Curves.easeInOut.transform(
        min(1.0, max(0.0, rawProgress)).toDouble(),
      );
      final lat =
          start.latitude + (newPosition.latitude - start.latitude) * progress;
      final lng =
          start.longitude +
          (newPosition.longitude - start.longitude) * progress;
      final rotation = _interpolateBearing(
        startBearing,
        targetBearing,
        progress,
      );
      _updateDriverMarker(LatLng(lat, lng), rotation);
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }

    if (generation != _driverAnimationGeneration) {
      return;
    }

    _updateDriverMarker(newPosition, targetBearing);
    _lastDriverPosition = newPosition;
    _lastBearing = targetBearing;
  }

  double _normalizeBearing(double bearing) {
    return (bearing % 360 + 360) % 360;
  }

  double _interpolateBearing(double from, double to, double progress) {
    final delta = ((to - from + 540) % 360) - 180;
    return _normalizeBearing(from + (delta * progress));
  }

  void _updateDriverMarker(LatLng position, double bearing) {
    final marker = Marker(
      markerId: const MarkerId('driver'),
      position: position,
      rotation: bearing,
      anchor: const Offset(0.5, 0.5),
      flat: true,
      zIndexInt: 2,
      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
    );

    _markers.removeWhere((existing) => existing.markerId.value == 'driver');
    _markers.add(marker);
    _driverMarker = marker;
    _lastDriverLocation = position;
    _notifyMapLayerChanged();

    _moveCamera();
  }

  void _startSafetyMonitoring() {
    if (_safetyMonitoringActive) {
      return;
    }

    _safetyMonitoringActive = true;
    _lastMoveTime = DateTime.now();
    _lastSafetyCheckLocation = _lastDriverLocation ?? _lastDriverPosition;
    _routeDeviationStrikeCount = 0;
    _logRideFlow(
      'safety monitoring started rideId=$_currentRideId routePoints=${_expectedRoutePoints.length}',
    );

    if (_expectedRoutePoints.isEmpty &&
        _pickupLocation != null &&
        _orderedDropOffLocations().isNotEmpty) {
      unawaited(_ensureRouteMetrics());
    }
  }

  void _stopSafetyMonitoring() {
    _safetyMonitoringActive = false;
    _lastMoveTime = null;
    _lastSafetyCheckLocation = null;
    _routeDeviationStrikeCount = 0;
    _lastRiderSpeedSampleAt = null;
    _lastRiderImpliedSpeedKmh = null;
  }

  bool _isNearExpectedStop(LatLng driverPosition) {
    final checkpoints = <LatLng>[
      ...?_pickupLocation == null ? null : <LatLng>[_pickupLocation!],
      ..._orderedDropOffLocations(),
    ];

    for (final checkpoint in checkpoints) {
      final distance = Geolocator.distanceBetween(
        checkpoint.latitude,
        checkpoint.longitude,
        driverPosition.latitude,
        driverPosition.longitude,
      );

      if (distance <= _expectedStopRadiusMeters) {
        return true;
      }
    }

    return false;
  }

  double? _distanceFromExpectedRouteMeters(LatLng driverPosition) {
    if (_expectedRoutePoints.isEmpty) {
      return null;
    }

    var minimumDistance = double.infinity;
    for (final routePoint in _expectedRoutePoints) {
      final distance = Geolocator.distanceBetween(
        routePoint.latitude,
        routePoint.longitude,
        driverPosition.latitude,
        driverPosition.longitude,
      );

      if (distance < minimumDistance) {
        minimumDistance = distance;
      }

      if (minimumDistance <= 25) {
        break;
      }
    }

    return minimumDistance.isFinite ? minimumDistance : null;
  }

  Future<bool> _showSafetyPopup({
    required String reason,
    required String details,
  }) async {
    if (!mounted || _safetyPopupVisible) {
      return false;
    }

    final now = DateTime.now();
    if (_lastSafetyPromptAt != null &&
        now.difference(_lastSafetyPromptAt!) < _safetyPopupCooldown) {
      _logRiderMap(
        'safety popup suppressed (cooldown) rideId=$_currentRideId reason=$reason',
      );
      return false;
    }

    _lastSafetyPromptAt = now;
    _safetyPopupVisible = true;
    _logRideFlow('safety popup shown rideId=$_currentRideId reason=$reason');

    final action = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Are you safe?'),
        content: Text(details),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('safe'),
            child: const Text("I'M SAFE"),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('help'),
            child: const Text('HELP'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(context).pop('sos'),
            child: const Text('SOS'),
          ),
        ],
      ),
    );

    _safetyPopupVisible = false;

    if (action == 'help') {
      await _openEmergencySheet();
      return true;
    }

    if (action == 'sos') {
      final rideId = _currentRideId;
      if (rideId != null && rideId.isNotEmpty) {
        unawaited(
          _tripSafetyService.createSafetyFlag(
            rideId: rideId,
            riderId: _currentRiderUid ?? '',
            driverId: _currentRideSnapshot?['driver_id']?.toString() ?? '',
            serviceType:
                _currentRideSnapshot?['service_type']?.toString() ??
                RiderServiceType.ride.key,
            flagType: 'rider_sos',
            source: 'rider_safety_popup',
            message: 'Rider triggered SOS from the in-trip safety prompt.',
            status: 'manual_review',
            severity: 'critical',
          ),
        );
      }
      await _openEmergencySheet();
    }
    return true;
  }

  Future<void> _maybeHandleRemoteRiderSafetyAlert({
    required String rideId,
    required Map<String, dynamic> rideData,
  }) async {
    if (TripStateMachine.canonicalStateFromSnapshot(rideData) !=
        TripLifecycleState.tripStarted) {
      return;
    }
    final alert = _asStringDynamicMap(rideData['rider_safety_alert']);
    if (alert == null) {
      return;
    }
    final type = _valueAsText(alert['type']).toLowerCase();
    if (type != 'sudden_stop') {
      return;
    }
    final issuedAt = _asInt(alert['issued_at']);
    if (issuedAt == null || issuedAt <= 0) {
      return;
    }
    if (issuedAt <= (_lastConsumedRiderSafetyAlertIssuedAt ?? 0)) {
      return;
    }
    final shown = await _showSafetyPopup(
      reason: 'sudden_stop_remote',
      details:
          'We detected a sharp slowdown on this trip. If you feel unsafe, use SOS or Help below.',
    );
    try {
      await _rideRequestsRef.child(rideId).child('rider_safety_alert').remove();
    } catch (error) {
      _logRideFlow(
        'rider_safety_alert remove failed rideId=$rideId error=$error',
      );
    }
    if (shown) {
      _lastConsumedRiderSafetyAlertIssuedAt = issuedAt;
    }
  }

  void _checkSafety(LatLng driverPosition) {
    if (!_safetyMonitoringActive || _rideStatus != 'on_trip') {
      return;
    }

    _logRiderMap(
      'safety check running rideId=$_currentRideId position=${_formatLatLng(driverPosition)}',
    );
    final now = DateTime.now();
    final previousPosition = _lastSafetyCheckLocation;
    final nearExpectedStop = _isNearExpectedStop(driverPosition);
    final distanceFromRoute = _distanceFromExpectedRouteMeters(driverPosition);

    if (previousPosition == null) {
      _lastMoveTime = now;
      _lastSafetyCheckLocation = driverPosition;
      _lastRiderSpeedSampleAt = null;
      _lastRiderImpliedSpeedKmh = null;
      return;
    }

    final movement = Geolocator.distanceBetween(
      previousPosition.latitude,
      previousPosition.longitude,
      driverPosition.latitude,
      driverPosition.longitude,
    );

    if (nearExpectedStop) {
      _routeDeviationStrikeCount = 0;
      _lastMoveTime = now;
      _lastRiderImpliedSpeedKmh = null;
      _lastRiderSpeedSampleAt = now;
    } else {
      if (_lastRiderSpeedSampleAt != null) {
        final dtSec =
            now.difference(_lastRiderSpeedSampleAt!).inMilliseconds / 1000.0;
        if (dtSec >= _suddenStopMinDtSec && dtSec <= _suddenStopMaxDtSec) {
          final impliedKmh = (movement / dtSec) * 3.6;
          final prev = _lastRiderImpliedSpeedKmh;
          if (prev != null &&
              prev >= _suddenStopMinPriorKmh &&
              impliedKmh <= _suddenStopMaxAfterKmh &&
              (prev - impliedKmh) >= _suddenStopDropKmh) {
            _logRideFlow(
              'sudden deceleration (rider inferred) rideId=$_currentRideId '
              'prevKmh=${prev.toStringAsFixed(1)} nextKmh=${impliedKmh.toStringAsFixed(1)} dtSec=${dtSec.toStringAsFixed(2)}',
            );
            final rideId = _currentRideId;
            if (rideId != null && rideId.isNotEmpty) {
              unawaited(
                _tripSafetyService.createSafetyFlag(
                  rideId: rideId,
                  riderId: _currentRiderUid ?? '',
                  driverId: _currentRideSnapshot?['driver_id']?.toString() ?? '',
                  serviceType:
                      _currentRideSnapshot?['service_type']?.toString() ??
                          RiderServiceType.ride.key,
                  flagType: 'sudden_stop',
                  source: 'rider_map_monitor',
                  message:
                      'Rider app inferred a sharp slowdown from live driver positions.',
                  status: 'manual_review',
                  severity: 'high',
                ),
              );
            }
            unawaited(
              _showSafetyPopup(
                reason: 'sudden_stop',
                details:
                    'We noticed a sharp slowdown on this trip. Are you safe?',
              ),
            );
          }
          _lastRiderImpliedSpeedKmh = impliedKmh;
        } else if (dtSec > _suddenStopMaxDtSec || dtSec <= 0) {
          _lastRiderImpliedSpeedKmh = null;
        }
      }
      if (movement >= _stopMovementThresholdMeters) {
        _lastMoveTime = now;
      } else if (_lastMoveTime != null &&
          now.difference(_lastMoveTime!) >= _longStopDuration) {
        _logRiderMap(
          'long stop detected rideId=$_currentRideId durationSeconds=${now.difference(_lastMoveTime!).inSeconds}',
        );
        _logRideFlow(
          'long stop detected rideId=$_currentRideId durationSeconds=${now.difference(_lastMoveTime!).inSeconds} position=${_formatLatLng(driverPosition)}',
        );
        _lastMoveTime = now;
        final rideId = _currentRideId;
        if (rideId != null && rideId.isNotEmpty) {
          unawaited(
            _tripSafetyService.createSafetyFlag(
              rideId: rideId,
              riderId: _currentRiderUid ?? '',
              driverId: _currentRideSnapshot?['driver_id']?.toString() ?? '',
              serviceType:
                  _currentRideSnapshot?['service_type']?.toString() ??
                  RiderServiceType.ride.key,
              flagType: 'long_stop',
              source: 'rider_map_monitor',
              message:
                  'Trip stopped longer than expected outside the normal stop radius.',
              status: 'manual_review',
              severity: 'medium',
            ),
          );
        }
        unawaited(
          _showSafetyPopup(
            reason: 'long_stop',
            details:
                'We noticed the vehicle has been stopped longer than expected. Are you safe?',
          ),
        );
      }

      if (distanceFromRoute != null &&
          distanceFromRoute > _configuredRouteDeviationToleranceMeters) {
        _routeDeviationStrikeCount += 1;

        if (_routeDeviationStrikeCount >=
            _configuredRouteDeviationStrikeThreshold) {
          _routeDeviationStrikeCount = 0;
          _logRiderMap(
            'deviation detected rideId=$_currentRideId distanceFromRouteMeters=${distanceFromRoute.toStringAsFixed(1)}',
          );
          _logRideFlow(
            'route deviation detected rideId=$_currentRideId distanceFromRouteMeters=${distanceFromRoute.toStringAsFixed(1)} position=${_formatLatLng(driverPosition)}',
          );
          final rideId = _currentRideId;
          if (rideId != null && rideId.isNotEmpty) {
            unawaited(
              _tripSafetyService.createSafetyFlag(
                rideId: rideId,
                riderId: _currentRiderUid ?? '',
                driverId: _currentRideSnapshot?['driver_id']?.toString() ?? '',
                serviceType:
                    _currentRideSnapshot?['service_type']?.toString() ??
                    RiderServiceType.ride.key,
                flagType: 'route_deviation',
                source: 'rider_map_monitor',
                message:
                    'Trip moved outside the configured route tolerance and needs review.',
                distanceFromRouteMeters: distanceFromRoute,
                status: 'manual_review',
                severity: 'high',
              ),
            );
          }
          unawaited(
            _showSafetyPopup(
              reason: 'route_deviation',
              details:
                  'We noticed the trip moved away from the expected route. Are you safe?',
            ),
          );
        }
      } else {
        _routeDeviationStrikeCount = 0;
      }
      _lastRiderSpeedSampleAt = now;
    }

    _lastSafetyCheckLocation = driverPosition;
  }

  void _moveCameraToBounds(List<LatLng> points, double padding) {
    if (!_mapReady || _mapController == null || points.isEmpty) {
      return;
    }

    final latitudes = points.map((point) => point.latitude);
    final longitudes = points.map((point) => point.longitude);
    final minLat = latitudes.reduce(min);
    final maxLat = latitudes.reduce(max);
    final minLng = longitudes.reduce(min);
    final maxLng = longitudes.reduce(max);

    if (minLat == maxLat && minLng == maxLng) {
      _mapController!.animateCamera(
        CameraUpdate.newLatLngZoom(points.first, 16),
      );
      return;
    }

    _mapController!.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(minLat, minLng),
          northeast: LatLng(maxLat, maxLng),
        ),
        padding,
      ),
    );
  }

  void _moveCamera() {
    if (!_mapReady || _mapController == null) {
      return;
    }

    final dropOffs = _orderedDropOffLocations();
    if (_pickupLocation == null && dropOffs.isEmpty) {
      final idleTarget = _deviceLocationAvailable
          ? _riderLocation
          : _selectedLaunchCityCenter;
      _mapController!.animateCamera(
        CameraUpdate.newLatLngZoom(
          idleTarget,
          RiderServiceAreaConfig.defaultMapZoom,
        ),
      );
      return;
    }

    if (!_tripStarted && _pickupLocation != null && dropOffs.isNotEmpty) {
      _moveCameraToBounds([_pickupLocation!, ...dropOffs], 100);
      return;
    }

    if (!_tripStarted &&
        _lastDriverLocation != null &&
        _pickupLocation != null) {
      _moveCameraToBounds([_lastDriverLocation!, _pickupLocation!], 120);
      return;
    }

    if (_tripStarted && _lastDriverLocation != null && dropOffs.isNotEmpty) {
      _moveCameraToBounds([_lastDriverLocation!, ...dropOffs], 120);
      return;
    }

    if (_lastDriverLocation != null) {
      _mapController!.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: _lastDriverLocation!, zoom: 16, tilt: 45),
        ),
      );
      return;
    }

    if (_pickupLocation != null) {
      _mapController!.animateCamera(
        CameraUpdate.newLatLngZoom(_pickupLocation!, 15),
      );
    }
  }

  void _loadDrivers() {
    _driversSubscription?.cancel();
    _logRideFlow('listening to live drivers');

    _driversSubscription = _driversRef.onValue.listen((event) {
      final raw = event.snapshot.value;
      if (raw is! Map) {
        return;
      }

      final drivers = Map<dynamic, dynamic>.from(raw);
      final driverMarkers = <Marker>{};

      for (final entry in drivers.entries) {
        final driverId = entry.key?.toString() ?? '';
        if (entry.value is! Map) {
          continue;
        }

        final data = Map<String, dynamic>.from(entry.value as Map);
        if (data['online'] != true && data['isOnline'] != true) {
          continue;
        }

        final driverCity = _normalizeServiceCity(
          data['market'] ?? data['launch_market_city'] ?? data['city'],
        );
        if (driverCity != null && driverCity != _selectedLaunchCity) {
          continue;
        }

        final lat = _asDouble(data['lat']);
        final lng = _asDouble(data['lng']);
        if (lat == null || lng == null) {
          continue;
        }

        driverMarkers.add(
          Marker(
            markerId: MarkerId('driver_$driverId'),
            position: LatLng(lat, lng),
            rotation: _asDouble(data['heading']) ?? 0,
            anchor: const Offset(0.5, 0.5),
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueAzure,
            ),
          ),
        );
      }

      _markers.removeWhere(
        (marker) =>
            marker.markerId.value.startsWith('driver_') &&
            marker.markerId.value != 'driver',
      );
      _markers.addAll(driverMarkers);
      _notifyMapLayerChanged();
    });
  }

  Future<void> _saveRiderTrip(
    String rideId,
    Map<String, dynamic> rideData,
  ) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return;
    }

    try {
      final completedAt = DateTime.now().millisecondsSinceEpoch;
      await rtdb.FirebaseDatabase.instance
          .ref('rider_trips/${user.uid}')
          .push()
          .set({
            'trip_id': rideId,
            'service_type':
                rideData['service_type'] ?? RiderServiceType.ride.key,
            'fare': (_asDouble(rideData['fare']) ?? _fare).toDouble(),
            'distance': (_asDouble(rideData['distance_km']) ?? _distanceKm)
                .toDouble(),
            'pickup_lat':
                ((rideData['pickup'] as Map?)?['lat'] ??
                _pickupLocation?.latitude),
            'pickup_lng':
                ((rideData['pickup'] as Map?)?['lng'] ??
                _pickupLocation?.longitude),
            'destination_lat':
                ((rideData['destination'] as Map?)?['lat'] ??
                _destinationLocation?.latitude),
            'destination_lng':
                ((rideData['destination'] as Map?)?['lng'] ??
                _destinationLocation?.longitude),
            'pickup_address': rideData['pickup_address'] ?? _pickupAddress,
            'destination_address':
                rideData['destination_address'] ?? _destinationAddress,
            'final_destination_address':
                rideData['final_destination_address'] ?? _lastDropOffAddress(),
            'stops': rideData['stops'] ?? _buildStopsPayload(),
            'stop_count':
                rideData['stop_count'] ?? _orderedDropOffLocations().length,
            'driver_id': rideData['driver_id'] ?? '',
            'driver_name': rideData['driver_name'] ?? '',
            'car': rideData['car'] ?? '',
            'plate': rideData['plate'] ?? '',
            'fare_breakdown': rideData['fare_breakdown'] ?? <String, dynamic>{},
            'settlement': rideData['settlement'] ?? <String, dynamic>{},
            'grossFare': rideData['grossFare'] ?? rideData['fare'] ?? _fare,
            'commission': rideData['commission'] ?? 0,
            'driverPayout': rideData['driverPayout'] ?? 0,
            'netEarning': rideData['netEarning'] ?? 0,
            'route_basis': rideData['route_basis'] ?? <String, dynamic>{},
            'rider_trust_snapshot':
                rideData['rider_trust_snapshot'] ?? <String, dynamic>{},
            'status': 'completed',
            'created_at':
                rideData['created_at'] ?? DateTime.now().millisecondsSinceEpoch,
            'timestamp': completedAt,
            'completed_at': completedAt,
          });

      _logRideFlow('trip saved to rider history');
    } catch (error) {
      _logRideFlow('saveRiderTrip failed error=$error');
    }
  }

  Future<void> _shareTrip() async {
    final rideId = _currentRideId;
    if (rideId == null || rideId.isEmpty || _isSharingTrip) {
      return;
    }

    if (mounted) {
      setState(() {
        _isSharingTrip = true;
      });
    } else {
      _isSharingTrip = true;
    }

    try {
      _logRideFlow('[SHARE_TRIP_START] rideId=$rideId');
      Map<String, dynamic>? latestRideData;
      try {
        latestRideData = await _fetchLatestRideSnapshot(rideId)
            .timeout(const Duration(seconds: 8));
      } on TimeoutException {
        _logRideFlow('[SHARE] fallback ride snapshot timeout rideId=$rideId');
        latestRideData = null;
      }
      latestRideData = latestRideData ?? _currentRideSnapshot;
      final payload = _buildShareTripPayload(
        rideId: rideId,
        rideData: latestRideData,
      );
      if (payload == null) {
        _logRideFlow('[SHARE_TRIP_FAIL] rideId=$rideId reason=no_payload');
        _showSnackBar('Unable to prepare trip sharing right now.');
        return;
      }

      _currentRideSnapshot = latestRideData ?? _currentRideSnapshot;

      ShareTripLink? shareLink;
      try {
        shareLink = await _shareTripRtdbService
            .ensureShare(payload)
            .timeout(const Duration(seconds: 10));
        _logRideFlow('[SHARE_TRIP_LINK_OK] rideId=$rideId');
      } catch (error) {
        _logRideFlow(
          '[SHARE_TRIP_LINK_FAIL] rideId=$rideId error=$error',
        );
      }

      final shareStops = payload.stops;
      final stopLines = shareStops
          .map((stop) => 'Stop ${stop['order']}: ${stop['address']}')
          .where((line) => line.trim().isNotEmpty)
          .join('\n');
      final vehicle = payload.driver?['car']?.toString().trim() ?? '';
      final plate = payload.driver?['plate']?.toString().trim() ?? '';
      final shareText = StringBuffer();
      if (shareLink != null) {
        _logRideFlow(
          '[SHARE_TRIP_URL] rideId=$rideId url=${shareLink.url}',
        );
        shareText
          ..writeln('Track this NexRide trip live:')
          ..writeln(shareLink.url);
      } else {
        final fallbackUrl =
            '${ShareTripRtdbService.shareBaseUrl}?rideId=${Uri.encodeComponent(rideId)}';
        _logRideFlow(
          '[SHARE_TRIP_URL_FALLBACK] rideId=$rideId url=$fallbackUrl',
        );
        shareText
          ..writeln('NexRide trip summary (live tracking link unavailable):')
          ..writeln(fallbackUrl);
      }
      shareText
        ..writeln()
        ..writeln('Ride ID: $rideId')
        ..writeln('Status: ${_rideStatusLabel(payload.status)}')
        ..writeln(
          'Driver: ${_firstNonEmptyText(<dynamic>[payload.driver?['name']], fallback: 'Driver not assigned yet')}',
        )
        ..writeln('Vehicle: ${vehicle.isEmpty ? 'Not assigned yet' : vehicle}')
        ..writeln('Plate: ${plate.isEmpty ? 'Not assigned yet' : plate}')
        ..writeln('Pickup: ${payload.pickup['address']}')
        ..writeln('Destination: ${payload.destination['address']}');

      if (stopLines.isNotEmpty) {
        shareText
          ..writeln('Stops:')
          ..writeln(stopLines);
      }

      _logRideFlow('share trip triggered rideId=$rideId');
      await Share.share(
        shareText.toString().trim(),
        subject: 'NexRide live trip $rideId',
      );
      if (shareLink == null) {
        _logRideFlow('[SHARE_TRIP_FALLBACK_OK] rideId=$rideId');
        if (mounted) {
          _showSnackBar('Trip summary shared successfully.');
        }
      }
    } catch (error) {
      _logRideFlow('[SHARE_TRIP_FAIL] rideId=$rideId error=$error');
      _showSnackBar('Unable to share this trip right now.');
    } finally {
      if (mounted) {
        setState(() {
          _isSharingTrip = false;
        });
      } else {
        _isSharingTrip = false;
      }
    }
  }

  Future<void> _openEmergencySheet() async {
    final rideId = _currentRideId;
    if (rideId == null || rideId.isEmpty || !mounted) {
      return;
    }

    _logRideFlow('SOS tapped rideId=$rideId status=$_rideStatus');

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const ListTile(
                  title: Text(
                    'Emergency actions',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text('Choose the safest option for this trip.'),
                ),
                ListTile(
                  leading: const Icon(Icons.call, color: Colors.red),
                  title: const Text('Call emergency contact'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    safeShowSnackBar(
                      context,
                      'No emergency contact is configured yet. Please call local emergency services immediately.',
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.share, color: _gold),
                  title: const Text('Share live trip'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_shareTrip());
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.warning_amber, color: Colors.red),
                  title: const Text('Emergency help / alert'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    safeShowSnackBar(
                      context,
                      'Emergency help is not connected yet. Please call local emergency services now.',
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.support_agent, color: _gold),
                  title: const Text('Contact support team'),
                  subtitle: Text(
                    'Email $kNexRideSupportEmail — include your ride ID if you can.',
                  ),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    final id = rideId;
                    safeShowSnackBar(
                      context,
                      id.isEmpty
                          ? 'Support: email $kNexRideSupportEmail with your account phone number, or use your trip receipt after the ride ends.'
                          : 'Support: email $kNexRideSupportEmail and reference ride ID $id.',
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  rtdb.DatabaseReference _rideChatMessagesRef(String rideId) {
    return _rideRequestsRef.root.child(canonicalRideChatMessagesPath(rideId));
  }

  Future<void> _mirrorRiderChatToTripRouteLog({
    required String rideId,
    required String messageId,
    required Map<String, dynamic> payload,
    required Map<String, dynamic> lastMessageMeta,
  }) async {
    try {
      await _rideRequestsRef.root.update(<String, dynamic>{
        'trip_route_logs/$rideId/chat/lastMessage': lastMessageMeta,
        'trip_route_logs/$rideId/chat/messageCountUpdatedAt':
            rtdb.ServerValue.timestamp,
        'trip_route_logs/$rideId/chat/messages/$messageId': payload,
        'trip_route_logs/$rideId/chat/updatedAt': rtdb.ServerValue.timestamp,
      });
    } catch (error) {
      _logRideFlow(
        'chat trip_route_logs mirror skipped rideId=$rideId error=$error',
      );
    }
  }

  void _confirmRiderOptimisticMessageSent({
    required String rideId,
    required String messageId,
    required String senderId,
    required String text,
    required int clientCreatedAt,
  }) {
    if (_riderChatListenerRideId != rideId) {
      return;
    }
    final existing = _riderChatMessagesById[messageId];
    final type = existing?.type ?? 'text';
    final imageUrl = existing?.imageUrl ?? '';
    _riderChatMessagesById[messageId] = RideChatMessage(
      id: messageId,
      rideId: rideId,
      messageId: messageId,
      senderId: senderId,
      senderRole: 'rider',
      type: type,
      text: text,
      imageUrl: imageUrl,
      createdAt: clientCreatedAt,
      status: 'sent',
      isRead: false,
      localTempId: messageId,
    );
    _flushRiderChatMessageTable(rideId);
  }

  void _markRiderOptimisticMessageFailed({
    required String rideId,
    required String messageId,
    required String senderId,
    required String text,
  }) {
    if (_riderChatListenerRideId != rideId) {
      return;
    }
    final existing = _riderChatMessagesById[messageId];
    if (existing == null) {
      return;
    }
    _riderChatMessagesById[messageId] = RideChatMessage(
      id: messageId,
      rideId: rideId,
      messageId: messageId,
      senderId: senderId,
      senderRole: 'rider',
      type: existing.type,
      text: text.isNotEmpty ? text : existing.text,
      imageUrl: existing.imageUrl,
      createdAt: existing.createdAt,
      status: 'failed',
      isRead: false,
      localTempId: existing.localTempId,
    );
    _flushRiderChatMessageTable(rideId);
  }

  Future<String?> sendMessage(String rideId, String text) async {
    return _sendRiderChatMessageInternal(rideId: rideId, text: text);
  }

  Future<String?> _retryRiderChatMessage(
    String rideId,
    RideChatMessage message,
  ) async {
    _logRideFlow(
      '[CHAT_RETRY] role=rider rideId=$rideId uid=${FirebaseAuth.instance.currentUser?.uid ?? ''} '
      'messageId=${message.id}',
    );
    return _sendRiderChatMessageInternal(
      rideId: rideId,
      text: message.text,
      imageUrl: message.imageUrl,
      retryMessageId: message.id,
      retryType: message.type,
    );
  }

  Future<String?> _sendRiderChatMessageInternal({
    required String rideId,
    required String text,
    String imageUrl = '',
    String? retryMessageId,
    String retryType = 'text',
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return 'Please log in before sending a message.';
    }

    final trimmed = text.trim();
    final normalizedImageUrl = imageUrl.trim();
    if (trimmed.isEmpty && normalizedImageUrl.isEmpty) {
      return null;
    }

    if (!_canChat || !_isRiderChatSessionActive(rideId)) {
      return 'Chat becomes available once your driver accepts the ride.';
    }

    final normalizedRideId = rideId.trim();
    final rootRef = _rideRequestsRef.root;
    final messagesRef = _rideChatMessagesRef(normalizedRideId);
    final messageNode = retryMessageId?.trim().isNotEmpty == true
        ? messagesRef.child(retryMessageId!.trim())
        : messagesRef.push();
    final messageId = messageNode.key?.trim() ?? '';
    if (messageId.isEmpty) {
      return 'Unable to start this chat message right now.';
    }

    try {
      if (_riderChatListenerRideId == null &&
          _isRiderChatSessionActive(normalizedRideId)) {
        _startRiderChatListener(normalizedRideId);
      }
      final clientCreatedAt = DateTime.now().millisecondsSinceEpoch;
      final messageType = normalizedImageUrl.isNotEmpty ? 'image' : retryType;
      final optimistic = RideChatMessage(
        id: messageId,
        rideId: normalizedRideId,
        messageId: messageId,
        senderId: user.uid,
        senderRole: 'rider',
        type: messageType,
        text: trimmed,
        imageUrl: normalizedImageUrl,
        createdAt: clientCreatedAt,
        status: 'sending',
        isRead: false,
        localTempId: messageId,
      );
      if (_riderChatListenerRideId == normalizedRideId) {
        _riderChatMessagesById[messageId] = optimistic;
        _flushRiderChatMessageTable(normalizedRideId);
      }

      final payload = <String, dynamic>{
        'senderId': user.uid,
        'senderRole': 'rider',
        'type': messageType,
        'text': trimmed,
        'imageUrl': normalizedImageUrl.isEmpty ? null : normalizedImageUrl,
        'timestamp': rtdb.ServerValue.timestamp,
      };
      final lastMessageMetaPlain = <String, dynamic>{
        'id': messageId,
        'ride_id': normalizedRideId,
        'sender_id': user.uid,
        'sender_role': 'rider',
        'text': _rideChatPreview(
          trimmed.isEmpty ? 'Photo' : trimmed,
        ),
        'created_at': clientCreatedAt,
        'created_at_client': clientCreatedAt,
      };
      _logRideFlow(
        '[CHAT_SEND_START] role=rider rideId=$normalizedRideId '
        'messageId=$messageId path=${canonicalRideChatMessagesPath(normalizedRideId)}/$messageId',
      );
      try {
        Future<void> writeAttempt() async {
          await messageNode
              .setWithPriority(payload, -clientCreatedAt)
              .timeout(_rideChatSendTimeout);
        }

        try {
          await writeAttempt();
        } catch (_) {
          await writeAttempt();
        }

        await rootRef.update(<String, dynamic>{
          '${canonicalRideChatParticipantPath(normalizedRideId, user.uid)}/uid':
              user.uid,
          '${canonicalRideChatParticipantPath(normalizedRideId, user.uid)}/sender_role':
              'rider',
          '${canonicalRideChatParticipantPath(normalizedRideId, user.uid)}/updated_at':
              rtdb.ServerValue.timestamp,
          '${canonicalRideChatMetaPath(normalizedRideId)}/rideId': normalizedRideId,
          '${canonicalRideChatMetaPath(normalizedRideId)}/rider_id': user.uid,
          '${canonicalRideChatMetaPath(normalizedRideId)}/driver_id':
              _valueAsText(_currentRideSnapshot?['driver_id']),
          '${canonicalRideChatMetaPath(normalizedRideId)}/created_at':
              rtdb.ServerValue.timestamp,
          '${canonicalRideChatMetaPath(normalizedRideId)}/updated_at':
              rtdb.ServerValue.timestamp,
          '${canonicalRideChatMetaPath(normalizedRideId)}/last_message':
              lastMessageMetaPlain['text'],
          '${canonicalRideChatMetaPath(normalizedRideId)}/last_message_sender_id':
              user.uid,
          '${canonicalRideChatMetaPath(normalizedRideId)}/last_message_at':
              rtdb.ServerValue.timestamp,
          '${canonicalRideChatMetaPath(normalizedRideId)}/status': 'active',
        });
        final patchRes = await _rideCloud.patchRideRequestMetadata(
          rideId: normalizedRideId,
          patch: <String, dynamic>{
            'chat_last_message': lastMessageMetaPlain,
            'chat_last_message_text': lastMessageMetaPlain['text'],
            'chat_last_message_sender_id': user.uid,
            'chat_last_message_sender_role': 'rider',
            'chat_last_message_at': clientCreatedAt,
            'chat_updated_at': clientCreatedAt,
            'has_chat_messages': true,
          },
        );
        if (!riderRideCallableSucceeded(patchRes)) {
          return 'Unable to sync this message to the trip right now.';
        }

        _confirmRiderOptimisticMessageSent(
          rideId: normalizedRideId,
          messageId: messageId,
          senderId: user.uid,
          text: trimmed,
          clientCreatedAt: clientCreatedAt,
        );

        final driverRecipient = _firstNonEmptyText(<dynamic>[
          _currentRideSnapshot?['driver_id'],
          _currentRideSnapshot?['matched_driver_id'],
        ]).trim();
        if (driverRecipient.isNotEmpty && driverRecipient != 'waiting') {
          unawaited(
            _bumpRideChatUnreadForRecipient(
              rideId: normalizedRideId,
              recipientUid: driverRecipient,
            ),
          );
        }

        unawaited(_mirrorRiderChatToTripRouteLog(
          rideId: normalizedRideId,
          messageId: messageId,
          payload: payload,
          lastMessageMeta: lastMessageMetaPlain,
        ));

        _logRideFlow(
          '[CHAT_SEND_OK] role=rider rideId=$normalizedRideId '
          'messageId=$messageId path=${canonicalRideChatMessagesPath(normalizedRideId)}/$messageId',
        );
        return null;
      } catch (error) {
        _markRiderOptimisticMessageFailed(
          rideId: normalizedRideId,
          messageId: messageId,
          senderId: user.uid,
          text: trimmed,
        );
        _logRideFlow(
          '[CHAT_SEND_FAIL] role=rider rideId=$normalizedRideId '
          'messageId=$messageId error=$error',
        );
        if (isPermissionDeniedError(error)) {
          _logRideFlow(
            '[CHAT_PERMISSION_DENIED] role=rider rideId=$normalizedRideId '
            'messageId=$messageId error=$error',
          );
        }
        if (error is TimeoutException) {
          return 'Sending this message took too long. Please try again.';
        }
        return isPermissionDeniedError(error)
            ? 'Chat permission was denied for this ride.'
            : 'Unable to send message right now.';
      }
    } finally {}
  }

  Future<String?> _sendRiderChatImage(
    String rideId,
    RideChatImageSource source,
  ) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return 'Please log in before sending a photo.';
    }
    final normalizedRideId = rideId.trim();
    final useCamera = source == RideChatImageSource.camera;
    _logRideFlow(
      '[CHAT_IMAGE_PICK] role=rider rideId=$normalizedRideId uid=${user.uid} source=${useCamera ? 'camera' : 'gallery'}',
    );
    if (useCamera) {
      final cameraPermission = await Permission.camera.request();
      if (!cameraPermission.isGranted) {
        return 'Camera permission is required to take a photo.';
      }
    }
    final picked = await _riderChatImagePicker.pickImage(
      source: useCamera ? ImageSource.camera : ImageSource.gallery,
      maxWidth: 1600,
      imageQuality: 86,
    );
    if (picked == null) {
      return null;
    }
    _logRideFlow(
      '[CHAT_IMAGE_UPLOAD_START] role=rider rideId=$normalizedRideId uid=${user.uid}',
    );
    try {
      final uploaded = await _dispatchPhotoUploadService.uploadRideChatPhoto(
        rideId: normalizedRideId,
        actorId: user.uid,
        asset: DispatchPhotoSelectedAsset(
          localPath: picked.path,
          fileName: picked.name.isNotEmpty
              ? picked.name
              : picked.path.split('/').last,
          mimeType: picked.path.toLowerCase().endsWith('.png')
              ? 'image/png'
              : 'image/jpeg',
          fileSizeBytes: await picked.length(),
          source: useCamera ? 'camera' : 'gallery',
        ),
      );
      final result = await _sendRiderChatMessageInternal(
        rideId: normalizedRideId,
        text: '',
        imageUrl: uploaded.fileUrl,
        retryType: 'image',
      );
      if (result == null) {
        _logRideFlow(
          '[CHAT_IMAGE_UPLOAD_OK] role=rider rideId=$normalizedRideId uid=${user.uid}',
        );
      } else {
        _logRideFlow(
          '[CHAT_IMAGE_UPLOAD_FAIL] role=rider rideId=$normalizedRideId uid=${user.uid} error=$result',
        );
      }
      return result;
    } catch (error) {
      _logRideFlow(
        '[CHAT_IMAGE_UPLOAD_FAIL] role=rider rideId=$normalizedRideId uid=${user.uid} error=$error',
      );
      return 'Unable to send this image right now.';
    }
  }

  void _setRiderChatMessages(String rideId, List<RideChatMessage> messages) {
    if (_riderChatListenerRideId != rideId) {
      return;
    }

    _riderChatMessages.value = List<RideChatMessage>.unmodifiable(messages);
  }

  void _reportRiderChatIssue(String rideId, String message, {Object? error}) {
    final errorSuffix = error == null ? '' : ':$error';
    final issueKey = '$rideId:$message$errorSuffix';
    _logRideFlow(
      'rider chat issue rideId=$rideId message=$message$errorSuffix',
    );
    if (_lastRiderChatErrorNoticeKey == issueKey) {
      return;
    }

    _lastRiderChatErrorNoticeKey = issueKey;
    if (error != null && isPermissionDeniedError(error)) {
      _logRideFlow('[CHAT_PERMISSION_DENIED] role=rider rideId=$rideId message=$message error=$error');
    }
    if (_isRiderChatSessionActive(rideId)) {
      _showSnackBar(
        'Chat is syncing. Please retry in a moment.',
      );
    }
  }

  Future<void> _markRiderMessagesRead(
    String rideId, {
    List<RideChatMessage>? messages,
  }) async {
    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    if (currentUserId == null) {
      return;
    }

    final updates = <String, dynamic>{};
    final currentMessages = messages ?? _riderChatMessages.value;

    for (final message in currentMessages) {
      final isIncomingDriverMessage =
          message.senderRole == 'driver' &&
          message.senderId != currentUserId &&
          !message.isRead;
      if (!isIncomingDriverMessage) {
        continue;
      }

      updates['${message.id}/read'] = true;
    }

    if (updates.isEmpty) {
      return;
    }

    try {
      await _rideChatMessagesRef(rideId).update(updates);
    } catch (error) {
      _reportRiderChatIssue(rideId, 'mark_read_failed', error: error);
    }
  }

  void _updateRiderUnreadCount(String rideId, int unreadCount) {
    if (_riderUnreadChatCount == unreadCount) {
      return;
    }

    if (mounted) {
      _setStateSafely(() {
        _riderUnreadChatCount = unreadCount;
      });
    } else {
      _riderUnreadChatCount = unreadCount;
    }

    _logRideFlow(
      '[CHAT_UNREAD_INC] role=rider rideId=$rideId uid=${FirebaseAuth.instance.currentUser?.uid ?? ''} '
      'unreadCount=$unreadCount',
    );
  }

  void _resetRiderUnreadCount(String rideId) {
    _updateRiderUnreadCount(rideId, 0);
    _logRideFlow(
      '[CHAT_UNREAD_CLEAR] role=rider rideId=$rideId uid=${FirebaseAuth.instance.currentUser?.uid ?? ''} unreadCount=0',
    );
  }

  Future<void> _clearOwnRideChatUnreadRtdb(String rideId, String uid) async {
    final u = uid.trim();
    if (u.isEmpty) {
      return;
    }
    try {
      await _rideRequestsRef.root.update(<String, dynamic>{
        canonicalRideChatUnreadCountPath(rideId, u): 0,
        canonicalRideChatUnreadUpdatedAtPath(rideId, u):
            rtdb.ServerValue.timestamp,
      });
    } catch (error) {
      _logRideFlow('ride chat unread clear failed rideId=$rideId error=$error');
    }
  }

  Future<void> _bumpRideChatUnreadForRecipient({
    required String rideId,
    required String recipientUid,
  }) async {
    final rid = recipientUid.trim();
    if (rid.isEmpty) {
      return;
    }
    final ref =
        _rideRequestsRef.root.child(canonicalRideChatUnreadCountPath(rideId, rid));
    try {
      await ref.runTransaction((Object? current) {
        final n =
            current is int ? current : (current is num ? current.toInt() : 0);
        return rtdb.Transaction.success(n + 1);
      });
      await _rideRequestsRef.root.update(<String, dynamic>{
        canonicalRideChatUnreadUpdatedAtPath(rideId, rid):
            rtdb.ServerValue.timestamp,
      });
    } catch (error) {
      _logRideFlow(
        'ride chat unread bump failed rideId=$rideId recipient=$rid error=$error',
      );
    }
  }

  void _stopRiderChatListener() {
    final rideId = _riderChatListenerRideId;
    if (rideId != null && rideId.trim().isNotEmpty) {
      _rideChatMessagesRef(rideId).keepSynced(false);
    }
    for (final sub in _riderChatSubscriptions) {
      sub.cancel();
    }
    _riderChatSubscriptions.clear();
    _riderChatMessagesById.clear();
    _riderChatListenerRideId = null;
  }

  void _flushRiderChatMessageTable(String rideId) {
    if (_riderChatListenerRideId != rideId) {
      return;
    }
    final messages = sortedRideChatMessagesFromMap(_riderChatMessagesById);
    _setRiderChatMessages(rideId, messages);
    _processRiderChatMessagesUpdate(rideId, messages);
  }

  void _processRiderChatMessagesUpdate(
    String rideId,
    List<RideChatMessage> messages,
  ) {
    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    if (currentUserId == null) {
      _hasHydratedRiderChatMessages = true;
      _lastRiderChatErrorNoticeKey = null;
      return;
    }

    var unreadCount = 0;
    var receivedNewDriverMessage = false;

    for (final message in messages) {
      if (message.senderRole != 'driver' ||
          message.senderId == currentUserId) {
        continue;
      }

      if (!message.isRead) {
        unreadCount += 1;
      }

      final messageKey = '$rideId:${message.id}';
      if (_hasHydratedRiderChatMessages) {
        if (_loggedRiderChatMessageIds.add(messageKey)) {
          receivedNewDriverMessage = true;
        }
      } else {
        _loggedRiderChatMessageIds.add(messageKey);
      }
    }

    if (_hasHydratedRiderChatMessages && receivedNewDriverMessage) {
      _logRideFlow(
        'new chat message rideId=$rideId unreadCount=$unreadCount chatOpen=$_isRiderChatOpen',
      );
      unawaited(_playChatNotificationSound());
    }

    if (_isRiderChatOpen) {
      _updateRiderUnreadCount(rideId, 0);
      if (unreadCount > 0) {
        unawaited(
          _markRiderMessagesRead(rideId, messages: messages),
        );
      }
    } else {
      _updateRiderUnreadCount(rideId, unreadCount);

      if (_hasHydratedRiderChatMessages &&
          receivedNewDriverMessage &&
          mounted) {
        _showRiderIncomingChatNotice();
      }
    }

    _hasHydratedRiderChatMessages = true;
    _lastRiderChatErrorNoticeKey = null;
  }

  void _startRiderChatListener(String rideId) {
    if (_riderChatListenerRideId == rideId &&
        _riderChatSubscriptions.isNotEmpty) {
      return;
    }

    _stopRiderChatListener();
    _riderChatListenerRideId = rideId;
    _hasHydratedRiderChatMessages = false;
    _loggedRiderChatMessageIds.clear();
    _lastRiderChatErrorNoticeKey = null;
    _riderChatMessages.value = const <RideChatMessage>[];
    _riderChatMessagesById.clear();
    _logRideFlow(
      '[CHAT_ATTACH] role=rider rideId=$rideId '
      'path=${canonicalRideChatMessagesPath(rideId)}',
    );

    final messagesRef = _rideChatMessagesRef(rideId);
    messagesRef.keepSynced(true);
    final ref = messagesRef.orderByChild('timestamp');
    _riderChatSubscriptions.add(
      ref.onValue.listen(
        (event) {
          final parsed = parseRideChatSnapshot(
            rideId: rideId,
            raw: event.snapshot.value,
          );
          _riderChatMessagesById
            ..clear()
            ..addEntries(parsed.messages.map((m) => MapEntry<String, RideChatMessage>(m.id, m)));
          _flushRiderChatMessageTable(rideId);
        },
        onError: (Object error) {
          _reportRiderChatIssue(rideId, 'listener_onvalue_failed', error: error);
        },
      ),
    );
  }

  void _openChat() {
    final rideId = _activeRideInteractionId;
    final user = FirebaseAuth.instance.currentUser;
    if (rideId == null || user == null || !_canChat) {
      return;
    }

    _logRideFlow('[CHAT_OPEN] role=rider rideId=$rideId');
    _resetRiderUnreadCount(rideId);
    unawaited(_clearOwnRideChatUnreadRtdb(rideId, user.uid));
    unawaited(
      _markRiderMessagesRead(rideId, messages: _riderChatMessages.value),
    );

    if (mounted) {
      _setStateSafely(() {
        _riderMissedCallNotice = false;
        _isRiderChatOpen = true;
      });
    } else {
      _riderMissedCallNotice = false;
      _isRiderChatOpen = true;
    }

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) {
        return RideChatSheet(
          rideId: rideId,
          currentUserId: user.uid,
          messagesListenable: _riderChatMessages,
          onSendMessage: sendMessage,
          onRetryMessage: _retryRiderChatMessage,
          onSendImage: _sendRiderChatImage,
          initialDraft: _riderChatDraftByRide[rideId] ?? '',
          onDraftChanged: (value) {
            _riderChatDraftByRide[rideId] = value;
          },
          onStartVoiceCall: _showRideCallButton
              ? () {
                  unawaited(_startVoiceCallFromChat());
                }
              : null,
          showCallButton: _showRideCallButton,
          isCallButtonEnabled: _isRideCallButtonEnabled,
          isCallButtonBusy: _isStartingVoiceCall,
          bankTransferReference: _valueAsText(
                        _currentRideSnapshot?['payment_method'],
                      )
                          .trim()
                          .toLowerCase()
                          .replaceAll(RegExp(r'[\s-]+'), '_') ==
                      'bank_transfer'
                  ? _bankTransferReferenceFromRide(_currentRideSnapshot)
                  : '',
          bankTransferAmountLabel: _valueAsText(
                        _currentRideSnapshot?['payment_method'],
                      )
                          .trim()
                          .toLowerCase()
                          .replaceAll(RegExp(r'[\s-]+'), '_') ==
                      'bank_transfer'
                  ? '₦${((_asDouble(_currentRideSnapshot?['fare']) ?? _fare)).toStringAsFixed(0)}'
                  : '',
        );
      },
    ).whenComplete(() {
      _isRiderChatOpen = false;
      _riderChatDraftByRide.removeWhere((key, _) => key != rideId);
    });
  }

  Future<void> _submitRating(String driverId, double rating) async {
    final ref = _driversRef.child(driverId);
    final snapshot = await ref.get();

    if (snapshot.value is! Map) {
      return;
    }

    final data = Map<String, dynamic>.from(snapshot.value as Map);
    final currentRating = _asDouble(data['rating']) ?? 5;
    final totalTrips = (data['total_trips'] as num?)?.toInt() ?? 0;
    final newRating =
        ((currentRating * totalTrips) + rating) / (totalTrips + 1);

    await ref.update({'rating': newRating, 'total_trips': totalTrips + 1});
  }

  void _showRatingDialog(String driverId) {
    var rating = 5.0;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) {
        return AlertDialog(
          title: const Text('Rate Driver'),
          content: StatefulBuilder(
            builder: (context, setDialogState) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List<Widget>.generate(5, (index) {
                      final starValue = (index + 1).toDouble();
                      return IconButton(
                        onPressed: () {
                          setDialogState(() {
                            rating = starValue;
                          });
                        },
                        icon: Icon(
                          rating >= starValue
                              ? Icons.star_rounded
                              : Icons.star_outline_rounded,
                          color: Colors.amber,
                          size: 34,
                        ),
                      );
                    }),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${rating.toStringAsFixed(0)} out of 5',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await _submitRating(driverId, rating);
                if (mounted) {
                  Navigator.of(context).pop();
                }
              },
              child: const Text('Submit'),
            ),
          ],
        );
      },
    );
  }

  Widget _pickupSearch() {
    return NativePlacesAutocompleteField(
      controller: _pickupController,
      hintText: 'Pickup location',
      countryCode: RiderLaunchScope.countryCode,
      searchScopeLabel: RiderLaunchScope.launchCitiesLabel,
      queryTransform: (String query) => RiderLaunchScope.normalizeAddressQuery(
        query,
        preferredCity: _selectedLaunchCity,
      ),
      fallbackSuggestionsBuilder: _fallbackPlaceSuggestions,
      onSelected: (suggestion) async {
        await _handlePlaceSelection(suggestion: suggestion, isPickup: true);
      },
    );
  }

  Widget _dropOffSearchField({
    required TextEditingController controller,
    required String hintText,
    required Future<void> Function(NativePlaceSuggestion suggestion) onSelected,
    VoidCallback? onRemove,
  }) {
    return Row(
      children: [
        Expanded(
          child: NativePlacesAutocompleteField(
            controller: controller,
            hintText: hintText,
            countryCode: RiderLaunchScope.countryCode,
            searchScopeLabel: RiderLaunchScope.launchCitiesLabel,
            queryTransform: (String query) =>
                RiderLaunchScope.normalizeAddressQuery(
                  query,
                  preferredCity: _selectedLaunchCity,
                ),
            fallbackSuggestionsBuilder: _fallbackPlaceSuggestions,
            onSelected: (suggestion) async {
              await onSelected(suggestion);
            },
          ),
        ),
        if (onRemove != null) ...[
          const SizedBox(width: 8),
          Material(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            child: IconButton(
              onPressed: onRemove,
              icon: const Icon(Icons.close, color: Colors.red),
            ),
          ),
        ],
      ],
    );
  }

  Widget _destinationSearch() {
    return _dropOffSearchField(
      controller: _destinationController,
      hintText: 'Where to?',
      onSelected: (suggestion) {
        return _handlePlaceSelection(suggestion: suggestion, isPickup: false);
      },
    );
  }

  Widget _additionalStopSearch(int extraStopIndex) {
    return _dropOffSearchField(
      controller: _additionalStopControllers[extraStopIndex],
      hintText: 'Stop ${extraStopIndex + 2}',
      onSelected: (suggestion) {
        return _handleAdditionalStopSelection(
          suggestion: suggestion,
          extraStopIndex: extraStopIndex,
        );
      },
      onRemove: () {
        unawaited(_removeAdditionalStopField(extraStopIndex));
      },
    );
  }

  Widget _sosButton() {
    return Material(
      elevation: 8,
      color: Colors.red,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: _openEmergencySheet,
        child: const SizedBox(
          width: 60,
          height: 60,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.white, size: 22),
              SizedBox(height: 2),
              Text(
                'SOS',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bottomPanel({bool collapsed = false}) {
    _logRequestUiState();
    final effectiveStatus = _effectiveRideStatus;
    final statusText = _rideStatusLabel(effectiveStatus);
    final stopAddresses = _orderedDropOffAddresses();
    final showRouteSummary = _hasActiveRide || _hasRoutePreviewReady;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
      decoration: BoxDecoration(
        color: _panelBackground,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
        boxShadow: [
          BoxShadow(
            color: _routeShadow.withValues(alpha: 0.08),
            blurRadius: 28,
            offset: const Offset(0, -8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 46,
            height: 5,
            decoration: BoxDecoration(
              color: _panelBorder,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          const SizedBox(height: 12),
          _buildRideStatusHeroCard(statusText),
          if (collapsed) ...[
            const SizedBox(height: 10),
            _buildPanelCard(
              child: Row(
                children: [
                  _buildCollapsedMetric(label: 'Fare', value: '₦${_fare.toStringAsFixed(0)}'),
                  _buildCollapsedMetric(
                    label: 'ETA',
                    value: _estimatedDurationMin > 0
                        ? '${_estimatedDurationMin.toStringAsFixed(0)} min'
                        : '--',
                  ),
                ],
              ),
            ),
            if (!_hidePrimaryRideDuringMatchingOnly) ...[
              const SizedBox(height: 10),
              _buildPrimaryRideButton(),
            ],
          ],
          if (!collapsed && _routePreviewError != null && !_hasActiveRide) ...[
            const SizedBox(height: 12),
            _buildRouteErrorCard(),
          ],
          if (!collapsed)
            _buildRouteSummaryCard(
              showRouteSummary: showRouteSummary,
              stopAddresses: stopAddresses,
            ),
          if (!collapsed && !_hasActiveRide && _hasRoutePreviewReady) ...[
            const SizedBox(height: 12),
            _buildTripPaymentMethodSelectorCard(),
          ],
          if (!collapsed && _driverFound && _driverData != null) ...[
            const SizedBox(height: 12),
            _buildDriverAssignmentCard(),
          ],
          if (!collapsed && effectiveStatus == 'arrived') ...[
            const SizedBox(height: 12),
            _buildArrivalCountdownCard(),
          ],
          if (!collapsed && _canShowCancelRequestButton) ...[
            const SizedBox(height: 10),
            _buildSecondaryRideActionButton(
              label: 'Cancel request',
              icon: Icons.close_rounded,
              filled: false,
              busy: _isCancellingRide,
              onPressed: _isCancellingRide
                  ? null
                  : () {
                      unawaited(_cancelRideRequestFromPanel());
                    },
            ),
          ],
          if (!(_hasActiveRide && collapsed)) ...[
            if (!_hidePrimaryRideDuringMatchingOnly) ...[
              const SizedBox(height: 12),
              _buildPrimaryRideButton(),
            ],
            if (!collapsed && _canShareTrip) ...[
              const SizedBox(height: 10),
              _buildSecondaryRideActionButton(
                label: 'Share trip',
                icon: Icons.share_outlined,
                filled: true,
                busy: _isSharingTrip,
                onPressed: () {
                  unawaited(_shareTrip());
                },
              ),
            ],
            if (_canChat) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _buildSecondaryRideActionButton(
                      label: 'Open chat',
                      icon: Icons.chat_bubble_outline_rounded,
                      onPressed: _openChat,
                      badgeText: _riderUnreadChatCount > 0
                          ? _riderUnreadBadgeText()
                          : null,
                    ),
                  ),
                  if (_showRideCallButton) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: _buildSecondaryRideActionButton(
                        label: 'Call',
                        icon: Icons.call_outlined,
                        busy: _isStartingVoiceCall,
                        onPressed: _isRideCallButtonEnabled
                            ? () {
                                unawaited(_startVoiceCallFromChat());
                              }
                            : null,
                        badgeText: _riderMissedCallNotice ? '!' : null,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildActiveRideDraggablePanel() {
    return Positioned.fill(
      child: NotificationListener<DraggableScrollableNotification>(
        onNotification: (notification) {
          final expanded = notification.extent > 0.5;
          if (expanded != _isRiderTripSheetExpanded && mounted) {
            setState(() {
              _isRiderTripSheetExpanded = expanded;
            });
          }
          return false;
        },
        child: DraggableScrollableSheet(
          initialChildSize: 0.35,
          minChildSize: 0.15,
          maxChildSize: 0.7,
          snap: true,
          snapSizes: const <double>[0.15, 0.35, 0.7],
          builder: (context, scrollController) {
            return SingleChildScrollView(
              controller: scrollController,
              physics: const ClampingScrollPhysics(),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: _bottomPanel(collapsed: !_isRiderTripSheetExpanded),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showSosButton = _effectiveRideStatus == 'on_trip';
    final showReturnToTripBanner =
        !_hasActiveRide &&
        (_recoverableActiveRideId?.trim().isNotEmpty ?? false);

    return Scaffold(
      body: Stack(
        children: [
          ValueListenableBuilder<int>(
            valueListenable: _mapLayerVersion,
            builder: (context, _, child) {
              if (_mapPlatformSurfaceFailed) {
                return ColoredBox(
                  color: Colors.black,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        kMapUnavailableUserMessage,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white70,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ),
                );
              }
              return GoogleMap(
                key: ValueKey<String>('rider-map-$_selectedLaunchCity'),
                initialCameraPosition: CameraPosition(
                  target: _riderLocation,
                  zoom: RiderServiceAreaConfig.defaultMapZoom,
                ),
                mapType: MapType.normal,
                markers: _markers,
                polylines: _polylines,
                myLocationEnabled: _deviceLocationAvailable,
                myLocationButtonEnabled: _deviceLocationAvailable,
                onMapCreated: (controller) {
                  try {
                    _mapController = controller;
                    _mapReady = true;
                    _iosMapCameraIdleObserved = false;
                    _logRiderMap(
                      'map created platform=${defaultTargetPlatform.name} city=$_selectedLaunchCity markers=${_markers.length} polylines=${_polylines.length}',
                    );
                    _syncTripLocationMarkers();
                    _moveCamera();
                    if (defaultTargetPlatform == TargetPlatform.iOS) {
                      _scheduleIosMapStabilization(controller: controller);
                      _scheduleIosMapTileRecovery(controller: controller);
                    }
                  } catch (e, st) {
                    if (kDebugMode) {
                      debugPrint('[RiderMap] onMapCreated error: $e');
                      debugPrintStack(
                        label: '[RiderMap] onMapCreated stack',
                        stackTrace: st,
                      );
                    }
                    if (mounted) {
                      setState(() => _mapPlatformSurfaceFailed = true);
                    } else {
                      _mapPlatformSurfaceFailed = true;
                    }
                    safeShowSnackBar(context, kMapUnavailableUserMessage);
                  }
                },
                onCameraIdle: () {
                  if (defaultTargetPlatform != TargetPlatform.iOS) {
                    return;
                  }
                  _iosMapCameraIdleObserved = true;
                  _logRiderMap(
                    'ios map camera settled city=$_selectedLaunchCity recovery=$_iosMapTileRecoveryCount',
                  );
                },
              );
            },
          ),
          if (showSosButton)
            Positioned(top: 60, left: 20, child: SafeArea(child: _sosButton())),
          Positioned(
            top: 60,
            left: showSosButton ? 92 : 20,
            right: 20,
            child: Column(
              children: [
                if (_identityComplianceLoaded &&
                    _selfieBlocksBooking &&
                    _riderFirestoreCompliance != null) ...[
                  RiderIdentityVerificationBanner(
                    message: riderMapIdentityBannerPrimaryLine(
                      _riderFirestoreCompliance!,
                    ),
                    actionLabel:
                        _riderFirestoreCompliance!.identityPhase ==
                            RiderIdentityBookingPhase.rejected
                        ? 'Retake'
                        : 'Verify',
                    onOpenVerification: () async {
                      const Widget screen = RiderSelfieVerificationScreen();
                      await Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(builder: (_) => screen),
                      );
                      if (mounted) {
                        await _refreshIdentityCompliance();
                      }
                    },
                  ),
                  const SizedBox(height: 10),
                ],
                if (!_hasActiveRide &&
                    (_rolloutCatalogLoading ||
                        _rolloutCatalogError != null ||
                        (_rolloutCatalogHydrated &&
                            _rolloutCatalog.isNotEmpty &&
                            !_rolloutSelectionComplete))) ...[
                  Material(
                    color: const Color(0xFFFFF2E0),
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: _rolloutCatalogLoading
                                ? null
                                : () {
                                    unawaited(_openRiderRolloutAreaSheet());
                                  },
                            child: Row(
                              children: <Widget>[
                                Icon(
                                  _rolloutCatalogLoading
                                      ? Icons.hourglass_top
                                      : Icons.location_on_outlined,
                                  color: const Color(0xFFB57A2A),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(
                                        _rolloutCatalogLoading
                                            ? 'Loading service areas…'
                                            : _rolloutCatalogError != null
                                            ? 'Could not load areas'
                                            : 'Service area required',
                                        style: const TextStyle(
                                          color: Color(0xFF4A3B2A),
                                          fontWeight: FontWeight.w700,
                                          fontSize: 13,
                                        ),
                                      ),
                                      if (!_rolloutCatalogLoading &&
                                          _rolloutCatalogError == null) ...<Widget>[
                                        const SizedBox(height: 4),
                                        Text(
                                          'Pick your state and city so NexRide can match drivers and pricing.',
                                          style: TextStyle(
                                            color: Colors.brown.shade800,
                                            fontSize: 12,
                                            height: 1.25,
                                          ),
                                        ),
                                      ],
                                      if (_rolloutCatalogError != null) ...<Widget>[
                                        const SizedBox(height: 4),
                                        Text(
                                          'Tap this banner to retry.',
                                          style: TextStyle(
                                            color: Colors.brown.shade800,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                if (!_rolloutCatalogLoading)
                                  const Icon(
                                    Icons.chevron_right,
                                    color: Color(0xFFB57A2A),
                                  ),
                              ],
                            ),
                          ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: _rolloutCatalogLoading
                                  ? null
                                  : () {
                                      unawaited(_openRiderRolloutAreaSheet());
                                    },
                              child: const Text('Choose service area'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                _pickupSearch(),
                const SizedBox(height: 10),
                _destinationSearch(),
                for (var i = 0; i < _extraStopFieldCount; i++) ...[
                  const SizedBox(height: 10),
                  _additionalStopSearch(i),
                ],
                if (!_hasActiveRide &&
                    _extraStopFieldCount <
                        _additionalStopControllers.length) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: _addStopField,
                      icon: const Icon(Icons.add_location_alt_outlined),
                      label: const Text('Add stop'),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (showReturnToTripBanner)
            Positioned(
              top: 156,
              left: 20,
              right: 20,
              child: SafeArea(
                child: Material(
                  color: const Color(0xFFDFF3E8),
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () {
                      unawaited(_restoreActiveRideIfAny());
                    },
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      child: Row(
                        children: [
                          Icon(Icons.directions_car_filled, color: Color(0xFF0F6B47)),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'You have an active trip — tap to return',
                              style: TextStyle(
                                color: Color(0xFF0D4F35),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Icon(Icons.chevron_right, color: Color(0xFF0F6B47)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (_hostedCheckoutProcessing ||
              _isCreatingRide ||
              _isSubmittingRideRequest)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.45),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(color: _gold),
                        const SizedBox(height: 18),
                        Text(
                          _hostedCheckoutProcessing
                              ? 'Processing payment…'
                              : 'Finding your driver…',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _hostedCheckoutProcessing
                              ? 'Stay on NexRide until we confirm your payment.'
                              : 'Hang tight while we match you with a driver.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.88),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (_hasActiveRide)
            _buildActiveRideDraggablePanel()
          else
            Positioned(bottom: 0, left: 0, right: 0, child: _bottomPanel()),
        ],
      ),
    );
  }
}
