import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/material.dart';

import 'config/rider_app_config.dart';
import 'dispatch_request_screen.dart';
import 'map_screen.dart';
import 'rider_profile_screen.dart';
import 'rider_login.dart';
import 'service_type.dart';
import 'services/rider_trust_bootstrap_service.dart';
import 'services/rider_active_trip_session_service.dart';
import 'support/rider_trust_support.dart';
import 'support/startup_rtdb_support.dart';

class RideTypeScreen extends StatefulWidget {
  const RideTypeScreen({super.key});

  @override
  State<RideTypeScreen> createState() => _RideTypeScreenState();
}

class _RideTypeScreenState extends State<RideTypeScreen>
    with WidgetsBindingObserver {
  static const Color _gold = Color(0xFFB57A2A);
  static const String _bookCarRouteName = '/rider/book-car';
  static const String _dispatchRouteName = '/rider/dispatch';

  final rtdb.DatabaseReference _rootRef = rtdb.FirebaseDatabase.instance.ref();
  final RiderTrustBootstrapService _trustBootstrapService =
      const RiderTrustBootstrapService();
  final RiderActiveTripSessionService _activeTripSessionService =
      RiderActiveTripSessionService.instance;

  Map<String, dynamic> _userProfile = <String, dynamic>{};
  Map<String, dynamic> _verification = buildRiderVerificationDefaults(null);
  Map<String, dynamic> _riskFlags = buildRiderRiskFlagsDefaults(null);
  Map<String, dynamic> _paymentFlags = buildRiderPaymentFlagsDefaults(null);
  Map<String, dynamic> _reputation = buildRiderReputationDefaults(null);
  Map<String, dynamic> _trustSummary = <String, dynamic>{};
  bool _loadingTrust = true;
  bool _serviceNavigationInFlight = false;
  String _lastRequestUiStateLog = '';

  String? get _currentRiderId => FirebaseAuth.instance.currentUser?.uid;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadTrustState());
    unawaited(
      _activeTripSessionService.restoreActiveTripForCurrentUser(
        source: 'ride_type.init',
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      return;
    }
    debugPrint('[RIDER_NAV_RESUME_ACTIVE_TRIP] source=ride_type');
    unawaited(
      _activeTripSessionService.restoreActiveTripForCurrentUser(
        source: 'ride_type.resume',
      ),
    );
  }

  Future<void> _loadTrustState() async {
    final riderId = _currentRiderId;
    if (riderId == null || riderId.isEmpty) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loadingTrust = false;
      });
      return;
    }

    try {
      final userSnapshot = await runOptionalStartupRead<rtdb.DataSnapshot>(
        source: 'ride_type.user_profile',
        path: 'users/$riderId',
        action: () => _rootRef.child('users/$riderId').get(),
      );
      final existingUser = userSnapshot?.value is Map
          ? Map<String, dynamic>.from(userSnapshot!.value as Map)
          : <String, dynamic>{};
      final bundle = await _trustBootstrapService.ensureRiderTrustState(
        riderId: riderId,
        existingUser: existingUser,
        fallbackName: existingUser['name']?.toString(),
        fallbackEmail:
            FirebaseAuth.instance.currentUser?.email ??
            existingUser['email']?.toString(),
        fallbackPhone: existingUser['phone']?.toString(),
      );

      await persistRiderOwnedBootstrap(
        rootRef: _rootRef,
        riderId: riderId,
        userProfile: <String, dynamic>{
          ...existingUser,
          ...bundle.userProfile,
          'created_at':
              existingUser['created_at'] ?? rtdb.ServerValue.timestamp,
        },
        verification: bundle.verification,
        deviceFingerprints: bundle.deviceFingerprints,
        source: 'ride_type.bootstrap_write',
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _userProfile = bundle.userProfile;
        _verification = bundle.verification;
        _riskFlags = bundle.riskFlags;
        _paymentFlags = bundle.paymentFlags;
        _reputation = bundle.reputation;
        _trustSummary = bundle.trustSummary;
        _loadingTrust = false;
      });
    } catch (error, stackTrace) {
      debugPrint('[RideType] trust load failed: $error');
      debugPrintStack(
        label: '[RideType] trust load stack',
        stackTrace: stackTrace,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _loadingTrust = false;
      });
    }
  }

  Future<void> _openBookCarFlow() async {
    debugPrint('[RIDER_REQUEST_BUTTON_TAPPED] source=ride_type.book_car');
    await _openServiceRoute(
      serviceLabel: 'Book a Car',
      routeName: _bookCarRouteName,
      errorMessage: 'Unable to open booking right now.',
      builder: (_) => const MapScreen(),
    );
  }

  Future<void> _openDispatchFlow() async {
    await _openServiceRoute(
      serviceLabel: 'Dispatch',
      routeName: _dispatchRouteName,
      errorMessage: 'Unable to open dispatch right now.',
      builder: (_) => const DispatchRequestScreen(),
    );
  }

  Future<void> _openServiceRoute({
    required String serviceLabel,
    required String routeName,
    required String errorMessage,
    required WidgetBuilder builder,
  }) async {
    debugPrint(
      '[RideType] $serviceLabel tap fired loadingTrust=$_loadingTrust',
    );
    FocusScope.of(context).unfocus();

    if (_serviceNavigationInFlight) {
      debugPrint(
        '[RideType] $serviceLabel tap ignored because navigation is already in flight',
      );
      return;
    }

    final riderId = _currentRiderId;
    if (riderId == null || riderId.isEmpty) {
      debugPrint(
        '[RideType] $serviceLabel tap blocked reason=missing_rider_session route=$routeName',
      );
      _showMessage('Please log in again to continue.');
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(builder: (_) => const RiderLogin()),
        );
      }
      return;
    }

    _serviceNavigationInFlight = true;
    try {
      debugPrint('[RideType] opening route route=$routeName');
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          settings: RouteSettings(name: routeName),
          builder: builder,
        ),
      );
      debugPrint('[RideType] navigation completed route=$routeName');
    } catch (error, stackTrace) {
      debugPrint(
        '[RideType] navigation failed route=$routeName service=$serviceLabel error=$error',
      );
      debugPrintStack(
        label: '[RideType] navigation stack route=$routeName',
        stackTrace: stackTrace,
      );
      _showMessage(errorMessage);
    } finally {
      _serviceNavigationInFlight = false;
    }
  }

  void _logRequestUiState({
    required RiderActiveTripSession? session,
  }) {
    final hasActiveTrip = _activeTripSessionService.hasActiveTrip;
    final tripState = session?.tripState.trim().isNotEmpty == true
        ? session!.tripState.trim()
        : 'idle';
    final lifecycleState = session?.status.trim().isNotEmpty == true
        ? session!.status.trim().toLowerCase()
        : 'idle';
    final showRequestButton = true; // RideType always exposes service entry cards.
    final line =
        '[RIDER_REQUEST_UI_STATE] hasActiveTrip=$hasActiveTrip '
        'trip_state=$tripState lifecycleState=$lifecycleState '
        'showRequestButton=$showRequestButton';
    if (_lastRequestUiStateLog == line) {
      return;
    }
    _lastRequestUiStateLog = line;
    debugPrint(line);
  }

  Future<void> _openProfile() async {
    final riderId = _currentRiderId;
    if (riderId == null || riderId.isEmpty) {
      return;
    }

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => RiderProfileScreen(
          riderId: riderId,
          initialUserProfile: _userProfile,
          initialVerification: _verification,
          initialRiskFlags: _riskFlags,
          initialPaymentFlags: _paymentFlags,
          initialReputation: _reputation,
          initialTrustSummary: _trustSummary,
        ),
      ),
    );

    unawaited(_loadTrustState());
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final services =
        <
          ({
            RiderServiceType type,
            Color background,
            Color border,
            VoidCallback onTap,
          })
        >[
          if (RiderServiceType.ride.isEnabled)
            (
              type: RiderServiceType.ride,
              background: _gold,
              border: _gold,
              onTap: () => unawaited(_openBookCarFlow()),
            ),
          if (RiderServiceType.dispatchDelivery.isEnabled)
            (
              type: RiderServiceType.dispatchDelivery,
              background: const Color(0xFF161616),
              border: _gold.withValues(alpha: 0.85),
              onTap: () => unawaited(_openDispatchFlow()),
            ),
        ];

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: _gold,
        centerTitle: true,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.local_taxi,
                color: Colors.black87,
                size: 20,
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              'NexRide',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22),
            ),
            const SizedBox(width: 10),
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.two_wheeler,
                color: Colors.black87,
                size: 20,
              ),
            ),
          ],
        ),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: IconButton(
              icon: const Icon(Icons.person_outline_rounded, size: 26),
              tooltip: 'User Profile',
              onPressed: () {
                unawaited(_openProfile());
              },
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                Color(0xFF0D0D0D),
                Color(0xFF171717),
                Color(0xFF080808),
              ],
            ),
          ),
          child: RefreshIndicator(
            color: _gold,
            onRefresh: _loadTrustState,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 32),
              children: <Widget>[
                _StaggeredReveal(
                  delayMs: 0,
                  child: Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.08),
                      ),
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: <Color>[Color(0xFF161616), Color(0xFF0E0E0E)],
                      ),
                      boxShadow: const <BoxShadow>[
                        BoxShadow(
                          color: Color(0x26000000),
                          blurRadius: 22,
                          offset: Offset(0, 14),
                        ),
                      ],
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                _loadingTrust
                                    ? 'Preparing your ride hub'
                                    : 'Move with NexRide',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -0.2,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Book a car or send a delivery with a cleaner, faster flow built for local testing.',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.68),
                                  fontSize: 13.5,
                                  height: 1.45,
                                ),
                              ),
                              const SizedBox(height: 18),
                              const _HeroDriveAnimation(),
                            ],
                          ),
                        ),
                        const SizedBox(width: 14),
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: _gold.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: _gold.withValues(alpha: 0.22),
                            ),
                          ),
                          child: const Icon(
                            Icons.directions_car_filled_rounded,
                            color: _gold,
                            size: 24,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                ValueListenableBuilder<RiderActiveTripSession?>(
                  valueListenable: _activeTripSessionService.sessionNotifier,
                  builder: (
                    BuildContext context,
                    RiderActiveTripSession? session,
                    Widget? _,
                  ) {
                    _logRequestUiState(session: session);
                    if (session == null ||
                        !_activeTripSessionService.hasActiveTrip) {
                      return const SizedBox.shrink();
                    }
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: _ActiveTripBanner(
                        session: session,
                        onTap: () {
                          debugPrint(
                            '[RIDER_NAV_RETURN_TO_TRIP] source=ride_type rideId=${session.rideId}',
                          );
                          unawaited(_openBookCarFlow());
                        },
                      ),
                    );
                  },
                ),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            'Choose a service',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.96),
                              fontSize: 15,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.2,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Pick a service to start a clean, focused booking flow.',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.62),
                              fontSize: 12.8,
                            ),
                          ),
                        ],
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => unawaited(_openProfile()),
                      icon: Icon(
                        Icons.person_outline_rounded,
                        color: _gold.withValues(alpha: 0.95),
                      ),
                      label: Text(
                        'User Profile',
                        style: TextStyle(
                          color: _gold.withValues(alpha: 0.95),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final useGrid = constraints.maxWidth >= 380;
                    if (!useGrid) {
                      return Column(
                        children: services.toList().asMap().entries.map((
                          entry,
                        ) {
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _StaggeredReveal(
                              delayMs: 120 + (entry.key * 80),
                              child: _ServiceCard(
                                backgroundColor: entry.value.background,
                                borderColor: entry.value.border,
                                serviceType: entry.value.type,
                                onTap: entry.value.onTap,
                              ),
                            ),
                          );
                        }).toList(),
                      );
                    }
                    return Row(
                      children: services.toList().asMap().entries.map((entry) {
                        return Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(
                              right: entry.key == 0 ? 8 : 0,
                              left: entry.key == 1 ? 8 : 0,
                            ),
                            child: _StaggeredReveal(
                              delayMs: 120 + (entry.key * 80),
                              child: _ServiceCard(
                                backgroundColor: entry.value.background,
                                borderColor: entry.value.border,
                                serviceType: entry.value.type,
                                onTap: entry.value.onTap,
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    );
                  },
                ),
                const SizedBox(height: 18),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text(
                    'Reliable rides and polished dispatch flows, with your User Profile always close by.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.54),
                      fontSize: 12.5,
                      height: 1.5,
                    ),
                  ),
                ),
                if (RiderFeatureFlags.showTrustWarnings &&
                    (_trustSummary['restrictionMessage']
                            ?.toString()
                            .trim()
                            .isNotEmpty ??
                        false)) ...<Widget>[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.07),
                      ),
                    ),
                    child: Text(
                      _trustSummary['restrictionMessage'].toString(),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.72),
                        height: 1.45,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ActiveTripBanner extends StatelessWidget {
  const _ActiveTripBanner({required this.session, required this.onTap});

  final RiderActiveTripSession session;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    debugPrint(
      '[RIDER_ACTIVE_TRIP_BANNER] source=ride_type status=${session.status} rideId=${session.rideId}',
    );
    return Material(
      color: const Color(0xFF1A1A1A),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFB57A2A)),
          ),
          child: Row(
            children: <Widget>[
              const Icon(Icons.alt_route_rounded, color: Color(0xFFB57A2A)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Trip active • ${session.status.replaceAll('_', ' ')}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: Colors.white70),
            ],
          ),
        ),
      ),
    );
  }
}

