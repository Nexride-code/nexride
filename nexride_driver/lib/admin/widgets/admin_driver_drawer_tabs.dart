import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/admin_models.dart';
import '../services/admin_data_service.dart';
import '../utils/admin_formatters.dart';
import 'admin_components.dart';

typedef AdminDriverActionBuilder = List<Widget> Function(AdminDriverRecord driver);

/// Tab bodies for driver [AdminEntityDrawer] (Phase 3L).
class AdminDriverDrawerTabs {
  AdminDriverDrawerTabs._();

  static Future<Widget> loadBody({
    required AdminDriverRecord driver,
    required String tabId,
    required AdminDataService dataService,
    required AdminDriverActionBuilder actionButtonsFor,
  }) async {
    final Map<String, dynamic>? raw = await dataService.fetchDriverEntityTabForAdmin(
      driverId: driver.id,
      tabId: tabId,
    );
    if (raw == null) {
      return const _PaneMessage(
        title: 'Unable to load',
        body: 'Network or auth error. Pull to refresh.',
        dense: true,
      );
    }
    if (raw['success'] == false) {
      final String reason = '${raw['reason'] ?? raw['code'] ?? 'unknown'}';
      return _PaneMessage(
        title: 'Request failed',
        body: reason,
        dense: true,
      );
    }
    if (raw['success'] != true) {
      return const _PaneMessage(
        title: 'Unexpected response',
        body: 'Server returned an unrecognized payload.',
        dense: true,
      );
    }

    switch (tabId) {
      case 'overview':
        return _overview(driver, raw, actionButtonsFor(driver));
      case 'verification':
        return _verification(raw);
      case 'wallet':
        return _wallet(raw);
      case 'trips':
        return _trips(raw);
      case 'subscription':
        return _subscription(driver, raw);
      case 'violations':
        return _violations(raw);
      case 'notes':
        return _notes(raw);
      case 'audit':
        return _audit(raw);
      default:
        return _PaneMessage(title: 'Unknown tab', body: tabId, dense: true);
    }
  }

