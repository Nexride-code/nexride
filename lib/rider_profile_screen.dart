import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/material.dart';

import 'config/rider_app_config.dart';
import 'payment_methods_screen.dart';
import 'rider_verification_screen.dart';
import 'services/payment_methods_service.dart';
import 'services/rider_ride_cloud_functions_service.dart';
import 'services/rider_active_trip_session_service.dart';
import 'services/rider_trust_bootstrap_service.dart';
import 'services/user_support_ticket_service.dart';
import 'support/payment_method_support.dart';
import 'support/rider_trust_support.dart';
import 'support/startup_rtdb_support.dart';
import 'support_center_screen.dart';
import 'trip_history_screen.dart';
import 'map_screen.dart';

class RiderProfileScreen extends StatefulWidget {
  const RiderProfileScreen({
    super.key,
    required this.riderId,
    this.initialUserProfile = const <String, dynamic>{},
    this.initialVerification = const <String, dynamic>{},
    this.initialRiskFlags = const <String, dynamic>{},
    this.initialPaymentFlags = const <String, dynamic>{},
    this.initialReputation = const <String, dynamic>{},
    this.initialTrustSummary = const <String, dynamic>{},
  });

  final String riderId;
  final Map<String, dynamic> initialUserProfile;
  final Map<String, dynamic> initialVerification;
  final Map<String, dynamic> initialRiskFlags;
  final Map<String, dynamic> initialPaymentFlags;
  final Map<String, dynamic> initialReputation;
  final Map<String, dynamic> initialTrustSummary;

  @override
  State<RiderProfileScreen> createState() => _RiderProfileScreenState();
}

