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
import 'package:url_launcher/url_launcher.dart';

import 'package:share_plus/share_plus.dart';

import 'compliance/rider_identity_booking_gate.dart';
import 'onboarding/rider_selfie_verification_screen.dart';
import 'config/rider_app_config.dart';
import 'config/rtdb_ride_request_contract.dart';
import 'services/rider_delivery_cloud_functions_service.dart';
import 'services/rider_ride_cloud_functions_service.dart'
    show
        RiderRideCloudFunctionsService,
        riderRideCallableReason,
        riderRideCallableSucceeded,
        riderRideCallableUserMessage;
import 'services/rider_rollout_profile_store.dart';
import 'config/rollout_copy.dart';
import 'models/rollout_delivery_region_model.dart';
import 'widgets/rider_rollout_area_sheet.dart';
import 'services/rollout_catalog_hydration.dart';
import 'services/dispatch_photo_upload_service.dart';
import 'services/rider_trust_bootstrap_service.dart';
import 'services/rider_trust_rules_service.dart';
import 'services/trip_safety_service.dart';
import 'service_type.dart';
import 'trip_sync/delivery_state_machine.dart';
import 'support/rider_backend_pricing.dart';
import 'support/rider_fare_support.dart';
import 'support/friendly_firebase_errors.dart';
import 'support/rtdb_flow_debug_log.dart';
import 'support/startup_rtdb_support.dart';
import 'support/phone_requirement.dart';
import 'screens/rider_profile_edit_screen.dart';
import 'trip_sync/trip_state_machine.dart';
import 'services/delivery_chat_service.dart';
import 'services/delivery_report_service.dart';
import 'services/call_service.dart';
import 'widgets/delivery_chat_sheet.dart';
import 'widgets/ride_chat_sheet.dart' show RideChatImageSource;
import 'widgets/delivery_live_tracking_panel.dart';
import 'widgets/driver_safety_card.dart';
import 'support/driver_vehicle_display.dart';
import 'services/vehicle_mismatch_report_service.dart';
import 'widgets/delivery_rating_sheet.dart';
import 'support/chat_image_debug.dart';
import 'support/delivery_chat_support.dart';
import 'support/delivery_call_support.dart';
import 'support/delivery_call_ui_controller.dart';
import 'support/delivery_cancel_reasons.dart';
import 'safe_share_origin.dart';
import 'services/rider_compliance_service.dart';
import 'widgets/rider_identity_verification_banner.dart';
import 'services/native_places_service.dart';
import 'share_trip_rtdb.dart';
import 'widgets/native_places_autocomplete_field.dart';
import 'widgets/rider_discount_selector.dart';
import 'widgets/rider_flutterwave_va_payment_sheet.dart';

class DispatchRequestScreen extends StatefulWidget {
  const DispatchRequestScreen({super.key});

  @override
  State<DispatchRequestScreen> createState() => _DispatchRequestScreenState();
}

enum _DispatchItemPhotoSource { camera, gallery }

class _DispatchRequestScreenState extends State<DispatchRequestScreen> {
  static const Color _gold = Color(0xFFB57A2A);
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
  final NativePlacesService _nativePlaces = NativePlacesService.instance;

  LatLng? _pickupLocation;
  LatLng? _dropoffLocation;
  bool _sharingDeliveryLink = false;
  bool _applyingDispatchPlace = false;

  final rtdb.DatabaseReference _rideRequestsRef = rtdb.FirebaseDatabase.instance
      .ref('ride_requests');
  final rtdb.DatabaseReference _deliveryRequestsRef = rtdb
      .FirebaseDatabase
      .instance
      .ref('delivery_requests');
  final rtdb.DatabaseReference _userActiveDeliveryRef = rtdb
      .FirebaseDatabase
      .instance
      .ref('user_active_delivery');
  final rtdb.DatabaseReference _usersRef = rtdb.FirebaseDatabase.instance.ref(
    'users',
  );
  final rtdb.DatabaseReference _driversRef = rtdb.FirebaseDatabase.instance.ref(
    'drivers',
  );
  final rtdb.DatabaseReference _driverActiveRidesRef = rtdb
      .FirebaseDatabase
      .instance
      .ref('driver_active_rides');
  final RiderTrustBootstrapService _bootstrapService =
      const RiderTrustBootstrapService();
  final RiderTrustRulesService _trustRulesService =
      const RiderTrustRulesService();
  final DispatchPhotoUploadService _dispatchPhotoUploadService =
      const DispatchPhotoUploadService();
  final RiderDeliveryCloudFunctionsService _deliveryCloud =
      RiderDeliveryCloudFunctionsService();
  final RiderRideCloudFunctionsService _rideCloud =
      RiderRideCloudFunctionsService.instance;
  final TripSafetyTelemetryService _tripSafetyService =
      TripSafetyTelemetryService();

  StreamSubscription<rtdb.DatabaseEvent>? _activeRequestSubscription;
  Timer? _deliveryWaitFeePollTimer;
  StreamSubscription<rtdb.DatabaseEvent>? _deliveryChatSubscription;
  final ValueNotifier<List<DeliveryChatMessage>> _deliveryChatMessages =
      ValueNotifier<List<DeliveryChatMessage>>(<DeliveryChatMessage>[]);
  final DeliveryChatService _deliveryChatService = DeliveryChatService();
  final DeliveryReportService _deliveryReportService = DeliveryReportService();
  final CallService _callService = CallService();
  late final DeliveryCallUiController _deliveryCallUi;
  bool _isStartingDeliveryCall = false;
  String? _activeRequestId;
  Map<String, dynamic>? _activeRequest;
  String? _paymentPromptedForDeliveryId;
  String? _ratingPromptedForDeliveryId;
  RiderBackendPricingQuote? _dispatchFarePreview;
  List<RiderDiscountOption> _deliveryDiscountOptions = <RiderDiscountOption>[];
  String? _selectedDeliveryDiscountId;
  bool _deliveryDiscountsLoading = false;
  bool _dispatchQuoteLoading = false;
  DispatchPhotoSelectedAsset? _packagePhotoAsset;
  String _selectedLaunchCity = RiderLaunchScope.defaultBrowseCity;
  List<RolloutDeliveryRegionModel> _rolloutCatalog =
      const <RolloutDeliveryRegionModel>[];
  bool _rolloutCatalogLoading = false;
  bool _rolloutCatalogHydrated = false;
  Object? _rolloutCatalogError;
  String? _rolloutCatalogSource;
  String? _rolloutRegionId;
  String? _rolloutCityId;
  String? _rolloutDispatchMarketId;
  bool _rolloutSavedAreaDisabled = false;
  int _rolloutCatalogLoadSeq = 0;
  bool _rolloutBannerDismissed = false;
  bool _loading = true;
  bool _submitting = false;
  bool _uploadingPackagePhoto = false;
  /// Hosted Flutterwave card link vs Flutterwave virtual-account bank transfer.
  String _dispatchPaymentMethod = 'flutterwave';
  bool _restoringActiveRequest = false;
  double _packagePhotoUploadProgress = 0;
  bool _identityComplianceLoaded = false;
  bool _selfieBlocksBooking = false;
  RiderComplianceSnapshot? _riderFirestoreCompliance;

