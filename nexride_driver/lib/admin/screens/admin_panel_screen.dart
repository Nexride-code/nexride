import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../admin_config.dart';
import '../admin_rbac.dart';
import '../admin_drivers_route_debug.dart';
import '../models/admin_audit_event.dart';
import '../models/admin_models.dart';
import '../platform/admin_cache_invalidation_registry.dart';
import '../platform/admin_entity_cache_policy.dart';
import '../services/admin_action_executor.dart';
import '../services/admin_auth_service.dart';
import '../services/admin_data_service.dart';
import '../utils/admin_formatters.dart';
import '../utils/admin_perf_guard.dart';
import '../widgets/admin_charts.dart';
import '../widgets/admin_components.dart';
import '../widgets/admin_driver_drawer_tabs.dart';
import '../widgets/admin_entity_drawer.dart';
import '../widgets/admin_entity_drawer_controller.dart';
import '../widgets/admin_permission_gate.dart';
import '../widgets/admin_shell.dart';
import 'admin_live_operations_screen.dart';
import 'admin_live_ops_dashboard_screen.dart';
import 'admin_system_health_screen.dart';
import 'admin_merchants_screen.dart';
import 'admin_rollout_regions_screen.dart';
import 'admin_service_areas_screen.dart';
import 'admin_verification_center_screen.dart';
import 'admin_audit_logs_screen.dart';
import 'admin_payment_intents_screen.dart';
import '../support/proof_open.dart';
import '../../services/driver_finance_service.dart';

List<AdminDriverRecord> _adminDebugFakeDrivers() {
  AdminDriverRecord row(
    String id,
    String name,
    String city,
    String stateOrRegion,
  ) {
    return AdminDriverRecord(
      id: id,
      name: name,
      phone: '+234800000000',
      email: '$id@example.test',
      city: city,
      stateOrRegion: stateOrRegion,
      accountStatus: 'active',
      status: 'offline',
      isOnline: false,
      verificationStatus: 'pending',
      vehicleName: 'Test Sedan',
      plateNumber: 'TST-001',
      tripCount: 0,
      completedTripCount: 0,
      grossEarnings: 0,
      netEarnings: 0,
      walletBalance: 0,
      totalWithdrawn: 0,
      pendingWithdrawals: 0,
      monetizationModel: 'commission',
      subscriptionPlanType: 'monthly',
      subscriptionStatus: 'not_started',
      subscriptionActive: false,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 5, 1),
      serviceTypes: const <String>['ride'],
      rawData: const <String, dynamic>{},
    );
  }

  return <AdminDriverRecord>[
    row('fake_driver_lagos_1', 'Fake Driver Lagos 1', 'Lagos', 'lagos'),
    row('fake_driver_abuja_1', 'Fake Driver Abuja 1', 'Abuja', 'abuja'),
    row('fake_driver_delta_1', 'Fake Driver Delta 1', 'Warri', 'delta'),
    row('fake_driver_imo_1', 'Fake Driver Imo 1', 'Owerri', 'imo'),
    row('fake_driver_edo_1', 'Fake Driver Edo 1', 'Benin', 'edo'),
  ];
}

class AdminPanelScreen extends StatefulWidget {
  const AdminPanelScreen({
    required this.session,
    super.key,
    this.dataService,
    this.authService,
    this.initialSection = AdminSection.dashboard,
    this.initialDriverDeepLink,
    this.loginRoute = AdminRoutePaths.adminLogin,
    this.routeForSection,
    this.snapshotTimeout = const Duration(seconds: 120),
    this.enableRealtimeBadgeListeners = true,
  });

