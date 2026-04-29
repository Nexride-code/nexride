import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/driver_app_config.dart';
import '../config/rtdb_ride_request_contract.dart';
import '../services/call_permissions.dart';
import '../services/call_service.dart';
import '../services/dispatch_photo_upload_service.dart';
import '../services/driver_alert_sound_service.dart';
import '../services/road_route_service.dart';
import '../services/driver_trip_safety_service.dart';
import '../services/rider_accountability_service.dart';
import '../services/user_support_ticket_service.dart';
import '../support/app_role.dart';
import '../support/driver_location_access_support.dart';
import '../support/driver_dispatch_support.dart';
import '../support/driver_profile_bootstrap_support.dart';
import '../support/driver_profile_support.dart';
import '../support/realtime_database_error_support.dart';
import '../support/rtdb_flow_debug_log.dart';
import '../support/ride_chat_support.dart';
import '../trip_sync/trip_state_machine.dart';
import '../widgets/driver_dashboard_panel.dart';
import '../widgets/driver_ride_chat_sheet.dart';
import 'driver_business_model_screen.dart';
import 'driver_support_center_screen.dart';
import 'driver_verification_screen.dart';
import 'driver_login_screen.dart';
import 'earnings_screen.dart';
import 'trip_history_screen.dart';
import 'wallet_screen.dart';

class _NigeriaTestDriverLocation {
  const _NigeriaTestDriverLocation({
    required this.latitude,
    required this.longitude,
    required this.city,
  });

  final double latitude;
  final double longitude;
  final String city;
}

const _NigeriaTestDriverLocation _kLagosTestDriverLocation =
    _NigeriaTestDriverLocation(
  latitude: 6.5244,
  longitude: 3.3792,
  city: 'lagos',
);

const _NigeriaTestDriverLocation _kAbujaTestDriverLocation =
    _NigeriaTestDriverLocation(
  latitude: 9.0765,
  longitude: 7.3986,
  city: 'abuja',
);

const Duration _kRouteRefreshInterval = Duration(seconds: 12);
const Duration _kActiveRouteDebounceDuration = Duration(milliseconds: 400);
const Duration _kPopupRouteDebounceDuration = Duration(milliseconds: 150);
const int _kRidePopupCountdownSeconds = 30;
// Temporary debug switch: keep market matching strict, but bypass distance
// radius suppression so all active rides in the same market are visible.
const bool _kDebugAllowAllActiveMarketRides = true;
const String _kPendingDriverAcceptanceStatus = 'pending_driver_acceptance';
const double _kRouteRefreshDistanceMeters = 35;
const double _kArrivedDistanceThresholdMeters = 100;
const double _kWaypointReachedThresholdMeters = 80;
const double _kSafetyRouteDeviationThresholdMeters = 200;
const double _kSafetyStopMovementThresholdMeters = 18;
const double _kSafetyExpectedStopRadiusMeters = 90;
const Duration _kSafetyLongStopDuration = Duration(minutes: 2);
const Duration _kSafetyPromptCooldown = Duration(minutes: 3);
const double _kSuddenStopMinPriorKmh = 32;
const double _kSuddenStopMaxAfterKmh = 14;
const double _kSuddenStopDropKmh = 22;
const double _kSuddenStopMinDtSec = 0.35;
const double _kSuddenStopMaxDtSec = 8;
const Duration _kDriverMapInitializationTimeout = Duration(seconds: 12);
const Duration _kRideChatSendTimeout = Duration(seconds: 8);
const Set<String> _kRenderableRideStatuses = <String>{
  'accepted',
  'arriving',
  'arrived',
  'on_trip',
};
const List<String> _kDriverRiderReportReasons = <String>[
  'non-payment',
  'abuse',
  'safety concern',
  'fake destination issue',
  'off-route coercion',
  'other',
];
const List<String> _kDriverSettlementMethods = <String>[
  'cash',
  'card',
  'bank_transfer',
  'unspecified',
];
const List<String> _kDriverEvidenceTypes = <String>[
  'chat log',
  'call log',
  'dropoff confirmation',
  'cash handover note',
  'other',
];

enum _DriverHubAction {
  tripHistory,
  earnings,
  businessModel,
  verification,
  wallet,
  support,
}

enum _PostTripReviewAction {
  reportNonPayment,
  reportIssue,
}

enum _RouteRequestKind {
  active,
  popupPreview,
}

class _PendingRouteRequest {
  const _PendingRouteRequest.active({
    required this.reason,
    this.force = false,
  })  : kind = _RouteRequestKind.active,
        rideId = null,
        origin = null,
        destination = null;

  const _PendingRouteRequest.popupPreview({
    required this.rideId,
    required this.origin,
    required this.destination,
    required this.reason,
  })  : kind = _RouteRequestKind.popupPreview,
        force = true;

  final _RouteRequestKind kind;
  final bool force;
  final String reason;
  final String? rideId;
  final LatLng? origin;
  final LatLng? destination;
}

class DriverMapScreen extends StatefulWidget {
  const DriverMapScreen({
    super.key,
    required this.driverId,
    required this.driverName,
    required this.car,
    required this.plate,
    this.profileSyncIssueMessage,
    this.onRetryProfileSync,
  });

  final String driverId;
  final String driverName;
  final String car;
  final String plate;
  final String? profileSyncIssueMessage;
  final Future<void> Function()? onRetryProfileSync;

  @override
  State<DriverMapScreen> createState() => _DriverMapScreenState();
}

enum _RidePopupAction { accepted, declined, blocked }

enum _DispatchPhotoSource { camera, gallery }

class _MatchedRideRequest {
  const _MatchedRideRequest({
    required this.rideId,
    required this.rideData,
    required this.pickup,
    required this.destination,
    required this.serviceType,
    required this.city,
    required this.area,
    required this.status,
    required this.driverId,
    required this.createdAt,
    required this.distanceMeters,
    required this.sameArea,
  });

  final String rideId;
  final Map<String, dynamic> rideData;
  final LatLng pickup;
  final LatLng destination;
  final String serviceType;
  final String city;
  final String area;
  final String status;
  final String driverId;
  final int createdAt;
  final double distanceMeters;
  final bool sameArea;
}

class _TripWaypoint {
  const _TripWaypoint({
    required this.location,
    required this.address,
  });

  final LatLng location;
  final String address;
}

class _RecoveredDriverRide {
  const _RecoveredDriverRide({
    required this.rideId,
    required this.rideData,
    required this.canonicalState,
  });

  final String rideId;
  final Map<String, dynamic> rideData;
  final String canonicalState;
}

class _DriverMapScreenState extends State<DriverMapScreen>
    with WidgetsBindingObserver {
  final rtdb.DatabaseReference _rideRequestsRef =
      rtdb.FirebaseDatabase.instance.ref('ride_requests');
  final rtdb.DatabaseReference _driversRef =
      rtdb.FirebaseDatabase.instance.ref('drivers');
  final CallService _callService = CallService();
  final CallPermissions _callPermissions = const CallPermissions();
  final ImagePicker _dispatchPhotoPicker = ImagePicker();
  final DispatchPhotoUploadService _dispatchPhotoUploadService =
      const DispatchPhotoUploadService();
  final DriverAlertSoundService _alertSoundService = DriverAlertSoundService();
  final RiderAccountabilityService _riderAccountabilityService =
      const RiderAccountabilityService();
  final UserSupportTicketService _userSupportTicketService =
      const UserSupportTicketService();
  final DriverTripSafetyService _driverTripSafetyService =
      DriverTripSafetyService();
  final RoadRouteService _roadRouteService = RoadRouteService();
  final Set<String> _presentedRideIds = <String>{};
  final Set<String> _timedOutRideIds = <String>{};
  final Set<String> _declinedRideIds = <String>{};
  final Set<String> _handledRideIds = <String>{};
  /// Ride IDs that must never re-open the market discovery popup (accept/decline).
  final Set<String> _suppressedRidePopupIds = <String>{};
  /// Accepted (or otherwise completed-on-this-device) ride IDs — never unsuppress, never popup again this session.
  final Set<String> _foreverSuppressedRidePopupIds = <String>{};
  /// Terminal self-accept lock: after a successful accept transaction, discovery and
  /// unavailable UI must not fight the active-trip flow for this [rideId] until trip end.
  final Set<String> _terminalSelfAcceptedRideIds = <String>{};
  /// Prevents concurrent [showRideRequestPopup] opens from parallel RTDB snapshots.
  bool _ridePopupOpenPipelineLocked = false;
  int _lastActiveHeartbeatLogCount = 0;
  bool _isDriverCancellingRide = false;
  final Set<String> _loggedDriverChatMessageIds = <String>{};
  final Set<Marker> _markers = <Marker>{};
  final Set<Polyline> _polyLines = <Polyline>{};
  final List<_TripWaypoint> _tripWaypoints = <_TripWaypoint>[];
  final List<LatLng> _expectedRoutePoints = <LatLng>[];
  final ValueNotifier<List<RideChatMessage>> _driverChatMessages =
      ValueNotifier<List<RideChatMessage>>(<RideChatMessage>[]);
  final ValueNotifier<int> _mapLayerVersion = ValueNotifier<int>(0);

  GoogleMapController? _mapController;
  StreamSubscription<Position>? _positionStream;
  StreamSubscription<rtdb.DatabaseEvent>? _rideRequestSubscription;
  /// City key for the active [ride_requests] market query (null if no listener).
  String? _rideRequestsListenerBoundCity;
  int _rideRequestListenerToken = 0;
  /// Serializes discovery attach/cancel so two callers cannot overlap native query setup.
  Future<void> _rideDiscoveryAttachChain = Future<void>.value();
  StreamSubscription<rtdb.DatabaseEvent>? _driverActiveRideSubscription;
  StreamSubscription<rtdb.DatabaseEvent>? _activeRideSubscription;
  final List<StreamSubscription<rtdb.DatabaseEvent>> _driverChatSubscriptions =
      <StreamSubscription<rtdb.DatabaseEvent>>[];
  final Map<String, RideChatMessage> _driverChatMessagesById =
      <String, RideChatMessage>{};
  bool _driverChatSendInFlight = false;
  final Map<String, String> _driverChatDraftByRide = <String, String>{};
  StreamSubscription<rtdb.DatabaseEvent>? _callSubscription;
  StreamSubscription<rtdb.DatabaseEvent>? _incomingCallSubscription;
  Timer? _ridePopupTimer;
  Timer? _routeRequestDebounceTimer;
  Timer? _callDurationTimer;
  Timer? _callRingTimeoutTimer;
  Timer? _mapInitializationTimer;
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

  LatLng _driverLocation = const LatLng(
    DriverServiceAreaConfig.defaultMapLatitude,
    DriverServiceAreaConfig.defaultMapLongitude,
  );
  LatLng? _pickupLocation;
  LatLng? _destinationLocation;
  LatLng? _nextNavigationTarget;
  String? _driverCity;
  String _driverArea = '';
  String _selectedLaunchCity = DriverLaunchScope.defaultBrowseCity;
  String? _currentRideId;
  String? _sessionTrackedRideId;
  Map<String, dynamic>? _currentRideData;
  String? _loadedRiderProfileKey;
  String? _lastTripPanelHiddenReason;
  String? _lastValidationBlockedKey;
  String? _lastDriverChatErrorNoticeKey;
  String? _pendingStaleRidePurgeKey;
  String? _driverActiveRideId;
  String? _activeRideListenerRideId;
  String? _driverChatListenerRideId;
  String? _currentCandidateRideId;
  String _pickupAddressText = '';
  String _destinationAddressText = '';
  String _riderName = 'Rider';
  String _riderPhone = '';
  String _riderVerificationStatus = 'unverified';
  String _riderRiskStatus = 'clear';
  String _riderPaymentStatus = 'clear';
  String _riderCashAccessStatus = 'enabled';
  int _onlineSessionStartedAt = 0;
  int _driverUnreadChatCount = 0;
  /// Missed incoming voice call (this driver was receiver) — cleared when chat/call is opened.
  bool _driverMissedCallNotice = false;
  DateTime? _lastDriverChatNoticeAt;
  int _routeDeviationStrikeCount = 0;
  int _riderRatingCount = 0;
  int _riderOutstandingCancellationFeesNgn = 0;
  int _riderNonPaymentReports = 0;
  bool _isOnline = false;
  bool _lastAvailabilityIntentOnline = false;
  bool _availabilityActionInProgress = false;
  /// Last successfully loaded driver profile from RTDB (used for fast GO ONLINE).
  Map<String, dynamic>? _lastDriverProfileSnapshot;
  bool _isDriverChatOpen = false;
  bool _hasHydratedDriverChatMessages = false;
  bool _hasActivePopup = false;
  bool _tripStarted = false;
  bool _popupOpen = false;

  /// FIFO of incoming open-pool offers when a popup is already visible (Grab-style backlog).
  final List<_MatchedRideRequest> _rideRequestPopupQueue = <_MatchedRideRequest>[];
  static const int _kMaxRideRequestPopupQueue = 8;
  bool _routeBuildInFlight = false;
  bool _arrivedEnabled = false;
  bool _hasLoggedArrivedEnabled = false;
  bool _safetyMonitoringActive = false;
  bool _riderTrustLoading = false;
  bool _riderVerifiedBadge = false;
  bool _profileSyncRetryInProgress = false;
  bool _profileSyncMaterialBannerShown = false;
  bool _mapBootstrapReady = false;
  bool _mapLocationReady = false;
  bool _deviceLocationOutsideLaunchArea = false;
  bool _launchCityChosenManually = false;
  bool _mapViewReady = false;
  bool _mapInitializationInProgress = true;
  bool _deliveryProofUploading = false;
  bool _routeRequestInFlight = false;
  bool _isDisposing = false;
  bool _rideDiscoveryListenerHealthy = false;
  bool _discoveryPermissionDeniedNoticeVisible = false;
  String? _activePopupRideId;
  String? _acceptingPopupRideId;
  String? _popupDismissedRideId;
  String? _popupDismissedReason;
  String? _mapInitializationError;
  String? _routeOverlayError;
  String _rideStatus = 'offline';
  String _lastRouteBuildKey = '';
  String _lastRouteConsistencyCheckKey = '';
  bool _startupPermissionNoticeShown = false;
  int _mapInitializationAttempt = 0;
  int _mapRenderRefreshGeneration = 0;
  bool _mapCameraIdleObserved = false;
  int _mapTileRecoveryCount = 0;
  int _mapWidgetKeyVersion = 0;
  double _deliveryProofUploadProgress = 0;
  DateTime? _lastRouteBuiltAt;
  DateTime? _lastMoveTime;
  DateTime? _lastSafetyPromptAt;
  DateTime? _lastTelemetryCheckpointAt;
  LatLng? _lastRouteOrigin;
  LatLng? _lastSafetyCheckLocation;
  DateTime? _lastDriverSpeedSampleAt;
  double? _lastDriverImpliedSpeedKmh;
  LatLng? _lastTelemetryCheckpointPosition;
  String? _activeSafetyPromptMessage;
  String _debugStartupStep = 'starting driver map';
  double _riderRating = 5.0;
  int _routeRequestGeneration = 0;
  _PendingRouteRequest? _pendingRouteRequest;
  Timer? _rideDiscoveryReattachTimer;

  Color get _gold => const Color(0xFFD4AF37);
  LatLng get _nigeriaMarketCenter => const LatLng(
        DriverServiceAreaConfig.defaultMapLatitude,
        DriverServiceAreaConfig.defaultMapLongitude,
      );
  LatLng get _selectedLaunchCityCenter => LatLng(
        DriverLaunchScope.latitudeForCity(_selectedLaunchCity),
        DriverLaunchScope.longitudeForCity(_selectedLaunchCity),
      );
  LatLng get _driverFallbackLocation => _configuredTestDriverCity != null
      ? _selectedLaunchCityCenter
      : _nigeriaMarketCenter;
  String get _currentRiderIdForRide =>
      _valueAsText(_currentRideData?['rider_id']);
  String? get _activeDriverRideContextId {
    final rideId = _valueAsText(
      _currentRideId ??
          _driverActiveRideId ??
          _driverChatListenerRideId ??
          _callListenerRideId,
    );
    return rideId.isEmpty ? null : rideId;
  }

  bool _isDriverChatSessionActive(String rideId) {
    final normalizedRideId = rideId.trim();
    if (normalizedRideId.isEmpty) {
      return false;
    }

    return normalizedRideId == _currentRideId ||
        normalizedRideId == _driverActiveRideId ||
        normalizedRideId == _driverChatListenerRideId ||
        normalizedRideId == _callListenerRideId;
  }

  String _driverChatPreview(String text, {int maxLength = 96}) {
    final trimmed = text.trim();
    if (trimmed.length <= maxLength) {
      return trimmed;
    }

    return '${trimmed.substring(0, maxLength - 1)}...';
  }

  bool get _canStartRideCall =>
      _canOpenChat && _currentRiderIdForRide.isNotEmpty;
  bool get _showRideCallButton => _canStartRideCall;
  bool get _isRideCallButtonEnabled =>
      _showRideCallButton &&
      !_isStartingVoiceCall &&
      (_currentCallSession == null || _currentCallSession!.isTerminal);
  bool get _isMapInitializationComplete => _mapBootstrapReady && _mapViewReady;
  String get _lastAvailabilityIntentValue =>
      _lastAvailabilityIntentOnline ? 'online' : 'offline';
  String get _availabilityStatusLabel => _isOnline ? 'ONLINE' : 'OFFLINE';
  String get _availabilityStatusMessage {
    if (_isOnline) {
      return 'Ride requests are live. You can receive trips now.';
    }
    if (_lastAvailabilityIntentOnline) {
      return 'Last intended state: ONLINE. Tap GO ONLINE to publish availability again.';
    }
    return 'You stay offline until you explicitly tap GO ONLINE.';
  }

  bool _lastAvailabilityIntentFromRecord(
    Map<String, dynamic> driverRecord, {
    required bool remoteOnline,
    bool hasTrackedRide = false,
  }) {
    final rawIntent =
        _valueAsText(driverRecord['last_availability_intent']).toLowerCase();
    if (rawIntent == 'online') {
      return true;
    }
    if (rawIntent == 'offline') {
      return false;
    }
    return remoteOnline || hasTrackedRide;
  }

  void _setDebugStartupStep(String step) {
    if (_debugStartupStep == step) {
      return;
    }
    _debugStartupStep = step;
    _log('startup step=$step');
  }

  bool _hasRenderableActiveRideData(Map<String, dynamic>? ride) {
    final canonicalState = TripStateMachine.canonicalStateFromSnapshot(ride);
    if (TripStateMachine.isPendingDriverAssignmentState(canonicalState) &&
        _valueAsText(ride?['driver_id']) == _effectiveDriverId) {
      return false;
    }

    final currentRideId = _currentRideId;
    final hiddenReason = _activeRideRenderGuardReason(
      ride,
      rideId: currentRideId,
    );
    if (hiddenReason != null) {
      if (currentRideId != null && currentRideId.isNotEmpty) {
        _logRenderBlocked(rideId: currentRideId, reason: hiddenReason);
      }
      _logTripPanelHidden('no_valid_active_ride');
      _scheduleStaleRidePurge(
        rideId: currentRideId,
        reason: hiddenReason,
      );
      return false;
    }

    _lastTripPanelHiddenReason = null;
    return true;
  }

  bool get _hasAuthenticatedDriver => FirebaseAuth.instance.currentUser != null;

  bool get _hasRenderableActiveRide =>
      _hasRenderableActiveRideData(_currentRideData);

  bool get _canOpenChat =>
      _hasRenderableActiveRide && _isActiveRideStatus(_rideStatus);

  String get _effectiveDriverId {
    final authId = FirebaseAuth.instance.currentUser?.uid.trim();
    final widgetId = widget.driverId.trim();

    if (authId != null && authId.isNotEmpty) {
      if (widgetId.isNotEmpty && widgetId != authId) {
        _log('driver id mismatch widget=$widgetId auth=$authId, using auth id');
      }
      return authId;
    }

    return widgetId;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _driverLocation = _selectedLaunchCityCenter;
    print('DRIVER_MAP_INIT');
    _log(
      'screen init auth=${FirebaseAuth.instance.currentUser?.uid ?? 'none'} widgetDriverId=${widget.driverId} platform=${defaultTargetPlatform.name}',
    );

    if (!_hasAuthenticatedDriver) {
      _log('screen init blocked: missing auth user');
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _startMapInitializationSequence();
      unawaited(_refreshDriverLocationCapability(reason: 'init_post_frame'));
      unawaited(_initializeDriverStartup());
    });
    _scheduleProfileSyncMaterialBanner();
  }

  @override
  void didUpdateWidget(DriverMapScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldMsg = oldWidget.profileSyncIssueMessage?.trim() ?? '';
    final newMsg = widget.profileSyncIssueMessage?.trim() ?? '';
    if (oldMsg.isNotEmpty && newMsg.isEmpty && mounted) {
      ScaffoldMessenger.maybeOf(context)?.hideCurrentMaterialBanner();
      _profileSyncMaterialBannerShown = false;
      return;
    }
    if (newMsg.isNotEmpty && oldMsg != newMsg) {
      _profileSyncMaterialBannerShown = false;
      _scheduleProfileSyncMaterialBanner();
    }
  }

  void _scheduleProfileSyncMaterialBanner() {
    final message = widget.profileSyncIssueMessage?.trim() ?? '';
    if (message.isEmpty || _profileSyncMaterialBannerShown) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final text = widget.profileSyncIssueMessage?.trim() ?? '';
      if (text.isEmpty || _profileSyncMaterialBannerShown) {
        return;
      }
      _profileSyncMaterialBannerShown = true;
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentMaterialBanner();
      messenger.showMaterialBanner(
        MaterialBanner(
          backgroundColor: Colors.white,
          elevation: 1,
          padding: const EdgeInsetsDirectional.only(
            start: 12,
            end: 4,
            top: 10,
            bottom: 10,
          ),
          leading: Icon(Icons.sync_problem_rounded, color: _gold),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text(
                'Driver profile needs attention',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                text,
                style: TextStyle(
                  color: Colors.black.withValues(alpha: 0.72),
                  height: 1.35,
                  fontSize: 13,
                ),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: _profileSyncRetryInProgress
                  ? null
                  : () {
                      messenger.hideCurrentMaterialBanner();
                      _profileSyncMaterialBannerShown = false;
                      unawaited(_retryProfileSyncFromMap());
                    },
              child: Text(
                _profileSyncRetryInProgress ? 'Retrying…' : 'Retry',
              ),
            ),
            TextButton(
              onPressed: () {
                messenger.hideCurrentMaterialBanner();
                unawaited(_signOutFromProfileIssue());
              },
              child: const Text('Sign out'),
            ),
            TextButton(
              onPressed: () {
                messenger.hideCurrentMaterialBanner();
              },
              child: const Text('Dismiss'),
            ),
          ],
        ),
      );
    });
  }

  Future<void> _initializeDriverStartup() async {
    try {
      await _restoreDriverSessionFromBackend();
      if (!_hasAuthenticatedDriver) {
        return;
      }
      await _loadOptionalDriverBootstrapContext();
    } catch (error, stackTrace) {
      if (isRealtimeDatabasePermissionDenied(error)) {
        _surfaceStartupPermissionDenied(
          path: 'driver_startup',
          error: error,
          stackTrace: stackTrace,
        );
      } else {
        _log('driver startup failed error=$error');
        debugPrintStack(
          label: '[DriverMap] startup initialization stack',
          stackTrace: stackTrace,
        );
        _showSnackBarSafely(
          const SnackBar(
            content: Text(
              'We could not restore your last driver session. Opening with a safe default state.',
            ),
          ),
        );
      }

      _applySafeStartupFallbackState(reason: 'startup_initialize_failed');
    }
  }

  Future<void> _restoreDriverSessionFromBackend() async {
    final driverId = _effectiveDriverId;
    if (driverId.isEmpty) {
      return;
    }

    _log('startup session restore requested driverId=$driverId');

    await _releaseLocalPendingAssignmentIfNeeded(
      reason: 'startup_restore_reset',
    );
    await _positionStream?.cancel();
    _positionStream = null;
    await _cancelRideRequestListener(reason: 'startup_restore_reset');
    await _driverActiveRideSubscription?.cancel();
    _driverActiveRideSubscription = null;
    await _stopIncomingCallMonitoring();
    _stopActiveRideListener();
    _stopDriverChatListener();
    _clearRidePopupTimer();

    _isOnline = false;
    _onlineSessionStartedAt = 0;
    _deliveryProofUploading = false;
    _deliveryProofUploadProgress = 0;
    _resetAllRideState();

    final snapshots = await Future.wait(<Future<rtdb.DataSnapshot?>>[
      _readStartupSnapshot(
        query: _driversRef.child(driverId),
        path: 'drivers/$driverId',
      ),
    ]);
    final driverRecord =
        _asStringDynamicMap(snapshots[0]?.value) ?? <String, dynamic>{};
    final activeRideMarker = null;
    final remoteOnline =
        _asBool(driverRecord['isOnline']) || _asBool(driverRecord['online']);
    final restoredCity = _normalizeCity(
      _valueAsText(driverRecord['market']).isNotEmpty
          ? driverRecord['market']
          : driverRecord['city'],
    );
    if (restoredCity != null) {
      _driverCity = restoredCity;
    }

    final recoveredRide = await _recoverDriverRideFromBackend(
      driverId: driverId,
      driverRecord: driverRecord,
      activeRideMarker: activeRideMarker,
    );
    final recoveredPendingRideId = await _recoverPendingRideFromBackend(
      driverId: driverId,
      driverRecord: driverRecord,
      activeRideMarker: activeRideMarker,
    );
    final lastIntentOnline = _lastAvailabilityIntentFromRecord(
      driverRecord,
      remoteOnline: remoteOnline,
      hasTrackedRide: recoveredRide != null || recoveredPendingRideId != null,
    );
    _lastAvailabilityIntentOnline = lastIntentOnline;

    if (recoveredRide != null) {
      final restoredStatus = TripStateMachine.legacyStatusForCanonical(
          recoveredRide.canonicalState);
      final restoredOnlineSessionStartedAt =
          _parseCreatedAt(driverRecord['online_session_started_at']);
      _onlineSessionStartedAt = restoredOnlineSessionStartedAt > 0
          ? restoredOnlineSessionStartedAt
          : DateTime.now().millisecondsSinceEpoch;
      _driverActiveRideId = recoveredRide.rideId;
      _currentRideId = recoveredRide.rideId;
      _currentRideData = Map<String, dynamic>.from(recoveredRide.rideData);
      _isOnline = false;
      _rideStatus = restoredStatus;
      _tripStarted = restoredStatus == 'on_trip';

      if (mounted) {
        setState(() {
          _currentRideId = recoveredRide.rideId;
          _currentRideData = Map<String, dynamic>.from(recoveredRide.rideData);
          _isOnline = false;
          _lastAvailabilityIntentOnline = lastIntentOnline;
          _rideStatus = restoredStatus;
          _tripStarted = restoredStatus == 'on_trip';
        });
      }

      await _updateDriverRecordSafely(
        driverId: driverId,
        source: 'startup_restore_active_ride',
        updates: <String, Object?>{
          'isOnline': false,
          'isAvailable': false,
          'available': false,
          'status': restoredStatus,
          'activeRideId': recoveredRide.rideId,
          'currentRideId': recoveredRide.rideId,
          'last_availability_intent': _lastAvailabilityIntentValue,
          'market': _driverCity,
          'city': _driverCity,
          'updated_at': rtdb.ServerValue.timestamp,
        },
      );
      await _setDriverActiveRideMarkerSafely(
        driverId: driverId,
        reason: 'startup_restore_active',
        data: <String, Object?>{
          'ride_id': recoveredRide.rideId,
          'status': restoredStatus,
          'trip_state': recoveredRide.canonicalState,
          'updated_at': rtdb.ServerValue.timestamp,
        },
      );

      unawaited(_resyncIncomingCallState());
      await _listenToActiveRide(recoveredRide.rideId);
      _startLiveLocationStream();
      _log(
        'startup session restored active ride in offline-safe mode driverId=$driverId rideId=${recoveredRide.rideId} status=$restoredStatus',
      );
      return;
    }

    await _releasePendingDriverAssignmentsFromBackend(
      driverId: driverId,
      reason: 'startup_pending_assignment_reset',
    );
    if (recoveredPendingRideId != null) {
      await _releaseAssignedRideIfNeeded(
        rideId: recoveredPendingRideId,
        reason: 'startup_restore_pending_release',
        resetLocalState: false,
      );
      _log(
        'startup session released pending assignment in offline-safe mode driverId=$driverId rideId=$recoveredPendingRideId',
      );
    }

    await _clearDriverActiveRideNode(
      reason: remoteOnline
          ? 'startup_restore_force_offline'
          : 'startup_restore_offline',
    );
    _isOnline = false;
    _rideStatus = 'offline';
    if (mounted) {
      setState(() {
        _isOnline = false;
        _lastAvailabilityIntentOnline = lastIntentOnline;
        _rideStatus = 'offline';
      });
    }
    await _updateDriverRecordSafely(
      driverId: driverId,
      source: remoteOnline
          ? 'startup_restore_force_offline'
          : 'startup_restore_offline',
      updates: <String, Object?>{
        'isOnline': false,
        'isAvailable': false,
        'available': false,
        'status': 'offline',
        'activeRideId': null,
        'currentRideId': null,
        'online_session_started_at': null,
        'last_availability_intent': _lastAvailabilityIntentValue,
        'updated_at': rtdb.ServerValue.timestamp,
      },
    );
    _updateDriverMarker();
    _log(
      'startup session restored offline-safe state driverId=$driverId remoteOnline=$remoteOnline lastIntent=$_lastAvailabilityIntentValue',
    );
  }

  Future<void> _releaseLocalPendingAssignmentIfNeeded({
    required String reason,
  }) async {
    final pendingRideIds = <String>{
      if (_activePopupRideId?.trim().isNotEmpty == true) _activePopupRideId!,
      if (_currentCandidateRideId?.trim().isNotEmpty == true)
        _currentCandidateRideId!,
      if (_currentRideId?.trim().isNotEmpty == true &&
          TripStateMachine.isPendingDriverAssignmentState(
            TripStateMachine.canonicalStateFromSnapshot(_currentRideData),
          ))
        _currentRideId!,
    };

    for (final rideId in pendingRideIds) {
      await _releaseAssignedRideIfNeeded(
        rideId: rideId,
        reason: reason,
        resetLocalState: false,
      );
    }
  }

  Future<void> _releasePendingDriverAssignmentsFromBackend({
    required String driverId,
    required String reason,
  }) async {
    final snapshot = await _readStartupSnapshot(
      query: _rideRequestsRef.orderByChild('driver_id').equalTo(driverId),
      path: 'ride_requests[orderByChild=driver_id,equalTo=$driverId]',
    );
    final rawAssignments = snapshot?.value;
    if (rawAssignments is! Map) {
      return;
    }

    for (final entry in rawAssignments.entries) {
      final rideId = entry.key?.toString().trim() ?? '';
      final rideData = _asStringDynamicMap(entry.value);
      if (!_isValidRideId(rideId) || rideData == null) {
        continue;
      }

      final canonicalState = TripStateMachine.canonicalStateFromSnapshot(
        rideData,
      );
      if (!TripStateMachine.isPendingDriverAssignmentState(canonicalState)) {
        continue;
      }

      if (!_assignmentHasExpired(rideData)) {
        continue;
      }

      await _releaseAssignedRideIfNeeded(
        rideId: rideId,
        reason: 'startup_pending_assignment_expired',
        resetLocalState: false,
      );
    }
  }

  Future<_RecoveredDriverRide?> _recoverDriverRideFromBackend({
    required String driverId,
    required Map<String, dynamic> driverRecord,
    required Map<String, dynamic>? activeRideMarker,
  }) async {
    _RecoveredDriverRide? bestMatch;
    var bestTimestamp = 0;

    Future<void> considerRideId(String rideId) async {
      if (!_isValidRideId(rideId)) {
        return;
      }

      final snapshot = await _readStartupSnapshot(
        query: _rideRequestsRef.child(rideId),
        path: 'ride_requests/$rideId',
      );
      final rideData = _asStringDynamicMap(snapshot?.value);
      if (rideData == null) {
        return;
      }

      if (_valueAsText(rideData['driver_id']) != driverId) {
        return;
      }

      final canonicalState = TripStateMachine.canonicalStateFromSnapshot(
        rideData,
      );
      if (!TripStateMachine.isDriverActiveState(canonicalState)) {
        return;
      }

      final lifecycleProofReason = TripStateMachine.lifecycleProofReason(
        rideData,
        canonicalState: canonicalState,
      );
      if (lifecycleProofReason != null) {
        return;
      }

      final timestamp = _activeRideSessionTimestamp(rideData);
      if (bestMatch == null || timestamp >= bestTimestamp) {
        bestMatch = _RecoveredDriverRide(
          rideId: rideId,
          rideData: rideData,
          canonicalState: canonicalState,
        );
        bestTimestamp = timestamp;
      }
    }

    final candidateRideIds = <String>{
      _valueAsText(activeRideMarker?['ride_id']),
      _valueAsText(driverRecord['activeRideId']),
      _valueAsText(driverRecord['currentRideId']),
    }..removeWhere((String value) => value.trim().isEmpty);

    for (final rideId in candidateRideIds) {
      await considerRideId(rideId);
    }

    if (bestMatch != null) {
      return bestMatch;
    }

    if (bestMatch == null && candidateRideIds.isEmpty) {
      _log(
        'startup session restore skipped ride_requests scan driverId=$driverId reason=no_explicit_active_ride_id',
      );
    }

    return bestMatch;
  }

  Future<String?> _recoverPendingRideFromBackend({
    required String driverId,
    required Map<String, dynamic> driverRecord,
    required Map<String, dynamic>? activeRideMarker,
  }) async {
    String? bestRideId;
    var bestTimestamp = 0;

    void considerPendingRide(String rideId, Map<String, dynamic>? rideData) {
      if (!_isValidRideId(rideId) || rideData == null) {
        return;
      }
      if (_valueAsText(rideData['driver_id']) != driverId) {
        return;
      }

      final canonicalState = TripStateMachine.canonicalStateFromSnapshot(
        rideData,
      );
      if (!TripStateMachine.isPendingDriverAssignmentState(canonicalState) ||
          _assignmentHasExpired(rideData)) {
        return;
      }

      final pendingTimestamp = _assignmentExpiryTimestamp(rideData);
      if (bestRideId == null || pendingTimestamp >= bestTimestamp) {
        bestRideId = rideId;
        bestTimestamp = pendingTimestamp;
      }
    }

    final candidateRideIds = <String>{
      _valueAsText(activeRideMarker?['ride_id']),
      _valueAsText(driverRecord['activeRideId']),
      _valueAsText(driverRecord['currentRideId']),
    }..removeWhere((String value) => value.trim().isEmpty);

    for (final rideId in candidateRideIds) {
      final snapshot = await _readStartupSnapshot(
        query: _rideRequestsRef.child(rideId),
        path: 'ride_requests/$rideId',
      );
      considerPendingRide(rideId, _asStringDynamicMap(snapshot?.value));
    }

    if (bestRideId != null) {
      return bestRideId;
    }

    final pendingAssignmentsSnapshot = await _readStartupSnapshot(
      query: _rideRequestsRef.orderByChild('driver_id').equalTo(driverId),
      path: 'ride_requests[orderByChild=driver_id,equalTo=$driverId]',
    );
    final rawAssignments = pendingAssignmentsSnapshot?.value;
    if (rawAssignments is Map) {
      for (final entry in rawAssignments.entries) {
        final rideId = entry.key?.toString().trim() ?? '';
        considerPendingRide(rideId, _asStringDynamicMap(entry.value));
      }
    }

    return bestRideId;
  }

  Future<void> _bootstrapMapState() async {
    await _loadCarIcon();
    await _prepareInitialLocation();
  }

  void _startMapInitializationSequence({bool forceRemount = false}) {
    final attempt = ++_mapInitializationAttempt;
    _mapRenderRefreshGeneration += 1;
    _mapInitializationTimer?.cancel();

    if (forceRemount) {
      _mapController?.dispose();
      _mapController = null;
    }

    if (mounted) {
      setState(() {
        _mapBootstrapReady = false;
        _mapViewReady = false;
        _mapInitializationInProgress = true;
        _mapInitializationError = null;
        if (forceRemount) {
          _mapWidgetKeyVersion += 1;
        }
      });
    } else {
      _mapBootstrapReady = false;
      _mapViewReady = false;
      _mapInitializationInProgress = true;
      _mapInitializationError = null;
      if (forceRemount) {
        _mapWidgetKeyVersion += 1;
      }
    }

    _log(
      'map initialization start attempt=$attempt platform=${defaultTargetPlatform.name} forceRemount=$forceRemount',
    );
    _setDebugStartupStep('waiting for map init');

    _mapInitializationTimer = Timer(_kDriverMapInitializationTimeout, () {
      if (!mounted ||
          attempt != _mapInitializationAttempt ||
          _isMapInitializationComplete) {
        return;
      }

      _log(
        'map initialization failure timeout attempt=$attempt bootstrapReady=$_mapBootstrapReady mapViewReady=$_mapViewReady',
      );
      _setDebugStartupStep('map init timeout');
      setState(() {
        _mapInitializationInProgress = false;
        _mapInitializationError = defaultTargetPlatform == TargetPlatform.iOS
            ? 'We could not verify the live driver map on this iPhone yet. Retry the map. If tiles stay blank, confirm the Google Maps iOS key allows bundle `com.nexride.driver`.'
            : 'We are still getting your driver map ready. Please retry in a moment.';
      });
    });

    unawaited(_runMapBootstrap(attempt));
  }

  Future<void> _runMapBootstrap(int attempt) async {
    try {
      await _bootstrapMapState();
      if (!mounted || attempt != _mapInitializationAttempt) {
        return;
      }

      setState(() {
        _mapBootstrapReady = true;
      });
      _log(
        'map bootstrap loaded attempt=$attempt city=${_driverCity ?? 'unknown'}',
      );
      _setDebugStartupStep('waiting for map view');
      _completeMapInitializationIfReady(attempt: attempt);
    } catch (error, stackTrace) {
      _log('map initialization failure attempt=$attempt error=$error');
      debugPrintStack(
        label: '[DriverMap] map initialization stack',
        stackTrace: stackTrace,
      );
      if (!mounted || attempt != _mapInitializationAttempt) {
        return;
      }

      _mapInitializationTimer?.cancel();
      _setDebugStartupStep('map init failed');
      setState(() {
        _mapInitializationInProgress = false;
        _mapInitializationError = defaultTargetPlatform == TargetPlatform.iOS
            ? 'We could not finish loading the live driver map on this iPhone. Retry the map and verify the iOS Google Maps bundle restriction for `com.nexride.driver` if it stays blank.'
            : 'We could not load the driver map right now. Please retry.';
      });
    }
  }

  void _completeMapInitializationIfReady({required int attempt}) {
    if (!mounted ||
        attempt != _mapInitializationAttempt ||
        !_isMapInitializationComplete) {
      return;
    }

    _mapInitializationTimer?.cancel();
    setState(() {
      _mapInitializationInProgress = false;
      _mapInitializationError = null;
    });
    _log(
      'map initialization success attempt=$attempt city=${_driverCity ?? 'unknown'}',
    );
    _setDebugStartupStep('map ready');
    _moveCameraToIdleState();
    _log('camera initialized attempt=$attempt target=${_driverLocation.latitude},${_driverLocation.longitude}');
  }

  void _retryMapInitialization() {
    _log('map initialization retry requested');
    _setDebugStartupStep('retrying map init');
    _startMapInitializationSequence(forceRemount: true);
  }

  void _notifyMapLayerChanged() {
    if (!mounted) {
      return;
    }

    _mapLayerVersion.value += 1;
  }

  void _refreshDriverMapPresentation({required String reason}) {
    _log(
      'refreshing map presentation reason=$reason activeRide=$_hasRenderableActiveRide markers=${_markers.length} polylines=${_polyLines.length}',
    );

    if (_hasRenderableActiveRide) {
      _moveCameraToActiveTrip();
      return;
    }

    _moveCameraToIdleState();
  }

  void _scheduleIosMapStabilization({
    required GoogleMapController controller,
    required int attempt,
  }) {
    final refreshGeneration = ++_mapRenderRefreshGeneration;

    Future<void>.delayed(const Duration(milliseconds: 250), () {
      if (!mounted ||
          _mapController != controller ||
          attempt != _mapInitializationAttempt ||
          refreshGeneration != _mapRenderRefreshGeneration) {
        return;
      }

      _log(
        'applying iOS map stabilization attempt=$attempt refresh=$refreshGeneration',
      );
      _notifyMapLayerChanged();
      _refreshDriverMapPresentation(reason: 'ios_post_create');
      unawaited(
        _nudgeIosMapTiles(
          controller,
          reason: 'ios_post_create',
        ),
      );
      unawaited(
        Future<void>.microtask(() {
          _scheduleActiveRouteRefresh(
            force: true,
            reason: 'ios_post_create',
            debounce: Duration.zero,
          );
        }),
      );
    });

    Future<void>.delayed(const Duration(milliseconds: 900), () {
      if (!mounted ||
          _mapController != controller ||
          attempt != _mapInitializationAttempt ||
          refreshGeneration != _mapRenderRefreshGeneration ||
          _mapViewReady) {
        return;
      }

      _log(
        'applying iOS follow-up map refresh attempt=$attempt refresh=$refreshGeneration',
      );
      _notifyMapLayerChanged();
      _refreshDriverMapPresentation(reason: 'ios_follow_up');
      unawaited(
        _nudgeIosMapTiles(
          controller,
          reason: 'ios_follow_up',
        ),
      );
      unawaited(
        Future<void>.microtask(() {
          _scheduleActiveRouteRefresh(
            force: true,
            reason: 'ios_follow_up',
            debounce: Duration.zero,
          );
        }),
      );
    });
  }

  Future<void> _nudgeIosMapTiles(
    GoogleMapController controller, {
    required String reason,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.iOS ||
        _mapController != controller) {
      return;
    }

    final target = _hasRenderableActiveRide
        ? _nextNavigationTarget ?? _pickupLocation ?? _driverLocation
        : (_mapLocationReady && !_deviceLocationOutsideLaunchArea)
            ? _driverLocation
            : _selectedLaunchCityCenter;
    final baseZoom = _hasRenderableActiveRide
        ? 15.5
        : DriverServiceAreaConfig.defaultMapZoom;

    try {
      await controller.animateCamera(
        CameraUpdate.newLatLngZoom(target, baseZoom + 0.2),
      );
      await controller.animateCamera(
        CameraUpdate.newLatLngZoom(target, baseZoom),
      );
      _log(
        'map tile nudge applied platform=ios reason=$reason target=${target.latitude},${target.longitude}',
      );
    } catch (error) {
      _log('map tile nudge skipped platform=ios reason=$reason error=$error');
    }
  }

  Future<void> _nudgeDriverMapTiles(
    GoogleMapController controller, {
    required String reason,
  }) async {
    if (_mapController != controller) {
      return;
    }

    final target = _hasRenderableActiveRide
        ? _nextNavigationTarget ?? _pickupLocation ?? _driverLocation
        : (_mapLocationReady && !_deviceLocationOutsideLaunchArea)
            ? _driverLocation
            : _selectedLaunchCityCenter;
    final baseZoom = _hasRenderableActiveRide
        ? 15.5
        : DriverServiceAreaConfig.defaultMapZoom;

    try {
      await controller.animateCamera(
        CameraUpdate.newLatLngZoom(target, baseZoom + 0.2),
      );
      await controller.animateCamera(
        CameraUpdate.newLatLngZoom(target, baseZoom),
      );
      _log(
        'map tile nudge applied platform=${defaultTargetPlatform.name} reason=$reason target=${target.latitude},${target.longitude}',
      );
    } catch (error) {
      _log(
        'map tile nudge skipped platform=${defaultTargetPlatform.name} reason=$reason error=$error',
      );
    }
  }

  void _scheduleMapTileRecovery({
    required GoogleMapController controller,
    required int attempt,
  }) {
    Future<void> runRecovery(int phaseMs, String phaseLabel) async {
      await Future<void>.delayed(Duration(milliseconds: phaseMs));
      if (!mounted ||
          _mapController != controller ||
          attempt != _mapInitializationAttempt) {
        return;
      }
      if (defaultTargetPlatform != TargetPlatform.iOS &&
          _mapCameraIdleObserved) {
        return;
      }
      _mapTileRecoveryCount += 1;
      _log(
        'map tile recovery started attempt=$attempt phase=$phaseLabel recovery=$_mapTileRecoveryCount platform=${defaultTargetPlatform.name}',
      );
      _notifyMapLayerChanged();
      _refreshDriverMapPresentation(reason: 'tile_recovery_$phaseLabel');
      await _nudgeDriverMapTiles(controller, reason: 'tile_recovery_$phaseLabel');
      _log('map tile recovery applied recovery=$_mapTileRecoveryCount phase=$phaseLabel');
      _log(
        'map tiles visible or render retry count=$_mapTileRecoveryCount',
      );
    }

    unawaited(runRecovery(1200, 't1'));
    unawaited(runRecovery(2500, 't2'));
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      unawaited(runRecovery(4200, 't3'));
    }
  }

  void _refreshIosDriverMapIfNeeded({required String reason}) {
    final controller = _mapController;
    if (controller == null || defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }

    _notifyMapLayerChanged();
    _refreshDriverMapPresentation(reason: reason);
    unawaited(_nudgeIosMapTiles(controller, reason: reason));
  }

  void _setStateSafely(VoidCallback apply) {
    if (!mounted || _isDisposing) {
      return;
    }

    setState(apply);
  }

  bool _isRouteRequestStale({
    required int requestGeneration,
    required _RouteRequestKind kind,
    String? expectedRideId,
  }) {
    if (_isDisposing || requestGeneration != _routeRequestGeneration) {
      return true;
    }

    if (kind == _RouteRequestKind.active) {
      return expectedRideId != null &&
          expectedRideId.isNotEmpty &&
          expectedRideId != _currentRideId;
    }

    return expectedRideId != null &&
        expectedRideId.isNotEmpty &&
        expectedRideId != _activePopupRideId &&
        expectedRideId != _currentCandidateRideId;
  }

  void _cancelPendingRouteRequests({required String reason}) {
    final hadPendingTimer = _routeRequestDebounceTimer != null;
    final hadPendingRequest = _pendingRouteRequest != null;
    _routeRequestDebounceTimer?.cancel();
    _routeRequestDebounceTimer = null;
    _pendingRouteRequest = null;
    _routeRequestGeneration++;
    if (hadPendingTimer || hadPendingRequest || _routeRequestInFlight) {
      _log(
        'route requests cancelled reason=$reason generation=$_routeRequestGeneration inFlight=$_routeRequestInFlight',
      );
    }
  }

  void _scheduleActiveRouteRefresh({
    bool force = false,
    required String reason,
    Duration debounce = _kActiveRouteDebounceDuration,
  }) {
    final rideId = _currentRideId;
    if (_isDisposing || rideId == null || rideId.isEmpty) {
      return;
    }

    _scheduleRouteRequest(
      _PendingRouteRequest.active(
        reason: reason,
        force: force,
      ),
      debounce: debounce,
    );
  }

  void _schedulePopupRoutePreview({
    required String rideId,
    required LatLng origin,
    required LatLng destination,
    required String reason,
    Duration debounce = _kPopupRouteDebounceDuration,
  }) {
    if (_isDisposing || rideId.isEmpty) {
      return;
    }

    _scheduleRouteRequest(
      _PendingRouteRequest.popupPreview(
        rideId: rideId,
        origin: origin,
        destination: destination,
        reason: reason,
      ),
      debounce: debounce,
    );
  }

  void _scheduleRouteRequest(
    _PendingRouteRequest request, {
    required Duration debounce,
  }) {
    if (_isDisposing) {
      return;
    }

    if (_routeRequestInFlight) {
      _routeRequestGeneration++;
    }
    _pendingRouteRequest = request;
    _routeRequestDebounceTimer?.cancel();
    _routeRequestDebounceTimer = Timer(debounce, () {
      _routeRequestDebounceTimer = null;
      if (_isDisposing) {
        return;
      }

      final pending = _pendingRouteRequest;
      _pendingRouteRequest = null;
      if (pending == null) {
        return;
      }

      if (_routeRequestInFlight) {
        _pendingRouteRequest = pending;
        return;
      }

      final requestGeneration = ++_routeRequestGeneration;
      _routeRequestInFlight = true;
      unawaited(_executeRouteRequest(pending, requestGeneration));
    });
  }

  Future<void> _executeRouteRequest(
    _PendingRouteRequest request,
    int requestGeneration,
  ) async {
    try {
      if (request.kind == _RouteRequestKind.popupPreview) {
        await _drawRoute(
          request.origin!,
          request.destination!,
          requestGeneration: requestGeneration,
          routeKind: request.kind,
          expectedRideId: request.rideId,
        );
        return;
      }

      await _refreshActiveRoute(
        force: request.force,
        reason: request.reason,
        requestGeneration: requestGeneration,
      );
    } catch (error) {
      _log(
        'route request execution failed kind=${request.kind.name} reason=${request.reason} error=$error',
      );
    } finally {
      _routeRequestInFlight = false;
      final pending = _pendingRouteRequest;
      if (pending != null && !_isDisposing) {
        _scheduleRouteRequest(
          pending,
          debounce: Duration.zero,
        );
      }
    }
  }

  void _log(String message) {
    debugPrint('[DriverMap] $message');
  }

  void _logGuard(String message) {
    debugPrint('[DriverGuard] $message');
  }

  void _logValidation(String message) {
    debugPrint('[DriverValidation] $message');
  }

  void _logUi(String message) {
    debugPrint('[DriverUI] $message');
  }

  void _logRtdb(String message) {
    debugPrint('[DriverRTDB] $message');
  }

  /// Temporary trace for ride discovery → popup (filter logcat by [RIDE_REQ]).
  void _logRideReq(String message) {
    _log('[RIDE_REQ] $message');
  }

  String _firebaseErrorCode(Object error) {
    if (error is FirebaseException) {
      return error.code.trim().isEmpty ? 'unknown' : error.code;
    }
    return 'unknown';
  }

  String _firebaseErrorMessage(Object error) {
    if (error is FirebaseException) {
      return (error.message ?? error.toString()).trim();
    }
    return error.toString();
  }

  String _discoveryListenerFailureMessage(Object error) {
    final code = _firebaseErrorCode(error).toLowerCase();
    if (isRealtimeDatabasePermissionDenied(error) || code == 'permission-denied') {
      return 'We could not load nearby ride requests (access denied). '
          'Confirm you are signed in, then try again. If it keeps happening, '
          'support may need to adjust ride discovery access in the backend.';
    }
    if (code.contains('network') || code.contains('unavailable')) {
      return 'Ride listings were interrupted (network). Retrying automatically…';
    }
    if (code.contains('database') || code.contains('project')) {
      return 'Ride listings could not start because the app is pointed at the wrong database or project. Check your build configuration and try again.';
    }
    return 'Ride listings could not start. Retrying automatically…';
  }

  void _scheduleRideDiscoveryReattach({
    required String reason,
    Duration delay = const Duration(seconds: 2),
  }) {
    _rideDiscoveryReattachTimer?.cancel();
    _rideDiscoveryReattachTimer = Timer(delay, () {
      if (!mounted || !_isOnline || _isDisposing) {
        return;
      }
      unawaited(_listenForRideRequests(reason: reason));
    });
  }

  void _logCanonicalRideEvent({
    required String eventName,
    required String rideId,
    Map<String, dynamic>? rideData,
  }) {
    final status = rideData == null ? '' : _valueAsText(rideData['status']);
    final tripState =
        rideData == null ? '' : _valueAsText(rideData['trip_state']);
    final driverId = rideData == null ? '' : _valueAsText(rideData['driver_id']);
    _logRideReq(
      '[MATCH_EVENT] event=$eventName rideId=$rideId status=$status '
      'trip_state=$tripState driver_id=$driverId',
    );
  }

  /// Temporary verification for RTDB discovery vs rider writes (filter by `[DRIVER_REQ]`).
  void _logDriverReq(String message) {
    debugPrint('[DRIVER_REQ] $message');
  }

  void _logReqDebug(String message) {
    debugPrint('[REQ_DEBUG] $message');
  }

  /// Discovery RTDB reads (filter `[RTDB_DISCOVERY]`); path + auth + permission outcome.
  Future<T> _logDiscoveryRtdbRead<T>({
    required String op,
    required String path,
    required String? market,
    required Future<T> Function() run,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? 'none';
    final m = market ?? 'null';
    debugPrint(
      '[RTDB_DISCOVERY] READ_START op=$op path=$path market=$m authUid=$uid',
    );
    try {
      final v = await run();
      debugPrint(
        '[RTDB_DISCOVERY] READ_OK op=$op path=$path market=$m authUid=$uid',
      );
      return v;
    } catch (error, stackTrace) {
      final denied = isRealtimeDatabasePermissionDenied(error);
      debugPrint(
        '[RTDB_DISCOVERY] READ_FAIL op=$op path=$path market=$m authUid=$uid '
        'permissionDenied=$denied error=$error',
      );
      debugPrintStack(
        label: '[RTDB_DISCOVERY] READ_FAIL op=$op',
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// One-shot read of `ride_requests/{rideId}` that never overlaps iOS-native
  /// `onValue` on the **same** child ref (Firebase iOS: tracked-keys assertion).
  Future<rtdb.DataSnapshot> _rideRequestChildGetIosSafe(
    String rideId,
    String op,
  ) async {
    final normalized = rideId.trim();
    _logRideReq('[MATCH_DEBUG][QUERY_GET:ride_requests/$normalized] op=$op');
    final conflictingListener = _activeRideListenerRideId == normalized &&
        _activeRideSubscription != null;
    if (!conflictingListener) {
      return _rideRequestsRef.child(normalized).get();
    }
    _logRideReq(
      '[MATCH_DEBUG][QUERY_PAUSE:ride_requests/$normalized] op=$op '
      'reason=avoid_get_while_active_ride_onvalue',
    );
    final sub = _activeRideSubscription;
    await sub?.cancel();
    _activeRideSubscription = null;
    _activeRideListenerRideId = null;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    try {
      return await _rideRequestsRef.child(normalized).get();
    } finally {
      if (conflictingListener && mounted && _isValidRideId(normalized)) {
        _logRideReq(
          '[MATCH_DEBUG][QUERY_ATTACH:ride_requests/$normalized] op=$op resume_onvalue',
        );
        await _listenToActiveRide(normalized);
      }
    }
  }

  /// Temporary popup lifecycle trace (filter by `[POPUP_FIX]`).
  void _logPopupFix(String message) {
    debugPrint('[POPUP_FIX] $message');
  }

  /// Popup pipeline (filter logcat by [POPUP]); messages kept stable for QA scripts.
  void _logPopup(String message) {
    _log('[POPUP] $message');
  }

  void _logRidePopup(String message) {
    debugPrint('[RIDE_POPUP] $message');
  }

  /// Rider → RTDB → driver discovery chain (filter logcat by `[DISCOVERY]`).
  void _logDiscoveryChain(String message) {
    debugPrint('[DISCOVERY] $message');
  }

  void _logRideReqContext(String stage) {
    _logRideReq(
      '$stage context driverMarket=${_effectiveDriverMarket ?? 'null'} '
      '_driverCity=${_driverCity ?? 'null'} boundCity=$_rideRequestsListenerBoundCity '
      'online=$_isOnline session=$_onlineSessionStartedAt '
      'driverActive=$_driverActiveRideId current=$_currentRideId '
      'activeListener=$_activeRideListenerRideId '
      'popupOpen=$_popupOpen hasActivePopup=$_hasActivePopup activePopup=$_activePopupRideId '
      'presented=${_presentedRideIds.join(',')} suppressed=${_suppressedRidePopupIds.join(',')}',
    );
  }

  void _logRideCall(String message) {
    debugPrint('[RideCall] $message');
  }

  void _logTripPanelHidden(String reason) {
    if (_lastTripPanelHiddenReason == reason) {
      return;
    }

    _lastTripPanelHiddenReason = reason;
    if (reason == 'no_valid_active_ride') {
      _logValidation('trip panel hidden no_valid_active_ride');
      return;
    }
    _logValidation('trip panel hidden reason=$reason');
  }

  void _logRenderBlocked({
    required String rideId,
    required String reason,
  }) {
    final logKey = 'render:$rideId:$reason';
    if (_lastValidationBlockedKey == logKey) {
      return;
    }

    _lastValidationBlockedKey = logKey;
    _logValidation('render blocked rideId=$rideId reason=$reason');
  }

  void _logListenerStillActiveWaitingForFreshRides() {
    if (!_isOnline) {
      return;
    }

    _logRtdb('listener still active waiting_for_fresh_rides');
  }

  void _logInvalidRideBlocked({
    required String rideId,
    required String reason,
  }) {
    final logKey = '$rideId:$reason';
    if (_lastValidationBlockedKey == logKey) {
      return;
    }

    _lastValidationBlockedKey = logKey;
    _logValidation('invalid ride blocked: $reason');
  }

  void _logRideCandidate({
    required String rideId,
    required Map<String, dynamic>? rideData,
  }) {
    final status = TripStateMachine.uiStatusFromSnapshot(rideData);
    final driverId = _valueAsText(rideData?['driver_id']);
    final serviceType = _serviceTypeKey(rideData?['service_type']);
    final city = _rideMarketFromData(rideData) ?? 'unknown';
    final area =
        rideData == null ? '' : _rideAreaFromData(rideData, city: city);
    _logRtdb(
      'ride candidate scan rideId=$rideId status=$status driverId=$driverId serviceType=$serviceType market=$city area=${area.isEmpty ? 'none' : area}',
    );
  }

  void _trackRideForCurrentSession(String rideId) {
    _sessionTrackedRideId = rideId;
    _lastTripPanelHiddenReason = null;
  }

  void _printRideOwnershipDebug(Map<String, dynamic>? ride) {
    final currentDriverId = _effectiveDriverId;
    // ignore: avoid_print
    print('RTDB ride status: ${_valueAsText(ride?['status'])}');
    // ignore: avoid_print
    print('RTDB driver_id: ${_valueAsText(ride?['driver_id'])}');
    // ignore: avoid_print
    print('CURRENT driver: $currentDriverId');
  }

  String? _activeRideInvalidReason(
    Map<String, dynamic>? ride, {
    String? rideId,
    bool requireTrackedRide = false,
    bool relaxLifecycleProof = false,
  }) {
    if (ride == null) {
      return 'payload_not_map';
    }

    final status = TripStateMachine.uiStatusFromSnapshot(ride);
    final canonicalState = TripStateMachine.canonicalStateFromSnapshot(ride);
    if (status.isEmpty) {
      return 'missing_status';
    }

    if (status == 'searching') {
      return 'status_searching';
    }

    if (status == 'cancelled') {
      return 'status_cancelled';
    }

    if (status == 'completed' || ride['trip_completed'] == true) {
      return 'status_completed';
    }

    if (!_isActiveRideStatus(status)) {
      return 'status_not_active';
    }

    if (!relaxLifecycleProof) {
      final lifecycleProofReason = TripStateMachine.lifecycleProofReason(
        ride,
        canonicalState: canonicalState,
      );
      if (lifecycleProofReason != null) {
        return lifecycleProofReason;
      }
    }

    if (_valueAsText(ride['driver_id']) != _effectiveDriverId) {
      return 'driver_mismatch';
    }

    if (_pickupLatLngFromRideData(ride) == null) {
      return 'missing_pickup_coordinates';
    }

    if (_destinationLatLngFromRideData(ride) == null) {
      return 'missing_destination_coordinates';
    }

    final normalizedRideId = rideId?.trim();
    if (normalizedRideId != null && normalizedRideId.isEmpty) {
      return 'ride_id_missing';
    }

    if (requireTrackedRide) {
      if (!_isOnline) {
        return 'driver_offline';
      }

      final trackedRideId = normalizedRideId ?? _currentRideId;
      if (trackedRideId == null || trackedRideId.isEmpty) {
        return 'ride_id_missing';
      }

      if (_sessionTrackedRideId != trackedRideId) {
        return 'ride_not_tracked_for_session';
      }
    }

    return null;
  }

  String? _activeRideRenderGuardReason(
    Map<String, dynamic>? ride, {
    String? rideId,
  }) {
    if (rideId == null || !_isValidRideId(rideId) || ride == null) {
      return 'no_valid_active_ride';
    }

    return _activeRideInvalidReason(
      ride,
      rideId: rideId,
      requireTrackedRide: true,
    );
  }

  bool _hasLocalRideStateToPurge() {
    final hasTrackedRideState = _currentRideId != null ||
        _sessionTrackedRideId != null ||
        _currentRideData != null ||
        _currentCandidateRideId != null;
    if (!hasTrackedRideState) {
      return false;
    }

    final hasRideMarkers = _markers.any((marker) {
      final markerId = marker.markerId.value;
      return markerId == 'pickup' ||
          markerId == 'destination' ||
          markerId.startsWith('stop_');
    });

    return _currentRideId != null ||
        _sessionTrackedRideId != null ||
        _currentRideData != null ||
        _currentCandidateRideId != null ||
        _activePopupRideId != null ||
        _acceptingPopupRideId != null ||
        _popupDismissedRideId != null ||
        _popupOpen ||
        _hasActivePopup ||
        _pickupLocation != null ||
        _destinationLocation != null ||
        _nextNavigationTarget != null ||
        _pickupAddressText.isNotEmpty ||
        _destinationAddressText.isNotEmpty ||
        _riderName != 'Rider' ||
        _riderPhone.isNotEmpty ||
        _tripWaypoints.isNotEmpty ||
        _expectedRoutePoints.isNotEmpty ||
        hasRideMarkers ||
        _polyLines.isNotEmpty;
  }

  void _scheduleStaleRidePurge({
    required String? rideId,
    required String reason,
  }) {
    if (!_hasLocalRideStateToPurge()) {
      return;
    }

    final purgeRideId = rideId?.trim().isNotEmpty == true
        ? rideId!.trim()
        : 'no_valid_active_ride';
    final purgeKey = '$purgeRideId:$reason';
    if (_pendingStaleRidePurgeKey == purgeKey) {
      return;
    }

    _pendingStaleRidePurgeKey = purgeKey;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingStaleRidePurgeKey = null;
      if (!mounted || !_hasLocalRideStateToPurge()) {
        return;
      }

      _logValidation('stale local ride purged');
      unawaited(_clearActiveRideState(reason: reason));
    });
  }

  bool isValidActiveRide(Map<String, dynamic>? ride) {
    return _activeRideInvalidReason(ride) == null;
  }

  String? get _configuredTestDriverCity {
    if (!DriverLocationPolicy.useTestDriverLocation) {
      return null;
    }
    return _defaultTestDriverCity;
  }

  String get _defaultTestDriverCity =>
      DriverLaunchScope.normalizeSupportedCity(
          DriverLocationPolicy.testDriverCity) ??
      DriverLaunchScope.defaultBrowseCity;

  String get _effectiveTestDriverCity =>
      _normalizeCity(_selectedLaunchCity) ?? _defaultTestDriverCity;

  _NigeriaTestDriverLocation? _getNigeriaTestDriverLocation() {
    final normalizedCity = DriverLocationPolicy.useTestDriverLocation
        ? _effectiveTestDriverCity
        : null;
    if (normalizedCity == null) {
      return null;
    }

    final testLocation = normalizedCity == 'abuja'
        ? _kAbujaTestDriverLocation
        : _kLagosTestDriverLocation;

    _log(
      'test mode enabled city=${testLocation.city} lat=${testLocation.latitude} lng=${testLocation.longitude}',
    );

    return testLocation;
  }

  @override
  void dispose() {
    _isDisposing = true;
    WidgetsBinding.instance.removeObserver(this);
    _positionStream?.cancel();
    _rideRequestListenerToken += 1;
    _rideRequestSubscription?.cancel();
    _rideDiscoveryReattachTimer?.cancel();
    _rideRequestsListenerBoundCity = null;
    _driverActiveRideSubscription?.cancel();
    _activeRideSubscription?.cancel();
    _stopDriverChatListener();
    _callSubscription?.cancel();
    _incomingCallSubscription?.cancel();
    _ridePopupTimer?.cancel();
    _cancelPendingRouteRequests(reason: 'dispose');
    _callDurationTimer?.cancel();
    _callRingTimeoutTimer?.cancel();
    _mapInitializationTimer?.cancel();
    _removeCallOverlayEntry();
    unawaited(_callService.dispose());
    unawaited(_stopCallRingtone());
    unawaited(_alertSoundService.dispose());
    _roadRouteService.dispose();
    _driverChatMessages.dispose();
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

    unawaited(_refreshDriverLocationCapability(reason: 'resume'));

    final rideIdForCallMonitoring = _currentRideId ?? _driverActiveRideId;
    if (_canMonitorRideCalls &&
        rideIdForCallMonitoring != null &&
        rideIdForCallMonitoring.isNotEmpty) {
      unawaited(_resyncIncomingCallState());
    }
    unawaited(_syncCallForegroundState(foreground: true));

    if (_positionStream == null &&
        (_isOnline ||
            (_currentRideId?.isNotEmpty ?? false) ||
            (_driverActiveRideId?.isNotEmpty ?? false))) {
      _startLiveLocationStream();
    }

    final rideId = _currentRideId;
    if (rideId == null || rideId.isEmpty) {
      _ensureRideDiscoverySubscriptionIfOnline(reason: 'lifecycle_resume_no_local_ride');
      return;
    }

    _startDriverChatListener(rideId);
    if (_activeRideListenerRideId != rideId ||
        _activeRideSubscription == null) {
      unawaited(_listenToActiveRide(rideId));
    }
    if (_callListenerRideId != rideId || _callSubscription == null) {
      _startCallListener(rideId);
      _ensureRideDiscoverySubscriptionIfOnline(
        reason: 'lifecycle_resume_call_listener_started',
      );
      return;
    }

    unawaited(_resyncCallState(rideId));
    _ensureRideDiscoverySubscriptionIfOnline(
      reason: 'lifecycle_resume_active_ride',
    );
  }

  /// While online, discovery must stay attached (including during an active trip).
  void _ensureRideDiscoverySubscriptionIfOnline({required String reason}) {
    if (!_isOnline || _isDisposing) {
      return;
    }
    if (_rideRequestSubscription != null) {
      return;
    }
    _logRideReq(
      '[DISCOVERY_REBIND] reason=$reason subscription=null -> _listenForRideRequests',
    );
    unawaited(_listenForRideRequests(reason: reason));
  }

  Future<void> _loadCarIcon() async {}

  Future<void> _prepareInitialLocation() async {
    _log('location permission started source=initial_map');
    _setDebugStartupStep('waiting for location');
    final testLocation = _getNigeriaTestDriverLocation();
    if (testLocation != null) {
      _driverLocation = LatLng(testLocation.latitude, testLocation.longitude);
      _driverCity = testLocation.city;
      _mapLocationReady = false;
      _log(
        'location permission completed source=initial_map mode=test_location city=${testLocation.city}',
      );
      _updateDriverMarker();

      if (mounted) {
        setState(() {});
      }
      return;
    }

    final position = await _getCurrentPositionIfPossible();
    if (position == null) {
      _log('initial location unavailable');
      _mapLocationReady = false;
      _log(
          'location permission completed source=initial_map status=unavailable');
      return;
    }

    final detectedLaunchCity = await _resolveLaunchCityFromPosition(position);
    if (detectedLaunchCity == null) {
      _driverLocation = const LatLng(
        DriverServiceAreaConfig.defaultMapLatitude,
        DriverServiceAreaConfig.defaultMapLongitude,
      );
      _driverCity = _selectedLaunchCity;
      _deviceLocationOutsideLaunchArea = true;
      _mapLocationReady = false;
      _log(
        'location permission completed source=initial_map status=outside_launch_area selectedLaunchCity=$_selectedLaunchCity',
      );
      _updateDriverMarker();
      if (mounted) {
        setState(() {});
      }
      return;
    }

    _deviceLocationOutsideLaunchArea = false;
    if (!_launchCityChosenManually &&
        detectedLaunchCity != _selectedLaunchCity) {
      await _selectLaunchCity(
        detectedLaunchCity,
        manual: false,
        persist: false,
        moveCamera: false,
      );
    }
    _driverLocation = LatLng(position.latitude, position.longitude);
    await _resolveDriverCity(position: position);
    _mapLocationReady = true;
    _log(
      'location permission completed source=initial_map lat=${position.latitude} lng=${position.longitude} city=${_driverCity ?? 'unknown'}',
    );
    _updateDriverMarker();

    if (mounted) {
      setState(() {});
    }
  }

  Future<Map<String, dynamic>> _fetchDriverProfile({
    String source = 'general',
    bool createIfMissing = true,
    Duration readTimeout = const Duration(seconds: 18),
  }) async {
    final driverId = _effectiveDriverId;
    final authUser = FirebaseAuth.instance.currentUser;
    if (driverId.isEmpty) {
      _log(
          'driver profile fetch blocked source=$source reason=missing_driver_id');
      return buildDriverProfileRecord(
        driverId: widget.driverId,
        existing: const <String, dynamic>{},
        fallbackName: widget.driverName,
      );
    }
    if (authUser == null) {
      _log('driver profile fetch blocked source=$source reason=missing_auth');
      return buildDriverProfileRecord(
        driverId: driverId,
        existing: const <String, dynamic>{},
        fallbackName: widget.driverName,
      );
    }
    if (authUser.uid.trim() != driverId) {
      _log(
        'driver profile fetch uid mismatch source=$source authUid=${authUser.uid} driverId=$driverId usingAuthUid=${authUser.uid.trim()}',
      );
    }

    _log(
      'driver profile fetch started source=$source driverId=$driverId path=${driverProfilePath(authUser.uid)}',
    );
    try {
      final result = await fetchDriverProfileRecord(
        rootRef: rtdb.FirebaseDatabase.instance.ref(),
        user: authUser,
        source: 'driver_map_$source',
        role: AppRole.driver,
        createIfMissing: createIfMissing,
      ).timeout(readTimeout);
      final profile = result.profile;
      _lastDriverProfileSnapshot = Map<String, dynamic>.from(profile);
      _log(
        'driver profile fetch completed source=$source driverId=$driverId path=${result.path} exists=${result.snapshotFound} createdFallback=${result.createdFallbackProfile} uidMatches=${result.uidMatchesRecord} parseWarning=${result.parseWarning ?? 'none'} readError=${result.readError ?? 'none'} persistWarning=${result.persistWarning ?? 'none'} status=${profile['status']} online=${profile['isOnline']}',
      );
      return profile;
    } on TimeoutException catch (error) {
      _log(
        'driver profile fetch TIMEOUT source=$source driverId=$driverId error=$error',
      );
      return buildDriverProfileRecord(
        driverId: driverId,
        existing: const <String, dynamic>{},
        fallbackName: widget.driverName,
      );
    } catch (error, stackTrace) {
      _logFirebaseDatabaseError(
        'driver profile fetch FAILED source=$source driverId=$driverId',
        error,
      );
      debugPrintStack(
        label: '[DriverMap] driver profile fetch stack',
        stackTrace: stackTrace,
      );
      return buildDriverProfileRecord(
        driverId: driverId,
        existing: const <String, dynamic>{},
        fallbackName: widget.driverName,
      );
    }
  }

  void _logFirebaseDatabaseError(String label, Object error) {
    if (error is FirebaseException) {
      _log('$label firebase code=${error.code} message=${error.message}');
      return;
    }
    _log('$label error=$error');
  }

  bool _goOnlineEligibleFromProfile(Map<String, dynamic>? profile) {
    if (profile == null || profile.isEmpty) {
      return false;
    }
    final businessModel =
        normalizedDriverBusinessModel(profile['businessModel']);
    final verification =
        normalizedDriverVerification(profile['verification']);
    return businessModel['canGoOnline'] == true &&
        driverVerificationCanGoOnline(verification);
  }

  Future<void> _loadOptionalDriverBootstrapContext() async {
    final driverId = _effectiveDriverId;
    if (driverId.isEmpty) {
      return;
    }

    _setDebugStartupStep('loading driver profile');
    try {
      final profile = await _fetchDriverProfile(
        source: 'bootstrap',
        createIfMissing: false,
      ).timeout(const Duration(seconds: 8));
      final storedLaunchCity = _normalizeCity(
        profile['launch_market_city'] ??
            profile['launchMarket'] ??
            profile['launch_market'],
      );
      final preferredLaunchCity = storedLaunchCity ??
          _normalizeCity(_selectedLaunchCity) ??
          _defaultTestDriverCity;
      final preferredArea = _preferredAreaFromProfile(
        profile,
        preferredLaunchCity,
      );
      final hasStoredLaunchCity = storedLaunchCity != null;
      final status = _normalizedRideStatus(_valueAsText(profile['status']));
      final remoteOnline =
          _asBool(profile['isOnline']) || _asBool(profile['online']);
      _log(
        'driver status fetch completed driverId=$driverId status=$status online=$remoteOnline startupMode=restore',
      );

      _log('driver service config fetch started driverId=$driverId');
      final businessModel =
          normalizedDriverBusinessModel(profile['businessModel']);
      final verification =
          normalizedDriverVerification(profile['verification']);
      _log(
        'driver service config fetch completed driverId=$driverId selectedModel=${businessModel['selectedModel']} canGoOnline=${businessModel['canGoOnline']} verification=${verification['overallStatus']}',
      );

      if (!mounted) {
        _selectedLaunchCity = preferredLaunchCity;
        _launchCityChosenManually = hasStoredLaunchCity;
        _driverCity = preferredLaunchCity;
        _driverArea = preferredArea;
        if (!_mapLocationReady || _deviceLocationOutsideLaunchArea) {
          _driverLocation = _driverFallbackLocation;
        }
        return;
      }

      setState(() {
        _selectedLaunchCity = preferredLaunchCity;
        _launchCityChosenManually = hasStoredLaunchCity;
        _driverCity = preferredLaunchCity;
        _driverArea = preferredArea;
        _lastAvailabilityIntentOnline = _lastAvailabilityIntentFromRecord(
          profile,
          remoteOnline: remoteOnline,
          hasTrackedRide: _hasRenderableActiveRide,
        );
        if (!_mapLocationReady || _deviceLocationOutsideLaunchArea) {
          _driverLocation = _driverFallbackLocation;
        }
        _rideStatus = _hasRenderableActiveRide ? _rideStatus : 'offline';
      });
    } on TimeoutException catch (error, stackTrace) {
      _log('optional bootstrap timeout driverId=$driverId error=$error');
      debugPrintStack(
        label: '[DriverMap] optional bootstrap timeout stack',
        stackTrace: stackTrace,
      );
    } catch (error, stackTrace) {
      if (isRealtimeDatabasePermissionDenied(error)) {
        _surfaceStartupPermissionDenied(
          path: 'drivers/$driverId',
          error: error,
          stackTrace: stackTrace,
          showDefaultState: false,
        );
        return;
      }
      _log('optional bootstrap failed driverId=$driverId error=$error');
      debugPrintStack(
        label: '[DriverMap] optional bootstrap stack',
        stackTrace: stackTrace,
      );
    } finally {
      if (_debugStartupStep == 'loading driver profile') {
        _setDebugStartupStep('waiting for map init');
      }
    }
  }

  Future<Position?> _getCurrentPositionIfPossible() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _log('location services disabled');
        unawaited(
            _refreshDriverLocationCapability(reason: 'initial_map_disabled'));
        return null;
      }

      final permission = await Geolocator.checkPermission();
      _log('location permission current source=initial_map value=$permission');
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _log('location permission not available yet for initial fetch');
        unawaited(
          _refreshDriverLocationCapability(reason: 'initial_map_permission'),
        );
        return null;
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      _log(
        'location current position completed source=initial_map lat=${position.latitude} lng=${position.longitude}',
      );
      unawaited(_refreshDriverLocationCapability(reason: 'initial_map_ready'));
      return position;
    } catch (error) {
      _log('initial location error=$error');
      unawaited(_refreshDriverLocationCapability(reason: 'initial_map_error'));
      return null;
    }
  }

  Future<void> _refreshDriverLocationCapability({
    required String reason,
  }) async {
    final capability = await evaluateDriverLocationCapability();
    _log(
      'location capability updated reason=$reason canBrowse=${capability.canBrowseDriverApp} canGoOnline=${capability.canGoOnline} serviceEnabled=${capability.locationServiceEnabled} permission=${capability.permission}',
    );
    if (!mounted) {
      return;
    }

    _setStateSafely(() {});
  }

  void _showDriverLocationRequirementNotice(
    String message, {
    bool openLocationSettings = false,
    bool openAppSettings = false,
  }) {
    _showSnackBarSafely(
      SnackBar(
        content: Text(message),
        action: openLocationSettings
            ? SnackBarAction(
                label: 'Settings',
                onPressed: () {
                  unawaited(Geolocator.openLocationSettings());
                },
              )
            : openAppSettings
                ? SnackBarAction(
                    label: 'Settings',
                    onPressed: () {
                      unawaited(Geolocator.openAppSettings());
                    },
                  )
                : null,
      ),
    );
  }

  void _showAvailabilityFailureNotice(String message) {
    _showSnackBarSafely(
      SnackBar(
        content: Text(message),
      ),
    );
  }

  void _markDiscoveryPermissionDeniedNoticeVisible({required String source}) {
    _discoveryPermissionDeniedNoticeVisible = true;
    _logRideReq('[DRIVER_DISCOVERY_TRACE] snackbar_state=set_access_denied source=$source');
  }

  void _clearDiscoveryPermissionDeniedNotice({required String source}) {
    if (!_discoveryPermissionDeniedNoticeVisible) {
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    _discoveryPermissionDeniedNoticeVisible = false;
    _logRideReq('[DRIVER_DISCOVERY_TRACE] snackbar_state=cleared_access_denied source=$source');
  }

  Future<Position?> _requestReadyPosition({
    Duration? positionTimeLimit,
  }) async {
    final initialCapability = await evaluateDriverLocationCapability();

    final serviceEnabled = initialCapability.locationServiceEnabled;
    if (!serviceEnabled) {
      _log('goOnline failed: location service disabled');
      _showDriverLocationRequirementNotice(
        'Turn on Location Services to go online and receive trips in ${DriverLaunchScope.launchCitiesLabel}.',
        openLocationSettings: true,
      );
      return null;
    }

    var permission = initialCapability.permission;
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied) {
      _log('goOnline failed: location permission denied');
      await _refreshDriverLocationCapability(
          reason: 'go_online_permission_denied');
      _showDriverLocationRequirementNotice(
        'Allow location access to go online and receive trips in ${DriverLaunchScope.launchCitiesLabel}.',
      );
      return null;
    }

    if (permission == LocationPermission.deniedForever) {
      _log('goOnline failed: location permission denied forever');
      await _refreshDriverLocationCapability(
        reason: 'go_online_permission_denied_forever',
      );
      _showDriverLocationRequirementNotice(
        'Location access is turned off for NexRide. Enable it in app settings before going online.',
        openAppSettings: true,
      );
      return null;
    }

    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: positionTimeLimit,
      );
      final detectedLaunchCity = await _resolveLaunchCityFromPosition(position);
      if (detectedLaunchCity == null) {
        if (DriverServiceAreaConfig.qaAllowOutOfRegionBrowsing) {
          _log(
            'goOnline: GPS outside launch geofence; continuing with selected launch city (qaAllowOutOfRegionBrowsing)',
          );
          if (mounted) {
            setState(() {
              _deviceLocationOutsideLaunchArea = true;
            });
          } else {
            _deviceLocationOutsideLaunchArea = true;
          }
          await _refreshDriverLocationCapability(
            reason: 'go_online_outside_launch_qa',
          );
          return position;
        }
        _log(
          'goOnline blocked: current device location is outside supported service area',
        );
        if (mounted) {
          setState(() {
            _deviceLocationOutsideLaunchArea = true;
          });
        } else {
          _deviceLocationOutsideLaunchArea = true;
        }
        _showDriverLocationRequirementNotice(
          'Go online is available only when your live location is inside ${DriverLaunchScope.launchCitiesLabel}.',
        );
        return null;
      } else {
        if (mounted) {
          setState(() {
            _deviceLocationOutsideLaunchArea = false;
          });
        } else {
          _deviceLocationOutsideLaunchArea = false;
        }
      }
      await _refreshDriverLocationCapability(
          reason: 'go_online_position_ready');
      return position;
    } catch (error) {
      _log('goOnline failed: current position error=$error');
      await _refreshDriverLocationCapability(
          reason: 'go_online_position_error');
      _showDriverLocationRequirementNotice(
        'We still need your live location before you can go online in ${DriverLaunchScope.launchCitiesLabel}.',
      );
      return null;
    }
  }

  Future<void> _rollbackFailedGoOnline({
    required String driverId,
    required String reason,
    bool publishedPresence = false,
  }) async {
    _log(
      'rolling back failed goOnline driverId=$driverId reason=$reason publishedPresence=$publishedPresence',
    );

    await _positionStream?.cancel();
    _positionStream = null;
    await _cancelRideRequestListener(reason: 'rollback_failed_go_online');
    await _stopIncomingCallMonitoring();
    _stopActiveRideListener();
    _resetDriverChatState();
    _clearRidePopupTimer();
    _cancelPendingRouteRequests(reason: 'go_online_failed');
    _hasActivePopup = false;
    _popupOpen = false;
    _activePopupRideId = null;
    _acceptingPopupRideId = null;
    _popupDismissedRideId = null;
    _popupDismissedReason = null;
    _presentedRideIds.clear();
    _timedOutRideIds.clear();
    _declinedRideIds.clear();
    _handledRideIds.clear();
    _suppressedRidePopupIds.clear();
    _terminalSelfAcceptedRideIds.clear();
    _rideRequestPopupQueue.clear();
    _onlineSessionStartedAt = 0;
    _lastAvailabilityIntentOnline = false;
    _sessionTrackedRideId = null;
    _driverActiveRideId = null;
    _currentRideId = null;
    _currentRideData = null;
    _currentCandidateRideId = null;
    _tripStarted = false;
    _rideStatus = 'offline';
    _pickupLocation = null;
    _destinationLocation = null;
    _nextNavigationTarget = null;
    _pickupAddressText = '';
    _destinationAddressText = '';
    _tripWaypoints.clear();
    _expectedRoutePoints.clear();
    _polyLines.clear();
    _syncTripLocationMarkers();

    if (publishedPresence && driverId.isNotEmpty) {
      try {
        await _driversRef.child(driverId).update({
          'isOnline': false,
          'is_online': false,
          'isAvailable': false,
          'available': false,
          'status': 'offline',
          'activeRideId': null,
          'currentRideId': null,
          'online_session_started_at': null,
          'last_availability_intent': 'offline',
          'last_availability_intent_at': rtdb.ServerValue.timestamp,
          'last_active_at': rtdb.ServerValue.timestamp,
          'updated_at': rtdb.ServerValue.timestamp,
        });
      } catch (error) {
        _log(
          'goOnline rollback presence update failed driverId=$driverId error=$error',
        );
      }
    }

    if (mounted) {
      _setStateSafely(() {
        _isOnline = false;
      });
    } else {
      _isOnline = false;
    }
  }

  String? _normalizeCity(dynamic city) {
    return DriverLaunchScope.normalizeSupportedCity(city?.toString());
  }

  String? _normalizeRideMarket(dynamic rawMarket) {
    return normalizeRideMarketSlug(rawMarket) ?? _normalizeCity(rawMarket);
  }

  /// Canonical market for ride request queries and popup eligibility.
  /// Uses GPS/profile [_driverCity] when set; otherwise the selected launch city
  /// so dispatch stays aligned if resolution lags briefly after startup.
  /// Falls back to [DriverServiceAreaConfig.marketForCity] when normalize returns
  /// null but a non-empty raw city exists (same slug as rider `ride_requests.market`).
  String? get _effectiveDriverMarket {
    final fromDriver = _normalizeCity(_driverCity);
    if (fromDriver != null) {
      return fromDriver;
    }
    final fromSelected = _normalizeCity(_selectedLaunchCity);
    if (fromSelected != null) {
      return fromSelected;
    }
    final raw = _driverCity ?? _selectedLaunchCity;
    if (raw.trim().isNotEmpty) {
      return DriverServiceAreaConfig.marketForCity(raw).city;
    }
    return null;
  }

  String? _normalizeArea(dynamic area, {String? city}) {
    return DriverLaunchScope.normalizeSupportedArea(
      area?.toString(),
      city: city,
    );
  }

  String _preferredAreaFromProfile(Map<String, dynamic> profile, String city) {
    return _normalizeArea(
          profile['area'] ?? profile['zone'] ?? profile['community'],
          city: city,
        ) ??
        '';
  }

  Future<void> _selectLaunchCity(
    String city, {
    bool manual = true,
    bool persist = true,
    bool moveCamera = true,
  }) async {
    final normalizedCity = _normalizeCity(city) ?? _selectedLaunchCity;
    if (!mounted) {
      _selectedLaunchCity = normalizedCity;
      _launchCityChosenManually = manual;
      _driverCity = normalizedCity;
    } else {
      setState(() {
        _selectedLaunchCity = normalizedCity;
        _launchCityChosenManually = manual;
        _driverCity = normalizedCity;
      });
    }

    if (moveCamera && !_hasRenderableActiveRide) {
      _driverLocation = _selectedLaunchCityCenter;
      if (_mapController != null && _mapViewReady) {
        await _mapController!.animateCamera(
          CameraUpdate.newLatLngZoom(_selectedLaunchCityCenter, 14),
        );
      }
      _updateDriverMarker();
    }

    if (!persist) {
      return;
    }

    final driverId = _effectiveDriverId;
    if (driverId.isEmpty) {
      return;
    }

    try {
      await _driversRef.child(driverId).update(<String, dynamic>{
        'launch_market_city': normalizedCity,
        'launch_market_country': DriverLaunchScope.countryName,
        'launch_market_updated_at': rtdb.ServerValue.timestamp,
      });
    } catch (error) {
      _log(
        'launch market persist failed driverId=$driverId city=$normalizedCity error=$error',
      );
    }
  }

  Future<String?> _resolveLaunchCityFromPosition(Position position) async {
    try {
      final placemarks = await placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );

      for (final placemark in placemarks) {
        final rawCandidates = <String>[
          if ((placemark.locality ?? '').trim().isNotEmpty)
            placemark.locality!.trim(),
          if ((placemark.subLocality ?? '').trim().isNotEmpty)
            placemark.subLocality!.trim(),
          if ((placemark.subAdministrativeArea ?? '').trim().isNotEmpty)
            placemark.subAdministrativeArea!.trim(),
          if ((placemark.administrativeArea ?? '').trim().isNotEmpty)
            placemark.administrativeArea!.trim(),
          if ((placemark.name ?? '').trim().isNotEmpty) placemark.name!.trim(),
        ];

        for (final rawCandidate in rawCandidates) {
          final normalizedCity = _normalizeCity(rawCandidate);
          _log(
            'launch market resolution source=geocoding raw=$rawCandidate result=${normalizedCity ?? 'unresolved'}',
          );
          if (normalizedCity != null) {
            return normalizedCity;
          }
        }
      }
    } catch (error) {
      _log('launch market resolution failed error=$error');
    }

    return null;
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

  Future<String> _resolveDriverArea({
    Position? position,
    required String city,
    Map<String, dynamic>? profile,
  }) async {
    final normalizedCity = _normalizeCity(city) ?? _selectedLaunchCity;
    final profileMatch = _serviceAreaFromCandidates(
      city: normalizedCity,
      candidates: <String?>[
        profile?['area']?.toString(),
        profile?['zone']?.toString(),
        profile?['community']?.toString(),
      ],
    );
    if (profileMatch.isNotEmpty) {
      return profileMatch;
    }

    if (position == null) {
      return '';
    }

    try {
      final placemarks = await placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );
      for (final placemark in placemarks) {
        final match = _serviceAreaFromCandidates(
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
        if (match.isNotEmpty) {
          return match;
        }
      }
    } catch (error) {
      _log('driver area resolution failed city=$normalizedCity error=$error');
    }

    return '';
  }

  Map<String, String> _buildServiceAreaFields({
    required String city,
    String? area,
  }) {
    return DriverLaunchScope.buildServiceAreaFields(city: city, area: area);
  }

  String? _rideMarketFromData(Map<String, dynamic>? rideData) {
    final serviceArea = _asStringDynamicMap(rideData?['service_area']);
    return _normalizeRideMarket(
      rideData?['market_pool'] ??
          rideData?['market'] ??
          serviceArea?['market'] ??
          rideData?['launch_market_city'] ??
          rideData?['city'],
    );
  }

  String _rideAreaFromData(Map<String, dynamic> rideData, {String? city}) {
    return _normalizeArea(
          rideData['area'] ??
              rideData['zone'] ??
              rideData['community'] ??
              rideData['pickup_area'] ??
              rideData['pickup_zone'] ??
              rideData['pickup_community'],
          city: city,
        ) ??
        '';
  }

  Future<String?> _resolveDriverCity({
    Position? position,
    Map<String, dynamic>? existingProfile,
    bool persistCityToRtdb = true,
  }) async {
    final testLocation = _getNigeriaTestDriverLocation();
    if (testLocation != null) {
      _driverCity = testLocation.city;
      return _driverCity;
    }

    final driverId = _effectiveDriverId;

    try {
      final profile = existingProfile ??
          await _fetchDriverProfile(source: 'resolve_driver_city');
      final profileCityRaw =
          (profile['market'] ?? profile['city'])?.toString().trim() ?? '';
      if (profileCityRaw.isNotEmpty) {
        _log('profile city loaded raw=$profileCityRaw');
        final savedCity = _normalizeCity(profileCityRaw);
        _log(
          'normalized city result source=profile raw=$profileCityRaw result=${savedCity ?? 'unresolved'}',
        );

        if (savedCity != null) {
          _driverCity = savedCity;

          if (driverId.isNotEmpty && persistCityToRtdb) {
            await _driversRef.child(driverId).update({
              'market': savedCity,
              'city': savedCity,
              'updated_at': rtdb.ServerValue.timestamp,
            });
          }

          return _driverCity;
        }
      }

      final currentPosition = position ?? await _getCurrentPositionIfPossible();
      if (currentPosition == null) {
        _log('resolved city failed: no position available');
        return null;
      }

      final detectedCity =
          await _resolveLaunchCityFromPosition(currentPosition);
      if (detectedCity != null) {
        _driverCity = detectedCity;

        if (driverId.isNotEmpty && persistCityToRtdb) {
          await _driversRef.child(driverId).update({
            'market': detectedCity,
            'city': detectedCity,
            'updated_at': rtdb.ServerValue.timestamp,
          });
        }

        return detectedCity;
      }

      _log('resolved city failed: placemarks did not map to supported markets');
    } catch (error) {
      _log('resolved city error=$error');
    }

    return _driverCity;
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

  int _parseCreatedAt(dynamic createdAt) {
    if (createdAt is num) {
      return createdAt.toInt();
    }

    if (createdAt is String) {
      return int.tryParse(createdAt) ?? 0;
    }

    return 0;
  }

  void _showSnackBarSafely(SnackBar snackBar) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }

      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) {
        return;
      }

      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(snackBar);
    });
  }

  void _applySafeStartupFallbackState({required String reason}) {
    if (_hasRenderableActiveRide) {
      _log('startup fallback skipped reason=$reason activeRideRetained=true');
      return;
    }

    _isOnline = false;
    _rideStatus = 'offline';
    _tripStarted = false;
    _driverActiveRideId = null;

    if (mounted) {
      setState(() {
        _isOnline = false;
        _rideStatus = 'offline';
        _tripStarted = false;
        _driverActiveRideId = null;
      });
    }

    _log('startup fallback applied reason=$reason');
  }

  void _surfaceStartupPermissionDenied({
    required String path,
    required Object error,
    StackTrace? stackTrace,
    bool showDefaultState = true,
  }) {
    final authUid = FirebaseAuth.instance.currentUser?.uid ?? 'none';
    final profilePath =
        authUid == 'none' ? 'drivers/(none)' : driverProfilePath(authUid);
    debugPrint(
      '[DRIVER_BACKEND] op=permission_denied source=driver_map_startup '
      'authUid=$authUid driverProfilePath=$profilePath deniedPath=$path error=$error',
    );
    _log('startup permission denied path=$path error=$error');
    if (stackTrace != null) {
      debugPrintStack(
        label: '[DriverMap] startup permission denied stack',
        stackTrace: stackTrace,
      );
    }

    if (showDefaultState) {
      _applySafeStartupFallbackState(reason: 'permission_denied:$path');
    }

    if (_startupPermissionNoticeShown) {
      return;
    }

    _startupPermissionNoticeShown = true;
    _showSnackBarSafely(
      const SnackBar(
        content: Text(
          'Some driver session data could not be loaded. Opening with a safe default state.',
        ),
      ),
    );
  }

  Future<rtdb.DataSnapshot?> _readStartupSnapshot({
    required rtdb.Query query,
    required String path,
  }) async {
    final authUid = FirebaseAuth.instance.currentUser?.uid ?? 'unauthenticated';
    final profilePath = authUid == 'unauthenticated'
        ? 'drivers/(none)'
        : driverProfilePath(authUid);
    debugPrint(
      '[DRIVER_BACKEND] op=rtdb_startup_read authUid=$authUid '
      'driverProfilePath=$profilePath targetPath=$path',
    );
    debugPrint(
      '[RTDB][start] source=driver_map.startup_read path=$path uid=$authUid optional=true',
    );
    try {
      final snapshot = await query.get().timeout(const Duration(seconds: 8));
      debugPrint(
        '[RTDB][success] source=driver_map.startup_read path=$path uid=$authUid optional=true',
      );
      return snapshot;
    } catch (error, stackTrace) {
      debugPrint(
        '[RTDB][error] source=driver_map.startup_read path=$path uid=$authUid optional=true error=$error',
      );
      debugPrint(
        '[DRIVER_BACKEND] op=rtdb_startup_read_failed authUid=$authUid '
        'driverProfilePath=$profilePath targetPath=$path error=$error',
      );
      if (isRealtimeDatabasePermissionDenied(error)) {
        _surfaceStartupPermissionDenied(
          path: path,
          error: error,
          stackTrace: stackTrace,
          showDefaultState: false,
        );
        return null;
      }
      rethrow;
    }
  }

  Future<void> _updateDriverRecordSafely({
    required String driverId,
    required String source,
    required Map<String, Object?> updates,
  }) async {
    try {
      await _driversRef.child(driverId).update(updates);
    } catch (error, stackTrace) {
      if (isRealtimeDatabasePermissionDenied(error)) {
        _surfaceStartupPermissionDenied(
          path: 'drivers/$driverId',
          error: error,
          stackTrace: stackTrace,
          showDefaultState: false,
        );
        _log('driver record update skipped driverId=$driverId source=$source');
        return;
      }
      rethrow;
    }
  }

  Future<void> _setDriverActiveRideMarkerSafely({
    required String driverId,
    required String reason,
    required Map<String, Object?> data,
  }) async {
    _log(
      '[MATCH_DEBUG][CANONICAL_RIDE_ONLY] skip driver_active_ride marker '
      'driverId=$driverId reason=$reason keys=${data.keys.length}',
    );
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

  void _logSafety(String message) {
    debugPrint('[DriverSafety] $message');
  }

  String _normalizedRideStatus(String rawStatus) {
    final normalized = rawStatus.trim().toLowerCase();
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

  bool _isActiveRideStatus(String status) {
    return _kRenderableRideStatuses.contains(status);
  }

  bool _isDriverActiveRideStatus(String status) {
    return status == 'accepted' ||
        status == 'arriving' ||
        status == 'arrived' ||
        status == 'on_trip';
  }

  bool _isArrivedEligibleRideStatus(String status) {
    return status == 'accepted' || status == 'arriving';
  }

  bool _canDriverCancelActiveRide(String status) {
    return status == 'accepted' || status == 'arriving' || status == 'arrived';
  }

  bool _canShowNonPaymentAction({
    required String rideStatus,
    Map<String, dynamic>? rideData,
  }) {
    if (rideData?['trip_completed'] == true) {
      return true;
    }

    final rideStatusFromData = _valueAsText(rideData?['status']);
    final normalizedStatus = _normalizedRideStatus(
      rideStatusFromData.isNotEmpty ? rideStatusFromData : rideStatus,
    );

    return normalizedStatus == 'completed' ||
        normalizedStatus == 'completed_with_payment_issue';
  }

  bool _isValidRideId(String rideId) {
    return rideId.trim().isNotEmpty;
  }

  int _activeRideSessionTimestamp(Map<String, dynamic> ride) {
    for (final key in <String>['accepted_at', 'updated_at', 'created_at']) {
      final timestamp = _parseCreatedAt(ride[key]);
      if (timestamp > 0) {
        return timestamp;
      }
    }

    return 0;
  }

  String _latLngKey(LatLng point) {
    return '${point.latitude.toStringAsFixed(5)},${point.longitude.toStringAsFixed(5)}';
  }

  bool _samePoint(LatLng a, LatLng b, {double toleranceMeters = 5}) {
    return Geolocator.distanceBetween(
          a.latitude,
          a.longitude,
          b.latitude,
          b.longitude,
        ) <=
        toleranceMeters;
  }

  bool _preOnlinePublishGate({
    required String cityToSave,
    required String driverArea,
  }) {
    final failed = <String>[];
    if (cityToSave.trim().isEmpty) {
      failed.add('city');
    }
    if (_effectiveDriverId.trim().isEmpty) {
      failed.add('driver_id');
    }
    final authUid = FirebaseAuth.instance.currentUser?.uid.trim();
    if (authUid == null || authUid.isEmpty) {
      failed.add('auth_uid');
    }
    if (failed.isNotEmpty) {
      _log(
        '[HEALTH] validation result=fail phase=pre_online_publish '
        'failed=${failed.join(',')}',
      );
      return false;
    }
    _log(
      '[HEALTH] validation result=ok phase=pre_online_publish '
      'city=$cityToSave area=${driverArea.isEmpty ? '(empty)' : driverArea}',
    );
    return true;
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

  String _driverAcceptAvailabilityUserMessage(String reason) {
    return switch (reason) {
      'driver_session_lost' =>
        'Your online session timestamp is missing. Go OFFLINE, then GO ONLINE again, and try accepting.',
      'driver_offline' || 'driver_offline_local' =>
        'You look offline to the server. Check your connection, go online again, then try accepting.',
      'driver_unavailable' =>
        'The server still shows you as busy. Wait a few seconds and tap Accept again.',
      'driver_request_listener_missing' =>
        'Ride alerts are not connected. Go OFFLINE, then GO ONLINE again, then try accepting.',
      'driver_trip_in_progress' || 'driver_trip_in_progress_local' =>
        'Finish or leave your other active trip before accepting this one.',
      'driver_auth_mismatch' || 'missing_driver_id' =>
        'Sign in again as this driver account, then try accepting.',
      'driver_record_missing' =>
        'Your driver profile could not be loaded. Check your connection and try again.',
      _ =>
        'Your online session is not healthy enough to accept rides yet. Try GO OFFLINE then GO ONLINE.',
    };
  }

  Future<void> _logDriverHealthDetailed(String phase) async {
    final driverId = _effectiveDriverId;
    if (driverId.isEmpty) {
      _log('[HEALTH] validation result=fail phase=$phase failed=driver_id');
      return;
    }
    try {
      final snapshots = await Future.wait(<Future<rtdb.DataSnapshot>>[
        _driversRef.child(driverId).get(),
      ]);
      final driverRecord = _asStringDynamicMap(snapshots[0].value);
      final activeRideRecord = null;
      if (driverRecord == null) {
        _log(
          '[HEALTH] validation result=fail phase=$phase failed=driver_record_missing',
        );
        return;
      }
      final isOnline =
          _asBool(driverRecord['isOnline']) || _asBool(driverRecord['online']);
      final isOnlineSnake = _asBool(driverRecord['is_online']);
      final hasAvailabilityFlag = driverRecord.containsKey('isAvailable') ||
          driverRecord.containsKey('available');
      final isAvailable = hasAvailabilityFlag
          ? (_asBool(driverRecord['isAvailable']) ||
              _asBool(driverRecord['available']))
          : _normalizedRideStatus(_valueAsText(driverRecord['status'])) ==
              'idle';
      final city = _valueAsText(driverRecord['city']);
      final market = _valueAsText(driverRecord['market']);
      final area = _valueAsText(driverRecord['area']);
      final lastActive = _parseCreatedAt(driverRecord['last_active_at']);
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final locAgeSec = lastActive > 0
          ? ((nowMs - lastActive) / 1000).round()
          : -1;
      final failed = <String>[];
      if (!isOnline && !isOnlineSnake) {
        failed.add('is_online');
      }
      if (hasAvailabilityFlag && !isAvailable) {
        failed.add('available');
      }
      if (city.isEmpty) {
        failed.add('city');
      }
      if (market.isEmpty) {
        failed.add('market');
      }
      if (area.isEmpty) {
        failed.add('area');
      }
      if (lastActive <= 0) {
        failed.add('last_active_at');
      }
      if (lastActive > 0 && locAgeSec > 120) {
        failed.add('location_age_stale');
      }
      final activeRideId = _firstNonEmptyText(<dynamic>[
        activeRideRecord?['ride_id'],
        driverRecord['activeRideId'],
        driverRecord['currentRideId'],
      ]);
      _log(
        '[HEALTH] validation result=${failed.isEmpty ? 'ok' : 'warn'} phase=$phase '
        'failed=${failed.isEmpty ? 'none' : failed.join(',')} '
        'available=$isAvailable isOnline=$isOnline is_online_field=$isOnlineSnake '
        'city=$city market=$market area=$area last_active_age_s=$locAgeSec '
        'activeRideId=$activeRideId',
      );
    } catch (error) {
      _log('[HEALTH] validation read_failed phase=$phase error=$error');
    }
  }

  Future<String?> _driverAvailabilityInvalidReason({
    required String rideId,
    bool requireRideRequestListener = true,
  }) async {
    final driverId = _effectiveDriverId;
    if (driverId.isEmpty) {
      return 'missing_driver_id';
    }

    final authUid = FirebaseAuth.instance.currentUser?.uid.trim();
    if (authUid == null || authUid.isEmpty || authUid != driverId) {
      return 'driver_auth_mismatch';
    }

    if (!_isOnline) {
      return 'driver_offline_local';
    }

    if (requireRideRequestListener && _rideRequestSubscription == null) {
      return 'driver_request_listener_missing';
    }

    final rideKey = rideId.trim();

    final localActiveRideId = _firstNonEmptyText(<dynamic>[
      _driverActiveRideId,
      _currentRideId,
    ]);
    if (localActiveRideId.isNotEmpty && localActiveRideId.trim() != rideKey) {
      return 'driver_trip_in_progress_local';
    }

    final snapshots = await Future.wait(<Future<rtdb.DataSnapshot>>[
      _driversRef.child(driverId).get(),
    ]);

    final driverRecord = _asStringDynamicMap(snapshots[0].value);
    final activeRideRecord = null;
    if (driverRecord == null) {
      return 'driver_record_missing';
    }

    final remoteSessionStarted =
        _parseCreatedAt(driverRecord['online_session_started_at']);
    final effectiveOnlineSession = _onlineSessionStartedAt > 0
        ? _onlineSessionStartedAt
        : remoteSessionStarted;
    if (effectiveOnlineSession <= 0) {
      return 'driver_session_lost';
    }

    final isOnline =
        _asBool(driverRecord['isOnline']) || _asBool(driverRecord['online']);
    if (!isOnline) {
      return 'driver_offline';
    }

    final hasAvailabilityFlag = driverRecord.containsKey('isAvailable') ||
        driverRecord.containsKey('available');
    final isAvailable = hasAvailabilityFlag
        ? (_asBool(driverRecord['isAvailable']) ||
            _asBool(driverRecord['available']))
        : _normalizedRideStatus(_valueAsText(driverRecord['status'])) == 'idle';
    final activeRideId = _firstNonEmptyText(<dynamic>[
      activeRideRecord?['ride_id'],
      driverRecord['activeRideId'],
      driverRecord['currentRideId'],
    ]);
    final activeRideKey = activeRideId.trim();
    final localReservedOrAcceptingSameRide = rideKey.isNotEmpty &&
        (_currentCandidateRideId?.trim() == rideKey ||
            _activePopupRideId?.trim() == rideKey ||
            _acceptingPopupRideId?.trim() == rideKey);

    if (!isAvailable && activeRideKey != rideKey) {
      if (!localReservedOrAcceptingSameRide) {
        return 'driver_unavailable';
      }
    }
    if (activeRideKey.isNotEmpty && activeRideKey != rideKey) {
      return 'driver_trip_in_progress';
    }

    final driverStatus =
        _normalizedRideStatus(_valueAsText(driverRecord['status']));
    if (driverStatus == 'suspended' || driverStatus == 'inactive') {
      return 'driver_status_$driverStatus';
    }
    final sameRidePendingAssignment =
        driverStatus == 'pending_driver_action' && activeRideKey == rideKey;
    if (driverStatus.isNotEmpty &&
        driverStatus != 'idle' &&
        !sameRidePendingAssignment) {
      return 'driver_status_$driverStatus';
    }

    if (_onlineSessionStartedAt <= 0 && remoteSessionStarted > 0) {
      _onlineSessionStartedAt = remoteSessionStarted;
    }

    return null;
  }

  String _valueAsText(dynamic value) {
    return value?.toString().trim() ?? '';
  }

  String _serviceTypeKey(dynamic rawValue) {
    final normalized = _valueAsText(rawValue).toLowerCase();
    return switch (normalized) {
      'dispatch' ||
      'dispatch_delivery' ||
      'dispatch/delivery' =>
        'dispatch_delivery',
      'groceries' || 'groceries_mart' || 'groceries/mart' => 'groceries_mart',
      'restaurants' ||
      'restaurants_food' ||
      'restaurants/food' =>
        'restaurants_food',
      _ => 'ride',
    };
  }

  bool _isSupportedDriverServiceType(String serviceType) {
    return DriverFeatureFlags.activeRequestServiceTypes.contains(serviceType);
  }

  String _serviceTypeLabel(String serviceType) {
    return switch (serviceType) {
      'dispatch_delivery' => 'Dispatch / Delivery',
      'groceries_mart' => 'Groceries / Mart',
      'restaurants_food' => 'Restaurants / Food',
      _ => 'Ride',
    };
  }

  String _servicePopupTitle(String serviceType) {
    return switch (serviceType) {
      'dispatch_delivery' => 'New Dispatch Request',
      'groceries_mart' => 'New Grocery Request',
      'restaurants_food' => 'New Food Request',
      _ => 'New Ride Request',
    };
  }

  String _serviceLifecycleLabel(String serviceType, String status) {
    return switch (serviceType) {
      'dispatch_delivery' => switch (status) {
          'pending_driver_action' => 'Ride matched. Waiting for your action',
          'accepted' => 'Dispatch accepted',
          'arriving' => 'Heading to pickup',
          'arrived' => 'Arrived at pickup',
          'on_trip' => 'Delivery in progress',
          _ => 'Dispatch active',
        },
      'groceries_mart' => switch (status) {
          'pending_driver_action' => 'Ride matched. Waiting for your action',
          'accepted' => 'Grocery request accepted',
          'arriving' => 'Heading to pickup',
          'arrived' => 'Arrived at pickup',
          'on_trip' => 'Mart order in progress',
          _ => 'Grocery request active',
        },
      'restaurants_food' => switch (status) {
          'pending_driver_action' => 'Ride matched. Waiting for your action',
          'accepted' => 'Food request accepted',
          'arriving' => 'Heading to pickup',
          'arrived' => 'Arrived at pickup',
          'on_trip' => 'Food delivery in progress',
          _ => 'Food request active',
        },
      _ => switch (status) {
          'pending_driver_action' => 'Ride matched. Waiting for your action',
          'accepted' => 'Ride accepted',
          'arriving' => 'Heading to pickup',
          'arrived' => 'Arrived at pickup',
          'on_trip' => 'Trip in progress',
          _ => 'Ride active',
        },
    };
  }

  String _serviceStartActionLabel(String serviceType) {
    return switch (serviceType) {
      'dispatch_delivery' => 'Start Delivery',
      'groceries_mart' => 'Start Order',
      'restaurants_food' => 'Start Delivery',
      _ => 'Start Trip',
    };
  }

  String _serviceCompleteActionLabel(String serviceType) {
    return switch (serviceType) {
      'dispatch_delivery' => 'Complete Delivery',
      'groceries_mart' => 'Complete Order',
      'restaurants_food' => 'Complete Delivery',
      _ => 'Complete Trip',
    };
  }

  String _serviceIdLabel(String serviceType) {
    return switch (serviceType) {
      'dispatch_delivery' => 'Dispatch ID',
      'groceries_mart' => 'Request ID',
      'restaurants_food' => 'Request ID',
      _ => 'Ride ID',
    };
  }

  String _destinationLabel(String serviceType) {
    return switch (serviceType) {
      'dispatch_delivery' => 'Dropoff',
      _ => 'Destination',
    };
  }

  bool _isDispatchDeliveryService(String serviceType) {
    return serviceType == 'dispatch_delivery';
  }

  Map<String, dynamic> _dispatchDetailsFromRide(Map<String, dynamic>? ride) {
    return _asStringDynamicMap(ride?['dispatch_details']) ??
        <String, dynamic>{};
  }

  String _dispatchPackageDetails(Map<String, dynamic>? ride) {
    return _valueAsText(_dispatchDetailsFromRide(ride)['package_details']);
  }

  String _dispatchRecipientName(Map<String, dynamic>? ride) {
    return _valueAsText(_dispatchDetailsFromRide(ride)['recipient_name']);
  }

  String _dispatchRecipientPhone(Map<String, dynamic>? ride) {
    return _valueAsText(_dispatchDetailsFromRide(ride)['recipient_phone']);
  }

  String _dispatchPackagePhotoUrl(Map<String, dynamic>? ride) {
    final dispatchDetails = _dispatchDetailsFromRide(ride);
    final nestedUrl = _valueAsText(dispatchDetails['packagePhotoUrl']);
    if (nestedUrl.isNotEmpty) {
      return nestedUrl;
    }
    return _valueAsText(ride?['packagePhotoUrl']);
  }

  String _dispatchDeliveryProofPhotoUrl(Map<String, dynamic>? ride) {
    final dispatchDetails = _dispatchDetailsFromRide(ride);
    final nestedUrl = _valueAsText(dispatchDetails['deliveryProofPhotoUrl']);
    if (nestedUrl.isNotEmpty) {
      return nestedUrl;
    }
    return _valueAsText(ride?['deliveryProofPhotoUrl']);
  }

  String _dispatchDeliveryProofStatus(Map<String, dynamic>? ride) {
    final dispatchDetails = _dispatchDetailsFromRide(ride);
    final status = _valueAsText(dispatchDetails['deliveryProofStatus']);
    if (status.isNotEmpty) {
      return status;
    }
    return _valueAsText(ride?['deliveryProofStatus']);
  }

  Map<String, dynamic> _copyRideWithDispatchDetails(
    Map<String, dynamic> ride,
    Map<String, dynamic> dispatchUpdates,
  ) {
    final nextRide = Map<String, dynamic>.from(ride);
    final nextDispatchDetails = _dispatchDetailsFromRide(ride)
      ..addAll(dispatchUpdates);
    nextRide['dispatch_details'] = nextDispatchDetails;
    return nextRide;
  }

  Map<String, dynamic> _riderTrustSnapshotFromRide(Map<String, dynamic>? ride) {
    return _asStringDynamicMap(ride?['rider_trust_snapshot']) ??
        <String, dynamic>{};
  }

  String _normalizedRiderVerificationStatus(String status) {
    return switch (status.trim().toLowerCase()) {
      'submitted' => 'submitted',
      'checking' => 'checking',
      'manual_review' || 'under_review' => 'manual_review',
      'verified' || 'approved' => 'verified',
      'rejected' || 'failed' => 'rejected',
      _ => 'unverified',
    };
  }

  bool _shouldShowVerifiedBadge({
    required String verificationStatus,
    required bool rawBadge,
  }) {
    return _normalizedRiderVerificationStatus(verificationStatus) ==
            'verified' &&
        rawBadge;
  }

  void _applyRiderTrustSnapshot(
    Map<String, dynamic> rideData, {
    required bool loading,
  }) {
    final riderName = _valueAsText(rideData['rider_name']).isEmpty
        ? 'Rider'
        : _valueAsText(rideData['rider_name']);
    final riderPhone = _valueAsText(rideData['rider_phone']).isNotEmpty
        ? _valueAsText(rideData['rider_phone'])
        : _valueAsText(rideData['phone']);
    final trustSnapshot = _riderTrustSnapshotFromRide(rideData);
    final verificationStatus = _normalizedRiderVerificationStatus(
      _valueAsText(trustSnapshot['verificationStatus']),
    );
    final verifiedBadge = _shouldShowVerifiedBadge(
      verificationStatus: verificationStatus,
      rawBadge: trustSnapshot['verifiedBadge'] == true,
    );
    final rating = _asDouble(trustSnapshot['rating']) ?? 5.0;
    final ratingCount = _asInt(trustSnapshot['ratingCount']) ?? 0;
    final riskStatus = _valueAsText(trustSnapshot['riskStatus']).isEmpty
        ? 'clear'
        : _valueAsText(trustSnapshot['riskStatus']);
    final paymentStatus = _valueAsText(trustSnapshot['paymentStatus']).isEmpty
        ? 'clear'
        : _valueAsText(trustSnapshot['paymentStatus']);
    final cashAccessStatus =
        _valueAsText(trustSnapshot['cashAccessStatus']).isEmpty
            ? 'enabled'
            : _valueAsText(trustSnapshot['cashAccessStatus']);

    void apply() {
      _riderName = riderName;
      _riderPhone = riderPhone;
      _riderVerificationStatus = verificationStatus;
      _riderVerifiedBadge = verifiedBadge;
      _riderRating = rating;
      _riderRatingCount = ratingCount;
      _riderRiskStatus = riskStatus;
      _riderPaymentStatus = paymentStatus;
      _riderCashAccessStatus = cashAccessStatus;
      _riderOutstandingCancellationFeesNgn = 0;
      _riderNonPaymentReports = 0;
      _riderTrustLoading = loading;
    }

    if (mounted) {
      setState(apply);
    } else {
      apply();
    }
  }

  Color _riderVerificationColor(String status) {
    return switch (status.trim().toLowerCase()) {
      'verified' => const Color(0xFF1B7F5A),
      'manual_review' => const Color(0xFFB57A2A),
      'checking' || 'submitted' => const Color(0xFF8A6424),
      'rejected' => const Color(0xFFC44536),
      _ => Colors.black54,
    };
  }

  String _riderVerificationLabel(String status) {
    return switch (status.trim().toLowerCase()) {
      'verified' => 'Verified rider',
      'manual_review' => 'Manual review',
      'checking' => 'Verification checking',
      'submitted' => 'Submitted',
      'rejected' => 'Verification rejected',
      _ => 'Unverified',
    };
  }

  Color _riderRiskColor(String status) {
    return switch (status.trim().toLowerCase()) {
      'watchlist' => const Color(0xFFB57A2A),
      'restricted' => const Color(0xFFC44536),
      'suspended' => const Color(0xFF8B1E1E),
      'blacklisted' => const Color(0xFF111111),
      _ => const Color(0xFF1B7F5A),
    };
  }

  String _riderRiskLabel(String status) {
    return switch (status.trim().toLowerCase()) {
      'watchlist' => 'Watchlist',
      'restricted' => 'Restricted',
      'suspended' => 'Suspended',
      'blacklisted' => 'Blacklisted',
      _ => 'Clear',
    };
  }

  String _paymentMethodFromRide(Map<String, dynamic> rideData) {
    final paymentContext = _asStringDynamicMap(rideData['payment_context']);
    final settlementContext = _asStringDynamicMap(rideData['settlement']);
    final value = _valueAsText(rideData['payment_method']).isNotEmpty
        ? _valueAsText(rideData['payment_method'])
        : _valueAsText(paymentContext?['method']).isNotEmpty
            ? _valueAsText(paymentContext?['method'])
            : _valueAsText(settlementContext?['paymentMethod']);
    return value.isEmpty ? 'unspecified' : value.toLowerCase();
  }

  Future<Map<String, dynamic>> _resolveDriverBusinessModelForSettlement({
    required String source,
  }) async {
    try {
      final profile = await _fetchDriverProfile(source: source);
      return normalizedDriverBusinessModel(profile['businessModel']);
    } catch (error) {
      _log('driver business model fetch failed source=$source error=$error');
      return normalizedDriverBusinessModel(null);
    }
  }

  Map<String, dynamic> _buildRideSettlementRecord({
    required Map<String, dynamic> rideData,
    required Map<String, dynamic> businessModel,
    required String settlementStatus,
    required String completionState,
    required String paymentMethod,
    String reviewStatus = 'not_required',
    int reportedOutstandingAmountNgn = 0,
  }) {
    final grossFare = _asDouble(rideData['fare']) ?? 0;
    return buildDriverTripSettlementRecord(
      grossFare: grossFare,
      businessModel: businessModel,
      paymentMethod: paymentMethod,
      settlementStatus: settlementStatus,
      completionState: completionState,
      reviewStatus: reviewStatus,
      reportedOutstandingAmountNgn: reportedOutstandingAmountNgn,
      city: _rideMarketFromData(rideData) ?? '',
      fareBreakdown: _asStringDynamicMap(rideData['fare_breakdown']),
    );
  }

  String _paymentMethodLabel(String method) {
    return switch (method.trim().toLowerCase()) {
      'cash' => 'Cash',
      'card' => 'Card',
      'bank_transfer' => 'Bank transfer',
      _ => 'Unspecified',
    };
  }

  String? _riderPaymentWarningLabel({
    required String paymentStatus,
    required String cashAccessStatus,
    required int outstandingCancellationFeesNgn,
    required int nonPaymentReports,
  }) {
    if (outstandingCancellationFeesNgn > 0) {
      return 'Outstanding rider fee';
    }
    if (cashAccessStatus == 'restricted' || paymentStatus == 'restricted') {
      return 'Payment review';
    }
    if (cashAccessStatus == 'limited') {
      return 'Limited cash access';
    }
    if (nonPaymentReports > 0) {
      return 'Prior payment issue';
    }
    return null;
  }

  Color _riderPaymentWarningColor({
    required String paymentStatus,
    required String cashAccessStatus,
    required int outstandingCancellationFeesNgn,
    required int nonPaymentReports,
  }) {
    if (outstandingCancellationFeesNgn > 0 ||
        cashAccessStatus == 'restricted' ||
        paymentStatus == 'restricted') {
      return const Color(0xFFC44536);
    }
    if (cashAccessStatus == 'limited' || nonPaymentReports > 0) {
      return const Color(0xFFB57A2A);
    }
    return const Color(0xFF1B7F5A);
  }

  String _normalizeAddressForComparison(String value) {
    return value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  List<LatLng> _routePointsFromBasis(Map<String, dynamic> routeBasis) {
    final rawPoints = routeBasis['expected_route_points'] ??
        routeBasis['expectedRoutePoints'];
    if (rawPoints is! List) {
      return <LatLng>[];
    }

    return rawPoints
        .map(_latLngFromMap)
        .whereType<LatLng>()
        .toList(growable: false);
  }

  List<Map<String, dynamic>> _routePointsPayload(List<LatLng> points) {
    return points
        .map(
          (LatLng point) => <String, dynamic>{
            'lat': point.latitude,
            'lng': point.longitude,
          },
        )
        .toList(growable: false);
  }

  Map<String, dynamic> _driverRouteBasisFromState({
    required Map<String, dynamic> rideData,
    List<LatLng>? driverRoutePointsOverride,
  }) {
    final pickup = _pickupLocation ?? _pickupLatLngFromRideData(rideData);
    final destination =
        _destinationLocation ?? _destinationLatLngFromRideData(rideData);
    final routePoints = driverRoutePointsOverride ?? _expectedRoutePoints;

    return <String, dynamic>{
      'pickup_address': _pickupAddressText,
      'destination_address': _destinationAddressText,
      'pickup': pickup == null
          ? <String, dynamic>{}
          : <String, dynamic>{
              'lat': pickup.latitude,
              'lng': pickup.longitude,
            },
      'destination': destination == null
          ? <String, dynamic>{}
          : <String, dynamic>{
              'lat': destination.latitude,
              'lng': destination.longitude,
            },
      'stops': _tripWaypoints
          .map(
            (_TripWaypoint waypoint) => <String, dynamic>{
              'lat': waypoint.location.latitude,
              'lng': waypoint.location.longitude,
              'address': waypoint.address,
            },
          )
          .toList(growable: false),
      'stop_count': _tripWaypoints.length,
      'expected_route_points': _routePointsPayload(routePoints),
    };
  }

  List<String> _routeMismatchReasons({
    required Map<String, dynamic> rideData,
    List<LatLng>? driverRoutePointsOverride,
  }) {
    final riderRouteBasis = _asStringDynamicMap(rideData['route_basis']);
    if (riderRouteBasis == null || riderRouteBasis.isEmpty) {
      return <String>[];
    }

    final driverRouteBasis = _driverRouteBasisFromState(
      rideData: rideData,
      driverRoutePointsOverride: driverRoutePointsOverride,
    );
    final mismatches = <String>[];

    final riderPickup = _latLngFromMap(riderRouteBasis['pickup']) ??
        _pickupLatLngFromRideData(rideData);
    final driverPickup = _latLngFromMap(driverRouteBasis['pickup']);
    if (riderPickup != null &&
        driverPickup != null &&
        !_samePoint(riderPickup, driverPickup, toleranceMeters: 120)) {
      mismatches.add('pickup_location_mismatch');
    }

    final riderDestination = _latLngFromMap(riderRouteBasis['destination']) ??
        _latLngFromMap(riderRouteBasis['final_destination']) ??
        _destinationLatLngFromRideData(rideData);
    final driverDestination = _latLngFromMap(driverRouteBasis['destination']);
    if (riderDestination != null &&
        driverDestination != null &&
        !_samePoint(
          riderDestination,
          driverDestination,
          toleranceMeters: 120,
        )) {
      mismatches.add('destination_location_mismatch');
    }

    final riderPickupAddress = _normalizeAddressForComparison(
      _valueAsText(riderRouteBasis['pickup_address']),
    );
    final driverPickupAddress = _normalizeAddressForComparison(
      _valueAsText(driverRouteBasis['pickup_address']),
    );
    if (riderPickupAddress.isNotEmpty &&
        driverPickupAddress.isNotEmpty &&
        riderPickupAddress != driverPickupAddress) {
      mismatches.add('pickup_address_mismatch');
    }

    final riderDestinationAddress = _normalizeAddressForComparison(
      _valueAsText(riderRouteBasis['destination_address']),
    );
    final driverDestinationAddress = _normalizeAddressForComparison(
      _valueAsText(driverRouteBasis['destination_address']),
    );
    if (riderDestinationAddress.isNotEmpty &&
        driverDestinationAddress.isNotEmpty &&
        riderDestinationAddress != driverDestinationAddress) {
      mismatches.add('destination_address_mismatch');
    }

    final riderStopCount =
        _asInt(riderRouteBasis['stop_count'] ?? riderRouteBasis['stopCount']) ??
            0;
    final driverStopCount = _tripWaypoints.length;
    if (riderStopCount > 0 &&
        driverStopCount > 0 &&
        riderStopCount != driverStopCount) {
      mismatches.add(
        'stop_count_mismatch rider=$riderStopCount driver=$driverStopCount',
      );
    }

    final riderRoutePoints = _routePointsFromBasis(riderRouteBasis);
    final driverRoutePoints = driverRoutePointsOverride ?? _expectedRoutePoints;
    if (riderRoutePoints.isNotEmpty && driverRoutePoints.isEmpty) {
      mismatches.add('driver_route_points_missing');
    } else if (riderRoutePoints.isNotEmpty && driverRoutePoints.isNotEmpty) {
      if (!_samePoint(
        riderRoutePoints.first,
        driverRoutePoints.first,
        toleranceMeters: 120,
      )) {
        mismatches.add('route_start_mismatch');
      }
      if (!_samePoint(
        riderRoutePoints.last,
        driverRoutePoints.last,
        toleranceMeters: 120,
      )) {
        mismatches.add('route_end_mismatch');
      }
    }

    return mismatches;
  }

  Future<void> _logRouteConsistencyCheckIfNeeded({
    required String rideId,
    required Map<String, dynamic> rideData,
    required String source,
    List<LatLng>? driverRoutePointsOverride,
  }) async {
    final riderId = _valueAsText(rideData['rider_id']);
    final riderRouteBasis = _asStringDynamicMap(rideData['route_basis']);
    if (riderId.isEmpty || riderRouteBasis == null || riderRouteBasis.isEmpty) {
      return;
    }

    final driverRouteBasis = _driverRouteBasisFromState(
      rideData: rideData,
      driverRoutePointsOverride: driverRoutePointsOverride,
    );
    final mismatches = _routeMismatchReasons(
      rideData: rideData,
      driverRoutePointsOverride: driverRoutePointsOverride,
    );
    final driverRoutePoints = driverRoutePointsOverride ?? _expectedRoutePoints;
    final consistencyKey =
        '$rideId|$source|${_tripWaypoints.length}|${driverRoutePoints.length}|${mismatches.join(",")}';
    if (consistencyKey == _lastRouteConsistencyCheckKey) {
      return;
    }
    _lastRouteConsistencyCheckKey = consistencyKey;

    if (mismatches.isEmpty) {
      _log('route consistency aligned rideId=$rideId source=$source');
    } else {
      _log(
        'route consistency mismatch rideId=$rideId source=$source reasons=${mismatches.join(", ")}',
      );
    }

    await _driverTripSafetyService.logRouteConsistencyCheck(
      rideId: rideId,
      riderId: riderId,
      driverId: _effectiveDriverId,
      serviceType: _serviceTypeKey(rideData['service_type']),
      source: source,
      riderRouteBasis: riderRouteBasis,
      driverRouteBasis: driverRouteBasis,
      mismatchReasons: mismatches,
    );
  }

  Future<void> _maybeLogDriverTelemetryCheckpoint() async {
    final rideId = _currentRideId;
    final activeRide = _currentRideData;
    if (rideId == null ||
        activeRide == null ||
        !_isActiveRideStatus(_rideStatus)) {
      return;
    }

    final now = DateTime.now();
    if (_lastTelemetryCheckpointPosition != null &&
        _lastTelemetryCheckpointAt != null) {
      final distanceSinceLast = Geolocator.distanceBetween(
        _lastTelemetryCheckpointPosition!.latitude,
        _lastTelemetryCheckpointPosition!.longitude,
        _driverLocation.latitude,
        _driverLocation.longitude,
      );
      final secondsSinceLast =
          now.difference(_lastTelemetryCheckpointAt!).inSeconds;
      if (distanceSinceLast < 120 && secondsSinceLast < 45) {
        return;
      }
    }

    _lastTelemetryCheckpointPosition = _driverLocation;
    _lastTelemetryCheckpointAt = now;
    await _driverTripSafetyService.logCheckpoint(
      rideId: rideId,
      riderId: _currentRiderIdForRide,
      driverId: _effectiveDriverId,
      serviceType: _serviceTypeKey(activeRide['service_type']),
      status: _rideStatus,
      position: _driverLocation,
      source: 'driver_map',
    );
  }

  bool get _canMonitorRideCalls {
    return _isDriverAuthorizedForCallRide(
      rideId: _currentRideId ?? _driverActiveRideId,
      rideData: _currentRideData,
    );
  }

  bool _isDriverAuthorizedForCallRide({
    required String? rideId,
    Map<String, dynamic>? rideData,
  }) {
    if (!_hasAuthenticatedDriver) {
      return false;
    }

    final driverId = _effectiveDriverId;
    final normalizedRideId = rideId?.trim() ?? '';
    if (driverId.isEmpty || normalizedRideId.isEmpty) {
      return false;
    }

    final activeRideId = _activeDriverRideContextId?.trim() ?? '';
    if (activeRideId.isEmpty || activeRideId != normalizedRideId) {
      return false;
    }

    final effectiveRideData = rideData ?? _currentRideData;
    if (effectiveRideData == null) {
      return false;
    }

    if (_valueAsText(effectiveRideData['driver_id']) != driverId) {
      return false;
    }

    if (_valueAsText(effectiveRideData['rider_id']).isEmpty) {
      return false;
    }

    final canonicalState =
        TripStateMachine.canonicalStateFromSnapshot(effectiveRideData);
    return TripStateMachine.isDriverActiveState(canonicalState);
  }

  bool _canWriteParticipantStateForSession(RideCallSession session) {
    if (!_isDriverAuthorizedForCallRide(rideId: session.rideId)) {
      return false;
    }

    final driverId = _effectiveDriverId;
    final riderId = _currentRiderIdForRide;
    if (driverId.isEmpty || riderId.isEmpty) {
      return false;
    }

    final participantIds = <String>{session.callerId, session.receiverId};
    return participantIds.contains(driverId) &&
        participantIds.contains(riderId);
  }

  Future<bool> _updateParticipantStateSafely({
    required String rideId,
    required String source,
    required bool joined,
    required bool muted,
    required bool speaker,
    bool? foreground,
    String? connectionState,
  }) async {
    final driverId = _effectiveDriverId;
    final normalizedRideId = rideId.trim();
    if (!_hasAuthenticatedDriver ||
        driverId.isEmpty ||
        normalizedRideId.isEmpty) {
      _logRideCall(
        '$source skipped rideId=${normalizedRideId.isEmpty ? 'unknown' : normalizedRideId} '
        'reason=driver_not_authenticated',
      );
      return false;
    }

    if (!_isDriverAuthorizedForCallRide(
      rideId: normalizedRideId,
      rideData: _currentRideData,
    )) {
      _logRideCall(
        '$source skipped rideId=$normalizedRideId reason=no_owned_active_ride',
      );
      return false;
    }

    try {
      await _callService.updateParticipantState(
        rideId: normalizedRideId,
        uid: driverId,
        joined: joined,
        muted: muted,
        speaker: speaker,
        foreground: foreground,
        connectionState: connectionState,
      );
      return true;
    } catch (error, stackTrace) {
      if (isRealtimeDatabasePermissionDenied(error)) {
        _logRideCall(
          '$source skipped rideId=$normalizedRideId reason=permission_denied error=$error',
        );
        debugPrintStack(
          label: '[DriverMap] call participant update skipped',
          stackTrace: stackTrace,
        );
        return false;
      }

      _logRideCall(
        '$source failed rideId=$normalizedRideId error=$error',
      );
      debugPrintStack(
        label: '[DriverMap] call participant update failed',
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  bool _callMatchesCurrentRide(RideCallSession session) {
    if (!_canWriteParticipantStateForSession(session)) {
      return false;
    }

    final driverId = _effectiveDriverId;
    final currentRideId = _activeDriverRideContextId;
    if (currentRideId != null &&
        currentRideId.isNotEmpty &&
        session.rideId != currentRideId) {
      return false;
    }

    final participantIds = <String>{session.callerId, session.receiverId};
    if (!participantIds.contains(driverId)) {
      return false;
    }

    final riderId = _currentRiderIdForRide;
    if (riderId.isEmpty) {
      return false;
    }

    return participantIds.contains(riderId);
  }

  bool _isIncomingCall(RideCallSession session) {
    final driverId = _effectiveDriverId;
    return driverId.isNotEmpty &&
        session.isRinging &&
        session.receiverId == driverId;
  }

  bool _isOutgoingCall(RideCallSession session) {
    final driverId = _effectiveDriverId;
    return driverId.isNotEmpty &&
        session.isRinging &&
        session.callerId == driverId;
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

    _showSnackBarSafely(
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
    final driverId = _effectiveDriverId;
    if (driverId.isEmpty || !_canMonitorRideCalls) {
      return;
    }

    if (_incomingCallSubscription != null) {
      return;
    }

    _logRideReq(
      '[MATCH_DEBUG][QUERY_ATTACH:calls?orderByChild=receiverId&equalTo=$driverId] '
      'incoming_calls onValue',
    );
    _incomingCallSubscription =
        _callService.observeCallsForReceiver(driverId).listen(
      (event) {
        final nextSession = _pickIncomingCallForDriver(
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
        unawaited(_handleCallSnapshotUpdate(nextSession.rideId, nextSession));
      },
      onError: (Object error) {
        _logRideCall('incoming listener error driverId=$driverId error=$error');
      },
    );
  }

  Future<void> _stopIncomingCallMonitoring() async {
    final rideIdForCleanup =
        _callListenerRideId ?? _currentRideId ?? _driverActiveRideId ?? '';
    if (_currentCallSession != null || rideIdForCleanup.isNotEmpty) {
      await _performLocalCallCleanup(
        rideId: rideIdForCleanup,
        logCleanup: false,
      );
    } else {
      await _stopCallRingtone();
      _removeCallOverlayEntry();
    }

    await _callSubscription?.cancel();
    _callSubscription = null;
    _callListenerRideId = null;
    await _incomingCallSubscription?.cancel();
    _incomingCallSubscription = null;
  }

  Future<void> _resyncIncomingCallState() async {
    final driverId = _effectiveDriverId;
    if (driverId.isEmpty || !_canMonitorRideCalls) {
      return;
    }

    // iOS: never run Query.get() on calls?receiverId=… while observeCallsForReceiver
    // (same query) is active — detach first, then fetch, then re-attach.
    if (_incomingCallSubscription != null) {
      _logRideReq(
        '[MATCH_DEBUG][QUERY_DETACH:calls?orderByChild=receiverId&equalTo=$driverId] '
        'incoming_calls resync_prefetch',
      );
      await _incomingCallSubscription?.cancel();
      _incomingCallSubscription = null;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    _logRideReq(
      '[MATCH_DEBUG][QUERY_GET:calls?orderByChild=receiverId&equalTo=$driverId] '
      'fetchCallsForReceiver resync',
    );
    List<RideCallSession> sessions;
    try {
      sessions = await _callService.fetchCallsForReceiver(driverId);
    } catch (error) {
      _logRideCall('incoming resync fetch failed driverId=$driverId error=$error');
      sessions = const <RideCallSession>[];
    }

    if (!mounted || !_canMonitorRideCalls || driverId.isEmpty) {
      return;
    }

    final nextSession = _pickIncomingCallForDriver(sessions);
    if (nextSession == null) {
      final session = _currentCallSession;
      if (session != null && _isIncomingCall(session)) {
        await _resyncCallState(session.rideId);
      }
    } else {
      _startCallListener(nextSession.rideId);
      await _handleCallSnapshotUpdate(nextSession.rideId, nextSession);
    }

    if (!mounted || !_canMonitorRideCalls || driverId.isEmpty) {
      return;
    }
    if (_incomingCallSubscription == null) {
      _startIncomingCallListener();
    }
  }

  RideCallSession? _pickIncomingCallForDriver(List<RideCallSession> sessions) {
    final driverId = _effectiveDriverId;
    if (driverId.isEmpty) {
      return null;
    }

    final activeRideId = _activeDriverRideContextId;
    if (activeRideId == null ||
        activeRideId.isEmpty ||
        !_isDriverAuthorizedForCallRide(rideId: activeRideId)) {
      return null;
    }

    for (final session in sessions) {
      if (session.receiverId != driverId) {
        continue;
      }
      if (!session.isRinging && !session.isAccepted) {
        continue;
      }
      if (session.rideId == activeRideId) {
        return _callMatchesCurrentRide(session) ? session : null;
      }
    }

    return null;
  }

  void _startCallListener(String rideId) {
    if (_callListenerRideId == rideId && _callSubscription != null) {
      return;
    }

    _callSubscription?.cancel();
    _callSubscription = null;
    _callListenerRideId = rideId;

    _logRideReq('[MATCH_DEBUG][QUERY_ATTACH:calls/$rideId] per_ride onValue');
    _callSubscription = _callService.observeCall(rideId).listen(
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
    final normalizedRideId = rideId.trim();
    if (normalizedRideId.isEmpty) {
      return;
    }

    final resumePerRideListener = _callSubscription != null &&
        _callListenerRideId == normalizedRideId;
    if (resumePerRideListener) {
      _logRideReq(
        '[MATCH_DEBUG][QUERY_DETACH:calls/$normalizedRideId] resync_prefetch',
      );
      await _callSubscription?.cancel();
      _callSubscription = null;
      _callListenerRideId = null;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    _logRideReq(
      '[MATCH_DEBUG][QUERY_GET:calls/$normalizedRideId] fetchCall resync',
    );
    final session = await _callService.fetchCall(normalizedRideId);
    if (!mounted) {
      return;
    }

    await _handleCallSnapshotUpdate(normalizedRideId, session);

    if (resumePerRideListener && _canMonitorRideCalls) {
      _startCallListener(normalizedRideId);
    }
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
      await _stopCallRingtone();
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
        await _startCallRingtone();
      } else {
        await _stopCallRingtone();
      }

      _refreshCallOverlayEntry();
      return;
    }

    if (nextSession.isAccepted) {
      _cancelCallRingTimeout();
      _startCallDurationTicker(nextSession.acceptedAtDateTime);
      await _stopCallRingtone();
      unawaited(
        _syncCallForegroundState(
          foreground: _appLifecycleState == AppLifecycleState.resumed,
        ),
      );

      if (previousStatus != RideCallStatus.accepted) {
        _logRideCall('call accepted rideId=$rideId');
      }

      if (!_callJoinedChannel) {
        final driverId = _effectiveDriverId;
        if (driverId.isNotEmpty) {
          await _joinAcceptedCall(rideId: rideId, uid: driverId);
        }
      }

      _refreshCallOverlayEntry();
      return;
    }

    _cancelCallRingTimeout();
    await _stopCallRingtone();

    if (nextSession.status == RideCallStatus.declined &&
        previousStatus != RideCallStatus.declined) {
      _logRideCall('call declined rideId=$rideId');
    } else if (nextSession.status == RideCallStatus.missed &&
        previousStatus != RideCallStatus.missed) {
      _logRideCall('call missed rideId=$rideId');
      final driverId = _effectiveDriverId;
      if (driverId.isNotEmpty && nextSession.receiverId == driverId) {
        if (mounted) {
          _setStateSafely(() {
            _driverMissedCallNotice = true;
          });
        } else {
          _driverMissedCallNotice = true;
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
    if (!_isDriverAuthorizedForCallRide(rideId: rideId)) {
      _logRideCall(
        'join skipped rideId=$rideId reason=no_owned_active_ride',
      );
      return;
    }

    try {
      _logRideCall('[CALL_JOIN_START] rideId=$rideId');
      await _callService.ensureJoinedVoiceChannel(
        channelId: rideId,
        uid: uid,
        speakerOn: _callSpeakerOn,
        muted: _callMuted,
      );
      _callJoinedChannel = true;
      _logRideCall('[CALL_JOIN_OK] rideId=$rideId');
      await _updateParticipantStateSafely(
        source: 'join_accepted_call',
        rideId: rideId,
        joined: true,
        muted: _callMuted,
        speaker: _callSpeakerOn,
        foreground: _appLifecycleState == AppLifecycleState.resumed,
      );
    } catch (error) {
      _logRideCall('[CALL_JOIN_FAIL] rideId=$rideId error=$error');
      final message = error is RideCallException
          ? error.message
          : 'Unable to connect the call right now.';
      await _callService.endAcceptedCall(
        rideId: rideId,
        endedBy: 'system',
      );
      _showSnackBarSafely(
        SnackBar(
          content: Text(message),
        ),
      );
    }
  }

  void _scheduleCallRingTimeout(RideCallSession session) {
    _cancelCallRingTimeout();
    final createdAt = session.createdAtDateTime ?? DateTime.now();
    final remaining = const Duration(seconds: 30).inMilliseconds -
        DateTime.now().difference(createdAt).inMilliseconds;

    if (remaining <= 0) {
      unawaited(
        _callService.markMissedIfUnanswered(rideId: session.rideId),
      );
      return;
    }

    _callRingTimeoutTimer = Timer(
      Duration(milliseconds: remaining),
      () {
        unawaited(
          _callService.markMissedIfUnanswered(rideId: session.rideId),
        );
      },
    );
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
    await _stopCallRingtone();
    _removeCallOverlayEntry();
    await _syncCallForegroundState(foreground: false);
  }

  Future<void> _syncCallForegroundState({
    required bool foreground,
  }) async {
    final session = _currentCallSession;
    if (session == null || session.isTerminal) {
      return;
    }

    await _updateParticipantStateSafely(
      source: 'call_foreground_sync',
      rideId: session.rideId,
      joined: session.isAccepted && _callJoinedChannel,
      muted: _callMuted,
      speaker: _callSpeakerOn,
      foreground: foreground,
    );
  }

  Future<void> _performLocalCallCleanup({
    required String rideId,
    bool logCleanup = true,
  }) async {
    final hadVisibleCallState = _currentCallSession != null ||
        _callJoinedChannel ||
        _alertSoundService.isCallAlertActive ||
        _callOverlayEntry != null ||
        _callDurationTimer != null ||
        _callRingTimeoutTimer != null;
    final driverId = _effectiveDriverId;

    if (driverId.isNotEmpty && rideId.isNotEmpty) {
      unawaited(
        _updateParticipantStateSafely(
          source: 'call_cleanup',
          rideId: rideId,
          joined: false,
          muted: _callMuted,
          speaker: _callSpeakerOn,
          foreground: _appLifecycleState == AppLifecycleState.resumed,
        ),
      );
    }

    _cancelCallRingTimeout();
    _stopCallDurationTicker();
    await _stopCallRingtone();
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

    final rideId = _activeDriverRideContextId;
    final riderId = _currentRiderIdForRide;
    final driverId = _effectiveDriverId;
    if (rideId == null ||
        rideId.isEmpty ||
        !_isDriverAuthorizedForCallRide(rideId: rideId) ||
        !_canStartRideCall ||
        riderId.isEmpty ||
        driverId.isEmpty) {
      _showSnackBarSafely(
        const SnackBar(
          content: Text('Voice call is available only for your active ride.'),
        ),
      );
      return;
    }

    if (mounted) {
      _setStateSafely(() {
        _driverMissedCallNotice = false;
      });
    } else {
      _driverMissedCallNotice = false;
    }

    _setStartingVoiceCall(true);
    try {
      _logRideCall('[CALL_START] rideId=$rideId initiator=driver');
      if (_currentCallSession != null && !_currentCallSession!.isTerminal) {
        _refreshCallOverlayEntry();
        _showSnackBarSafely(
          const SnackBar(
            content: Text('A call is already active for this ride.'),
          ),
        );
        return;
      }

      if (!_callService.hasRtcConfiguration) {
        _logRideCall('[CALL_CONFIG_MISSING] rideId=$rideId');
        _showSnackBarSafely(
          SnackBar(
            content: Text(_callService.unavailableUserMessage),
          ),
        );
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
        await _callService.prefetchAgoraToken(
          channelId: rideId,
          uid: driverId,
        );
        _logRideCall('[CALL_TOKEN_FETCH_OK] rideId=$rideId');
      } on RideCallException catch (error) {
        _logRideCall('[CALL_TOKEN_FETCH_FAIL] rideId=$rideId error=$error');
        _showSnackBarSafely(
          SnackBar(
            content: Text(error.message),
          ),
        );
        return;
      }

      _startCallListener(rideId);
      _logRideCall('outgoing call requested rideId=$rideId by=$driverId');

      final result = await _callService.requestOutgoingVoiceCall(
        rideId: rideId,
        riderId: riderId,
        driverId: driverId,
        startedBy: 'driver',
      );

      if (!result.created) {
        _showSnackBarSafely(
          const SnackBar(
            content: Text('A call is already active for this ride.'),
          ),
        );
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
    if (session == null ||
        !_isIncomingCall(session) ||
        !_canWriteParticipantStateForSession(session)) {
      return;
    }

    if (!_callService.hasRtcConfiguration) {
      _logRideCall('[CALL_CONFIG_MISSING] rideId=${session.rideId}');
      _showSnackBarSafely(
        SnackBar(
          content: Text(_callService.unavailableUserMessage),
        ),
      );
      return;
    }

    final permissionGranted = await _ensureMicrophonePermission(
      actionLabel: 'answer this call',
    );
    if (!permissionGranted) {
      return;
    }

    final driverId = _effectiveDriverId;
    if (driverId.isEmpty) {
      _showSnackBarSafely(
        const SnackBar(
          content:
              Text('Unable to confirm your driver identity for this call.'),
        ),
      );
      return;
    }

    try {
      _logRideCall('[CALL_TOKEN_FETCH_START] rideId=${session.rideId}');
      await _callService.prefetchAgoraToken(
        channelId: session.rideId,
        uid: driverId,
      );
      _logRideCall('[CALL_TOKEN_FETCH_OK] rideId=${session.rideId}');
    } on RideCallException catch (error) {
      _logRideCall('[CALL_TOKEN_FETCH_FAIL] rideId=${session.rideId} error=$error');
      _showSnackBarSafely(
        SnackBar(
          content: Text(error.message),
        ),
      );
      return;
    }

    final accepted = await _callService.acceptCall(
      rideId: session.rideId,
      receiverId: driverId,
    );
    if (!accepted) {
      _showSnackBarSafely(
        const SnackBar(
          content: Text('This call is no longer available.'),
        ),
      );
    }
  }

  Future<void> _declineIncomingCall() async {
    final session = _currentCallSession;
    if (session == null ||
        !_isIncomingCall(session) ||
        !_canWriteParticipantStateForSession(session)) {
      return;
    }

    await _callService.declineCall(
      rideId: session.rideId,
      endedBy: 'driver',
      receiverId: _effectiveDriverId,
    );
  }

  Future<void> _cancelOutgoingCall() async {
    final session = _currentCallSession;
    if (session == null ||
        !_isOutgoingCall(session) ||
        !_canWriteParticipantStateForSession(session)) {
      return;
    }

    await _callService.cancelOutgoingCall(
      rideId: session.rideId,
      endedBy: 'driver',
      callerId: _effectiveDriverId,
    );
  }

  Future<void> _endOngoingCall() async {
    final session = _currentCallSession;
    if (session == null ||
        !session.isAccepted ||
        !_canWriteParticipantStateForSession(session)) {
      return;
    }

    await _callService.endAcceptedCall(
      rideId: session.rideId,
      endedBy: 'driver',
    );
  }

  Future<void> _toggleCallMute() async {
    final session = _currentCallSession;
    final driverId = _effectiveDriverId;
    if (session == null ||
        !session.isAccepted ||
        driverId.isEmpty ||
        !_canWriteParticipantStateForSession(session)) {
      return;
    }

    final nextMuted = !_callMuted;
    _callMuted = nextMuted;
    _callOverlayEntry?.markNeedsBuild();

    try {
      await _callService.setMuted(nextMuted);
      await _updateParticipantStateSafely(
        source: 'toggle_call_mute',
        rideId: session.rideId,
        joined: _callJoinedChannel,
        muted: nextMuted,
        speaker: _callSpeakerOn,
        foreground: _appLifecycleState == AppLifecycleState.resumed,
      );
    } catch (error) {
      _callMuted = !nextMuted;
      _callOverlayEntry?.markNeedsBuild();
      _showSnackBarSafely(
        const SnackBar(
          content: Text('Unable to update mute right now.'),
        ),
      );
      _logRideCall('mute toggle failed rideId=${session.rideId} error=$error');
    }
  }

  Future<void> _toggleSpeaker() async {
    final session = _currentCallSession;
    final driverId = _effectiveDriverId;
    if (session == null ||
        !session.isAccepted ||
        driverId.isEmpty ||
        !_canWriteParticipantStateForSession(session)) {
      return;
    }

    final nextSpeakerState = !_callSpeakerOn;
    _callSpeakerOn = nextSpeakerState;
    _callOverlayEntry?.markNeedsBuild();

    try {
      await _callService.setSpeakerOn(nextSpeakerState);
      await _updateParticipantStateSafely(
        source: 'toggle_call_speaker',
        rideId: session.rideId,
        joined: _callJoinedChannel,
        muted: _callMuted,
        speaker: nextSpeakerState,
        foreground: _appLifecycleState == AppLifecycleState.resumed,
      );
    } catch (error) {
      _callSpeakerOn = !nextSpeakerState;
      _callOverlayEntry?.markNeedsBuild();
      _showSnackBarSafely(
        const SnackBar(
          content: Text('Unable to switch audio output right now.'),
        ),
      );
      _logRideCall(
        'speaker toggle failed rideId=${session.rideId} error=$error',
      );
    }
  }

  Future<void> _endCallForRideLifecycle({
    required String rideId,
  }) async {
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

    final isIncoming = _isIncomingCall(session);
    final isOutgoing = _isOutgoingCall(session);
    final title = _riderName.isEmpty ? 'Rider' : _riderName;
    final subtitle = isIncoming
        ? 'Incoming call'
        : isOutgoing
            ? 'Calling...'
            : _formatCallDuration(_callDuration);

    if (isIncoming) {
      return Material(
        color: const Color(0xFF08111F),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 34),
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Text(
                        'Incoming ride call',
                        style: TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                Container(
                  width: 110,
                  height: 110,
                  decoration: BoxDecoration(
                    color: _gold.withValues(alpha: 0.18),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _gold.withValues(alpha: 0.45),
                      width: 1.5,
                    ),
                  ),
                  child: Icon(
                    Icons.call_rounded,
                    size: 46,
                    color: _gold,
                  ),
                ),
                const SizedBox(height: 28),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  subtitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Colors.white70,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Ride ID: ${session.rideId}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white.withValues(alpha: 0.48),
                  ),
                ),
                const Spacer(),
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
                    const SizedBox(width: 14),
                    Expanded(
                      child: _buildCallActionButton(
                        label: 'Accept',
                        icon: Icons.call_rounded,
                        backgroundColor: const Color(0xFF22A45D),
                        onPressed: _acceptIncomingCall,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Material(
      color: Colors.black.withValues(alpha: 0.58),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Container(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 22),
                decoration: BoxDecoration(
                  color: const Color(0xFF111827),
                  borderRadius: BorderRadius.circular(28),
                  border:
                      Border.all(color: Colors.white.withValues(alpha: 0.08)),
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
                        color: _gold.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Icon(
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
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      subtitle,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: session.isAccepted ? 18 : 16,
                        fontWeight: FontWeight.w600,
                        color: session.isAccepted ? _gold : Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (isOutgoing)
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
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
      ),
      onPressed: () {
        unawaited(onPressed());
      },
      icon: Icon(icon),
      label: Text(
        label,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
    );
  }

  Widget _buildCallControlChip({
    required String label,
    required IconData icon,
    required bool active,
    required Future<void> Function() onTap,
    Color? backgroundColor,
    Color? foregroundColor,
  }) {
    final effectiveBackground = backgroundColor ??
        (active ? _gold.withValues(alpha: 0.18) : const Color(0xFF1F2937));
    final effectiveForeground =
        foregroundColor ?? (active ? _gold : Colors.white70);

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

  bool _isPopupDriverSlotAvailable(String driverId) {
    final trimmed = driverId.trim();
    if (trimmed.isEmpty) {
      return true;
    }
    final lower = trimmed.toLowerCase();
    if (lower == 'waiting') {
      return true;
    }
    return trimmed == _effectiveDriverId;
  }

  ({int value, String field}) _rideExpiryInfo(Map<String, dynamic> rideData) {
    // Single expiry source: request_expires_at, fallback expires_at.
    for (final key in <String>['request_expires_at', 'expires_at', 'expiresAt']) {
      final timestamp = _parseCreatedAt(rideData[key]);
      if (timestamp > 0) {
        return (value: timestamp, field: key);
      }
    }
    return (value: 0, field: 'none');
  }

  int _rideExpiryTimestamp(Map<String, dynamic> rideData) =>
      _rideExpiryInfo(rideData).value;

  int _assignmentExpiryTimestamp(Map<String, dynamic>? rideData) {
    if (rideData == null) {
      return 0;
    }

    for (final key in <String>[
      'assignment_expires_at',
      'driver_response_timeout_at',
    ]) {
      final timestamp = _parseCreatedAt(rideData[key]);
      if (timestamp > 0) {
        return timestamp;
      }
    }

    return 0;
  }

  bool _assignmentHasExpired(Map<String, dynamic>? rideData) {
    final expiresAt = _assignmentExpiryTimestamp(rideData);
    return expiresAt > 0 && DateTime.now().millisecondsSinceEpoch >= expiresAt;
  }

  String _cancelledSettlementStatus(Map<String, dynamic> rideData) {
    final settlement = _asStringDynamicMap(rideData['settlement']);
    final normalizedExistingStatus =
        _valueAsText(settlement?['settlementStatus']).toLowerCase();
    if (normalizedExistingStatus.isNotEmpty &&
        normalizedExistingStatus != 'none' &&
        normalizedExistingStatus != 'reversed') {
      return 'reversed';
    }
    return settlement == null || settlement.isEmpty ? 'none' : 'reversed';
  }

  Map<String, dynamic> _cancelledRideSettlementPayload(
    Map<String, dynamic> rideData,
  ) {
    return <String, dynamic>{
      'settlementStatus': _cancelledSettlementStatus(rideData),
      'completionState': 'trip_cancelled',
      'paymentMethod': _paymentMethodFromRide(rideData),
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

  Map<String, dynamic> _cancelledRideSupplementalUpdate({
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
      'assignment_expires_at': null,
      'driver_response_timeout_at': null,
      'assignment_timeout_ms': null,
      'start_timeout_at': null,
      'route_log_timeout_at': null,
      'settlement': _cancelledRideSettlementPayload(rideData),
      'commission': 0,
      'commissionAmount': 0,
      'driverPayout': 0,
      'netEarning': 0,
      'trip_invalid': invalidTrip,
      'trip_invalid_reason': invalidTrip ? (invalidReason ?? '') : null,
    };
  }

  String _driverRideCancellationMessage(String cancelReason) {
    return switch (cancelReason.trim().toLowerCase()) {
      'driver_start_timeout' =>
        'Trip cancelled because pickup did not start in time.',
      'no_route_logs' =>
        'Trip cancelled because no started-trip route logs were recorded.',
      'driver_offline' ||
      'driver_status_offline' ||
      'driver_session_lost' =>
        'Trip cancelled because the driver session went offline.',
      _ => 'Trip cancelled.',
    };
  }

  Future<bool> _cancelRideForSystemReason({
    required String rideId,
    required Map<String, dynamic> rideData,
    required String reason,
    required String transitionSource,
    required String cancelSource,
    int? effectiveAt,
    bool invalidTrip = false,
    bool showMessage = false,
  }) async {
    final transactionResult =
        await _rideRequestsRef.child(rideId).runTransaction((currentData) {
      final currentRide = _asStringDynamicMap(currentData);
      if (currentRide == null) {
        return rtdb.Transaction.abort();
      }

      final currentCanonicalState =
          TripStateMachine.canonicalStateFromSnapshot(currentRide);
      if (TripStateMachine.isTerminal(currentCanonicalState)) {
        return rtdb.Transaction.abort();
      }

      final updates = TripStateMachine.buildTransitionUpdate(
        currentRide: currentRide,
        nextCanonicalState: TripLifecycleState.tripCancelled,
        timestampValue: rtdb.ServerValue.timestamp,
        transitionSource: transitionSource,
        transitionActor: 'system',
        cancellationActor: 'system',
        cancellationReason: reason,
      )..addAll(
          _cancelledRideSupplementalUpdate(
            rideData: currentRide,
            cancelSource: cancelSource,
            effectiveAt: effectiveAt,
            invalidTrip: invalidTrip,
            invalidReason: reason,
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
    await _commitRideAndDriverState(
      rideId: rideId,
      rideUpdates: <String, dynamic>{
        'driver_state_synced_at': rtdb.ServerValue.timestamp,
      },
      driverUpdates: _buildDriverPresenceUpdate(
        status: _isOnline ? 'idle' : 'offline',
        isAvailable: _isOnline,
      ),
      clearActiveRide: true,
    );
    await _endCallForRideLifecycle(rideId: rideId);
    await _driverTripSafetyService.logRideStateChange(
      rideId: rideId,
      riderId: _valueAsText(committedRide['rider_id']),
      driverId: _effectiveDriverId,
      serviceType: _serviceTypeKey(committedRide['service_type']),
      status: 'cancelled',
      source: transitionSource,
      rideData: committedRide,
    );

    if (_currentRideId == rideId || _driverActiveRideId == rideId) {
      await _clearActiveRideState(
        reason: 'system_cancel_$reason',
        resetTripState: true,
      );
    }

    if (showMessage) {
      _showSnackBarSafely(
        SnackBar(content: Text(_driverRideCancellationMessage(reason))),
      );
    }

    _log(
      'system cancel applied rideId=$rideId reason=$reason source=$transitionSource effectiveAt=${effectiveAt ?? 0}',
    );
    _logCanonicalRideEvent(
      eventName: reason == 'driver_start_timeout' || reason == 'no_route_logs'
          ? 'ride_expired'
          : 'ride_cancelled',
      rideId: rideId,
      rideData: committedRide,
    );
    return true;
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

    final didCancel = await _cancelRideForSystemReason(
      rideId: rideId,
      rideData: rideData,
      reason: decision.reason,
      transitionSource: decision.transitionSource,
      cancelSource: decision.cancelSource,
      effectiveAt: decision.effectiveAt,
      invalidTrip: decision.invalidTrip,
      showMessage: _currentRideId == rideId || _driverActiveRideId == rideId,
    );
    if (didCancel) {
      _log(
        'ride lifecycle timeout enforced source=$source rideId=$rideId reason=${decision.reason}',
      );
    }
    return didCancel;
  }

  Future<bool> _rideHasStartedCheckpointLogs(
    String rideId, {
    Map<String, dynamic>? rideData,
  }) async {
    if (rideData != null) {
      if (rideData['has_started_route_checkpoints'] == true ||
          rideData['hasStartedRouteCheckpoints'] == true) {
        return true;
      }

      final mirroredStartedCheckpointAt = _parseCreatedAt(
        rideData['route_log_trip_started_checkpoint_at'] ??
            rideData['routeLogTripStartedCheckpointAt'],
      );
      if (mirroredStartedCheckpointAt > 0) {
        return true;
      }
    }

    final snapshot = await _rideRequestsRef.root
        .child('trip_route_logs/$rideId/checkpoints')
        .get();
    final checkpoints = _asStringDynamicMap(snapshot.value);
    if (checkpoints == null || checkpoints.isEmpty) {
      return false;
    }

    for (final rawCheckpoint in checkpoints.values) {
      final checkpoint = _asStringDynamicMap(rawCheckpoint);
      final status = _normalizedRideStatus(_valueAsText(checkpoint?['status']));
      if (status == 'on_trip') {
        return true;
      }
    }

    return false;
  }

  LatLng? _latLngFromMap(dynamic raw) {
    final map = _asStringDynamicMap(raw);
    final lat = _asDouble(map?['lat']);
    final lng = _asDouble(map?['lng']);
    if (lat == null ||
        lng == null ||
        !lat.isFinite ||
        !lng.isFinite ||
        lat < -90 ||
        lat > 90 ||
        lng < -180 ||
        lng > 180) {
      return null;
    }

    return LatLng(lat, lng);
  }

  LatLng? _pickupLatLngFromRideData(Map<String, dynamic> rideData) {
    return _latLngFromMap(rideData['pickup']);
  }

  LatLng? _destinationLatLngFromRideData(Map<String, dynamic> rideData) {
    return _latLngFromMap(rideData['destination']) ??
        _latLngFromMap(rideData['dropoff']) ??
        _latLngFromMap(rideData['final_destination']);
  }

  /// RTDB [onValue] can deliver **partial** maps (e.g. only status/trip_state).
  /// Merging with the last full snapshot avoids falsely clearing an active trip,
  /// which used to drop route/chat UI and confuse rider matching.
  Map<String, dynamic> _coalesceRideListenerSnapshot({
    required String rideId,
    required Map<String, dynamic> incoming,
  }) {
    final baseline =
        _currentRideId == rideId ? _currentRideData : null;
    if (baseline == null || baseline.isEmpty) {
      return Map<String, dynamic>.from(incoming);
    }

    final merged = Map<String, dynamic>.from(baseline);
    incoming.forEach((String key, dynamic value) {
      if (value == null) {
        return;
      }
      merged[key] = value;
    });

    for (final key in <String>['pickup', 'destination', 'final_destination']) {
      if (_latLngFromMap(merged[key]) == null) {
        final fallback = baseline[key];
        if (_latLngFromMap(fallback) != null) {
          merged[key] = fallback;
        }
      }
    }

    return merged;
  }

  String _destinationAddressFromRideData(Map<String, dynamic> rideData) {
    final destinationAddress = _valueAsText(rideData['destination_address']);
    if (destinationAddress.isNotEmpty) {
      return destinationAddress;
    }

    final dropoffAddress = _valueAsText(rideData['dropoff_address']);
    if (dropoffAddress.isNotEmpty) {
      return dropoffAddress;
    }

    return _valueAsText(rideData['final_destination_address']);
  }

  String _popupAddressLabel(String address, LatLng point) {
    if (address.trim().isNotEmpty) {
      return address.trim();
    }

    return '${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}';
  }

  /// Open-pool rides back in [searching]/[requested] with a public driver slot
  /// should not stay locally suppressed from an older accept cycle.
  void _maybeUnsuppressOpenPoolRide(String rideId, Map<String, dynamic> rideData) {
    final n = rideId.trim();
    if (n.isEmpty) {
      return;
    }
    if (_foreverSuppressedRidePopupIds.contains(n)) {
      return;
    }
    final canonical = TripStateMachine.canonicalStateFromSnapshot(rideData);
    if (canonical != TripLifecycleState.searchingDriver &&
        canonical != TripLifecycleState.requested) {
      return;
    }
    final did = _valueAsText(rideData['driver_id']);
    final dLower = did.toLowerCase();
    final openSlot = did.isEmpty ||
        dLower == 'waiting' ||
        did == _effectiveDriverId;
    if (!openSlot) {
      return;
    }
    final ui = TripStateMachine.uiStatusFromSnapshot(rideData);
    if (ui != 'searching' && ui != 'requested') {
      return;
    }
    if (_suppressedRidePopupIds.remove(n)) {
      _logRideReq('unsuppressed open-pool rideId=$n ui=$ui');
    }
  }

  void _logPopupServerSkip(
    String rideId,
    Map<String, dynamic>? rideData,
    String reason,
  ) {
    final st = rideData == null ? '?' : _valueAsText(rideData['status']);
    final tripState = rideData == null ? '?' : _valueAsText(rideData['trip_state']);
    final did = rideData == null ? '?' : _valueAsText(rideData['driver_id']);
    final market = rideData == null ? '?' : (_rideMarketFromData(rideData) ?? '?');
    final expectedMarket = _effectiveDriverMarket ?? '?';
    _logRideReq(
      'popup skip rideId=$rideId reason=$reason status=$st trip_state=$tripState '
      'driver_id=$did market=$market expected_market=$expectedMarket',
    );
  }

  /// Final RTDB read before [showDialog]: cancelled / terminal / expired / market / other driver.
  String? _popupHardGateBeforeDialog(String rideId, dynamic rawRide) {
    final rideData = _asStringDynamicMap(rawRide);
    if (rideData == null) {
      return 'payload_null';
    }

    final canonical = TripStateMachine.canonicalStateFromSnapshot(rideData);
    if (TripStateMachine.isTerminal(canonical)) {
      return 'trip_terminal';
    }

    if (TripStateMachine.uiStatusFromSnapshot(rideData) == 'cancelled') {
      return 'ride_cancelled';
    }

    final expiresAt = _rideExpiryTimestamp(rideData);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (expiresAt > 0 && nowMs >= expiresAt) {
      return 'expired';
    }

    final rideMarketRaw = _rideMarketFromData(rideData);
    final rideMarket = rideMarketRaw != null
        ? (_normalizeCity(rideMarketRaw) ?? rideMarketRaw)
        : null;
    // Use the currently bound discovery query market when available so
    // popup filtering stays aligned with the live listener contract.
    final driverMarket = _rideRequestsListenerBoundCity ?? _effectiveDriverMarket;
    if (rideMarket == null ||
        rideMarket.isEmpty ||
        driverMarket == null ||
        driverMarket.isEmpty ||
        rideMarket != driverMarket) {
      return 'market_mismatch';
    }

    final did = _valueAsText(rideData['driver_id']);
    final dLower = did.toLowerCase();
    if (did.isNotEmpty &&
        dLower != 'waiting' &&
        did != _effectiveDriverId) {
      return 'driver_already_assigned';
    }

    return null;
  }

  /// For popup discovery only: treat active trip as [_currentRideId]/[_driverActiveRideId].
  /// Do not treat [_activeRideListenerRideId] alone as blocking (stale listener vs RTDB).
  bool _isDriverSameRideContextBlockingPopup(String rideId) {
    final n = rideId.trim();
    if (n.isEmpty) {
      return false;
    }
    if (_terminalSelfAcceptedRideIds.contains(n)) {
      return true;
    }
    return n == _currentRideId || n == _driverActiveRideId;
  }

  bool _isTerminalSelfAcceptedRide(String rideId) {
    final n = rideId.trim();
    return n.isNotEmpty && _terminalSelfAcceptedRideIds.contains(n);
  }

  String? _popupLocalSkipReason(String rideId) {
    final normalizedId = rideId.trim();
    if (_handledRideIds.contains(normalizedId)) {
      return 'already_handled';
    }
    if (_terminalSelfAcceptedRideIds.contains(normalizedId)) {
      _logRideReq(
        '[MATCH_DEBUG][POPUP_SUPPRESSED_SELF_ACCEPTED] rideId=$normalizedId '
        'reason=terminal_local_accept_lock',
      );
      return 'terminal_self_accepted';
    }
    if (_foreverSuppressedRidePopupIds.contains(normalizedId)) {
      return 'forever_suppressed_after_accept';
    }
    if (_suppressedRidePopupIds.contains(normalizedId)) {
      return 'locally_suppressed_after_accept';
    }

    if (_isDriverSameRideContextBlockingPopup(normalizedId)) {
      return 'already_active_same_ride';
    }

    if (_timedOutRideIds.contains(normalizedId)) {
      return 'timed_out_locally';
    }

    if (_declinedRideIds.contains(normalizedId)) {
      return 'declined_locally';
    }

    if (_acceptingPopupRideId == normalizedId) {
      return 'accept_in_flight';
    }

    if (_presentedRideIds.contains(normalizedId)) {
      return 'already_presented';
    }

    return null;
  }

  void _enqueueRideRequestPopupIfIdleSlot(_MatchedRideRequest ride) {
    final id = ride.rideId.trim();
    if (id.isEmpty) {
      return;
    }
    if (_isTerminalSelfAcceptedRide(id) ||
        _foreverSuppressedRidePopupIds.contains(id)) {
      return;
    }
    if (_isDriverSameRideContextBlockingPopup(id)) {
      return;
    }
    final local = _popupLocalSkipReason(id);
    if (local != null) {
      return;
    }
    if (_activePopupRideId?.trim() == id) {
      return;
    }
    for (final existing in _rideRequestPopupQueue) {
      if (existing.rideId.trim() == id) {
        return;
      }
    }
    while (_rideRequestPopupQueue.length >= _kMaxRideRequestPopupQueue) {
      final dropped = _rideRequestPopupQueue.removeAt(0);
      _logRideReq(
        '[DISCOVERY_QUEUE] dropped_oldest rideId=${dropped.rideId} '
        'cap=$_kMaxRideRequestPopupQueue',
      );
    }
    _rideRequestPopupQueue.add(ride);
    _logRideReq(
      '[DISCOVERY_QUEUE] enqueued rideId=$id depth=${_rideRequestPopupQueue.length}',
    );
  }

  Future<void> _flushRideRequestPopupQueueAfterClose() async {
    if (!mounted || !_isOnline) {
      return;
    }
    if (_popupOpen || _hasActivePopup || _ridePopupOpenPipelineLocked) {
      return;
    }
    if (_rideRequestPopupQueue.isEmpty) {
      return;
    }
    final next = _rideRequestPopupQueue.removeAt(0);
    _logRideReq(
      '[DISCOVERY_QUEUE] flushing next rideId=${next.rideId} '
      'remaining=${_rideRequestPopupQueue.length}',
    );
    await showRideRequestPopup(next);
  }

  bool _isCanonicalOpenForClaim(String canonicalState) {
    return canonicalState == TripLifecycleState.searchingDriver ||
        canonicalState == TripLifecycleState.requested;
  }

  bool _isRideClaimableForDriverAccept(Map<String, dynamic> rideData) {
    final canonicalState = TripStateMachine.canonicalStateFromSnapshot(rideData);
    if (TripStateMachine.isPendingDriverAssignmentState(canonicalState)) {
      final assignedDriver = _valueAsText(rideData['driver_id']);
      return assignedDriver == _effectiveDriverId &&
          !_assignmentHasExpired(rideData);
    }

    if (!_isCanonicalOpenForClaim(canonicalState)) {
      return false;
    }

    final statusRaw = _valueAsText(rideData['status']).trim().toLowerCase();
    final tripStateRaw =
        _valueAsText(rideData['trip_state']).trim().toLowerCase();
    final status = _normalizedRideStatus(statusRaw);
    if (status == 'accepted' ||
        status == 'cancelled' ||
        status == 'expired' ||
        status == 'completed') {
      return false;
    }
    final statusOpen = statusRaw == 'requesting' || statusRaw == 'requested';
    final tripStateOpen =
        tripStateRaw == 'requesting' || tripStateRaw == 'requested';
    if (!statusOpen || !tripStateOpen) {
      return false;
    }

    final rideMarket = (_rideMarketFromData(rideData) ?? '').trim().toLowerCase();
    final driverMarket = (_effectiveDriverMarket ?? '').trim().toLowerCase();
    if (rideMarket.isEmpty || driverMarket.isEmpty || rideMarket != driverMarket) {
      return false;
    }

    final expiresAt = _rideExpiryInfo(rideData).value;
    if (expiresAt > 0 &&
        DateTime.now().millisecondsSinceEpoch >= expiresAt) {
      return false;
    }

    final assignedDriver = _valueAsText(rideData['driver_id']);
    return assignedDriver.isEmpty || assignedDriver.toLowerCase() == 'waiting';
  }

  String _rawTripLifecycleToken(dynamic value) =>
      _valueAsText(value).trim().toLowerCase();

  bool _rideHasOpenDiscoveryLifecycle(Map<String, dynamic> rideData) {
    final statusToken = _rawTripLifecycleToken(rideData['status']);
    final tripToken = _rawTripLifecycleToken(rideData['trip_state']);
    if (statusToken.isNotEmpty &&
        kRtdbOpenPoolDiscoveryLifecycleTokens.contains(statusToken)) {
      return true;
    }
    if (tripToken.isNotEmpty &&
        kRtdbOpenPoolDiscoveryLifecycleTokens.contains(tripToken)) {
      return true;
    }
    return false;
  }

  bool _isOpenPoolDiscoveryLifecycle({
    required String uiStatus,
    required Map<String, dynamic> rideData,
    required String canonicalState,
  }) {
    return uiStatus == 'searching' ||
        uiStatus == 'requested' ||
        _rideHasOpenDiscoveryLifecycle(rideData) ||
        canonicalState == TripLifecycleState.searchingDriver ||
        canonicalState == TripLifecycleState.requested;
  }

  void _logRideRequestDiscoveryRecheckSuppressed(
    String rideId,
    Map<String, dynamic>? rideData,
  ) {
    final n = rideId.trim();
    if (_terminalSelfAcceptedRideIds.contains(n)) {
      _logRideReq(
        '[MATCH_DEBUG][DISCOVERY_IGNORED_ACCEPTED_RIDE] rideId=$n '
        'source=discovery_recheck_suppressed',
      );
      return;
    }
    if (_suppressedRidePopupIds.contains(n)) {
      _logRtdb(
        'popup skipped reason=locally_suppressed_after_accept rideId=$n',
      );
      return;
    }
    if (_isDriverSameRideContextBlockingPopup(n)) {
      _logRtdb('popup skipped reason=already_active_same_ride rideId=$n');
      return;
    }
    final ui = rideData == null
        ? ''
        : TripStateMachine.uiStatusFromSnapshot(rideData);
    final canonical = rideData == null
        ? TripLifecycleState.requested
        : TripStateMachine.canonicalStateFromSnapshot(rideData);
    if (!_isOpenPoolDiscoveryLifecycle(
      uiStatus: ui,
      rideData: rideData ?? const <String, dynamic>{},
      canonicalState: canonical,
    )) {
      _logRtdb(
        'popup skipped reason=status_not_open_discovery_after_recheck rideId=$n '
        'ui=$ui canonical=$canonical',
      );
      return;
    }
    final did = rideData == null ? '' : _valueAsText(rideData['driver_id']);
    final dLower = did.toLowerCase();
    if (did.isNotEmpty &&
        dLower != 'waiting' &&
        did != _effectiveDriverId) {
      _logRtdb('popup skipped reason=driver_already_assigned rideId=$n');
      return;
    }
    final skip = _popupServerSkipReason(
      n,
      rideData,
      marketDiscoveryStage: true,
    );
    _logRtdb(
      'popup skipped reason=${skip ?? 'discovery_recheck_failed'} rideId=$n',
    );
  }

  bool _shouldDismissPopupForServerReason(String? reason) {
    return switch (reason) {
      null => false,
      'dispatch_stale' || 'outside_dispatch_radius' => false,
      _ => true,
    };
  }

  /// Relaxed rules for market-query discovery: open pool only; wrong market,
  /// terminal/cancelled, expired, or missing coords still block.
  String? _popupServerSkipReasonOpenPoolDiscovery(
    String rideId,
    Map<String, dynamic> rideData,
  ) {
    final trimmedId = rideId.trim();
    if (_terminalSelfAcceptedRideIds.contains(trimmedId)) {
      _logRideReq(
        '[MATCH_DEBUG][DISCOVERY_IGNORED_ACCEPTED_RIDE] rideId=$rideId '
        'source=open_pool_discovery',
      );
      _logPopupFix('skip reason=terminal_self_accepted_local rideId=$rideId');
      _logPopupServerSkip(rideId, rideData, 'terminal_self_accepted_local');
      return 'terminal_self_accepted_local';
    }
    if (_foreverSuppressedRidePopupIds.contains(trimmedId)) {
      _logPopupFix('skip reason=forever_suppressed_local rideId=$rideId');
      _logPopupServerSkip(rideId, rideData, 'forever_suppressed_local');
      return 'forever_suppressed_local';
    }
    _logPopupFix(
      'snapshot rideId=$rideId status=${_valueAsText(rideData['status'])} '
      'tripState=${_valueAsText(rideData['trip_state'])}',
    );
    final canonicalState =
        TripStateMachine.canonicalStateFromSnapshot(rideData);
    if (TripStateMachine.isTerminal(canonicalState)) {
      _logPopupFix('skip reason=trip_terminal_state rideId=$rideId');
      _logPopupServerSkip(rideId, rideData, 'trip_terminal_state');
      return 'trip_terminal_state';
    }

    final uiStatus = TripStateMachine.uiStatusFromSnapshot(rideData);
    if (uiStatus == 'cancelled') {
      _logPopupFix('skip reason=ride_cancelled rideId=$rideId');
      _logPopupServerSkip(rideId, rideData, 'ride_cancelled');
      _logRideReq(
        '[MATCH_DEBUG][DRIVER_FILTER] rideId=$rideId status=cancelled qualifies=false reason=ride_cancelled',
      );
      return 'ride_cancelled';
    }

    final rideMarketRaw = _rideMarketFromData(rideData);
    final rideMarket =
        rideMarketRaw != null ? (_normalizeCity(rideMarketRaw) ?? rideMarketRaw) : null;
    // Keep post-discovery popup checks aligned with the active discovery market.
    final driverMarket = _rideRequestsListenerBoundCity ?? _effectiveDriverMarket;
    if (rideMarket == null || rideMarket.isEmpty) {
      _logPopupFix('skip reason=missing_market rideId=$rideId');
      _logPopupServerSkip(rideId, rideData, 'missing_market');
      return 'missing_market';
    }
    if (driverMarket == null ||
        driverMarket.isEmpty ||
        rideMarket != driverMarket) {
      _logPopupFix('skip reason=market_mismatch rideId=$rideId');
      _logPopupServerSkip(rideId, rideData, 'market_mismatch');
      return 'market_mismatch';
    }

    final expiry = _rideExpiryInfo(rideData);
    final expiresAt = expiry.value;
    final nowTimestamp = DateTime.now().millisecondsSinceEpoch;
    if (expiresAt > 0 && nowTimestamp >= expiresAt) {
      _logPopupFix(
        'skip reason=expired rideId=$rideId now_ms=$nowTimestamp expires_at=$expiresAt '
        'delta_ms=${nowTimestamp - expiresAt} expiry_field=${expiry.field}',
      );
      _logPopupServerSkip(rideId, rideData, 'expired');
      _logRideReq(
        '[MATCH_DEBUG][DRIVER_FILTER] rideId=$rideId status=$uiStatus '
        'qualifies=false reason=expired now_ms=$nowTimestamp expires_at=$expiresAt '
        'delta_ms=${nowTimestamp - expiresAt} expiry_field=${expiry.field}',
      );
      return 'expired';
    }

    if (!_isOpenPoolDiscoveryLifecycle(
      uiStatus: uiStatus,
      rideData: rideData,
      canonicalState: canonicalState,
    )) {
      _logPopupFix('skip reason=status_not_active_open rideId=$rideId');
      _logPopupServerSkip(rideId, rideData, 'status_not_searching');
      _logRideReq(
        '[MATCH_DEBUG][DRIVER_FILTER] rideId=$rideId ui=$uiStatus canonical=$canonicalState '
        'raw_status=${_rawTripLifecycleToken(rideData['status'])} '
        'raw_trip_state=${_rawTripLifecycleToken(rideData['trip_state'])} '
        'qualifies=false reason=not_open_discovery_lifecycle',
      );
      return 'status_not_searching';
    }

    final assignedSelf = _valueAsText(rideData['driver_id']);
    if (assignedSelf.isNotEmpty &&
        assignedSelf == _effectiveDriverId &&
        TripStateMachine.isDriverActiveState(canonicalState)) {
      _logPopupFix('skip reason=already_accepted_by_self rideId=$rideId');
      _logPopupServerSkip(rideId, rideData, 'already_accepted_by_self');
      return 'already_accepted_by_self';
    }

    final driverIdValue = _valueAsText(rideData['driver_id']);
    final dTrim = driverIdValue.trim();
    final dLower = dTrim.toLowerCase();
    if (dTrim.isNotEmpty &&
        dLower != 'waiting' &&
        dTrim != _effectiveDriverId) {
      _logPopupFix('skip reason=driver_already_assigned rideId=$rideId');
      _logPopupServerSkip(rideId, rideData, 'driver_already_assigned');
      return 'driver_already_assigned';
    }

    if (_pickupLatLngFromRideData(rideData) == null) {
      _logPopupFix('skip reason=missing_pickup_coordinates rideId=$rideId');
      _logPopupServerSkip(rideId, rideData, 'missing_pickup_coordinates');
      return 'missing_pickup_coordinates';
    }

    if (_destinationLatLngFromRideData(rideData) == null) {
      _logPopupFix('skip reason=missing_destination_coordinates rideId=$rideId');
      _logPopupServerSkip(rideId, rideData, 'missing_destination_coordinates');
      return 'missing_destination_coordinates';
    }

    _logRideReq(
      '[DRIVER_DISCOVERY] rideId=$rideId market=${_rideMarketFromData(rideData)} '
      'trip_state=${rideData['trip_state']} status=${rideData['status']}',
    );

    return null;
  }

  String? _popupServerSkipReason(
    String rideId,
    Map<String, dynamic>? rideData, {
    bool marketDiscoveryStage = false,
  }) {
    if (!_isValidRideId(rideId)) {
      _logPopupServerSkip(rideId, rideData, 'ride_id_missing');
      return 'ride_id_missing';
    }

    if (rideData == null) {
      _logPopupServerSkip(rideId, rideData, 'payload_not_map');
      return 'payload_not_map';
    }

    if (marketDiscoveryStage) {
      // Discovery uses trip_state / ui status from [TripStateMachine]; top-level
      // [status] may be empty on some writes — do not reject solely on that.
      return _popupServerSkipReasonOpenPoolDiscovery(rideId, rideData);
    }

    final statusValue = _valueAsText(rideData['status']);
    final driverIdValue = _valueAsText(rideData['driver_id']);
    final countryValue = _valueAsText(rideData['country']);
    final countryCodeValue = _valueAsText(rideData['country_code']);
    final rideMarketRaw = _rideMarketFromData(rideData);
    final rideMarket =
        rideMarketRaw != null ? (_normalizeCity(rideMarketRaw) ?? rideMarketRaw) : null;
    final driverMarket = _effectiveDriverMarket;

    if (statusValue.isEmpty) {
      _logPopupServerSkip(rideId, rideData, 'missing_status');
      return 'missing_status';
    }

    final canonicalState =
        TripStateMachine.canonicalStateFromSnapshot(rideData);
    final normalizedStatus = TripStateMachine.legacyStatusForCanonical(
      canonicalState,
    );

    if (TripStateMachine.isPendingDriverAssignmentState(canonicalState)) {
      if (driverIdValue != _effectiveDriverId) {
        _logPopupServerSkip(rideId, rideData, 'assigned_to_another_driver');
        return 'assigned_to_another_driver';
      }
      if (_assignmentHasExpired(rideData)) {
        _logPopupServerSkip(rideId, rideData, 'assignment_expired');
        return 'assignment_expired';
      }
      return null;
    } else if (canonicalState != TripLifecycleState.searchingDriver &&
        canonicalState != TripLifecycleState.requested &&
        normalizedStatus != 'searching') {
      _logPopupServerSkip(rideId, rideData, 'status_not_searching');
      return 'status_not_searching';
    }

    if (!TripStateMachine.isPendingDriverAssignmentState(canonicalState) &&
        !_isPopupDriverSlotAvailable(driverIdValue)) {
      _logPopupServerSkip(rideId, rideData, 'driver_unavailable');
      return 'driver_unavailable';
    }

    if (countryValue.isNotEmpty || countryCodeValue.isNotEmpty) {
      final normalizedCountry = countryValue.trim().toLowerCase();
      final normalizedCode = countryCodeValue.trim().toUpperCase();
      var countryOk = false;
      if (normalizedCountry.isNotEmpty) {
        countryOk = normalizedCountry == DriverServiceAreaConfig.countryValue ||
            normalizedCountry ==
                DriverServiceAreaConfig.countryName.toLowerCase();
      }
      if (!countryOk && normalizedCode.isNotEmpty) {
        countryOk =
            normalizedCode == DriverServiceAreaConfig.countryCode.toUpperCase();
      }
      if (!countryOk) {
        _logPopupServerSkip(rideId, rideData, 'country_mismatch');
        return 'country_mismatch';
      }
    }

    if (rideMarket == null || rideMarket.isEmpty) {
      _logPopupServerSkip(rideId, rideData, 'missing_market');
      return 'missing_market';
    }

    if (driverMarket == null ||
        driverMarket.isEmpty ||
        rideMarket != driverMarket) {
      _logPopupServerSkip(rideId, rideData, 'market_mismatch');
      return 'market_mismatch';
    }

    final expiresAt = _rideExpiryTimestamp(rideData);
    final nowTimestamp = DateTime.now().millisecondsSinceEpoch;
    if (expiresAt > 0 && nowTimestamp >= expiresAt) {
      _logPopupServerSkip(rideId, rideData, 'expired');
      return 'expired';
    }

    final createdAt = _parseCreatedAt(rideData['created_at']);
    final requestedAt = _parseCreatedAt(rideData['requested_at']);
    final hasActiveSearchWindow = expiresAt > 0 && nowTimestamp < expiresAt;
    // Server timestamps may still be placeholders in snapshots; a valid future
    // search window proves the request is live for dispatch.
    if (createdAt <= 0 && requestedAt <= 0 && !hasActiveSearchWindow) {
      _logPopupServerSkip(rideId, rideData, 'missing_created_at');
      return 'missing_created_at';
    }

    if (!isRideRequestFreshForDispatch(
      createdAtMs: createdAt,
      requestedAtMs: requestedAt,
      expiresAtMs: expiresAt,
      nowMs: nowTimestamp,
    )) {
      _logPopupServerSkip(rideId, rideData, 'dispatch_stale');
      return 'dispatch_stale';
    }

    if (_pickupLatLngFromRideData(rideData) == null) {
      _logPopupServerSkip(rideId, rideData, 'missing_pickup_coordinates');
      return 'missing_pickup_coordinates';
    }

    if (_destinationLatLngFromRideData(rideData) == null) {
      _logPopupServerSkip(rideId, rideData, 'missing_destination_coordinates');
      return 'missing_destination_coordinates';
    }

    final pickup = _pickupLatLngFromRideData(rideData);
    if (pickup != null) {
      final pickupDistanceMeters = Geolocator.distanceBetween(
        _driverLocation.latitude,
        _driverLocation.longitude,
        pickup.latitude,
        pickup.longitude,
      );
      if (pickupDistanceMeters >
          DriverDispatchConfig.nearbyRequestRadiusMeters) {
        if (_kDebugAllowAllActiveMarketRides) {
          _logRideReq(
            'radius filter bypassed for debug rideId=$rideId distanceMeters=${pickupDistanceMeters.round()} max=${DriverDispatchConfig.nearbyRequestRadiusMeters}',
          );
        } else {
          _logPopupServerSkip(rideId, rideData, 'outside_dispatch_radius');
          return 'outside_dispatch_radius';
        }
      }
    }

    return null;
  }

  String _acceptBlockedReasonFromRideData(
    String rideId,
    Map<String, dynamic>? rideData,
  ) {
    return _popupServerSkipReason(rideId, rideData) ??
        'transaction_not_committed';
  }

  bool _rideAlreadyAcceptedByCurrentDriver(Map<String, dynamic>? rideData) {
    if (rideData == null) {
      return false;
    }

    final canonicalState =
        TripStateMachine.canonicalStateFromSnapshot(rideData);
    return _valueAsText(rideData['driver_id']) == _effectiveDriverId &&
        (TripStateMachine.isDriverActiveState(canonicalState) ||
            TripStateMachine.isPendingDriverAssignmentState(canonicalState));
  }

  String _acceptBlockedMessage({
    required String blockedReason,
    required Map<String, dynamic>? rideData,
    String? rideId,
  }) {
    final rid = rideId?.trim() ?? '';
    if (rid.isNotEmpty && _terminalSelfAcceptedRideIds.contains(rid)) {
      _logRideReq(
        '[MATCH_DEBUG][UNAVAILABLE_SKIPPED_SELF_ACCEPTED] rideId=$rid '
        'source=accept_blocked_message',
      );
      return 'This trip is already linked to you.';
    }
    if (rideData != null && _rideAlreadyAcceptedByCurrentDriver(rideData)) {
      return 'This ride is already confirmed for you.';
    }
    final normalizedStatus = TripStateMachine.uiStatusFromSnapshot(rideData);
    if (normalizedStatus == 'cancelled') {
      return 'The rider cancelled this request before it could be accepted.';
    }

    if (_rideBelongsToAnotherDriver(rideData)) {
      return 'Another driver already accepted this request.';
    }

    return switch (blockedReason) {
      'assignment_expired' ||
      'expired' ||
      'driver_response_timeout' =>
        'This request timed out before it could be confirmed.',
      'driver_session_lost' ||
      'driver_not_ready' =>
        'Your driver session needs to reconnect before you can accept rides.',
      _ => 'This request is no longer available.',
    };
  }

  bool _rideBelongsToAnotherDriver(Map<String, dynamic>? rideData) {
    if (rideData == null) {
      return false;
    }

    final assignedDriverId = _valueAsText(rideData['driver_id']);
    return assignedDriverId.isNotEmpty &&
        assignedDriverId.toLowerCase() != 'waiting' &&
        assignedDriverId != _effectiveDriverId;
  }

  List<Map<String, dynamic>> _orderedStopsFromRide(
      Map<String, dynamic> rideData) {
    final rawStops = rideData['stops'];
    final stops = <Map<String, dynamic>>[];

    if (rawStops is List) {
      for (final value in rawStops) {
        final stop = _asStringDynamicMap(value);
        if (stop != null) {
          stops.add(stop);
        }
      }
    } else if (rawStops is Map) {
      rawStops.forEach((key, value) {
        final stop = _asStringDynamicMap(value);
        if (stop == null) {
          return;
        }

        final normalized = Map<String, dynamic>.from(stop);
        normalized.putIfAbsent('order', () => key);
        stops.add(normalized);
      });
    }

    stops.sort((a, b) {
      final orderA = _asDouble(a['order']) ?? 0;
      final orderB = _asDouble(b['order']) ?? 0;
      return orderA.compareTo(orderB);
    });

    return stops;
  }

  List<_TripWaypoint> _orderedTripWaypoints(Map<String, dynamic> rideData) {
    final waypoints = <_TripWaypoint>[];
    final stopMaps = _orderedStopsFromRide(rideData);

    for (final stop in stopMaps) {
      final location = _latLngFromMap(stop);
      if (location == null) {
        continue;
      }

      waypoints.add(
        _TripWaypoint(
          location: location,
          address: _valueAsText(stop['address']),
        ),
      );
    }

    final destinationLocation = _latLngFromMap(
          rideData['destination'],
        ) ??
        _latLngFromMap(rideData['final_destination']);
    if (destinationLocation != null &&
        (waypoints.isEmpty ||
            !_samePoint(waypoints.last.location, destinationLocation))) {
      waypoints.add(
        _TripWaypoint(
          location: destinationLocation,
          address: _valueAsText(
            rideData['destination_address'],
          ).isNotEmpty
              ? _valueAsText(rideData['destination_address'])
              : _valueAsText(rideData['final_destination_address']),
        ),
      );
    }

    return waypoints;
  }

  List<_TripWaypoint> _remainingTripWaypoints(
      List<_TripWaypoint> allWaypoints) {
    final remaining = List<_TripWaypoint>.from(allWaypoints);
    if (_rideStatus != 'on_trip') {
      return remaining;
    }

    while (remaining.length > 1) {
      final distanceToFirst = Geolocator.distanceBetween(
        _driverLocation.latitude,
        _driverLocation.longitude,
        remaining.first.location.latitude,
        remaining.first.location.longitude,
      );

      if (distanceToFirst > _kWaypointReachedThresholdMeters) {
        break;
      }

      remaining.removeAt(0);
    }

    return remaining;
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
        Marker(
          markerId: const MarkerId('pickup'),
          position: pickup,
          infoWindow: const InfoWindow(title: 'Pickup'),
          icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueGreen,
          ),
        ),
      );
    }

    final visibleWaypoints = _remainingTripWaypoints(_tripWaypoints);
    for (var i = 0; i < visibleWaypoints.length; i++) {
      final isFinal = i == visibleWaypoints.length - 1;
      final waypoint = visibleWaypoints[i];
      _markers.add(
        Marker(
          markerId: MarkerId(isFinal ? 'destination' : 'stop_${i + 1}'),
          position: waypoint.location,
          infoWindow: InfoWindow(
            title: isFinal ? 'Final destination' : 'Stop ${i + 1}',
            snippet: waypoint.address.isEmpty ? null : waypoint.address,
          ),
          icon: BitmapDescriptor.defaultMarkerWithHue(
            isFinal ? BitmapDescriptor.hueRed : BitmapDescriptor.hueOrange,
          ),
        ),
      );
    }
  }

  void _resetAllRideState() {
    _cancelPendingRouteRequests(reason: 'reset_all_ride_state');
    _clearRidePopupTimer();
    _stopActiveRideListener();
    _resetDriverChatState();
    _stopDriverSafetyMonitoring();
    _callSubscription?.cancel();
    _callSubscription = null;
    _callListenerRideId = null;
    _cancelCallRingTimeout();
    _stopCallDurationTicker();
    _removeCallOverlayEntry();
    unawaited(_stopCallRingtone());
    _callAcceptedAt = null;
    _callDuration = Duration.zero;
    _callMuted = false;
    _callSpeakerOn = true;
    _callJoinedChannel = false;
    _currentCallSession = null;
    unawaited(_callService.leaveVoiceChannel());

    void resetRideState() {
      _currentRideId = null;
      _sessionTrackedRideId = null;
      _currentRideData = null;
      _driverActiveRideId = null;
      _currentCandidateRideId = null;
      _activePopupRideId = null;
      _acceptingPopupRideId = null;
      _popupDismissedRideId = null;
      _popupDismissedReason = null;
      _popupOpen = false;
      _hasActivePopup = false;
      _pendingStaleRidePurgeKey = null;
      _rideStatus = _isOnline ? 'idle' : 'offline';
      _tripStarted = false;
      _driverUnreadChatCount = 0;
      _isDriverChatOpen = false;
      _pickupLocation = null;
      _destinationLocation = null;
      _nextNavigationTarget = null;
      _pickupAddressText = '';
      _destinationAddressText = '';
      _riderName = 'Rider';
      _riderPhone = '';
      _riderVerificationStatus = 'unverified';
      _riderRiskStatus = 'clear';
      _riderPaymentStatus = 'clear';
      _riderCashAccessStatus = 'enabled';
      _riderTrustLoading = false;
      _riderVerifiedBadge = false;
      _riderRating = 5.0;
      _riderRatingCount = 0;
      _riderOutstandingCancellationFeesNgn = 0;
      _riderNonPaymentReports = 0;
      _arrivedEnabled = false;
      _deliveryProofUploading = false;
      _deliveryProofUploadProgress = 0;
      _activeSafetyPromptMessage = null;
      _tripWaypoints.clear();
      _expectedRoutePoints.clear();
      _polyLines.clear();
      _markers.clear();
      _loadedRiderProfileKey = null;
      _hasLoggedArrivedEnabled = false;
      _lastRouteBuildKey = '';
      _lastRouteConsistencyCheckKey = '';
      _lastRouteBuiltAt = null;
      _lastRouteOrigin = null;
      _routeOverlayError = null;
      _routeBuildInFlight = false;
      _routeDeviationStrikeCount = 0;
      _lastMoveTime = null;
      _lastSafetyPromptAt = null;
      _lastSafetyCheckLocation = null;
      _lastDriverSpeedSampleAt = null;
      _lastDriverImpliedSpeedKmh = null;
      _lastTelemetryCheckpointPosition = null;
      _lastTelemetryCheckpointAt = null;
      _safetyMonitoringActive = false;
      _updateDriverMarker();
    }

    if (mounted) {
      setState(resetRideState);
      return;
    }

    resetRideState();
  }

  void _stopActiveRideListener() {
    _activeRideSubscription?.cancel();
    _activeRideSubscription = null;
    _activeRideListenerRideId = null;
  }

  bool _hasActiveTripUiState() {
    final hasRideMarkers = _markers.any((marker) {
      final markerId = marker.markerId.value;
      return markerId == 'pickup' ||
          markerId == 'destination' ||
          markerId.startsWith('stop_');
    });

    return _driverActiveRideId != null ||
        _currentRideId != null ||
        _sessionTrackedRideId != null ||
        _currentRideData != null ||
        _activeRideListenerRideId != null ||
        _pickupLocation != null ||
        _destinationLocation != null ||
        _nextNavigationTarget != null ||
        _pickupAddressText.isNotEmpty ||
        _destinationAddressText.isNotEmpty ||
        _riderName != 'Rider' ||
        _riderPhone.isNotEmpty ||
        _tripStarted ||
        _arrivedEnabled ||
        _tripWaypoints.isNotEmpty ||
        _expectedRoutePoints.isNotEmpty ||
        hasRideMarkers ||
        _polyLines.isNotEmpty;
  }

  Future<void> _clearDriverActiveRideNode({
    String? rideId,
    required String reason,
  }) async {
    _driverActiveRideId = null;
    _logRideReq(
      '[MATCH_DEBUG][CANONICAL_RIDE_ONLY] skip driver_active_ride clear '
      'rideId=${rideId ?? 'unknown'} reason=$reason',
    );
  }

  Future<void> _commitRideAndDriverState({
    required String rideId,
    required Map<String, dynamic> rideUpdates,
    required Map<String, Object?> driverUpdates,
    Map<String, Object?>? activeRideUpdates,
    bool clearActiveRide = false,
  }) async {
    final driverId = _effectiveDriverId;
    if (driverId.isEmpty) {
      throw StateError('missing_driver_id');
    }

    final primaryUpdates = <String, Object?>{};
    rideUpdates.forEach((key, value) {
      primaryUpdates['ride_requests/$rideId/$key'] = value;
    });
    driverUpdates.forEach((key, value) {
      primaryUpdates['drivers/$driverId/$key'] = value;
    });

    _logRtdb(
      'multi-path update start rideId=$rideId rideKeys=${rideUpdates.keys.length} '
      'driverKeys=${driverUpdates.keys.length} '
      'secondaryKeys=0 clearActiveRide=$clearActiveRide canonical_only=true',
    );
    try {
      await rtdb.FirebaseDatabase.instance.ref().update(primaryUpdates);
      _logRtdb('multi-path primary update success rideId=$rideId');
    } catch (error) {
      final code = error is FirebaseException ? error.code : 'unknown';
      _logRtdb(
        '[RTDB_WRITE] phase=error operation=multi_path_update_primary '
        'rideId=$rideId uid=$driverId paths=ride_requests+drivers code=$code error=$error',
      );
      _logRtdb('multi-path primary update failure rideId=$rideId error=$error');
      rethrow;
    }

    if (clearActiveRide || activeRideUpdates != null) {
      _logRtdb(
        '[MATCH_DEBUG][CANONICAL_RIDE_ONLY] skipped legacy driver_active_ride '
        'rideId=$rideId clearActiveRide=$clearActiveRide',
      );
    }
  }

  /// Success for [ride_requests] + [drivers] only (no [driver_active_ride],
  /// telemetry, or route logs). Used after accept transaction commits.
  Future<void> _commitCriticalRideAndDriverSnapshot({
    required String rideId,
    required Map<String, dynamic> rideUpdates,
    required Map<String, Object?> driverUpdates,
  }) async {
    final driverId = _effectiveDriverId;
    if (driverId.isEmpty) {
      throw StateError('missing_driver_id');
    }

    final primaryUpdates = <String, Object?>{};
    rideUpdates.forEach((key, value) {
      primaryUpdates['ride_requests/$rideId/$key'] = value;
    });
    driverUpdates.forEach((key, value) {
      primaryUpdates['drivers/$driverId/$key'] = value;
    });

    _logRtdb(
      'critical post-accept update start rideId=$rideId '
      'rideKeys=${rideUpdates.keys.length} driverKeys=${driverUpdates.keys.length}',
    );
    try {
      await rtdb.FirebaseDatabase.instance.ref().update(primaryUpdates);
      _logRtdb('critical post-accept update success rideId=$rideId');
    } catch (error) {
      final code = error is FirebaseException ? error.code : 'unknown';
      _logRtdb(
        '[RTDB_WRITE] phase=error operation=critical_post_accept_update '
        'rideId=$rideId uid=$driverId paths=ride_requests+drivers code=$code error=$error',
      );
      _logRtdb('critical post-accept update failure rideId=$rideId error=$error');
      rethrow;
    }
  }

  void _scheduleOptionalPostAcceptRtdbMirrors({
    required String rideId,
    required String committedStatus,
    required String committedCanonicalForCommit,
    required Map<String, dynamic> rideData,
  }) {
    final driverId = _effectiveDriverId;
    if (driverId.isEmpty) {
      return;
    }

    final latestTripPaths = <String, Object?>{
      'drivers/$driverId/latest_trip_ride_id': rideId,
      'drivers/$driverId/latest_trip_status': committedStatus,
      'drivers/$driverId/latest_trip_trip_state': committedCanonicalForCommit,
      'drivers/$driverId/latest_trip_at': rtdb.ServerValue.timestamp,
    };
    unawaited(
      runOptionalRealtimeDatabaseWrite(
        source: 'driver_map.post_accept_latest_trip',
        path: 'drivers/$driverId',
        operation: 'merge',
        rideId: rideId,
        action: () =>
            rtdb.FirebaseDatabase.instance.ref().update(latestTripPaths),
      ),
    );

    final riderId = _valueAsText(rideData['rider_id']);
    final nowServer = rtdb.ServerValue.timestamp;
    final opsUpdates = <String, Object?>{
      'admin_rides/$rideId/summary/ride_id': rideId,
      'admin_rides/$rideId/summary/rider_id': riderId,
      'admin_rides/$rideId/summary/driver_id': driverId,
      'admin_rides/$rideId/summary/market': _rideMarketFromData(rideData),
      'admin_rides/$rideId/summary/status': committedStatus,
      'admin_rides/$rideId/summary/trip_state': committedCanonicalForCommit,
      'admin_rides/$rideId/summary/payment_method': _valueAsText(rideData['payment_method']),
      'admin_rides/$rideId/summary/payment_status': _valueAsText(rideData['payment_status']),
      'admin_rides/$rideId/summary/settlement_status': _valueAsText(rideData['settlement_status']).isEmpty
          ? 'pending'
          : _valueAsText(rideData['settlement_status']),
      'admin_rides/$rideId/summary/support_status': _valueAsText(rideData['support_status']).isEmpty
          ? 'normal'
          : _valueAsText(rideData['support_status']),
      'admin_rides/$rideId/summary/created_at': rideData['created_at'],
      'admin_rides/$rideId/summary/accepted_at': rideData['accepted_at'] ?? nowServer,
      'admin_rides/$rideId/summary/cancelled_at': rideData['cancelled_at'],
      'admin_rides/$rideId/summary/completed_at': rideData['completed_at'],
      'admin_rides/$rideId/summary/cancel_reason': _valueAsText(rideData['cancel_reason']),
      'admin_rides/$rideId/summary/updated_at': nowServer,
      'support_queue/$rideId/ride_id': rideId,
      'support_queue/$rideId/rider_id': riderId,
      'support_queue/$rideId/driver_id': driverId,
      'support_queue/$rideId/status': committedStatus,
      'support_queue/$rideId/trip_state': committedCanonicalForCommit,
      'support_queue/$rideId/payment_status': _valueAsText(rideData['payment_status']),
      'support_queue/$rideId/settlement_status': _valueAsText(rideData['settlement_status']).isEmpty
          ? 'pending'
          : _valueAsText(rideData['settlement_status']),
      'support_queue/$rideId/support_status': _valueAsText(rideData['support_status']).isEmpty
          ? 'normal'
          : _valueAsText(rideData['support_status']),
      'support_queue/$rideId/created_at': rideData['created_at'],
      'support_queue/$rideId/accepted_at': rideData['accepted_at'] ?? nowServer,
      'support_queue/$rideId/cancelled_at': rideData['cancelled_at'],
      'support_queue/$rideId/completed_at': rideData['completed_at'],
      'support_queue/$rideId/cancel_reason': _valueAsText(rideData['cancel_reason']),
      'support_queue/$rideId/last_event': 'driver_accept',
      'support_queue/$rideId/updated_at': nowServer,
    };
    unawaited(
      runOptionalRealtimeDatabaseWrite(
        source: 'driver_map.post_accept_ops_mirror',
        path: 'admin_rides/$rideId/summary',
        operation: 'merge',
        rideId: rideId,
        action: () => rtdb.FirebaseDatabase.instance.ref().update(opsUpdates),
      ),
    );
  }

  Map<String, Object?> _buildDriverPresenceUpdate({
    required String status,
    String? activeRideId,
    required bool isAvailable,
    bool syncOnlineSessionStartedAt = false,
    bool clearOnlineSessionStartedAt = false,
  }) {
    final normalizedRideId = activeRideId?.trim();
    final hasActiveRide =
        normalizedRideId != null && normalizedRideId.isNotEmpty;
    final publishedOnline = _isOnline;

    return <String, Object?>{
      'isOnline': publishedOnline,
      'is_online': publishedOnline,
      'isAvailable': publishedOnline && isAvailable,
      'available': publishedOnline && isAvailable,
      'status': publishedOnline || hasActiveRide ? status : 'offline',
      'activeRideId': hasActiveRide ? normalizedRideId : null,
      'currentRideId': hasActiveRide ? normalizedRideId : null,
      if (clearOnlineSessionStartedAt)
        'online_session_started_at': null
      else if (syncOnlineSessionStartedAt)
        'online_session_started_at':
            publishedOnline && _onlineSessionStartedAt > 0
                ? _onlineSessionStartedAt
                : null,
      'last_availability_intent': _lastAvailabilityIntentValue,
      'last_active_at': rtdb.ServerValue.timestamp,
      'updated_at': rtdb.ServerValue.timestamp,
    };
  }

  void _syncPendingRidePreviewLocalState({
    required String rideId,
    required Map<String, dynamic> rideData,
  }) {
    void applyState() {
      _currentCandidateRideId = rideId;
      _driverUnreadChatCount = 0;
      _isDriverChatOpen = false;
    }

    if (mounted) {
      setState(applyState);
    } else {
      applyState();
    }

    _applyRideLocationsFromData(rideData);
  }

  Future<_MatchedRideRequest?> _reserveRideForPopup({
    required _MatchedRideRequest ride,
    required String driverName,
    required String car,
    required String plate,
  }) async {
    final availabilityReason = await _driverAvailabilityInvalidReason(
      rideId: ride.rideId,
      requireRideRequestListener: false,
    );
    if (availabilityReason != null) {
      _log(
        '[HEALTH] reserve proceeds with warning rideId=${ride.rideId} '
        'reason=$availabilityReason (no longer blocking reservation)',
      );
    }

    final driverId = _effectiveDriverId;
    if (driverId.isEmpty) {
      return null;
    }

    final requestPath = 'ride_requests/${ride.rideId}';
    final assignmentExpiresAt = DateTime.now().millisecondsSinceEpoch +
        const Duration(seconds: _kRidePopupCountdownSeconds).inMilliseconds;
    final rideRef = _rideRequestsRef.child(ride.rideId);
    String blockedReason = 'unknown';
    final transactionResult = await rideRef.runTransaction((currentData) {
      final currentRide = _asStringDynamicMap(currentData);
      if (currentRide == null) {
        blockedReason = 'ride_missing';
        return rtdb.Transaction.abort();
      }

      final currentCanonicalState = TripStateMachine.canonicalStateFromSnapshot(
        currentRide,
      );
      if (TripStateMachine.isPendingDriverAssignmentState(
              currentCanonicalState) &&
          _valueAsText(currentRide['driver_id']) == driverId &&
          !_assignmentHasExpired(currentRide)) {
        return rtdb.Transaction.success(Map<String, dynamic>.from(currentRide));
      }

      final reservationReason =
          _popupServerSkipReason(ride.rideId, currentRide);
      if (reservationReason != null) {
        blockedReason = reservationReason;
        return rtdb.Transaction.abort();
      }

      final transitionUpdates = TripStateMachine.buildTransitionUpdate(
        currentRide: currentRide,
        nextCanonicalState: TripLifecycleState.pendingDriverAction,
        timestampValue: rtdb.ServerValue.timestamp,
        transitionSource: 'driver_assignment_reserve',
        transitionActor: 'system',
      );

      return rtdb.Transaction.success(
        Map<String, dynamic>.from(currentRide)
          ..addAll(transitionUpdates)
          ..addAll(<String, dynamic>{
            'driver_id': driverId,
            'driver_name': driverName,
            'car': car,
            'plate': plate,
            'status': _kPendingDriverAcceptanceStatus,
            // Drop open-pool index fields so other drivers' discovery queries stay valid.
            'market': null,
            'market_pool': null,
            'driver_notified_at': rtdb.ServerValue.timestamp,
            'driver_matched_at': rtdb.ServerValue.timestamp,
            'matched_driver_id': driverId,
            'assignment_expires_at': assignmentExpiresAt,
            'driver_response_timeout_at': assignmentExpiresAt,
            'assignment_timeout_ms': const Duration(
              seconds: _kRidePopupCountdownSeconds,
            ).inMilliseconds,
          }),
      );
    }, applyLocally: false);

    if (!transactionResult.committed) {
      final latestRideData =
          _asStringDynamicMap(transactionResult.snapshot.value);
      final latestBlockedReason = blockedReason != 'unknown'
          ? blockedReason
          : (_popupServerSkipReason(ride.rideId, latestRideData) ??
              'assignment_not_committed');
      _logRtdb(
        'assignment blocked rideId=${ride.rideId} reason=$latestBlockedReason',
      );
      _logRideReq(
        '[MATCH_DEBUG][DRIVER_DECISION] decision=rejected rideId=${ride.rideId} '
        'status=${latestRideData == null ? 'unknown' : TripStateMachine.uiStatusFromSnapshot(latestRideData)} '
        'reason=$latestBlockedReason stage=reserve_popup',
      );
      return null;
    }

    final reservedRideData =
        _asStringDynamicMap(transactionResult.snapshot.value);
    if (reservedRideData == null) {
      return null;
    }

    final matchedRide = _matchRideForPopup(
      ride.rideId,
      reservedRideData,
      ignoreLocalState: true,
      logSkips: false,
    );
    if (matchedRide == null) {
      await _releaseAssignedRideIfNeeded(
        rideId: ride.rideId,
        reason: 'assignment_payload_invalid',
      );
      return null;
    }

    try {
      await _commitRideAndDriverState(
        rideId: ride.rideId,
        rideUpdates: const <String, dynamic>{},
        driverUpdates: _buildDriverPresenceUpdate(
          status: _kPendingDriverAcceptanceStatus,
          activeRideId: ride.rideId,
          isAvailable: false,
        ),
        activeRideUpdates: <String, Object?>{
          'ride_id': ride.rideId,
          'status': _kPendingDriverAcceptanceStatus,
          'trip_state': TripLifecycleState.pendingDriverAction,
          'updated_at': rtdb.ServerValue.timestamp,
        },
      );
    } catch (error) {
      _logRtdb(
        'assignment sync failed rideId=${ride.rideId} path=$requestPath error=$error',
      );
      await _releaseAssignedRideIfNeeded(
        rideId: ride.rideId,
        reason: 'assignment_state_sync_failed',
      );
      return null;
    }

    _syncPendingRidePreviewLocalState(
        rideId: ride.rideId, rideData: reservedRideData);
    _logRtdb(
      'assignment reserved rideId=${ride.rideId} path=$requestPath driverId=$driverId',
    );
    _logRideReq(
      '[MATCH_DEBUG][DRIVER_DECISION] decision=accepted_for_popup rideId=${ride.rideId} '
      'status=${TripStateMachine.uiStatusFromSnapshot(reservedRideData)} stage=reserve_popup',
    );
    unawaited(
      _driverTripSafetyService
          .logRideStateChange(
        rideId: ride.rideId,
        riderId: _valueAsText(reservedRideData['rider_id']),
        driverId: driverId,
        serviceType: _serviceTypeKey(reservedRideData['service_type']),
        status: _kPendingDriverAcceptanceStatus,
        source: 'driver_popup_reserved',
        rideData: reservedRideData,
      )
          .catchError((Object error) {
        _log(
          'assignment telemetry failed rideId=${ride.rideId} error=$error',
        );
      }),
    );
    return matchedRide;
  }

  Future<bool> _releaseAssignedRideIfNeeded({
    required String rideId,
    required String reason,
    bool resetLocalState = true,
  }) async {
    final driverId = _effectiveDriverId;
    if (driverId.isEmpty || !_isValidRideId(rideId)) {
      return false;
    }

    _logRideReq(
      '[MATCH_DEBUG][ASSIGNMENT_RELEASE] rideId=$rideId driverId=$driverId reason=$reason',
    );

    final rideRef = _rideRequestsRef.child(rideId);
    late final rtdb.TransactionResult transactionResult;
    try {
      transactionResult = await rideRef.runTransaction((currentData) {
        final currentRide = _asStringDynamicMap(currentData);
        if (currentRide == null) {
          return rtdb.Transaction.abort();
        }

        final currentCanonicalState =
            TripStateMachine.canonicalStateFromSnapshot(
          currentRide,
        );
        if (!TripStateMachine.isPendingDriverAssignmentState(
                currentCanonicalState) ||
            _valueAsText(currentRide['driver_id']) != driverId) {
          return rtdb.Transaction.abort();
        }

        final updates = TripStateMachine.buildTransitionUpdate(
          currentRide: currentRide,
          nextCanonicalState: TripLifecycleState.searchingDriver,
          timestampValue: rtdb.ServerValue.timestamp,
          transitionSource: 'driver_assignment_release',
          transitionActor: 'system',
        );

        final reindexMarket = _rideMarketFromData(currentRide);
        return rtdb.Transaction.success(
          Map<String, dynamic>.from(currentRide)
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
              'driver_response_timeout_at': null,
              'assignment_timeout_ms': null,
              'last_assignment_driver_id': driverId,
              'last_assignment_release_reason': reason,
              if (reindexMarket != null && reindexMarket.isNotEmpty) ...<String, dynamic>{
                'market': reindexMarket,
                'market_pool': reindexMarket,
              },
            }),
        );
      }, applyLocally: false);
    } catch (error) {
      final code = error is FirebaseException ? error.code : 'unknown';
      _logRtdb(
        '[RTDB_WRITE] phase=error operation=transaction_assignment_release '
        'rideId=$rideId uid=$driverId path=ride_requests/$rideId code=$code error=$error',
      );
      return false;
    }

    if (!transactionResult.committed) {
      return false;
    }

    try {
      await _commitRideAndDriverState(
        rideId: rideId,
        rideUpdates: const <String, dynamic>{},
        driverUpdates: _buildDriverPresenceUpdate(
          status: 'idle',
          isAvailable: true,
        ),
        clearActiveRide: true,
      );
    } catch (error) {
      final code = error is FirebaseException ? error.code : 'unknown';
      _logRtdb(
        '[RTDB_WRITE] phase=error operation=post_assignment_release_presence '
        'rideId=$rideId uid=$driverId code=$code error=$error',
      );
    }

    if (resetLocalState &&
        (_driverActiveRideId == rideId || _currentRideId == rideId)) {
      await _clearActiveRideState(
        reason: reason,
        resetTripState: true,
      );
    }

    _logRtdb('assignment released rideId=$rideId reason=$reason');
    unawaited(
      _driverTripSafetyService
          .logRideStateChange(
        rideId: rideId,
        riderId: _valueAsText(
          transactionResult.snapshot.child('rider_id').value,
        ),
        driverId: driverId,
        serviceType: _serviceTypeKey(
          transactionResult.snapshot.child('service_type').value,
        ),
        status: 'searching',
        source: 'driver_assignment_release_$reason',
        rideData: _asStringDynamicMap(transactionResult.snapshot.value),
      )
          .catchError((Object error) {
        _log(
          'assignment release telemetry failed rideId=$rideId error=$error',
        );
      }),
    );
    return true;
  }

  Future<void> _startDriverActiveRideListener() async {
    print('DISPATCH_ATTACH_START');
    final driverId = _effectiveDriverId;
    await _driverActiveRideSubscription?.cancel();
    _driverActiveRideSubscription = null;
    if (driverId.isEmpty || !_isOnline || _onlineSessionStartedAt <= 0) {
      return;
    }
    _logRideReq(
      '[MATCH_DEBUG][CANONICAL_RIDE_ONLY] driver_active_ride listener disabled driverId=$driverId',
    );
    try {
      final driverSnapshot = await _driversRef.child(driverId).get();
      final recoveredRide = await _recoverDriverRideFromBackend(
        driverId: driverId,
        driverRecord:
            _asStringDynamicMap(driverSnapshot.value) ?? <String, dynamic>{},
        activeRideMarker: null,
      );
      if (recoveredRide != null) {
        _driverActiveRideId = recoveredRide.rideId;
        print('DISPATCH_ATTACH_SUCCESS');
        _clearDiscoveryPermissionDeniedNotice(
          source: 'dispatch_attach_success_recovered_ride',
        );
        await _listenToActiveRide(recoveredRide.rideId);
      } else {
        print('DISPATCH_ATTACH_SUCCESS');
        _clearDiscoveryPermissionDeniedNotice(
          source: 'dispatch_attach_success_no_active_ride',
        );
      }
    } catch (error) {
      _log(
        '[MATCH_DEBUG][CANONICAL_RIDE_ONLY] active ride recovery failed '
        'driverId=$driverId error=$error',
      );
    }
  }

  void _clearInvalidRideUiState() {
    _resetAllRideState();
    _logGuard('UI cleared due to invalid ride');
    _logUi('cleared invalid ride state');
  }

  Future<void> _cancelRideRequestListener({
    required String reason,
  }) async {
    final hadListener = _rideRequestSubscription != null;
    final previousCity = _rideRequestsListenerBoundCity;
    _rideRequestListenerToken += 1;
    final invalidatedToken = _rideRequestListenerToken;
    if (hadListener) {
      _logRideReq(
        'request listener cancel start reason=$reason token=$invalidatedToken market=${previousCity ?? 'none'}',
      );
      _log(
        'request listener cancel start reason=$reason token=$invalidatedToken market=${previousCity ?? 'none'}',
      );
    }
    final subscription = _rideRequestSubscription;
    _rideRequestSubscription = null;
    _rideDiscoveryListenerHealthy = false;
    _rideRequestsListenerBoundCity = null;
    await subscription?.cancel();
    if (hadListener) {
      _logRideReq(
        '[MATCH_DEBUG][QUERY_DETACH:ride_requests?orderByChild=market_pool&equalTo=${previousCity ?? 'none'}] '
        'discovery reason=$reason',
      );
      _logRideReq(
        '[MATCH_DEBUG][DRIVER_DETACH] reason=$reason token=$invalidatedToken market=${previousCity ?? 'none'}',
      );
      _logRideReq(
        'request listener cancelled reason=$reason token=$invalidatedToken market=${previousCity ?? 'none'}',
      );
      _log(
        'request listener cancelled reason=$reason token=$invalidatedToken market=${previousCity ?? 'none'}',
      );
    }
  }

  Future<void> _hardResetBeforeListenerAttach() async {
    await _releaseLocalPendingAssignmentIfNeeded(
      reason: 'fresh_online_session_reset',
    );
    await _cancelRideRequestListener(
      reason: 'hard_reset_before_listener_attach',
    );
    _stopActiveRideListener();
    await _clearDriverActiveRideNode(reason: 'fresh_online_session');
    _resetAllRideState();

    _lastTripPanelHiddenReason = null;
    _lastValidationBlockedKey = null;
    _presentedRideIds.clear();
    _timedOutRideIds.clear();
    _declinedRideIds.clear();
    _handledRideIds.clear();
    _suppressedRidePopupIds.clear();
    _rideRequestPopupQueue.clear();
    _onlineSessionStartedAt = 0;

    _logRtdb('hard reset before listener attach');
  }

  Future<void> _hardResetToFreshSearchSession({
    required String reason,
  }) async {
    await _clearDriverActiveRideNode(
      rideId: _driverActiveRideId ?? _currentRideId,
      reason: reason,
    );
    await _clearActiveRideState(
      reason: reason,
      resetTripState: true,
    );
  }

  Future<void> _clearActiveRideState({
    required String reason,
    bool resetTripState = false,
  }) async {
    final rideId = _driverActiveRideId ?? _currentRideId ?? _callListenerRideId;
    if (rideId != null && rideId.isNotEmpty) {
      final normalizedReason = reason.toLowerCase();
      if (normalizedReason.contains('cancel') ||
          normalizedReason.contains('complete') ||
          normalizedReason.contains('expired')) {
        await _endCallForRideLifecycle(rideId: rideId);
      } else if (!resetTripState) {
        await _performLocalCallCleanup(
          rideId: rideId,
          logCleanup: false,
        );
      }
    }

    _logRtdb('active ride cleared reason=$reason');
    _logTripPanelHidden(reason);
    if (resetTripState) {
      await _resetTripState();
    } else {
      _clearInvalidRideUiState();
    }

    _logListenerStillActiveWaitingForFreshRides();
  }

  Future<void> _listenToActiveRide(String rideId) async {
    if (_activeRideListenerRideId == rideId &&
        _activeRideSubscription != null) {
      return;
    }

    await _activeRideSubscription?.cancel();
    _activeRideSubscription = null;
    _activeRideListenerRideId = rideId;
    _logRideReq(
      '[MATCH_DEBUG][QUERY_ATTACH:ride_requests/$rideId] active_ride onValue',
    );
    _activeRideSubscription = _rideRequestsRef.child(rideId).onValue.listen(
      (event) async {
        try {
          if (_activeRideListenerRideId != rideId) {
            return;
          }

          final rawRideData = _asStringDynamicMap(event.snapshot.value);
          if (rawRideData == null) {
            _logInvalidRideBlocked(rideId: rideId, reason: 'ride_missing');
            await _clearDriverActiveRideNode(
              rideId: rideId,
              reason: 'ride_missing',
            );
            await _clearActiveRideState(
              reason: 'ride_missing',
              resetTripState: true,
            );
            return;
          }

          final rideData = _coalesceRideListenerSnapshot(
            rideId: rideId,
            incoming: rawRideData,
          );

          final assignedDriverId = _valueAsText(rideData['driver_id']);
          if (assignedDriverId != _effectiveDriverId) {
            _logInvalidRideBlocked(rideId: rideId, reason: 'driver_mismatch');
            await _hardResetToFreshSearchSession(
              reason: 'not_assigned_to_driver',
            );
            return;
          }
          _clearDiscoveryPermissionDeniedNotice(
            source: 'active_ride_listener_valid_assignment',
          );
          if (_serviceTypeKey(_valueAsText(rideData['service_type'])) ==
              'dispatch_delivery') {
            print('DISPATCH_REQUEST_RECEIVED');
          }

          final canonicalState = TripStateMachine.canonicalStateFromSnapshot(
            rideData,
          );
          if (TripStateMachine.isPendingDriverAssignmentState(canonicalState)) {
            if (!_isOnline) {
              _log(
                'pending ride popup suppressed because driver is offline rideId=$rideId',
              );
              return;
            }
            if (_assignmentHasExpired(rideData)) {
              await _releaseAssignedRideIfNeeded(
                rideId: rideId,
                reason: 'assignment_expired',
              );
              return;
            }

            _syncPendingRidePreviewLocalState(
              rideId: rideId,
              rideData: rideData,
            );
            _logRideReq(
              '[MATCH_DEBUG][POPUP_SUPPRESSED_PENDING_STATE] rideId=$rideId '
              'source=active_ride_child_listener_pending',
            );
            return;
          }

          if (await _autoCancelRideForLifecycleTimeoutIfNeeded(
            rideId: rideId,
            rideData: rideData,
            source: 'active_ride_listener',
          )) {
            return;
          }

          final invalidReason = _activeRideInvalidReason(
            rideData,
            rideId: rideId,
          );
          if (invalidReason != null) {
            _logInvalidRideBlocked(rideId: rideId, reason: invalidReason);
            if (invalidReason == 'status_cancelled' && mounted) {
              final by = _valueAsText(rideData['cancelled_by']).toLowerCase();
              final actor = _valueAsText(rideData['cancel_actor']).toLowerCase();
              final riderCancelled = by == 'rider' ||
                  by == 'rider_user' ||
                  by == 'user' ||
                  actor == 'rider' ||
                  actor == 'rider_user' ||
                  actor == 'user';
              _showSnackBarSafely(
                SnackBar(
                  content: Text(
                    riderCancelled
                        ? 'The rider cancelled this trip.'
                        : 'This trip was cancelled.',
                  ),
                ),
              );
            }
            await _clearDriverActiveRideNode(
              rideId: rideId,
              reason: invalidReason,
            );
            await _clearActiveRideState(
              reason: invalidReason,
              resetTripState: true,
            );
            return;
          }

          final status = TripStateMachine.uiStatusFromSnapshot(rideData);
          await _applyActiveRideSnapshot(
            rideId: rideId,
            rideData: rideData,
            status: status,
          );
        } catch (error) {
          _log(
              'active ride snapshot handling failed rideId=$rideId error=$error');
        }
      },
      onError: (Object error) {
        _log('active ride listener error rideId=$rideId error=$error');
      },
    );
  }

  void _applyRideLocationsFromData(Map<String, dynamic> rideData) {
    final pickup = _pickupLatLngFromRideData(rideData);
    final waypoints = _orderedTripWaypoints(rideData);

    _pickupLocation = pickup;
    _tripWaypoints
      ..clear()
      ..addAll(waypoints);
    _destinationLocation =
        waypoints.isNotEmpty ? waypoints.last.location : null;
    _pickupAddressText = _valueAsText(rideData['pickup_address']);
    _destinationAddressText = _destinationAddressFromRideData(rideData);
    _nextNavigationTarget = !_tripStarted
        ? pickup
        : (_remainingTripWaypoints(waypoints).isNotEmpty
            ? _remainingTripWaypoints(waypoints).first.location
            : _destinationLocation);
    _syncTripLocationMarkers();
  }

  Future<void> _loadRiderDetails({
    required String rideId,
    required Map<String, dynamic> rideData,
  }) async {
    final riderId = _valueAsText(rideData['rider_id']);
    final profileKey = '$rideId:$riderId';
    final rideProfileChanged = _loadedRiderProfileKey != profileKey;
    if (rideProfileChanged) {
      _applyRiderTrustSnapshot(
        rideData,
        loading: riderId.isNotEmpty,
      );
    }

    if (_loadedRiderProfileKey == profileKey) {
      return;
    }

    _loadedRiderProfileKey = profileKey;
    if (riderId.isEmpty) {
      _applyRiderTrustSnapshot(rideData, loading: false);
      return;
    }

    try {
      final riderContext = await _riderAccountabilityService.loadRiderContext(
        riderId: riderId,
        rideData: rideData,
      );
      if (_currentRideId != rideId) {
        return;
      }

      if (mounted) {
        setState(() {
          _riderName = riderContext.name;
          _riderPhone = riderContext.phone;
          _riderVerificationStatus = riderContext.verificationStatus;
          _riderVerifiedBadge = riderContext.verifiedBadge;
          _riderRating = riderContext.rating;
          _riderRatingCount = riderContext.ratingCount;
          _riderRiskStatus = riderContext.riskStatus;
          _riderPaymentStatus = riderContext.paymentStatus;
          _riderCashAccessStatus = riderContext.cashAccessStatus;
          _riderOutstandingCancellationFeesNgn =
              riderContext.outstandingCancellationFeesNgn;
          _riderNonPaymentReports = riderContext.nonPaymentReports;
          _riderTrustLoading = false;
        });
      } else {
        _riderName = riderContext.name;
        _riderPhone = riderContext.phone;
        _riderVerificationStatus = riderContext.verificationStatus;
        _riderVerifiedBadge = riderContext.verifiedBadge;
        _riderRating = riderContext.rating;
        _riderRatingCount = riderContext.ratingCount;
        _riderRiskStatus = riderContext.riskStatus;
        _riderPaymentStatus = riderContext.paymentStatus;
        _riderCashAccessStatus = riderContext.cashAccessStatus;
        _riderOutstandingCancellationFeesNgn =
            riderContext.outstandingCancellationFeesNgn;
        _riderNonPaymentReports = riderContext.nonPaymentReports;
        _riderTrustLoading = false;
      }
    } catch (error) {
      _log('rider profile load failed rideId=$rideId error=$error');
      if (_currentRideId != rideId) {
        return;
      }
      if (mounted) {
        setState(() {
          _riderTrustLoading = false;
        });
      } else {
        _riderTrustLoading = false;
      }
    }
  }

  void _clearSafetyPrompt() {
    if (!mounted) {
      _activeSafetyPromptMessage = null;
      return;
    }

    setState(() {
      _activeSafetyPromptMessage = null;
    });
  }

  void _showDriverSafetyPrompt({
    required String rideId,
    required String reason,
    required String message,
  }) {
    final now = DateTime.now();
    if (_lastSafetyPromptAt != null &&
        now.difference(_lastSafetyPromptAt!) < _kSafetyPromptCooldown) {
      return;
    }

    _lastSafetyPromptAt = now;
    _logSafety('prompt shown rideId=$rideId reason=$reason');

    if (mounted) {
      setState(() {
        _activeSafetyPromptMessage = message;
      });
    } else {
      _activeSafetyPromptMessage = message;
    }
  }

  void _clearRidePreview() {
    if (_currentRideId != null) {
      return;
    }

    _cancelPendingRouteRequests(reason: 'clear_ride_preview');
    _pickupLocation = null;
    _destinationLocation = null;
    _nextNavigationTarget = null;
    _pickupAddressText = '';
    _destinationAddressText = '';
    _tripWaypoints.clear();
    _syncTripLocationMarkers();
    _clearRouteOverlay();

    if (mounted) {
      _setStateSafely(() {});
    }
  }

  rtdb.DatabaseReference _rideChatMessagesRef(String rideId) {
    return _rideRequestsRef.root.child(canonicalRideChatMessagesPath(rideId));
  }

  Future<void> _ensureRideChatInitialized({
    required String rideId,
    required Map<String, dynamic> rideData,
  }) async {
    final normalizedRideId = rideId.trim();
    if (normalizedRideId.isEmpty) {
      return;
    }
    final riderId = _valueAsText(rideData['rider_id']);
    final driverId = _valueAsText(rideData['driver_id']);
    final status = TripStateMachine.uiStatusFromSnapshot(rideData);
    final now = rtdb.ServerValue.timestamp;
    _log(
      '[CHAT_INIT] rideId=$normalizedRideId rider_id=$riderId '
      'driver_id=$driverId status=$status',
    );
    await _rideRequestsRef.root.update(<String, dynamic>{
      'ride_chats/$normalizedRideId/ride_id': normalizedRideId,
      'ride_chats/$normalizedRideId/rider_id': riderId,
      'ride_chats/$normalizedRideId/driver_id': driverId,
      'ride_chats/$normalizedRideId/status': status,
      'ride_chats/$normalizedRideId/updated_at': now,
      'ride_chats/$normalizedRideId/created_at': now,
      'ride_requests/$normalizedRideId/chat_ready': true,
      'ride_requests/$normalizedRideId/chat_ready_at': now,
    });
  }

  Future<void> _mirrorDriverChatToTripRouteLog({
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
      _log('chat trip_route_logs mirror skipped rideId=$rideId error=$error');
    }
  }

  void _setDriverChatMessages(
    String rideId,
    List<RideChatMessage> messages,
  ) {
    if (_driverChatListenerRideId != rideId) {
      return;
    }

    _driverChatMessages.value = List<RideChatMessage>.unmodifiable(messages);
  }

  void _confirmDriverOptimisticMessageSent({
    required String rideId,
    required String messageId,
    required String senderId,
    required String text,
    required int clientCreatedAt,
  }) {
    final r = rideId.trim();
    final id = messageId.trim();
    if (_driverChatListenerRideId != r) {
      return;
    }
    final existing = _driverChatMessagesById[id];
    final type = existing?.type ?? 'text';
    final imageUrl = existing?.imageUrl ?? '';
    _driverChatMessagesById[id] = RideChatMessage(
      id: id,
      rideId: r,
      messageId: id,
      senderId: senderId,
      senderRole: 'driver',
      type: type,
      text: text,
      imageUrl: imageUrl,
      createdAt: clientCreatedAt,
      status: 'sent',
      isRead: false,
      localTempId: id,
    );
    _flushDriverChatMessageTable(r);
  }

  void _markDriverOptimisticMessageFailed({
    required String rideId,
    required String messageId,
    required String senderId,
    required String text,
  }) {
    final r = rideId.trim();
    final id = messageId.trim();
    if (_driverChatListenerRideId != r) {
      return;
    }
    final existing = _driverChatMessagesById[id];
    if (existing == null) {
      return;
    }
    _driverChatMessagesById[id] = RideChatMessage(
      id: id,
      rideId: r,
      messageId: id,
      senderId: senderId,
      senderRole: 'driver',
      type: existing.type,
      text: text.isNotEmpty ? text : existing.text,
      imageUrl: existing.imageUrl,
      createdAt: existing.createdAt,
      status: 'failed',
      isRead: false,
      localTempId: existing.localTempId,
    );
    _flushDriverChatMessageTable(r);
  }

  void _flushDriverChatMessageTable(String rideId) {
    if (_driverChatListenerRideId != rideId) {
      return;
    }
    final messages = sortedRideChatMessagesFromMap(_driverChatMessagesById);
    _setDriverChatMessages(rideId, messages);
    _processDriverChatMessagesUpdate(rideId, messages);
  }

  void _processDriverChatMessagesUpdate(
    String rideId,
    List<RideChatMessage> messages,
  ) {
    final driverId = _effectiveDriverId;
    if (driverId.isEmpty) {
      _hasHydratedDriverChatMessages = true;
      _lastDriverChatErrorNoticeKey = null;
      return;
    }

    var unreadCount = 0;
    var receivedNewRiderMessage = false;

    for (final message in messages) {
      if (message.senderRole != 'rider' ||
          message.senderId == driverId) {
        continue;
      }

      if (!message.isRead) {
        unreadCount += 1;
      }

      final messageKey = '$rideId:${message.id}';
      if (_hasHydratedDriverChatMessages) {
        if (_loggedDriverChatMessageIds.add(messageKey)) {
          receivedNewRiderMessage = true;
          _log('message received rideId=$rideId messageId=${message.id}');
        }
      } else {
        _loggedDriverChatMessageIds.add(messageKey);
      }
    }

    if (_hasHydratedDriverChatMessages && receivedNewRiderMessage) {
      unawaited(_playChatNotificationSound());
    }

    if (_isDriverChatOpen) {
      _updateDriverUnreadCount(rideId, 0);
      if (unreadCount > 0) {
        unawaited(
          _markDriverMessagesRead(
            rideId,
            messages: messages,
          ),
        );
      }
    } else {
      _updateDriverUnreadCount(rideId, unreadCount);

      if (_hasHydratedDriverChatMessages &&
          receivedNewRiderMessage &&
          mounted) {
        _showDriverIncomingChatNotice();
      }
    }

    _hasHydratedDriverChatMessages = true;
    _lastDriverChatErrorNoticeKey = null;
  }

  void _onDriverChatChildEvent(String rideId, rtdb.DatabaseEvent event) {
    try {
      if (_driverChatListenerRideId != rideId) {
        return;
      }

      final messageId = event.snapshot.key?.trim() ?? '';
      if (messageId.isEmpty) {
        return;
      }

      final parsed = parseRideChatMessageEntry(
        rideId: rideId,
        messageId: messageId,
        raw: event.snapshot.value,
      );
      if (parsed != null) {
        _driverChatMessagesById[messageId] = parsed;
      }

      _flushDriverChatMessageTable(rideId);
    } catch (error) {
      _reportDriverChatIssue(
        rideId,
        'listener_child_event_failed',
        error: error,
      );
    }
  }

  void _onDriverChatChildRemoved(String rideId, rtdb.DatabaseEvent event) {
    try {
      if (_driverChatListenerRideId != rideId) {
        return;
      }
      final messageId = event.snapshot.key?.trim() ?? '';
      if (messageId.isEmpty) {
        return;
      }
      _driverChatMessagesById.remove(messageId);
      _flushDriverChatMessageTable(rideId);
    } catch (error) {
      _reportDriverChatIssue(
        rideId,
        'listener_child_removed_failed',
        error: error,
      );
    }
  }

  void _reportDriverChatIssue(
    String rideId,
    String message, {
    Object? error,
  }) {
    final errorSuffix = error == null ? '' : ':$error';
    final issueKey = '$rideId:$message$errorSuffix';
    _log('driver chat issue rideId=$rideId message=$message$errorSuffix');
    if (_lastDriverChatErrorNoticeKey == issueKey) {
      return;
    }

    _lastDriverChatErrorNoticeKey = issueKey;
    if (error != null && isRealtimeDatabasePermissionDenied(error)) {
      _log('[CHAT_PERMISSION_DENIED] rideId=$rideId message=$message error=$error');
    }
    if (_isDriverChatSessionActive(rideId)) {
      _showSnackBarSafely(
        const SnackBar(
          content: Text('Chat is syncing. Please retry in a moment.'),
        ),
      );
    }
  }

  Future<void> _markDriverMessagesRead(
    String rideId, {
    List<RideChatMessage>? messages,
  }) async {
    final updates = <String, dynamic>{};
    final currentMessages = messages ?? _driverChatMessages.value;

    for (final message in currentMessages) {
      final isIncomingRiderMessage = message.senderRole == 'rider' &&
          message.senderId != _effectiveDriverId &&
          !message.isRead;
      if (!isIncomingRiderMessage) {
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
      _reportDriverChatIssue(
        rideId,
        'mark_read_failed',
        error: error,
      );
    }
  }

  void _updateDriverUnreadCount(String rideId, int unreadCount) {
    if (_driverUnreadChatCount == unreadCount) {
      return;
    }

    if (mounted) {
      _setStateSafely(() {
        _driverUnreadChatCount = unreadCount;
      });
    } else {
      _driverUnreadChatCount = unreadCount;
    }

    _log(
      '[CHAT_UNREAD_INC] role=driver rideId=$rideId uid=$_effectiveDriverId unreadCount=$unreadCount',
    );
  }

  void _resetDriverUnreadCount(String rideId) {
    _updateDriverUnreadCount(rideId, 0);
    _log(
      '[CHAT_UNREAD_CLEAR] role=driver rideId=$rideId uid=$_effectiveDriverId unreadCount=0',
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
      _log('ride chat unread clear failed rideId=$rideId error=$error');
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
      _log(
        'ride chat unread bump failed rideId=$rideId recipient=$rid error=$error',
      );
    }
  }

  void _resetDriverChatState({bool stopListener = true}) {
    if (stopListener) {
      _stopDriverChatListener();
    }
    _driverChatListenerRideId = null;
    _hasHydratedDriverChatMessages = false;
    _lastDriverChatErrorNoticeKey = null;
    _loggedDriverChatMessageIds.clear();
    _driverChatMessages.value = const <RideChatMessage>[];
    _driverUnreadChatCount = 0;
    _driverMissedCallNotice = false;
    _isDriverChatOpen = false;
  }

  void _stopDriverChatListener() {
    for (final sub in _driverChatSubscriptions) {
      sub.cancel();
    }
    _driverChatSubscriptions.clear();
    _driverChatMessagesById.clear();
    _driverChatListenerRideId = null;
  }

  void _clearRidePopupTimer() {
    _ridePopupTimer?.cancel();
    _ridePopupTimer = null;
  }

  void _startDriverChatListener(String rideId) {
    if (_driverChatListenerRideId == rideId &&
        _driverChatSubscriptions.isNotEmpty) {
      return;
    }

    _stopDriverChatListener();
    _driverChatListenerRideId = rideId;
    _hasHydratedDriverChatMessages = false;
    _lastDriverChatErrorNoticeKey = null;
    _loggedDriverChatMessageIds.clear();
    _driverChatMessages.value = const <RideChatMessage>[];
    _driverChatMessagesById.clear();
    _log(
      '[CHAT_ATTACH] role=driver rideId=$rideId '
      'path=${canonicalRideChatMessagesPath(rideId)}',
    );

    final ref = _rideChatMessagesRef(rideId).orderByChild('timestamp');
    _driverChatSubscriptions.add(
      ref.onValue.listen(
        (event) {
          final parsed = parseRideChatSnapshot(
            rideId: rideId,
            raw: event.snapshot.value,
          );
          _driverChatMessagesById
            ..clear()
            ..addEntries(
              parsed.messages.map(
                (m) => MapEntry<String, RideChatMessage>(m.id, m),
              ),
            );
          _flushDriverChatMessageTable(rideId);
        },
        onError: (Object error) async {
          _reportDriverChatIssue(
            rideId,
            'listener_onvalue_failed',
            error: error,
          );
        },
      ),
    );
  }

  Future<void> _loadDriverChatSnapshot(
    String rideId,
    rtdb.DatabaseReference ref,
  ) async {
    try {
      _log('[CHAT_LOAD_START] role=driver rideId=$rideId');
      final snapshot = await ref.get().timeout(const Duration(seconds: 6));
      final parsed = parseRideChatSnapshot(rideId: rideId, raw: snapshot.value);
      for (final message in parsed.messages) {
        _driverChatMessagesById[message.id] = message;
      }
      _flushDriverChatMessageTable(rideId);
      _log(
        '[CHAT_LOAD_OK] role=driver rideId=$rideId count=${parsed.messages.length} '
        'invalid=${parsed.invalidRecordCount}',
      );
    } catch (error) {
      _log('[CHAT_LOAD_FAIL] role=driver rideId=$rideId error=$error');
      _reportDriverChatIssue(rideId, 'load_failed', error: error);
    }
  }

  void _rearmRideRequestListener(String reason) {
    Future<void>.microtask(() {
      if (!_isOnline) {
        return;
      }

      _logListenerStillActiveWaitingForFreshRides();
      unawaited(_listenForRideRequests(reason: reason));
    });
  }

  Future<_MatchedRideRequest?> _loadLivePopupRide(
    String rideId, {
    bool logSkips = true,
    bool ignoreLocalState = false,
  }) async {
    if (_isTerminalSelfAcceptedRide(rideId)) {
      _logRideReq(
        '[MATCH_DEBUG][POPUP_SUPPRESSED_SELF_ACCEPTED] rideId=$rideId '
        'source=load_live_popup_ride',
      );
      return null;
    }
    final snapshot =
        await _rideRequestChildGetIosSafe(rideId, 'load_live_popup_ride');
    final liveRide = _matchRideForPopup(
      rideId,
      snapshot.value,
      ignoreLocalState: ignoreLocalState,
      logSkips: false,
    );
    if (liveRide != null) {
      return liveRide;
    }

    final rideData = _asStringDynamicMap(snapshot.value);
    final skipReason =
        _popupServerSkipReason(rideId, rideData) ?? 'unavailable';
    _logInvalidRideBlocked(rideId: rideId, reason: skipReason);
    _popupDismissedRideId = rideId;
    _popupDismissedReason = skipReason;
    if (logSkips) {
      _logRtdb('ride skipped rideId=$rideId reason=$skipReason');
    }
    return null;
  }

  _MatchedRideRequest? _matchRideForPopup(
    String rideId,
    dynamic rawRide, {
    bool ignoreLocalState = false,
    bool logSkips = true,
    bool logCandidate = false,
    bool marketDiscoveryCandidate = false,
  }) {
    final trimmedRideId = rideId.trim();
    if (_terminalSelfAcceptedRideIds.contains(trimmedRideId)) {
      _logRideReq(
        '[MATCH_DEBUG][DISCOVERY_IGNORED_ACCEPTED_RIDE] rideId=$rideId '
        'source=_matchRideForPopup',
      );
      return null;
    }
    if (_foreverSuppressedRidePopupIds.contains(trimmedRideId)) {
      _logRideReq(
        '[MATCH_DEBUG][POPUP_SUPPRESSED_ACCEPTED] rideId=$rideId '
        'source=_matchRideForPopup ignoreLocalState=$ignoreLocalState',
      );
      return null;
    }
    final rideData = _asStringDynamicMap(rawRide);
    if (logCandidate) {
      _logRideCandidate(rideId: rideId, rideData: rideData);
    }
    final serverSkipReason = _popupServerSkipReason(
      rideId,
      rideData,
      marketDiscoveryStage: marketDiscoveryCandidate,
    );
    if (serverSkipReason != null) {
      _logInvalidRideBlocked(rideId: rideId, reason: serverSkipReason);
      _logPopupServerSkip(rideId, rideData, serverSkipReason);
      _logRtdb('popup suppressed reason=$serverSkipReason rideId=$rideId');
      if (logSkips) {
        _logRtdb('ride skipped rideId=$rideId reason=$serverSkipReason');
      }
      return null;
    }

    if (!ignoreLocalState) {
      final localSkipReason = _popupLocalSkipReason(rideId);
      if (localSkipReason != null) {
        _logPopupServerSkip(rideId, rideData, 'local_$localSkipReason');
        if (localSkipReason == 'locally_suppressed_after_accept' ||
            localSkipReason == 'already_active_same_ride') {
          _logRtdb('popup skipped reason=$localSkipReason rideId=$rideId');
        } else if (logSkips) {
          _logRtdb('ride skipped rideId=$rideId reason=$localSkipReason');
        }
        return null;
      }
    }

    final matchedRideData = rideData!;
    final pickup = _pickupLatLngFromRideData(matchedRideData)!;
    final destination = _destinationLatLngFromRideData(matchedRideData)!;
    final normalizedStatus =
        TripStateMachine.uiStatusFromSnapshot(matchedRideData);
    final driverIdValue = _valueAsText(matchedRideData['driver_id']);
    final serviceType = _serviceTypeKey(matchedRideData['service_type']);
    final rideCity = _rideMarketFromData(matchedRideData)!;
    final rideArea = _rideAreaFromData(matchedRideData, city: rideCity);
    final createdAt = _parseCreatedAt(matchedRideData['created_at']);
    final distanceMeters = Geolocator.distanceBetween(
      _driverLocation.latitude,
      _driverLocation.longitude,
      pickup.latitude,
      pickup.longitude,
    );
    final normalizedDriverArea = _normalizeArea(_driverArea, city: rideCity);
    final sameArea = rideArea.isNotEmpty &&
        normalizedDriverArea != null &&
        normalizedDriverArea.isNotEmpty &&
        rideArea == normalizedDriverArea;

    return _MatchedRideRequest(
      rideId: rideId,
      rideData: matchedRideData,
      pickup: pickup,
      destination: destination,
      serviceType: serviceType,
      city: rideCity,
      area: rideArea,
      status: normalizedStatus,
      driverId: driverIdValue,
      createdAt: createdAt,
      distanceMeters: distanceMeters,
      sameArea: sameArea,
    );
  }

  Future<void> goOnline() async {
    final driverId = _effectiveDriverId;
    var publishedPresence = false;
    _log(
        'goOnline requested ts=${DateTime.now().toIso8601String()} auth=${FirebaseAuth.instance.currentUser?.uid ?? 'none'} driverId=$driverId');
    print('DRIVER_ONLINE_START');

    Future<Map<String, dynamic>>? profileReconcileFuture;
    var onlinePublishAttempted = false;

    try {
      if (driverId.isEmpty) {
        _log('goOnline failed: missing driver id');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Driver account is not available.')),
          );
        }
        return;
      }

      if ((_currentRideId?.isNotEmpty ?? false) ||
          (_driverActiveRideId?.isNotEmpty ?? false)) {
        _showSnackBarSafely(
          const SnackBar(
            content: Text(
              'Finish the current trip before changing availability.',
            ),
          ),
        );
        return;
      }

      final testLocation = _getNigeriaTestDriverLocation();
      Future<Position?>? positionFuture;
      if (testLocation == null) {
        positionFuture = _requestReadyPosition(
          positionTimeLimit: const Duration(seconds: 12),
        );
      }

      late Map<String, dynamic> profile;
      if (_goOnlineEligibleFromProfile(_lastDriverProfileSnapshot)) {
        profile = Map<String, dynamic>.from(_lastDriverProfileSnapshot!);
        _log(
          'goOnline profile path=cached_eligibility driverId=$driverId (fresh profile reconciles in background)',
        );
        profileReconcileFuture = _fetchDriverProfile(
          source: 'go_online_reconcile',
          readTimeout: const Duration(seconds: 18),
        );
      } else {
        profile = await _fetchDriverProfile(
          source: 'go_online',
          readTimeout: const Duration(seconds: 5),
        );
      }

      final businessModel =
          normalizedDriverBusinessModel(profile['businessModel']);
      final verification =
          normalizedDriverVerification(profile['verification']);
      if (businessModel['canGoOnline'] != true) {
        _log(
          'goOnline blocked: business model ineligible selectedModel=${businessModel['selectedModel']} status=${businessModel['eligibilityStatus']}',
        );
        if (mounted) {
          final messenger = ScaffoldMessenger.of(context);
          messenger.hideCurrentSnackBar();
          messenger.showSnackBar(
            SnackBar(
              content: Text(driverBusinessEligibilityMessage(businessModel)),
              action: SnackBarAction(
                label: 'Review',
                onPressed: () {
                  unawaited(_openBusinessModelScreen());
                },
              ),
            ),
          );
        }
        return;
      }
      if (!driverVerificationCanGoOnline(verification)) {
        _log(
          'goOnline blocked: verification ineligible status=${verification['overallStatus']}',
        );
        if (mounted) {
          final messenger = ScaffoldMessenger.of(context);
          messenger.hideCurrentSnackBar();
          messenger.showSnackBar(
            SnackBar(
              content: Text(driverVerificationEligibilityMessage(verification)),
              action: SnackBarAction(
                label: 'Review',
                onPressed: () {
                  unawaited(_openVerificationScreen());
                },
              ),
            ),
          );
        }
        return;
      }

      double latitude;
      double longitude;
      String? resolvedCity;
      Position? livePosition;

      if (testLocation != null) {
        latitude = testLocation.latitude;
        longitude = testLocation.longitude;
        resolvedCity = testLocation.city;
        _driverCity = resolvedCity;
      } else {
        final position = await positionFuture!;
        if (position == null) {
          return;
        }

        if (position.latitude == 0 || position.longitude == 0) {
          _log(
              'goOnline failed: invalid GPS lat=${position.latitude} lng=${position.longitude}');
          _showAvailabilityFailureNotice(
            'GPS coordinates are invalid. Move to an open area and try GO ONLINE again.',
          );
          return;
        }

        latitude = position.latitude;
        longitude = position.longitude;
        livePosition = position;
        resolvedCity = await _resolveDriverCity(
          position: position,
          existingProfile: profile,
          persistCityToRtdb: false,
        );
      }

      if (resolvedCity == null || resolvedCity.isEmpty) {
        _log(
          'goOnline warning: launch market unresolved, falling back to selected=$_selectedLaunchCity',
        );
      }

      var cityToSave = _normalizeCity(
            (resolvedCity != null && resolvedCity.isNotEmpty)
                ? resolvedCity
                : _selectedLaunchCity,
          ) ??
          _selectedLaunchCity;
      // Same canonical slug as rider `ride_requests.market` (DriverServiceAreaConfig).
      cityToSave = DriverServiceAreaConfig.marketForCity(cityToSave).city;
      final repairedMarket = await _ensureDriverProfileForDiscovery(
        preferredMarket: cityToSave,
        source: 'go_online_pre_publish',
      );
      if (repairedMarket == null || repairedMarket.isEmpty) {
        _showAvailabilityFailureNotice(
          'Driver profile could not be validated. Please sign in again and retry GO ONLINE.',
        );
        return;
      }
      cityToSave = repairedMarket;
      _driverCity = cityToSave;
      _selectedLaunchCity = cityToSave;
      if (_deviceLocationOutsideLaunchArea) {
        latitude = DriverLaunchScope.latitudeForCity(cityToSave);
        longitude = DriverLaunchScope.longitudeForCity(cityToSave);
      }
      final driverArea = await _resolveDriverArea(
        position: _deviceLocationOutsideLaunchArea ? null : livePosition,
        city: cityToSave,
        profile: profile,
      ).timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _log(
            'goOnline driver area resolution TIMEOUT city=$cityToSave (using profile hints)',
          );
          return _serviceAreaFromCandidates(
            city: cityToSave,
            candidates: <String?>[
              profile['area']?.toString(),
              profile['zone']?.toString(),
              profile['community']?.toString(),
            ],
          );
        },
      );
      _driverArea = driverArea;
      final driverScope = _buildServiceAreaFields(
        city: cityToSave,
        area: driverArea,
      );
      _log('driver city set to ${resolvedCity ?? _selectedLaunchCity}');
      _logRideReq(
        'ONLINE attach start cityToSave=$cityToSave effectiveMarket=${_effectiveDriverMarket ?? 'null'}',
      );

      final name = (widget.driverName.trim().isNotEmpty
              ? widget.driverName.trim()
              : profile['name']?.toString().trim()) ??
          'Driver';
      final car = widget.car.trim().isNotEmpty
          ? widget.car.trim()
          : profile['car']?.toString().trim() ?? '';
      final plate = widget.plate.trim().isNotEmpty
          ? widget.plate.trim()
          : profile['plate']?.toString().trim() ?? '';

      _driverLocation = LatLng(latitude, longitude);
      await _hardResetBeforeListenerAttach();
      _onlineSessionStartedAt = DateTime.now().millisecondsSinceEpoch;
      _lastAvailabilityIntentOnline = true;

      _log('[ONLINE] start driverId=$driverId city=$cityToSave');
      if (!_preOnlinePublishGate(cityToSave: cityToSave, driverArea: driverArea)) {
        _log('[ONLINE] fail reason=pre_online_publish_gate');
        _showAvailabilityFailureNotice(
          'Could not go online: city or service area is incomplete. Pick a launch city and try again.',
        );
        return;
      }

      _logRtdb('online publish start driverId=$driverId');
      onlinePublishAttempted = true;
      await _driversRef.child(driverId).update({
        'id': driverId,
        'uid': driverId,
        'name': name,
        'car': car,
        'plate': plate,
        'serviceTypes': profile['serviceTypes'],
        'businessModel': businessModel,
        'verification': verification,
        'online_session_started_at': _onlineSessionStartedAt,
        'isOnline': true,
        'is_online': true,
        'isAvailable': true,
        'available': true,
        'status': 'idle',
        'activeRideId': null,
        'currentRideId': null,
        'lat': latitude,
        'lng': longitude,
        'country': driverScope['country'],
        'country_code': driverScope['country_code'],
        'market': cityToSave,
        'city': cityToSave,
        'area': driverScope['area'],
        'zone': driverScope['zone'],
        'community': driverScope['community'],
        'service_area': driverScope,
        'launch_market_city': cityToSave,
        'launch_market_country': DriverLaunchScope.countryName,
        'last_availability_intent': 'online',
        'last_availability_intent_at': rtdb.ServerValue.timestamp,
        'launch_market_updated_at': rtdb.ServerValue.timestamp,
        'last_active_at': rtdb.ServerValue.timestamp,
        'updated_at': rtdb.ServerValue.timestamp,
      }).timeout(const Duration(seconds: 12));
      publishedPresence = true;
      _log('[LAST_ACTIVE] updated source=go_online driverId=$driverId');
      _logRtdb('online publish success driverId=$driverId');

      try {
        final driversPostSnap = await _driversRef.child(driverId).get();
        final driversPostMap = _asStringDynamicMap(driversPostSnap.value);
        final postedMarket = driversPostMap == null
            ? 'n/a'
            : _valueAsText(driversPostMap['market']);
        final opts = Firebase.app().options;
        final probeDbUrl = rtdb.FirebaseDatabase.instance.databaseURL ??
            opts.databaseURL ??
            'null';
        _logDriverReq('databaseURL=$probeDbUrl');
        _logDriverReq('firebase_projectId=${opts.projectId}');
        _logDriverReq('drivers/$driverId exists=${driversPostSnap.exists}');
        _logDiscoveryChain(
          'go_online_pre_listener drivers/$driverId exists=${driversPostSnap.exists} '
          'drivers_node_market=$postedMarket '
          '_driverCity=${_driverCity ?? 'null'} _selectedLaunchCity=$_selectedLaunchCity '
          '_effectiveDriverMarket=${_effectiveDriverMarket ?? 'null'} '
          'firebase_project=${opts.projectId} databaseURL=${opts.databaseURL ?? 'null'}',
        );
      } catch (error) {
        _logDiscoveryChain(
          'go_online_pre_listener drivers_probe_failed error=$error',
        );
      }

      _log(
        'online session started driverId=$driverId city=$cityToSave online_session_started_at=$_onlineSessionStartedAt',
      );
      _logRtdb('online session started at=$_onlineSessionStartedAt');

      _log(
        'goOnline success driverId=$driverId city=$cityToSave lat=$latitude lng=$longitude',
      );
      _log('[ONLINE] success driverId=$driverId city=$cityToSave');
      _log(
        'driver state change ts=${DateTime.now().toIso8601String()} online=true currentRideId=$_currentRideId',
      );

      if (mounted) {
        _setStateSafely(() {
          _isOnline = true;
          _rideStatus = 'idle';
          _tripStarted = false;
          _driverUnreadChatCount = 0;
          _isDriverChatOpen = false;
        });
      } else {
        _isOnline = true;
        _rideStatus = 'idle';
        _tripStarted = false;
        _driverUnreadChatCount = 0;
        _isDriverChatOpen = false;
      }
      // Await first market prime inside [_listenForRideRequests] so [driver_active_ride]
      // cannot populate [_driverActiveRideId] before the initial open-pool snapshot runs.
      final discoveryReady = await _listenForRideRequests(reason: 'goOnline');
      _logDiscoveryChain(
        'go_online listener_attach_succeeded=$discoveryReady '
        'query_market=${_effectiveDriverMarket ?? 'null'}',
      );
      _logRideReqContext('post-listener-invoke');
      await _startDriverActiveRideListener();
      _updateDriverMarker();
      if (_mapViewReady) {
        _moveCameraToIdleState();
      }
      _refreshIosDriverMapIfNeeded(reason: 'go_online');
      _startLiveLocationStream();
      if (discoveryReady) {
        _showSnackBarSafely(
          const SnackBar(
            content: Text(
              'You are online. Ride requests will pop up here when riders nearby request a trip.',
            ),
          ),
        );
      } else {
        _logPopup(
          'goOnline discovery listener unavailable; staying online with dispatch/assigned flow',
        );
      }

      final reconcile = profileReconcileFuture;
      if (reconcile != null) {
        unawaited(() async {
          try {
            await reconcile;
            _log('goOnline profile reconcile completed driverId=$driverId');
          } on TimeoutException catch (error) {
            _log(
              'goOnline profile reconcile TIMEOUT driverId=$driverId error=$error',
            );
          } catch (error) {
            _log(
              'goOnline profile reconcile FAILED driverId=$driverId error=$error',
            );
          }
        }());
      }
    } catch (error) {
      if (onlinePublishAttempted && !publishedPresence) {
        if (error is TimeoutException) {
          _log(
            'online publish failure TIMEOUT driverId=$driverId error=$error',
          );
        } else {
          _log('online publish failure driverId=$driverId error=$error');
        }
      }
      _log('goOnline failed unexpectedly driverId=$driverId error=$error');
      _log('[ONLINE] fail driverId=$driverId error=$error');
      await _rollbackFailedGoOnline(
        driverId: driverId,
        reason: error.toString(),
        publishedPresence: publishedPresence,
      );
      if (error is TimeoutException) {
        _showAvailabilityFailureNotice(
          'Going online timed out. Check your connection and try again.',
        );
      } else if (isRealtimeDatabasePermissionDenied(error)) {
        _showAvailabilityFailureNotice(
          'Could not publish online status (permission denied). Check Realtime Database rules for drivers/$driverId and try again.',
        );
      } else {
        _showAvailabilityFailureNotice(
          'Could not go online right now. Please try again.',
        );
      }
    }
  }

  Future<void> goOffline() async {
    final driverId = _effectiveDriverId;
    _log(
      'goOffline requested ts=${DateTime.now().toIso8601String()} driverId=$driverId currentRideId=$_currentRideId',
    );
    _log('[OFFLINE] start driverId=$driverId');

    if (_currentRideId != null || _driverActiveRideId != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Complete or cancel the current trip first.')),
        );
      }
      _log('[OFFLINE] fail reason=active_trip');
      return;
    }

    await _releaseLocalPendingAssignmentIfNeeded(
      reason: 'go_offline_pending_assignment_release',
    );

    if (driverId.isNotEmpty) {
      try {
        await _driversRef.child(driverId).update({
          'isOnline': false,
          'is_online': false,
          'isAvailable': false,
          'available': false,
          'status': 'offline',
          'activeRideId': null,
          'currentRideId': null,
          'online_session_started_at': null,
          'last_availability_intent': 'offline',
          'last_availability_intent_at': rtdb.ServerValue.timestamp,
          'last_active_at': rtdb.ServerValue.timestamp,
          'updated_at': rtdb.ServerValue.timestamp,
        });
        _log('[LAST_ACTIVE] updated source=go_offline driverId=$driverId');
      } catch (error) {
        _log('[OFFLINE] fail driverId=$driverId error=$error');
        _showAvailabilityFailureNotice(
          'Could not sync offline status to the server. You will be taken offline locally — try again when online.',
        );
      }
    }

    await _positionStream?.cancel();
    _positionStream = null;

    await _cancelRideRequestListener(reason: 'go_offline');
    await _stopIncomingCallMonitoring();
    _stopActiveRideListener();
    _resetDriverChatState();
    _clearRidePopupTimer();
    await _clearDriverActiveRideNode(reason: 'go_offline');

    _hasActivePopup = false;
    _popupOpen = false;
    _activePopupRideId = null;
    _acceptingPopupRideId = null;
    _popupDismissedRideId = null;
    _popupDismissedReason = null;
    _presentedRideIds.clear();
    _timedOutRideIds.clear();
    _declinedRideIds.clear();
    _handledRideIds.clear();
    _suppressedRidePopupIds.clear();
    _foreverSuppressedRidePopupIds.clear();
    _terminalSelfAcceptedRideIds.clear();
    _rideRequestPopupQueue.clear();
    _cancelPendingRouteRequests(reason: 'go_offline');
    _onlineSessionStartedAt = 0;
    _lastAvailabilityIntentOnline = false;
    _sessionTrackedRideId = null;
    _lastRouteBuildKey = '';
    _lastRouteBuiltAt = null;
    _lastRouteOrigin = null;
    _routeBuildInFlight = false;
    _deliveryProofUploading = false;
    _deliveryProofUploadProgress = 0;

    if (mounted) {
      setState(() {
        _currentRideId = null;
        _isOnline = false;
        _currentRideData = null;
        _rideStatus = 'offline';
        _tripStarted = false;
        _driverUnreadChatCount = 0;
        _isDriverChatOpen = false;
        _pickupLocation = null;
        _destinationLocation = null;
        _nextNavigationTarget = null;
        _pickupAddressText = '';
        _destinationAddressText = '';
        _riderName = 'Rider';
        _riderPhone = '';
        _riderVerificationStatus = 'unverified';
        _riderRiskStatus = 'clear';
        _riderPaymentStatus = 'clear';
        _riderCashAccessStatus = 'enabled';
        _riderTrustLoading = false;
        _riderVerifiedBadge = false;
        _riderRating = 5.0;
        _riderRatingCount = 0;
        _riderOutstandingCancellationFeesNgn = 0;
        _riderNonPaymentReports = 0;
        _arrivedEnabled = false;
        _deliveryProofUploading = false;
        _deliveryProofUploadProgress = 0;
        _polyLines.clear();
      });
    }

    _currentRideId = null;
    _currentRideData = null;
    _sessionTrackedRideId = null;
    _tripWaypoints.clear();
    _expectedRoutePoints.clear();
    _activePopupRideId = null;
    _acceptingPopupRideId = null;
    _loadedRiderProfileKey = null;
    _driverActiveRideId = null;
    _currentCandidateRideId = null;
    _hasLoggedArrivedEnabled = false;
    _lastRouteConsistencyCheckKey = '';
    _lastTelemetryCheckpointPosition = null;
    _lastTelemetryCheckpointAt = null;
    _stopDriverSafetyMonitoring();
    _syncTripLocationMarkers();

    _log(
      'driver state change ts=${DateTime.now().toIso8601String()} online=false currentRideId=$_currentRideId',
    );
    _log('[OFFLINE] success driverId=$driverId');
    _log('goOffline success');
  }

  void toggleOnline() {
    if (_availabilityActionInProgress) {
      return;
    }

    if (mounted) {
      _setStateSafely(() {
        _availabilityActionInProgress = true;
      });
    } else {
      _availabilityActionInProgress = true;
    }

    unawaited(() async {
      try {
        if (_isOnline) {
          await goOffline();
        } else {
          _log(
            'toggleOnline goOnline tap driverId=$_effectiveDriverId ts=${DateTime.now().toIso8601String()}',
          );
          await goOnline();
        }
      } catch (error) {
        _log('toggleOnline failed error=$error');
        _showAvailabilityFailureNotice(
          'Availability update failed. Please try again.',
        );
      } finally {
        _log(
          'toggleOnline finally cleared availabilityActionInProgress driverId=$_effectiveDriverId',
        );
        if (mounted) {
          _setStateSafely(() {
            _availabilityActionInProgress = false;
          });
        } else {
          _availabilityActionInProgress = false;
        }
      }
    }());
  }

  Future<void> _openBusinessModelScreen() async {
    if (!mounted) {
      return;
    }

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => DriverBusinessModelScreen(driverId: _effectiveDriverId),
      ),
    );
  }

  Future<void> _openVerificationScreen() async {
    if (!mounted) {
      return;
    }

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => DriverVerificationScreen(driverId: _effectiveDriverId),
      ),
    );
  }

  Future<void> _openDriverToolsSheet() async {
    final profile = await _fetchDriverProfile();
    UserSupportInboxSummary? supportSummary;
    try {
      supportSummary = await _userSupportTicketService.fetchInboxSummary(
        userId: _effectiveDriverId,
        createdByType: 'driver',
      );
    } catch (_) {
      supportSummary = null;
    }
    final businessModel =
        normalizedDriverBusinessModel(profile['businessModel']);
    final verification = normalizedDriverVerification(profile['verification']);
    final subtitle =
        '${driverSelectedMonetizationModeLabel(businessModel)} • ${driverVerificationStatusLabel(verification['overallStatus']?.toString() ?? 'incomplete')} verification • ${driverBusinessEligibilityMessage(businessModel)}';

    if (!mounted) {
      return;
    }

    final action = await showModalBottomSheet<_DriverHubAction>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (BuildContext sheetContext) {
        final mediaQuery = MediaQuery.of(sheetContext);
        return Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            12,
            16,
            mediaQuery.viewInsets.bottom + 16,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: mediaQuery.size.height * 0.82,
            ),
            child: SingleChildScrollView(
              child: DriverDashboardPanel(
                title: 'Driver Hub',
                subtitle: subtitle,
                actions: <DriverDashboardAction>[
                  DriverDashboardAction(
                    label: 'Trip history',
                    icon: Icons.history,
                    onTap: () {
                      Navigator.of(sheetContext)
                          .pop(_DriverHubAction.tripHistory);
                    },
                  ),
                  DriverDashboardAction(
                    label: 'Earnings',
                    icon: Icons.payments_outlined,
                    onTap: () {
                      Navigator.of(sheetContext).pop(_DriverHubAction.earnings);
                    },
                  ),
                  DriverDashboardAction(
                    label: 'Business model',
                    icon: Icons.work_outline,
                    onTap: () {
                      Navigator.of(sheetContext)
                          .pop(_DriverHubAction.businessModel);
                    },
                  ),
                  DriverDashboardAction(
                    label: 'Verification',
                    icon: Icons.verified_user_outlined,
                    onTap: () {
                      Navigator.of(sheetContext)
                          .pop(_DriverHubAction.verification);
                    },
                  ),
                  DriverDashboardAction(
                    label: 'Wallet',
                    icon: Icons.account_balance_wallet_outlined,
                    onTap: () {
                      Navigator.of(sheetContext).pop(_DriverHubAction.wallet);
                    },
                  ),
                  DriverDashboardAction(
                    label: 'Report issue / support',
                    icon: Icons.support_agent_rounded,
                    badgeLabel: _supportBadgeLabel(supportSummary),
                    onTap: () {
                      Navigator.of(sheetContext).pop(_DriverHubAction.support);
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    if (!mounted || action == null) {
      return;
    }

    switch (action) {
      case _DriverHubAction.tripHistory:
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => TripHistoryScreen(driverId: _effectiveDriverId),
          ),
        );
        break;
      case _DriverHubAction.earnings:
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => EarningsScreen(driverId: _effectiveDriverId),
          ),
        );
        break;
      case _DriverHubAction.businessModel:
        await _openBusinessModelScreen();
        break;
      case _DriverHubAction.verification:
        await _openVerificationScreen();
        break;
      case _DriverHubAction.wallet:
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => WalletScreen(driverId: _effectiveDriverId),
          ),
        );
        break;
      case _DriverHubAction.support:
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => DriverSupportCenterScreen(
              driverId: _effectiveDriverId,
            ),
          ),
        );
        break;
    }
  }

  String? _supportBadgeLabel(UserSupportInboxSummary? summary) {
    if (summary == null) {
      return null;
    }
    if (summary.unreadReplies > 0) {
      return '${summary.unreadReplies} new';
    }
    if (summary.openTickets > 0) {
      return '${summary.openTickets} open';
    }
    return null;
  }

  void _startLiveLocationStream() {
    _positionStream?.cancel();

    final testLocation = _getNigeriaTestDriverLocation();
    if (testLocation != null) {
      _driverLocation = LatLng(testLocation.latitude, testLocation.longitude);
      _driverCity = testLocation.city;
      _updateDriverMarker();

      if (mounted) {
        _setStateSafely(() {});
      }
      return;
    }

    try {
      _positionStream = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 10,
        ),
      ).listen((position) async {
        try {
          final hasTrackedRide = (_currentRideId?.isNotEmpty ?? false) ||
              (_driverActiveRideId?.isNotEmpty ?? false);
          if (!_isOnline && !hasTrackedRide) {
            return;
          }

          if (position.latitude == 0 || position.longitude == 0) {
            _log('live location skipped invalid coordinates');
            return;
          }

          if (_deviceLocationOutsideLaunchArea) {
            _driverLocation = _selectedLaunchCityCenter;
          } else {
            _driverLocation = LatLng(position.latitude, position.longitude);
          }
          _updateDriverMarker();

          final driverId = _effectiveDriverId;
          if (driverId.isNotEmpty) {
            final hasActiveRide = _currentRideId != null;
            await _driversRef.child(driverId).update({
              'lng': _driverLocation.longitude,
              'lat': _driverLocation.latitude,
              'isOnline': _isOnline,
              'is_online': _isOnline,
              'isAvailable': _isOnline && !hasActiveRide,
              'available': _isOnline && !hasActiveRide,
              'status': hasActiveRide
                  ? _rideStatus
                  : (_isOnline ? 'idle' : 'offline'),
              'activeRideId': _currentRideId,
              'currentRideId': _currentRideId,
              'country': DriverServiceAreaConfig.countryValue,
              'country_code': DriverServiceAreaConfig.countryCode,
              'market': _driverCity,
              'city': _driverCity,
              'area': _driverArea,
              'zone': _driverArea,
              'community': _driverArea,
              'last_availability_intent': _lastAvailabilityIntentValue,
              'last_active_at': rtdb.ServerValue.timestamp,
              'updated_at': rtdb.ServerValue.timestamp,
            });
            _lastActiveHeartbeatLogCount += 1;
            if (_lastActiveHeartbeatLogCount % 18 == 1) {
              _log('[LAST_ACTIVE] updated source=location_heartbeat');
            }
          }

          if (_currentRideId != null) {
            final activeRideId = _currentRideId!;
            final currentRide = _currentRideData;
            final currentCanonicalState = currentRide == null
                ? TripLifecycleState.searchingDriver
                : TripStateMachine.canonicalStateFromSnapshot(currentRide);
            final canSyncRideLocation = currentRide != null &&
                !TripStateMachine.isPendingDriverAssignmentState(
                  currentCanonicalState,
                );
            final shouldPromoteToArriving = canSyncRideLocation &&
                currentCanonicalState == TripLifecycleState.driverAccepted;
            if (canSyncRideLocation) {
              final rideUpdates = <String, dynamic>{
                'driver_lat': position.latitude,
                'driver_lng': position.longitude,
                'updated_at': rtdb.ServerValue.timestamp,
              };
              if (shouldPromoteToArriving) {
                rideUpdates.addAll(
                  TripStateMachine.buildTransitionUpdate(
                    currentRide: currentRide,
                    nextCanonicalState: TripLifecycleState.driverArriving,
                    timestampValue: rtdb.ServerValue.timestamp,
                    transitionSource: 'driver_location_en_route',
                    transitionActor: 'driver',
                  ),
                );
              }

              await _rideRequestsRef.child(activeRideId).update(rideUpdates);
              if (shouldPromoteToArriving) {
                await _commitRideAndDriverState(
                  rideId: activeRideId,
                  rideUpdates: <String, dynamic>{},
                  driverUpdates: _buildDriverPresenceUpdate(
                    status: 'arriving',
                    activeRideId: activeRideId,
                    isAvailable: false,
                  ),
                  activeRideUpdates: <String, Object?>{
                    'ride_id': activeRideId,
                    'status': 'arriving',
                    'trip_state': TripLifecycleState.driverArriving,
                    'updated_at': rtdb.ServerValue.timestamp,
                  },
                );
                final nextRideData = Map<String, dynamic>.from(currentRide)
                  ..addAll(<String, dynamic>{
                    'status': 'arriving',
                    'trip_state': TripLifecycleState.driverArriving,
                  });
                if (mounted) {
                  _setStateSafely(() {
                    _rideStatus = 'arriving';
                    _currentRideData = nextRideData;
                  });
                } else {
                  _rideStatus = 'arriving';
                  _currentRideData = nextRideData;
                }
                _log('driver en route state promoted rideId=$activeRideId');
              }
              await _maybeLogDriverTelemetryCheckpoint();
            }
          }

          _evaluateArrivedAvailability();
          _scheduleActiveRouteRefresh(
            reason: 'driver_location_update',
          );
          _checkDriverSafety();

          if (mounted) {
            _setStateSafely(() {});
          }
        } catch (error) {
          _log('live location update failed error=$error');
        }
      }, onError: (Object error) {
        _log('live location listener error=$error');
      });
    } catch (error) {
      _log('live location stream start failed error=$error');
      _showAvailabilityFailureNotice(
        'Live location could not start. Please try GO ONLINE again.',
      );
    }
  }

  Future<bool> _listenForRideRequests({required String reason}) async {
    final captured = <bool>[false];
    _rideDiscoveryAttachChain = _rideDiscoveryAttachChain
        .catchError((Object _) {})
        .then<void>((_) async {
      try {
        captured[0] = await _listenForRideRequestsImpl(
          reason: reason,
        ).timeout(const Duration(seconds: 12));
      } catch (error, stackTrace) {
        if (isRealtimeDatabasePermissionDenied(error)) {
          print('RIDE_DISCOVERY_PERMISSION_DENIED');
        }
        _log('discovery attach failed reason=$reason error=$error');
        debugPrintStack(
          label: '[DriverMap] discovery attach stack',
          stackTrace: stackTrace,
        );
        captured[0] = false;
      }
    });
    await _rideDiscoveryAttachChain;
    return captured[0];
  }

  Future<String?> _ensureDriverProfileForDiscovery({
    required String? preferredMarket,
    required String source,
  }) async {
    final authUid = FirebaseAuth.instance.currentUser?.uid.trim();
    _logRideReq('[DRIVER_CHECK] uid=${authUid ?? 'none'} source=$source');
    if (authUid == null || authUid.isEmpty) {
      return null;
    }
    final targetMarket = DriverServiceAreaConfig.marketForCity(
      (preferredMarket == null || preferredMarket.trim().isEmpty)
          ? 'lagos'
          : preferredMarket,
    ).city;
    final profileRef = _driversRef.child(authUid);
    try {
      var snap = await profileRef.get();
      var map = _asStringDynamicMap(snap.value);
      _logRideReq('[DRIVER_CHECK] exists=${snap.exists} data=${map ?? {}} source=$source');
      if (!snap.exists) {
        await profileRef.set({
          'id': authUid,
          'uid': authUid,
          'market': targetMarket,
          'market_pool': targetMarket,
          'city': targetMarket,
          'updated_at': rtdb.ServerValue.timestamp,
        });
        _logRideReq('[DRIVER_PROFILE_REPAIR] created missing driver node');
        snap = await profileRef.get();
        map = _asStringDynamicMap(snap.value);
      }
      var market = _valueAsText(map?['market']);
      if (market.isEmpty) {
        market = _valueAsText(map?['city']);
      }
      market = DriverServiceAreaConfig.marketForCity(
        market.isEmpty ? targetMarket : market,
      ).city;
      if (_valueAsText(map?['market']) != market || _valueAsText(map?['city']) != market) {
        await profileRef.update({
          'market': market,
          'market_pool': market,
          'city': market,
          'launch_market_city': market,
          'launch_market_updated_at': rtdb.ServerValue.timestamp,
          'updated_at': rtdb.ServerValue.timestamp,
        });
        snap = await profileRef.get();
        map = _asStringDynamicMap(snap.value);
        _logRideReq('[DRIVER_PROFILE_REPAIR] normalized driver node data=${map ?? {}}');
      }
      return market;
    } catch (error) {
      _logRideReq('[DRIVER_CHECK] failure error=$error source=$source');
      return null;
    }
  }

  Future<bool> _listenForRideRequestsImpl({required String reason}) async {
    print('RIDE_DISCOVERY_ATTACH_START');
    _logRideReq('request listener attach attempt reason=$reason');
    _logRideReqContext('pre-bind');
    _logReqDebug(
      'effectiveDriverMarket=${_effectiveDriverMarket ?? 'null'} '
      'driverCity=${_driverCity ?? 'null'} selectedLaunchCity=$_selectedLaunchCity',
    );
    String firebaseProject = 'unavailable';
    String firebaseDbUrl = 'unavailable';
    try {
      final o = Firebase.app().options;
      firebaseProject = o.projectId;
      firebaseDbUrl = o.databaseURL ?? 'null';
    } catch (_) {}
    _logDiscoveryChain(
      'listener_bind_attempt reason=$reason _driverCity=${_driverCity ?? 'null'} '
      '_selectedLaunchCity=$_selectedLaunchCity '
      '_effectiveDriverMarket=${_effectiveDriverMarket ?? 'null'} '
      'firebase_project=$firebaseProject databaseURL=$firebaseDbUrl',
    );
    final uid = FirebaseAuth.instance.currentUser?.uid.trim();
    final profilePath =
        uid == null || uid.isEmpty ? 'drivers/(none)' : driverProfilePath(uid);
    final runtimeDbUrl = rtdb.FirebaseDatabase.instance.databaseURL ??
        Firebase.app().options.databaseURL ??
        'null';
    final runtimeProjectId = Firebase.app().options.projectId;
    _logRideReq('[DRIVER_DISCOVERY_TRACE] projectId=$runtimeProjectId');
    _logRideReq('[DRIVER_DISCOVERY_TRACE] databaseURL=$runtimeDbUrl');
    _logRideReq('[DRIVER_DISCOVERY_TRACE] uid=${uid ?? 'none'}');
    _logRideReq('[DRIVER_DISCOVERY_TRACE] driverProfilePath=$profilePath');
    if (uid == null || uid.isEmpty) {
      _showAvailabilityFailureNotice(
        'Driver profile is invalid for discovery. Please retry GO ONLINE.',
      );
      return false;
    }
    final repairedMarket = await _ensureDriverProfileForDiscovery(
      preferredMarket: _effectiveDriverMarket ?? _driverCity ?? 'lagos',
      source: 'ride_discovery_listener',
    ).timeout(const Duration(seconds: 8));
    final driverRef = rtdb.FirebaseDatabase.instance.ref('drivers/$uid');
    final snap = await driverRef.get().timeout(const Duration(seconds: 8));
    final snapMap = _asStringDynamicMap(snap.value);
    final runtimeDriverMarketRaw = _valueAsText(snapMap?['market']);
    final runtimeDriverMarketPoolRaw = _valueAsText(snapMap?['market_pool']);
    final runtimeDriverCityRaw = _valueAsText(snapMap?['city']);
    debugPrint(
      'DRIVER_RUNTIME_DATA uid=${uid.isEmpty ? 'none' : uid} '
      'market=$runtimeDriverMarketRaw market_pool=$runtimeDriverMarketPoolRaw city=$runtimeDriverCityRaw '
      'snapshot=${snapMap ?? <String, dynamic>{}}',
    );
    _logRideReq(
      '[DRIVER_DISCOVERY_TRACE] driverSnapshot exists=${snap.exists} data=${snapMap ?? {}}',
    );
    String? driverMarket = repairedMarket;
    if ((driverMarket == null || driverMarket.trim().isEmpty) && snapMap != null) {
      driverMarket = _valueAsText(snapMap['market']);
      if (driverMarket.isEmpty) {
        driverMarket = _valueAsText(snapMap['market_pool']);
      }
      if (driverMarket.isEmpty) {
        driverMarket = _valueAsText(snapMap['city']);
      }
    }
    final queryMarket = driverMarket == null || driverMarket.trim().isEmpty
        ? ''
        : DriverServiceAreaConfig.marketForCity(driverMarket).city;
    _logRideReq('[DRIVER_DISCOVERY_TRACE] driverMarket=$driverMarket');
    _logRideReq('[DRIVER_DISCOVERY_TRACE] queryMarket=$queryMarket');
    if (!snap.exists || queryMarket.isEmpty) {
      _logRideReq('[DRIVER_DISCOVERY_TRACE] BLOCKING DISCOVERY invalid driver profile');
      _showAvailabilityFailureNotice(
        'Driver profile missing market. Please update your profile and try GO ONLINE again.',
      );
      return false;
    }
    var driverCity = queryMarket;
    if (driverCity.isEmpty) {
      try {
        final o = Firebase.app().options;
        final u = rtdb.FirebaseDatabase.instance.databaseURL ?? o.databaseURL;
        _logDriverReq('databaseURL=$u');
        _logDriverReq('effectiveMarket=(unresolved)');
        _logDriverReq('queryPath=(listener not attached)');
        _logDriverReq('snapshotCount=n/a');
        _logDriverReq('candidateRideId=n/a');
        _logDriverReq('skippedReason=market_unresolved');
      } catch (_) {
        _logDriverReq('skippedReason=market_unresolved');
      }
      _logReqDebug('listener attach FAIL error=market_unresolved');
      _logRideReq(
        'request listener SKIPPED driver market unresolved (driverCity=$_driverCity selected=$_selectedLaunchCity)',
      );
      _showAvailabilityFailureNotice(
        'Driver profile missing market. Please update your profile city/market and try GO ONLINE again.',
      );
      _logPopup('listener attach FAILED reason=market_unresolved');
      _logDiscoveryChain('listener attach FAILED reason=market_unresolved');
      return false;
    }

    driverCity = DriverServiceAreaConfig.marketForCity(driverCity).city;
    _logReqDebug('listener attach START market=$driverCity');
    _logRideReq(
      'driver online state for discovery online=$_isOnline session=$_onlineSessionStartedAt market=$driverCity',
    );
    _logDiscoveryChain(
      'listener_query_market canonical=$driverCity raw_effective=${_effectiveDriverMarket ?? 'null'}',
    );

    if (_driverCity == null || _driverCity!.trim().isEmpty) {
      _driverCity = driverCity;
      _logRtdb('ride request listener using launch market=$driverCity (driver city unset)');
    }

    _logRideReq(
      'driver market resolved=$driverCity query=ride_requests orderByChild=market_pool equalTo=$driverCity',
    );
    _logRideReq(
      '[DRIVER_DISCOVERY_QUERY] path=ride_requests '
      'orderByChild=market_pool equalTo=$driverCity',
    );
    _logRideReq('[DRIVER_DISCOVERY_TRACE] uid=$uid');
    _logRideReq('[DRIVER_DISCOVERY_TRACE] driverProfilePath=$profilePath');
    _logRideReq('[DRIVER_DISCOVERY_TRACE] driverMarket=$driverCity');
    _logRideReq('[DRIVER_DISCOVERY_TRACE] queryMarket=$driverCity');
    _logRideReq(
      '[DRIVER_DISCOVERY_TRACE] query path=ride_requests orderByChild=market_pool equalTo=$driverCity',
    );
    debugPrint('RTDB_QUERY_PATH path=ride_requests');
    debugPrint(
      'RTDB_QUERY_PARAMS orderByChild=market_pool equalTo=$driverCity '
      'driver_market=$runtimeDriverMarketRaw driver_market_pool=$runtimeDriverMarketPoolRaw '
      'driver_city=$runtimeDriverCityRaw',
    );
    final compareMarket = runtimeDriverMarketRaw == driverCity;
    final compareMarketPool = runtimeDriverMarketPoolRaw == driverCity;
    final compareCity = runtimeDriverCityRaw == driverCity;
    _logRideReq(
      '[DRIVER_DISCOVERY_TRACE] query_value_compare '
      'driverMarketExactMatch=$compareMarket '
      'driverMarketPoolExactMatch=$compareMarketPool '
      'driverCityExactMatch=$compareCity',
    );
    final discoveryUid = FirebaseAuth.instance.currentUser?.uid ?? 'none';
    debugPrint(
      '[DRIVER_BACKEND] op=ride_discovery_attach authUid=$discoveryUid '
      'driverProfilePath=${discoveryUid == 'none' ? 'drivers/(none)' : driverProfilePath(discoveryUid)} '
      'query=ride_requests.orderByChild(market_pool).equalTo($driverCity)',
    );
    _log(
      'listener attached path=ride_requests[orderByChild=market_pool,equalTo=$driverCity] online_session_started_at=$_onlineSessionStartedAt reason=$reason',
    );
    _logRtdb(
      'listener attached path=ride_requests[orderByChild=market_pool,equalTo=$driverCity]',
    );

    debugPrint(
      '[DISCOVERY_QUERY] queryField=market_pool queryEqualTo=$driverCity '
      'effectiveDriverMarket=${_effectiveDriverMarket ?? 'null'} '
      'effectiveDriverCity=${_driverCity ?? 'null'} selectedLaunchCity=$_selectedLaunchCity',
    );

    final rideRequestsQuery =
        _rideRequestsRef.orderByChild('market_pool').equalTo(driverCity);

    String driverReqDatabaseUrl() {
      try {
        return rtdb.FirebaseDatabase.instance.databaseURL ??
            Firebase.app().options.databaseURL ??
            'null';
      } catch (_) {
        return 'unavailable';
      }
    }

    final driverReqDbUrl = driverReqDatabaseUrl();
    _logDriverReq('databaseURL=$driverReqDbUrl');
    _logDriverReq('effectiveMarket=$driverCity');
    _logDriverReq(
      'queryPath=ride_requests orderByChild=market_pool equalTo=$driverCity',
    );

    Future<void> snapshotProcessingChain = Future<void>.value();

    Future<void> processSnapshot(
      rtdb.DataSnapshot snapshot, {
      required String source,
      required int listenerToken,
    }) async {
        if (listenerToken != _rideRequestListenerToken) {
          _logRideReq(
            'snapshot skipped reason=stale_listener source=$source token=$listenerToken activeToken=$_rideRequestListenerToken',
          );
          return;
        }
        final raw = snapshot.value;
        final rideMap = <String, dynamic>{};

        if (raw is Map) {
          raw.forEach((key, value) {
            if (key != null) {
              rideMap[key.toString()] = value;
            }
          });
        }

        final activeOpenRideMap = <String, Map<String, dynamic>>{};
        for (final entry in rideMap.entries) {
          final rideId = entry.key;
          final rideData = _asStringDynamicMap(entry.value);
          final status = rideData == null
              ? 'payload_not_map'
              : TripStateMachine.uiStatusFromSnapshot(rideData);
          if (rideData != null) {
            _logRideReq(
              '[RIDER_WRITE] observed rideId=$rideId '
              'market=${_rideMarketFromData(rideData) ?? 'missing'} '
              'status=${_valueAsText(rideData[RtdbRideRequestFields.status])} '
              'trip_state=${_valueAsText(rideData[RtdbRideRequestFields.tripState])} '
              'driver_id=${_valueAsText(rideData[RtdbRideRequestFields.driverId])} '
              'created_at=${_parseCreatedAt(rideData[RtdbRideRequestFields.createdAt])} '
              'expires_at=${_rideExpiryTimestamp(rideData)}',
            );
            _logRideReq(
              '[DRIVER_DISCOVERY_CANDIDATE] rideId=$rideId '
              'market=${_rideMarketFromData(rideData) ?? 'missing'} '
              'status=${_valueAsText(rideData[RtdbRideRequestFields.status])} '
              'trip_state=${_valueAsText(rideData[RtdbRideRequestFields.tripState])} '
              'driver_id=${_valueAsText(rideData[RtdbRideRequestFields.driverId])} '
              'created_at=${_parseCreatedAt(rideData[RtdbRideRequestFields.createdAt])} '
              'expires_at=${_rideExpiryTimestamp(rideData)}',
            );
          }
          final skipReason = rideData == null
              ? 'payload_not_map'
              : _popupServerSkipReason(
                      rideId,
                      rideData,
                      marketDiscoveryStage: true,
                    ) ??
                  '';
          final qualifies = rideData != null &&
              DriverFeatureFlags.activeRequestServiceTypes.contains(
                _serviceTypeKey(rideData['service_type']),
              ) &&
              skipReason.isEmpty;
          if (!qualifies) {
            final expectedMarket = driverCity;
            final actualMarket = rideData == null
                ? ''
                : (_rideMarketFromData(rideData) ?? '');
            final rawStatus = rideData == null
                ? ''
                : _valueAsText(rideData[RtdbRideRequestFields.status]);
            final rawTripState = rideData == null
                ? ''
                : _valueAsText(rideData[RtdbRideRequestFields.tripState]);
            final rawDriverId = rideData == null
                ? ''
                : _valueAsText(rideData[RtdbRideRequestFields.driverId]);
            final rawRequestExpires = rideData == null
                ? ''
                : _valueAsText(rideData['request_expires_at']);
            final rawExpires = rideData == null
                ? ''
                : _valueAsText(rideData['expires_at']);
            final nowMs = DateTime.now().millisecondsSinceEpoch;
            final expiryInfo = rideData == null
                ? (value: 0, field: 'none')
                : _rideExpiryInfo(rideData);
            final expiresEval = expiryInfo.value;
            _logRideReq(
              '[DRIVER_DISCOVERY_REJECT] rideId=$rideId reason='
              '${skipReason.isEmpty ? 'service_type_not_active' : skipReason} '
              'market_expected=$expectedMarket market_actual=$actualMarket '
              'status=$rawStatus trip_state=$rawTripState driver_id=$rawDriverId '
              'request_expires_at=$rawRequestExpires '
              'expires_at=$rawExpires expires_eval_ms=$expiresEval now_ms=$nowMs '
              'delta_ms=${expiresEval > 0 ? nowMs - expiresEval : -1} '
              'chosen_expiry_field=${expiryInfo.field}',
            );
          } else {
            _logRideReq('[DRIVER_DISCOVERY_ACCEPT] rideId=$rideId');
            debugPrint(
              '[DRIVER_REQUEST_RECEIVED] rideId=$rideId '
              'market=${_rideMarketFromData(rideData) ?? ''}',
            );
          }
          _logRideReq(
            'ride discovery evaluation rideId=$rideId status=$status qualifies=$qualifies reason=${skipReason.isEmpty ? 'qualified' : skipReason} source=$source',
          );
          _logRideReq(
            '[MATCH_DEBUG][DRIVER_LISTENER] rideId=$rideId source=$source '
            'status=$status qualifies=$qualifies reason=${skipReason.isEmpty ? 'qualified' : skipReason}',
          );
          _logReqDebug(
            'ride eval rideId=$rideId status=$status qualifies=$qualifies reason=${skipReason.isEmpty ? 'qualified' : skipReason}',
          );
          if (qualifies) {
            activeOpenRideMap[rideId] = rideData;
          }
        }

        _logReqDebug(
          'snapshot count=${rideMap.length} activeOpen=${activeOpenRideMap.length} market=$driverCity',
        );
        _logDriverReq(
          'snapshotCount=${rideMap.length} activeOpenSnapshotCount=${activeOpenRideMap.length} source=$source',
        );
        if (activeOpenRideMap.isEmpty) {
          _logDriverReq('candidateRideId=(none)');
        } else {
          final keys = activeOpenRideMap.keys.toList(growable: false);
          const maxKeys = 24;
          final shown = keys.length <= maxKeys
              ? keys.join(',')
              : '${keys.take(maxKeys).join(',')},+${keys.length - maxKeys}_more';
          _logDriverReq('candidateRideId=$shown');
        }

        _logReqDebug(
          'local currentRideId=${_currentRideId ?? 'null'} '
          'driverActiveRideId=${_driverActiveRideId ?? 'null'} '
          'popupOpen=$_popupOpen hasActivePopup=$_hasActivePopup',
        );

        var reqDebugChild = 0;
        const reqDebugChildMax = 50;
        for (final entry in activeOpenRideMap.entries) {
          if (reqDebugChild >= reqDebugChildMax) {
            _logReqDebug(
              'candidate (+${activeOpenRideMap.length - reqDebugChildMax} more children not logged)',
            );
            break;
          }
          reqDebugChild += 1;
          final cm = _asStringDynamicMap(entry.value);
          if (cm == null) {
            _logReqDebug(
              'candidate rideId=${entry.key} status=(non-map) tripState=(non-map) '
              'driverId=(non-map) market=(non-map) serviceType=(non-map)',
            );
            continue;
          }
          _logReqDebug(
            'candidate rideId=${entry.key} '
            'status=${_valueAsText(cm['status'])} '
            'tripState=${_valueAsText(cm['trip_state'])} '
            'driverId=${_valueAsText(cm['driver_id'])} '
            'market=${_valueAsText(cm['market'])} '
            'serviceType=${_valueAsText(cm['service_type'])}',
          );
        }

        _logRideReq(
          'request listener snapshot source=$source rawChildCount=${rideMap.length} activeOpenCount=${activeOpenRideMap.length} market=$driverCity',
        );
        _logRideReq(
          '[DRIVER_DISCOVERY_SNAPSHOT] source=$source rawChildCount=${rideMap.length} '
          'activeOpenCount=${activeOpenRideMap.length} market=$driverCity',
        );
        _logPopup('snapshot received raw=${rideMap.length} activeOpen=${activeOpenRideMap.length}');
        _logDiscoveryChain(
          'snapshot received raw=${rideMap.length} activeOpen=${activeOpenRideMap.length}',
        );
        if (activeOpenRideMap.isEmpty) {
          _logDiscoveryChain(
            'snapshot_empty query_market_exact=$driverCity '
            '(compare byte-for-byte to ride_requests/{rideId}/market in Firebase console)',
          );
        } else {
          var loggedChildren = 0;
          const maxChildLogs = 30;
          for (final entry in activeOpenRideMap.entries) {
            if (loggedChildren >= maxChildLogs) {
              _logDiscoveryChain(
                'snapshot_children_truncated total=${activeOpenRideMap.length} logged=$maxChildLogs',
              );
              break;
            }
            loggedChildren += 1;
            final rawChild = entry.value;
            final childMap = _asStringDynamicMap(rawChild);
            final cm = childMap == null ? '?' : _valueAsText(childMap['market']);
            final cs = childMap == null ? '?' : _valueAsText(childMap['status']);
            final cst =
                childMap == null ? '?' : _valueAsText(childMap['trip_state']);
            final csrv = childMap == null
                ? '?'
                : _valueAsText(childMap['service_type']);
            _logDiscoveryChain(
              'snapshot_child rideId=${entry.key} market=$cm status=$cs '
              'trip_state=$cst service_type=$csrv',
            );
          }
        }

        if (!_isOnline) {
          _logDriverReq('skippedReason=driver_offline source=$source');
          _logRideReq('snapshot ignored driver offline source=$source');
          _logPopup('skipped reason=driver_offline');
          _logDiscoveryChain('skipped reason=driver_offline source=$source');
          return;
        }

        final activePopupRideId = _activePopupRideId;
        if ((_popupOpen || _hasActivePopup) &&
            activePopupRideId != null &&
            _acceptingPopupRideId != activePopupRideId) {
          final aid = activePopupRideId.trim();
          final skipUnavailableDismissal =
              _foreverSuppressedRidePopupIds.contains(aid) ||
                  _terminalSelfAcceptedRideIds.contains(aid) ||
                  _currentRideId == activePopupRideId ||
                  _driverActiveRideId == activePopupRideId;
          if (skipUnavailableDismissal) {
            _logRideReq(
              '[MATCH_DEBUG][UNAVAILABLE_RENDER_BLOCKED] rideId=$activePopupRideId '
              'forever=${_foreverSuppressedRidePopupIds.contains(aid)} '
              'terminal=${_terminalSelfAcceptedRideIds.contains(aid)} '
              'currentRide=$_currentRideId driverActive=$_driverActiveRideId',
            );
            if (_terminalSelfAcceptedRideIds.contains(aid)) {
              _logRideReq(
                '[MATCH_DEBUG][UNAVAILABLE_SKIPPED_SELF_ACCEPTED] rideId=$activePopupRideId '
                'source=discovery_popup_dismissal_guard',
              );
            }
          } else {
            var activePopupRideData =
                _asStringDynamicMap(rideMap[activePopupRideId]);
            if (activePopupRideData == null) {
              _logRideReq(
                '[DRIVER_DISCOVERY_TRACE] skip direct read path=ride_requests/$activePopupRideId reason=query_only_rules',
              );
            }
            final activePopupRide = _matchRideForPopup(
              activePopupRideId,
              activePopupRideData,
              ignoreLocalState: true,
            );
            if (activePopupRide == null && mounted) {
              final dismissalReason = _popupServerSkipReason(
                activePopupRideId,
                activePopupRideData,
              );
              if (!_shouldDismissPopupForServerReason(dismissalReason)) {
                _logRtdb(
                  'popup kept open rideId=$activePopupRideId reason=${dismissalReason ?? 'transient'}',
                );
                return;
              }
              if (_popupDismissedRideId != activePopupRideId) {
                _popupDismissedRideId = activePopupRideId;
                _popupDismissedReason = dismissalReason;
                if (_rideBelongsToAnotherDriver(activePopupRideData)) {
                  _logRtdb('accept lost rideId=$activePopupRideId');
                }
              }
              if (!mounted) {
                return;
              }
              unawaited(Navigator.of(context, rootNavigator: true).maybePop());
            }
          }
        }

        // Do not gate on [_rideStatus] here: stale non-idle status must not block
        // incoming offers. Active-trip blocking was removed so drivers still receive
        // the open-pool stream while assigned (queue handles concurrent popups).

        final candidates = <_MatchedRideRequest>[];
        var skipLogBudget = 6;
        var seenLogBudget = 8;
        for (final entry in activeOpenRideMap.entries) {
          final entryData = entry.value;
          if (seenLogBudget > 0) {
            seenLogBudget -= 1;
            _logRideReq('candidate seen rideId=${entry.key} service=ride');
          }
          _maybeUnsuppressOpenPoolRide(entry.key, entryData);
          final matchedRide = _matchRideForPopup(
            entry.key,
            entry.value,
            logCandidate: true,
            marketDiscoveryCandidate: true,
          );
          if (matchedRide != null) {
            final mkt = _valueAsText(entryData['market']);
            final st = _valueAsText(entryData['status']);
            final did = _valueAsText(entryData['driver_id']);
            _logPopup(
              'candidate rideId=${entry.key} status=$st market=$mkt driverId=$did',
            );
            _logDiscoveryChain(
              'candidate rideId=${entry.key} status=$st market=$mkt driverId=$did',
            );
            candidates.add(matchedRide);
          } else {
            final serverSkip = _popupServerSkipReason(
              entry.key,
              entryData,
              marketDiscoveryStage: true,
            );
            final localSkip = _popupLocalSkipReason(entry.key);
            final skipReason = localSkip ?? serverSkip ?? 'unknown';
            _logReqDebug('skip rideId=${entry.key} reason=$skipReason');
            if (skipLogBudget > 0) {
              skipLogBudget -= 1;
              _logRideReq(
                'candidate skipped rideId=${entry.key} server=${serverSkip ?? 'ok'} '
                'local=${localSkip ?? 'ok'}',
              );
              _logPopup('skipped reason=$skipReason');
              _logDiscoveryChain(
                'candidate_filtered rideId=${entry.key} skipped reason=$skipReason',
              );
            }
          }
        }

        if (candidates.isEmpty) {
          if (activeOpenRideMap.isNotEmpty) {
            for (final entry in activeOpenRideMap.entries) {
              final ed = entry.value;
              final skip = _popupServerSkipReason(
                entry.key,
                ed,
                marketDiscoveryStage: true,
              );
              _logRtdb(
                'dispatch skip sample rideId=${entry.key} reason=${skip ?? 'unknown'} driverCity=$driverCity driverLoc=${_driverLocation.latitude},${_driverLocation.longitude}',
              );
              _logRideReq(
                'no dispatchable candidates (sample) rideId=${entry.key} reason=${skip ?? 'unknown'}',
              );
              break;
            }
          }
          _logRideReq('no candidates after filter source=$source');
          if (activeOpenRideMap.isEmpty) {
            _logDriverReq('skippedReason=snapshot_empty source=$source');
          } else {
            _logDriverReq(
              'skippedReason=no_dispatchable_candidates source=$source',
            );
          }
          _logListenerStillActiveWaitingForFreshRides();
          return;
        }

        candidates.sort((a, b) {
          if (a.sameArea != b.sameArea) {
            return a.sameArea ? -1 : 1;
          }
          final distanceCompare = a.distanceMeters.compareTo(b.distanceMeters);
          if (distanceCompare != 0) {
            return distanceCompare;
          }
          return a.createdAt.compareTo(b.createdAt);
        });
        final matchedRide = candidates.first;
        _logRtdb(
          'candidate request found rideId=${matchedRide.rideId} city=$driverCity serviceType=${matchedRide.serviceType} source=$source',
        );

        final latestDiscoverySnapshotValue = matchedRide.rideData;
        final recheckedRide = _matchRideForPopup(
          matchedRide.rideId,
          latestDiscoverySnapshotValue,
          logCandidate: false,
          marketDiscoveryCandidate: true,
        );
        if (recheckedRide == null) {
          _logRidePopup(
            'skip rideId=${matchedRide.rideId} reason=pre_show_recheck_failed',
          );
          _logDriverReq(
            'skippedReason=pre_show_recheck_failed rideId=${matchedRide.rideId} source=$source',
          );
          _logRideReq(
            'popup blocked pre-show recheck failed rideId=${matchedRide.rideId} source=$source',
          );
          _logPopup('skipped reason=pre_show_recheck_failed');
          _logDiscoveryChain(
            'skipped reason=pre_show_recheck_failed rideId=${matchedRide.rideId}',
          );
          _logRideRequestDiscoveryRecheckSuppressed(
            matchedRide.rideId,
            _asStringDynamicMap(latestDiscoverySnapshotValue),
          );
          _logListenerStillActiveWaitingForFreshRides();
          return;
        }

        for (var i = 1; i < candidates.length; i++) {
          _enqueueRideRequestPopupIfIdleSlot(candidates[i]);
        }
        if (_popupOpen || _hasActivePopup) {
          _enqueueRideRequestPopupIfIdleSlot(recheckedRide);
          _logDriverReq(
            'skippedReason=popup_busy_queued rideId=${recheckedRide.rideId} '
            'open=$_popupOpen hasActive=$_hasActivePopup '
            'queue_depth=${_rideRequestPopupQueue.length} source=$source',
          );
          _logRideReq(
            '[DISCOVERY_QUEUE] deferred primary rideId=${recheckedRide.rideId} '
            'queue_depth=${_rideRequestPopupQueue.length} source=$source',
          );
          _logPopup(
            'queued reason=popup_busy rideId=${recheckedRide.rideId} '
            'depth=${_rideRequestPopupQueue.length}',
          );
          _logDiscoveryChain(
            'snapshot_queued popup_busy rideId=${recheckedRide.rideId} '
            'depth=${_rideRequestPopupQueue.length} source=$source',
          );
          _logListenerStillActiveWaitingForFreshRides();
          return;
        }

        _currentCandidateRideId = recheckedRide.rideId;
        _logRideReq(
          'popup opening rideId=${recheckedRide.rideId} source=$source (calling showRideRequestPopup)',
        );
        _logCanonicalRideEvent(
          eventName: 'ride_offered',
          rideId: recheckedRide.rideId,
          rideData: recheckedRide.rideData,
        );
        _logReqDebug('popup OPEN rideId=${recheckedRide.rideId}');
        _logPopupFix('opening popup rideId=${recheckedRide.rideId}');
        _logPopup('opening rideId=${recheckedRide.rideId}');
        _logDiscoveryChain('popup opening rideId=${recheckedRide.rideId}');
        if (_ridePopupOpenPipelineLocked) {
          _enqueueRideRequestPopupIfIdleSlot(recheckedRide);
          _logRidePopup(
            'queued rideId=${recheckedRide.rideId} reason=pipeline_locked',
          );
          if (_currentCandidateRideId == recheckedRide.rideId) {
            _currentCandidateRideId = null;
          }
        } else {
          _ridePopupOpenPipelineLocked = true;
          try {
            await showRideRequestPopup(recheckedRide);
          } finally {
            _ridePopupOpenPipelineLocked = false;
          }
        }
    }

    Future<void> queueSnapshotProcessing(
      rtdb.DataSnapshot snapshot, {
      required String source,
      required int listenerToken,
    }) async {
      snapshotProcessingChain = snapshotProcessingChain
          .catchError((Object _) {})
          .then(
            (_) => processSnapshot(
              snapshot,
              source: source,
              listenerToken: listenerToken,
            ),
          );
      await snapshotProcessingChain;
    }

    if (_rideRequestSubscription != null &&
        _rideRequestsListenerBoundCity == driverCity) {
      _logRideReq(
        'request listener refresh same market=$driverCity reason=$reason '
        '(no extra .get — iOS avoids concurrent query.get + onValue on same Query)',
      );
      _logRideReq(
        '[MATCH_DEBUG][DRIVER_ATTACH] noop_refresh market=$driverCity reason=$reason '
        'activeStream=true',
      );
      _logPopup('listener already bound market=$driverCity refresh noop');
      _logDiscoveryChain(
        'online attach refresh (already bound) market=$driverCity reason=$reason',
      );
      _logRtdb(
        'ride request listener refresh city=$driverCity reason=$reason',
      );
      return true;
    }

    await _cancelRideRequestListener(
      reason: 'before_attach_market_$driverCity',
    );
    // Let the native RTDB client finish tearing down the previous query before
    // registering a new ValueEventListener (iOS: tracked-keys assertion).
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _rideRequestListenerToken += 1;
    final listenerToken = _rideRequestListenerToken;
    _rideRequestsListenerBoundCity = driverCity;

    try {
      final discoveryUid = _effectiveDriverId.trim();
      if (discoveryUid.isEmpty) {
        _rideRequestsListenerBoundCity = null;
        rtdbFlowLog(
          '[DRIVER_LISTENER_FAIL]',
          'uid=empty market=$driverCity op=abort reason=missing_driver_id',
        );
        return false;
      }
      rtdbFlowLog(
        '[MATCH_FLOW]',
        'phase=precheck_discovery uid=$discoveryUid market=$driverCity',
      );
      rtdbFlowLog(
        '[RULES_PATH]',
        'path=drivers/$discoveryUid op=get context=discovery_precheck',
      );
      try {
        final driverSnap = await _driversRef.child(discoveryUid).get();
        final driverMap = _asStringDynamicMap(driverSnap.value);
        final precheckMarket = _valueAsText(driverMap?['market']);
        final precheckCity = _valueAsText(driverMap?['city']);
        rtdbFlowLog(
          '[DRIVER_LISTENER_START]',
          'drivers_exists=${driverSnap.exists} uid=$discoveryUid market=$driverCity',
        );
        _logRideReq(
          '[DRIVER_DISCOVERY_TRACE] precheck drivers/$discoveryUid exists=${driverSnap.exists} market=${precheckMarket.isEmpty ? 'missing' : precheckMarket} city=${precheckCity.isEmpty ? 'missing' : precheckCity}',
        );
        if (!driverSnap.exists) {
          final u = FirebaseAuth.instance.currentUser;
          if (u != null && u.uid == discoveryUid) {
            rtdbFlowLog(
              '[DRIVER_PROFILE_REPAIR]',
              'uid=$discoveryUid reason=precheck_missing op=fetchDriverProfileRecord',
            );
            await fetchDriverProfileRecord(
              rootRef: rtdb.FirebaseDatabase.instance.ref(),
              user: u,
              source: 'driver_map_discovery_precheck',
              role: AppRole.driver,
              createIfMissing: true,
            );
          }
        }
      } catch (precheckError) {
        rtdbFlowLog(
          '[DRIVER_LISTENER_FAIL]',
          'uid=$discoveryUid market=$driverCity op=precheck error=$precheckError',
        );
      }
      try {
        final probe = await _rideRequestsRef
            .orderByChild('market_pool')
            .equalTo(driverCity)
            .limitToFirst(3)
            .get();
        final probeMap = _asStringDynamicMap(probe.value);
        _logRideReq(
          '[DRIVER_DISCOVERY_TRACE] one_shot_query_ok exists=${probe.exists} sample_count=${probeMap?.length ?? 0}',
        );
      } catch (probeError) {
        final denied = isRealtimeDatabasePermissionDenied(probeError);
        _logRideReq(
          '[DRIVER_DISCOVERY_TRACE] one_shot_query_fail permissionDenied=$denied error=$probeError',
        );
      }

      _logRideReq(
        'request listener STREAM subscribed market=$driverCity reason=$reason token=$listenerToken',
      );
      debugPrint(
        '[RTDB_DISCOVERY] STREAM_SUBSCRIBE path=ride_requests?orderByChild=market_pool&equalTo=$driverCity '
        'market=$driverCity authUid=${FirebaseAuth.instance.currentUser?.uid ?? 'none'}',
      );
      _logRideReq(
        '[MATCH_DEBUG][QUERY_ATTACH:ride_requests?orderByChild=market_pool&equalTo=$driverCity] '
        'discovery onValue',
      );
      _rideRequestSubscription = rideRequestsQuery.onValue.listen(
        (event) async {
          _clearDiscoveryPermissionDeniedNotice(source: 'listener_event');
          _rideDiscoveryListenerHealthy = true;
          try {
            await queueSnapshotProcessing(
              event.snapshot,
              source: 'stream',
              listenerToken: listenerToken,
            );
          } catch (error) {
            _log('ride listener snapshot handling failed error=$error');
            _logRideReq('snapshot handler ERROR source=stream error=$error');
          }
        },
        onError: (Object error) async {
          final staleCallback = listenerToken != _rideRequestListenerToken ||
              _rideRequestsListenerBoundCity != driverCity;
          if (staleCallback) {
            _logRideReq(
              '[DRIVER_DISCOVERY_TRACE] stale_listener_error_ignored token=$listenerToken '
              'activeToken=$_rideRequestListenerToken boundCity=${_rideRequestsListenerBoundCity ?? 'none'} '
              'market=$driverCity error=$error',
            );
            return;
          }
          print('[TRACE] RTDB ERROR = $error');
          final uid = FirebaseAuth.instance.currentUser?.uid ?? 'none';
          final denied = isRealtimeDatabasePermissionDenied(error);
          final code = _firebaseErrorCode(error);
          final message = _firebaseErrorMessage(error);
          _rideDiscoveryListenerHealthy = false;
          debugPrint(
            '[DRIVER_BACKEND] op=ride_discovery_stream_error authUid=$uid '
            'driverProfilePath=${uid == 'none' ? 'drivers/(none)' : driverProfilePath(uid)} '
            'query=ride_requests.orderByChild(market_pool).equalTo($driverCity) '
            'permissionDenied=$denied code=$code message=$message',
          );
          debugPrint(
            '[RTDB_DISCOVERY] STREAM_ERROR path=ride_requests?orderByChild=market_pool&equalTo=$driverCity '
            'market=$driverCity authUid=$uid permissionDenied=$denied code=$code error=$message',
          );
          rtdbFlowLog(
            '[DRIVER_LISTENER_FAIL]',
            'uid=$uid market=$driverCity op=onValue_stream denied=$denied error=$error',
          );
          _log('ride listener error code=$code message=$message');
          _logRideReq(
            'request listener stream ERROR market=$driverCity code=$code message=$message',
          );
          if (isRealtimeDatabasePermissionDenied(error)) {
            print('RIDE_DISCOVERY_PERMISSION_DENIED');
            debugPrint(
              'RTDB_PERMISSION_ERROR_FULL '
              'error=$error code=$code message=$message '
              'path=ride_requests orderByChild=market_pool equalTo=$driverCity',
            );
            _logDriverReq('skippedReason=rtdb_permission_denied_stream error=$error');
            unawaited(
              _cancelRideRequestListener(
                reason: 'permission_denied_stream_market_$driverCity',
              ),
            );
            _logRtdb(
              'ride_requests discovery stream permission denied (logged for engineering; '
              'snackbar shows user-safe copy)',
            );
            try {
              final debugUid = FirebaseAuth.instance.currentUser?.uid ?? 'none';
              final debugPath = debugUid == 'none'
                  ? 'drivers/(none)'
                  : driverProfilePath(debugUid);
              final debugDriver = debugUid == 'none'
                  ? null
                  : await _driversRef.child(debugUid).get();
              final debugMap = _asStringDynamicMap(debugDriver?.value);
              _logRideReq(
                '[DRIVER_DISCOVERY_TRACE] permission_denied_snapshot uid=$debugUid '
                'driverProfilePath=$debugPath driverExists=${debugDriver?.exists ?? false} '
                'driverData=${debugMap ?? {}} queryPath=ride_requests queryOrderByChild=market_pool queryEqualTo=$driverCity',
              );
            } catch (snapshotError) {
              _logRideReq(
                '[DRIVER_DISCOVERY_TRACE] permission_denied_snapshot_failed error=$snapshotError',
              );
            }
            _clearDiscoveryPermissionDeniedNotice(
              source: 'listener_permission_denied_no_blocking_notice',
            );
            return;
          } else {
            _showSnackBarSafely(
              SnackBar(
                content: Text(_discoveryListenerFailureMessage(error)),
                action: SnackBarAction(
                  label: 'Retry now',
                  onPressed: () {
                    unawaited(
                      _listenForRideRequests(
                        reason: 'snackbar_retry_after_stream_error',
                      ),
                    );
                  },
                ),
              ),
            );
            _logRideReq(
              '[DRIVER_DISCOVERY_TRACE] snackbar_state=set_stream_error source=listener_non_permission',
            );
          }
          return;
        },
      );
      _logRideReq(
        '[MATCH_DEBUG][DRIVER_ATTACH] market=$driverCity token=$listenerToken '
        'reason=$reason prime_get=skipped_ios_safe',
      );
      _rideDiscoveryListenerHealthy = true;
      _logRideReq(
        '[MATCH_DEBUG][DRIVER_LISTENER_ATTACH_OK] market=$driverCity token=$listenerToken',
      );
      _logRtdb(
        'listener prime skipped (onValue initial snapshot only) city=$driverCity',
      );
      _logRideReq(
        'request listener PRIME skipped market=$driverCity '
        '(rely on onValue only; no query.get while listener active)',
      );
      _logReqDebug('listener attach OK market=$driverCity');
      _logRideReq('[DRIVER_DISCOVERY_TRACE] listener attach OK');
      _clearDiscoveryPermissionDeniedNotice(source: 'listener_attach_success');
      _logPopup('online attach success');
      _logDiscoveryChain('online attach success market=$driverCity reason=$reason');
      print('RIDE_DISCOVERY_ATTACH_SUCCESS');
      return true;
    } catch (error) {
      if (isRealtimeDatabasePermissionDenied(error)) {
        print('RIDE_DISCOVERY_PERMISSION_DENIED');
        debugPrint(
          'RTDB_PERMISSION_ERROR_FULL '
          'error=$error path=ride_requests orderByChild=market_pool equalTo=$driverCity',
        );
      }
      final code = _firebaseErrorCode(error);
      final message = _firebaseErrorMessage(error);
      _rideRequestsListenerBoundCity = null;
      _rideDiscoveryListenerHealthy = false;
      _logReqDebug('listener attach FAIL error=$error');
      _logDriverReq(
        'skippedReason=listener_attach_failed market=$driverCity reason=$reason code=$code message=$message',
      );
      _log(
          'ride listener attach failed city=$driverCity reason=$reason code=$code message=$message');
      _logRideReq(
        'request listener ATTACH FAILED market=$driverCity reason=$reason error=$error',
      );
      _logPopup('listener attach FAILED error=$error');
      _logDiscoveryChain('listener attach FAILED error=$error');
      if (!isRealtimeDatabasePermissionDenied(error)) {
        _showAvailabilityFailureNotice(_discoveryListenerFailureMessage(error));
      } else {
        _clearDiscoveryPermissionDeniedNotice(
          source: 'attach_permission_denied_no_blocking_notice',
        );
      }
      if (isRealtimeDatabasePermissionDenied(error)) {
        final uid = FirebaseAuth.instance.currentUser?.uid ?? 'none';
        _logRideReq(
          '[DRIVER_DISCOVERY_TRACE] attach_permission_denied uid=$uid queryPath=ride_requests '
          'queryOrderByChild=market_pool queryEqualTo=$driverCity code=$code message=$message',
        );
        return false;
      }
      return false;
    }
  }

  Future<void> _applyActiveRideSnapshot({
    required String rideId,
    required Map<String, dynamic> rideData,
    required String status,
  }) async {
    if (_valueAsText(rideData['driver_id']) != _effectiveDriverId) {
      _logInvalidRideBlocked(rideId: rideId, reason: 'driver_mismatch');
      await _hardResetToFreshSearchSession(
        reason: 'not_assigned_to_driver',
      );
      return;
    }

    final validationReason = _activeRideInvalidReason(
      rideData,
      rideId: rideId,
    );

    if (validationReason != null) {
      _logUi('snapshot rejected - invalid');
      _logInvalidRideBlocked(rideId: rideId, reason: validationReason);
      await _clearDriverActiveRideNode(
        rideId: rideId,
        reason: validationReason,
      );
      await _clearActiveRideState(
        reason: validationReason,
        resetTripState: true,
      );
      return;
    }

    _logGuard('applying ride id=$rideId');
    _trackRideForCurrentSession(rideId);
    _driverActiveRideId = rideId;
    _startCallListener(rideId);

    final previousRideId = _currentRideId;
    final previousStatus = _rideStatus;
    final rideChanged = previousRideId != rideId;
    final statusChanged = previousStatus != status;

    if (statusChanged) {
      _log(
        'active ride status transition rideId=$rideId from=$previousStatus to=$status',
      );
      _logRideReq(
        '[MATCH_DEBUG][DRIVER_RIDE_STATUS] rideId=$rideId from=$previousStatus to=$status',
      );
    }

    if (mounted) {
      setState(() {
        _currentRideId = rideId;
        _currentRideData = Map<String, dynamic>.from(rideData);
        _rideStatus = status;
        _tripStarted = status == 'on_trip';
        if (rideChanged) {
          _driverUnreadChatCount = 0;
          _isDriverChatOpen = false;
        }
      });
    } else {
      _currentRideId = rideId;
      _currentRideData = Map<String, dynamic>.from(rideData);
      _rideStatus = status;
      _tripStarted = status == 'on_trip';
      if (rideChanged) {
        _driverUnreadChatCount = 0;
        _isDriverChatOpen = false;
      }
    }

    _applyRideLocationsFromData(rideData);

    _log(
      'active ride loaded rideId=$rideId status=$status stopCount=${_tripWaypoints.length}',
    );

    if (rideChanged) {
      _loggedDriverChatMessageIds.clear();
      _startDriverChatListener(rideId);
    }

    unawaited(
      _loadRiderDetails(
        rideId: rideId,
        rideData: rideData,
      ),
    );

    _evaluateArrivedAvailability();

    if (status == 'on_trip') {
      _startDriverSafetyMonitoring(rideId);
    } else if (previousStatus == 'on_trip') {
      _stopDriverSafetyMonitoring();
    }

    _scheduleActiveRouteRefresh(
      force: rideChanged || statusChanged,
      reason: 'active_ride_listener',
      debounce: Duration.zero,
    );
    _refreshIosDriverMapIfNeeded(reason: 'active_ride_listener');
  }

  Future<void> showRideRequestPopup(
    _MatchedRideRequest ride, {
    bool rideAlreadyReserved = false,
  }) async {
    _logRideReq(
      'showRideRequestPopup enter rideId=${ride.rideId} reserved=$rideAlreadyReserved '
      'online=$_isOnline popupOpen=$_popupOpen hasActive=$_hasActivePopup',
    );
    if (_isTerminalSelfAcceptedRide(ride.rideId)) {
      _logRideReq(
        '[MATCH_DEBUG][POPUP_SUPPRESSED_SELF_ACCEPTED] rideId=${ride.rideId} '
        'source=showRideRequestPopup_entry_terminal',
      );
      _logRidePopup(
        'skip rideId=${ride.rideId} reason=terminal_self_accepted',
      );
      return;
    }
    if (_foreverSuppressedRidePopupIds.contains(ride.rideId.trim())) {
      _logRideReq(
        '[MATCH_DEBUG][POPUP_SUPPRESSED_ACCEPTED] rideId=${ride.rideId} '
        'source=showRideRequestPopup_entry',
      );
      _logRidePopup(
        'skip rideId=${ride.rideId} reason=forever_suppressed_after_accept',
      );
      return;
    }

    final dedupRideId = ride.rideId.trim();
    if (_presentedRideIds.contains(dedupRideId) &&
        _activePopupRideId != dedupRideId) {
      _logRideReq(
        '[MATCH_DEBUG][POPUP_DEDUP] rideId=$dedupRideId '
        'source=showRideRequestPopup_entry reason=already_presented_elsewhere',
      );
      _logRidePopup(
        'skip rideId=$dedupRideId reason=popup_dedup_same_ride_id',
      );
      return;
    }

    if (!_isOnline) {
      _logRidePopup(
        'skip rideId=${ride.rideId} reason=driver_offline',
      );
      _logRideReq(
        'popup blocked reason=driver_offline rideId=${ride.rideId}',
      );
      _log(
        'ride request popup blocked because driver is offline rideId=${ride.rideId}',
      );
      return;
    }

    if (_popupOpen || _hasActivePopup) {
      _enqueueRideRequestPopupIfIdleSlot(ride);
      _logRidePopup(
        'queued rideId=${ride.rideId} reason=popup_already_active '
        'open=$_popupOpen hasActive=$_hasActivePopup activePopup=$_activePopupRideId '
        'depth=${_rideRequestPopupQueue.length}',
      );
      _logRideReq(
        'popup deferred to queue reason=popup_already_active rideId=${ride.rideId} '
        'open=$_popupOpen hasActive=$_hasActivePopup activePopup=$_activePopupRideId '
        'queue_depth=${_rideRequestPopupQueue.length}',
      );
      return;
    }

    _logRidePopup('open rideId=${ride.rideId} reserved=$rideAlreadyReserved');

    _popupOpen = true;
    _hasActivePopup = true;
    _activePopupRideId = ride.rideId;
    _currentCandidateRideId = ride.rideId;
    _popupDismissedRideId = null;
    _popupDismissedReason = null;
    var popupTimedOut = false;
    var remainingSeconds = _kRidePopupCountdownSeconds;
    var isAccepting = false;
      var rideReserved = rideAlreadyReserved;
    var rideAccepted = false;
    StateSetter? dialogSetState;

    try {
      var popupRide =
          rideAlreadyReserved ? ride : await _loadLivePopupRide(ride.rideId);
      if (popupRide == null) {
        _logRidePopup('skip rideId=${ride.rideId} reason=live_load_null');
        _logRideReq(
          'popup blocked reason=live_load_null rideId=${ride.rideId}',
        );
        if (_currentCandidateRideId == ride.rideId) {
          _currentCandidateRideId = null;
        }
        _clearRidePreview();
        _rearmRideRequestListener('popup blocked rideId=${ride.rideId}');
        return;
      }

      final localAfterLive = _popupLocalSkipReason(popupRide.rideId);
      if (localAfterLive != null) {
        _logRidePopup(
          'skip rideId=${popupRide.rideId} reason=$localAfterLive',
        );
        if (_currentCandidateRideId == ride.rideId) {
          _currentCandidateRideId = null;
        }
        _clearRidePreview();
        _rearmRideRequestListener(
          'popup local skip rideId=${popupRide.rideId} reason=$localAfterLive',
        );
        return;
      }

      if (_currentCandidateRideId != popupRide.rideId) {
        _logRidePopup(
          'skip rideId=${popupRide.rideId} reason=candidate_mismatch '
          'expected=$_currentCandidateRideId',
        );
        _logRideReq(
          'popup blocked reason=candidate_mismatch expected=$_currentCandidateRideId '
          'got=${popupRide.rideId}',
        );
        _clearRidePreview();
        return;
      }

      _applyRideLocationsFromData(popupRide.rideData);

      final pickupAddress = _popupAddressLabel(
        _valueAsText(popupRide.rideData['pickup_address']),
        popupRide.pickup,
      );
      final destinationAddress = _popupAddressLabel(
        _destinationAddressFromRideData(popupRide.rideData),
        popupRide.destination,
      );
      final distanceKm =
          _calculateDistanceKm(_driverLocation, popupRide.pickup);
      final etaMinutes = _calculateEtaMinutes(distanceKm);

      final fareBreakdown =
          _asStringDynamicMap(popupRide.rideData['fare_breakdown']);
      final rawFare = popupRide.rideData['fare'] ??
          fareBreakdown?['totalFare'] ??
          fareBreakdown?['total_fare'];
      final fareValue = _asDouble(rawFare)?.round() ?? 0;
      final serviceSupported =
          _isSupportedDriverServiceType(popupRide.serviceType);
      final profile = await _fetchDriverProfile();
      final verification =
          normalizedDriverVerification(profile['verification']);
      final driverName = (widget.driverName.trim().isNotEmpty
              ? widget.driverName.trim()
              : profile['name']?.toString().trim()) ??
          'Driver';
      final car = widget.car.trim().isNotEmpty
          ? widget.car.trim()
          : profile['car']?.toString().trim() ?? '';
      final plate = widget.plate.trim().isNotEmpty
          ? widget.plate.trim()
          : profile['plate']?.toString().trim() ?? '';
      final serviceApproved = driverServiceCanReceiveRequests(
        verification,
        popupRide.serviceType,
      );
      final canAcceptService = serviceSupported && serviceApproved;
      final serviceRestrictionMessage = !serviceSupported
          ? '${_serviceTypeLabel(popupRide.serviceType)} is not enabled for drivers yet. You can close this request safely.'
          : driverServiceRestrictionMessage(
              verification,
              popupRide.serviceType,
            );
      final popupHeadline = fareValue > 0
          ? '₦$fareValue'
          : _serviceTypeLabel(popupRide.serviceType);
      final packageDetails = _dispatchPackageDetails(popupRide.rideData);
      final recipientSummary = _dispatchRecipientSummary(popupRide.rideData);
      final packagePhotoUrl = _dispatchPackagePhotoUrl(popupRide.rideData);
      final riderTrustSnapshot =
          _riderTrustSnapshotFromRide(popupRide.rideData);
      final popupVerificationStatus = _valueAsText(
        riderTrustSnapshot['verificationStatus'],
      ).isEmpty
          ? 'unverified'
          : _normalizedRiderVerificationStatus(
              _valueAsText(riderTrustSnapshot['verificationStatus']),
            );
      final popupVerifiedBadge = _shouldShowVerifiedBadge(
        verificationStatus: popupVerificationStatus,
        rawBadge: riderTrustSnapshot['verifiedBadge'] == true,
      );
      final popupRating = _asDouble(riderTrustSnapshot['rating']) ?? 5.0;
      final popupRatingCount = _asInt(riderTrustSnapshot['ratingCount']) ?? 0;
      final popupRiskStatus =
          _valueAsText(riderTrustSnapshot['riskStatus']).isEmpty
              ? 'clear'
              : _valueAsText(riderTrustSnapshot['riskStatus']);
      final popupPaymentStatus =
          _valueAsText(riderTrustSnapshot['paymentStatus']).isEmpty
              ? 'clear'
              : _valueAsText(riderTrustSnapshot['paymentStatus']);
      final popupCashAccessStatus =
          _valueAsText(riderTrustSnapshot['cashAccessStatus']).isEmpty
              ? 'enabled'
              : _valueAsText(riderTrustSnapshot['cashAccessStatus']);
      final popupPaymentWarningLabel = _riderPaymentWarningLabel(
        paymentStatus: popupPaymentStatus,
        cashAccessStatus: popupCashAccessStatus,
        outstandingCancellationFeesNgn: 0,
        nonPaymentReports: 0,
      );

      if (!canAcceptService) {
        _popupDismissedReason = 'service_not_supported_for_driver';
        _logRideReq(
          'popup blocked reason=service_not_supported rideId=${popupRide.rideId} '
          'serviceSupported=$serviceSupported serviceApproved=$serviceApproved '
          'serviceType=${popupRide.serviceType}',
        );
        _clearRidePreview();
        _rearmRideRequestListener(
          'ride skipped rideId=${popupRide.rideId} reason=${_popupDismissedReason!}',
        );
        return;
      }

      // Hard reset behavior: keep `ride_requests/{rideId}` open until an atomic
      // accept transaction commits. Do not pre-reserve via pending state.
      rideReserved = false;

      final refreshedPopupRide = await _loadLivePopupRide(
        popupRide.rideId,
        logSkips: false,
      );
      if (refreshedPopupRide == null) {
        _logRideReq(
          'popup blocked reason=post_reserve_refresh_null rideId=${popupRide.rideId}',
        );
        _clearRidePreview();
        _rearmRideRequestListener('popup blocked rideId=${popupRide.rideId}');
        return;
      }
      popupRide = refreshedPopupRide;
      final assignmentExpiresAt =
          _assignmentExpiryTimestamp(popupRide.rideData);
      if (assignmentExpiresAt > 0) {
        remainingSeconds = math.max(
          1,
          ((assignmentExpiresAt - DateTime.now().millisecondsSinceEpoch) / 1000)
              .ceil(),
        );
      }

      final previewRide = popupRide;
      _clearRouteOverlay();
      _syncTripLocationMarkers();
      _schedulePopupRoutePreview(
        rideId: previewRide.rideId,
        origin: _driverLocation,
        destination: previewRide.pickup,
        reason: 'driver_popup_preview',
        debounce: Duration.zero,
      );
      unawaited(_playSound());

      if (!mounted) {
        _logRideReq(
          'popup blocked reason=not_mounted_after_preview rideId=${popupRide.rideId}',
        );
        _presentedRideIds.remove(popupRide.rideId.trim());
        return;
      }

      if (_popupDismissedRideId == popupRide.rideId) {
        _logRideReq(
          'popup blocked reason=already_dismissed rideId=${popupRide.rideId} '
          'dismissReason=$_popupDismissedReason',
        );
        _clearRidePreview();
        _rearmRideRequestListener(
          'popup blocked rideId=${popupRide.rideId} reason=${_popupDismissedReason ?? 'unavailable'}',
        );
        return;
      }

      final activePopupRide = popupRide;
      _presentedRideIds.add(activePopupRide.rideId.trim());
      _logRideReq(
        'popup UI showDialog rideId=${activePopupRide.rideId} countdown=$_kRidePopupCountdownSeconds',
      );
      _logRideReq(
        '[DRIVER_POPUP_SHOW] rideId=${activePopupRide.rideId} '
        'market=${_rideMarketFromData(activePopupRide.rideData) ?? 'missing'} '
        'status=${_valueAsText(activePopupRide.rideData['status'])} '
        'trip_state=${_valueAsText(activePopupRide.rideData['trip_state'])}',
      );
      debugPrint(
        '[DRIVER_POPUP_SHOWN] rideId=${activePopupRide.rideId}',
      );
      _logDiscoveryChain(
        'popup UI showDialog rideId=${activePopupRide.rideId} countdown=$_kRidePopupCountdownSeconds',
      );
      _logRtdb(
        'popup shown rideId=${activePopupRide.rideId} countdown=$_kRidePopupCountdownSeconds',
      );
      _logCanonicalRideEvent(
        eventName: 'popup_shown',
        rideId: activePopupRide.rideId,
        rideData: activePopupRide.rideData,
      );
      final preShowSnapshot = await _rideRequestChildGetIosSafe(
        activePopupRide.rideId,
        'popup_pre_dialog_gate',
      );
      final preShowBlock = _popupHardGateBeforeDialog(
        activePopupRide.rideId,
        preShowSnapshot.value,
      );
      if (preShowBlock != null) {
        _logRidePopup(
          'skip rideId=${activePopupRide.rideId} reason=pre_dialog_gate_$preShowBlock',
        );
        _logPopup('skipped reason=$preShowBlock');
        _logRideReq(
          'popup blocked reason=pre_dialog_gate rideId=${activePopupRide.rideId} detail=$preShowBlock',
        );
        _presentedRideIds.remove(activePopupRide.rideId.trim());
        _clearRidePreview();
        _rearmRideRequestListener(
          'pre_dialog_gate rideId=${activePopupRide.rideId} reason=$preShowBlock',
        );
        return;
      }

      if (!mounted) {
        _logRideReq(
          'popup blocked reason=not_mounted_after_pre_dialog rideId=${activePopupRide.rideId}',
        );
        _presentedRideIds.remove(activePopupRide.rideId.trim());
        return;
      }

      _logPopup('dialog shown rideId=${activePopupRide.rideId}');
      _clearRidePopupTimer();
      final navigator = Navigator.of(context, rootNavigator: true);
      _ridePopupTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted ||
            !_hasActivePopup ||
            _activePopupRideId != activePopupRide.rideId) {
          timer.cancel();
          return;
        }

        if (isAccepting || _acceptingPopupRideId == activePopupRide.rideId) {
          return;
        }

        remainingSeconds -= 1;
        if (remainingSeconds <= 0) {
          popupTimedOut = true;
          _timedOutRideIds.add(activePopupRide.rideId.trim());
          _logRtdb('popup timeout rideId=${activePopupRide.rideId}');
          timer.cancel();
          unawaited(navigator.maybePop());
          return;
        }

        if (dialogSetState != null) {
          dialogSetState!(() {});
        }
      });

      print('REQUEST_POPUP_SHOWN');
      if (_serviceTypeKey(activePopupRide.serviceType) == 'dispatch_delivery') {
        print('DISPATCH_REQUEST_RECEIVED');
      }
      final action = await showDialog<_RidePopupAction>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          return PopScope(
            canPop: false,
            child: StatefulBuilder(
              builder: (dialogContext, setDialogState) {
                dialogSetState = setDialogState;
                return AlertDialog(
                  insetPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 18,
                  ),
                  contentPadding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  title: Text(
                    _servicePopupTitle(activePopupRide.serviceType),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 17,
                    ),
                  ),
                  content: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'This request stays pending until you explicitly accept or decline it.',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.black54,
                            height: 1.3,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Center(
                          child: Text(
                            popupHeadline,
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFFD4AF37),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: _gold.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              _serviceTypeLabel(activePopupRide.serviceType),
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                color: Colors.black87,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          alignment: WrapAlignment.center,
                          children: <Widget>[
                            _buildMetaChip(
                              label: popupVerifiedBadge
                                  ? 'Verified rider'
                                  : _riderVerificationLabel(
                                      popupVerificationStatus,
                                    ),
                              color: _riderVerificationColor(
                                popupVerificationStatus,
                              ),
                              icon: popupVerifiedBadge
                                  ? Icons.verified_rounded
                                  : Icons.badge_outlined,
                            ),
                            _buildMetaChip(
                              label: popupRatingCount > 0
                                  ? '${popupRating.toStringAsFixed(1)} ★ ($popupRatingCount)'
                                  : '${popupRating.toStringAsFixed(1)} ★',
                              color: _gold,
                              icon: Icons.star_rounded,
                            ),
                            if (popupRiskStatus != 'clear')
                              _buildMetaChip(
                                label: _riderRiskLabel(popupRiskStatus),
                                color: _riderRiskColor(popupRiskStatus),
                                icon: Icons.shield_outlined,
                              ),
                            if (popupPaymentWarningLabel != null)
                              _buildMetaChip(
                                label: popupPaymentWarningLabel,
                                color: _riderPaymentWarningColor(
                                  paymentStatus: popupPaymentStatus,
                                  cashAccessStatus: popupCashAccessStatus,
                                  outstandingCancellationFeesNgn: 0,
                                  nonPaymentReports: 0,
                                ),
                                icon: Icons.payments_outlined,
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Center(
                          child: Text(
                            'Respond in ${remainingSeconds}s',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.black54,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(999),
                          child: LinearProgressIndicator(
                            minHeight: 5,
                            value:
                                remainingSeconds / _kRidePopupCountdownSeconds,
                            backgroundColor: Colors.black12,
                            valueColor: AlwaysStoppedAnimation<Color>(_gold),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Icons.my_location,
                              color: Colors.green,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                pickupAddress,
                                style: const TextStyle(height: 1.25),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Icons.location_on,
                              color: Colors.red,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                destinationAddress,
                                style: const TextStyle(height: 1.25),
                              ),
                            ),
                          ],
                        ),
                        if (_routeOverlayError != null) ...[
                          const SizedBox(height: 12),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.04),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: Colors.black.withValues(alpha: 0.06),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Route preview unavailable',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: Colors.black87,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  _routeOverlayError!,
                                  style: TextStyle(
                                    color: Colors.black.withValues(alpha: 0.68),
                                    height: 1.35,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 10),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.04),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: Colors.black.withValues(alpha: 0.06),
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              _buildTripMetric(
                                label: 'Fare',
                                value: '₦$fareValue',
                              ),
                              _buildTripMetric(
                                label: 'Distance',
                                value: '${distanceKm.toStringAsFixed(2)} km',
                              ),
                              _buildTripMetric(
                                label: 'ETA',
                                value: '${etaMinutes.toStringAsFixed(0)} min',
                              ),
                            ],
                          ),
                        ),
                        if (packageDetails.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          _buildTripDetailRow(
                            icon: Icons.inventory_2_outlined,
                            label: 'Package details',
                            value: packageDetails,
                          ),
                        ],
                        if (recipientSummary.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          _buildTripDetailRow(
                            icon: Icons.person_pin_circle_outlined,
                            label: 'Recipient details',
                            value: recipientSummary,
                          ),
                        ],
                        if (packagePhotoUrl.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          _buildDispatchMediaCard(
                            title: 'Package photo',
                            subtitle:
                                'This dispatch includes the rider\'s item photo.',
                            icon: Icons.photo_camera_back_outlined,
                            actionLabel: 'View package photo',
                            onPressed: () {
                              unawaited(
                                _showDispatchImagePreview(
                                  title: 'Package photo',
                                  imageUrl: packagePhotoUrl,
                                ),
                              );
                            },
                          ),
                        ],
                        if (!canAcceptService) ...[
                          const SizedBox(height: 14),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.05),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Text(
                              serviceRestrictionMessage,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Colors.black87,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  actionsPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  actions: [
                    TextButton(
                      onPressed: isAccepting
                          ? null
                          : () {
                              Navigator.of(dialogContext).pop(
                                _RidePopupAction.declined,
                              );
                            },
                      child: Text(canAcceptService ? 'DECLINE' : 'CLOSE'),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _gold,
                        disabledBackgroundColor: _gold.withValues(alpha: 0.5),
                      ),
                      onPressed: isAccepting || !canAcceptService
                          ? null
                          : () async {
                              if (isAccepting) {
                                return;
                              }
                              isAccepting = true;
                              final acceptRequestedAt =
                                  DateTime.now().millisecondsSinceEpoch;
                              _logRideReq(
                                '[MATCH_DEBUG][ACCEPT_TAP] rideId=${activePopupRide.rideId} '
                                'driverId=$_effectiveDriverId ts=$acceptRequestedAt',
                              );
                              _logCanonicalRideEvent(
                                eventName: 'accept_pressed',
                                rideId: activePopupRide.rideId,
                                rideData: activePopupRide.rideData,
                              );
                              _logRtdb(
                                'accept tapped rideId=${activePopupRide.rideId} driverId=$_effectiveDriverId',
                              );
                              _clearRidePopupTimer();
                              setDialogState(() {});
                              final accepted = await _acceptRide(
                                activePopupRide.rideId,
                                driverName: driverName,
                                car: car,
                                plate: plate,
                                acceptRequestedAt: acceptRequestedAt,
                              );
                              if (!dialogContext.mounted) {
                                return;
                              }
                              if (accepted) {
                                _logRideReq(
                                  '[MATCH_DEBUG][POPUP_DISMISSED_AFTER_ACCEPT] '
                                  'rideId=${activePopupRide.rideId}',
                                );
                              }
                              Navigator.of(dialogContext).pop(
                                accepted
                                    ? _RidePopupAction.accepted
                                    : _RidePopupAction.blocked,
                              );
                            },
                      child: isAccepting
                          ? const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      Colors.black,
                                    ),
                                  ),
                                ),
                                SizedBox(width: 10),
                                Text(
                                  'Accepting…',
                                  style: TextStyle(
                                    color: Colors.black,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            )
                          : const Text(
                              'ACCEPT',
                              style: TextStyle(color: Colors.black),
                            ),
                    ),
                  ],
                );
              },
            ),
          );
        },
      );
      dialogSetState = null;

      if (action == _RidePopupAction.declined) {
        _popupDismissedReason = 'driver_declined';
        _declinedRideIds.add(popupRide.rideId.trim());
        _handledRideIds.add(popupRide.rideId.trim());
        _suppressedRidePopupIds.add(popupRide.rideId.trim());
        _logRtdb('popup declined locally rideId=${popupRide.rideId}');
        _log(
          'driver acceptance ts=${DateTime.now().toIso8601String()} action=decline rideId=${popupRide.rideId} currentRideId=$_currentRideId',
        );
        _clearRidePreview();
        _rearmRideRequestListener('ride declined rideId=${popupRide.rideId}');
        return;
      }

      if (action == _RidePopupAction.accepted) {
        rideAccepted = true;
        _handledRideIds.add(popupRide.rideId.trim());
        return;
      }

      if (action == _RidePopupAction.blocked) {
        final blockedRid = popupRide.rideId.trim();
        _handledRideIds.add(blockedRid);
        if (_terminalSelfAcceptedRideIds.contains(blockedRid) ||
            _foreverSuppressedRidePopupIds.contains(blockedRid)) {
          _logRideReq(
            '[MATCH_DEBUG][UNAVAILABLE_SKIPPED_SELF_ACCEPTED] rideId=$blockedRid '
            'source=popup_action_blocked',
          );
          _clearRidePreview();
          return;
        }
        _popupDismissedReason = 'accept_blocked';
        _clearRidePreview();
        _rearmRideRequestListener('accept blocked rideId=${popupRide.rideId}');
        return;
      }

      if (_popupDismissedRideId == popupRide.rideId) {
        _clearRidePreview();
        _rearmRideRequestListener(
          'popup dismissed rideId=${popupRide.rideId} reason=${_popupDismissedReason ?? 'unavailable'}',
        );
        return;
      }

      _presentedRideIds.remove(popupRide.rideId.trim());
      if (popupTimedOut) {
        _handledRideIds.add(popupRide.rideId.trim());
        _clearRidePreview();
        _rearmRideRequestListener('popup timeout rideId=${popupRide.rideId}');
        return;
      }

      _log(
        'popup dismissed without action rideId=${popupRide.rideId}, allowing retry',
      );
      _clearRidePreview();
      _rearmRideRequestListener('popup dismissed rideId=${popupRide.rideId}');
    } catch (error) {
      _presentedRideIds.remove(ride.rideId.trim());
      _clearRidePreview();
      _log('showRideRequestPopup error rideId=${ride.rideId} error=$error');
    } finally {
      _clearRidePopupTimer();
      if (!rideAccepted) {
        _presentedRideIds.remove(ride.rideId.trim());
      }
      if (rideReserved && !rideAccepted) {
        final rid = ride.rideId.trim();
        if (_terminalSelfAcceptedRideIds.contains(rid) ||
            _foreverSuppressedRidePopupIds.contains(rid)) {
          _logRideReq(
            '[MATCH_DEBUG][ASSIGNMENT_RELEASE_SKIPPED] rideId=$rid '
            'reason=accept_terminal_or_forever_lock popupTimedOut=$popupTimedOut',
          );
        } else {
          await _releaseAssignedRideIfNeeded(
            rideId: ride.rideId,
            reason: popupTimedOut
                ? 'driver_response_timeout'
                : (_popupDismissedReason ?? 'driver_declined'),
          );
        }
      }
      _popupOpen = false;
      _hasActivePopup = false;
      _activePopupRideId = null;
      if (_currentCandidateRideId == ride.rideId) {
        _currentCandidateRideId = null;
      }
      _acceptingPopupRideId = null;
      if (_popupDismissedRideId == ride.rideId) {
        _popupDismissedRideId = null;
        _popupDismissedReason = null;
      }
      scheduleMicrotask(() {
        unawaited(_flushRideRequestPopupQueueAfterClose());
      });
    }
  }

  Future<bool> _acceptRide(
    String rideId, {
    String? driverName,
    String? car,
    String? plate,
    int? acceptRequestedAt,
  }) async {
    if (!_isValidRideId(rideId)) {
      _logRideReq(
        '[MATCH_DEBUG][ACCEPT_LOCK_FAIL] rideId=$rideId reason=ride_id_missing',
      );
      _logRtdb('accept blocked rideId=$rideId reason=ride_id_missing');
      return false;
    }

    final popupRideId = _activePopupRideId;
    if (popupRideId != null && popupRideId != rideId) {
      _logRideReq(
        '[MATCH_DEBUG][ACCEPT_LOCK_FAIL] rideId=$rideId reason=popup_request_mismatch '
        'popupRideId=$popupRideId',
      );
      _logRtdb(
        'accept blocked rideId=$rideId reason=popup_request_mismatch popupRideId=$popupRideId',
      );
      return false;
    }

    if (_acceptingPopupRideId == rideId) {
      _logRideReq(
        '[MATCH_DEBUG][ACCEPT_LOCK_FAIL] rideId=$rideId reason=accept_already_in_flight',
      );
      _logRtdb('accept blocked rideId=$rideId reason=accept_in_flight');
      return false;
    }

    _acceptingPopupRideId = rideId;
    _logRtdb(
      'accept requested rideId=$rideId path=ride_requests/$rideId popupRideId=${popupRideId ?? rideId}',
    );

    final ref = _rideRequestsRef.child(rideId);
    final effectiveAcceptRequestedAt =
        acceptRequestedAt ?? DateTime.now().millisecondsSinceEpoch;
    final resolvedDriverName = driverName?.trim().isNotEmpty == true
        ? driverName!.trim()
        : widget.driverName.trim().isNotEmpty
            ? widget.driverName.trim()
            : 'Driver';
    final resolvedCar =
        car?.trim().isNotEmpty == true ? car!.trim() : widget.car.trim();
    final resolvedPlate =
        plate?.trim().isNotEmpty == true ? plate!.trim() : widget.plate.trim();

    if (_effectiveDriverId.isEmpty ||
        FirebaseAuth.instance.currentUser?.uid != _effectiveDriverId ||
        !_isOnline) {
      _logRideReq(
        '[MATCH_DEBUG][ACCEPT_LOCK_FAIL] rideId=$rideId reason=driver_not_ready',
      );
      _logRtdb('accept blocked rideId=$rideId reason=driver_not_ready');
      _showSnackBarSafely(
        const SnackBar(
          content: Text(
              'You need to be online and signed in before accepting a ride.'),
        ),
      );
      _acceptingPopupRideId = null;
      return false;
    }
    final availabilityInvalidReason = await _driverAvailabilityInvalidReason(
      rideId: rideId,
      requireRideRequestListener: false,
    );
    if (availabilityInvalidReason != null) {
      await _logDriverHealthDetailed('pre_accept');
      _log(
        '[HEALTH] pre_accept session warning rideId=$rideId reason=$availabilityInvalidReason '
        '(accept not blocked — see ${_driverAcceptAvailabilityUserMessage(availabilityInvalidReason)})',
      );
    } else {
      await _logDriverHealthDetailed('pre_accept');
    }
    _log(
      '[ACCEPT] start rideId=$rideId driverId=$_effectiveDriverId '
      'sessionWarning=${availabilityInvalidReason ?? 'none'}',
    );
    var acceptSucceeded = false;
    try {
      String blockedReason = 'unknown';
      var acceptLockWasIdempotent = false;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final startTimeoutAt =
          nowMs + TripStateMachine.acceptedToStartTimeout.inMilliseconds;
      _logRideReq(
        '[MATCH_DEBUG][ACCEPT_START] rideId=$rideId driverId=$_effectiveDriverId',
      );
      _logRideReq(
        '[DRIVER_ACCEPT_START] rideId=$rideId driverId=$_effectiveDriverId',
      );
      _logRideReq(
        '[MATCH_DEBUG][ACCEPT_TX_BEGIN] rideId=$rideId driverId=$_effectiveDriverId',
      );
      _logRideReq(
        '[DRIVER_ACCEPT_TX] stage=begin rideId=$rideId driverId=$_effectiveDriverId',
      );
      final transactionResult = await ref.runTransaction((currentData) {
        final current = _asStringDynamicMap(currentData);
        if (current == null) {
          blockedReason = 'ride_missing';
          _logRideReq('[DRIVER_ACCEPT_BLOCKED] reason=$blockedReason');
          return rtdb.Transaction.abort();
        }
        final nowMsInTx = DateTime.now().millisecondsSinceEpoch;
        _logRideReq(
          '[DRIVER_ACCEPT_ATTEMPT] rideId=$rideId '
          'status=${_valueAsText(current['status'])} '
          'trip_state=${_valueAsText(current['trip_state'])} '
          'driver_id=${_valueAsText(current['driver_id'])} '
          'market=${_rideMarketFromData(current) ?? ''} '
          'expires_at=${_valueAsText(current['expires_at'])} '
          'request_expires_at=${_valueAsText(current['request_expires_at'])} '
          'now_ms=$nowMsInTx',
        );

        final currentCanonicalState =
            TripStateMachine.canonicalStateFromSnapshot(current);
        final currentDriverId = _valueAsText(current['driver_id']);
        if (currentDriverId == _effectiveDriverId &&
            TripStateMachine.isDriverActiveState(currentCanonicalState)) {
          acceptLockWasIdempotent = true;
          return rtdb.Transaction.success(Map<String, dynamic>.from(current));
        }
        if (!_isRideClaimableForDriverAccept(current)) {
          blockedReason = _popupServerSkipReason(rideId, current) ??
              'ride_not_claimable';
          _logRideReq('[DRIVER_ACCEPT_BLOCKED] reason=$blockedReason');
          return rtdb.Transaction.abort();
        }

        final transitionUpdates = TripStateMachine.buildTransitionUpdate(
          currentRide: current,
          nextCanonicalState: TripLifecycleState.driverAccepted,
          timestampValue: rtdb.ServerValue.timestamp,
          transitionSource: 'driver_accept',
          transitionActor: 'driver',
        );
        return rtdb.Transaction.success(
          Map<String, dynamic>.from(current)
            ..addAll(transitionUpdates)
            ..addAll(<String, dynamic>{
              'driver_id': _effectiveDriverId,
              'accepted_driver_id': _effectiveDriverId,
              'driver_name': resolvedDriverName,
              'car': resolvedCar,
              'plate': resolvedPlate,
              // Rider / legacy UIs (and Firestore-era clients) often key off this phrase.
              'rider_sync_status': 'driver_found',
              'driver_match_confirmed_at': rtdb.ServerValue.timestamp,
              'status': 'accepted',
              'trip_state': 'accepted',
              // Leave the open-pool index; [service_area] / [city] still carry market.
              'market': null,
              'market_pool': null,
              'accepted_at': rtdb.ServerValue.timestamp,
              'updated_at': rtdb.ServerValue.timestamp,
              'assignment_expires_at': null,
              'driver_response_timeout_at': null,
              'assignment_timeout_ms': null,
              'start_timeout_at': startTimeoutAt,
              'route_log_timeout_at': null,
              'has_started_route_checkpoints': false,
              'route_log_trip_started_checkpoint_at': null,
            }),
        );
      }, applyLocally: false);

      final latestRideData = transactionResult.committed
          ? null
          : _asStringDynamicMap(transactionResult.snapshot.value);
      Map<String, dynamic>? ridePayload = transactionResult.committed
          ? _asStringDynamicMap(transactionResult.snapshot.value)
          : _rideAlreadyAcceptedByCurrentDriver(latestRideData)
              ? latestRideData
              : null;

      if (!transactionResult.committed && ridePayload != null) {
        acceptLockWasIdempotent = true;
      }

      if (ridePayload == null &&
          latestRideData != null &&
          _rideAlreadyAcceptedByCurrentDriver(latestRideData)) {
        _logRideReq(
          '[MATCH_DEBUG][UNAVAILABLE_SUPPRESSED_ACCEPTED_DRIVER] rideId=$rideId '
          'reason=client_tx_view_recover_server_accepted',
        );
        ridePayload = latestRideData;
        acceptLockWasIdempotent = true;
      }

      if (ridePayload == null) {
        if (_terminalSelfAcceptedRideIds.contains(rideId.trim())) {
          _logRideReq(
            '[MATCH_DEBUG][UNAVAILABLE_SKIPPED_SELF_ACCEPTED] rideId=$rideId '
            'source=accept_tx_null_while_terminal_locked',
          );
          return false;
        }
        final latestBlockedReason = blockedReason != 'unknown'
            ? blockedReason
            : _acceptBlockedReasonFromRideData(rideId, latestRideData);
        _logRtdb('accept blocked rideId=$rideId reason=$latestBlockedReason');
        _logRideReq(
          '[MATCH_DEBUG][ACCEPT_TX_ABORT] rideId=$rideId reason=$latestBlockedReason '
          'rtdb_committed=${transactionResult.committed}',
        );
        _logRideReq(
          '[DRIVER_ACCEPT_TX] stage=abort rideId=$rideId reason=$latestBlockedReason '
          'committed=${transactionResult.committed}',
        );
        _logRideReq(
          '[MATCH_DEBUG][ACCEPT_LOCK_FAIL] rideId=$rideId reason=$latestBlockedReason '
          'committed=${transactionResult.committed}',
        );
        _logRideReq(
          '[MATCH_DEBUG][DRIVER_DECISION] decision=rejected rideId=$rideId '
          'status=${latestRideData == null ? 'unknown' : TripStateMachine.uiStatusFromSnapshot(latestRideData)} '
          'reason=$latestBlockedReason stage=accept',
        );
        _logRideReq(
          '[MATCH_DEBUG][ACCEPT_FAIL] rideId=$rideId reason=$latestBlockedReason '
          'phase=transaction',
        );
        _logRideReq(
          '[DRIVER_ACCEPT_FAIL] rideId=$rideId reason=$latestBlockedReason phase=transaction',
        );
        _logCanonicalRideEvent(
          eventName: 'transaction_failed',
          rideId: rideId,
          rideData: latestRideData,
        );
        if (_rideBelongsToAnotherDriver(latestRideData)) {
          _logRtdb('accept lost rideId=$rideId');
        }
        _showSnackBarSafely(
          SnackBar(
            content: Text(
              _acceptBlockedMessage(
                blockedReason: latestBlockedReason,
                rideData: latestRideData,
                rideId: rideId,
              ),
            ),
          ),
        );
        return false;
      }
      final committedRideReason = _activeRideInvalidReason(
        ridePayload,
        rideId: rideId,
        relaxLifecycleProof: true,
      );
      if (committedRideReason != null) {
        final committedCanonicalState =
            TripStateMachine.canonicalStateFromSnapshot(ridePayload);
        final assignedHere =
            _valueAsText(ridePayload['driver_id']) == _effectiveDriverId;
        final treatAsSoftFailure = assignedHere &&
            TripStateMachine.isDriverActiveState(committedCanonicalState);
        if (treatAsSoftFailure) {
          _log(
            '[HEALTH] post_accept_payload_warning rideId=$rideId reason=$committedRideReason '
            '(trip continues — no auto-cancel)',
          );
        } else {
          _logInvalidRideBlocked(
            rideId: rideId,
            reason: committedRideReason,
          );
          _logTripPanelHidden(committedRideReason);
          _logRtdb(
            'accept blocked rideId=$rideId reason=committed_payload_invalid',
          );
          _logRideReq(
            '[MATCH_DEBUG][ACCEPT_TX_ABORT] rideId=$rideId reason=committed_payload_invalid '
            'detail=$committedRideReason',
          );
          _logRideReq(
            '[MATCH_DEBUG][ACCEPT_LOCK_FAIL] rideId=$rideId reason=committed_payload_invalid '
            'detail=$committedRideReason',
          );
          _logRideReq(
            '[MATCH_DEBUG][ACCEPT_FAIL] rideId=$rideId reason=committed_payload_invalid '
            'detail=$committedRideReason phase=post_tx_validation',
          );
          await _clearActiveRideState(
            reason: 'accepted_payload_invalid',
            resetTripState: true,
          );
          return false;
        }
      }
      final validatedCommittedRideData = ridePayload;
      _logRideReq(
        '[MATCH_DEBUG][DRIVER_DECISION] decision=accepted rideId=$rideId '
        'status=${TripStateMachine.uiStatusFromSnapshot(validatedCommittedRideData)} stage=accept',
      );
      final committedCanonicalForCommit =
          TripStateMachine.canonicalStateFromSnapshot(
        validatedCommittedRideData,
      );
      final committedStatus =
          TripStateMachine.uiStatusFromSnapshot(validatedCommittedRideData);
      _logRideReq(
        '[MATCH_DEBUG][ACCEPT_TX_COMMIT] rideId=$rideId driverId=$_effectiveDriverId '
        'idempotent=$acceptLockWasIdempotent rtdb_committed=${transactionResult.committed} '
        'trip_state=$committedCanonicalForCommit ui_status=$committedStatus',
      );
      _logRideReq('[OPEN_POOL_REMOVE] rideId=$rideId market_pool=null source=accept_tx');
      _logRideReq(
        '[DRIVER_ACCEPT_TX] stage=commit rideId=$rideId driverId=$_effectiveDriverId '
        'trip_state=$committedCanonicalForCommit ui_status=$committedStatus',
      );
      _logCanonicalRideEvent(
        eventName: 'transaction_committed',
        rideId: rideId,
        rideData: validatedCommittedRideData,
      );
      debugPrint('[DRIVER_ACCEPTED_REQUEST] rideId=$rideId');

      final rid = rideId.trim();
      var criticalPostAcceptSyncOk = false;
      final driverPresenceCritical = _buildDriverPresenceUpdate(
        status: committedStatus,
        activeRideId: rideId,
        isAvailable: false,
      );
      try {
        await _commitCriticalRideAndDriverSnapshot(
          rideId: rideId,
          rideUpdates: <String, dynamic>{
            'driver_state_synced_at': rtdb.ServerValue.timestamp,
          },
          driverUpdates: driverPresenceCritical,
        );
        criticalPostAcceptSyncOk = true;
      } catch (error, stackTrace) {
        _logRideReq(
          '[MATCH_DEBUG][ACCEPT_FAIL] rideId=$rideId phase=critical_post_accept_rtdb '
          'error=$error',
        );
        _logRtdb(
          'critical post-accept sync failed rideId=$rideId error=$error '
          '(ride_requests accept already committed — not releasing assignment)',
        );
        debugPrintStack(
          label: 'critical post-accept sync',
          stackTrace: stackTrace,
        );
      }

      _terminalSelfAcceptedRideIds.add(rid);
      _foreverSuppressedRidePopupIds.add(rid);
      _suppressedRidePopupIds.add(rid);
      _presentedRideIds.remove(rid);
      _logRideReq(
        '[MATCH_DEBUG][POPUP_SUPPRESSED_ACCEPTED] rideId=$rideId driverId=$_effectiveDriverId '
        'trip_state=$committedCanonicalForCommit '
        'critical_rtdb_sync_ok=$criticalPostAcceptSyncOk',
      );
      _trackRideForCurrentSession(rideId);

      _scheduleOptionalPostAcceptRtdbMirrors(
        rideId: rideId,
        committedStatus: committedStatus,
        committedCanonicalForCommit: committedCanonicalForCommit,
        rideData: validatedCommittedRideData,
      );

      _logRideReq(
        '[MATCH_DEBUG][ACCEPT_SUCCESS] rideId=$rideId driverId=$_effectiveDriverId '
        'trip_state=$committedCanonicalForCommit ui_status=$committedStatus '
        'critical_rtdb_sync_ok=$criticalPostAcceptSyncOk',
      );
      _logRideReq(
        '[DRIVER_ACCEPT_OK] rideId=$rideId driverId=$_effectiveDriverId '
        'trip_state=$committedCanonicalForCommit ui_status=$committedStatus',
      );
      _logRideReq(
        '[MATCH_DEBUG][DRIVER_ACTIVE_TRIP] rideId=$rideId driverId=$_effectiveDriverId '
        'ui_status=$committedStatus trip_state=$committedCanonicalForCommit',
      );
      _logRideReq(
        '[MATCH_DEBUG][DRIVER_ASSIGNED_RIDE] rideId=$rideId driverId=$_effectiveDriverId '
        'ui_status=$committedStatus trip_state=$committedCanonicalForCommit '
        'source=accept_after_driver_sync',
      );
      _startCallListener(rideId);
      if (mounted) {
        setState(() {
          _driverActiveRideId = rideId;
          _currentRideId = rideId;
          _currentRideData =
              Map<String, dynamic>.from(validatedCommittedRideData);
          _rideStatus = committedStatus;
          _tripStarted = committedStatus == 'on_trip';
          _driverUnreadChatCount = 0;
          _isDriverChatOpen = false;
        });
      } else {
        _driverActiveRideId = rideId;
        _currentRideId = rideId;
        _currentRideData =
            Map<String, dynamic>.from(validatedCommittedRideData);
        _rideStatus = committedStatus;
        _tripStarted = committedStatus == 'on_trip';
        _driverUnreadChatCount = 0;
        _isDriverChatOpen = false;
      }
      _logRideReq(
        '[MATCH_DEBUG][ACCEPT_UI_SUCCESS] rideId=$rideId ui_status=$committedStatus '
        'trip_state=$committedCanonicalForCommit',
      );
      _logRideReq(
        '[MATCH_DEBUG][POST_ACCEPT_DRIVER_STATE] rideId=$rideId '
        'rideStatus=$_rideStatus currentRideId=$_currentRideId '
        'driverActive=$_driverActiveRideId trip_state=$committedCanonicalForCommit',
      );
      try {
        _applyRideLocationsFromData(validatedCommittedRideData);
        _evaluateArrivedAvailability();
        await _ensureRideChatInitialized(
          rideId: rideId,
          rideData: validatedCommittedRideData,
        );
        _loggedDriverChatMessageIds.clear();
        _startDriverChatListener(rideId);
        unawaited(
          _loadRiderDetails(
            rideId: rideId,
            rideData: validatedCommittedRideData,
          ),
        );
        await _listenToActiveRide(rideId);
        _scheduleActiveRouteRefresh(
          force: true,
          reason: 'driver_accept_local',
          debounce: Duration.zero,
        );
        _refreshIosDriverMapIfNeeded(reason: 'driver_accept_local');
      } catch (error, stackTrace) {
        _logRideReq(
          '[MATCH_DEBUG][ACCEPT_UI_SOFT_FAIL] rideId=$rideId error=$error',
        );
        _log('accept post_bind_soft_failure rideId=$rideId error=$error');
        debugPrintStack(
          label: 'accept post_bind',
          stackTrace: stackTrace,
        );
      }

      unawaited(
        _driverTripSafetyService
            .logRideStateChange(
          rideId: rideId,
          riderId: _valueAsText(validatedCommittedRideData['rider_id']),
          driverId: _effectiveDriverId,
          serviceType:
              _serviceTypeKey(validatedCommittedRideData['service_type']),
          status: committedStatus,
          source: 'driver_accept',
          rideData: validatedCommittedRideData,
        )
            .catchError((Object error) {
          _log(
            'accept telemetry soft_failure rideId=$rideId error=$error',
          );
        }),
      );

      _logRtdb(
        'accept write succeeded rideId=$rideId driverId=$_effectiveDriverId',
      );
      _log(
        '[ACCEPT] success rideId=$rideId trip_state=${TripStateMachine.canonicalStateFromSnapshot(validatedCommittedRideData)} '
        'status=${TripStateMachine.uiStatusFromSnapshot(validatedCommittedRideData)}',
      );
      _log(
        'driver acceptance ts=${DateTime.now().toIso8601String()} action=accept rideId=$rideId currentRideId=$_currentRideId',
      );
      _printRideOwnershipDebug(validatedCommittedRideData);
      _log('[LAST_ACTIVE] updated source=accept_ride rideId=$rideId');
      acceptSucceeded = true;
      if (!criticalPostAcceptSyncOk) {
        _showSnackBarSafely(
          const SnackBar(
            content: Text(
              'Ride accepted. If the trip panel looks wrong, pull to refresh.',
            ),
          ),
        );
      }
      if (_acceptingPopupRideId == rideId) {
        _acceptingPopupRideId = null;
      }
      return true;
    } catch (error) {
      _logRideReq('[DRIVER_ACCEPT_ERROR] error=$error');
      if (_currentRideId != rideId) {
        _driverActiveRideId = null;
      }
      _logRideReq(
        '[MATCH_DEBUG][ACCEPT_FAIL] rideId=$rideId reason=exception '
        'type=${error.runtimeType} phase=accept_try',
      );
      _logRideReq(
        '[DRIVER_ACCEPT_FAIL] rideId=$rideId reason=exception '
        'type=${error.runtimeType} phase=accept_try',
      );
      _logRideReq(
        '[MATCH_DEBUG][ACCEPT_TX_ABORT] rideId=$rideId reason=exception '
        'type=${error.runtimeType}',
      );
      _logRideReq(
        '[MATCH_DEBUG][ACCEPT_LOCK_FAIL] rideId=$rideId reason=exception '
        'type=${error.runtimeType}',
      );
      _logRtdb(
        'accept write failed rideId=$rideId exact_error_type=${error.runtimeType} exact_error=$error',
      );
      _logRtdb('accept write failed rideId=$rideId error=$error');
      _log('accept ride error rideId=$rideId error=$error');
      _showSnackBarSafely(
        const SnackBar(content: Text('Unable to accept this ride right now.')),
      );
      return false;
    } finally {
      if (!acceptSucceeded && _acceptingPopupRideId == rideId) {
        _acceptingPopupRideId = null;
      }
    }
  }

  Future<void> markArrived() async {
    final currentRideId = _currentRideId;
    final invalidReason = currentRideId == null
        ? 'missing_ride_id'
        : _activeRideInvalidReason(
            _currentRideData,
            rideId: currentRideId,
            requireTrackedRide: true,
          );
    final pickup = _pickupLocation;
    final distanceMeters = pickup == null
        ? null
        : Geolocator.distanceBetween(
            _driverLocation.latitude,
            _driverLocation.longitude,
            pickup.latitude,
            pickup.longitude,
          );

    if (currentRideId == null) {
      _log('arrived blocked reason=missing_ride_id');
      return;
    }

    if (!_arrivedEnabled) {
      _log(
        'arrived blocked rideId=$currentRideId reason=arrived_disabled '
        'status=$_rideStatus distanceMeters=${distanceMeters?.round() ?? 'unknown'}',
      );
      return;
    }

    if (!_isArrivedEligibleRideStatus(_rideStatus)) {
      _log(
        'arrived blocked rideId=$currentRideId reason=invalid_status status=$_rideStatus',
      );
      return;
    }

    if (invalidReason != null) {
      _log(
        'arrived blocked rideId=$currentRideId reason=$invalidReason status=$_rideStatus',
      );
      return;
    }

    _log(
      'arrived tapped rideId=$currentRideId status=$_rideStatus '
      'distanceMeters=${distanceMeters?.round() ?? 'unknown'}',
    );

    try {
      final currentRide = _currentRideData == null
          ? <String, dynamic>{'status': _rideStatus}
          : Map<String, dynamic>.from(_currentRideData!);
      final rideUpdates = TripStateMachine.buildTransitionUpdate(
        currentRide: currentRide,
        nextCanonicalState: TripLifecycleState.driverArrived,
        timestampValue: rtdb.ServerValue.timestamp,
        transitionSource: 'driver_arrived',
        transitionActor: 'driver',
      );
      await _commitRideAndDriverState(
        rideId: currentRideId,
        rideUpdates: rideUpdates,
        driverUpdates: _buildDriverPresenceUpdate(
          status: 'arrived',
          activeRideId: currentRideId,
          isAvailable: false,
        ),
        activeRideUpdates: <String, Object?>{
          'ride_id': currentRideId,
          'status': 'arrived',
          'trip_state': TripLifecycleState.driverArrived,
          'updated_at': rtdb.ServerValue.timestamp,
        },
      );
      _log('arrived ride update success rideId=$currentRideId');
      _log('arrived driver update success rideId=$currentRideId');
      _log('arrived active ride marker success rideId=$currentRideId');
    } catch (error) {
      _log('arrived failed rideId=$currentRideId error=$error');
      _showSnackBarSafely(
        const SnackBar(
          content: Text('Unable to mark arrival right now. Please try again.'),
        ),
      );
      return;
    }

    final nextRideData = _currentRideData == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(_currentRideData!);
    nextRideData['status'] = 'arrived';
    nextRideData['trip_state'] = TripLifecycleState.driverArrived;

    if (mounted) {
      setState(() {
        _rideStatus = 'arrived';
        _tripStarted = false;
        _arrivedEnabled = false;
        _currentRideData = nextRideData;
      });
    } else {
      _rideStatus = 'arrived';
      _tripStarted = false;
      _arrivedEnabled = false;
      _currentRideData = nextRideData;
    }
    _log('arrived local ui updated rideId=$currentRideId status=$_rideStatus');

    unawaited(
      _driverTripSafetyService.logRideStateChange(
        rideId: currentRideId,
        riderId: _currentRiderIdForRide,
        driverId: _effectiveDriverId,
        serviceType: _serviceTypeKey(_currentRideData?['service_type']),
        status: 'arrived',
        source: 'driver_arrived',
        rideData: _currentRideData,
      ),
    );

    _hasLoggedArrivedEnabled = false;
  }

  Future<void> startTrip() async {
    final currentRideId = _currentRideId;
    final serviceType = _serviceTypeKey(_currentRideData?['service_type']);
    final invalidReason = currentRideId == null
        ? 'missing_ride_id'
        : _activeRideInvalidReason(
            _currentRideData,
            rideId: currentRideId,
            requireTrackedRide: true,
          );

    if (currentRideId == null) {
      _log('start trip blocked reason=missing_ride_id');
      return;
    }

    if (_rideStatus != 'arrived') {
      _log(
        'start trip blocked rideId=$currentRideId reason=invalid_status status=$_rideStatus',
      );
      return;
    }

    if (invalidReason != null) {
      _log('start trip blocked rideId=$currentRideId reason=$invalidReason');
      return;
    }

    _log('start trip tapped rideId=$currentRideId status=$_rideStatus');

    try {
      final currentRide = _currentRideData == null
          ? <String, dynamic>{'status': _rideStatus}
          : Map<String, dynamic>.from(_currentRideData!);
      final rideUpdates = TripStateMachine.buildTransitionUpdate(
        currentRide: currentRide,
        nextCanonicalState: TripLifecycleState.tripStarted,
        timestampValue: rtdb.ServerValue.timestamp,
        transitionSource: 'driver_start_trip',
        transitionActor: 'driver',
      )..addAll(<String, dynamic>{
          'start_timeout_at': null,
          'route_log_timeout_at': DateTime.now().millisecondsSinceEpoch +
              TripStateMachine.routeLogTimeout.inMilliseconds,
          'has_started_route_checkpoints': false,
          'route_log_trip_started_checkpoint_at': null,
        });
      if (_isDispatchDeliveryService(serviceType)) {
        rideUpdates['pickupConfirmedAt'] = rtdb.ServerValue.timestamp;
        rideUpdates['deliveryProofStatus'] = 'pending';
        rideUpdates['dispatch_details/pickupConfirmedAt'] =
            rtdb.ServerValue.timestamp;
        rideUpdates['dispatch_details/deliveryProofStatus'] = 'pending';
      }

      await _commitRideAndDriverState(
        rideId: currentRideId,
        rideUpdates: rideUpdates,
        driverUpdates: _buildDriverPresenceUpdate(
          status: 'on_trip',
          activeRideId: currentRideId,
          isAvailable: false,
        ),
        activeRideUpdates: <String, Object?>{
          'ride_id': currentRideId,
          'status': 'on_trip',
          'trip_state': TripLifecycleState.tripStarted,
          'updated_at': rtdb.ServerValue.timestamp,
        },
      );
      _log('start trip ride update success rideId=$currentRideId');
      _log('start trip driver update success rideId=$currentRideId');
      _log('start trip active ride marker success rideId=$currentRideId');
    } catch (error) {
      _log('start trip failed rideId=$currentRideId error=$error');
      _showSnackBarSafely(
        const SnackBar(
          content:
              Text('Unable to start the trip right now. Please try again.'),
        ),
      );
      return;
    }

    var nextRideData = _currentRideData == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(_currentRideData!);
    nextRideData['status'] = 'on_trip';
    nextRideData['trip_state'] = TripLifecycleState.tripStarted;
    nextRideData['start_timeout_at'] = null;
    nextRideData['route_log_timeout_at'] =
        DateTime.now().millisecondsSinceEpoch +
            TripStateMachine.routeLogTimeout.inMilliseconds;
    nextRideData['has_started_route_checkpoints'] = false;
    nextRideData['route_log_trip_started_checkpoint_at'] = null;
    if (_isDispatchDeliveryService(serviceType)) {
      nextRideData['pickupConfirmedAt'] = DateTime.now().millisecondsSinceEpoch;
      nextRideData['deliveryProofStatus'] = 'pending';
      nextRideData = _copyRideWithDispatchDetails(
        nextRideData,
        <String, dynamic>{
          'pickupConfirmedAt': DateTime.now().millisecondsSinceEpoch,
          'deliveryProofStatus': 'pending',
        },
      );
    }

    if (mounted) {
      setState(() {
        _rideStatus = 'on_trip';
        _tripStarted = true;
        _currentRideData = nextRideData;
      });
    } else {
      _rideStatus = 'on_trip';
      _tripStarted = true;
      _currentRideData = nextRideData;
    }
    _log(
        'start trip local ui updated rideId=$currentRideId status=$_rideStatus');

    unawaited(
      _driverTripSafetyService.logRideStateChange(
        rideId: currentRideId,
        riderId: _currentRiderIdForRide,
        driverId: _effectiveDriverId,
        serviceType: _serviceTypeKey(_currentRideData?['service_type']),
        status: 'on_trip',
        source: 'driver_start_trip',
        rideData: _currentRideData,
      ),
    );

    _log('trip started rideId=$currentRideId');

    _hasLoggedArrivedEnabled = false;
  }

  static const List<String> _kDriverTripCancelReasons = <String>[
    'Rider not reachable',
    'Wrong pickup',
    'Vehicle issue',
    'Unsafe situation',
    'Change of plans',
    'Other',
  ];

  Future<String?> _pickDriverTripCancelReason() async {
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
          title: const Text('Cancel trip'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Pick a reason. This will cancel the trip for you and the rider.',
                  style: TextStyle(fontSize: 13, height: 1.35),
                ),
                const SizedBox(height: 12),
                ..._kDriverTripCancelReasons.map(
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
              child: const Text('KEEP TRIP'),
            ),
          ],
        );
      },
    );
  }

  Future<void> cancelActiveRide() async {
    final currentRideId = _currentRideId;
    final serviceType = _serviceTypeKey(_currentRideData?['service_type']);
    final invalidReason = currentRideId == null
        ? 'missing_ride_id'
        : _activeRideInvalidReason(
            _currentRideData,
            rideId: currentRideId,
            requireTrackedRide: true,
          );

    if (currentRideId == null) {
      _log('driver cancel blocked reason=missing_ride_id');
      return;
    }

    if (!_canDriverCancelActiveRide(_rideStatus)) {
      _log(
        'driver cancel blocked rideId=$currentRideId reason=invalid_status status=$_rideStatus',
      );
      return;
    }

    if (invalidReason != null) {
      _log(
        'driver cancel blocked rideId=$currentRideId reason=$invalidReason status=$_rideStatus',
      );
      return;
    }

    final cancelReason = await _pickDriverTripCancelReason();
    if (cancelReason == null || cancelReason.trim().isEmpty) {
      _log('[CANCEL] actor=driver rideId=$currentRideId dismissed');
      return;
    }

    if (mounted) {
      _setStateSafely(() {
        _isDriverCancellingRide = true;
      });
    } else {
      _isDriverCancellingRide = true;
    }

    final riderId = _currentRiderIdForRide;
    final currentRide = _currentRideData == null
        ? <String, dynamic>{'status': _rideStatus}
        : Map<String, dynamic>.from(_currentRideData!);
    _log(
      '[CANCEL] actor=driver rideId=$currentRideId reason=$cancelReason start',
    );

    try {
      final rideUpdates = TripStateMachine.buildTransitionUpdate(
        currentRide: currentRide,
        nextCanonicalState: TripLifecycleState.tripCancelled,
        timestampValue: rtdb.ServerValue.timestamp,
        transitionSource: 'driver_cancel',
        transitionActor: 'driver',
        cancellationActor: 'driver',
        cancellationReason: cancelReason.trim(),
      )..addAll(<String, dynamic>{
          'driver_id': _effectiveDriverId,
          'cancelled_by': 'driver',
          'cancelled_at': rtdb.ServerValue.timestamp,
          ..._cancelledRideSupplementalUpdate(
            rideData: currentRide,
            cancelSource: 'driver_cancel',
          ),
        });

      await _commitRideAndDriverState(
        rideId: currentRideId,
        rideUpdates: rideUpdates,
        driverUpdates: _buildDriverPresenceUpdate(
          status: 'idle',
          isAvailable: true,
        ),
        clearActiveRide: true,
      );
      _log('[LAST_ACTIVE] updated source=driver_cancel rideId=$currentRideId');
      _log(
        '[CANCEL] actor=driver rideId=$currentRideId reason=$cancelReason success',
      );
    } catch (error) {
      _log(
        '[CANCEL] actor=driver rideId=$currentRideId reason=$cancelReason fail error=$error',
      );
      _log('driver cancel failed rideId=$currentRideId error=$error');
      _showSnackBarSafely(
        const SnackBar(
          content:
              Text('Unable to cancel this trip right now. Please try again.'),
        ),
      );
      return;
    } finally {
      if (mounted) {
        _setStateSafely(() {
          _isDriverCancellingRide = false;
        });
      } else {
        _isDriverCancellingRide = false;
      }
    }

    final cancelledRideData = Map<String, dynamic>.from(currentRide)
      ..addAll(<String, dynamic>{
        'status': 'cancelled',
        'trip_state': TripLifecycleState.tripCancelled,
        'cancel_reason': cancelReason.trim(),
        'cancelled_by': 'driver',
        'driver_id': _effectiveDriverId,
        ..._cancelledRideSupplementalUpdate(
          rideData: currentRide,
          cancelSource: 'driver_cancel',
        ),
      });

    unawaited(
      _driverTripSafetyService.logRideStateChange(
        rideId: currentRideId,
        riderId: riderId,
        driverId: _effectiveDriverId,
        serviceType: serviceType,
        status: 'cancelled',
        source: 'driver_cancel',
        rideData: cancelledRideData,
      ),
    );

    await _clearActiveRideState(
      reason: 'driver_cancelled',
      resetTripState: true,
    );
    _showSnackBarSafely(
      const SnackBar(content: Text('Trip cancelled.')),
    );
    _log('driver cancel completed rideId=$currentRideId');
  }

  Future<void> completeTrip() async {
    final currentRideId = _currentRideId;
    if (currentRideId == null) {
      return;
    }
    final completedRideData = _currentRideData == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(_currentRideData!);
    final riderId = _currentRiderIdForRide;
    final serviceType = _serviceTypeKey(completedRideData['service_type']);
    final isDispatchDelivery = _isDispatchDeliveryService(serviceType);
    final deliveryProofUrl = _dispatchDeliveryProofPhotoUrl(completedRideData);

    if (isDispatchDelivery && deliveryProofUrl.isEmpty) {
      _showSnackBarSafely(
        const SnackBar(
          content: Text(
            'Upload delivery proof before completing this dispatch.',
          ),
        ),
      );
      return;
    }

    final hasStartedCheckpointLogs = await _rideHasStartedCheckpointLogs(
      currentRideId,
      rideData: completedRideData,
    );
    if (!hasStartedCheckpointLogs) {
      await _cancelRideForSystemReason(
        rideId: currentRideId,
        rideData: completedRideData,
        reason: 'no_route_logs',
        transitionSource: 'system_invalid_trip_no_route_logs',
        cancelSource: 'system_invalid_trip_no_route_logs',
        invalidTrip: true,
        showMessage: true,
      );
      return;
    }

    final paymentMethod = _paymentMethodFromRide(completedRideData);
    final businessModel = await _resolveDriverBusinessModelForSettlement(
      source: 'complete_trip',
    );
    final settlement = _buildRideSettlementRecord(
      rideData: completedRideData,
      businessModel: businessModel,
      settlementStatus: 'trip_completed',
      completionState: 'driver_marked_completed',
      paymentMethod: paymentMethod,
    );
    final settledRideData = <String, dynamic>{
      ...completedRideData,
      'settlement': settlement,
      'grossFare': settlement['grossFareNgn'] ?? 0,
      'commission': settlement['commissionAmountNgn'] ?? 0,
      'commissionAmount': settlement['commissionAmountNgn'] ?? 0,
      'driverPayout': settlement['driverPayoutNgn'] ?? 0,
      'netEarning': settlement['netEarningNgn'] ?? 0,
    };

    final rideUpdates = TripStateMachine.buildTransitionUpdate(
      currentRide: completedRideData,
      nextCanonicalState: TripLifecycleState.tripCompleted,
      timestampValue: rtdb.ServerValue.timestamp,
      transitionSource: 'driver_complete_trip',
      transitionActor: 'driver',
    )..addAll(<String, dynamic>{
        'driver_id': _effectiveDriverId,
        'completed_driver_id': _effectiveDriverId,
        'trip_completed': true,
        'settlement': settlement,
        'grossFare': settlement['grossFareNgn'] ?? 0,
        'commission': settlement['commissionAmountNgn'] ?? 0,
        'commissionAmount': settlement['commissionAmountNgn'] ?? 0,
        'driverPayout': settlement['driverPayoutNgn'] ?? 0,
        'netEarning': settlement['netEarningNgn'] ?? 0,
      });
    if (isDispatchDelivery) {
      rideUpdates['deliveredAt'] = rtdb.ServerValue.timestamp;
      rideUpdates['deliveryProofStatus'] = 'submitted';
      rideUpdates['dispatch_details/deliveredAt'] = rtdb.ServerValue.timestamp;
      rideUpdates['dispatch_details/deliveryProofStatus'] = 'submitted';
    }

    final completedDriverPresence = _buildDriverPresenceUpdate(
      status: 'idle',
      isAvailable: true,
    );
    completedDriverPresence['latest_trip_ride_id'] = currentRideId;
    completedDriverPresence['latest_trip_status'] = 'completed';
    completedDriverPresence['latest_trip_trip_state'] =
        TripLifecycleState.tripCompleted;
    completedDriverPresence['latest_trip_at'] = rtdb.ServerValue.timestamp;

    await _commitRideAndDriverState(
      rideId: currentRideId,
      rideUpdates: rideUpdates,
      driverUpdates: completedDriverPresence,
      clearActiveRide: true,
    );
    await _endCallForRideLifecycle(rideId: currentRideId);

    await _clearDriverActiveRideNode(
      rideId: currentRideId,
      reason: 'completed',
    );
    try {
      await _driverTripSafetyService.logRideStateChange(
        rideId: currentRideId,
        riderId: riderId,
        driverId: _effectiveDriverId,
        serviceType: serviceType,
        status: 'completed',
        source: 'driver_complete_trip',
        rideData: settledRideData,
      );
    } catch (error) {
      _log(
          'trip completion state log failed rideId=$currentRideId error=$error');
    }
    try {
      await _driverTripSafetyService.updateSettlementHook(
        rideId: currentRideId,
        riderId: riderId,
        driverId: _effectiveDriverId,
        serviceType: serviceType,
        source: 'driver_complete_trip',
        settlementStatus: 'trip_completed',
        completionState: 'driver_marked_completed',
        paymentMethod: paymentMethod,
        reviewStatus: 'not_required',
        reportedOutstandingAmountNgn: 0,
        note: 'Driver marked the trip as completed.',
        evidence: const <String, dynamic>{},
        rideData: settledRideData,
        settlement: settlement,
      );
    } catch (error) {
      _log('trip settlement hook failed rideId=$currentRideId error=$error');
    }

    _log('trip completed rideId=$currentRideId');
    _logRtdb('active ride cleared reason=completed');
    _logTripPanelHidden('completed');
    await _resetTripState();
    if (mounted && riderId.isNotEmpty) {
      Future<void>.microtask(
        () => _showPostTripReviewSheet(
          rideId: currentRideId,
          rideData: settledRideData,
        ),
      );
    }
  }

  Future<void> _resetTripState() async {
    final previousRideId = _currentRideId;
    final driverId = _effectiveDriverId;
    if (previousRideId != null && previousRideId.isNotEmpty) {
      final p = previousRideId.trim();
      if (p.isNotEmpty) {
        _terminalSelfAcceptedRideIds.remove(p);
      }
      await _performLocalCallCleanup(
        rideId: previousRideId,
        logCleanup: false,
      );
    }

    if (driverId.isNotEmpty && _isOnline) {
      await _driversRef.child(driverId).update(
            _buildDriverPresenceUpdate(
              status: 'idle',
              isAvailable: true,
            ),
          );
    }

    _resetAllRideState();

    _log('trip state reset status=$_rideStatus');

    if (_isOnline && previousRideId != null) {
      _logListenerStillActiveWaitingForFreshRides();
      _rearmRideRequestListener(
        'ride lifecycle ended rideId=$previousRideId status=$_rideStatus',
      );
    }
  }

  double _calculateDistanceKm(LatLng start, LatLng end) {
    return Geolocator.distanceBetween(
          start.latitude,
          start.longitude,
          end.latitude,
          end.longitude,
        ) /
        1000;
  }

  double _calculateEtaMinutes(double distanceKm) {
    const averageSpeedKmPerHour = 40.0;
    return (distanceKm / averageSpeedKmPerHour) * 60;
  }

  void _clearRouteOverlay({bool cancelPendingRequests = true}) {
    if (cancelPendingRequests) {
      _cancelPendingRouteRequests(reason: 'clear_route_overlay');
    }
    _expectedRoutePoints.clear();
    _lastRouteBuiltAt = null;
    _lastRouteOrigin = null;
    _lastRouteBuildKey = '';
    _routeOverlayError = null;

    if (mounted) {
      _setStateSafely(() {
        _polyLines.clear();
      });
    } else {
      _polyLines.clear();
    }
  }

  Future<List<LatLng>> _composeRoutePoints(
    List<LatLng> points, {
    required int requestGeneration,
    required _RouteRequestKind routeKind,
    String? expectedRideId,
  }) async {
    if (points.length < 2) {
      return <LatLng>[];
    }

    if (_isRouteRequestStale(
      requestGeneration: requestGeneration,
      kind: routeKind,
      expectedRideId: expectedRideId,
    )) {
      return <LatLng>[];
    }

    final route = <LatLng>[];
    _routeOverlayError = null;
    try {
      for (var i = 0; i < points.length - 1; i++) {
        if (_isRouteRequestStale(
          requestGeneration: requestGeneration,
          kind: routeKind,
          expectedRideId: expectedRideId,
        )) {
          return <LatLng>[];
        }
        final origin = points[i];
        final destination = points[i + 1];

        try {
          final result = await _roadRouteService.fetchDrivingRoute(
            origin: origin,
            destination: destination,
          );
          if (_isRouteRequestStale(
            requestGeneration: requestGeneration,
            kind: routeKind,
            expectedRideId: expectedRideId,
          )) {
            return <LatLng>[];
          }
          final segment = result.points;
          _log(
            'route fetch result segment=${i + 1} points=${segment.length} origin=${origin.latitude},${origin.longitude} destination=${destination.latitude},${destination.longitude} hasRoute=${result.hasRoute} error=${result.errorMessage}',
          );

          if (!result.hasRoute || segment.length < 2) {
            _routeOverlayError = result.errorMessage ??
                'Route preview is reconnecting. Retry to refresh the live road path.';
            return <LatLng>[];
          }

          if (route.isEmpty) {
            route.addAll(segment);
          } else {
            route.addAll(segment.skip(1));
          }
        } catch (error) {
          _log('route segment error index=$i error=$error');
          _routeOverlayError =
              'Route preview is reconnecting. Retry to refresh the live road path.';
          return <LatLng>[];
        }
      }
    } catch (error) {
      _log('route compose error=$error');
      _routeOverlayError =
          'Route preview is reconnecting. Retry to refresh the live road path.';
      return <LatLng>[];
    }

    return route;
  }

  Future<void> _drawRoute(
    LatLng origin,
    LatLng destination, {
    required int requestGeneration,
    required _RouteRequestKind routeKind,
    String? expectedRideId,
  }) async {
    try {
      final routePoints = await _composeRoutePoints(
        <LatLng>[origin, destination],
        requestGeneration: requestGeneration,
        routeKind: routeKind,
        expectedRideId: expectedRideId,
      );
      if (_isRouteRequestStale(
        requestGeneration: requestGeneration,
        kind: routeKind,
        expectedRideId: expectedRideId,
      )) {
        return;
      }
      if (routePoints.length < 2) {
        _log('route draw skipped: no polyline points returned');
        if (mounted) {
          _setStateSafely(() {
            _polyLines.clear();
          });
        } else {
          _polyLines.clear();
        }
        return;
      }

      _routeOverlayError = null;
      if (mounted) {
        _setStateSafely(() {
          _polyLines
            ..clear()
            ..add(
              Polyline(
                polylineId: const PolylineId('route'),
                points: routePoints,
                width: 6,
                color: _gold,
              ),
            );
        });
      }
    } catch (error) {
      _log('route draw error=$error');
    }
  }

  Future<void> _refreshActiveRoute({
    bool force = false,
    required String reason,
    int? requestGeneration,
  }) async {
    final rideId = _currentRideId;
    if (rideId == null) {
      return;
    }
    final effectiveRequestGeneration =
        requestGeneration ?? _routeRequestGeneration;

    final routeTargets = _rideStatus == 'on_trip'
        ? _remainingTripWaypoints(_tripWaypoints)
        : (_pickupLocation == null
            ? <_TripWaypoint>[]
            : <_TripWaypoint>[
                _TripWaypoint(
                  location: _pickupLocation!,
                  address: _pickupAddressText,
                ),
              ]);

    if (routeTargets.isEmpty) {
      _clearRouteOverlay(cancelPendingRequests: false);
      return;
    }

    final origin = _driverLocation;
    final routeBuildKey =
        '$rideId|$_rideStatus|${routeTargets.map((waypoint) => _latLngKey(waypoint.location)).join('|')}';
    final routeKeyChanged = routeBuildKey != _lastRouteBuildKey;
    final now = DateTime.now();
    final originDelta = _lastRouteOrigin == null
        ? double.infinity
        : Geolocator.distanceBetween(
            _lastRouteOrigin!.latitude,
            _lastRouteOrigin!.longitude,
            origin.latitude,
            origin.longitude,
          );
    final shouldRefresh = force ||
        _lastRouteBuiltAt == null ||
        routeKeyChanged ||
        now.difference(_lastRouteBuiltAt!) >= _kRouteRefreshInterval ||
        originDelta >= _kRouteRefreshDistanceMeters;

    if (!shouldRefresh || _routeBuildInFlight) {
      return;
    }

    _routeBuildInFlight = true;

    try {
      final routePoints = await _composeRoutePoints(
        <LatLng>[
          origin,
          ...routeTargets.map((waypoint) => waypoint.location),
        ],
        requestGeneration: effectiveRequestGeneration,
        routeKind: _RouteRequestKind.active,
        expectedRideId: rideId,
      );
      if (_isRouteRequestStale(
        requestGeneration: effectiveRequestGeneration,
        kind: _RouteRequestKind.active,
        expectedRideId: rideId,
      )) {
        return;
      }
      _nextNavigationTarget = routeTargets.first.location;
      if (routePoints.length < 2) {
        _expectedRoutePoints.clear();
        _lastRouteBuiltAt = now;
        _lastRouteOrigin = origin;
        _lastRouteBuildKey = routeBuildKey;
        _syncTripLocationMarkers();
        if (mounted) {
          _setStateSafely(() {
            _polyLines.clear();
          });
        } else {
          _polyLines.clear();
        }
        _log(
          'active route unavailable rideId=$rideId reason=$reason error=${_routeOverlayError ?? 'unknown'} markers_only=true',
        );
        if (force || routeKeyChanged) {
          try {
            _moveCameraToActiveTrip();
          } catch (error) {
            _log(
                'active route camera update skipped reason=$reason error=$error');
          }
        }
        return;
      }

      _routeOverlayError = null;
      _expectedRoutePoints
        ..clear()
        ..addAll(routePoints);
      _lastRouteBuiltAt = now;
      _lastRouteOrigin = origin;
      _lastRouteBuildKey = routeBuildKey;
      _nextNavigationTarget = routeTargets.first.location;
      _syncTripLocationMarkers();

      if (!mounted) {
        return;
      }

      _setStateSafely(() {
        _polyLines
          ..clear()
          ..add(
            Polyline(
              polylineId: const PolylineId('route'),
              points: routePoints,
              width: 6,
              color: _gold,
            ),
          );
      });

      if (_rideStatus == 'on_trip' && routeTargets.length > 1) {
        _log(
          'route built with stops rideId=$rideId stopCount=${routeTargets.length - 1} reason=$reason',
        );
      } else if (_rideStatus == 'on_trip') {
        _log('route built to destination rideId=$rideId reason=$reason');
      } else {
        _log('route built to pickup rideId=$rideId reason=$reason');
      }

      final activeRideData = _currentRideData;
      if (activeRideData != null) {
        unawaited(
          _logRouteConsistencyCheckIfNeeded(
            rideId: rideId,
            rideData: activeRideData,
            source: 'driver_active_route_refresh',
            driverRoutePointsOverride: routePoints,
          ),
        );
      }

      if (force || routeKeyChanged) {
        try {
          _moveCameraToActiveTrip();
        } catch (error) {
          _log(
              'active route camera update skipped reason=$reason error=$error');
        }
      }
    } catch (error) {
      _log(
          'active route refresh failed rideId=$rideId reason=$reason error=$error');
      _routeOverlayError ??=
          'Route preview is reconnecting. Retry to refresh the live road path.';
      _expectedRoutePoints.clear();
      _nextNavigationTarget = routeTargets.first.location;
      _syncTripLocationMarkers();
      if (mounted) {
        _setStateSafely(() {
          _polyLines.clear();
        });
      } else {
        _polyLines.clear();
      }
    } finally {
      _routeBuildInFlight = false;
    }
  }

  void _evaluateArrivedAvailability() {
    final rideId = _currentRideId;
    final pickup = _pickupLocation;
    if (rideId == null ||
        pickup == null ||
        !_isArrivedEligibleRideStatus(_rideStatus) ||
        _activeRideInvalidReason(
              _currentRideData,
              rideId: rideId,
              requireTrackedRide: true,
            ) !=
            null) {
      if (_arrivedEnabled != false) {
        if (mounted) {
          setState(() {
            _arrivedEnabled = false;
          });
        } else {
          _arrivedEnabled = false;
        }
      }
      _hasLoggedArrivedEnabled = false;
      return;
    }

    final distanceMeters = Geolocator.distanceBetween(
      _driverLocation.latitude,
      _driverLocation.longitude,
      pickup.latitude,
      pickup.longitude,
    );
    final etaMinutes = _calculateEtaMinutes(distanceMeters / 1000);
    _log(
      'arrived check etaMinutes=${etaMinutes.round()} distanceMeters=${distanceMeters.round()}',
    );

    final arrivedEnabled = distanceMeters < _kArrivedDistanceThresholdMeters;

    if (arrivedEnabled && !_hasLoggedArrivedEnabled) {
      _log('arrived enabled rideId=$rideId');
      _logRtdb(
        'arrived enabled rideId=$rideId distanceMeters=${distanceMeters.round()}',
      );
      _hasLoggedArrivedEnabled = true;
    }

    if (!arrivedEnabled) {
      _hasLoggedArrivedEnabled = false;
    }

    if (mounted) {
      setState(() {
        _arrivedEnabled = arrivedEnabled;
      });
    } else {
      _arrivedEnabled = arrivedEnabled;
    }
  }

  void _startDriverSafetyMonitoring(String rideId) {
    if (_safetyMonitoringActive) {
      return;
    }

    _safetyMonitoringActive = true;
    _lastMoveTime = DateTime.now();
    _lastSafetyCheckLocation = _driverLocation;
    _lastDriverSpeedSampleAt = null;
    _lastDriverImpliedSpeedKmh = null;
    _routeDeviationStrikeCount = 0;
    _logSafety('monitoring started rideId=$rideId');
  }

  void _stopDriverSafetyMonitoring() {
    _safetyMonitoringActive = false;
    _lastMoveTime = null;
    _lastSafetyCheckLocation = null;
    _lastDriverSpeedSampleAt = null;
    _lastDriverImpliedSpeedKmh = null;
    _routeDeviationStrikeCount = 0;
    _clearSafetyPrompt();
  }

  bool _isNearExpectedStop(LatLng driverPosition) {
    final checkpoints = _remainingTripWaypoints(_tripWaypoints)
        .map((waypoint) => waypoint.location)
        .toList();

    for (final checkpoint in checkpoints) {
      final distance = Geolocator.distanceBetween(
        checkpoint.latitude,
        checkpoint.longitude,
        driverPosition.latitude,
        driverPosition.longitude,
      );
      if (distance <= _kSafetyExpectedStopRadiusMeters) {
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

  Future<void> _publishRiderSuddenStopSafetyAlert(String rideId) async {
    try {
      await _rideRequestsRef.child(rideId).update(<String, dynamic>{
        'rider_safety_alert': <String, dynamic>{
          'type': 'sudden_stop',
          'issued_at': DateTime.now().millisecondsSinceEpoch,
          'source': 'driver_device',
        },
      });
    } catch (error) {
      _logSafety('rider_safety_alert publish failed rideId=$rideId error=$error');
    }
  }

  void _checkDriverSafety() {
    final rideId = _currentRideId;
    if (!_safetyMonitoringActive ||
        _rideStatus != 'on_trip' ||
        rideId == null) {
      return;
    }

    final now = DateTime.now();
    final previousPosition = _lastSafetyCheckLocation;
    final currentPosition = _driverLocation;
    final nearExpectedStop = _isNearExpectedStop(currentPosition);
    final distanceFromRoute = _distanceFromExpectedRouteMeters(currentPosition);

    if (previousPosition == null) {
      _lastMoveTime = now;
      _lastSafetyCheckLocation = currentPosition;
      _lastDriverSpeedSampleAt = null;
      _lastDriverImpliedSpeedKmh = null;
      return;
    }

    final movement = Geolocator.distanceBetween(
      previousPosition.latitude,
      previousPosition.longitude,
      currentPosition.latitude,
      currentPosition.longitude,
    );

    if (nearExpectedStop) {
      _routeDeviationStrikeCount = 0;
      _lastMoveTime = now;
      _lastDriverImpliedSpeedKmh = null;
      _lastDriverSpeedSampleAt = now;
    } else {
      if (_lastDriverSpeedSampleAt != null) {
        final dtSec =
            now.difference(_lastDriverSpeedSampleAt!).inMilliseconds / 1000.0;
        if (dtSec >= _kSuddenStopMinDtSec && dtSec <= _kSuddenStopMaxDtSec) {
          final impliedKmh = (movement / dtSec) * 3.6;
          final prev = _lastDriverImpliedSpeedKmh;
          if (prev != null &&
              prev >= _kSuddenStopMinPriorKmh &&
              impliedKmh <= _kSuddenStopMaxAfterKmh &&
              (prev - impliedKmh) >= _kSuddenStopDropKmh) {
            _logSafety(
              'sudden deceleration detected rideId=$rideId '
              'prevKmh=${prev.toStringAsFixed(1)} nextKmh=${impliedKmh.toStringAsFixed(1)}',
            );
            unawaited(
              _driverTripSafetyService.createSafetyFlag(
                rideId: rideId,
                riderId: _currentRiderIdForRide,
                driverId: _effectiveDriverId,
                serviceType: _serviceTypeKey(_currentRideData?['service_type']),
                flagType: 'sudden_stop',
                source: 'driver_map_monitor',
                message:
                    'Driver device inferred a sharp slowdown during an active trip.',
                status: 'manual_review',
                severity: 'high',
              ),
            );
            _showDriverSafetyPrompt(
              rideId: rideId,
              reason: 'sudden_stop',
              message:
                  'Sharp braking detected. If you are in danger, pull over safely and use SOS.',
            );
            unawaited(_publishRiderSuddenStopSafetyAlert(rideId));
          }
          _lastDriverImpliedSpeedKmh = impliedKmh;
        } else if (dtSec > _kSuddenStopMaxDtSec || dtSec <= 0) {
          _lastDriverImpliedSpeedKmh = null;
        }
      }
      if (movement >= _kSafetyStopMovementThresholdMeters) {
        _lastMoveTime = now;
      } else if (_lastMoveTime != null &&
          now.difference(_lastMoveTime!) >= _kSafetyLongStopDuration) {
        _logSafety('long stop detected rideId=$rideId');
        _lastMoveTime = now;
        unawaited(
          _driverTripSafetyService.createSafetyFlag(
            rideId: rideId,
            riderId: _currentRiderIdForRide,
            driverId: _effectiveDriverId,
            serviceType: _serviceTypeKey(_currentRideData?['service_type']),
            flagType: 'long_stop',
            source: 'driver_map_monitor',
            message:
                'Driver device detected a prolonged stop outside the expected stop radius.',
            status: 'manual_review',
            severity: 'medium',
          ),
        );
        _showDriverSafetyPrompt(
          rideId: rideId,
          reason: 'long_stop',
          message:
              'Are you okay? We noticed this trip has stopped longer than expected.',
        );
      }

      if (distanceFromRoute != null &&
          distanceFromRoute > _kSafetyRouteDeviationThresholdMeters) {
        _routeDeviationStrikeCount += 1;
        if (_routeDeviationStrikeCount >= 3) {
          _routeDeviationStrikeCount = 0;
          _logSafety('route deviation detected rideId=$rideId');
          unawaited(
            _driverTripSafetyService.createSafetyFlag(
              rideId: rideId,
              riderId: _currentRiderIdForRide,
              driverId: _effectiveDriverId,
              serviceType: _serviceTypeKey(_currentRideData?['service_type']),
              flagType: 'route_deviation',
              source: 'driver_map_monitor',
              message:
                  'Driver device detected a significant deviation from the expected route.',
              distanceFromRouteMeters: distanceFromRoute,
              status: 'manual_review',
              severity: 'high',
            ),
          );
          _showDriverSafetyPrompt(
            rideId: rideId,
            reason: 'route_deviation',
            message:
                'What\'s happening on this trip? We noticed you moved away from the expected route.',
          );
        }
      } else {
        _routeDeviationStrikeCount = 0;
      }
      _lastDriverSpeedSampleAt = now;
    }

    _lastSafetyCheckLocation = currentPosition;
  }

  void _moveCameraToBounds(List<LatLng> points, double padding) {
    if (_mapController == null || points.isEmpty) {
      return;
    }

    final latitudes = points.map((point) => point.latitude);
    final longitudes = points.map((point) => point.longitude);
    final minLat = latitudes.reduce(math.min);
    final maxLat = latitudes.reduce(math.max);
    final minLng = longitudes.reduce(math.min);
    final maxLng = longitudes.reduce(math.max);

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

  void _moveCameraToIdleState() {
    if (_mapController == null || _hasRenderableActiveRide) {
      return;
    }

    final target = (_mapLocationReady && !_deviceLocationOutsideLaunchArea)
        ? _driverLocation
        : _selectedLaunchCityCenter;
    _mapController!.animateCamera(
      CameraUpdate.newLatLngZoom(
          target, DriverServiceAreaConfig.defaultMapZoom),
    );
  }

  void _moveCameraToActiveTrip() {
    final points = <LatLng>[_driverLocation];
    if (_rideStatus == 'on_trip') {
      points.addAll(
        _remainingTripWaypoints(_tripWaypoints)
            .map((waypoint) => waypoint.location),
      );
    } else if (_pickupLocation != null) {
      points.add(_pickupLocation!);
    }

    if (points.isEmpty) {
      return;
    }

    _moveCameraToBounds(points, 120);
  }

  Future<void> _playSound() async {
    try {
      await _alertSoundService.playRideRequestAlert();
    } catch (error) {
      _log('sound error=$error');
    }
  }

  Future<void> _startCallRingtone() async {
    try {
      await _alertSoundService.startIncomingCallAlert();
    } catch (error) {
      _log('call ringtone error=$error');
    }
  }

  Future<void> _stopCallRingtone() async {
    try {
      await _alertSoundService.stopIncomingCallAlert();
    } catch (error) {
      _log('call ringtone stop error=$error');
    }
  }

  Future<void> _playChatNotificationSound() async {
    try {
      await _alertSoundService.playChatAlert();
      await HapticFeedback.lightImpact();
    } catch (error) {
      _log('chat sound error=$error');
    }
  }

  void _showDriverIncomingChatNotice() {
    final now = DateTime.now();
    if (_lastDriverChatNoticeAt != null &&
        now.difference(_lastDriverChatNoticeAt!) < const Duration(seconds: 2)) {
      return;
    }
    _lastDriverChatNoticeAt = now;
    if (!mounted) {
      return;
    }
    _showSnackBarSafely(
      SnackBar(
        content: const Text('New message from rider'),
        action: SnackBarAction(
          label: 'Open',
          onPressed: _openDriverChat,
        ),
      ),
    );
  }

  void _updateDriverMarker() {
    _markers.removeWhere((marker) => marker.markerId.value == 'driver');
    _markers.add(
      Marker(
        markerId: const MarkerId('driver'),
        position: _driverLocation,
      ),
    );
  }

  Widget _buildMapInitializationOverlay() {
    final hasError = _mapInitializationError != null;
    final subtitle = hasError
        ? _mapInitializationError!
        : 'Getting your map and driver location ready.';

    return Positioned.fill(
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: <Color>[
              Color(0xFFF7F2EA),
              Color(0xFFE9DDBF),
            ],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        alignment: Alignment.center,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(28),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x1A000000),
                    blurRadius: 24,
                    offset: Offset(0, 14),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Container(
                    width: 62,
                    height: 62,
                    decoration: BoxDecoration(
                      color: _gold.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Icon(
                      hasError
                          ? Icons.map_outlined
                          : Icons.location_searching_rounded,
                      color: _gold,
                      size: 30,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    hasError ? 'Map unavailable right now' : 'Opening your map',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    subtitle,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.black.withValues(alpha: 0.66),
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (!hasError)
                    const CircularProgressIndicator(color: Color(0xFFD4AF37))
                  else
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _gold,
                          foregroundColor: Colors.black,
                        ),
                        onPressed: _retryMapInitialization,
                        child: const Text('Retry map'),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _retryProfileSyncFromMap() async {
    if (_profileSyncRetryInProgress) {
      return;
    }

    if (mounted) {
      ScaffoldMessenger.maybeOf(context)?.hideCurrentMaterialBanner();
    }
    _profileSyncMaterialBannerShown = false;

    _log('driver profile retry requested from map');
    if (mounted) {
      setState(() {
        _profileSyncRetryInProgress = true;
      });
    } else {
      _profileSyncRetryInProgress = true;
    }

    try {
      if (widget.onRetryProfileSync != null) {
        await widget.onRetryProfileSync!.call();
      }
      await _loadOptionalDriverBootstrapContext();
    } finally {
      if (mounted) {
        setState(() {
          _profileSyncRetryInProgress = false;
        });
      } else {
        _profileSyncRetryInProgress = false;
      }
      if (mounted &&
          (widget.profileSyncIssueMessage?.trim().isNotEmpty ?? false)) {
        _profileSyncMaterialBannerShown = false;
        _scheduleProfileSyncMaterialBanner();
      }
    }
  }

  Future<void> _signOutFromProfileIssue() async {
    _log('driver profile issue sign out requested');
    if (mounted) {
      ScaffoldMessenger.maybeOf(context)?.hideCurrentMaterialBanner();
    }
    await FirebaseAuth.instance.signOut();
  }

  Future<void> _openNavigation() async {
    final target = _nextNavigationTarget ??
        (_tripStarted ? _destinationLocation : _pickupLocation);
    if (target == null) {
      return;
    }

    final url = Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination=${target.latitude},${target.longitude}',
    );

    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  Future<String?> _sendDriverChatMessage(String rideId, String text) async {
    return _sendDriverChatMessageInternal(rideId: rideId, text: text);
  }

  Future<String?> _retryDriverChatMessage(
    String rideId,
    RideChatMessage message,
  ) async {
    _log(
      '[CHAT_RETRY] role=driver rideId=$rideId uid=$_effectiveDriverId messageId=${message.id}',
    );
    return _sendDriverChatMessageInternal(
      rideId: rideId,
      text: message.text,
      imageUrl: message.imageUrl,
      retryMessageId: message.id,
      retryType: message.type,
    );
  }

  Future<String?> _sendDriverChatMessageInternal({
    required String rideId,
    required String text,
    String imageUrl = '',
    String? retryMessageId,
    String retryType = 'text',
  }) async {
    final senderId = _effectiveDriverId;
    if (senderId.isEmpty) {
      _log('message send blocked rideId=$rideId reason=missing_driver_id');
      return 'Driver account is not available.';
    }

    final trimmed = text.trim();
    final normalizedImageUrl = imageUrl.trim();
    if (trimmed.isEmpty && normalizedImageUrl.isEmpty) {
      return null;
    }

    if (!_canOpenChat || !_isDriverChatSessionActive(rideId)) {
      return 'Chat is available only for accepted or active rides.';
    }

    if (_driverChatSendInFlight) {
      return 'Please wait for the current message to finish sending.';
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

    _driverChatSendInFlight = true;
    try {
      if (_driverChatListenerRideId == null &&
          _isDriverChatSessionActive(normalizedRideId)) {
        _startDriverChatListener(normalizedRideId);
      }

      final clientCreatedAt = DateTime.now().millisecondsSinceEpoch;
      final messageType = normalizedImageUrl.isNotEmpty ? 'image' : retryType;
      final optimistic = RideChatMessage(
        id: messageId,
        rideId: normalizedRideId,
        messageId: messageId,
        senderId: senderId,
        senderRole: 'driver',
        type: messageType,
        text: trimmed,
        imageUrl: normalizedImageUrl,
        createdAt: clientCreatedAt,
        status: 'sending',
        isRead: false,
        localTempId: messageId,
      );
      if (_driverChatListenerRideId == normalizedRideId) {
        _driverChatMessagesById[messageId] = optimistic;
        _flushDriverChatMessageTable(normalizedRideId);
      }

      final payload = <String, dynamic>{
        'senderId': senderId,
        'senderRole': 'driver',
        'type': messageType,
        'text': trimmed,
        'imageUrl': normalizedImageUrl.isEmpty ? null : normalizedImageUrl,
        'timestamp': rtdb.ServerValue.timestamp,
      };
      final lastMessageMeta = <String, dynamic>{
        'id': messageId,
        'ride_id': normalizedRideId,
        'sender_id': senderId,
        'sender_role': 'driver',
        'text': _driverChatPreview(trimmed.isEmpty ? 'Photo' : trimmed),
        'created_at': rtdb.ServerValue.timestamp,
        'created_at_client': clientCreatedAt,
      };
      _log(
        '[CHAT_SEND_START] role=driver rideId=$normalizedRideId '
        'messageId=$messageId path=${canonicalRideChatMessagesPath(normalizedRideId)}/$messageId',
      );
      try {
        Future<void> writeAttempt() async {
          await messageNode.set(payload).timeout(_kRideChatSendTimeout);
        }
        try {
          await writeAttempt();
        } catch (_) {
          await writeAttempt();
        }
        await rootRef.update(<String, dynamic>{
          '${canonicalRideChatParticipantPath(normalizedRideId, senderId)}/uid':
              senderId,
          '${canonicalRideChatParticipantPath(normalizedRideId, senderId)}/sender_role':
              'driver',
          '${canonicalRideChatParticipantPath(normalizedRideId, senderId)}/updated_at':
              rtdb.ServerValue.timestamp,
          'ride_requests/$normalizedRideId/chat_last_message': lastMessageMeta,
          'ride_requests/$normalizedRideId/chat_last_message_text':
              lastMessageMeta['text'],
          'ride_requests/$normalizedRideId/chat_last_message_sender_id':
              senderId,
          'ride_requests/$normalizedRideId/chat_last_message_sender_role':
              'driver',
          'ride_requests/$normalizedRideId/chat_last_message_at':
              rtdb.ServerValue.timestamp,
          'ride_requests/$normalizedRideId/chat_updated_at':
              rtdb.ServerValue.timestamp,
          'ride_requests/$normalizedRideId/has_chat_messages': true,
          '${canonicalRideChatMetaPath(normalizedRideId)}/rideId':
              normalizedRideId,
          '${canonicalRideChatMetaPath(normalizedRideId)}/rider_id':
              _currentRiderIdForRide,
          '${canonicalRideChatMetaPath(normalizedRideId)}/driver_id': senderId,
          '${canonicalRideChatMetaPath(normalizedRideId)}/created_at':
              rtdb.ServerValue.timestamp,
          '${canonicalRideChatMetaPath(normalizedRideId)}/updated_at':
              rtdb.ServerValue.timestamp,
          '${canonicalRideChatMetaPath(normalizedRideId)}/last_message':
              lastMessageMeta['text'],
          '${canonicalRideChatMetaPath(normalizedRideId)}/last_message_sender_id':
              senderId,
          '${canonicalRideChatMetaPath(normalizedRideId)}/last_message_at':
              rtdb.ServerValue.timestamp,
          '${canonicalRideChatMetaPath(normalizedRideId)}/status': 'active',
        }).timeout(_kRideChatSendTimeout);

        _confirmDriverOptimisticMessageSent(
          rideId: normalizedRideId,
          messageId: messageId,
          senderId: senderId,
          text: trimmed,
          clientCreatedAt: clientCreatedAt,
        );

        final riderRecipient = _currentRiderIdForRide.trim();
        if (riderRecipient.isNotEmpty) {
          unawaited(
            _bumpRideChatUnreadForRecipient(
              rideId: normalizedRideId,
              recipientUid: riderRecipient,
            ),
          );
        }

        unawaited(_mirrorDriverChatToTripRouteLog(
          rideId: normalizedRideId,
          messageId: messageId,
          payload: payload,
          lastMessageMeta: lastMessageMeta,
        ));

        _log(
          '[CHAT_SEND_OK] role=driver rideId=$normalizedRideId '
          'messageId=$messageId path=${canonicalRideChatMessagesPath(normalizedRideId)}/$messageId',
        );
        return null;
      } catch (error) {
        _markDriverOptimisticMessageFailed(
          rideId: normalizedRideId,
          messageId: messageId,
          senderId: senderId,
          text: trimmed,
        );
        _log(
          '[CHAT_SEND_FAIL] role=driver rideId=$normalizedRideId '
          'messageId=$messageId error=$error',
        );
        if (error is TimeoutException) {
          return 'Sending this message took too long. Please try again.';
        }
        if (isRealtimeDatabasePermissionDenied(error)) {
          _log(
            '[CHAT_PERMISSION_DENIED] rideId=$normalizedRideId '
            'path=${canonicalRideChatMessagesPath(normalizedRideId)}/$messageId '
            'error=$error',
          );
        }
        return isRealtimeDatabasePermissionDenied(error)
            ? 'Chat permission was denied for this ride.'
            : 'Unable to send message right now.';
      }
    } finally {
      _driverChatSendInFlight = false;
    }
  }

  Future<String?> _sendDriverChatImage(
    String rideId,
    DriverRideChatImageSource source,
  ) async {
    final senderId = _effectiveDriverId;
    if (senderId.isEmpty) {
      return 'Driver account is not available.';
    }
    final normalizedRideId = rideId.trim();
    final useCamera = source == DriverRideChatImageSource.camera;
    _log(
      '[CHAT_IMAGE_PICK] role=driver rideId=$normalizedRideId uid=$senderId source=${useCamera ? 'camera' : 'gallery'}',
    );
    if (useCamera) {
      final cameraPermission = await Permission.camera.request();
      if (!cameraPermission.isGranted) {
        return 'Camera permission is required to take a photo.';
      }
    }
    final picked = await _dispatchPhotoPicker.pickImage(
      source: useCamera ? ImageSource.camera : ImageSource.gallery,
      maxWidth: 1600,
      imageQuality: 86,
    );
    if (picked == null) {
      return null;
    }
    _log(
      '[CHAT_IMAGE_UPLOAD_START] role=driver rideId=$normalizedRideId uid=$senderId',
    );
    try {
      final uploaded = await _dispatchPhotoUploadService.uploadRideChatPhoto(
        rideId: normalizedRideId,
        actorId: senderId,
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
      final result = await _sendDriverChatMessageInternal(
        rideId: normalizedRideId,
        text: '',
        imageUrl: uploaded.fileUrl,
        retryType: 'image',
      );
      if (result == null) {
        _log(
          '[CHAT_IMAGE_UPLOAD_OK] role=driver rideId=$normalizedRideId uid=$senderId',
        );
      } else {
        _log(
          '[CHAT_IMAGE_UPLOAD_FAIL] role=driver rideId=$normalizedRideId uid=$senderId error=$result',
        );
      }
      return result;
    } catch (error) {
      _log(
        '[CHAT_IMAGE_UPLOAD_FAIL] role=driver rideId=$normalizedRideId uid=$senderId error=$error',
      );
      return 'Unable to send this image right now.';
    }
  }

  void _openDriverChat() {
    final rideId = _activeDriverRideContextId;
    if (rideId == null || !_canOpenChat) {
      return;
    }

    _startDriverChatListener(rideId);
    _log('[CHAT_OPEN] role=driver rideId=$rideId');
    _resetDriverUnreadCount(rideId);
    unawaited(_clearOwnRideChatUnreadRtdb(rideId, _effectiveDriverId));
    unawaited(
      _markDriverMessagesRead(
        rideId,
        messages: _driverChatMessages.value,
      ),
    );

    if (mounted) {
      _setStateSafely(() {
        _driverMissedCallNotice = false;
        _isDriverChatOpen = true;
      });
    } else {
      _driverMissedCallNotice = false;
      _isDriverChatOpen = true;
    }

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) {
        return DriverRideChatSheet(
          rideId: rideId,
          currentUserId: _effectiveDriverId,
          messagesListenable: _driverChatMessages,
          onSendMessage: _sendDriverChatMessage,
          onRetryMessage: _retryDriverChatMessage,
          onSendImage: _sendDriverChatImage,
          initialDraft: _driverChatDraftByRide[rideId] ?? '',
          onDraftChanged: (value) {
            _driverChatDraftByRide[rideId] = value;
          },
          onStartVoiceCall: _showRideCallButton
              ? () {
                  unawaited(_startVoiceCallFromChat());
                }
              : null,
          showCallButton: _showRideCallButton,
          isCallButtonEnabled: _isRideCallButtonEnabled,
          isCallButtonBusy: _isStartingVoiceCall,
        );
      },
    ).whenComplete(() {
      _isDriverChatOpen = false;
      _driverChatDraftByRide.removeWhere((key, _) => key != rideId);
    });
  }

  String _rideStatusLabel() {
    final serviceType = _serviceTypeKey(_currentRideData?['service_type']);
    return _serviceLifecycleLabel(serviceType, _rideStatus);
  }

  Widget _buildTripDetailRow({
    required IconData icon,
    required String label,
    required String value,
    Color? iconColor,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: iconColor ?? Colors.black87),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Colors.black54,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTripMetric({
    required String label,
    required String value,
  }) {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Colors.black54,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Colors.black87,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetaChip({
    required String label,
    required Color color,
    IconData? icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...[
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  String _dispatchRecipientSummary(Map<String, dynamic>? ride) {
    final recipientName = _dispatchRecipientName(ride);
    final recipientPhone = _dispatchRecipientPhone(ride);
    return <String>[
      if (recipientName.isNotEmpty) recipientName,
      if (recipientPhone.isNotEmpty) recipientPhone,
    ].join(' • ');
  }

  String _mimeTypeForDispatchPhotoPath(String path) {
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

  Future<DispatchPhotoSelectedAsset?> _pickDispatchPhotoAsset(
    _DispatchPhotoSource source,
  ) async {
    if (source == _DispatchPhotoSource.camera) {
      final status = await Permission.camera.request();
      if (!status.isGranted) {
        _showSnackBarSafely(
          const SnackBar(
            content: Text('Camera permission is required for delivery proof.'),
          ),
        );
        return null;
      }
    }

    final image = await _dispatchPhotoPicker.pickImage(
      source: source == _DispatchPhotoSource.camera
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
      mimeType: _mimeTypeForDispatchPhotoPath(image.path),
      fileSizeBytes: File(image.path).lengthSync(),
      source: source == _DispatchPhotoSource.camera ? 'camera' : 'gallery',
    );
  }

  Future<_DispatchPhotoSource?> _showDispatchPhotoSourceSheet() async {
    if (!mounted) {
      return null;
    }

    return showModalBottomSheet<_DispatchPhotoSource>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (BuildContext sheetContext) {
        Widget buildSourceTile({
          required IconData icon,
          required String title,
          required String subtitle,
          required _DispatchPhotoSource source,
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
                    'Upload delivery proof',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Add a clear completion photo before you close this dispatch.',
                    style: TextStyle(
                      color: Colors.black.withValues(alpha: 0.64),
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 18),
                  buildSourceTile(
                    icon: Icons.photo_camera_outlined,
                    title: 'Take photo',
                    subtitle: 'Use the camera for a fresh delivery snapshot.',
                    source: _DispatchPhotoSource.camera,
                  ),
                  const SizedBox(height: 12),
                  buildSourceTile(
                    icon: Icons.photo_library_outlined,
                    title: 'Choose from gallery',
                    subtitle: 'Select an existing photo from your device.',
                    source: _DispatchPhotoSource.gallery,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showDispatchImagePreview({
    required String title,
    required String imageUrl,
  }) async {
    if (!mounted || imageUrl.trim().isEmpty) {
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return Dialog(
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
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
                          child: Image.network(
                            imageUrl,
                            fit: BoxFit.contain,
                            width: double.infinity,
                            loadingBuilder: (context, child, loadingProgress) {
                              if (loadingProgress == null) {
                                return child;
                              }
                              return const Center(
                                child: CircularProgressIndicator(
                                  color: Color(0xFFD4AF37),
                                ),
                              );
                            },
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

  Future<void> _uploadDispatchDeliveryProof() async {
    final currentRideId = _currentRideId;
    final currentRideData = _currentRideData;
    if (currentRideId == null ||
        currentRideData == null ||
        !_isDispatchDeliveryService(
          _serviceTypeKey(currentRideData['service_type']),
        )) {
      return;
    }
    if (_deliveryProofUploading) {
      return;
    }

    final source = await _showDispatchPhotoSourceSheet();
    if (source == null) {
      return;
    }

    final asset = await _pickDispatchPhotoAsset(source);
    if (asset == null) {
      return;
    }

    if (mounted) {
      setState(() {
        _deliveryProofUploading = true;
        _deliveryProofUploadProgress = 0.05;
      });
    } else {
      _deliveryProofUploading = true;
      _deliveryProofUploadProgress = 0.05;
    }

    try {
      final uploadedPhoto = await _dispatchPhotoUploadService.uploadRidePhoto(
        rideId: currentRideId,
        actorId: _effectiveDriverId,
        category: 'delivery_proof',
        asset: asset,
        onProgress: (double progress) {
          if (!mounted) {
            _deliveryProofUploadProgress = progress.clamp(0.08, 0.94);
            return;
          }
          setState(() {
            _deliveryProofUploadProgress = progress.clamp(0.08, 0.94);
          });
        },
      );

      await _rideRequestsRef.child(currentRideId).update(<String, dynamic>{
        'deliveryProofPhotoUrl': uploadedPhoto.fileUrl,
        'deliveryProofSubmittedAt': rtdb.ServerValue.timestamp,
        'deliveryProofStatus': 'submitted',
        'dispatch_details/deliveryProofPhotoUrl': uploadedPhoto.fileUrl,
        'dispatch_details/deliveryProofSubmittedAt': rtdb.ServerValue.timestamp,
        'dispatch_details/deliveryProofStatus': 'submitted',
        'updated_at': rtdb.ServerValue.timestamp,
      });

      if (mounted) {
        setState(() {
          _deliveryProofUploading = false;
          _deliveryProofUploadProgress = 0;
          final nextRideData = Map<String, dynamic>.from(currentRideData);
          nextRideData['deliveryProofPhotoUrl'] = uploadedPhoto.fileUrl;
          nextRideData['deliveryProofStatus'] = 'submitted';
          _currentRideData = _copyRideWithDispatchDetails(
            nextRideData,
            <String, dynamic>{
              'deliveryProofPhotoUrl': uploadedPhoto.fileUrl,
              'deliveryProofStatus': 'submitted',
            },
          );
        });
      } else {
        _deliveryProofUploading = false;
        _deliveryProofUploadProgress = 0;
        final nextRideData = Map<String, dynamic>.from(currentRideData);
        nextRideData['deliveryProofPhotoUrl'] = uploadedPhoto.fileUrl;
        nextRideData['deliveryProofStatus'] = 'submitted';
        _currentRideData = _copyRideWithDispatchDetails(
          nextRideData,
          <String, dynamic>{
            'deliveryProofPhotoUrl': uploadedPhoto.fileUrl,
            'deliveryProofStatus': 'submitted',
          },
        );
      }

      _showSnackBarSafely(
        const SnackBar(
          content: Text('Delivery proof uploaded successfully.'),
        ),
      );
    } catch (error) {
      _log('delivery proof upload failed rideId=$currentRideId error=$error');
      _showSnackBarSafely(
        const SnackBar(
          content: Text('Unable to upload delivery proof right now.'),
        ),
      );
      if (mounted) {
        setState(() {
          _deliveryProofUploading = false;
          _deliveryProofUploadProgress = 0;
        });
      } else {
        _deliveryProofUploading = false;
        _deliveryProofUploadProgress = 0;
      }
    }
  }

  Widget _buildDispatchMediaCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required String actionLabel,
    required VoidCallback onPressed,
    String? secondaryActionLabel,
    VoidCallback? onSecondaryPressed,
    Widget? footer,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kDriverCream,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
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
                  color: _gold.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: _gold),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        color: Colors.black87,
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
            ],
          ),
          if (footer != null) ...<Widget>[
            const SizedBox(height: 14),
            footer,
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _gold,
                  foregroundColor: Colors.black,
                ),
                onPressed: onPressed,
                child: Text(actionLabel),
              ),
              if (secondaryActionLabel != null && onSecondaryPressed != null)
                OutlinedButton(
                  onPressed: onSecondaryPressed,
                  child: Text(secondaryActionLabel),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _showPostTripReviewSheet({
    required String rideId,
    required Map<String, dynamic> rideData,
  }) async {
    final riderId = _valueAsText(rideData['rider_id']);
    final canShowNonPaymentAction = _canShowNonPaymentAction(
      rideStatus: 'completed',
      rideData: rideData,
    );
    if (!mounted || riderId.isEmpty) {
      return;
    }

    final noteController = TextEditingController();
    var rating = 5.0;
    var submitting = false;

    final nextAction = await showModalBottomSheet<_PostTripReviewAction>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext sheetContext) {
        return StatefulBuilder(
          builder: (BuildContext sheetContext, StateSetter setSheetState) {
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  24,
                  16,
                  MediaQuery.of(sheetContext).viewInsets.bottom + 16,
                ),
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(28),
                    boxShadow: const <BoxShadow>[
                      BoxShadow(
                        color: Color(0x26000000),
                        blurRadius: 24,
                        offset: Offset(0, 14),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text(
                        'Trip completed',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Rate this rider to support future trust and service decisions.',
                        style: TextStyle(
                          color: Colors.black.withValues(alpha: 0.64),
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Center(
                        child: Wrap(
                          spacing: 6,
                          children: List<Widget>.generate(5, (int index) {
                            final starValue = (index + 1).toDouble();
                            return IconButton(
                              onPressed: submitting
                                  ? null
                                  : () {
                                      setSheetState(() {
                                        rating = starValue;
                                      });
                                    },
                              icon: Icon(
                                rating >= starValue
                                    ? Icons.star_rounded
                                    : Icons.star_outline_rounded,
                                size: 34,
                                color: _gold,
                              ),
                            );
                          }),
                        ),
                      ),
                      Center(
                        child: Text(
                          '${rating.toStringAsFixed(0)} out of 5',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: noteController,
                        enabled: !submitting,
                        minLines: 2,
                        maxLines: 4,
                        decoration: InputDecoration(
                          labelText: 'Driver note (optional)',
                          hintText: 'Add context about this rider or the trip.',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(18),
                            borderSide:
                                const BorderSide(color: Color(0xFFD4AF37)),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _gold,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(18),
                            ),
                          ),
                          onPressed: submitting
                              ? null
                              : () async {
                                  setSheetState(() {
                                    submitting = true;
                                  });
                                  try {
                                    await _riderAccountabilityService
                                        .submitRiderRating(
                                      rideId: rideId,
                                      riderId: riderId,
                                      driverId: _effectiveDriverId,
                                      serviceType: _serviceTypeKey(
                                        rideData['service_type'],
                                      ),
                                      rating: rating,
                                      note: noteController.text.trim(),
                                    );
                                    if (!sheetContext.mounted) {
                                      return;
                                    }
                                    Navigator.of(sheetContext).pop();
                                    _showSnackBarSafely(
                                      const SnackBar(
                                        content: Text('Rider rating saved.'),
                                      ),
                                    );
                                  } catch (error) {
                                    if (!sheetContext.mounted) {
                                      return;
                                    }
                                    setSheetState(() {
                                      submitting = false;
                                    });
                                    _showSnackBarSafely(
                                      const SnackBar(
                                        content: Text(
                                          'Unable to save rider rating right now.',
                                        ),
                                      ),
                                    );
                                  }
                                },
                          child: submitting
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                  ),
                                )
                              : const Text(
                                  'Submit rider rating',
                                  style: TextStyle(fontWeight: FontWeight.w800),
                                ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 12,
                        runSpacing: 4,
                        children: <Widget>[
                          if (canShowNonPaymentAction)
                            TextButton.icon(
                              onPressed: submitting
                                  ? null
                                  : () {
                                      Navigator.of(sheetContext).pop(
                                        _PostTripReviewAction.reportNonPayment,
                                      );
                                    },
                              icon: const Icon(Icons.payments_outlined),
                              label: const Text("My passenger didn't pay"),
                            ),
                          TextButton.icon(
                            onPressed: submitting
                                ? null
                                : () {
                                    Navigator.of(sheetContext).pop(
                                      _PostTripReviewAction.reportIssue,
                                    );
                                  },
                            icon: const Icon(Icons.flag_outlined),
                            label: const Text(
                              'Report an issue with this rider',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    noteController.dispose();
    if (!mounted || nextAction == null) {
      return;
    }

    switch (nextAction) {
      case _PostTripReviewAction.reportNonPayment:
        await _openReportRiderSheet(
          rideId: rideId,
          rideData: rideData,
          rideStatus: 'completed',
          initialReason: 'non-payment',
        );
        break;
      case _PostTripReviewAction.reportIssue:
        await _openReportRiderSheet(
          rideId: rideId,
          rideData: rideData,
          rideStatus: 'completed',
        );
        break;
    }
  }

  Future<void> _openReportRiderSheet({
    required String rideId,
    required Map<String, dynamic> rideData,
    String? rideStatus,
    String? initialReason,
  }) async {
    if (!mounted) {
      return;
    }

    final riderId = _valueAsText(rideData['rider_id']);
    if (riderId.isEmpty) {
      _showSnackBarSafely(
        const SnackBar(content: Text('Rider account details are missing.')),
      );
      return;
    }

    final formKey = GlobalKey<FormState>();
    final noteController = TextEditingController();
    final amountDueController = TextEditingController();
    final evidenceSummaryController = TextEditingController();
    final evidenceReferenceController = TextEditingController();
    var selectedReason = _kDriverRiderReportReasons.contains(initialReason)
        ? initialReason!
        : _kDriverRiderReportReasons.first;
    var selectedPaymentMethod = _kDriverSettlementMethods.contains(
      _paymentMethodFromRide(rideData),
    )
        ? _paymentMethodFromRide(rideData)
        : 'unspecified';
    final selectedEvidenceTypes = <String>{};
    var submitting = false;
    final serviceType = _serviceTypeKey(rideData['service_type']);

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext sheetContext) {
        return StatefulBuilder(
          builder: (BuildContext sheetContext, StateSetter setSheetState) {
            final isNonPayment = selectedReason == 'non-payment';
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  24,
                  16,
                  MediaQuery.of(sheetContext).viewInsets.bottom + 16,
                ),
                child: SingleChildScrollView(
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(28),
                      boxShadow: const <BoxShadow>[
                        BoxShadow(
                          color: Color(0x26000000),
                          blurRadius: 24,
                          offset: Offset(0, 14),
                        ),
                      ],
                    ),
                    child: Form(
                      key: formKey,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Text(
                            'Report rider',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w900,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            isNonPayment
                                ? 'Send this unpaid passenger case to NexRide review. The rider is not auto-blacklisted from this form.'
                                : 'Choose the reason that best matches the issue. Reports go into manual review.',
                            style: TextStyle(
                              color: Colors.black.withValues(alpha: 0.64),
                              height: 1.45,
                            ),
                          ),
                          const SizedBox(height: 18),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: const Color(0xFF111111),
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  _serviceTypeLabel(serviceType),
                                  style: TextStyle(
                                    color: _gold,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  _destinationAddressFromRideData(rideData),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Review queue only. Support can add evidence attachments later if needed.',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.72),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 18),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: _kDriverRiderReportReasons
                                .map(
                                  (String reason) => ChoiceChip(
                                    label: Text(
                                      reason[0].toUpperCase() +
                                          reason.substring(1),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    selected: selectedReason == reason,
                                    selectedColor:
                                        _gold.withValues(alpha: 0.18),
                                    side: BorderSide(
                                      color: selectedReason == reason
                                          ? _gold
                                          : Colors.black.withValues(
                                              alpha: 0.12,
                                            ),
                                    ),
                                    onSelected: submitting
                                        ? null
                                        : (_) {
                                            setSheetState(() {
                                              selectedReason = reason;
                                            });
                                          },
                                  ),
                                )
                                .toList(),
                          ),
                          if (isNonPayment) ...[
                            const SizedBox(height: 18),
                            TextFormField(
                              controller: amountDueController,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                              enabled: !submitting,
                              decoration: InputDecoration(
                                labelText: 'Amount due (NGN)',
                                hintText: 'Enter the unpaid amount for review',
                                prefixText: '₦ ',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(18),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(18),
                                  borderSide: BorderSide(color: _gold),
                                ),
                              ),
                              validator: (String? value) {
                                if (!isNonPayment) {
                                  return null;
                                }
                                final normalized =
                                    value?.replaceAll(',', '').trim() ?? '';
                                final amount = double.tryParse(normalized);
                                if (amount == null || amount <= 0) {
                                  return 'Enter the unpaid amount due.';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 14),
                            Text(
                              'Expected payment method',
                              style: TextStyle(
                                color: Colors.black.withValues(alpha: 0.68),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              children: _kDriverSettlementMethods
                                  .map(
                                    (String method) => ChoiceChip(
                                      label: Text(
                                        _paymentMethodLabel(method),
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      selected: selectedPaymentMethod == method,
                                      selectedColor:
                                          _gold.withValues(alpha: 0.18),
                                      side: BorderSide(
                                        color: selectedPaymentMethod == method
                                            ? _gold
                                            : Colors.black.withValues(
                                                alpha: 0.12,
                                              ),
                                      ),
                                      onSelected: submitting
                                          ? null
                                          : (_) {
                                              setSheetState(() {
                                                selectedPaymentMethod = method;
                                              });
                                            },
                                    ),
                                  )
                                  .toList(),
                            ),
                          ],
                          const SizedBox(height: 18),
                          Text(
                            'Evidence details',
                            style: TextStyle(
                              color: Colors.black.withValues(alpha: 0.68),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: _kDriverEvidenceTypes
                                .map(
                                  (String evidenceType) => FilterChip(
                                    label: Text(
                                      evidenceType[0].toUpperCase() +
                                          evidenceType.substring(1),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    selected: selectedEvidenceTypes
                                        .contains(evidenceType),
                                    selectedColor:
                                        _gold.withValues(alpha: 0.18),
                                    side: BorderSide(
                                      color: selectedEvidenceTypes
                                              .contains(evidenceType)
                                          ? _gold
                                          : Colors.black.withValues(
                                              alpha: 0.12,
                                            ),
                                    ),
                                    onSelected: submitting
                                        ? null
                                        : (bool selected) {
                                            setSheetState(() {
                                              if (selected) {
                                                selectedEvidenceTypes.add(
                                                  evidenceType,
                                                );
                                              } else {
                                                selectedEvidenceTypes.remove(
                                                  evidenceType,
                                                );
                                              }
                                            });
                                          },
                                  ),
                                )
                                .toList(),
                          ),
                          const SizedBox(height: 14),
                          TextField(
                            controller: evidenceSummaryController,
                            enabled: !submitting,
                            minLines: 2,
                            maxLines: 3,
                            decoration: InputDecoration(
                              labelText: 'Evidence summary (optional)',
                              hintText:
                                  'Describe what support should look for, such as a chat promise or dropoff disagreement.',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(18),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(18),
                                borderSide: BorderSide(color: _gold),
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          TextField(
                            controller: evidenceReferenceController,
                            enabled: !submitting,
                            decoration: InputDecoration(
                              labelText: 'Evidence reference (optional)',
                              hintText:
                                  'Add any future attachment note, receipt reference, or chat timestamp.',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(18),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(18),
                                borderSide: BorderSide(color: _gold),
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          TextField(
                            controller: noteController,
                            enabled: !submitting,
                            minLines: 3,
                            maxLines: 5,
                            decoration: InputDecoration(
                              labelText: 'Additional details (optional)',
                              hintText:
                                  'Add context that support or trust review should know.',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(18),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(18),
                                borderSide: BorderSide(color: _gold),
                              ),
                            ),
                          ),
                          const SizedBox(height: 18),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.black87,
                                foregroundColor: Colors.white,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(18),
                                ),
                              ),
                              onPressed: submitting
                                  ? null
                                  : () async {
                                      if (!formKey.currentState!.validate()) {
                                        return;
                                      }

                                      final amountDue = double.tryParse(
                                            amountDueController.text
                                                .replaceAll(',', '')
                                                .trim(),
                                          ) ??
                                          0;
                                      final message =
                                          noteController.text.trim();
                                      final evidenceSummary =
                                          evidenceSummaryController.text.trim();
                                      final evidenceReference =
                                          evidenceReferenceController.text
                                              .trim();
                                      final disputeMessageParts = <String>[
                                        if (message.isNotEmpty) message,
                                        if (isNonPayment && amountDue > 0)
                                          'Amount due: NGN ${amountDue.toStringAsFixed(amountDue.truncateToDouble() == amountDue ? 0 : 2)}',
                                        if (selectedEvidenceTypes.isNotEmpty)
                                          'Evidence: ${selectedEvidenceTypes.join(', ')}',
                                        if (evidenceSummary.isNotEmpty)
                                          evidenceSummary,
                                      ];

                                      setSheetState(() {
                                        submitting = true;
                                      });
                                      try {
                                        await _riderAccountabilityService
                                            .submitRiderReport(
                                          rideId: rideId,
                                          riderId: riderId,
                                          driverId: _effectiveDriverId,
                                          serviceType: serviceType,
                                          reason: selectedReason,
                                          message: message,
                                          rideStatus: rideStatus ?? _rideStatus,
                                          amountDueNgn:
                                              isNonPayment ? amountDue : null,
                                          paymentMethod: selectedPaymentMethod,
                                          evidenceSummary: evidenceSummary,
                                          evidenceReference: evidenceReference,
                                          evidenceTypes: selectedEvidenceTypes
                                              .toList(growable: false),
                                        );
                                        await _driverTripSafetyService
                                            .createTripDispute(
                                          rideId: rideId,
                                          riderId: riderId,
                                          driverId: _effectiveDriverId,
                                          serviceType: serviceType,
                                          reason: selectedReason,
                                          message: disputeMessageParts.isEmpty
                                              ? 'Driver submitted a rider report.'
                                              : disputeMessageParts.join(' • '),
                                          source: isNonPayment
                                              ? 'driver_non_payment_report'
                                              : 'driver_rider_report',
                                        );
                                        if (isNonPayment) {
                                          final businessModel =
                                              await _resolveDriverBusinessModelForSettlement(
                                            source: 'non_payment_report',
                                          );
                                          final settlement =
                                              _buildRideSettlementRecord(
                                            rideData: rideData,
                                            businessModel: businessModel,
                                            settlementStatus: 'payment_review',
                                            completionState:
                                                'completed_with_payment_issue',
                                            paymentMethod:
                                                selectedPaymentMethod,
                                            reviewStatus: 'pending',
                                            reportedOutstandingAmountNgn:
                                                amountDue.round(),
                                          );
                                          await _driverTripSafetyService
                                              .updateSettlementHook(
                                            rideId: rideId,
                                            riderId: riderId,
                                            driverId: _effectiveDriverId,
                                            serviceType: serviceType,
                                            source: 'driver_non_payment_report',
                                            settlementStatus: 'payment_review',
                                            completionState:
                                                'completed_with_payment_issue',
                                            paymentMethod:
                                                selectedPaymentMethod,
                                            reviewStatus: 'pending',
                                            reportedOutstandingAmountNgn:
                                                amountDue.round(),
                                            note: message,
                                            evidence: <String, dynamic>{
                                              'summary': evidenceSummary,
                                              'reference': evidenceReference,
                                              'types': selectedEvidenceTypes
                                                  .toList(growable: false),
                                              'attachmentStatus':
                                                  'details_recorded',
                                            },
                                            rideData: rideData,
                                            settlement: settlement,
                                          );
                                        }
                                        if (selectedReason ==
                                                'safety concern' ||
                                            selectedReason ==
                                                'off-route coercion') {
                                          await _driverTripSafetyService
                                              .createSafetyFlag(
                                            rideId: rideId,
                                            riderId: riderId,
                                            driverId: _effectiveDriverId,
                                            serviceType: serviceType,
                                            flagType: 'driver_rider_report',
                                            source: 'driver_rider_report',
                                            message:
                                                'Driver submitted a safety-related rider report for manual review.',
                                            status: 'manual_review',
                                            severity: 'high',
                                          );
                                        }
                                        if (!sheetContext.mounted) {
                                          return;
                                        }
                                        Navigator.of(sheetContext).pop();
                                        _showSnackBarSafely(
                                          SnackBar(
                                            content: Text(
                                              isNonPayment
                                                  ? 'Passenger payment review submitted.'
                                                  : 'Rider report submitted.',
                                            ),
                                          ),
                                        );
                                      } catch (error) {
                                        if (!sheetContext.mounted) {
                                          return;
                                        }
                                        setSheetState(() {
                                          submitting = false;
                                        });
                                        _showSnackBarSafely(
                                          const SnackBar(
                                            content: Text(
                                              'Unable to submit rider report right now.',
                                            ),
                                          ),
                                        );
                                      }
                                    },
                              icon: Icon(
                                isNonPayment
                                    ? Icons.payments_outlined
                                    : Icons.flag_outlined,
                              ),
                              label: submitting
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.2,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                          Colors.white,
                                        ),
                                      ),
                                    )
                                  : Text(
                                      isNonPayment
                                          ? 'Submit payment review'
                                          : 'Submit rider report',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    noteController.dispose();
    amountDueController.dispose();
    evidenceSummaryController.dispose();
    evidenceReferenceController.dispose();
  }

  Widget _buildSafetyPromptCard() {
    final message = _activeSafetyPromptMessage;
    if (message == null || message.isEmpty) {
      return const SizedBox.shrink();
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFFDF7E7).withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: const Color(0xFFFFE2A8)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x22000000),
                blurRadius: 18,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Row(
                children: [
                  Icon(Icons.shield_outlined, color: Colors.black87),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Safety check-in',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Colors.black87,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                message,
                style: const TextStyle(color: Colors.black87, height: 1.35),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _clearSafetyPrompt,
                  child: const Text("I'M OKAY"),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTripPanel() {
    final activeRide = _currentRideData;
    if (!_hasRenderableActiveRideData(activeRide) || activeRide == null) {
      return const SizedBox.shrink();
    }

    final pickup = _pickupLatLngFromRideData(activeRide);
    final destination = _destinationLatLngFromRideData(activeRide);
    if (pickup == null || destination == null) {
      return const SizedBox.shrink();
    }

    final showStartTrip = _rideStatus == 'arrived';
    final showCancelTrip = _canDriverCancelActiveRide(_rideStatus);
    final riderPhone = _riderPhone.isEmpty ? 'Phone unavailable' : _riderPhone;
    final serviceType = _serviceTypeKey(activeRide['service_type']);
    final isDispatchDelivery = _isDispatchDeliveryService(serviceType);
    final packageDetails = _dispatchPackageDetails(activeRide);
    final recipientSummary = _dispatchRecipientSummary(activeRide);
    final packagePhotoUrl = _dispatchPackagePhotoUrl(activeRide);
    final deliveryProofUrl = _dispatchDeliveryProofPhotoUrl(activeRide);
    final deliveryProofStatus = _dispatchDeliveryProofStatus(activeRide);

    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.78),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white.withValues(alpha: 0.65)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x26000000),
                blurRadius: 24,
                offset: Offset(0, 14),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _rideStatusLabel(),
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: Colors.black87,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${_serviceIdLabel(serviceType)}: ${_currentRideId ?? ''}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.black54,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: _gold.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            _serviceTypeLabel(serviceType),
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: Colors.black87,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: _gold.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      _rideStatus.replaceAll('_', ' ').toUpperCase(),
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        color: Colors.black87,
                        letterSpacing: 0.35,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _buildTripDetailRow(
                icon: Icons.person_outline,
                label: 'Rider',
                value: _riderName,
              ),
              const SizedBox(height: 8),
              _buildTripDetailRow(
                icon: Icons.call_outlined,
                label: 'Phone',
                value: riderPhone,
              ),
              const SizedBox(height: 10),
              Builder(
                builder: (BuildContext context) {
                  final paymentWarningLabel = _riderPaymentWarningLabel(
                    paymentStatus: _riderPaymentStatus,
                    cashAccessStatus: _riderCashAccessStatus,
                    outstandingCancellationFeesNgn:
                        _riderOutstandingCancellationFeesNgn,
                    nonPaymentReports: _riderNonPaymentReports,
                  );
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      if (_riderTrustLoading)
                        _buildMetaChip(
                          label: 'Syncing rider trust',
                          color: Colors.black54,
                          icon: Icons.sync_outlined,
                        ),
                      _buildMetaChip(
                        label: _riderVerifiedBadge
                            ? 'Verified rider'
                            : _riderVerificationLabel(
                                _riderVerificationStatus,
                              ),
                        color: _riderVerificationColor(
                          _riderVerificationStatus,
                        ),
                        icon: _riderVerifiedBadge
                            ? Icons.verified_rounded
                            : Icons.badge_outlined,
                      ),
                      _buildMetaChip(
                        label: _riderRatingCount > 0
                            ? '${_riderRating.toStringAsFixed(1)} ★ ($_riderRatingCount)'
                            : '${_riderRating.toStringAsFixed(1)} ★',
                        color: _gold,
                        icon: Icons.star_rounded,
                      ),
                      if (_riderRiskStatus != 'clear')
                        _buildMetaChip(
                          label: _riderRiskLabel(_riderRiskStatus),
                          color: _riderRiskColor(_riderRiskStatus),
                          icon: Icons.shield_outlined,
                        ),
                      if (paymentWarningLabel != null)
                        _buildMetaChip(
                          label: paymentWarningLabel,
                          color: _riderPaymentWarningColor(
                            paymentStatus: _riderPaymentStatus,
                            cashAccessStatus: _riderCashAccessStatus,
                            outstandingCancellationFeesNgn:
                                _riderOutstandingCancellationFeesNgn,
                            nonPaymentReports: _riderNonPaymentReports,
                          ),
                          icon: Icons.payments_outlined,
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 12),
              _buildTripDetailRow(
                icon: Icons.my_location,
                label: 'Pickup',
                value: _pickupAddressText,
                iconColor: Colors.green,
              ),
              const SizedBox(height: 12),
              _buildTripDetailRow(
                icon: Icons.location_on_outlined,
                label: _destinationLabel(serviceType),
                value: _destinationAddressText,
                iconColor: Colors.redAccent,
              ),
              if (packageDetails.isNotEmpty) ...[
                const SizedBox(height: 12),
                _buildTripDetailRow(
                  icon: Icons.inventory_2_outlined,
                  label: 'Package details',
                  value: packageDetails,
                ),
              ],
              if (recipientSummary.isNotEmpty) ...[
                const SizedBox(height: 12),
                _buildTripDetailRow(
                  icon: Icons.person_pin_circle_outlined,
                  label: 'Recipient details',
                  value: recipientSummary,
                ),
              ],
              if (packagePhotoUrl.isNotEmpty) ...[
                const SizedBox(height: 14),
                _buildDispatchMediaCard(
                  title: 'Package photo',
                  subtitle:
                      'The rider attached an item photo for this delivery.',
                  icon: Icons.photo_camera_back_outlined,
                  actionLabel: 'View package photo',
                  onPressed: () {
                    unawaited(
                      _showDispatchImagePreview(
                        title: 'Package photo',
                        imageUrl: packagePhotoUrl,
                      ),
                    );
                  },
                ),
              ],
              if (isDispatchDelivery && _tripStarted) ...[
                const SizedBox(height: 14),
                _buildDispatchMediaCard(
                  title: deliveryProofUrl.isEmpty
                      ? 'Delivery proof required'
                      : 'Delivery proof uploaded',
                  subtitle: deliveryProofUrl.isEmpty
                      ? 'Upload a completion photo before you finish this dispatch.'
                      : 'Your completion photo is attached to this dispatch and ready for review.',
                  icon: Icons.assignment_turned_in_outlined,
                  actionLabel: 'Upload delivery proof',
                  onPressed: () {
                    unawaited(_uploadDispatchDeliveryProof());
                  },
                  secondaryActionLabel:
                      deliveryProofUrl.isEmpty ? null : 'View delivery proof',
                  onSecondaryPressed: deliveryProofUrl.isEmpty
                      ? null
                      : () {
                          unawaited(
                            _showDispatchImagePreview(
                              title: 'Delivery proof',
                              imageUrl: deliveryProofUrl,
                            ),
                          );
                        },
                  footer: _deliveryProofUploading
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            ClipRRect(
                              borderRadius: BorderRadius.circular(999),
                              child: LinearProgressIndicator(
                                minHeight: 7,
                                value: _deliveryProofUploadProgress <= 0
                                    ? null
                                    : _deliveryProofUploadProgress,
                                backgroundColor:
                                    Colors.black.withValues(alpha: 0.08),
                                valueColor:
                                    AlwaysStoppedAnimation<Color>(_gold),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Uploading delivery proof...',
                              style: TextStyle(
                                color: Colors.black.withValues(alpha: 0.62),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        )
                      : Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: <Widget>[
                            _buildMetaChip(
                              label: deliveryProofUrl.isEmpty
                                  ? 'Proof pending'
                                  : 'Proof ${deliveryProofStatus.isEmpty ? 'submitted' : deliveryProofStatus}',
                              color: deliveryProofUrl.isEmpty
                                  ? Colors.black54
                                  : _gold,
                              icon: deliveryProofUrl.isEmpty
                                  ? Icons.hourglass_bottom_rounded
                                  : Icons.verified_outlined,
                            ),
                          ],
                        ),
                ),
              ],
              if (_tripWaypoints.length > 1) ...[
                const SizedBox(height: 10),
                Text(
                  '${_tripWaypoints.length - 1} stop${_tripWaypoints.length - 1 == 1 ? '' : 's'} before final destination',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.black54,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              if (_routeOverlayError != null) ...[
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: Colors.black.withValues(alpha: 0.06),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.route_outlined, size: 18, color: _gold),
                          const SizedBox(width: 8),
                          const Text(
                            'Route preview unavailable',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: Colors.black87,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _routeOverlayError!,
                        style: TextStyle(
                          color: Colors.black.withValues(alpha: 0.68),
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextButton(
                        onPressed: () {
                          _scheduleActiveRouteRefresh(
                            force: true,
                            reason: 'driver_route_retry',
                            debounce: Duration.zero,
                          );
                        },
                        style: TextButton.styleFrom(
                          foregroundColor: _gold,
                          padding: EdgeInsets.zero,
                        ),
                        child: const Text(
                          'Retry route',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              if (_isArrivedEligibleRideStatus(_rideStatus) &&
                  _arrivedEnabled) ...[
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.black87,
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    onPressed: markArrived,
                    child: const Text(
                      'ARRIVED',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              if (showStartTrip) ...[
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    onPressed: startTrip,
                    child: Text(
                      _serviceStartActionLabel(serviceType),
                      style: const TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              if (_tripStarted) ...[
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    onPressed: isDispatchDelivery &&
                            _tripStarted &&
                            (_deliveryProofUploading ||
                                deliveryProofUrl.isEmpty)
                        ? null
                        : completeTrip,
                    child: Text(
                      _serviceCompleteActionLabel(serviceType),
                      style: const TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              if (showCancelTrip) ...[
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      side: const BorderSide(color: Colors.redAccent),
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    onPressed: _isDriverCancellingRide
                        ? null
                        : () {
                            unawaited(cancelActiveRide());
                          },
                    child: _isDriverCancellingRide
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text(
                            'Cancel Trip',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: _openNavigation,
                  child: const Text(
                    'Navigate',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              if (_canOpenChat) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 11),
                          side: BorderSide(
                            color: Colors.black.withValues(alpha: 0.12),
                          ),
                          backgroundColor: Colors.white.withValues(alpha: 0.55),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        onPressed: _openDriverChat,
                        child: SizedBox(
                          width: double.infinity,
                          child: Stack(
                            clipBehavior: Clip.none,
                            alignment: Alignment.center,
                            children: [
                              const Row(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.chat_bubble_outline),
                                  SizedBox(width: 8),
                                  Text(
                                    'Open Chat',
                                    style:
                                        TextStyle(fontWeight: FontWeight.w700),
                                  ),
                                ],
                              ),
                              if (_driverUnreadChatCount > 0)
                                Positioned(
                                  right: 12,
                                  top: -4,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.red,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      '$_driverUnreadChatCount',
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
                    if (_showRideCallButton) ...[
                      const SizedBox(width: 10),
                      Expanded(
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 11,
                                  ),
                                  side: BorderSide(
                                    color: _gold.withValues(alpha: 0.28),
                                  ),
                                  backgroundColor:
                                      _gold.withValues(alpha: 0.08),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                                onPressed: _isRideCallButtonEnabled
                                    ? () {
                                        unawaited(_startVoiceCallFromChat());
                                      }
                                    : null,
                                icon: _isStartingVoiceCall
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : Icon(Icons.call_outlined, color: _gold),
                                label: const Text(
                                  'Call Rider',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: Colors.black87,
                                  ),
                                ),
                              ),
                            ),
                            if (_driverMissedCallNotice)
                              Positioned(
                                right: 6,
                                top: -2,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.red,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: const Text(
                                    '!',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800,
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
              ],
              if (_currentRideId != null &&
                  _currentRiderIdForRide.isNotEmpty &&
                  _canShowNonPaymentAction(
                    rideStatus: _rideStatus,
                    rideData: activeRide,
                  )) ...[
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      side: BorderSide(
                        color: _gold.withValues(alpha: 0.28),
                      ),
                      backgroundColor: _gold.withValues(alpha: 0.08),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    onPressed: () {
                      unawaited(
                        _openReportRiderSheet(
                          rideId: _currentRideId!,
                          rideData: activeRide,
                          rideStatus: _rideStatus,
                          initialReason: 'non-payment',
                        ),
                      );
                    },
                    icon: Icon(Icons.payments_outlined, color: _gold),
                    label: const Text(
                      "My passenger didn't pay",
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Colors.black87,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      side: BorderSide(
                        color: Colors.red.withValues(alpha: 0.22),
                      ),
                      backgroundColor: Colors.red.withValues(alpha: 0.04),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    onPressed: () {
                      unawaited(
                        _openReportRiderSheet(
                          rideId: _currentRideId!,
                          rideData: activeRide,
                          rideStatus: _rideStatus,
                        ),
                      );
                    },
                    icon: const Icon(Icons.flag_outlined, color: Colors.red),
                    label: const Text(
                      'Report rider',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Colors.red,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAvailabilityStatusCard() {
    final badgeBackground = _isOnline
        ? const Color(0xFFDBF7E6)
        : _lastAvailabilityIntentOnline
            ? _gold.withValues(alpha: 0.16)
            : const Color(0xFFF1F3F5);
    final badgeForeground =
        _isOnline ? const Color(0xFF137A3E) : const Color(0xFF1F2937);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: (_isOnline ? const Color(0xFFB8E6CB) : _gold)
              .withValues(alpha: 0.45),
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: badgeBackground,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              _availabilityStatusLabel,
              style: TextStyle(
                color: badgeForeground,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _availabilityStatusMessage,
              style: const TextStyle(
                color: Colors.black87,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvailabilityToggleButton() {
    final isOfflineAction = !_isOnline;
    final backgroundColor = isOfflineAction ? _gold : const Color(0xFF18120B);
    final foregroundColor = isOfflineAction ? Colors.black : _gold;
    final buttonLabel = _availabilityActionInProgress
        ? (_isOnline ? 'GOING OFFLINE...' : 'GOING ONLINE...')
        : (_isOnline ? 'GO OFFLINE' : 'GO ONLINE');

    return ElevatedButton.icon(
      style: ElevatedButton.styleFrom(
        backgroundColor: backgroundColor,
        foregroundColor: foregroundColor,
        disabledBackgroundColor: backgroundColor.withValues(
          alpha: isOfflineAction ? 0.8 : 0.92,
        ),
        disabledForegroundColor: foregroundColor.withValues(alpha: 0.82),
        elevation: isOfflineAction ? 8 : 2,
        shadowColor: _gold.withValues(alpha: isOfflineAction ? 0.4 : 0.18),
        padding: const EdgeInsets.symmetric(vertical: 18),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: isOfflineAction
                ? const Color(0xFF9E7420)
                : _gold.withValues(alpha: 0.72),
          ),
        ),
      ),
      onPressed: _availabilityActionInProgress ? null : toggleOnline,
      icon: Icon(
        _availabilityActionInProgress
            ? Icons.sync_rounded
            : isOfflineAction
                ? Icons.power_settings_new_rounded
                : Icons.pause_circle,
      ),
      label: Text(
        buttonLabel,
        style: const TextStyle(
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasAuthenticatedDriver) {
      return const DriverLoginScreen();
    }

    const safetyPromptTop = 92.0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('NexRide Driver'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Driver Hub',
            onPressed: () {
              unawaited(_openDriverToolsSheet());
            },
            icon: const Icon(Icons.dashboard_customize_outlined),
          ),
        ],
      ),
      body: Stack(
        children: [
          ValueListenableBuilder<int>(
            valueListenable: _mapLayerVersion,
            builder: (context, _, child) {
              return GoogleMap(
                key: ValueKey<String>('driver-map-$_mapWidgetKeyVersion'),
                initialCameraPosition: CameraPosition(
                  target: _driverLocation,
                  zoom: DriverServiceAreaConfig.defaultMapZoom,
                ),
                mapType: MapType.normal,
                markers: _markers,
                polylines: _polyLines,
                myLocationEnabled: _mapLocationReady,
                myLocationButtonEnabled: _mapLocationReady,
                onMapCreated: (controller) {
                  _mapController = controller;
                  final attempt = _mapInitializationAttempt;
                  _mapCameraIdleObserved = false;
                  _setDebugStartupStep('map view created');
                  _log(
                    'map view created attempt=$attempt platform=${defaultTargetPlatform.name}',
                  );
                  _log(
                    'driver map created attempt=$attempt platform=${defaultTargetPlatform.name}',
                  );
                  _log(
                    'initial camera target=${_driverLocation.latitude},${_driverLocation.longitude} zoom=${DriverServiceAreaConfig.defaultMapZoom}',
                  );
                  _refreshDriverMapPresentation(reason: 'map_created');
                  _scheduleActiveRouteRefresh(
                    force: true,
                    reason: 'map_created',
                    debounce: Duration.zero,
                  );
                  if (mounted) {
                    setState(() {
                      _mapViewReady = true;
                    });
                  } else {
                    _mapViewReady = true;
                  }
                  _completeMapInitializationIfReady(attempt: attempt);
                  _scheduleMapTileRecovery(
                    controller: controller,
                    attempt: attempt,
                  );
                  if (defaultTargetPlatform == TargetPlatform.iOS) {
                    _scheduleIosMapStabilization(
                      controller: controller,
                      attempt: attempt,
                    );
                    return;
                  }
                },
                onCameraIdle: () {
                  _mapCameraIdleObserved = true;
                  if (defaultTargetPlatform != TargetPlatform.iOS ||
                      _mapViewReady ||
                      !_mapInitializationInProgress) {
                    return;
                  }

                  _log(
                    'iOS map camera settled attempt=$_mapInitializationAttempt',
                  );
                  if (mounted) {
                    setState(() {
                      _mapViewReady = true;
                    });
                  } else {
                    _mapViewReady = true;
                  }
                  _completeMapInitializationIfReady(
                    attempt: _mapInitializationAttempt,
                  );
                },
              );
            },
          ),
          if (!_hasRenderableActiveRide)
            Positioned(
              bottom: 94,
              left: 20,
              right: 20,
              child: _buildAvailabilityStatusCard(),
            ),
          Positioned(
            bottom: 20,
            left: 20,
            right: 20,
            child: _buildAvailabilityToggleButton(),
          ),
          if (_activeSafetyPromptMessage != null)
            Positioned(
              top: safetyPromptTop,
              left: 20,
              right: 20,
              child: _buildSafetyPromptCard(),
            ),
          if (_mapInitializationInProgress || _mapInitializationError != null)
            _buildMapInitializationOverlay(),
          if (_hasRenderableActiveRide)
            Positioned(
              bottom: 100,
              left: 20,
              right: 20,
              child: _buildTripPanel(),
            ),
        ],
      ),
    );
  }
}