  Future<void> _loadIdentityCompliance() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) {
        setState(() {
          _identityComplianceLoaded = true;
          _riderFirestoreCompliance = null;
          _selfieBlocksBooking = true;
        });
      }
      return;
    }
    final snap = await RiderComplianceService.instance.fetchSnapshot(user.uid);
    if (!mounted) {
      return;
    }
    setState(() {
      _identityComplianceLoaded = true;
      _riderFirestoreCompliance = snap;
      _selfieBlocksBooking = snap.blocksRideBooking;
    });
  }

  @override
  void initState() {
    super.initState();
    _deliveryCallUi = DeliveryCallUiController(
      callService: _callService,
      getOverlayContext: () => mounted ? context : null,
      onBusyChanged: (busy) {
        if (mounted) {
          setState(() => _isStartingDeliveryCall = busy);
        }
      },
    );
    _deliveryCallUi.registerLifecycle();
    _pickupController.addListener(_onPickupAddressEdited);
    _dropoffController.addListener(_onDropoffAddressEdited);
    unawaited(_hydrateRiderTrustState(persist: true));
    unawaited(_restoreActiveDispatchRequest());
    unawaited(_loadIdentityCompliance());
    unawaited(_loadRolloutForDispatch());
  }

  bool get _rolloutSelectionComplete =>
      (_rolloutRegionId ?? '').trim().isNotEmpty &&
      (_rolloutCityId ?? '').trim().isNotEmpty &&
      (_rolloutDispatchMarketId ?? '').trim().isNotEmpty;

  Future<void> _loadRolloutForDispatch() async {
    final loadSeq = ++_rolloutCatalogLoadSeq;
    final uid = FirebaseAuth.instance.currentUser?.uid.trim();
    if (uid == null || uid.isEmpty) {
      if (mounted) {
        setState(() {
          _rolloutCatalogLoading = false;
          _rolloutCatalogHydrated = false;
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _rolloutCatalogLoading = true;
        _rolloutCatalogError = null;
        _rolloutBannerDismissed = false;
      });
    }
    List<RolloutDeliveryRegionModel> regions = const <RolloutDeliveryRegionModel>[];
    RolloutCatalogSelection selection = const RolloutCatalogSelection();
    Object? loadError;
    String? catalogSource;
    try {
      await (() async {
        final raw = await _rideCloud
            .listDeliveryRegions(
              riderSelectedRegionId: _rolloutRegionId?.trim(),
              riderSelectedCityId: _rolloutCityId?.trim(),
            )
            .timeout(kRolloutCatalogCallableTimeout);
        if (raw['success'] != true) {
          throw StateError('listDeliveryRegions_failed');
        }
        catalogSource = rolloutCatalogSourceFromResponse(Map<String, dynamic>.from(raw));
        regions = parseRolloutRegionsWithEmergencyFallback(Map<String, dynamic>.from(raw));
        Map<String, String>? saved;
        try {
          saved = await RiderRolloutProfileStore.instance.fetchSelection(uid);
        } catch (_) {
          saved = null;
        }
        selection = mergeSavedRolloutWithCatalog(
          regions: regions,
          saved: saved,
          regionKey: RiderRolloutProfileStore.kRegionId,
          cityKey: RiderRolloutProfileStore.kCityId,
          dispatchKey: RiderRolloutProfileStore.kDispatchMarketId,
        );
      })().timeout(kRolloutCatalogLoadBudget);
    } catch (e) {
      loadError = e;
    } finally {
      if (loadSeq != _rolloutCatalogLoadSeq) {
        return;
      }
      if (!mounted) {
        _rolloutCatalogLoading = false;
        _rolloutCatalogHydrated = true;
        _rolloutCatalogError = loadError;
        if (loadError == null) {
          _rolloutCatalog = regions;
          _rolloutCatalogSource = catalogSource;
          _rolloutRegionId = selection.regionId;
          _rolloutCityId = selection.cityId;
          _rolloutDispatchMarketId = selection.dispatchMarketId;
          _rolloutSavedAreaDisabled = selection.savedAreaDisabled;
        } else {
          _rolloutCatalogSource = null;
        }
        return;
      }
      setState(() {
        _rolloutCatalogLoading = false;
        _rolloutCatalogHydrated = true;
        _rolloutCatalogError = loadError;
        if (loadError == null) {
          _rolloutCatalog = regions;
          _rolloutCatalogSource = catalogSource;
          _rolloutRegionId = selection.regionId;
          _rolloutCityId = selection.cityId;
          _rolloutDispatchMarketId = selection.dispatchMarketId;
          _rolloutSavedAreaDisabled = selection.savedAreaDisabled;
          if (_rolloutSelectionComplete) {
            _selectedLaunchCity = RiderServiceAreaConfig.marketForCity(
              _rolloutDispatchMarketId,
            ).city;
          }
        } else {
          _rolloutCatalogSource = null;
        }
      });
    }
  }

  Future<void> _openRolloutSheet() async {
    if (!mounted) {
      return;
    }
    await RiderRolloutAreaSheet.show(
      context,
      regions: _rolloutCatalog,
      initialRegionId: _rolloutRegionId,
      initialCityId: _rolloutCityId,
      catalogSource: _rolloutCatalogSource,
      onReloadCatalog: () async {
        final raw = await _rideCloud
            .listDeliveryRegions(
              riderSelectedRegionId: _rolloutRegionId?.trim(),
              riderSelectedCityId: _rolloutCityId?.trim(),
            )
            .timeout(kRolloutCatalogCallableTimeout);
        if (raw['success'] != true) {
          throw StateError('listDeliveryRegions_failed');
        }
        final regions = parseRolloutRegionsWithEmergencyFallback(Map<String, dynamic>.from(raw));
        if (mounted) {
          setState(() {
            _rolloutCatalog = regions;
            _rolloutCatalogSource = rolloutCatalogSourceFromResponse(Map<String, dynamic>.from(raw));
            _rolloutCatalogError = null;
          });
        }
        return regions;
      },
    );
    await _refreshRolloutAfterDispatchSheet();
  }

  Future<void> _refreshRolloutAfterDispatchSheet() async {
    await _loadRolloutForDispatch();
    if (!mounted || !_rolloutSelectionComplete) {
      return;
    }
    try {
      final vr = await _rideCloud
          .validateServiceLocation(
            regionId: _rolloutRegionId!.trim(),
            cityId: _rolloutCityId!.trim(),
            service: 'package',
          )
          .timeout(const Duration(seconds: 20));
      if (!mounted) {
        return;
      }
      if (riderRideCallableSucceeded(vr)) {
        _showMessage('Service area saved.');
        if (mounted) {
          setState(() {
            _rolloutBannerDismissed = true;
          });
        }
      } else {
        _showMessage(RolloutCopy.notAvailableInArea);
      }
    } catch (_) {
      if (mounted) {
        _showMessage(
          'Could not verify your area yet. Check connection and try again.',
        );
      }
    }
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _activeRequestSubscription?.cancel();
    unawaited(_deliveryCallUi.dispose());
    _deliveryWaitFeePollTimer?.cancel();
    _deliveryWaitFeePollTimer = null;
    _deliveryChatSubscription?.cancel();
    _deliveryChatMessages.dispose();
    _pickupController.removeListener(_onPickupAddressEdited);
    _dropoffController.removeListener(_onDropoffAddressEdited);
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
        return;
      }

      setState(() {
        _selectedLaunchCity = preferredLaunchCity;
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
        final pointerSnap = await runOptionalStartupRead<rtdb.DataSnapshot>(
          source: 'dispatch_request.restore_active_delivery_pointer',
          path: 'user_active_delivery/$userId',
          action: () => _userActiveDeliveryRef
              .child(userId)
              .get()
              .timeout(_restoreReadTimeout),
        );
        if (pointerSnap != null &&
            pointerSnap.exists &&
            pointerSnap.value is Map) {
          final ptr = _asStringDynamicMap(pointerSnap.value);
          final deliveryId =
              ptr?['delivery_id']?.toString().trim() ??
              ptr?['deliveryId']?.toString().trim() ??
              '';
          if (deliveryId.isNotEmpty) {
            final dSnap = await runOptionalStartupRead<rtdb.DataSnapshot>(
              source: 'dispatch_request.restore_active_delivery_row',
              path: 'delivery_requests/$deliveryId',
              action: () => _deliveryRequestsRef
                  .child(deliveryId)
                  .get()
                  .timeout(_restoreReadTimeout),
            );
            if (dSnap != null && dSnap.exists && dSnap.value is Map) {
              final latestRequest =
                  _asStringDynamicMap(dSnap.value) ?? <String, dynamic>{};
              final status =
                  TripStateMachine.uiStatusFromSnapshot(latestRequest);
              if (status != 'completed' && status != 'cancelled') {
                final assignmentReleased =
                    await _releaseExpiredAssignedDispatchRequestIfNeeded(
                      deliveryId,
                      latestRequest,
                    );
                if (assignmentReleased) {
                  continue;
                }
                final timedOut = await _cancelTimedOutDispatchRequestIfNeeded(
                  deliveryId,
                  latestRequest,
                );
                if (timedOut) {
                  if (!mounted) {
                    return;
                  }
                  setState(() {
                    _loading = false;
                  });
                  return;
                }
                _watchRequest(deliveryId);
                if (!mounted) {
                  return;
                }
                setState(() {
                  _activeRequestId = deliveryId;
                  _activeRequest = latestRequest;
                  _loading = false;
                });
                return;
              }
            }
          }
        }

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

  int _deliveryWaitFeeNgn(Map<String, dynamic>? row) {
    if (row == null) {
      return 0;
    }
    final raw = row['wait_fee_total'] ?? row['waitFeeTotal'];
    if (raw is num) {
      return raw.round();
    }
    return int.tryParse('$raw') ?? 0;
  }

  bool _deliveryPaymentVerified(Map<String, dynamic> row) {
    final ps = (row['payment_status']?.toString() ?? '').trim().toLowerCase();
    final tid = (row['payment_transaction_id']?.toString() ?? '').trim();
    final verified = row['payment_verified'] == true;
    if (ps == 'paid_verified' && tid.isNotEmpty) {
      return verified;
    }
    return ps == 'verified' && tid.isNotEmpty && verified;
  }

  Future<Map<String, dynamic>?> _runFlutterwaveDeliveryCheckout({
    required String deliveryId,
    required Map<String, dynamic> deliveryRow,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    final quote = RiderBackendPricingQuote.tryFromMap(deliveryRow);
    final init = await _deliveryCloud.initiateFlutterwavePayment(
      deliveryId: deliveryId,
      amount: quote?.hasAuthoritativeTotal == true
          ? quote!.totalNgn.toDouble()
          : (deliveryRow['fare'] as num?)?.toDouble() ?? 0,
      currency: 'NGN',
      customerName: user?.displayName,
      email: user?.email,
    );
    if (init['success'] != true) {
      debugPrint(
        '[DispatchPayment] init failed raw=${riderDeliveryCallableReason(init)}',
      );
      _showMessage(
        friendlyCallableReason(
          init,
          fallback: 'Could not start payment. Please try again.',
        ),
      );
      return null;
    }
    final url = (init['authorization_url'] ?? init['authorizationUrl'] ?? '')
        .toString()
        .trim();
    final txRef = (init['tx_ref'] ?? init['txRef'] ?? '').toString().trim();
    if (url.isEmpty || txRef.isEmpty) {
      _showMessage('Payment link missing.');
      return null;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      _showMessage('Invalid payment link.');
      return null;
    }
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched) {
      _showMessage('Could not open payment page.');
      return null;
    }
    _showMessage(
      'Complete payment in your browser, then return here. Matching starts after verification.',
    );
    for (var i = 0; i < 90; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final snap = await _deliveryRequestsRef.child(deliveryId).get();
      final row = _asStringDynamicMap(snap.value);
      if (row != null && _deliveryPaymentVerified(row)) {
        return row;
      }
      if (i % 3 == 2) {
        try {
          await _deliveryCloud.verifyFlutterwavePayment(
            deliveryId: deliveryId,
            reference: txRef,
          );
        } catch (_) {
          /* keep polling */
        }
      }
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
      _driverActiveRidesRef.child(driverId).get(),
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
    final driverRef = _driversRef.child(driverId);
    await driverRef.update(<String, dynamic>{
      'isAvailable': isOnline,
      'available': isOnline,
      'status': isOnline ? 'idle' : 'offline',
      'activeRideId': null,
      'currentRideId': null,
      'updated_at': rtdb.ServerValue.timestamp,
    });
    await _driverActiveRidesRef.child(driverId).remove();
    debugPrint(
      '[Dispatch] driver availability restored requestId=$requestId driverId=$driverId reason=$reason',
    );
  }

  void _safeNavigatorPop(BuildContext navigatorContext, [Object? result]) {
    if (!mounted) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final navigator = Navigator.of(navigatorContext);
      if (!navigator.canPop()) {
        return;
      }
      debugPrint('DISPATCH_NAVIGATION_LOCK_GUARD pop');
      navigator.pop(result);
    });
  }

  String _deliveryCreateUserMessage(String reason) {
    switch (reason) {
      case 'package_photo_upload_failed':
      case 'package_photo_upload_timeout':
        return 'Package photo upload failed. Check your connection and try again.';
      case 'package_description_required':
      case 'package_description_too_long':
        return 'Please describe your package in 3–2000 characters.';
      case 'recipient_name_required':
      case 'recipient_name_invalid':
        return 'Please enter the recipient’s name (at least 2 characters) or leave it blank.';
      case 'recipient_phone_invalid':
        return 'Enter a valid recipient phone number.';
      case 'invalid_category':
        return 'That package category is not supported.';
      case 'customer_active_delivery':
        return 'You already have an active delivery. Finish or cancel it first.';
      case 'user_profile_required':
        return 'Please complete your profile before sending a delivery.';
      case 'invalid_market':
      case 'pickup_location_out_of_region':
      case 'dropoff_location_out_of_region':
        return RiderLaunchScope.tripRequestAvailabilityMessage;
      case 'pickup_mismatch_service_city':
      case 'pickup_outside_selected_service_area':
      case 'pickup_outside_enabled_city':
      case 'no_service_area_for_pickup':
      case 'service_area_unsupported':
      case 'rollout_hint_invalid':
        return riderIdentityServerRejectionUserMessage(reason) ??
            RiderLaunchScope.tripRequestAvailabilityMessage;
      case 'invalid_fare':
      case 'fare_above_limit':
        return 'The delivery fare could not be calculated. Try again.';
      case 'fare_quote_mismatch':
        return 'The delivery fare changed. Review the price and try again.';
      case 'pricing_total_mismatch':
        return 'The delivery total did not match the quoted price. Try again.';
      case 'invalid_distance':
        return 'Dispatch distance could not be validated. Refresh the route and try again.';
      case 'invalid_eta':
        return 'Dispatch ETA could not be validated. Refresh the route and try again.';
      case 'invalid_pickup_or_dropoff':
        return 'Pickup and dropoff locations are required.';
      case 'unsupported_payment_method':
        return 'This payment method is not available for delivery yet.';
      case 'payment_failed':
        return 'Payment was not completed. You can try sending your dispatch again.';
      case 'identity_selfie_missing':
      case 'identity_pending_review':
      case 'identity_rejected':
      case 'identity_phone_not_verified':
      case 'identity_gate_unavailable':
      case 'identity_denied':
        return riderIdentityServerRejectionUserMessage(reason) ??
            'Identity verification required before dispatch.';
      default:
        return 'Unable to send your dispatch request right now.';
    }
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

  /// Shows a profile-completion block with a direct "Edit profile" action.
  void _promptCompleteProfile(String riderId, String message) {
    if (!mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) {
      return;
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: 'Edit profile',
            onPressed: () {
              RiderProfileEditScreen.open(context, riderId: riderId);
            },
          ),
        ),
      );
  }

  String _dispatchPackagePhotoUrl(Map<String, dynamic>? request) {
    final top =
        request?['package_photo_url']?.toString().trim() ??
        request?['packagePhotoUrl']?.toString().trim() ??
        '';
    if (top.isNotEmpty) {
      return top;
    }
    final dispatchDetails = _asStringDynamicMap(request?['dispatch_details']);
    final nestedUrl =
        dispatchDetails?['packagePhotoUrl']?.toString().trim() ?? '';
    if (nestedUrl.isNotEmpty) {
      return nestedUrl;
    }
    return request?['packagePhotoUrl']?.toString().trim() ?? '';
  }

  String _dispatchRecipientSummary(Map<String, dynamic>? request) {
    final topName =
        request?['recipient_name']?.toString().trim() ??
        request?['recipientName']?.toString().trim() ??
        '';
    final topPhone =
        request?['recipient_phone']?.toString().trim() ??
        request?['recipientPhone']?.toString().trim() ??
        '';
    if (topName.isNotEmpty || topPhone.isNotEmpty) {
      return <String>[
        if (topName.isNotEmpty) topName,
        if (topPhone.isNotEmpty) topPhone,
      ].join(' • ');
    }
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
        _showMessage(
          'Camera permission denied. Opening your photo gallery instead.',
        );
        final galleryImage = await _dispatchPhotoPicker.pickImage(
          source: ImageSource.gallery,
          maxWidth: 1800,
          imageQuality: 88,
        );
        if (galleryImage == null) {
          return null;
        }
        return DispatchPhotoSelectedAsset(
          localPath: galleryImage.path,
          fileName: galleryImage.name.isNotEmpty
              ? galleryImage.name
              : galleryImage.path.split('/').last,
          mimeType: _mimeTypeForPath(galleryImage.path),
          fileSizeBytes: File(galleryImage.path).lengthSync(),
          source: 'gallery',
        );
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
                _safeNavigatorPop(sheetContext, source);
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
                          _safeNavigatorPop(dialogContext);
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
    _activeRequestSubscription = _deliveryRequestsRef
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
              final unpaidTimedOut =
                  await _cancelUnpaidAssignedDispatchIfNeeded(requestId, data);
              if (unpaidTimedOut) {
                return;
              }
            }

            if (!mounted) {
              return;
            }

            setState(() {
              _activeRequestId = requestId;
              _activeRequest = data;
              if (data != null &&
                  DeliveryStateMachine.snapshotShowsAssignedDriver(data)) {
                _submitting = false;
                _loading = false;
                _startDeliveryChatListener(requestId);
                _ensureDeliveryCallListener(requestId);
                _syncDeliveryWaitFeePolling(data, requestId);
              }
            });
            if (data != null &&
                DeliveryStateMachine.snapshotShowsAssignedDriver(data) &&
                !_deliveryPaymentVerified(data) &&
                _paymentPromptedForDeliveryId != requestId) {
              _paymentPromptedForDeliveryId = requestId;
              unawaited(_collectPaymentAfterDriverAssigned(requestId, data));
            }
            if (data != null &&
                DeliveryStateMachine.canonicalStateFromSnapshot(data) ==
                    DeliveryLifecycleState.completed &&
                _ratingPromptedForDeliveryId != requestId) {
              _ratingPromptedForDeliveryId = requestId;
              unawaited(_promptRiderDeliveryRating(requestId));
            }
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

  Future<bool> _releaseExpiredAssignedDispatchRequestIfNeeded(
    String requestId,
    Map<String, dynamic>? request,
  ) async {
    // Client-side RTDB transactions for assignment release are disabled; lifecycle
    // is enforced by Cloud Functions.
    return false;
  }

  int _unpaidPaymentDeadlineAt(Map<String, dynamic>? request) {
    if (request == null) {
      return 0;
    }
    for (final key in <String>['payment_deadline_at', 'paymentDeadlineAt']) {
      final value = _parseTimestamp(request[key]);
      if (value > 0) {
        return value;
      }
    }
    return 0;
  }

  bool _unpaidAssignedPaymentPastDeadline(Map<String, dynamic>? request) {
    if (request == null || _deliveryPaymentVerified(request)) {
      return false;
    }
    final deadline = _unpaidPaymentDeadlineAt(request);
    if (deadline <= 0) {
      return false;
    }
    final state = DeliveryStateMachine.canonicalStateFromSnapshot(request);
    if (state != DeliveryLifecycleState.driverAssigned) {
      return false;
    }
    return DateTime.now().millisecondsSinceEpoch >= deadline;
  }

  Future<bool> _cancelUnpaidAssignedDispatchIfNeeded(
    String requestId,
    Map<String, dynamic>? request,
  ) async {
    if (!_unpaidAssignedPaymentPastDeadline(request)) {
      return false;
    }
    try {
      await _deliveryCloud.cancelDeliveryRequest(
        deliveryId: requestId,
        cancelReason: 'payment_timeout',
      );
    } catch (error) {
      debugPrint('[Dispatch] unpaid payment timeout cancel failed: $error');
      return false;
    }
    if (!mounted) {
      return true;
    }
    setState(() {
      _activeRequestId = null;
      _activeRequest = null;
      _paymentPromptedForDeliveryId = null;
    });
    _showMessage(
      'Payment was not completed in time. This delivery was cancelled.',
    );
    debugPrint(
      '[Dispatch] unpaid payment timeout requestId=$requestId',
    );
    return true;
  }

  Future<void> _promptRiderDeliveryRating(String deliveryId) async {
    if (!mounted) {
      return;
    }
    final result = await showDeliveryRatingSheet(
      context,
      title: 'Rate your biker',
      subtitle: 'How was this delivery?',
    );
    if (result == null || !mounted) {
      return;
    }
    try {
      final res = await _deliveryCloud.submitDeliveryRating(
        deliveryId: deliveryId,
        rating: result.rating,
        comment: result.comment.isNotEmpty ? result.comment : null,
      );
      if (!riderDeliveryCallableSucceeded(res)) {
        final reason = riderDeliveryCallableReason(res);
        if (reason != 'rating_duplicate') {
          _showMessage('Could not save rating ($reason).');
        }
      }
    } catch (error) {
      debugPrint('[Dispatch] rider rating failed: $error');
    }
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

    Map<String, dynamic>? expireRes;
    try {
      expireRes = await _deliveryCloud.expireDeliveryRequest(
        deliveryId: requestId,
      );
    } catch (_) {}
    if (!riderDeliveryCallableSucceeded(expireRes)) {
      try {
        await _deliveryCloud.cancelDeliveryRequest(
          deliveryId: requestId,
          cancelReason: 'no_drivers_available',
        );
      } catch (_) {}
    }
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

  Future<LatLng?> _resolvePlaceLocation({
    required NativePlaceSuggestion suggestion,
    required String description,
  }) async {
    if (!suggestion.isManualSuggestion && suggestion.placeId.isNotEmpty) {
      final details = await _nativePlaces.fetchPlaceDetails(suggestion.placeId);
      if (details != null &&
          details.latitude != 0 &&
          details.longitude != 0) {
        return LatLng(details.latitude, details.longitude);
      }
    }
    for (final query in RiderLaunchScope.buildSearchQueries(
      description,
      preferredCity: _selectedLaunchCity,
    )) {
      try {
        final locations = await locationFromAddress(query);
        if (locations.isNotEmpty) {
          final location = locations.first;
          return LatLng(location.latitude, location.longitude);
        }
      } catch (_) {}
    }
    return null;
  }

  void _onPickupAddressEdited() {
    if (_applyingDispatchPlace) {
      return;
    }
    _pickupLocation = null;
  }

  void _onDropoffAddressEdited() {
    if (_applyingDispatchPlace) {
      return;
    }
    _dropoffLocation = null;
  }

  Future<void> _handleDispatchPlaceSelection({
    required NativePlaceSuggestion suggestion,
    required bool isPickup,
  }) async {
    final description = suggestion.fullText.trim();
    if (description.isEmpty) {
      return;
    }
    final point = await _resolvePlaceLocation(
      suggestion: suggestion,
      description: description,
    );
    if (point == null) {
      _showMessage('Unable to resolve that location. Try another suggestion.');
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _applyingDispatchPlace = true;
      if (isPickup) {
        _pickupController.text = description;
        _pickupLocation = point;
      } else {
        _dropoffController.text = description;
        _dropoffLocation = point;
      }
      _applyingDispatchPlace = false;
    });
    unawaited(_refreshDispatchFarePreview());
  }

  String? _dispatchMarketSlug() {
    if (_rolloutSelectionComplete &&
        (_rolloutDispatchMarketId ?? '').trim().isNotEmpty) {
      final dm =
          RiderServiceAreaConfig.marketForCity(_rolloutDispatchMarketId).city;
      return normalizeRideMarketSlug(dm) ?? dm.trim().toLowerCase();
    }
    return null;
  }

  Future<void> _loadDeliveryDiscountOptions({required int baseAmountNgn}) async {
    if (baseAmountNgn <= 0) return;
    setState(() => _deliveryDiscountsLoading = true);
    try {
      final res = await _rideCloud.listRiderDiscounts(
        appliesTo: 'delivery',
        baseAmountNgn: baseAmountNgn,
      );
      if (!mounted) return;
      final options = <RiderDiscountOption>[];
      if (res['success'] == true && res['discounts'] is List) {
        for (final row in res['discounts'] as List) {
          if (row is Map) {
            final opt = RiderDiscountOption.fromMap(
              Map<String, dynamic>.from(row),
            );
            if (opt.discountId.isNotEmpty) {
              options.add(opt);
            }
          }
        }
      }
      setState(() {
        _deliveryDiscountOptions = options;
        _deliveryDiscountsLoading = false;
        if (_selectedDeliveryDiscountId != null &&
            !options.any((o) => o.discountId == _selectedDeliveryDiscountId)) {
          _selectedDeliveryDiscountId = null;
        }
      });
    } catch (_) {
      if (mounted) setState(() => _deliveryDiscountsLoading = false);
    }
  }

  Future<void> _refreshDispatchFarePreview() async {
    final pickup = _pickupLocation;
    final dropoff = _dropoffLocation;
    final dispatchSlug = _dispatchMarketSlug();
    if (pickup == null || dropoff == null || dispatchSlug == null) {
      return;
    }
    final distanceKm =
        Geolocator.distanceBetween(
          pickup.latitude,
          pickup.longitude,
          dropoff.latitude,
          dropoff.longitude,
        ) /
        1000;
    if (distanceKm <= 0) return;
    final etaMin = estimateRiderDurationMinutes(distanceKm: distanceKm);
    if (mounted) setState(() => _dispatchQuoteLoading = true);
    try {
      final quoteRes = await _deliveryCloud
          .quoteDeliveryFare(
            market: dispatchSlug,
            distanceKm: distanceKm,
            etaMin: etaMin,
            discountId: _selectedDeliveryDiscountId,
          )
          .timeout(const Duration(seconds: 20));
      final dispatchQuote =
          RiderBackendPricingQuote.tryFromDeliveryQuoteResponse(
        quoteRes,
        market: dispatchSlug,
        distanceKm: distanceKm,
        etaMin: etaMin,
      );
      if (!mounted) return;
      setState(() {
        _dispatchFarePreview = dispatchQuote;
        _dispatchQuoteLoading = false;
        if (_selectedDeliveryDiscountId != null &&
            dispatchQuote?.showsDiscount != true) {
          _selectedDeliveryDiscountId = null;
        }
      });
      if (dispatchQuote != null) {
        unawaited(
          _loadDeliveryDiscountOptions(
            baseAmountNgn: dispatchQuote.preDiscountSubtotalNgn,
          ),
        );
      }
    } catch (_) {
      if (mounted) setState(() => _dispatchQuoteLoading = false);
    }
  }

  Future<void> _handleSelectDeliveryDiscount(RiderDiscountOption option) async {
    setState(() => _selectedDeliveryDiscountId = option.discountId);
    await _refreshDispatchFarePreview();
  }

  Future<void> _handleClearDeliveryDiscount() async {
    setState(() => _selectedDeliveryDiscountId = null);
    await _refreshDispatchFarePreview();
  }

  Future<({double lat, double lng})> _resolveDispatchPoint({
    required String address,
    required LatLng? selected,
    required String label,
  }) async {
    if (selected != null) {
      return (lat: selected.latitude, lng: selected.longitude);
    }
    try {
      return await _resolveCoordinates(address);
    } on FormatException {
      throw FormatException('address_not_found:$label');
    }
  }

  String _fleetOperatorLabel(Map<String, dynamic>? request) {
    if (request == null) {
      return '';
    }
    final ownerName = request['fleet_owner_name']?.toString().trim() ??
        request['fleetOwnerName']?.toString().trim() ??
        '';
    if (ownerName.isEmpty) {
      return '';
    }
    return 'Fleet operator: $ownerName';
  }

  String _dispatchDriverPhone(Map<String, dynamic>? request) {
    if (request == null) {
      return '';
    }
    for (final key in <String>[
      'assigned_driver_phone',
      'driver_phone',
      'driverPhone',
    ]) {
      final v = request[key]?.toString().trim() ?? '';
      if (v.length >= 8) {
        return v;
      }
    }
    return '';
  }

  Future<void> _callDispatchDriverPhone() async {
    final phone = _dispatchDriverPhone(_activeRequest);
    if (phone.isEmpty) {
      _showMessage('Driver phone is not available yet.');
      return;
    }
    final uri = Uri(scheme: 'tel', path: phone);
    if (!await canLaunchUrl(uri)) {
      _showMessage('Could not start a phone call on this device.');
      return;
    }
    await launchUrl(uri);
  }

  Future<void> _cancelActiveDispatchDelivery() async {
    final deliveryId = _activeRequestId?.trim();
    if (deliveryId == null || deliveryId.isEmpty) {
      return;
    }
    final state = DeliveryStateMachine.canonicalStateFromSnapshot(_activeRequest);
    final paid = _activeRequest != null && _deliveryPaymentVerified(_activeRequest!);
    final afterPickup = state == DeliveryLifecycleState.pickedUp ||
        state == DeliveryLifecycleState.onDelivery ||
        state == DeliveryLifecycleState.arrivedDropoff;
    final picked = await showDeliveryCancelReasonSheet(
      context: context,
      title: afterPickup ? 'Why request cancellation?' : 'Why cancel delivery?',
      options: riderDeliveryCancelReasons,
    );
    if (picked == null || !mounted) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(afterPickup ? 'Request cancellation?' : 'Cancel delivery?'),
        content: Text(
          afterPickup
              ? 'Your package is already picked up. Support will review your request.'
              : paid
                  ? 'Payment was verified. Cancelling before pickup may queue a refund review.'
                  : 'Cancel this delivery? The assigned biker will be released.',
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(afterPickup ? 'Request cancel' : 'Cancel delivery'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    try {
      final res = await _deliveryCloud.cancelDeliveryRequest(
        deliveryId: deliveryId,
        cancelReason: afterPickup ? 'request_cancel' : picked.code,
        cancelReasonCode: picked.code,
        cancelReasonText: picked.text,
        cancelNote: picked.note,
        requestOnly: afterPickup,
      );
      if (!riderDeliveryCallableSucceeded(res)) {
        _showMessage(
          'Could not cancel (${riderDeliveryCallableReason(res)}).',
        );
        return;
      }
      final reason = riderDeliveryCallableReason(res);
      if (reason == 'delivery_cancel_requested') {
        _showMessage('Cancellation request sent to your biker.');
      } else {
        _showMessage('Delivery cancelled.');
        setState(() {
          _activeRequestId = null;
          _activeRequest = null;
        });
      }
    } catch (error) {
      _showMessage('Could not cancel delivery: $error');
    }
  }

  Future<void> _shareActiveDeliveryLink({Rect? sharePositionOrigin}) async {
    final deliveryId = _activeRequestId?.trim();
    if (deliveryId == null || deliveryId.isEmpty || _sharingDeliveryLink) {
      return;
    }
    setState(() => _sharingDeliveryLink = true);
    try {
      final trackToken =
          _activeRequest?['track_token']?.toString().trim() ?? '';
      String shareUrl;
      if (trackToken.isNotEmpty) {
        shareUrl = 'https://nexride.africa/track/$trackToken';
        debugPrint('DELIVERY_SHARE_TOKEN_SUCCESS deliveryId=$deliveryId reused=true');
      } else {
        final tokenResp =
            await _rideCloud.createTripShareToken(deliveryId: deliveryId);
        if (!riderRideCallableSucceeded(tokenResp)) {
          debugPrint(
            'DELIVERY_SHARE_FAIL deliveryId=$deliveryId reason=${riderRideCallableReason(tokenResp)}',
          );
          _showMessage(
            'Unable to create a live tracking link (${riderRideCallableReason(tokenResp)}).',
          );
          return;
        }
        shareUrl = tokenResp['share_url']?.toString().trim() ??
            'https://nexride.africa/track/${tokenResp['track_token']?.toString().trim() ?? ''}';
        debugPrint('DELIVERY_SHARE_TOKEN_SUCCESS deliveryId=$deliveryId reused=false');
      }
      final origin = safeShareOrigin(context, override: sharePositionOrigin);
      debugPrint('DELIVERY_SHARE_SHEET_OPEN deliveryId=$deliveryId');
      await Share.share(
        'Track this NexRide delivery live: $shareUrl',
        subject: 'NexRide delivery tracking',
        sharePositionOrigin: origin,
      );
    } catch (error) {
      debugPrint('DELIVERY_SHARE_FAIL deliveryId=$deliveryId reason=$error');
      _showMessage('Unable to share live tracking right now ($error).');
    } finally {
      if (mounted) {
        setState(() => _sharingDeliveryLink = false);
      }
    }
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

  String _dispatchMatchingStatusLabel(Map<String, dynamic>? request) {
    if (request == null || request.isEmpty) {
      return DeliveryStateMachine.uiStatusLabel(DeliveryLifecycleState.searching);
    }
    final state = DeliveryStateMachine.canonicalStateFromSnapshot(request);
    if (state == DeliveryLifecycleState.searching) {
      final matchDebug = request['match_debug'];
      if (matchDebug is Map) {
        final offersWritten = matchDebug['offers_written'];
        if (offersWritten is num && offersWritten.toInt() == 0) {
          return 'No nearby dispatch driver yet. We are still searching.';
        }
      }
    }
    return DeliveryStateMachine.uiStatusLabel(state);
  }

  String _statusLabel(String status) {
    if (_activeRequest != null && _activeRequest!.isNotEmpty) {
      return _dispatchMatchingStatusLabel(_activeRequest);
    }
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

  Future<void> _collectPaymentAfterDriverAssigned(
    String deliveryId,
    Map<String, dynamic> row,
  ) async {
    if (_deliveryPaymentVerified(row)) {
      return;
    }
    if (!mounted) {
      return;
    }
    _showMessage('Driver assigned — complete payment to continue.');
    try {
      if (_dispatchPaymentMethod == 'bank_transfer') {
        final bankReg = await _rideCloud
            .registerBankTransferPayment(deliveryId: deliveryId)
            .timeout(const Duration(seconds: 45));
        if (bankReg['success'] != true) {
          _showMessage(
            riderRideCallableUserMessage(Map<String, dynamic>.from(bankReg)),
          );
          return;
        }
        final autoVa =
            bankReg['automated_va'] == true ||
            bankReg['automated_va'] == 'true' ||
            bankReg['automated_va'] == 1;
        if (autoVa && mounted) {
          await showModalBottomSheet<bool>(
            context: context,
            isScrollControlled: true,
            showDragHandle: true,
            builder: (ctx) => RiderFlutterwaveVaPaymentSheet(
              databaseRef: _deliveryRequestsRef.child(deliveryId),
              sheetTitle: 'Pay for dispatch',
              initialRegistration: Map<String, dynamic>.from(bankReg),
              onRegenerate: () => _rideCloud.registerBankTransferPayment(
                deliveryId: deliveryId,
              ),
            ),
          );
        }
      } else {
        await _runFlutterwaveDeliveryCheckout(
          deliveryId: deliveryId,
          deliveryRow: row,
        );
      }
    } catch (error) {
      debugPrint('DISPATCH_PAYMENT_AFTER_ASSIGN_FAIL error=$error');
      if (mounted) {
        _showMessage('Payment could not be started. Try again from this screen.');
      }
    }
  }

  Future<void> _submitDispatchRequest() async {
    debugPrint('DISPATCH_REQUEST_SUBMIT_START');
    if (_submitting || _uploadingPackagePhoto || _hasActiveRequest) {
      if (_uploadingPackagePhoto) {
        debugPrint('DISPATCH_SUBMIT_BLOCKED_PHOTO_UPLOAD');
      }
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
      debugPrint('DISPATCH_REQUEST_VALIDATION_FAIL reason=required_fields_missing');
      _showMessage('Pickup, dropoff, and package details are required.');
      return;
    }
    if (recipientName.isNotEmpty && recipientName.length < 2) {
      debugPrint('DISPATCH_REQUEST_VALIDATION_FAIL reason=recipient_name_invalid');
      _showMessage('Recipient name must be at least 2 characters or left blank.');
      return;
    }
    if (recipientPhone.isNotEmpty &&
        (recipientPhone.length < 8 || recipientPhone.length > 20)) {
      debugPrint('DISPATCH_REQUEST_VALIDATION_FAIL reason=recipient_phone_invalid');
      _showMessage('Enter a valid recipient phone (8–20 digits) or leave it blank.');
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _showMessage('Please log in again to send a request.');
      return;
    }

    final profileBlock = await RiderProfileRequirement.evaluate(user.uid);
    if (profileBlock != RiderProfileBlock.none) {
      final reason = profileBlock == RiderProfileBlock.missingPhone
          ? 'missing_phone'
          : 'missing_photo';
      debugPrint('PROFILE_REQUIREMENT_BLOCKED reason=$reason');
      _promptCompleteProfile(
        user.uid,
        RiderProfileRequirement.messageFor(
            profileBlock, 'send a delivery request'),
      );
      return;
    }

    if (_selfieBlocksBooking) {
      final msg = _riderFirestoreCompliance != null
          ? riderRequestButtonIdentityBlockSubtitle(_riderFirestoreCompliance!)
          : 'Complete identity verification before sending a delivery request.';
      _showMessage(msg);
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

    if (!_rolloutCatalogHydrated) {
      await _loadRolloutForDispatch();
    }
    if (_rolloutCatalogError != null) {
      _showMessage('Could not load service areas. Scroll up to retry.');
      return;
    }
    if (_rolloutCatalog.isEmpty) {
      _showMessage(RolloutCopy.notAvailableInArea);
      return;
    }
    if (!_rolloutSelectionComplete) {
      _showMessage('Select your service area before sending a request.');
      return;
    }
    try {
      final vr = await _rideCloud
          .validateServiceLocation(
            regionId: _rolloutRegionId!.trim(),
            cityId: _rolloutCityId!.trim(),
            service: 'package',
          )
          .timeout(const Duration(seconds: 20));
      if (!riderRideCallableSucceeded(vr)) {
        _showMessage(RolloutCopy.notAvailableInArea);
        return;
      }
    } catch (e) {
      _showMessage(
        'Could not verify your area. Check connection and try again.',
      );
      return;
    }

    setState(() {
      _submitting = true;
      _packagePhotoUploadProgress = packagePhotoAsset == null ? 0 : 0.05;
    });

    debugPrint('[Dispatch] submit tapped');

    try {
      final pickup = await _resolveDispatchPoint(
        address: pickupAddress,
        selected: _pickupLocation,
        label: 'pickup',
      );
      final dropoff = await _resolveDispatchPoint(
        address: dropoffAddress,
        selected: _dropoffLocation,
        label: 'dropoff',
      );
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
      var dispatchSlug =
          normalizeRideMarketSlug(dispatchMarket) ?? dispatchMarket.trim().toLowerCase();
      if (_rolloutSelectionComplete &&
          (_rolloutDispatchMarketId ?? '').trim().isNotEmpty) {
        final dm =
            RiderServiceAreaConfig.marketForCity(_rolloutDispatchMarketId).city;
        dispatchSlug = normalizeRideMarketSlug(dm) ?? dm.trim().toLowerCase();
      }

      final photoUploadKey =
          'pending_${user.uid}_${DateTime.now().millisecondsSinceEpoch}';

      DispatchUploadedPhoto? uploadedPackagePhoto;
      if (packagePhotoAsset != null) {
        debugPrint('DISPATCH_PHOTO_UPLOAD_START');
        if (mounted) {
          setState(() {
            _uploadingPackagePhoto = true;
            _packagePhotoUploadProgress = 0.08;
          });
        }
        try {
          uploadedPackagePhoto = await _dispatchPhotoUploadService
              .uploadRidePhoto(
                rideId: photoUploadKey,
                actorId: user.uid,
                category: 'package_photo',
                asset: packagePhotoAsset,
                onProgress: (double progress) {
                  final clamped = progress.clamp(0.08, 0.94);
                  if (!mounted) {
                    _packagePhotoUploadProgress = clamped;
                    return;
                  }
                  setState(() {
                    _packagePhotoUploadProgress = clamped;
                  });
                },
              )
              .timeout(const Duration(seconds: 90));
          debugPrint(
            'DISPATCH_PHOTO_UPLOAD_SUCCESS '
            'bytes=${uploadedPackagePhoto.fileSizeBytes}',
          );
          if (mounted) {
            setState(() => _packagePhotoUploadProgress = 1);
          }
        } on TimeoutException {
          debugPrint('DISPATCH_PHOTO_UPLOAD_FAIL reason=timeout');
          throw StateError('package_photo_upload_timeout');
        } catch (error, stackTrace) {
          debugPrint('DISPATCH_PHOTO_UPLOAD_FAIL error=$error');
          debugPrintStack(
            label: 'DISPATCH_PHOTO_UPLOAD_FAIL',
            stackTrace: stackTrace,
          );
          throw StateError('package_photo_upload_failed');
        } finally {
          if (mounted) {
            setState(() => _uploadingPackagePhoto = false);
          } else {
            _uploadingPackagePhoto = false;
          }
        }
      }

      final distanceKm =
          Geolocator.distanceBetween(
            pickup.lat,
            pickup.lng,
            dropoff.lat,
            dropoff.lng,
          ) /
          1000;
      final etaMin = estimateRiderDurationMinutes(distanceKm: distanceKm);
      final quoteRes = await _deliveryCloud
          .quoteDeliveryFare(
            market: dispatchSlug,
            distanceKm: distanceKm,
            etaMin: etaMin,
            discountId: _selectedDeliveryDiscountId,
          )
          .timeout(const Duration(seconds: 20));
      final dispatchQuote =
          RiderBackendPricingQuote.tryFromDeliveryQuoteResponse(quoteRes);
      if (dispatchQuote == null || dispatchQuote.tripFareNgn <= 0) {
        debugPrint(
          '[RIDER_DELIVERY_QUOTE_FAIL] market=$dispatchSlug '
          'distance_km=$distanceKm eta_min=$etaMin response=$quoteRes',
        );
        throw StateError(
          'Could not load delivery pricing. Check your connection and try again.',
        );
      }
      final tripFareNgn = dispatchQuote.tripFareNgn;
      final bookingFeeNgn = dispatchQuote.platformFeeNgn;
      final totalNgn = dispatchQuote.totalNgn > 0
          ? dispatchQuote.totalNgn
          : tripFareNgn + bookingFeeNgn;
      if (mounted) {
        setState(() => _dispatchFarePreview = dispatchQuote);
      }
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
      final pickupScope = _buildServiceAreaFields(city: dispatchSlug, area: pickupArea);
      final destinationScope = _buildServiceAreaFields(
        city: dispatchSlug,
        area: destinationArea,
      );
      final packagePhotoUrl = uploadedPackagePhoto?.fileUrl ?? '';

      final pickupPayload = <String, dynamic>{
        'lat': pickup.lat,
        'lng': pickup.lng,
        'address': pickupAddress,
        ...pickupScope,
      };
      final dropoffPayload = <String, dynamic>{
        'lat': dropoff.lat,
        'lng': dropoff.lng,
        'address': dropoffAddress,
        ...destinationScope,
      };

      rtdbFlowLog(
        '[NEXRIDE_RIDER_RTDB][DELIVERY_CREATE_CALLABLE]',
        'uid=${user.uid} market_pool=$dispatchSlug',
      );
      debugPrint(
        '[RIDER_DELIVERY_CREATE] rider_id=${user.uid} market=$dispatchSlug '
        'trip_fare=$tripFareNgn booking_fee=$bookingFeeNgn total_ngn=$totalNgn '
        'distance_km=$distanceKm eta_min=$etaMin',
      );
      debugPrint('DISPATCH_CREATE_CALL_START delivery market=$dispatchSlug');
      final createRes = await _deliveryCloud
          .createDeliveryRequest(<String, dynamic>{
            'market': dispatchSlug,
            if (_rolloutSelectionComplete) ...<String, dynamic>{
              'service_region_id': _rolloutRegionId!.trim(),
              'service_city_id': _rolloutCityId!.trim(),
              'rollout_region_id': _rolloutRegionId!.trim(),
              'rollout_city_id': _rolloutCityId!.trim(),
            },
            'pickup': pickupPayload,
            'dropoff': dropoffPayload,
            'fare': tripFareNgn,
            'trip_fare_ngn': tripFareNgn,
            'delivery_fee_ngn': tripFareNgn,
            'booking_fee_ngn': bookingFeeNgn,
            'platform_fee_ngn': bookingFeeNgn,
            'total_ngn': totalNgn,
            if (_selectedDeliveryDiscountId != null)
              'discount_id': _selectedDeliveryDiscountId,
            if (dispatchQuote.discountAppliedNgn > 0)
              'discount_applied_ngn': dispatchQuote.discountAppliedNgn,
            'currency': 'NGN',
            'distance_km': double.parse(distanceKm.toStringAsFixed(2)),
            'eta_min': double.parse(etaMin.toStringAsFixed(2)),
            'eta_minutes': double.parse(etaMin.toStringAsFixed(2)),
            'payment_method':
                _dispatchPaymentMethod == 'bank_transfer'
                    ? 'bank_transfer'
                    : 'flutterwave',
            'package_description': packageDetails,
            if (recipientName.isNotEmpty) 'recipient_name': recipientName,
            if (recipientPhone.isNotEmpty) 'recipient_phone': recipientPhone,
            'category': 'parcel',
            if (packagePhotoUrl.isNotEmpty) 'package_photo_url': packagePhotoUrl,
          })
          .timeout(const Duration(seconds: 45));
      debugPrint(
        'DISPATCH_CREATE_CALL_RESPONSE success=${createRes['success']} reason=${createRes['reason']}',
      );
      if (!riderDeliveryCallableSucceeded(createRes)) {
        final reason = riderDeliveryCallableReason(createRes);
        debugPrint(
          'DISPATCH_CREATE_CALL_FAIL reason=$reason response=$createRes',
        );
        final serverMsg = createRes['message']?.toString().trim();
        final mapped = _deliveryCreateUserMessage(reason);
        final detail = serverMsg?.isNotEmpty == true &&
                mapped == 'Unable to send your dispatch request right now.'
            ? serverMsg!
            : mapped;
        throw StateError(detail);
      }
      final effectiveRequestId =
          (createRes['deliveryId'] ?? createRes['delivery_id'] ?? '')
              .toString()
              .trim();
      if (effectiveRequestId.isEmpty) {
        throw StateError('delivery_id_missing');
      }
      final liveSnap =
          await _deliveryRequestsRef.child(effectiveRequestId).get();
      if (!liveSnap.exists) {
        throw StateError('dispatch_missing_after_create');
      }
      final livePayload = _asStringDynamicMap(liveSnap.value);
      if (livePayload == null) {
        throw StateError('dispatch_invalid_after_create');
      }
      final workingPayload = Map<String, dynamic>.from(livePayload);
      debugPrint('[Dispatch] delivery created deliveryId=$effectiveRequestId');
      await _tripSafetyService.registerRideRequest(
        rideId: effectiveRequestId,
        riderId: user.uid,
        serviceType: RiderServiceType.dispatchDelivery.key,
        ridePayload: workingPayload,
        expectedRoutePoints: <LatLng>[
          LatLng(pickup.lat, pickup.lng),
          LatLng(dropoff.lat, dropoff.lng),
        ],
      );

      await _watchRequest(effectiveRequestId);

      if (!mounted) {
        return;
      }

      setState(() {
        _activeRequestId = effectiveRequestId;
        _activeRequest = workingPayload;
      });

      _showMessage(
        'Dispatch request sent. Bikers nearby will be notified.',
      );
    } on FormatException catch (error) {
      debugPrint('DISPATCH_REQUEST_GEO_FAIL message=${error.message}');
      final message = switch (error.message) {
        'unsupported_city' => RiderLaunchScope.tripRequestAvailabilityMessage,
        'address_not_found:pickup' =>
          'Pickup address could not be found. Choose a suggestion or enter a clearer address.',
        'address_not_found:dropoff' =>
          'Dropoff address could not be found. Choose a suggestion or enter a clearer address.',
        'address_not_found' =>
          'Pickup or dropoff address could not be found. Choose a suggestion from the list.',
        _ => 'Please use clearer pickup and dropoff addresses.',
      };
      if (!mounted) {
        return;
      }
      _showMessage(message);
    } catch (error, stackTrace) {
      debugPrint('DISPATCH_CREATE_CALL_FAIL error=$error');
      debugPrint('[Dispatch] submit failed: $error');
      debugPrintStack(label: '[Dispatch] submit stack', stackTrace: stackTrace);
      if (!mounted) {
        return;
      }
      final message = error is StateError
          ? (error.message?.trim().isNotEmpty == true
              ? error.message!.trim()
              : 'Unable to send your dispatch request right now.')
          : friendlyFirebaseError(error, debugLabel: 'dispatchSubmit');
      _showMessage(message);
    } finally {
      _submitting = false;
      _uploadingPackagePhoto = false;
      _packagePhotoUploadProgress = 0;
      debugPrint('DISPATCH_SUBMIT_RECOVERED');
      if (mounted) {
        setState(() {
          _loading = false;
        });
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
      _dispatchFarePreview = null;
      _deliveryDiscountOptions = <RiderDiscountOption>[];
      _selectedDeliveryDiscountId = null;
      _packagePhotoAsset = null;
      _packagePhotoUploadProgress = 0;
    });
    _pickupController.clear();
    _dropoffController.clear();
    _pickupLocation = null;
    _dropoffLocation = null;
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
          if (_uploadingPackagePhoto && selectedAsset != null) ...<Widget>[
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
          ] else if (_submitting && selectedAsset != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              'Sending dispatch request...',
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
              onPressed: (_submitting || _uploadingPackagePhoto)
                  ? null
                  : _selectPackagePhoto,
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
                    onPressed: (_submitting || _uploadingPackagePhoto)
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
                    onPressed: (_submitting || _uploadingPackagePhoto)
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

  void _syncDeliveryWaitFeePolling(
    Map<String, dynamic>? data,
    String deliveryId,
  ) {
    final state = DeliveryStateMachine.canonicalStateFromSnapshot(data);
    final shouldPoll =
        state == DeliveryLifecycleState.driverArrivingPickup;
    if (!shouldPoll) {
      _deliveryWaitFeePollTimer?.cancel();
      _deliveryWaitFeePollTimer = null;
      return;
    }
    _deliveryWaitFeePollTimer ??= Timer.periodic(
      const Duration(seconds: 30),
      (_) async {
        try {
          await _deliveryCloud.applyDeliveryWaitFee(deliveryId: deliveryId);
        } catch (e) {
          debugPrint(
            'DELIVERY_WAIT_FEE_POLL_FAIL deliveryId=$deliveryId reason=$e',
          );
        }
      },
    );
    unawaited(
      _deliveryCloud.applyDeliveryWaitFee(deliveryId: deliveryId).catchError(
        (Object e) {
          debugPrint(
            'DELIVERY_WAIT_FEE_POLL_FAIL deliveryId=$deliveryId reason=$e',
          );
          return <String, dynamic>{};
        },
      ),
    );
  }

  Future<String?> _sendDeliveryChatImage(
    String deliveryId,
    RideChatImageSource source,
  ) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return 'Please log in before sending a photo.';
    }
    final useCamera = source == RideChatImageSource.camera;
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
      actorId: user.uid,
    );
    try {
      final uploaded = await _dispatchPhotoUploadService.uploadDeliveryChatPhoto(
        deliveryId: deliveryId,
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
      return _deliveryChatService.sendImage(
        deliveryId: deliveryId,
        imageUrl: uploaded.fileUrl,
      );
    } catch (e) {
      return 'Unable to send this image right now.';
    }
  }

  void _startDeliveryChatListener(String deliveryId) {
    _deliveryChatSubscription?.cancel();
    _deliveryChatSubscription = _deliveryChatService.startListener(
      deliveryId: deliveryId,
      onMessages: (messages) {
        if (mounted) {
          _deliveryChatMessages.value = messages;
        }
      },
      onError: (error) {
        debugPrint('[Dispatch] chat listener error: $error');
      },
    );
  }

  Future<void> _openDeliveryChat() async {
    final deliveryId = _activeRequestId;
    final user = FirebaseAuth.instance.currentUser;
    if (deliveryId == null || user == null) {
      return;
    }
    if (!mounted) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      builder: (ctx) {
        return SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.75,
          child: DeliveryChatSheet(
            deliveryId: deliveryId,
            currentUserId: user.uid,
            messagesListenable: _deliveryChatMessages,
            onSendMessage: (id, text) => _deliveryChatService.sendText(
              deliveryId: id,
              senderRole: 'customer',
              text: text,
            ),
            onRetryMessage: (id, msg) => _deliveryChatService.sendText(
              deliveryId: id,
              senderRole: 'customer',
              text: msg.text,
              retryMessageId: msg.id,
            ),
            onSendImage: _sendDeliveryChatImage,
            onStartVoiceCall: () => unawaited(_startDeliveryCall()),
            showCallButton: DeliveryStateMachine.snapshotShowsAssignedDriver(
              _activeRequest,
            ),
            isCallButtonEnabled: !_isStartingDeliveryCall,
            isCallButtonBusy: _isStartingDeliveryCall,
          ),
        );
      },
    );
  }

  void _ensureDeliveryCallListener(String deliveryId) {
    final user = FirebaseAuth.instance.currentUser;
    final driverId = DeliveryStateMachine.canonicalAssignedDriverId(
      _activeRequest,
    );
    if (user == null || driverId.isEmpty) {
      return;
    }
    _deliveryCallUi.attach(
      deliveryId: deliveryId,
      riderUid: user.uid,
      driverId: driverId,
    );
  }

  Future<void> _startDeliveryCall() async {
    final deliveryId = _activeRequestId;
    if (deliveryId == null ||
        _isStartingDeliveryCall ||
        !isActiveDeliveryCallEligible(
          deliveryId: deliveryId,
          delivery: _activeRequest,
        )) {
      _showMessage('In-app call is not available yet.');
      return;
    }
    try {
      await _deliveryCallUi.startOutgoingCall(
        deliveryId: deliveryId,
        delivery: _activeRequest,
      );
    } on RideCallException catch (e) {
      debugPrint('DELIVERY_CALL_FAIL deliveryId=$deliveryId reason=$e');
      _showMessage(e.message);
    } catch (e) {
      debugPrint('DELIVERY_CALL_FAIL deliveryId=$deliveryId reason=$e');
      final phone = _dispatchDriverPhone(_activeRequest);
      if (!mounted) {
        return;
      }
      final usePhone = phone.isNotEmpty
          ? await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('In-app call failed'),
                content: Text(
                  'Could not connect in the app ($e). Call the driver by phone instead?',
                ),
                actions: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Call by phone'),
                  ),
                ],
              ),
            )
          : false;
      if (usePhone == true) {
        await _callDispatchDriverPhone();
      } else {
        _showMessage('Call could not start: $e');
      }
    }
  }

  Future<void> _reportDeliveryIssue() async {
    final deliveryId = _activeRequestId;
    if (deliveryId == null) {
      return;
    }
    try {
      await _deliveryReportService.submitReport(
        deliveryId: deliveryId,
        reason: 'order_issue',
        message: 'Customer reported an issue from dispatch screen.',
        reporterRole: 'customer',
        customerId: FirebaseAuth.instance.currentUser?.uid,
        driverId: DeliveryStateMachine.canonicalAssignedDriverId(_activeRequest),
      );
      if (mounted) {
        _showMessage('Report submitted. Support will follow up.');
      }
    } catch (e) {
      if (mounted) {
        _showMessage('Could not submit report: $e');
      }
    }
  }

  Future<void> _reportVehicleMismatch({
    required String driverId,
    required String referenceId,
    required Map<String, dynamic> request,
    required DriverVehicleIdentity identity,
  }) async {
    final city = (request['city'] ?? request['market'] ?? '').toString().trim();
    await VehicleMismatchReportService.report(
      context: context,
      riderId: FirebaseAuth.instance.currentUser?.uid ?? '',
      driverId: driverId,
      referenceId: referenceId,
      isDelivery: true,
      identity: identity,
      city: city,
    );
  }

  Widget _buildActiveRequestCard() {
    final activeRequest = _activeRequest ?? <String, dynamic>{};
    final status = TripStateMachine.uiStatusFromSnapshot(activeRequest);
    final deliveryCanon =
        DeliveryStateMachine.canonicalStateFromSnapshot(activeRequest);
    final assignedDriverId =
        DeliveryStateMachine.canonicalAssignedDriverId(activeRequest);
    final dispatchDetails = _asStringDynamicMap(
      activeRequest['dispatch_details'],
    );
    final recipientSummary = _dispatchRecipientSummary(activeRequest);
    final packagePhotoUrl = _dispatchPackagePhotoUrl(activeRequest);
    final proofUrl = (activeRequest['delivery_proof_photo_url'] ??
            activeRequest['deliveryProofPhotoUrl'] ??
            '')
        .toString()
        .trim();
    final paymentPending = assignedDriverId.isNotEmpty &&
        !_deliveryPaymentVerified(activeRequest);
    final paymentBanner = paymentPending
        ? 'Driver assigned — complete payment to continue.'
        : null;
    final requestId = _activeRequestId ?? '';

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
          if (_activeRequestId != null)
            OutlinedButton.icon(
              onPressed: _sharingDeliveryLink
                  ? null
                  : () => unawaited(
                        _shareActiveDeliveryLink(
                          sharePositionOrigin: safeShareOrigin(context),
                        ),
                      ),
              icon: _sharingDeliveryLink
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.share_outlined),
              label: const Text('Share live tracking'),
            ),
          const SizedBox(height: 14),
          Text(
            'Request ID: ${_activeRequestId ?? ''}',
            style: TextStyle(
              fontSize: 12,
              color: Colors.black.withValues(alpha: 0.55),
            ),
          ),
          if (_deliveryWaitFeeNgn(activeRequest) > 0) ...<Widget>[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF8E1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFFFE082)),
              ),
              child: Text(
                'Waiting fee: ₦${_deliveryWaitFeeNgn(activeRequest)} '
                '(added to your delivery total)',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF5D4037),
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          DeliveryLiveTrackingPanel(
            deliveryData: activeRequest,
            statusLabel: _dispatchMatchingStatusLabel(activeRequest),
            fleetBusinessName:
                activeRequest['fleet_business_name']?.toString() ??
                    activeRequest['fleetBusinessName']?.toString(),
            fleetOperatorLabel: _fleetOperatorLabel(activeRequest),
            pickupLabel: activeRequest['pickup_address']?.toString() ?? '',
            dropoffLabel: activeRequest['destination_address']?.toString() ?? '',
            etaMinutes: activeRequest['eta_minutes'] is num
                ? (activeRequest['eta_minutes'] as num).toInt()
                : null,
            paymentPendingBanner: paymentBanner,
            deliveryProofPhotoUrl:
                deliveryCanon == DeliveryLifecycleState.completed &&
                        proofUrl.startsWith('https')
                    ? proofUrl
                    : null,
            onPayNow: paymentPending && requestId.isNotEmpty
                ? () => unawaited(
                      _collectPaymentAfterDriverAssigned(requestId, activeRequest),
                    )
                : null,
            showChat: DeliveryStateMachine.isChatEligible(activeRequest),
            showCall: assignedDriverId.isNotEmpty,
            onOpenChat: _openDeliveryChat,
            onCall: () => unawaited(_startDeliveryCall()),
            onReport: _reportDeliveryIssue,
          ),
          if (assignedDriverId.isNotEmpty &&
              deliveryCanon != DeliveryLifecycleState.completed &&
              deliveryCanon != DeliveryLifecycleState.cancelled) ...<Widget>[
            const SizedBox(height: 12),
            DriverSafetyCard(
              driverId: assignedDriverId,
              rideRecord: Map<String, dynamic>.from(activeRequest),
              isDelivery: true,
              onReportMismatch: (DriverVehicleIdentity identity) =>
                  unawaited(_reportVehicleMismatch(
                driverId: assignedDriverId,
                referenceId: requestId,
                request: activeRequest,
                identity: identity,
              )),
            ),
          ],
          if (deliveryCanon != DeliveryLifecycleState.completed &&
              deliveryCanon != DeliveryLifecycleState.cancelled) ...<Widget>[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _cancelActiveDispatchDelivery,
              icon: const Icon(Icons.cancel_outlined, color: Colors.redAccent),
              label: const Text(
                'Cancel delivery',
                style: TextStyle(color: Colors.redAccent),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Builder(
            builder: (context) {
              final pricing = RiderBackendPricingQuote.tryFromMap(activeRequest);
              if (pricing == null || !pricing.hasAuthoritativeTotal) {
                return const SizedBox.shrink();
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  RiderBackendPricingBreakdown(
                    quote: pricing,
                    tripFareLabel: 'Delivery fare',
                    compact: true,
                  ),
                  const SizedBox(height: 12),
                ],
              );
            },
          ),
          _DispatchInfoRow(
            icon: Icons.my_location,
            label: 'Pickup',
            value: activeRequest['pickup_address']?.toString().trim().isNotEmpty ==
                    true
                ? activeRequest['pickup_address'].toString()
                : (_asStringDynamicMap(activeRequest['pickup'])?['address']
                        ?.toString() ??
                    'Pending'),
            iconColor: Colors.green,
          ),
          const SizedBox(height: 12),
          _DispatchInfoRow(
            icon: Icons.location_on_outlined,
            label: 'Dropoff',
            value: activeRequest['destination_address']
                        ?.toString()
                        .trim()
                        .isNotEmpty ==
                    true
                ? activeRequest['destination_address'].toString()
                : (_asStringDynamicMap(activeRequest['dropoff'])?['address']
                        ?.toString() ??
                    'Pending'),
            iconColor: Colors.redAccent,
          ),
          if (((activeRequest['package_description'] ??
                      activeRequest['packageDescription'] ??
                      dispatchDetails?['package_details'])
                  ?.toString()
                  .trim() ??
              '')
              .isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            _DispatchInfoRow(
              icon: Icons.inventory_2_outlined,
              label: 'Package details',
              value: (activeRequest['package_description'] ??
                      activeRequest['packageDescription'] ??
                      dispatchDetails?['package_details'])
                  .toString(),
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
    return PopScope(
      canPop: !_submitting && !_uploadingPackagePhoto,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) {
          return;
        }
        if (_submitting || _uploadingPackagePhoto) {
          debugPrint('DISPATCH_NAVIGATION_LOCK_GUARD back_blocked');
          _showMessage('Please wait — your request is still in progress.');
        }
      },
      child: Scaffold(
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
                        await Navigator.of(context).push<void>(
                          MaterialPageRoute<void>(
                            builder: (_) => const RiderSelfieVerificationScreen(),
                          ),
                        );
                        if (mounted) {
                          await _loadIdentityCompliance();
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (shouldShowRiderRolloutBanner(
                    catalogLoading: _rolloutCatalogLoading,
                    catalogHydrated: _rolloutCatalogHydrated,
                    catalogError: _rolloutCatalogError,
                    catalog: _rolloutCatalog,
                    selectionComplete: _rolloutSelectionComplete,
                    savedAreaDisabled: _rolloutSavedAreaDisabled,
                    bannerDismissed: _rolloutBannerDismissed,
                  )) ...[
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
                              onTap: () {
                                unawaited(_openRolloutSheet());
                              },
                              child: Row(
                                children: <Widget>[
                                  Icon(
                                    _rolloutCatalogLoading
                                        ? Icons.hourglass_top
                                        : Icons.location_on_outlined,
                                    color: _gold,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: <Widget>[
                                        Text(
                                          riderRolloutBannerTitle(
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
                                        if (_rolloutCatalogLoading) ...<Widget>[
                                          const SizedBox(height: 4),
                                          Text(
                                            'You can open the picker, use GPS, or retry while the catalog loads.',
                                            style: TextStyle(
                                              color: Colors.brown.shade800,
                                              fontSize: 12,
                                              height: 1.25,
                                            ),
                                          ),
                                        ],
                                        if (!_rolloutCatalogLoading &&
                                            _rolloutCatalogError == null) ...<Widget>[
                                          const SizedBox(height: 4),
                                          Text(
                                            _rolloutSavedAreaDisabled
                                                ? 'Choose a new area or use your current location.'
                                                : 'Pick your state and city, or use your current location.',
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
                                            'Tap the banner or Retry. GPS is available in the picker.',
                                            style: TextStyle(
                                              color: Colors.brown.shade800,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
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
                                TextButton(
                                  onPressed: () {
                                    setState(() {
                                      _rolloutBannerDismissed = true;
                                    });
                                  },
                                  child: const Text('Dismiss'),
                                ),
                                TextButton(
                                  onPressed: () {
                                    unawaited(_openRolloutSheet());
                                  },
                                  child: Text(
                                    _rolloutCatalogError != null
                                        ? 'Retry catalog'
                                        : 'Choose area',
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
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
                          NativePlacesAutocompleteField(
                            controller: _pickupController,
                            hintText: 'Pickup address',
                            countryCode: RiderLaunchScope.countryCode,
                            searchScopeLabel: RiderLaunchScope.launchCitiesLabel,
                            queryTransform: (String query) =>
                                RiderLaunchScope.normalizeAddressQuery(
                                  query,
                                  preferredCity: _selectedLaunchCity,
                                ),
                            fallbackSuggestionsBuilder: _fallbackPlaceSuggestions,
                            onSelected: (suggestion) async {
                              await _handleDispatchPlaceSelection(
                                suggestion: suggestion,
                                isPickup: true,
                              );
                            },
                          ),
                          const SizedBox(height: 14),
                          NativePlacesAutocompleteField(
                            controller: _dropoffController,
                            hintText: 'Dropoff address',
                            countryCode: RiderLaunchScope.countryCode,
                            searchScopeLabel: RiderLaunchScope.launchCitiesLabel,
                            queryTransform: (String query) =>
                                RiderLaunchScope.normalizeAddressQuery(
                                  query,
                                  preferredCity: _selectedLaunchCity,
                                ),
                            fallbackSuggestionsBuilder: _fallbackPlaceSuggestions,
                            onSelected: (suggestion) async {
                              await _handleDispatchPlaceSelection(
                                suggestion: suggestion,
                                isPickup: false,
                              );
                            },
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
                          const SizedBox(height: 14),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  'Payment method',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                    color: Colors.grey.shade800,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 8,
                                  children: <Widget>[
                                    ChoiceChip(
                                      label: const Text('Debit / credit card'),
                                      selected:
                                          _dispatchPaymentMethod ==
                                              'flutterwave',
                                      onSelected:
                                          _submitting
                                              ? null
                                              : (bool v) {
                                                  if (v) {
                                                    setState(
                                                      () =>
                                                          _dispatchPaymentMethod =
                                                              'flutterwave',
                                                    );
                                                  }
                                                },
                                    ),
                                    ChoiceChip(
                                      label: const Text('Bank transfer'),
                                      selected:
                                          _dispatchPaymentMethod ==
                                              'bank_transfer',
                                      onSelected:
                                          _submitting
                                              ? null
                                              : (bool v) {
                                                  if (v) {
                                                    setState(
                                                      () =>
                                                          _dispatchPaymentMethod =
                                                              'bank_transfer',
                                                    );
                                                  }
                                                },
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          if (_dispatchPaymentMethod == 'bank_transfer') ...<
                            Widget>[
                            const SizedBox(height: 10),
                            Text(
                              'You will get a dedicated virtual account and exact amount. Payment confirms automatically — no receipt upload.',
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.35,
                                color: Colors.grey.shade700,
                              ),
                            ),
                          ],
                          if (_dispatchFarePreview != null) ...<Widget>[
                            const SizedBox(height: 12),
                            RiderBackendPricingBreakdown(
                              quote: _dispatchFarePreview!,
                              tripFareLabel: 'Delivery fee',
                              compact: true,
                            ),
                          ],
                          if (_pickupLocation != null && _dropoffLocation != null) ...<Widget>[
                            const SizedBox(height: 12),
                            RiderDiscountSelector(
                              discounts: _deliveryDiscountOptions,
                              selectedDiscountId: _selectedDeliveryDiscountId,
                              appliedQuote: _dispatchFarePreview,
                              busy: _deliveryDiscountsLoading || _dispatchQuoteLoading,
                              applyLabel: 'Apply delivery discount',
                              onSelect: _handleSelectDeliveryDiscount,
                              onClear: _handleClearDeliveryDiscount,
                            ),
                          ],
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