  final AdminSession session;
  final AdminDataService? dataService;
  final AdminAuthService? authService;
  final AdminSection initialSection;
  final AdminDriverDeepLink? initialDriverDeepLink;
  final String loginRoute;
  final String Function(AdminSection section)? routeForSection;
  final Duration snapshotTimeout;
  /// When false, skips RTDB listeners (widget tests / environments without Firebase).
  final bool enableRealtimeBadgeListeners;

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen> {
  late final AdminDataService _dataService;
  late final AdminAuthService _authService;

  final TextEditingController _riderSearchController = TextEditingController();
  final TextEditingController _driverSearchController = TextEditingController();
  final TextEditingController _supportSearchController =
      TextEditingController();
  final TextEditingController _withdrawalSearchController =
      TextEditingController();

  AdminPanelSnapshot? _snapshot;
  /// Drivers fetched via the lightweight drivers-only loader (no full snapshot).
  List<AdminDriverRecord>? _driversOnly;
  /// Pre-computed filtered+paginated driver list — updated outside build().
  List<AdminDriverRecord> _cachedFilteredDrivers = <AdminDriverRecord>[];
  AdminSection _section = AdminSection.dashboard;
  bool _isLoading = true;
  String? _errorMessage;
  bool _tokenRefreshedForDashboardLoad = false;
  Map<AdminSection, int> _sidebarBadgeCounts = <AdminSection, int>{};
  final List<_AdminPendingNotification> _pendingNotifications =
      <_AdminPendingNotification>[];
  Timer? _badgeRefreshTimer;
  Timer? _driverSearchDebounce;
  Timer? _riderSearchDebounce;
  Timer? _withdrawalSearchDebounce;
  Timer? _supportInboxSearchDebounce;
  int _driverPageIndex = 0;
  static const int _driverPageSize = 50;
  bool _driversOnlyLoading = false;
  final List<String?> _driversServerCursorStack = <String?>[null];
  String? _driversServerNextCursor;
  bool _driversServerHasMore = false;

  List<AdminRiderRecord>? _ridersOnly;
  bool _ridersOnlyLoading = false;
  final List<String?> _ridersServerCursorStack = <String?>[null];
  String? _ridersServerNextCursor;
  bool _ridersServerHasMore = false;

  List<AdminWithdrawalRecord>? _withdrawalsOnly;
  bool _withdrawalsOnlyLoading = false;
  final List<String?> _withdrawalsServerCursorStack = <String?>[null];
  String? _withdrawalsServerNextCursor;
  bool _withdrawalsServerHasMore = false;

  List<AdminSupportTicketListItem>? _supportTicketsOnly;
  bool _supportTicketsOnlyLoading = false;
  final List<String?> _supportTicketsServerCursorStack = <String?>[null];
  String? _supportTicketsServerNextCursor;
  bool _supportTicketsServerHasMore = false;

  String _riderCityFilter = 'All';
  String _riderStatusFilter = 'All';
  String _riderSignupFilter = 'All time';
  String _riderProfileCompletenessFilter = 'Completed profiles';
  String _driverCityFilter = 'All';
  String _driverStateOrRegionFilter = 'All';
  String _driverStatusFilter = 'All';
  String _driverModelFilter = 'All';
  String _supportKindFilter = 'All';
  String _withdrawalStatusFilter = 'All';
  String _supportTicketStatusFilter = 'All';

  bool _initialDriverDeepLinkHandled = false;
  static const List<String> _driverDrawerTabIds = <String>[
    'overview',
    'verification',
    'wallet',
    'trips',
    'subscription',
    'violations',
    'notes',
    'audit',
  ];
  final AdminActionExecutor _actionExecutor = const AdminActionExecutor();

  @override
  void initState() {
    super.initState();
    final initTs = DateTime.now().toIso8601String();
    debugPrint('[AdminPanel] initState start t=$initTs initialSection=${widget.initialSection.name}');
    _dataService = widget.dataService ?? AdminDataService();
    _authService = widget.authService ?? AdminAuthService();
    _section = widget.initialSection;
    _snapshot = _dataService.cachedSnapshot;
    _isLoading = _snapshot == null;
    debugPrint(
      '[AdminPanel] init section=${_section.name} adminUid=${widget.session.uid} adminEmail=${widget.session.email} cachedSnapshot=${_snapshot != null}',
    );

    if (_section == AdminSection.dashboard) {
      _snapshot = null;
      _isLoading = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_loadDashboardOnly());
        }
      });
    } else if (_section == AdminSection.drivers) {
      if (AdminDriversRouteDebug.driversRouteFakeLocalDrivers) {
        _isLoading = false;
        _driversOnly = _adminDebugFakeDrivers();
        _driversOnlyLoading = false;
        _recomputeDriverFilter();
        debugPrint('[AdminPanel] drivers fake local rows=${_driversOnly!.length}');
      } else {
        _isLoading = false;
        _driversOnlyLoading = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          debugPrint(
            '[AdminPanel] postFrameCallback scheduling drivers fetch t=${DateTime.now().toIso8601String()}',
          );
          if (mounted) {
            unawaited(_loadDriversOnly());
          }
        });
      }
    } else if (_section == AdminSection.finance) {
      _snapshot = null;
      _isLoading = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_loadDashboardOnly());
        }
      });
    } else if (_section == AdminSection.withdrawals) {
      _isLoading = false;
      _withdrawalsOnlyLoading = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_loadWithdrawalsOnly());
        }
      });
    } else if (_section == AdminSection.support) {
      _isLoading = false;
      _supportTicketsOnlyLoading = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_loadSupportTicketsOnly());
        }
      });
    } else if (_section == AdminSection.riders) {
      _isLoading = false;
      _ridersOnlyLoading = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_loadRidersOnly());
        }
      });
    } else if (_section == AdminSection.trips ||
        _section == AdminSection.liveOperations ||
        _section == AdminSection.systemHealth ||
        _section == AdminSection.paymentIntents ||
        _section == AdminSection.auditLogs ||
        _section == AdminSection.regions ||
        _section == AdminSection.serviceAreas ||
        _section == AdminSection.merchants) {
      _isLoading = false;
    } else {
      _loadSnapshot();
    }
    if (widget.enableRealtimeBadgeListeners) {
      _startRealtimeBadgeListeners();
    }
    debugPrint(
      '[AdminPanel] initState end t=${DateTime.now().toIso8601String()}',
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _tryConsumeInitialDriverDeepLink();
      }
    });
  }

  @override
  void dispose() {
    _badgeRefreshTimer?.cancel();
    _driverSearchDebounce?.cancel();
    _riderSearchDebounce?.cancel();
    _riderSearchController.dispose();
    _driverSearchController.dispose();
    _supportSearchController.dispose();
    _withdrawalSearchController.dispose();
    _withdrawalSearchDebounce?.cancel();
    _supportInboxSearchDebounce?.cancel();
    super.dispose();
  }

  /// Loads [AdminDataService.fetchSnapshot] — **legacy giant RTDB bundle**.
  /// Prefer section loaders (`_loadDashboardOnly`, `_loadDriversOnly`, …).
  /// See `lib/admin/docs/SNAPSHOT_MIGRATION.md`.
  Future<void> _loadSnapshot() async {
    debugPrint(
      '[AdminPanel] loading snapshot for adminUid=${widget.session.uid} adminEmail=${widget.session.email} section=${_section.name} cachedSnapshot=${_snapshot != null}',
    );
    if (mounted) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      if (!_tokenRefreshedForDashboardLoad) {
        await _authService.forceTokenRefresh();
        _tokenRefreshedForDashboardLoad = true;
      }
      final snapshot = await _dataService
          .fetchSnapshot(
            adminEmail: widget.session.email,
            adminUid: widget.session.uid,
          )
          .timeout(widget.snapshotTimeout);
      if (!mounted) {
        return;
      }
      setState(() {
        _snapshot = snapshot;
        _isLoading = false;
        _driversOnly = null;
        _driversOnlyLoading = false;
        _driversServerCursorStack
          ..clear()
          ..add(null);
        _driversServerNextCursor = null;
        _driversServerHasMore = false;
        _ridersOnly = null;
        _ridersOnlyLoading = false;
        _withdrawalsOnly = null;
        _withdrawalsOnlyLoading = false;
        _withdrawalsServerCursorStack
          ..clear()
          ..add(null);
        _withdrawalsServerNextCursor = null;
        _withdrawalsServerHasMore = false;
        _supportTicketsOnly = null;
        _supportTicketsOnlyLoading = false;
        _supportTicketsServerCursorStack
          ..clear()
          ..add(null);
        _supportTicketsServerNextCursor = null;
        _supportTicketsServerHasMore = false;
      });
      _syncBadgesFromSnapshot(snapshot);
      _recomputeDriverFilter();
      debugPrint(
        '[AdminPanel] snapshot loaded riders=${snapshot.riders.length} drivers=${snapshot.drivers.length} trips=${snapshot.trips.length}',
      );
    } on TimeoutException catch (error) {
      debugPrint(
        '[AdminPanel] snapshot load timeout section=${_section.name} error=$error',
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _errorMessage =
            'Unable to load ${_section.label.toLowerCase()} right now. The admin data request timed out. Try again in a moment.';
      });
    } catch (error) {
      debugPrint('[AdminPanel] snapshot load failed: $error');
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _errorMessage = _buildLoadFailureMessage(error);
      });
    }
  }

  Future<void> _loadDashboardOnly() async {
    debugPrint('[AdminPanel] _loadDashboardOnly start');
    if (mounted) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }
    try {
      if (!_tokenRefreshedForDashboardLoad) {
        await _authService.forceTokenRefresh();
        _tokenRefreshedForDashboardLoad = true;
      }
      final snapshot = await _dataService
          .fetchDashboardSnapshot(
            adminEmail: widget.session.email,
            adminUid: widget.session.uid,
          )
          .timeout(widget.snapshotTimeout);
      if (!mounted) {
        return;
      }
      setState(() {
        _snapshot = snapshot;
        _isLoading = false;
        _driversOnly = null;
        _driversOnlyLoading = false;
        _ridersOnly = null;
        _ridersOnlyLoading = false;
        _withdrawalsOnly = null;
        _withdrawalsOnlyLoading = false;
        _withdrawalsServerCursorStack
          ..clear()
          ..add(null);
        _withdrawalsServerNextCursor = null;
        _withdrawalsServerHasMore = false;
        _supportTicketsOnly = null;
        _supportTicketsOnlyLoading = false;
        _supportTicketsServerCursorStack
          ..clear()
          ..add(null);
        _supportTicketsServerNextCursor = null;
        _supportTicketsServerHasMore = false;
      });
      debugPrint('[AdminPanel] _loadDashboardOnly success');
    } on TimeoutException catch (error) {
      debugPrint('[AdminPanel] _loadDashboardOnly timeout $error');
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _errorMessage =
            'Unable to load dashboard right now. The request timed out. Try again in a moment.';
      });
    } catch (error) {
      debugPrint('[AdminPanel] _loadDashboardOnly failed: $error');
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _errorMessage = _buildLoadFailureMessage(error);
      });
    }
  }

  String _riderProfileCompletenessApiValue() {
    switch (_riderProfileCompletenessFilter) {
      case 'Incomplete registrations':
        return 'incomplete';
      case 'All':
        return 'all';
      default:
        return 'completed';
    }
  }

  Future<void> _loadRidersOnly({bool resetServerCursors = true}) async {
    debugPrint(
      '[AdminPanel] _loadRidersOnly start resetCursors=$resetServerCursors',
    );
    if (resetServerCursors) {
      _ridersServerCursorStack
        ..clear()
        ..add(null);
    }
    if (mounted) {
      setState(() {
        _ridersOnlyLoading = true;
        _errorMessage = null;
      });
    } else {
      _ridersOnlyLoading = true;
    }
    try {
      if (!_tokenRefreshedForDashboardLoad) {
        await _authService.forceTokenRefresh();
        _tokenRefreshedForDashboardLoad = true;
      }
      final cursor = _ridersServerCursorStack.isEmpty
          ? null
          : _ridersServerCursorStack.last;
      final query = AdminListQuery(
        search: _riderSearchController.text.trim(),
        city: _riderCityFilter,
        stateOrRegion: 'All',
        status: _riderStatusFilter,
        verificationStatus: 'All',
        profileCompleteness: _riderProfileCompletenessApiValue(),
      );
      final page = await _dataService
          .fetchRidersPageForAdmin(
            cursor: cursor,
            limit: _driverPageSize,
            query: query,
          )
          .timeout(widget.snapshotTimeout);
      // ignore: avoid_print
      print(
        '[AdminRidersDebug] panel load complete riders=${page.riders.length} '
        'hasMore=${page.hasMore} nextCursor=${page.nextCursor}',
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _ridersOnly = page.riders;
        _ridersServerNextCursor = page.nextCursor;
        _ridersServerHasMore = page.hasMore;
        _ridersOnlyLoading = false;
      });
    } on TimeoutException catch (error) {
      debugPrint('[AdminPanel] _loadRidersOnly timeout $error');
      if (!mounted) {
        return;
      }
      setState(() {
        _ridersOnlyLoading = false;
        _errorMessage = 'Rider list timed out. Try refreshing.';
      });
    } catch (error) {
      debugPrint('[AdminPanel] _loadRidersOnly failed: $error');
      if (!mounted) {
        return;
      }
      setState(() {
        _ridersOnlyLoading = false;
        _errorMessage = _buildLoadFailureMessage(error);
      });
    }
  }

  Future<void> _loadWithdrawalsOnly({bool resetServerCursors = true}) async {
    if (resetServerCursors) {
      _withdrawalsServerCursorStack
        ..clear()
        ..add(null);
    }
    if (mounted) {
      setState(() {
        _withdrawalsOnlyLoading = true;
        _errorMessage = null;
      });
    } else {
      _withdrawalsOnlyLoading = true;
    }
    try {
      if (!_tokenRefreshedForDashboardLoad) {
        await _authService.forceTokenRefresh();
        _tokenRefreshedForDashboardLoad = true;
      }
      final cursor = _withdrawalsServerCursorStack.isEmpty
          ? null
          : _withdrawalsServerCursorStack.last;
      final query = AdminListQuery(
        search: _withdrawalSearchController.text.trim(),
        city: 'All',
        stateOrRegion: 'All',
        status: _withdrawalStatusFilter,
        verificationStatus: 'All',
      );
      final page = await _dataService
          .fetchWithdrawalsPageForAdmin(
            cursor: cursor,
            limit: _driverPageSize,
            query: query,
          )
          .timeout(widget.snapshotTimeout);
      if (!mounted) {
        return;
      }
      setState(() {
        _withdrawalsOnly = page.withdrawals;
        _withdrawalsServerNextCursor = page.nextCursor;
        _withdrawalsServerHasMore = page.hasMore;
        _withdrawalsOnlyLoading = false;
      });
    } on TimeoutException catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _withdrawalsOnlyLoading = false;
        _errorMessage = 'Withdrawals timed out. Try again.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _withdrawalsOnlyLoading = false;
        _errorMessage = _buildLoadFailureMessage(error);
      });
    }
  }

  Future<void> _loadSupportTicketsOnly({bool resetServerCursors = true}) async {
    if (resetServerCursors) {
      _supportTicketsServerCursorStack
        ..clear()
        ..add(null);
    }
    if (mounted) {
      setState(() {
        _supportTicketsOnlyLoading = true;
        _errorMessage = null;
      });
    } else {
      _supportTicketsOnlyLoading = true;
    }
    try {
      if (!_tokenRefreshedForDashboardLoad) {
        await _authService.forceTokenRefresh();
        _tokenRefreshedForDashboardLoad = true;
      }
      final cursor = _supportTicketsServerCursorStack.isEmpty
          ? null
          : _supportTicketsServerCursorStack.last;
      final query = AdminListQuery(
        search: _supportSearchController.text.trim(),
        city: 'All',
        stateOrRegion: 'All',
        status: _supportTicketStatusFilter,
        verificationStatus: 'All',
      );
      final page = await _dataService
          .fetchSupportTicketsPageForAdmin(
            cursor: cursor,
            limit: _driverPageSize,
            query: query,
          )
          .timeout(widget.snapshotTimeout);
      if (!mounted) {
        return;
      }
      setState(() {
        _supportTicketsOnly = page.tickets;
        _supportTicketsServerNextCursor = page.nextCursor;
        _supportTicketsServerHasMore = page.hasMore;
        _supportTicketsOnlyLoading = false;
      });
    } on TimeoutException catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _supportTicketsOnlyLoading = false;
        _errorMessage = 'Support inbox timed out. Try again.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _supportTicketsOnlyLoading = false;
        _errorMessage = _buildLoadFailureMessage(error);
      });
    }
  }

  void _beginWithdrawalsSectionLoad() {
    _withdrawalsServerCursorStack
      ..clear()
      ..add(null);
    if (mounted) {
      setState(() {
        _withdrawalsOnly = null;
        _withdrawalsOnlyLoading = true;
        _errorMessage = null;
        _withdrawalsServerNextCursor = null;
        _withdrawalsServerHasMore = false;
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_loadWithdrawalsOnly());
      }
    });
  }

  void _beginSupportTicketsSectionLoad() {
    _supportTicketsServerCursorStack
      ..clear()
      ..add(null);
    if (mounted) {
      setState(() {
        _supportTicketsOnly = null;
        _supportTicketsOnlyLoading = true;
        _errorMessage = null;
        _supportTicketsServerNextCursor = null;
        _supportTicketsServerHasMore = false;
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_loadSupportTicketsOnly());
      }
    });
  }

  void _onWithdrawalsServerNextPage() {
    final c = _withdrawalsServerNextCursor;
    if (c == null || !_withdrawalsServerHasMore || _withdrawalsOnlyLoading) {
      return;
    }
    setState(() {
      _withdrawalsServerCursorStack.add(c);
    });
    unawaited(_loadWithdrawalsOnly(resetServerCursors: false));
  }

  void _onWithdrawalsServerPrevPage() {
    if (_withdrawalsServerCursorStack.length <= 1 || _withdrawalsOnlyLoading) {
      return;
    }
    setState(() {
      _withdrawalsServerCursorStack.removeLast();
    });
    unawaited(_loadWithdrawalsOnly(resetServerCursors: false));
  }

  void _onSupportTicketsServerNextPage() {
    final c = _supportTicketsServerNextCursor;
    if (c == null || !_supportTicketsServerHasMore || _supportTicketsOnlyLoading) {
      return;
    }
    setState(() {
      _supportTicketsServerCursorStack.add(c);
    });
    unawaited(_loadSupportTicketsOnly(resetServerCursors: false));
  }

  void _onSupportTicketsServerPrevPage() {
    if (_supportTicketsServerCursorStack.length <= 1 ||
        _supportTicketsOnlyLoading) {
      return;
    }
    setState(() {
      _supportTicketsServerCursorStack.removeLast();
    });
    unawaited(_loadSupportTicketsOnly(resetServerCursors: false));
  }

  AdminListQuery _driverListQueryForCallable() {
    return AdminListQuery(
      search: _driverSearchController.text.trim(),
      city: _driverCityFilter,
      stateOrRegion: _driverStateOrRegionFilter,
      status: _driverStatusFilter,
      verificationStatus: 'All',
      monetizationModel: _driverModelFilter,
    );
  }

  /// Lightweight loader for `/admin/drivers` — uses [AdminDataService.fetchDriversPageForAdmin]
  /// (server-paged) unless debug flags override.
  Future<void> _loadDriversOnly({bool resetServerCursors = true}) async {
    final t0 = DateTime.now().millisecondsSinceEpoch;
    debugPrint(
      '[AdminPanel] _loadDriversOnly start resetCursors=$resetServerCursors t=$t0',
    );
    if (resetServerCursors) {
      _driversServerCursorStack
        ..clear()
        ..add(null);
    }
    if (mounted) {
      setState(() {
        _driversOnlyLoading = true;
        _errorMessage = null;
      });
    } else {
      _driversOnlyLoading = true;
    }
    try {
      if (!_tokenRefreshedForDashboardLoad) {
        final tAuth0 = DateTime.now().millisecondsSinceEpoch;
        await _authService.forceTokenRefresh();
        _tokenRefreshedForDashboardLoad = true;
        debugPrint(
          '[AdminPanel] _loadDriversOnly forceTokenRefresh done in ${DateTime.now().millisecondsSinceEpoch - tAuth0}ms',
        );
      }
      final cursor = _driversServerCursorStack.isEmpty
          ? null
          : _driversServerCursorStack.last;
      final t1 = DateTime.now().millisecondsSinceEpoch;
      debugPrint('[AdminPanel] _loadDriversOnly calling fetchDriversPageForAdmin t=$t1');
      final page = await _dataService
          .fetchDriversPageForAdmin(
            cursor: cursor,
            limit: _driverPageSize,
            query: _driverListQueryForCallable(),
          )
          .timeout(widget.snapshotTimeout);
      final t2 = DateTime.now().millisecondsSinceEpoch;
      debugPrint(
        '[AdminPanel] _loadDriversOnly page received rows=${page.drivers.length} '
        'hasMore=${page.hasMore} next=${page.nextCursor} in ${t2 - t1}ms total=${t2 - t0}ms',
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _driversOnly = page.drivers;
        _driversServerNextCursor = page.nextCursor;
        _driversServerHasMore = page.hasMore;
        _driversOnlyLoading = false;
      });
      _recomputeDriverFilter();
      debugPrint(
        '[AdminPanel] _buildDriversSection data ready t=${DateTime.now().toIso8601String()}',
      );
      _tryConsumeInitialDriverDeepLink();
    } on TimeoutException catch (error) {
      debugPrint('[AdminPanel] _loadDriversOnly timeout error=$error');
      if (!mounted) {
        return;
      }
      setState(() {
        _driversOnlyLoading = false;
        _errorMessage = 'Driver list timed out. Try refreshing.';
      });
    } catch (error) {
      debugPrint('[AdminPanel] _loadDriversOnly failed: $error');
      if (!mounted) {
        return;
      }
      setState(() {
        _driversOnlyLoading = false;
        _errorMessage = _buildLoadFailureMessage(error);
      });
    }
  }

  void _beginRidersSectionLoad() {
    _ridersServerCursorStack
      ..clear()
      ..add(null);
    if (mounted) {
      setState(() {
        _ridersOnly = null;
        _ridersOnlyLoading = true;
        _errorMessage = null;
        _ridersServerNextCursor = null;
        _ridersServerHasMore = false;
      });
    } else {
      _ridersOnly = null;
      _ridersOnlyLoading = true;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_loadRidersOnly(resetServerCursors: false));
      }
    });
  }

  void _onRidersServerNextPage() {
    final String? c = _ridersServerNextCursor;
    if (c == null || !_ridersServerHasMore || _ridersOnlyLoading) {
      return;
    }
    setState(() {
      _ridersServerCursorStack.add(c);
    });
    unawaited(_loadRidersOnly(resetServerCursors: false));
  }

  void _onRidersServerPrevPage() {
    if (_ridersServerCursorStack.length <= 1 || _ridersOnlyLoading) {
      return;
    }
    setState(() {
      _ridersServerCursorStack.removeLast();
    });
    unawaited(_loadRidersOnly(resetServerCursors: false));
  }

  void _beginDriversSectionLoad() {
    if (AdminDriversRouteDebug.driversRouteFakeLocalDrivers) {
      return;
    }
    _driversServerCursorStack
      ..clear()
      ..add(null);
    if (mounted) {
      setState(() {
        _driversOnly = null;
        _driversOnlyLoading = true;
        _errorMessage = null;
        _driversServerNextCursor = null;
        _driversServerHasMore = false;
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      debugPrint(
        '[AdminPanel] _beginDriversSectionLoad postFrame t=${DateTime.now().toIso8601String()}',
      );
      if (mounted) {
        unawaited(_loadDriversOnly(resetServerCursors: false));
      }
    });
  }

  void _onDriversServerNextPage() {
    final String? c = _driversServerNextCursor;
    if (c == null || !_driversServerHasMore || _driversOnlyLoading) {
      return;
    }
    setState(() {
      _driversServerCursorStack.add(c);
    });
    unawaited(_loadDriversOnly(resetServerCursors: false));
  }

  void _onDriversServerPrevPage() {
    if (_driversServerCursorStack.length <= 1 || _driversOnlyLoading) {
      return;
    }
    setState(() {
      _driversServerCursorStack.removeLast();
    });
    unawaited(_loadDriversOnly(resetServerCursors: false));
  }

  /// Computes filtered drivers outside build() and stores in [_cachedFilteredDrivers].
  /// Must be called whenever drivers data, search query, or filter values change.
  void _recomputeDriverFilter() {
    final tf0 = DateTime.now().millisecondsSinceEpoch;
    final drivers = _driversOnly ?? _snapshot?.drivers ?? <AdminDriverRecord>[];
    final bool serverFilteredDrivers = _driversOnly != null &&
        _snapshot == null &&
        _section == AdminSection.drivers;
    final query = _driverSearchController.text.trim().toLowerCase();
    final filtered = drivers.where((AdminDriverRecord driver) {
      if (serverFilteredDrivers) {
        return true;
      }
      final matchesQuery = query.isEmpty ||
          driver.id.toLowerCase().contains(query) ||
          driver.name.toLowerCase().contains(query) ||
          driver.phone.toLowerCase().contains(query) ||
          driver.city.toLowerCase().contains(query) ||
          driver.stateOrRegion.toLowerCase().contains(query) ||
          driver.vehicleName.toLowerCase().contains(query) ||
          driver.plateNumber.toLowerCase().contains(query);
      final matchesCity =
          _driverCityFilter == 'All' || driver.city == _driverCityFilter;
      final matchesStateOrRegion = _driverStateOrRegionFilter == 'All' ||
          driver.stateOrRegion == _driverStateOrRegionFilter;
      final matchesStatus = _driverStatusFilter == 'All' ||
          driver.accountStatus == _driverStatusFilter;
      final matchesModel = _driverModelFilter == 'All' ||
          driver.monetizationModel == _driverModelFilter;
      return matchesQuery &&
          matchesCity &&
          matchesStateOrRegion &&
          matchesStatus &&
          matchesModel;
    }).toList();
    final tf1 = DateTime.now().millisecondsSinceEpoch;
    final visible = filtered.length.clamp(0, _driverPageSize);
    debugPrint('[AdminPanel] _recomputeDriverFilter total=${drivers.length} filtered=${filtered.length} visible=$visible in ${tf1 - tf0}ms');
    if (mounted) {
      setState(() {
        _cachedFilteredDrivers = filtered;
        _driverPageIndex = 0;
      });
    } else {
      _cachedFilteredDrivers = filtered;
      _driverPageIndex = 0;
    }
  }

  /// Section-aware refresh: drivers section uses the lightweight loader;
  /// all other sections use the full snapshot loader.
  Future<void> _refresh() async {
    if (_section == AdminSection.dashboard) {
      await _loadDashboardOnly();
    } else if (_section == AdminSection.drivers) {
      if (AdminDriversRouteDebug.driversRouteFakeLocalDrivers) {
        return;
      }
      if (_driversOnly != null || _snapshot == null) {
        await _loadDriversOnly();
      } else {
        await _loadSnapshot();
      }
    } else if (_section == AdminSection.riders) {
      if (_ridersOnly != null || _snapshot == null) {
        await _loadRidersOnly();
      } else {
        await _loadSnapshot();
      }
    } else if (_section == AdminSection.withdrawals) {
      await _loadWithdrawalsOnly(resetServerCursors: false);
    } else if (_section == AdminSection.support) {
      await _loadSupportTicketsOnly(resetServerCursors: false);
    } else if (_section == AdminSection.finance) {
      await _loadDashboardOnly();
    } else if (_section == AdminSection.auditLogs ||
        _section == AdminSection.paymentIntents ||
        _section == AdminSection.liveOperations ||
        _section == AdminSection.systemHealth ||
        _section == AdminSection.trips ||
        _section == AdminSection.regions ||
        _section == AdminSection.serviceAreas ||
        _section == AdminSection.merchants) {
      return;
    } else {
      await _loadSnapshot();
    }
  }

  Future<void> _logout() async {
    await _authService.signOut();
    if (!mounted) {
      return;
    }
    Navigator.of(context).pushNamedAndRemoveUntil(
      widget.loginRoute,
      (Route<dynamic> route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AdminShell(
      section: _section,
      onSectionSelected: _handleSectionSelected,
      session: widget.session,
      isLoading: _isLoading,
      lastUpdated: _snapshot?.fetchedAt,
      onRefresh: _refresh,
      onLogout: _logout,
      liveDataSections: _snapshot?.liveDataSections ?? const <String, bool>{},
      sidebarBadgeCounts: _sidebarBadgeCounts,
      pendingNotifications: _pendingNotifications
          .map(
            (item) => AdminPendingNotification(
              title: item.title,
              subtitle: item.subtitle,
              section: item.section,
            ),
          )
          .toList(growable: false),
      onNotificationSelected: _handleSectionSelected,
      child: _buildBody(),
    );
  }

  void _startRealtimeBadgeListeners() {
    _badgeRefreshTimer?.cancel();
    unawaited(_refreshSidebarBadgesFromCallable());
    _badgeRefreshTimer = Timer.periodic(const Duration(seconds: 45), (_) {
      unawaited(_refreshSidebarBadgesFromCallable());
    });
  }

  Future<void> _refreshSidebarBadgesFromCallable() async {
    if (!widget.enableRealtimeBadgeListeners || !mounted) {
      return;
    }
    try {
      final callable = FirebaseFunctions.instanceFor(
        region: 'us-central1',
      ).httpsCallable(
        'adminGetSidebarBadgeCounts',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 20)),
      );
      final result = await callable.call(<String, dynamic>{});
      final data = result.data is Map
          ? Map<String, dynamic>.from(result.data as Map)
          : <String, dynamic>{};
      if (data['success'] != true || !mounted) {
        return;
      }
      _setBadgeCount(
        AdminSection.subscriptions,
        _badgeInt(data['subscription_drivers_pending']),
      );
      _setBadgeCount(
        AdminSection.trips,
        _badgeInt(data['trips_payment_pending_confirmation']),
      );
      _setBadgeCount(
        AdminSection.support,
        _badgeInt(data['support_tickets_open']),
      );
    } catch (error) {
      debugPrint('[AdminPanel] badge refresh failed: $error');
    }
  }

  int _badgeInt(dynamic value) {
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString().trim() ?? '') ?? 0;
  }

  void _syncBadgesFromSnapshot(AdminPanelSnapshot snapshot) {
    var ridersPending = 0;
    for (final AdminRiderRecord r in snapshot.riders) {
      final v = r.verificationStatus.toLowerCase();
      if (v == 'pending' || v == 'submitted' || v == 'in_review') {
        ridersPending += 1;
      }
    }
    _setBadgeCount(AdminSection.riders, ridersPending);

    var driverVerificationPending = 0;
    var subscriptionPending = 0;
    for (final AdminDriverRecord d in snapshot.drivers) {
      final v = d.verificationStatus.toLowerCase();
      if (v == 'pending' || v == 'submitted' || v == 'in_review') {
        driverVerificationPending += 1;
      }
      final sub = d.subscriptionStatus.toLowerCase();
      final hasProof =
          '${d.rawData['subscription_proof_url'] ?? ''}'.trim().isNotEmpty;
      if (d.rawData['subscription_pending'] == true ||
          sub == 'pending' ||
          sub == 'pending_review' ||
          hasProof) {
        subscriptionPending += 1;
      }
    }
    _setBadgeCount(AdminSection.verification, driverVerificationPending);
    _setBadgeCount(AdminSection.subscriptions, subscriptionPending);

    var tripsPending = 0;
    for (final AdminTripRecord t in snapshot.trips) {
      final p =
          (t.rawData['payment_status'] as String? ?? '').toLowerCase().replaceAll(RegExp(r'[\s-]+'), '_');
      if (p == 'pending_manual_confirmation' ||
          p == 'pending_review' ||
          p == 'pending') {
        tripsPending += 1;
      }
    }
    _setBadgeCount(AdminSection.trips, tripsPending);
  }

  void _setBadgeCount(AdminSection section, int count) {
    if (!mounted) {
      return;
    }
    if ((_sidebarBadgeCounts[section] ?? -1) == count) {
      return;
    }
    setState(() {
      _sidebarBadgeCounts = <AdminSection, int>{
        ..._sidebarBadgeCounts,
        section: count,
      };
    });
  }

  void _handleSectionSelected(AdminSection next) {
    debugPrint('[AdminPanel] section change ${_section.name} -> ${next.name}');
    final routeForSection = widget.routeForSection;
    if (routeForSection != null) {
      final nextRoute = routeForSection(next);
      if (next == AdminSection.liveOperations) {
        debugPrint('[LIVE_OPS][ROUTE] resolved section=liveOperations');
      }
      if (next == AdminSection.auditLogs) {
        debugPrint('[AUDIT_LOGS][ROUTE] resolved section=auditLogs');
      }
      if (kIsWeb) {
        if (_section != next) {
          setState(() {
            _section = next;
          });
          if (next == AdminSection.drivers &&
              !AdminDriversRouteDebug.driversRouteFakeLocalDrivers &&
              _driversOnly == null) {
            _beginDriversSectionLoad();
          }
          if (next == AdminSection.riders && _ridersOnly == null) {
            _beginRidersSectionLoad();
          }
          if (next == AdminSection.withdrawals) {
            if (_withdrawalsOnly == null) {
              _beginWithdrawalsSectionLoad();
            } else {
              unawaited(_loadWithdrawalsOnly(resetServerCursors: true));
            }
          }
          if (next == AdminSection.support) {
            if (_supportTicketsOnly == null) {
              _beginSupportTicketsSectionLoad();
            } else {
              unawaited(_loadSupportTicketsOnly(resetServerCursors: true));
            }
          }
          if (next == AdminSection.finance && _snapshot == null) {
            unawaited(_loadDashboardOnly());
          }
        }
        SystemNavigator.routeInformationUpdated(uri: Uri.parse(nextRoute));
        return;
      }
      final currentRoute = ModalRoute.of(context)?.settings.name ?? '';
      if (currentRoute != nextRoute) {
        Navigator.of(context).pushReplacementNamed(nextRoute);
        return;
      }
    }
    setState(() {
      _section = next;
    });
    if (next == AdminSection.drivers &&
        !AdminDriversRouteDebug.driversRouteFakeLocalDrivers &&
        _driversOnly == null) {
      _beginDriversSectionLoad();
    }
    if (next == AdminSection.riders && _ridersOnly == null) {
      _beginRidersSectionLoad();
    }
    if (next == AdminSection.withdrawals) {
      if (_withdrawalsOnly == null) {
        _beginWithdrawalsSectionLoad();
      } else {
        unawaited(_loadWithdrawalsOnly(resetServerCursors: true));
      }
    }
    if (next == AdminSection.support) {
      if (_supportTicketsOnly == null) {
        _beginSupportTicketsSectionLoad();
      } else {
        unawaited(_loadSupportTicketsOnly(resetServerCursors: true));
      }
    }
    if (next == AdminSection.finance && _snapshot == null) {
      unawaited(_loadDashboardOnly());
    }
  }

  Widget _buildBody() {
    final String? requiredPerm = requiredPermissionForSection(_section);
    if (requiredPerm != null && !widget.session.hasPermission(requiredPerm)) {
      return Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: AdminSurfaceCard(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    'Access restricted',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: AdminThemeTokens.ink,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'You do not have permission for this action.',
                    style: TextStyle(height: 1.45, color: Color(0xFF5C564D)),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'This section requires “$requiredPerm”.',
                    style: const TextStyle(
                      fontSize: 13,
                      color: AdminThemeTokens.slate,
                    ),
                  ),
                  const SizedBox(height: 20),
                  AdminPrimaryButton(
                    label: 'Go to dashboard',
                    onPressed: () => _handleSectionSelected(AdminSection.dashboard),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (_section == AdminSection.regions ||
        _section == AdminSection.serviceAreas ||
        _section == AdminSection.merchants ||
        _section == AdminSection.trips ||
        _section == AdminSection.liveOperations ||
        _section == AdminSection.systemHealth ||
        _section == AdminSection.paymentIntents ||
        _section == AdminSection.auditLogs) {
      if (_section == AdminSection.liveOperations) {
        debugPrint('[LIVE_OPS][AdminPanel] routing to AdminLiveOpsDashboardScreen');
      }
      if (_section == AdminSection.auditLogs) {
        debugPrint('[AUDIT_LOGS][PANEL] routing to AdminAuditLogsScreen');
      }
      if (_section == AdminSection.paymentIntents) {
        debugPrint('[PAYMENT_INTENTS][PANEL] routing to AdminPaymentIntentsScreen');
      }
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 240),
        child: SingleChildScrollView(
          key: ValueKey<AdminSection>(_section),
          child: Align(
            alignment: Alignment.topLeft,
            child: switch (_section) {
              AdminSection.regions =>
                  AdminRolloutRegionsScreen(session: widget.session),
              AdminSection.serviceAreas =>
                  AdminServiceAreasScreen(
                    dataService: _dataService,
                    session: widget.session,
                  ),
              AdminSection.merchants =>
                  AdminMerchantsScreen(session: widget.session),
              AdminSection.trips => AdminLiveOperationsScreen(
                    dataService: _dataService,
                    session: widget.session,
                  ),
              AdminSection.liveOperations =>
                  AdminLiveOpsDashboardScreen(
                    dataService: _dataService,
                  ),
              AdminSection.systemHealth => AdminSystemHealthScreen(
                    dataService: _dataService,
                  ),
              AdminSection.paymentIntents => AdminPaymentIntentsScreen(
                    dataService: _dataService,
                    session: widget.session,
                  ),
              AdminSection.auditLogs => AdminAuditLogsScreen(
                    dataService: _dataService,
                  ),
              _ => const SizedBox.shrink(),
            },
          ),
        ),
      );
    }

    // `/admin/drivers` without a full panel snapshot: first frame shows shell + spinner;
    // drivers load post-frame (see [initState] / [_beginDriversSectionLoad]).
    if (_section == AdminSection.drivers && _snapshot == null) {
      if (_driversOnlyLoading && _driversOnly == null) {
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: CircularProgressIndicator(),
          ),
        );
      }
      if ((_errorMessage?.trim().isNotEmpty ?? false) &&
          _driversOnly == null &&
          !_driversOnlyLoading) {
        return _buildUnavailableState(
          title: 'Unable to load drivers right now',
          message: _errorMessage!.trim(),
        );
      }
      if (_driversOnly != null && !_driversOnlyLoading) {
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 240),
          child: SingleChildScrollView(
            key: const ValueKey<AdminSection>(AdminSection.drivers),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (_errorMessage?.trim().isNotEmpty ?? false) ...<Widget>[
                  _buildRefreshNotice(_errorMessage!),
                  const SizedBox(height: 16),
                ],
                _buildDriversSection(),
              ],
            ),
          ),
        );
      }
    }

    // Drivers section backed by a full snapshot (e.g. opened Dashboard first).
    final driversReady =
        _driversOnly != null || (_snapshot?.drivers.isNotEmpty ?? false);
    if (_section == AdminSection.drivers && !_isLoading && driversReady) {
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 240),
        child: SingleChildScrollView(
          key: const ValueKey<AdminSection>(AdminSection.drivers),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (_errorMessage?.trim().isNotEmpty ?? false) ...<Widget>[
                _buildRefreshNotice(_errorMessage!),
                const SizedBox(height: 16),
              ],
              _buildDriversSection(),
            ],
          ),
        ),
      );
    }

    if (_section == AdminSection.riders) {
      if (_ridersOnlyLoading && _ridersOnly == null) {
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: CircularProgressIndicator(),
          ),
        );
      }
      if ((_errorMessage?.trim().isNotEmpty ?? false) &&
          _ridersOnly == null &&
          !_ridersOnlyLoading) {
        return _buildUnavailableState(
          title: 'Unable to load riders right now',
          message: _errorMessage!.trim(),
        );
      }
      final ridersDataReady = _ridersOnly != null ||
          (_snapshot != null && !_ridersOnlyLoading);
      if (!_isLoading && ridersDataReady) {
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 240),
          child: SingleChildScrollView(
            key: const ValueKey<AdminSection>(AdminSection.riders),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (_errorMessage?.trim().isNotEmpty ?? false) ...<Widget>[
                  _buildRefreshNotice(_errorMessage!),
                  const SizedBox(height: 16),
                ],
                _buildRidersSection(snapshot: _snapshot),
              ],
            ),
          ),
        );
      }
    }

    if (_section == AdminSection.withdrawals) {
      if (_withdrawalsOnlyLoading && _withdrawalsOnly == null) {
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: CircularProgressIndicator(),
          ),
        );
      }
      if ((_errorMessage?.trim().isNotEmpty ?? false) &&
          _withdrawalsOnly == null &&
          !_withdrawalsOnlyLoading) {
        return _buildUnavailableState(
          title: 'Unable to load withdrawals right now',
          message: _errorMessage!.trim(),
        );
      }
      if (_withdrawalsOnly != null) {
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 240),
          child: SingleChildScrollView(
            key: const ValueKey<AdminSection>(AdminSection.withdrawals),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (_withdrawalsOnlyLoading) ...<Widget>[
                  const LinearProgressIndicator(minHeight: 3),
                  const SizedBox(height: 12),
                ],
                if (_errorMessage?.trim().isNotEmpty ?? false) ...<Widget>[
                  _buildRefreshNotice(_errorMessage!),
                  const SizedBox(height: 16),
                ],
                _buildWithdrawalsSection(),
              ],
            ),
          ),
        );
      }
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (_section == AdminSection.support) {
      if (_supportTicketsOnlyLoading && _supportTicketsOnly == null) {
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: CircularProgressIndicator(),
          ),
        );
      }
      if ((_errorMessage?.trim().isNotEmpty ?? false) &&
          _supportTicketsOnly == null &&
          !_supportTicketsOnlyLoading) {
        return _buildUnavailableState(
          title: 'Unable to load support inbox right now',
          message: _errorMessage!.trim(),
        );
      }
      if (_supportTicketsOnly != null) {
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 240),
          child: SingleChildScrollView(
            key: const ValueKey<AdminSection>(AdminSection.support),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (_supportTicketsOnlyLoading) ...<Widget>[
                  const LinearProgressIndicator(minHeight: 3),
                  const SizedBox(height: 12),
                ],
                if (_errorMessage?.trim().isNotEmpty ?? false) ...<Widget>[
                  _buildRefreshNotice(_errorMessage!),
                  const SizedBox(height: 16),
                ],
                _buildSupportTicketsAdminSection(),
              ],
            ),
          ),
        );
      }
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (_snapshot == null && _isLoading) {
      return AdminEmptyState(
        title: 'Loading ${_section.label.toLowerCase()}',
        message:
            'NexRide Admin is querying the live backend for ${_section.label.toLowerCase()} data.',
        icon: Icons.sync_rounded,
      );
    }

    if (_snapshot == null) {
      return _buildUnavailableState(
        title: 'Unable to load ${_section.label.toLowerCase()} right now',
        message: _errorMessage ??
            'The admin shell is ready, but we could not read platform data yet.',
      );
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 240),
      child: SingleChildScrollView(
        key: ValueKey<AdminSection>(_section),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (_errorMessage?.trim().isNotEmpty ?? false) ...<Widget>[
              _buildRefreshNotice(_errorMessage!),
              const SizedBox(height: 16),
            ],
            switch (_section) {
              AdminSection.dashboard => _buildDashboardSection(_snapshot!),
              AdminSection.riders => _buildRidersSection(snapshot: _snapshot!),
              AdminSection.drivers => _buildDriversSection(),
              AdminSection.finance => _buildFinanceSection(_snapshot!),
              AdminSection.withdrawals =>
                _withdrawalsOnly != null ? _buildWithdrawalsSection() : const SizedBox.shrink(),
              AdminSection.pricing => _buildPricingSection(_snapshot!),
              AdminSection.subscriptions => _buildSubscriptionsTab(_snapshot!),
              AdminSection.verification =>
                  AdminVerificationCenterScreen(session: widget.session),
              AdminSection.support =>
                _supportTicketsOnly != null ? _buildSupportTicketsAdminSection() : const SizedBox.shrink(),
              AdminSection.regions =>
                  AdminRolloutRegionsScreen(session: widget.session),
              AdminSection.serviceAreas =>
                  AdminServiceAreasScreen(
                    dataService: _dataService,
                    session: widget.session,
                  ),
              AdminSection.merchants =>
                  AdminMerchantsScreen(session: widget.session),
              AdminSection.trips => AdminLiveOperationsScreen(
                    dataService: _dataService,
                    session: widget.session,
                  ),
              AdminSection.liveOperations =>
                  AdminLiveOpsDashboardScreen(
                    dataService: _dataService,
                  ),
              AdminSection.systemHealth => AdminSystemHealthScreen(
                    dataService: _dataService,
                  ),
              AdminSection.paymentIntents => AdminPaymentIntentsScreen(
                    dataService: _dataService,
                    session: widget.session,
                  ),
              AdminSection.auditLogs => AdminAuditLogsScreen(
                    dataService: _dataService,
                  ),
              AdminSection.settings => _buildSettingsSection(_snapshot!),
            },
          ],
        ),
      ),
    );
  }

  Widget _buildDashboardSection(AdminPanelSnapshot snapshot) {
    final metrics = snapshot.metrics;
    final metricCards = <_MetricCardEntry>[
      _MetricCardEntry(
        icon: Icons.people_alt_outlined,
        data: AdminMetricCardData(
          label: 'Total riders',
          value: formatAdminCompactNumber(metrics.totalRiders),
          caption:
              'Rider accounts with a usable display identity, a contact channel (phone or email), and a known signup timestamp. Internal, merchant, driver, and test accounts are excluded from this count.',
        ),
      ),
      _MetricCardEntry(
        icon: Icons.person_off_outlined,
        data: AdminMetricCardData(
          label: 'Incomplete registrations',
          value: formatAdminCompactNumber(metrics.incompleteRiderRegistrations),
          caption:
              'Highest sample across directory sources: accounts that look like riders but are still missing minimum profile fields.',
        ),
      ),
      _MetricCardEntry(
        icon: Icons.flag_outlined,
        data: AdminMetricCardData(
          label: 'Pending onboarding',
          value: formatAdminCompactNumber(metrics.pendingOnboarding),
          caption:
              'Completed profile rows where onboarding is explicitly still incomplete, when that signal exists.',
        ),
      ),
      _MetricCardEntry(
        icon: Icons.storefront_outlined,
        data: AdminMetricCardData(
          label: 'Total merchants',
          value: formatAdminCompactNumber(metrics.totalMerchants),
          caption: 'Merchant storefront profiles in Firestore.',
        ),
      ),
      _MetricCardEntry(
        icon: Icons.badge_outlined,
        data: AdminMetricCardData(
          label: 'Total drivers',
          value: formatAdminCompactNumber(metrics.totalDrivers),
          caption: 'Driver profiles currently available in the backend.',
        ),
      ),
      _MetricCardEntry(
        icon: Icons.wifi_tethering_outlined,
        data: AdminMetricCardData(
          label: 'Drivers online',
          value: formatAdminCompactNumber(metrics.activeDriversOnline),
          caption: 'Accounts reporting live online availability right now.',
        ),
      ),
      _MetricCardEntry(
        icon: Icons.alt_route_rounded,
        data: AdminMetricCardData(
          label: 'Ongoing trips',
          value: formatAdminCompactNumber(metrics.ongoingTrips),
          caption:
              'Trips currently requested, assigned, accepted, arrived, or started.',
        ),
      ),
      _MetricCardEntry(
        icon: Icons.check_circle_outline_rounded,
        data: AdminMetricCardData(
          label: 'Completed trips',
          value: formatAdminCompactNumber(metrics.completedTrips),
          caption: 'Trips marked completed in the live ride flow.',
        ),
      ),
      _MetricCardEntry(
        icon: Icons.cancel_outlined,
        data: AdminMetricCardData(
          label: 'Cancelled trips',
          value: formatAdminCompactNumber(metrics.cancelledTrips),
          caption: 'Trips that exited the lifecycle as cancelled.',
        ),
      ),
      _MetricCardEntry(
        icon: Icons.today_outlined,
        data: AdminMetricCardData(
          label: 'Today’s revenue',
          value: formatAdminCurrency(metrics.todaysRevenue),
          caption:
              'Platform revenue recognized from today’s trip commissions and new subscriptions.',
        ),
      ),
      _MetricCardEntry(
        icon: Icons.account_balance_outlined,
        data: AdminMetricCardData(
          label: 'Platform revenue',
          value: formatAdminCurrency(metrics.totalPlatformRevenue),
          caption:
              'Commissions plus subscription revenue currently visible from backend records.',
        ),
      ),
      _MetricCardEntry(
        icon: Icons.payments_outlined,
        data: AdminMetricCardData(
          label: 'Driver payouts',
          value: formatAdminCurrency(metrics.totalDriverPayouts),
          caption:
              'Net trip earnings allocated to drivers from completed rides.',
        ),
      ),
      _MetricCardEntry(
        icon: Icons.account_balance_wallet_outlined,
        data: AdminMetricCardData(
          label: 'Pending withdrawals',
          value: formatAdminCurrency(metrics.pendingWithdrawals),
          caption: 'Withdrawal requests still pending or in processing.',
        ),
      ),
      _MetricCardEntry(
        icon: Icons.workspace_premium_outlined,
        data: AdminMetricCardData(
          label: 'Subscription drivers',
          value: formatAdminCompactNumber(metrics.subscriptionDriversCount),
          caption:
              'Drivers currently operating under active subscription monetization.',
        ),
      ),
      _MetricCardEntry(
        icon: Icons.percent_rounded,
        data: AdminMetricCardData(
          label: 'Commission drivers',
          value: formatAdminCompactNumber(metrics.commissionDriversCount),
          caption: 'Drivers currently monetized through trip commissions.',
        ),
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        AdminSummaryBanner(
          title: 'NexRide Control Center',
          subtitle:
              'Live platform visibility across riders, drivers, trips, revenue, withdrawals, compliance, and issue management.',
          kpis: <String, String>{
            'Gross bookings': formatAdminCurrency(metrics.totalGrossBookings),
            'Commissions': formatAdminCurrency(metrics.totalCommissionsEarned),
            'Subscription revenue':
                formatAdminCurrency(metrics.subscriptionRevenue),
            'Last sync': formatAdminDateTime(snapshot.fetchedAt),
          },
        ),
        const SizedBox(height: 20),
        _buildMetricGrid(metricCards),
        const SizedBox(height: 20),
        _buildResponsiveTwoUp(
          left: AdminMultiSeriesLineChartCard(
            title: 'Trip trends',
            subtitle:
                'Request volume, completed rides, and cancelled rides over the last seven days.',
            points: snapshot.tripTrends,
            primaryLabel: 'Trips',
            secondaryLabel: 'Completed',
            tertiaryLabel: 'Cancelled',
          ),
          right: AdminMultiSeriesLineChartCard(
            title: 'Revenue trends',
            subtitle:
                'Gross bookings, platform revenue, and driver payouts over the last seven days.',
            points: snapshot.revenueTrends,
            primaryLabel: 'Gross',
            secondaryLabel: 'Platform',
            tertiaryLabel: 'Driver',
            valuePrefix: '₦',
          ),
        ),
        const SizedBox(height: 20),
        _buildResponsiveThreeUp(
          first: AdminInsightList(
            title: 'City performance',
            items: snapshot.cityPerformance,
          ),
          second: AdminInsightList(
            title: 'Driver growth',
            items: snapshot.driverGrowth,
          ),
          third: AdminInsightList(
            title: 'Adoption split',
            items: snapshot.adoptionBreakdown,
          ),
        ),
      ],
    );
  }

  Widget _buildRidersSection({AdminPanelSnapshot? snapshot}) {
    debugPrint(
      '[AdminPanel] riders section entered adminUid=${widget.session.uid} query="${_riderSearchController.text.trim()}" cityFilter=$_riderCityFilter statusFilter=$_riderStatusFilter signupFilter=$_riderSignupFilter profileFilter=$_riderProfileCompletenessFilter',
    );
    final allRiders = _ridersOnly ?? snapshot?.riders ?? <AdminRiderRecord>[];
    debugPrint('[AdminPanel] riders section total=${allRiders.length}');
    final cities = _cityOptions(
        allRiders.map((AdminRiderRecord rider) => rider.city));
    final query = _riderSearchController.text.trim().toLowerCase();
    final filtered = allRiders.where((AdminRiderRecord rider) {
      final matchesQuery = query.isEmpty ||
          rider.id.toLowerCase().contains(query) ||
          rider.name.toLowerCase().contains(query) ||
          rider.phone.toLowerCase().contains(query) ||
          rider.email.toLowerCase().contains(query) ||
          rider.city.toLowerCase().contains(query);
      final matchesCity =
          _riderCityFilter == 'All' || rider.city == _riderCityFilter;
      final matchesStatus =
          _riderStatusFilter == 'All' || rider.status == _riderStatusFilter;
      final matchesSignupWindow = switch (_riderSignupFilter) {
        'Last 7 days' => rider.createdAt != null &&
            rider.createdAt!
                .isAfter(DateTime.now().subtract(const Duration(days: 7))),
        'Last 30 days' => rider.createdAt != null &&
            rider.createdAt!
                .isAfter(DateTime.now().subtract(const Duration(days: 30))),
        _ => true,
      };
      final bool matchesProfileCompleteness = switch (
          _riderProfileCompletenessFilter) {
        'Incomplete registrations' => !rider.profileCompleted,
        'All' => true,
        _ => rider.profileCompleted,
      };
      return matchesQuery &&
          matchesCity &&
          matchesStatus &&
          matchesSignupWindow &&
          matchesProfileCompleteness;
    }).toList();

    if (allRiders.isEmpty) {
      debugPrint('[AdminPanel] riders section empty source=users');
      return const AdminEmptyState(
        title: 'No rider records yet',
        message:
            'The rider management UI is connected to the live backend and ready. As soon as rider records exist under users, they will appear here with search, filters, and profile details.',
        icon: Icons.person_search_outlined,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const AdminSectionHeader(
          title: 'Riders management',
          description:
              'Live rider directory (server-paged). Open a row for full profile context, identity review, account controls, or flag support to contact the rider.',
        ),
        const SizedBox(height: 16),
        _buildFilterBar(
          children: <Widget>[
            Expanded(
              flex: 2,
              child: AdminTextFilterField(
                controller: _riderSearchController,
                hintText:
                    'Search riders by name, phone, email, city, or rider ID',
                onChanged: (_) {
                  setState(() {});
                  if (_ridersOnly != null) {
                    _riderSearchDebounce?.cancel();
                    _riderSearchDebounce = Timer(const Duration(milliseconds: 350), () {
                      if (mounted) {
                        unawaited(_loadRidersOnly(resetServerCursors: true));
                      }
                    });
                  }
                },
              ),
            ),
            Expanded(
              child: AdminFilterDropdown<String>(
                value: _riderCityFilter,
                items: _dropdownItems(<String>['All', ...cities]),
                onChanged: (String? value) {
                  setState(() {
                    _riderCityFilter = value ?? 'All';
                  });
                  if (_ridersOnly != null) {
                    unawaited(_loadRidersOnly());
                  }
                },
              ),
            ),
            Expanded(
              child: AdminFilterDropdown<String>(
                value: _riderStatusFilter,
                items: _dropdownItems(<String>[
                  'All',
                  'active',
                  'suspended',
                  'inactive',
                ]),
                onChanged: (String? value) {
                  setState(() {
                    _riderStatusFilter = value ?? 'All';
                  });
                  if (_ridersOnly != null) {
                    unawaited(_loadRidersOnly());
                  }
                },
              ),
            ),
            Expanded(
              child: AdminFilterDropdown<String>(
                value: _riderProfileCompletenessFilter,
                items: _dropdownItems(<String>[
                  'Completed profiles',
                  'Incomplete registrations',
                  'All',
                ]),
                onChanged: (String? value) {
                  setState(() {
                    _riderProfileCompletenessFilter =
                        value ?? 'Completed profiles';
                  });
                  if (_ridersOnly != null) {
                    unawaited(_loadRidersOnly(resetServerCursors: true));
                  }
                },
              ),
            ),
            Expanded(
              child: AdminFilterDropdown<String>(
                value: _riderSignupFilter,
                items: _dropdownItems(<String>[
                  'All time',
                  'Last 7 days',
                  'Last 30 days',
                ]),
                onChanged: (String? value) {
                  setState(() {
                    _riderSignupFilter = value ?? 'All time';
                  });
                  if (_ridersOnly != null) {
                    unawaited(_loadRidersOnly(resetServerCursors: true));
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        AdminDataTableCard(
          heading: Row(
            children: <Widget>[
              Text(
                '${filtered.length} riders',
                style: const TextStyle(
                  color: AdminThemeTokens.ink,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: 10),
              AdminStatusChip(
                '${allRiders.length} live records',
                color: AdminThemeTokens.info,
              ),
            ],
          ),
          columns: const <DataColumn>[
            DataColumn(label: Text('Rider')),
            DataColumn(label: Text('City')),
            DataColumn(label: Text('Status')),
            DataColumn(label: Text('Verification')),
            DataColumn(label: Text('Trips')),
            DataColumn(label: Text('Wallet')),
            DataColumn(label: Text('Last active')),
            DataColumn(label: Text('Actions')),
          ],
          rows: filtered.map((AdminRiderRecord rider) {
            return DataRow(
              onSelectChanged: (_) => _showRiderDialog(rider),
              cells: <DataCell>[
                DataCell(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              rider.name,
                              style: const TextStyle(fontWeight: FontWeight.w800),
                            ),
                          ),
                          if (!rider.profileCompleted) ...<Widget>[
                            const SizedBox(width: 8),
                            AdminStatusChip(
                              'Incomplete',
                              color: AdminThemeTokens.warning,
                            ),
                          ],
                        ],
                      ),
                      Text(rider.phone.isNotEmpty ? rider.phone : rider.id),
                    ],
                  ),
                ),
                DataCell(Text(rider.city.isNotEmpty ? rider.city : 'Not set')),
                DataCell(AdminStatusChip(rider.status)),
                DataCell(AdminStatusChip(rider.verificationStatus)),
                DataCell(Text(
                  '${rider.tripSummary.completedTrips}/${rider.tripSummary.totalTrips}',
                )),
                DataCell(Text(formatAdminCurrency(rider.walletBalance))),
                DataCell(Text(formatAdminDateTime(rider.lastActiveAt))),
                DataCell(
                  Align(
                    alignment: Alignment.centerRight,
                    child: _riderAccountActions(rider),
                  ),
                ),
              ],
            );
          }).toList(),
        ),
        if (_ridersOnly != null) ...<Widget>[
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'Server paging: up to $_driverPageSize riders per request '
                  '(signup date filter applies on this page only).',
                  style: const TextStyle(
                    color: AdminThemeTokens.slate,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ),
              TextButton(
                onPressed: (_ridersOnlyLoading ||
                        _ridersServerCursorStack.length <= 1)
                    ? null
                    : _onRidersServerPrevPage,
                child: const Text('Previous server page'),
              ),
              TextButton(
                onPressed: (!_ridersServerHasMore ||
                        _ridersOnlyLoading ||
                        (_ridersServerNextCursor ?? '').isEmpty)
                    ? null
                    : _onRidersServerNextPage,
                child: const Text('Next server page'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildUnavailableState({
    required String title,
    required String message,
  }) {
    return AdminSurfaceCard(
      child: SizedBox(
        width: double.infinity,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Container(
              width: 62,
              height: 62,
              decoration: BoxDecoration(
                color: AdminThemeTokens.goldSoft,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(
                Icons.cloud_off_outlined,
                color: AdminThemeTokens.gold,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              style: const TextStyle(
                color: AdminThemeTokens.ink,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFF736C61),
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 18),
            AdminPrimaryButton(
              label: 'Retry',
              onPressed: _refresh,
              icon: Icons.refresh_rounded,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRefreshNotice(String message) {
    return AdminSurfaceCard(
      padding: const EdgeInsets.all(18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AdminThemeTokens.goldSoft,
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(
              Icons.warning_amber_rounded,
              color: AdminThemeTokens.warning,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Unable to refresh ${_section.label.toLowerCase()}',
                  style: const TextStyle(
                    color: AdminThemeTokens.ink,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  message,
                  style: const TextStyle(
                    color: Color(0xFF6D685F),
                    fontSize: 13,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          AdminGhostButton(
            label: 'Retry',
            onPressed: _refresh,
            icon: Icons.refresh_rounded,
          ),
        ],
      ),
    );
  }

  String _buildLoadFailureMessage(Object error) {
    if (_isPermissionDenied(error)) {
      return 'Your account is signed in but does not have access. Contact the NexRide system administrator.';
    }
    final details = error.toString().replaceFirst('Exception: ', '').trim();
    if (details.isNotEmpty) {
      return 'Unable to load ${_section.label.toLowerCase()} right now. $details';
    }
    return 'Unable to load ${_section.label.toLowerCase()} right now. Try again in a moment.';
  }

  bool _isPermissionDenied(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('permission-denied') ||
        message.contains('permission denied');
  }

  Widget _buildDriversSection() {
    // Use pre-computed cached data — filtering runs in _recomputeDriverFilter(),
    // not here inside build(), so this method is cheap per frame.
    final allDrivers = _driversOnly ?? _snapshot?.drivers ?? <AdminDriverRecord>[];
    final cities = _cityOptions(allDrivers.map((d) => d.city));
    final stateOrRegions = _cityOptions(allDrivers.map((d) => d.stateOrRegion));

    // Use cached filtered list; fall back to computing inline only on first render
    // before _recomputeDriverFilter has had a chance to run.
    final filtered = _cachedFilteredDrivers.isNotEmpty || allDrivers.isEmpty
        ? _cachedFilteredDrivers
        : allDrivers;

    final totalFiltered = filtered.length;
    final pageCount =
        totalFiltered == 0 ? 1 : ((totalFiltered - 1) ~/ _driverPageSize) + 1;
    final safePageIndex =
        pageCount > 0 ? _driverPageIndex.clamp(0, pageCount - 1) : 0;
    final start = (safePageIndex * _driverPageSize).clamp(0, totalFiltered);
    final end = (start + _driverPageSize).clamp(0, totalFiltered);
    // Hard cap: never render more than _driverPageSize rows per frame.
    final pageSlice =
        start >= end ? <AdminDriverRecord>[] : filtered.sublist(start, end);
    adminPerfWarnRowBudget(
      surface: 'drivers_filtered_materialized',
      rowCount: filtered.length,
    );
    if (safePageIndex != _driverPageIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _driverPageIndex = safePageIndex;
          });
        }
      });
    }

    if (allDrivers.isEmpty) {
      return const AdminEmptyState(
        title: 'No driver records yet',
        message:
            'The driver operations module is wired to live driver, wallet, verification, withdrawal, and monetization data. Driver records will appear here as soon as they exist in the backend.',
        icon: Icons.directions_car_outlined,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const AdminSectionHeader(
          title: 'Drivers management',
          description:
              'Server-paged driver directory. Open a row for the profile drawer (overview, verification, wallet, trips, subscription, violations, notes, audit). Approve verification for go-online; use warn / suspend / delete as needed; Flag for support queues human follow-up.',
        ),
        const SizedBox(height: 16),
        _buildFilterBar(
          children: <Widget>[
            Expanded(
              flex: 2,
              child: AdminTextFilterField(
                controller: _driverSearchController,
                hintText:
                    'Search drivers by name, phone, city, state, vehicle, plate, or driver ID',
                onChanged: (_) {
                  _driverSearchDebounce?.cancel();
                  _driverSearchDebounce = Timer(const Duration(milliseconds: 350), () {
                    if (mounted) {
                      _recomputeDriverFilter();
                      if ((_driversOnly != null ||
                              (_section == AdminSection.drivers &&
                                  _snapshot == null)) &&
                          !AdminDriversRouteDebug.driversRouteFakeLocalDrivers) {
                        unawaited(_loadDriversOnly(resetServerCursors: true));
                      }
                    }
                  });
                },
              ),
            ),
            Expanded(
              child: AdminFilterDropdown<String>(
                value: _driverCityFilter,
                items: _dropdownItems(<String>['All', ...cities]),
                onChanged: (String? value) {
                  setState(() {
                    _driverCityFilter = value ?? 'All';
                  });
                  _recomputeDriverFilter();
                  if ((_driversOnly != null ||
                          (_section == AdminSection.drivers &&
                              _snapshot == null)) &&
                      !AdminDriversRouteDebug.driversRouteFakeLocalDrivers) {
                    unawaited(_loadDriversOnly(resetServerCursors: true));
                  }
                },
              ),
            ),
            Expanded(
              child: AdminFilterDropdown<String>(
                value: _driverStateOrRegionFilter,
                items: _dropdownItems(<String>['All', ...stateOrRegions]),
                onChanged: (String? value) {
                  setState(() {
                    _driverStateOrRegionFilter = value ?? 'All';
                  });
                  _recomputeDriverFilter();
                  if ((_driversOnly != null ||
                          (_section == AdminSection.drivers &&
                              _snapshot == null)) &&
                      !AdminDriversRouteDebug.driversRouteFakeLocalDrivers) {
                    unawaited(_loadDriversOnly(resetServerCursors: true));
                  }
                },
              ),
            ),
            Expanded(
              child: AdminFilterDropdown<String>(
                value: _driverStatusFilter,
                items: _dropdownItems(<String>[
                  'All',
                  'active',
                  'deactivated',
                  'suspended',
                ]),
                onChanged: (String? value) {
                  setState(() {
                    _driverStatusFilter = value ?? 'All';
                  });
                  _recomputeDriverFilter();
                  if ((_driversOnly != null ||
                          (_section == AdminSection.drivers &&
                              _snapshot == null)) &&
                      !AdminDriversRouteDebug.driversRouteFakeLocalDrivers) {
                    unawaited(_loadDriversOnly(resetServerCursors: true));
                  }
                },
              ),
            ),
            Expanded(
              child: AdminFilterDropdown<String>(
                value: _driverModelFilter,
                items: _dropdownItems(<String>[
                  'All',
                  'commission',
                  'subscription',
                ]),
                onChanged: (String? value) {
                  setState(() {
                    _driverModelFilter = value ?? 'All';
                  });
                  _recomputeDriverFilter();
                  if ((_driversOnly != null ||
                          (_section == AdminSection.drivers &&
                              _snapshot == null)) &&
                      !AdminDriversRouteDebug.driversRouteFakeLocalDrivers) {
                    unawaited(_loadDriversOnly(resetServerCursors: true));
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        AdminDataTableCard(
          heading: Text(
            'Showing ${pageSlice.length} of $totalFiltered matching drivers'
            '${totalFiltered > _driverPageSize ? ' · page ${safePageIndex + 1}/$pageCount' : ''}',
            style: const TextStyle(
              color: AdminThemeTokens.ink,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          columns: const <DataColumn>[
            DataColumn(label: Text('Driver')),
            DataColumn(label: Text('City')),
            DataColumn(label: Text('State / region')),
            DataColumn(label: Text('Account')),
            DataColumn(label: Text('Verification')),
            DataColumn(label: Text('Vehicle')),
            DataColumn(label: Text('Trips')),
            DataColumn(label: Text('Earnings')),
            DataColumn(label: Text('Wallet')),
            DataColumn(label: Text('Model')),
            DataColumn(label: Text('Actions')),
          ],
          rows: pageSlice.map((AdminDriverRecord driver) {
            return DataRow(
              onSelectChanged: (_) => _showDriverDialog(driver),
              cells: <DataCell>[
                DataCell(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Text(
                        driver.name,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      Text(driver.phone.isNotEmpty ? driver.phone : driver.id),
                    ],
                  ),
                ),
                DataCell(
                    Text(driver.city.isNotEmpty ? driver.city : 'Not set')),
                DataCell(
                  Text(
                    driver.stateOrRegion.isNotEmpty
                        ? driver.stateOrRegion
                        : '—',
                  ),
                ),
                DataCell(AdminStatusChip(driver.accountStatus)),
                DataCell(AdminStatusChip(driver.verificationStatus)),
                DataCell(Text(
                  driver.vehicleName.isNotEmpty
                      ? '${driver.vehicleName} • ${driver.plateNumber}'
                      : 'Vehicle not added',
                )),
                DataCell(
                    Text('${driver.completedTripCount}/${driver.tripCount}')),
                DataCell(Text(formatAdminCurrency(driver.netEarnings))),
                DataCell(Text(formatAdminCurrency(driver.walletBalance))),
                DataCell(
                  AdminStatusChip(
                    driverMonetizationStatusLabel(
                      monetizationModel: driver.monetizationModel,
                      subscriptionPlanType: driver.subscriptionPlanType,
                      subscriptionActive: driver.subscriptionActive,
                    ),
                  ),
                ),
                DataCell(_driverAccountActions(driver)),
              ],
            );
          }).toList(),
        ),
        if (totalFiltered > _driverPageSize) ...<Widget>[
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Text(
                'Showing ${pageSlice.length} rows per page',
                style: const TextStyle(
                  color: AdminThemeTokens.slate,
                  fontSize: 13,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: _driverPageIndex <= 0
                    ? null
                    : () => setState(() {
                          _driverPageIndex -= 1;
                        }),
                child: const Text('Previous'),
              ),
              TextButton(
                onPressed: _driverPageIndex >= pageCount - 1
                    ? null
                    : () => setState(() {
                          _driverPageIndex += 1;
                        }),
                child: const Text('Next'),
              ),
            ],
          ),
        ],
        if (_driversOnly != null &&
            !AdminDriversRouteDebug.driversRouteFakeLocalDrivers &&
            !AdminDriversRouteDebug.useLegacyFullDriversTreeCallable) ...<Widget>[
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'Server paging: up to $_driverPageSize drivers per request '
                  '(filters apply to the loaded page only).',
                  style: const TextStyle(
                    color: AdminThemeTokens.slate,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ),
              TextButton(
                onPressed: (_driversOnlyLoading ||
                        _driversServerCursorStack.length <= 1)
                    ? null
                    : _onDriversServerPrevPage,
                child: const Text('Previous server page'),
              ),
              TextButton(
                onPressed: (!_driversServerHasMore ||
                        _driversOnlyLoading ||
                        (_driversServerNextCursor ?? '').isEmpty)
                    ? null
                    : _onDriversServerNextPage,
                child: const Text('Next server page'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildFinanceSection(AdminPanelSnapshot snapshot) {
    final metrics = snapshot.metrics;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        AdminSummaryBanner(
          title: 'Finance and revenue',
          subtitle:
              'Platform-level visibility into gross bookings, commissions, subscription monetization, driver payouts, pending payouts, and city-by-city revenue performance.',
          kpis: <String, String>{
            'Gross bookings': formatAdminCurrency(metrics.totalGrossBookings),
            'Commissions': formatAdminCurrency(metrics.totalCommissionsEarned),
            'Subscriptions': formatAdminCurrency(metrics.subscriptionRevenue),
            'Pending payouts': formatAdminCurrency(metrics.pendingWithdrawals),
          },
        ),
        const SizedBox(height: 20),
        _buildMetricGrid(<_MetricCardEntry>[
          _MetricCardEntry(
            icon: Icons.receipt_long_outlined,
            data: AdminMetricCardData(
              label: 'Gross bookings',
              value: formatAdminCurrency(metrics.totalGrossBookings),
              caption:
                  'Total completed-ride fare volume currently visible from trips.',
            ),
          ),
          _MetricCardEntry(
            icon: Icons.percent_rounded,
            data: AdminMetricCardData(
              label: 'Commissions earned',
              value: formatAdminCurrency(metrics.totalCommissionsEarned),
              caption: 'Commission revenue realized from completed trips.',
            ),
          ),
          _MetricCardEntry(
            icon: Icons.workspace_premium_outlined,
            data: AdminMetricCardData(
              label: 'Subscription revenue',
              value: formatAdminCurrency(metrics.subscriptionRevenue),
              caption:
                  'Revenue inferred from subscription plan records and payment states.',
            ),
          ),
          _MetricCardEntry(
            icon: Icons.payments_outlined,
            data: AdminMetricCardData(
              label: 'Driver payouts',
              value: formatAdminCurrency(metrics.totalDriverPayouts),
              caption:
                  'Driver-side trip payouts calculated from monetization rules.',
            ),
          ),
        ]),
        const SizedBox(height: 20),
        _buildResponsiveTwoUp(
          left: AdminFinanceBarsCard(
            title: 'Daily finance',
            items: snapshot.dailyFinance,
          ),
          right: AdminFinanceBarsCard(
            title: 'Weekly finance',
            items: snapshot.weeklyFinance,
          ),
        ),
        const SizedBox(height: 20),
        _buildResponsiveTwoUp(
          left: AdminFinanceBarsCard(
            title: 'Monthly finance',
            items: snapshot.monthlyFinance,
          ),
          right: AdminFinanceBarsCard(
            title: 'City finance',
            items: snapshot.cityFinance,
          ),
        ),
      ],
    );
  }

  Widget _buildWithdrawalsSection() {
    final rows = _withdrawalsOnly ?? const <AdminWithdrawalRecord>[];
    adminPerfWarnRowBudget(surface: 'withdrawals_table', rowCount: rows.length);
    final configured =
        (_snapshot?.settings.withdrawalNoticeText ?? '').trim();
    final noticeText = configured.isNotEmpty
        ? configured
        : DriverFinanceService.payoutNoticeText;

    if (rows.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const AdminSectionHeader(
            title: 'Driver withdrawals',
            description:
                'Server-paged payout queue (50 per page). Search by driver id or name; filter by status.',
          ),
          const SizedBox(height: 16),
          AdminSurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'Withdrawal policy',
                  style: TextStyle(
                    color: AdminThemeTokens.ink,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  noticeText,
                  style: const TextStyle(
                    color: Color(0xFF6D675E),
                    height: 1.55,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const AdminEmptyState(
            title: 'No withdrawal requests on this page',
            message:
                'Try another status filter, clear search, or use Next page if more requests exist beyond this scan window.',
            icon: Icons.account_balance_wallet_outlined,
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const AdminSectionHeader(
          title: 'Driver withdrawals',
          description:
              'Callable-backed queue: 50 rows per request with server-side search and status filters.',
        ),
        const SizedBox(height: 16),
        AdminSurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                'Withdrawal policy',
                style: TextStyle(
                  color: AdminThemeTokens.ink,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                noticeText,
                style: const TextStyle(
                  color: Color(0xFF6D675E),
                  height: 1.55,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _buildFilterBar(
          children: <Widget>[
            Expanded(
              flex: 2,
              child: AdminTextFilterField(
                controller: _withdrawalSearchController,
                hintText:
                    'Search withdrawal id, driver uid, merchant id, or name',
                onChanged: (_) => _scheduleWithdrawalSearchReload(),
              ),
            ),
            Expanded(
              child: AdminFilterDropdown<String>(
                value: _withdrawalStatusFilter,
                items: _dropdownItems(<String>[
                  'All',
                  'pending',
                  'processing',
                  'paid',
                  'failed',
                ]),
                onChanged: (String? value) {
                  setState(() {
                    _withdrawalStatusFilter = value ?? 'All';
                  });
                  _beginWithdrawalsSectionLoad();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        AdminDataTableCard(
          heading: Text(
            'Withdrawals (${rows.length} on this page)',
            style: const TextStyle(
              color: AdminThemeTokens.ink,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          columns: const <DataColumn>[
            DataColumn(label: Text('Entity')),
            DataColumn(label: Text('Party')),
            DataColumn(label: Text('Amount')),
            DataColumn(label: Text('Payout destination')),
            DataColumn(label: Text('Requested')),
            DataColumn(label: Text('Status')),
            DataColumn(label: Text('Reference')),
          ],
          rows: rows.map((AdminWithdrawalRecord item) {
            final bool missingDriverDest = item.entityType == 'driver' &&
                !item.hasPayoutDestination;
            final String partyLabel = item.entityType == 'merchant'
                ? (item.merchantId.isNotEmpty ? item.merchantId : 'Merchant')
                : item.driverName;
            final String partySub = item.entityType == 'merchant'
                ? (item.driverName.isNotEmpty ? item.driverName : '')
                : item.driverId;
            return DataRow(
              onSelectChanged: (_) => _showWithdrawalDialog(item),
              cells: <DataCell>[
                DataCell(Text(item.entityType)),
                DataCell(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Text(
                        partyLabel,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      if (partySub.isNotEmpty)
                        Text(
                          partySub,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AdminThemeTokens.slate,
                          ),
                        ),
                    ],
                  ),
                ),
                DataCell(Text(formatAdminCurrency(item.amount))),
                DataCell(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      if (missingDriverDest)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: AdminStatusChip(
                            'Missing withdrawal destination',
                            color: AdminThemeTokens.warning,
                          ),
                        ),
                      Text(
                        item.bankName.isNotEmpty ? item.bankName : '—',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        item.accountNumber.isNotEmpty
                            ? item.accountNumber
                            : '—',
                        style: const TextStyle(fontSize: 12),
                      ),
                      Text(
                        item.accountName.isNotEmpty ? item.accountName : '—',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
                DataCell(Text(formatAdminDateTime(item.requestDate))),
                DataCell(AdminStatusChip(item.status)),
                DataCell(Text(
                  item.payoutReference.isNotEmpty
                      ? item.payoutReference
                      : '—',
                )),
              ],
            );
          }).toList(),
        ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                'Server paging: up to $_driverPageSize withdrawals per request.',
                style: const TextStyle(
                  color: AdminThemeTokens.slate,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ),
            TextButton(
              onPressed: (_withdrawalsOnlyLoading ||
                      _withdrawalsServerCursorStack.length <= 1)
                  ? null
                  : _onWithdrawalsServerPrevPage,
              child: const Text('Previous'),
            ),
            TextButton(
              onPressed: (!_withdrawalsServerHasMore ||
                      _withdrawalsOnlyLoading ||
                      (_withdrawalsServerNextCursor ?? '').isEmpty)
                  ? null
                  : _onWithdrawalsServerNextPage,
              child: const Text('Next'),
            ),
          ],
        ),
      ],
    );
  }

  void _scheduleWithdrawalSearchReload() {
    _withdrawalSearchDebounce?.cancel();
    _withdrawalSearchDebounce = Timer(const Duration(milliseconds: 450), () {
      if (!mounted || _section != AdminSection.withdrawals) {
        return;
      }
      _beginWithdrawalsSectionLoad();
    });
  }

  void _scheduleSupportInboxSearchReload() {
    _supportInboxSearchDebounce?.cancel();
    _supportInboxSearchDebounce = Timer(const Duration(milliseconds: 450), () {
      if (!mounted || _section != AdminSection.support) {
        return;
      }
      _beginSupportTicketsSectionLoad();
    });
  }

  Widget _buildSupportTicketsAdminSection() {
    final rows = _supportTicketsOnly ?? const <AdminSupportTicketListItem>[];
    adminPerfWarnRowBudget(surface: 'support_inbox_table', rowCount: rows.length);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const AdminSectionHeader(
          title: 'Support tickets',
          description:
              'Callable-backed inbox (50 per page). Search ticket id, subject, or creator uid; filter by status.',
        ),
        const SizedBox(height: 16),
        _buildFilterBar(
          children: <Widget>[
            Expanded(
              flex: 2,
              child: AdminTextFilterField(
                controller: _supportSearchController,
                hintText: 'Search ticket id, subject, or user id',
                onChanged: (_) => _scheduleSupportInboxSearchReload(),
              ),
            ),
            Expanded(
              child: AdminFilterDropdown<String>(
                value: _supportTicketStatusFilter,
                items: _dropdownItems(<String>[
                  'All',
                  'open',
                  'pending',
                  'in_progress',
                  'resolved',
                  'closed',
                ]),
                onChanged: (String? value) {
                  setState(() {
                    _supportTicketStatusFilter = value ?? 'All';
                  });
                  _beginSupportTicketsSectionLoad();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (rows.isEmpty)
          const AdminEmptyState(
            title: 'No tickets on this page',
            message:
                'Adjust filters or step through pages — large inboxes are scanned in bounded batches on the server.',
            icon: Icons.support_agent_outlined,
          )
        else
          AdminDataTableCard(
            heading: Text(
              'Tickets (${rows.length} on this page)',
              style: const TextStyle(
                color: AdminThemeTokens.ink,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            columns: const <DataColumn>[
              DataColumn(label: Text('Ticket')),
              DataColumn(label: Text('Status')),
              DataColumn(label: Text('Subject')),
              DataColumn(label: Text('Ride')),
              DataColumn(label: Text('Created by')),
              DataColumn(label: Text('Updated')),
            ],
            rows: rows.map((AdminSupportTicketListItem t) {
              return DataRow(
                onSelectChanged: (_) =>
                    unawaited(_showSupportTicketAdminDetail(t)),
                cells: <DataCell>[
                  DataCell(Text(t.id, style: const TextStyle(fontWeight: FontWeight.w700))),
                  DataCell(AdminStatusChip(t.status)),
                  DataCell(Text(
                    t.subject.isNotEmpty ? t.subject : '—',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  )),
                  DataCell(Text(t.rideId.isNotEmpty ? t.rideId : '—')),
                  DataCell(Text(t.createdByUserId.isNotEmpty ? t.createdByUserId : '—')),
                  DataCell(Text(
                    t.updatedAtMs > 0
                        ? formatAdminDateTime(
                            DateTime.fromMillisecondsSinceEpoch(t.updatedAtMs),
                          )
                        : '—',
                  )),
                ],
              );
            }).toList(),
          ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                'Server paging: up to $_driverPageSize tickets per request.',
                style: const TextStyle(
                  color: AdminThemeTokens.slate,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ),
            TextButton(
              onPressed: (_supportTicketsOnlyLoading ||
                      _supportTicketsServerCursorStack.length <= 1)
                  ? null
                  : _onSupportTicketsServerPrevPage,
              child: const Text('Previous'),
            ),
            TextButton(
              onPressed: (!_supportTicketsServerHasMore ||
                      _supportTicketsOnlyLoading ||
                      (_supportTicketsServerNextCursor ?? '').isEmpty)
                  ? null
                  : _onSupportTicketsServerNextPage,
              child: const Text('Next'),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _showSupportTicketAdminDetail(
    AdminSupportTicketListItem item,
  ) async {
    if (!mounted) {
      return;
    }
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) {
        return const AlertDialog(
          content: SizedBox(
            width: 360,
            height: 120,
            child: Center(child: CircularProgressIndicator()),
          ),
        );
      },
    );

    final detail = await _dataService.fetchSupportTicketForAdmin(item.id);
    if (!mounted) {
      return;
    }
    Navigator.of(context, rootNavigator: true).pop();

    if (detail == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load ticket ${item.id}')),
      );
      return;
    }

    final ticket = Map<String, dynamic>.from(
      _mapStringDynamic(detail['ticket']) ?? const <String, dynamic>{},
    );
    final messagesRaw = detail['messages'];
    final messageEntries = <MapEntry<String, dynamic>>[];
    if (messagesRaw is Map) {
      for (final MapEntry<dynamic, dynamic> e in messagesRaw.entries) {
        messageEntries.add(
          MapEntry(e.key.toString(), e.value),
        );
      }
      messageEntries.sort((a, b) {
        final ma = _mapStringDynamic(a.value) ?? const {};
        final mb = _mapStringDynamic(b.value) ?? const {};
        final ta = (ma['createdAt'] as num?)?.toInt() ??
            (ma['created_at'] as num?)?.toInt() ??
            0;
        final tb = (mb['createdAt'] as num?)?.toInt() ??
            (mb['created_at'] as num?)?.toInt() ??
            0;
        return ta.compareTo(tb);
      });
    }

    final replyController = TextEditingController();
    final statusController = TextEditingController(
      text: ticket['status']?.toString() ?? item.status,
    );

    try {
      await showDialog<void>(
        context: context,
        builder: (BuildContext dialogContext) {
          return AlertDialog(
            title: Text('Ticket ${item.id}'),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    AdminKeyValueWrap(
                      items: <String, String>{
                        'Status': ticket['status']?.toString() ?? item.status,
                        'Subject':
                            ticket['subject']?.toString() ?? item.subject,
                        'Ride': ticket['ride_id']?.toString() ?? item.rideId,
                        'Created by':
                            ticket['createdByUserId']?.toString() ??
                                item.createdByUserId,
                      },
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Messages (${messageEntries.length})',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    ...messageEntries
                        .take(12)
                        .map((MapEntry<String, dynamic> e) {
                      final m = _mapStringDynamic(e.value) ?? const {};
                      final body = m['message']?.toString() ?? '';
                      final who = m['senderRole']?.toString() ??
                          m['sender_role']?.toString() ??
                          '';
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          '[$who] $body',
                          style: const TextStyle(height: 1.35),
                        ),
                      );
                    }),
                    if (messageEntries.length > 12)
                      const Text(
                        'Older messages truncated — full history stays in Firebase.',
                        style: TextStyle(
                          color: AdminThemeTokens.slate,
                          fontSize: 12,
                        ),
                      ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: statusController,
                      decoration: _dialogInputDecoration('New status'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: replyController,
                      minLines: 2,
                      maxLines: 5,
                      decoration:
                          _dialogInputDecoration('Public reply (optional)'),
                    ),
                  ],
                ),
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Close'),
              ),
              TextButton(
                onPressed: () async {
                  final ok =
                      await _dataService.adminEscalateSupportTicketCallable(
                    ticketId: item.id,
                  );
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content:
                          Text(ok ? 'Ticket escalated' : 'Escalate failed'),
                    ),
                  );
                  if (ok) {
                    await _loadSupportTicketsOnly(resetServerCursors: false);
                  }
                },
                child: const Text('Escalate'),
              ),
              FilledButton(
                onPressed: () async {
                  final status = statusController.text.trim();
                  if (status.isNotEmpty) {
                    final ok = await _dataService
                        .adminUpdateSupportTicketStatusCallable(
                      ticketId: item.id,
                      status: status,
                    );
                    if (!mounted) return;
                    if (!ok) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Status update failed')),
                      );
                      return;
                    }
                  }
                  final reply = replyController.text.trim();
                  if (reply.isNotEmpty) {
                    final ok = await _dataService.adminReplySupportTicketCallable(
                      ticketId: item.id,
                      message: reply,
                      visibility: 'public',
                    );
                    if (!mounted) return;
                    if (!ok) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Reply failed')),
                      );
                      return;
                    }
                  }
                  if (!mounted) return;
                  Navigator.pop(dialogContext);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Ticket updated')),
                  );
                  await _loadSupportTicketsOnly(resetServerCursors: false);
                },
                child: const Text('Apply'),
              ),
            ],
          );
        },
      );
    } finally {
      replyController.dispose();
      statusController.dispose();
    }
  }

  Map<String, dynamic>? _mapStringDynamic(Object? raw) {
    if (raw is Map<String, dynamic>) {
      return raw;
    }
    if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }
    return null;
  }

  Widget _buildSubscriptionsTab(AdminPanelSnapshot snapshot) {
    try {
      return _buildSubscriptionsSection(snapshot);
    } catch (error, stackTrace) {
      debugPrint('[ADMIN_SUBSCRIPTIONS_ERROR] $error\n$stackTrace');
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const Icon(Icons.error_outline, size: 48, color: Colors.amber),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Could not load subscriptions: $error',
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => unawaited(_loadSnapshot()),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
  }

  Widget _buildPricingSection(AdminPanelSnapshot snapshot) {
    return _PricingEditor(
      pricing: snapshot.pricingConfig,
      settings: snapshot.settings,
      canEditPricing: widget.session.hasPermission('settings.write'),
      onSave: (List<AdminCityPricing> cities, double commissionRate,
          int weeklySubscriptionNgn, int monthlySubscriptionNgn) async {
        await _dataService.updatePricingConfig(
          cities: cities,
          commissionRate: commissionRate,
          weeklySubscriptionNgn: weeklySubscriptionNgn,
          monthlySubscriptionNgn: monthlySubscriptionNgn,
        );
        await _loadSnapshot();
      },
    );
  }

  Widget _buildSubscriptionsSection(AdminPanelSnapshot snapshot) {
    final pending = snapshot.subscriptions
        .where((AdminSubscriptionRecord record) => record.pendingApproval)
        .toList(growable: false);
    if (pending.isEmpty) {
      return const AdminEmptyState(
        title: 'No pending subscription requests',
        message:
            'Approved and rejected subscription records are tracked automatically. New pending payment proofs will appear here for admin review.',
        icon: Icons.workspace_premium_outlined,
      );
    }

    return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AdminSummaryBanner(
            title: 'Pending subscription approvals',
            subtitle:
                'Review proof uploads, confirm payment references, and approve or reject pending driver subscription requests.',
            kpis: <String, String>{
              'Pending requests': '${pending.length}',
              'Weekly plans':
                  '${pending.where((AdminSubscriptionRecord record) => record.planType == 'weekly').length}',
              'Monthly plans':
                  '${pending.where((AdminSubscriptionRecord record) => record.planType != 'weekly').length}',
            },
          ),
          const SizedBox(height: 20),
          ...pending.map((AdminSubscriptionRecord record) {
            final planLabel =
                '${sentenceCaseStatus(record.planType)} ${formatAdminCurrency(record.amountNgn.toDouble())}';
            return Container(
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.black12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '${record.driverName} (${record.driverId})',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  AdminKeyValueWrap(
                    items: <String, String>{
                      'Plan': planLabel,
                      'Requested': formatAdminDateTime(
                          record.requestedAt ?? record.startDate),
                      'Payment reference': record.paymentReference.isNotEmpty
                          ? record.paymentReference
                          : 'Not provided',
                      'Payment proof':
                          record.hasProof ? 'Available (open on demand)' : 'None',
                    },
                  ),
                  const SizedBox(height: 10),
                  if (!record.hasProof)
                    const Text(
                      'No proof uploaded',
                      style: TextStyle(
                        color: Colors.black54,
                        fontStyle: FontStyle.italic,
                      ),
                    )
                  else
                    TextButton(
                      onPressed: () => unawaited(_viewSubscriptionProof(record)),
                      child: const Text('View Proof'),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: widget.session.hasPermission('drivers.read')
                            ? ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF198754),
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () async {
                            debugPrint(
                              '[ADMIN_APPROVE] tapped for driverId=${record.driverId}',
                            );
                            try {
                              await _dataService.reviewSubscriptionRequest(
                                subscription: record,
                                approve: true,
                              );
                              if (!mounted) {
                                return;
                              }
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Subscription approved for ${record.driverName}',
                                  ),
                                ),
                              );
                              unawaited(_loadSnapshot());
                            } catch (e) {
                              if (!mounted) {
                                return;
                              }
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Approve failed: $e'),
                                  backgroundColor: Colors.red,
                                ),
                              );
                            }
                          },
                          child: const Text('Approve'),
                        )
                            : Tooltip(
                                message: kAdminNoPermissionTooltip,
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF198754),
                                    foregroundColor: Colors.white,
                                  ),
                                  onPressed: null,
                                  child: const Text('Approve'),
                                ),
                              ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: widget.session.hasPermission('drivers.read')
                            ? ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFDC3545),
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () async {
                            debugPrint(
                              '[ADMIN_REJECT] tapped for driverId=${record.driverId}',
                            );
                            try {
                              await _dataService.reviewSubscriptionRequest(
                                subscription: record,
                                approve: false,
                              );
                              if (!mounted) {
                                return;
                              }
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Subscription rejected for ${record.driverName}',
                                  ),
                                ),
                              );
                              unawaited(_loadSnapshot());
                            } catch (e) {
                              if (!mounted) {
                                return;
                              }
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Reject failed: $e'),
                                  backgroundColor: Colors.red,
                                ),
                              );
                            }
                          },
                          child: const Text('Reject'),
                        )
                            : Tooltip(
                                message: kAdminNoPermissionTooltip,
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFFDC3545),
                                    foregroundColor: Colors.white,
                                  ),
                                  onPressed: null,
                                  child: const Text('Reject'),
                                ),
                              ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          }),
        ],
      );
  }

  Future<void> _viewSubscriptionProof(AdminSubscriptionRecord record) async {
    if (!record.hasProof) {
      return;
    }
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return PopScope(
          canPop: false,
          child: AlertDialog(
            content: Row(
              children: <Widget>[
                const SizedBox(
                  height: 28,
                  width: 28,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    'Loading payment proof for ${record.driverName}…',
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    try {
      final proofUrl = await _dataService.fetchSubscriptionProofUrl(
        driverId: record.driverId,
      );
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      await _openSubscriptionProofUrl(proofUrl);
    } catch (error) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load proof: $error')),
        );
      }
    }
  }

  Future<void> _openSubscriptionProofUrl(String proofUrl) async {
    final uri = Uri.tryParse(proofUrl.trim());
    if (uri == null || !uri.hasScheme) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid proof link.')),
      );
      return;
    }
    try {
      await adminOpenProofInBrowser(proofUrl);
    } catch (error) {
      debugPrint('[AdminPanel][Subscriptions] open proof URL failed: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open link: $error')),
        );
      }
    }
  }

  Future<String?> _promptAdminReason({
    required String title,
    required String fieldLabel,
    int minLength = 8,
  }) async {
    final TextEditingController controller = TextEditingController();
    final GlobalKey<FormState> formKey = GlobalKey<FormState>();
    try {
      return await showDialog<String>(
        context: context,
        builder: (BuildContext dialogContext) {
          return AlertDialog(
            title: Text(title),
            content: Form(
              key: formKey,
              child: TextFormField(
                controller: controller,
                decoration: InputDecoration(labelText: fieldLabel),
                minLines: 3,
                maxLines: 5,
                validator: (String? value) {
                  final String trimmed = value?.trim() ?? '';
                  if (trimmed.length < minLength) {
                    return 'Enter at least $minLength characters.';
                  }
                  return null;
                },
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  if (formKey.currentState?.validate() != true) {
                    return;
                  }
                  Navigator.of(dialogContext).pop(controller.text.trim());
                },
                child: const Text('Continue'),
              ),
            ],
          );
        },
      );
    } finally {
      controller.dispose();
    }
  }

  Future<_AdminWarnFields?> _promptAdminWarnDialog({
    required String accountLabel,
  }) async {
    final reasonController = TextEditingController();
    final messageController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    try {
      return await showDialog<_AdminWarnFields>(
        context: context,
        builder: (BuildContext ctx) {
          return AlertDialog(
            title: Text('Warn $accountLabel'),
            content: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  TextFormField(
                    controller: reasonController,
                    decoration: const InputDecoration(
                      labelText: 'Reason (required)',
                    ),
                    minLines: 2,
                    maxLines: 4,
                    validator: (String? value) {
                      final trimmed = (value ?? '').trim();
                      if (trimmed.length < 4) {
                        return 'Enter at least 4 characters.';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: messageController,
                    decoration: const InputDecoration(
                      labelText: 'Optional message',
                    ),
                    minLines: 1,
                    maxLines: 3,
                  ),
                ],
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () {
                  if (formKey.currentState?.validate() ?? false) {
                    Navigator.pop(
                      ctx,
                      _AdminWarnFields(
                        reason: reasonController.text.trim(),
                        message: messageController.text.trim(),
                      ),
                    );
                  }
                },
                child: const Text('Send warning'),
              ),
            ],
          );
        },
      );
    } finally {
      reasonController.dispose();
      messageController.dispose();
    }
  }

  Future<void> _driverApproveVerification(
    AdminDriverRecord driver, {
    AdminEntityDrawerController? drawerController,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) {
        return AlertDialog(
          title: const Text('Approve driver verification?'),
          content: Text(
            'This approves ${driver.name}\'s identity on the driver profile and '
            'clears the KYC gate so they can go online (subscription and location '
            'rules still apply). Continue?',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Approve'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) {
      return;
    }
    final AdminDriverRecord before = driver;
    await _actionExecutor.run<void>(
      context: context,
      actionName: 'driver_approve_verification',
      successMessage: 'Verification approved for ${driver.name}.',
      applyOptimistic: () {
        _replaceDriverInPagedLists(
          driver.id,
          (AdminDriverRecord d) => d.copyWith(
            verificationStatus: 'approved',
            rawData: <String, dynamic>{
              ...d.rawData,
              'identity_verification_status': 'approved',
              'verification_status': 'approved',
              'is_verified': true,
              'nexride_verified': true,
            },
          ),
        );
      },
      rollbackOptimistic: () {
        _replaceDriverInPagedLists(driver.id, (_) => before);
      },
      invoke: () => _dataService.adminApproveDriverVerification(driverId: driver.id),
      emitAudit: ({
        required bool success,
        Object? value,
        Object? error,
        required String correlationId,
      }) {
        if (!success) {
          return _driverAudit(
            action: 'driver_approve_verification',
            driverId: driver.id,
            before: driver.verificationStatus,
            after: null,
            metadata: <String, dynamic>{
              if (error != null) 'error': error.toString(),
            },
            correlationId: correlationId,
          );
        }
        return _driverAudit(
          action: 'driver_approve_verification',
          driverId: driver.id,
          before: driver.verificationStatus,
          after: 'approved',
          correlationId: correlationId,
        );
      },
      onSuccess: (_) {
        drawerController?.invalidateTabs(
          AdminCacheInvalidationRegistry.tabsFor('driver_approve_verification'),
        );
        unawaited(_refreshDriverRows());
      },
    );
  }

  Future<void> _driverSuspend(
    AdminDriverRecord driver, {
    AdminEntityDrawerController? drawerController,
  }) async {
    final String? reason = await _promptAdminReason(
      title: 'Suspend driver',
      fieldLabel: 'Reason (shown internally)',
      minLength: 8,
    );
    if (reason == null || !mounted) {
      return;
    }
    await _actionExecutor.run<void>(
      context: context,
      actionName: 'driver_suspend',
      successMessage: 'Driver suspended.',
      invoke: () => _dataService.adminSuspendAccount(
        uid: driver.id,
        role: 'driver',
        reason: reason,
      ),
      emitAudit: ({
        required bool success,
        Object? value,
        Object? error,
        required String correlationId,
      }) {
        if (!success) {
          return _driverAudit(
            action: 'driver_suspend',
            driverId: driver.id,
            before: driver.accountStatus,
            after: null,
            metadata: <String, dynamic>{
              'reason': reason,
              if (error != null) 'error': error.toString(),
            },
            correlationId: correlationId,
          );
        }
        return _driverAudit(
          action: 'driver_suspend',
          driverId: driver.id,
          before: driver.accountStatus,
          after: 'suspended',
          metadata: <String, dynamic>{'reason': reason},
          correlationId: correlationId,
        );
      },
      onSuccess: (_) {
        drawerController?.invalidateTabs(
          AdminCacheInvalidationRegistry.tabsFor('driver_suspend'),
        );
        unawaited(_refreshDriverRows());
      },
    );
  }

  Future<void> _driverWarn(
    AdminDriverRecord driver, {
    AdminEntityDrawerController? drawerController,
  }) async {
    final _AdminWarnFields? fields =
        await _promptAdminWarnDialog(accountLabel: driver.name);
    if (fields == null || !mounted) {
      return;
    }
    await _actionExecutor.run<void>(
      context: context,
      actionName: 'driver_warn',
      successMessage: 'Warning sent.',
      invoke: () => _dataService.adminWarnAccount(
        uid: driver.id,
        role: 'driver',
        reason: fields.reason,
        message: fields.message,
      ),
      emitAudit: ({
        required bool success,
        Object? value,
        Object? error,
        required String correlationId,
      }) {
        if (!success) {
          return _driverAudit(
            action: 'driver_warn',
            driverId: driver.id,
            before: null,
            after: null,
            metadata: <String, dynamic>{
              'reason': fields.reason,
              'message': fields.message,
              if (error != null) 'error': error.toString(),
            },
            correlationId: correlationId,
          );
        }
        return _driverAudit(
          action: 'driver_warn',
          driverId: driver.id,
          before: null,
          after: 'warned',
          metadata: <String, dynamic>{
            'reason': fields.reason,
            'message': fields.message,
          },
          correlationId: correlationId,
        );
      },
      onSuccess: (_) {
        drawerController?.invalidateTabs(
          AdminCacheInvalidationRegistry.tabsFor('driver_warn'),
        );
        unawaited(_refreshDriverRows());
      },
    );
  }

  Future<void> _driverDelete(
    AdminDriverRecord driver, {
    AdminEntityDrawerController? drawerController,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) {
        return AlertDialog(
          title: const Text('Delete driver account?'),
          content: Text(
            'This permanently deletes ${driver.name} (${driver.id}) from '
            'Realtime Database and Firebase Auth. This cannot be undone.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red.shade800),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) {
      return;
    }
    await _actionExecutor.run<void>(
      context: context,
      actionName: 'driver_delete',
      successMessage: 'Driver account deleted.',
      invoke: () => _dataService.adminDeleteAccount(
        uid: driver.id,
        role: 'driver',
      ),
      emitAudit: ({
        required bool success,
        Object? value,
        Object? error,
        required String correlationId,
      }) {
        if (!success) {
          return _driverAudit(
            action: 'driver_delete',
            driverId: driver.id,
            before: driver.accountStatus,
            after: null,
            metadata: <String, dynamic>{
              if (error != null) 'error': error.toString(),
            },
            correlationId: correlationId,
          );
        }
        return _driverAudit(
          action: 'driver_delete',
          driverId: driver.id,
          before: driver.accountStatus,
          after: 'deleted',
          correlationId: correlationId,
        );
      },
      onSuccess: (_) {
        drawerController?.close();
        unawaited(_refreshDriverRows());
      },
    );
  }

  Future<void> _riderWarn(AdminRiderRecord rider) async {
    final fields = await _promptAdminWarnDialog(accountLabel: rider.name);
    if (fields == null || !mounted) {
      return;
    }
    await _actionExecutor.run<void>(
      context: context,
      actionName: 'rider_warn',
      successMessage: 'Warning sent.',
      useDefaultMutationThrottle: true,
      invoke: () => _dataService.adminWarnAccount(
        uid: rider.id,
        role: 'rider',
        reason: fields.reason,
        message: fields.message,
      ),
      emitAudit: ({
        required bool success,
        Object? value,
        Object? error,
        required String correlationId,
      }) {
        return _riderAudit(
          action: 'rider_warn',
          riderId: rider.id,
          before: null,
          after: success ? 'warned' : null,
          metadata: <String, dynamic>{
            'reason': fields.reason,
            'message': fields.message,
            if (!success && error != null) 'error': error.toString(),
          },
          correlationId: correlationId,
        );
      },
      onSuccess: (_) {
        unawaited(_refresh());
      },
    );
  }

  Future<void> _riderSuspend(AdminRiderRecord rider) async {
    final reason = await _promptAdminReason(
      title: 'Suspend rider',
      fieldLabel: 'Reason (shown internally)',
      minLength: 8,
    );
    if (reason == null || !mounted) {
      return;
    }
    await _actionExecutor.run<void>(
      context: context,
      actionName: 'rider_suspend',
      successMessage: 'Rider suspended.',
      useDefaultMutationThrottle: true,
      invoke: () => _dataService.adminSuspendAccount(
        uid: rider.id,
        role: 'rider',
        reason: reason,
      ),
      emitAudit: ({
        required bool success,
        Object? value,
        Object? error,
        required String correlationId,
      }) {
        return _riderAudit(
          action: 'rider_suspend',
          riderId: rider.id,
          before: rider.status,
          after: success ? 'suspended' : null,
          metadata: <String, dynamic>{
            'reason': reason,
            if (!success && error != null) 'error': error.toString(),
          },
          correlationId: correlationId,
        );
      },
      onSuccess: (_) {
        unawaited(_refresh());
      },
    );
  }

  Future<void> _riderDelete(AdminRiderRecord rider) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) {
        return AlertDialog(
          title: const Text('Delete rider account?'),
          content: Text(
            'This permanently deletes ${rider.name} (${rider.id}) from '
            'Realtime Database and Firebase Auth. This cannot be undone.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red.shade800),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) {
      return;
    }
    await _actionExecutor.run<void>(
      context: context,
      actionName: 'rider_delete',
      successMessage: 'Rider account deleted.',
      invoke: () => _dataService.adminDeleteAccount(
        uid: rider.id,
        role: 'rider',
      ),
      emitAudit: ({
        required bool success,
        Object? value,
        Object? error,
        required String correlationId,
      }) {
        return _riderAudit(
          action: 'rider_delete',
          riderId: rider.id,
          before: rider.status,
          after: success ? 'deleted' : null,
          metadata: <String, dynamic>{
            if (!success && error != null) 'error': error.toString(),
          },
          correlationId: correlationId,
        );
      },
      onSuccess: (_) {
        unawaited(_refresh());
      },
    );
  }

  bool _isDriverVerificationApproved(AdminDriverRecord driver) {
    final String v = driver.verificationStatus.toLowerCase().trim();
    return v == 'verified' ||
        v == 'approved' ||
        v == 'complete' ||
        v == 'completed' ||
        v == 'active';
  }

  Widget _rbacTextButton({
    required bool allowed,
    required String label,
    required VoidCallback onPressed,
    ButtonStyle? style,
  }) {
    final Widget btn = TextButton(
      style: style,
      onPressed: allowed ? onPressed : null,
      child: Text(label),
    );
    if (allowed) {
      return btn;
    }
    return Tooltip(message: kAdminNoPermissionTooltip, child: btn);
  }

  Widget _driverAccountActions(AdminDriverRecord driver) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        if (!_isDriverVerificationApproved(driver))
          _rbacTextButton(
            allowed: widget.session.hasPermission('verification.approve'),
            label: 'Approve verification',
            onPressed: () => unawaited(
              _driverApproveVerification(driver, drawerController: null),
            ),
          ),
        _rbacTextButton(
          allowed: widget.session.hasPermission('drivers.write'),
          label: 'Suspend',
          onPressed: () =>
              unawaited(_driverSuspend(driver, drawerController: null)),
        ),
        _rbacTextButton(
          allowed: widget.session.hasPermission('drivers.write'),
          label: 'Warn',
          onPressed: () =>
              unawaited(_driverWarn(driver, drawerController: null)),
        ),
        _rbacTextButton(
          allowed: widget.session.hasPermission('support.write'),
          label: 'Support flag',
          onPressed: () => unawaited(
            _runSupportContactFlagForUser(
              uid: driver.id,
              role: 'driver',
              displayLabel: driver.name,
            ),
          ),
        ),
        const SizedBox(width: 8),
        _rbacTextButton(
          allowed: widget.session.hasPermission('settings.write'),
          label: 'Delete',
          style: TextButton.styleFrom(foregroundColor: Colors.red.shade800),
          onPressed: () =>
              unawaited(_driverDelete(driver, drawerController: null)),
        ),
      ],
    );
  }

  bool _isRiderIdentityVerified(AdminRiderRecord rider) {
    final String v = rider.verificationStatus.toLowerCase().trim();
    return v == 'verified' || v == 'approved';
  }

  Widget _riderAccountActions(AdminRiderRecord rider) {
    return PopupMenuButton<String>(
      tooltip: 'Rider actions',
      padding: EdgeInsets.zero,
      onSelected: (String value) {
        switch (value) {
          case 'warn':
            unawaited(_riderWarn(rider));
            break;
          case 'suspend':
            unawaited(_riderSuspend(rider));
            break;
          case 'flag':
            unawaited(
              _runSupportContactFlagForUser(
                uid: rider.id,
                role: 'rider',
                displayLabel: rider.name,
              ),
            );
            break;
          case 'delete':
            unawaited(_riderDelete(rider));
            break;
        }
      },
      itemBuilder: (BuildContext context) {
        final bool rw = widget.session.hasPermission('riders.write');
        final bool sw = widget.session.hasPermission('support.write');
        final bool st = widget.session.hasPermission('settings.write');
        return <PopupMenuEntry<String>>[
          PopupMenuItem<String>(
            value: 'warn',
            enabled: rw,
            child: const Text('Warn'),
          ),
          PopupMenuItem<String>(
            value: 'suspend',
            enabled: rw,
            child: const Text('Suspend'),
          ),
          PopupMenuItem<String>(
            value: 'flag',
            enabled: sw,
            child: const Text('Support flag'),
          ),
          const PopupMenuDivider(),
          PopupMenuItem<String>(
            value: 'delete',
            enabled: st,
            child: Text(
              'Delete',
              style: TextStyle(color: Colors.red.shade800),
            ),
          ),
        ];
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Icon(
          Icons.more_vert_rounded,
          color: AdminThemeTokens.ink.withValues(alpha: 0.75),
        ),
      ),
    );
  }

  // ignore: unused_element
  Widget _buildSupportSection(AdminPanelSnapshot snapshot) {
    final query = _supportSearchController.text.trim().toLowerCase();
    final supportIssues =
        snapshot.supportIssues.where((AdminSupportIssueRecord issue) {
      final matchesQuery = query.isEmpty ||
          issue.reason.toLowerCase().contains(query) ||
          issue.summary.toLowerCase().contains(query) ||
          issue.rideId.toLowerCase().contains(query) ||
          issue.riderId.toLowerCase().contains(query) ||
          issue.driverId.toLowerCase().contains(query);
      final matchesKind =
          _supportKindFilter == 'All' || issue.kind == _supportKindFilter;
      return matchesQuery && matchesKind;
    }).toList();

    final topCancellationCities = _topCancellationCities(snapshot.trips);
    final problematicAccounts = _problematicAccounts(snapshot);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const AdminSectionHeader(
          title: 'Support and issue visibility',
          description:
              'Keep visibility on rider complaints, trip disputes, cancellation patterns, and accounts that may require intervention.',
        ),
        const SizedBox(height: 16),
        _buildFilterBar(
          children: <Widget>[
            Expanded(
              flex: 2,
              child: AdminTextFilterField(
                controller: _supportSearchController,
                hintText:
                    'Search issue reason, message, ride ID, rider ID, or driver ID',
                onChanged: (_) => setState(() {}),
              ),
            ),
            Expanded(
              child: AdminFilterDropdown<String>(
                value: _supportKindFilter,
                items: _dropdownItems(<String>[
                  'All',
                  'rider_report',
                  'trip_dispute',
                ]),
                onChanged: (String? value) => setState(() {
                  _supportKindFilter = value ?? 'All';
                }),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _buildResponsiveTwoUp(
          left: AdminInsightList(
            title: 'Cancelled ride patterns',
            items: topCancellationCities,
          ),
          right: AdminInsightList(
            title: 'Problematic accounts',
            items: problematicAccounts,
          ),
        ),
        const SizedBox(height: 20),
        if (supportIssues.isEmpty)
          const AdminEmptyState(
            title: 'No support issues yet',
            message:
                'The support queue is ready, and it will populate automatically when rider reports or trip disputes are written into the backend.',
            icon: Icons.support_agent_outlined,
          )
        else
          AdminDataTableCard(
            columns: const <DataColumn>[
              DataColumn(label: Text('Kind')),
              DataColumn(label: Text('Status')),
              DataColumn(label: Text('Reason')),
              DataColumn(label: Text('Summary')),
              DataColumn(label: Text('Ride')),
              DataColumn(label: Text('Created')),
            ],
            rows: supportIssues.map((AdminSupportIssueRecord issue) {
              return DataRow(
                onSelectChanged: (_) => _showSupportDialog(issue),
                cells: <DataCell>[
                  DataCell(AdminStatusChip(issue.kind)),
                  DataCell(AdminStatusChip(issue.status)),
                  DataCell(Text(issue.reason)),
                  DataCell(
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 360),
                      child: Text(
                        issue.summary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  DataCell(
                      Text(issue.rideId.isNotEmpty ? issue.rideId : 'N/A')),
                  DataCell(Text(formatAdminDateTime(issue.createdAt))),
                ],
              );
            }).toList(),
          ),
      ],
    );
  }

  Widget _buildSettingsSection(AdminPanelSnapshot snapshot) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const AdminSectionHeader(
          title: 'Settings and configuration',
          description:
              'Review fare model, monetization rules, withdrawal notice text, city enablement, operational constants, and admin access details.',
        ),
        const SizedBox(height: 16),
        AdminSurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                'Fare model summary',
                style: TextStyle(
                  color: AdminThemeTokens.ink,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 16,
                runSpacing: 16,
                children:
                    snapshot.pricingConfig.cities.map((AdminCityPricing city) {
                  return Container(
                    width: 260,
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8F5EF),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                city.city,
                                style: const TextStyle(
                                  color: AdminThemeTokens.ink,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            AdminStatusChip(
                                city.enabled ? 'enabled' : 'disabled'),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Text(
                            'Base fare • ${formatAdminCurrency(city.baseFareNgn)}'),
                        Text('Per km • ${formatAdminCurrency(city.perKmNgn)}'),
                        Text(
                            'Per minute • ${formatAdminCurrency(city.perMinuteNgn)}'),
                        Text(
                            'Minimum fare • ${formatAdminCurrency(city.minimumFareNgn)}'),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        AdminSurfaceCard(
          child: AdminKeyValueWrap(
            items: <String, String>{
              'Commission model':
                  '${(snapshot.pricingConfig.commissionRate * 100).toStringAsFixed(0)}% commission',
              'Weekly subscription': formatAdminCurrency(
                  snapshot.pricingConfig.weeklySubscriptionNgn),
              'Monthly subscription': formatAdminCurrency(
                  snapshot.pricingConfig.monthlySubscriptionNgn),
              'Withdrawal notice': snapshot.settings.withdrawalNoticeText,
              'Verification required':
                  snapshot.settings.driverVerificationRequired ? 'Yes' : 'No',
              'Off-route tolerance':
                  '${snapshot.settings.offRouteToleranceMeters} meters',
              'Active request services':
                  formatAdminActiveRequestServiceSummary(
                    snapshot.settings.activeServiceTypes,
                  ),
              'Admin profile': widget.session.email,
            },
          ),
        ),
        const SizedBox(height: 16),
        AdminSurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                'City enablement',
                style: TextStyle(
                  color: AdminThemeTokens.ink,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: snapshot.settings.cityEnablement.entries
                    .map((MapEntry<String, bool> entry) {
                  return AdminStatusChip(
                    '${entry.key} ${entry.value ? 'enabled' : 'disabled'}',
                    color: entry.value
                        ? AdminThemeTokens.success
                        : AdminThemeTokens.warning,
                  );
                }).toList(),
              ),
              const SizedBox(height: 20),
              AdminGhostButton(
                label: 'Log out admin session',
                onPressed: _logout,
                icon: Icons.logout_rounded,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMetricGrid(List<_MetricCardEntry> entries) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final width = constraints.maxWidth;
        final crossAxisCount = width >= 1280
            ? 4
            : width >= 960
                ? 3
                : width >= 640
                    ? 2
                    : 1;
        final itemWidth = (width - (crossAxisCount - 1) * 16) / crossAxisCount;
        return Wrap(
          spacing: 16,
          runSpacing: 16,
          children: entries.map((_MetricCardEntry entry) {
            return SizedBox(
              width: itemWidth,
              child: AdminStatCard(
                metric: entry.data,
                icon: entry.icon,
              ),
            );
          }).toList(),
        );
      },
    );
  }

  Widget _buildResponsiveTwoUp({
    required Widget left,
    required Widget right,
  }) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth < 960) {
          return Column(
            children: <Widget>[
              left,
              const SizedBox(height: 16),
              right,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(child: left),
            const SizedBox(width: 16),
            Expanded(child: right),
          ],
        );
      },
    );
  }

  Widget _buildResponsiveThreeUp({
    required Widget first,
    required Widget second,
    required Widget third,
  }) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth < 1180) {
          return Column(
            children: <Widget>[
              first,
              const SizedBox(height: 16),
              second,
              const SizedBox(height: 16),
              third,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(child: first),
            const SizedBox(width: 16),
            Expanded(child: second),
            const SizedBox(width: 16),
            Expanded(child: third),
          ],
        );
      },
    );
  }

  Widget _buildFilterBar({
    required List<Widget> children,
  }) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth < 920) {
          return Column(
            children: children
                .map((Widget child) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: child,
                    ))
                .toList(),
          );
        }
        return Row(
          children: children
              .expand((Widget child) => <Widget>[
                    child,
                    const SizedBox(width: 12),
                  ])
              .toList()
            ..removeLast(),
        );
      },
    );
  }

  List<DropdownMenuItem<String>> _dropdownItems(List<String> values) {
    return values
        .map(
          (String value) => DropdownMenuItem<String>(
            value: value,
            child: Text(sentenceCaseStatus(value)),
          ),
        )
        .toList();
  }

  List<String> _cityOptions(Iterable<String> values) {
    final options = values
        .where((String value) => value.trim().isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return options;
  }

  List<Widget> _driverAccountActionButtons(
    AdminDriverRecord driver, {
    AdminEntityDrawerController? drawerController,
  }) {
    final List<Widget> verificationActions = <Widget>[
      if (!_isDriverVerificationApproved(driver))
        AdminPermissionGate(
          session: widget.session,
          permission: 'verification.approve',
          child: AdminGhostButton(
            label: 'Approve verification',
            onPressed: () async {
              await _driverApproveVerification(
                driver,
                drawerController: drawerController,
              );
            },
          ),
        ),
      AdminPermissionGate(
        session: widget.session,
        permission: 'support.write',
        child: AdminGhostButton(
          label: 'Flag for support',
          onPressed: () async {
            await _runSupportContactFlagForUser(
              uid: driver.id,
              role: 'driver',
              displayLabel: driver.name,
            );
          },
        ),
      ),
    ];

    Future<void> applyStatus(String status) async {
      final AdminDriverRecord before = driver;
      await _actionExecutor.run<void>(
        context: context,
        actionName: 'driver_update_status',
        successMessage: 'Driver status updated',
        applyOptimistic: () {
          _replaceDriverInPagedLists(
            driver.id,
            (AdminDriverRecord d) => d.copyWith(accountStatus: status),
          );
        },
        rollbackOptimistic: () {
          _replaceDriverInPagedLists(driver.id, (_) => before);
        },
        invoke: () => _dataService.updateDriverStatus(
          driver: driver,
          status: status,
        ),
        emitAudit: ({
          required bool success,
          Object? value,
          Object? error,
          required String correlationId,
        }) {
          if (!success) {
            return _driverAudit(
              action: 'driver_update_status',
              driverId: driver.id,
              before: before.accountStatus,
              after: null,
              metadata: <String, dynamic>{
                'attemptedStatus': status,
                if (error != null) 'error': error.toString(),
              },
              correlationId: correlationId,
            );
          }
          return _driverAudit(
            action: 'driver_update_status',
            driverId: driver.id,
            before: before.accountStatus,
            after: status,
            correlationId: correlationId,
          );
        },
        onSuccess: (_) {
          drawerController?.invalidateTabs();
          unawaited(_refreshDriverRows());
        },
      );
    }

    switch (driver.accountStatus) {
      case 'deactivated':
        return <Widget>[
          ...verificationActions,
          AdminPermissionGate(
            session: widget.session,
            permission: 'drivers.write',
            child: AdminPrimaryButton(
              label: 'Activate',
              onPressed: () async {
                await applyStatus('active');
              },
            ),
          ),
        ];
      case 'suspended':
        return <Widget>[
          ...verificationActions,
          AdminPermissionGate(
            session: widget.session,
            permission: 'drivers.write',
            child: AdminPrimaryButton(
              label: 'Activate',
              onPressed: () async {
                await applyStatus('active');
              },
            ),
          ),
          AdminPermissionGate(
            session: widget.session,
            permission: 'drivers.write',
            child: AdminGhostButton(
              label: 'Deactivate',
              onPressed: () async {
                await applyStatus('deactivated');
              },
            ),
          ),
        ];
      default:
        return <Widget>[
          ...verificationActions,
          const AdminPrimaryButton(
            label: 'Active',
            onPressed: null,
          ),
          AdminPermissionGate(
            session: widget.session,
            permission: 'drivers.write',
            child: AdminGhostButton(
              label: 'Deactivate',
              onPressed: () async {
                await applyStatus('deactivated');
              },
            ),
          ),
          AdminPermissionGate(
            session: widget.session,
            permission: 'drivers.write',
            child: AdminGhostButton(
              label: 'Suspend',
              onPressed: () async {
                await applyStatus('suspended');
              },
            ),
          ),
        ];
    }
  }

  Future<void> _runSupportContactFlagForUser({
    required String uid,
    required String role,
    required String displayLabel,
  }) async {
    final String r = role.trim().toLowerCase();
    if (r != 'driver' && r != 'rider') {
      return;
    }
    final TextEditingController noteController = TextEditingController();
    String priority = 'normal';
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) {
        return StatefulBuilder(
          builder:
              (BuildContext ctx, void Function(void Function()) setLocal) {
            return AlertDialog(
              title: Text('Flag for support: $displayLabel'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text(
                      'Creates an internal support queue entry and notifies the user that the team may reach out. Minimum 4 characters for the note.',
                      style: TextStyle(fontSize: 13, height: 1.35),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      key: ValueKey<String>(priority),
                      initialValue: priority,
                      decoration: const InputDecoration(
                        labelText: 'Priority',
                        border: OutlineInputBorder(),
                      ),
                      items: const <DropdownMenuItem<String>>[
                        DropdownMenuItem<String>(
                          value: 'normal',
                          child: Text('Normal'),
                        ),
                        DropdownMenuItem<String>(
                          value: 'high',
                          child: Text('High'),
                        ),
                        DropdownMenuItem<String>(
                          value: 'urgent',
                          child: Text('Urgent'),
                        ),
                      ],
                      onChanged: (String? v) {
                        setLocal(() {
                          priority = v ?? 'normal';
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: noteController,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Instruction for support team',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    if (noteController.text.trim().length < 4) {
                      return;
                    }
                    Navigator.pop(ctx, true);
                  },
                  child: const Text('Submit'),
                ),
              ],
            );
          },
        );
      },
    );
    if (ok != true || !mounted) {
      noteController.dispose();
      return;
    }
    final String note = noteController.text.trim();
    noteController.dispose();
    await _actionExecutor.run<void>(
      context: context,
      actionName: 'support_contact_flag',
      successMessage: 'Support flag saved. User notified when push delivery succeeds.',
      useDefaultMutationThrottle: true,
      invoke: () => _dataService.adminFlagUserForSupportContact(
            uid: uid,
            role: r,
            note: note,
            priority: priority,
          ),
      emitAudit: ({
        required bool success,
        Object? value,
        Object? error,
        required String correlationId,
      }) {
        final Map<String, dynamic> meta = <String, dynamic>{
          'targetRole': r,
          'priority': priority,
          'note': note,
          if (!success && error != null) 'error': error.toString(),
        };
        if (r == 'driver') {
          return _driverAudit(
            action: 'support_contact_flag',
            driverId: uid,
            before: null,
            after: success ? 'flagged' : null,
            metadata: meta,
            correlationId: correlationId,
          );
        }
        return _riderAudit(
          action: 'support_contact_flag',
          riderId: uid,
          before: null,
          after: success ? 'flagged' : null,
          metadata: meta,
          correlationId: correlationId,
        );
      },
    );
  }

  Future<void> _showRiderDialog(AdminRiderRecord rider) async {
    final Map<String, dynamic>? envelope =
        await _dataService.fetchRiderProfileForAdmin(rider.id);
    if (!mounted) {
      return;
    }
    final Map<String, dynamic> detailRider = envelope != null &&
            envelope['rider'] is Map
        ? Map<String, dynamic>.from(envelope['rider'] as Map)
        : Map<String, dynamic>.from(rider.rawData);
    final Map<String, dynamic>? authMeta = envelope != null &&
            envelope['auth_metadata'] is Map
        ? Map<String, dynamic>.from(envelope['auth_metadata'] as Map)
        : null;

    int msFrom(dynamic v) {
      if (v is num) {
        return v.toInt();
      }
      if (v is String) {
        return int.tryParse(v) ?? 0;
      }
      return 0;
    }

    String strOf(dynamic v) => '${v ?? ''}'.trim();

    String tryFormatAuthTs(String raw) {
      if (raw.isEmpty) {
        return raw;
      }
      try {
        return formatAdminDateTime(DateTime.parse(raw));
      } catch (_) {
        return raw;
      }
    }

    final int createdMs = msFrom(
      detailRider['created_at'] ?? detailRider['createdAt'],
    );
    final String email = strOf(detailRider['email']).isNotEmpty
        ? strOf(detailRider['email'])
        : rider.email;
    final String phone = strOf(detailRider['phone']).isNotEmpty
        ? strOf(detailRider['phone'])
        : rider.phone;
    final bool profileDone = detailRider.containsKey('profile_completed')
        ? detailRider['profile_completed'] == true
        : rider.profileCompleted;
    final String onboardingLabel = !detailRider.containsKey('onboarding_completed')
        ? 'Unknown'
        : (detailRider['onboarding_completed'] == true ? 'Complete' : 'Incomplete');
    final String lastAuth = strOf(authMeta?['last_sign_in_time']);
    final String authCreated = strOf(authMeta?['creation_time']);
    final String authCreatedDisplay = authCreated.isNotEmpty
        ? tryFormatAuthTs(authCreated)
        : (createdMs > 0
            ? formatAdminDateTime(
                DateTime.fromMillisecondsSinceEpoch(createdMs),
              )
            : 'Not set');
    final String lastAuthDisplay =
        lastAuth.isNotEmpty ? tryFormatAuthTs(lastAuth) : 'Not set';
    final String serviceArea = <String>[
      strOf(detailRider['city']),
      strOf(detailRider['state']),
      strOf(detailRider['rollout_city_id']),
    ].where((String e) => e.isNotEmpty).join(', ');
    final Map<String, dynamic> walletMap =
        detailRider['wallet'] is Map
            ? Map<String, dynamic>.from(detailRider['wallet'] as Map)
            : <String, dynamic>{};
    final String walletLine = walletMap['balance'] != null
        ? formatAdminCurrency(
            (walletMap['balance'] as num?)?.toDouble() ?? rider.walletBalance,
          )
        : formatAdminCurrency(rider.walletBalance);
    final int? tripHint = envelope != null && envelope['trip_count_hint'] is num
        ? (envelope['trip_count_hint'] as num).toInt()
        : null;
    final String tripsLine = tripHint != null
        ? 'About $tripHint trip history keys under users (capped count)'
        : '${rider.tripSummary.completedTrips} completed / ${rider.tripSummary.totalTrips} total (from list row)';

    final List<dynamic> warnRaw = envelope != null &&
            envelope['warnings_tail'] is List
        ? envelope['warnings_tail'] as List<dynamic>
        : const <dynamic>[];
    final List<dynamic> evtRaw = envelope != null &&
            envelope['account_events'] is List
        ? envelope['account_events'] as List<dynamic>
        : const <dynamic>[];
    final StringBuffer susp = StringBuffer();
    for (final dynamic e in evtRaw) {
      if (e is Map) {
        final Map<String, dynamic> m = Map<String, dynamic>.from(e);
        final int at = msFrom(m['at']);
        susp.writeln(
          '${m['code']}: ${m['message']}${at > 0 ? ' @ ${formatAdminDateTime(DateTime.fromMillisecondsSinceEpoch(at))}' : ''}',
        );
      }
    }
    for (final dynamic w in warnRaw) {
      if (w is Map) {
        final Map<String, dynamic> m = Map<String, dynamic>.from(w);
        final int at = msFrom(m['created_at']);
        susp.writeln(
          '${m['kind']}: ${m['message']}${at > 0 ? ' @ ${formatAdminDateTime(DateTime.fromMillisecondsSinceEpoch(at))}' : ''}',
        );
      }
    }
    final String suspText =
        susp.isEmpty ? 'None in RTDB warning / account-event fields.' : susp.toString().trim();

    await _showDetailsDialog(
      title: rider.name,
      subtitle: phone.isNotEmpty ? phone : rider.id,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AdminKeyValueWrap(
            items: <String, String>{
              'UID': rider.id,
              'Auth creation': authCreatedDisplay,
              'Email': email.isNotEmpty ? email : 'Not set',
              'Phone': phone.isNotEmpty ? phone : 'Not set',
              'Profile completed': profileDone ? 'Yes' : 'No',
              'Onboarding': onboardingLabel,
              'Last login (Auth)': lastAuthDisplay,
              'Service area':
                  serviceArea.isNotEmpty ? serviceArea : 'Not set',
              'Wallet': walletLine,
              'Trips': tripsLine,
              'Suspension / warnings': suspText,
              'City': rider.city.isNotEmpty ? rider.city : 'Not set',
              'Status': sentenceCaseStatus(rider.status),
              'Verification': sentenceCaseStatus(rider.verificationStatus),
              'Risk': sentenceCaseStatus(rider.riskStatus),
              'Payment': sentenceCaseStatus(rider.paymentStatus),
              'Trip history (list)':
                  '${rider.tripSummary.completedTrips} completed / ${rider.tripSummary.totalTrips} total',
              'Outstanding fees': formatAdminCurrency(rider.outstandingFeesNgn),
            },
          ),
          const SizedBox(height: 18),
          if (_isRiderIdentityVerified(rider))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    Icons.verified_user_rounded,
                    size: 22,
                    color: Colors.green.shade700,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Rider identity is verified. Approve / reject selfie actions are hidden.',
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.35,
                        color: Colors.grey.shade800,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: <Widget>[
                AdminGhostButton(
                  label: 'Approve rider selfie',
                  onPressed: () async {
                    Navigator.of(context).pop();
                    if (!mounted) {
                      return;
                    }
                    await _actionExecutor.run<void>(
                      context: context,
                      actionName: 'rider_review_selfie_approve',
                      successMessage: 'Selfie approved.',
                      useDefaultMutationThrottle: true,
                      invoke: () => _dataService.adminReviewRiderFirestoreIdentity(
                        riderId: rider.id,
                        approve: true,
                      ),
                      emitAudit: ({
                        required bool success,
                        Object? value,
                        Object? error,
                        required String correlationId,
                      }) {
                        return _riderAudit(
                          action: 'rider_review_selfie_approve',
                          riderId: rider.id,
                          before: rider.verificationStatus,
                          after: success ? 'approved' : null,
                          metadata: <String, dynamic>{
                            if (!success && error != null) 'error': error.toString(),
                          },
                          correlationId: correlationId,
                        );
                      },
                      onSuccess: (_) {
                        unawaited(_refresh());
                      },
                    );
                  },
                ),
                AdminGhostButton(
                  label: 'Reject rider selfie',
                  onPressed: () async {
                    final reason = await _promptAdminReason(
                      title: 'Reject rider selfie',
                      fieldLabel: 'Reason (audit trail, min 8 chars)',
                      minLength: 8,
                    );
                    if (reason == null || !mounted) {
                      return;
                    }
                    Navigator.of(context).pop();
                    if (!mounted) {
                      return;
                    }
                    await _actionExecutor.run<void>(
                      context: context,
                      actionName: 'rider_review_selfie_reject',
                      successMessage: 'Selfie rejected.',
                      useDefaultMutationThrottle: true,
                      invoke: () => _dataService.adminReviewRiderFirestoreIdentity(
                        riderId: rider.id,
                        approve: false,
                        rejectionReason: reason,
                      ),
                      emitAudit: ({
                        required bool success,
                        Object? value,
                        Object? error,
                        required String correlationId,
                      }) {
                        return _riderAudit(
                          action: 'rider_review_selfie_reject',
                          riderId: rider.id,
                          before: rider.verificationStatus,
                          after: success ? 'rejected' : null,
                          metadata: <String, dynamic>{
                            'rejectionReason': reason,
                            if (!success && error != null) 'error': error.toString(),
                          },
                          correlationId: correlationId,
                        );
                      },
                      onSuccess: (_) {
                        unawaited(_refresh());
                      },
                    );
                  },
                ),
              ],
            ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              AdminGhostButton(
                label: 'Tell support to contact rider',
                onPressed: () async {
                  await _runSupportContactFlagForUser(
                    uid: rider.id,
                    role: 'rider',
                    displayLabel: rider.name,
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: <Widget>[
              AdminPrimaryButton(
                label: rider.status == 'suspended'
                    ? 'Reactivate rider'
                    : 'Suspend rider',
                onPressed: () async {
                  if (rider.status == 'suspended') {
                    Navigator.of(context).pop();
                    if (!mounted) {
                      return;
                    }
                    await _actionExecutor.run<void>(
                      context: context,
                      actionName: 'rider_reactivate',
                      successMessage: 'Rider reactivated.',
                      useDefaultMutationThrottle: true,
                      invoke: () => _dataService.updateRiderStatus(
                        riderId: rider.id,
                        status: 'active',
                      ),
                      emitAudit: ({
                        required bool success,
                        Object? value,
                        Object? error,
                        required String correlationId,
                      }) {
                        return _riderAudit(
                          action: 'rider_reactivate',
                          riderId: rider.id,
                          before: rider.status,
                          after: success ? 'active' : null,
                          metadata: <String, dynamic>{
                            if (!success && error != null) 'error': error.toString(),
                          },
                          correlationId: correlationId,
                        );
                      },
                      onSuccess: (_) {
                        unawaited(_refresh());
                      },
                    );
                    return;
                  }
                  final reason = await _promptAdminReason(
                    title: 'Suspend rider',
                    fieldLabel: 'Reason (shown internally)',
                    minLength: 8,
                  );
                  if (reason == null || !mounted) {
                    return;
                  }
                  Navigator.of(context).pop();
                  if (!mounted) {
                    return;
                  }
                  await _actionExecutor.run<void>(
                    context: context,
                    actionName: 'rider_suspend',
                    successMessage: 'Rider suspended.',
                    useDefaultMutationThrottle: true,
                    invoke: () => _dataService.adminSuspendAccount(
                      uid: rider.id,
                      role: 'rider',
                      reason: reason,
                    ),
                    emitAudit: ({
                      required bool success,
                      Object? value,
                      Object? error,
                      required String correlationId,
                    }) {
                      return _riderAudit(
                        action: 'rider_suspend',
                        riderId: rider.id,
                        before: rider.status,
                        after: success ? 'suspended' : null,
                        metadata: <String, dynamic>{
                          'reason': reason,
                          if (!success && error != null) 'error': error.toString(),
                        },
                        correlationId: correlationId,
                      );
                    },
                    onSuccess: (_) {
                      unawaited(_refresh());
                    },
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  int _driverDrawerTabIndex(String? tabId) {
    if (tabId == null || tabId.trim().isEmpty) {
      return 0;
    }
    final int i = _driverDrawerTabIds.indexOf(tabId.trim());
    return i >= 0 ? i : 0;
  }

  void _tryConsumeInitialDriverDeepLink() {
    if (_initialDriverDeepLinkHandled) {
      return;
    }
    final AdminDriverDeepLink? link = widget.initialDriverDeepLink;
    if (link == null || _section != AdminSection.drivers) {
      return;
    }
    if (_driversOnlyLoading && _driversOnly == null) {
      return;
    }
    _initialDriverDeepLinkHandled = true;
    unawaited(_openDriverDrawerForDeepLink(link));
  }

  Future<void> _openDriverDrawerForDeepLink(AdminDriverDeepLink link) async {
    final AdminDriverRecord? row = await _resolveDriverForDrawer(link.driverId);
    if (!mounted || row == null) {
      return;
    }
    await _showDriverDialog(row, initialTabId: link.tab, syncUrl: false);
  }

  Future<AdminDriverRecord?> _resolveDriverForDrawer(String driverId) async {
    final List<AdminDriverRecord> pool =
        _driversOnly ?? _snapshot?.drivers ?? const <AdminDriverRecord>[];
    for (final AdminDriverRecord d in pool) {
      if (d.id == driverId) {
        return d;
      }
    }
    final Map<String, dynamic>? overview =
        await _dataService.fetchDriverEntityTabForAdmin(
      driverId: driverId,
      tabId: 'overview',
    );
    if (overview == null || overview['success'] != true) {
      return null;
    }
    final Object? raw = overview['driver'];
    if (raw is! Map) {
      return _minimalDriverPlaceholder(driverId);
    }
    return _driverFromOverviewMap(driverId, Map<String, dynamic>.from(raw));
  }

  AdminDriverRecord _minimalDriverPlaceholder(String driverId) {
    return AdminDriverRecord(
      id: driverId,
      name: driverId,
      phone: '',
      email: '',
      city: '',
      stateOrRegion: '',
      accountStatus: 'active',
      status: 'offline',
      isOnline: false,
      verificationStatus: 'incomplete',
      vehicleName: '',
      plateNumber: '',
      tripCount: 0,
      completedTripCount: 0,
      grossEarnings: 0,
      netEarnings: 0,
      walletBalance: 0,
      totalWithdrawn: 0,
      pendingWithdrawals: 0,
      monetizationModel: 'commission',
      subscriptionPlanType: 'monthly',
      subscriptionStatus: 'not_started',
      subscriptionActive: false,
      createdAt: null,
      updatedAt: null,
      serviceTypes: const <String>['ride'],
      rawData: const <String, dynamic>{},
    );
  }

  AdminDriverRecord _driverFromOverviewMap(
    String driverId,
    Map<String, dynamic> m,
  ) {
    String s(dynamic v) => '${v ?? ''}'.trim();
    final Map<String, dynamic> ver = m['verification'] is Map
        ? Map<String, dynamic>.from(m['verification'] as Map)
        : <String, dynamic>{};
    final Map<String, dynamic> veh = m['vehicle'] is Map
        ? Map<String, dynamic>.from(m['vehicle'] as Map)
        : <String, dynamic>{};
    return AdminDriverRecord(
      id: driverId,
      name: s(m['name']).isEmpty ? 'Driver' : s(m['name']),
      phone: s(m['phone']),
      email: s(m['email']),
      city: s(m['city']),
      stateOrRegion: s(m['state'] ?? m['region']),
      accountStatus: s(m['accountStatus'] ?? m['account_status']).isEmpty
          ? 'active'
          : s(m['accountStatus'] ?? m['account_status']),
      status: s(m['status']).isEmpty ? 'offline' : s(m['status']),
      isOnline: m['isOnline'] == true || m['is_online'] == true,
      verificationStatus:
          s(ver['overallStatus'] ?? m['verification_status']).isEmpty
              ? 'incomplete'
              : s(ver['overallStatus'] ?? m['verification_status']),
      vehicleName: s(m['car'] ?? veh['model']),
      plateNumber: s(m['plate'] ?? veh['plate']),
      tripCount: int.tryParse('${m['tripCount'] ?? m['trip_count'] ?? 0}') ?? 0,
      completedTripCount: int.tryParse(
            '${m['completedTripCount'] ?? m['completed_trip_count'] ?? 0}',
          ) ??
          0,
      grossEarnings: (num.tryParse(
                '${m['grossEarnings'] ?? m['gross_earnings'] ?? 0}',
              ) ??
              0)
          .toDouble(),
      netEarnings: (num.tryParse(
                '${m['netEarnings'] ?? m['net_earnings'] ?? 0}',
              ) ??
              0)
          .toDouble(),
      walletBalance: (num.tryParse(
                '${m['walletBalance'] ?? m['wallet_balance'] ?? 0}',
              ) ??
              0)
          .toDouble(),
      totalWithdrawn: (num.tryParse(
                '${m['totalWithdrawn'] ?? m['total_withdrawn'] ?? 0}',
              ) ??
              0)
          .toDouble(),
      pendingWithdrawals: (num.tryParse(
                '${m['pendingWithdrawals'] ?? m['pending_withdrawals'] ?? 0}',
              ) ??
              0)
          .toDouble(),
      monetizationModel:
          s(m['monetization_model'] ?? m['monetizationModel']).isEmpty
              ? 'commission'
              : s(m['monetization_model'] ?? m['monetizationModel']),
      subscriptionPlanType:
          s(m['subscription_plan_type'] ?? m['subscriptionPlanType']).isEmpty
              ? 'monthly'
              : s(m['subscription_plan_type'] ?? m['subscriptionPlanType']),
      subscriptionStatus:
          s(m['subscription_status'] ?? m['subscriptionStatus']).isEmpty
              ? 'not_started'
              : s(m['subscription_status'] ?? m['subscriptionStatus']),
      subscriptionActive:
          m['subscription_active'] == true || m['subscriptionActive'] == true,
      createdAt: null,
      updatedAt: null,
      serviceTypes: const <String>['ride'],
      rawData: m,
    );
  }

  void _replaceDriverInPagedLists(
    String driverId,
    AdminDriverRecord Function(AdminDriverRecord current) map,
  ) {
    final AdminPanelSnapshot? snap = _snapshot;
    final bool inPaged =
        _driversOnly != null && _driversOnly!.any((AdminDriverRecord d) => d.id == driverId);
    final bool inSnapshot =
        snap != null && snap.drivers.any((AdminDriverRecord d) => d.id == driverId);
    if (!inPaged && !inSnapshot) {
      return;
    }
    setState(() {
      if (inPaged) {
        _driversOnly = _driversOnly!
            .map(
              (AdminDriverRecord d) => d.id == driverId ? map(d) : d,
            )
            .toList(growable: false);
      }
      if (inSnapshot) {
        final AdminPanelSnapshot s = snap;
        _snapshot = s.copyWith(
          drivers: s.drivers
              .map(
                (AdminDriverRecord d) => d.id == driverId ? map(d) : d,
              )
              .toList(growable: false),
        );
      }
    });
    _recomputeDriverFilter();
  }

  AdminAuditEvent _driverAudit({
    required String action,
    required String driverId,
    Object? before,
    Object? after,
    Map<String, dynamic> metadata = const <String, dynamic>{},
    String? correlationId,
    int? entityRevision,
    DateTime? entityUpdatedAt,
  }) {
    return AdminAuditEvent(
      actorUid: widget.session.uid,
      actorEmail: widget.session.email,
      entityType: 'driver',
      entityId: driverId,
      action: action,
      before: before,
      after: after,
      metadata: metadata,
      correlationId: correlationId,
      entityRevision: entityRevision,
      entityUpdatedAt: entityUpdatedAt,
    );
  }

  AdminAuditEvent _riderAudit({
    required String action,
    required String riderId,
    Object? before,
    Object? after,
    Map<String, dynamic> metadata = const <String, dynamic>{},
    String? correlationId,
  }) {
    return AdminAuditEvent(
      actorUid: widget.session.uid,
      actorEmail: widget.session.email,
      entityType: 'rider',
      entityId: riderId,
      action: action,
      before: before,
      after: after,
      metadata: metadata,
      correlationId: correlationId,
    );
  }

  AdminAuditEvent _withdrawalAudit({
    required String action,
    required String withdrawalId,
    Object? before,
    Object? after,
    Map<String, dynamic> metadata = const <String, dynamic>{},
    String? correlationId,
  }) {
    return AdminAuditEvent(
      actorUid: widget.session.uid,
      actorEmail: widget.session.email,
      entityType: 'withdrawal',
      entityId: withdrawalId,
      action: action,
      before: before,
      after: after,
      metadata: metadata,
      correlationId: correlationId,
    );
  }

  Future<void> _refreshDriverRows() async {
    if (_section == AdminSection.drivers) {
      await _loadDriversOnly(resetServerCursors: false);
    }
  }

  Future<void> _showDriverDialog(
    AdminDriverRecord driver, {
    String? initialTabId,
    bool syncUrl = true,
  }) async {
    if (!mounted) {
      return;
    }
    final int t0 = DateTime.now().millisecondsSinceEpoch;
    final AdminEntityDrawerController controller = AdminEntityDrawerController();
    final int initialIndex = _driverDrawerTabIndex(initialTabId);
    await AdminEntityDrawer.present(
      context,
      entityType: 'driver',
      entityId: driver.id,
      title: driver.name,
      subtitle: driver.phone.isNotEmpty ? driver.phone : driver.id,
      tabs: const <AdminEntityTabSpec>[
        AdminEntityTabSpec(id: 'overview', label: 'Overview', icon: Icons.person_outline),
        AdminEntityTabSpec(
          id: 'verification',
          label: 'Verification',
          icon: Icons.verified_user_outlined,
        ),
        AdminEntityTabSpec(
          id: 'wallet',
          label: 'Wallet',
          icon: Icons.account_balance_wallet_outlined,
        ),
        AdminEntityTabSpec(id: 'trips', label: 'Trips', icon: Icons.route_outlined),
        AdminEntityTabSpec(
          id: 'subscription',
          label: 'Subscription',
          icon: Icons.card_membership_outlined,
        ),
        AdminEntityTabSpec(
          id: 'violations',
          label: 'Violations',
          icon: Icons.report_problem_outlined,
        ),
        AdminEntityTabSpec(
          id: 'notes',
          label: 'Notes',
          icon: Icons.sticky_note_2_outlined,
        ),
        AdminEntityTabSpec(id: 'audit', label: 'Audit', icon: Icons.history),
      ],
      controller: controller,
      debugOpenStartedMs: t0,
      cachePolicy: AdminEntityCachePolicy.driverDrawer(),
      syncBrowserHistory: syncUrl && kIsWeb,
      initialTabIndex: initialIndex,
      loadBody: (String tabId) => AdminDriverDrawerTabs.loadBody(
        driver: driver,
        tabId: tabId,
        dataService: _dataService,
        actionButtonsFor: (AdminDriverRecord d) =>
            _driverAccountActionButtons(d, drawerController: controller),
      ),
    );
  }

  Future<void> _showWithdrawalDialog(AdminWithdrawalRecord withdrawal) async {
    final referenceController =
        TextEditingController(text: withdrawal.payoutReference);
    final noteController = TextEditingController(text: withdrawal.notes);
    String selectedStatus = withdrawal.status;

    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder:
              (BuildContext context, void Function(void Function()) setState) {
            return Dialog(
              insetPadding: const EdgeInsets.all(24),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Withdrawal ${withdrawal.id}',
                        style: const TextStyle(
                          color: AdminThemeTokens.ink,
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${sentenceCaseStatus(withdrawal.entityType)} • ${formatAdminCurrency(withdrawal.amount)}',
                        style: const TextStyle(color: Color(0xFF6B655B)),
                      ),
                      if (withdrawal.entityType == 'driver' &&
                          !withdrawal.hasPayoutDestination) ...<Widget>[
                        const SizedBox(height: 12),
                        AdminStatusChip(
                          'Missing withdrawal destination',
                          color: AdminThemeTokens.warning,
                        ),
                      ],
                      const SizedBox(height: 18),
                      AdminKeyValueWrap(
                        items: <String, String>{
                          'Entity type': withdrawal.entityType,
                          'Driver UID': withdrawal.entityType == 'driver'
                              ? (withdrawal.driverId.isNotEmpty
                                  ? withdrawal.driverId
                                  : '—')
                              : '—',
                          'Merchant ID': withdrawal.entityType == 'merchant'
                              ? (withdrawal.merchantId.isNotEmpty
                                  ? withdrawal.merchantId
                                  : '—')
                              : '—',
                          'Party name': withdrawal.driverName.isNotEmpty
                              ? withdrawal.driverName
                              : '—',
                          'Amount': formatAdminCurrency(withdrawal.amount),
                          'Current status':
                              sentenceCaseStatus(withdrawal.status),
                          'Requested at':
                              formatAdminDateTime(withdrawal.requestDate),
                          'Processed at':
                              formatAdminDateTime(withdrawal.processedDate),
                          'Bank name': withdrawal.bankName.isNotEmpty
                              ? withdrawal.bankName
                              : '—',
                          'Account number': withdrawal.accountNumber.isNotEmpty
                              ? withdrawal.accountNumber
                              : '—',
                          'Account holder name':
                              withdrawal.accountName.isNotEmpty
                                  ? withdrawal.accountName
                                  : '—',
                        },
                      ),
                      const SizedBox(height: 18),
                      AdminFilterDropdown<String>(
                        value: selectedStatus,
                        items: _dropdownItems(<String>[
                          'pending',
                          'processing',
                          'paid',
                          'failed',
                        ]),
                        onChanged: (String? value) {
                          setState(() {
                            selectedStatus = value ?? selectedStatus;
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: referenceController,
                        decoration: _dialogInputDecoration('Payout reference'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: noteController,
                        minLines: 2,
                        maxLines: 4,
                        decoration: _dialogInputDecoration('Audit note'),
                      ),
                      const SizedBox(height: 18),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Builder(
                              builder: (BuildContext buttonContext) {
                              final bool needsWithdrawalApprove =
                                  selectedStatus == 'paid' ||
                                      selectedStatus == 'rejected';
                              final bool canMutateWithdrawal =
                                  needsWithdrawalApprove
                                      ? widget.session.hasPermission(
                                          'withdrawals.approve',
                                        )
                                      : widget.session.hasPermission(
                                          'finance.write',
                                        );
                              final Future<void> Function()? onSave =
                                  canMutateWithdrawal
                                      ? () async {
                                if (selectedStatus == 'paid' &&
                                    withdrawal.entityType == 'driver' &&
                                    !withdrawal.hasPayoutDestination) {
                                  ScaffoldMessenger.of(buttonContext).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Missing withdrawal destination. Cannot mark paid until payout details exist on this request.',
                                      ),
                                    ),
                                  );
                                  return;
                                }
                                final String auditNote = noteController.text.trim();
                                if (selectedStatus == 'paid' &&
                                    auditNote.length < 8) {
                                  ScaffoldMessenger.of(buttonContext).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Audit note is required (at least 8 characters) before marking paid.',
                                      ),
                                    ),
                                  );
                                  return;
                                }
                                Navigator.of(dialogContext).pop();
                                if (!mounted) {
                                  return;
                                }
                                await _actionExecutor.run<void>(
                                  context: context,
                                  actionName: 'withdrawal_update',
                                  successMessage: 'Payout record updated.',
                                  useDefaultMutationThrottle: true,
                                  invoke: () => _dataService.updateWithdrawal(
                                    withdrawal: withdrawal,
                                    status: selectedStatus,
                                    payoutReference: referenceController.text,
                                    note: noteController.text,
                                  ),
                                  emitAudit: ({
                                    required bool success,
                                    Object? value,
                                    Object? error,
                                    required String correlationId,
                                  }) {
                                    return _withdrawalAudit(
                                      action: 'withdrawal_update',
                                      withdrawalId: withdrawal.id,
                                      before: withdrawal.status,
                                      after: success ? selectedStatus : null,
                                      metadata: <String, dynamic>{
                                        'driverId': withdrawal.driverId,
                                        'payoutReference': referenceController.text,
                                        'note': noteController.text,
                                        if (!success && error != null) 'error': error.toString(),
                                      },
                                      correlationId: correlationId,
                                    );
                                  },
                                  onSuccess: (_) {
                                    unawaited(_refresh());
                                  },
                                );
                              }
                                      : null;
                              final Widget button = AdminPrimaryButton(
                                label: 'Save payout update',
                                onPressed: onSave,
                              );
                              if (canMutateWithdrawal) {
                                return button;
                              }
                              return Tooltip(
                                message: kAdminNoPermissionTooltip,
                                child: button,
                              );
                            },
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

    referenceController.dispose();
    noteController.dispose();
  }

  Future<void> _showSupportDialog(AdminSupportIssueRecord issue) async {
    await _showDetailsDialog(
      title: sentenceCaseStatus(issue.reason),
      subtitle:
          '${sentenceCaseStatus(issue.kind)} • ${issue.rideId.isNotEmpty ? issue.rideId : 'No trip ID'}',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AdminKeyValueWrap(
            items: <String, String>{
              'Status': sentenceCaseStatus(issue.status),
              'Kind': sentenceCaseStatus(issue.kind),
              'Ride ID':
                  issue.rideId.isNotEmpty ? issue.rideId : 'Not available',
              'Rider ID':
                  issue.riderId.isNotEmpty ? issue.riderId : 'Not available',
              'Driver ID':
                  issue.driverId.isNotEmpty ? issue.driverId : 'Not available',
              'City': issue.city.isNotEmpty ? issue.city : 'Not set',
              'Created': formatAdminDateTime(issue.createdAt),
              'Updated': formatAdminDateTime(issue.updatedAt),
              'Summary': issue.summary,
            },
          ),
        ],
      ),
    );
  }

  Future<void> _showDetailsDialog({
    required String title,
    required String subtitle,
    required Widget body,
  }) {
    return showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return Dialog(
          insetPadding: const EdgeInsets.all(24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: const TextStyle(
                        color: AdminThemeTokens.ink,
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      subtitle,
                      style: const TextStyle(color: Color(0xFF6F685E)),
                    ),
                    const SizedBox(height: 20),
                    body,
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  InputDecoration _dialogInputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: AdminThemeTokens.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: AdminThemeTokens.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: AdminThemeTokens.gold, width: 1.4),
      ),
    );
  }

  List<AdminTrendPoint> _topCancellationCities(List<AdminTripRecord> trips) {
    final counts = <String, double>{};
    for (final trip
        in trips.where((AdminTripRecord item) => item.status == 'cancelled')) {
      final city = trip.city.isNotEmpty ? trip.city : 'Unknown';
      counts[city] = (counts[city] ?? 0) + 1;
    }
    final entries = counts.entries.toList()
      ..sort((MapEntry<String, double> a, MapEntry<String, double> b) =>
          b.value.compareTo(a.value));
    return entries
        .take(5)
        .map((MapEntry<String, double> entry) =>
            AdminTrendPoint(label: entry.key, value: entry.value))
        .toList();
  }

  List<AdminTrendPoint> _problematicAccounts(AdminPanelSnapshot snapshot) {
    final items = <AdminTrendPoint>[];
    for (final rider in snapshot.riders) {
      if (rider.riskStatus == 'blacklisted' ||
          rider.paymentStatus == 'restricted' ||
          rider.outstandingFeesNgn > 0) {
        items.add(
          AdminTrendPoint(
            label: rider.name,
            value: mathScore(
              risk: rider.riskStatus == 'blacklisted' ? 3 : 0,
              payment: rider.paymentStatus == 'restricted' ? 2 : 0,
              fees: rider.outstandingFeesNgn > 0 ? 1 : 0,
            ),
          ),
        );
      }
    }
    return items.take(5).toList();
  }
}

double mathScore({
  required int risk,
  required int payment,
  required int fees,
}) {
  return (risk + payment + fees).toDouble();
}

class _MetricCardEntry {
  const _MetricCardEntry({
    required this.icon,
    required this.data,
  });

  final IconData icon;
  final AdminMetricCardData data;
}

class _AdminPendingNotification {
  const _AdminPendingNotification({
    required this.title,
    required this.subtitle,
    required this.section,
  });

  final String title;
  final String subtitle;
  final AdminSection section;
}

class _PricingEditor extends StatefulWidget {
  const _PricingEditor({
    required this.pricing,
    required this.settings,
    required this.onSave,
    required this.canEditPricing,
  });

  final AdminPricingConfig pricing;
  final AdminOperationalSettings settings;
  final bool canEditPricing;
  final Future<void> Function(
    List<AdminCityPricing> cities,
    double commissionRate,
    int weeklySubscriptionNgn,
    int monthlySubscriptionNgn,
  ) onSave;

  @override
  State<_PricingEditor> createState() => _PricingEditorState();
}

class _PricingEditorState extends State<_PricingEditor> {
  late final TextEditingController _commissionController;
  late final TextEditingController _weeklyController;
  late final TextEditingController _monthlyController;
  late final Map<String, _CityPricingControllers> _cityControllers;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _commissionController = TextEditingController(
      text: (widget.pricing.commissionRate * 100).toStringAsFixed(0),
    );
    _weeklyController = TextEditingController(
      text: widget.pricing.weeklySubscriptionNgn.toString(),
    );
    _monthlyController = TextEditingController(
      text: widget.pricing.monthlySubscriptionNgn.toString(),
    );
    _cityControllers = <String, _CityPricingControllers>{
      for (final city in widget.pricing.cities)
        city.city: _CityPricingControllers.fromCity(city),
    };
  }

  @override
  void dispose() {
    _commissionController.dispose();
    _weeklyController.dispose();
    _monthlyController.dispose();
    for (final controllers in _cityControllers.values) {
      controllers.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!widget.canEditPricing) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(kAdminNoPermissionTooltip)),
      );
      return;
    }
    final commissionPercent =
        double.tryParse(_commissionController.text.trim());
    final weekly = int.tryParse(_weeklyController.text.trim());
    final monthly = int.tryParse(_monthlyController.text.trim());
    if (commissionPercent == null ||
        weekly == null ||
        monthly == null ||
        commissionPercent < 0 ||
        weekly < 0 ||
        monthly < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Enter valid pricing and monetization values.')),
      );
      return;
    }

    final cities = <AdminCityPricing>[];
    for (final entry in _cityControllers.entries) {
      final controllers = entry.value;
      final baseFare = int.tryParse(controllers.baseFare.text.trim());
      final perKm = int.tryParse(controllers.perKm.text.trim());
      final perMinute = int.tryParse(controllers.perMinute.text.trim());
      final minimumFare = int.tryParse(controllers.minimumFare.text.trim());
      if (baseFare == null ||
          perKm == null ||
          perMinute == null ||
          minimumFare == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Enter valid fare fields for ${entry.key}.')),
        );
        return;
      }
      cities.add(
        AdminCityPricing(
          city: entry.key,
          baseFareNgn: baseFare,
          perKmNgn: perKm,
          perMinuteNgn: perMinute,
          minimumFareNgn: minimumFare,
          enabled: controllers.enabled,
        ),
      );
    }

    setState(() {
      _saving = true;
    });
    try {
      await widget.onSave(
        cities,
        commissionPercent / 100,
        weekly,
        monthly,
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pricing configuration saved.')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        AdminSummaryBanner(
          title: 'Pricing management',
          subtitle:
              'Display or safely edit official fare formulas for rollout regions (Lagos, Abuja/FCT, Delta, Edo, Imo, Anambra), together with NexRide monetization rules.',
          kpis: <String, String>{
            'Commission drivers':
                '${(widget.pricing.commissionRate * 100).toStringAsFixed(0)}%',
            'Weekly subscription':
                formatAdminCurrency(widget.pricing.weeklySubscriptionNgn),
            'Monthly subscription':
                formatAdminCurrency(widget.pricing.monthlySubscriptionNgn),
            'Config source': widget.pricing.loadedFromBackend
                ? 'Live backend'
                : 'Official defaults',
          },
        ),
        const SizedBox(height: 20),
        AdminSurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                'Monetization rules',
                style: TextStyle(
                  color: AdminThemeTokens.ink,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 16),
              _editorField(_commissionController, 'Commission rate (%)'),
              const SizedBox(height: 12),
              _editorField(_weeklyController, 'Weekly subscription (₦)'),
              const SizedBox(height: 12),
              _editorField(_monthlyController, 'Monthly subscription (₦)'),
              const SizedBox(height: 12),
              Text(
                widget.settings.withdrawalNoticeText,
                style: const TextStyle(
                  color: Color(0xFF6A645A),
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        ...widget.pricing.cities.map((AdminCityPricing city) {
          final controllers = _cityControllers[city.city]!;
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: AdminSurfaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          city.city,
                          style: const TextStyle(
                            color: AdminThemeTokens.ink,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      Switch.adaptive(
                        value: controllers.enabled,
                        activeTrackColor: AdminThemeTokens.gold,
                        onChanged: widget.canEditPricing
                            ? (bool value) {
                                setState(() {
                                  controllers.enabled = value;
                                });
                              }
                            : null,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  LayoutBuilder(
                    builder:
                        (BuildContext context, BoxConstraints constraints) {
                      final singleColumn = constraints.maxWidth < 860;
                      final children = <Widget>[
                        _editorField(controllers.baseFare, 'Base fare (₦)'),
                        _editorField(controllers.perKm, 'Per km (₦)'),
                        _editorField(controllers.perMinute, 'Per minute (₦)'),
                        _editorField(
                            controllers.minimumFare, 'Minimum fare (₦)'),
                      ];
                      if (singleColumn) {
                        return Column(
                          children: children
                              .map((Widget child) => Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: SizedBox(
                                        width: double.infinity, child: child),
                                  ))
                              .toList(),
                        );
                      }
                      return Row(
                        children: children
                            .expand((Widget child) => <Widget>[
                                  Expanded(child: child),
                                  const SizedBox(width: 12),
                                ])
                            .toList()
                          ..removeLast(),
                      );
                    },
                  ),
                ],
              ),
            ),
          );
        }),
        if (widget.canEditPricing)
          AdminPrimaryButton(
            label: _saving ? 'Saving...' : 'Save pricing config',
            onPressed: _saving ? null : _save,
            icon: Icons.save_outlined,
          )
        else
          Tooltip(
            message: kAdminNoPermissionTooltip,
            child: AdminPrimaryButton(
              label: _saving ? 'Saving...' : 'Save pricing config',
              onPressed: null,
              icon: Icons.save_outlined,
            ),
          ),
      ],
    );
  }

  Widget _editorField(TextEditingController controller, String label) {
    return TextField(
      controller: controller,
      readOnly: !widget.canEditPricing,
      decoration: InputDecoration(
        labelText: label,
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: AdminThemeTokens.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: AdminThemeTokens.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide:
              const BorderSide(color: AdminThemeTokens.gold, width: 1.4),
        ),
      ),
      keyboardType: TextInputType.number,
    );
  }
}

class _CityPricingControllers {
  _CityPricingControllers({
    required this.baseFare,
    required this.perKm,
    required this.perMinute,
    required this.minimumFare,
    required this.enabled,
  });

  factory _CityPricingControllers.fromCity(AdminCityPricing city) {
    return _CityPricingControllers(
      baseFare: TextEditingController(text: city.baseFareNgn.toString()),
      perKm: TextEditingController(text: city.perKmNgn.toString()),
      perMinute: TextEditingController(text: city.perMinuteNgn.toString()),
      minimumFare: TextEditingController(text: city.minimumFareNgn.toString()),
      enabled: city.enabled,
    );
  }

  final TextEditingController baseFare;
  final TextEditingController perKm;
  final TextEditingController perMinute;
  final TextEditingController minimumFare;
  bool enabled;

  void dispose() {
    baseFare.dispose();
    perKm.dispose();
    perMinute.dispose();
    minimumFare.dispose();
  }
}

class _AdminWarnFields {
  const _AdminWarnFields({
    required this.reason,
    required this.message,
  });

  final String reason;
  final String message;
}
