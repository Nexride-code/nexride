import 'package:flutter/material.dart';

import '../admin_config.dart';
import '../admin_rbac.dart';
import '../models/admin_models.dart';
import '../utils/admin_formatters.dart';
import 'admin_components.dart';

class AdminPendingNotification {
  const AdminPendingNotification({
    required this.title,
    required this.subtitle,
    required this.section,
    this.updatedAt,
  });

  final String title;
  final String subtitle;
  final AdminSection section;
  final int? updatedAt;
}

class AdminShell extends StatelessWidget {
  const AdminShell({
    required this.section,
    required this.onSectionSelected,
    required this.session,
    required this.isLoading,
    required this.lastUpdated,
    required this.onRefresh,
    required this.onLogout,
    required this.liveDataSections,
    required this.sidebarBadgeCounts,
    required this.pendingNotifications,
    required this.onNotificationSelected,
    required this.child,
    super.key,
  });

  final AdminSection section;
  final ValueChanged<AdminSection> onSectionSelected;
  final AdminSession session;
  final bool isLoading;
  final DateTime? lastUpdated;
  final VoidCallback onRefresh;
  final VoidCallback onLogout;
  final Map<String, bool> liveDataSections;
  final Map<AdminSection, int> sidebarBadgeCounts;
  final List<AdminPendingNotification> pendingNotifications;
  final ValueChanged<AdminSection> onNotificationSelected;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final wide = constraints.maxWidth >= 1120;
        final compact = constraints.maxWidth < 940;
        final content = _AdminScaffoldContent(
          section: section,
          session: session,
          isLoading: isLoading,
          lastUpdated: lastUpdated,
          onRefresh: onRefresh,
          onLogout: onLogout,
          liveDataSections: liveDataSections,
          pendingNotifications: pendingNotifications,
          onNotificationSelected: onNotificationSelected,
          compact: compact,
          showDrawerButton: !wide,
          child: child,
        );

        if (wide) {
          return Scaffold(
            backgroundColor: AdminThemeTokens.canvas,
            body: SafeArea(
              child: Row(
                children: <Widget>[
                  _AdminSidebar(
                    selected: section,
                    onSelected: onSectionSelected,
                    badgeCounts: sidebarBadgeCounts,
                    session: session,
                  ),
                  Expanded(child: content),
                ],
              ),
            ),
          );
        }

        return Scaffold(
          backgroundColor: AdminThemeTokens.canvas,
          drawer: Drawer(
            width: 280,
            child: SafeArea(
              child: _AdminSidebar(
                selected: section,
                onSelected: (AdminSection next) {
                  Navigator.of(context).pop();
                  onSectionSelected(next);
                },
                badgeCounts: sidebarBadgeCounts,
                session: session,
              ),
            ),
          ),
          body: SafeArea(child: content),
        );
      },
    );
  }
}

class _AdminScaffoldContent extends StatelessWidget {
  const _AdminScaffoldContent({
    required this.section,
    required this.session,
    required this.isLoading,
    required this.lastUpdated,
    required this.onRefresh,
    required this.onLogout,
    required this.liveDataSections,
    required this.pendingNotifications,
    required this.onNotificationSelected,
    required this.compact,
    required this.child,
    required this.showDrawerButton,
  });

  final AdminSection section;
  final AdminSession session;
  final bool isLoading;
  final DateTime? lastUpdated;
  final VoidCallback onRefresh;
  final VoidCallback onLogout;
  final Map<String, bool> liveDataSections;
  final List<AdminPendingNotification> pendingNotifications;
  final ValueChanged<AdminSection> onNotificationSelected;
  final bool compact;
  final Widget child;
  final bool showDrawerButton;

