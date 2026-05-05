import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../admin_config.dart';
import '../models/admin_models.dart';
import '../services/admin_auth_service.dart';
import '../services/admin_data_service.dart';
import '../utils/admin_formatters.dart';
import '../widgets/admin_charts.dart';
import '../widgets/admin_components.dart';
import '../widgets/admin_shell.dart';
import '../../support_portal/models/support_models.dart';
import '../../support_portal/widgets/support_workspace_screen.dart';

class AdminPanelScreen extends StatefulWidget {
  const AdminPanelScreen({
    required this.session,
    super.key,
    this.dataService,
    this.authService,
    this.initialSection = AdminSection.dashboard,
    this.loginRoute = AdminRoutePaths.adminLogin,
    this.routeForSection,
    this.snapshotTimeout = const Duration(seconds: 12),
  });

  final AdminSession session;
  final AdminDataService? dataService;
  final AdminAuthService? authService;
  final AdminSection initialSection;
  final String loginRoute;
  final String Function(AdminSection section)? routeForSection;
  final Duration snapshotTimeout;

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen> {
  late final AdminDataService _dataService;
  late final AdminAuthService _authService;

  final TextEditingController _riderSearchController = TextEditingController();
  final TextEditingController _driverSearchController = TextEditingController();
  final TextEditingController _tripSearchController = TextEditingController();
  final TextEditingController _supportSearchController =
      TextEditingController();

  AdminPanelSnapshot? _snapshot;
  AdminSection _section = AdminSection.dashboard;
  bool _isLoading = true;
  String? _errorMessage;
  bool _tokenRefreshedForDashboardLoad = false;

  String _riderCityFilter = 'All';
  String _riderStatusFilter = 'All';
  String _riderSignupFilter = 'All time';
  String _driverCityFilter = 'All';
  String _driverStatusFilter = 'All';
  String _driverModelFilter = 'All';
  String _tripCityFilter = 'All';
  String _tripStatusFilter = 'All';
  String _supportKindFilter = 'All';

  @override
  void initState() {
    super.initState();
    _dataService = widget.dataService ?? AdminDataService();
    _authService = widget.authService ?? AdminAuthService();
    _section = widget.initialSection;
    _snapshot = _dataService.cachedSnapshot;
    _isLoading = _snapshot == null;
    debugPrint(
      '[AdminPanel] init section=${_section.name} adminUid=${widget.session.uid} adminEmail=${widget.session.email} cachedSnapshot=${_snapshot != null}',
    );
    _loadSnapshot();
  }

  @override
  void dispose() {
    _riderSearchController.dispose();
    _driverSearchController.dispose();
    _tripSearchController.dispose();
    _supportSearchController.dispose();
    super.dispose();
  }

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
      });
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
      onRefresh: _loadSnapshot,
      onLogout: _logout,
      liveDataSections: _snapshot?.liveDataSections ?? const <String, bool>{},
      child: _buildBody(),
    );
  }

  void _handleSectionSelected(AdminSection next) {
    debugPrint('[AdminPanel] section change ${_section.name} -> ${next.name}');
    final routeForSection = widget.routeForSection;
    if (routeForSection != null) {
      final nextRoute = routeForSection(next);
      if (kIsWeb) {
        if (_section != next) {
          setState(() {
            _section = next;
          });
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
  }

  Widget _buildBody() {
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
              AdminSection.riders => _buildRidersSection(_snapshot!),
              AdminSection.drivers => _buildDriversSection(_snapshot!),
              AdminSection.trips => _buildTripsSection(_snapshot!),
              AdminSection.finance => _buildFinanceSection(_snapshot!),
              AdminSection.withdrawals => _buildWithdrawalsSection(_snapshot!),
              AdminSection.pricing => _buildPricingSection(_snapshot!),
              AdminSection.subscriptions =>
                _buildSubscriptionsSection(_snapshot!),
              AdminSection.verification =>
                _buildVerificationSection(_snapshot!),
              AdminSection.support => SupportWorkspaceScreen(
                  session: SupportSession.adminOverride(
                    uid: widget.session.uid,
                    email: widget.session.email,
                    displayName: widget.session.displayName,
                    role: 'admin',
                    accessMode: widget.session.accessMode,
                  ),
                  embeddedInAdmin: true,
                  initialView: SupportInboxView.dashboard,
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
          caption: 'Registered rider accounts across the platform.',
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

  Widget _buildRidersSection(AdminPanelSnapshot snapshot) {
    debugPrint(
      '[AdminPanel] riders section entered adminUid=${widget.session.uid} total=${snapshot.riders.length} query="${_riderSearchController.text.trim()}" cityFilter=$_riderCityFilter statusFilter=$_riderStatusFilter signupFilter=$_riderSignupFilter',
    );
    final cities = _cityOptions(
        snapshot.riders.map((AdminRiderRecord rider) => rider.city));
    final query = _riderSearchController.text.trim().toLowerCase();
    final filtered = snapshot.riders.where((AdminRiderRecord rider) {
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
      return matchesQuery &&
          matchesCity &&
          matchesStatus &&
          matchesSignupWindow;
    }).toList();

    if (snapshot.riders.isEmpty) {
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
              'Search riders, review trip activity, inspect payment context, and apply account-level status controls.',
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
                onChanged: (_) => setState(() {}),
              ),
            ),
            Expanded(
              child: AdminFilterDropdown<String>(
                value: _riderCityFilter,
                items: _dropdownItems(<String>['All', ...cities]),
                onChanged: (String? value) => setState(() {
                  _riderCityFilter = value ?? 'All';
                }),
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
                onChanged: (String? value) => setState(() {
                  _riderStatusFilter = value ?? 'All';
                }),
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
                onChanged: (String? value) => setState(() {
                  _riderSignupFilter = value ?? 'All time';
                }),
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
                '${snapshot.riders.length} live records',
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
                      Text(
                        rider.name,
                        style: const TextStyle(fontWeight: FontWeight.w800),
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
              ],
            );
          }).toList(),
        ),
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
              onPressed: _loadSnapshot,
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
            onPressed: _loadSnapshot,
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

  Widget _buildDriversSection(AdminPanelSnapshot snapshot) {
    final cities = _cityOptions(
        snapshot.drivers.map((AdminDriverRecord driver) => driver.city));
    final query = _driverSearchController.text.trim().toLowerCase();
    final filtered = snapshot.drivers.where((AdminDriverRecord driver) {
      final matchesQuery = query.isEmpty ||
          driver.id.toLowerCase().contains(query) ||
          driver.name.toLowerCase().contains(query) ||
          driver.phone.toLowerCase().contains(query) ||
          driver.city.toLowerCase().contains(query) ||
          driver.vehicleName.toLowerCase().contains(query) ||
          driver.plateNumber.toLowerCase().contains(query);
      final matchesCity =
          _driverCityFilter == 'All' || driver.city == _driverCityFilter;
      final matchesStatus = _driverStatusFilter == 'All' ||
          driver.accountStatus == _driverStatusFilter;
      final matchesModel = _driverModelFilter == 'All' ||
          driver.monetizationModel == _driverModelFilter;
      return matchesQuery && matchesCity && matchesStatus && matchesModel;
    }).toList();

    if (snapshot.drivers.isEmpty) {
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
              'Review verification, online status, wallets, withdrawals, trip performance, and commission versus subscription monetization from one place.',
        ),
        const SizedBox(height: 16),
        _buildFilterBar(
          children: <Widget>[
            Expanded(
              flex: 2,
              child: AdminTextFilterField(
                controller: _driverSearchController,
                hintText:
                    'Search drivers by name, phone, city, vehicle, plate, or driver ID',
                onChanged: (_) => setState(() {}),
              ),
            ),
            Expanded(
              child: AdminFilterDropdown<String>(
                value: _driverCityFilter,
                items: _dropdownItems(<String>['All', ...cities]),
                onChanged: (String? value) => setState(() {
                  _driverCityFilter = value ?? 'All';
                }),
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
                onChanged: (String? value) => setState(() {
                  _driverStatusFilter = value ?? 'All';
                }),
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
                onChanged: (String? value) => setState(() {
                  _driverModelFilter = value ?? 'All';
                }),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        AdminDataTableCard(
          heading: Text(
            '${filtered.length} drivers',
            style: const TextStyle(
              color: AdminThemeTokens.ink,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          columns: const <DataColumn>[
            DataColumn(label: Text('Driver')),
            DataColumn(label: Text('City')),
            DataColumn(label: Text('Account')),
            DataColumn(label: Text('Verification')),
            DataColumn(label: Text('Vehicle')),
            DataColumn(label: Text('Trips')),
            DataColumn(label: Text('Earnings')),
            DataColumn(label: Text('Wallet')),
            DataColumn(label: Text('Model')),
          ],
          rows: filtered.map((AdminDriverRecord driver) {
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
              ],
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildTripsSection(AdminPanelSnapshot snapshot) {
    final cities =
        _cityOptions(snapshot.trips.map((AdminTripRecord trip) => trip.city));
    final query = _tripSearchController.text.trim().toLowerCase();
    final filtered = snapshot.trips.where((AdminTripRecord trip) {
      final matchesQuery = query.isEmpty ||
          trip.id.toLowerCase().contains(query) ||
          trip.riderName.toLowerCase().contains(query) ||
          trip.driverName.toLowerCase().contains(query) ||
          trip.riderPhone.toLowerCase().contains(query) ||
          trip.driverPhone.toLowerCase().contains(query) ||
          trip.city.toLowerCase().contains(query);
      final matchesStatus =
          _tripStatusFilter == 'All' || trip.status == _tripStatusFilter;
      final matchesCity =
          _tripCityFilter == 'All' || trip.city == _tripCityFilter;
      return matchesQuery && matchesStatus && matchesCity;
    }).toList();

    if (snapshot.trips.isEmpty) {
      return const AdminEmptyState(
        title: 'No trip records yet',
        message:
            'Trip management reads live ride data from Realtime Database. When records exist, you will see lifecycle status, settlement details, route logs, and timestamps here.',
        icon: Icons.route_outlined,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const AdminSectionHeader(
          title: 'Trips management',
          description:
              'Search by trip ID, rider, driver, phone number, or city, then inspect lifecycle timestamps, settlement outcomes, and route monitoring records.',
        ),
        const SizedBox(height: 16),
        _buildFilterBar(
          children: <Widget>[
            Expanded(
              flex: 2,
              child: AdminTextFilterField(
                controller: _tripSearchController,
                hintText: 'Search trip ID, rider, driver, phone, or city',
                onChanged: (_) => setState(() {}),
              ),
            ),
            Expanded(
              child: AdminFilterDropdown<String>(
                value: _tripStatusFilter,
                items: _dropdownItems(<String>[
                  'All',
                  'requested',
                  'assigned',
                  'accepted',
                  'arrived',
                  'started',
                  'completed',
                  'cancelled',
                ]),
                onChanged: (String? value) => setState(() {
                  _tripStatusFilter = value ?? 'All';
                }),
              ),
            ),
            Expanded(
              child: AdminFilterDropdown<String>(
                value: _tripCityFilter,
                items: _dropdownItems(<String>['All', ...cities]),
                onChanged: (String? value) => setState(() {
                  _tripCityFilter = value ?? 'All';
                }),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        AdminDataTableCard(
          heading: Text(
            '${filtered.length} trips',
            style: const TextStyle(
              color: AdminThemeTokens.ink,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          columns: const <DataColumn>[
            DataColumn(label: Text('Trip')),
            DataColumn(label: Text('Status')),
            DataColumn(label: Text('City')),
            DataColumn(label: Text('Rider')),
            DataColumn(label: Text('Driver')),
            DataColumn(label: Text('Fare')),
            DataColumn(label: Text('Model')),
            DataColumn(label: Text('Payment')),
            DataColumn(label: Text('Created')),
          ],
          rows: filtered.map((AdminTripRecord trip) {
            return DataRow(
              onSelectChanged: (_) => _showTripDialog(trip),
              cells: <DataCell>[
                DataCell(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Text(
                        trip.id,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      Text(sentenceCaseStatus(trip.serviceType)),
                    ],
                  ),
                ),
                DataCell(AdminStatusChip(trip.status)),
                DataCell(Text(trip.city.isNotEmpty ? trip.city : 'Not set')),
                DataCell(Text(trip.riderName)),
                DataCell(Text(trip.driverName)),
                DataCell(Text(formatAdminCurrency(trip.fareAmount))),
                DataCell(AdminStatusChip(trip.appliedMonetizationModel)),
                DataCell(Text(trip.paymentMethod)),
                DataCell(Text(formatAdminDateTime(trip.createdAt))),
              ],
            );
          }).toList(),
        ),
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

  Widget _buildWithdrawalsSection(AdminPanelSnapshot snapshot) {
    if (snapshot.withdrawals.isEmpty) {
      return const AdminEmptyState(
        title: 'No withdrawal requests yet',
        message:
            'The withdrawals workflow is live and ready. Once drivers submit payout requests, you can approve, process, pay, fail, and add payout references from this screen.',
        icon: Icons.account_balance_wallet_outlined,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const AdminSectionHeader(
          title: 'Driver withdrawals',
          description:
              'Review payout requests, bank details, references, and processing states, then update status directly from the admin console.',
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
                snapshot.settings.withdrawalNoticeText,
                style: const TextStyle(
                  color: Color(0xFF6D675E),
                  height: 1.55,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        AdminDataTableCard(
          columns: const <DataColumn>[
            DataColumn(label: Text('Driver')),
            DataColumn(label: Text('Amount')),
            DataColumn(label: Text('Status')),
            DataColumn(label: Text('Requested')),
            DataColumn(label: Text('Bank')),
            DataColumn(label: Text('Reference')),
          ],
          rows: snapshot.withdrawals.map((AdminWithdrawalRecord item) {
            return DataRow(
              onSelectChanged: (_) => _showWithdrawalDialog(item),
              cells: <DataCell>[
                DataCell(Text(item.driverName)),
                DataCell(Text(formatAdminCurrency(item.amount))),
                DataCell(AdminStatusChip(item.status)),
                DataCell(Text(formatAdminDateTime(item.requestDate))),
                DataCell(Text(
                  item.bankName.isNotEmpty
                      ? '${item.bankName} • ${item.accountNumber}'
                      : 'Not available',
                )),
                DataCell(Text(item.payoutReference.isNotEmpty
                    ? item.payoutReference
                    : 'Awaiting reference')),
              ],
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildPricingSection(AdminPanelSnapshot snapshot) {
    return _PricingEditor(
      pricing: snapshot.pricingConfig,
      settings: snapshot.settings,
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
    if (snapshot.subscriptions.isEmpty) {
      return const AdminEmptyState(
        title: 'No subscription records yet',
        message:
            'Drivers can already choose commission or subscription monetization. As soon as subscription plan data is present in driver business models, it will appear here with status and payment visibility.',
        icon: Icons.workspace_premium_outlined,
      );
    }

    final conversionRate = snapshot.drivers.isEmpty
        ? 0.0
        : snapshot.subscriptions.length / snapshot.drivers.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        AdminSummaryBanner(
          title: 'Subscriptions management',
          subtitle:
              'Monitor weekly and monthly plan adoption, payment state, expiry windows, and manual plan status adjustments.',
          kpis: <String, String>{
            'Subscribed drivers': '${snapshot.subscriptions.length}',
            'Conversion rate': '${(conversionRate * 100).toStringAsFixed(1)}%',
            'Weekly plans':
                '${snapshot.subscriptions.where((AdminSubscriptionRecord record) => record.planType == 'weekly').length}',
            'Monthly plans':
                '${snapshot.subscriptions.where((AdminSubscriptionRecord record) => record.planType != 'weekly').length}',
          },
        ),
        const SizedBox(height: 20),
        AdminDataTableCard(
          columns: const <DataColumn>[
            DataColumn(label: Text('Driver')),
            DataColumn(label: Text('City')),
            DataColumn(label: Text('Plan')),
            DataColumn(label: Text('Status')),
            DataColumn(label: Text('Payment')),
            DataColumn(label: Text('Start')),
            DataColumn(label: Text('End')),
          ],
          rows: snapshot.subscriptions.map((AdminSubscriptionRecord record) {
            return DataRow(
              onSelectChanged: (_) => _showSubscriptionDialog(record),
              cells: <DataCell>[
                DataCell(Text(record.driverName)),
                DataCell(
                    Text(record.city.isNotEmpty ? record.city : 'Not set')),
                DataCell(AdminStatusChip(record.planType)),
                DataCell(AdminStatusChip(record.status)),
                DataCell(AdminStatusChip(record.paymentStatus)),
                DataCell(Text(formatAdminDate(record.startDate))),
                DataCell(Text(formatAdminDate(record.endDate))),
              ],
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildVerificationSection(AdminPanelSnapshot snapshot) {
    if (snapshot.verificationCases.isEmpty) {
      return const AdminEmptyState(
        title: 'No verification cases yet',
        message:
            'Verification and compliance review is fully scaffolded around live driver verification, driver documents, and verification audits. Cases will show up here once drivers submit documents.',
        icon: Icons.verified_user_outlined,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const AdminSectionHeader(
          title: 'Verification and compliance',
          description:
              'Review pending driver verification cases, inspect uploaded documents, and approve, reject, or request resubmission with audit trail updates.',
        ),
        const SizedBox(height: 16),
        AdminDataTableCard(
          columns: const <DataColumn>[
            DataColumn(label: Text('Driver')),
            DataColumn(label: Text('Model')),
            DataColumn(label: Text('Status')),
            DataColumn(label: Text('Submitted')),
            DataColumn(label: Text('Reviewed by')),
            DataColumn(label: Text('Documents')),
          ],
          rows: snapshot.verificationCases.map((AdminVerificationCase item) {
            return DataRow(
              onSelectChanged: (_) => _showVerificationDialog(item),
              cells: <DataCell>[
                DataCell(Text(item.driverName)),
                DataCell(AdminStatusChip(item.businessModel)),
                DataCell(AdminStatusChip(item.overallStatus)),
                DataCell(Text(formatAdminDateTime(item.submittedAt))),
                DataCell(Text(
                    item.reviewedBy.isNotEmpty ? item.reviewedBy : 'Pending')),
                DataCell(Text('${item.documents.length}')),
              ],
            );
          }).toList(),
        ),
      ],
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
                  snapshot.settings.activeServiceTypes.join(', '),
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

  List<Widget> _driverAccountActionButtons(AdminDriverRecord driver) {
    Future<void> applyStatus(String status) async {
      Navigator.of(context).pop();
      await _dataService.updateDriverStatus(
        driver: driver,
        status: status,
      );
      await _loadSnapshot();
    }

    switch (driver.accountStatus) {
      case 'deactivated':
        return <Widget>[
          AdminPrimaryButton(
            label: 'Activate',
            onPressed: () async {
              await applyStatus('active');
            },
          ),
        ];
      case 'suspended':
        return <Widget>[
          AdminPrimaryButton(
            label: 'Activate',
            onPressed: () async {
              await applyStatus('active');
            },
          ),
          AdminGhostButton(
            label: 'Deactivate',
            onPressed: () async {
              await applyStatus('deactivated');
            },
          ),
        ];
      default:
        return <Widget>[
          const AdminPrimaryButton(
            label: 'Active',
            onPressed: null,
          ),
          AdminGhostButton(
            label: 'Deactivate',
            onPressed: () async {
              await applyStatus('deactivated');
            },
          ),
          AdminGhostButton(
            label: 'Suspend',
            onPressed: () async {
              await applyStatus('suspended');
            },
          ),
        ];
    }
  }

  Future<void> _showRiderDialog(AdminRiderRecord rider) async {
    await _showDetailsDialog(
      title: rider.name,
      subtitle: rider.phone.isNotEmpty ? rider.phone : rider.id,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AdminKeyValueWrap(
            items: <String, String>{
              'City': rider.city.isNotEmpty ? rider.city : 'Not set',
              'Status': sentenceCaseStatus(rider.status),
              'Verification': sentenceCaseStatus(rider.verificationStatus),
              'Risk': sentenceCaseStatus(rider.riskStatus),
              'Payment': sentenceCaseStatus(rider.paymentStatus),
              'Trip history':
                  '${rider.tripSummary.completedTrips} completed / ${rider.tripSummary.totalTrips} total',
              'Wallet / payment info': formatAdminCurrency(rider.walletBalance),
              'Outstanding fees': formatAdminCurrency(rider.outstandingFeesNgn),
            },
          ),
          const SizedBox(height: 18),
          Row(
            children: <Widget>[
              AdminPrimaryButton(
                label: rider.status == 'suspended'
                    ? 'Reactivate rider'
                    : 'Suspend rider',
                onPressed: () async {
                  Navigator.of(context).pop();
                  await _dataService.updateRiderStatus(
                    riderId: rider.id,
                    status:
                        rider.status == 'suspended' ? 'active' : 'suspended',
                  );
                  await _loadSnapshot();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _showDriverDialog(AdminDriverRecord driver) async {
    await _showDetailsDialog(
      title: driver.name,
      subtitle: driver.phone.isNotEmpty ? driver.phone : driver.id,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AdminStatusChip(driver.accountStatus),
          const SizedBox(height: 16),
          AdminKeyValueWrap(
            items: <String, String>{
              'City': driver.city.isNotEmpty ? driver.city : 'Not set',
              'Account status': sentenceCaseStatus(driver.accountStatus),
              'Online state': driver.isOnline ? 'Online' : 'Offline',
              'Driver state': sentenceCaseStatus(driver.status),
              'Verification': sentenceCaseStatus(driver.verificationStatus),
              'Vehicle': driver.vehicleName.isNotEmpty
                  ? '${driver.vehicleName} • ${driver.plateNumber}'
                  : 'Vehicle not added',
              'Trip count':
                  '${driver.completedTripCount} completed / ${driver.tripCount} total',
              'Earnings': formatAdminCurrency(driver.netEarnings),
              'Wallet balance': formatAdminCurrency(driver.walletBalance),
              'Total withdrawn': formatAdminCurrency(driver.totalWithdrawn),
              'Pending withdrawals':
                  formatAdminCurrency(driver.pendingWithdrawals),
              'Monetization': driverMonetizationStatusLabel(
                monetizationModel: driver.monetizationModel,
                subscriptionPlanType: driver.subscriptionPlanType,
                subscriptionActive: driver.subscriptionActive,
              ),
              'Subscription plan':
                  '${sentenceCaseStatus(driver.subscriptionPlanType)} • ${sentenceCaseStatus(driver.subscriptionStatus)}',
            },
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: _driverAccountActionButtons(driver),
          ),
        ],
      ),
    );
  }

  Future<void> _showTripDialog(AdminTripRecord trip) async {
    final routeLog = trip.routeLog;
    final checkpoints = _map(routeLog['checkpoints']).length;
    final settlement = _map(routeLog['settlement']);
    final isCancelled = trip.status == 'cancelled';
    final hasValidSettlement = trip.status == 'completed' &&
        (trip.settlementStatus == 'completed' ||
            trip.settlementStatus == 'payment_review');
    final detailItems = <String, String>{
      'Status': sentenceCaseStatus(trip.status),
      'Service type': sentenceCaseStatus(trip.serviceType),
      'City': trip.city.isNotEmpty ? trip.city : 'Not set',
      'Pickup':
          trip.pickupAddress.isNotEmpty ? trip.pickupAddress : 'Not available',
      'Destination': trip.destinationAddress.isNotEmpty
          ? trip.destinationAddress
          : 'Not available',
      'Payment method': trip.paymentMethod,
      'Requested at': formatAdminDateTime(trip.createdAt),
      if (trip.acceptedAt != null)
        'Accepted at': formatAdminDateTime(trip.acceptedAt),
      if (isCancelled) 'Cancelled at': formatAdminDateTime(trip.cancelledAt),
      if (isCancelled)
        'Cancellation reason':
            _tripCancellationReasonLabel(trip.cancellationReason),
      if (!isCancelled && trip.arrivedAt != null)
        'Arrived at': formatAdminDateTime(trip.arrivedAt),
      if (!isCancelled && trip.startedAt != null)
        'Started at': formatAdminDateTime(trip.startedAt),
      if (!isCancelled && trip.completedAt != null)
        'Completed at': formatAdminDateTime(trip.completedAt),
      'Settlement result': trip.settlementStatus.isNotEmpty
          ? sentenceCaseStatus(trip.settlementStatus)
          : 'No settlement status',
      if (hasValidSettlement)
        'Fare breakdown':
            'Gross ${formatAdminCurrency(trip.fareAmount)} • Commission ${formatAdminCurrency(trip.commissionAmount)} • Driver ${formatAdminCurrency(trip.driverPayout)}',
      if (!isCancelled)
        'Route data': checkpoints > 0
            ? '$checkpoints checkpoint logs available'
            : 'No checkpoint logs yet',
      if (!isCancelled)
        'Route settlement': settlement.isNotEmpty
            ? sentenceCaseStatus(_text(settlement['settlementStatus']))
            : 'No route settlement log',
    };
    await _showDetailsDialog(
      title: 'Trip ${trip.id}',
      subtitle: '${trip.riderName} • ${trip.driverName}',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AdminKeyValueWrap(
            items: detailItems,
          ),
        ],
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
                        '${withdrawal.driverName} • ${formatAdminCurrency(withdrawal.amount)}',
                        style: const TextStyle(color: Color(0xFF6B655B)),
                      ),
                      const SizedBox(height: 18),
                      AdminKeyValueWrap(
                        items: <String, String>{
                          'Current status':
                              sentenceCaseStatus(withdrawal.status),
                          'Requested':
                              formatAdminDateTime(withdrawal.requestDate),
                          'Processed':
                              formatAdminDateTime(withdrawal.processedDate),
                          'Bank': withdrawal.bankName.isNotEmpty
                              ? withdrawal.bankName
                              : 'Not available',
                          'Account name': withdrawal.accountName.isNotEmpty
                              ? withdrawal.accountName
                              : 'Not available',
                          'Account number': withdrawal.accountNumber.isNotEmpty
                              ? withdrawal.accountNumber
                              : 'Not available',
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
                            child: AdminPrimaryButton(
                              label: 'Save payout update',
                              onPressed: () async {
                                Navigator.of(dialogContext).pop();
                                await _dataService.updateWithdrawal(
                                  withdrawal: withdrawal,
                                  status: selectedStatus,
                                  payoutReference: referenceController.text,
                                  note: noteController.text,
                                );
                                await _loadSnapshot();
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

  Future<void> _showSubscriptionDialog(AdminSubscriptionRecord record) async {
    await _showDetailsDialog(
      title: '${record.driverName} subscription',
      subtitle: '${sentenceCaseStatus(record.planType)} plan',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AdminKeyValueWrap(
            items: <String, String>{
              'City': record.city.isNotEmpty ? record.city : 'Not set',
              'Plan type': sentenceCaseStatus(record.planType),
              'Status': sentenceCaseStatus(record.status),
              'Payment status': sentenceCaseStatus(record.paymentStatus),
              'Start date': formatAdminDate(record.startDate),
              'End date': formatAdminDate(record.endDate),
            },
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              AdminPrimaryButton(
                label: 'Mark active',
                onPressed: () async {
                  Navigator.of(context).pop();
                  await _dataService.updateSubscriptionStatus(
                    subscription: record,
                    status: 'active',
                  );
                  await _loadSnapshot();
                },
              ),
              AdminGhostButton(
                label: 'Mark expired',
                onPressed: () async {
                  Navigator.of(context).pop();
                  await _dataService.updateSubscriptionStatus(
                    subscription: record,
                    status: 'expired',
                  );
                  await _loadSnapshot();
                },
              ),
              AdminGhostButton(
                label: 'Cancel plan',
                onPressed: () async {
                  Navigator.of(context).pop();
                  await _dataService.updateSubscriptionStatus(
                    subscription: record,
                    status: 'cancelled',
                  );
                  await _loadSnapshot();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _showVerificationDialog(AdminVerificationCase item) async {
    final noteController = TextEditingController();
    await showDialog<void>(
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
                      item.driverName,
                      style: const TextStyle(
                        color: AdminThemeTokens.ink,
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${item.phone} • ${item.email}',
                      style: const TextStyle(color: Color(0xFF6A6359)),
                    ),
                    const SizedBox(height: 18),
                    AdminKeyValueWrap(
                      items: <String, String>{
                        'Business model':
                            sentenceCaseStatus(item.businessModel),
                        'Overall status':
                            sentenceCaseStatus(item.overallStatus),
                        'Workflow status': sentenceCaseStatus(item.status),
                        'Submitted at': formatAdminDateTime(item.submittedAt),
                        'Reviewed at': formatAdminDateTime(item.reviewedAt),
                        'Reviewed by': item.reviewedBy.isNotEmpty
                            ? item.reviewedBy
                            : 'Pending',
                        'Failure reason': item.failureReason.isNotEmpty
                            ? item.failureReason
                            : 'None',
                      },
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'Documents',
                      style: TextStyle(
                        color: AdminThemeTokens.ink,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ...item.documents.entries
                        .map((MapEntry<String, dynamic> entry) {
                      final document = _map(entry.value);
                      final fileUrl = _text(document['fileUrl']);
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8F5EF),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Row(
                                children: <Widget>[
                                  Expanded(
                                    child: Text(
                                      _text(document['label']).isNotEmpty
                                          ? _text(document['label'])
                                          : entry.key,
                                      style: const TextStyle(
                                        color: AdminThemeTokens.ink,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                  AdminStatusChip(_text(document['status'])),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _text(document['documentNumber']).isNotEmpty
                                    ? _text(document['documentNumber'])
                                    : 'No document number stored',
                                style:
                                    const TextStyle(color: Color(0xFF6F685E)),
                              ),
                              if (fileUrl.isNotEmpty) ...<Widget>[
                                const SizedBox(height: 10),
                                AdminGhostButton(
                                  label: 'Open uploaded file',
                                  onPressed: () async {
                                    final uri = Uri.tryParse(fileUrl);
                                    if (uri != null) {
                                      await launchUrl(uri);
                                    }
                                  },
                                  icon: Icons.open_in_new_rounded,
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    }),
                    TextField(
                      controller: noteController,
                      minLines: 2,
                      maxLines: 4,
                      decoration: _dialogInputDecoration(
                          'Review note or resubmission reason'),
                    ),
                    const SizedBox(height: 18),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: <Widget>[
                        AdminPrimaryButton(
                          label: 'Approve',
                          onPressed: () async {
                            Navigator.of(dialogContext).pop();
                            await _dataService.reviewVerificationCase(
                              verificationCase: item,
                              action: 'approve',
                              reviewedBy: widget.session.email,
                              note: noteController.text,
                            );
                            await _loadSnapshot();
                          },
                        ),
                        AdminGhostButton(
                          label: 'Reject',
                          onPressed: () async {
                            Navigator.of(dialogContext).pop();
                            await _dataService.reviewVerificationCase(
                              verificationCase: item,
                              action: 'reject',
                              reviewedBy: widget.session.email,
                              note: noteController.text,
                            );
                            await _loadSnapshot();
                          },
                        ),
                        AdminGhostButton(
                          label: 'Request resubmission',
                          onPressed: () async {
                            Navigator.of(dialogContext).pop();
                            await _dataService.reviewVerificationCase(
                              verificationCase: item,
                              action: 'resubmit',
                              reviewedBy: widget.session.email,
                              note: noteController.text,
                            );
                            await _loadSnapshot();
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
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

  Map<String, dynamic> _map(dynamic value) {
    if (value is Map) {
      return value.map<String, dynamic>(
        (dynamic key, dynamic entryValue) =>
            MapEntry(key.toString(), entryValue),
      );
    }
    return <String, dynamic>{};
  }

  String _tripCancellationReasonLabel(String reason) {
    return switch (reason.trim().toLowerCase()) {
      'timeout' => 'Timeout',
      'driver_offline' => 'Driver offline',
      'user_cancelled' => 'User cancelled',
      'driver_cancelled' => 'Driver cancelled',
      'no_route_logs' => 'No route logs',
      'no_drivers_available' => 'No drivers available',
      '' => 'Not available',
      _ => sentenceCaseStatus(reason),
    };
  }

  String _text(dynamic value) => value?.toString().trim() ?? '';
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

class _PricingEditor extends StatefulWidget {
  const _PricingEditor({
    required this.pricing,
    required this.settings,
    required this.onSave,
  });

  final AdminPricingConfig pricing;
  final AdminOperationalSettings settings;
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
              'Display or safely edit official fare formulas for Lagos and Abuja, together with NexRide monetization rules.',
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
                        onChanged: (bool value) {
                          setState(() {
                            controllers.enabled = value;
                          });
                        },
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
        AdminPrimaryButton(
          label: _saving ? 'Saving...' : 'Save pricing config',
          onPressed: _saving ? null : _save,
          icon: Icons.save_outlined,
        ),
      ],
    );
  }

  Widget _editorField(TextEditingController controller, String label) {
    return TextField(
      controller: controller,
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
