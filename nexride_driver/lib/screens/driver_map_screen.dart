import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:cloud_functions/cloud_functions.dart';
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
import '../config/rollout_copy.dart';
import '../config/rtdb_ride_request_contract.dart';
import '../models/rollout_delivery_region_model.dart';
import '../widgets/driver_rollout_operating_area_sheet.dart';
import '../services/rollout_catalog_hydration.dart';
import '../services/driver_rollout_profile_store.dart';
import '../services/call_permissions.dart';
import '../services/call_service.dart';
import '../support/shared_call_listener_support.dart';
import '../support/call_trace_support.dart';
import '../support/phone_requirement.dart';
import '../services/dispatch_photo_upload_service.dart';
import '../services/driver_alert_sound_service.dart';
import '../services/local_backend_simulation_service.dart';
import '../services/ride_cloud_functions_service.dart';
import '../services/driver_offer_prime_coordinator.dart';
import '../services/driver_pending_offer_launch_store.dart';
import '../services/ride_driver_payment_gate.dart';
import '../services/delivery_cloud_functions_service.dart';
import '../services/driver_delivery_chat_service.dart';
import '../support/delivery_call_support.dart';
import '../support/delivery_call_ui_controller.dart';
import '../support/delivery_cancel_reasons.dart';
import '../support/delivery_offer_popup_support.dart';
import '../trip_sync/delivery_state_machine.dart';
import '../widgets/driver_active_delivery_panel.dart';
import '../widgets/driver_delivery_chat_sheet.dart';
import '../services/road_route_service.dart';
import '../services/driver_trip_safety_service.dart';
import '../services/rider_accountability_service.dart';
import '../services/user_support_ticket_service.dart';
import '../shared/notifications/portal_in_app_notification_service.dart';
import '../shared/notifications/portal_notification_bell_button.dart';
import '../support/app_role.dart';
import '../support/driver_location_access_support.dart';
import '../support/driver_dispatch_support.dart';
import '../support/driver_profile_bootstrap_support.dart';
import '../support/driver_profile_support.dart';
import '../support/driver_vehicle_profile.dart';
import '../support/dispatch_payment_support.dart';
import '../support/dispatch_production_log.dart';
import '../support/chat_image_debug.dart';
import '../support/delivery_chat_support.dart';
import '../support/realtime_database_error_support.dart';
import '../support/realtime_database_write_queue.dart';
import '../support/rtdb_flow_debug_log.dart';
import '../support/rtdb_read_support.dart';
import '../support/help_support_navigation.dart';
import '../support/ride_chat_support.dart';
import '../support/driver_rtdb_listener_hub.dart';
import '../support/driver_active_delivery_restore_support.dart';
import '../support/driver_active_ride_restore_support.dart';
import '../support/nex_trace.dart';
import '../support/ride_pipeline_guard.dart';
import '../support/rtdb_resource_guard.dart';
import '../trip_sync/trip_state_machine.dart';
import '../support/driver_offer_lease.dart';
import '../support/profile_identity_resolver.dart';
import '../widgets/driver_dashboard_panel.dart';
import '../widgets/profile_identity_header.dart';
import '../widgets/driver_ride_chat_sheet.dart';
import 'driver_business_model_screen.dart';
import 'driver_redeem_fleet_invite_screen.dart';
import 'driver_support_center_screen.dart';
import 'driver_verification_screen.dart';
import 'driver_login_screen.dart';
import 'earnings_screen.dart';
import 'trip_history_screen.dart';
import 'driver_profile_edit_screen.dart';
import '../widgets/profile_avatar.dart';
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
const Duration _kActiveRouteDebounceDuration = Duration(seconds: 25);
const Duration _kActiveTripUiDebounceDuration = Duration(seconds: 2);
const Duration _kIdleMapSetStateThrottle = Duration(seconds: 8);
const Duration _kArrivedEligibilityCheckInterval = Duration(seconds: 3);
const Duration _kPopupRouteDebounceDuration = Duration(milliseconds: 150);
const int _kRidePopupCountdownSeconds = 20;
const Duration _kRideAcceptPropagationGrace = Duration(seconds: 25);
// Temporary debug switch: keep market matching strict, but bypass distance
// radius suppression so all active rides in the same market are visible.
const bool _kDebugAllowAllActiveMarketRides = true;
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
const Set<String> _kRenderableRideStatuses = <String>{
  // Reserved-offer popup (driver matched — waiting for ACCEPT tap).
  'pending_driver_action',
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
  fleetInvite,
  operatingArea,
  settings,
  debugOverlay,
  editProfile,
  verification,
  wallet,
  whatsappSupport,
  support,
  signOut,
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

/// Driver offer popup lifecycle (Grab-style: stable until explicit outcome).
enum _DriverPopupLifecycleState {
  idle,
  offered,
  visible,
  accepting,
  assigned,
  expired,
  cancelled,
}

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
  /// Slice 3: dedicated delivery request node (parallel to ride_requests).
  final rtdb.DatabaseReference _deliveryRequestsRef =
      rtdb.FirebaseDatabase.instance.ref('delivery_requests');
  final rtdb.DatabaseReference _driversRef =
      rtdb.FirebaseDatabase.instance.ref('drivers');
  final CallService _callService = CallService(callTraceRole: 'driver');
  late final SharedCallStateListener _sharedCallListener =
      SharedCallStateListener(_callService);
  late final DeliveryCallUiController _deliveryCallUi;
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
  final FirebaseFunctions _functions =
      FirebaseFunctions.instanceFor(region: 'us-central1');
  late final RideCloudFunctionsService _rideCloud =
      RideCloudFunctionsService(functions: _functions);
  late final DeliveryCloudFunctionsService _deliveryCloud =
      DeliveryCloudFunctionsService(functions: _functions);
  final RoadRouteService _roadRouteService = RoadRouteService();
  final Set<String> _presentedRideIds = <String>{};
  final Set<String> _timedOutRideIds = <String>{};
  final Set<String> _declinedRideIds = <String>{};
  final Set<String> _handledRideIds = <String>{};

  /// Ride IDs that must never re-open the market discovery popup (accept/decline).
  final Set<String> _suppressedRidePopupIds = <String>{};

  /// Accepted (or otherwise completed-on-this-device) ride IDs — never unsuppress, never popup again this session.
  final Set<String> _foreverSuppressedRidePopupIds = <String>{};
  final Set<String> _ratingHandledRideIds = <String>{};

  /// Terminal self-accept lock: after a successful accept transaction, discovery and
  /// unavailable UI must not fight the active-trip flow for this [rideId] until trip end.
  final Set<String> _terminalSelfAcceptedRideIds = <String>{};

  /// Dedupes redundant [driver_offer_queue] value events while an offer fingerprint is unchanged.
  final Map<String, String> _lastDiscoveryDismissFingerprintByRideId =
      <String, String>{};
  final Map<String, int> _discoveryPopupCooldownUntilMs = <String, int>{};

  /// Prevents concurrent [showRideRequestPopup] opens from parallel RTDB snapshots.
  bool _ridePopupOpenPipelineLocked = false;
  int _lastActiveHeartbeatLogCount = 0;
  bool _isDriverCancellingRide = false;
  /// Prevents repeated [driverEnroute] HTTPS calls for the same active ride.
  String? _driverEnrouteCloudSentRideId;
  final Set<String> _loggedDriverChatMessageIds = <String>{};
  final Set<Marker> _markers = <Marker>{};
  final Set<Polyline> _polyLines = <Polyline>{};
  final List<_TripWaypoint> _tripWaypoints = <_TripWaypoint>[];
  int _manualTripStopIndex = 0;
  String _tripWaypointsSignature = '';
  final List<LatLng> _expectedRoutePoints = <LatLng>[];
  final ValueNotifier<List<RideChatMessage>> _driverChatMessages =
      ValueNotifier<List<RideChatMessage>>(<RideChatMessage>[]);
  final ValueNotifier<int> _mapLayerVersion = ValueNotifier<int>(0);

  GoogleMapController? _mapController;
  StreamSubscription<Position>? _positionStream;
  StreamSubscription<rtdb.DatabaseEvent>? _rideRequestSubscription;
  StreamSubscription<rtdb.DatabaseEvent>? _driverOfferQueueChildChangedSubscription;
  StreamSubscription<rtdb.DatabaseEvent>? _driverOfferQueueChildRemovedSubscription;

  /// Parallel dispatch-delivery offer reception (Slice 1, Option A). Listens to
  /// the dedicated `delivery_offer_queue/{uid}` and feeds the SAME popup
  /// pipeline as ride offers so delivery offers surface independently.
  StreamSubscription<rtdb.DatabaseEvent>? _deliveryOfferQueueChildAddedSubscription;
  StreamSubscription<rtdb.DatabaseEvent>? _deliveryOfferQueueChildRemovedSubscription;

  /// True only when the primary [onChildAdded] offer-queue listener is bound.
  /// Partial subscriptions (changed/removed only) must not count as attached —
  /// otherwise a dead childAdded stream skips rebind and offers never arrive.
  bool get _isDriverOfferQueueListenerAttached =>
      _rideRequestSubscription != null &&
      _driverOfferQueueBoundUid != null &&
      _driverOfferQueueBoundUid!.trim().isNotEmpty;

  bool _shouldForceRebindOfferListener(String reason) {
    final normalized = reason.trim().toLowerCase();
    if (normalized.isEmpty) {
      return false;
    }
    return normalized == 'goonline' ||
        normalized == 'goonline_retry' ||
        normalized.contains('resume_after_terminal') ||
        normalized.contains('terminal_cancel') ||
        normalized.contains('terminal_rebind') ||
        normalized.contains('force_rebind') ||
        normalized.contains('watchdog') ||
        normalized.contains('discovery_rearm') ||
        normalized.contains('dispatch_blocker_repair') ||
        normalized.contains('offer_expired') ||
        normalized.contains('driver_declined') ||
        normalized.contains('child_removed') ||
        normalized.contains('popup_closed') ||
        normalized.contains('unhealthy_listener');
  }

  bool _isTerminalRebindReason(String reason) {
    final normalized = reason.trim().toLowerCase();
    return normalized.contains('terminal') ||
        normalized.contains('cancel') ||
        normalized.contains('complete') ||
        normalized.contains('decline') ||
        normalized.contains('declined') ||
        normalized.contains('expired') ||
        normalized.contains('timeout') ||
        normalized.contains('child_removed') ||
        normalized.contains('offer_expired');
  }

  bool _offerListenerAppearsUnhealthy() {
    if (!_isDriverOfferQueueListenerAttached) {
      return false;
    }
    return _socketStatus == 'disconnected' || _socketStatus == 'stream_error';
  }

  /// Incremental mirror of RTDB `driver_offer_queue/{uid}/*` for ChildAdded/Removed processing.
  final Map<String, dynamic> _driverOfferQueueReplica = <String, dynamic>{};

  /// City key for the active discovery listener (debug / legacy logging).
  String? _rideRequestsListenerBoundCity;
  /// Auth uid bound to `driver_offer_queue/{uid}` (null if no listener).
  String? _driverOfferQueueBoundUid;

  /// Bound while offer-queue child listeners are active (resume / FCM prime).
  Future<void> Function(
    Map<String, dynamic> rideMap, {
    required String source,
  })? _boundOfferQueueProcessor;

  int _boundOfferQueueListenerToken = 0;
  /// Auth uid bound to `delivery_offer_queue/{uid}` (null if no delivery listener).
  String? _deliveryOfferQueueBoundUid;
  /// Synthetic ride snapshots built from [driver_offer_queue] entries (preflight accept).
  final Map<String, Map<String, dynamic>> _driverOfferRideCache =
      <String, Map<String, dynamic>>{};
  final Set<String> _loggedDriverOfferReceivedRideIds = <String>{};
  /// One-shot RTDB read of `driver_offer_queue/{uid}` after go-online (debug).
  int _rideRequestListenerToken = 0;
  Timer? _offerListenerWatchdogTimer;
  String _lastOfferEventSummary = 'none';
  int _offerQueueDebugCount = 0;
  static const Duration _kOfferListenerWatchdogInterval =
      Duration(seconds: 12);

  /// Serializes discovery attach/cancel so two callers cannot overlap native query setup.
  Future<void> _rideDiscoveryAttachChain = Future<void>.value();
  StreamSubscription<rtdb.DatabaseEvent>? _driverActiveRideSubscription;
  StreamSubscription<rtdb.DatabaseEvent>? _activeRideSubscription;
  final DriverRtdbListenerHub _rtdbListenerHub = DriverRtdbListenerHub();

  /// Slice 3: active dispatch-delivery tracking. Fully independent of the ride
  /// active-trip listener/state above — driven by [DeliveryStateMachine] over
  /// `delivery_requests/{deliveryId}` and `driver_active_delivery/{driverId}`.
  StreamSubscription<rtdb.DatabaseEvent>? _activeDeliverySubscription;
  StreamSubscription<rtdb.DatabaseEvent>? _driverActiveDeliverySubscription;
  String? _activeDeliveryId;
  Map<String, dynamic>? _activeDeliveryData;
  DeliveryLifecycleState _activeDeliveryState =
      DeliveryLifecycleState.searching;
  bool _deliveryActionInFlight = false;
  String? _deliveryCallVisibilityLogKey;
  final List<StreamSubscription<rtdb.DatabaseEvent>> _driverChatSubscriptions =
      <StreamSubscription<rtdb.DatabaseEvent>>[];
  final Map<String, RideChatMessage> _driverChatMessagesById =
      <String, RideChatMessage>{};
  final Map<String, String> _driverChatDraftByRide = <String, String>{};
  StreamSubscription<rtdb.DatabaseEvent>? _callSubscription;
  StreamSubscription<rtdb.DatabaseEvent>? _rideCallMirrorSubscription;
  StreamSubscription<rtdb.DatabaseEvent>? _incomingCallSubscription;
  Timer? _ridePopupTimer;
  Timer? _routeRequestDebounceTimer;
  Timer? _activeTripUiDebounceTimer;
  String? _activeTripUiPendingRideId;
  String? _activeTripUiPendingStatus;
  Map<String, dynamic>? _activeTripUiPendingRideData;
  DateTime? _lastIdleMapSetStateAt;
  LatLng? _lastMapSetStateDriverPosition;
  String? _lastTripMarkersSignature;
  DateTime? _lastArrivedEligibilityCheckAt;
  bool _driverChatUnreadOnlyMode = false;
  DateTime? _lastResourceCountLogAt;
  static final BitmapDescriptor _markerIconPickup =
      BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen);
  static final BitmapDescriptor _markerIconDestination =
      BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed);
  static final BitmapDescriptor _markerIconStop =
      BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);
  Timer? _callDurationTimer;
  Timer? _callRingTimeoutTimer;
  Timer? _callForegroundDebounceTimer;
  bool? _pendingCallForeground;
  Timer? _mapInitializationTimer;
  OverlayEntry? _callOverlayEntry;
  RideCallSession? _currentCallSession;
  String? _callListenerRideId;
  CallSessionKind _callListenerKind = CallSessionKind.ride;
  DateTime? _callAcceptedAt;
  DateTime? _activeCallStartedAt;
  Duration _callDuration = Duration.zero;
  bool _isEndingCall = false;
  AppLifecycleState _appLifecycleState = AppLifecycleState.resumed;
  bool _callMuted = false;
  bool _callSpeakerOn = true;
  bool _callJoinedChannel = false;
  bool _isStartingVoiceCall = false;
  int _callJoinAttemptCount = 0;
  final Set<String> _callCleanupDoneRideIds = <String>{};
  final Set<String> _callLocallyEndedRideIds = <String>{};
  final Map<String, int> _callNullGraceUntilByRideId = <String, int>{};
  String? _callJoinInFlightRideId;
  String? _callUiActiveRideId;
  bool _callLocalCleanupInProgress = false;
  DateTime? _lastCallCleanupAt;

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
  List<RolloutDeliveryRegionModel> _rolloutCatalog =
      const <RolloutDeliveryRegionModel>[];
  bool _rolloutCatalogLoading = false;
  bool _rolloutCatalogHydrated = false;
  Object? _rolloutCatalogError;
  String? _rolloutRegionId;
  String? _rolloutCityId;
  String? _rolloutDispatchMarketId;
  bool _rolloutSavedAreaDisabled = false;
  bool _rolloutBannerDismissed = false;
  int _rolloutCatalogLoadSeq = 0;
  String? _currentRideId;
  String? _sessionTrackedRideId;
  Map<String, dynamic>? _currentRideData;
  String? _loadedRiderProfileKey;
  String? _enrichedRiderProfileKey;
  String? _lastTripPanelHiddenReason;
  String? _lastValidationBlockedKey;
  String? _pendingStaleRidePurgeKey;
  String? _completedStaleRidePurgeKey;
  String? _lastNoValidActiveRideClearKey;
  bool _loggedWaitingForFreshRides = false;
  final Set<String> _postAcceptMirrorsScheduledRideIds = <String>{};
  final Set<String> _loggedRideStateChangeKeys = <String>{};
  final Set<String> _optionalRtdbEventKeys = <String>{};
  final Set<String> _startupRejectedRestoreRideIds = <String>{};
  bool _explicitDriverSessionCleared = false;
  Timer? _waitFeeGraceTimer;
  String? _waitFeeGraceRideId;
  bool _waitFeeApplyInFlight = false;
  Timer? _waitTimerTicker;
  int _waitTimerSecondsRemaining = 0;
  bool _paymentConfirmInFlight = false;
  String? _driverActiveRideId;
  String? _activeRideListenerRideId;
  String? _driverChatListenerRideId;
  int _driverChatListenerGeneration = 0;
  int? _driverChatHydrateCompletedGeneration;
  String? _currentCandidateRideId;

  /// Stable offer-queue popup reservation until showRideRequestPopup completes.
  String? _pendingOfferPopupRideId;
  String _pickupAddressText = '';
  String _destinationAddressText = '';
  String _riderName = 'Rider';
  String _riderPhone = '';
  String _riderPhotoUrl = '';
  String _riderVerificationStatus = 'unverified';
  String _riderRiskStatus = 'clear';
  String _riderPaymentStatus = 'clear';
  String _riderCashAccessStatus = 'enabled';
  int _onlineSessionStartedAt = 0;
  int _driverUnreadChatCount = 0;
  final ValueNotifier<int> _driverChatUnreadNotifier = ValueNotifier<int>(0);
  String _lastDriverChatListSignature = '';
  String _lastDriverChatRawSnapshotSignature = '';

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

  /// Server `driver_availability_mode` while online (or last go-online mode).
  String _activeOnlineAvailabilityMode = '';

  /// Next GO ONLINE uses GPS vs selected rollout city (`current_location` | `service_area`).
  String _pendingAvailabilityMode = 'current_location';

  /// Last successfully loaded driver profile from RTDB (used for fast GO ONLINE).
  Map<String, dynamic>? _lastDriverProfileSnapshot;
  UserSupportInboxSummary? _cachedHubSupportSummary;
  ResolvedDriverProfileIdentity? _cachedHubIdentity;
  String? _queuedNextRideIdFromProfile;
  bool _isDriverChatOpen = false;
  bool _hasHydratedDriverChatMessages = false;
  bool _hasActivePopup = false;
  bool _tripStarted = false;
  bool _popupOpen = false;
  _DriverPopupLifecycleState _popupLifecycleState =
      _DriverPopupLifecycleState.idle;

  /// Ride IDs matched by backend fan-out (`driver_offer_queue`); never re-filter locally.
  final Set<String> _backendTrustedOfferRideIds = <String>{};

  /// FIFO of incoming open-pool offers when a popup is already visible (Grab-style backlog).
  final List<_MatchedRideRequest> _rideRequestPopupQueue =
      <_MatchedRideRequest>[];
  static const int _kMaxRideRequestPopupQueue = 8;
  bool _routeBuildInFlight = false;
  bool _routeRefreshInFlight = false;
  bool _arrivedEnabled = false;
  bool _showArrivedButton = false;
  String _arrivedDisabledReason = '';
  bool _hasLoggedArrivedEnabled = false;
  String? _lastArrivedButtonStateLog;
  bool _safetyMonitoringActive = false;
  bool _riderTrustLoading = false;
  bool _riderVerifiedBadge = false;
  bool _profileSyncRetryInProgress = false;
  bool _profileSyncMaterialBannerShown = false;
  bool _mapBootstrapReady = false;
  bool _mapLocationReady = false;
  bool _deviceLocationOutsideLaunchArea = false;
  DriverLocationCapability? _locationCapability;
  Timer? _popupLifecycleStaleResetTimer;
  static const Duration _kPopupLifecycleStaleResetDuration =
      Duration(seconds: 90);
  bool _launchCityChosenManually = false;
  bool _mapViewReady = false;
  bool _mapInitializationInProgress = true;
  bool _deliveryProofUploading = false;
  bool _pickupProofUploading = false;
  final DriverDeliveryChatService _driverDeliveryChatService =
      DriverDeliveryChatService();
  StreamSubscription<rtdb.DatabaseEvent>? _activeDeliveryChatSubscription;
  final ValueNotifier<List<DeliveryChatMessage>> _activeDeliveryChatMessages =
      ValueNotifier<List<DeliveryChatMessage>>(<DeliveryChatMessage>[]);
  bool _routeRequestInFlight = false;
  bool _isDisposing = false;
  bool _showDriverDebugOverlay = false;
  bool _discoveryPermissionDeniedNoticeVisible = false;
  String? _activePopupRideId;
  String? _acceptingPopupRideId;

  /// One backend [acceptRide] call per ride; duplicate taps await the same future.
  final Map<String, Future<bool>> _acceptRideInFlightById = <String, Future<bool>>{};
  /// In-flight dedupe for dispatch-delivery accepts (Slice 2). Kept separate
  /// from [_acceptRideInFlightById] so ride accept bookkeeping is untouched.
  final Map<String, Future<bool>> _acceptDeliveryInFlightById =
      <String, Future<bool>>{};
  final Map<String, Future<void>> _arrivedInFlightByRideId = <String, Future<void>>{};
  bool _startTripInFlight = false;
  bool _completeTripInFlight = false;
  String? _popupDismissedRideId;
  String? _popupDismissedReason;
  String? _rideAcceptGraceRideId;
  int? _rideAcceptGraceUntilMs;
  String? _mapInitializationError;
  String? _routeOverlayError;
  String _rideStatus = 'offline';
  String _socketStatus = 'disconnected';
  String _lastApiCallStatus = 'idle';
  String _lastActionError = '';
  String _lastRouteBuildKey = '';
  String _lastRouteConsistencyCheckKey = '';
  String? _lastAppliedSocketRideId;
  String? _lastAppliedSocketStatus;
  String? _lastAppliedSocketPaymentKey;
  String? _discoverySuspendedForRideId;
  String? _activeRouteRideId;
  String? _lastBuiltRouteStatus;
  String? _lastAppliedRouteTargetKey;
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
  DateTime? _lastDriverPresenceRtdbWriteAt;
  static const Duration _kDriverPresenceRtdbMinInterval = Duration(seconds: 20);
  DateTime? _lastPublicTrackSyncAt;
  static const Duration _kPublicTrackSyncMinInterval = Duration(seconds: 45);
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
  final Set<String> _localWalletCreditedRideIds = <String>{};
  final LocalBackendSimulationService _backendSimulation =
      LocalBackendSimulationService();

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
    final activeDeliveryId = _activeDeliveryId?.trim() ?? '';
    if (activeDeliveryId.isNotEmpty &&
        DeliveryStateMachine.isDriverActiveDeliveryState(_activeDeliveryState)) {
      return activeDeliveryId;
    }
    final rideId = _valueAsText(
      _currentRideId ??
          _driverActiveRideId ??
          _driverChatListenerRideId ??
          _callListenerRideId,
    );
    return rideId.isEmpty ? null : rideId;
  }

  bool get _isDeliveryCallContext => _callListenerKind == CallSessionKind.delivery;

  CallSessionKind _callKindFor(String contextId) {
    final normalized = contextId.trim();
    if (normalized.isEmpty) {
      return CallSessionKind.ride;
    }
    if (_callListenerRideId == normalized) {
      return _callListenerKind;
    }
    final activeDeliveryId = _activeDeliveryId?.trim() ?? '';
    if (activeDeliveryId.isNotEmpty && activeDeliveryId == normalized) {
      return CallSessionKind.delivery;
    }
    return CallSessionKind.ride;
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
      if (_activeOnlineAvailabilityMode == 'service_area') {
        return 'Ride requests are live for your selected service area.';
      }
      if (_activeOnlineAvailabilityMode == 'current_location') {
        return 'Ride requests are live using your current GPS position.';
      }
      return 'Ride requests are live. You can receive trips now.';
    }
    if (_lastAvailabilityIntentOnline) {
      return 'Last intended state: ONLINE. Tap GO ONLINE to publish availability again.';
    }
    return 'You stay offline until you explicitly tap GO ONLINE.';
  }

  String _normalizedAvailabilityMode(String raw) {
    final t = raw.trim().toLowerCase().replaceAll('-', '_');
    if (t == 'service_area' || t == 'area' || t == 'city') {
      return 'service_area';
    }
    return 'current_location';
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

    if (_isCommittedActiveRideForDriver(
      ride,
      rideId: _currentRideId ?? _driverActiveRideId ?? _sessionTrackedRideId,
    )) {
      _lastTripPanelHiddenReason = null;
      return true;
    }

    final currentRideId = _currentRideId;
    final hiddenReason = _activeRideRenderGuardReason(
      ride,
      rideId: currentRideId,
    );
    if (hiddenReason != null) {
      if (_isCommittedActiveRideForDriver(
        ride,
        rideId: currentRideId ?? _driverActiveRideId ?? _sessionTrackedRideId,
      )) {
        _lastTripPanelHiddenReason = null;
        return true;
      }
      if (currentRideId != null && currentRideId.isNotEmpty) {
        _logRenderBlocked(rideId: currentRideId, reason: hiddenReason);
      }
      _logTripPanelHidden('no_valid_active_ride');
      if (!_shouldScheduleStaleRidePurgeFromRenderGuard(
        rideId: currentRideId,
        reason: hiddenReason,
      )) {
        return false;
      }
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

  /// Slice 3: true while the driver is tracking an active dispatch delivery.
  bool get _hasActiveDelivery =>
      _activeDeliveryId != null &&
      _activeDeliveryData != null &&
      DeliveryStateMachine.isDriverActiveDeliveryState(_activeDeliveryState);

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

  /// True when any canonical ownership field maps to [uid].
  bool _rideAssignedToUid(Map<String, dynamic>? ride, String uid) {
    if (ride == null) {
      return false;
    }
    final normalizedUid = uid.trim();
    if (normalizedUid.isEmpty) {
      return false;
    }
    for (final key in const <String>[
      'driver_id',
      'matched_driver_id',
      'accepted_driver_id',
    ]) {
      if (_valueAsText(ride[key]).trim() == normalizedUid) {
        return true;
      }
    }
    return false;
  }

  bool _isCommittedActiveRideForDriver(
    Map<String, dynamic>? ride, {
    String? rideId,
  }) {
    if (ride == null) {
      return false;
    }
    final authUid = _currentAuthUid;
    if (authUid.isEmpty || !_rideAssignedToUid(ride, authUid)) {
      return false;
    }

    final status = TripStateMachine.uiStatusFromSnapshot(ride);
    if (status == 'cancelled' ||
        status == 'completed' ||
        status == 'searching' ||
        ride['trip_completed'] == true) {
      return false;
    }

    final tripState =
        _valueAsText(ride['trip_state']).trim().toLowerCase();
    final canonical = TripStateMachine.canonicalStateFromSnapshot(ride);
    final committed = status == 'accepted' ||
        tripState == TripLifecycleState.driverAssigned ||
        canonical == TripLifecycleState.driverAssigned ||
        TripStateMachine.isDriverActiveState(canonical);
    if (!committed) {
      return false;
    }

    final normalizedRideId = (rideId ?? _currentRideId ?? '').trim();
    if (normalizedRideId.isNotEmpty &&
        (_currentRideId == normalizedRideId ||
            _driverActiveRideId == normalizedRideId)) {
      return true;
    }

    return status == 'accepted' ||
        tripState == TripLifecycleState.driverAssigned ||
        canonical == TripLifecycleState.driverAssigned;
  }

  String get _currentAuthUid =>
      FirebaseAuth.instance.currentUser?.uid.trim() ?? '';

  bool _shouldRunOptionalRtdbEvent(String rideId, String eventKey) {
    final normalizedRideId = rideId.trim();
    final normalizedEventKey = eventKey.trim();
    if (normalizedRideId.isEmpty || normalizedEventKey.isEmpty) {
      return false;
    }
    return _optionalRtdbEventKeys.add('$normalizedRideId|$normalizedEventKey');
  }

  bool _isTerminalActiveRideClearReason(String reason) {
    final normalized = reason.trim().toLowerCase();
    return normalized.contains('cancel') ||
        normalized.contains('complete') ||
        normalized.contains('expired') ||
        normalized.contains('not_assigned') ||
        normalized.contains('driver_mismatch') ||
        normalized.contains('hard_reset') ||
        normalized.contains('system_cancel');
  }

  bool _shouldSuppressCommittedActiveRideClear({
    required String reason,
    Map<String, dynamic>? rideData,
    String? rideId,
  }) {
    if (!_isCommittedActiveRideForDriver(rideData, rideId: rideId)) {
      return false;
    }
    return !_isTerminalActiveRideClearReason(reason);
  }

  bool _shouldSuppressStaleRidePurge({
    String? rideId,
    Map<String, dynamic>? ride,
  }) {
    final normalizedRideId = rideId?.trim();
    if (normalizedRideId != null &&
        normalizedRideId.isNotEmpty &&
        (_currentRideId == normalizedRideId ||
            _driverActiveRideId == normalizedRideId)) {
      return true;
    }
    return _isCommittedActiveRideForDriver(
      ride ?? _currentRideData,
      rideId: normalizedRideId ?? _currentRideId,
    );
  }

  void _logRideStateChangeOnce({
    required String rideId,
    required String riderId,
    required String driverId,
    required String serviceType,
    required String status,
    required String source,
    Map<String, dynamic>? rideData,
  }) {
    // Route-log / ride_requests mirrors are backend-owned during active trips.
  }

  void _cancelWaitFeeGraceTimer({String reason = 'cancelled'}) {
    _waitFeeGraceTimer?.cancel();
    _waitFeeGraceTimer = null;
    _waitFeeGraceRideId = null;
    if (reason.isNotEmpty) {
      _log('wait fee grace timer cleared reason=$reason');
    }
  }

  void _cancelWaitTimerTicker() {
    _waitTimerTicker?.cancel();
    _waitTimerTicker = null;
    _waitTimerSecondsRemaining = 0;
  }

  String _waitTimerLabel() {
    final seconds = _waitTimerSecondsRemaining.clamp(0, 36000);
    final mm = (seconds ~/ 60).toString().padLeft(2, '0');
    final ss = (seconds % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  void _startWaitTimerTicker(String rideId) {
    final normalizedRideId = rideId.trim();
    if (normalizedRideId.isEmpty) return;
    _cancelWaitTimerTicker();
    _waitTimerTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _currentRideId != normalizedRideId) {
        _cancelWaitTimerTicker();
        return;
      }
      final graceUntilMs = _asInt(_currentRideData?['wait_fee_grace_until']) ?? 0;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final remainingSeconds =
          graceUntilMs > nowMs ? ((graceUntilMs - nowMs) / 1000).ceil() : 0;
      _waitTimerSecondsRemaining = remainingSeconds;
      if (remainingSeconds % 15 == 0) {
        _log('WAIT_TIMER_TICK rideId=$normalizedRideId seconds=$remainingSeconds');
      }
      if (remainingSeconds <= 0) {
        _log('WAIT_TIMER_EXPIRED rideId=$normalizedRideId');
        _cancelWaitTimerTicker();
      } else {
        _setStateSafely(() {});
      }
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _deliveryCallUi = DeliveryCallUiController(
      callService: _callService,
      getOverlayContext: () => mounted ? context : null,
      onBusyChanged: (bool busy) {
        if (mounted) {
          _setStateSafely(() => _isStartingVoiceCall = busy);
        }
      },
    );
    _deliveryCallUi.registerLifecycle();
    _callService.phaseNotifier.addListener(_handleCallVoicePhaseChanged);
    _callService.remotePeerJoinedNotifier.addListener(_handleCallVoicePhaseChanged);
    _callService.remotePeerStatusNotifier.addListener(_refreshCallOverlayEntry);
    _driverLocation = _selectedLaunchCityCenter;
    dispatchVerboseLog('DRIVER_MAP_INIT');
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
    DriverOfferPrimeCoordinator.instance.register((rideId) {
      unawaited(
        _consumePendingOfferLaunchIntent(
          source: 'push_or_resume',
          overrideRideId: rideId,
        ),
      );
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
      final notifyUid =
          FirebaseAuth.instance.currentUser?.uid.trim() ?? _effectiveDriverId;
      if (notifyUid.isNotEmpty) {
        unawaited(PortalInAppNotificationService.instance.attach(notifyUid));
      }
      await _loadOptionalDriverBootstrapContext();
      unawaited(_loadRolloutCatalogForDriver());
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

    DriverActiveRideRestoreSupport.traceStartupCheck(
      driverId: driverId,
      source: 'startup_restore',
    );
    DriverActiveDeliveryRestoreSupport.traceStartupCheck(
      driverId: driverId,
      source: 'startup_restore',
    );
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
    await _stopActiveDeliveryTracking(reason: 'startup_restore_reset');
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
      _readStartupSnapshot(
        query: _driversRef.root.child('driver_active_ride/$driverId'),
        path: 'driver_active_ride/$driverId',
      ),
      _readStartupSnapshot(
        query: _driversRef.root.child('driver_active_delivery/$driverId'),
        path: 'driver_active_delivery/$driverId',
      ),
    ]);
    final driverRecord =
        _asStringDynamicMap(snapshots[0]?.value) ?? <String, dynamic>{};
    final activeRideMarker = _asStringDynamicMap(snapshots[1]?.value);
    final activeDeliveryMarker = _asStringDynamicMap(snapshots[2]?.value);
    final pointerRideId = _valueAsText(
      activeRideMarker?['ride_id'] ?? activeRideMarker?['rideId'],
    );
    if (pointerRideId.isNotEmpty) {
      DriverActiveRideRestoreSupport.tracePointerFound(
        driverId: driverId,
        rideId: pointerRideId,
        source: 'startup_restore',
      );
    }
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

    var recoveredRide = await _recoverDriverRideFromBackend(
      driverId: driverId,
      driverRecord: driverRecord,
      activeRideMarker: activeRideMarker,
    );
    final recoveredPendingRideId = await _recoverPendingRideFromBackend(
      driverId: driverId,
      driverRecord: driverRecord,
      activeRideMarker: activeRideMarker,
    );
    if (recoveredRide != null) {
      final candidateRide = recoveredRide;
      final rejectReason = _evaluateDriverRestoreRejectReason(
        rideData: candidateRide.rideData,
        driverId: driverId,
        rideId: candidateRide.rideId,
        source: 'startup_restore',
      );
      if (rejectReason != null) {
        await _clearStaleDriverActiveRideSession(
          rideId: candidateRide.rideId,
          reason: rejectReason,
          source: 'startup_restore',
        );
        recoveredRide = null;
      }
    }
    final lastIntentOnline = _lastAvailabilityIntentFromRecord(
      driverRecord,
      remoteOnline: remoteOnline,
      hasTrackedRide: recoveredRide != null || recoveredPendingRideId != null,
    );
    _lastAvailabilityIntentOnline = lastIntentOnline;

    final rideToRestore = recoveredRide;
    if (rideToRestore != null) {
      final restoredStatus = TripStateMachine.legacyStatusForCanonical(
          rideToRestore.canonicalState);
      DriverActiveRideRestoreSupport.logRestoreAccept(
        rideId: rideToRestore.rideId,
        state: rideToRestore.canonicalState,
        status: restoredStatus,
      );
      DriverActiveRideRestoreSupport.traceValidated(
        driverId: driverId,
        rideId: rideToRestore.rideId,
        tripState: rideToRestore.canonicalState,
        source: 'startup_restore',
      );
      final restoredOnlineSessionStartedAt =
          _parseCreatedAt(driverRecord['online_session_started_at']);
      _onlineSessionStartedAt = restoredOnlineSessionStartedAt > 0
          ? restoredOnlineSessionStartedAt
          : DateTime.now().millisecondsSinceEpoch;
      _driverActiveRideId = rideToRestore.rideId;
      _currentRideId = rideToRestore.rideId;
      _currentRideData = Map<String, dynamic>.from(rideToRestore.rideData);
      _isOnline = false;
      _rideStatus = restoredStatus;
      _tripStarted = restoredStatus == 'on_trip';

      if (mounted) {
        setState(() {
          _currentRideId = rideToRestore.rideId;
          _currentRideData = Map<String, dynamic>.from(rideToRestore.rideData);
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
          'activeRideId': rideToRestore.rideId,
          'currentRideId': rideToRestore.rideId,
          'last_availability_intent': _lastAvailabilityIntentValue,
          if (_driverCity != null && _driverCity!.trim().isNotEmpty)
            'launch_market_city': _driverCity,
          'updated_at': rtdb.ServerValue.timestamp,
        },
      );
      unawaited(_resyncIncomingCallState());
      await _listenToActiveRide(rideToRestore.rideId);
      _startLiveLocationStream();
      DriverActiveRideRestoreSupport.traceUiRestored(
        driverId: driverId,
        rideId: rideToRestore.rideId,
        tripState: rideToRestore.canonicalState,
        source: 'startup_restore',
      );
      _log(
        'startup session restored active ride in offline-safe mode driverId=$driverId rideId=${rideToRestore.rideId} status=$restoredStatus',
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

    final remoteSessionStartedAt =
        _parseCreatedAt(driverRecord['online_session_started_at']);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final sessionAgeMs = remoteSessionStartedAt > 0
        ? nowMs - remoteSessionStartedAt
        : 1 << 62;
    const maxRehydrateSessionMs = 7 * 24 * 60 * 60 * 1000;
    final canRehydrateOnlineSession = remoteOnline &&
        lastIntentOnline &&
        remoteSessionStartedAt > 0 &&
        sessionAgeMs < maxRehydrateSessionMs;
    if (canRehydrateOnlineSession) {
      final verification = normalizedDriverVerification(
        driverRecord['verification'],
      );
      final businessModel = normalizedDriverBusinessModel(
        driverRecord['businessModel'] ?? driverRecord['business_model'],
      );
      final rehydrateBlock = evaluateDriverGoLive(
        Map<String, dynamic>.from(driverRecord),
        documentsApproved: driverVerificationCanGoOnline(verification),
      );
      if (rehydrateBlock != DriverGoLiveBlock.none ||
          businessModel['canGoOnline'] != true) {
        _log(
          'startup session blocked rehydrate — verification or business model '
          'not eligible driverId=$driverId block=$rehydrateBlock '
          'verification=${verification['overallStatus']}',
        );
        await _clearDriverActiveRideNode(
          reason: 'startup_restore_verification_blocked',
        );
        _isOnline = false;
        _rideStatus = 'offline';
        if (mounted) {
          setState(() {
            _isOnline = false;
            _rideStatus = 'offline';
          });
        }
        try {
          await RideCloudFunctionsService()
              .setDriverOffline()
              .timeout(const Duration(seconds: 20));
        } catch (e) {
          _log('startup_restore_verification_blocked setDriverOffline: $e');
        }
        return;
      }
      _ingestRolloutFromProfile(driverRecord);
      final modeRaw = _valueAsText(driverRecord['driver_availability_mode']);
      if (modeRaw.isNotEmpty) {
        _activeOnlineAvailabilityMode = _normalizedAvailabilityMode(modeRaw);
        _pendingAvailabilityMode = _activeOnlineAvailabilityMode;
      }
      _onlineSessionStartedAt = remoteSessionStartedAt;
      _lastAvailabilityIntentOnline = lastIntentOnline;
      _isOnline = true;
      _rideStatus = 'idle';
      if (mounted) {
        setState(() {
          _isOnline = true;
          _lastAvailabilityIntentOnline = lastIntentOnline;
          _rideStatus = 'idle';
        });
      }
      _updateDriverMarker();
      _startLiveLocationStream();
      _log(
        'startup session rehydrated online driverId=$driverId '
        'online_session_started_at=$_onlineSessionStartedAt '
        '(skipped RTDB offline wipe — server still shows available session)',
      );
      unawaited(
        _rideCloud.refreshDriverAvailability(source: 'startup_rehydrate_online'),
      );
      _logDriverOnlineState(online: true, reason: 'startup_rehydrate_online');
      _startOfferListenerWatchdog();
      unawaited(_listenForRideRequests(reason: 'startup_rehydrate_online'));
      await _restoreActiveDeliveryIfEligible(
        driverId: driverId,
        activeDeliveryMarker: activeDeliveryMarker,
        rideWasRestored: false,
      );
      return;
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
    await _restoreActiveDeliveryIfEligible(
      driverId: driverId,
      activeDeliveryMarker: activeDeliveryMarker,
      rideWasRestored: false,
    );
  }

  /// P0-B: cold-start restore for active dispatch deliveries (parallel to ride
  /// restore; never touches TripStateMachine or ride listeners).
  Future<void> _restoreActiveDeliveryIfEligible({
    required String driverId,
    required Map<String, dynamic>? activeDeliveryMarker,
    required bool rideWasRestored,
  }) async {
    final deliveryId = DriverActiveDeliveryRestoreSupport.resolveStartupDeliveryRestore(
      pointer: activeDeliveryMarker,
      rideWasRestored: rideWasRestored,
    );
    if (deliveryId == null) {
      return;
    }
    DriverActiveDeliveryRestoreSupport.tracePointerFound(
      driverId: driverId,
      deliveryId: deliveryId,
      pointerUpdatedAt: DriverActiveDeliveryRestoreSupport.pointerUpdatedAtMs(
        activeDeliveryMarker,
      ),
      source: 'startup_restore',
    );
    _log(
      'startup session restoring active delivery driverId=$driverId deliveryId=$deliveryId',
    );
    await _startActiveDeliveryTracking(deliveryId);
    DriverActiveDeliveryRestoreSupport.traceUiRestored(
      driverId: driverId,
      deliveryId: deliveryId,
      source: 'startup_restore',
    );
  }

  Future<void> _releaseLocalPendingAssignmentIfNeeded({
    required String reason,
  }) async {
    final pendingRideIds = <String>{
      if (_activePopupRideId?.trim().isNotEmpty == true) _activePopupRideId!,
      if (_pendingOfferPopupRideId?.trim().isNotEmpty == true)
        _pendingOfferPopupRideId!,
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
      if (_startupRejectedRestoreRideIds.contains(rideId)) {
        DriverActiveRideRestoreSupport.logRestoreReject(
          rideId: rideId,
          reason: 'startup_rejected_cached',
        );
        return;
      }

      final snapshot = await _readStartupSnapshot(
        query: _rideRequestsRef.child(rideId),
        path: 'ride_requests/$rideId',
      );
      final rideData = _asStringDynamicMap(snapshot?.value);
      if (rideData == null) {
        DriverActiveRideRestoreSupport.logRestoreReject(
          rideId: rideId,
          reason: 'ride_missing',
        );
        _startupRejectedRestoreRideIds.add(rideId);
        return;
      }

      if (!_rideAssignedToUid(rideData, driverId)) {
        DriverActiveRideRestoreSupport.logRestoreReject(
          rideId: rideId,
          reason: 'driver_mismatch',
        );
        _startupRejectedRestoreRideIds.add(rideId);
        return;
      }

      final canonicalState = TripStateMachine.canonicalStateFromSnapshot(
        rideData,
      );
      final rejectReason = _evaluateDriverRestoreRejectReason(
        rideData: rideData,
        driverId: driverId,
        rideId: rideId,
        source: 'recover_driver_ride',
      );
      if (rejectReason != null) {
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
    _log(
        'camera initialized attempt=$attempt target=${_driverLocation.latitude},${_driverLocation.longitude}');
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
      await _nudgeDriverMapTiles(controller,
          reason: 'tile_recovery_$phaseLabel');
      _log(
          'map tile recovery applied recovery=$_mapTileRecoveryCount phase=$phaseLabel');
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
        expectedRideId != _currentCandidateRideId &&
        expectedRideId != _pendingOfferPopupRideId;
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
    if (_isDriverChatOpen) {
      return;
    }

    final status = _rideStatus;
    final routeTargetKey =
        _buildActiveRouteTargetKey(rideId: rideId, status: status);
    if (!force &&
        _activeRouteRideId == rideId &&
        _lastBuiltRouteStatus == status &&
        _lastAppliedRouteTargetKey == routeTargetKey) {
      _log(
        'ROUTE_REFRESH_SKIPPED reason=no_change rideId=$rideId status=$status',
      );
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
    dispatchVerboseLog('[DriverMap] $message');
  }

  void _logGuard(String message) {
    dispatchVerboseLog('[DriverGuard] $message');
  }

  void _logValidation(String message) {
    dispatchVerboseLog('[DriverValidation] $message');
  }

  void _logUi(String message) {
    dispatchVerboseLog('[DriverUI] $message');
  }

  void _logRtdb(String message) {
    dispatchVerboseLog('[DriverRTDB] $message');
  }

  /// Verbose ride discovery → popup trace (off in release).
  void _logRideReq(String message) {
    if (message.contains('DRIVER_DISCOVERY_TRACE') ||
        message.contains('fallback_polling_recover') ||
        message.contains('noop_refresh') ||
        message.contains('[MATCH_DEBUG]') ||
        message.contains('[DRIVER_DISCOVERY_QUERY]') ||
        message.contains('DRIVER_REQUEST_RECEIVED')) {
      return;
    }
    dispatchVerboseLog('[RIDE_REQ] $message');
  }

  void _setApiStatus(
    String status, {
    String? errorMessage,
  }) {
    final nextError = errorMessage ??
        ((status == 'success' || status == 'listening') ? '' : _lastActionError);
    if (status == _lastApiCallStatus && nextError == _lastActionError) {
      return;
    }
    _lastApiCallStatus = status;
    if (errorMessage != null) {
      _lastActionError = errorMessage;
    } else if (status == 'success' || status == 'listening') {
      _lastActionError = '';
    }
    if (mounted) {
      _setStateSafely(() {});
    }
  }

  int _countActiveDriverRtdbSubscriptions() {
    var count = _driverChatSubscriptions.length;
    if (_rideRequestSubscription != null) {
      count++;
    }
    if (_driverOfferQueueChildRemovedSubscription != null) {
      count++;
    }
    if (_deliveryOfferQueueChildAddedSubscription != null) {
      count++;
    }
    if (_deliveryOfferQueueChildRemovedSubscription != null) {
      count++;
    }
    if (_activeRideSubscription != null) {
      count++;
    }
    if (_activeDeliverySubscription != null) {
      count++;
    }
    if (_driverActiveDeliverySubscription != null) {
      count++;
    }
    return count;
  }

  int _countActiveDriverTimers() {
    var count = 0;
    if (_routeRequestDebounceTimer != null) {
      count++;
    }
    if (_ridePopupTimer != null) {
      count++;
    }
    if (_waitFeeGraceTimer != null) {
      count++;
    }
    if (_waitTimerTicker != null) {
      count++;
    }
    if (_callDurationTimer != null) {
      count++;
    }
    if (_callRingTimeoutTimer != null) {
      count++;
    }
    if (_mapInitializationTimer != null) {
      count++;
    }
    if (_activeTripUiDebounceTimer != null) {
      count++;
    }
    return count;
  }

  void _logResourceCounts(String source) {
    final now = DateTime.now();
    if (_lastResourceCountLogAt != null &&
        now.difference(_lastResourceCountLogAt!) <
            const Duration(seconds: 30)) {
      return;
    }
    _lastResourceCountLogAt = now;
    final offerListeners =
        (_rideRequestSubscription != null ? 1 : 0) +
        (_driverOfferQueueChildRemovedSubscription != null ? 1 : 0) +
        (_deliveryOfferQueueChildAddedSubscription != null ? 1 : 0) +
        (_deliveryOfferQueueChildRemovedSubscription != null ? 1 : 0);
    final activeTripListeners = (_activeRideSubscription != null ? 1 : 0) +
        (_activeDeliverySubscription != null ? 1 : 0) +
        (_driverActiveDeliverySubscription != null ? 1 : 0);
    final chatListeners = _driverChatSubscriptions.length;
    final activeTimers = _countActiveDriverTimers();
    final activeSubscriptions = _countActiveDriverRtdbSubscriptions();
    RtdbResourceGuard.logActiveSubscriptions(
      total: activeSubscriptions,
      source: source,
    );
    if (activeTimers > RtdbResourceGuard.maxActiveTimers ||
        activeSubscriptions > RtdbResourceGuard.maxActiveRtdbListeners) {
      _log(
        'RESOURCE_GUARD timers=$activeTimers listeners=$activeSubscriptions '
        'source=$source',
      );
    }
    _log(
      'LISTENER_COUNT offer=$offerListeners activeTrip=$activeTripListeners '
      'chat=$chatListeners source=$source',
    );
    _log('TIMER_COUNT active=$activeTimers source=$source');
    final pendingWrites =
        RealtimeDatabaseWriteQueue.instance.pendingCount;
    _log(
      'MEMORY_FLOW listeners=$activeSubscriptions '
      'timers=$activeTimers chatMessages=${_driverChatMessagesById.length} '
      'pendingWrites=$pendingWrites routeRefreshInFlight=$_routeRequestInFlight '
      'source=$source',
    );
  }

  String _debugTripStateLabel() {
    final canonical =
        TripStateMachine.canonicalStateFromSnapshot(_currentRideData);
    return switch (canonical) {
      TripLifecycleState.searching => 'searching',
      TripLifecycleState.driverAssigned => 'accepted',
      TripLifecycleState.driverArriving => 'arriving',
      TripLifecycleState.arrived => 'arrived',
      TripLifecycleState.inProgress => 'in_progress',
      TripLifecycleState.completed => 'completed',
      TripLifecycleState.cancelled => 'cancelled',
      TripLifecycleState.expired => 'expired',
      _ => _rideStatus,
    };
  }

  void _ensureActiveTripNavigation({
    required String rideId,
    required Map<String, dynamic> rideData,
  }) {
    _logRideReq(
        '[NAVIGATION_TRIGGERED] rideId=$rideId target=active_trip_forced');
    if (mounted) {
      _setStateSafely(() {
        _popupOpen = false;
        _hasActivePopup = false;
        _activePopupRideId = null;
        _driverActiveRideId = rideId;
        _currentRideId = rideId;
        _currentRideData = Map<String, dynamic>.from(rideData);
        _rideStatus = TripStateMachine.uiStatusFromSnapshot(rideData);
      });
    } else {
      _popupOpen = false;
      _hasActivePopup = false;
      _activePopupRideId = null;
      _driverActiveRideId = rideId;
      _currentRideId = rideId;
      _currentRideData = Map<String, dynamic>.from(rideData);
      _rideStatus = TripStateMachine.uiStatusFromSnapshot(rideData);
    }
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (_currentRideId == rideId && _driverActiveRideId != rideId) {
        _driverActiveRideId = rideId;
        if (mounted) {
          _setStateSafely(() {});
        }
      }
    });
  }

  bool _hasActiveDriverTripAssignment() {
    if (_hasActiveDelivery) {
      return true;
    }
    final rideId = _firstNonEmptyText(<dynamic>[
      _currentRideId,
      _driverActiveRideId,
    ]).trim();
    if (rideId.isEmpty) {
      return false;
    }
    return _hasActiveJobBlockingNewOffers();
  }

  /// Production policy (Option A): no new offer popups while a committed ride or delivery is active,
  /// except one queued-next offer when the driver is on a trip and the queue slot is empty.
  bool _hasActiveJobBlockingNewOffers({String? incomingOfferId}) {
    if (_hasActiveDelivery) {
      return true;
    }
    final rideId = _firstNonEmptyText(<dynamic>[
      _driverActiveRideId,
      _currentRideId,
    ]).trim();
    if (rideId.isEmpty) {
      return false;
    }
    final incoming = incomingOfferId?.trim() ?? '';
    final queuedNext = _queuedNextRideIdFromProfile?.trim() ?? '';
    if (incoming.isNotEmpty && incoming != rideId) {
      return queuedNext.isNotEmpty;
    }
    if (incoming.isNotEmpty && incoming == rideId) {
      return false;
    }
    if (queuedNext.isNotEmpty) {
      return true;
    }
    final rideData = _currentRideData;
    if (rideData == null || rideData.isEmpty) {
      if (_driverActiveRideId?.trim() == rideId) {
        _driverActiveRideId = null;
      }
      if (_currentRideId?.trim() == rideId) {
        _currentRideId = null;
        _currentRideData = null;
        _rideStatus = _isOnline ? 'idle' : 'offline';
      }
      return false;
    }
    final canonical = TripStateMachine.canonicalStateFromSnapshot(rideData);
    if (TripStateMachine.isTerminal(canonical)) {
      return false;
    }
    final status = _normalizedRideStatus(_valueAsText(rideData['status']));
    if (status == 'cancelled' ||
        status == 'completed' ||
        status == 'expired' ||
        status == 'driver_cancelled') {
      return false;
    }
    final assignedDriver = _valueAsText(
      rideData['matched_driver_id'] ?? rideData['driver_id'],
    );
    if (assignedDriver.isEmpty || assignedDriver == 'waiting') {
      return false;
    }
    if (assignedDriver == _effectiveDriverId) {
      // On-trip with an empty queue slot — allow one additional queued offer.
      return false;
    }
    return true;
  }

  String _activeJobBlockingSkipReason() {
    if (_hasActiveDelivery) {
      return 'active_delivery_blocked';
    }
    return 'active_trip_blocked';
  }

  void _logActiveJobOfferBlocked(String rideId, {required String source}) {
    final reason = _activeJobBlockingSkipReason();
    debugPrint(
      '[MATCH_DEBUG] driver_active_ride_busy rideId=$rideId source=$source '
      'reason=$reason activeRide=${_currentRideId ?? _driverActiveRideId ?? 'none'} '
      'activeDelivery=${_activeDeliveryId ?? 'none'}',
    );
    debugPrint(
      'DRIVER_OFFER_POPUP_SKIPPED rideId=$rideId reason=active_trip_blocked '
      'detail=$reason',
    );
    _logDriverOfferPopupSuppressed(rideId, 'active_trip_blocked');
    _logRideReq(
      'offer popup skipped reason=active_trip_blocked detail=$reason '
      'rideId=$rideId source=$source',
    );
  }

  void _resetSocketApplyDedup() {
    _lastAppliedSocketRideId = null;
    _lastAppliedSocketStatus = null;
    _lastAppliedSocketPaymentKey = null;
    _discoverySuspendedForRideId = null;
    _activeRouteRideId = null;
    _lastBuiltRouteStatus = null;
    _lastAppliedRouteTargetKey = null;
  }

  String _ridePaymentFingerprint(Map<String, dynamic> rideData) {
    return [
      rideData['payment_verified'] == true ? '1' : '0',
      _valueAsText(rideData['payment_status']),
      _valueAsText(rideData['paid_at']),
      _valueAsText(rideData['payment_transaction_id']),
      _valueAsText(rideData['flutterwave_transaction_id']),
    ].join('|');
  }

  bool _shouldSkipDuplicateRideApply({
    required String rideId,
    required String? status,
    required String paymentKey,
  }) {
    if (_lastAppliedSocketRideId != rideId) {
      _lastAppliedSocketRideId = rideId;
      _lastAppliedSocketStatus = status;
      _lastAppliedSocketPaymentKey = paymentKey;
      return false;
    }
    if (_lastAppliedSocketStatus == status &&
        _lastAppliedSocketPaymentKey == paymentKey) {
      return true;
    }
    _lastAppliedSocketRideId = rideId;
    _lastAppliedSocketStatus = status;
    _lastAppliedSocketPaymentKey = paymentKey;
    return false;
  }

  Future<void> _suspendOfferDiscoveryForActiveTrip(String reason) async {
    if (!_hasActiveDriverTripAssignment()) {
      return;
    }
    // Option A: listener may stay attached; popups are blocked in processRideMap.
    _logRideReq(
      '[DISCOVERY_ACTIVE_TRIP] listener_may_stay_attached popups_blocked reason=$reason '
      'currentRideId=$_currentRideId driverActive=$_driverActiveRideId',
    );
    _ensureRideDiscoverySubscriptionIfOnline(
      reason: 'active_trip_keep_listening:$reason',
    );
  }

  void _offerDiscoveryLog(String event, {String? rideId, String? detail}) {
    dispatchOfferEvent(
      event,
      rideId: rideId,
      driverId: _effectiveDriverId.trim(),
      detail: detail,
    );
  }

  void _logDriverOnlineState({required bool online, required String reason}) {
    debugPrint(
      'DRIVER_ONLINE_STATE online=$online reason=$reason '
      'driverId=${_effectiveDriverId.trim()} '
      'listenerAttached=${_rideRequestSubscription != null}',
    );
  }

  void _logDriverOfferListenerAttach(String uid, {required String reason}) {
    debugPrint(
      'DRIVER_OFFER_LISTENER_ATTACH driverId=$uid '
      'path=driver_offer_queue/$uid reason=$reason',
    );
    debugPrint(
      'DRIVER_OFFER_QUEUE_ATTACH path=driver_offer_queue/$uid reason=$reason',
    );
  }

  void _logDriverOfferListenerAlreadyAttached(String uid, {required String reason}) {
    debugPrint(
      'DRIVER_OFFER_LISTENER_ALREADY_ATTACHED driverId=$uid '
      'path=driver_offer_queue/$uid reason=$reason',
    );
  }

  void _logDriverOfferListenerHealth({required String source}) {
    _syncOfferListenerDebugCounts();
    debugPrint(
      'DRIVER_OFFER_LISTENER_HEALTH driverId=${_effectiveDriverId} '
      'online=$_isOnline '
      'listenerAttached=$_isDriverOfferQueueListenerAttached '
      'childAddedAttached=${_rideRequestSubscription != null} '
      'childChangedAttached=${_driverOfferQueueChildChangedSubscription != null} '
      'childRemovedAttached=${_driverOfferQueueChildRemovedSubscription != null} '
      'processorBound=${_boundOfferQueueProcessor != null} '
      'boundUid=${_driverOfferQueueBoundUid ?? 'none'} '
      'offerQueueCount=$_offerQueueDebugCount '
      'lastOfferEvent=$_lastOfferEventSummary '
      'hasActiveRide=${_hasActiveJobBlockingNewOffers()} '
      'hasActiveDelivery=$_hasActiveDelivery '
      'popupVisible=${_popupOpen || _hasActivePopup} '
      'lifecycle=${_popupLifecycleState.name} queueDepth=${_rideRequestPopupQueue.length} '
      'socketStatus=$_socketStatus source=$source',
    );
  }

  void _syncOfferListenerDebugCounts() {
    _offerQueueDebugCount = _driverOfferQueueReplica.length;
  }

  void _recordOfferListenerEvent({
    required String type,
    required String rideId,
  }) {
    final rid = rideId.trim();
    _lastOfferEventSummary =
        rid.isEmpty ? type : '$type $rid';
    _syncOfferListenerDebugCounts();
    if (mounted) {
      _setStateSafely(() {});
    }
  }

  void _startOfferListenerWatchdog() {
    _offerListenerWatchdogTimer?.cancel();
    if (!_isOnline || _isDisposing) {
      return;
    }
    _offerListenerWatchdogTimer = Timer.periodic(
      _kOfferListenerWatchdogInterval,
      (_) => unawaited(_tickOfferListenerWatchdog()),
    );
    unawaited(_tickOfferListenerWatchdog());
  }

  void _stopOfferListenerWatchdog() {
    _offerListenerWatchdogTimer?.cancel();
    _offerListenerWatchdogTimer = null;
  }

  Future<void> _tickOfferListenerWatchdog() async {
    if (!mounted || !_isOnline || _isDisposing) {
      return;
    }
    _logDriverOfferListenerHealth(source: 'watchdog');
    if (_hasActiveJobBlockingNewOffers() || _hasActiveDelivery) {
      return;
    }
    final childAddedAttached = _rideRequestSubscription != null;
    final processorBound = _boundOfferQueueProcessor != null;
    if (!childAddedAttached || !processorBound) {
      await _rebindOfferListenerIfNeeded(
        source: 'watchdog_missing_child_added',
        force: true,
      );
      return;
    }
    if (_offerListenerAppearsUnhealthy()) {
      await _rebindOfferListenerIfNeeded(
        source: 'watchdog_unhealthy',
        force: true,
      );
      return;
    }
    unawaited(_primeOfferQueuesFromRtdb(source: 'watchdog_prime'));
  }

  void _logDriverOfferPopupClosed(String rideId, {required String reason}) {
    debugPrint(
      'DRIVER_OFFER_POPUP_CLOSED rideId=$rideId reason=$reason '
      'queueDepth=${_rideRequestPopupQueue.length}',
    );
  }

  String _popupStateSnapshotFields({String? rideId}) {
    final rid = rideId?.trim() ?? '';
    return 'popupOpen=$_popupOpen hasActivePopup=$_hasActivePopup '
        'lifecycle=${_popupLifecycleState.name} currentRideId=${_currentRideId ?? 'none'} '
        'driverActiveRideId=${_driverActiveRideId ?? 'none'} activePopup=${_activePopupRideId ?? 'none'} '
        'presentedCount=${_presentedRideIds.length} queueDepth=${_rideRequestPopupQueue.length} '
        'cacheSize=${_driverOfferRideCache.length} focusRideId=${rid.isEmpty ? 'none' : rid}';
  }

  void _logPopupStateBeforeClear({
    required String reason,
    String? rideId,
  }) {
    debugPrint(
      'POPUP_STATE_BEFORE_CLEAR reason=$reason ${_popupStateSnapshotFields(rideId: rideId)}',
    );
  }

  void _logPopupStateAfterClear({
    required String reason,
    String? rideId,
  }) {
    debugPrint(
      'POPUP_STATE_AFTER_CLEAR reason=$reason ${_popupStateSnapshotFields(rideId: rideId)}',
    );
  }

  void _logNewOfferSuppressed(String rideId, String reason) {
    debugPrint(
      'NEW_OFFER_SUPPRESSED rideId=$rideId reason=$reason ${_popupStateSnapshotFields(rideId: rideId)}',
    );
  }

  void _clearPopupVisibilityFlags() {
    _popupOpen = false;
    _hasActivePopup = false;
  }

  /// Clears popup lifecycle, queue/cache entries, and stale trip pointers after terminal outcomes.
  void _clearOfferPopupState({
    required String reason,
    String? rideId,
    bool clearQueue = true,
    bool removeRideFromCache = true,
    bool clearEntireCache = false,
    bool dismissVisibleDialog = false,
    bool clearCurrentRidePointer = true,
    bool forceLifecycleIdle = true,
  }) {
    final rid = rideId?.trim() ?? '';
    _logPopupStateBeforeClear(reason: reason, rideId: rid.isEmpty ? null : rid);

    if (dismissVisibleDialog && mounted && (_popupOpen || _hasActivePopup)) {
      unawaited(Navigator.of(context, rootNavigator: true).maybePop());
    }

    _clearPopupVisibilityFlags();
    _popupDismissedRideId = null;
    _popupDismissedReason = null;
    _acceptingPopupRideId = null;

    if (rid.isNotEmpty) {
      _presentedRideIds.remove(rid);
      _handledRideIds.remove(rid);
      _timedOutRideIds.remove(rid);
      _declinedRideIds.remove(rid);
      _suppressedRidePopupIds.remove(rid);
      _lastDiscoveryDismissFingerprintByRideId.remove(rid);
      _discoveryPopupCooldownUntilMs.remove(rid);
      _loggedDriverOfferReceivedRideIds.remove(rid);
      _driverOfferQueueReplica.remove(rid);
      if (removeRideFromCache) {
        _driverOfferRideCache.remove(rid);
      }
      if (clearQueue) {
        _rideRequestPopupQueue.removeWhere((r) => r.rideId.trim() == rid);
      }
      if (_activePopupRideId?.trim() == rid) {
        _activePopupRideId = null;
      }
      if (_currentCandidateRideId?.trim() == rid) {
        _currentCandidateRideId = null;
      }
      _clearPendingOfferPopupRideId(rid);
      _backendTrustedOfferRideIds.remove(rid);
      if (clearCurrentRidePointer &&
          !_isCommittedActiveRideForDriver(_currentRideData, rideId: rid)) {
        if (_currentRideId?.trim() == rid) {
          _currentRideId = null;
          _currentRideData = null;
          _rideStatus = _isOnline ? 'idle' : 'offline';
        }
        if (_driverActiveRideId?.trim() == rid) {
          _driverActiveRideId = null;
        }
      }
    } else if (clearQueue) {
      _rideRequestPopupQueue.clear();
      _activePopupRideId = null;
      _currentCandidateRideId = null;
      _pendingOfferPopupRideId = null;
    }

    if (clearEntireCache) {
      _driverOfferRideCache.clear();
      _driverOfferQueueReplica.clear();
    }

    _popupLifecycleStaleResetTimer?.cancel();
    _popupLifecycleStaleResetTimer = null;
    if (forceLifecycleIdle && _popupLifecycleState != _DriverPopupLifecycleState.idle) {
      _logRideReq(
        'popup_state ${_popupLifecycleState.name} -> idle '
        'rideId=${rid.isEmpty ? 'none' : rid} reason=$reason',
      );
      _popupLifecycleState = _DriverPopupLifecycleState.idle;
    } else if (forceLifecycleIdle) {
      _popupLifecycleState = _DriverPopupLifecycleState.idle;
    }

    _logPopupStateAfterClear(reason: reason, rideId: rid.isEmpty ? null : rid);
  }

  void _logDriverOfferQueueDrained({required int nextCount, required String source}) {
    debugPrint(
      'DRIVER_OFFER_QUEUE_DRAINED nextCount=$nextCount source=$source',
    );
  }

  void _ensureContinuousOfferDiscovery({required String source}) {
    if (!_isOnline || _isDisposing) {
      return;
    }
    unawaited(_rebindOfferListenerIfNeeded(source: source));
    _ensureRideDiscoverySubscriptionIfOnline(reason: source);
    unawaited(_primeOfferQueuesFromRtdb(source: source));
  }

  Future<void> _rebindOfferListenerIfNeeded({
    required String source,
    bool force = false,
  }) async {
    if (!_isOnline || _isDisposing) {
      return;
    }
    _logDriverOfferListenerHealth(source: source);
    if (_hasActiveJobBlockingNewOffers() || _hasActiveDelivery) {
      return;
    }
    if (_discoveryRebindFrozen && !_isTerminalRebindReason(source)) {
      _scheduleDiscoveryRearmWhenIdle(source);
      return;
    }
    final attached = _isDriverOfferQueueListenerAttached;
    final unhealthy = _offerListenerAppearsUnhealthy();
    final shouldRebind =
        force || _shouldForceRebindOfferListener(source) || !attached || unhealthy;
    if (!shouldRebind) {
      return;
    }
    debugPrint(
      'MATCHING_DRIVER_READY_CHECK driverId=${_effectiveDriverId} '
      'source=$source listenerAttached=$attached unhealthy=$unhealthy force=$force',
    );
    if (unhealthy && attached) {
      await _cancelRideRequestListener(
        reason: 'unhealthy_listener:$source',
      );
    }
    final rebindReason = force || _shouldForceRebindOfferListener(source)
        ? 'force_rebind:$source'
        : 'watchdog:$source';
    await _listenForRideRequests(reason: rebindReason);
    debugPrint(
      'DRIVER_OFFER_QUEUE_RESUBSCRIBED driverId=${_effectiveDriverId} '
      'reason=$rebindReason',
    );
    debugPrint(
      'DRIVER_READY_FOR_NEXT_OFFER driverId=${_effectiveDriverId} '
      'rideId=none source=$rebindReason',
    );
  }

  void _clearStaleLocalTripBlockersAfterOfferTerminal(String rideId) {
    final rid = rideId.trim();
    if (rid.isEmpty) {
      return;
    }
    _clearOfferPopupState(
      reason: 'offer_terminal_local',
      rideId: rid,
      dismissVisibleDialog: false,
      clearEntireCache: false,
    );
  }

  /// Re-read authoritative ride row before showing an offer popup.
  /// Returns fresh ride map when offerable; discards stale queue rows otherwise.
  Future<Map<String, dynamic>?> _loadFreshRideRequestForOfferPopup(
    String rideId, {
    required String source,
  }) async {
    final rid = rideId.trim();
    if (rid.isEmpty) {
      return null;
    }
    try {
      final snap = await rtdb.FirebaseDatabase.instance
          .ref('ride_requests/$rid')
          .get()
          .timeout(const Duration(seconds: 4));
      if (!snap.exists || snap.value is! Map) {
        debugPrint(
          'OFFER_POPUP_DISCARDED_STALE rideId=$rid status=missing trip_state=missing '
          'reason=ride_missing source=$source',
        );
        await _removeStaleOfferQueueEntry(rid);
        return null;
      }
      final fresh = _asStringDynamicMap(snap.value);
      if (fresh == null) {
        debugPrint(
          'OFFER_POPUP_DISCARDED_STALE rideId=$rid status=invalid trip_state=invalid '
          'reason=ride_invalid source=$source',
        );
        await _removeStaleOfferQueueEntry(rid);
        return null;
      }
      final status = _valueAsText(fresh['status']).toLowerCase();
      final tripState = _valueAsText(fresh['trip_state']).toLowerCase();
      final canonical = TripStateMachine.canonicalStateFromSnapshot(fresh);
      String? discardReason;
      if (TripStateMachine.isTerminal(canonical)) {
        discardReason = 'trip_terminal_state';
      } else if (<String>{
        'cancelled',
        'canceled',
        'completed',
        'expired',
        'accepted',
        'driver_cancelled',
        'rider_cancelled',
      }.contains(status)) {
        discardReason = 'ride_status_terminal';
      } else if (<String>{
        'cancelled',
        'canceled',
        'completed',
        'expired',
        'accepted',
        'driver_assigned',
        'driver_cancelled',
        'rider_cancelled',
      }.contains(tripState)) {
        discardReason = 'trip_state_terminal';
      } else if (status == 'accepted' ||
          tripState == 'accepted' ||
          tripState == 'driver_assigned') {
        final assignedDriver = _valueAsText(fresh['driver_id']).trim();
        final assignedLower = assignedDriver.toLowerCase();
        if (assignedDriver.isNotEmpty &&
            assignedLower != 'waiting' &&
            assignedDriver != _effectiveDriverId) {
          discardReason = 'driver_already_assigned';
        }
      }
      if (discardReason == null) {
        const offerable = <String>{
          'searching',
          'requesting',
          'requested',
          'searching_driver',
          '',
        };
        if (!offerable.contains(status) &&
            !offerable.contains(tripState) &&
            !TripStateMachine.isPendingDriverAssignmentState(canonical)) {
          discardReason = 'not_searching_or_requesting';
        }
      }
      if (discardReason == null &&
          !_driverOfferQueueReplica.containsKey(rid) &&
          source.startsWith('process_ride_map')) {
        discardReason = 'offer_not_in_queue';
      }
      if (discardReason != null) {
        debugPrint(
          'OFFER_POPUP_DISCARDED_STALE rideId=$rid status=$status trip_state=$tripState '
          'reason=$discardReason source=$source',
        );
        await _removeStaleOfferQueueEntry(rid);
        return null;
      }
      return fresh;
    } catch (error) {
      debugPrint(
        'OFFER_POPUP_FRESH_READ_FAIL rideId=$rid source=$source error=$error',
      );
      return null;
    }
  }

  bool _isDeliveryOfferQueuePayload(Map<String, dynamic>? offer) =>
      DeliveryOfferPopupSupport.isDeliveryOfferQueuePayload(offer);

  bool _isDeliveryOfferData(Map<String, dynamic>? data) =>
      DeliveryOfferPopupSupport.isDeliveryOfferData(data);

  String? _popupServerSkipReasonDeliveryOffer(
    String deliveryId,
    Map<String, dynamic> rideData,
  ) {
    return DeliveryOfferPopupSupport.skipReason(
      rideData,
      effectiveDriverId: _effectiveDriverId,
      nowMs: DateTime.now().millisecondsSinceEpoch,
      expiryGraceMs: 10_000,
    );
  }

  /// Dispatch delivery offers must never fresh-read `ride_requests/{id}`.
  Future<Map<String, dynamic>?> _loadFreshDeliveryRequestForOfferPopup(
    String deliveryId, {
    required String source,
    Map<String, dynamic>? queuePayload,
  }) async {
    final did = deliveryId.trim();
    if (did.isEmpty) {
      return null;
    }
    var payloadData = _rideDataFromDriverOfferQueue(did, queuePayload);
    if (payloadData == null) {
      debugPrint(
        'DELIVERY_OFFER_REJECTED deliveryId=$did reason=missing_queue_payload source=$source',
      );
      return null;
    }
    payloadData = Map<String, dynamic>.from(payloadData)
      ..['delivery_id'] = did
      ..['__nexride_request_kind'] = 'delivery'
      ..['request_kind'] = 'delivery'
      ..['service_type'] = 'dispatch_delivery';
    final payloadReject = _popupServerSkipReasonDeliveryOffer(did, payloadData);
    if (payloadReject != null) {
      debugPrint(
        'DELIVERY_OFFER_REJECTED deliveryId=$did reason=$payloadReject source=$source',
      );
      if (payloadReject == 'expired' ||
          payloadReject == 'delivery_terminal' ||
          payloadReject == 'delivery_status_terminal' ||
          payloadReject == 'assigned_to_another_driver') {
        await _removeStaleOfferQueueEntry(did, isDelivery: true);
      }
      return null;
    }

    try {
      debugPrint(
        'DELIVERY_OFFER_FRESH_READ_START path=delivery_requests/$did source=$source',
      );
      final snap = await rtdb.FirebaseDatabase.instance
          .ref('delivery_requests/$did')
          .get()
          .timeout(const Duration(seconds: 4));
      if (snap.exists && snap.value is Map) {
        final fresh = _asStringDynamicMap(snap.value);
        if (fresh != null) {
          debugPrint(
            'DELIVERY_OFFER_FRESH_READ_SUCCESS deliveryId=$did source=$source',
          );
          payloadData = Map<String, dynamic>.from(payloadData)
            ..addAll(fresh)
            ..['delivery_id'] = did
            ..['__nexride_request_kind'] = 'delivery'
            ..['request_kind'] = 'delivery'
            ..['service_type'] = 'dispatch_delivery'
            ..['__nexride_from_offer_queue'] = true;
          final freshReject =
              _popupServerSkipReasonDeliveryOffer(did, payloadData);
          if (freshReject != null) {
            debugPrint(
              'DELIVERY_OFFER_REJECTED deliveryId=$did reason=$freshReject source=$source',
            );
            await _removeStaleOfferQueueEntry(did, isDelivery: true);
            return null;
          }
        }
      }
    } catch (error) {
      debugPrint(
        'DELIVERY_OFFER_FRESH_READ_FAIL deliveryId=$did source=$source error=$error',
      );
    }

    return payloadData;
  }

  Future<Map<String, dynamic>?> _loadFreshOfferRequestForOfferPopup(
    String offerId, {
    required String source,
    Map<String, dynamic>? queuePayload,
  }) async {
    final cached = _driverOfferRideCache[offerId.trim()];
    if (_isDeliveryOfferQueuePayload(queuePayload) ||
        _isDeliveryOfferData(cached) ||
        _isDeliveryOfferData(queuePayload)) {
      return _loadFreshDeliveryRequestForOfferPopup(
        offerId,
        source: source,
        queuePayload: queuePayload ?? cached,
      );
    }
    return _loadFreshRideRequestForOfferPopup(offerId, source: source);
  }

  Future<void> _purgeDriverOfferLeasesForRide(String rideId) async {
    final rid = rideId.trim();
    final uid = (_driverOfferQueueBoundUid ?? _effectiveDriverId).trim();
    if (rid.isEmpty || uid.isEmpty) {
      return;
    }
    try {
      final snap = await rtdb.FirebaseDatabase.instance
          .ref('driver_offer_leases/$uid')
          .get()
          .timeout(const Duration(seconds: 4));
      if (!snap.exists || snap.value is! Map) {
        return;
      }
      final leases = Map<String, dynamic>.from(snap.value as Map);
      for (final entry in leases.entries) {
        final lease = _asStringDynamicMap(entry.value);
        if (lease == null) {
          continue;
        }
        final leaseRideId = _valueAsText(
          lease['ride_id'] ?? lease['rideId'] ?? entry.key,
        ).trim();
        if (leaseRideId == rid || entry.key.trim() == rid) {
          await rtdb.FirebaseDatabase.instance
              .ref('driver_offer_leases/$uid/${entry.key}')
              .remove();
        }
      }
    } catch (error) {
      debugPrint(
        'DRIVER_OFFER_LEASE_PURGE_FAIL rideId=$rid driverId=$uid error=$error',
      );
    }
  }

  Future<void> _removeStaleOfferQueueEntry(
    String rideId, {
    bool? isDelivery,
  }) async {
    final rid = rideId.trim();
    if (rid.isEmpty) {
      return;
    }
    final delivery =
        isDelivery ?? _isDeliveryOfferData(_driverOfferRideCache[rid]);
    _driverOfferQueueReplica.remove(rid);
    _driverOfferRideCache.remove(rid);
    final uid = (_driverOfferQueueBoundUid ?? _effectiveDriverId).trim();
    if (uid.isEmpty) {
      return;
    }
    try {
      final queuePath = delivery
          ? 'delivery_offer_queue/$uid/$rid'
          : 'driver_offer_queue/$uid/$rid';
      await rtdb.FirebaseDatabase.instance.ref(queuePath).remove();
      if (!delivery) {
        await _purgeDriverOfferLeasesForRide(rid);
      }
    } catch (error) {
      debugPrint(
        'DRIVER_OFFER_QUEUE_PURGE_FAIL offerId=$rid driverId=$uid '
        'isDelivery=$delivery error=$error',
      );
    }
  }

  Map<String, dynamic> _buildValidOfferQueueReplica(Map<String, dynamic> raw) {
    final valid = <String, dynamic>{};
    for (final entry in raw.entries) {
      final rideId = entry.key.toString().trim();
      if (rideId.isEmpty) {
        continue;
      }
      final rawOffer = _asStringDynamicMap(entry.value);
      final rideData = _rideDataFromDriverOfferQueue(rideId, rawOffer);
      if (rideData == null) {
        continue;
      }
      if (_rideExpiredWithOfferGrace(rideData)) {
        _offerDiscoveryLog('OFFER_EXPIRED', rideId: rideId);
        unawaited(_removeStaleOfferQueueEntry(rideId));
        continue;
      }
      valid[rideId] = entry.value;
      _driverOfferRideCache[rideId] = rideData;
    }
    return valid;
  }

  bool _offerQueueEntryBypassesLocalDedup(String rideId) {
    final rid = rideId.trim();
    return rid.isNotEmpty && _driverOfferQueueReplica.containsKey(rid);
  }

  Future<void> _presentOfferDirectFromQueue(
    String rideId,
    dynamic rawOffer, {
    required String source,
    required int listenerToken,
  }) async {
    if (listenerToken != _rideRequestListenerToken) {
      return;
    }
    if (!_isOnline || _isDisposing) {
      debugPrint(
        'DRIVER_OFFER_POPUP_SKIPPED rideId=$rideId reason=driver_offline source=$source',
      );
      return;
    }
    debugPrint(
      'DRIVER_OFFER_POPUP_RECEIVED rideId=$rideId source=$source listenerToken=$listenerToken',
    );
    if (_hasActiveJobBlockingNewOffers(incomingOfferId: rideId)) {
      _logNewOfferSuppressed(rideId, 'active_trip_blocked');
      _logActiveJobOfferBlocked(rideId, source: source);
      debugPrint(
        'DRIVER_OFFER_POPUP_SKIPPED rideId=$rideId reason=active_trip_blocked source=$source',
      );
      return;
    }
    final rawMap = _asStringDynamicMap(rawOffer) ?? <String, dynamic>{};
    if (rawMap.isEmpty) {
      debugPrint(
        'DRIVER_OFFER_POPUP_SKIPPED rideId=$rideId reason=payload_not_map source=$source',
      );
      return;
    }
    final leaseReject = DriverOfferLeaseSupport.rejectReason(
      offer: rawMap,
      rideId: rideId,
      serverNowMs: DateTime.now().millisecondsSinceEpoch,
      activeAcceptedRideId: _firstNonEmptyText(<dynamic>[
        _driverActiveRideId,
        _currentRideId,
      ]),
    );
    if (leaseReject != null &&
        leaseReject != 'active_trip_other_ride' &&
        leaseReject != 'lease_missing') {
      debugPrint(
        'OFFER_POPUP_DISCARDED_STALE rideId=$rideId reason=$leaseReject source=$source',
      );
      unawaited(_removeStaleOfferQueueEntry(rideId));
      return;
    }
    final rideData = _rideDataFromDriverOfferQueue(rideId, rawMap);
    if (rideData == null) {
      debugPrint(
        'DRIVER_OFFER_POPUP_SKIPPED rideId=$rideId reason=payload_not_map source=$source',
      );
      return;
    }
    final freshRide = await _loadFreshOfferRequestForOfferPopup(
      rideId,
      source: source,
      queuePayload: rawMap,
    );
    if (freshRide == null) {
      return;
    }
    rideData.addAll(freshRide);
    if (_rideExpiredWithOfferGrace(rideData)) {
      _offerDiscoveryLog('OFFER_EXPIRED', rideId: rideId);
      await _removeStaleOfferQueueEntry(rideId);
      return;
    }
    final serverSkip = _popupServerSkipReason(
      rideId,
      rideData,
      marketDiscoveryStage: false,
    );
    if (serverSkip != null) {
      debugPrint(
        'DRIVER_OFFER_POPUP_SKIPPED rideId=$rideId reason=$serverSkip source=$source',
      );
      return;
    }
    if (!_offerQueueEntryBypassesLocalDedup(rideId)) {
      final localSkip = _popupLocalSkipReason(rideId);
      if (localSkip != null) {
        debugPrint(
          'DRIVER_OFFER_POPUP_SKIPPED rideId=$rideId reason=$localSkip source=$source',
        );
        return;
      }
    } else {
      _handledRideIds.remove(rideId.trim());
      _timedOutRideIds.remove(rideId.trim());
      _declinedRideIds.remove(rideId.trim());
    }
    final matched = _matchRideForPopup(
      rideId,
      rideData,
      ignoreLocalState: true,
      logSkips: false,
      marketDiscoveryCandidate: false,
    );
    if (matched == null) {
      debugPrint(
        'DRIVER_OFFER_POPUP_SKIPPED rideId=$rideId reason=match_build_failed source=$source',
      );
      return;
    }
    _pinPendingOfferPopupRideId(rideId);
    if (_popupOpen || _hasActivePopup) {
      _logNewOfferSuppressed(rideId, 'popup_busy');
      _enqueueRideRequestPopupIfIdleSlot(matched);
      _logDriverOfferQueueDrained(
        nextCount: _rideRequestPopupQueue.length,
        source: 'queued:$source',
      );
      return;
    }
    _currentCandidateRideId = rideId;
    _logDriverOfferPopupShow(rideId, source: 'driver_offer_queue');
    if (_ridePopupOpenPipelineLocked) {
      _enqueueRideRequestPopupIfIdleSlot(matched);
      return;
    }
    _ridePopupOpenPipelineLocked = true;
    try {
      await showRideRequestPopup(matched);
    } finally {
      _ridePopupOpenPipelineLocked = false;
    }
  }

  Future<void> _handleDriverOfferQueueChildEvent(
    rtdb.DatabaseEvent event, {
    required String type,
    required int listenerToken,
    required String source,
  }) async {
    final key = event.snapshot.key?.trim();
    if (key == null || key.isEmpty) {
      return;
    }
    _recordOfferListenerEvent(type: type, rideId: key);
    _logDriverOfferQueueEvent(key, type: type, source: source);
    if (type == 'child_removed') {
      _offerDiscoveryLog('OFFER_REMOVED', rideId: key);
      _driverOfferQueueReplica.remove(key);
      _driverOfferRideCache.remove(key);
      final dismissPopup = (_popupOpen || _hasActivePopup) &&
          _activePopupRideId?.trim() == key &&
          _acceptingPopupRideId != key;
      _clearOfferPopupState(
        reason: 'offer_queue_child_removed',
        rideId: key,
        dismissVisibleDialog: dismissPopup,
        clearCurrentRidePointer: true,
      );
      if (_isOnline) {
        unawaited(
          _resumeDriverOfferListenersAfterTerminal(
            source: 'offer_queue_child_removed',
            rideId: key,
          ),
        );
      }
      return;
    }
    final rawOffer = event.snapshot.value;
    if (rawOffer == null) {
      _driverOfferQueueReplica.remove(key);
      _driverOfferRideCache.remove(key);
      return;
    }
    _driverOfferQueueReplica[key] = rawOffer;
    _releaseRidePopupSessionBlocks(key);
    await _presentOfferDirectFromQueue(
      key,
      rawOffer,
      source: source,
      listenerToken: listenerToken,
    );
  }

  void _logDeliveryOfferListenerAttach(String uid, {required String reason}) {
    debugPrint(
      'DELIVERY_OFFER_LISTENER_ATTACH driverId=$uid '
      'path=delivery_offer_queue/$uid reason=$reason',
    );
  }

  void _logDriverOfferQueueEvent(
    String rideId, {
    required String type,
    String source = '',
  }) {
    debugPrint(
      'DRIVER_OFFER_QUEUE_EVENT type=$type rideId=$rideId'
      '${source.isEmpty ? '' : ' source=$source'}',
    );
  }

  void _logDriverOfferEventReceived(
    String rideId, {
    required String source,
    String? detail,
  }) {
    final type = detail != null && detail.contains('type=')
        ? detail.split('type=').last.split(' ').first
        : source;
    _logDriverOfferQueueEvent(rideId, type: type, source: source);
    debugPrint(
      'DRIVER_OFFER_LISTENER_EVENT rideId=$rideId source=$source'
      '${detail == null || detail.isEmpty ? '' : ' $detail'}',
    );
    debugPrint(
      'DRIVER_OFFER_EVENT_RECEIVED rideId=$rideId source=$source'
      '${detail == null || detail.isEmpty ? '' : ' $detail'}',
    );
  }

  void _logDeliveryOfferEvent(String deliveryId, {required String source}) {
    debugPrint(
      'DELIVERY_OFFER_EVENT deliveryId=$deliveryId source=$source',
    );
  }

  void _logDriverOfferPopupShow(String rideId, {String? source}) {
    debugPrint(
      'DRIVER_OFFER_POPUP_SHOW rideId=$rideId'
      '${source == null || source.isEmpty ? '' : ' source=$source'}',
    );
  }

  void _logDeliveryOfferPopupShow(String deliveryId, {String? source}) {
    debugPrint(
      'DELIVERY_OFFER_POPUP_SHOW deliveryId=$deliveryId'
      '${source == null || source.isEmpty ? '' : ' source=$source'}',
    );
  }

  void _logDriverOfferPopupSuppressed(String rideId, String reason) {
    debugPrint(
      'DRIVER_OFFER_POPUP_SUPPRESSED rideId=$rideId reason=$reason',
    );
    debugPrint(
      'DRIVER_OFFER_POPUP_SKIPPED rideId=$rideId reason=$reason',
    );
  }

  void _releaseOfferPopupLifecycleIfBlocked({
    required String rideId,
    required String reason,
  }) {
    if (_popupLifecycleState == _DriverPopupLifecycleState.idle) {
      return;
    }
    _setPopupLifecycleState(
      _DriverPopupLifecycleState.idle,
      rideId: rideId,
      reason: reason,
    );
  }

  void _suppressRideOfferPopup(String rideId, String reason) {
    _logDriverOfferPopupSuppressed(rideId, reason);
    _clearPendingOfferPopupRideId(rideId);
    _releaseOfferPopupLifecycleIfBlocked(rideId: rideId, reason: reason);
  }

  Map<String, dynamic>? _offerPlaceGeoFromPayload(
    Map<String, dynamic> offer,
    String nestedKey,
    String prefix,
  ) {
    final nested = _asStringDynamicMap(offer[nestedKey]);
    if (nested != null && nested.isNotEmpty) {
      final lat = _asDouble(nested['lat']) ?? _asDouble(nested['latitude']);
      final lng = _asDouble(nested['lng']) ?? _asDouble(nested['longitude']);
      if (lat != null &&
          lng != null &&
          lat.isFinite &&
          lng.isFinite &&
          lat >= -90 &&
          lat <= 90 &&
          lng >= -180 &&
          lng <= 180) {
        return <String, dynamic>{
          ...nested,
          'lat': lat,
          'lng': lng,
        };
      }
    }
    final lat = _asDouble(offer['${prefix}_lat']) ??
        _asDouble(offer['${prefix}Lat']);
    final lng = _asDouble(offer['${prefix}_lng']) ??
        _asDouble(offer['${prefix}Lng']);
    if (lat != null &&
        lng != null &&
        lat.isFinite &&
        lng.isFinite &&
        lat >= -90 &&
        lat <= 90 &&
        lng >= -180 &&
        lng <= 180) {
      return <String, dynamic>{'lat': lat, 'lng': lng};
    }
    return nested;
  }

  Future<void> _primeDriverOfferQueueFromRtdb({
    required String source,
    String focusRideId = '',
  }) async {
    await _primeOfferQueuesFromRtdb(
      source: source,
      focusRideId: focusRideId,
    );
  }

  /// Re-read per-driver offer queues after background/resume (RTDB child events may have been missed).
  Future<void> _primeOfferQueuesFromRtdb({
    required String source,
    String focusRideId = '',
    String focusDeliveryId = '',
    bool primeRideQueue = true,
    bool primeDeliveryQueue = true,
  }) async {
    if (!_isOnline || _isDisposing) {
      return;
    }
    if (_hasActiveJobBlockingNewOffers(incomingOfferId: focusRideId.trim())) {
      debugPrint(
        'DRIVER_OFFER_PRIME_SKIP source=$source reason=active_trip_blocked '
        'activeRide=${_currentRideId ?? _driverActiveRideId ?? 'none'} '
        'activeDelivery=${_activeDeliveryId ?? 'none'}',
      );
      return;
    }
    final processor = _boundOfferQueueProcessor;
    if (processor == null) {
      unawaited(_listenForRideRequests(reason: 'prime_attach:$source'));
      return;
    }
    final uid = (_driverOfferQueueBoundUid ?? _effectiveDriverId).trim();
    if (uid.isEmpty) {
      return;
    }
    try {
      final rideFocus = focusRideId.trim();
      final deliveryFocus = focusDeliveryId.trim();
      _driverOfferQueueReplica.clear();
      if (primeRideQueue) {
        final offerQueuePath = 'driver_offer_queue/$uid';
        final snap = await runRtdbQueryGet(
          query: rtdb.FirebaseDatabase.instance.ref(offerQueuePath),
          path: offerQueuePath,
          source: 'driver_map.prime_offer_queue',
        );
        final raw = snap.value;
        if (raw is Map) {
          final validReplica = _buildValidOfferQueueReplica(
            Map<String, dynamic>.from(raw),
          );
          _driverOfferQueueReplica.addAll(validReplica);
          if (rideFocus.isNotEmpty && validReplica.containsKey(rideFocus)) {
            await _presentOfferDirectFromQueue(
              rideFocus,
              validReplica[rideFocus],
              source: 'prime:$source',
              listenerToken: _rideRequestListenerToken,
            );
            return;
          }
        } else {
          _driverOfferQueueReplica.clear();
        }
      }
      if (primeDeliveryQueue) {
        final deliveryQueuePath = 'delivery_offer_queue/$uid';
        final deliverySnap = await runRtdbQueryGet(
          query: rtdb.FirebaseDatabase.instance.ref(deliveryQueuePath),
          path: deliveryQueuePath,
          source: 'driver_map.prime_delivery_offer_queue',
        );
        final deliveryRaw = deliverySnap.value;
        if (deliveryRaw is Map) {
          for (final entry in deliveryRaw.entries) {
            final deliveryId = entry.key.toString().trim();
            if (deliveryId.isEmpty) {
              continue;
            }
            if (deliveryFocus.isNotEmpty && deliveryId != deliveryFocus) {
              continue;
            }
            _driverOfferQueueReplica[deliveryId] = entry.value;
          }
        }
      }
      if (_driverOfferQueueReplica.isEmpty) {
        debugPrint('DRIVER_OFFER_QUEUE_EMPTY driverId=$uid source=$source');
        return;
      }
      if (processor == null) {
        return;
      }
      await processor(
        Map<String, dynamic>.from(_driverOfferQueueReplica),
        source: 'prime_$source',
      );
      _syncOfferListenerDebugCounts();
    } catch (error, stackTrace) {
      debugPrint(
        'DRIVER_OFFER_PRIME_FAIL source=$source uid=$uid error=$error',
      );
      debugPrintStack(
        stackTrace: stackTrace,
        label: 'DRIVER_OFFER_PRIME_FAIL uid=$uid',
      );
      rethrow;
    }
  }

  /// Applies FCM-captured offer IDs once listeners are online (cold start / resume).
  Future<void> _consumePendingOfferLaunchIntent({
    required String source,
    String overrideRideId = '',
    String overrideDeliveryId = '',
  }) async {
    final store = DriverPendingOfferLaunchStore.instance;
    final rideId = overrideRideId.trim().isNotEmpty
        ? overrideRideId.trim()
        : (store.peekRideRequestId()?.trim() ?? '');
    final deliveryId = overrideDeliveryId.trim().isNotEmpty
        ? overrideDeliveryId.trim()
        : (store.peekDeliveryRequestId()?.trim() ?? '');
    if (rideId.isEmpty && deliveryId.isEmpty) {
      return;
    }
    debugPrint(
      'DRIVER_RESUME_LISTENERS source=$source '
      'pendingRide=${rideId.isEmpty ? 'none' : rideId} '
      'pendingDelivery=${deliveryId.isEmpty ? 'none' : deliveryId} '
      'online=$_isOnline listenerAttached=${_rideRequestSubscription != null}',
    );
    if (!_isOnline) {
      final pendingId = rideId.isNotEmpty ? rideId : deliveryId;
      _logDriverOfferPopupSuppressed(pendingId, 'offline');
      return;
    }
    if (_hasActiveJobBlockingNewOffers()) {
      _logActiveJobOfferBlocked(
        rideId.isNotEmpty ? rideId : deliveryId,
        source: 'pending_launch_$source',
      );
      return;
    }
    if (_rideRequestSubscription == null) {
      await _listenForRideRequests(reason: 'pending_launch:$source');
    }
    await _primeOfferQueuesFromRtdb(
      source: 'pending_launch_$source',
      focusRideId: rideId,
      focusDeliveryId: deliveryId,
      primeRideQueue: rideId.isNotEmpty,
      primeDeliveryQueue: deliveryId.isNotEmpty,
    );
    store.clearPendingLaunchIntent();
  }

  Future<void> _logDriverOfferQueueSnapshot({
    required String driverId,
    required rtdb.DatabaseReference queueRef,
    String source = 'attach',
  }) async {
    final uid = driverId.trim();
    if (uid.isEmpty) {
      return;
    }
    final queuePath = queueRef.path;
    final snap = await runRtdbQueryGetOrNull(
      query: queueRef,
      path: queuePath,
      source: 'driver_map.offer_queue_snapshot',
    );
    if (snap == null) {
      debugPrint(
        'DRIVER_OFFER_QUEUE_SNAPSHOT driverId=$uid count=0 keys=[] '
        'path=$queuePath source=$source',
      );
      return;
    }
    final raw = snap.value;
    var count = 0;
    final keys = <String>[];
    if (raw is Map) {
      count = raw.length;
      keys.addAll(raw.keys.map((k) => k.toString()));
      keys.sort();
    }
    debugPrint(
      'DRIVER_OFFER_QUEUE_SNAPSHOT driverId=$uid count=$count '
      'keys=[${keys.join(",")}] source=$source path=$queuePath',
    );
    if (count > 0) {
      unawaited(_primeDriverOfferQueueFromRtdb(source: 'snapshot_$source'));
    }
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
    if (isRealtimeDatabasePermissionDenied(error) ||
        code == 'permission-denied') {
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

  void _logCanonicalRideEvent({
    required String eventName,
    required String rideId,
    Map<String, dynamic>? rideData,
  }) {
    final status = rideData == null ? '' : _valueAsText(rideData['status']);
    final tripState =
        rideData == null ? '' : _valueAsText(rideData['trip_state']);
    final driverId =
        rideData == null ? '' : _valueAsText(rideData['driver_id']);
    _logRideReq(
      '[MATCH_EVENT] event=$eventName rideId=$rideId status=$status '
      'trip_state=$tripState driver_id=$driverId',
    );
  }

  void _logDriverReq(String message) {
    dispatchVerboseLog('[DRIVER_REQ] $message');
  }

  String _driverWhatsAppSupportCity() {
    final dispatchMarket = (_rolloutDispatchMarketId ?? '').trim();
    if (dispatchMarket.isNotEmpty) {
      return dispatchMarket;
    }
    final driverCity = (_driverCity ?? '').trim();
    if (driverCity.isNotEmpty) {
      return driverCity;
    }
    final profile = _lastDriverProfileSnapshot;
    if (profile != null) {
      final rolloutMarket =
          profile['rollout_dispatch_market_id']?.toString().trim() ?? '';
      if (rolloutMarket.isNotEmpty) {
        return rolloutMarket;
      }
      final serviceAreaCity =
          profile['service_area_city']?.toString().trim() ?? '';
      if (serviceAreaCity.isNotEmpty) {
        return serviceAreaCity;
      }
      final market = profile['market']?.toString().trim() ?? '';
      if (market.isNotEmpty) {
        return market;
      }
      final city = profile['city']?.toString().trim() ?? '';
      if (city.isNotEmpty) {
        return city;
      }
    }
    return 'Unknown';
  }

  String _driverWhatsAppTripId() {
    final deliveryId = (_activeDeliveryId ?? '').trim();
    if (deliveryId.isNotEmpty) {
      return deliveryId;
    }
    final rideId =
        (_currentRideId ?? _driverActiveRideId ?? _sessionTrackedRideId ?? '')
            .trim();
    return rideId.isEmpty ? 'N/A' : rideId;
  }

  Future<void> _openWhatsAppSupportFromDriverMap({
    required String sourceScreen,
    String? tripType,
    String? paymentStatus,
    String? tripStatus,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? _effectiveDriverId;
    if (!mounted) {
      return;
    }
    final deliveryId = (_activeDeliveryId ?? '').trim();
    final rideId =
        (_currentRideId ?? _driverActiveRideId ?? _sessionTrackedRideId ?? '')
            .trim();
    final tripId = _driverWhatsAppTripId();
    final initialCategory = sourceScreen == 'payment_review'
        ? 'Payment Issue'
        : (sourceScreen == 'wallet' || sourceScreen == 'earnings'
            ? 'Wallet / Earnings'
            : 'Trip Issue');
    await HelpSupportNavigation.openDriver(
      context,
      userId: uid,
      city: _driverWhatsAppSupportCity(),
      rideId: rideId.isEmpty ? null : rideId,
      tripId: tripId == 'N/A' ? (deliveryId.isEmpty ? null : deliveryId) : tripId,
      driverId: uid,
      initialCategory: initialCategory,
    );
  }

  void _logReqDebug(String message) {
    dispatchVerboseLog('[REQ_DEBUG] $message');
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
      return runRtdbQueryGet(
        query: _rideRequestsRef.child(normalized),
        path: 'ride_requests/$normalized',
        source: 'driver_map.$op',
      );
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
      return await runRtdbQueryGet(
        query: _rideRequestsRef.child(normalized),
        path: 'ride_requests/$normalized',
        source: 'driver_map.$op.resume_after_pause',
      );
    } finally {
      if (conflictingListener && mounted && _isValidRideId(normalized)) {
        _logRideReq(
          '[MATCH_DEBUG][QUERY_ATTACH:ride_requests/$normalized] op=$op resume_onvalue',
        );
        await _listenToActiveRide(normalized);
      }
    }
  }

  void _logPopupFix(String message) {
    dispatchVerboseLog('[POPUP_FIX] $message');
  }

  /// Popup pipeline (filter logcat by [POPUP]); messages kept stable for QA scripts.
  void _logPopup(String message) {
    _log('[POPUP] $message');
  }

  void _logRidePopup(String message) {
    dispatchVerboseLog('[RIDE_POPUP] $message');
  }

  void _pinPendingOfferPopupRideId(String rideId) {
    final id = rideId.trim();
    if (id.isEmpty) {
      return;
    }
    _pendingOfferPopupRideId = id;
    _backendTrustedOfferRideIds.add(id);
  }

  bool _isBackendTrustedOffer(
    String rideId, [
    Map<String, dynamic>? rideData,
  ]) {
    final id = rideId.trim();
    if (id.isEmpty) {
      return false;
    }
    if (rideData != null && rideData['__nexride_from_offer_queue'] == true) {
      return true;
    }
    if (_backendTrustedOfferRideIds.contains(id)) {
      return true;
    }
    if (_driverOfferRideCache.containsKey(id)) {
      return true;
    }
    if (_driverOfferQueueReplica.containsKey(id)) {
      return true;
    }
    if (_pendingOfferPopupRideId?.trim() == id &&
        _popupLifecycleState != _DriverPopupLifecycleState.idle) {
      return true;
    }
    if (_activePopupRideId?.trim() == id &&
        _popupLifecycleState != _DriverPopupLifecycleState.idle) {
      return true;
    }
    return false;
  }

  bool get _discoveryRebindFrozen =>
      _popupLifecycleState != _DriverPopupLifecycleState.idle;

  void _setPopupLifecycleState(
    _DriverPopupLifecycleState next, {
    String? rideId,
    String? reason,
  }) {
    if (next == _DriverPopupLifecycleState.idle) {
      _clearPopupVisibilityFlags();
      _popupLifecycleStaleResetTimer?.cancel();
      _popupLifecycleStaleResetTimer = null;
      _activePopupRideId = null;
      _acceptingPopupRideId = null;
    }
    if (_popupLifecycleState == next) {
      return;
    }
    _logRideReq(
      'popup_state ${_popupLifecycleState.name} -> ${next.name} '
      'rideId=${rideId ?? _activePopupRideId ?? 'none'} reason=${reason ?? ''}',
    );
    _popupLifecycleState = next;
    _popupLifecycleStaleResetTimer?.cancel();
    _popupLifecycleStaleResetTimer = null;
    if (next != _DriverPopupLifecycleState.idle) {
      _popupLifecycleStaleResetTimer = Timer(
        _kPopupLifecycleStaleResetDuration,
        () {
          if (!mounted || _popupLifecycleState == _DriverPopupLifecycleState.idle) {
            return;
          }
          final staleRideId =
              (_activePopupRideId ?? rideId ?? _pendingOfferPopupRideId ?? '')
                  .trim();
          _logRideReq(
            'popup_state stale_reset rideId=${staleRideId.isEmpty ? 'none' : staleRideId} '
            'from=${_popupLifecycleState.name}',
          );
          _popupOpen = false;
          _hasActivePopup = false;
          _activePopupRideId = null;
          _pendingOfferPopupRideId = null;
          _acceptingPopupRideId = null;
          _setPopupLifecycleState(
            _DriverPopupLifecycleState.idle,
            rideId: staleRideId.isEmpty ? null : staleRideId,
            reason: 'stale_lifecycle_reset',
          );
          if (_isOnline) {
            _scheduleDiscoveryRearmWhenIdle('stale_popup_lifecycle_reset');
          }
        },
      );
    }
  }

  Map<String, dynamic> _stampBackendOfferPayload(
    String rideId,
    Map<String, dynamic> payload,
  ) {
    final stamped = Map<String, dynamic>.from(payload)
      ..['__nexride_from_offer_queue'] = true
      ..[RtdbRideRequestFields.rideId] = rideId;
    final offerMarket = _normalizeRideMarket(
      stamped['canonical_market_id'] ??
          stamped['dispatch_market_id'] ??
          stamped['market_pool'] ??
          stamped['market'],
    );
    if (offerMarket != null && offerMarket.isNotEmpty) {
      stamped['canonical_market_id'] = offerMarket;
      stamped['dispatch_market_id'] = offerMarket;
      stamped['market_pool'] = offerMarket;
      stamped['market'] = offerMarket;
    }
    return stamped;
  }

  void _clearPendingOfferPopupRideId(String rideId) {
    final id = rideId.trim();
    if (id.isEmpty) {
      return;
    }
    if (_pendingOfferPopupRideId?.trim() == id) {
      _pendingOfferPopupRideId = null;
    }
  }

  bool _popupCandidateRideIdMatches(String rideId) {
    final id = rideId.trim();
    if (id.isEmpty) {
      return false;
    }
    return _currentCandidateRideId?.trim() == id ||
        _pendingOfferPopupRideId?.trim() == id;
  }

  /// Rider → RTDB → driver discovery chain (filter logcat by `[DISCOVERY]`).
  void _logDiscoveryChain(String message) {
    dispatchVerboseLog('[DISCOVERY] $message');
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
    dispatchVerboseLog('[RideCall] $message');
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
    if (!_isOnline || _loggedWaitingForFreshRides) {
      return;
    }

    _loggedWaitingForFreshRides = true;
    _logRtdb('listener still active waiting_for_fresh_rides');
  }

  String _idleNoValidActiveRideClearKey() {
    final normalizedCity =
        (_driverCity ?? '').trim().toLowerCase();
    return 'idle:${_isOnline ? 'online' : 'offline'}:$normalizedCity';
  }

  void _resetIdleRideClearDedup({String? source}) {
    _lastNoValidActiveRideClearKey = null;
    _completedStaleRidePurgeKey = null;
    _pendingStaleRidePurgeKey = null;
    _loggedWaitingForFreshRides = false;
    if (source != null && source.isNotEmpty) {
      _logValidation('idle ride clear dedup reset source=$source');
    }
  }

  bool _hasTrackedActiveRideId() {
    return (_currentRideId?.trim().isNotEmpty ?? false) ||
        (_driverActiveRideId?.trim().isNotEmpty ?? false) ||
        (_sessionTrackedRideId?.trim().isNotEmpty ?? false) ||
        (_activeRideListenerRideId?.trim().isNotEmpty ?? false);
  }

  bool _isNoValidActiveRideClearReason(String reason) {
    final normalized = reason.trim().toLowerCase();
    return normalized == 'no_valid_active_ride' ||
        normalized.contains('no_valid_active_ride');
  }

  bool _alreadyClearedIdleNoValidActiveRide(String reason) {
    if (!_isNoValidActiveRideClearReason(reason)) {
      return false;
    }
    return _lastNoValidActiveRideClearKey == _idleNoValidActiveRideClearKey();
  }

  bool _shouldScheduleStaleRidePurgeFromRenderGuard({
    required String? rideId,
    required String reason,
  }) {
    if (!_isNoValidActiveRideClearReason(reason)) {
      return true;
    }
    if (_alreadyClearedIdleNoValidActiveRide(reason)) {
      return false;
    }
    if (!_hasStaleActiveTripLocalState()) {
      return false;
    }
    return true;
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
    final normalizedRideId = rideId.trim();
    if (normalizedRideId.isEmpty) {
      return;
    }
    if (_sessionTrackedRideId == normalizedRideId) {
      return;
    }
    _sessionTrackedRideId = normalizedRideId;
    _lastTripPanelHiddenReason = null;
    _resetIdleRideClearDedup(source: 'track_ride_session');
  }

  void _printRideOwnershipDebug(Map<String, dynamic>? ride) {
    final currentDriverId = _effectiveDriverId;
    // ignore: avoid_print
    dispatchVerboseLog('RTDB ride status: ${_valueAsText(ride?['status'])}');
    // ignore: avoid_print
    dispatchVerboseLog('RTDB driver_id: ${_valueAsText(ride?['driver_id'])}');
    // ignore: avoid_print
    dispatchVerboseLog('CURRENT driver: $currentDriverId');
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

    if (TripStateMachine.isTerminalTripRecord(ride)) {
      final canon = TripStateMachine.canonicalStateFromSnapshot(ride);
      if (canon == TripLifecycleState.cancelled) {
        return 'status_cancelled';
      }
      if (canon == TripLifecycleState.completed) {
        return 'status_completed';
      }
      return 'terminal_ride';
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

    if (!relaxLifecycleProof &&
        !_isCommittedActiveRideForDriver(ride, rideId: rideId ?? _currentRideId)) {
      final lifecycleProofReason = TripStateMachine.lifecycleProofReason(
        ride,
        canonicalState: canonicalState,
      );
      if (lifecycleProofReason != null) {
        return lifecycleProofReason;
      }
    }

    if (!_rideAssignedToUid(ride, _effectiveDriverId)) {
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

    if (requireTrackedRide &&
        !_isCommittedActiveRideForDriver(ride, rideId: normalizedRideId ?? _currentRideId)) {
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
    final normalizedRideId =
        rideId?.trim() ?? _currentRideId?.trim() ?? _driverActiveRideId?.trim();
    if (_isCommittedActiveRideForDriver(
      ride ?? _currentRideData,
      rideId: normalizedRideId,
    )) {
      return null;
    }
    if (rideId == null || !_isValidRideId(rideId) || ride == null) {
      return 'no_valid_active_ride';
    }

    return _activeRideInvalidReason(
      ride,
      rideId: rideId,
      requireTrackedRide: true,
    );
  }

  bool _hasOfferPopupOnlyLocalState() {
    if (_hasTrackedActiveRideId() || _currentRideData != null) {
      return false;
    }
    return _currentCandidateRideId != null ||
        _pendingOfferPopupRideId != null ||
        _activePopupRideId != null ||
        _acceptingPopupRideId != null ||
        _popupOpen ||
        _hasActivePopup;
  }

  bool _hasStaleActiveTripLocalState() {
    if (_hasOfferPopupOnlyLocalState()) {
      return false;
    }
    if (_hasTrackedActiveRideId()) {
      return true;
    }
    if (_currentRideData != null) {
      return true;
    }

    final hasRideMarkers = _markers.any((marker) {
      final markerId = marker.markerId.value;
      return markerId == 'pickup' ||
          markerId == 'destination' ||
          markerId.startsWith('stop_');
    });

    return _pickupLocation != null ||
        _destinationLocation != null ||
        _nextNavigationTarget != null ||
        _pickupAddressText.isNotEmpty ||
        _destinationAddressText.isNotEmpty ||
        _riderName != 'Rider' ||
        _riderPhone.isNotEmpty ||
        _tripWaypoints.isNotEmpty ||
        _expectedRoutePoints.isNotEmpty ||
        hasRideMarkers ||
        _polyLines.isNotEmpty ||
        _tripStarted ||
        _arrivedEnabled;
  }

  bool _hasLocalRideStateToPurge() => _hasStaleActiveTripLocalState();

  void _scheduleStaleRidePurge({
    required String? rideId,
    required String reason,
  }) {
    if (_shouldSuppressStaleRidePurge(rideId: rideId, ride: _currentRideData)) {
      _logValidation(
        'stale local ride purge suppressed rideId=${rideId ?? _currentRideId} reason=$reason',
      );
      return;
    }
    if (_isNoValidActiveRideClearReason(reason) &&
        _alreadyClearedIdleNoValidActiveRide(reason)) {
      return;
    }
    if (!_hasLocalRideStateToPurge()) {
      return;
    }

    final purgeRideId = rideId?.trim().isNotEmpty == true
        ? rideId!.trim()
        : 'no_valid_active_ride';
    final purgeKey = '$purgeRideId:$reason';
    if (_pendingStaleRidePurgeKey == purgeKey ||
        _completedStaleRidePurgeKey == purgeKey) {
      return;
    }

    _pendingStaleRidePurgeKey = purgeKey;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingStaleRidePurgeKey = null;
      if (!mounted || !_hasLocalRideStateToPurge()) {
        return;
      }
      if (_isNoValidActiveRideClearReason(reason) &&
          _alreadyClearedIdleNoValidActiveRide(reason)) {
        return;
      }
      if (_shouldSuppressStaleRidePurge(
        rideId: rideId,
        ride: _currentRideData,
      )) {
        _logValidation(
          'stale local ride purge suppressed rideId=${rideId ?? _currentRideId} reason=$reason',
        );
        return;
      }
      if (_completedStaleRidePurgeKey == purgeKey) {
        return;
      }

      _logValidation('stale local ride purged');
      _completedStaleRidePurgeKey = purgeKey;
      unawaited(_clearActiveRideState(reason: reason));
    });
  }

  bool isValidActiveRide(Map<String, dynamic>? ride) {
    return _activeRideInvalidReason(ride) == null;
  }

  bool _isRideCancellationInvalidReason(String reason) {
    final normalized = reason.trim().toLowerCase();
    return normalized == 'status_cancelled' ||
        normalized == 'terminal_ride' ||
        normalized.contains('cancel');
  }

  String _driverCancellationSnackMessage(Map<String, dynamic> rideData) {
    final by = _valueAsText(rideData['cancelled_by']).toLowerCase();
    final actor = _valueAsText(rideData['cancel_actor']).toLowerCase();
    final reason = _valueAsText(rideData['cancel_reason']).toLowerCase();
    final riderCancelled = by == 'rider' ||
        by == 'rider_user' ||
        by == 'user' ||
        actor == 'rider' ||
        actor == 'rider_user' ||
        actor == 'user' ||
        reason.contains('rider_cancel');
    if (riderCancelled) {
      return 'Trip cancelled by rider.';
    }
    if (reason.contains('timeout') || reason.contains('expired')) {
      return 'This trip timed out and was cancelled.';
    }
    return 'This trip was cancelled.';
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
    unawaited(PortalInAppNotificationService.instance.detach());
    _stopOfferListenerWatchdog();
    _popupLifecycleStaleResetTimer?.cancel();
    _popupLifecycleStaleResetTimer = null;
    DriverOfferPrimeCoordinator.instance.unregister();
    _boundOfferQueueProcessor = null;
    _boundOfferQueueListenerToken = 0;
    _cancelWaitFeeGraceTimer(reason: 'dispose');
    _cancelWaitTimerTicker();
    WidgetsBinding.instance.removeObserver(this);
    _positionStream?.cancel();
    _positionStream = null;
    _rideRequestListenerToken += 1;
    _rideRequestSubscription?.cancel();
    _rideRequestSubscription = null;
    _driverOfferQueueChildChangedSubscription?.cancel();
    _driverOfferQueueChildChangedSubscription = null;
    _driverOfferQueueChildRemovedSubscription?.cancel();
    _driverOfferQueueChildRemovedSubscription = null;
    _deliveryOfferQueueChildAddedSubscription?.cancel();
    _deliveryOfferQueueChildAddedSubscription = null;
    _deliveryOfferQueueChildRemovedSubscription?.cancel();
    _deliveryOfferQueueChildRemovedSubscription = null;
    _rideRequestsListenerBoundCity = null;
    _driverOfferQueueBoundUid = null;
    _deliveryOfferQueueBoundUid = null;
    _driverActiveRideSubscription?.cancel();
    _driverActiveRideSubscription = null;
    _activeRideSubscription?.cancel();
    _activeRideSubscription = null;
    _activeRideListenerRideId = null;
    _activeDeliverySubscription?.cancel();
    _activeDeliverySubscription = null;
    _driverActiveDeliverySubscription?.cancel();
    _driverActiveDeliverySubscription = null;
    _activeDeliveryId = null;
    _activeDeliveryData = null;
    _stopDriverChatListener();
    _callSubscription?.cancel();
    _callSubscription = null;
    _rideCallMirrorSubscription?.cancel();
    _rideCallMirrorSubscription = null;
    _incomingCallSubscription?.cancel();
    _incomingCallSubscription = null;
    _ridePopupTimer?.cancel();
    _ridePopupTimer = null;
    _activeTripUiDebounceTimer?.cancel();
    _activeTripUiDebounceTimer = null;
    unawaited(_rtdbListenerHub.cancelAll());
    _cancelPendingRouteRequests(reason: 'dispose');
    _callDurationTimer?.cancel();
    _callDurationTimer = null;
    _callRingTimeoutTimer?.cancel();
    _callRingTimeoutTimer = null;
    _callForegroundDebounceTimer?.cancel();
    _callForegroundDebounceTimer = null;
    _pendingCallForeground = null;
    _callService.phaseNotifier.removeListener(_handleCallVoicePhaseChanged);
    _callService.remotePeerJoinedNotifier.removeListener(_handleCallVoicePhaseChanged);
    _callService.remotePeerStatusNotifier.removeListener(_refreshCallOverlayEntry);
    _mapInitializationTimer?.cancel();
    _mapInitializationTimer = null;
    _removeCallOverlayEntry();
    unawaited(_deliveryCallUi.dispose());
    unawaited(_callService.dispose());
    unawaited(_stopCallRingtone());
    unawaited(_alertSoundService.dispose());
    _roadRouteService.dispose();
    _driverChatMessages.dispose();
    _driverChatUnreadNotifier.dispose();
    _mapLayerVersion.dispose();
    _mapController?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appLifecycleState = state;
    final foreground = state == AppLifecycleState.resumed;
    _callService.notifyAppLifecycleForeground(foreground);

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(_syncCallForegroundState(foreground: false));
      return;
    }

    if (state != AppLifecycleState.resumed) {
      unawaited(_syncCallForegroundState(foreground: false));
      return;
    }

    debugPrint(
      'DRIVER_RESUME_LISTENERS lifecycle=resumed online=$_isOnline '
      'listenerAttached=${_rideRequestSubscription != null} '
      'currentRideId=${_currentRideId ?? 'none'}',
    );
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
      _ensureRideDiscoverySubscriptionIfOnline(
          reason: 'lifecycle_resume_no_local_ride');
      if (_isOnline) {
        _startOfferListenerWatchdog();
      }
      return;
    }

    if (_isDriverChatOpen) {
      _startDriverChatListener(rideId, unreadOnly: false);
    } else {
      _ensureDriverChatUnreadListener(rideId);
    }
    if (_activeRideListenerRideId != rideId ||
        _activeRideSubscription == null) {
      unawaited(_listenToActiveRide(rideId));
    }
    if (_callListenerRideId != rideId || _callSubscription == null) {
      _startCallListener(rideId);
    } else {
      unawaited(_resyncCallState(rideId));
    }
    if (_isOnline && !_isDisposing) {
      _ensureContinuousOfferDiscovery(source: 'lifecycle_resume_with_ride_context');
    }
  }

  /// While online and idle, keep a single offer_queue listener attached.
  void _ensureRideDiscoverySubscriptionIfOnline({required String reason}) {
    if (!_isOnline || _isDisposing) {
      return;
    }
    if (_rideRequestSubscription != null) {
      unawaited(_primeOfferQueuesFromRtdb(source: reason));
      unawaited(_consumePendingOfferLaunchIntent(source: reason));
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
      _ingestRolloutFromProfile(profile);
      final modeRaw =
          profile['driver_availability_mode']?.toString().trim() ?? '';
      if (modeRaw.isNotEmpty) {
        if (!_isOnline &&
            (modeRaw == 'current_location' || modeRaw == 'service_area')) {
          _pendingAvailabilityMode = modeRaw;
        }
      }
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
    final verification = normalizedDriverVerification(profile['verification']);
    final goLiveBlock = evaluateDriverGoLive(
      profile,
      documentsApproved: driverVerificationCanGoOnline(verification),
    );
    return businessModel['canGoOnline'] == true &&
        goLiveBlock == DriverGoLiveBlock.none;
  }

  bool get _rolloutSelectionComplete =>
      (_rolloutRegionId ?? '').trim().isNotEmpty &&
      (_rolloutCityId ?? '').trim().isNotEmpty &&
      (_rolloutDispatchMarketId ?? '').trim().isNotEmpty;

  void _ingestRolloutFromProfile(Map<String, dynamic> profile) {
    final rr = profile['rollout_region_id']?.toString().trim() ?? '';
    final rc = profile['rollout_city_id']?.toString().trim() ?? '';
    final rd = profile['rollout_dispatch_market_id']?.toString().trim() ?? '';
    if (rr.isNotEmpty) {
      _rolloutRegionId = rr;
    }
    if (rc.isNotEmpty) {
      _rolloutCityId = rc;
    }
    if (rd.isNotEmpty) {
      _rolloutDispatchMarketId = rd;
    }
    _ingestQueuePointersFromProfile(profile);
  }

  void _ingestQueuePointersFromProfile(Map<String, dynamic> profile) {
    final queued = _firstNonEmptyText(<dynamic>[
      profile['queued_next_ride_id'],
      profile['queuedNextRideId'],
      profile['next_trip_queue'] is Map
          ? (profile['next_trip_queue'] as Map)['ride_id']
          : null,
      profile['next_trip_queue'] is Map
          ? (profile['next_trip_queue'] as Map)['rideId']
          : null,
    ]).trim();
    _queuedNextRideIdFromProfile = queued.isEmpty ? null : queued;
  }

  Future<void> _loadRolloutCatalogForDriver() async {
    if (!_hasAuthenticatedDriver) {
      return;
    }
    final loadSeq = ++_rolloutCatalogLoadSeq;
    final driverId = _effectiveDriverId.trim();
    if (mounted) {
      _setStateSafely(() {
        _rolloutCatalogLoading = true;
        _rolloutCatalogError = null;
        _rolloutBannerDismissed = false;
      });
    } else {
      _rolloutCatalogLoading = true;
      _rolloutCatalogError = null;
    }
    List<RolloutDeliveryRegionModel> regions =
        const <RolloutDeliveryRegionModel>[];
    RolloutCatalogSelection selection = const RolloutCatalogSelection();
    Object? loadError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        if (attempt > 0) {
          await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
        }
        final raw = await RideCloudFunctionsService()
            .listDeliveryRegions()
            .timeout(kRolloutCatalogCallableTimeout);
        if (raw['success'] != true) {
          throw StateError('listDeliveryRegions_failed');
        }
        regions = parseRolloutRegionsResponse(raw);
        Map<String, String>? saved;
        if (driverId.isNotEmpty) {
          try {
            saved = await DriverRolloutProfileStore.instance.fetchSelection(
              driverId,
            );
          } catch (_) {
            saved = null;
          }
        }
        if (_lastDriverProfileSnapshot != null) {
          _ingestRolloutFromProfile(_lastDriverProfileSnapshot!);
        }
        selection = mergeSavedRolloutWithCatalog(
          regions: regions,
          saved: saved ??
              <String, String>{
                if ((_rolloutRegionId ?? '').isNotEmpty)
                  DriverRolloutProfileStore.kRegionId: _rolloutRegionId!,
                if ((_rolloutCityId ?? '').isNotEmpty)
                  DriverRolloutProfileStore.kCityId: _rolloutCityId!,
                if ((_rolloutDispatchMarketId ?? '').isNotEmpty)
                  DriverRolloutProfileStore.kDispatchMarketId:
                      _rolloutDispatchMarketId!,
              },
          regionKey: DriverRolloutProfileStore.kRegionId,
          cityKey: DriverRolloutProfileStore.kCityId,
          dispatchKey: DriverRolloutProfileStore.kDispatchMarketId,
        );
        loadError = null;
        break;
      } catch (e) {
        loadError = e;
      }
    }
    if (loadSeq != _rolloutCatalogLoadSeq) {
      return;
    }
    void apply() {
      _rolloutCatalogLoading = false;
      _rolloutCatalogHydrated = true;
      _rolloutCatalogError = loadError;
      if (loadError == null) {
        _rolloutCatalog = regions;
        _rolloutRegionId = selection.regionId;
        _rolloutCityId = selection.cityId;
        _rolloutDispatchMarketId = selection.dispatchMarketId;
        _rolloutSavedAreaDisabled = selection.savedAreaDisabled;
      }
    }
    if (mounted) {
      _setStateSafely(apply);
    } else {
      apply();
    }
  }

  Future<void> _openDriverRolloutOperatingArea() async {
    if (!mounted) {
      return;
    }
    if (!_rolloutCatalogHydrated || _rolloutCatalog.isEmpty) {
      await _loadRolloutCatalogForDriver();
    }
    if (!mounted) {
      return;
    }
    await DriverRolloutOperatingAreaSheet.show(
      context,
      driverId: _effectiveDriverId,
      regions: _rolloutCatalog,
      initialRegionId: _rolloutRegionId,
      initialCityId: _rolloutCityId,
      onReloadCatalog: () async {
        final raw = await RideCloudFunctionsService()
            .listDeliveryRegions()
            .timeout(const Duration(seconds: 22));
        if (raw['success'] != true) {
          throw StateError('listDeliveryRegions_failed');
        }
        final regions = parseRolloutRegionsResponse(raw);
        if (mounted) {
          _setStateSafely(() {
            _rolloutCatalog = regions;
            _rolloutCatalogError = null;
          });
        }
        return regions;
      },
    );
    final profile = await _fetchDriverProfile(source: 'rollout_area_sheet');
    _ingestRolloutFromProfile(profile);
    final dm = (_rolloutDispatchMarketId ?? '').trim();
    if (dm.isNotEmpty) {
      await _selectLaunchCity(
        DriverServiceAreaConfig.marketForCity(dm).city,
        manual: true,
        persist: true,
      );
    }
    if (mounted) {
      _setStateSafely(() {});
    }
    _showSnackBarSafely(
      const SnackBar(content: Text('Service area saved.')),
    );
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
      _ingestRolloutFromProfile(profile);
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
    if (!mounted) {
      return;
    }
    _locationCapability = capability;
    _log(
      'location capability updated reason=$reason canBrowse=${capability.canBrowseDriverApp} canGoOnline=${capability.canGoOnline} serviceEnabled=${capability.locationServiceEnabled} permission=${capability.permission}',
    );
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
        duration: const Duration(seconds: 8),
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
                : SnackBarAction(
                    label: 'Allow',
                    onPressed: () {
                      unawaited(_requestLocationPermissionAgain());
                    },
                  ),
      ),
    );
  }

  Future<void> _requestLocationPermissionAgain() async {
    var capability = await evaluateDriverLocationCapability();
    if (capability.permission == LocationPermission.denied) {
      await Geolocator.requestPermission();
      capability = await evaluateDriverLocationCapability();
    } else if (capability.recommendOpenSettings) {
      if (capability.locationServiceEnabled) {
        await Geolocator.openAppSettings();
      } else {
        await Geolocator.openLocationSettings();
      }
      capability = await evaluateDriverLocationCapability();
    }
    await _refreshDriverLocationCapability(reason: 'location_permission_retry');
    if (!capability.canGoOnline && mounted) {
      _showDriverLocationRequirementNotice(capability.message);
    }
  }

  Widget _buildLocationPermissionBlockCard() {
    final capability = _locationCapability;
    if (capability == null || capability.canGoOnline || _isOnline) {
      return const SizedBox.shrink();
    }
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4E5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE8C878)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            capability.title,
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              color: Color(0xFF7A4E00),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            capability.message,
            style: TextStyle(
              fontSize: 13,
              height: 1.35,
              color: Colors.black.withValues(alpha: 0.78),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: <Widget>[
              TextButton(
                onPressed: _requestLocationPermissionAgain,
                child: const Text('Allow location'),
              ),
              if (capability.recommendOpenSettings)
                TextButton(
                  onPressed: () {
                    unawaited(() async {
                      if (capability.locationServiceEnabled) {
                        await Geolocator.openAppSettings();
                      } else {
                        await Geolocator.openLocationSettings();
                      }
                      await _refreshDriverLocationCapability(
                        reason: 'location_open_settings',
                      );
                    }());
                  },
                  child: const Text('Open settings'),
                ),
            ],
          ),
        ],
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
    _logRideReq(
        '[DRIVER_DISCOVERY_TRACE] snackbar_state=set_access_denied source=$source');
  }

  void _clearDiscoveryPermissionDeniedNotice({required String source}) {
    if (!_discoveryPermissionDeniedNoticeVisible) {
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    _discoveryPermissionDeniedNoticeVisible = false;
    _logRideReq(
        '[DRIVER_DISCOVERY_TRACE] snackbar_state=cleared_access_denied source=$source');
  }

  Future<Position?> _requestReadyPosition({
    Duration? positionTimeLimit,
  }) async {
    final initialCapability = await evaluateDriverLocationCapability();

    final serviceEnabled = initialCapability.locationServiceEnabled;
    if (!serviceEnabled) {
      _log(
        'DRIVER_GO_ONLINE_BLOCKED reason=location_service_disabled canGoOnline=false',
      );
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
      _log(
        'DRIVER_GO_ONLINE_BLOCKED reason=location_permission_denied permission=$permission canGoOnline=false',
      );
      _log('goOnline failed: location permission denied');
      await _refreshDriverLocationCapability(
          reason: 'go_online_permission_denied');
      _showDriverLocationRequirementNotice(
        'Allow location access to go online and receive trips in ${DriverLaunchScope.launchCitiesLabel}.',
      );
      return null;
    }

    if (permission == LocationPermission.deniedForever) {
      _log(
        'DRIVER_GO_ONLINE_BLOCKED reason=location_permission_denied_forever permission=$permission canGoOnline=false',
      );
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
    _lastDiscoveryDismissFingerprintByRideId.clear();
    _discoveryPopupCooldownUntilMs.clear();
    _loggedDriverOfferReceivedRideIds.clear();
    _rideRequestPopupQueue.clear();
    _onlineSessionStartedAt = 0;
    _lastAvailabilityIntentOnline = false;
    _sessionTrackedRideId = null;
    _driverActiveRideId = null;
    _currentRideId = null;
    _currentRideData = null;
    _currentCandidateRideId = null;
    _pendingOfferPopupRideId = null;
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

  /// Canonical dispatch market for discovery (must match backend `abuja_fct`, etc.).
  String? get _effectiveDriverMarket {
    final fromDriver = normalizeRideMarketSlug(_driverCity);
    if (fromDriver != null && fromDriver.isNotEmpty) {
      return fromDriver;
    }
    final fromSelected = normalizeRideMarketSlug(_selectedLaunchCity);
    if (fromSelected != null && fromSelected.isNotEmpty) {
      return fromSelected;
    }
    return null;
  }

  bool _isRideAcceptGraceActive(String rideId) {
    final rid = rideId.trim();
    final until = _rideAcceptGraceUntilMs;
    if (rid.isEmpty || until == null || _rideAcceptGraceRideId != rid) {
      return false;
    }
    return DateTime.now().millisecondsSinceEpoch < until;
  }

  void _startRideAcceptGrace(String rideId) {
    final rid = rideId.trim();
    if (rid.isEmpty) {
      return;
    }
    _rideAcceptGraceRideId = rid;
    _rideAcceptGraceUntilMs =
        DateTime.now().add(_kRideAcceptPropagationGrace).millisecondsSinceEpoch;
    dispatchVerboseLog('RIDE_ACCEPT_GRACE_ACTIVE rideId=$rid');
  }

  void _clearRideAcceptGrace({String? rideId}) {
    final rid = rideId?.trim();
    if (rid != null &&
        rid.isNotEmpty &&
        _rideAcceptGraceRideId != null &&
        _rideAcceptGraceRideId != rid) {
      return;
    }
    _rideAcceptGraceRideId = null;
    _rideAcceptGraceUntilMs = null;
  }

  bool _shouldIgnoreTransientRideMissing({
    required String rideId,
    Map<String, dynamic>? rideData,
  }) {
    if (_isRideAcceptGraceActive(rideId)) {
      dispatchVerboseLog('RIDE_ACCEPT_GRACE_IGNORE_MISSING rideId=$rideId');
      return true;
    }
    if (_isCommittedActiveRideForDriver(rideData, rideId: rideId)) {
      dispatchVerboseLog(
        'RIDE_ACCEPT_GRACE_IGNORE_MISSING rideId=$rideId reason=committed_local',
      );
      return true;
    }
    final localRideId = (_currentRideId ?? _driverActiveRideId ?? '').trim();
    if (localRideId == rideId.trim() &&
        (_currentRideData != null || _rideStatus == 'accepted')) {
      dispatchVerboseLog(
        'RIDE_ACCEPT_GRACE_IGNORE_MISSING rideId=$rideId reason=local_active',
      );
      return true;
    }
    return false;
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
      rideData?['canonical_market_id'] ??
          rideData?['dispatch_market_id'] ??
          rideData?['resolved_dispatch_market_id'] ??
          rideData?['market_pool'] ??
          rideData?['market'] ??
          serviceArea?['canonical_market_id'] ??
          serviceArea?['market'] ??
          rideData?['launch_market_city'] ??
          rideData?['city'],
    );
  }

  String? _canonicalDriverDispatchMarket() {
    return _normalizeRideMarket(
      _rideRequestsListenerBoundCity ??
          _effectiveDriverMarket ??
          _driverCity ??
          _selectedLaunchCity,
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
            await runInstrumentedRtdbUpdate(
              path: 'drivers/$driverId',
              source: 'resolve_driver_city_profile',
              role: 'driver',
              updates: <String, Object?>{
                'launch_market_city': savedCity,
                'updated_at': rtdb.ServerValue.timestamp,
              },
              action: (sanitized) =>
                  _driversRef.child(driverId).update(sanitized),
            );
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
          await runInstrumentedRtdbUpdate(
            path: 'drivers/$driverId',
            source: 'resolve_driver_city_gps',
            role: 'driver',
            updates: <String, Object?>{
              'launch_market_city': detectedCity,
              'updated_at': rtdb.ServerValue.timestamp,
            },
            action: (sanitized) =>
                _driversRef.child(driverId).update(sanitized),
          );
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

  void _markRatingRideHandled(String rideId, {required String source}) {
    final normalizedRideId = rideId.trim();
    if (normalizedRideId.isEmpty) {
      return;
    }
    if (!_ratingHandledRideIds.contains(normalizedRideId)) {
      _log('RATING_RIDE_HANDLED rideId=$normalizedRideId source=$source');
    }
    _ratingHandledRideIds.add(normalizedRideId);
  }

  void _closeRatingSheetSafely(BuildContext sheetContext) {
    if (!sheetContext.mounted) {
      return;
    }
    final navigator = Navigator.of(sheetContext, rootNavigator: true);
    if (navigator.canPop()) {
      _log('RATING_SHEET_CLOSE_SAFE');
      navigator.pop();
    }
  }

  void _showRatingResultSnackBarForContext(
    BuildContext parentContext,
    String message,
  ) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!parentContext.mounted) {
        return;
      }
      final messenger = ScaffoldMessenger.maybeOf(parentContext);
      if (messenger == null) {
        return;
      }
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    });
  }

  Future<void> _submitDriverRiderRatingAfterTrip({
    required BuildContext parentContext,
    required String rideId,
    required String riderId,
    required String serviceType,
    required double rating,
    required String note,
  }) async {
    _log('DRIVER_RATE_RIDER_AFTER_CLOSE rideId=$rideId riderId=$riderId');
    if (!mounted || !parentContext.mounted) {
      _log('DRIVER_RATE_RIDER_ABORT_UNMOUNTED rideId=$rideId');
      return;
    }

    _log('DRIVER_RATE_RIDER_BEFORE_CALLABLE rideId=$rideId');
    try {
      await _riderAccountabilityService.submitRiderRating(
        rideId: rideId,
        riderId: riderId,
        driverId: _effectiveDriverId,
        serviceType: serviceType,
        rating: rating,
        note: note,
      );
      _log('DRIVER_RATE_RIDER_AFTER_CALLABLE rideId=$rideId ok=true');
      if (!mounted || !parentContext.mounted) {
        _log('DRIVER_RATE_RIDER_ABORT_UNMOUNTED rideId=$rideId');
        return;
      }
      _showRatingResultSnackBarForContext(parentContext, 'Rider rating saved.');
    } catch (error) {
      _log(
        'DRIVER_RATE_RIDER_AFTER_CALLABLE rideId=$rideId ok=false error=$error',
      );
      if (!mounted || !parentContext.mounted) {
        _log('DRIVER_RATE_RIDER_ABORT_UNMOUNTED rideId=$rideId');
        return;
      }
      _log('DRIVER_RATE_RIDER_SHOW_ERROR_SAFE rideId=$rideId');
      _showRatingResultSnackBarForContext(
        parentContext,
        'Unable to save rider rating right now.',
      );
    } finally {
      _markRatingRideHandled(rideId, source: 'driver_submit_attempt');
    }
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
    dispatchVerboseLog(
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
    dispatchVerboseLog(
      '[DRIVER_BACKEND] op=rtdb_startup_read authUid=$authUid '
      'driverProfilePath=$profilePath targetPath=$path',
    );
    try {
      return await runRtdbQueryGet(
        query: query,
        path: path,
        source: 'driver_map.startup_read',
      );
    } catch (error, stackTrace) {
      dispatchVerboseLog(
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
      }
      return null;
    }
  }

  Future<void> _updateDriverRecordSafely({
    required String driverId,
    required String source,
    required Map<String, Object?> updates,
  }) async {
    try {
      await runInstrumentedRtdbUpdate(
        path: 'drivers/$driverId',
        source: source,
        role: 'driver',
        updates: updates,
        action: (sanitized) => _driversRef.child(driverId).update(sanitized),
      );
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

  void _resetCallButtonLoading({required String reason}) {
    _setStartingVoiceCall(false);
    _callJoinInFlightRideId = null;
    _logRideCall('CALL_BUTTON_LOADING_RESET reason=$reason');
  }

  void _logSafety(String message) {
    dispatchVerboseLog('[DriverSafety] $message');
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

  bool _tripStateIsAssigned(Map<String, dynamic>? ride) {
    return TripStateMachine.canonicalStateFromSnapshot(ride) ==
        TripLifecycleState.assigned;
  }

  bool _tripStateIsArrived(Map<String, dynamic>? ride) {
    return TripStateMachine.canonicalStateFromSnapshot(ride) ==
        TripLifecycleState.arrived;
  }

  bool _ridePaymentBlocksDriverCancel(Map<String, dynamic>? rideData) {
    if (rideData == null) {
      return false;
    }
    if (rideData['payment_verified'] == true) {
      return true;
    }
    final status = _valueAsText(rideData['payment_status']).toLowerCase();
    return status == 'verified' || status == 'paid';
  }

  bool _deliveryPaymentBlocksDriverCancel(Map<String, dynamic>? deliveryData) {
    if (deliveryData == null) {
      return false;
    }
    if (deliveryData['payment_verified'] == true) {
      return true;
    }
    final status = _valueAsText(deliveryData['payment_status']).toLowerCase();
    return status == 'verified' || status == 'paid';
  }

  bool _canDriverCancelActiveRide(
    String status, {
    Map<String, dynamic>? rideData,
  }) {
    if (_ridePaymentBlocksDriverCancel(rideData ?? _currentRideData)) {
      return false;
    }
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

  String _buildActiveRouteTargetKey({
    required String rideId,
    required String status,
  }) {
    final routeTargets = status == 'on_trip'
        ? _remainingTripWaypoints(_tripWaypoints)
        : (_pickupLocation == null
            ? <_TripWaypoint>[]
            : <_TripWaypoint>[
                _TripWaypoint(
                  location: _pickupLocation!,
                  address: _pickupAddressText,
                ),
              ]);
    return '$rideId|$status|${routeTargets.map((waypoint) => _latLngKey(waypoint.location)).join('|')}';
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
      'driver_offline' ||
      'driver_offline_local' =>
        'You look offline to the server. Check your connection, go online again, then try accepting.',
      'driver_unavailable' =>
        'The server still shows you as busy. Wait a few seconds and tap Accept again.',
      'driver_request_listener_missing' =>
        'Ride alerts are not connected. Go OFFLINE, then GO ONLINE again, then try accepting.',
      'driver_trip_in_progress' ||
      'driver_trip_in_progress_local' =>
        'Finish or leave your other active trip before accepting this one.',
      'driver_auth_mismatch' ||
      'missing_driver_id' =>
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
        runRtdbQueryGet(
          query: _driversRef.child(driverId),
          path: 'drivers/$driverId',
          source: 'driver_map.driver_record_read',
        ),
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
      final locAgeSec =
          lastActive > 0 ? ((nowMs - lastActive) / 1000).round() : -1;
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
      final queuedNext = _queuedNextRideIdFromProfile?.trim() ?? '';
      if (queuedNext.isEmpty) {
        return null;
      }
      if (queuedNext != rideKey) {
        return 'driver_trip_in_progress_local';
      }
      return null;
    }

    final snapshots = await Future.wait(<Future<rtdb.DataSnapshot>>[
      runRtdbQueryGet(
        query: _driversRef.child(driverId),
        path: 'drivers/$driverId',
        source: 'driver_map.driver_record_read',
      ),
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
            _pendingOfferPopupRideId?.trim() == rideKey ||
            _activePopupRideId?.trim() == rideKey ||
            _acceptingPopupRideId?.trim() == rideKey);

    if (!isAvailable && activeRideKey != rideKey) {
      if (!localReservedOrAcceptingSameRide) {
        return 'driver_unavailable';
      }
    }
    if (activeRideKey.isNotEmpty && activeRideKey != rideKey) {
      final queuedNext = _firstNonEmptyText(<dynamic>[
        driverRecord['queued_next_ride_id'],
        driverRecord['queuedNextRideId'],
        driverRecord['next_trip_queue'] is Map
            ? (driverRecord['next_trip_queue'] as Map)['ride_id']
            : null,
        driverRecord['next_trip_queue'] is Map
            ? (driverRecord['next_trip_queue'] as Map)['rideId']
            : null,
      ]).trim();
      if (queuedNext.isEmpty) {
        return null;
      }
      if (queuedNext != rideKey) {
        return 'driver_trip_in_progress';
      }
      return null;
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

  Set<String> _effectiveDriverServiceTypes() {
    final profile = _lastDriverProfileSnapshot;
    if (profile == null || profile.isEmpty) {
      return const <String>{'ride'};
    }
    final rawServiceTypes = profile['serviceTypes'] ?? profile['service_types'];
    final normalizedRequestTypes = <String>{};
    if (rawServiceTypes is List) {
      for (final rawType in rawServiceTypes) {
        final key = _serviceTypeKey(rawType);
        if (key.isNotEmpty) {
          normalizedRequestTypes.add(key);
        }
      }
    }

    final rawDriverServiceTypes =
        profile['driver_service_types'] ?? profile['driverServiceTypes'];
    if (rawDriverServiceTypes is List) {
      for (final rawType in rawDriverServiceTypes) {
        final normalized = _valueAsText(rawType).toLowerCase();
        if (normalized == 'car_driver') {
          normalizedRequestTypes.add('ride');
        } else if (normalized == 'dispatch_driver') {
          normalizedRequestTypes.add('dispatch_delivery');
        }
      }
    }

    if (normalizedRequestTypes.isEmpty) {
      normalizedRequestTypes.add('ride');
    }
    return normalizedRequestTypes;
  }

  bool _driverCanAcceptServiceType(String serviceType) {
    final normalized = _serviceTypeKey(serviceType);
    return _effectiveDriverServiceTypes().contains(normalized);
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

  String _firstNonEmptyRiderPhoto(Map<String, dynamic>? ride) {
    if (ride == null) {
      return '';
    }
    for (final String key in const <String>[
      'rider_photo_url',
      'riderPhotoUrl',
      'rider_photo',
      'rider_profile_photo_url',
    ]) {
      final value = _valueAsText(ride[key]);
      if (value.isNotEmpty) {
        return value;
      }
    }
    return '';
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
    final riderPhotoUrl = _firstNonEmptyRiderPhoto(rideData);
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
      _riderPhotoUrl = riderPhotoUrl;
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
    if (_isDriverChatOpen || _isDisposing) {
      return;
    }
    if (!_shouldRunOptionalRtdbEvent(rideId, 'route_consistency|$source')) {
      return;
    }
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
    final deliveryId = _activeDeliveryId?.trim() ?? '';
    if (deliveryId.isNotEmpty &&
        isActiveDeliveryCallEligible(
          activeDeliveryId: _activeDeliveryId,
          delivery: _activeDeliveryData,
          state: _activeDeliveryState,
          driverId: _effectiveDriverId,
        )) {
      return deliveryCallCustomerId(_activeDeliveryData).isNotEmpty;
    }
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

    if (_activeDeliveryId?.trim() == normalizedRideId &&
        isActiveDeliveryCallEligible(
          activeDeliveryId: _activeDeliveryId,
          delivery: _activeDeliveryData,
          state: _activeDeliveryState,
          driverId: driverId,
        )) {
      return deliveryCallCustomerId(_activeDeliveryData).isNotEmpty;
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

  String _customerIdForCallContext(String contextId) {
    if (_activeDeliveryId?.trim() == contextId.trim()) {
      return deliveryCallCustomerId(_activeDeliveryData);
    }
    return _currentRiderIdForRide;
  }

  bool _canWriteParticipantStateForSession(RideCallSession session) {
    if (!_isDriverAuthorizedForCallRide(rideId: session.rideId)) {
      return false;
    }

    final driverId = _effectiveDriverId;
    final riderId = _customerIdForCallContext(session.rideId);
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
    ParticipantUpdateKind updateKind = ParticipantUpdateKind.avState,
    bool force = false,
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
        updateKind: updateKind,
        force: force,
        kind: _callKindFor(normalizedRideId),
      );
      return true;
    } catch (error, stackTrace) {
      if (isRealtimeDatabasePermissionDenied(error)) {
        dispatchVerboseLog(
          'CALL_SYNC_NON_FATAL rideId=$normalizedRideId source=$source',
        );
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

    final riderId = _customerIdForCallContext(session.rideId);
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
    _incomingCallSubscription?.cancel();
    _incomingCallSubscription = null;

    if (!_canMonitorRideCalls) {
      return;
    }
    final rideId = (_activeDriverRideContextId ?? '').trim();
    if (rideId.isEmpty || !_isDriverAuthorizedForCallRide(rideId: rideId)) {
      return;
    }
    // Ride-scoped call_sessions/{rideId} only — no root /calls query.
    _startCallListener(rideId);
  }

  Future<void> _stopIncomingCallMonitoring() async {
    final rideIdForCleanup =
        _callListenerRideId ?? _currentRideId ?? _driverActiveRideId ?? '';
    if (_currentCallSession != null || rideIdForCleanup.isNotEmpty) {
      await _performLocalCallCleanup(
        rideId: rideIdForCleanup,
        cleanupSource: 'stop_incoming_call_monitoring',
        endReason: 'incoming_call_monitoring_stopped',
        logCleanup: false,
      );
    } else {
      await _stopCallRingtone();
      _removeCallOverlayEntry();
    }

    await _callSubscription?.cancel();
    _callSubscription = null;
    await _rideCallMirrorSubscription?.cancel();
    _rideCallMirrorSubscription = null;
    _callListenerRideId = null;
    await _incomingCallSubscription?.cancel();
    _incomingCallSubscription = null;
  }

  Future<void> _resyncIncomingCallState() async {
    if (!_canMonitorRideCalls) {
      return;
    }
    final rideId = (_activeDriverRideContextId ?? '').trim();
    if (rideId.isEmpty || !_isDriverAuthorizedForCallRide(rideId: rideId)) {
      return;
    }
    _startCallListener(rideId);
    if (!mounted) {
      return;
    }
    await _resyncCallState(rideId);
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

  void _startCallListener(
    String rideId, {
    CallSessionKind kind = CallSessionKind.ride,
  }) {
    if (_callListenerRideId == rideId &&
        _callSubscription != null &&
        _callListenerKind == kind) {
      _logRideCall('CALL_LISTENER_REUSED rideId=$rideId');
      return;
    }

    if (_callListenerRideId != null && _callListenerRideId != rideId) {
      RidePipelineGuard.releaseCallListener(
        rideId: _callListenerRideId!,
        owner: 'DriverMapScreen',
      );
    }
    _callSubscription?.cancel();
    _callSubscription = null;
    _rideCallMirrorSubscription?.cancel();
    _rideCallMirrorSubscription = null;
    _detachSharedCallListener();
    _callListenerRideId = rideId;
    _callListenerKind = kind;
    RidePipelineGuard.assertCallListenerAttach(
      rideId: rideId,
      owner: 'DriverMapScreen',
    );

    final path = CallService.sessionPath(rideId, kind: kind);
    debugPrint(
      'CALL_SESSION_PATH role=driver path=$path rideId=$rideId kind=${kind.name}',
    );
    _logRideReq('[MATCH_DEBUG][QUERY_ATTACH:$path] per_ride onValue');
    _callSubscription = _callService.observeCall(rideId, kind: kind).listen(
      (event) {
        if (_callListenerRideId != rideId) {
          return;
        }

        final session = RideCallSession.fromSnapshotValue(
          rideId,
          event.snapshot.value,
        );
        final statusRaw = session?.status.name ??
            (event.snapshot.value is Map
                ? _valueAsText(
                    (event.snapshot.value as Map)['status'] ??
                        (event.snapshot.value as Map)['state'],
                  )
                : 'null');
        debugPrint(
          'CALL_SESSION_SNAPSHOT path=${CallService.sessionPath(rideId, kind: kind)} '
          'rideId=$rideId status=$statusRaw listener_role=driver',
        );
        unawaited(_handleCallSnapshotUpdate(rideId, session));
      },
      onError: (Object error) {
        _logRideCall('listener error rideId=$rideId error=$error');
      },
    );

    _rideCallMirrorSubscription?.cancel();
    _rideCallMirrorSubscription =
        _callService.observeRideCallMirror(rideId, kind: kind).listen(
      (event) {
        if (_callListenerRideId != rideId) {
          return;
        }
        final value = event.snapshot.value;
        if (value is! Map) {
          return;
        }
        for (final entry in value.entries) {
          final row = entry.value;
          if (row is! Map) {
            continue;
          }
          final mirrorStatus =
              (row['status'] ?? '').toString().trim().toLowerCase();
          if (mirrorStatus != 'ended') {
            continue;
          }
          debugPrint(
            'CALL_SESSION_ENDED_SYNCED rideId=$rideId callId=${entry.key} '
            'listener_role=driver source=ride_calls',
          );
          unawaited(() async {
            final session = await _callService.fetchCall(rideId, kind: kind);
            if (session != null && session.isTerminal) {
              await _handleCallSnapshotUpdate(rideId, session);
            }
          }());
          break;
        }
      },
      onError: (Object error) {
        _logRideCall(
          'ride_calls mirror listener error rideId=$rideId error=$error',
        );
      },
    );
  }

  Future<void> _resyncCallState(String rideId) async {
    final normalizedRideId = rideId.trim();
    if (normalizedRideId.isEmpty) {
      return;
    }
    if (_callCleanupDoneRideIds.contains(normalizedRideId)) {
      final session = _currentCallSession;
      if (session == null || session.isTerminal) {
        _logRideCall(
          'CALL_LOG_LOAD_SKIPPED_DUPLICATE rideId=$normalizedRideId',
        );
        return;
      }
    }

    final resumePerRideListener =
        _callSubscription != null && _callListenerRideId == normalizedRideId;
    if (resumePerRideListener) {
      _logRideReq(
        '[MATCH_DEBUG][QUERY_DETACH:call_sessions/$normalizedRideId] resync_prefetch',
      );
      await _callSubscription?.cancel();
      _callSubscription = null;
      _callListenerRideId = null;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    _logRideReq(
      '[MATCH_DEBUG][QUERY_GET:call_sessions/$normalizedRideId] fetchCall resync',
    );
    _logRideCall('CALL_LOG_LOAD_START rideId=$normalizedRideId');
    RideCallSession? session;
    try {
      session = await _callService
          .fetchCall(normalizedRideId, kind: _callKindFor(normalizedRideId))
          .timeout(const Duration(seconds: 8));
    } on TimeoutException {
      _logRideCall(
        'CALL_LOG_LOAD_ERROR rideId=$normalizedRideId reason=timeout',
      );
      session = _currentCallSession;
    } catch (error) {
      _logRideCall(
        'CALL_LOG_LOAD_ERROR rideId=$normalizedRideId error=$error',
      );
      session = _currentCallSession;
    }
    if (!mounted) {
      return;
    }

    RideCallSession? resolvedSession = session;
    if (resolvedSession == null) {
      _logRideCall('CALL_LOG_LOAD_EMPTY rideId=$normalizedRideId');
    } else {
      _logRideCall(
        'CALL_LOG_LOAD_OK rideId=$normalizedRideId status=${resolvedSession.status.name}',
      );
    }
    if (resolvedSession == null &&
        (_callJoinedChannel || _callService.isVoiceConnected)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      try {
        resolvedSession = await _callService.fetchCall(
          normalizedRideId,
          kind: _callKindFor(normalizedRideId),
        );
      } catch (_) {
        resolvedSession = _currentCallSession;
      }
    }

    await _handleCallSnapshotUpdate(
      normalizedRideId,
      resolvedSession ?? _currentCallSession,
    );

    if (resumePerRideListener && _canMonitorRideCalls) {
      _startCallListener(normalizedRideId, kind: _callListenerKind);
    }
  }

  Future<void> _handleCallSnapshotUpdate(
    String rideId,
    RideCallSession? nextSession,
  ) async {
    final previousSession = _currentCallSession;
    final previousStatus = previousSession?.status;

    if (nextSession != null &&
        !nextSession.isTerminal &&
        !_callMatchesCurrentRide(nextSession)) {
      return;
    }

    _currentCallSession = nextSession;

    if (nextSession != null && !nextSession.isTerminal) {
      _attachSharedCallListener(nextSession);
    }

    if (nextSession != null && nextSession.isTerminal) {
      final rideKey = rideId.trim();
      _logCallTerminalSnapshotReceived(
        nextSession,
        source: 'remote_terminal',
      );
      debugPrint(
        'CALL_SESSION_TERMINAL_REMOTE rideId=$rideKey '
        'status=${nextSession.status.name} ended_by=${nextSession.endedBy ?? ''}',
      );
      _logCallTerminalObeyed(nextSession, source: 'remote_terminal');
      if (previousStatus != nextSession.status) {
        if (nextSession.status == RideCallStatus.ended) {
          _logRideCall(
            'CALL_REMOTE_ENDED_RECEIVED rideId=$rideId '
            'endedBy=${nextSession.endedBy ?? ''}',
          );
        }
        _logRideCall(
          'CALL_REMOTE_TERMINAL_RECEIVED rideId=$rideId '
          'status=${nextSession.status.name} endedBy=${nextSession.endedBy ?? ''}',
        );
      }
      await _forceCallTerminalCleanup(
        rideId: rideId,
        source: 'remote_terminal',
        endReason: 'rtdb_status_${nextSession.status.name}',
        session: nextSession,
      );
      callTraceLog(
        'CALL_END_REMOTE_CLEANUP_OK',
        rideId: rideId,
        role: 'driver',
      );
      return;
    }

    if (_callLocallyEndedRideIds.contains(rideId.trim())) {
      if (nextSession == null) {
        return;
      }
      if (nextSession.isTerminal) {
        debugPrint(
          'CALL_SESSION_TERMINAL_REMOTE rideId=${rideId.trim()} '
          'status=${nextSession.status.name} ended_by=${nextSession.endedBy ?? ''}',
        );
        _logCallTerminalSnapshotReceived(
          nextSession,
          source: 'remote_terminal_local_end_guard',
        );
        if (_shouldObeyRemoteCallTerminal(nextSession)) {
          _logCallTerminalObeyed(
            nextSession,
            source: 'remote_terminal_local_end_guard',
          );
          await _forceCallTerminalCleanup(
            rideId: rideId,
            source: 'remote_terminal_local_end_guard',
            endReason: 'rtdb_status_${nextSession.status.name}',
            session: nextSession,
          );
        }
        return;
      }
      _resetCallGuardsForNewSession(
        rideId,
        source: 'snapshot_active_after_local_end',
      );
    }

    if (nextSession == null) {
      final endedLocally =
          _callLocallyEndedRideIds.contains(rideId.trim()) ||
          _callCleanupDoneRideIds.contains(rideId);
      if (endedLocally) {
        await _performLocalCallCleanup(
          rideId: rideId,
          cleanupSource: 'call_snapshot_null_after_end',
          endReason: 'local_or_remote_end',
          logCleanup: false,
        );
        return;
      }

      _callJoinAttemptCount = 0;
      final hadCallActivity = previousSession != null ||
          _callJoinedChannel ||
          _callOverlayEntry != null ||
          _callDurationTimer != null ||
          _callRingTimeoutTimer != null;
      if (hadCallActivity) {
        RideCallSession? confirmed = previousSession;
        try {
          confirmed = await _callService.fetchCall(
            rideId,
            kind: _callKindFor(rideId),
          );
        } catch (error) {
          _logRideCall(
            'CALL_NULL_SNAPSHOT_REFETCH_FAIL rideId=$rideId error=$error',
          );
        }

        if (confirmed != null && confirmed.isTerminal) {
          _logRideCall(
            'CALL_REMOTE_TERMINAL_RECEIVED rideId=$rideId '
            'status=${confirmed.status.name} endedBy=${confirmed.endedBy ?? ''}',
          );
          await _stopCallRingtone();
          _logCallTerminalSnapshotReceived(
            confirmed,
            source: 'remote_terminal_refetch',
          );
          if (_shouldObeyRemoteCallTerminal(confirmed)) {
            _logCallTerminalObeyed(
              confirmed,
              source: 'remote_terminal_refetch',
            );
            await _forceCallTerminalCleanup(
              rideId: rideId,
              source: 'remote_terminal_refetch',
              endReason: 'rtdb_status_${confirmed.status.name}',
              session: confirmed,
            );
          }
          callTraceLog(
            'CALL_END_REMOTE_CLEANUP_OK',
            rideId: rideId,
            role: 'driver',
          );
          return;
        }

        if (confirmed != null &&
            !confirmed.isTerminal &&
            _callMatchesCurrentRide(confirmed)) {
          _logRideCall(
            'CALL_NULL_SNAPSHOT_IGNORED rideId=$rideId status=${confirmed.status}',
          );
          _currentCallSession = confirmed;
          _ensureActiveCallUiVisible(
            rideId: rideId,
            source: 'CALL_NULL_SNAPSHOT_IGNORED',
          );
          return;
        }

        if (_isCallNullGraceActive(rideId) ||
            _callJoinInFlightRideId == rideId.trim() ||
            (previousSession != null && !previousSession.isTerminal)) {
          _logRideCall(
            'CALL_NULL_SNAPSHOT_IGNORED rideId=$rideId reason=setup_grace',
          );
          _currentCallSession =
              confirmed ?? previousSession ?? _synthesizeActiveCallSession(rideId);
          return;
        }

        if ((_callJoinedChannel || _callService.isVoiceConnected) &&
            (confirmed == null || !confirmed.isTerminal) &&
            !_callLocallyEndedRideIds.contains(rideId.trim()) &&
            !_callCleanupDoneRideIds.contains(rideId)) {
          _logRideCall(
            'CALL_NULL_SNAPSHOT_DEFER_CLEANUP rideId=$rideId reason=local_voice_active',
          );
          _currentCallSession =
              confirmed ?? previousSession ?? _synthesizeActiveCallSession(rideId);
          _ensureActiveCallUiVisible(
            rideId: rideId,
            source: 'CALL_NULL_SNAPSHOT_DEFER',
          );
          return;
        }

        await _stopCallRingtone();
        await _performLocalCallCleanup(
          rideId: rideId,
          cleanupSource: 'call_snapshot_null',
          endReason: confirmed == null
              ? 'rtdb_null_or_unparseable'
              : 'rtdb_terminal_after_refetch',
          logCleanup: false,
        );
      }
      return;
    }

    if (nextSession.isRinging) {
      _extendCallNullGrace(rideId);
      _callJoinAttemptCount = 0;
      _callCleanupDoneRideIds.remove(rideId);
      _callLocallyEndedRideIds.remove(rideId);
      _scheduleCallRingTimeout(nextSession);
      _stopCallDurationTicker();
      _callAcceptedAt = null;
      _callDuration = Duration.zero;

      if (_isIncomingCall(nextSession) &&
          previousStatus != RideCallStatus.ringing) {
        callTraceLog(
          'CALL_INCOMING_RECEIVED',
          rideId: rideId,
          role: 'driver',
        );
        _logRideCall(
          'incoming call shown rideId=$rideId caller=${nextSession.callerUid}',
        );
      }

      if (_callKindFor(rideId) == CallSessionKind.delivery &&
          _isIncomingCall(nextSession)) {
        debugPrint(
          'DRIVER_DELIVERY_CALL_INCOMING deliveryId=$rideId '
          'callId=${nextSession.callId ?? rideId}',
        );
      }

      if (_isIncomingCall(nextSession)) {
        await _startCallRingtone();
      } else {
        await _stopCallRingtone();
        _logRideCall('CALL_UI_OUTGOING_SHOW rideId=$rideId source=CALL_SIGNAL_WRITE_OK');
      }

      _refreshCallOverlayEntry();
      return;
    }

    if (nextSession.isAccepted) {
      _extendCallNullGrace(rideId);
      _cancelCallRingTimeout();
      await _stopCallRingtone();

      if (previousStatus != RideCallStatus.accepted) {
        _logRideCall('call accepted rideId=$rideId');
      }

      if (!_callJoinedChannel &&
          _callJoinInFlightRideId != rideId.trim() &&
          _callJoinAttemptCount < 1) {
        final driverId = _effectiveDriverId;
        if (driverId.isNotEmpty) {
          await _joinAcceptedCall(rideId: rideId, uid: driverId);
        }
      }

      _logRideCall('CALL_UI_ACTIVE_SHOW rideId=$rideId source=accepted_session');
      if (_callService.isVoiceConnected) {
        _logRideCall('CALL_UI_ACTIVE_SHOW rideId=$rideId source=CALL_REMOTE_JOINED');
      }
      _ensureActiveCallUiVisible(
        rideId: rideId,
        source: 'accepted_session',
      );
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
  }

  Future<void> _joinAcceptedCall({
    required String rideId,
    required String uid,
  }) async {
    final normalizedRideId = rideId.trim();
    if (!_isDriverAuthorizedForCallRide(rideId: normalizedRideId)) {
      _logRideCall(
        'join skipped rideId=$normalizedRideId reason=no_owned_active_ride',
      );
      return;
    }

    if (_callJoinInFlightRideId == normalizedRideId) {
      _logRideCall('CALL_JOIN_SKIPPED_DUPLICATE rideId=$normalizedRideId');
      return;
    }
    if (_callJoinedChannel && _callService.isLocalVoiceJoined) {
      _logRideCall(
        'CALL_JOIN_SKIPPED_DUPLICATE rideId=$normalizedRideId reason=already_joined',
      );
      return;
    }
    _callJoinInFlightRideId = normalizedRideId;
    _extendCallNullGrace(normalizedRideId);
    try {
      _logRideCall('CALL_JOIN_START rideId=$normalizedRideId uid=$uid');
      await _callService.prefetchAgoraToken(
        channelId: normalizedRideId,
        uid: uid,
        forceRefresh: false,
      );
      await _callService.ensureJoinedVoiceChannel(
        channelId: normalizedRideId,
        uid: uid,
        speakerOn: _callSpeakerOn,
        muted: _callMuted,
      );
      if (_shouldAbortCallUiForRide(normalizedRideId)) {
        await _callService.leaveVoiceChannel();
        return;
      }
      await _callService.waitForVoiceJoinConnected(
        timeout: const Duration(seconds: 15),
      );
      if (_shouldAbortCallUiForRide(normalizedRideId)) {
        await _callService.leaveVoiceChannel();
        return;
      }
      _callJoinedChannel = true;
      await _updateParticipantStateSafely(
        source: 'join_accepted_call',
        rideId: normalizedRideId,
        joined: true,
        muted: _callMuted,
        speaker: _callSpeakerOn,
        foreground: _appLifecycleState == AppLifecycleState.resumed,
        updateKind: ParticipantUpdateKind.callLifecycle,
        force: true,
      );
      _logRideCall('CALL_UI_ACTIVE_SHOW rideId=$rideId source=CALL_JOIN_OK');
      _ensureActiveCallUiVisible(rideId: rideId, source: 'CALL_JOIN_OK');
    } catch (error) {
      if (_shouldAbortCallUiForRide(normalizedRideId)) {
        _callJoinedChannel = false;
        return;
      }
      _callJoinAttemptCount++;
      _logRideCall(
        '[CALL_JOIN_FAIL] rideId=$rideId attempt=$_callJoinAttemptCount error=$error',
      );
      _callJoinedChannel = false;
      _setStartingVoiceCall(false);
      final message = error is RideCallException
          ? error.message
          : 'Unable to connect the call right now.';
      if (_callJoinAttemptCount >= 3) {
        _logRideCall(
          'join retries exhausted rideId=$rideId local_only=true',
        );
      }
      _showSnackBarSafely(
        SnackBar(
          content: Text(message),
        ),
      );
    } finally {
      if (_callJoinInFlightRideId == normalizedRideId) {
        _callJoinInFlightRideId = null;
      }
    }
  }

  void _scheduleCallRingTimeout(RideCallSession session) {
    _cancelCallRingTimeout();
    final kind = _callKindFor(session.rideId);
    final defaultTimeout = kind == CallSessionKind.delivery
        ? const Duration(seconds: kDeliveryCallRingTimeoutSeconds)
        : const Duration(seconds: 30);
    final deadline = session.expiresAtDateTime ??
        (session.createdAtDateTime ?? DateTime.now()).add(defaultTimeout);
    final remaining = deadline.difference(DateTime.now());

    if (remaining <= Duration.zero) {
      unawaited(
        _callService.markMissedIfUnanswered(
          rideId: session.rideId,
          kind: kind,
        ),
      );
      return;
    }

    _callRingTimeoutTimer = Timer(
      remaining,
      () {
        unawaited(
          _callService.markMissedIfUnanswered(
            rideId: session.rideId,
            kind: kind,
          ),
        );
      },
    );
  }

  void _cancelCallRingTimeout() {
    _callRingTimeoutTimer?.cancel();
    _callRingTimeoutTimer = null;
  }

  void _startCallDurationTicker(DateTime? acceptedAt) {
    final startAt = _activeCallStartedAt ?? acceptedAt ?? DateTime.now();
    if (_activeCallStartedAt == null) {
      _activeCallStartedAt = startAt;
    }
    _callAcceptedAt = startAt;
    _stopCallDurationTicker();
    _callDuration = DateTime.now().difference(startAt);
    _callDurationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final anchor = _activeCallStartedAt ?? _callAcceptedAt;
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
    await _syncCallForegroundState(foreground: false);
  }

  Future<void> _syncCallForegroundState({
    required bool foreground,
  }) async {
    final session = _currentCallSession;
    if (session == null || session.isTerminal) {
      return;
    }

    _pendingCallForeground = foreground;
    _callForegroundDebounceTimer?.cancel();
    _callForegroundDebounceTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(_flushCallForegroundState());
    });
  }

  Future<void> _flushCallForegroundState() async {
    final foreground = _pendingCallForeground;
    if (foreground == null) {
      return;
    }

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
      updateKind: ParticipantUpdateKind.foreground,
    );
  }

  void _logCallTerminalSnapshotReceived(
    RideCallSession session, {
    required String source,
  }) {
    debugPrint(
      'CALL_TERMINAL_SNAPSHOT_RECEIVED path=call_sessions/${session.rideId} '
      'rideId=${session.rideId} status=${session.status.name} '
      'callerId=${session.callerId} receiverId=${session.receiverId} '
      'ended_by=${session.endedBy ?? ''} source=$source',
    );
  }

  void _logCallTerminalObeyed(
    RideCallSession session, {
    required String source,
  }) {
    debugPrint(
      'CALL_TERMINAL_OBEYED rideId=${session.rideId} status=${session.status.name} '
      'callerId=${session.callerId} receiverId=${session.receiverId} source=$source',
    );
  }

  void _logCallCleanupDone({
    required String rideId,
    required String source,
    required String endReason,
    RideCallSession? session,
  }) {
    final status = session?.status.name ??
        _currentCallSession?.status.name ??
        'cleared';
    final callerId =
        session?.callerId ?? _currentCallSession?.callerId ?? '';
    final receiverId =
        session?.receiverId ?? _currentCallSession?.receiverId ?? '';
    debugPrint(
      'CALL_CLEANUP_DONE rideId=$rideId status=$status callerId=$callerId '
      'receiverId=$receiverId source=$source reason=$endReason',
    );
  }

  bool _shouldAbortCallUiForRide(String rideId) {
    final normalizedRideId = rideId.trim();
    if (normalizedRideId.isEmpty) {
      return true;
    }
    if (_callCleanupDoneRideIds.contains(normalizedRideId)) {
      return true;
    }
    final session = _currentCallSession;
    if (session != null &&
        session.rideId.trim() == normalizedRideId &&
        session.isTerminal) {
      return true;
    }
    return false;
  }

  bool _shouldObeyRemoteCallTerminal(RideCallSession session) {
    // Terminal snapshots (ended/cancelled/failed/timeout) are obeyed
    // unconditionally. We must never gate local cleanup on Agora join state,
    // connecting/ringing phase, overlay visibility, or end timestamp ordering:
    // doing so left the peer stuck on the call screen when the other party
    // tapped End while still "Connecting to other party…".
    return true;
  }

  Future<void> _forceCallTerminalCleanup({
    required String rideId,
    required String source,
    String endReason = 'terminal',
    RideCallSession? session,
  }) async {
    final rideKey = rideId.trim();
    if (rideKey.isEmpty) {
      return;
    }
    debugPrint('CALL_CLEANUP_FORCE rideId=$rideKey source=$source');
    _detachSharedCallListener();
    _callNullGraceUntilByRideId.remove(rideKey);
    _callLocallyEndedRideIds.remove(rideKey);
    _callJoinAttemptCount = 0;
    await _stopCallRingtone();
    _cancelCallRingTimeout();
    _stopCallDurationTicker();
    _currentCallSession = null;
    _callAcceptedAt = null;
    _activeCallStartedAt = null;
    _callDuration = Duration.zero;
    _removeCallOverlayEntry();
    _callMuted = false;
    _callSpeakerOn = true;
    _isEndingCall = false;
    _callJoinInFlightRideId = null;
    try {
      await _callService.leaveVoiceChannel();
      debugPrint('CALL_LEAVE_CHANNEL rideId=$rideKey source=$source');
    } catch (error) {
      _logRideCall(
        'CALL_LEAVE_CHANNEL_FAIL rideId=$rideKey source=$source error=$error',
      );
    }
    _callJoinedChannel = false;
    _callCleanupDoneRideIds.add(rideKey);
    _lastCallCleanupAt = DateTime.now();
    debugPrint('CALL_OVERLAY_CLOSE rideId=$rideKey source=$source');
    _logCallCleanupDone(
      rideId: rideKey,
      source: source,
      endReason: endReason,
      session: session,
    );
    _resetCallButtonLoading(reason: 'force_terminal_$source');
  }

  Future<void> _performLocalCallCleanup({
    required String rideId,
    required String cleanupSource,
    required String endReason,
    bool logCleanup = true,
    bool force = false,
  }) async {
    if (_callLocalCleanupInProgress) {
      if (force || cleanupSource == 'call_snapshot_terminal') {
        final rideKey = rideId.trim();
        _tearDownCallUiImmediately(rideKey);
        try {
          await _callService.leaveVoiceChannel();
          debugPrint(
            'CALL_LEAVE_CHANNEL rideId=$rideKey source=forced_terminal_while_in_progress',
          );
        } catch (error) {
          _logRideCall(
            'CALL_LEAVE_CHANNEL_FAIL rideId=$rideKey source=forced_terminal error=$error',
          );
        }
        _callJoinedChannel = false;
        _removeCallOverlayEntry();
        _isEndingCall = false;
        _callCleanupDoneRideIds.add(rideKey);
        debugPrint(
          'CALL_OVERLAY_CLOSE rideId=$rideKey source=forced_terminal_while_in_progress',
        );
      }
      return;
    }
    _callLocalCleanupInProgress = true;
    try {
      await _performLocalCallCleanupBody(
        rideId: rideId,
        cleanupSource: cleanupSource,
        endReason: endReason,
        logCleanup: logCleanup,
        force: force,
      );
    } finally {
      _callLocalCleanupInProgress = false;
    }
  }

  void _resetCallGuardsForNewSession(String rideId, {required String source}) {
    final normalizedRideId = rideId.trim();
    if (normalizedRideId.isEmpty) {
      return;
    }
    final hadRestartBlocks = _callLocallyEndedRideIds.contains(normalizedRideId) ||
        _callCleanupDoneRideIds.contains(normalizedRideId) ||
        _callJoinInFlightRideId == normalizedRideId ||
        (_currentCallSession?.rideId == normalizedRideId &&
            (_currentCallSession?.isTerminal ?? false));
    _callLocallyEndedRideIds.remove(normalizedRideId);
    _callCleanupDoneRideIds.remove(normalizedRideId);
    _callJoinInFlightRideId = null;
    _callJoinAttemptCount = 0;
    _callUiActiveRideId = null;
    if (_currentCallSession?.rideId == normalizedRideId &&
        (_currentCallSession?.isTerminal ?? false)) {
      _currentCallSession = null;
    }
    if (hadRestartBlocks) {
      _logRideCall(
        'CALL_TERMINAL_STATE_RESET_FOR_RESTART rideId=$normalizedRideId source=$source',
      );
      callTraceLog(
        'CALL_JOIN_GUARD_RESET_FOR_NEW_SESSION',
        rideId: normalizedRideId,
        role: 'driver',
      );
    }
  }

  void _stopCallListenerForRide(String rideId) {
    final normalizedRideId = rideId.trim();
    if (normalizedRideId.isEmpty) {
      return;
    }
    if (_callListenerRideId != null && _callListenerRideId != normalizedRideId) {
      return;
    }
    if (_callListenerRideId != null) {
      RidePipelineGuard.releaseCallListener(
        rideId: _callListenerRideId!,
        owner: 'DriverMapScreen',
      );
    }
    _callSubscription?.cancel();
    _callSubscription = null;
    _rideCallMirrorSubscription?.cancel();
    _rideCallMirrorSubscription = null;
    _detachSharedCallListener();
    _callListenerRideId = null;
  }

  void _attachSharedCallListener(RideCallSession session) {
    final callId = session.callId?.trim() ?? '';
    final contextId = session.rideId.trim();
    if (callId.isEmpty || contextId.isEmpty || session.isTerminal) {
      return;
    }
    final uid = _effectiveDriverId;
    _sharedCallListener.attach(
      callId: callId,
      contextId: contextId,
      uid: uid,
      onTerminal: ({
        required String callId,
        required String contextId,
        required String status,
        String? endedBy,
      }) async {
        if (!mounted || _callListenerRideId != contextId) {
          return;
        }
        final confirmed = await _callService.fetchCall(
          contextId,
          kind: _callKindFor(contextId),
        );
        if (confirmed != null && confirmed.isTerminal) {
          await _handleCallSnapshotUpdate(contextId, confirmed);
          return;
        }
        await _forceCallTerminalCleanup(
          rideId: contextId,
          source: 'shared_call_$status',
          endReason: 'shared_call_$status',
          session: _currentCallSession,
        );
      },
    );
  }

  void _detachSharedCallListener() {
    _sharedCallListener.detach();
  }

  void _dismissOpenModalRoutes({int maxPops = 6}) {
    if (!mounted) {
      return;
    }
    var pops = 0;
    while (mounted && pops < maxPops) {
      final route = ModalRoute.of(context);
      if (route == null || route.isFirst) {
        break;
      }
      if (route is PopupRoute) {
        Navigator.of(context).pop();
        pops++;
        continue;
      }
      break;
    }
  }

  Future<void> _prepareUiCleanupBeforeTripReset(String rideId) async {
    final normalizedRideId = rideId.trim();
    if (normalizedRideId.isEmpty) {
      return;
    }
    _log('COMPLETE_TRIP_PRE_UI_CLEANUP_START rideId=$normalizedRideId');
    if (!mounted) {
      return;
    }
    _dismissOpenModalRoutes();
    _stopCallListenerForRide(normalizedRideId);
    _removeCallOverlayEntry(
      logReason: 'CALL_OVERLAY_REMOVED_BEFORE_TRIP_RESET',
    );
    await _performLocalCallCleanup(
      rideId: normalizedRideId,
      cleanupSource: 'complete_trip_pre_reset',
      endReason: 'trip_completed',
      logCleanup: false,
      force: true,
    );
    if (!mounted) {
      return;
    }
    _log('COMPLETE_TRIP_PRE_UI_CLEANUP_OK rideId=$normalizedRideId');
  }

  void _tearDownCallUiImmediately(String rideId) {
    final normalizedRideId = rideId.trim();
    if (normalizedRideId.isEmpty) {
      return;
    }
    _callLocallyEndedRideIds.add(normalizedRideId);
    _cancelCallRingTimeout();
    _stopCallDurationTicker();
    _currentCallSession = null;
    _callAcceptedAt = null;
    _activeCallStartedAt = null;
    _callDuration = Duration.zero;
    _removeCallOverlayEntry();
  }

  Future<void> _performLocalCallCleanupBody({
    required String rideId,
    required String cleanupSource,
    required String endReason,
    bool logCleanup = true,
    bool force = false,
  }) async {
    if (!force && _callCleanupDoneRideIds.contains(rideId)) {
      if (cleanupSource != 'end_tap' &&
          cleanupSource != 'call_snapshot_terminal') {
        return;
      }
      final stillVisible = _callOverlayEntry != null ||
          _currentCallSession != null ||
          _callJoinedChannel ||
          _callService.isVoiceConnected;
      if (!stillVisible) {
        return;
      }
      _callCleanupDoneRideIds.remove(rideId);
    }
    final hadVisibleCallState = _currentCallSession != null ||
        _callJoinedChannel ||
        _callJoinInFlightRideId == rideId.trim() ||
        _alertSoundService.isCallAlertActive ||
        _callOverlayEntry != null ||
        _callDurationTimer != null ||
        _callRingTimeoutTimer != null;
    if (!hadVisibleCallState &&
        !force &&
        !_callService.isVoiceConnected &&
        !_callJoinedChannel) {
      return;
    }

    RideCallSession? rtdbSession;
    if (cleanupSource != 'end_tap' && cleanupSource != 'call_snapshot_terminal') {
      try {
        rtdbSession = await _callService.fetchCall(
          rideId,
          kind: _callKindFor(rideId),
        );
      } catch (error) {
        _logRideCall('CALL_CLEANUP_REFETCH_FAIL rideId=$rideId error=$error');
      }
    }
    final remoteState = _callService.isVoiceConnected
        ? 'agora_connected'
        : (_callJoinedChannel ? 'local_joined' : 'local_disconnected');
    callCleanupDiagnostics(
      cleanupSource: cleanupSource,
      endReason: endReason,
      rideId: rideId,
      role: 'driver',
      rtdbState: rtdbSession?.status.name ?? 'null',
      remoteState: remoteState,
    );
    final sessionForLog = rtdbSession ?? _currentCallSession;

    _callCleanupDoneRideIds.add(rideId);
    _lastCallCleanupAt = DateTime.now();
    _callNullGraceUntilByRideId.remove(rideId.trim());
    _callJoinInFlightRideId = null;
    if (_callUiActiveRideId == rideId.trim()) {
      _callUiActiveRideId = null;
    }

    if (cleanupSource == 'end_tap') {
      _tearDownCallUiImmediately(rideId);
    } else {
      _cancelCallRingTimeout();
      _stopCallDurationTicker();
      _callAcceptedAt = null;
      _activeCallStartedAt = null;
      _callDuration = Duration.zero;
      _currentCallSession = null;
      _removeCallOverlayEntry();
    }

    _callMuted = false;
    _callSpeakerOn = true;
    _isEndingCall = false;

    try {
      await _callService.leaveVoiceChannel();
    } catch (error) {
      _logRideCall('leave failed rideId=$rideId error=$error');
    }

    _callJoinedChannel = false;
    unawaited(_stopCallRingtone());
    _logRideCall(
      'CALL_UI_CLOSE rideId=$rideId reason=local_cleanup source=$cleanupSource',
    );
    _logCallCleanupDone(
      rideId: rideId,
      source: cleanupSource,
      endReason: endReason,
      session: sessionForLog,
    );

    if (hadVisibleCallState) {
      callTraceLog(
        'CALL_END_LOCAL_CLEANUP_OK',
        rideId: rideId,
        role: 'driver',
      );
    }

    _resetCallButtonLoading(reason: 'local_cleanup_$cleanupSource');

    if (logCleanup && hadVisibleCallState) {
      _logRideCall(
        'local cleanup completed rideId=$rideId source=$cleanupSource reason=$endReason',
      );
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
      callTraceLog('CALL_START_TAP', rideId: rideId, role: 'driver');
      _resetCallGuardsForNewSession(rideId, source: 'start_voice_call');
      _extendCallNullGrace(rideId);
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
      _resetCallButtonLoading(reason: 'start_voice_call_finally');
    }
  }

  Future<void> _acceptIncomingCall() async {
    final session = _currentCallSession;
    if (session == null ||
        !_isIncomingCall(session) ||
        !_canWriteParticipantStateForSession(session)) {
      return;
    }

    callTraceLog('CALL_ACCEPT_TAP', rideId: session.rideId, role: 'driver');

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
      _logRideCall(
          '[CALL_TOKEN_FETCH_FAIL] rideId=${session.rideId} error=$error');
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
      kind: _callKindFor(session.rideId),
    );
    if (!accepted) {
      _showSnackBarSafely(
        const SnackBar(
          content: Text('This call is no longer available.'),
        ),
      );
      return;
    }
    await _joinAcceptedCall(rideId: session.rideId, uid: driverId);
  }

  Future<void> _declineIncomingCall() async {
    final session = _currentCallSession;
    if (session == null ||
        !_isIncomingCall(session) ||
        !_canWriteParticipantStateForSession(session)) {
      return;
    }

    callTraceLog('CALL_END_TAP', rideId: session.rideId, role: 'driver');

    await _callService.declineCall(
      rideId: session.rideId,
      endedBy: 'driver',
      receiverId: _effectiveDriverId,
      kind: _callKindFor(session.rideId),
    );
  }

  Future<void> _cancelOutgoingCall() async {
    final session = _currentCallSession;
    if (session == null ||
        !_isOutgoingCall(session) ||
        !_canWriteParticipantStateForSession(session)) {
      return;
    }

    callTraceLog('CALL_END_TAP', rideId: session.rideId, role: 'driver');

    await _callService.cancelOutgoingCall(
      rideId: session.rideId,
      endedBy: 'driver',
      callerId: _effectiveDriverId,
      kind: _callKindFor(session.rideId),
    );
  }

  Future<void> _endOngoingCall() async {
    if (_isEndingCall) {
      final debouncedRideId = _activeCallRideId;
      if (debouncedRideId.isNotEmpty) {
        callTraceLog(
          'CALL_END_DEBOUNCED',
          rideId: debouncedRideId,
          role: 'driver',
        );
      }
      return;
    }

    final session = _currentCallSession;
    final rideId = (session?.rideId ?? _activeCallRideId).trim();
    if (rideId.isEmpty) {
      return;
    }
    final voiceLive = _callJoinedChannel || _callService.isVoiceConnected;
    final joinInFlight = _callJoinInFlightRideId == rideId;
    final overlayVisible =
        _callOverlayEntry != null && _callOverlayEntry!.mounted;
    final canEndDuringSetup = joinInFlight ||
        overlayVisible ||
        (session != null && (session.isAccepted || session.isRinging));
    if (!voiceLive && !canEndDuringSetup) {
      return;
    }

    _isEndingCall = true;
    callTraceLog('CALL_END_TAP', rideId: rideId, role: 'driver');
    _callOverlayEntry?.markNeedsBuild();

    final endSession = session;
    unawaited(() async {
      try {
        final committed = await _callService.endCallFromUserTap(
          rideId: rideId,
          endedByUid: _effectiveDriverId,
          endedByRole: 'driver',
          kind: _callKindFor(rideId),
        );
        if (committed) {
          callTraceLog('CALL_END_RTDB_OK', rideId: rideId, role: 'driver');
        } else {
          _logRideCall('CALL_END_RTDB_FAIL rideId=$rideId reason=not_committed');
        }
        await _forceCallTerminalCleanup(
          rideId: rideId,
          source: committed ? 'local_end_tap' : 'local_end_tap_fallback',
          endReason: 'user_ended',
          session: endSession,
        );
      } catch (error) {
        _logRideCall('CALL_END_RTDB_FAIL rideId=$rideId error=$error');
        await _forceCallTerminalCleanup(
          rideId: rideId,
          source: 'local_end_tap_error',
          endReason: 'user_ended',
          session: endSession,
        );
      }
    }());
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
    required String lifecycleReason,
  }) async {
    await _callService.endCallForRideLifecycle(
      rideId: rideId,
      endedBy: 'system',
      kind: _callKindFor(rideId),
    );
    await _performLocalCallCleanup(
      rideId: rideId,
      cleanupSource: 'ride_lifecycle_end_call',
      endReason: lifecycleReason,
    );
  }

  String get _activeCallRideId {
    return (_callListenerRideId ??
            _currentRideId ??
            _driverActiveRideId ??
            _activeDriverRideContextId ??
            '')
        .trim();
  }

  void _handleCallVoicePhaseChanged() {
    if (!_callService.isVoiceConnected) {
      if (_callService.isLocalVoiceJoined) {
        _refreshCallOverlayEntry();
      }
      return;
    }
    final rideId = _activeCallRideId;
    if (rideId.isEmpty) {
      return;
    }
    _ensureCallDurationTimerStarted(
      rideId: rideId,
      source: 'CALL_REMOTE_JOINED',
    );
    _ensureActiveCallUiVisible(
      rideId: rideId,
      source: 'CALL_REMOTE_JOINED',
    );
  }

  RideCallSession? _synthesizeActiveCallSession(String rideId) {
    final normalizedRideId = rideId.trim();
    if (normalizedRideId.isEmpty) {
      return null;
    }
    final driverId = _effectiveDriverId.trim();
    if (driverId.isEmpty) {
      return null;
    }
    final riderId = _valueAsText(_currentRideData?['rider_id']).trim().isNotEmpty
        ? _valueAsText(_currentRideData?['rider_id']).trim()
        : _valueAsText(_currentRideData?['riderId']).trim();
    final existing = _currentCallSession;
    if (existing != null &&
        existing.rideId == normalizedRideId &&
        !existing.isTerminal) {
      return existing;
    }
    return RideCallSession(
      rideId: normalizedRideId,
      callerId: riderId.isNotEmpty ? riderId : driverId,
      receiverId: driverId,
      status: RideCallStatus.joined,
      channelId: normalizedRideId,
      callerUid: riderId.isNotEmpty ? riderId : driverId,
      acceptedAt:
          _callAcceptedAt?.millisecondsSinceEpoch ??
          DateTime.now().millisecondsSinceEpoch,
    );
  }

  void _extendCallNullGrace(String rideId, {Duration grace = const Duration(seconds: 12)}) {
    final normalizedRideId = rideId.trim();
    if (normalizedRideId.isEmpty) {
      return;
    }
    final until =
        DateTime.now().millisecondsSinceEpoch + grace.inMilliseconds;
    final previous = _callNullGraceUntilByRideId[normalizedRideId] ?? 0;
    if (until > previous) {
      _callNullGraceUntilByRideId[normalizedRideId] = until;
    }
  }

  bool _isCallNullGraceActive(String rideId) {
    final until = _callNullGraceUntilByRideId[rideId.trim()];
    if (until == null) {
      return false;
    }
    return DateTime.now().millisecondsSinceEpoch < until;
  }

  void _ensureActiveCallUiVisible({
    required String rideId,
    required String source,
  }) {
    if (!mounted) {
      return;
    }
    final normalizedRideId = rideId.trim();
    if (normalizedRideId.isEmpty) {
      return;
    }
    if (_shouldAbortCallUiForRide(normalizedRideId)) {
      _logRideCall(
        'CALL_UI_ACTIVE_SUPPRESSED rideId=$normalizedRideId source=$source '
        'reason=terminal_or_cleanup_done',
      );
      return;
    }
    if (_callLocallyEndedRideIds.contains(normalizedRideId)) {
      final activeSession = _currentCallSession;
      if ((activeSession == null || activeSession.isTerminal) &&
          !_callJoinedChannel &&
          !_callService.isVoiceConnected) {
        return;
      }
      _callLocallyEndedRideIds.remove(normalizedRideId);
    }
    if (_callOverlayEntry != null && !_callOverlayEntry!.mounted) {
      _logRideCall(
        'CALL_UI_ACTIVE_STALE_OVERLAY_RESET rideId=$normalizedRideId source=$source',
      );
      _removeCallOverlayEntry();
    }
    if (_callUiActiveRideId == normalizedRideId &&
        _callOverlayEntry != null &&
        _callOverlayEntry!.mounted) {
      final voiceLive = _callJoinedChannel || _callService.isVoiceConnected;
      final session = _currentCallSession;
      final callLive = voiceLive ||
          (session != null &&
              !session.isTerminal &&
              (session.isRinging || session.isAccepted));
      if (callLive) {
        _logRideCall(
          'CALL_UI_ACTIVE_ALREADY_VISIBLE rideId=$normalizedRideId source=$source',
        );
        if (source == 'CALL_REMOTE_JOINED') {
          _ensureCallDurationTimerStarted(
            rideId: normalizedRideId,
            source: source,
          );
        }
        _callOverlayEntry!.markNeedsBuild();
        return;
      }
    }
    final voiceLive = _callJoinedChannel || _callService.isVoiceConnected;
    final session = _currentCallSession;
    if ((session == null || session.isTerminal) && voiceLive) {
      _currentCallSession = _synthesizeActiveCallSession(normalizedRideId);
    }
    final visibleSession = _currentCallSession;
    if (visibleSession == null || visibleSession.isTerminal) {
      if (!voiceLive) {
        return;
      }
    }
    _callUiActiveRideId = normalizedRideId;
    if (source == 'CALL_REMOTE_JOINED') {
      _logRideCall(
        'CALL_UI_ACTIVE_ENSURE rideId=$normalizedRideId source=$source',
      );
      _ensureCallDurationTimerStarted(
        rideId: normalizedRideId,
        source: source,
      );
    } else {
      _logRideCall('CALL_UI_ACTIVE_SHOW rideId=$normalizedRideId source=$source');
    }
    _refreshCallOverlayEntry();
  }

  void _ensureCallDurationTimerStarted({
    required String rideId,
    required String source,
  }) {
    final normalizedRideId = rideId.trim();
    if (normalizedRideId.isEmpty) {
      return;
    }
    if (_activeCallStartedAt == null) {
      final sessionAnchor = _currentCallSession?.acceptedAtDateTime;
      _activeCallStartedAt = sessionAnchor ?? DateTime.now();
      _logRideCall(
        'CALL_TIMER_START rideId=$normalizedRideId source=$source',
      );
    }
    _startCallDurationTicker(_activeCallStartedAt);
  }

  void _refreshCallOverlayEntry() {
    if (!mounted) {
      return;
    }

    if (_appLifecycleState != AppLifecycleState.resumed) {
      if (_isDeliveryCallContext) {
        debugPrint(
          'DELIVERY_CALL_NOT_AUTO_ENDED_ON_INACTIVE '
          'lifecycle=${_appLifecycleState.name}',
        );
        return;
      }
      _removeCallOverlayEntry();
      return;
    }

    final rideId = _activeCallRideId;
    if (rideId.isNotEmpty && _callLocallyEndedRideIds.contains(rideId)) {
      final activeSession = _currentCallSession;
      if ((activeSession == null || activeSession.isTerminal) &&
          !_callJoinedChannel &&
          !_callService.isVoiceConnected) {
        _removeCallOverlayEntry();
        return;
      }
      _callLocallyEndedRideIds.remove(rideId.trim());
    }
    final voiceLive = _callJoinedChannel || _callService.isVoiceConnected;
    var session = _currentCallSession;
    if ((session == null || session.isTerminal) &&
        voiceLive &&
        rideId.isNotEmpty &&
        !_callLocallyEndedRideIds.contains(rideId)) {
      session = _synthesizeActiveCallSession(rideId);
      _currentCallSession = session;
    }
    final shouldShow = session != null &&
        !session.isTerminal &&
        (session.isRinging || session.isAccepted || voiceLive);
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

    if (_callOverlayEntry != null && !_callOverlayEntry!.mounted) {
      try {
        _callOverlayEntry!.remove();
      } catch (_) {}
      _callOverlayEntry = null;
      _logRideCall(
        'CALL_UI_ACTIVE_STALE_OVERLAY_RESET rideId=$rideId reason=unmounted_entry',
      );
    }

    _callOverlayEntry ??= OverlayEntry(
      builder: (context) => _buildRideCallOverlay(),
    );

    if (!_callOverlayEntry!.mounted) {
      try {
        overlay.insert(_callOverlayEntry!);
        _logRideCall('CALL_UI_ACTIVE_ENSURE rideId=$rideId');
      } catch (error) {
        final message = error.toString();
        if (message.contains('already present')) {
          _logRideCall(
            'CALL_UI_ACTIVE_STALE_OVERLAY_RESET rideId=$rideId reason=duplicate_insert',
          );
          _callOverlayEntry = OverlayEntry(
            builder: (context) => _buildRideCallOverlay(),
          );
          overlay.insert(_callOverlayEntry!);
          _logRideCall('CALL_UI_ACTIVE_ENSURE rideId=$rideId reason=reinsert');
        } else {
          rethrow;
        }
      }
      return;
    }

    _logRideCall('CALL_UI_ACTIVE_ALREADY_VISIBLE rideId=$rideId');
    _callOverlayEntry!.markNeedsBuild();
  }

  void _removeCallOverlayEntry({String? logReason}) {
    final entry = _callOverlayEntry;
    _callOverlayEntry = null;
    if (entry == null) {
      return;
    }
    try {
      if (entry.mounted) {
        entry.remove();
        if (logReason != null && logReason.isNotEmpty) {
          _logRideCall('$logReason rideId=${_activeCallRideId}');
        }
      }
    } catch (error) {
      _logRideCall(
        'CALL_OVERLAY_REMOVE_FAIL rideId=${_activeCallRideId} error=$error',
      );
    }
  }

  Widget _buildRideCallOverlay() {
    final session = _currentCallSession;
    if (session == null || session.isTerminal) {
      return const SizedBox.shrink();
    }

    final isIncoming = _isIncomingCall(session);
    final isOutgoing = _isOutgoingCall(session);
    final title = _riderName.isEmpty ? 'Rider' : _riderName;

    if (isIncoming && !session.isAccepted) {
      return Material(
        color: Colors.transparent,
        child: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxWidth: 520),
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                decoration: BoxDecoration(
                  color: const Color(0xFF111827),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: _gold.withValues(alpha: 0.35)),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x44000000),
                      blurRadius: 18,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Incoming ride call',
                      style: TextStyle(
                        color: _gold.withValues(alpha: 0.95),
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 20,
                      ),
                    ),
                    const SizedBox(height: 12),
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
                        const SizedBox(width: 10),
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
          ),
        ),
      );
    }

    return ValueListenableBuilder<AgoraConnectionPhase>(
      valueListenable: _callService.phaseNotifier,
      builder: (context, phase, _) {
        return ValueListenableBuilder<String?>(
          valueListenable: _callService.phaseErrorNotifier,
          builder: (context, phaseError, _) {
            return ValueListenableBuilder<String?>(
              valueListenable: _callService.remotePeerStatusNotifier,
              builder: (context, remotePeerStatus, _) {
            final isFailed = phase == AgoraConnectionPhase.failed;
            final isReconnecting = phase == AgoraConnectionPhase.reconnecting;
            final isWaitingForRemote =
                phase == AgoraConnectionPhase.waitingForRemote ||
                    (_callService.isLocalVoiceJoined &&
                        !_callService.remotePeerJoined);
            final isConnecting = phase == AgoraConnectionPhase.connecting ||
                (session.isAccepted &&
                    !_callService.isVoiceConnected &&
                    phase != AgoraConnectionPhase.failed &&
                    phase != AgoraConnectionPhase.reconnecting);
            final resolvedSubtitle = isOutgoing
                ? 'Calling...'
                : isFailed
                    ? (phaseError ??
                        'Could not connect call. Please try again.')
                    : isReconnecting
                        ? 'Reconnecting...'
                        : isWaitingForRemote
                            ? (remotePeerStatus ??
                                'Connecting to other party…')
                        : isConnecting
                            ? 'Connecting...'
                            : _formatCallDuration(_callDuration);

            return Material(
      color: const Color(0xFF08111F),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
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
                      resolvedSubtitle,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: session.isAccepted ? 18 : 16,
                        fontWeight: FontWeight.w600,
                        color: isFailed
                            ? const Color(0xFFE85D4C)
                            : (session.isAccepted &&
                                    phase == AgoraConnectionPhase.connected)
                                ? _gold
                                : Colors.white70,
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
                        children: [
                          Expanded(
                            child: _buildCallControlChip(
                              label: _callMuted ? 'Unmute' : 'Mute',
                              icon: _callMuted
                                  ? Icons.mic_off_rounded
                                  : Icons.mic_none_rounded,
                              active: _callMuted,
                              onTap: _toggleCallMute,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: _buildCallControlChip(
                              label: _callSpeakerOn ? 'Speaker' : 'Earpiece',
                              icon: _callSpeakerOn
                                  ? Icons.volume_up_rounded
                                  : Icons.hearing_rounded,
                              active: _callSpeakerOn,
                              onTap: _toggleSpeaker,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: _buildCallControlChip(
                              label: 'End',
                              icon: Icons.call_end_rounded,
                              active: true,
                              backgroundColor: const Color(0xFFE85D4C),
                              foregroundColor: Colors.white,
                              onTap: _isEndingCall ? null : _endOngoingCall,
                            ),
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
              },
            );
          },
        );
      },
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
    Future<void> Function()? onTap,
    Color? backgroundColor,
    Color? foregroundColor,
  }) {
    final effectiveBackground = backgroundColor ??
        (active ? _gold.withValues(alpha: 0.18) : const Color(0xFF1F2937));
    final effectiveForeground =
        foregroundColor ?? (active ? _gold : Colors.white70);

    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap == null
          ? null
          : () {
              unawaited(onTap());
            },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 14),
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
    for (final key in <String>[
      'request_expires_at',
      'expires_at',
      'expiresAt'
    ]) {
      final timestamp = _parseCreatedAt(rideData[key]);
      if (timestamp > 0) {
        return (value: timestamp, field: key);
      }
    }
    return (value: 0, field: 'none');
  }

  int _rideExpiryTimestamp(Map<String, dynamic> rideData) =>
      _rideExpiryInfo(rideData).value;

  /// Server [expires_at] plus grace so a just-written queue offer is not dropped.
  bool _rideExpiredWithOfferGrace(Map<String, dynamic> rideData) {
    final rideId = _valueAsText(rideData['ride_id']).trim();
    if (_popupOpen &&
        _hasActivePopup &&
        rideId.isNotEmpty &&
        _activePopupRideId == rideId) {
      return false;
    }
    const graceMs = 10000;
    final expiresAt = _rideExpiryTimestamp(rideData);
    if (expiresAt <= 0) {
      return false;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    return now > expiresAt + graceMs;
  }

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
    try {
      final cloud = await _rideCloud.cancelRideRequest(
        rideId: rideId,
        cancelReason: reason,
      );
      if (!rideCallableSucceeded(cloud)) {
        _log(
          'system cancel cloud failed rideId=$rideId reason=${rideCallableReason(cloud)}',
        );
        return false;
      }
    } catch (error) {
      _log('system cancel cloud exception rideId=$rideId error=$error');
      return false;
    }

    final snap = await runRtdbQueryGet(
      query: _rideRequestsRef.child(rideId),
      path: 'ride_requests/$rideId',
      source: 'driver_map.ride_commit_check',
    );
    final committedRide = _asStringDynamicMap(snap.value) ?? rideData;
    await _commitRideAndDriverState(
      rideId: rideId,
      rideUpdates: const <String, dynamic>{},
      driverUpdates: _buildDriverPresenceUpdate(
        status: _isOnline ? 'idle' : 'offline',
        isAvailable: _isOnline,
      ),
      clearActiveRide: true,
    );
    await _endCallForRideLifecycle(
      rideId: rideId,
      lifecycleReason: 'system_cancel_$reason',
    );
    _logRideStateChangeOnce(
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

    final checkpointPath = 'trip_route_logs/$rideId/checkpoints';
    final snapshot = await runRtdbQueryGet(
      query: _rideRequestsRef.root.child(checkpointPath),
      path: checkpointPath,
      source: 'driver_map.trip_route_checkpoints',
    );
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
    final lat = _asDouble(map?['lat']) ?? _asDouble(map?['latitude']);
    final lng = _asDouble(map?['lng']) ?? _asDouble(map?['longitude']);
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
    final baseline = _currentRideId == rideId ? _currentRideData : null;
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

  /// Clears per-ride popup dedupe so a new offer (or re-queued offer) can show again.
  void _releaseRidePopupSessionBlocks(
    String rideId, {
    bool includeForever = false,
    bool includeTerminalSelfAccepted = false,
  }) {
    final normalizedId = rideId.trim();
    if (normalizedId.isEmpty) {
      return;
    }
    _declinedRideIds.remove(normalizedId);
    _handledRideIds.remove(normalizedId);
    _suppressedRidePopupIds.remove(normalizedId);
    _presentedRideIds.remove(normalizedId);
    _timedOutRideIds.remove(normalizedId);
    _lastDiscoveryDismissFingerprintByRideId.remove(normalizedId);
    _discoveryPopupCooldownUntilMs.remove(normalizedId);
    _loggedDriverOfferReceivedRideIds.remove(normalizedId);
    if (includeForever) {
      _foreverSuppressedRidePopupIds.remove(normalizedId);
    }
    if (includeTerminalSelfAccepted) {
      _terminalSelfAcceptedRideIds.remove(normalizedId);
    }
    _logRideReq(
      'POPUP_SESSION_BLOCKS_RELEASED rideId=$normalizedId '
      'forever=$includeForever terminal=$includeTerminalSelfAccepted',
    );
  }

  bool _offerQueuedForDriver(String rideId) {
    final normalizedId = rideId.trim();
    return normalizedId.isNotEmpty &&
        _driverOfferQueueReplica.containsKey(normalizedId);
  }

  /// Open-pool rides back in [searching]/[requested] with a public driver slot
  /// should not stay locally suppressed from an older accept cycle.
  void _maybeUnsuppressOpenPoolRide(
      String rideId, Map<String, dynamic> rideData) {
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
    final openSlot =
        did.isEmpty || dLower == 'waiting' || did == _effectiveDriverId;
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
    _releaseRidePopupSessionBlocks(n);
  }

  void _logPopupServerSkip(
    String rideId,
    Map<String, dynamic>? rideData,
    String reason,
  ) {
    final st = rideData == null ? '?' : _valueAsText(rideData['status']);
    final tripState =
        rideData == null ? '?' : _valueAsText(rideData['trip_state']);
    final did = rideData == null ? '?' : _valueAsText(rideData['driver_id']);
    final market =
        rideData == null ? '?' : (_rideMarketFromData(rideData) ?? '?');
    final expectedMarket = _effectiveDriverMarket ?? '?';
    _logRideReq(
      'popup skip rideId=$rideId reason=$reason status=$st trip_state=$tripState '
      'driver_id=$did market=$market expected_market=$expectedMarket',
    );
  }

  /// Final safety check before [showDialog] — backend offers skip local geo/market gates.
  String? _popupHardGateBeforeDialog(
    String rideId,
    dynamic rawRide, {
    bool trustBackendOffer = false,
  }) {
    final rideData = _asStringDynamicMap(rawRide);
    if (rideData == null) {
      return 'payload_null';
    }

    final backendTrusted =
        trustBackendOffer || _isBackendTrustedOffer(rideId, rideData);

    final canonical = TripStateMachine.canonicalStateFromSnapshot(rideData);
    if (TripStateMachine.isTerminal(canonical)) {
      return 'trip_terminal';
    }

    if (TripStateMachine.uiStatusFromSnapshot(rideData) == 'cancelled') {
      return 'ride_cancelled';
    }

    if (!_rideExpiredWithOfferGrace(rideData)) {
      final expiresAt = _rideExpiryTimestamp(rideData);
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (expiresAt > 0 && nowMs >= expiresAt) {
        return 'expired';
      }
    }

    if (!backendTrusted) {
      final rideMarket = _rideMarketFromData(rideData);
      final driverMarket = _canonicalDriverDispatchMarket();
      if (rideMarket == null ||
          rideMarket.isEmpty ||
          driverMarket == null ||
          driverMarket.isEmpty ||
          rideMarket != driverMarket) {
        return 'market_mismatch';
      }
    }

    final did = _valueAsText(rideData['driver_id']);
    final dLower = did.toLowerCase();
    if (did.isNotEmpty && dLower != 'waiting' && did != _effectiveDriverId) {
      return 'driver_already_assigned';
    }

    return null;
  }

  /// Popup may only close for explicit outcomes — not RTDB refetch drift.
  bool _shouldDismissPopupForServerReason(
    String? reason, {
    String? rideId,
    Map<String, dynamic>? rideData,
  }) {
    if (rideId != null &&
        _isBackendTrustedOffer(rideId, rideData)) {
      return switch (reason) {
        'trip_terminal_state' ||
        'ride_cancelled' ||
        'expired' ||
        'driver_already_assigned' ||
        'assigned_to_another_driver' ||
        'already_accepted_by_self' ||
        'terminal_self_accepted_local' =>
          true,
        _ => false,
      };
    }
    return switch (reason) {
      null => false,
      'dispatch_stale' || 'outside_dispatch_radius' => false,
      _ => true,
    };
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

  String _discoveryOfferFingerprint(
    String rideId,
    Map<String, dynamic> rideData,
  ) {
    return <String>[
      rideId,
      _valueAsText(rideData[RtdbRideRequestFields.createdAt]),
      '${_asDouble(rideData[RtdbRideRequestFields.fare]) ?? 0}',
      '${_rideExpiryTimestamp(rideData)}',
      _valueAsText(rideData[RtdbRideRequestFields.paymentStatus]),
      _valueAsText(rideData[RtdbRideRequestFields.status]),
      _valueAsText(rideData[RtdbRideRequestFields.tripState]),
    ].join('\x1f');
  }

  String? _popupLocalSkipReason(String rideId) {
    final normalizedId = rideId.trim();
    if (_offerQueueEntryBypassesLocalDedup(normalizedId)) {
      return null;
    }
    if (_handledRideIds.contains(normalizedId) &&
        !_offerQueuedForDriver(normalizedId)) {
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
    if (_suppressedRidePopupIds.contains(normalizedId) &&
        !_offerQueuedForDriver(normalizedId)) {
      return 'locally_suppressed_after_accept';
    }

    if (_isDriverSameRideContextBlockingPopup(normalizedId)) {
      return 'already_active_same_ride';
    }

    if (_timedOutRideIds.contains(normalizedId) &&
        !_offerQueuedForDriver(normalizedId)) {
      return 'timed_out_locally';
    }

    if (_declinedRideIds.contains(normalizedId) &&
        !_offerQueuedForDriver(normalizedId)) {
      return 'declined_locally';
    }

    if (_offerQueuedForDriver(normalizedId)) {
      return null;
    }

    if (_acceptingPopupRideId == normalizedId &&
        (_activePopupRideId != normalizedId || !_hasActivePopup)) {
      return 'accept_in_flight';
    }

    final cachedOffer = _driverOfferRideCache[normalizedId];
    if (cachedOffer != null) {
      final fp = _discoveryOfferFingerprint(normalizedId, cachedOffer);
      final until = _discoveryPopupCooldownUntilMs[normalizedId] ?? 0;
      final lastFp = _lastDiscoveryDismissFingerprintByRideId[normalizedId];
      final nowClock = DateTime.now().millisecondsSinceEpoch;
      if (until > nowClock && lastFp != null && lastFp == fp) {
        return 'duplicate_offer_snapshot';
      }
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
      _logDriverOfferQueueDrained(nextCount: 0, source: 'flush_empty');
      _ensureContinuousOfferDiscovery(source: 'popup_queue_empty');
      return;
    }
    final next = _rideRequestPopupQueue.removeAt(0);
    _logDriverOfferQueueDrained(
      nextCount: _rideRequestPopupQueue.length,
      source: 'flush_next',
    );
    _logRideReq(
      '[DISCOVERY_QUEUE] flushing next rideId=${next.rideId} '
      'remaining=${_rideRequestPopupQueue.length}',
    );
    final freshRide = await _loadFreshOfferRequestForOfferPopup(
      next.rideId,
      source: 'popup_queue_flush',
      queuePayload: _asStringDynamicMap(_driverOfferQueueReplica[next.rideId]),
    );
    if (freshRide == null) {
      await _flushRideRequestPopupQueueAfterClose();
      return;
    }
    final mergedData = Map<String, dynamic>.from(next.rideData)..addAll(freshRide);
    final refreshed = _matchRideForPopup(
      next.rideId,
      mergedData,
      ignoreLocalState: true,
      marketDiscoveryCandidate: true,
    );
    if (refreshed == null) {
      await _flushRideRequestPopupQueueAfterClose();
      return;
    }
    await showRideRequestPopup(refreshed);
  }

  bool _isCanonicalOpenForClaim(String canonicalState) {
    return canonicalState == TripLifecycleState.searchingDriver ||
        canonicalState == TripLifecycleState.requested;
  }

  bool get isDevRelaxedRideAcceptanceEnabled =>
      !kReleaseMode &&
      const bool.fromEnvironment(
        'DEV_RELAXED_RIDE_ACCEPTANCE',
        defaultValue: false,
      );

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
    final ui =
        rideData == null ? '' : TripStateMachine.uiStatusFromSnapshot(rideData);
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
    if (did.isNotEmpty && dLower != 'waiting' && did != _effectiveDriverId) {
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

  /// Relaxed rules for market-query discovery: open pool only; wrong market,
  /// terminal/cancelled, expired, or missing coords still block.
  String? _popupServerSkipReasonOpenPoolDiscovery(
    String rideId,
    Map<String, dynamic> rideData,
  ) {
    if (_isDeliveryOfferData(rideData)) {
      return _popupServerSkipReasonDeliveryOffer(rideId, rideData);
    }
    if (_isBackendTrustedOffer(rideId, rideData)) {
      return _popupServerSkipReasonBackendOffer(rideId, rideData);
    }
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

    final fromOfferQueue = rideData['__nexride_from_offer_queue'] == true;
    if (!fromOfferQueue) {
      final rideMarket = _rideMarketFromData(rideData);
      final driverMarket = _canonicalDriverDispatchMarket();
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
    }

    final expiry = _rideExpiryInfo(rideData);
    final expiresAt = expiry.value;
    final nowTimestamp = DateTime.now().millisecondsSinceEpoch;
    if (_rideExpiredWithOfferGrace(rideData)) {
      _logPopupFix(
        'skip reason=expired rideId=$rideId now_ms=$nowTimestamp expires_at=$expiresAt '
        'delta_ms=${expiresAt > 0 ? nowTimestamp - expiresAt : -1} expiry_field=${expiry.field} '
        'grace_ms=10000',
      );
      _logPopupServerSkip(rideId, rideData, 'expired');
      _logRideReq(
        '[MATCH_DEBUG][DRIVER_FILTER] rideId=$rideId status=$uiStatus '
        'qualifies=false reason=expired now_ms=$nowTimestamp expires_at=$expiresAt '
        'delta_ms=${expiresAt > 0 ? nowTimestamp - expiresAt : -1} expiry_field=${expiry.field}',
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

    if (!fromOfferQueue) {
      if (_pickupLatLngFromRideData(rideData) == null) {
        _logPopupFix('skip reason=missing_pickup_coordinates rideId=$rideId');
        _logPopupServerSkip(rideId, rideData, 'missing_pickup_coordinates');
        return 'missing_pickup_coordinates';
      }

      if (_destinationLatLngFromRideData(rideData) == null) {
        _logPopupFix(
            'skip reason=missing_destination_coordinates rideId=$rideId');
        _logPopupServerSkip(
          rideId,
          rideData,
          'missing_destination_coordinates',
        );
        return 'missing_destination_coordinates';
      }
    }

    _logRideReq(
      '[DRIVER_DISCOVERY] rideId=$rideId market=${_rideMarketFromData(rideData)} '
      'trip_state=${rideData['trip_state']} status=${rideData['status']}',
    );

    return null;
  }

  String? _popupServerSkipReasonBackendOffer(
    String rideId,
    Map<String, dynamic> rideData,
  ) {
    if (_isDeliveryOfferData(rideData)) {
      return _popupServerSkipReasonDeliveryOffer(rideId, rideData);
    }
    final trimmedId = rideId.trim();
    if (_terminalSelfAcceptedRideIds.contains(trimmedId)) {
      return 'terminal_self_accepted_local';
    }
    if (_foreverSuppressedRidePopupIds.contains(trimmedId)) {
      return 'forever_suppressed_local';
    }
    final canonicalState =
        TripStateMachine.canonicalStateFromSnapshot(rideData);
    if (TripStateMachine.isTerminal(canonicalState)) {
      return 'trip_terminal_state';
    }
    if (TripStateMachine.uiStatusFromSnapshot(rideData) == 'cancelled') {
      return 'ride_cancelled';
    }
    if (_rideExpiredWithOfferGrace(rideData)) {
      return 'expired';
    }
    final driverIdValue = _valueAsText(rideData['driver_id']);
    final dTrim = driverIdValue.trim();
    final dLower = dTrim.toLowerCase();
    if (dTrim.isNotEmpty &&
        dLower != 'waiting' &&
        dTrim != _effectiveDriverId) {
      return 'driver_already_assigned';
    }
    if (TripStateMachine.isPendingDriverAssignmentState(canonicalState) &&
        driverIdValue != _effectiveDriverId) {
      return 'assigned_to_another_driver';
    }
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
      if (_isBackendTrustedOffer(rideId)) {
        return null;
      }
      _logPopupServerSkip(rideId, rideData, 'payload_not_map');
      return 'payload_not_map';
    }

    if (_isDeliveryOfferData(rideData)) {
      return _popupServerSkipReasonDeliveryOffer(rideId, rideData);
    }

    if (_isBackendTrustedOffer(rideId, rideData)) {
      return _popupServerSkipReasonBackendOffer(rideId, rideData);
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
    final fromOfferQueueStrict = rideData['__nexride_from_offer_queue'] == true;
    final rideMarket = fromOfferQueueStrict ? null : _rideMarketFromData(rideData);
    final driverMarket =
        fromOfferQueueStrict ? null : _canonicalDriverDispatchMarket();

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

    if (!fromOfferQueueStrict) {
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
    }

    if (_rideExpiredWithOfferGrace(rideData)) {
      _logPopupServerSkip(rideId, rideData, 'expired');
      return 'expired';
    }

    final expiresAt = _rideExpiryTimestamp(rideData);
    final nowTimestamp = DateTime.now().millisecondsSinceEpoch;

    final createdAt = _parseCreatedAt(rideData['created_at']);
    final requestedAt = _parseCreatedAt(rideData['requested_at']);
    final hasActiveSearchWindow =
        expiresAt > 0 && !_rideExpiredWithOfferGrace(rideData);
    // Server timestamps may still be placeholders in snapshots; a valid future
    // search window proves the request is live for dispatch.
    if (createdAt <= 0 && requestedAt <= 0 && !hasActiveSearchWindow) {
      _logPopupServerSkip(rideId, rideData, 'missing_created_at');
      return 'missing_created_at';
    }

    if (!fromOfferQueueStrict) {
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
      return 'Ride already accepted by another driver.';
    }

    if (blockedReason == 'driver_already_set' ||
        blockedReason == 'already_taken') {
      return 'Ride already accepted by another driver.';
    }

    return switch (blockedReason) {
      'driver_already_set' => 'Ride already taken',
      'already_taken' => 'Ride already taken',
      'assignment_expired' ||
      'expired' ||
      'driver_response_timeout' =>
        'Ride expired',
      'status_not_requesting' || 'transaction_not_committed' => 'Invalid state',
      'service_not_allowed' || 'service_type_not_enabled_for_driver' =>
        'Driver not eligible',
      'driver_session_lost' ||
      'driver_not_ready' =>
        'Your driver session needs to reconnect before you can accept rides.',
      'ride_missing' => 'Ride already taken',
      'unauthorized' => 'Driver not eligible',
      'invalid_input' => 'Invalid state',
      'accept_pending_retry' || 'transaction_conflict' =>
        'Could not confirm this ride yet. Tap ACCEPT once more.',
      'payment_not_dispatchable' ||
      'payment_pending' ||
      'payment_not_verified' =>
        'This request cannot be accepted until payment is ready.',
      _ => 'This request is no longer available.',
    };
  }

  bool _driverOfferRideStillAcceptable(
    Map<String, dynamic>? rideData,
    String driverId,
  ) {
    if (rideData == null || rideData.isEmpty) {
      return false;
    }
    final canonical = TripStateMachine.canonicalStateFromSnapshot(rideData);
    if (TripStateMachine.isTerminal(canonical)) {
      return false;
    }
    if (_rideAssignedToUid(rideData, driverId)) {
      return true;
    }
    return TripStateMachine.isPendingDriverAssignmentState(canonical) ||
        _valueAsText(rideData['status']).toLowerCase() == 'searching' ||
        _valueAsText(rideData['trip_state']).toLowerCase() == 'searching' ||
        _valueAsText(rideData['trip_state']).toLowerCase() == 'requesting';
  }

  bool _paymentAllowsAcceptRide(Map<String, dynamic>? rideData) {
    if (rideData == null || rideData.isEmpty) {
      return false;
    }
    final method = _paymentMethodFromRide(rideData).toLowerCase();
    final status = _valueAsText(rideData['payment_status']).toLowerCase();
    final settlement = _valueAsText(rideData['settlement_status']).toLowerCase();
    if (status == 'bank_transfer_expired' ||
        status == 'failed' ||
        status == 'declined') {
      return false;
    }
    if (_ridePaymentConfirmed(rideData)) {
      return true;
    }
    const reviewStatuses = <String>{
      'pending',
      'pending_transfer',
      'pending_manual_confirmation',
      'pending_review',
      'payment_review',
      'bank_transfer_pending',
      'automated_va',
      'in_review',
    };
    if (reviewStatuses.contains(status) || settlement == 'payment_review') {
      return true;
    }
    final automatedVa = rideData['bank_transfer_automated'] == true ||
        rideData['automated_va'] == true ||
        method == 'flutterwave_va';
    if (automatedVa && (status.isEmpty || reviewStatuses.contains(status))) {
      return true;
    }
    if (method == 'bank_transfer' && status == 'awaiting_transfer') {
      return true;
    }
    if (method == 'flutterwave_va' || method == 'flutterwave') {
      return true;
    }
    return false;
  }

  void _suppressPopupForeverAfterTerminalAcceptFailure(
    String rideId,
    String reason,
  ) {
    final normalized = reason.trim().toLowerCase();
    const terminal = <String>{
      'already_taken',
      'driver_already_set',
      'expired',
      'offer_withdrawn',
      'no_offer',
      'status_not_open',
      'payment_not_verified',
      'ride_missing',
      'driver_not_eligible',
      'driver_profile_missing',
      'not_available',
      'offer_market_mismatch',
      'offer_ride_mismatch',
    };
    if (!terminal.contains(normalized)) {
      return;
    }
    final id = rideId.trim();
    if (id.isEmpty) {
      return;
    }
    _foreverSuppressedRidePopupIds.add(id);
    _suppressedRidePopupIds.add(id);
    _handledRideIds.add(id);
    _presentedRideIds.remove(id);
    _logRideReq(
      '[POPUP_SUPPRESS_TERMINAL_ACCEPT] rideId=$id reason=$normalized',
    );
  }

  String _acceptFailureMessageFromException(Object error) {
    if (error is FirebaseFunctionsException) {
      final details = error.details;
      if (details is Map) {
        final reason = _valueAsText(details['reason']);
        if (reason.isNotEmpty) {
          return _acceptBlockedMessage(
            blockedReason: reason,
            rideData: _currentRideData,
            rideId: _currentRideId,
          );
        }
      }
      if (error.message != null && error.message!.trim().isNotEmpty) {
        return error.message!.trim();
      }
    }
    return 'Unable to accept this ride right now.';
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

  bool _isMultiStopRideMap(Map<String, dynamic>? rideData) {
    if (rideData == null || rideData.isEmpty) {
      return false;
    }
    final stopCount =
        _asInt(rideData['stop_count'] ?? rideData['stopCount']) ?? 0;
    if (stopCount > 1) {
      return true;
    }
    return _orderedStopsFromRide(rideData).isNotEmpty;
  }

  List<_TripWaypoint> _driverFacingRemainingStops() {
    if (_tripWaypoints.isEmpty) {
      return const <_TripWaypoint>[];
    }
    final index = _manualTripStopIndex.clamp(0, _tripWaypoints.length - 1);
    return _tripWaypoints.sublist(index);
  }

  bool get _hasPendingTripStopsBeforeFinal {
    if (_tripWaypoints.length <= 1) {
      return false;
    }
    return _manualTripStopIndex < _tripWaypoints.length - 1;
  }

  String _tripWaypointsSignatureFrom(List<_TripWaypoint> waypoints) {
    if (waypoints.isEmpty) {
      return '';
    }
    return waypoints
        .map(
          (_TripWaypoint w) =>
              '${w.location.latitude.toStringAsFixed(5)},${w.location.longitude.toStringAsFixed(5)}:${w.address}',
        )
        .join('|');
  }

  String _rideTripProgressActionLabel(String serviceType) {
    if (!_hasPendingTripStopsBeforeFinal) {
      return _serviceCompleteActionLabel(serviceType);
    }
    final remaining = _driverFacingRemainingStops();
    final stopNumber = _tripWaypoints.length - remaining.length + 1;
    final isFinalLeg = remaining.length == 1;
    if (isFinalLeg) {
      return 'Arrived at destination';
    }
    return 'Arrived at stop $stopNumber';
  }

  Future<void> _handleTripProgressAction() async {
    if (_hasPendingTripStopsBeforeFinal) {
      if (!mounted) {
        return;
      }
      setState(() {
        _manualTripStopIndex =
            (_manualTripStopIndex + 1).clamp(0, _tripWaypoints.length - 1);
        final remaining = _driverFacingRemainingStops();
        _nextNavigationTarget = remaining.isNotEmpty
            ? remaining.first.location
            : _destinationLocation;
      });
      debugPrint(
        'DRIVER_TRIP_STOP_ARRIVED index=$_manualTripStopIndex '
        'total=${_tripWaypoints.length}',
      );
      final hasMoreStops = _hasPendingTripStopsBeforeFinal;
      _showSnackBarSafely(
        SnackBar(
          content: Text(
            hasMoreStops
                ? 'Stop marked. Continue to the next stop.'
                : 'Final destination reached. You can complete the trip.',
          ),
        ),
      );
      return;
    }
    await completeTrip();
  }

  Widget _buildRoundTripBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _gold.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _gold.withValues(alpha: 0.45)),
      ),
      child: const Row(
        children: [
          Icon(Icons.sync_alt_rounded, color: Colors.black87, size: 20),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'ROUND TRIP / 2-WAY TRIP',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: Colors.black87,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTripItinerarySection({
    required Map<String, dynamic> rideData,
    required String pickupAddress,
    required String finalDestinationAddress,
  }) {
    if (!_isMultiStopRideMap(rideData)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.my_location, color: Colors.green, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(pickupAddress, style: const TextStyle(height: 1.25)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.location_on, color: Colors.red, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  finalDestinationAddress,
                  style: const TextStyle(height: 1.25),
                ),
              ),
            ],
          ),
        ],
      );
    }

    final intermediateStops = _orderedStopsFromRide(rideData);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildRoundTripBanner(),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.my_location, color: Colors.green, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Pickup',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                      color: Colors.black54,
                    ),
                  ),
                  Text(pickupAddress, style: const TextStyle(height: 1.25)),
                ],
              ),
            ),
          ],
        ),
        for (var i = 0; i < intermediateStops.length; i++) ...[
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.place_outlined, color: _gold, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Stop ${i + 1}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                        color: Colors.black54,
                      ),
                    ),
                    Text(
                      _valueAsText(intermediateStops[i]['address']).isNotEmpty
                          ? _valueAsText(intermediateStops[i]['address'])
                          : 'Stop ${i + 1}',
                      style: const TextStyle(height: 1.25),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.flag_rounded, color: Colors.red, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Final destination / Return destination',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                      color: Colors.black54,
                    ),
                  ),
                  Text(
                    finalDestinationAddress,
                    style: const TextStyle(height: 1.25),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _tripMarkersSignature() {
    final pickup = _pickupLocation;
    final destination = _destinationLocation;
    final waypointKeys = _tripWaypoints
        .map((waypoint) => _latLngKey(waypoint.location))
        .join('|');
    return '${pickup != null ? _latLngKey(pickup) : ''}|'
        '${destination != null ? _latLngKey(destination) : ''}|'
        '$waypointKeys|$_rideStatus';
  }

  void _syncTripLocationMarkersIfChanged() {
    final signature = _tripMarkersSignature();
    if (signature == _lastTripMarkersSignature) {
      return;
    }
    _lastTripMarkersSignature = signature;
    _syncTripLocationMarkers();
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
          icon: _markerIconPickup,
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
          icon: isFinal ? _markerIconDestination : _markerIconStop,
        ),
      );
    }
  }

  void _resetAllRideState() {
    _cancelPendingRouteRequests(reason: 'reset_all_ride_state');
    _clearRidePopupTimer();
    _activeTripUiDebounceTimer?.cancel();
    _activeTripUiDebounceTimer = null;
    _activeTripUiPendingRideId = null;
    _activeTripUiPendingStatus = null;
    _activeTripUiPendingRideData = null;
    _lastTripMarkersSignature = null;
    _stopActiveRideListener();
    _resetDriverChatState();
    _resetSocketApplyDedup();
    _stopDriverSafetyMonitoring();
    _callSubscription?.cancel();
    _callSubscription = null;
    _rideCallMirrorSubscription?.cancel();
    _rideCallMirrorSubscription = null;
    _detachSharedCallListener();
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
      final terminalRideId = _firstNonEmptyText(<dynamic>[
        _currentRideId,
        _driverActiveRideId,
        _activePopupRideId,
        _sessionTrackedRideId,
      ]).trim();
      _clearOfferPopupState(
        reason: 'reset_all_ride_state',
        rideId: terminalRideId.isEmpty ? null : terminalRideId,
        clearQueue: true,
        clearEntireCache: true,
        dismissVisibleDialog: true,
        clearCurrentRidePointer: true,
      );
      _currentRideId = null;
      _sessionTrackedRideId = null;
      _currentRideData = null;
      _driverActiveRideId = null;
      _currentCandidateRideId = null;
      _pendingStaleRidePurgeKey = null;
      _completedStaleRidePurgeKey = null;
      _rideStatus = _isOnline ? 'idle' : 'offline';
      _tripStarted = false;
      _driverUnreadChatCount = 0;
      _driverChatUnreadNotifier.value = 0;
      _isDriverChatOpen = false;
      _pickupLocation = null;
      _destinationLocation = null;
      _nextNavigationTarget = null;
      _pickupAddressText = '';
      _destinationAddressText = '';
      _riderName = 'Rider';
      _riderPhone = '';
      _riderPhotoUrl = '';
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
      _showArrivedButton = false;
      _arrivedDisabledReason = '';
      _deliveryProofUploading = false;
      _deliveryProofUploadProgress = 0;
      _activeSafetyPromptMessage = null;
      _manualTripStopIndex = 0;
      _tripWaypointsSignature = '';
      _tripWaypoints.clear();
      _expectedRoutePoints.clear();
      _polyLines.clear();
      _markers.clear();
      _loadedRiderProfileKey = null;
      _hasLoggedArrivedEnabled = false;
      _lastRouteBuildKey = '';
      _activeRouteRideId = null;
      _lastBuiltRouteStatus = null;
      _lastAppliedRouteTargetKey = null;
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
    final previousRideId = _activeRideListenerRideId?.trim();
    if (previousRideId != null && previousRideId.isNotEmpty) {
      RidePipelineGuard.releaseRideListener(
        rideId: previousRideId,
        owner: 'DriverMapScreen',
        path: 'ride_requests/$previousRideId',
        role: 'driver',
      );
      unawaited(
        _rtdbListenerHub.cancel('ride_requests/$previousRideId/onValue'),
      );
    }
    _activeRideSubscription?.cancel();
    _activeRideSubscription = null;
    _activeRideListenerRideId = null;
    _activeTripUiDebounceTimer?.cancel();
    _activeTripUiDebounceTimer = null;
    _logResourceCounts('active_trip_listener_stop');
  }

  Future<void> _clearStaleDriverActiveRideSession({
    required String reason,
    String? rideId,
    String source = 'stale_active_ride',
  }) async {
    final driverId = _effectiveDriverId;
    final normalizedRideId = (rideId ?? _currentRideId ?? _driverActiveRideId)
        ?.trim();
    if (normalizedRideId != null && normalizedRideId.isNotEmpty) {
      DriverActiveRideRestoreSupport.logRestoreClearLocal(
        rideId: normalizedRideId,
        reason: reason,
      );
      _startupRejectedRestoreRideIds.add(normalizedRideId);
    }
    DriverActiveRideRestoreSupport.traceCleared(
      driverId: driverId,
      rideId: normalizedRideId,
      reason: reason,
      source: source,
    );

    _socketStatus = 'disconnected';
    _discoverySuspendedForRideId = null;
    _driverActiveRideId = null;

    if (normalizedRideId != null && normalizedRideId.isNotEmpty) {
      RidePipelineGuard.releaseRideListener(
        rideId: normalizedRideId,
        owner: 'DriverMapScreen',
        path: 'ride_requests/$normalizedRideId',
        role: 'driver',
      );
      RidePipelineGuard.releaseChatListener(
        rideId: normalizedRideId,
        owner: 'DriverMapScreen',
      );
      RidePipelineGuard.releaseCallListener(
        rideId: normalizedRideId,
        owner: 'DriverMapScreen',
      );
    }

    _stopActiveRideListener();
    _stopDriverChatListener();
    if (_callListenerRideId != null) {
      await _callSubscription?.cancel();
      _callSubscription = null;
      _callListenerRideId = null;
    }

    await _clearActiveRideState(reason: reason, resetTripState: true);

    if (driverId.isNotEmpty) {
      await _updateDriverRecordSafely(
        driverId: driverId,
        source: source,
        updates: <String, Object?>{
          'activeRideId': null,
          'currentRideId': null,
          'updated_at': rtdb.ServerValue.timestamp,
        },
      );
    }
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

    if (rideUpdates.isNotEmpty) {
      _logRtdb(
        '[RTDB_WRITE] blocked ride_requests lifecycle write rideId=$rideId '
        'keys=${rideUpdates.keys.join(",")} (backend authority only)',
      );
    }

    if (driverUpdates.isNotEmpty) {
      try {
        await runInstrumentedRtdbUpdate(
          path: 'drivers/$driverId',
          source: 'commit_ride_driver_update',
          role: 'driver',
          updates: driverUpdates,
          action: (sanitized) => _driversRef.child(driverId).update(sanitized),
        );
      } catch (error) {
        final code = error is FirebaseException ? error.code : 'unknown';
        _logRtdb(
          '[RTDB_WRITE] phase=error operation=driver_update rideId=$rideId '
          'uid=$driverId code=$code error=$error',
        );
        rethrow;
      }
    }

    if (clearActiveRide || activeRideUpdates != null) {
      _logRtdb(
        '[MATCH_DEBUG][CANONICAL_RIDE_ONLY] skipped legacy driver_active_ride '
        'rideId=$rideId clearActiveRide=$clearActiveRide',
      );
    }
  }

  /// Success for [drivers] presence only — ride_requests is CF-owned on accept.
  Future<bool> _commitCriticalRideAndDriverSnapshot({
    required String rideId,
    required Map<String, dynamic> rideUpdates,
    required Map<String, Object?> driverUpdates,
  }) async {
    final driverId = _effectiveDriverId;
    if (driverId.isEmpty) {
      return false;
    }

    if (driverUpdates.isEmpty) {
      return true;
    }

    _logRtdb(
      'critical post-accept driver update start rideId=$rideId '
      'driverKeys=${driverUpdates.keys.length}',
    );
    try {
      await runInstrumentedRtdbUpdate(
        path: 'drivers/$driverId',
        source: 'critical_post_accept_driver_update',
        role: 'driver',
        updates: driverUpdates,
        action: (sanitized) => _driversRef.child(driverId).update(sanitized),
      );
      _logRtdb('critical post-accept driver update success rideId=$rideId');
      return true;
    } catch (error) {
      final code = error is FirebaseException ? error.code : 'unknown';
      _logRtdb(
        '[RTDB_WRITE] phase=error operation=critical_post_accept_driver_update '
        'rideId=$rideId uid=$driverId code=$code error=$error',
      );
      _logRtdb(
          'critical post-accept driver update failure rideId=$rideId error=$error');
      return false;
    }
  }

  void _scheduleOptionalPostAcceptRtdbMirrors({
    required String rideId,
    required String committedStatus,
    required String committedCanonicalForCommit,
    required Map<String, dynamic> rideData,
  }) {
    // admin_rides / support_queue / latest_trip mirrors are Cloud Function authority.
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
      if (publishedOnline && isAvailable && !hasActiveRide)
        'dispatch_state': status == 'online_available'
            ? 'online_available'
            : status,
      'activeRideId': hasActiveRide ? normalizedRideId : null,
      'currentRideId': hasActiveRide ? normalizedRideId : null,
      'active_ride_id': hasActiveRide ? normalizedRideId : null,
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
      _pinPendingOfferPopupRideId(rideId);
      _driverUnreadChatCount = 0;
      _driverChatUnreadNotifier.value = 0;
      _isDriverChatOpen = false;
    }

    if (mounted) {
      setState(applyState);
    } else {
      applyState();
    }

    _applyRideLocationsFromData(rideData);
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

    if (resetLocalState &&
        (_driverActiveRideId == rideId || _currentRideId == rideId)) {
      await _clearActiveRideState(
        reason: reason,
        resetTripState: true,
      );
    }
    _clearPendingOfferPopupRideId(rideId);

    _logRtdb('assignment release local rideId=$rideId reason=$reason');
    return true;
  }

  Future<void> _startDriverActiveRideListener() async {
    dispatchVerboseLog('DISPATCH_ATTACH_START');
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
      final driverSnapshot = await runRtdbQueryGet(
        query: _driversRef.child(driverId),
        path: 'drivers/$driverId',
        source: 'driver_map.recover_driver_ride',
      );
      final recoveredRide = await _recoverDriverRideFromBackend(
        driverId: driverId,
        driverRecord:
            _asStringDynamicMap(driverSnapshot.value) ?? <String, dynamic>{},
        activeRideMarker: null,
      );
      if (recoveredRide != null) {
        final rejectReason = _evaluateDriverRestoreRejectReason(
          rideData: recoveredRide.rideData,
          driverId: driverId,
          rideId: recoveredRide.rideId,
          source: 'dispatch_attach',
        );
        if (rejectReason != null) {
          await _clearStaleDriverActiveRideSession(
            rideId: recoveredRide.rideId,
            reason: rejectReason,
            source: 'dispatch_attach',
          );
        } else {
          _driverActiveRideId = recoveredRide.rideId;
          dispatchVerboseLog('DISPATCH_ATTACH_SUCCESS');
          _clearDiscoveryPermissionDeniedNotice(
            source: 'dispatch_attach_success_recovered_ride',
          );
          await _listenToActiveRide(recoveredRide.rideId);
        }
      } else {
        dispatchVerboseLog('DISPATCH_ATTACH_SUCCESS');
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
    if (_shouldSuppressCommittedActiveRideClear(
      reason: 'invalid_ride_ui',
      rideData: _currentRideData,
      rideId: _currentRideId ?? _driverActiveRideId,
    )) {
      _logValidation(
        'invalid ride ui clear suppressed rideId=${_currentRideId ?? _driverActiveRideId}',
      );
      return;
    }
    if (!_hasActiveTripUiState()) {
      if (_lastNoValidActiveRideClearKey == _idleNoValidActiveRideClearKey()) {
        return;
      }
      _lastNoValidActiveRideClearKey = _idleNoValidActiveRideClearKey();
      return;
    }
    _resetAllRideState();
    _lastNoValidActiveRideClearKey = _idleNoValidActiveRideClearKey();
    _logGuard('UI cleared due to invalid ride');
    _logUi('cleared invalid ride state');
  }

  Future<void> _cancelRideRequestListener({
    required String reason,
    String? rebindReason,
  }) async {
    final hadListener = _rideRequestSubscription != null ||
        _driverOfferQueueChildChangedSubscription != null ||
        _driverOfferQueueChildRemovedSubscription != null;
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
    final changedSub = _driverOfferQueueChildChangedSubscription;
    final removedSub = _driverOfferQueueChildRemovedSubscription;
    final deliveryAddedSub = _deliveryOfferQueueChildAddedSubscription;
    final deliveryRemovedSub = _deliveryOfferQueueChildRemovedSubscription;
    final boundUid = _driverOfferQueueBoundUid?.trim();
    final deliveryUid = _deliveryOfferQueueBoundUid?.trim();
    _rideRequestSubscription = null;
    _driverOfferQueueChildChangedSubscription = null;
    _driverOfferQueueChildRemovedSubscription = null;
    _deliveryOfferQueueChildAddedSubscription = null;
    _deliveryOfferQueueChildRemovedSubscription = null;
    _driverOfferQueueReplica.clear();
    _socketStatus = 'disconnected';
    _setApiStatus('idle');
    _rideRequestsListenerBoundCity = null;
    _driverOfferQueueBoundUid = null;
    _deliveryOfferQueueBoundUid = null;
    _boundOfferQueueProcessor = null;
    _boundOfferQueueListenerToken = 0;
    await subscription?.cancel();
    await changedSub?.cancel();
    await removedSub?.cancel();
    await deliveryAddedSub?.cancel();
    await deliveryRemovedSub?.cancel();
    if (boundUid != null && boundUid.isNotEmpty) {
      await _rtdbListenerHub.cancel('driver_offer_queue/$boundUid/onChildAdded');
      await _rtdbListenerHub.cancel(
        'driver_offer_queue/$boundUid/onChildChanged',
      );
      await _rtdbListenerHub.cancel(
        'driver_offer_queue/$boundUid/onChildRemoved',
      );
    }
    if (deliveryUid != null && deliveryUid.isNotEmpty) {
      await _rtdbListenerHub.cancel(
        'delivery_offer_queue/$deliveryUid/onChildAdded',
      );
      await _rtdbListenerHub.cancel(
        'delivery_offer_queue/$deliveryUid/onChildRemoved',
      );
    }
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
      debugPrint(
        'DRIVER_OFFER_LISTENER_CANCEL source=$reason driverId=${_effectiveDriverId} '
        'market=${previousCity ?? 'none'}',
      );
      _log(
        'request listener cancelled reason=$reason token=$invalidatedToken market=${previousCity ?? 'none'}',
      );
    }
    _logResourceCounts('offer_listener_cancel');
    final rebound = rebindReason?.trim();
    if (rebound != null &&
        rebound.isNotEmpty &&
        _isOnline &&
        !_isDisposing &&
        !_hasActiveJobBlockingNewOffers() &&
        !_hasActiveDelivery) {
      await _listenForRideRequests(reason: rebound);
      debugPrint(
        'DRIVER_OFFER_QUEUE_RESUBSCRIBED driverId=${_effectiveDriverId} '
        'reason=$rebound source=cancel_rebind',
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
    _pendingOfferPopupRideId = null;
    _resetIdleRideClearDedup(source: 'hard_reset_before_listener_attach');
    _resetAllRideState();

    _lastTripPanelHiddenReason = null;
    _lastValidationBlockedKey = null;
    _presentedRideIds.clear();
    _timedOutRideIds.clear();
    _declinedRideIds.clear();
    _handledRideIds.clear();
    _suppressedRidePopupIds.clear();
    _lastDiscoveryDismissFingerprintByRideId.clear();
    _discoveryPopupCooldownUntilMs.clear();
    _loggedDriverOfferReceivedRideIds.clear();
    _rideRequestPopupQueue.clear();
    _onlineSessionStartedAt = 0;
    _logRtdb('hard reset before listener attach');
  }

  Future<void> _hardResetToFreshSearchSession({
    required String reason,
  }) async {
    _pendingOfferPopupRideId = null;
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
    final normalizedReason = reason.trim().toLowerCase();
    if (normalizedReason.contains('ride_missing') &&
        rideId != null &&
        rideId.trim().isNotEmpty &&
        _shouldIgnoreTransientRideMissing(
          rideId: rideId,
          rideData: _currentRideData,
        )) {
      return;
    }
    if (_isCommittedActiveRideForDriver(_currentRideData, rideId: rideId) &&
        !normalizedReason.contains('cancel') &&
        !normalizedReason.contains('complete') &&
        !normalizedReason.contains('expired')) {
      _logValidation(
        'active ride clear suppressed rideId=$rideId reason=$reason',
      );
      return;
    }
    if (_isNoValidActiveRideClearReason(reason) &&
        _alreadyClearedIdleNoValidActiveRide(reason) &&
        !_hasStaleActiveTripLocalState()) {
      return;
    }
    if (_shouldSuppressCommittedActiveRideClear(
      reason: reason,
      rideData: _currentRideData,
      rideId: rideId,
    )) {
      _logValidation(
        'active ride clear suppressed rideId=$rideId reason=$reason',
      );
      return;
    }
    if (_isNoValidActiveRideClearReason(reason) &&
        !_hasStaleActiveTripLocalState()) {
      _lastNoValidActiveRideClearKey = _idleNoValidActiveRideClearKey();
      return;
    }
    if (normalizedReason.contains('cancel') ||
        normalizedReason.contains('complete') ||
        normalizedReason.contains('expired') ||
        normalizedReason.contains('terminal')) {
      _clearOfferPopupState(
        reason: 'active_ride_clear:$reason',
        rideId: rideId,
        dismissVisibleDialog: true,
        clearEntireCache: false,
        clearQueue: true,
      );
      _stopActiveRideListener();
    }
    _driverEnrouteCloudSentRideId = null;
    if (rideId != null && rideId.isNotEmpty) {
      final normalizedReason = reason.toLowerCase();
      if (normalizedReason.contains('cancel') ||
          normalizedReason.contains('complete') ||
          normalizedReason.contains('expired')) {
        await _endCallForRideLifecycle(
          rideId: rideId,
          lifecycleReason: 'active_ride_clear_$normalizedReason',
        );
      } else if (!resetTripState) {
        await _performLocalCallCleanup(
          rideId: rideId,
          cleanupSource: 'clear_active_ride_state',
          endReason: reason,
          logCleanup: false,
        );
      }
    }

    _logRtdb('active ride cleared reason=$reason');
    _cancelWaitFeeGraceTimer(reason: reason);
    _logTripPanelHidden(reason);
    if (resetTripState) {
      if (_isTerminalTripEligibilityRefreshReason(reason)) {
        await _resetTripState();
        final resumeSource = reason.contains('driver_cancel')
            ? 'driver_cancel'
            : reason;
        await _restoreDriverMatchingEligibilityAfterTerminalTrip(
          source: resumeSource,
          rideId: rideId,
        );
      } else {
        await _resetTripState();
      }
    } else {
      _clearInvalidRideUiState();
    }
    if (_isNoValidActiveRideClearReason(reason)) {
      _lastNoValidActiveRideClearKey = _idleNoValidActiveRideClearKey();
    }

    _logListenerStillActiveWaitingForFreshRides();
  }

  Future<void> _listenToActiveRide(String rideId) async {
    final rid = rideId.trim();
    if (!_isValidRideId(rid)) {
      return;
    }
    final pathKey = 'ride_requests/$rid/onValue';

    if (_activeRideListenerRideId == rid &&
        _rtdbListenerHub.isAttached(pathKey)) {
      debugPrint('DRIVER_LISTENER_SKIP_DUPLICATE path=$pathKey');
      return;
    }

    final previousRideId = _activeRideListenerRideId?.trim();
    if (previousRideId != null &&
        previousRideId.isNotEmpty &&
        previousRideId != rid) {
      RidePipelineGuard.releaseRideListener(
        rideId: previousRideId,
        owner: 'DriverMapScreen',
        path: 'ride_requests/$previousRideId',
        role: 'driver',
      );
      await _rtdbListenerHub.cancel('ride_requests/$previousRideId/onValue');
      await _activeRideSubscription?.cancel();
      RtdbResourceGuard.onListenerDisposed();
    }

    _activeRideSubscription = null;
    _activeRideListenerRideId = rid;
    RidePipelineGuard.assertRideListenerAttach(
      rideId: rid,
      owner: 'DriverMapScreen',
      path: 'ride_requests/$rid',
      role: 'driver',
    );
    _log('ACTIVE_TRIP_LISTENER_ATTACHED rideId=$rid');
    _logRideReq(
      '[MATCH_DEBUG][QUERY_ATTACH:ride_requests/$rid] active_ride onValue',
    );
    final attached = await _rtdbListenerHub.attachOnValue(
      pathKey: pathKey,
      query: _rideRequestsRef.child(rid),
      onData: (rtdb.DatabaseEvent event) async {
        try {
          if (_activeRideListenerRideId != rid) {
            return;
          }

          final rawRideData = _asStringDynamicMap(event.snapshot.value);
          if (rawRideData == null) {
            if (_shouldIgnoreTransientRideMissing(
              rideId: rid,
              rideData: _currentRideData,
            )) {
              dispatchVerboseLog('RIDE_STATE_PROPAGATION_WAIT rideId=$rid');
              return;
            }
            _logInvalidRideBlocked(rideId: rid, reason: 'ride_missing');
            await _clearDriverActiveRideNode(
              rideId: rid,
              reason: 'ride_missing',
            );
            await _clearActiveRideState(
              reason: 'ride_missing',
              resetTripState: true,
            );
            return;
          }

          final rideData = _coalesceRideListenerSnapshot(
            rideId: rid,
            incoming: rawRideData,
          );
          final status = TripStateMachine.uiStatusFromSnapshot(rideData);
          final paymentKey = _ridePaymentFingerprint(rideData);
          if (_shouldSkipDuplicateRideApply(
            rideId: rid,
            status: status,
            paymentKey: paymentKey,
          )) {
            return;
          }

          if (!_rideAssignedToUid(rideData, _currentAuthUid)) {
            _logInvalidRideBlocked(rideId: rid, reason: 'driver_mismatch');
            await _hardResetToFreshSearchSession(
              reason: 'not_assigned_to_driver',
            );
            return;
          }

          final staleReason =
              DriverActiveRideRestoreSupport.staleRestoreReason(
            rideData: rideData,
            driverId: _currentAuthUid,
            rideId: rid,
          );
          if (staleReason != null) {
            DriverActiveRideRestoreSupport.traceStale(
              driverId: _currentAuthUid,
              rideId: rid,
              reason: staleReason,
              source: 'active_ride_listener',
            );
            await _clearStaleDriverActiveRideSession(
              rideId: rid,
              reason: staleReason,
              source: 'active_ride_listener',
            );
            return;
          }

          _clearDiscoveryPermissionDeniedNotice(
            source: 'active_ride_listener_valid_assignment',
          );
          if (_serviceTypeKey(_valueAsText(rideData['service_type'])) ==
              'dispatch_delivery') {
            dispatchVerboseLog('DISPATCH_REQUEST_RECEIVED');
          }

          final canonicalState = TripStateMachine.canonicalStateFromSnapshot(
            rideData,
          );
          if (TripStateMachine.isPendingDriverAssignmentState(canonicalState)) {
            if (!_isOnline) {
              _log(
                'pending ride popup suppressed because driver is offline rideId=$rid',
              );
              return;
            }
            if (_assignmentHasExpired(rideData)) {
              await _releaseAssignedRideIfNeeded(
                rideId: rid,
                reason: 'assignment_expired',
              );
              return;
            }

            _syncPendingRidePreviewLocalState(
              rideId: rid,
              rideData: rideData,
            );
            _logRideReq(
              '[MATCH_DEBUG][POPUP_SUPPRESSED_PENDING_STATE] rideId=$rid '
              'source=active_ride_child_listener_pending',
            );
            return;
          }

          if (await _autoCancelRideForLifecycleTimeoutIfNeeded(
            rideId: rid,
            rideData: rideData,
            source: 'active_ride_listener',
          )) {
            return;
          }

          final invalidReason = _activeRideInvalidReason(
            rideData,
            rideId: rid,
          );
          if (invalidReason != null &&
              !_isCommittedActiveRideForDriver(rideData, rideId: rid)) {
            _logInvalidRideBlocked(rideId: rid, reason: invalidReason);
            if (_isRideCancellationInvalidReason(invalidReason) && mounted) {
              if (!_isDriverCancellingRide) {
                callTraceLog(
                  'CANCEL_REMOTE_RECEIVED',
                  rideId: rid,
                  role: 'driver',
                );
              }
              _showSnackBarSafely(
                SnackBar(
                  content: Text(_driverCancellationSnackMessage(rideData)),
                ),
              );
            }
            await _clearDriverActiveRideNode(
              rideId: rid,
              reason: invalidReason,
            );
            await _clearActiveRideState(
              reason: invalidReason,
              resetTripState: true,
            );
            return;
          }

          await _applyActiveRideSnapshot(
            rideId: rid,
            rideData: rideData,
            status: status,
          );
        } catch (error) {
          _log(
              'active ride snapshot handling failed rideId=$rid error=$error');
        }
      },
      onError: (Object error) {
        _log('active ride listener error rideId=$rid error=$error');
      },
    );
    if (attached) {
      _activeRideSubscription = _rtdbListenerHub.subscriptionFor(pathKey);
      RtdbResourceGuard.onListenerAttached();
      _logResourceCounts('active_trip_listener_attach');
    }
  }

  void _applyRideLocationsFromData(Map<String, dynamic> rideData) {
    final pickup = _pickupLatLngFromRideData(rideData);
    final waypoints = _orderedTripWaypoints(rideData);
    final nextSignature = _tripWaypointsSignatureFrom(waypoints);
    final itineraryChanged = nextSignature != _tripWaypointsSignature;

    _pickupLocation = pickup;
    if (itineraryChanged) {
      _manualTripStopIndex = 0;
      _tripWaypointsSignature = nextSignature;
    }
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
    _syncTripLocationMarkersIfChanged();
  }

  void _syncRiderDisplayFromRideSnapshot({
    required String rideId,
    required Map<String, dynamic> rideData,
  }) {
    final riderId = _valueAsText(rideData['rider_id']);
    final profileKey = '$rideId:$riderId';
    if (_loadedRiderProfileKey == profileKey) {
      return;
    }
    _loadedRiderProfileKey = profileKey;
    _applyRiderTrustSnapshot(rideData, loading: false);
    // The ride payload is the primary source (rider_photo_url / rider_phone are
    // denormalized at create time). If either is still missing — e.g. an older
    // ride — fall back to the rider profile under users/{riderId}.
    if (_riderPhotoUrl.trim().isEmpty || _riderPhone.trim().isEmpty) {
      unawaited(_enrichRiderProfileFromUsersNode(riderId));
    }
  }

  Future<void> _enrichRiderProfileFromUsersNode(String riderId) async {
    final id = riderId.trim();
    if (id.isEmpty || _enrichedRiderProfileKey == id) return;
    _enrichedRiderProfileKey = id;
    try {
      final snap = await rtdb.FirebaseDatabase.instance
          .ref('users/$id')
          .get()
          .timeout(const Duration(seconds: 8));
      if (!snap.exists || snap.value is! Map) return;
      final data = Map<String, dynamic>.from(snap.value as Map);
      final photo = _valueAsText(data['profilePhotoUrl']).isNotEmpty
          ? _valueAsText(data['profilePhotoUrl'])
          : (_valueAsText(data['photoUrl']).isNotEmpty
              ? _valueAsText(data['photoUrl'])
              : _valueAsText(data['photo_url']));
      final phone = _valueAsText(data['phone']).isNotEmpty
          ? _valueAsText(data['phone'])
          : _valueAsText(data['phoneNumber']);
      void apply() {
        if (_riderPhotoUrl.trim().isEmpty && photo.isNotEmpty) {
          _riderPhotoUrl = photo;
        }
        if (_riderPhone.trim().isEmpty && phone.isNotEmpty) {
          _riderPhone = phone;
        }
      }

      if (mounted) {
        setState(apply);
      } else {
        apply();
      }
      _log(
        'RIDER_IDENTITY_ENRICHED_FROM_USERS riderId=$id '
        'photo=${photo.isNotEmpty} phone=${phone.isNotEmpty}',
      );
    } catch (error) {
      _log('RIDER_IDENTITY_ENRICH_FAIL riderId=$id error=$error');
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
      final rid = _currentRideId!.trim();
      if (_isCommittedActiveRideForDriver(_currentRideData, rideId: rid)) {
        return;
      }
      _clearStaleLocalTripBlockersAfterOfferTerminal(rid);
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

  bool _sameRideChatMessage(RideChatMessage a, RideChatMessage b) {
    return a.id == b.id &&
        a.text == b.text &&
        a.status == b.status &&
        a.createdAt == b.createdAt &&
        a.senderId == b.senderId &&
        a.senderRole == b.senderRole &&
        a.imageUrl == b.imageUrl &&
        a.isRead == b.isRead;
  }

  bool _driverChatUiWantsUpdates(String rideId) {
    final normalizedRideId = rideId.trim();
    if (normalizedRideId.isEmpty) {
      return false;
    }
    if (_driverChatListenerRideId == normalizedRideId) {
      return true;
    }
    if (_isDriverChatSessionActive(normalizedRideId)) {
      return true;
    }
    if (_isDriverChatOpen &&
        _activeDriverRideContextId?.trim() == normalizedRideId) {
      return true;
    }
    return false;
  }

  void _setDriverChatMessages(
    String rideId,
    List<RideChatMessage> messages,
  ) {
    final normalizedRideId = rideId.trim();
    if (normalizedRideId.isEmpty) {
      return;
    }
    if (!_driverChatUiWantsUpdates(normalizedRideId)) {
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
    _log(
      'CHAT_LOCAL_ACK role=driver rideId=$r clientMessageId=$id',
    );
    if (_driverChatUiWantsUpdates(r)) {
      _flushDriverChatMessageTable(r);
    }
  }

  RideChatMessage? _findDriverChatMessageForAck(RideChatMessage incoming) {
    final direct = _driverChatMessagesById[incoming.id];
    if (direct != null) {
      return direct;
    }
    for (final candidate in _driverChatMessagesById.values) {
      if (candidate.localTempId.isEmpty) {
        continue;
      }
      if (candidate.localTempId == incoming.localTempId ||
          candidate.localTempId == incoming.id ||
          candidate.id == incoming.localTempId) {
        return candidate;
      }
    }
    return null;
  }

  void _markDriverOptimisticMessageFailed({
    required String rideId,
    required String messageId,
    required String senderId,
    required String text,
  }) {
    final r = rideId.trim();
    final id = messageId.trim();
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
    if (_driverChatUiWantsUpdates(r)) {
      _flushDriverChatMessageTable(r);
    }
  }

  void _logDriverChatRenderSummary(String rideId) {
    final normalizedRideId = rideId.trim();
    final ids = sortedRideChatMessagesFromMap(_driverChatMessagesById)
        .map((message) => message.id)
        .toList();
    _log(
      'DRIVER_CHAT_RENDER count=${ids.length} ids=[${formatRideChatKnownIds(ids)}] '
      'rideId=$normalizedRideId notifierCount=${_driverChatMessages.value.length}',
    );
  }

  void _ingestDriverChatRtdbMessage({
    required String normalizedRideId,
    required String messageId,
    required dynamic raw,
    required String source,
  }) {
    if (_driverChatListenerRideId != normalizedRideId) {
      return;
    }
    final trimmedId = messageId.trim();
    if (trimmedId.isEmpty) {
      return;
    }

    RideChatMessage? message;
    try {
      message = parseRideChatMessageEntry(
        rideId: normalizedRideId,
        messageId: trimmedId,
        raw: raw,
      );
    } catch (error) {
      _log(
        'CHAT_IMAGE_PARSE_FAIL role=driver rideId=$normalizedRideId '
        'messageId=$trimmedId source=$source error=$error',
      );
      rethrow;
    }
    if (message == null) {
      if (raw is Map) {
        final map = <String, dynamic>{};
        raw.forEach((key, value) {
          if (key != null) {
            map[key.toString()] = value;
          }
        });
        final imageUrl = rawRideChatImageUrlFromMap(map);
        if (imageUrl != null) {
          _log(
            'CHAT_IMAGE_PARSE_FAIL role=driver rideId=$normalizedRideId '
            'messageId=$trimmedId source=$source imageUrl=$imageUrl '
            'reason=parse_returned_null',
          );
          throw StateError('ride_chat_image_parse_returned_null');
        }
      }
      _log(
        'DRIVER_CHAT_MESSAGE_FILTERED rideId=$normalizedRideId messageId=$trimmedId '
        'reason=parse_failed source=$source',
      );
      return;
    }

    final driverId = _effectiveDriverId;
    final isIncoming = message.senderRole == 'rider' ||
        (message.senderId.isNotEmpty && message.senderId != driverId);
    final preview = message.text.length > 48
        ? '${message.text.substring(0, 48)}…'
        : message.text;
    _log(
      'DRIVER_CHAT_MESSAGE_ACCEPT rideId=$normalizedRideId messageId=$trimmedId '
      'senderRole=${message.senderRole} senderId=${message.senderId} '
      'status=${message.status} text=$preview source=$source',
    );
    _log(
      'CHAT_LISTENER_EVENT role=driver rideId=$normalizedRideId messageId=$trimmedId '
      'senderId=${message.senderId} status=${message.status} text=$preview',
    );

    final knownBefore = _driverChatMessagesById.keys.toList();
    final applyResult = applyIncomingRideChatToMap(
      byId: _driverChatMessagesById,
      snapshotMessageId: trimmedId,
      incoming: message,
      isIncoming: isIncoming,
    );

    if (applyResult.skippedDuplicate) {
      _log(
        'CHAT_DUPLICATE_SKIPPED role=driver rideId=$normalizedRideId '
        'messageId=$trimmedId reason=own_optimistic_unchanged',
      );
      return;
    }

    if (!applyResult.applied) {
      _log(
        'CHAT_RECONCILE_MISS role=driver rideId=$normalizedRideId messageId=$trimmedId '
        'knownIds=[${formatRideChatKnownIds(knownBefore)}]',
      );
      return;
    }

    if (applyResult.reconciledLocalKey != null) {
      _log(
        'CHAT_RECONCILE_MATCH role=driver rideId=$normalizedRideId messageId=$trimmedId '
        'localKey=${applyResult.reconciledLocalKey} '
        'oldStatus=${applyResult.oldStatus ?? ''} newStatus=${applyResult.newStatus ?? message.status}',
      );
    } else if (!isIncoming) {
      final hadPending = knownBefore.any((id) {
        final existing = _driverChatMessagesById[id];
        return existing != null && rideChatStatusIsPending(existing.status);
      });
      if (hadPending) {
        _log(
          'CHAT_RECONCILE_MISS role=driver rideId=$normalizedRideId messageId=$trimmedId '
          'knownIds=[${formatRideChatKnownIds(knownBefore)}]',
        );
      }
    }

    if (isIncoming) {
      final receivedAtMs = DateTime.now().millisecondsSinceEpoch;
      final remoteLatencyMs = message.createdAt > 0
          ? receivedAtMs - message.createdAt
          : -1;
      _log(
        'CHAT_RECEIVED role=driver rideId=$normalizedRideId messageId=$trimmedId',
      );
      _log(
        'CHAT_LATENCY_REMOTE_RECEIVED role=driver rideId=$normalizedRideId '
        'messageId=$trimmedId receivedAtMs=$receivedAtMs '
        'remoteLatencyMs=$remoteLatencyMs',
      );
    }

    trimRideChatMessagesById(_driverChatMessagesById);
    _log(
      'CHAT_APPENDED role=driver rideId=$normalizedRideId messageId=$trimmedId '
      'count=${_driverChatMessagesById.length}',
    );
  }

  void _flushDriverChatUiAfterIngest(String normalizedRideId, {String? messageId}) {
    if (_driverChatUnreadOnlyMode && !_isDriverChatOpen) {
      _processDriverChatMessagesUpdate(
        normalizedRideId,
        sortedRideChatMessagesFromMap(_driverChatMessagesById),
      );
      return;
    }
    _flushDriverChatMessageTable(normalizedRideId);
    _log(
      'CHAT_RENDERED role=driver rideId=$normalizedRideId messageId=${messageId ?? 'batch'} '
      'notifierCount=${_driverChatMessages.value.length}',
    );
    _logDriverChatRenderSummary(normalizedRideId);
  }

  void _onDriverChatChildEvent(String normalizedRideId, rtdb.DatabaseEvent event) {
    final messageId = event.snapshot.key?.trim() ?? '';
    if (messageId.isEmpty) {
      return;
    }
    final path = '${canonicalRideChatMessagesPath(normalizedRideId)}/$messageId';
    logRtdbListenerRead(
      context: RtdbReadContext(
        path: path,
        rideId: normalizedRideId,
        driverId: _effectiveDriverId,
        riderId: _valueAsText(_currentRideData?['rider_id']),
        source: 'driver_chat_listener',
      ),
      listenerEvent: event.type.name,
    );
    _ingestDriverChatRtdbMessage(
      normalizedRideId: normalizedRideId,
      messageId: messageId,
      raw: event.snapshot.value,
      source: 'child_event',
    );
    _flushDriverChatUiAfterIngest(normalizedRideId, messageId: messageId);
  }

  Future<void> _hydrateDriverChatMessagesFromRtdb(
    String rideId, {
    required int listenerGeneration,
  }) async {
    final normalizedRideId = rideId.trim();
    if (normalizedRideId.isEmpty) {
      return;
    }
    if (_driverChatHydrateCompletedGeneration == listenerGeneration) {
      return;
    }
    final path = canonicalRideChatMessagesPath(normalizedRideId);
    try {
      final snap = await runRtdbQueryGet(
        query: _rideChatMessagesRef(normalizedRideId),
        context: RtdbReadContext(
          path: path,
          rideId: normalizedRideId,
          driverId: _effectiveDriverId,
          riderId: _valueAsText(_currentRideData?['rider_id']),
          source: 'driver_map.chat_hydrate',
        ),
      );
      if (_driverChatListenerRideId != normalizedRideId ||
          listenerGeneration != _driverChatListenerGeneration) {
        return;
      }
      final raw = snap.value;
      final keys = <String>[];
      if (raw is Map) {
        raw.forEach((key, value) {
          final messageId = key?.toString().trim() ?? '';
          if (messageId.isEmpty) {
            return;
          }
          keys.add(messageId);
          _ingestDriverChatRtdbMessage(
            normalizedRideId: normalizedRideId,
            messageId: messageId,
            raw: value,
            source: 'initial_snapshot',
          );
        });
      }
      _log(
        'DRIVER_CHAT_INITIAL_SNAPSHOT rideId=$normalizedRideId count=${keys.length} '
        'keys=[${formatRideChatKnownIds(keys)}]',
      );
      if (_driverChatListenerRideId == normalizedRideId &&
          listenerGeneration == _driverChatListenerGeneration) {
        _driverChatHydrateCompletedGeneration = listenerGeneration;
        _flushDriverChatUiAfterIngest(normalizedRideId);
      }
    } catch (error) {
      _reportDriverChatIssue(
        normalizedRideId,
        'initial_snapshot_failed',
        error: error,
      );
      rethrow;
    }
  }

  void _flushDriverChatMessageTable(String rideId) {
    final normalizedRideId = rideId.trim();
    if (normalizedRideId.isEmpty) {
      return;
    }
    if (!_driverChatUiWantsUpdates(normalizedRideId)) {
      return;
    }
    final rebuildStartedAt = DateTime.now();
    final messages = sortedRideChatMessagesFromMap(_driverChatMessagesById);
    _setDriverChatMessages(rideId, messages);
    _processDriverChatMessagesUpdate(rideId, messages);
    final rebuildMs = DateTime.now().difference(rebuildStartedAt).inMilliseconds;
    _log(
      'CHAT_REBUILD_MS role=driver rideId=$rideId ms=$rebuildMs '
      'CHAT_MESSAGE_COUNT=${messages.length}',
    );
  }

  void _processDriverChatMessagesUpdate(
    String rideId,
    List<RideChatMessage> messages,
  ) {
    final driverId = _effectiveDriverId;
    if (driverId.isEmpty) {
      _hasHydratedDriverChatMessages = true;
      return;
    }

    var unreadCount = 0;
    var receivedNewRiderMessage = false;

    for (final message in messages) {
      if (message.senderRole != 'rider' || message.senderId == driverId) {
        continue;
      }

      final messageKey = '$rideId:${message.id}';
      if (_hasHydratedDriverChatMessages) {
        if (_loggedDriverChatMessageIds.add(messageKey)) {
          receivedNewRiderMessage = true;
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
    } else {
      unreadCount = 0;
      for (final message in messages) {
        if (message.senderRole == 'rider' && message.senderId != driverId) {
          unreadCount += 1;
        }
      }
      _updateDriverUnreadCount(rideId, unreadCount);

      if (_hasHydratedDriverChatMessages &&
          receivedNewRiderMessage &&
          mounted) {
        _showDriverIncomingChatNotice();
      }
    }

    _hasHydratedDriverChatMessages = true;
  }

  void _reportDriverChatIssue(
    String rideId,
    String message, {
    Object? error,
  }) {
    final errorSuffix = error == null ? '' : ':$error';
    _log('driver chat issue rideId=$rideId message=$message$errorSuffix');
    if (error != null && isRealtimeDatabasePermissionDenied(error)) {
      _log(
          '[CHAT_PERMISSION_DENIED] rideId=$rideId message=$message error=$error');
    }
    if (_isDriverChatSessionActive(rideId)) {
      _showSnackBarSafely(
        const SnackBar(
          content: Text('Chat is syncing. Please try again in a moment.'),
        ),
      );
    }
  }

  void _updateDriverUnreadCount(String rideId, int unreadCount) {
    if (_driverUnreadChatCount == unreadCount &&
        _driverChatUnreadNotifier.value == unreadCount) {
      return;
    }

    _driverUnreadChatCount = unreadCount;
    _driverChatUnreadNotifier.value = unreadCount;
  }

  void _resetDriverUnreadCount(String rideId) {
    _updateDriverUnreadCount(rideId, 0);
  }

  void _resetDriverChatState({bool stopListener = true}) {
    if (stopListener) {
      _stopDriverChatListener();
    }
    _driverChatUnreadOnlyMode = false;
    _driverChatListenerRideId = null;
    _hasHydratedDriverChatMessages = false;
    _driverChatHydrateCompletedGeneration = null;
    _loggedDriverChatMessageIds.clear();
    _driverChatMessages.value = const <RideChatMessage>[];
    _driverUnreadChatCount = 0;
      _driverChatUnreadNotifier.value = 0;
    _driverMissedCallNotice = false;
    _isDriverChatOpen = false;
  }

  void _stopDriverChatListener({bool clearMessages = true}) {
    final rideId = _driverChatListenerRideId?.trim();
    if (rideId != null && rideId.isNotEmpty) {
      _rideChatMessagesRef(rideId).keepSynced(false);
      _log(
        'CHAT_LISTENER_DISPOSE role=driver rideId=$rideId clearMessages=$clearMessages',
      );
    }
    if (rideId != null && rideId.isNotEmpty) {
      RidePipelineGuard.releaseChatListener(
        rideId: rideId,
        owner: 'DriverMapScreen',
      );
    }
    for (final sub in _driverChatSubscriptions) {
      sub.cancel();
      RtdbResourceGuard.onListenerDisposed();
    }
    _driverChatSubscriptions.clear();
    if (clearMessages) {
      _driverChatMessagesById.clear();
    }
    _driverChatListenerRideId = null;
    _driverChatUnreadOnlyMode = false;
    _driverChatHydrateCompletedGeneration = null;
    _logResourceCounts('chat_listener_stop');
  }

  void _clearRidePopupTimer() {
    _ridePopupTimer?.cancel();
    _ridePopupTimer = null;
  }

  void _ensureDriverChatUnreadListener(String rideId) {
    final normalizedRideId = rideId.trim();
    if (normalizedRideId.isEmpty ||
        !_isDriverChatSessionActive(normalizedRideId) ||
        _isDriverChatOpen) {
      return;
    }
    if (_driverChatListenerRideId == normalizedRideId &&
        _driverChatSubscriptions.isNotEmpty) {
      _driverChatUnreadOnlyMode = true;
      _rideChatMessagesRef(normalizedRideId).keepSynced(true);
      return;
    }
    _startDriverChatListener(normalizedRideId, unreadOnly: true);
  }

  void _startDriverChatListener(
    String rideId, {
    bool unreadOnly = false,
  }) {
    final normalizedRideId = rideId.trim();
    if (normalizedRideId.isEmpty) {
      return;
    }
    if (_driverChatListenerRideId == normalizedRideId &&
        _driverChatSubscriptions.isNotEmpty) {
      if (unreadOnly) {
        _driverChatUnreadOnlyMode = true;
        _rideChatMessagesRef(normalizedRideId).keepSynced(true);
        return;
      }
      if (_driverChatUnreadOnlyMode) {
        _driverChatUnreadOnlyMode = false;
        _rideChatMessagesRef(normalizedRideId).keepSynced(true);
        _log(
          'CHAT_LISTENER_UPGRADE role=driver rideId=$normalizedRideId '
          'unreadOnly=false',
        );
        if (_driverChatMessagesById.isNotEmpty) {
          _flushDriverChatMessageTable(normalizedRideId);
        }
        return;
      }
      _log(
        'CHAT_LISTENER_SKIP_DUPLICATE role=driver rideId=$normalizedRideId',
      );
      return;
    }

    final switchingRide = _driverChatListenerRideId != null &&
        _driverChatListenerRideId != normalizedRideId;
    _stopDriverChatListener(clearMessages: switchingRide);
    _driverChatListenerRideId = normalizedRideId;
    _driverChatUnreadOnlyMode = unreadOnly;
    final listenerGeneration = ++_driverChatListenerGeneration;
    RidePipelineGuard.assertChatListenerAttach(
      rideId: normalizedRideId,
      owner: 'DriverMapScreen',
      path: canonicalRideChatMessagesPath(normalizedRideId),
      role: 'driver',
    );
    final chatPath = canonicalRideChatMessagesPath(normalizedRideId);
    _log(
      'DRIVER_CHAT_LISTENER_ATTACH rideId=$normalizedRideId path=$chatPath '
      'unreadOnly=$unreadOnly generation=$listenerGeneration',
    );
    _log(
      'CHAT_LISTENER_ATTACH rideId=$normalizedRideId path=$chatPath '
      'unreadOnly=$unreadOnly',
    );
    if (switchingRide) {
      _hasHydratedDriverChatMessages = false;
      _driverChatHydrateCompletedGeneration = null;
      _loggedDriverChatMessageIds.clear();
      _driverChatMessages.value = const <RideChatMessage>[];
      _driverChatMessagesById.clear();
    }
    final messagesRef = _rideChatMessagesRef(normalizedRideId);
    messagesRef.keepSynced(true);
    _driverChatSubscriptions.add(
      messagesRef.onChildAdded.listen(
        (event) => _onDriverChatChildEvent(normalizedRideId, event),
        onError: (Object error) {
          logRtdbListenerRead(
            context: RtdbReadContext(
              path: canonicalRideChatMessagesPath(normalizedRideId),
              rideId: normalizedRideId,
              driverId: _effectiveDriverId,
              riderId: _valueAsText(_currentRideData?['rider_id']),
              source: 'driver_chat_listener',
            ),
            listenerEvent: 'onChildAdded',
            error: error,
          );
          _reportDriverChatIssue(
            normalizedRideId,
            'listener_onchild_added_failed',
            error: error,
          );
          Error.throwWithStackTrace(error, StackTrace.current);
        },
      ),
    );
    _driverChatSubscriptions.add(
      messagesRef.onChildChanged.listen(
        (event) => _onDriverChatChildEvent(normalizedRideId, event),
        onError: (Object error) {
          logRtdbListenerRead(
            context: RtdbReadContext(
              path: canonicalRideChatMessagesPath(normalizedRideId),
              rideId: normalizedRideId,
              driverId: _effectiveDriverId,
              riderId: _valueAsText(_currentRideData?['rider_id']),
              source: 'driver_chat_listener',
            ),
            listenerEvent: 'onChildChanged',
            error: error,
          );
          _reportDriverChatIssue(
            normalizedRideId,
            'listener_onchild_changed_failed',
            error: error,
          );
          Error.throwWithStackTrace(error, StackTrace.current);
        },
      ),
    );
    RtdbResourceGuard.onListenerAttached();
    RtdbResourceGuard.onListenerAttached();
    _logResourceCounts('chat_listener_attach');
    unawaited(
      _hydrateDriverChatMessagesFromRtdb(
        normalizedRideId,
        listenerGeneration: listenerGeneration,
      ),
    );
    unawaited(
      probeRideChatThreadPaths(
        root: messagesRef.root,
        rideId: normalizedRideId,
        driverId: _effectiveDriverId,
        riderId: _valueAsText(_currentRideData?['rider_id']),
      ),
    );
  }

  void _rearmRideRequestListener(String reason) {
    _scheduleDiscoveryRearmWhenIdle(reason);
  }

  void _scheduleDiscoveryRearmWhenIdle(String reason, {int attempt = 0}) {
    if (attempt > 12) {
      _logRideReq(
        'DISPATCH_DISCOVERY_REARM_FORCE reason=$reason attempts=$attempt',
      );
      if (_popupLifecycleState != _DriverPopupLifecycleState.idle) {
        _setPopupLifecycleState(
          _DriverPopupLifecycleState.idle,
          reason: 'discovery_rearm_force_idle',
        );
      }
      unawaited(_rebindOfferListenerIfNeeded(source: 'discovery_rearm_force:$reason', force: true));
      return;
    }
    Future<void>.delayed(Duration(milliseconds: attempt == 0 ? 0 : 250), () {
      if (!mounted || !_isOnline) {
        return;
      }
      if (_discoveryRebindFrozen && !_isTerminalRebindReason(reason)) {
        if (attempt == 0) {
          _logNewOfferSuppressed(
            _activePopupRideId ?? _pendingOfferPopupRideId ?? 'none',
            'popup_lifecycle_${_popupLifecycleState.name}',
          );
        }
        _scheduleDiscoveryRearmWhenIdle(reason, attempt: attempt + 1);
        return;
      }
      if (_isTerminalRebindReason(reason) &&
          _popupLifecycleState != _DriverPopupLifecycleState.idle) {
        _setPopupLifecycleState(
          _DriverPopupLifecycleState.idle,
          reason: 'discovery_rearm_terminal_idle',
        );
      }
      _logListenerStillActiveWaitingForFreshRides();
      unawaited(_rebindOfferListenerIfNeeded(
        source: 'discovery_rearm:$reason',
        force: _isTerminalRebindReason(reason),
      ).then((_) {
        _logRideReq('DISPATCH_DISCOVERY_REARM_OK reason=$reason');
      }));
    });
  }

  Future<void> _syncDriverDeclineToServer(
    String rideId, {
    String? serviceType,
  }) async {
    final normalized = rideId.trim();
    if (normalized.isEmpty) {
      return;
    }
    _logRideReq(
      'DRIVER_DECLINE_SERVER_SYNC_START rideId=$normalized serviceType=${serviceType ?? ''}',
    );
    try {
      final resp = await _rideCloud
          .withdrawDriverOffer(
            rideId: normalized,
            reason: 'driver_declined',
            serviceType: serviceType,
          )
          .timeout(const Duration(seconds: 20));
      if (rideCallableSucceeded(resp)) {
        _logRideReq('DRIVER_DECLINE_SERVER_SYNC_OK rideId=$normalized');
      } else {
        _logRideReq(
          'DRIVER_DECLINE_SERVER_SYNC_FAIL rideId=$normalized '
          'reason=${_valueAsText(resp['reason'])}',
        );
      }
    } catch (error) {
      _logRideReq(
        'DRIVER_DECLINE_SERVER_SYNC_FAIL rideId=$normalized error=$error',
      );
    }
  }

  Future<void> _repairDispatchBlockersAndRearmDiscovery({
    required String reason,
    String releasedRideId = '',
  }) async {
    if (!_isOnline) {
      return;
    }
    _logRideReq('DISPATCH_BLOCKER_REPAIR_START reason=$reason');
    try {
      final resp = await _rideCloud
          .refreshDriverAvailability(source: 'dispatch_blocker_repair_$reason')
          .timeout(const Duration(seconds: 20));
      _applyDispatchBlockerRepairToLocalState(
        resp,
        releasedRideId: releasedRideId,
      );
      if (rideCallableSucceeded(resp)) {
        _logRideReq('DISPATCH_BLOCKER_REPAIR_OK reason=$reason');
      } else {
        _logRideReq(
          'DISPATCH_BLOCKER_REPAIR_FAIL reason=$reason '
          'callableReason=${_valueAsText(resp['reason'])}',
        );
      }
    } catch (error) {
      _logRideReq('DISPATCH_BLOCKER_REPAIR_FAIL reason=$reason error=$error');
    }
    await _resumeDriverOfferListenersAfterTerminal(
      source: 'dispatch_blocker_repair:$reason',
      rideId: releasedRideId.trim().isEmpty ? null : releasedRideId.trim(),
    );
  }

  void _applyDispatchBlockerRepairToLocalState(
    Map<String, dynamic> resp, {
    String releasedRideId = '',
  }) {
    final repair = resp['repair'];
    if (repair is! Map) {
      return;
    }
    final blockingRaw = repair['blockingTripIds'] ?? repair['blocking_trip_ids'];
    final blocking = blockingRaw is List
        ? blockingRaw.map((e) => _valueAsText(e).trim()).where((id) => id.isNotEmpty).toList()
        : <String>[];
    if (blocking.isNotEmpty) {
      return;
    }
    final releaseId = releasedRideId.trim();
    if (releaseId.isNotEmpty &&
        (_currentRideId?.trim() == releaseId ||
            _driverActiveRideId?.trim() == releaseId)) {
      unawaited(
        _releaseAssignedRideIfNeeded(
          rideId: releaseId,
          reason: 'dispatch_blocker_repair',
        ),
      );
    }
    if (!_hasActiveDriverTripAssignment()) {
      _discoverySuspendedForRideId = null;
    }
  }

  Future<_MatchedRideRequest?> _loadLivePopupRide(
    String rideId, {
    bool logSkips = true,
    bool ignoreLocalState = false,
    Map<String, dynamic>? offerQueueFallbackData,
  }) async {
    if (_isTerminalSelfAcceptedRide(rideId)) {
      _logRideReq(
        '[MATCH_DEBUG][POPUP_SUPPRESSED_SELF_ACCEPTED] rideId=$rideId '
        'source=load_live_popup_ride',
      );
      return null;
    }
    final fb = offerQueueFallbackData;
    final isDeliveryOffer = fb != null && _isDeliveryOfferData(fb);
    Map<String, dynamic>? liveMap;
    if (isDeliveryOffer) {
      try {
        debugPrint(
          'DELIVERY_OFFER_FRESH_READ_START path=delivery_requests/$rideId source=load_live_popup_ride',
        );
        final snap = await rtdb.FirebaseDatabase.instance
            .ref('delivery_requests/${rideId.trim()}')
            .get()
            .timeout(const Duration(seconds: 4));
        liveMap = _asStringDynamicMap(snap.value);
        if (liveMap != null) {
          debugPrint(
            'DELIVERY_OFFER_FRESH_READ_SUCCESS deliveryId=$rideId source=load_live_popup_ride',
          );
        }
      } catch (error) {
        debugPrint(
          'DELIVERY_OFFER_FRESH_READ_FAIL deliveryId=$rideId source=load_live_popup_ride error=$error',
        );
      }
    } else {
      final snapshot =
          await _rideRequestChildGetIosSafe(rideId, 'load_live_popup_ride');
      liveMap = _asStringDynamicMap(snapshot.value);
    }
    final useOfferFlow =
        fb != null && fb['__nexride_from_offer_queue'] == true;

    Map<String, dynamic>? mergedPayload = liveMap;
    if (useOfferFlow) {
      final stampedOffer = _stampBackendOfferPayload(rideId, fb);
      if (liveMap == null || liveMap.isEmpty) {
        dispatchVerboseLog(
          isDeliveryOffer
              ? 'DRIVER_DELIVERY_OFFER_PAYLOAD_USED deliveryId=$rideId'
              : 'DRIVER_OFFER_PAYLOAD_USED rideId=$rideId',
        );
        mergedPayload = stampedOffer;
      } else {
        // Authoritative lifecycle wins over synthetic queue status.
        mergedPayload = _stampBackendOfferPayload(
          rideId,
          <String, dynamic>{...stampedOffer, ...liveMap},
        );
      }
    }

    final matched = _matchRideForPopup(
      rideId,
      mergedPayload ?? (isDeliveryOffer ? fb : null),
      ignoreLocalState: ignoreLocalState,
      logSkips: false,
      marketDiscoveryCandidate: useOfferFlow,
    );
    if (matched != null) {
      return matched;
    }

    if (useOfferFlow && mergedPayload != null) {
      final offerOnly = _matchRideForPopup(
        rideId,
        mergedPayload,
        ignoreLocalState: true,
        logSkips: false,
        marketDiscoveryCandidate: true,
      );
      if (offerOnly != null) {
        return offerOnly;
      }
      final pickup = _pickupLatLngFromRideData(mergedPayload);
      final destination = _destinationLatLngFromRideData(mergedPayload);
      if (pickup != null && destination != null) {
        final rideCity = _rideMarketFromData(mergedPayload) ?? '';
        return _MatchedRideRequest(
          rideId: rideId,
          rideData: mergedPayload,
          pickup: pickup,
          destination: destination,
          serviceType: _serviceTypeKey(mergedPayload['service_type']),
          city: rideCity,
          area: _rideAreaFromData(mergedPayload, city: rideCity),
          status: TripStateMachine.uiStatusFromSnapshot(mergedPayload),
          driverId: _valueAsText(mergedPayload['driver_id']),
          createdAt: _parseCreatedAt(mergedPayload['created_at']),
          distanceMeters: Geolocator.distanceBetween(
            _driverLocation.latitude,
            _driverLocation.longitude,
            pickup.latitude,
            pickup.longitude,
          ),
          sameArea: false,
        );
      }
    }

    final rideData = mergedPayload ?? _asStringDynamicMap(snapshot.value);
    if (_isBackendTrustedOffer(rideId, rideData)) {
      final cached = _driverOfferRideCache[rideId.trim()];
      if (cached != null) {
        final cachedMatch = _matchRideForPopup(
          rideId,
          cached,
          ignoreLocalState: true,
          logSkips: false,
          marketDiscoveryCandidate: true,
        );
        if (cachedMatch != null) {
          return cachedMatch;
        }
      }
    }
    final skipReason =
        _popupServerSkipReason(rideId, rideData) ?? 'unavailable';
    _logInvalidRideBlocked(rideId: rideId, reason: skipReason);
    if (!_isBackendTrustedOffer(rideId, rideData)) {
      _popupDismissedRideId = rideId;
      _popupDismissedReason = skipReason;
    }
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
      _logDriverOfferPopupSuppressed(trimmedRideId, serverSkipReason);
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
    var pickup = _pickupLatLngFromRideData(matchedRideData);
    if (pickup == null &&
        _isBackendTrustedOffer(trimmedRideId, matchedRideData)) {
      pickup = _latLngFromMap(
        _offerPlaceGeoFromPayload(matchedRideData, 'pickup', 'pickup'),
      );
    }
    if (pickup == null) {
      if (logSkips) {
        _logRtdb('ride skipped rideId=$rideId reason=missing_pickup_coordinates');
        _logDriverOfferPopupSuppressed(
          trimmedRideId,
          'missing_pickup_coordinates',
        );
      }
      return null;
    }
    var destination = _destinationLatLngFromRideData(matchedRideData);
    if (destination == null &&
        _isBackendTrustedOffer(rideId, matchedRideData)) {
      destination = pickup;
    }
    if (destination == null) {
      if (logSkips) {
        _logRtdb(
          'ride skipped rideId=$rideId reason=missing_destination_coordinates',
        );
      }
      return null;
    }
    final normalizedStatus =
        TripStateMachine.uiStatusFromSnapshot(matchedRideData);
    final driverIdValue = _valueAsText(matchedRideData['driver_id']);
    final serviceType = _serviceTypeKey(matchedRideData['service_type']);
    final rideCity = _rideMarketFromData(matchedRideData) ??
        _canonicalDriverDispatchMarket() ??
        _driverCity ??
        '';
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
    dispatchVerboseLog(
      'DRIVER_ONLINE_START driverId=$driverId '
      'authUid=${FirebaseAuth.instance.currentUser?.uid ?? 'none'}',
    );

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

      final locationCapability = await evaluateDriverLocationCapability();
      _locationCapability = locationCapability;
      if (!locationCapability.canGoOnline) {
        final blockReason = !locationCapability.locationServiceEnabled
            ? 'location_service_disabled'
            : locationCapability.permission ==
                    LocationPermission.deniedForever
                ? 'location_permission_denied_forever'
                : 'location_permission_denied';
        _log(
          'DRIVER_GO_ONLINE_BLOCKED reason=$blockReason '
          'permission=${locationCapability.permission} canGoOnline=false',
        );
        if (mounted) {
          _showDriverLocationRequirementNotice(
            locationCapability.message,
            openLocationSettings: locationCapability.recommendOpenSettings &&
                !locationCapability.locationServiceEnabled,
            openAppSettings: locationCapability.recommendOpenSettings &&
                locationCapability.locationServiceEnabled,
          );
          setState(() {});
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

      final sessionMode = _normalizedAvailabilityMode(_pendingAvailabilityMode);
      final testLocation = _getNigeriaTestDriverLocation();
      Future<Position?>? positionFuture;
      if (testLocation == null && sessionMode == 'current_location') {
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

      final profileBlock =
          await DriverProfileRequirement.evaluate(driverId, profile);
      if (profileBlock != DriverProfileBlock.none) {
        final reason = profileBlock == DriverProfileBlock.missingPhone
            ? 'missing_phone'
            : 'missing_photo';
        _log('PROFILE_REQUIREMENT_BLOCKED reason=$reason driverId=$driverId');
        if (mounted) {
          final messenger = ScaffoldMessenger.of(context);
          messenger.hideCurrentSnackBar();
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                  DriverProfileRequirement.messageFor(profileBlock, 'go online')),
              duration: const Duration(seconds: 6),
              action: SnackBarAction(
                label: 'Edit profile',
                onPressed: () {
                  DriverProfileEditScreen.open(context, driverId: driverId);
                },
              ),
            ),
          );
        }
        return;
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
      final goLiveBlock = evaluateDriverGoLive(
        profile,
        documentsApproved: driverVerificationCanGoOnline(verification),
      );
      if (goLiveBlock == DriverGoLiveBlock.profileIncomplete) {
        final missing = missingDriverProfileFields(profile).join(', ');
        _log('GO_LIVE_BLOCKED reason=profile_incomplete missing=$missing '
            'driverId=$driverId');
        if (mounted) {
          final messenger = ScaffoldMessenger.of(context);
          messenger.hideCurrentSnackBar();
          messenger.showSnackBar(
            SnackBar(
              content: Text(driverGoLiveBlockMessage(goLiveBlock)),
              duration: const Duration(seconds: 6),
              action: SnackBarAction(
                label: 'Edit profile',
                onPressed: () {
                  DriverProfileEditScreen.open(context, driverId: driverId);
                },
              ),
            ),
          );
        }
        return;
      }
      if (goLiveBlock != DriverGoLiveBlock.none) {
        _log(
          'GO_LIVE_BLOCKED reason=verification block=$goLiveBlock '
          'status=${verification['overallStatus']} driverId=$driverId',
        );
        if (mounted) {
          final messenger = ScaffoldMessenger.of(context);
          messenger.hideCurrentSnackBar();
          messenger.showSnackBar(
            SnackBar(
              content: Text(driverGoLiveBlockMessage(goLiveBlock)),
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

      _ingestRolloutFromProfile(profile);
      final rRoll = _rolloutRegionId?.trim() ?? '';
      final cRoll = _rolloutCityId?.trim() ?? '';
      if (sessionMode == 'service_area') {
        if (rRoll.isEmpty || cRoll.isEmpty) {
          _showAvailabilityFailureNotice(
            'Select your operating state and city in Driver Hub before going online.',
          );
          return;
        }
        try {
          final v = await RideCloudFunctionsService()
              .validateServiceLocation(
                regionId: rRoll,
                cityId: cRoll,
                service: 'rides',
              )
              .timeout(const Duration(seconds: 20));
          if (!rideCallableSucceeded(v)) {
            _showAvailabilityFailureNotice(RolloutCopy.notAvailableInArea);
            return;
          }
        } catch (e) {
          _log('goOnline rollout validate error: $e');
          _showAvailabilityFailureNotice(
            'Could not verify your area. Check connection and try again.',
          );
          return;
        }
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
      } else if (sessionMode == 'service_area') {
        final String rolloutMarketTrim =
            (_rolloutDispatchMarketId ?? '').trim();
        final hubCity = DriverServiceAreaConfig.marketForCity(
          rolloutMarketTrim.isNotEmpty
              ? rolloutMarketTrim
              : _selectedLaunchCity,
        ).city;
        resolvedCity = hubCity;
        _driverCity = resolvedCity;
        latitude = DriverLaunchScope.latitudeForCity(hubCity);
        longitude = DriverLaunchScope.longitudeForCity(hubCity);
        livePosition = null;
      } else {
        final requestedPositionFuture = positionFuture;
        if (requestedPositionFuture == null) {
          _showAvailabilityFailureNotice(
            'Could not go online. Please check your connection and try again.',
          );
          return;
        }
        final position = await requestedPositionFuture;
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

      var cityToSave = normalizeRideMarketSlug(
            (resolvedCity != null && resolvedCity.isNotEmpty)
                ? resolvedCity
                : _selectedLaunchCity,
          ) ??
          normalizeRideMarketSlug(_selectedLaunchCity) ??
          _selectedLaunchCity;
      if (sessionMode == 'service_area' &&
          _rolloutSelectionComplete &&
          (_rolloutDispatchMarketId ?? '').trim().isNotEmpty) {
        cityToSave = normalizeRideMarketSlug(_rolloutDispatchMarketId) ??
            cityToSave;
      }
      // Fanout indexes drivers by `dispatch_market`; must match the rider ride `market` (never force a single city).
      _driverCity = cityToSave;
      _selectedLaunchCity = cityToSave;
      if (_deviceLocationOutsideLaunchArea && sessionMode != 'service_area') {
        latitude = DriverLaunchScope.latitudeForCity(cityToSave);
        longitude = DriverLaunchScope.longitudeForCity(cityToSave);
      }
      final driverArea = await _resolveDriverArea(
        position: (_deviceLocationOutsideLaunchArea || sessionMode == 'service_area')
            ? null
            : livePosition,
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
      if (!_preOnlinePublishGate(
          cityToSave: cityToSave, driverArea: driverArea)) {
        _log('[ONLINE] fail reason=pre_online_publish_gate');
        _showAvailabilityFailureNotice(
          'Could not go online: city or service area is incomplete. Pick a launch city and try again.',
        );
        return;
      }

      _logRtdb('online publish start driverId=$driverId');
      logRtdbAuthContext(role: 'driver', path: 'drivers/$driverId');
      onlinePublishAttempted = true;
      try {
        _logRideReq('DISPATCH_BLOCKER_REPAIR_START reason=go_online');
        final refreshResp = await _rideCloud
            .refreshDriverAvailability(source: 'go_online')
            .timeout(const Duration(seconds: 20));
        _applyDispatchBlockerRepairToLocalState(refreshResp);
        if (rideCallableSucceeded(refreshResp)) {
          _logRideReq('DISPATCH_BLOCKER_REPAIR_OK reason=go_online');
        } else {
          _logRideReq(
            'DISPATCH_BLOCKER_REPAIR_FAIL reason=go_online '
            'callableReason=${_valueAsText(refreshResp['reason'])}',
          );
        }
        final onlineResp = await _rideCloud
            .setDriverOnline(
              availabilityMode: sessionMode,
              dispatchMarket: cityToSave,
              latitude: latitude,
              longitude: longitude,
              serviceRegionId:
                  sessionMode == 'service_area' && rRoll.isNotEmpty ? rRoll : null,
              serviceCityId:
                  sessionMode == 'service_area' && cRoll.isNotEmpty ? cRoll : null,
            )
            .timeout(const Duration(seconds: 25));
        if (!rideCallableSucceeded(onlineResp)) {
          final reason = _valueAsText(onlineResp['reason']);
          final message = _valueAsText(onlineResp['message']);
          _showAvailabilityFailureNotice(
            message.isNotEmpty
                ? message
                : 'Could not go online (${reason.isEmpty ? 'server_rejected' : reason}).',
          );
          return;
        }
        final canonFromServer = _valueAsText(
          onlineResp['canonical_market_id'] ?? onlineResp['dispatch_market_id'],
        ).trim().toLowerCase();
        if (canonFromServer.isNotEmpty) {
          _driverCity = canonFromServer;
          _selectedLaunchCity = canonFromServer;
          cityToSave = canonFromServer;
        }
        await runInstrumentedRtdbUpdate(
          path: 'drivers/$driverId',
          source: 'go_online_profile',
          role: 'driver',
          updates: <String, Object?>{
            'name': name,
            'car': car,
            'plate': plate,
            'serviceTypes': profile['serviceTypes'],
            'businessModel': businessModel,
            'verification': verification,
            'country': driverScope['country'],
            'country_code': driverScope['country_code'],
            'area': driverScope['area'],
            'zone': driverScope['zone'],
            'community': driverScope['community'],
            'service_area': driverScope,
            'launch_market_city': cityToSave,
            'launch_market_country': DriverLaunchScope.countryName,
          },
          action: (sanitized) => _driversRef
              .child(driverId)
              .update(sanitized)
              .timeout(const Duration(seconds: 8)),
        );
        dispatchVerboseLog(
          'DRIVER_ONLINE_CF_OK uid=$driverId market=$cityToSave '
          'canonical_market_id=${canonFromServer.isEmpty ? cityToSave : canonFromServer}',
        );
      } catch (profileWriteError, profileWriteStack) {
        dispatchVerboseLog(
          'DRIVER_ONLINE_CF_FAIL uid=$driverId path=setDriverOnline error=$profileWriteError',
        );
        debugPrintStack(
          label: 'DRIVER_ONLINE_CF_FAIL',
          stackTrace: profileWriteStack,
        );
        rethrow;
      }
      publishedPresence = true;
      _log('[LAST_ACTIVE] updated source=go_online driverId=$driverId');
      _logRtdb('online publish success driverId=$driverId');

      try {
        final driversPostSnap = await runRtdbQueryGet(
          query: _driversRef.child(driverId),
          path: 'drivers/$driverId',
          source: 'driver_map.go_online_verify',
        );
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
          _activeOnlineAvailabilityMode = sessionMode;
          _rideStatus = 'idle';
          _tripStarted = false;
          _driverUnreadChatCount = 0;
      _driverChatUnreadNotifier.value = 0;
          _isDriverChatOpen = false;
        });
      } else {
        _isOnline = true;
        _activeOnlineAvailabilityMode = sessionMode;
        _rideStatus = 'idle';
        _tripStarted = false;
        _driverUnreadChatCount = 0;
      _driverChatUnreadNotifier.value = 0;
        _isDriverChatOpen = false;
      }
      _logDriverOnlineState(online: true, reason: 'go_online');
      // Await first market prime inside [_listenForRideRequests] so [driver_active_ride]
      // cannot populate [_driverActiveRideId] before the initial open-pool snapshot runs.
      var discoveryReady = await _listenForRideRequests(reason: 'goOnline');
      if (!discoveryReady) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        discoveryReady = await _listenForRideRequests(reason: 'goOnline_retry');
      }
      if (discoveryReady) {
        _logRideReq('DISPATCH_DISCOVERY_REARM_OK reason=go_online');
      }
      dispatchVerboseLog(
        'DRIVER_ONLINE_SUCCESS driverId=$driverId '
        'authUid=${FirebaseAuth.instance.currentUser?.uid ?? 'none'} '
        'discoveryReady=$discoveryReady socket=$_socketStatus',
      );
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
      _logResourceCounts('go_online_success');
      if (_isOnline) {
        _startOfferListenerWatchdog();
      }
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
    _stopOfferListenerWatchdog();
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
    _lastDiscoveryDismissFingerprintByRideId.clear();
    _discoveryPopupCooldownUntilMs.clear();
    _loggedDriverOfferReceivedRideIds.clear();
    _rideRequestPopupQueue.clear();
    _cancelPendingRouteRequests(reason: 'go_offline');
    _onlineSessionStartedAt = 0;
    _lastAvailabilityIntentOnline = false;
    _sessionTrackedRideId = null;
    _lastRouteBuildKey = '';
    _activeRouteRideId = null;
    _lastBuiltRouteStatus = null;
    _lastAppliedRouteTargetKey = null;
    _lastRouteBuiltAt = null;
    _lastRouteOrigin = null;
    _routeBuildInFlight = false;
    _deliveryProofUploading = false;
    _deliveryProofUploadProgress = 0;

    _logDriverOnlineState(online: false, reason: 'go_offline');
    if (mounted) {
      setState(() {
        _currentRideId = null;
        _isOnline = false;
        _currentRideData = null;
        _rideStatus = 'offline';
        _tripStarted = false;
        _driverUnreadChatCount = 0;
      _driverChatUnreadNotifier.value = 0;
        _isDriverChatOpen = false;
        _pickupLocation = null;
        _destinationLocation = null;
        _nextNavigationTarget = null;
        _pickupAddressText = '';
        _destinationAddressText = '';
        _riderName = 'Rider';
        _riderPhone = '';
        _riderPhotoUrl = '';
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
    _pendingOfferPopupRideId = null;
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

  Future<void> _openRedeemFleetInviteScreen() async {
    if (!mounted) {
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => DriverRedeemFleetInviteScreen(
          driverId: _effectiveDriverId,
        ),
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
    final hubOpenStart = DateTime.now();
    final authUser = FirebaseAuth.instance.currentUser;
    final cachedProfile = _lastDriverProfileSnapshot != null
        ? Map<String, dynamic>.from(_lastDriverProfileSnapshot!)
        : <String, dynamic>{};
    var identity = _cachedHubIdentity ??
        buildCachedDriverProfileIdentity(
          uid: _effectiveDriverId,
          authUser: authUser,
          driverRecord: cachedProfile.isNotEmpty ? cachedProfile : null,
        );
    var supportSummary = _cachedHubSupportSummary;
    final businessModel =
        normalizedDriverBusinessModel(cachedProfile['businessModel']);
    final monetizationSubtitle =
        '${driverSelectedMonetizationModeLabel(businessModel)} • ${driverBusinessEligibilityMessage(businessModel)}';

    if (!mounted) {
      return;
    }

    unawaited(() async {
      try {
        final profile = await _fetchDriverProfile(source: 'driver_hub');
        final refreshedIdentity = await resolveDriverProfileIdentity(
          uid: _effectiveDriverId,
          rootRef: rtdb.FirebaseDatabase.instance.ref(),
          authUser: authUser,
          driverRecord: profile,
        );
        _cachedHubIdentity = refreshedIdentity;
        try {
          _cachedHubSupportSummary =
              await _userSupportTicketService.fetchInboxSummary(
            userId: _effectiveDriverId,
            createdByType: 'driver',
          );
        } catch (_) {
          _cachedHubSupportSummary = null;
        }
      } catch (_) {}
    }());

    final action = await showModalBottomSheet<_DriverHubAction>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (BuildContext sheetContext) {
        final mediaQuery = MediaQuery.of(sheetContext);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final elapsedMs =
              DateTime.now().difference(hubOpenStart).inMilliseconds;
          debugPrint(
            'DRIVER_HUB_OPEN_MS ms=$elapsedMs cachedProfile=${cachedProfile.isNotEmpty}',
          );
        });
        return StatefulBuilder(
          builder: (BuildContext sheetContext, StateSetter setSheetState) {
            final header = driverProfileHeaderCard(
              identity,
              monetizationSubtitle: monetizationSubtitle,
            );
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
                    profileHeader: identity.displayName == 'Driver' &&
                            cachedProfile.isEmpty
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              header,
                              const SizedBox(height: 8),
                              const LinearProgressIndicator(minHeight: 2),
                            ],
                          )
                        : header,
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
                    label: 'Operating areas',
                    icon: Icons.map_outlined,
                    onTap: () {
                      Navigator.of(sheetContext)
                          .pop(_DriverHubAction.operatingArea);
                    },
                  ),
                  DriverDashboardAction(
                    label: 'Fleet invite',
                    icon: Icons.link,
                    onTap: () {
                      Navigator.of(sheetContext)
                          .pop(_DriverHubAction.fleetInvite);
                    },
                  ),
                  DriverDashboardAction(
                    label: 'Settings',
                    icon: Icons.settings_outlined,
                    onTap: () {
                      Navigator.of(sheetContext).pop(_DriverHubAction.settings);
                    },
                  ),
                  if (kDebugMode)
                    DriverDashboardAction(
                      label: 'Debug overlay',
                      icon: Icons.bug_report_outlined,
                      onTap: () {
                        Navigator.of(sheetContext)
                            .pop(_DriverHubAction.debugOverlay);
                      },
                    ),
                  DriverDashboardAction(
                    label: 'Sign out',
                    icon: Icons.logout_rounded,
                    onTap: () {
                      Navigator.of(sheetContext).pop(_DriverHubAction.signOut);
                    },
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

    if (!mounted || action == null) {
      return;
    }

    switch (action) {
      case _DriverHubAction.settings:
        await _openDriverSettingsSheet();
        break;
      case _DriverHubAction.debugOverlay:
        _setStateSafely(() {
          _showDriverDebugOverlay = !_showDriverDebugOverlay;
        });
        break;
      case _DriverHubAction.editProfile:
        await DriverProfileEditScreen.open(
          context,
          driverId: _effectiveDriverId,
        );
        break;
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
      case _DriverHubAction.fleetInvite:
        await _openRedeemFleetInviteScreen();
        break;
      case _DriverHubAction.operatingArea:
        await _openDriverRolloutOperatingArea();
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
      case _DriverHubAction.whatsappSupport:
        await _openWhatsAppSupportFromDriverMap(sourceScreen: 'profile');
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
      case _DriverHubAction.signOut:
        await _logoutFromDriverHub();
        break;
    }
  }

  Future<void> _openDriverSettingsSheet() async {
    final action = await showModalBottomSheet<_DriverHubAction>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext sheetContext) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: DriverDashboardPanel(
            title: 'Settings',
            actions: <DriverDashboardAction>[
              DriverDashboardAction(
                label: 'Edit profile',
                icon: Icons.person_outline,
                onTap: () => Navigator.of(sheetContext).pop(_DriverHubAction.editProfile),
              ),
              DriverDashboardAction(
                label: 'Verification',
                icon: Icons.verified_user_outlined,
                onTap: () => Navigator.of(sheetContext).pop(_DriverHubAction.verification),
              ),
              DriverDashboardAction(
                label: 'Wallet',
                icon: Icons.account_balance_wallet_outlined,
                onTap: () => Navigator.of(sheetContext).pop(_DriverHubAction.wallet),
              ),
              DriverDashboardAction(
                label: 'Support',
                icon: Icons.support_agent_rounded,
                onTap: () => Navigator.of(sheetContext).pop(_DriverHubAction.support),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _DriverHubAction.editProfile:
        await DriverProfileEditScreen.open(
          context,
          driverId: _effectiveDriverId,
        );
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
      default:
        break;
    }
  }

  Future<void> _logoutFromDriverHub() async {
    _log('driver hub logout requested');
    _explicitDriverSessionCleared = true;
    if (mounted) {
      ScaffoldMessenger.maybeOf(context)?.hideCurrentMaterialBanner();
    }
    await FirebaseAuth.instance.signOut();
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

  /// Pushes verified GPS into public `ride_track_public` via existing callable (no new CF).
  Future<void> _maybeSyncPublicTrackFromGps(Position position) async {
    final hasRide = _currentRideId?.trim().isNotEmpty ?? false;
    final hasDelivery = _activeDeliveryId?.trim().isNotEmpty ?? false;
    if (!hasRide && !hasDelivery) {
      return;
    }
    final now = DateTime.now();
    final throttleOk = _lastPublicTrackSyncAt == null ||
        now.difference(_lastPublicTrackSyncAt!) >= _kPublicTrackSyncMinInterval;
    if (!throttleOk) {
      return;
    }
    _lastPublicTrackSyncAt = now;
    try {
      final resp = await _rideCloud.driverUpdateLiveLocation(
        latitude: position.latitude,
        longitude: position.longitude,
        heading: position.heading,
        accuracy: position.accuracy,
      );
      if (!rideCallableSucceeded(resp)) {
        _log(
          'public track sync skipped reason=${rideCallableReason(resp)}',
        );
      }
    } catch (error) {
      _log('public track sync failed error=$error');
    }
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
          distanceFilter: 25,
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
            final now = DateTime.now();
            final throttleOk = _lastDriverPresenceRtdbWriteAt == null ||
                now.difference(_lastDriverPresenceRtdbWriteAt!) >=
                    _kDriverPresenceRtdbMinInterval;
            if (throttleOk) {
              _lastDriverPresenceRtdbWriteAt = now;
              final hasActiveRide = _currentRideId != null;
              final heartbeatPath = 'drivers/$driverId';
              await runInstrumentedRtdbUpdate(
                path: heartbeatPath,
                source: 'location_heartbeat',
                role: 'driver',
                updates: <String, Object?>{
                  'lng': _driverLocation.longitude,
                  'lat': _driverLocation.latitude,
                  'activeRideId': _currentRideId,
                  'currentRideId': _currentRideId,
                  'country': DriverServiceAreaConfig.countryValue,
                  'country_code': DriverServiceAreaConfig.countryCode,
                  if (_driverCity != null && _driverCity!.trim().isNotEmpty)
                    'launch_market_city': _driverCity,
                  'area': _driverArea,
                  'zone': _driverArea,
                  'community': _driverArea,
                  'last_availability_intent': _lastAvailabilityIntentValue,
                  'last_active_at': rtdb.ServerValue.timestamp,
                  'updated_at': rtdb.ServerValue.timestamp,
                },
                action: (sanitized) =>
                    _driversRef.child(driverId).update(sanitized),
              );
              _lastActiveHeartbeatLogCount += 1;
              if (_lastActiveHeartbeatLogCount % 18 == 1) {
                _log('[LAST_ACTIVE] updated source=location_heartbeat');
              }
            }
          }

          await _maybeSyncPublicTrackFromGps(position);

          if (_currentRideId != null) {
            final activeRideId = _currentRideId!;
            final currentRide = _currentRideData;
            if (currentRide != null) {
              final currentCanonicalState =
                  TripStateMachine.canonicalStateFromSnapshot(currentRide);
              final shouldCallDriverEnroute =
                  currentCanonicalState == TripLifecycleState.driverAssigned &&
                      _driverEnrouteCloudSentRideId != activeRideId;
              if (shouldCallDriverEnroute) {
                try {
                  final resp =
                      await _rideCloud.driverEnroute(rideId: activeRideId);
                  if (rideCallableSucceeded(resp)) {
                    _driverEnrouteCloudSentRideId = activeRideId;
                    await _commitRideAndDriverState(
                      rideId: activeRideId,
                      rideUpdates: const <String, dynamic>{},
                      driverUpdates: _buildDriverPresenceUpdate(
                        status: 'arriving',
                        activeRideId: activeRideId,
                        isAvailable: false,
                      ),
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
                    _log(
                      'driver en route via cloud function rideId=$activeRideId',
                    );
                  }
                } catch (error) {
                  _log(
                    'driverEnroute cloud call failed rideId=$activeRideId error=$error',
                  );
                }
              }
              await _maybeLogDriverTelemetryCheckpoint();
            }
          }

          final hasActiveRideForUi =
              (_currentRideId?.trim().isNotEmpty ?? false);
          if (hasActiveRideForUi) {
            _evaluateArrivedAvailabilityThrottled();
            _scheduleActiveRouteRefresh(
              reason: 'driver_location_update',
            );
            _checkDriverSafety();
            if (mounted) {
              _setStateSafely(() {});
            }
          } else {
            _refreshDriverMapFromLocationThrottled();
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

  Map<String, dynamic>? _rideDataFromDriverOfferQueue(
    String rideId,
    Map<String, dynamic>? offer,
  ) {
    if (offer == null || offer.isEmpty) {
      return null;
    }
    final st = _valueAsText(offer['status']);
    if (st == 'withdrawn' || st == 'closed') {
      return null;
    }
    final isDelivery = _isDeliveryOfferQueuePayload(offer);
    final pool = _normalizeRideMarket(
          offer['canonical_market_id'] ??
              offer['dispatch_market_id'] ??
              offer['market'],
        ) ??
        _valueAsText(offer['market']);
    final pickupMap = _offerPlaceGeoFromPayload(offer, 'pickup', 'pickup');
    if (pickupMap == null || pickupMap.isEmpty) {
      return null;
    }
    final dropoffMap =
        _offerPlaceGeoFromPayload(offer, 'dropoff', 'dropoff') ??
            _offerPlaceGeoFromPayload(offer, 'destination', 'destination');
    final riderId = _valueAsText(offer['rider_id']);
    final pickupAddr = _valueAsText(offer['pickup_address']);
    final dropAddr = _valueAsText(offer['dropoff_address']);
    return _stampBackendOfferPayload(rideId, <String, dynamic>{
      RtdbRideRequestFields.rideId: rideId,
      if (isDelivery) 'delivery_id': rideId,
      if (isDelivery) '__nexride_request_kind': 'delivery',
      if (isDelivery) 'request_kind': 'delivery',
      RtdbRideRequestFields.riderId: riderId,
      RtdbRideRequestFields.driverId: null,
      RtdbRideRequestFields.marketPool: pool,
      RtdbRideRequestFields.market: pool,
      'canonical_market_id': pool,
      'dispatch_market_id': pool,
      RtdbRideRequestFields.status: isDelivery ? (st.isEmpty ? 'searching' : st) : 'searching',
      RtdbRideRequestFields.tripState: TripLifecycleState.searching,
      RtdbRideRequestFields.pickup: pickupMap,
      RtdbRideRequestFields.dropoff: dropoffMap ?? offer['dropoff'],
      'destination': dropoffMap ?? offer['destination'],
      'pickup_address': pickupAddr.isEmpty ? null : pickupAddr,
      'dropoff_address': dropAddr.isEmpty ? null : dropAddr,
      'destination_address': dropAddr.isEmpty ? null : dropAddr,
      RtdbRideRequestFields.fare: offer['fare'] ?? offer['total_ngn'],
      'total_ngn': offer['total_ngn'] ?? offer['fare'],
      'delivery_fee_ngn': offer['delivery_fee_ngn'],
      'booking_fee_ngn': offer['booking_fee_ngn'],
      'distance_km': offer['distance_km'],
      'eta_minutes': offer['eta_minutes'],
      'service_type': isDelivery ? 'dispatch_delivery' : offer['service_type'],
      'package_description': offer['package_description'],
      'vehicle_requirement':
          offer['vehicle_requirement'] ?? offer['dispatch_vehicle_type'],
      'dispatch_vehicle_type':
          offer['dispatch_vehicle_type'] ?? offer['vehicle_requirement'],
      if (offer['delivery_state'] != null) 'delivery_state': offer['delivery_state'],
      RtdbRideRequestFields.paymentMethod: offer['payment_method'],
      RtdbRideRequestFields.paymentStatus: offer['payment_status'],
      RtdbRideRequestFields.expiresAt: offer['expires_at'],
      RtdbRideRequestFields.createdAt: offer['created_at'],
    });
  }

  Future<void> _handleOfferQueueChildStreamError({
    required Object error,
    required String discoveryUid,
    required String driverCity,
    required int listenerToken,
  }) async {
    final staleCallback = listenerToken != _rideRequestListenerToken ||
        _driverOfferQueueBoundUid != discoveryUid;
    if (staleCallback) {
      _logRideReq(
        '[DRIVER_DISCOVERY_TRACE] stale_listener_error_ignored token=$listenerToken '
        'activeToken=$_rideRequestListenerToken boundUid=${_driverOfferQueueBoundUid ?? 'none'} '
        'market=$driverCity error=$error',
      );
      return;
    }
    dispatchVerboseLog('[TRACE] RTDB ERROR = $error');
    final streamUid = FirebaseAuth.instance.currentUser?.uid ?? 'none';
    final denied = isRealtimeDatabasePermissionDenied(error);
    final code = _firebaseErrorCode(error);
    final message = _firebaseErrorMessage(error);
    _socketStatus = 'stream_error';
    _setApiStatus('idle', errorMessage: message);
    dispatchVerboseLog(
      '[DRIVER_BACKEND] op=ride_discovery_stream_error authUid=$streamUid '
      'driverProfilePath=${streamUid == 'none' ? 'drivers/(none)' : driverProfilePath(streamUid)} '
      'path=driver_offer_queue/$discoveryUid '
      'permissionDenied=$denied code=$code message=$message',
    );
    dispatchVerboseLog(
      '[RTDB_DISCOVERY] STREAM_ERROR path=driver_offer_queue/$discoveryUid '
      'market=$driverCity authUid=$streamUid permissionDenied=$denied code=$code error=$message',
    );
    rtdbFlowLog(
      '[DRIVER_LISTENER_FAIL]',
      'uid=$streamUid market=$driverCity op=onChildEvent_stream denied=$denied error=$error',
    );
    _log('ride listener error code=$code message=$message');
    _logRideReq(
      'request listener stream ERROR market=$driverCity code=$code message=$message',
    );
    if (isRealtimeDatabasePermissionDenied(error)) {
      dispatchVerboseLog('RIDE_DISCOVERY_PERMISSION_DENIED');
      dispatchVerboseLog(
        'DRIVER_OFFER_LISTENER_PERMISSION_DENIED path=driver_offer_queue/$discoveryUid uid=$discoveryUid',
      );
      dispatchVerboseLog(
        'DRIVER_OFFER_LISTENER_PERMISSION_DENIED_DETAIL authUid=$streamUid '
        'code=$code message=$message',
      );
      dispatchVerboseLog(
        'RTDB_PERMISSION_ERROR_FULL '
        'error=$error code=$code message=$message '
        'path=driver_offer_queue/$discoveryUid',
      );
      _logDriverReq('skippedReason=rtdb_permission_denied_stream error=$error');
      unawaited(
        _cancelRideRequestListener(
          reason: 'permission_denied_stream_market_$driverCity',
        ),
      );
      _scheduleDiscoveryRearmWhenIdle('permission_denied_stream');
      _logRtdb(
        'driver_offer_queue discovery stream permission denied (logged for engineering; '
        'snackbar shows user-safe copy)',
      );
      try {
        final debugUid = FirebaseAuth.instance.currentUser?.uid ?? 'none';
        final debugPath = debugUid == 'none'
            ? 'drivers/(none)'
            : driverProfilePath(debugUid);
        final debugDriver = debugUid == 'none'
            ? null
            : await runRtdbQueryGet(
                query: _driversRef.child(debugUid),
                path: debugPath,
                source: 'driver_map.offer_listener_permission_debug',
              );
        final debugMap = _asStringDynamicMap(debugDriver?.value);
        _logRideReq(
          '[DRIVER_DISCOVERY_TRACE] permission_denied_snapshot uid=$debugUid '
          'driverProfilePath=$debugPath driverExists=${debugDriver?.exists ?? false} '
          'driverData=${debugMap ?? {}} queryPath=driver_offer_queue/$discoveryUid',
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
      dispatchVerboseLog(
        'DRIVER_OFFER_LISTENER_ERROR path=driver_offer_queue/$discoveryUid '
        'uid=$discoveryUid authUid=$streamUid phase=onChildEvent_stream '
        'code=$code message=$message',
      );
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
  }

  /// Backend fanout keys off RTDB `drivers/{uid}` (isOnline / dispatch_market).
  /// When the map thinks we are in an online session but RTDB is stale, republish
  /// so `createRideRequest` can write [driver_offer_queue]. Honors explicit offline intent.
  Future<bool> _ensureDiscoveryPresenceMatchesServer({
    required rtdb.DatabaseReference driverRef,
    required String driverCity,
    required Map<String, dynamic>? snapMap,
  }) async {
    if (!_isOnline || _onlineSessionStartedAt <= 0 || snapMap == null) {
      return true;
    }
    final intent =
        _valueAsText(snapMap['last_availability_intent']).toLowerCase();
    final remoteOn = _asBool(snapMap['isOnline']) ||
        _asBool(snapMap['online']) ||
        _asBool(snapMap['is_online']);
    if (intent == 'offline' && !remoteOn) {
      _logRideReq(
        '[DISCOVERY] RTDB offline intent with no presence — clearing stale local online',
      );
      _isOnline = false;
      _onlineSessionStartedAt = 0;
      _lastAvailabilityIntentOnline = false;
      if (mounted) {
        _setStateSafely(() {});
      }
      return false;
    }
    if (!remoteOn && intent != 'offline') {
      _logRideReq(
        '[DISCOVERY_PRESENCE_RESYNC] local online session but RTDB shows offline '
        '— refresh via setDriverOnline callable (no client market writes)',
      );
      try {
        await _rideCloud.refreshDriverAvailability(source: 'discovery_presence_resync');
        _lastAvailabilityIntentOnline = true;
      } catch (error) {
        _logRideReq('[DISCOVERY_PRESENCE_RESYNC] update failed error=$error');
      }
    }
    return true;
  }

  Future<bool> _listenForRideRequests({required String reason}) async {
    if (_hasActiveDriverTripAssignment()) {
      _logRideReq(
        '[DISCOVERY_ACTIVE_TRIP] attaching offer listener during active trip reason=$reason '
        'currentRideId=$_currentRideId driverActive=$_driverActiveRideId',
      );
    }
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
          dispatchVerboseLog('RIDE_DISCOVERY_PERMISSION_DENIED');
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

  Future<bool> _listenForRideRequestsImpl({required String reason}) async {
    if (_discoveryRebindFrozen &&
        (_rideRequestSubscription != null ||
            _driverOfferQueueChildRemovedSubscription != null)) {
      _logRideReq(
        'listener attach SKIPPED popup_state=${_popupLifecycleState.name} reason=$reason',
      );
      _logPopup(
        'attach skipped popup_state=${_popupLifecycleState.name} reason=$reason',
      );
      unawaited(_primeDriverOfferQueueFromRtdb(source: 'rebind_frozen:$reason'));
      return true;
    }
    dispatchVerboseLog('RIDE_DISCOVERY_ATTACH_START');
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
    final driverRef = rtdb.FirebaseDatabase.instance.ref('drivers/$uid');
    final queryMarket = _effectiveDriverMarket ??
        normalizeRideMarketSlug(_driverCity) ??
        normalizeRideMarketSlug(_selectedLaunchCity) ??
        'lagos';
    if (queryMarket.isEmpty) {
      _logRideReq(
          '[DRIVER_DISCOVERY_TRACE] BLOCKING DISCOVERY invalid driver profile');
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

    final presenceOk = await _ensureDiscoveryPresenceMatchesServer(
      driverRef: driverRef,
      driverCity: driverCity,
      snapMap: null,
    );
    if (!presenceOk) {
      _logRideReq(
        'request listener SKIPPED reason=rtdb_offline_intent driverCity=$driverCity',
      );
      _showAvailabilityFailureNotice(
        'You are offline on the server. Tap GO ONLINE to receive ride requests.',
      );
      return false;
    }
    _logReqDebug('listener attach START market=$driverCity');
    _logRideReq(
      'driver online state for discovery online=$_isOnline session=$_onlineSessionStartedAt market=$driverCity',
    );
    _logDiscoveryChain(
      'listener_query_market canonical=$driverCity raw_effective=${_effectiveDriverMarket ?? 'null'}',
    );

    if (_driverCity == null || _driverCity!.trim().isEmpty) {
      _driverCity = driverCity;
      _logRtdb(
          'ride request listener using launch market=$driverCity (driver city unset)');
    }

    _logRideReq(
      'driver market resolved=$driverCity offer_listener=driver_offer_queue/$uid (per-uid child_added)',
    );
    _logRideReq(
      '[DRIVER_DISCOVERY_QUERY] path=driver_offer_queue/$uid (onChildAdded)',
    );
    _logRideReq('[DRIVER_DISCOVERY_TRACE] uid=$uid');
    _logRideReq('[DRIVER_DISCOVERY_TRACE] driverProfilePath=$profilePath');
    _logRideReq('[DRIVER_DISCOVERY_TRACE] driverMarket=$driverCity');
    dispatchVerboseLog(
      '[DRIVER_BACKEND] op=offer_queue_attach uid=$uid driverMarket=$driverCity',
    );
    _logRideReq('DRIVER_OFFER_LISTENER_ATTACHED uid=$uid path=driver_offer_queue/$uid');
    _logDriverOfferListenerAttach(uid, reason: reason);
    dispatchVerboseLog(
      '[DRIVER_BACKEND] op=offer_queue_discovery authUid=$uid '
      'path=driver_offer_queue/$uid '
      'driverProfilePath=$profilePath',
    );
    _log(
      'listener target path=driver_offer_queue/$uid market=$driverCity '
      'online_session_started_at=$_onlineSessionStartedAt reason=$reason',
    );
    _logRtdb('listener attach target path=driver_offer_queue/$uid market=$driverCity');

    dispatchVerboseLog(
      '[DISCOVERY_QUERY] offer_queue uid=$uid market=$driverCity '
      'effectiveDriverMarket=${_effectiveDriverMarket ?? 'null'} '
      'effectiveDriverCity=${_driverCity ?? 'null'} selectedLaunchCity=$_selectedLaunchCity',
    );

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
      'queryPath=driver_offer_queue/$uid (child listeners)',
    );

    Future<void> rideMapProcessingChain = Future<void>.value();

    Future<void> processRideMap(
      Map<String, dynamic> rideMap, {
      required String source,
      required int listenerToken,
    }) async {
      if (listenerToken != _rideRequestListenerToken) {
        _logRideReq(
          'snapshot skipped reason=stale_listener source=$source token=$listenerToken activeToken=$_rideRequestListenerToken',
        );
        return;
      }

      final activeOpenRideMap = <String, Map<String, dynamic>>{};
      for (final entry in rideMap.entries) {
        final rideId = entry.key;
        final rawOffer = _asStringDynamicMap(entry.value);
        var rideData = _rideDataFromDriverOfferQueue(rideId, rawOffer);
        if (rideData != null && _rideExpiredWithOfferGrace(rideData)) {
          _offerDiscoveryLog('OFFER_EXPIRED', rideId: rideId);
          _driverOfferQueueReplica.remove(rideId);
          _driverOfferRideCache.remove(rideId);
          continue;
        }
        if (rideData != null) {
          final isDeliveryOffer = _isDeliveryOfferQueuePayload(rawOffer) ||
              _isDeliveryOfferData(rideData);
          if (isDeliveryOffer) {
            final freshDelivery = await _loadFreshDeliveryRequestForOfferPopup(
              rideId,
              source: 'process_ride_map_$source',
              queuePayload: rawOffer,
            );
            if (freshDelivery == null) {
              continue;
            }
            rideData = Map<String, dynamic>.from(freshDelivery);
            _driverOfferRideCache[rideId] = rideData;
          } else {
            final freshRide = await _loadFreshRideRequestForOfferPopup(
              rideId,
              source: 'process_ride_map_$source',
            );
            if (freshRide == null) {
              continue;
            }
            rideData = Map<String, dynamic>.from(rideData)..addAll(freshRide);
            _driverOfferRideCache[rideId] = rideData;
          }
        } else {
          _driverOfferRideCache.remove(rideId);
        }
        final status = rideData == null
            ? 'payload_not_map'
            : TripStateMachine.uiStatusFromSnapshot(rideData);
        if (rideData != null) {
          _logDriverOfferEventReceived(
            rideId,
            source: source,
            detail: 'status=${_valueAsText(rideData[RtdbRideRequestFields.status])}',
          );
          _logRideReq('DRIVER_OFFER_RECEIVED rideId=$rideId source=$source');
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
                  marketDiscoveryStage:
                      rideData['__nexride_from_offer_queue'] != true,
                ) ??
                '';
        final qualifies = rideData != null &&
            DriverFeatureFlags.activeRequestServiceTypes.contains(
              _serviceTypeKey(rideData['service_type']),
            ) &&
            _driverCanAcceptServiceType(
              _serviceTypeKey(rideData['service_type']),
            ) &&
            skipReason.isEmpty;
        if (!qualifies) {
          final expectedMarket = driverCity;
          final actualMarket =
              rideData == null ? '' : (_rideMarketFromData(rideData) ?? '');
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
          final rawExpires =
              rideData == null ? '' : _valueAsText(rideData['expires_at']);
          final nowMs = DateTime.now().millisecondsSinceEpoch;
          final expiryInfo = rideData == null
              ? (value: 0, field: 'none')
              : _rideExpiryInfo(rideData);
          final expiresEval = expiryInfo.value;
          _logRideReq(
            '[DRIVER_DISCOVERY_REJECT] rideId=$rideId reason='
            '${skipReason.isEmpty ? 'service_type_not_enabled_for_driver' : skipReason} '
            'market_expected=$expectedMarket market_actual=$actualMarket '
            'status=$rawStatus trip_state=$rawTripState driver_id=$rawDriverId '
            'request_expires_at=$rawRequestExpires '
            'expires_at=$rawExpires expires_eval_ms=$expiresEval now_ms=$nowMs '
            'delta_ms=${expiresEval > 0 ? nowMs - expiresEval : -1} '
            'chosen_expiry_field=${expiryInfo.field}',
          );
        } else {
          _logRideReq('[DRIVER_DISCOVERY_ACCEPT] rideId=$rideId');
          _pinPendingOfferPopupRideId(rideId);
          dispatchVerboseLog(
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
          _loggedDriverOfferReceivedRideIds.add(rideId);
          activeOpenRideMap[rideId] = rideData;
        }
      }
      _driverOfferRideCache.removeWhere((k, _) => !rideMap.containsKey(k));

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
      _logPopup(
          'snapshot received raw=${rideMap.length} activeOpen=${activeOpenRideMap.length}');
      _logDiscoveryChain(
        'snapshot received raw=${rideMap.length} activeOpen=${activeOpenRideMap.length}',
      );
      if (activeOpenRideMap.isEmpty) {
        if (rideMap.isEmpty) {
          _logDiscoveryChain(
            'offer_queue_empty driverId=${_driverOfferQueueBoundUid ?? _effectiveDriverId}',
          );
        } else {
          _logDiscoveryChain(
            'offer_queue_no_qualifying raw=${rideMap.length} market=$driverCity '
            '(stale/expired/filtered entries in driver_offer_queue only)',
          );
        }
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
          final csrv =
              childMap == null ? '?' : _valueAsText(childMap['service_type']);
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

      if (_hasActiveJobBlockingNewOffers()) {
        if (activeOpenRideMap.isNotEmpty) {
          final firstKey = activeOpenRideMap.keys.first.toString();
          _logNewOfferSuppressed(firstKey, _activeJobBlockingSkipReason());
          _logActiveJobOfferBlocked(firstKey, source: source);
        } else if (_popupOpen || _hasActivePopup) {
          _logNewOfferSuppressed(
            _activePopupRideId ?? 'none',
            'popup_busy_without_active_trip',
          );
        } else {
          debugPrint(
            '[MATCH_DEBUG] driver_active_ride_busy source=$source '
            'reason=${_activeJobBlockingSkipReason()} snapshot_empty=true',
          );
        }
        _logDriverReq(
          'skippedReason=${_activeJobBlockingSkipReason()} source=$source',
        );
        _logDiscoveryChain(
          'skipped reason=active_trip_blocked source=$source',
        );
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
        } else if (_isBackendTrustedOffer(activePopupRideId)) {
          _logRtdb(
            'popup kept open rideId=$activePopupRideId reason=backend_trusted_offer',
          );
        } else {
          var activePopupRideData =
              _driverOfferRideCache[activePopupRideId] ??
              _rideDataFromDriverOfferQueue(
                activePopupRideId,
                _asStringDynamicMap(rideMap[activePopupRideId]),
              ) ??
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
            marketDiscoveryCandidate:
                _isBackendTrustedOffer(activePopupRideId, activePopupRideData),
          );
          if (activePopupRide == null && mounted) {
            final dismissalReason = _popupServerSkipReason(
              activePopupRideId,
              activePopupRideData,
            );
            if (!_shouldDismissPopupForServerReason(
              dismissalReason,
              rideId: activePopupRideId,
              rideData: activePopupRideData,
            )) {
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

      // Do not gate on [_rideStatus]: stale non-idle status must not block idle drivers.
      // Option A: active ride/delivery blocking is enforced above; server also skips fan-out.

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
            marketDiscoveryStage: entryData['__nexride_from_offer_queue'] != true,
          );
          final localSkip = _popupLocalSkipReason(entry.key);
          final skipReason = localSkip ?? serverSkip ?? 'unknown';
          _logReqDebug('skip rideId=${entry.key} reason=$skipReason');
          if (skipLogBudget > 0) {
            skipLogBudget -= 1;
            _logDriverOfferPopupSuppressed(entry.key, skipReason);
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
              marketDiscoveryStage: ed['__nexride_from_offer_queue'] != true,
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
        _logNewOfferSuppressed(recheckedRide.rideId, 'popup_busy_discovery');
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
      _pinPendingOfferPopupRideId(recheckedRide.rideId);
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
      } else {
        _ridePopupOpenPipelineLocked = true;
        try {
          dispatchVerboseLog(
            'DRIVER_OFFER_POPUP_SHOWN rideId=${recheckedRide.rideId}',
          );
          _logRideReq('DRIVER_OFFER_POPUP_SHOWN rideId=${recheckedRide.rideId}');
          _logDriverOfferPopupShow(
            recheckedRide.rideId,
            source: source,
          );
          await showRideRequestPopup(recheckedRide);
        } finally {
          _ridePopupOpenPipelineLocked = false;
        }
      }
    }

    Future<void> queueRideMapProcessing(
      Map<String, dynamic> rideMap, {
      required String source,
      required int listenerToken,
    }) async {
      rideMapProcessingChain =
          rideMapProcessingChain.catchError((Object _) {}).then(
                (_) => processRideMap(
                  rideMap,
                  source: source,
                  listenerToken: listenerToken,
                ),
              );
      await rideMapProcessingChain;
    }

    final forceRebindOfferListener = _shouldForceRebindOfferListener(reason);
    final rideOfferChildAddedAttached = _rideRequestSubscription != null;
    final deliveryOfferChildAddedAttached =
        _deliveryOfferQueueChildAddedSubscription != null;
    if (!forceRebindOfferListener &&
        rideOfferChildAddedAttached &&
        deliveryOfferChildAddedAttached &&
        _boundOfferQueueProcessor != null &&
        _driverOfferQueueBoundUid != null &&
        _deliveryOfferQueueBoundUid != null &&
        _driverOfferQueueBoundUid == uid &&
        _deliveryOfferQueueBoundUid == uid) {
      if (_rideRequestSubscription != null) {
        _socketStatus = 'offer_queue_connected';
        _setApiStatus('listening');
      }
      _logDriverOfferListenerAlreadyAttached(uid, reason: 'attach_skip:$reason');
      unawaited(_primeOfferQueuesFromRtdb(source: 'attach_skip:$reason'));
      return true;
    }

    final attachUid =
        (FirebaseAuth.instance.currentUser?.uid ?? _effectiveDriverId).trim();
    _logDriverOfferListenerAttach(attachUid, reason: reason);
    final attachAuth = FirebaseAuth.instance.currentUser?.uid.trim();
    final attachEffective = _effectiveDriverId.trim();
    if (attachAuth != null &&
        attachAuth.isNotEmpty &&
        attachEffective.isNotEmpty &&
        attachAuth != attachEffective) {
      dispatchVerboseLog(
        'DRIVER_OFFER_LISTENER_UID_MISMATCH authUid=$attachAuth '
        'effectiveDriverId=$attachEffective',
      );
    }

    await _cancelRideRequestListener(
      reason: 'before_attach_market_$driverCity',
    );
    // Let the native RTDB client finish tearing down the previous query before
    // registering a new ValueEventListener (iOS: tracked-keys assertion).
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _rideRequestListenerToken += 1;
    final listenerToken = _rideRequestListenerToken;
    _boundOfferQueueListenerToken = listenerToken;
    _boundOfferQueueProcessor =
        (Map<String, dynamic> rideMap, {required String source}) {
      return queueRideMapProcessing(
        rideMap,
        source: source,
        listenerToken: listenerToken,
      );
    };
    _rideRequestsListenerBoundCity = driverCity;

    try {
      final discoveryUid =
          (FirebaseAuth.instance.currentUser?.uid ?? _effectiveDriverId).trim();
      if (discoveryUid.isEmpty) {
        _rideRequestsListenerBoundCity = null;
        _driverOfferQueueBoundUid = null;
        rtdbFlowLog(
          '[DRIVER_LISTENER_FAIL]',
          'uid=empty market=$driverCity op=abort reason=missing_driver_id',
        );
        return false;
      }
      _driverOfferQueueBoundUid = discoveryUid;
      final authForQueue = FirebaseAuth.instance.currentUser?.uid.trim();
      dispatchVerboseLog(
        'DRIVER_OFFER_QUEUE_BIND discoveryUid=$discoveryUid '
        'authUid=${authForQueue ?? 'none'} '
        'match=${authForQueue != null && authForQueue == discoveryUid}',
      );
      final driverOfferQueueRef =
          rtdb.FirebaseDatabase.instance.ref('driver_offer_queue/$discoveryUid');
      rtdbFlowLog(
        '[MATCH_FLOW]',
        'phase=precheck_discovery uid=$discoveryUid market=$driverCity',
      );
      _driverOfferQueueReplica.clear();
      void offerQueueStreamNoteEvent() {
        _clearDiscoveryPermissionDeniedNotice(source: 'listener_event');
        if (_socketStatus != 'offer_queue_connected') {
          _socketStatus = 'offer_queue_connected';
        }
        _setApiStatus('listening');
      }

      void onOfferQueueChildError(Object error) {
        unawaited(
          _handleOfferQueueChildStreamError(
            error: error,
            discoveryUid: discoveryUid,
            driverCity: driverCity,
            listenerToken: listenerToken,
          ),
        );
      }

      _logRideReq(
        'request listener SUBSCRIBE onChildAdded/onChildRemoved path=driver_offer_queue/$discoveryUid '
        'market=$driverCity reason=$reason token=$listenerToken',
      );
      _log(
        'DRIVER_OFFER_QUEUE_RESUBSCRIBED driverId=$discoveryUid '
        'reason=$reason token=$listenerToken',
      );
      dispatchVerboseLog(
        '[RTDB_DISCOVERY] OFFER_QUEUE_SUBSCRIBE path=driver_offer_queue/$discoveryUid '
        'market=$driverCity authUid=${FirebaseAuth.instance.currentUser?.uid ?? 'none'}',
      );
      _logRideReq(
        '[MATCH_DEBUG][QUERY_ATTACH:driver_offer_queue/$discoveryUid] '
        'discovery onChildAdded+onChildRemoved',
      );
      unawaited(
        _logDriverOfferQueueSnapshot(
          driverId: discoveryUid,
          queueRef: driverOfferQueueRef,
          source: reason,
        ),
      );
      final addedKey = 'driver_offer_queue/$discoveryUid/onChildAdded';
      final changedKey = 'driver_offer_queue/$discoveryUid/onChildChanged';
      final removedKey = 'driver_offer_queue/$discoveryUid/onChildRemoved';
      await _rtdbListenerHub.attachOnChildAdded(
        pathKey: addedKey,
        query: driverOfferQueueRef,
        onData: (event) async {
          offerQueueStreamNoteEvent();
          await _handleDriverOfferQueueChildEvent(
            event,
            type: 'child_added',
            listenerToken: listenerToken,
            source: 'child_added',
          );
        },
        onError: onOfferQueueChildError,
      );
      _rideRequestSubscription = _rtdbListenerHub.subscriptionFor(addedKey);
      await _rtdbListenerHub.attachOnChildChanged(
        pathKey: changedKey,
        query: driverOfferQueueRef,
        onData: (event) async {
          offerQueueStreamNoteEvent();
          await _handleDriverOfferQueueChildEvent(
            event,
            type: 'child_changed',
            listenerToken: listenerToken,
            source: 'child_changed',
          );
        },
        onError: onOfferQueueChildError,
      );
      _driverOfferQueueChildChangedSubscription =
          _rtdbListenerHub.subscriptionFor(changedKey);
      await _rtdbListenerHub.attachOnChildRemoved(
        pathKey: removedKey,
        query: driverOfferQueueRef,
        onData: (event) async {
          offerQueueStreamNoteEvent();
          await _handleDriverOfferQueueChildEvent(
            event,
            type: 'child_removed',
            listenerToken: listenerToken,
            source: 'child_removed',
          );
          try {
            await queueRideMapProcessing(
              Map<String, dynamic>.from(_driverOfferQueueReplica),
              source: 'child_removed',
              listenerToken: listenerToken,
            );
          } catch (error) {
            _log('offer queue child_removed handler failed error=$error');
            _logRideReq(
              'rideMap handler ERROR source=child_removed error=$error',
            );
          }
          _ensureContinuousOfferDiscovery(source: 'child_removed:${event.snapshot.key ?? ''}');
        },
        onError: onOfferQueueChildError,
      );
      _driverOfferQueueChildRemovedSubscription =
          _rtdbListenerHub.subscriptionFor(removedKey);

      // Slice 1 (Option A): parallel listener on the dedicated dispatch-delivery
      // offer queue. Delivery offers are merged into the SAME replica and pushed
      // through queueRideMapProcessing, so the existing single-popup selection /
      // dedup applies (no duplicate popup, no second popup system). Delivery
      // queue stream errors must NEVER tear down ride discovery.
      _deliveryOfferQueueBoundUid = discoveryUid;
      final deliveryOfferQueueRef = rtdb.FirebaseDatabase.instance
          .ref('delivery_offer_queue/$discoveryUid');
      void onDeliveryOfferQueueError(Object error) {
        final stale = listenerToken != _rideRequestListenerToken ||
            _deliveryOfferQueueBoundUid != discoveryUid;
        if (stale) {
          return;
        }
        _logRideReq(
          '[DELIVERY_OFFER_QUEUE] stream error (ride discovery unaffected) '
          'path=delivery_offer_queue/$discoveryUid '
          'permissionDenied=${isRealtimeDatabasePermissionDenied(error)} '
          'error=$error',
        );
      }

      _logDeliveryOfferListenerAttach(discoveryUid, reason: reason);
      _logRideReq(
        'request listener SUBSCRIBE onChildAdded/onChildRemoved '
        'path=delivery_offer_queue/$discoveryUid market=$driverCity '
        'reason=$reason token=$listenerToken',
      );
      dispatchVerboseLog(
        '[RTDB_DISCOVERY] DELIVERY_OFFER_QUEUE_SUBSCRIBE '
        'path=delivery_offer_queue/$discoveryUid market=$driverCity',
      );
      final deliveryAddedKey =
          'delivery_offer_queue/$discoveryUid/onChildAdded';
      final deliveryRemovedKey =
          'delivery_offer_queue/$discoveryUid/onChildRemoved';
      await _rtdbListenerHub.attachOnChildAdded(
        pathKey: deliveryAddedKey,
        query: deliveryOfferQueueRef,
        onData: (event) async {
          offerQueueStreamNoteEvent();
          final key = event.snapshot.key?.trim();
          if (key == null || key.isEmpty) {
            return;
          }
          debugPrint('DELIVERY_OFFER_QUEUE_CHILD_ADDED deliveryId=$key');
          final rawOffer = _asStringDynamicMap(event.snapshot.value);
          final offerRideData = _rideDataFromDriverOfferQueue(key, rawOffer);
          if (offerRideData == null) {
            debugPrint(
              'DELIVERY_OFFER_POPUP_SKIPPED deliveryId=$key reason=missing_pickup_geo',
            );
            return;
          }
          if (_rideExpiredWithOfferGrace(offerRideData)) {
            _offerDiscoveryLog('DELIVERY_OFFER_EXPIRED', rideId: key);
            _driverOfferQueueReplica.remove(key);
            _driverOfferRideCache.remove(key);
            return;
          }
          debugPrint('DRIVER_DELIVERY_OFFER_RECEIVED deliveryId=$key');
          debugPrint('DELIVERY_OFFER_POPUP_RECEIVED deliveryId=$key');
          _offerDiscoveryLog('DELIVERY_OFFER_RECEIVED', rideId: key);
          _logDeliveryOfferEvent(key, source: 'child_added');
          _pinPendingOfferPopupRideId(key);
          _driverOfferQueueReplica[key] = event.snapshot.value;
          try {
            await queueRideMapProcessing(
              Map<String, dynamic>.from(_driverOfferQueueReplica),
              source: 'delivery_child_added',
              listenerToken: listenerToken,
            );
          } catch (error) {
            _logRideReq(
              'rideMap handler ERROR source=delivery_child_added error=$error',
            );
          }
        },
        onError: onDeliveryOfferQueueError,
      );
      _deliveryOfferQueueChildAddedSubscription =
          _rtdbListenerHub.subscriptionFor(deliveryAddedKey);
      await _rtdbListenerHub.attachOnChildRemoved(
        pathKey: deliveryRemovedKey,
        query: deliveryOfferQueueRef,
        onData: (event) async {
          offerQueueStreamNoteEvent();
          final key = event.snapshot.key?.trim();
          if (key != null && key.isNotEmpty) {
            _driverOfferQueueReplica.remove(key);
            _driverOfferRideCache.remove(key);
            _logDeliveryOfferEvent(key, source: 'child_removed');
            if ((_popupOpen || _hasActivePopup) &&
                _activePopupRideId?.trim() == key &&
                _acceptingPopupRideId != key) {
              if (mounted) {
                unawaited(
                  Navigator.of(context, rootNavigator: true).maybePop(),
                );
              }
            }
          }
          try {
            await queueRideMapProcessing(
              Map<String, dynamic>.from(_driverOfferQueueReplica),
              source: 'delivery_child_removed',
              listenerToken: listenerToken,
            );
          } catch (error) {
            _logRideReq(
              'rideMap handler ERROR source=delivery_child_removed error=$error',
            );
          }
        },
        onError: onDeliveryOfferQueueError,
      );
      _deliveryOfferQueueChildRemovedSubscription =
          _rtdbListenerHub.subscriptionFor(deliveryRemovedKey);

      _logRideReq(
        '[MATCH_DEBUG][DRIVER_ATTACH] market=$driverCity token=$listenerToken '
        'reason=$reason prime_get=skipped_ios_safe',
      );
      _socketStatus = 'offer_queue_connected';
      _setApiStatus('listening');
      _logRideReq(
        '[MATCH_DEBUG][DRIVER_LISTENER_ATTACH_OK] market=$driverCity token=$listenerToken',
      );
      _logRtdb(
        'offer_queue onChildAdded+onChildRemoved active city=$driverCity',
      );
      _logRideReq(
        'request listener CHILD_EVENTS market=$driverCity '
        '(onChildAdded relays initial children + deltas)',
      );
      _logReqDebug('listener attach OK market=$driverCity');
      _logRideReq('[DRIVER_DISCOVERY_TRACE] listener attach OK');
      _clearDiscoveryPermissionDeniedNotice(source: 'listener_attach_success');
      _logPopup('online attach success');
      _logDiscoveryChain(
          'online attach success market=$driverCity reason=$reason');
      dispatchVerboseLog('RIDE_DISCOVERY_ATTACH_SUCCESS');
      _logResourceCounts('offer_listener_attach');
      _logDeliveryOfferListenerAttach(discoveryUid, reason: reason);
      unawaited(
        _consumePendingOfferLaunchIntent(source: 'listener_attach:$reason'),
      );
      return true;
    } catch (error) {
      if (isRealtimeDatabasePermissionDenied(error)) {
        dispatchVerboseLog('RIDE_DISCOVERY_PERMISSION_DENIED');
        dispatchVerboseLog(
          'RTDB_PERMISSION_ERROR_FULL '
          'error=$error path=driver_offer_queue/${_driverOfferQueueBoundUid ?? 'none'}',
        );
      }
      final code = _firebaseErrorCode(error);
      final message = _firebaseErrorMessage(error);
      _rideRequestsListenerBoundCity = null;
      _socketStatus = 'disconnected';
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
        final bound =
            (_driverOfferQueueBoundUid ?? _effectiveDriverId.trim()).trim();
        final denyUid = bound.isEmpty ? uid : bound;
        final denyPath =
            denyUid.isEmpty || denyUid == 'none'
                ? 'driver_offer_queue/(none)'
                : 'driver_offer_queue/$denyUid';
        dispatchVerboseLog(
          'DRIVER_OFFER_LISTENER_PERMISSION_DENIED path=$denyPath uid=$denyUid',
        );
        dispatchVerboseLog(
          'DRIVER_OFFER_LISTENER_PERMISSION_DENIED_DETAIL authUid=$uid '
          'code=$code message=$message phase=attach_try',
        );
        _logRideReq(
          '[DRIVER_DISCOVERY_TRACE] attach_permission_denied uid=$uid '
          'queryPath=driver_offer_queue/${_driverOfferQueueBoundUid ?? 'none'} code=$code message=$message',
        );
        return false;
      }
      dispatchVerboseLog(
        'DRIVER_OFFER_LISTENER_ERROR path=driver_offer_queue/${_effectiveDriverId.trim()} '
        'authUid=${FirebaseAuth.instance.currentUser?.uid ?? 'none'} '
        'phase=attach_try code=$code message=$message error=$error',
      );
      return false;
    }
  }

  Future<void> _applyActiveRideSnapshot({
    required String rideId,
    required Map<String, dynamic> rideData,
    required String status,
  }) async {
    if (!_rideAssignedToUid(rideData, _currentAuthUid)) {
      _logInvalidRideBlocked(rideId: rideId, reason: 'driver_mismatch');
      await _hardResetToFreshSearchSession(
        reason: 'not_assigned_to_driver',
      );
      return;
    }

    final staleReason = DriverActiveRideRestoreSupport.staleRestoreReason(
      rideData: rideData,
      driverId: _currentAuthUid,
      rideId: rideId,
    );
    if (staleReason != null) {
      await _clearStaleDriverActiveRideSession(
        rideId: rideId,
        reason: staleReason,
        source: 'apply_active_ride_snapshot',
      );
      return;
    }

    final validationReason = _activeRideInvalidReason(
      rideData,
      rideId: rideId,
    );

    if (validationReason != null &&
        !_isCommittedActiveRideForDriver(rideData, rideId: rideId)) {
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

    final previousRideId = _driverActiveRideId ?? _currentRideId;
    final previousStatus = _rideStatus;
    final rideChanged = previousRideId != rideId;
    final statusChanged = previousStatus != status;
    final wasPaymentVerified = _ridePaymentServerVerified(_currentRideData);
    final nowPaymentVerified = _ridePaymentServerVerified(rideData);
    final paymentVerifiedTransition =
        !wasPaymentVerified && nowPaymentVerified;
    final paymentKey = _ridePaymentFingerprint(rideData);
    final paymentChanged =
        _lastAppliedSocketPaymentKey != null &&
            _lastAppliedSocketPaymentKey != paymentKey;

    if (rideChanged || statusChanged) {
      _logGuard('applying ride id=$rideId status=$status');
    }
    _trackRideForCurrentSession(rideId);
    _driverActiveRideId = rideId;
    if (_callListenerRideId != rideId || _callSubscription == null) {
      _startCallListener(rideId);
    }
    unawaited(_suspendOfferDiscoveryForActiveTrip('active_ride_listener'));

    if (statusChanged) {
      _log(
        'active ride status transition rideId=$rideId from=$previousStatus to=$status',
      );
      _logRideReq(
        '[MATCH_DEBUG][DRIVER_RIDE_STATUS] rideId=$rideId from=$previousStatus to=$status',
      );
    }

    if (rideChanged || statusChanged || paymentChanged || wasPaymentVerified != nowPaymentVerified) {
      if (mounted) {
        setState(() {
          _currentRideId = rideId;
          _currentRideData = Map<String, dynamic>.from(rideData);
          _rideStatus = status;
          _tripStarted = status == 'on_trip';
          if (rideChanged) {
            _driverUnreadChatCount = 0;
            _driverChatUnreadNotifier.value = 0;
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
          _driverChatUnreadNotifier.value = 0;
          _isDriverChatOpen = false;
        }
      }
    } else {
      _currentRideData = Map<String, dynamic>.from(rideData);
    }

    if (paymentVerifiedTransition && mounted) {
      debugPrint(
        'DRIVER_PAYMENT_CONFIRMED_UI_APPLIED rideId=$rideId '
        'payment_status=${_valueAsText(rideData['payment_status'])}',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Payment confirmed'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 3),
        ),
      );
    }

    final routeTargetKeyBefore = _buildActiveRouteTargetKey(
      rideId: previousRideId ?? rideId,
      status: previousStatus,
    );
    _applyRideLocationsFromData(rideData);
    final routeTargetChanged = _buildActiveRouteTargetKey(
          rideId: rideId,
          status: status,
        ) !=
        routeTargetKeyBefore;

    if (rideChanged || statusChanged) {
      _log(
        'active ride loaded rideId=$rideId status=$status stopCount=${_tripWaypoints.length}',
      );
      _log(
        'ACTIVE_TRIP_SNAPSHOT rideId=$rideId status=$status '
        'trip_state=${_valueAsText(rideData['trip_state'])}',
      );
    }

    if (rideChanged) {
      _loggedDriverChatMessageIds.clear();
      if (_isDriverChatOpen) {
        _startDriverChatListener(rideId, unreadOnly: false);
      } else {
        _ensureDriverChatUnreadListener(rideId);
      }
    }

    _syncRiderDisplayFromRideSnapshot(
      rideId: rideId,
      rideData: rideData,
    );

    _evaluateArrivedAvailability();

    if (status == 'on_trip') {
      _startDriverSafetyMonitoring(rideId);
    } else if (previousStatus == 'on_trip') {
      _stopDriverSafetyMonitoring();
    }

    if (rideChanged || statusChanged || routeTargetChanged) {
      _scheduleActiveRouteRefresh(
        force: rideChanged || statusChanged,
        reason: 'active_ride_listener',
        debounce: rideChanged || statusChanged
            ? _kActiveTripUiDebounceDuration
            : _kActiveRouteDebounceDuration,
      );
    }
    if (rideChanged || statusChanged) {
      _refreshIosDriverMapIfNeeded(reason: 'active_ride_listener');
    }
  }

  Future<void> showRideRequestPopup(
    _MatchedRideRequest ride, {
    bool rideAlreadyReserved = false,
  }) async {
    final rideIdTrim = ride.rideId.trim();
    final Map<String, dynamic>? offerQueueFallback =
        ride.rideData['__nexride_from_offer_queue'] == true
            ? ride.rideData
            : _driverOfferRideCache[rideIdTrim];
    if (offerQueueFallback != null) {
      _backendTrustedOfferRideIds.add(rideIdTrim);
    }
    final serviceType = (ride.rideData['service_type'] ??
            ride.rideData['serviceType'] ??
            '')
        .toString()
        .trim()
        .toLowerCase();
    if (serviceType == 'dispatch_delivery' ||
        ride.rideData['request_kind']?.toString() == 'delivery') {
      debugPrint(
        'DRIVER_DELIVERY_POPUP_SHOWN deliveryId=${ride.rideId} '
        'source=showRideRequestPopup',
      );
      _logDeliveryOfferPopupShow(ride.rideId, source: 'showRideRequestPopup');
    }
    _setPopupLifecycleState(
      _DriverPopupLifecycleState.offered,
      rideId: ride.rideId,
      reason: 'showRideRequestPopup_enter',
    );
    _logRideReq(
      'showRideRequestPopup enter rideId=${ride.rideId} reserved=$rideAlreadyReserved '
      'online=$_isOnline popupOpen=$_popupOpen hasActive=$_hasActivePopup '
      'backendTrusted=${_isBackendTrustedOffer(ride.rideId, ride.rideData)}',
    );
    if (_isTerminalSelfAcceptedRide(ride.rideId)) {
      _suppressRideOfferPopup(ride.rideId, 'terminal_self_accepted');
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
      _suppressRideOfferPopup(ride.rideId, 'forever_suppressed_after_accept');
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
        _activePopupRideId != dedupRideId &&
        !_offerQueuedForDriver(dedupRideId)) {
      _suppressRideOfferPopup(dedupRideId, 'popup_dedup_same_ride_id');
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
      _suppressRideOfferPopup(ride.rideId, 'driver_offline');
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

    if (_hasActiveJobBlockingNewOffers(incomingOfferId: ride.rideId)) {
      _logNewOfferSuppressed(ride.rideId, 'active_job_blocked');
      _logActiveJobOfferBlocked(
        ride.rideId,
        source: 'showRideRequestPopup',
      );
      _releaseOfferPopupLifecycleIfBlocked(
        rideId: ride.rideId,
        reason: 'active_job_blocked',
      );
      return;
    }

    if (_popupOpen || _hasActivePopup) {
      _logNewOfferSuppressed(ride.rideId, 'popup_already_active');
      _enqueueRideRequestPopupIfIdleSlot(ride);
      _releaseOfferPopupLifecycleIfBlocked(
        rideId: ride.rideId,
        reason: 'popup_already_active',
      );
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
    _pinPendingOfferPopupRideId(ride.rideId);
    _popupDismissedRideId = null;
    _popupDismissedReason = null;
    var popupTimedOut = false;
    var remainingSeconds = _kRidePopupCountdownSeconds;
    var popupExpiresAtMs = 0;
    var isAccepting = false;
    var rideReserved = rideAlreadyReserved;
    var rideAccepted = false;
    StateSetter? dialogSetState;

    var resolvedRide = ride;
    try {
      final preShowFresh = await _loadFreshOfferRequestForOfferPopup(
        resolvedRide.rideId,
        source: 'showRideRequestPopup',
        queuePayload:
            _asStringDynamicMap(_driverOfferQueueReplica[resolvedRide.rideId]) ??
                resolvedRide.rideData,
      );
      if (preShowFresh == null) {
        _suppressRideOfferPopup(resolvedRide.rideId, 'fresh_read_stale');
        _logRidePopup('skip rideId=${resolvedRide.rideId} reason=fresh_read_stale');
        return;
      }
      final preShowMerged = Map<String, dynamic>.from(resolvedRide.rideData)
        ..addAll(preShowFresh);
      final preShowMatched = _matchRideForPopup(
        resolvedRide.rideId,
        preShowMerged,
        ignoreLocalState: true,
        marketDiscoveryCandidate: true,
      );
      if (preShowMatched == null) {
        _suppressRideOfferPopup(resolvedRide.rideId, 'fresh_read_unmatchable');
        _logRidePopup(
          'skip rideId=${resolvedRide.rideId} reason=fresh_read_unmatchable',
        );
        return;
      }
      resolvedRide = preShowMatched;

      var popupRide = rideAlreadyReserved
          ? resolvedRide
          : await _loadLivePopupRide(
              resolvedRide.rideId,
              offerQueueFallbackData: offerQueueFallback,
            );
      if (popupRide == null && offerQueueFallback != null) {
        final fallbackMatch = _matchRideForPopup(
          ride.rideId,
          offerQueueFallback,
          ignoreLocalState: true,
          logSkips: false,
          marketDiscoveryCandidate: true,
        );
        popupRide = fallbackMatch;
      }
      if (popupRide == null) {
        _suppressRideOfferPopup(ride.rideId, 'live_load_null');
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

      final backendTrustedPopup =
          _isBackendTrustedOffer(popupRide.rideId, popupRide.rideData);
      final localAfterLive = backendTrustedPopup
          ? null
          : _popupLocalSkipReason(popupRide.rideId);
      if (localAfterLive != null) {
        _suppressRideOfferPopup(popupRide.rideId, localAfterLive);
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

      if (!_popupCandidateRideIdMatches(popupRide.rideId)) {
        _suppressRideOfferPopup(popupRide.rideId, 'candidate_mismatch');
        _logRidePopup(
          'skip rideId=${popupRide.rideId} reason=candidate_mismatch '
          'expected=$_currentCandidateRideId pending=$_pendingOfferPopupRideId',
        );
        _logRideReq(
          'popup blocked reason=candidate_mismatch expected=$_currentCandidateRideId '
          'pending=$_pendingOfferPopupRideId got=${popupRide.rideId}',
        );
        _clearRidePreview();
        _ensureContinuousOfferDiscovery(source: 'candidate_mismatch');
        return;
      }
      if (_currentCandidateRideId != popupRide.rideId) {
        _currentCandidateRideId = popupRide.rideId;
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
      final serviceMatchedDriverType =
          _driverCanAcceptServiceType(popupRide.serviceType);
      final canAcceptService = serviceSupported &&
          serviceApproved &&
          serviceMatchedDriverType;
      final serviceRestrictionMessage = !serviceSupported
          ? '${_serviceTypeLabel(popupRide.serviceType)} is not enabled for drivers yet. You can close this request safely.'
          : !serviceMatchedDriverType
              ? 'This request does not match your selected driver service type.'
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
      final popupRiderName = _valueAsText(popupRide.rideData['rider_name'])
              .isEmpty
          ? 'Rider'
          : _valueAsText(popupRide.rideData['rider_name']);
      final popupRiderPhoto = _firstNonEmptyRiderPhoto(popupRide.rideData);
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

      if (!canAcceptService && !backendTrustedPopup) {
        _popupDismissedReason = 'service_not_supported_for_driver';
        _logRideReq(
          'popup blocked reason=service_not_supported rideId=${popupRide.rideId} '
          'serviceSupported=$serviceSupported serviceApproved=$serviceApproved '
          'serviceType=${popupRide.serviceType}',
        );
        _clearRidePreview();
        _setPopupLifecycleState(
          _DriverPopupLifecycleState.idle,
          rideId: popupRide.rideId,
          reason: 'service_not_supported',
        );
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
        offerQueueFallbackData: offerQueueFallback ?? popupRide.rideData,
      );
      if (refreshedPopupRide != null) {
        popupRide = refreshedPopupRide;
      } else if (!backendTrustedPopup) {
        _logRideReq(
          'popup blocked reason=post_reserve_refresh_null rideId=${popupRide.rideId}',
        );
        _clearRidePreview();
        _setPopupLifecycleState(
          _DriverPopupLifecycleState.idle,
          rideId: popupRide.rideId,
          reason: 'post_reserve_refresh_null',
        );
        _rearmRideRequestListener('popup blocked rideId=${popupRide.rideId}');
        return;
      }
      final previewRide = popupRide;
      _clearRouteOverlay();
      _syncTripLocationMarkers();
      if (_activeOnlineAvailabilityMode != 'service_area') {
        _schedulePopupRoutePreview(
          rideId: previewRide.rideId,
          origin: _driverLocation,
          destination: previewRide.pickup,
          reason: 'driver_popup_preview',
        );
      }
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

      final _MatchedRideRequest activePopupRide = popupRide;
      final Map<String, dynamic> activePopupRideData = activePopupRide.rideData;
      final backendTrustedActive = _isBackendTrustedOffer(
        activePopupRide.rideId,
        activePopupRide.rideData,
      );
      final preShowBlock = _popupHardGateBeforeDialog(
        activePopupRide.rideId,
        activePopupRide.rideData,
        trustBackendOffer: backendTrustedActive,
      );
      if (preShowBlock != null) {
        _logDriverOfferPopupSuppressed(activePopupRide.rideId, preShowBlock);
        _logRidePopup(
          'skip rideId=${activePopupRide.rideId} reason=pre_dialog_gate_$preShowBlock',
        );
        _logPopup('skipped reason=$preShowBlock');
        _logRideReq(
          'popup blocked reason=pre_dialog_gate rideId=${activePopupRide.rideId} detail=$preShowBlock',
        );
        _presentedRideIds.remove(activePopupRide.rideId.trim());
        _clearRidePreview();
        _setPopupLifecycleState(
          _DriverPopupLifecycleState.idle,
          rideId: activePopupRide.rideId,
          reason: 'pre_dialog_gate_$preShowBlock',
        );
        _rearmRideRequestListener(
          'pre_dialog_gate rideId=${activePopupRide.rideId} reason=$preShowBlock',
        );
        return;
      }

      _presentedRideIds.add(activePopupRide.rideId.trim());
      _logDriverOfferPopupShow(
        activePopupRide.rideId,
        source: 'showDialog',
      );
      _setPopupLifecycleState(
        _DriverPopupLifecycleState.visible,
        rideId: activePopupRide.rideId,
        reason: 'showDialog',
      );
      _logRideReq(
        'popup UI showDialog rideId=${activePopupRide.rideId} countdown=$_kRidePopupCountdownSeconds '
        'backendTrusted=$backendTrustedActive',
      );
      _logRideReq(
        '[DRIVER_POPUP_SHOW] rideId=${activePopupRide.rideId} '
        'market=${_rideMarketFromData(activePopupRide.rideData) ?? 'missing'} '
        'status=${_valueAsText(activePopupRide.rideData['status'])} '
        'trip_state=${_valueAsText(activePopupRide.rideData['trip_state'])}',
      );
      dispatchVerboseLog(
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
      final popupShownAtMs = DateTime.now().millisecondsSinceEpoch;
      popupExpiresAtMs =
          popupShownAtMs + _kRidePopupCountdownSeconds * 1000;
      final serverOfferExpiresAt =
          _rideExpiryTimestamp(activePopupRide.rideData);
      if (serverOfferExpiresAt > popupShownAtMs) {
        popupExpiresAtMs = math.min(popupExpiresAtMs, serverOfferExpiresAt);
      }
      final assignmentExpiresAt =
          _assignmentExpiryTimestamp(activePopupRide.rideData);
      if (assignmentExpiresAt > popupShownAtMs) {
        popupExpiresAtMs = math.min(popupExpiresAtMs, assignmentExpiresAt);
      }
      remainingSeconds = math.max(
        0,
        ((popupExpiresAtMs - popupShownAtMs) / 1000).ceil(),
      );
      _offerDiscoveryLog(
        'OFFER_TIMER_START',
        rideId: activePopupRide.rideId,
        detail: 'expiresAt=$popupExpiresAtMs',
      );
      _ridePopupTimer = Timer.periodic(const Duration(milliseconds: 250), (
        timer,
      ) {
        if (!mounted ||
            !_hasActivePopup ||
            _activePopupRideId != activePopupRide.rideId) {
          timer.cancel();
          return;
        }

        if (isAccepting || _acceptingPopupRideId == activePopupRide.rideId) {
          return;
        }

        remainingSeconds = math.max(
          0,
          ((popupExpiresAtMs - DateTime.now().millisecondsSinceEpoch) / 1000)
              .ceil(),
        );
        if (remainingSeconds <= 0) {
          popupTimedOut = true;
          _timedOutRideIds.add(activePopupRide.rideId.trim());
          _setPopupLifecycleState(
            _DriverPopupLifecycleState.expired,
            rideId: activePopupRide.rideId,
            reason: 'countdown_zero',
          );
          _offerDiscoveryLog(
            'OFFER_TIMER_EXPIRED',
            rideId: activePopupRide.rideId,
          );
          _offerDiscoveryLog('MATCH_TIMEOUT', rideId: activePopupRide.rideId);
          timer.cancel();
          unawaited(navigator.maybePop());
          return;
        }

        if (dialogSetState != null) {
          dialogSetState!(() {});
        }
      });

      dispatchVerboseLog('REQUEST_POPUP_SHOWN');
      if (_serviceTypeKey(activePopupRide.serviceType) == 'dispatch_delivery') {
        dispatchVerboseLog('DISPATCH_REQUEST_RECEIVED');
      }
      final action = await showDialog<_RidePopupAction>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          final Map<String, dynamic> popupAckOfferPayload =
              Map<String, dynamic>.from(
            offerQueueFallback ??
                _driverOfferRideCache[activePopupRide.rideId.trim()] ??
                activePopupRideData,
          );
          WidgetsBinding.instance.addPostFrameCallback((_) {
            debugPrint(
              'DRIVER_POPUP_RENDERED rideId=${activePopupRide.rideId} '
              'source=showRideRequestPopup',
            );
            final leaseId =
                DriverOfferLeaseSupport.leaseId(popupAckOfferPayload) ?? '';
            final generation =
                DriverOfferLeaseSupport.popupGeneration(popupAckOfferPayload);
            if (leaseId.isNotEmpty) {
              unawaited(
                _rideCloud.recordDriverOfferPopupAck(
                  rideId: activePopupRide.rideId,
                  leaseId: leaseId,
                  generation: generation,
                  popupRenderedAtMs: DateTime.now().millisecondsSinceEpoch,
                ),
              );
            }
          });
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
                          child: Column(
                            children: <Widget>[
                              ProfileAvatar(
                                name: popupRiderName,
                                photoUrl: popupRiderPhoto,
                                radius: 30,
                                backgroundColor: _gold.withValues(alpha: 0.16),
                                foregroundColor: Colors.black87,
                              ),
                              const SizedBox(height: 6),
                              Text(
                                popupRiderName,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.black87,
                                ),
                              ),
                            ],
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
                            rideAccepted
                                ? 'Ride assigned — opening trip…'
                                : isAccepting
                                    ? 'Confirming assignment…'
                                    : 'Respond in ${remainingSeconds}s',
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
                        _buildTripItinerarySection(
                          rideData: activePopupRideData,
                          pickupAddress: pickupAddress,
                          finalDestinationAddress: destinationAddress,
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
                      onPressed:
                          isAccepting || rideAccepted || !canAcceptService
                          ? null
                          : () async {
                              if (isAccepting || rideAccepted) {
                                return;
                              }
                              isAccepting = true;
                              _setPopupLifecycleState(
                                _DriverPopupLifecycleState.accepting,
                                rideId: activePopupRide.rideId,
                                reason: 'accept_tap',
                              );
                              final acceptRequestedAt =
                                  DateTime.now().millisecondsSinceEpoch;
                              _offerDiscoveryLog(
                                'OFFER_ACCEPT_TAP',
                                rideId: activePopupRide.rideId,
                              );
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
                              _logRideReq(
                                '[ACCEPT_API_STARTED] rideId=${activePopupRide.rideId} driverId=$_effectiveDriverId',
                              );
                              _setApiStatus('loading');
                              _clearRidePopupTimer();
                              setDialogState(() {});
                              // Slice 2: dispatch-delivery offers accept via
                              // acceptDeliveryRequest; normal ride offers keep
                              // the exact existing _acceptRide path unchanged.
                              final bool isDeliveryOffer = _serviceTypeKey(
                                    activePopupRide.serviceType,
                                  ) ==
                                  'dispatch_delivery';
                              final accepted = await (isDeliveryOffer
                                      ? _acceptDeliveryOffer(
                                          activePopupRide.rideId,
                                          acceptRequestedAt: acceptRequestedAt,
                                        )
                                      : _acceptRide(
                                          activePopupRide.rideId,
                                          driverName: driverName,
                                          car: car,
                                          plate: plate,
                                          acceptRequestedAt: acceptRequestedAt,
                                        ))
                                  .timeout(
                                const Duration(seconds: 20),
                                onTimeout: () {
                                  _logRideReq(
                                    '[ACCEPT_API_FAILURE] rideId=${activePopupRide.rideId} reason=timeout',
                                  );
                                  _showSnackBarSafely(
                                    const SnackBar(
                                      content: Text(
                                        'Accept is taking too long. Please try again.',
                                      ),
                                    ),
                                  );
                                  return false;
                                },
                              );
                              _logRideReq(
                                accepted
                                    ? '[ACCEPT_API_SUCCESS] rideId=${activePopupRide.rideId}'
                                    : '[ACCEPT_API_FAILURE] rideId=${activePopupRide.rideId}',
                              );
                              _setApiStatus(
                                accepted ? 'success' : 'failed',
                                errorMessage: accepted
                                    ? null
                                    : 'Could not accept request.',
                              );
                              if (!dialogContext.mounted) {
                                return;
                              }
                              if (accepted) {
                                rideAccepted = true;
                                isAccepting = false;
                                _setPopupLifecycleState(
                                  _DriverPopupLifecycleState.assigned,
                                  rideId: activePopupRide.rideId,
                                  reason: 'accept_success',
                                );
                                setDialogState(() {});
                                await Future<void>.delayed(
                                  const Duration(milliseconds: 1500),
                                );
                                if (!dialogContext.mounted) {
                                  return;
                                }
                                _logRideReq(
                                  '[MATCH_DEBUG][POPUP_DISMISSED_AFTER_ASSIGN] '
                                  'rideId=${activePopupRide.rideId}',
                                );
                              } else {
                                isAccepting = false;
                                _setPopupLifecycleState(
                                  _DriverPopupLifecycleState.visible,
                                  rideId: activePopupRide.rideId,
                                  reason: 'accept_failed_retry',
                                );
                                setDialogState(() {});
                                return;
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
        _setPopupLifecycleState(
          _DriverPopupLifecycleState.cancelled,
          rideId: popupRide.rideId,
          reason: 'driver_declined',
        );
        _popupDismissedReason = 'driver_declined';
        _logRtdb('popup declined locally rideId=${popupRide.rideId}');
        _log(
          'driver acceptance ts=${DateTime.now().toIso8601String()} action=decline rideId=${popupRide.rideId} currentRideId=$_currentRideId',
        );
        unawaited(
          _syncDriverDeclineToServer(
            popupRide.rideId,
            serviceType: popupRide.serviceType,
          ),
        );
        _clearRidePreview();
        _clearOfferPopupState(
          reason: 'driver_declined_immediate',
          rideId: popupRide.rideId,
          clearQueue: false,
          dismissVisibleDialog: false,
          clearCurrentRidePointer: true,
        );
        unawaited(
          _resumeDriverOfferListenersAfterTerminal(
            source: 'driver_declined',
            rideId: popupRide.rideId,
          ),
        );
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
        _clearOfferPopupState(
          reason: 'offer_timeout',
          rideId: popupRide.rideId,
          clearQueue: false,
          dismissVisibleDialog: false,
          clearCurrentRidePointer: true,
        );
        unawaited(
          _resumeDriverOfferListenersAfterTerminal(
            source: 'offer_timeout',
            rideId: popupRide.rideId,
          ),
        );
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
      final dismissedReasonSnapshot = _popupDismissedReason;
      if (!rideAccepted) {
        final rid = ride.rideId.trim();
        final cachedOffer = _driverOfferRideCache[rid];
        if (cachedOffer != null && rid.isNotEmpty) {
          _lastDiscoveryDismissFingerprintByRideId[rid] =
              _discoveryOfferFingerprint(rid, cachedOffer);
          _discoveryPopupCooldownUntilMs[rid] =
              DateTime.now().millisecondsSinceEpoch + 4800;
        }
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
                : (dismissedReasonSnapshot ?? 'driver_declined'),
          );
        }
      }
      final popupCloseReason = rideAccepted
          ? 'popup_closed_accepted'
          : popupTimedOut
              ? 'offer_expired'
              : (dismissedReasonSnapshot ?? 'popup_closed');
      _clearOfferPopupState(
        reason: popupCloseReason,
        rideId: ride.rideId,
        dismissVisibleDialog: false,
        clearCurrentRidePointer: !rideAccepted,
        clearEntireCache: false,
      );
      if (!rideAccepted) {
        _releaseRidePopupSessionBlocks(ride.rideId.trim());
        final repairReason = popupTimedOut
            ? 'offer_expired'
            : (dismissedReasonSnapshot ?? 'popup_closed');
        _logDriverOfferPopupClosed(
          ride.rideId,
          reason: popupTimedOut
              ? 'expired'
              : (dismissedReasonSnapshot ?? 'dismissed'),
        );
        unawaited(
          _repairDispatchBlockersAndRearmDiscovery(
            reason: repairReason,
            releasedRideId: ride.rideId,
          ),
        );
        _ensureContinuousOfferDiscovery(source: repairReason);
      }
      scheduleMicrotask(() {
        unawaited(_flushRideRequestPopupQueueAfterClose());
      });
    }
  }

  /// Slice 2: accept a dispatch-delivery offer via the dedicated
  /// `acceptDeliveryRequest` callable. This is intentionally separate from the
  /// ride accept path (`_acceptRide` / `_acceptRideOnce`) and does NOT start the
  /// ride lifecycle or any active-delivery tracking (that is Slice 3). It only
  /// performs the backend accept and lets the popup clear its loading state.
  Future<bool> _acceptDeliveryOffer(
    String deliveryId, {
    int? acceptRequestedAt,
  }) async {
    final rid = deliveryId.trim();
    if (!_isValidRideId(rid)) {
      _logRideReq(
        '[DELIVERY_ACCEPT_FAIL] deliveryId=$deliveryId reason=delivery_id_missing',
      );
      return false;
    }
    final existing = _acceptDeliveryInFlightById[rid];
    if (existing != null) {
      _logRideReq('[DELIVERY_ACCEPT_JOIN_IN_FLIGHT] deliveryId=$rid');
      return existing;
    }
    final acceptFuture = _acceptDeliveryOfferOnce(
      rid,
      acceptRequestedAt: acceptRequestedAt,
    );
    _acceptDeliveryInFlightById[rid] = acceptFuture;
    try {
      return await acceptFuture;
    } finally {
      _acceptDeliveryInFlightById.remove(rid);
    }
  }

  Future<bool> _acceptDeliveryOfferOnce(
    String deliveryId, {
    int? acceptRequestedAt,
  }) async {
    if (_effectiveDriverId.isEmpty ||
        FirebaseAuth.instance.currentUser?.uid != _effectiveDriverId ||
        !_isOnline) {
      _logRideReq(
        '[DELIVERY_ACCEPT_FAIL] deliveryId=$deliveryId reason=driver_not_ready',
      );
      _showSnackBarSafely(
        const SnackBar(
          content: Text(
            'You need to be online and signed in before accepting a request.',
          ),
        ),
      );
      return false;
    }
    final startedAt =
        acceptRequestedAt ?? DateTime.now().millisecondsSinceEpoch;
    _offerDiscoveryLog('DELIVERY_ACCEPT_START', rideId: deliveryId);
    _logRideReq(
      '[DELIVERY_ACCEPT_START] deliveryId=$deliveryId '
      'driverId=$_effectiveDriverId ts=$startedAt',
    );
    try {
      final response = await _deliveryCloud.acceptDeliveryRequest(
        deliveryId: deliveryId,
      );
      if (deliveryCallableSucceeded(response)) {
        _offerDiscoveryLog('DELIVERY_ACCEPT_OK', rideId: deliveryId);
        _logRideReq('[DELIVERY_ACCEPT_OK] deliveryId=$deliveryId');
        // Clear this offer from the local discovery caches and mark it handled
        // so the popup dismisses cleanly.
        _driverOfferQueueReplica.remove(deliveryId);
        _driverOfferRideCache.remove(deliveryId);
        _handledRideIds.add(deliveryId.trim());
        // Slice 3: begin active-delivery tracking (delivery_requests +
        // driver_active_delivery listeners). This does NOT start the ride
        // lifecycle or use TripStateMachine.
        unawaited(_startActiveDeliveryTracking(deliveryId));
        return true;
      }
      final reason = _valueAsText(response['reason']).isNotEmpty
          ? _valueAsText(response['reason'])
          : (_valueAsText(response['error']).isNotEmpty
              ? _valueAsText(response['error'])
              : 'unknown');
      _offerDiscoveryLog('DELIVERY_ACCEPT_FAIL', rideId: deliveryId);
      _logRideReq(
        '[DELIVERY_ACCEPT_FAIL] deliveryId=$deliveryId reason=$reason',
      );
      _showSnackBarSafely(
        SnackBar(content: Text('Could not accept delivery request: $reason')),
      );
      return false;
    } catch (error) {
      _offerDiscoveryLog('DELIVERY_ACCEPT_FAIL', rideId: deliveryId);
      _logRideReq(
        '[DELIVERY_ACCEPT_FAIL] deliveryId=$deliveryId error=$error',
      );
      _showSnackBarSafely(
        const SnackBar(
          content: Text(
            'Could not accept delivery request. Please try again.',
          ),
        ),
      );
      return false;
    }
  }

  // ===========================================================================
  // Slice 3: active dispatch-delivery tracking + lifecycle.
  // Self-contained and parallel to the ride active-trip flow. Uses
  // DeliveryStateMachine over delivery_requests/{deliveryId} and
  // driver_active_delivery/{driverId}; never touches TripStateMachine,
  // _listenToActiveRide, or the ride lifecycle callables.
  // ===========================================================================

  Future<void> _startActiveDeliveryTracking(String deliveryId) async {
    final rid = deliveryId.trim();
    if (rid.isEmpty) {
      return;
    }
    if (DriverActiveDeliveryRestoreSupport.shouldSkipTrackingAttach(
      trackedDeliveryId: _activeDeliveryId,
      hasActiveDeliverySubscription: _activeDeliverySubscription != null,
      candidateDeliveryId: rid,
    )) {
      return;
    }
    await _stopActiveDeliveryTracking(reason: 'restart_tracking');
    _activeDeliveryId = rid;
    _logRideReq(
      '[DELIVERY_TRACK_ATTACH] deliveryId=$rid path=delivery_requests/$rid',
    );
    _activeDeliverySubscription =
        _deliveryRequestsRef.child(rid).onValue.listen(
      (event) {
        _handleActiveDeliverySnapshot(
          rid,
          _asStringDynamicMap(event.snapshot.value),
        );
      },
      onError: (Object error) {
        _logRideReq(
          '[DELIVERY_TRACK] delivery_requests listener error '
          'deliveryId=$rid error=$error',
        );
      },
    );

    // driver_active_delivery/{driverId} is the backend-owned pointer set on
    // accept. We use it ONLY as a restore signal (never to stop tracking, to
    // avoid races right after accept); terminal/stop is driven by the
    // delivery_requests snapshot below.
    final driverId = _effectiveDriverId.trim();
    if (driverId.isNotEmpty) {
      _logRideReq(
        '[DELIVERY_TRACK_ATTACH] driverId=$driverId '
        'path=driver_active_delivery/$driverId',
      );
      _driverActiveDeliverySubscription = rtdb.FirebaseDatabase.instance
          .ref('driver_active_delivery/$driverId')
          .onValue
          .listen(
        (event) {
          final pointer = _asStringDynamicMap(event.snapshot.value);
          final pointerId =
              pointer == null ? '' : _valueAsText(pointer['delivery_id']);
          if (pointerId.isNotEmpty && _activeDeliveryId == null) {
            _logRideReq(
              '[DELIVERY_TRACK] driver_active_delivery restore '
              'deliveryId=$pointerId',
            );
            unawaited(_startActiveDeliveryTracking(pointerId));
          }
        },
        onError: (Object error) {
          _logRideReq(
            '[DELIVERY_TRACK] driver_active_delivery listener error '
            'driverId=$driverId error=$error',
          );
        },
      );
    }
    if (isActiveDeliveryCallEligible(
      activeDeliveryId: rid,
      delivery: _activeDeliveryData,
      state: _activeDeliveryState,
      driverId: _effectiveDriverId,
    )) {
      final delivery = _activeDeliveryData ?? const <String, dynamic>{};
      final customerUid = deliveryCallCustomerId(delivery);
      final customerName = (delivery['customer_name'] ??
              delivery['customerName'] ??
              delivery['rider_name'] ??
              delivery['riderName'] ??
              delivery['sender_name'] ??
              delivery['senderName'] ??
              'Customer')
          .toString()
          .trim();
      if (customerUid.isNotEmpty) {
        _deliveryCallUi.attach(
          deliveryId: rid,
          driverUid: _effectiveDriverId,
          customerUid: customerUid,
          remoteName: customerName,
        );
      }
    }
    if (mounted) {
      _setStateSafely(() {});
    }
  }

  void _handleActiveDeliverySnapshot(
    String deliveryId,
    Map<String, dynamic>? data,
  ) {
    if (_activeDeliveryId != deliveryId) {
      return;
    }
    if (data == null || data.isEmpty) {
      unawaited(
        _stopActiveDeliveryTracking(reason: 'delivery_missing'),
      );
      return;
    }
    final assigned = DeliveryStateMachine.canonicalAssignedDriverId(data);
    if (assigned.isNotEmpty && assigned != _effectiveDriverId.trim()) {
      _logRideReq(
        '[DELIVERY_TRACK] reassigned deliveryId=$deliveryId assigned=$assigned',
      );
      unawaited(
        _stopActiveDeliveryTracking(reason: 'reassigned_to_other_driver'),
      );
      return;
    }
    final state = DeliveryStateMachine.canonicalStateFromSnapshot(data);
    if (state == DeliveryLifecycleState.completed ||
        state == DeliveryLifecycleState.cancelled) {
      _logRideReq(
        '[DELIVERY_TRACK] terminal deliveryId=$deliveryId state=${state.name}',
      );
      unawaited(
        _stopActiveDeliveryTracking(reason: 'delivery_${state.name}'),
      );
      return;
    }
    _logRideReq(
      '[DELIVERY_TRACK] snapshot deliveryId=$deliveryId state=${state.name}',
    );
    _setStateSafely(() {
      _activeDeliveryData = data;
      _activeDeliveryState = state;
    });
  }

  Future<void> _stopActiveDeliveryTracking({required String reason}) async {
    final hadTracking = _activeDeliverySubscription != null ||
        _driverActiveDeliverySubscription != null ||
        _activeDeliveryId != null;
    final sub = _activeDeliverySubscription;
    final pointerSub = _driverActiveDeliverySubscription;
    final priorId = _activeDeliveryId;
    _activeDeliverySubscription = null;
    _driverActiveDeliverySubscription = null;
    _activeDeliveryId = null;
    _activeDeliveryData = null;
    _activeDeliveryState = DeliveryLifecycleState.searching;
    _deliveryActionInFlight = false;
    _deliveryCallVisibilityLogKey = null;
    await sub?.cancel();
    await pointerSub?.cancel();
    if (hadTracking) {
      if (priorId != null && priorId.trim().isNotEmpty) {
        final endCallOnDetach = reason.contains('cancel') ||
            reason.contains('complete') ||
            reason.contains('completed');
        unawaited(_deliveryCallUi.detach(endCall: endCallOnDetach));
        _handledRideIds.remove(priorId.trim());
      }
      _logRideReq(
        '[DELIVERY_TRACK_DETACH] deliveryId=${priorId ?? 'none'} reason=$reason',
      );
      debugPrint(
        'DRIVER_READY_FOR_RIDE_AFTER_DELIVERY_CANCEL deliveryId=${priorId ?? 'none'} reason=$reason',
      );
      if (_isTerminalTripEligibilityRefreshReason(reason)) {
        _clearOfferPopupState(
          reason: 'delivery_terminal:$reason',
          rideId: priorId,
          clearQueue: true,
          dismissVisibleDialog: true,
          clearCurrentRidePointer: true,
        );
        await _restoreDriverMatchingEligibilityAfterTerminalTrip(
          source: reason,
          rideId: priorId,
        );
      }
    }
    if (mounted) {
      _setStateSafely(() {});
    }
  }

  /// Advance the active delivery to [targetState] via `updateDeliveryState`.
  /// Valid targets (driver progression): driver_arriving_pickup, picked_up,
  /// on_delivery, arrived_dropoff, completed. The delivery_requests listener
  /// reflects the new state; this never calls ride lifecycle callables.
  Future<void> _advanceDeliveryState(String targetState) async {
    final deliveryId = _activeDeliveryId?.trim();
    if (deliveryId == null || deliveryId.isEmpty) {
      _logRideReq(
        '[DELIVERY_STATE_UPDATE_FAIL] target=$targetState reason=no_active_delivery',
      );
      return;
    }
    if (_deliveryActionInFlight) {
      return;
    }
    _setStateSafely(() => _deliveryActionInFlight = true);
    _logRideReq(
      '[DELIVERY_STATE_UPDATE_START] deliveryId=$deliveryId target=$targetState',
    );
    try {
      final response = await _deliveryCloud.updateDeliveryState(
        deliveryId: deliveryId,
        deliveryState: targetState,
        driverLat: _driverLocation.latitude,
        driverLng: _driverLocation.longitude,
      );
      if (deliveryCallableSucceeded(response)) {
        _logRideReq(
          '[DELIVERY_STATE_UPDATE_OK] deliveryId=$deliveryId target=$targetState',
        );
      } else {
        final reason = _valueAsText(response['reason']).isNotEmpty
            ? _valueAsText(response['reason'])
            : (_valueAsText(response['error']).isNotEmpty
                ? _valueAsText(response['error'])
                : 'unknown');
        _logRideReq(
          '[DELIVERY_STATE_UPDATE_FAIL] deliveryId=$deliveryId '
          'target=$targetState reason=$reason',
        );
        final message = reason == 'payment_not_verified'
            ? 'Waiting for rider payment verification.'
            : reason == 'delivery_proof_required'
                ? 'Upload delivery photo before completing.'
            : reason == 'pickup_proof_required'
                ? 'Upload pickup photo before confirming pickup.'
                : 'Could not update delivery: $reason';
        _showSnackBarSafely(SnackBar(content: Text(message)));
      }
    } catch (error) {
      _logRideReq(
        '[DELIVERY_STATE_UPDATE_FAIL] deliveryId=$deliveryId '
        'target=$targetState error=$error',
      );
      _showSnackBarSafely(
        const SnackBar(
          content: Text('Could not update delivery. Please try again.'),
        ),
      );
    } finally {
      if (mounted) {
        _setStateSafely(() => _deliveryActionInFlight = false);
      }
    }
  }

  void _logDeliveryDriverCallVisibility(String deliveryId, String phone) {
    if (deliveryId.isEmpty) {
      return;
    }
    final phonePresent = phone.trim().length >= 8;
    final key = '$deliveryId:$phonePresent';
    if (_deliveryCallVisibilityLogKey == key) {
      return;
    }
    _deliveryCallVisibilityLogKey = key;
    if (phonePresent) {
      debugPrint(
        'DELIVERY_DRIVER_CALL_VISIBLE deliveryId=$deliveryId phonePresent=true',
      );
    } else {
      debugPrint('DELIVERY_CALL_INFO_MISSING deliveryId=$deliveryId');
    }
  }

  Widget _buildActiveDeliveryDraggablePanel() {
    final delivery = _activeDeliveryData ?? const <String, dynamic>{};
    final deliveryId = (_activeDeliveryId ?? _currentRideId ?? '').trim();
    final riderPhone = DriverActiveDeliveryPanel.resolveDeliveryContactPhone(
      delivery,
    );
    _logDeliveryDriverCallVisibility(deliveryId, riderPhone);
    final riderName = (delivery['customer_name'] ??
            delivery['customerName'] ??
            delivery['rider_name'] ??
            delivery['riderName'] ??
            delivery['sender_name'] ??
            delivery['senderName'] ??
            '')
        .toString()
        .trim();
    return DriverActiveDeliveryPanel(
      delivery: delivery,
      state: _activeDeliveryState,
      busy: _deliveryActionInFlight,
      onAdvance: _advanceDeliveryState,
      onUploadProof: _uploadDispatchDeliveryProof,
      onUploadPickupProof: _uploadDispatchPickupProof,
      onRateRider: _promptDriverDeliveryRating,
      onOpenChat: _openActiveDeliveryChat,
      onCallRider: () => unawaited(_startActiveDeliveryInAppCall()),
      onCancelDelivery: _cancelActiveDelivery,
      onReportIssue: _reportActiveDeliveryIssue,
      proofUploading: _deliveryProofUploading,
      pickupProofUploading: _pickupProofUploading,
      riderPhone: riderPhone,
      riderName: riderName,
    );
  }

  void _startActiveDeliveryChatListener(String deliveryId) {
    unawaited(_activeDeliveryChatSubscription?.cancel());
    _activeDeliveryChatSubscription =
        _driverDeliveryChatService.startListener(
      deliveryId: deliveryId,
      onMessages: (messages) {
        _activeDeliveryChatMessages.value = messages;
      },
    );
  }

  Future<String?> _sendActiveDeliveryChatImage(
    String deliveryId,
    DriverDeliveryChatImageSource source,
  ) async {
    final senderId = _effectiveDriverId;
    if (senderId.isEmpty) {
      return 'Driver account is not available.';
    }
    final useCamera = source == DriverDeliveryChatImageSource.camera;
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
    logChatImagePicked(
      chatKind: 'delivery_chat',
      threadId: deliveryId,
      source: useCamera ? 'camera' : 'gallery',
      localPath: picked.path,
      actorId: senderId,
    );
    try {
      final uploaded = await _dispatchPhotoUploadService.uploadDeliveryChatPhoto(
        deliveryId: deliveryId,
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
      return _driverDeliveryChatService.sendImage(
        deliveryId: deliveryId,
        imageUrl: uploaded.fileUrl,
      );
    } catch (error) {
      return 'Unable to send this image right now.';
    }
  }

  Future<void> _openActiveDeliveryChat() async {
    final deliveryId = (_activeDeliveryId ?? _currentRideId ?? '').trim();
    if (deliveryId.isEmpty || !mounted) {
      return;
    }
    _startActiveDeliveryChatListener(deliveryId);
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.72,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: DriverDeliveryChatSheet(
              deliveryId: deliveryId,
              currentUserId: user.uid,
              messagesListenable: _activeDeliveryChatMessages,
              onSendMessage: (id, text) =>
                  _driverDeliveryChatService.sendText(
                deliveryId: id,
                text: text,
              ),
              onSendImage: _sendActiveDeliveryChatImage,
            ),
          ),
        );
      },
    );
  }

  Future<void> _startActiveDeliveryInAppCall() async {
    final deliveryId = (_activeDeliveryId ?? '').trim();
    final delivery = _activeDeliveryData;
    final customerId = deliveryCallCustomerId(delivery);
    final driverId = _effectiveDriverId;
    if (deliveryId.isEmpty ||
        delivery == null ||
        customerId.isEmpty ||
        driverId.isEmpty ||
        !isActiveDeliveryCallEligible(
          activeDeliveryId: _activeDeliveryId,
          delivery: delivery,
          state: _activeDeliveryState,
          driverId: driverId,
        )) {
      _showSnackBarSafely(
        const SnackBar(content: Text('In-app call is unavailable for this delivery.')),
      );
      return;
    }
    debugPrint('DELIVERY_CALL_START deliveryId=$deliveryId role=driver');
    try {
      await _deliveryCallUi.startOutgoingCall(
        deliveryId: deliveryId,
        delivery: delivery,
        driverUid: driverId,
        state: _activeDeliveryState,
      );
    } on RideCallException catch (error) {
      debugPrint(
        'DELIVERY_CALL_FAIL deliveryId=$deliveryId reason=${error.message}',
      );
      _showSnackBarSafely(SnackBar(content: Text(error.message)));
    } catch (error) {
      debugPrint('DELIVERY_CALL_FAIL deliveryId=$deliveryId reason=$error');
      _showSnackBarSafely(
        SnackBar(content: Text('Call could not start: $error')),
      );
    }
  }

  Future<void> _callActiveDeliveryRiderByPhone() async {
    final delivery = _activeDeliveryData ?? const <String, dynamic>{};
    final deliveryId = (_activeDeliveryId ?? _currentRideId ?? '').trim();
    final phone = DriverActiveDeliveryPanel.resolveDeliveryContactPhone(
      delivery,
    );
    if (phone.isEmpty) {
      debugPrint('DELIVERY_CALL_INFO_MISSING deliveryId=$deliveryId');
      _showSnackBarSafely(const SnackBar(content: Text('Sender phone unavailable.')));
      return;
    }
    debugPrint('DELIVERY_DRIVER_CALL_TAP deliveryId=$deliveryId');
    final uri = Uri(scheme: 'tel', path: phone);
    if (!await canLaunchUrl(uri)) {
      _showSnackBarSafely(const SnackBar(content: Text('Could not start phone call.')));
      return;
    }
    await launchUrl(uri);
  }

  Future<void> _cancelActiveDelivery() async {
    final deliveryId = (_activeDeliveryId ?? _currentRideId ?? '').trim();
    if (deliveryId.isEmpty) {
      return;
    }
    final state = _activeDeliveryState;
    final afterPickup = state == DeliveryLifecycleState.pickedUp ||
        state == DeliveryLifecycleState.onDelivery ||
        state == DeliveryLifecycleState.arrivedDropoff;
    if (afterPickup) {
      _showSnackBarSafely(
        const SnackBar(
          content: Text('After pickup, contact support to cancel this delivery.'),
        ),
      );
      return;
    }
    if (_deliveryPaymentBlocksDriverCancel(_activeDeliveryData)) {
      debugPrint(
        'DELIVERY_CANCEL_BLOCKED_PAYMENT_VERIFIED deliveryId=$deliveryId '
        'driverId=$_effectiveDriverId',
      );
      _showSnackBarSafely(
        const SnackBar(
          content: Text(
            'Paid deliveries cannot be cancelled by the driver. Contact support.',
          ),
        ),
      );
      return;
    }
    final picked = await showDeliveryCancelReasonSheet(
      context: context,
      title: 'Why are you cancelling?',
      options: driverDeliveryCancelReasons,
    );
    if (picked == null || !mounted) {
      return;
    }
    try {
      final res = await _deliveryCloud.cancelDeliveryRequest(
        deliveryId: deliveryId,
        cancelReason: 'cancelled_by_driver',
        cancelReasonCode: picked.code,
        cancelReasonText: picked.text,
        cancelNote: picked.note,
      );
      if (!deliveryCallableSucceeded(res)) {
        final failReason = _valueAsText(res['reason']).toLowerCase();
        final failMessage = _valueAsText(res['message']);
        if (failReason.contains('paid') && failReason.contains('cancel_blocked')) {
          debugPrint(
            'DELIVERY_CANCEL_BLOCKED_PAYMENT_VERIFIED deliveryId=$deliveryId '
            'driverId=$_effectiveDriverId reason=$failReason',
          );
        }
        _showSnackBarSafely(
          SnackBar(
            content: Text(
              failMessage.isNotEmpty
                  ? failMessage
                  : 'Cancel failed: ${res['reason'] ?? 'unknown'}',
            ),
          ),
        );
        return;
      }
      _showSnackBarSafely(const SnackBar(content: Text('Delivery cancelled.')));
      await _stopActiveDeliveryTracking(reason: 'driver_cancelled');
    } catch (error) {
      _showSnackBarSafely(SnackBar(content: Text('Cancel failed: $error')));
    }
  }

  Future<void> _reportActiveDeliveryIssue() async {
    _showSnackBarSafely(
      const SnackBar(content: Text('Use Support Center to report delivery issues.')),
    );
  }

  Future<void> _uploadDispatchPickupProof() async {
    final currentRideId = _currentRideId;
    final currentRideData = _currentRideData;
    if (currentRideId == null ||
        currentRideData == null ||
        !_isDispatchDeliveryService(
          _serviceTypeKey(currentRideData['service_type']),
        )) {
      return;
    }
    if (_pickupProofUploading) {
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
      setState(() => _pickupProofUploading = true);
    } else {
      _pickupProofUploading = true;
    }
    try {
      final uploadedPhoto = await _dispatchPhotoUploadService.uploadRidePhoto(
        rideId: currentRideId,
        actorId: _effectiveDriverId,
        category: 'pickup_proof',
        asset: asset,
      );
      final proofRes = await _deliveryCloud.registerPickupProofPhoto(
        deliveryId: currentRideId,
        photoUrl: uploadedPhoto.fileUrl,
      );
      if (!deliveryCallableSucceeded(proofRes)) {
        throw StateError(proofRes['reason']?.toString() ?? 'pickup_proof_register_failed');
      }
      if (mounted) {
        setState(() {
          _pickupProofUploading = false;
          final next = Map<String, dynamic>.from(currentRideData);
          next['pickup_proof_photo_url'] = uploadedPhoto.fileUrl;
          _currentRideData = next;
          if (_activeDeliveryId == currentRideId) {
            _activeDeliveryData = Map<String, dynamic>.from(next);
          }
        });
      }
      _showSnackBarSafely(const SnackBar(content: Text('Pickup photo uploaded.')));
    } catch (error) {
      if (mounted) {
        setState(() => _pickupProofUploading = false);
      } else {
        _pickupProofUploading = false;
      }
      _showSnackBarSafely(const SnackBar(content: Text('Pickup photo upload failed.')));
    }
  }

  Future<bool> _acceptRide(
    String rideId, {
    String? driverName,
    String? car,
    String? plate,
    int? acceptRequestedAt,
  }) async {
    final rid = rideId.trim();
    if (!_isValidRideId(rid)) {
      _logRideReq(
        '[MATCH_DEBUG][ACCEPT_LOCK_FAIL] rideId=$rideId reason=ride_id_missing',
      );
      _logRtdb('accept blocked rideId=$rideId reason=ride_id_missing');
      return false;
    }

    final popupRideId = _activePopupRideId;
    if (popupRideId != null && popupRideId != rid) {
      _logRideReq(
        '[MATCH_DEBUG][ACCEPT_LOCK_FAIL] rideId=$rid reason=popup_request_mismatch '
        'popupRideId=$popupRideId',
      );
      _logRtdb(
        'accept blocked rideId=$rid reason=popup_request_mismatch popupRideId=$popupRideId',
      );
      return false;
    }

    final existing = _acceptRideInFlightById[rid];
    if (existing != null) {
      _logRideReq('[ACCEPT_JOIN_IN_FLIGHT] rideId=$rid');
      return existing;
    }
    for (final otherId in _acceptRideInFlightById.keys) {
      if (otherId != rid) {
        _logRideReq(
          '[MATCH_DEBUG][ACCEPT_LOCK_FAIL] rideId=$rid reason=accept_other_ride_in_flight '
          'activeRideId=$otherId',
        );
        _logRtdb(
          'accept blocked rideId=$rid reason=accept_other_ride_in_flight active=$otherId',
        );
        return false;
      }
    }

    final acceptFuture = _acceptRideOnce(
      rid,
      driverName: driverName,
      car: car,
      plate: plate,
      acceptRequestedAt: acceptRequestedAt,
    );
    _acceptRideInFlightById[rid] = acceptFuture;
    try {
      return await acceptFuture;
    } finally {
      _acceptRideInFlightById.remove(rid);
    }
  }

  Future<bool> _acceptRideOnce(
    String rideId, {
    String? driverName,
    String? car,
    String? plate,
    int? acceptRequestedAt,
  }) async {
    _acceptingPopupRideId = rideId;
    _startRideAcceptGrace(rideId);
    dispatchVerboseLog('RIDE_STATE_PROPAGATION_WAIT rideId=$rideId');
    _logRtdb(
      'accept requested rideId=$rideId path=ride_requests/$rideId popupRideId=${_activePopupRideId ?? _acceptingPopupRideId ?? rideId}',
    );

    final ref = _rideRequestsRef.child(rideId);
    final effectiveAcceptRequestedAt =
        acceptRequestedAt ?? DateTime.now().millisecondsSinceEpoch;
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
      'sessionWarning=${availabilityInvalidReason ?? 'none'} '
      'acceptRequestedAt=$effectiveAcceptRequestedAt',
    );
    var acceptSucceeded = false;
    try {
      final authUser = FirebaseAuth.instance.currentUser;
      if (authUser == null) {
        throw Exception('No authenticated user');
      }
      // Force a fresh ID token before callable invocation so backend context.auth
      // is populated with current session credentials.
      await authUser.getIdToken(true);
      final driverId = authUser.uid.trim();
      final driverSnapshot = await runRtdbQueryGet(
        query: _driversRef.child(driverId),
        path: 'drivers/$driverId',
        source: 'driver_map.accept_driver_precheck',
      );
      final driverRecord = _asStringDynamicMap(driverSnapshot.value);
      final storedUid = _valueAsText(driverRecord?['uid']);
      final storedId = _valueAsText(driverRecord?['id']);
      final driverProfileMatchesUid =
          (storedUid.isEmpty || storedUid == driverId) &&
              (storedId.isEmpty || storedId == driverId);
      final callablePayload = <String, dynamic>{
        'rideId': rideId,
        'driverId': driverId,
      };
      _logRideReq(
        '[ACCEPT_PRECHECK] authUid=${authUser.uid} effectiveDriverIdSent=$driverId '
        'driverNodeExists=${driverSnapshot.exists} driverIdField=$storedId '
        'driverUidField=$storedUid driverProfileMatchesUid=$driverProfileMatchesUid '
        'payloadRideId=$rideId payloadDriverId=$driverId',
      );
      if (!driverSnapshot.exists ||
          !driverProfileMatchesUid) {
        _setApiStatus(
          'failed',
          errorMessage:
              'Driver profile is not ready. Please refresh your account session.',
        );
        _showSnackBarSafely(
          const SnackBar(
            content: Text(
              'Driver profile is not ready. Please refresh your account session.',
            ),
          ),
        );
        return false;
      }
      rtdb.DataSnapshot? preflightSnapshot;
      preflightSnapshot = await runRtdbQueryGet(
        query: ref,
        path: 'ride_requests/$rideId',
        source: 'driver_map.accept_preflight',
      );
      Map<String, dynamic>? preflightRideData =
          _asStringDynamicMap(preflightSnapshot.value) ??
              _driverOfferRideCache[rideId];
      if (preflightRideData == null) {
        final offerEntryPath = 'driver_offer_queue/$driverId/$rideId';
        final offerQueued = _driverOfferQueueReplica.containsKey(rideId) ||
            (await runRtdbQueryGet(
              query: rtdb.FirebaseDatabase.instance.ref(offerEntryPath),
              path: offerEntryPath,
              source: 'driver_map.accept_offer_entry_check',
            )).exists;
        if (offerQueued) {
          preflightSnapshot = await runRtdbQueryGet(
            query: ref,
            path: 'ride_requests/$rideId',
            source: 'driver_map.accept_preflight_retry',
          );
          preflightRideData = _asStringDynamicMap(preflightSnapshot.value);
        }
      }
      final rideKey = rideId.trim();
      final offerQueued = _driverOfferQueueReplica.containsKey(rideKey);
      if (preflightRideData == null && offerQueued) {
        preflightRideData = _rideDataFromDriverOfferQueue(
          rideKey,
          _asStringDynamicMap(_driverOfferQueueReplica[rideKey]),
        );
      }
      final backendTrustedOffer =
          offerQueued || _isBackendTrustedOffer(rideId, preflightRideData);
      if (backendTrustedOffer) {
        _offerDiscoveryLog(
          'OFFER_ACCEPT_LOCAL_GATE_BYPASSED',
          rideId: rideId,
          detail: 'reason=backend_offer_exists',
        );
      }
      final offerAcceptable = backendTrustedOffer && offerQueued
          ? true
          : _driverOfferRideStillAcceptable(preflightRideData, driverId);
      final paymentAcceptable = backendTrustedOffer ||
          _paymentAllowsAcceptRide(preflightRideData);
      final canAcceptPreflight = backendTrustedOffer && offerQueued
          ? true
          : preflightRideData != null && offerAcceptable && paymentAcceptable;
      if (!canAcceptPreflight) {
        final blockReason = preflightRideData == null
            ? 'offer_unavailable_preflight'
            : !offerAcceptable
                ? 'offer_not_acceptable'
                : 'payment_not_verified';
        _offerDiscoveryLog(
          'OFFER_ACCEPT_BLOCKED',
          rideId: rideId,
          detail:
              'offer=$offerAcceptable payment=$paymentAcceptable backendTrusted=$backendTrustedOffer '
              'status=${_valueAsText(preflightRideData?['payment_status'])} reason=$blockReason',
        );
        _offerDiscoveryLog(
          'OFFER_ACCEPT_FIRST_TAP_BLOCKED',
          rideId: rideId,
          detail:
              'offer=$offerAcceptable payment=$paymentAcceptable status=${_valueAsText(preflightRideData?['payment_status'])}',
        );
        _setApiStatus(
          'failed',
          errorMessage: backendTrustedOffer && !offerAcceptable
              ? 'This request is no longer available.'
              : _acceptBlockedMessage(
                  blockedReason: blockReason,
                  rideData: preflightRideData,
                  rideId: rideId,
                ),
        );
        _offerDiscoveryLog(
          'OFFER_ACCEPT_FAIL',
          rideId: rideId,
          detail: blockReason,
        );
        return false;
      }
      final acceptRideSnapshot = preflightRideData ??
          _rideDataFromDriverOfferQueue(
            rideKey,
            _asStringDynamicMap(_driverOfferQueueReplica[rideKey]),
          ) ??
          <String, dynamic>{
            'ride_id': rideKey,
            'status': 'searching',
            'trip_state': 'searching',
          };
      _logRideReq(
        '[ACCEPT_DEBUG_PRE] rideId=$rideId path=ride_requests/$rideId '
        'snapshotExists=${preflightSnapshot?.exists ?? true} '
        'status=${_valueAsText(acceptRideSnapshot['status'])} '
        'driver_id=${_valueAsText(acceptRideSnapshot['driver_id'])} '
        'trip_state=${_valueAsText(acceptRideSnapshot['trip_state'])}',
      );
      final simulatedAccept = await _backendSimulation.acceptTrip(
        BackendAcceptRequest(
          rideId: rideId,
          driverId: driverId,
          driverServiceTypes: _effectiveDriverServiceTypes(),
          rideSnapshot: acceptRideSnapshot,
        ),
      );
      if (!simulatedAccept.ok) {
        _setApiStatus('failed', errorMessage: simulatedAccept.message);
        _showSnackBarSafely(SnackBar(content: Text(simulatedAccept.message)));
        return false;
      }
      String blockedReason = 'unknown';
      var acceptLockWasIdempotent = false;
      _logRideReq(
        '[MATCH_DEBUG][ACCEPT_START] rideId=$rideId driverId=$driverId',
      );
      _logRideReq(
        '[DRIVER_ACCEPT_START] rideId=$rideId driverId=$driverId',
      );
      _logRideReq(
        '[MATCH_DEBUG][ACCEPT_TX_BEGIN] rideId=$rideId driverId=$driverId',
      );
      _logRideReq(
        '[DRIVER_ACCEPT_TX] stage=begin rideId=$rideId driverId=$driverId',
      );
      _logRideReq(
        'DRIVER_ACCEPT_API_START rideId=$rideId driverId=$driverId',
      );
      _offerDiscoveryLog('OFFER_ACCEPT_CALL_START', rideId: rideId);
      dispatchVerboseLog(
        'ACCEPT_CALL_PAYLOAD driverId=$driverId authUid=${authUser.uid}',
      );
      final functions = FirebaseFunctions.instanceFor(region: 'us-central1');
      final callable = functions.httpsCallable('acceptRide');
      Map<String, dynamic>? callableResponse;
      var acceptOk = false;
      const maxAcceptApiAttempts = 3;
      for (var apiAttempt = 0; apiAttempt < maxAcceptApiAttempts; apiAttempt++) {
        if (apiAttempt > 0) {
          await Future<void>.delayed(Duration(milliseconds: 350 * apiAttempt));
        }
        final callableResult = await callable.call(callablePayload);
        callableResponse = _asStringDynamicMap(callableResult.data);
        acceptOk = callableResponse?['success'] == true;
        blockedReason = _valueAsText(callableResponse?['reason']);
        acceptLockWasIdempotent = callableResponse?['idempotent'] == true;
        if (acceptOk) {
          break;
        }
        final retryable = blockedReason == 'accept_pending_retry' ||
            blockedReason == 'transaction_conflict';
        if (!retryable || apiAttempt >= maxAcceptApiAttempts - 1) {
          break;
        }
        _logRideReq(
          '[ACCEPT_API_RETRY] rideId=$rideId attempt=${apiAttempt + 1} '
          'reason=$blockedReason',
        );
      }

      if (!acceptOk &&
          (blockedReason == 'unavailable' ||
              blockedReason == 'payment_not_dispatchable')) {
        _offerDiscoveryLog(
          'OFFER_ACCEPT_RETRY',
          rideId: rideId,
          detail: blockedReason,
        );
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final refreshedPreflight =
            _asStringDynamicMap(
              (await runRtdbQueryGet(
                query: ref,
                path: 'ride_requests/$rideId',
                source: 'driver_map.accept_preflight_refresh',
              )).value,
            );
        final refreshedTrusted = offerQueued ||
            _isBackendTrustedOffer(rideId, refreshedPreflight);
        final refreshedAllowsAccept = offerQueued ||
            (refreshedPreflight != null &&
                _driverOfferRideStillAcceptable(refreshedPreflight, driverId) &&
                (refreshedTrusted ||
                    _paymentAllowsAcceptRide(refreshedPreflight)));
        if (refreshedAllowsAccept) {
          final retryResult = await callable.call(callablePayload);
          callableResponse = _asStringDynamicMap(retryResult.data);
          acceptOk = callableResponse?['success'] == true;
          blockedReason = _valueAsText(callableResponse?['reason']);
          acceptLockWasIdempotent = callableResponse?['idempotent'] == true;
        }
      }

      if (!acceptOk) {
        final alreadyAssigned = blockedReason == 'driver_already_set' ||
            blockedReason == 'already_taken' ||
            _rideBelongsToAnotherDriver(preflightRideData);
        if (alreadyAssigned) {
          _offerDiscoveryLog('OFFER_ACCEPT_ALREADY_ASSIGNED', rideId: rideId);
        }
        _offerDiscoveryLog(
          'OFFER_ACCEPT_FIRST_TAP_BLOCKED',
          rideId: rideId,
          detail: blockedReason.isEmpty ? 'unknown' : blockedReason,
        );
        _offerDiscoveryLog(
          'OFFER_ACCEPT_FAIL',
          rideId: rideId,
          detail: blockedReason.isEmpty ? 'unknown' : blockedReason,
        );
        _offerDiscoveryLog(
          'ACCEPT_FAILED',
          rideId: rideId,
          detail: blockedReason.isEmpty ? 'unknown' : blockedReason,
        );
        _logRideReq(
          'DRIVER_ACCEPT_API_FAIL rideId=$rideId reason=${blockedReason.isEmpty ? 'unknown' : blockedReason}',
        );
      } else {
        final acceptedRideData =
            _asStringDynamicMap(
              (await runRtdbQueryGet(
                query: ref,
                path: 'ride_requests/$rideId',
                source: 'driver_map.accept_post_cloud',
              )).value,
            ) ??
            preflightRideData;
        _offerDiscoveryLog(
          'OFFER_ACCEPT_FIRST_TAP_OK',
          rideId: rideId,
          detail:
              'payment_status=${_valueAsText(acceptedRideData?['payment_status'])}',
        );
        if (_shouldShowDriverPaymentConfirmation(acceptedRideData)) {
          _offerDiscoveryLog(
            'ACCEPT_PAYMENT_REVIEW_ALLOWED',
            rideId: rideId,
            detail: _valueAsText(acceptedRideData?['payment_status']),
          );
        }
        _offerDiscoveryLog('OFFER_ACCEPT_SUCCESS', rideId: rideId);
        _offerDiscoveryLog('OFFER_ACCEPTED', rideId: rideId);
        _offerDiscoveryLog('MATCH_ASSIGNED', rideId: rideId);
        _logRideReq(
          'DRIVER_ACCEPT_API_SUCCESS rideId=$rideId idempotent=$acceptLockWasIdempotent',
        );
      }

      Map<String, dynamic>? latestRideData;
      Map<String, dynamic>? ridePayload;
      const maxSnapAttempts = 6;
      const snapBackoff = Duration(milliseconds: 100);
      for (var attempt = 0; attempt < maxSnapAttempts; attempt++) {
        if (attempt > 0) {
          await Future<void>.delayed(snapBackoff);
        }
        latestRideData = _asStringDynamicMap(
          (await runRtdbQueryGet(
            query: ref,
            path: 'ride_requests/$rideId',
            source: 'driver_map.accept_assignment_poll',
          )).value,
        );
        if (latestRideData != null && _rideAssignedToUid(latestRideData, driverId)) {
          ridePayload = latestRideData;
          break;
        }
      }

      final payloadForAcceptTrust = ridePayload;
      if (acceptOk &&
          (payloadForAcceptTrust == null ||
              !_rideAssignedToUid(payloadForAcceptTrust, driverId))) {
        ridePayload = Map<String, dynamic>.from(acceptRideSnapshot)
          ..['driver_id'] = driverId
          ..['matched_driver_id'] = driverId
          ..['accepted_driver_id'] = driverId
          ..['accepted_at'] = DateTime.now().millisecondsSinceEpoch
          ..['updated_at'] = DateTime.now().millisecondsSinceEpoch;
        _logRideReq(
          '[ACCEPT_FALLBACK_PAYLOAD] rideId=$rideId reason=api_success_stale_snapshot',
        );
      }

      if (!acceptOk &&
          ridePayload == null &&
          latestRideData != null &&
          _rideAssignedToUid(latestRideData, driverId)) {
        ridePayload = latestRideData;
      }

      _logRideReq(
        '[ACCEPT_DEBUG_POST] rideId=$rideId path=ride_requests/$rideId '
        'apiOk=$acceptOk '
        'apiReason=${blockedReason.isEmpty ? 'none' : blockedReason} '
        'rtdbAfterExists=${latestRideData != null} '
        'statusAfter=${latestRideData == null ? 'null' : _valueAsText(latestRideData['status'])} '
        'driverIdAfter=${latestRideData == null ? 'null' : _valueAsText(latestRideData['driver_id'])} '
        'tripStateAfter=${latestRideData == null ? 'null' : _valueAsText(latestRideData['trip_state'])} '
        'committedForDriver=${ridePayload != null}',
      );

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
          'rtdb_committed=false',
        );
        _logRideReq(
          '[DRIVER_ACCEPT_TX] stage=abort rideId=$rideId reason=$latestBlockedReason '
          'committed=false',
        );
        _logRideReq(
          '[MATCH_DEBUG][ACCEPT_LOCK_FAIL] rideId=$rideId reason=$latestBlockedReason '
          'committed=false',
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
        _suppressPopupForeverAfterTerminalAcceptFailure(
          rideId,
          latestBlockedReason,
        );
        _offerDiscoveryLog(
          'ACCEPT_FAILED',
          rideId: rideId,
          detail: latestBlockedReason,
        );
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
            _rideAssignedToUid(ridePayload, _effectiveDriverId);
        final treatAsSoftFailure = assignedHere &&
            (TripStateMachine.isDriverActiveState(committedCanonicalState) ||
                TripStateMachine.isPendingDriverAssignmentState(
                    committedCanonicalState));
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
        'idempotent=$acceptLockWasIdempotent rtdb_committed=true '
        'trip_state=$committedCanonicalForCommit ui_status=$committedStatus',
      );
      _logRideReq(
          '[OPEN_POOL_REMOVE] rideId=$rideId market_pool=null source=accept_tx');
      _logRideReq(
        '[DRIVER_ACCEPT_TX] stage=commit rideId=$rideId driverId=$_effectiveDriverId '
        'trip_state=$committedCanonicalForCommit ui_status=$committedStatus',
      );
      _logCanonicalRideEvent(
        eventName: 'transaction_committed',
        rideId: rideId,
        rideData: validatedCommittedRideData,
      );
      dispatchVerboseLog('[DRIVER_ACCEPTED_REQUEST] rideId=$rideId');

      final rid = rideId.trim();
      final acceptedAsQueuedNext = callableResponse?['queued'] == true;
      final activeRideDuringQueueAccept =
          _valueAsText(callableResponse?['active_ride_id']);
      var criticalPostAcceptSyncOk = false;
      final preserveActiveRideId = acceptedAsQueuedNext &&
          activeRideDuringQueueAccept.isNotEmpty &&
          (_currentRideId?.trim().isNotEmpty == true ||
              _driverActiveRideId?.trim().isNotEmpty == true);
      final driverPresenceCritical = _buildDriverPresenceUpdate(
        status: preserveActiveRideId
            ? _rideStatus
            : committedStatus,
        activeRideId: preserveActiveRideId
            ? (_currentRideId ?? _driverActiveRideId ?? activeRideDuringQueueAccept)
            : rideId,
        isAvailable: false,
      );
      try {
        criticalPostAcceptSyncOk = await _commitCriticalRideAndDriverSnapshot(
          rideId: rideId,
          rideUpdates: const <String, dynamic>{},
          driverUpdates: driverPresenceCritical,
        );
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

      dispatchVerboseLog('RIDE_ACCEPTED_PERSISTED rideId=$rideId');
      dispatchVerboseLog('RIDE_STATE_CONFIRMED_ASSIGNED rideId=$rideId');
      _clearRideAcceptGrace(rideId: rideId);
      _terminalSelfAcceptedRideIds.add(rid);
      _foreverSuppressedRidePopupIds.add(rid);
      _suppressedRidePopupIds.add(rid);
      _discoveryPopupCooldownUntilMs.remove(rid);
      _lastDiscoveryDismissFingerprintByRideId.remove(rid);
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
        'ACCEPT_SUCCESS rideId=$rideId driverId=$_effectiveDriverId '
        'trip_state=$committedCanonicalForCommit ui_status=$committedStatus '
        'critical_rtdb_sync_ok=$criticalPostAcceptSyncOk',
      );
      _logRideReq(
        '[DRIVER_ACCEPT_OK] rideId=$rideId driverId=$_effectiveDriverId '
        'trip_state=$committedCanonicalForCommit ui_status=$committedStatus',
      );
      _logRideReq('DRIVER_OFFER_ACCEPTED rideId=$rideId driverId=$_effectiveDriverId');
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
      if (acceptedAsQueuedNext) {
        _logRideReq(
          'DRIVER_NEXT_RIDE_QUEUED rideId=$rideId activeRideId=${_currentRideId ?? _driverActiveRideId ?? activeRideDuringQueueAccept}',
        );
        _queuedNextRideIdFromProfile = rid;
        if (mounted) {
          _showSnackBarSafely(
            const SnackBar(
              content: Text(
                'Next ride queued. Finish your current trip first.',
              ),
            ),
          );
        }
      }
      if (mounted) {
        setState(() {
          if (!acceptedAsQueuedNext) {
            _driverActiveRideId = rideId;
            _currentRideId = rideId;
            _currentRideData =
                Map<String, dynamic>.from(validatedCommittedRideData);
            _rideStatus = committedStatus;
            _tripStarted = committedStatus == 'on_trip';
          }
          _driverUnreadChatCount = 0;
      _driverChatUnreadNotifier.value = 0;
          _isDriverChatOpen = false;
        });
      } else if (!acceptedAsQueuedNext) {
        _driverActiveRideId = rideId;
        _currentRideId = rideId;
        _currentRideData =
            Map<String, dynamic>.from(validatedCommittedRideData);
        _rideStatus = committedStatus;
        _tripStarted = committedStatus == 'on_trip';
        _driverUnreadChatCount = 0;
      _driverChatUnreadNotifier.value = 0;
        _isDriverChatOpen = false;
      }
      if (!acceptedAsQueuedNext) {
        unawaited(_suspendOfferDiscoveryForActiveTrip('driver_accept'));
      }
      _logRideReq(
        '[MATCH_DEBUG][ACCEPT_UI_SUCCESS] rideId=$rideId ui_status=$committedStatus '
        'trip_state=$committedCanonicalForCommit',
      );
      if (!acceptedAsQueuedNext) {
        _logRideReq('[NAVIGATION_TRIGGERED] rideId=$rideId target=active_trip');
        _ensureActiveTripNavigation(
          rideId: rideId,
          rideData: validatedCommittedRideData,
        );
      }
      _logRideReq(
        '[MATCH_DEBUG][POST_ACCEPT_DRIVER_STATE] rideId=$rideId '
        'rideStatus=$_rideStatus currentRideId=$_currentRideId '
        'driverActive=$_driverActiveRideId trip_state=$committedCanonicalForCommit',
      );
      if (!acceptedAsQueuedNext) {
        try {
          _applyRideLocationsFromData(validatedCommittedRideData);
          _evaluateArrivedAvailability();
          _loggedDriverChatMessageIds.clear();
          _ensureDriverChatUnreadListener(rideId);
          _syncRiderDisplayFromRideSnapshot(
            rideId: rideId,
            rideData: validatedCommittedRideData,
          );
          await _listenToActiveRide(rideId);
          debugPrint('DRIVER_ACCEPT_RIDE_NO_CRASH rideId=$rideId');
          _logRideReq('[ACTIVE_TRIP_LOADED] rideId=$rideId');
          _scheduleActiveRouteRefresh(
            force: true,
            reason: 'driver_accept_local',
            debounce: Duration.zero,
          );
          try {
            debugPrint(
              'DRIVER_ROUTE_FIT_START rideId=$rideId source=driver_accept_local',
            );
            _moveCameraToActiveTrip();
            debugPrint(
              'DRIVER_ROUTE_FIT_SUCCESS rideId=$rideId source=driver_accept_local',
            );
          } catch (error) {
            debugPrint(
              'DRIVER_ROUTE_FIT_FAIL rideId=$rideId reason=$error',
            );
          }
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
      }

      _logRideStateChangeOnce(
        rideId: rideId,
        riderId: _valueAsText(validatedCommittedRideData['rider_id']),
        driverId: _effectiveDriverId,
        serviceType:
            _serviceTypeKey(validatedCommittedRideData['service_type']),
        status: committedStatus,
        source: 'driver_accept',
        rideData: validatedCommittedRideData,
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
      final errorMessage = _acceptFailureMessageFromException(error);
      _setApiStatus(
        'failed',
        errorMessage: errorMessage,
      );
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
        SnackBar(content: Text(errorMessage)),
      );
      return false;
    } finally {
      if (!acceptSucceeded) {
        _clearRideAcceptGrace(rideId: rideId);
        if (_acceptingPopupRideId == rideId) {
          _acceptingPopupRideId = null;
        }
        final rid = rideId.trim();
        if (_currentRideId?.trim() == rid ||
            _driverActiveRideId?.trim() == rid) {
          final committed = _isCommittedActiveRideForDriver(
            _currentRideData,
            rideId: rid,
          );
          if (!committed) {
            _currentRideId = null;
            _driverActiveRideId = null;
            _discoverySuspendedForRideId = null;
          }
        }
        _releaseRidePopupSessionBlocks(rid);
        if (_isOnline) {
          _scheduleDiscoveryRearmWhenIdle('accept_failed');
        }
      }
    }
  }

  void _applyLocalDriverArrivedUi(String rideId) {
    final arrivedAtMs = DateTime.now().millisecondsSinceEpoch;
    final graceUntilMs =
        arrivedAtMs + const Duration(minutes: 5).inMilliseconds;
    final nextRideData = _currentRideData == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(_currentRideData!);
    // UI-only cache — lifecycle authority is server trip_state (no client RTDB writes).
    nextRideData['arrived_at'] = arrivedAtMs;
    nextRideData['driver_arrived_at'] = arrivedAtMs;
    nextRideData['wait_fee_started_at'] = arrivedAtMs;
    nextRideData['wait_fee_grace_until'] = graceUntilMs;

    if (mounted) {
      setState(() {
        _rideStatus = 'arrived';
        _tripStarted = false;
        _arrivedEnabled = false;
        _showArrivedButton = false;
        _currentRideData = nextRideData;
      });
    } else {
      _rideStatus = 'arrived';
      _tripStarted = false;
      _arrivedEnabled = false;
      _showArrivedButton = false;
      _currentRideData = nextRideData;
    }
    _log('DRIVER_ARRIVED_APPLIED rideId=$rideId');
    _scheduleWaitFeeGraceTimer(rideId);
    _hasLoggedArrivedEnabled = false;
  }

  void markArrived() {
    final currentRideId = _activeDriverRideContextId?.trim();
    if (currentRideId == null || currentRideId.isEmpty) {
      _log('arrived blocked reason=missing_ride_id');
      return;
    }
    _log('DRIVER_ARRIVED_TAP rideId=$currentRideId');

    if (!_arrivedEnabled) {
      _log('arrived blocked rideId=$currentRideId reason=arrived_disabled');
      return;
    }

    if (!_tripStateIsAssigned(_currentRideData)) {
      _log(
        'arrived blocked rideId=$currentRideId reason=invalid_trip_state '
        'trip_state=${_valueAsText(_currentRideData?['trip_state'])} '
        'ui_status=$_rideStatus',
      );
      return;
    }

    final existing = _arrivedInFlightByRideId[currentRideId];
    if (existing != null) {
      unawaited(existing);
      return;
    }

    final arrivedFuture = _markArrivedOnce(currentRideId);
    _arrivedInFlightByRideId[currentRideId] = arrivedFuture;
    unawaited(
      arrivedFuture.whenComplete(() {
        _arrivedInFlightByRideId.remove(currentRideId);
      }),
    );
  }

  Future<void> _markArrivedOnce(String currentRideId) async {
    _log('ARRIVED_CALL_START rideId=$currentRideId driverId=$_effectiveDriverId');
    _log(
      'DRIVER_ARRIVED_WRITE_START rideId=$currentRideId '
      'path=ride_requests/$currentRideId/trip_state payload=arrived',
    );
    try {
      final cloud = await _rideCloud.driverArrived(rideId: currentRideId);
      if (!rideCallableSucceeded(cloud)) {
        _log(
          'ARRIVED_CALL_FAIL rideId=$currentRideId '
          'reason=${rideCallableReason(cloud)}',
        );
        return;
      }
      _log(
        'DRIVER_ARRIVED_WRITE_OK path=ride_requests/$currentRideId/trip_state',
      );
      _log('ARRIVED_COMMIT_SUCCESS rideId=$currentRideId');
      _applyLocalDriverArrivedUi(currentRideId);
    } catch (error) {
      _log('ARRIVED_CALL_FAIL rideId=$currentRideId error=$error');
    }
  }

  void _scheduleWaitFeeGraceTimer(String rideId) {
    final normalizedRideId = rideId.trim();
    if (normalizedRideId.isEmpty) {
      return;
    }
    if (_waitFeeGraceRideId == normalizedRideId && _waitFeeGraceTimer != null) {
      return;
    }

    _cancelWaitFeeGraceTimer(reason: 'reschedule');
    _waitFeeGraceRideId = normalizedRideId;
    _startWaitTimerTicker(normalizedRideId);

    final graceUntilMs =
        _asInt(_currentRideData?['wait_fee_grace_until']) ?? 0;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final delayMs = graceUntilMs > nowMs
        ? graceUntilMs - nowMs
        : const Duration(minutes: 5).inMilliseconds;

    _waitFeeGraceTimer = Timer(Duration(milliseconds: delayMs), () {
      unawaited(_applyWaitFeeOnce(normalizedRideId));
    });
    _log(
      'wait fee grace timer started rideId=$normalizedRideId delayMs=$delayMs',
    );
  }

  Future<void> _applyWaitFeeOnce(String rideId) async {
    if (_waitFeeApplyInFlight || _isDisposing) {
      return;
    }
    if (_currentRideId != rideId) {
      return;
    }

    _waitFeeApplyInFlight = true;
    try {
      final cloud = await _rideCloud.applyRideWaitFeeInterval(rideId: rideId);
      if (!rideCallableSucceeded(cloud)) {
        _log(
          'WAIT_FEE_APPLY_FAIL rideId=$rideId reason=${rideCallableReason(cloud)}',
        );
        return;
      }
      final reason = rideCallableReason(cloud);
      _log('WAIT_FEE_APPLY_OK rideId=$rideId reason=$reason cloud=$cloud');
      if (reason == 'waiting_expired_cancelled' && mounted) {
        _showSnackBarSafely(
          const SnackBar(
            content: Text(
              'Waiting window expired. Trip was cancelled and waiting fee recorded.',
            ),
          ),
        );
      }
    } catch (error) {
      _log('wait fee apply failed rideId=$rideId error=$error');
    } finally {
      _waitFeeApplyInFlight = false;
      _cancelWaitFeeGraceTimer(reason: 'applied_or_failed');
    }
  }

  bool _isDriverBankTransferPaymentConfirmedOnRide(
    Map<String, dynamic>? rideData,
  ) {
    if (rideData == null) {
      return false;
    }
    if (rideData['payment_confirmed_by_driver'] == true ||
        rideData['driver_confirmed_rider_payment'] == true) {
      return true;
    }
    return _valueAsText(rideData['payment_status']).toLowerCase() ==
        'driver_confirmed';
  }

  bool _isBankTransferPaymentMethod(Map<String, dynamic>? rideData) {
    if (rideData == null) {
      return false;
    }
    final method = _paymentMethodFromRide(rideData).toLowerCase();
    if (method == 'bank_transfer' || method == 'flutterwave_va') {
      return true;
    }
    return rideData['bank_transfer_automated'] == true ||
        rideData['automated_va'] == true;
  }

  bool _isTripCompletedForPaymentUi(Map<String, dynamic>? rideData) {
    if (rideData == null) {
      return false;
    }
    final tripState = _valueAsText(rideData['trip_state']).toLowerCase();
    final status = _valueAsText(rideData['status']).toLowerCase();
    return tripState == TripLifecycleState.completed ||
        tripState == 'completed' ||
        status == 'completed';
  }

  bool _ridePaymentServerVerified(Map<String, dynamic>? rideData) {
    return RideDriverPaymentGate.ridePaymentServerVerified(rideData);
  }

  bool _ridePaymentConfirmedForUi(Map<String, dynamic>? rideData) {
    if (rideData == null || _isTripCompletedForPaymentUi(rideData)) {
      return false;
    }
    if (rideData['payment_verified'] == true) {
      return true;
    }
    final status = _valueAsText(rideData['payment_status']).toLowerCase();
    if (status == 'paid' || status == 'paid_verified' || status == 'verified') {
      return true;
    }
    final paidAt = rideData['paid_at'];
    if (paidAt is num && paidAt > 0) {
      return true;
    }
    if (_valueAsText(paidAt).isNotEmpty) {
      return true;
    }
    return RideDriverPaymentGate.ridePaymentAllowsStartTrip(rideData);
  }

  bool _ridePaymentConfirmed(Map<String, dynamic>? rideData) {
    if (rideData == null) {
      return false;
    }
    if (_isBankTransferPaymentMethod(rideData)) {
      return _ridePaymentServerVerified(rideData);
    }
    if (_isDriverBankTransferPaymentConfirmedOnRide(rideData)) {
      return false;
    }
    if (rideData['payment_verified'] == true) {
      return true;
    }
    if (rideData['payment_confirmed'] == true) {
      return true;
    }
    final status = _valueAsText(rideData['payment_status']).toLowerCase();
    const cardReady = <String>{
      'card_authorized',
      'preauthorized',
      'paid',
      'verified',
      'paid_verified',
      'card_captured',
      'prepaid',
    };
    if (cardReady.contains(status)) {
      final ptid = _valueAsText(rideData['payment_transaction_id']);
      return ptid.isNotEmpty || status == 'card_authorized' || status == 'preauthorized';
    }
    return status == 'confirmed' || status == 'verified' || status == 'paid';
  }

  bool _ridePaymentPendingForStartTrip(Map<String, dynamic>? rideData) {
    return RideDriverPaymentGate.ridePaymentPendingForStartTrip(rideData);
  }

  bool _shouldShowDriverPaymentConfirmation(Map<String, dynamic>? rideData) {
    if (rideData == null || _isTripCompletedForPaymentUi(rideData)) {
      return false;
    }
    if (_ridePaymentServerVerified(rideData)) {
      return false;
    }
    final paymentStatus = _valueAsText(rideData['payment_status']).toLowerCase();
    if (paymentStatus == 'verified' || paymentStatus == 'paid_verified') {
      return false;
    }
    if (!_isBankTransferPaymentMethod(rideData)) {
      return false;
    }
    return !_isDriverBankTransferPaymentConfirmedOnRide(rideData);
  }

  Future<void> _promptConfirmRiderBankTransferPayment() async {
    if (!mounted || _paymentConfirmInFlight) {
      return;
    }
    final rideId = _firstNonEmptyText(<dynamic>[
      _currentRideId,
      _activeDriverRideContextId,
      _currentRideData?['ride_id'],
      _currentRideData?['rideId'],
    ]);
    _log('PAYMENT_CONFIRM_DIALOG_SHOW rideId=$rideId');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Payment seen?'),
          content: const Text(
            'Use this only if the rider showed you a transfer receipt or claim. '
            'NexRide must verify the payment before your wallet is credited.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: Colors.black,
              ),
              child: const Text('Payment seen / report issue'),
            ),
          ],
        );
      },
    );
    if (confirmed == true) {
      await _confirmRiderBankTransferPayment();
    }
  }

  String _bankTransferReferenceFromRideData(Map<String, dynamic>? rideData) {
    if (rideData == null) {
      return '';
    }
    for (final key in const <String>[
      'payment_reference',
      'customer_transaction_reference',
      'tx_ref',
      'txRef',
    ]) {
      final value = _valueAsText(rideData[key]);
      if (value.isNotEmpty) {
        return value;
      }
    }
    return _valueAsText(rideData['ride_id']);
  }

  Future<void> _confirmRiderBankTransferPayment() async {
    final rideData = _currentRideData;
    final rideId = _firstNonEmptyText(<dynamic>[
      _currentRideId,
      _activeDriverRideContextId,
      rideData?['ride_id'],
      rideData?['rideId'],
    ]);
    if (rideId.isEmpty || rideData == null || _paymentConfirmInFlight) {
      return;
    }
    if (_ridePaymentConfirmed(rideData)) {
      return;
    }

    final reference = _bankTransferReferenceFromRideData(rideData);
    if (reference.isEmpty) {
      _showSnackBarSafely(
        const SnackBar(
          content: Text('Payment reference is not available for this trip.'),
        ),
      );
      return;
    }

    _paymentConfirmInFlight = true;
    _log('PAYMENT_CONFIRM_START rideId=$rideId reference=$reference');
    try {
      final nextRideData = Map<String, dynamic>.from(rideData)
        ..['driver_payment_claim_seen'] = true
        ..['driver_confirmed_rider_payment'] = true;
      _currentRideData = nextRideData;
      if (mounted) {
        _setStateSafely(() {});
      }
      _log('PAYMENT_CONFIRMED_DRIVER rideId=$rideId reference=$reference');
      final cloud = await _rideCloud.driverConfirmBankTransferPayment(
        rideId: rideId,
        reference: reference,
      );
      if (rideCallableSucceeded(cloud)) {
        _log('PAYMENT_CONFIRM_WRITE_OK rideId=$rideId reference=$reference');
        _log('PAYMENT_CONFIRMED_RIDER_NOTIFY rideId=$rideId reference=$reference');
        _showSnackBarSafely(
          const SnackBar(
            content: Text(
              'Payment claim noted. Waiting for NexRide verification.',
            ),
          ),
        );
      } else {
        _log(
          'PAYMENT_CONFIRM_BACKEND_DEFERRED rideId=$rideId '
          'reason=${rideCallableReason(cloud)}',
        );
        _showSnackBarSafely(
          const SnackBar(
            content: Text('Payment confirmation saved locally; syncing…'),
          ),
        );
      }
    } catch (error) {
      _log('PAYMENT_CONFIRM_BACKEND_ERROR rideId=$rideId error=$error');
      _showSnackBarSafely(
        const SnackBar(content: Text('Unable to confirm payment right now.')),
      );
    } finally {
      _paymentConfirmInFlight = false;
    }
  }

  Future<void> startTrip() async {
    String candidateRideId(Map<String, dynamic>? ride) {
      if (ride == null) return '';
      return _firstNonEmptyText(<dynamic>[
        ride['ride_id'],
        ride['rideId'],
        ride['id'],
      ]);
    }

    final currentRideId = _firstNonEmptyText(<dynamic>[
      _currentRideId,
      candidateRideId(_currentRideData),
      _driverActiveRideId,
    ]);
    _log('START_TRIP_TAP rideId=$currentRideId');
    final serviceType = _serviceTypeKey(_currentRideData?['service_type']);
    final invalidReason = currentRideId.isEmpty
        ? 'missing_ride_id'
        : _activeRideInvalidReason(
            _currentRideData,
            rideId: currentRideId,
            requireTrackedRide: true,
          );

    if (currentRideId.isEmpty) {
      _log('start trip blocked reason=missing_ride_id');
      return;
    }

    if (!_tripStateIsArrived(_currentRideData)) {
      _log(
        'start trip blocked rideId=$currentRideId reason=invalid_trip_state '
        'trip_state=${_valueAsText(_currentRideData?['trip_state'])} '
        'ui_status=$_rideStatus',
      );
      return;
    }

    if (invalidReason != null) {
      _log('start trip blocked rideId=$currentRideId reason=$invalidReason');
      return;
    }

    if (_ridePaymentPendingForStartTrip(_currentRideData)) {
      _offerDiscoveryLog(
        'START_TRIP_BLOCKED_PAYMENT_PENDING',
        rideId: currentRideId,
        detail: _valueAsText(_currentRideData?['payment_status']),
      );
      _log(
        'START_TRIP_BLOCKED_PAYMENT_PENDING rideId=$currentRideId '
        'payment_status=${_valueAsText(_currentRideData?['payment_status'])}',
      );
      _showSnackBarSafely(
        const SnackBar(
          content: Text(
            'Start trip is unavailable until payment is confirmed.',
          ),
        ),
      );
      return;
    }

    if (_startTripInFlight) {
      _log('start trip blocked reason=in_flight rideId=$currentRideId');
      return;
    }
    _startTripInFlight = true;

    try {
      _log(
        'START_TRIP_REQUEST rideId=$currentRideId '
        'path=ride_requests/$currentRideId '
        'trip_state=${_valueAsText(_currentRideData?['trip_state'])}',
      );
      try {
      var cloud = await _rideCloud.startTrip(rideId: currentRideId);
      if (rideCallableReason(cloud) == 'ride_missing') {
        final refreshSnap =
            await runRtdbQueryGet(
              query: _rideRequestsRef.child(currentRideId),
              path: 'ride_requests/$currentRideId',
              source: 'driver_map.start_trip_refresh',
            );
        if (refreshSnap.exists) {
          final refreshed = _asStringDynamicMap(refreshSnap.value);
          if (refreshed != null) {
            _currentRideData = refreshed;
            _currentRideId = currentRideId;
            _driverActiveRideId = currentRideId;
          }
          _log('START_TRIP_RETRY_AFTER_REFRESH rideId=$currentRideId');
          cloud = await _rideCloud.startTrip(rideId: currentRideId);
        }
      }
      if (!rideCallableSucceeded(cloud)) {
        final startReason = rideCallableReason(cloud);
        if (startReason == 'bank_transfer_pending_confirmation' ||
            startReason == 'payment_not_verified') {
          _offerDiscoveryLog(
            'START_TRIP_BLOCKED_PAYMENT_PENDING',
            rideId: currentRideId,
            detail: startReason,
          );
        }
        _showSnackBarSafely(
          SnackBar(
            content: Text(
              startReason == 'bank_transfer_pending_confirmation' ||
                      startReason == 'payment_not_verified'
                  ? 'Payment not verified yet — do not start trip. NexRide must confirm payment first.'
                  : 'Unable to start trip ($startReason).',
            ),
          ),
        );
        return;
      }
      _log('START_TRIP_OK rideId=$currentRideId');
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
    // trip_state owned by Cloud Functions — local cache only for timestamps/UI.
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

    _logRideStateChangeOnce(
      rideId: currentRideId,
      riderId: _currentRiderIdForRide,
      driverId: _effectiveDriverId,
      serviceType: _serviceTypeKey(_currentRideData?['service_type']),
      status: 'on_trip',
      source: 'driver_start_trip',
      rideData: _currentRideData,
    );

    _log('trip started rideId=$currentRideId');

    _hasLoggedArrivedEnabled = false;
    } finally {
      _startTripInFlight = false;
    }
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

  List<String> _cancelRideIdCandidates() {
    final seen = <String>{};
    final ordered = <String>[];
    void addCandidate(dynamic value) {
      final rideId = _valueAsText(value).trim();
      if (rideId.isEmpty || !_isValidRideId(rideId) || seen.contains(rideId)) {
        return;
      }
      seen.add(rideId);
      ordered.add(rideId);
    }

    addCandidate(_currentRideId);
    addCandidate(_currentRideData?['ride_id']);
    addCandidate(_currentRideData?['rideId']);
    addCandidate(_currentRideData?['id']);
    addCandidate(_driverActiveRideId);
    addCandidate(_sessionTrackedRideId);
    addCandidate(_activeRideListenerRideId);
    addCandidate(_callListenerRideId);
    return ordered;
  }

  Future<String?> _resolveCancelRideIdForDriver() async {
    for (final rideId in _cancelRideIdCandidates()) {
      final remote = await _fetchRideRequestForCancel(rideId);
      if (_rideDataIsNonTerminalForCancel(remote)) {
        _currentRideData = remote;
        return rideId;
      }
    }

    final driverId = _effectiveDriverId.trim();
    if (driverId.isEmpty) {
      return null;
    }
    try {
      final snapshot =
          await runRtdbQueryGet(
            query: _driversRef.root.child('driver_active_ride/$driverId'),
            path: 'driver_active_ride/$driverId',
            source: 'driver_map.active_ride_pointer_read',
          );
      final marker = _asStringDynamicMap(snapshot.value);
      final pointerRideId = _valueAsText(
        marker?['ride_id'] ?? marker?['rideId'],
      );
      if (pointerRideId.isNotEmpty && _isValidRideId(pointerRideId)) {
        final remote = await _fetchRideRequestForCancel(pointerRideId);
        if (_rideDataIsNonTerminalForCancel(remote)) {
          _currentRideData = remote;
          return pointerRideId;
        }
      }
    } catch (error) {
      _log('driver cancel rideId resolve pointer failed error=$error');
    }
    return null;
  }

  Future<Map<String, dynamic>?> _fetchRideRequestForCancel(String rideId) async {
    try {
      final snapshot = await runRtdbQueryGet(
        query: _rideRequestsRef.child(rideId),
        path: 'ride_requests/$rideId',
        source: 'driver_map.fetch_ride_for_cancel',
      );
      return _asStringDynamicMap(snapshot.value);
    } catch (error) {
      _log('driver cancel ride fetch failed rideId=$rideId error=$error');
      return null;
    }
  }

  bool _rideDataIsNonTerminalForCancel(Map<String, dynamic>? rideData) {
    if (rideData == null || rideData.isEmpty) {
      return false;
    }
    final canonical = TripStateMachine.canonicalStateFromSnapshot(rideData);
    return !TripStateMachine.isTerminal(canonical);
  }

  Future<void> cancelActiveRide() async {
    final currentRideId = await _resolveCancelRideIdForDriver();
    if (currentRideId == null || currentRideId.isEmpty) {
      _log('driver cancel blocked reason=missing_ride_id');
      return;
    }
    if (_currentRideId != currentRideId) {
      _currentRideId = currentRideId;
      if (mounted) {
        _setStateSafely(() {});
      }
    }
    callTraceLog('CANCEL_REQUEST_TAP', rideId: currentRideId, role: 'driver');
    final serviceType = _serviceTypeKey(_currentRideData?['service_type']);
    final invalidReason = currentRideId == null
        ? 'missing_ride_id'
        : _activeRideInvalidReason(
            _currentRideData,
            rideId: currentRideId,
            requireTrackedRide: true,
          );

    if (_ridePaymentBlocksDriverCancel(_currentRideData)) {
      _log(
        'DRIVER_CANCEL_BLOCKED_PAYMENT_VERIFIED rideId=$currentRideId '
        'driverId=$_effectiveDriverId '
        'payment_status=${_valueAsText(_currentRideData?['payment_status'])} '
        'total_ngn=${_asDouble(_currentRideData?['total_ngn']) ?? _asDouble(_currentRideData?['fare']) ?? 0}',
      );
      _showSnackBarSafely(
        const SnackBar(
          content: Text(
            'Paid trips cannot be cancelled by the driver. Contact support.',
          ),
        ),
      );
      return;
    }

    if (!_canDriverCancelActiveRide(_rideStatus, rideData: _currentRideData)) {
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

    if (_isDriverCancellingRide) {
      _log('driver cancel blocked reason=in_flight rideId=$currentRideId');
      return;
    }

    if (_lastCallCleanupAt != null) {
      final sinceCleanupMs =
          DateTime.now().difference(_lastCallCleanupAt!).inMilliseconds;
      _log(
        'CANCEL_REQUEST_AFTER_CALL_CLEANUP rideId=$currentRideId '
        'deltaMs=$sinceCleanupMs',
      );
      if (sinceCleanupMs <= 8000 && mounted) {
        final proceed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            return AlertDialog(
              title: const Text('Cancel trip?'),
              content: const Text(
                'Ending a voice call does not cancel the trip. '
                'Do you want to cancel this trip for the rider?',
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('KEEP TRIP'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('CANCEL TRIP'),
                ),
              ],
            );
          },
        );
        if (proceed != true) {
          _log(
            '[CANCEL] actor=driver rideId=$currentRideId '
            'dismissed_after_call_cleanup deltaMs=$sinceCleanupMs',
          );
          return;
        }
      }
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
    callTraceLog(
      'CANCEL_REQUEST_START',
      rideId: currentRideId,
      role: 'driver',
    );
    _log(
      '[CANCEL] actor=driver rideId=$currentRideId reason=$cancelReason start',
    );

    try {
      var cloud = await _rideCloud.cancelRideRequest(
        rideId: currentRideId,
        cancelReason: cancelReason.trim(),
      );
      if (!rideCallableSucceeded(cloud)) {
        final failReason = rideCallableReason(cloud).trim().toLowerCase();
        if (failReason == 'ride_missing') {
          final refreshSnap = await runRtdbQueryGet(
            query: _rideRequestsRef.child(currentRideId),
            path: 'ride_requests/$currentRideId',
            source: 'driver_map.cancel_ride_refresh',
          );
          if (refreshSnap.exists) {
            final refreshedRide = _asStringDynamicMap(refreshSnap.value);
            if (refreshedRide != null) {
              _currentRideData = refreshedRide;
              if (mounted) {
                _setStateSafely(() {
                  _currentRideId = currentRideId;
                });
              } else {
                _currentRideId = currentRideId;
              }
            }
          }
          final refreshedRide = await _fetchRideRequestForCancel(currentRideId);
          if (_rideDataIsNonTerminalForCancel(refreshedRide)) {
            _log('CANCEL_REQUEST_RETRY_AFTER_REFRESH rideId=$currentRideId');
            cloud = await _rideCloud.cancelRideRequest(
              rideId: currentRideId,
              cancelReason: cancelReason.trim(),
            );
          } else {
            await _commitRideAndDriverState(
              rideId: currentRideId,
              rideUpdates: const <String, dynamic>{},
              driverUpdates: _buildDriverPresenceUpdate(
                status: 'online_available',
                isAvailable: true,
              ),
              clearActiveRide: true,
            );
            await _clearActiveRideState(
              reason: 'cancel_ride_missing',
              resetTripState: true,
            );
            _showSnackBarSafely(
              const SnackBar(
                content: Text(
                  'Trip is no longer active. You are back online.',
                ),
              ),
            );
            return;
          }
        }
      }
      if (!rideCallableSucceeded(cloud)) {
        callTraceLog(
          'CANCEL_REQUEST_FAIL',
          rideId: currentRideId,
          role: 'driver',
          error: rideCallableReason(cloud),
        );
        final failReason = rideCallableReason(cloud).trim().toLowerCase();
        final failMessage = _valueAsText(cloud['message']);
        if (failReason == 'paid_trip_driver_cancel_blocked') {
          _log(
            'DRIVER_CANCEL_BLOCKED_PAYMENT_VERIFIED rideId=$currentRideId '
            'driverId=$_effectiveDriverId reason=$failReason',
          );
        }
        _showSnackBarSafely(
          SnackBar(
            content: Text(
              failMessage.isNotEmpty
                  ? failMessage
                  : 'Unable to cancel (${rideCallableReason(cloud)}).',
            ),
          ),
        );
        return;
      }
      callTraceLog('CANCEL_REQUEST_OK', rideId: currentRideId, role: 'driver');
      await _commitRideAndDriverState(
        rideId: currentRideId,
        rideUpdates: const <String, dynamic>{},
        // Keep the driver dispatch-eligible after cancelling. `idle` is NOT in
        // the offer-eligible status set, so writing it here would block new
        // ride requests until a later availability refresh. `online_available`
        // matches the server-side release in releaseDriverForRematchAfterCancel.
        driverUpdates: _buildDriverPresenceUpdate(
          status: 'online_available',
          isAvailable: true,
        ),
        clearActiveRide: true,
      );
      _log('[LAST_ACTIVE] updated source=driver_cancel rideId=$currentRideId');
      _log('DRIVER_READY_FOR_NEW_REQUEST rideId=$currentRideId driverId=$_effectiveDriverId source=driver_cancel');
      _log(
        '[CANCEL] actor=driver rideId=$currentRideId reason=$cancelReason success',
      );
    } catch (error) {
      callTraceLog(
        'CANCEL_REQUEST_FAIL',
        rideId: currentRideId,
        role: 'driver',
        error: error.toString(),
      );
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

    _logRideStateChangeOnce(
      rideId: currentRideId,
      riderId: riderId,
      driverId: _effectiveDriverId,
      serviceType: serviceType,
      status: 'cancelled',
      source: 'driver_cancel',
      rideData: cancelledRideData,
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

  bool _isTerminalTripEligibilityRefreshReason(String reason) {
    final normalized = reason.trim().toLowerCase();
    if (normalized.contains('ride_missing')) {
      return false;
    }
    if (normalized.contains('no_valid')) {
      return false;
    }
    if (normalized.contains('hard_reset')) {
      return false;
    }
    return normalized.contains('cancel') ||
        normalized.contains('complete') ||
        normalized.contains('completed') ||
        normalized.contains('expired') ||
        normalized.contains('status_cancelled') ||
        normalized.contains('terminal') ||
        normalized.contains('system_cancel');
  }

  Future<void> _restoreDriverMatchingEligibilityAfterTerminalTrip({
    required String source,
    String? rideId,
  }) async {
    if (!_isOnline || _effectiveDriverId.isEmpty) {
      return;
    }
    final rid = rideId?.trim() ?? _currentRideId?.trim() ?? '';
    debugPrint(
      'ACTIVE_POINTERS_CLEARED rideId=$rid driverId=${_effectiveDriverId} '
      'source=client_$source',
    );
    await _repairDispatchBlockersAndRearmDiscovery(
      reason: source,
      releasedRideId: rid,
    );
    debugPrint(
      'DRIVER_READY_FOR_NEXT_OFFER driverId=${_effectiveDriverId} '
      'rideId=${rid.isEmpty ? "none" : rid} source=$source',
    );
  }

  Future<void> _resumeDriverOfferListenersAfterTerminal({
    required String source,
    String? rideId,
  }) async {
    if (!_isOnline || _isDisposing || _effectiveDriverId.isEmpty) {
      return;
    }
    final resumeSource = source.contains('driver_cancel')
        ? 'driver_cancel'
        : 'terminal_cancel:$source';
    final terminalRideId = _firstNonEmptyText(<dynamic>[
      rideId,
      _driverActiveRideId,
      _currentRideId,
      _activePopupRideId,
    ]).trim();
    debugPrint(
      'DRIVER_TERMINAL_REBIND driverId=${_effectiveDriverId} '
      'rideId=${terminalRideId.isEmpty ? "none" : terminalRideId} source=$resumeSource',
    );
    _stopActiveRideListener();
    if (_popupLifecycleState != _DriverPopupLifecycleState.idle) {
      _setPopupLifecycleState(
        _DriverPopupLifecycleState.idle,
        rideId: terminalRideId.isEmpty ? null : terminalRideId,
        reason: 'terminal_rebind:$resumeSource',
      );
    }
    _clearOfferPopupState(
      reason: 'resume_after_terminal:$resumeSource',
      rideId: terminalRideId.isEmpty ? null : terminalRideId,
      clearQueue: true,
      clearEntireCache: false,
      dismissVisibleDialog: true,
      clearCurrentRidePointer: true,
    );
    _driverOfferQueueReplica.clear();
    _logRideReq('DRIVER_RESUME_LISTENERS source=$resumeSource');
    await _cancelRideRequestListener(reason: 'resume_after_terminal:$resumeSource');
    _logRideReq(
      '[MATCH_DEBUG][DRIVER_ATTACH] driverId=$_effectiveDriverId '
      'source=$resumeSource path=driver_offer_queue/$_effectiveDriverId',
    );
    _logRideReq(
      'DRIVER_OFFER_LISTENER_ATTACH driverId=$_effectiveDriverId source=$resumeSource',
    );
    _logRideReq(
      'DELIVERY_OFFER_LISTENER_ATTACH driverId=$_effectiveDriverId source=$resumeSource',
    );
    _ensureRideDiscoverySubscriptionIfOnline(reason: resumeSource);
    await _listenForRideRequests(reason: resumeSource);
    debugPrint(
      'DRIVER_OFFER_QUEUE_RESUBSCRIBED driverId=$_effectiveDriverId '
      'source=$resumeSource rideId=${terminalRideId.isEmpty ? "none" : terminalRideId}',
    );
    debugPrint(
      'DRIVER_READY_FOR_NEXT_OFFER driverId=$_effectiveDriverId '
      'rideId=${terminalRideId.isEmpty ? "none" : terminalRideId} source=$resumeSource',
    );
    await _primeOfferQueuesFromRtdb(source: resumeSource);
    _startOfferListenerWatchdog();
    _logRideReq('DRIVER_ELIGIBLE_AFTER_CANCEL source=$resumeSource');
  }

  Future<String?> _readPromotedActiveRideIdAfterTerminal({
    required String completedRideId,
  }) async {
    final driverId = _effectiveDriverId.trim();
    if (driverId.isEmpty) {
      return null;
    }
    final snap = await runRtdbQueryGet(
      query: _driversRef.child(driverId),
      path: 'drivers/$driverId',
      source: 'driver_map.post_terminal_promotion_check',
    );
    final profile = _asStringDynamicMap(snap.value);
    if (profile != null) {
      _ingestQueuePointersFromProfile(profile);
    }
    final activeRideId = _firstNonEmptyText(<dynamic>[
      profile?['active_ride_id'],
      profile?['activeRideId'],
      profile?['currentRideId'],
    ]).trim();
    final completedKey = completedRideId.trim();
    if (activeRideId.isNotEmpty && activeRideId != completedKey) {
      return activeRideId;
    }
    final queuedRideId = _queuedNextRideIdFromProfile?.trim() ?? '';
    if (queuedRideId.isNotEmpty && queuedRideId != completedKey) {
      final rideSnap = await runRtdbQueryGet(
        query: _rideRequestsRef.child(queuedRideId),
        path: 'ride_requests/$queuedRideId',
        source: 'driver_map.post_terminal_queued_ride_check',
      );
      final rideData = _asStringDynamicMap(rideSnap.value);
      if (rideData != null && rideData['queued_driver_trip'] != true) {
        return queuedRideId;
      }
    }
    return null;
  }

  Future<void> _attachDriverToPromotedQueuedRide({
    required String promotedRideId,
    required String completedRideId,
    Map<String, dynamic>? completedRideData,
  }) async {
    final promotedKey = promotedRideId.trim();
    final completedKey = completedRideId.trim();
    if (promotedKey.isEmpty || promotedKey == completedKey) {
      return;
    }
    _log(
      'DRIVER_NEXT_RIDE_PROMOTED_LOCAL promotedRideId=$promotedKey completedRideId=$completedKey',
    );
    debugPrint(
      'DRIVER_HEADING_TO_QUEUED_PICKUP rideId=$promotedKey completedRideId=$completedKey',
    );
    _queuedNextRideIdFromProfile = null;
    _releaseRidePopupSessionBlocks(
      completedKey,
      includeForever: true,
      includeTerminalSelfAccepted: true,
    );
    final rideSnap = await runRtdbQueryGet(
      query: _rideRequestsRef.child(promotedKey),
      path: 'ride_requests/$promotedKey',
      source: 'driver_map.promoted_ride_load',
    );
    final promotedRideData = _asStringDynamicMap(rideSnap.value);
    if (promotedRideData == null) {
      await _resetTripState();
      return;
    }
    final promotedStatus =
        TripStateMachine.uiStatusFromSnapshot(promotedRideData);
    if (mounted) {
      setState(() {
        _driverActiveRideId = promotedKey;
        _currentRideId = promotedKey;
        _currentRideData = Map<String, dynamic>.from(promotedRideData);
        _rideStatus = promotedStatus;
        _tripStarted = promotedStatus == 'on_trip';
      });
    } else {
      _driverActiveRideId = promotedKey;
      _currentRideId = promotedKey;
      _currentRideData = Map<String, dynamic>.from(promotedRideData);
      _rideStatus = promotedStatus;
      _tripStarted = promotedStatus == 'on_trip';
    }
    unawaited(_suspendOfferDiscoveryForActiveTrip('queued_ride_promoted'));
    _ensureActiveTripNavigation(
      rideId: promotedKey,
      rideData: promotedRideData,
    );
    _applyRideLocationsFromData(promotedRideData);
    _evaluateArrivedAvailability();
    _loggedDriverChatMessageIds.clear();
    _ensureDriverChatUnreadListener(promotedKey);
    _syncRiderDisplayFromRideSnapshot(
      rideId: promotedKey,
      rideData: promotedRideData,
    );
    await _listenToActiveRide(promotedKey);
    _scheduleActiveRouteRefresh(
      force: true,
      reason: 'queued_ride_promoted',
      debounce: Duration.zero,
    );
    try {
      _moveCameraToActiveTrip();
    } catch (_) {}
    _refreshIosDriverMapIfNeeded(reason: 'queued_ride_promoted');
    if (mounted) {
      _showSnackBarSafely(
        const SnackBar(
          content: Text('Heading to your next pickup.'),
        ),
      );
    }
    _setApiStatus('success');
    if (completedRideData != null && mounted) {
      Future<void>.microtask(() {
        if (!mounted) {
          return;
        }
        unawaited(
          _showPostTripReviewSheet(
            rideId: completedKey,
            rideData: completedRideData,
          ),
        );
      });
    }
  }

  Future<void> completeTrip() async {
    final currentRideId = _currentRideId;
    if (currentRideId == null) {
      return;
    }
    if (_completeTripInFlight) {
      _log('complete trip blocked reason=in_flight rideId=$currentRideId');
      return;
    }
    _completeTripInFlight = true;
    try {
    final completedRideData = _currentRideData == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(_currentRideData!);
    final riderId = _currentRiderIdForRide;
    final serviceType = _serviceTypeKey(completedRideData['service_type']);
    final isDispatchDelivery = _isDispatchDeliveryService(serviceType);
    final deliveryProofUrl = _dispatchDeliveryProofPhotoUrl(completedRideData);
    _setApiStatus('loading');

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

    if (_hasPendingTripStopsBeforeFinal) {
      _showSnackBarSafely(
        const SnackBar(
          content: Text(
            'Visit all stops before completing this trip.',
          ),
        ),
      );
      return;
    }

    final paymentReference = _valueAsText(
      completedRideData['customer_transaction_reference'],
    ).isNotEmpty
        ? _valueAsText(completedRideData['customer_transaction_reference'])
        : _valueAsText(completedRideData['payment_reference']);
    _log(
      'COMPLETE_TRIP_PAYMENT_CHECK rideId=$currentRideId '
      'payment_status=${_valueAsText(completedRideData['payment_status'])} '
      'payment_verified=${completedRideData['payment_verified'] == true} '
      'payment_confirmed_by_driver=${completedRideData['payment_confirmed_by_driver'] == true} '
      'driver_confirmed=${completedRideData['driver_confirmed_rider_payment'] == true}',
    );
    if (!_ridePaymentConfirmed(completedRideData)) {
      final verifyResult = await _backendSimulation.verifyPayment(
        BackendVerifyPaymentRequest(
          rideId: currentRideId,
          reference: paymentReference.isEmpty
              ? 'local_$currentRideId'
              : paymentReference,
          amount: _asDouble(completedRideData['fare']) ?? 0,
        ),
      );
      if (!verifyResult.ok) {
        _setApiStatus('failed', errorMessage: verifyResult.message);
        _showSnackBarSafely(SnackBar(content: Text(verifyResult.message)));
        return;
      }
    }

    _log('COMPLETE_TRIP_START rideId=$currentRideId');
    final hasStartedCheckpointLogs = await _rideHasStartedCheckpointLogs(
      currentRideId,
      rideData: completedRideData,
    );
    if (!hasStartedCheckpointLogs) {
      _log(
        'COMPLETE_TRIP_NO_ROUTE_LOGS_CONTINUE rideId=$currentRideId',
      );
    }

    _log('COMPLETE_TRIP_CALLABLE_START rideId=$currentRideId');
    final cloudComplete = await _rideCloud.completeTrip(rideId: currentRideId);
    final completeReason = rideCallableReason(cloudComplete);
    if (rideCallableSucceeded(cloudComplete)) {
      _log('COMPLETE_TRIP_CALLABLE_OK rideId=$currentRideId reason=$completeReason');
      _log('COMPLETE_TRIP_SUCCESS rideId=$currentRideId');
      _log('COMPLETE_TRIP_STATUS_RECEIVED rideId=$currentRideId');
    }
    if (!rideCallableSucceeded(cloudComplete)) {
      _log(
        'COMPLETE_TRIP_CALLABLE_FAIL rideId=$currentRideId '
        'code=$completeReason message=${cloudComplete?['message'] ?? ''} '
        'details=${cloudComplete?['details'] ?? ''}',
      );
      _setApiStatus('failed', errorMessage: completeReason);
      final userMessage = completeReason == 'payment_not_verified'
          ? 'Waiting for NexRide payment verification before this trip can pay out.'
          : 'Unable to complete trip ($completeReason).';
      _showSnackBarSafely(SnackBar(content: Text(userMessage)));
      return;
    }

    final promotedRideId = await _readPromotedActiveRideIdAfterTerminal(
      completedRideId: currentRideId,
    );
    if (promotedRideId != null && promotedRideId.trim().isNotEmpty) {
      final refreshedSnap = await runRtdbQueryGet(
        query: _rideRequestsRef.child(currentRideId),
        path: 'ride_requests/$currentRideId',
        source: 'driver_map.complete_trip_refresh_promoted',
      );
      final settledRideData =
          _asStringDynamicMap(refreshedSnap.value) ?? completedRideData;
      await _prepareUiCleanupBeforeTripReset(currentRideId);
      if (!mounted) {
        return;
      }
      await _endCallForRideLifecycle(
        rideId: currentRideId,
        lifecycleReason: 'trip_completed',
      );
      await _clearDriverActiveRideNode(
        rideId: currentRideId,
        reason: 'completed',
      );
      await _restoreDriverMatchingEligibilityAfterTerminalTrip(
        source: 'trip_completed',
        rideId: currentRideId,
      );
      await _attachDriverToPromotedQueuedRide(
        promotedRideId: promotedRideId,
        completedRideId: currentRideId,
        completedRideData: settledRideData,
      );
      return;
    }

    _currentRideData = Map<String, dynamic>.from(completedRideData)
      ..['status'] = 'completed'
      ..['trip_state'] = TripLifecycleState.completed
      ..['trip_completed'] = true;

    if (isDispatchDelivery) {
      await _rideCloud.patchRideRequestMetadata(
        rideId: currentRideId,
        patch: <String, dynamic>{
          'deliveredAt': DateTime.now().millisecondsSinceEpoch,
          'deliveryProofStatus': 'submitted',
          'dispatch_details/deliveredAt': DateTime.now().millisecondsSinceEpoch,
          'dispatch_details/deliveryProofStatus': 'submitted',
        },
      );
    }

    final refreshedSnap = await runRtdbQueryGet(
      query: _rideRequestsRef.child(currentRideId),
      path: 'ride_requests/$currentRideId',
      source: 'driver_map.complete_trip_refresh',
    );
    final settledRideData =
        _asStringDynamicMap(refreshedSnap.value) ?? completedRideData;
    _log(
      'COMPLETE_TRIP_VERIFY_STATE rideId=$currentRideId '
      'status=${_valueAsText(settledRideData['status'])} '
      'trip_state=${_valueAsText(settledRideData['trip_state'])}',
    );
    final completedDriverPresence = _buildDriverPresenceUpdate(
      status: 'online_available',
      isAvailable: true,
    );
    completedDriverPresence['latest_trip_ride_id'] = currentRideId;
    completedDriverPresence['latest_trip_status'] = 'completed';
    completedDriverPresence['latest_trip_trip_state'] =
        TripLifecycleState.completed;
    completedDriverPresence['latest_trip_at'] = rtdb.ServerValue.timestamp;

    await _prepareUiCleanupBeforeTripReset(currentRideId);
    if (!mounted) {
      return;
    }

    await _commitRideAndDriverState(
      rideId: currentRideId,
      rideUpdates: const <String, dynamic>{},
      driverUpdates: completedDriverPresence,
      clearActiveRide: true,
    );
    await _endCallForRideLifecycle(
      rideId: currentRideId,
      lifecycleReason: 'trip_completed',
    );

    await _clearDriverActiveRideNode(
      rideId: currentRideId,
      reason: 'completed',
    );
    debugPrint(
      'TRIP_COMPLETE rideId=$currentRideId driverId=${_effectiveDriverId}',
    );
    await _restoreDriverMatchingEligibilityAfterTerminalTrip(
      source: 'trip_completed',
      rideId: currentRideId,
    );
    _logRideStateChangeOnce(
      rideId: currentRideId,
      riderId: riderId,
      driverId: _effectiveDriverId,
      serviceType: serviceType,
      status: 'completed',
      source: 'driver_complete_trip',
      rideData: settledRideData,
    );
    if (isDispatchDelivery &&
        !_localWalletCreditedRideIds.contains(currentRideId)) {
      try {
        final distanceKm = _asDouble(completedRideData['distance_km']) ??
            _asDouble(completedRideData['distanceKm']) ??
            1.0;
        final baseFare = _asDouble(completedRideData['base_fare']) ??
            _asDouble(
                _dispatchDetailsFromRide(completedRideData)['base_fare']) ??
            0.0;
        final pricePerKm = _asDouble(completedRideData['price_per_km']) ??
            _asDouble(
                _dispatchDetailsFromRide(completedRideData)['price_per_km']) ??
            0.0;
        final breakdown = buildDispatchPaymentBreakdown(
          baseFare: baseFare,
          distanceKm: distanceKm,
          pricePerKm: pricePerKm,
        );
        final creditResult = await _backendSimulation.creditWallet(
          BackendCreditWalletRequest(
            rideId: currentRideId,
            walletId: _effectiveDriverId,
            amount: breakdown.riderEarning,
            transactionType: 'dispatch_earning',
          ),
        );
        if (creditResult.ok) {
          _localWalletCreditedRideIds.add(currentRideId);
          _logRideReq(
            '[WALLET_CREDITED] rideId=$currentRideId amount=${breakdown.riderEarning}',
          );
        } else {
          _logRideReq(
            '[WALLET_CREDIT_FAILED] rideId=$currentRideId reason=${creditResult.errorCode}',
          );
        }
      } catch (error) {
        _logRideReq(
            '[WALLET_CREDIT_FAILED] rideId=$currentRideId error=$error');
      }
    }

    _log('trip completed rideId=$currentRideId');
    _logRtdb('active ride cleared reason=completed');
    _logTripPanelHidden('completed');
    await _resetTripState();
    if (!mounted) {
      return;
    }
    _setApiStatus('success');
    if (mounted && riderId.isNotEmpty) {
      _log('DRIVER_RATE_RIDER_PROMPT rideId=$currentRideId riderId=$riderId');
      Future<void>.microtask(() {
        if (!mounted) {
          return;
        }
        unawaited(
          _showPostTripReviewSheet(
            rideId: currentRideId,
            rideData: settledRideData,
          ),
        );
      });
    }
    } finally {
      _completeTripInFlight = false;
    }
  }

  Future<void> _resetTripState() async {
    final previousRideId = _currentRideId;
    final driverId = _effectiveDriverId;
    if (previousRideId != null && previousRideId.trim().isNotEmpty) {
      _log('COMPLETE_TRIP_UI_RESET_SAFE rideId=${previousRideId.trim()}');
    }
    if (previousRideId != null && previousRideId.isNotEmpty) {
      final p = previousRideId.trim();
      if (p.isNotEmpty) {
        _releaseRidePopupSessionBlocks(
          p,
          includeForever: true,
          includeTerminalSelfAccepted: true,
        );
      }
      await _performLocalCallCleanup(
        rideId: previousRideId,
        cleanupSource: 'reset_trip_state_presence',
        endReason: 'trip_state_reset',
        logCleanup: false,
      );
    }

    if (driverId.isNotEmpty && _isOnline) {
      await runInstrumentedRtdbUpdate(
        path: 'drivers/$driverId',
        source: 'reset_trip_state_presence',
        role: 'driver',
        updates: _buildDriverPresenceUpdate(
          status: 'online_available',
          isAvailable: true,
        ),
        action: (sanitized) => _driversRef.child(driverId).update(sanitized),
      );
    }

    _resetAllRideState();
    _discoverySuspendedForRideId = null;

    _log('trip state reset status=$_rideStatus');

    if (_isOnline) {
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
    _activeRouteRideId = null;
    _lastBuiltRouteStatus = null;
    _lastAppliedRouteTargetKey = null;
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

    if (_routeRefreshInFlight) {
      return <LatLng>[];
    }

    if (_isRouteRequestStale(
      requestGeneration: requestGeneration,
      kind: routeKind,
      expectedRideId: expectedRideId,
    )) {
      return <LatLng>[];
    }

    _routeRefreshInFlight = true;
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
          if (route.isEmpty) {
            _log(
              'route fetch result segment=${i + 1} points=${segment.length} '
              'origin=${origin.latitude},${origin.longitude} '
              'destination=${destination.latitude},${destination.longitude} '
              'hasRoute=${result.hasRoute} error=${result.errorMessage}',
            );
          }

          if (!result.hasRoute || segment.length < 2) {
            _routeOverlayError = result.errorMessage ??
                'Using straight-line route preview while road routing reconnects.';
            if (route.isEmpty) {
              route.add(origin);
            }
            route.add(destination);
            continue;
          }

          if (route.isEmpty) {
            route.addAll(segment);
          } else {
            route.addAll(segment.skip(1));
          }
        } catch (error) {
          _log('route segment error index=$i error=$error');
          _routeOverlayError =
              'Using straight-line route preview while road routing reconnects.';
          if (route.isEmpty) {
            route.add(origin);
          }
          route.add(destination);
        }
      }
    } catch (error) {
      _log('route compose error=$error');
      _routeOverlayError =
          'Route preview is reconnecting. Retry to refresh the live road path.';
      return <LatLng>[];
    } finally {
      _routeRefreshInFlight = false;
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
        (!_isDriverChatOpen &&
            (now.difference(_lastRouteBuiltAt!) >= _kRouteRefreshInterval ||
                originDelta >= _kRouteRefreshDistanceMeters));

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
        _activeRouteRideId = rideId;
        _lastBuiltRouteStatus = _rideStatus;
        _lastAppliedRouteTargetKey = routeBuildKey;
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
      _activeRouteRideId = rideId;
      _lastBuiltRouteStatus = _rideStatus;
      _lastAppliedRouteTargetKey = routeBuildKey;
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

  void _logArrivedButtonState({
    required String rideId,
    required bool visible,
    required bool enabled,
    required String reason,
    required int distanceMeters,
  }) {
    final tripState = _valueAsText(_currentRideData?['trip_state']);
    final line =
        'ARRIVED_BUTTON_STATE rideId=$rideId visible=$visible enabled=$enabled '
        'reason=$reason status=$_rideStatus trip_state=$tripState '
        'distanceMeters=$distanceMeters locationMode=$_activeOnlineAvailabilityMode';
    if (_lastArrivedButtonStateLog == line) {
      return;
    }
    _lastArrivedButtonStateLog = line;
    _log(line);
  }

  void _evaluateArrivedAvailability() {
    final rideId = _currentRideId?.trim() ?? '';
    final pickup = _pickupLocation;
    final committed = _isCommittedActiveRideForDriver(
      _currentRideData,
      rideId: rideId.isEmpty ? null : rideId,
    );
    final eligibleStatus = _isArrivedEligibleRideStatus(_rideStatus);
    final showButton = rideId.isNotEmpty &&
        eligibleStatus &&
        _rideStatus != 'arrived' &&
        !_tripStarted;

    if (!showButton ||
        _activeRideInvalidReason(
              _currentRideData,
              rideId: rideId,
              requireTrackedRide: !committed,
              relaxLifecycleProof: committed,
            ) !=
            null) {
      final changedVisibility = _showArrivedButton || _arrivedEnabled;
      _showArrivedButton = false;
      _arrivedEnabled = false;
      _arrivedDisabledReason = '';
      _hasLoggedArrivedEnabled = false;
      if (changedVisibility) {
        _logArrivedButtonState(
          rideId: rideId,
          visible: false,
          enabled: false,
          reason: 'hidden',
          distanceMeters: 0,
        );
        if (mounted) {
          setState(() {});
        }
      }
      return;
    }

    var distanceMeters = 0;
    if (pickup != null) {
      distanceMeters = Geolocator.distanceBetween(
        _driverLocation.latitude,
        _driverLocation.longitude,
        pickup.latitude,
        pickup.longitude,
      ).round();
      _log(
        'arrived check etaMinutes=${_calculateEtaMinutes(distanceMeters / 1000).round()} '
        'distanceMeters=$distanceMeters',
      );
    }

    String disabledReason = '';
    var arrivedEnabled = false;
    if (_activeOnlineAvailabilityMode == 'service_area') {
      arrivedEnabled = true;
      disabledReason = 'service_area';
    } else if (pickup == null) {
      disabledReason = 'pickup_missing';
    } else if (distanceMeters < _kArrivedDistanceThresholdMeters) {
      arrivedEnabled = true;
      disabledReason = 'within_distance';
    } else if (_polyLines.isNotEmpty || _expectedRoutePoints.length >= 2) {
      arrivedEnabled = true;
      disabledReason = 'route_ready';
    } else if (committed) {
      arrivedEnabled = true;
      disabledReason = 'assigned_ride';
    } else {
      disabledReason = 'distance_${distanceMeters}m';
    }

    if (arrivedEnabled && !_hasLoggedArrivedEnabled) {
      _log('arrived enabled rideId=$rideId');
      _logRtdb('arrived enabled rideId=$rideId distanceMeters=$distanceMeters');
      _hasLoggedArrivedEnabled = true;
    }
    if (!arrivedEnabled) {
      _hasLoggedArrivedEnabled = false;
    }

    final stateChanged = _showArrivedButton != showButton ||
        _arrivedEnabled != arrivedEnabled ||
        _arrivedDisabledReason != disabledReason;
    _showArrivedButton = showButton;
    _arrivedEnabled = arrivedEnabled;
    _arrivedDisabledReason = disabledReason;

    _logArrivedButtonState(
      rideId: rideId,
      visible: showButton,
      enabled: arrivedEnabled,
      reason: arrivedEnabled ? disabledReason : disabledReason,
      distanceMeters: distanceMeters,
    );

    if (stateChanged && mounted) {
      setState(() {});
    }
  }

  void _evaluateArrivedAvailabilityThrottled() {
    if (_currentRideId == null || _currentRideId!.trim().isEmpty) {
      return;
    }
    final now = DateTime.now();
    if (_lastArrivedEligibilityCheckAt != null &&
        now.difference(_lastArrivedEligibilityCheckAt!) <
            _kArrivedEligibilityCheckInterval) {
      return;
    }
    _lastArrivedEligibilityCheckAt = now;
    _evaluateArrivedAvailability();
  }

  void _refreshDriverMapFromLocationThrottled() {
    final now = DateTime.now();
    final lastPosition = _lastMapSetStateDriverPosition;
    final movedMeters = lastPosition == null
        ? double.infinity
        : Geolocator.distanceBetween(
            lastPosition.latitude,
            lastPosition.longitude,
            _driverLocation.latitude,
            _driverLocation.longitude,
          );
    if (_lastIdleMapSetStateAt != null &&
        now.difference(_lastIdleMapSetStateAt!) < _kIdleMapSetStateThrottle &&
        movedMeters < 40) {
      return;
    }
    _lastIdleMapSetStateAt = now;
    _lastMapSetStateDriverPosition = _driverLocation;
    if (mounted) {
      _setStateSafely(() {});
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
      await _rideCloud.patchRideRequestMetadata(
        rideId: rideId,
        patch: <String, dynamic>{
          'rider_safety_alert': <String, dynamic>{
            'type': 'sudden_stop',
            'issued_at': DateTime.now().millisecondsSinceEpoch,
            'source': 'driver_device',
          },
        },
      );
    } catch (error) {
      _logSafety(
          'rider_safety_alert publish failed rideId=$rideId error=$error');
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
    if (_mapController == null) {
      debugPrint('MAP_CONTROLLER_READY ready=false');
      return;
    }
    debugPrint('MAP_CONTROLLER_READY ready=true');
    if (points.isEmpty) {
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
    if (_expectedRoutePoints.isNotEmpty) {
      points.addAll(_expectedRoutePoints);
    }
    if (_rideStatus == 'on_trip') {
      points.addAll(
        _remainingTripWaypoints(_tripWaypoints)
            .map((waypoint) => waypoint.location),
      );
    } else {
      if (_pickupLocation != null) {
        points.add(_pickupLocation!);
      }
      if (_destinationLocation != null) {
        points.add(_destinationLocation!);
      }
    }

    if (points.isEmpty) {
      return;
    }

    _moveCameraToBounds(points, 96);
  }

  Future<void> _playSound() async {
    try {
      await _alertSoundService.playRideRequestAlert();
    } catch (_) {}
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
    _explicitDriverSessionCleared = true;
    if (mounted) {
      ScaffoldMessenger.maybeOf(context)?.hideCurrentMaterialBanner();
    }
    await FirebaseAuth.instance.signOut();
  }

  String? _evaluateDriverRestoreRejectReason({
    required Map<String, dynamic> rideData,
    required String driverId,
    required String rideId,
    String source = 'startup_restore',
  }) {
    DriverActiveRideRestoreSupport.logRestoreCandidate(
      rideId: rideId,
      state: TripStateMachine.canonicalStateFromSnapshot(rideData),
      status: TripStateMachine.uiStatusFromSnapshot(rideData),
      api: _lastApiCallStatus,
      socket: _socketStatus,
      updatedAt: DriverActiveRideRestoreSupport.referenceActivityMs(rideData),
    );
    final rejectReason = DriverActiveRideRestoreSupport.staleRestoreReason(
      rideData: rideData,
      driverId: driverId,
      rideId: rideId,
      localSessionExplicitlyCleared: _explicitDriverSessionCleared,
      apiStatus: _lastApiCallStatus,
      socketStatus: _socketStatus,
    );
    if (rejectReason != null) {
      DriverActiveRideRestoreSupport.logRestoreReject(
        rideId: rideId,
        reason: rejectReason,
      );
      DriverActiveRideRestoreSupport.traceStale(
        driverId: driverId,
        rideId: rideId,
        reason: rejectReason,
        source: source,
      );
      _startupRejectedRestoreRideIds.add(rideId);
    }
    return rejectReason;
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
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _log('message send blocked rideId=$rideId reason=missing_auth_user');
      return 'Driver account is not available.';
    }
    final senderId = user.uid;

    final trimmed = text.trim();
    final normalizedImageUrl = imageUrl.trim();
    if (trimmed.isEmpty && normalizedImageUrl.isEmpty) {
      return null;
    }

    if (!_canOpenChat || !_isDriverChatSessionActive(rideId)) {
      return 'Chat is available only for accepted or active rides.';
    }

    final normalizedRideId = rideId.trim();
    final messagesRef = _rideChatMessagesRef(normalizedRideId);
    final messageNode = retryMessageId?.trim().isNotEmpty == true
        ? messagesRef.child(retryMessageId!.trim())
        : messagesRef.push();
    final messageId = messageNode.key?.trim() ?? '';
    if (messageId.isEmpty) {
      return 'Unable to start this chat message right now.';
    }

    final chatCollectionPath = canonicalRideChatMessagesPath(normalizedRideId);
    final chatWritePath = '$chatCollectionPath/$messageId';
    _log(
      'CHAT_SEND_START role=driver rideId=$normalizedRideId messageId=$messageId '
      'path=$chatWritePath senderId=$senderId '
      'text=${trimmed.length > 48 ? '${trimmed.substring(0, 48)}…' : trimmed}',
    );

    try {
      if (_driverChatListenerRideId == null &&
          _isDriverChatSessionActive(normalizedRideId)) {
        if (_isDriverChatOpen) {
          _startDriverChatListener(normalizedRideId, unreadOnly: false);
        } else {
          _ensureDriverChatUnreadListener(normalizedRideId);
        }
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
      _driverChatMessagesById[messageId] = optimistic;
      _log(
        'CHAT_OPTIMISTIC_ADD role=driver rideId=$normalizedRideId '
        'localMessageId=$messageId text=${trimmed.length > 48 ? '${trimmed.substring(0, 48)}…' : trimmed} '
        'status=sending',
      );
      if (_driverChatUiWantsUpdates(normalizedRideId)) {
        _flushDriverChatMessageTable(normalizedRideId);
      }
      final localRenderMs =
          DateTime.now().millisecondsSinceEpoch - clientCreatedAt;
      _log(
        'CHAT_LATENCY_LOCAL_RENDER role=driver rideId=$normalizedRideId '
        'messageId=$messageId ms=$localRenderMs',
      );

      final payload = buildPureAppendChatPayload(
        messageId: messageId,
        rideId: normalizedRideId,
        senderId: senderId,
        senderRole: 'driver',
        text: trimmed,
        type: messageType,
        imageUrl: normalizedImageUrl,
        clientCreatedAtMs: clientCreatedAt,
      );
      if (normalizedImageUrl.isNotEmpty) {
        logRideChatThreadPath(
          rideId: normalizedRideId,
          messageId: messageId,
          path: chatWritePath,
          stage: 'pre_write',
          canonicalPath: chatCollectionPath,
        );
        logRideChatImageMessageWrite(
          rideId: normalizedRideId,
          messageId: messageId,
          senderId: senderId,
          imageUrl: normalizedImageUrl,
          path: chatWritePath,
        );
      }
      unawaited(
        _persistDriverChatMessageToRtdb(
          normalizedRideId: normalizedRideId,
          messageId: messageId,
          messageNode: messageNode,
          chatWritePath: chatWritePath,
          payload: payload,
          senderId: senderId,
          text: trimmed,
          clientCreatedAt: clientCreatedAt,
        ),
      );
      return null;
    } finally {}
  }

  Future<void> _persistDriverChatMessageToRtdb({
    required String normalizedRideId,
    required String messageId,
    required rtdb.DatabaseReference messageNode,
    required String chatWritePath,
    required Map<String, dynamic> payload,
    required String senderId,
    required String text,
    required int clientCreatedAt,
  }) async {
    try {
      await persistRideChatMessageToRtdb(
        messageNode: messageNode,
        payload: payload,
        role: 'driver',
        rideId: normalizedRideId,
        messageId: messageId,
        logLine: _log,
      );
      _confirmDriverOptimisticMessageSent(
        rideId: normalizedRideId,
        messageId: messageId,
        senderId: senderId,
        text: text,
        clientCreatedAt: clientCreatedAt,
      );
      _log(
        'CHAT_SEND_OK role=driver rideId=$normalizedRideId messageId=$messageId '
        'path=$chatWritePath',
      );
    } on TimeoutException catch (error) {
      _markDriverOptimisticMessageFailed(
        rideId: normalizedRideId,
        messageId: messageId,
        senderId: senderId,
        text: text,
      );
      final imageUrl = (payload['imageUrl'] ?? payload['image_url'])?.toString() ?? '';
      if (imageUrl.isNotEmpty) {
        logRideChatImageMessageWriteFail(
          rideId: normalizedRideId,
          messageId: messageId,
          senderId: senderId,
          imageUrl: imageUrl,
          path: chatWritePath,
          error: error,
        );
      }
      _log(
        'CHAT_SEND_FAIL role=driver rideId=$normalizedRideId messageId=$messageId '
        'path=$chatWritePath reason=write_timeout',
      );
      rethrow;
    } catch (error) {
      _markDriverOptimisticMessageFailed(
        rideId: normalizedRideId,
        messageId: messageId,
        senderId: senderId,
        text: text,
      );
      final imageUrl = (payload['imageUrl'] ?? payload['image_url'])?.toString() ?? '';
      if (imageUrl.isNotEmpty) {
        logRideChatImageMessageWriteFail(
          rideId: normalizedRideId,
          messageId: messageId,
          senderId: senderId,
          imageUrl: imageUrl,
          path: chatWritePath,
          error: error,
        );
      }
      if (isRealtimeDatabasePermissionDenied(error)) {
        logRtdbPermissionDenied(
          path: chatWritePath,
          source: 'driver_chat_send',
          error: error,
        );
      }
      _log(
        'CHAT_SEND_FAIL role=driver rideId=$normalizedRideId messageId=$messageId '
        'path=$chatWritePath error=$error',
      );
      rethrow;
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
    logChatImagePicked(
      chatKind: 'ride_chat',
      threadId: normalizedRideId,
      source: useCamera ? 'camera' : 'gallery',
      localPath: picked.path,
      actorId: senderId,
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
      if (result != null) {
        logRideChatImageUploadFail(
          rideId: normalizedRideId,
          senderId: senderId,
          reason: result,
        );
      }
      return result;
    } catch (error) {
      logRideChatImageUploadFail(
        rideId: normalizedRideId,
        senderId: senderId,
        reason: '$error',
      );
      rethrow;
    }
  }

  void _openDriverChat() {
    final rideId = _activeDriverRideContextId;
    if (rideId == null || !_canOpenChat) {
      return;
    }

    _log(
      'DRIVER_CHAT_OPEN rideId=$rideId path=${canonicalRideChatMessagesPath(rideId)}',
    );
    _isDriverChatOpen = true;
    _startDriverChatListener(rideId, unreadOnly: false);
    if (_driverChatMessagesById.isNotEmpty) {
      _flushDriverChatMessageTable(rideId);
      _logDriverChatRenderSummary(rideId);
    }
    _resetDriverUnreadCount(rideId);
    _cancelPendingRouteRequests(reason: 'chat_open');

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
          peerName: _riderName,
          peerPhotoUrl: _riderPhotoUrl,
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
      if (_isDriverChatSessionActive(rideId)) {
        _ensureDriverChatUnreadListener(rideId);
      } else {
        _stopDriverChatListener();
      }
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
    var effectiveSource = source;
    if (source == _DispatchPhotoSource.camera) {
      final status = await Permission.camera.request();
      if (!status.isGranted) {
        _showSnackBarSafely(
          const SnackBar(
            content: Text(
              'Camera permission denied. Opening your photo gallery instead.',
            ),
          ),
        );
        effectiveSource = _DispatchPhotoSource.gallery;
      }
    }

    final image = await _dispatchPhotoPicker.pickImage(
      source: effectiveSource == _DispatchPhotoSource.camera
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

      debugPrint(
        'DELIVERY_PROOF_UPLOAD_START deliveryId=$currentRideId driverId=$_effectiveDriverId',
      );
      final proofRes = await _deliveryCloud.registerDeliveryProofPhoto(
        deliveryId: currentRideId,
        photoUrl: uploadedPhoto.fileUrl,
      );
      if (!deliveryCallableSucceeded(proofRes)) {
        throw StateError(
          proofRes['reason']?.toString() ?? 'delivery_proof_register_failed',
        );
      }
      debugPrint(
        'DELIVERY_PROOF_UPLOAD_SUCCESS deliveryId=$currentRideId',
      );

      if (mounted) {
        setState(() {
          _deliveryProofUploading = false;
          _deliveryProofUploadProgress = 0;
          final nextRideData = Map<String, dynamic>.from(currentRideData);
          nextRideData['deliveryProofPhotoUrl'] = uploadedPhoto.fileUrl;
          nextRideData['delivery_proof_photo_url'] = uploadedPhoto.fileUrl;
          nextRideData['deliveryProofStatus'] = 'submitted';
          _currentRideData = _copyRideWithDispatchDetails(
            nextRideData,
            <String, dynamic>{
              'deliveryProofPhotoUrl': uploadedPhoto.fileUrl,
              'deliveryProofStatus': 'submitted',
            },
          );
          if (_activeDeliveryId == currentRideId && _activeDeliveryData != null) {
            _activeDeliveryData = Map<String, dynamic>.from(nextRideData);
          }
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

  Future<void> _promptDriverDeliveryRating() async {
    final deliveryId = (_activeDeliveryId ?? _currentRideId ?? '').trim();
    if (deliveryId.isEmpty || !mounted) {
      return;
    }
    var selected = 0;
    final result = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext ctx) {
        return StatefulBuilder(
          builder: (BuildContext context, void Function(void Function()) setLocal) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Text(
                    'Rate rider/sender',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List<Widget>.generate(5, (int i) {
                      final star = i + 1;
                      return IconButton(
                        iconSize: 36,
                        onPressed: () => setLocal(() => selected = star),
                        icon: Icon(
                          star <= selected ? Icons.star : Icons.star_border,
                          color: const Color(0xFFFFC107),
                        ),
                      );
                    }),
                  ),
                  FilledButton(
                    onPressed: selected < 1
                        ? null
                        : () => Navigator.pop(ctx, selected),
                    child: const Text('Submit'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
    if (result == null || result < 1) {
      return;
    }
    try {
      final res = await _deliveryCloud.submitDeliveryRating(
        deliveryId: deliveryId,
        rating: result,
      );
      if (!deliveryCallableSucceeded(res)) {
        final reason = res['reason']?.toString() ?? 'unknown';
        if (reason != 'rating_duplicate') {
          _showSnackBarSafely(
            SnackBar(content: Text('Could not save rating ($reason).')),
          );
        }
        return;
      }
      _showSnackBarSafely(const SnackBar(content: Text('Thanks for your rating.')));
    } catch (error) {
      _showSnackBarSafely(
        const SnackBar(content: Text('Could not submit rating right now.')),
      );
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
    final serviceType = _serviceTypeKey(rideData['service_type']);
    final canShowNonPaymentAction = _canShowNonPaymentAction(
      rideStatus: 'completed',
      rideData: rideData,
    );
    if (!mounted || riderId.isEmpty) {
      return;
    }
    final normalizedRideId = rideId.trim();
    if (normalizedRideId.isEmpty ||
        _ratingHandledRideIds.contains(normalizedRideId)) {
      return;
    }
    _markRatingRideHandled(normalizedRideId, source: 'driver_prompt_show');
    final parentContext = context;
    _log(
      'RATING_UI_CONTEXT_SAFE rideId=$rideId mounted=$mounted rootNavigator=true',
    );

    final noteController = TextEditingController();
    var rating = 5.0;
    var submitting = false;

    final nextAction = await showModalBottomSheet<_PostTripReviewAction>(
      context: context,
      useRootNavigator: true,
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
                              : () {
                                  final submittedRating = rating;
                                  final submittedNote =
                                      noteController.text.trim();
                                  _closeRatingSheetSafely(sheetContext);
                                  WidgetsBinding.instance.addPostFrameCallback(
                                    (_) {
                                      unawaited(
                                        _submitDriverRiderRatingAfterTrip(
                                          parentContext: parentContext,
                                          rideId: rideId,
                                          riderId: riderId,
                                          serviceType: serviceType,
                                          rating: submittedRating,
                                          note: submittedNote,
                                        ),
                                      );
                                    },
                                  );
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
                                      Navigator.of(
                                        sheetContext,
                                        rootNavigator: true,
                                      ).pop(
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
                                    Navigator.of(
                                      sheetContext,
                                      rootNavigator: true,
                                    ).pop(
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

  Widget _buildActiveTripDraggablePanel() {
    return Positioned.fill(
      child: DraggableScrollableSheet(
        initialChildSize: 0.38,
        minChildSize: 0.18,
        maxChildSize: 0.70,
        snap: true,
        snapSizes: const <double>[0.18, 0.38, 0.60, 0.70],
        builder: (BuildContext context, ScrollController scrollController) {
          return SingleChildScrollView(
            controller: scrollController,
            physics: const ClampingScrollPhysics(),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: SafeArea(
                top: false,
                child: _buildTripPanel(),
              ),
            ),
          );
        },
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

    final showStartTrip = _rideStatus == 'arrived' || _tripStateIsArrived(activeRide);
    final paymentBlocksDriverCancel =
        _ridePaymentBlocksDriverCancel(activeRide);
    final showCancelTrip = _canDriverCancelActiveRide(
      _rideStatus,
      rideData: activeRide,
    );
    const contactHint = 'Contact through NexRide call/chat';
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
              if ((_queuedNextRideIdFromProfile ?? '').trim().isNotEmpty) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  decoration: BoxDecoration(
                    color: _gold.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _gold.withValues(alpha: 0.35)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Next ride queued',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Finish your current trip first. Ride ${_queuedNextRideIdFromProfile ?? ''} will start automatically after this trip ends.',
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: Colors.black54,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
              ],
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
              Row(
                children: <Widget>[
                  ProfileAvatar(
                    name: _riderName,
                    photoUrl: _riderPhotoUrl,
                    radius: 20,
                    backgroundColor: _gold.withValues(alpha: 0.14),
                    foregroundColor: Colors.black87,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Text(
                          'Rider',
                          style: TextStyle(fontSize: 12, color: Colors.black54),
                        ),
                        Text(
                          _riderName,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: Colors.black87,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _buildTripDetailRow(
                icon: Icons.call_outlined,
                label: 'Contact',
                value: contactHint,
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
              if (_currentRideData != null)
                _buildTripItinerarySection(
                  rideData: _currentRideData!,
                  pickupAddress: _pickupAddressText,
                  finalDestinationAddress: _destinationAddressText,
                )
              else ...[
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
              ],
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
                  _hasPendingTripStopsBeforeFinal
                      ? '${_driverFacingRemainingStops().length} stop${_driverFacingRemainingStops().length == 1 ? '' : 's'} remaining before final destination'
                      : 'Final destination reached — ready to complete',
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
              if (_ridePaymentConfirmedForUi(activeRide)) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.green.withValues(alpha: 0.35),
                    ),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.check_circle, color: Colors.green),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Payment confirmed',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            color: Colors.black87,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (_isBankTransferPaymentMethod(activeRide) &&
                  !_ridePaymentConfirmedForUi(activeRide)) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.amber.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _isDriverBankTransferPaymentConfirmedOnRide(activeRide)
                            ? 'Payment not verified yet — do not start trip'
                            : 'Payment not verified yet — do not start trip',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _isDriverBankTransferPaymentConfirmedOnRide(activeRide)
                            ? 'NexRide is confirming the rider payment with Flutterwave. You cannot start or complete this paid trip until verification finishes.'
                            : 'NexRide must verify rider payment before you start or complete this trip. Driver payment notes do not unlock the trip.',
                        style: const TextStyle(
                          color: Colors.black54,
                          height: 1.35,
                        ),
                      ),
                      if (_shouldShowDriverPaymentConfirmation(activeRide)) ...[
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _paymentConfirmInFlight
                                ? null
                                : () {
                                    unawaited(
                                      _promptConfirmRiderBankTransferPayment(),
                                    );
                                  },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _gold,
                              foregroundColor: Colors.black,
                            ),
                            child: Text(
                              _paymentConfirmInFlight
                                  ? 'Saving…'
                                  : 'Payment seen / report issue',
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () {
                            unawaited(
                              _openWhatsAppSupportFromDriverMap(
                                sourceScreen: 'payment_review',
                                tripType: 'payment',
                                paymentStatus: activeRide['payment_status']
                                        ?.toString() ??
                                    activeRide['paymentStatus']?.toString(),
                                tripStatus: activeRide['status']?.toString(),
                              ),
                            );
                          },
                          icon: const Icon(Icons.support_agent_outlined),
                          label: const Text('Support'),
                        ),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      unawaited(
                        _openWhatsAppSupportFromDriverMap(
                          sourceScreen: 'active_trip',
                          tripStatus: activeRide['status']?.toString(),
                        ),
                      );
                    },
                    icon: const Icon(Icons.support_agent_outlined),
                    label: const Text('Support'),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              if (_showArrivedButton) ...[
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.black87,
                      disabledBackgroundColor: Colors.black38,
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    onPressed: _arrivedEnabled ? markArrived : null,
                    child: const Text(
                      'ARRIVED',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                if (!_arrivedEnabled && _arrivedDisabledReason.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    _arrivedDisabledReason == 'pickup_missing'
                        ? 'Pickup location is still loading.'
                        : _arrivedDisabledReason.startsWith('distance_')
                            ? 'Move closer to pickup to enable Arrived.'
                            : 'Arrived will enable shortly.',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.black54,
                      height: 1.3,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
              ],
              if (showStartTrip) ...[
                Text(
                  'Waiting timer: ${_waitTimerLabel()}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.black54,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      disabledBackgroundColor: _gold.withValues(alpha: 0.45),
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    onPressed: _ridePaymentPendingForStartTrip(activeRide)
                        ? null
                        : startTrip,
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
                        : () {
                            unawaited(_handleTripProgressAction());
                          },
                    child: Text(
                      _rideTripProgressActionLabel(serviceType),
                      style: const TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              if (paymentBlocksDriverCancel) ...[
                Text(
                  'Paid trips cannot be cancelled by the driver. Contact support.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.redAccent.shade200,
                    fontWeight: FontWeight.w600,
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
                              Positioned(
                                right: 12,
                                top: -4,
                                child: ValueListenableBuilder<int>(
                                  valueListenable: _driverChatUnreadNotifier,
                                  builder: (context, unreadCount, _) {
                                    if (unreadCount <= 0) {
                                      return const SizedBox.shrink();
                                    }
                                    return Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.red,
                                          borderRadius:
                                              BorderRadius.circular(10),
                                        ),
                                        child: Text(
                                          '$unreadCount',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      );
                                    },
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

  Widget _buildAvailabilityModeSelector() {
    Widget modeChip({
      required String id,
      required String label,
      required IconData icon,
    }) {
      final bool selected = _pendingAvailabilityMode == id;
      return Expanded(
        child: ChoiceChip(
          avatar: Icon(icon, size: 18),
          label: Text(label),
          selected: selected,
          onSelected: (bool v) {
            if (!v || !mounted) {
              return;
            }
            _setStateSafely(() {
              _pendingAvailabilityMode = id;
              _rolloutBannerDismissed = false;
            });
          },
        ),
      );
    }

    return Material(
      color: Colors.white.withValues(alpha: 0.96),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              _pendingAvailabilityMode == 'service_area'
                  ? 'Area mode: requests match your selected city (GPS not required).'
                  : 'GPS mode: requests match distance from your live position.',
              style: const TextStyle(
                color: Colors.black54,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                modeChip(
                  id: 'current_location',
                  label: 'GPS',
                  icon: Icons.gps_fixed_rounded,
                ),
                const SizedBox(width: 8),
                modeChip(
                  id: 'service_area',
                  label: 'Area',
                  icon: Icons.location_city_rounded,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRolloutAreaBanner() {
    return Material(
      color: const Color(0xFFFFF2E0),
      borderRadius: BorderRadius.circular(14),
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
                      unawaited(_openDriverRolloutOperatingArea());
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
                    child: Text(
                      driverRolloutBannerTitle(
                        catalogLoading: _rolloutCatalogLoading,
                        catalogError: _rolloutCatalogError,
                        catalogHydrated: _rolloutCatalogHydrated,
                        catalogEmpty: _rolloutCatalog.isEmpty,
                        savedAreaDisabled: _rolloutSavedAreaDisabled,
                        selectionComplete: _rolloutSelectionComplete,
                      ),
                      style: const TextStyle(
                        color: Color(0xFF4A3B2A),
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
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
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                if (!_rolloutCatalogLoading)
                  TextButton(
                    onPressed: () {
                      _setStateSafely(() {
                        _rolloutBannerDismissed = true;
                      });
                    },
                    child: const Text('Dismiss'),
                  ),
                TextButton(
                  onPressed: _rolloutCatalogLoading
                      ? null
                      : () {
                          unawaited(_openDriverRolloutOperatingArea());
                        },
                  child: Text(
                    _rolloutCatalogError != null
                        ? 'Retry'
                        : 'Choose service area',
                  ),
                ),
              ],
            ),
          ],
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

  Widget _buildDebugOverlay() {
    final serviceTypes = _effectiveDriverServiceTypes().join(', ');
    _syncOfferListenerDebugCounts();
    final activeRideLabel = _firstNonEmptyText(<dynamic>[
      _currentRideId,
      _driverActiveRideId,
    ]).trim();
    return GestureDetector(
      onDoubleTap: () {
        if (!mounted) {
          return;
        }
        _setStateSafely(() {
          _showDriverDebugOverlay = !_showDriverDebugOverlay;
        });
      },
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(10),
        ),
        child: DefaultTextStyle(
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            height: 1.25,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text('state: ${_debugTripStateLabel()}'),
              Text('api: $_lastApiCallStatus'),
              Text('socket: $_socketStatus'),
              Text(
                'Offer listener: ${_isDriverOfferQueueListenerAttached ? 'attached' : 'not attached'}',
              ),
              Text('Offer queue count: $_offerQueueDebugCount'),
              Text(
                'Current active ride: ${activeRideLabel.isEmpty ? 'none' : activeRideLabel}',
              ),
              Text('Last offer event: $_lastOfferEventSummary'),
              Text(
                'location_mode: ${_isOnline ? _activeOnlineAvailabilityMode : _pendingAvailabilityMode}',
              ),
              if ((_rolloutDispatchMarketId ?? '').trim().isNotEmpty)
                Text('dispatch_market_id: $_rolloutDispatchMarketId'),
              if ((_rolloutCityId ?? '').trim().isNotEmpty)
                Text('service_area_city: $_rolloutCityId'),
              Text('service: $serviceTypes'),
              Text(
                'error: ${_lastActionError.isEmpty ? 'none' : _lastActionError}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
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
          PortalNotificationBellButton(
            uid: FirebaseAuth.instance.currentUser?.uid ?? _effectiveDriverId,
          ),
          IconButton(
            tooltip: 'Driver hub',
            onPressed: () {
              unawaited(_openDriverToolsSheet());
            },
            icon: const Icon(Icons.menu_rounded),
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
          if (!_hasRenderableActiveRide &&
              !_hasActiveDelivery &&
              shouldShowDriverRolloutBanner(
                pendingAvailabilityMode: _pendingAvailabilityMode,
                catalogLoading: _rolloutCatalogLoading,
                catalogHydrated: _rolloutCatalogHydrated,
                catalogError: _rolloutCatalogError,
                catalog: _rolloutCatalog,
                selectionComplete: _rolloutSelectionComplete,
                savedAreaDisabled: _rolloutSavedAreaDisabled,
                bannerDismissed: _rolloutBannerDismissed,
              ))
            Positioned(
              top: 8,
              left: 16,
              right: 16,
              child: SafeArea(
                bottom: false,
                child: _buildRolloutAreaBanner(),
              ),
            ),
          if (!_hasRenderableActiveRide && !_hasActiveDelivery)
            Positioned(
              bottom: 20,
              left: 20,
              right: 20,
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _buildLocationPermissionBlockCard(),
                    if (_locationCapability != null &&
                        !_locationCapability!.canGoOnline &&
                        !_isOnline)
                      const SizedBox(height: 10),
                    _buildAvailabilityStatusCard(),
                    const SizedBox(height: 10),
                    if (!_isOnline) ...<Widget>[
                      _buildAvailabilityModeSelector(),
                      const SizedBox(height: 10),
                    ],
                    _buildAvailabilityToggleButton(),
                  ],
                ),
              ),
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
          if (kDebugMode && _showDriverDebugOverlay)
            Positioned(
              top: 98,
              left: 12,
              right: 12,
              child: _buildDebugOverlay(),
            ),
          if (_hasRenderableActiveRide) _buildActiveTripDraggablePanel(),
          if (_hasActiveDelivery) _buildActiveDeliveryDraggablePanel(),
        ],
      ),
    );
  }
}