class _RiderProfileScreenState extends State<RiderProfileScreen>
    with WidgetsBindingObserver {
  static const Color _gold = Color(0xFFB57A2A);
  static const Color _cream = Color(0xFFF7F2EA);
  static const Color _dark = Color(0xFF111111);

  final RiderTrustBootstrapService _bootstrapService =
      const RiderTrustBootstrapService();
  final PaymentMethodsService _paymentMethodsService =
      const PaymentMethodsService();
  final UserSupportTicketService _userSupportTicketService =
      const UserSupportTicketService();
  final RiderActiveTripSessionService _activeTripSessionService =
      RiderActiveTripSessionService.instance;
  final RiderRideCloudFunctionsService _rideCloud =
      RiderRideCloudFunctionsService();
  final rtdb.DatabaseReference _rootRef = rtdb.FirebaseDatabase.instance.ref();

  late Map<String, dynamic> _userProfile;
  late Map<String, dynamic> _verification;
  late Map<String, dynamic> _riskFlags;
  late Map<String, dynamic> _paymentFlags;
  late Map<String, dynamic> _reputation;
  late Map<String, dynamic> _trustSummary;
  List<PaymentMethodRecord> _paymentMethods = <PaymentMethodRecord>[];
  UserSupportInboxSummary? _supportSummary;
  bool _loading = true;
  bool _refreshing = false;
  bool _tripCancelInFlight = false;

  String _tripStatusHeadline(String status) {
    switch (status) {
      case 'searching':
      case 'requested':
      case 'searching_driver':
      case 'matching':
        return 'Finding a driver';
      case 'accepted':
      case 'pending_driver_action':
      case 'assigned':
        return 'Driver assigned';
      case 'arriving':
        return 'Driver on the way';
      case 'arrived':
        return 'Driver arrived';
      case 'on_trip':
        return 'Trip in progress';
      default:
        return 'Active trip';
    }
  }

  Future<void> _cancelTripFromProfile(RiderActiveTripSession session) async {
    if (_tripCancelInFlight ||
        !_activeTripSessionService.allowsRiderBannerCancel(session)) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Cancel this trip?'),
          content: const Text(
            'You can book again anytime. Only cancel if the driver has not started the trip.',
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
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() {
      _tripCancelInFlight = true;
    });
    try {
      await _activeTripSessionService.cancelActiveTripViaCloudFunction(
        _rideCloud,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Trip cancelled')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not cancel: $error')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _tripCancelInFlight = false;
        });
      } else {
        _tripCancelInFlight = false;
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _userProfile = Map<String, dynamic>.from(widget.initialUserProfile);
    _verification = buildRiderVerificationDefaults(widget.initialVerification);
    _riskFlags = buildRiderRiskFlagsDefaults(widget.initialRiskFlags);
    _paymentFlags = buildRiderPaymentFlagsDefaults(widget.initialPaymentFlags);
    _reputation = buildRiderReputationDefaults(widget.initialReputation);
    _trustSummary = Map<String, dynamic>.from(widget.initialTrustSummary);
    _loading =
        _userProfile.isEmpty &&
        widget.initialVerification.isEmpty &&
        widget.initialTrustSummary.isEmpty;
    unawaited(_loadProfile(showLoading: _loading));
    unawaited(
      _activeTripSessionService.restoreActiveTripForCurrentUser(
        source: 'profile.init',
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
    debugPrint('[RIDER_NAV_RESUME_ACTIVE_TRIP] source=profile');
    unawaited(
      _activeTripSessionService.restoreActiveTripForCurrentUser(
        source: 'profile.resume',
      ),
    );
  }

  Future<void> _loadProfile({bool showLoading = false}) async {
    if (showLoading && mounted) {
      setState(() {
        _loading = true;
      });
    } else if (mounted) {
      setState(() {
        _refreshing = true;
      });
    }

    debugPrint('[RiderProfile] bootstrap load riderId=${widget.riderId}');

    try {
      final userSnapshot = await runOptionalStartupRead<rtdb.DataSnapshot>(
        source: 'rider_profile.user_profile',
        path: 'users/${widget.riderId}',
        action: () => _rootRef.child('users/${widget.riderId}').get(),
      );
      final existingUser = userSnapshot?.value is Map
          ? Map<String, dynamic>.from(userSnapshot!.value as Map)
          : <String, dynamic>{};

      final bundle = await _bootstrapService.ensureRiderTrustState(
        riderId: widget.riderId,
        existingUser: existingUser,
        fallbackName: FirebaseAuth.instance.currentUser?.email
            ?.split('@')
            .first,
        fallbackEmail: FirebaseAuth.instance.currentUser?.email,
        fallbackPhone: existingUser['phone']?.toString(),
      );

      final paymentMethods = await _paymentMethodsService.fetchPaymentMethods(
        widget.riderId,
      );
      UserSupportInboxSummary? supportSummary = _supportSummary;
      try {
        supportSummary = await _userSupportTicketService.fetchInboxSummary(
          userId: widget.riderId,
          createdByType: 'rider',
        );
      } catch (_) {
        supportSummary = _supportSummary;
      }

      await persistRiderOwnedBootstrap(
        rootRef: _rootRef,
        riderId: widget.riderId,
        userProfile: <String, dynamic>{
          ...existingUser,
          ...bundle.userProfile,
          'created_at':
              existingUser['created_at'] ?? rtdb.ServerValue.timestamp,
        },
        verification: bundle.verification,
        deviceFingerprints: bundle.deviceFingerprints,
        source: 'rider_profile.bootstrap_write',
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _userProfile = Map<String, dynamic>.from(bundle.userProfile);
        _verification = bundle.verification;
        _riskFlags = bundle.riskFlags;
        _paymentFlags = bundle.paymentFlags;
        _reputation = bundle.reputation;
        _trustSummary = bundle.trustSummary;
        _paymentMethods = paymentMethods;
        _supportSummary = supportSummary;
        _loading = false;
      });
    } catch (error, stackTrace) {
      debugPrint('[RiderProfile] load failed: $error');
      debugPrintStack(
        label: '[RiderProfile] load stack',
        stackTrace: stackTrace,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _loading = false;
      });
    } finally {
      if (mounted) {
        setState(() {
          _refreshing = false;
        });
      } else {
        _refreshing = false;
      }
    }
  }

  Future<void> _openVerification() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => RiderVerificationScreen(riderId: widget.riderId),
      ),
    );

    await _loadProfile();
  }

  Future<void> _openTripHistory() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => RiderTripHistoryScreen(userId: widget.riderId),
      ),
    );
  }

  Future<void> _openSupportSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) {
        return SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              16,
              24,
              16,
              16 + MediaQuery.of(sheetContext).viewInsets.bottom,
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
                    'Help & Support',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Open the NexRide support center, review your trips, or continue ${RiderVerificationCopy.titleLowercase} from one place.',
                    style: TextStyle(
                      color: Colors.black.withValues(alpha: 0.66),
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 18),
                  _ProfileActionTile(
                    icon: Icons.support_agent_rounded,
                    title: 'Report Issue / Support',
                    subtitle:
                        'Create a support ticket, read staff replies, and follow active disputes.',
                    trailing: _supportStatusChip(),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      unawaited(_openSupportCenter());
                    },
                  ),
                  const SizedBox(height: 12),
                  _ProfileActionTile(
                    icon: Icons.history_rounded,
                    title: 'Trip History',
                    subtitle: 'Review past rides and deliveries.',
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      unawaited(_openTripHistory());
                    },
                  ),
                  const SizedBox(height: 12),
                  _ProfileActionTile(
                    icon: Icons.verified_user_outlined,
                    title: RiderVerificationCopy.title,
                    subtitle: 'Check your status or continue verification.',
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      unawaited(_openVerification());
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openSupportCenter() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SupportCenterScreen(userId: widget.riderId),
      ),
    );

    await _loadProfile();
  }

  Widget? _supportStatusChip() {
    final summary = _supportSummary;
    if (summary == null) {
      return null;
    }
    if (summary.unreadReplies > 0) {
      return _ProfileStatusChip(
        label: '${summary.unreadReplies} new',
        color: const Color(0xFF8A6424),
      );
    }
    if (summary.openTickets > 0) {
      return _ProfileStatusChip(
        label: '${summary.openTickets} open',
        color: const Color(0xFF1E3A5F),
      );
    }
    if (summary.totalTickets > 0) {
      return const _ProfileStatusChip(
        label: 'Resolved',
        color: Color(0xFF2D6B57),
      );
    }
    return null;
  }

  Future<void> _openPaymentMethods() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PaymentMethodsScreen(riderId: widget.riderId),
      ),
    );

    await _loadProfile();
  }

  String _basicName() {
    final authUser = FirebaseAuth.instance.currentUser;
    final candidates = <String>[
      _userProfile['name']?.toString() ?? '',
      authUser?.displayName ?? '',
      authUser?.email?.split('@').first ?? '',
    ];

    return candidates.firstWhere(
      (String value) => value.trim().isNotEmpty,
      orElse: () => 'NexRide User',
    );
  }

  String _basicEmail() {
    return (_userProfile['email']?.toString().trim().isNotEmpty ?? false)
        ? _userProfile['email'].toString().trim()
        : (FirebaseAuth.instance.currentUser?.email ?? 'Email not set');
  }

  String _basicPhone() {
    final phone = _userProfile['phone']?.toString().trim() ?? '';
    return phone.isEmpty ? 'Phone not added yet' : phone;
  }

  Widget _buildMetricCard({
    required String label,
    required String value,
    Color? valueColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x10000000),
            blurRadius: 14,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Text(
            label,
            style: TextStyle(
              color: Colors.black.withValues(alpha: 0.55),
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: valueColor ?? Colors.black87,
              fontSize: 20,
              fontWeight: FontWeight.w900,
              height: 1.15,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final verificationStatus =
        _verification['overallStatus']?.toString() ?? 'unverified';
    final verificationLabel = riderVerificationStatusLabel(verificationStatus);
    final verificationColor = riderVerificationStatusColor(verificationStatus);
    final accountStatus = _riskFlags['status']?.toString() ?? 'clear';
    final accountStatusLabel = riderRiskStatusLabel(accountStatus);
    final accountStatusColor = riderRiskStatusColor(accountStatus);
    final rating = (_reputation['averageRating'] as num?)?.toDouble() ?? 5.0;
    final ratingCount = (_reputation['ratingCount'] as int?) ?? 0;
    final paymentMethods = _paymentMethods;
    final outstandingFees =
        (_paymentFlags['outstandingCancellationFeesNgn'] as int?) ?? 0;
    final defaultPaymentMethod =
        paymentMethods.where((method) => method.isDefault).isEmpty
        ? null
        : paymentMethods.firstWhere((method) => method.isDefault);

    return Scaffold(
      backgroundColor: _cream,
      appBar: AppBar(
        backgroundColor: _gold,
        foregroundColor: Colors.black,
        title: const Text('User Profile'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                color: _gold,
                onRefresh: () => _loadProfile(),
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    return SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.fromLTRB(
                        18,
                        18,
                        18,
                        28 + MediaQuery.of(context).padding.bottom,
                      ),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: constraints.maxHeight,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            Container(
                      padding: const EdgeInsets.all(22),
                      decoration: BoxDecoration(
                        color: _dark,
                        borderRadius: BorderRadius.circular(30),
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
                          CircleAvatar(
                            radius: 28,
                            backgroundColor: _gold.withValues(alpha: 0.18),
                            child: Text(
                              _basicName().trim().isEmpty
                                  ? 'N'
                                  : _basicName().trim()[0].toUpperCase(),
                              style: const TextStyle(
                                color: _gold,
                                fontSize: 24,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  _basicName(),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 24,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  _basicEmail(),
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.76),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  _basicPhone(),
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.76),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                            const SizedBox(height: 18),
                            LayoutBuilder(
                              builder: (
                                BuildContext context,
                                BoxConstraints metricConstraints,
                              ) {
                                final stackMetrics =
                                    metricConstraints.maxWidth < 360;
                                if (stackMetrics) {
                                  return Column(
                                    children: <Widget>[
                                      _buildMetricCard(
                                        label: 'Verification',
                                        value: verificationLabel,
                                        valueColor: verificationColor,
                                      ),
                                      const SizedBox(height: 12),
                                      _buildMetricCard(
                                        label: ratingCount <= 0
                                            ? 'Rating'
                                            : 'Rating ($ratingCount)',
                                        value: ratingCount <= 0
                                            ? '${rating.toStringAsFixed(1)} baseline'
                                            : rating.toStringAsFixed(1),
                                        valueColor: _gold,
                                      ),
                                    ],
                                  );
                                }
                                return IntrinsicHeight(
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: <Widget>[
                                      Expanded(
                                        child: _buildMetricCard(
                                          label: 'Verification',
                                          value: verificationLabel,
                                          valueColor: verificationColor,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: _buildMetricCard(
                                          label: ratingCount <= 0
                                              ? 'Rating'
                                              : 'Rating ($ratingCount)',
                                          value: ratingCount <= 0
                                              ? '${rating.toStringAsFixed(1)} baseline'
                                              : rating.toStringAsFixed(1),
                                          valueColor: _gold,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    if (RiderFeatureFlags.showTrustWarnings) ...<Widget>[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: const <BoxShadow>[
                            BoxShadow(
                              color: Color(0x10000000),
                              blurRadius: 14,
                              offset: Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            const Text(
                              'Account trust',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              riderTrustSummaryMessage(_trustSummary),
                              style: TextStyle(
                                color: Colors.black.withValues(alpha: 0.66),
                                height: 1.45,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              children: <Widget>[
                                _ProfileStatusChip(
                                  label: accountStatusLabel,
                                  color: accountStatusColor,
                                ),
                                if (outstandingFees > 0)
                                  _ProfileStatusChip(
                                    label:
                                        'Outstanding fees: NGN $outstandingFees',
                                    color: const Color(0xFF8A6424),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 18),
                    ValueListenableBuilder<RiderActiveTripSession?>(
                      valueListenable: _activeTripSessionService.sessionNotifier,
                      builder: (
                        BuildContext context,
                        RiderActiveTripSession? session,
                        Widget? _,
                      ) {
                        if (session == null ||
                            !_activeTripSessionService.hasActiveTrip) {
                          return const SizedBox.shrink();
                        }
                        debugPrint(
                          '[RIDER_ACTIVE_TRIP_BANNER] source=profile status=${session.status} rideId=${session.rideId}',
                        );
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              _ProfileActionTile(
                                icon: Icons.alt_route_rounded,
                                title: _tripStatusHeadline(session.status),
                                subtitle:
                                    'Status: ${session.status.replaceAll('_', ' ')}. Tap to open the map and track this trip.',
                                trailing: const _ProfileStatusChip(
                                  label: 'Live',
                                  color: Color(0xFF198754),
                                ),
                                onTap: () {
                                  debugPrint(
                                    '[RIDER_NAV_RETURN_TO_TRIP] source=profile rideId=${session.rideId}',
                                  );
                                  Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) => const MapScreen(),
                                    ),
                                  );
                                },
                              ),
                              if (_activeTripSessionService
                                  .allowsRiderBannerCancel(session))
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: TextButton(
                                    onPressed: _tripCancelInFlight
                                        ? null
                                        : () => unawaited(
                                              _cancelTripFromProfile(session),
                                            ),
                                    child: Text(
                                      _tripCancelInFlight
                                          ? 'Cancelling…'
                                          : 'Cancel trip',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                    Text(
                      'Account',
                      style: TextStyle(
                        color: Colors.black.withValues(alpha: 0.86),
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(height: 10),
                    _ProfileActionTile(
                      icon: Icons.verified_user_outlined,
                      title: RiderVerificationCopy.title,
                      subtitle:
                          'Status: $verificationLabel. Open this area to review or continue your verification details.',
                      trailing: _ProfileStatusChip(
                        label: verificationLabel,
                        color: verificationColor,
                      ),
                      onTap: _openVerification,
                    ),
                    const SizedBox(height: 14),
                    _ProfileActionTile(
                      icon: Icons.payments_outlined,
                      title: 'Payment Methods',
                      subtitle: paymentMethods.isEmpty
                          ? 'Link a card or bank account to prepare online payment checkout.'
                          : defaultPaymentMethod != null
                          ? '${paymentMethods.length} linked method${paymentMethods.length == 1 ? '' : 's'} • Default: ${defaultPaymentMethod.displayTitle}'
                          : '${paymentMethods.length} linked method${paymentMethods.length == 1 ? '' : 's'} saved for future checkout.',
                      trailing: paymentMethods.isEmpty
                          ? const _ProfileStatusChip(
                              label: 'Empty',
                              color: Color(0xFF8A6424),
                            )
                          : _ProfileStatusChip(
                              label: '${paymentMethods.length} saved',
                              color: const Color(0xFF1E3A5F),
                            ),
                      onTap: _openPaymentMethods,
                    ),
                    const SizedBox(height: 14),
                    _ProfileActionTile(
                      icon: Icons.history_rounded,
                      title: 'Trip History',
                      subtitle:
                          'Review completed rides and deliveries from one place.',
                      onTap: _openTripHistory,
                    ),
                    const SizedBox(height: 14),
                    _ProfileActionTile(
                      icon: Icons.support_agent_rounded,
                      title: 'Help & Support',
                      subtitle:
                          'Open support options for trip help, account questions, and verification guidance.',
                      trailing: _supportStatusChip(),
                      onTap: _openSupportSheet,
                    ),
                    if (_refreshing) ...<Widget>[
                      const SizedBox(height: 18),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: <Widget>[
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: _gold,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            'Refreshing profile',
                            style: TextStyle(
                              color: Colors.black.withValues(alpha: 0.58),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
      ),
    );
  }
}

class _ProfileActionTile extends StatelessWidget {
  const _ProfileActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final stackTrailing = width < 365;
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: Color(0x10000000),
                blurRadius: 14,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: _RiderProfileScreenState._gold.withValues(
                        alpha: 0.12,
                      ),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(icon, color: _RiderProfileScreenState._gold),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w900,
                            color: Colors.black87,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
                          style: TextStyle(
                            color: Colors.black.withValues(alpha: 0.64),
                            height: 1.45,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!stackTrailing) ...<Widget>[
                    const SizedBox(width: 12),
                    trailing ??
                        Icon(
                          onTap == null
                              ? Icons.info_outline_rounded
                              : Icons.chevron_right_rounded,
                          color: Colors.black45,
                        ),
                  ],
                ],
              ),
              if (stackTrailing) ...<Widget>[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: trailing ??
                      Icon(
                        onTap == null
                            ? Icons.info_outline_rounded
                            : Icons.chevron_right_rounded,
                        color: Colors.black45,
                      ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileStatusChip extends StatelessWidget {
  const _ProfileStatusChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
    );
  }
}