  @override
  Widget build(BuildContext context) {
    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text(
          'NexRide Admin',
          style: TextStyle(
            color: AdminThemeTokens.gold,
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          section.label,
          style: const TextStyle(
            color: AdminThemeTokens.ink,
            fontSize: 22,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Single control center for NexRide operations, control, monitoring, and business management.',
          style: TextStyle(
            color: Color(0xFF6D675D),
            fontSize: 13,
            height: 1.4,
          ),
        ),
      ],
    );

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: AdminThemeTokens.border),
            ),
            child: compact
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          if (showDrawerButton) _buildDrawerButton(),
                          Expanded(child: titleBlock),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _buildHeaderActions(),
                    ],
                  )
                : Row(
                    children: <Widget>[
                      if (showDrawerButton) _buildDrawerButton(),
                      Expanded(child: titleBlock),
                      const SizedBox(width: 16),
                      Flexible(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: _buildHeaderActions(),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: AdminSurfaceCard(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: Colors.green.shade600,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'Live backend sources connected',
                        style: TextStyle(
                          color: AdminThemeTokens.ink,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  ...liveDataSections.entries
                      .expand((MapEntry<String, bool> entry) {
                    return <Widget>[
                      AdminStatusChip(
                        entry.value ? entry.key : '${entry.key} pending',
                        color: entry.value
                            ? AdminThemeTokens.success
                            : AdminThemeTokens.warning,
                      ),
                      const SizedBox(width: 12),
                    ];
                  }),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF6F1E5),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Text(
                      '${session.displayName} • ${formatAdminRoleLabel(session.adminRole)} • ${sentenceCaseStatus(session.accessMode)}',
                      style: const TextStyle(
                        color: Color(0xFF6E675C),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: child,
          ),
        ),
      ],
    );
  }

  Widget _buildDrawerButton() {
    return Builder(
      builder: (BuildContext innerContext) {
        return IconButton(
          onPressed: () => Scaffold.of(innerContext).openDrawer(),
          icon: const Icon(Icons.menu_rounded),
        );
      },
    );
  }

  Widget _buildHeaderActions() {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      alignment: compact ? WrapAlignment.start : WrapAlignment.end,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFFF6F1E5),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Text(
            lastUpdated == null
                ? 'Syncing data'
                : 'Updated ${formatAdminDateTime(lastUpdated)}',
            style: const TextStyle(
              color: Color(0xFF6B6356),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        AdminPrimaryButton(
          label: isLoading ? 'Refreshing...' : 'Refresh',
          onPressed: isLoading ? null : onRefresh,
          icon: Icons.refresh_rounded,
          compact: true,
        ),
        AdminGhostButton(
          label: 'Logout',
          onPressed: onLogout,
          icon: Icons.logout_rounded,
        ),
        PopupMenuButton<AdminPendingNotification>(
          tooltip: 'Pending notifications',
          onSelected: (item) => onNotificationSelected(item.section),
          itemBuilder: (context) {
            if (pendingNotifications.isEmpty) {
              return const <PopupMenuEntry<AdminPendingNotification>>[
                PopupMenuItem<AdminPendingNotification>(
                  enabled: false,
                  child: Text('No pending items'),
                ),
              ];
            }
            return pendingNotifications
                .map(
                  (item) => PopupMenuItem<AdminPendingNotification>(
                    value: item,
                    child: Text('${item.title}: ${item.subtitle}'),
                  ),
                )
                .toList(growable: false);
          },
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              const Padding(
                padding: EdgeInsets.all(6),
                child: Icon(Icons.notifications_none_rounded),
              ),
              if (pendingNotifications.isNotEmpty)
                Positioned(
                  right: 0,
                  top: 0,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: const Color(0xFFD64545),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AdminSidebar extends StatelessWidget {
  const _AdminSidebar({
    required this.selected,
    required this.onSelected,
    required this.badgeCounts,
    required this.session,
  });

  final AdminSection selected;
  final ValueChanged<AdminSection> onSelected;
  final Map<AdminSection, int> badgeCounts;
  final AdminSession session;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 300,
      margin: const EdgeInsets.all(18),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: AdminThemeTokens.heroGradient,
        borderRadius: BorderRadius.circular(30),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(22),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: AdminThemeTokens.goldSoft.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: const Icon(
                    Icons.apartment_rounded,
                    color: AdminThemeTokens.gold,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'NexRide Admin',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Operations command center for riders, drivers, trips, finance, and compliance.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.72),
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Expanded(
            child: ListView(
              children: kAdminSidebarNavOrder.map((AdminSection item) {
                final isSelected = item == selected;
                final String? req = requiredPermissionForSection(item);
                final bool allowed = req == null || session.hasPermission(req);
                final Widget row = Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: allowed
                        ? () {
                            if (item == AdminSection.auditLogs) {
                              debugPrint('[AUDIT_LOGS][NAV] drawer item tapped');
                            } else if (item == AdminSection.liveOperations) {
                              debugPrint(
                                '[LIVE_OPS][NAV] drawer item tapped section=${item.name} '
                                'route=${AdminPortalRoutePaths.pathForSection(item)}',
                              );
                            } else {
                              debugPrint(
                                '[AdminNav] drawer item tapped section=${item.name} '
                                'route=${AdminPortalRoutePaths.pathForSection(item)}',
                              );
                            }
                            onSelected(item);
                          }
                        : null,
                    child: Opacity(
                      opacity: allowed ? 1 : 0.45,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 14),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? Colors.white.withValues(alpha: 0.12)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: isSelected
                                ? Colors.white.withValues(alpha: 0.12)
                                : Colors.transparent,
                          ),
                        ),
                        child: Row(
                          children: <Widget>[
                            Icon(
                              item.icon,
                              color: isSelected
                                  ? AdminThemeTokens.gold
                                  : Colors.white.withValues(alpha: 0.82),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                item.label,
                                style: TextStyle(
                                  color: Colors.white.withValues(
                                    alpha: isSelected ? 1 : 0.84,
                                  ),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            if ((badgeCounts[item] ?? 0) > 0)
                              Container(
                                margin: const EdgeInsets.only(right: 8),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFD64545),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  '${badgeCounts[item] ?? 0}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            if (isSelected)
                              const Icon(
                                Icons.chevron_right_rounded,
                                color: AdminThemeTokens.gold,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
                if (allowed) {
                  return row;
                }
                return Tooltip(
                  message: kAdminNoPermissionTooltip,
                  child: row,
                );
              }).toList(),
            ),
          ),
          Text(
            'Premium operations visibility with live backend controls.',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.56),
              fontSize: 12,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}
