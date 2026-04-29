import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../admin_config.dart';
import '../models/admin_models.dart';
import '../utils/admin_formatters.dart';

class AdminSurfaceCard extends StatelessWidget {
  const AdminSurfaceCard({
    required this.child,
    super.key,
    this.padding = const EdgeInsets.all(20),
    this.height,
  });

  final Widget child;
  final EdgeInsets padding;
  final double? height;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AdminThemeTokens.border),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x11000000),
            blurRadius: 28,
            offset: Offset(0, 16),
          ),
        ],
      ),
      padding: padding,
      child: child,
    );
  }
}

class AdminStatCard extends StatelessWidget {
  const AdminStatCard({
    required this.metric,
    required this.icon,
    super.key,
  });

  final AdminMetricCardData metric;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return AdminSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: AdminThemeTokens.goldSoft,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, color: AdminThemeTokens.gold),
          ),
          const SizedBox(height: 18),
          Text(
            metric.label,
            style: const TextStyle(
              color: Color(0xFF68635A),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            metric.value,
            style: const TextStyle(
              color: AdminThemeTokens.ink,
              fontSize: 28,
              fontWeight: FontWeight.w800,
              height: 0.95,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            metric.caption,
            style: const TextStyle(
              color: Color(0xFF8D8578),
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class AdminSectionHeader extends StatelessWidget {
  const AdminSectionHeader({
    required this.title,
    required this.description,
    super.key,
    this.trailing,
  });

  final String title;
  final String description;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
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
              const SizedBox(height: 6),
              Text(
                description,
                style: const TextStyle(
                  color: Color(0xFF6D685F),
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
        if (trailing != null) ...<Widget>[
          const SizedBox(width: 16),
          trailing!,
        ],
      ],
    );
  }
}

class AdminStatusChip extends StatelessWidget {
  const AdminStatusChip(
    this.label, {
    super.key,
    this.color,
  });

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? adminStatusColor(label);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: effectiveColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        sentenceCaseStatus(label),
        style: TextStyle(
          color: effectiveColor,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class AdminPrimaryButton extends StatelessWidget {
  const AdminPrimaryButton({
    required this.label,
    required this.onPressed,
    super.key,
    this.icon,
    this.compact = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: icon == null ? const SizedBox.shrink() : Icon(icon, size: 18),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        backgroundColor: AdminThemeTokens.gold,
        foregroundColor: Colors.black,
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 14 : 18,
          vertical: compact ? 12 : 14,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        textStyle: const TextStyle(fontWeight: FontWeight.w800),
      ),
    );
  }
}

class AdminGhostButton extends StatelessWidget {
  const AdminGhostButton({
    required this.label,
    required this.onPressed,
    super.key,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: icon == null ? const SizedBox.shrink() : Icon(icon, size: 18),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: AdminThemeTokens.ink,
        side: const BorderSide(color: AdminThemeTokens.border),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    );
  }
}

class AdminTextFilterField extends StatelessWidget {
  const AdminTextFilterField({
    required this.controller,
    required this.hintText,
    super.key,
    this.onChanged,
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      decoration: InputDecoration(
        hintText: hintText,
        prefixIcon: const Icon(Icons.search_rounded),
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
    );
  }
}

class AdminFilterDropdown<T> extends StatelessWidget {
  const AdminFilterDropdown({
    required this.value,
    required this.items,
    required this.onChanged,
    super.key,
  });

  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<T>(
      initialValue: value,
      isExpanded: true,
      items: items,
      onChanged: onChanged,
      decoration: InputDecoration(
        filled: true,
        fillColor: Colors.white,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
    );
  }
}

class AdminKeyValueWrap extends StatelessWidget {
  const AdminKeyValueWrap({
    required this.items,
    super.key,
  });

  final Map<String, String> items;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 14,
      runSpacing: 14,
      children: items.entries.map((MapEntry<String, String> entry) {
        return Container(
          constraints: const BoxConstraints(minWidth: 180, maxWidth: 280),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFF8F5EF),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                entry.key,
                style: const TextStyle(
                  color: Color(0xFF7A7367),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                entry.value,
                style: const TextStyle(
                  color: AdminThemeTokens.ink,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

class AdminEmptyState extends StatelessWidget {
  const AdminEmptyState({
    required this.title,
    required this.message,
    super.key,
    this.icon = Icons.inbox_outlined,
  });

  final String title;
  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
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
              child: Icon(icon, color: AdminThemeTokens.gold),
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
              constraints: const BoxConstraints(maxWidth: 420),
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
          ],
        ),
      ),
    );
  }
}

class AdminFullscreenState extends StatelessWidget {
  const AdminFullscreenState({
    required this.title,
    required this.message,
    super.key,
    this.error,
    this.stackTrace,
    this.icon = Icons.warning_amber_rounded,
    this.isLoading = false,
  });

  final String title;
  final String message;
  final Object? error;
  final StackTrace? stackTrace;
  final IconData icon;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final details = error?.toString().trim();
    final trace = stackTrace?.toString().trim();

    return Scaffold(
      backgroundColor: AdminThemeTokens.canvas,
      body: Container(
        decoration: const BoxDecoration(
          gradient: AdminThemeTokens.heroGradient,
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: AdminSurfaceCard(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: AdminThemeTokens.goldSoft,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: isLoading
                            ? const Padding(
                                padding: EdgeInsets.all(16),
                                child: CircularProgressIndicator(
                                  strokeWidth: 3,
                                  color: AdminThemeTokens.gold,
                                ),
                              )
                            : Icon(
                                icon,
                                color: AdminThemeTokens.gold,
                                size: 32,
                              ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        title,
                        style: const TextStyle(
                          color: AdminThemeTokens.ink,
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        message,
                        style: const TextStyle(
                          color: Color(0xFF6F675D),
                          fontSize: 14,
                          height: 1.55,
                        ),
                      ),
                      if (details != null && details.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 18),
                        _errorPanel(
                          label: 'Exception',
                          content: details,
                        ),
                      ],
                      if (kDebugMode &&
                          trace != null &&
                          trace.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 14),
                        _errorPanel(
                          label: 'Stack trace',
                          content: trace,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _errorPanel({
    required String label,
    required String content,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F5EF),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AdminThemeTokens.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF6F675D),
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          SelectableText(
            content,
            style: const TextStyle(
              color: AdminThemeTokens.ink,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class AdminDataTableCard extends StatelessWidget {
  const AdminDataTableCard({
    required this.columns,
    required this.rows,
    super.key,
    this.heading,
  });

  final List<DataColumn> columns;
  final List<DataRow> rows;
  final Widget? heading;

  @override
  Widget build(BuildContext context) {
    return AdminSurfaceCard(
      padding: const EdgeInsets.all(0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (heading != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: heading!,
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 24,
              headingTextStyle: const TextStyle(
                color: Color(0xFF726B60),
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
              dataTextStyle: const TextStyle(
                color: AdminThemeTokens.ink,
                fontSize: 13,
              ),
              columns: columns,
              rows: rows,
            ),
          ),
        ],
      ),
    );
  }
}

class AdminSummaryBanner extends StatelessWidget {
  const AdminSummaryBanner({
    required this.title,
    required this.subtitle,
    required this.kpis,
    super.key,
  });

  final String title;
  final String subtitle;
  final Map<String, String> kpis;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: AdminThemeTokens.heroGradient,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w800,
              height: 1.05,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            subtitle,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.78),
              fontSize: 14,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: kpis.entries.map((MapEntry<String, String> entry) {
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.10),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      entry.key,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.68),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      entry.value,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class AdminInsightList extends StatelessWidget {
  const AdminInsightList({
    required this.title,
    required this.items,
    super.key,
  });

  final String title;
  final List<AdminTrendPoint> items;

  @override
  Widget build(BuildContext context) {
    return AdminSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: const TextStyle(
              color: AdminThemeTokens.ink,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 18),
          ...items.map((AdminTrendPoint item) {
            final maxValue = items.fold<double>(
              1,
              (double max, AdminTrendPoint point) =>
                  point.value > max ? point.value : max,
            );
            final widthFactor = maxValue <= 0 ? 0.0 : item.value / maxValue;
            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          item.label,
                          style: const TextStyle(
                            color: AdminThemeTokens.ink,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Text(
                        item.value >= 1000
                            ? formatAdminCurrency(item.value)
                            : formatAdminCompactNumber(item.value),
                        style: const TextStyle(
                          color: Color(0xFF6D665C),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: widthFactor,
                      minHeight: 10,
                      backgroundColor: const Color(0xFFF1E9DB),
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        AdminThemeTokens.gold,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}