  static Widget _overview(
    AdminDriverRecord driver,
    Map<String, dynamic> payload,
    List<Widget> actions,
  ) {
    final Map<String, dynamic> d = payload['driver'] is Map
        ? Map<String, dynamic>.from(payload['driver'] as Map)
        : <String, dynamic>{};
    final Map<String, dynamic> dp = payload['dispatch_presence'] is Map
        ? Map<String, dynamic>.from(payload['dispatch_presence'] as Map)
        : <String, dynamic>{};
    final int? docSlots = switch (payload['document_slot_count']) {
      final int x => x,
      final num x => x.toInt(),
      _ => int.tryParse('${payload['document_slot_count']}'),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        AdminStatusChip(driver.accountStatus),
        const SizedBox(height: 16),
        AdminKeyValueWrap(
          items: <String, String>{
            'City': _nz(driver.city, d['city']),
            'State / region': _nz(driver.stateOrRegion, d['state'] ?? d['region']),
            'Account status': sentenceCaseStatus(driver.accountStatus),
            'Online state': driver.isOnline ? 'Online' : 'Offline',
            if (dp.isNotEmpty) ...<String, String>{
              'Availability mode':
                  '${dp['driver_availability_mode'] ?? '—'}',
              'Live lat / lng': _formatLatLng(dp['lat'], dp['lng']),
              'Last location': _formatLastLoc(dp['last_location']),
              'Last location update (ms)':
                  '${dp['last_location_updated_at'] ?? '—'}',
              'Selected service area id':
                  '${dp['selected_service_area_id'] ?? '—'}',
              'Selected service area name':
                  '${dp['selected_service_area_name'] ?? '—'}',
              'Last seen (ms)': '${dp['last_seen_at'] ?? '—'}',
              'Dispatch verified (server)':
                  dp['nexride_verified'] == true ? 'Yes' : 'No',
              'Suspended (server)': dp['suspended'] == true ? 'Yes' : 'No',
            },
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
            'Pending withdrawals': formatAdminCurrency(driver.pendingWithdrawals),
            'Monetization': driverMonetizationStatusLabel(
              monetizationModel: driver.monetizationModel,
              subscriptionPlanType: driver.subscriptionPlanType,
              subscriptionActive: driver.subscriptionActive,
            ),
            'Subscription plan':
                '${sentenceCaseStatus(driver.subscriptionPlanType)} • ${sentenceCaseStatus(driver.subscriptionStatus)}',
            if (docSlots != null && docSlots > 0) 'Document slots (server)': '$docSlots',
          },
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: actions,
        ),
      ],
    );
  }

  static String _formatLatLng(Object? lat, Object? lng) {
    final double? la = lat is num ? lat.toDouble() : double.tryParse('$lat');
    final double? ln = lng is num ? lng.toDouble() : double.tryParse('$lng');
    if (la == null || ln == null) {
      return '—';
    }
    return '${la.toStringAsFixed(5)}, ${ln.toStringAsFixed(5)}';
  }

  static String _formatLastLoc(Object? raw) {
    if (raw is! Map) {
      return '—';
    }
    final Map<String, dynamic> m = Map<String, dynamic>.from(raw);
    return _formatLatLng(m['lat'] ?? m['latitude'], m['lng'] ?? m['longitude']);
  }

  static String _nz(String primary, Object? secondary) {
    if (primary.trim().isNotEmpty) {
      return primary;
    }
    if (secondary == null) {
      return 'Not set';
    }
    final String s = secondary.toString().trim();
    return s.isEmpty ? 'Not set' : s;
  }

  static Widget _verification(Map<String, dynamic> payload) {
    final Map<String, dynamic> ver = payload['verification'] is Map
        ? Map<String, dynamic>.from(payload['verification'] as Map)
        : <String, dynamic>{};
    final Map<String, dynamic> docs = payload['documents_meta'] is Map
        ? Map<String, dynamic>.from(payload['documents_meta'] as Map)
        : <String, dynamic>{};
    final Map<String, dynamic> dv = payload['driver_verification'] is Map
        ? Map<String, dynamic>.from(payload['driver_verification'] as Map)
        : <String, dynamic>{};
    if (ver.isEmpty && docs.isEmpty && dv.isEmpty) {
      return const _PaneMessage(
        title: 'No verification payload',
        body: 'This driver has no stored verification rows yet.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text(
          'Verification (driver_verifications)',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
        ),
        const SizedBox(height: 8),
        if (ver.isEmpty)
          const Text('Empty record.', style: TextStyle(color: Color(0xFF6F685E)))
        else
          SelectableText(
            const JsonEncoder.withIndent('  ').convert(ver),
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          ),
        if (dv.isNotEmpty) ...<Widget>[
          const SizedBox(height: 16),
          const Text(
            'Driver snapshot (verification)',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
          ),
          const SizedBox(height: 8),
          SelectableText(
            const JsonEncoder.withIndent('  ').convert(dv),
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          ),
        ],
        if (docs.isNotEmpty) ...<Widget>[
          const SizedBox(height: 16),
          const Text(
            'Documents',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
          ),
          const SizedBox(height: 8),
          ...docs.entries.map(
            (MapEntry<String, dynamic> e) => ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(e.key),
              subtitle: Text(
                e.value is Map ? jsonEncode(e.value) : '${e.value}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ],
    );
  }

  static Widget _wallet(Map<String, dynamic> payload) {
    final Object? w = payload['wallet'];
    if (w is! Map) {
      return const _PaneMessage(
        title: 'No wallet',
        body: 'Wallet record is missing or empty.',
      );
    }
    final Map<String, dynamic> wm = Map<String, dynamic>.from(w);
    if (wm.isEmpty) {
      return const _PaneMessage(
        title: 'No wallet',
        body: 'Wallet record is missing or empty.',
      );
    }
    final List<MapEntry<String, dynamic>> entries = wm.entries.toList()
      ..sort((MapEntry<String, dynamic> a, MapEntry<String, dynamic> b) => a.key.compareTo(b.key));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final MapEntry<String, dynamic> e in entries)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(e.key),
            subtitle: SelectableText(
              _prettyValue(e.value),
              style: const TextStyle(fontSize: 13),
            ),
          ),
      ],
    );
  }

  static String _prettyValue(Object? v) {
    if (v == null) {
      return '—';
    }
    if (v is Map || v is List) {
      try {
        return const JsonEncoder.withIndent('  ').convert(v);
      } catch (_) {
        return v.toString();
      }
    }
    return v.toString();
  }

  static Widget _trips(Map<String, dynamic> payload) {
    final List<dynamic>? rawTrips = payload['trips'] is List ? payload['trips'] as List : null;
    if (rawTrips == null || rawTrips.isEmpty) {
      return const _PaneMessage(
        title: 'No recent trips',
        body: 'No ride_requests matched this driver in the bounded query.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Last ${rawTrips.length} trips (server bounded)',
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
        const SizedBox(height: 8),
        for (final dynamic t in rawTrips)
          if (t is Map)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                dense: true,
                title: Text('${t['ride_id'] ?? '—'} · ${t['status'] ?? ''}'),
                subtitle: Text(
                  '${t['pickup_hint'] ?? ''} → ${t['dropoff_hint'] ?? ''}\n'
                  '${formatAdminCurrency(num.tryParse('${t['fare'] ?? 0}') ?? 0)} · '
                  '${formatAdminDateTime(_msToDate(t['updated_at']))}',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
      ],
    );
  }

  static DateTime? _msToDate(Object? v) {
    final int? n = int.tryParse('$v');
    if (n == null || n <= 0) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(n);
  }

  static Widget _subscription(AdminDriverRecord driver, Map<String, dynamic> payload) {
    final Object? rawS = payload['subscription'];
    if (rawS is! Map) {
      return const _PaneMessage(title: 'No subscription data', body: '—');
    }
    final Map<String, dynamic> sm = Map<String, dynamic>.from(rawS);
    return AdminKeyValueWrap(
      items: <String, String>{
        'List row (fallback)': driverMonetizationStatusLabel(
          monetizationModel: driver.monetizationModel,
          subscriptionPlanType: driver.subscriptionPlanType,
          subscriptionActive: driver.subscriptionActive,
        ),
        'Monetization (server)': '${sm['monetization_model'] ?? '—'}',
        'Plan type': '${sm['subscription_plan_type'] ?? '—'}',
        'Status': '${sm['subscription_status'] ?? '—'}',
        'Active': '${sm['subscription_active'] ?? false}',
        'Expires': formatAdminDateTime(_msToDate(sm['subscription_expires_at'])),
      },
    );
  }

  static Widget _violations(Map<String, dynamic> payload) {
    final List<dynamic>? rows = payload['violations'] is List ? payload['violations'] as List : null;
    if (rows == null || rows.isEmpty) {
      return const _PaneMessage(
        title: 'No violations',
        body: 'No structured warning / suspension notes were found on the driver record.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final dynamic r in rows)
          if (r is Map)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                dense: true,
                title: Text('${r['code'] ?? 'violation'}'),
                subtitle: SelectableText('${r['message'] ?? ''}'),
                trailing: Text(formatAdminDateTime(_msToDate(r['at']))),
              ),
            ),
      ],
    );
  }

  static Widget _notes(Map<String, dynamic> payload) {
    final Object? n = payload['notes'];
    if (n is! Map) {
      return const _PaneMessage(title: 'No notes', body: 'Notes tab had no fields.');
    }
    final Map<String, dynamic> nm = Map<String, dynamic>.from(n);
    final List<String> keys = nm.keys.toList()..sort();
    final bool hasContent = keys.any((String k) {
      final Object? v = nm[k];
      return v != null && v.toString().trim().isNotEmpty;
    });
    if (!hasContent) {
      return const _PaneMessage(title: 'No notes', body: 'All note fields are empty.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final String k in keys)
          if (nm[k] != null && nm[k].toString().trim().isNotEmpty) ...<Widget>[
            Text(k, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
            const SizedBox(height: 4),
            SelectableText('${nm[k]}'),
            const SizedBox(height: 12),
          ],
      ],
    );
  }

  static Widget _audit(Map<String, dynamic> payload) {
    final List<dynamic> va =
        payload['verification_audits'] is List ? payload['verification_audits'] as List : <dynamic>[];
    final List<dynamic> aa =
        payload['admin_audit_tail'] is List ? payload['admin_audit_tail'] as List : <dynamic>[];
    if (va.isEmpty && aa.isEmpty) {
      return const _PaneMessage(
        title: 'No audit entries',
        body: 'No verification_audits or admin_audit_logs rows matched this driver.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (va.isNotEmpty) ...<Widget>[
          const Text('Verification audits', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          for (final dynamic r in va)
            if (r is Map)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('${r['action'] ?? r['id'] ?? 'event'}'),
                subtitle: Text('${r['reviewedBy'] ?? ''} · ${r['failureReason'] ?? ''}'),
                trailing: Text(formatAdminDateTime(_msToDate(r['reviewedAt']))),
              ),
        ],
        if (aa.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          const Text('Admin audit tail', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          for (final dynamic r in aa)
            if (r is Map)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('${r['action'] ?? r['type'] ?? r['id'] ?? 'audit'}'),
                subtitle: Text('${r['actor_uid'] ?? ''}'),
                trailing: Text(formatAdminDateTime(_msToDate(r['created_at']))),
              ),
        ],
      ],
    );
  }
}

class _PaneMessage extends StatelessWidget {
  const _PaneMessage({
    required this.title,
    required this.body,
    this.dense = false,
  });

  final String title;
  final String body;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: dense ? 14 : 16,
            color: const Color(0xFF3C3630),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          body,
          style: TextStyle(
            fontSize: dense ? 13 : 14,
            color: const Color(0xFF6F685E),
          ),
        ),
      ],
    );
  }
}