class _ServiceCard extends StatelessWidget {
  const _ServiceCard({
    required this.backgroundColor,
    required this.borderColor,
    required this.serviceType,
    required this.onTap,
  });

  final Color backgroundColor;
  final Color borderColor;
  final RiderServiceType serviceType;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: backgroundColor,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: borderColor, width: 1.2),
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 18,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: SizedBox(
            height: 228,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(
                        serviceType.icon,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                    const Spacer(),
                    const Icon(
                      Icons.arrow_forward_rounded,
                      color: Colors.white70,
                      size: 18,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 46,
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Text(
                      serviceType.label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                        height: 1.18,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: Text(
                    serviceType.subtitle,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      height: 1.45,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.09),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text(
                    'Available now',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
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
}

class _HeroDriveAnimation extends StatefulWidget {
  const _HeroDriveAnimation();

  @override
  State<_HeroDriveAnimation> createState() => _HeroDriveAnimationState();
}

class _HeroDriveAnimationState extends State<_HeroDriveAnimation>
    with SingleTickerProviderStateMixin {
  static const Color _gold = Color(0xFFB57A2A);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3600),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
          gradient: LinearGradient(
            colors: <Color>[
              _gold.withValues(alpha: 0.11),
              Colors.white.withValues(alpha: 0.02),
            ],
          ),
        ),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final travelDistance = constraints.maxWidth - 72;
            return AnimatedBuilder(
              animation: _controller,
              builder: (BuildContext context, Widget? child) {
                final progress = Curves.easeInOut.transform(_controller.value);
                final left = 18 + (travelDistance * progress);
                final trailWidth = 24 + ((1 - progress) * 18);
                final trailLeft = left > trailWidth ? left - trailWidth : 0.0;

                return Stack(
                  alignment: Alignment.centerLeft,
                  children: <Widget>[
                    Positioned(
                      left: 18,
                      right: 18,
                      child: Container(
                        height: 2,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(999),
                          gradient: LinearGradient(
                            colors: <Color>[
                              Colors.transparent,
                              Colors.white.withValues(alpha: 0.18),
                              _gold.withValues(alpha: 0.42),
                              Colors.white.withValues(alpha: 0.18),
                              Colors.transparent,
                            ],
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 26,
                      right: 26,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: List<Widget>.generate(4, (int index) {
                          return Container(
                            width: 18,
                            height: 3,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(999),
                            ),
                          );
                        }),
                      ),
                    ),
                    Positioned(
                      left: trailLeft,
                      child: Opacity(
                        opacity: 0.3,
                        child: Container(
                          width: trailWidth,
                          height: 2,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(999),
                            gradient: LinearGradient(
                              colors: <Color>[
                                Colors.transparent,
                                _gold.withValues(alpha: 0.26),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: left,
                      child: Container(
                        width: 38,
                        height: 28,
                        decoration: BoxDecoration(
                          color: const Color(0xFF111111),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: _gold.withValues(alpha: 0.78),
                          ),
                          boxShadow: <BoxShadow>[
                            BoxShadow(
                              color: _gold.withValues(alpha: 0.22),
                              blurRadius: 14,
                              offset: const Offset(0, 5),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.directions_car_filled_rounded,
                          color: _gold,
                          size: 18,
                        ),
                      ),
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _StaggeredReveal extends StatelessWidget {
  const _StaggeredReveal({required this.child, required this.delayMs});

  final Widget child;
  final int delayMs;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      duration: Duration(milliseconds: 520 + delayMs),
      tween: Tween<double>(begin: 0, end: 1),
      curve: Curves.easeOutCubic,
      builder: (BuildContext context, double value, Widget? child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, (1 - value) * 22),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}
