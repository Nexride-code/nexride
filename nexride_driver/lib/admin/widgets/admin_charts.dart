import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../admin_config.dart';
import '../models/admin_models.dart';
import '../utils/admin_formatters.dart';
import 'admin_components.dart';

class AdminMultiSeriesLineChartCard extends StatelessWidget {
  const AdminMultiSeriesLineChartCard({
    required this.title,
    required this.subtitle,
    required this.points,
    super.key,
    this.primaryLabel = 'Primary',
    this.secondaryLabel = 'Secondary',
    this.tertiaryLabel = 'Tertiary',
    this.valuePrefix = '',
  });

  final String title;
  final String subtitle;
  final List<AdminTrendPoint> points;
  final String primaryLabel;
  final String secondaryLabel;
  final String tertiaryLabel;
  final String valuePrefix;

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
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: const TextStyle(
              color: Color(0xFF756E64),
              fontSize: 13,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 220,
            child: CustomPaint(
              painter: _AdminLineChartPainter(points: points),
              child: const SizedBox.expand(),
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 16,
            runSpacing: 10,
            children: <Widget>[
              _LegendDot(color: AdminThemeTokens.gold, label: primaryLabel),
              _LegendDot(color: AdminThemeTokens.info, label: secondaryLabel),
              _LegendDot(color: AdminThemeTokens.danger, label: tertiaryLabel),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 18,
            runSpacing: 10,
            children: points.map((AdminTrendPoint point) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    point.label,
                    style: const TextStyle(
                      color: Color(0xFF7A7267),
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$valuePrefix${formatAdminCompactNumber(point.value)}',
                    style: const TextStyle(
                      color: AdminThemeTokens.ink,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class AdminFinanceBarsCard extends StatelessWidget {
  const AdminFinanceBarsCard({
    required this.title,
    required this.items,
    super.key,
  });

  final String title;
  final List<AdminRevenueSlice> items;

  @override
  Widget build(BuildContext context) {
    final maxValue = items.fold<double>(
      1,
      (double max, AdminRevenueSlice item) {
        final localMax = math.max(
          math.max(item.grossBookings, item.driverPayouts),
          item.commissionRevenue + item.subscriptionRevenue,
        );
        return localMax > max ? localMax : max;
      },
    );

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
          ...items.map((AdminRevenueSlice item) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 18),
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
                        formatAdminCurrency(item.grossBookings),
                        style: const TextStyle(
                          color: Color(0xFF736C62),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _FinanceBarRow(
                    value: item.grossBookings,
                    maxValue: maxValue,
                    color: AdminThemeTokens.gold,
                    label: 'Gross',
                  ),
                  const SizedBox(height: 6),
                  _FinanceBarRow(
                    value: item.commissionRevenue + item.subscriptionRevenue,
                    maxValue: maxValue,
                    color: AdminThemeTokens.info,
                    label: 'Platform',
                  ),
                  const SizedBox(height: 6),
                  _FinanceBarRow(
                    value: item.driverPayouts,
                    maxValue: maxValue,
                    color: AdminThemeTokens.success,
                    label: 'Driver',
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

class _LegendDot extends StatelessWidget {
  const _LegendDot({
    required this.color,
    required this.label,
  });

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(999),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF736D63),
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _FinanceBarRow extends StatelessWidget {
  const _FinanceBarRow({
    required this.value,
    required this.maxValue,
    required this.color,
    required this.label,
  });

  final double value;
  final double maxValue;
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        SizedBox(
          width: 62,
          child: Text(
            label,
            style: const TextStyle(
              color: Color(0xFF7A7368),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: maxValue <= 0 ? 0 : value / maxValue,
              minHeight: 10,
              backgroundColor: const Color(0xFFF2ECE1),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          formatAdminCompactNumber(value),
          style: const TextStyle(
            color: AdminThemeTokens.ink,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _AdminLineChartPainter extends CustomPainter {
  _AdminLineChartPainter({
    required this.points,
  });

  final List<AdminTrendPoint> points;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) {
      return;
    }

    const double horizontalPadding = 18;
    const double verticalPadding = 16;
    final chartRect = Rect.fromLTWH(
      horizontalPadding,
      verticalPadding,
      size.width - (horizontalPadding * 2),
      size.height - (verticalPadding * 2),
    );

    final maxValue = points.fold<double>(
      1,
      (double max, AdminTrendPoint point) => math.max(
        max,
        math.max(
            point.value, math.max(point.secondaryValue, point.tertiaryValue)),
      ),
    );

    final gridPaint = Paint()
      ..color = const Color(0xFFEDE6D7)
      ..strokeWidth = 1;
    for (var i = 0; i < 4; i++) {
      final y = chartRect.top + ((chartRect.height / 3) * i);
      canvas.drawLine(
          Offset(chartRect.left, y), Offset(chartRect.right, y), gridPaint);
    }

    final primary = _buildPath(
        points.map((AdminTrendPoint point) => point.value).toList(),
        chartRect,
        maxValue);
    final secondary = _buildPath(
        points.map((AdminTrendPoint point) => point.secondaryValue).toList(),
        chartRect,
        maxValue);
    final tertiary = _buildPath(
        points.map((AdminTrendPoint point) => point.tertiaryValue).toList(),
        chartRect,
        maxValue);

    _drawPath(canvas, primary, AdminThemeTokens.gold, true);
    _drawPath(canvas, secondary, AdminThemeTokens.info, false);
    _drawPath(canvas, tertiary, AdminThemeTokens.danger, false);
  }

  Path _buildPath(List<double> values, Rect rect, double maxValue) {
    final path = Path();
    final step = values.length == 1 ? 0.0 : rect.width / (values.length - 1);

    for (var index = 0; index < values.length; index++) {
      final x = rect.left + (step * index);
      final value = values[index];
      final y = rect.bottom - ((value / maxValue) * rect.height);
      if (index == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    return path;
  }

  void _drawPath(Canvas canvas, Path path, Color color, bool fill) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = fill ? 4 : 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, stroke);

    if (fill) {
      final metrics = path.computeMetrics().toList();
      if (metrics.isNotEmpty) {
        final metric = metrics.first;
        final bounds = path.getBounds();
        final fillPath = Path.from(path)
          ..lineTo(bounds.right, bounds.bottom)
          ..lineTo(bounds.left, bounds.bottom)
          ..close();
        canvas.drawPath(
          fillPath,
          Paint()
            ..shader = LinearGradient(
              colors: <Color>[
                color.withValues(alpha: 0.28),
                color.withValues(alpha: 0.02),
              ],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ).createShader(bounds)
            ..style = PaintingStyle.fill,
        );
        final start = metric.getTangentForOffset(0)?.position;
        final end = metric.getTangentForOffset(metric.length)?.position;
        if (start != null) {
          canvas.drawCircle(start, 4.5, Paint()..color = color);
        }
        if (end != null) {
          canvas.drawCircle(end, 4.5, Paint()..color = color);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _AdminLineChartPainter oldDelegate) {
    return oldDelegate.points != points;
  }
}
