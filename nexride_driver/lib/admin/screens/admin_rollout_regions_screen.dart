import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../admin_config.dart';
import '../models/admin_models.dart';
import '../widgets/admin_components.dart';
import '../widgets/admin_permission_gate.dart';

/// Delivery rollout regions (Firestore `delivery_regions`) — mirrors admin web `/admin/regions`.
class AdminRolloutRegionsScreen extends StatefulWidget {
  const AdminRolloutRegionsScreen({super.key, required this.session});

  final AdminSession session;

  @override
  State<AdminRolloutRegionsScreen> createState() =>
      _AdminRolloutRegionsScreenState();
}

class _AdminRolloutRegionsScreenState extends State<AdminRolloutRegionsScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _regions = const <Map<String, dynamic>>[];
  bool _seeding = false;

  FirebaseFunctions get _fn =>
      FirebaseFunctions.instanceFor(region: 'us-central1');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final callable = _fn.httpsCallable(
        'adminListDeliveryRollout',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 45)),
      );
      final result = await callable.call(<String, dynamic>{});
      final data = _asMap(result.data);
      if (data['success'] != true) {
        throw StateError(
          data['reason']?.toString() ?? 'list_failed',
        );
      }
      final raw = data['regions'];
      final list = <Map<String, dynamic>>[];
      if (raw is List) {
        for (final item in raw) {
          if (item is Map) {
            list.add(item.map((k, v) => MapEntry(k.toString(), v)));
          }
        }
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _regions = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _seed() async {
    setState(() => _seeding = true);
    try {
      final callable = _fn.httpsCallable(
        'adminSeedRolloutDeliveryRegions',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 120)),
      );
      final result = await callable.call(<String, dynamic>{});
      final data = _asMap(result.data);
      if (data['success'] != true) {
        throw StateError(data['reason']?.toString() ?? 'seed_failed');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Rollout regions seeded / updated.')),
        );
      }
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Seed failed: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _seeding = false);
      }
    }
  }

  Future<void> _setRegionEnabled(
    Map<String, dynamic> region,
    bool enabled,
  ) async {
    final regionId = _text(region['region_id']);
    final state = _text(region['state']);
    final dispatchMarketId = _text(
      region['dispatch_market_id'] ?? region['dispatchMarketId'],
    );
    if (regionId.isEmpty || state.isEmpty || dispatchMarketId.isEmpty) {
      return;
    }
    final callable = _fn.httpsCallable(
      'adminUpsertDeliveryRegion',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
    );
    final result = await callable.call(<String, dynamic>{
      'region_id': regionId,
      'state': state,
      'dispatch_market_id': dispatchMarketId,
      'enabled': enabled,
      'country': _text(region['country']).isEmpty
          ? 'Nigeria'
          : _text(region['country']),
      'currency': _text(region['currency']).isEmpty
          ? 'NGN'
          : _text(region['currency']),
      'timezone': _text(region['timezone']).isEmpty
          ? 'Africa/Lagos'
          : _text(region['timezone']),
      'supports_rides': region['supports_rides'] != false,
      'supports_food': region['supports_food'] != false,
      'supports_package': region['supports_package'] != false,
      'supports_merchant': region['supports_merchant'] != false,
    });
    final data = _asMap(result.data);
    if (data['success'] != true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Update failed: ${data['reason'] ?? 'unknown'}',
          ),
        ),
      );
    } else {
      await _load();
    }
  }

  Future<void> _setCityEnabled(
    String regionId,
    Map<String, dynamic> city,
    bool enabled,
  ) async {
    final cityId = _text(city['city_id']);
    final displayName = _text(city['display_name'] ?? cityId);
    if (regionId.isEmpty || cityId.isEmpty || displayName.isEmpty) {
      return;
    }
    final callable = _fn.httpsCallable(
      'adminUpsertDeliveryCity',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
    );
    final lat = _asDouble(city['center_lat'] ?? city['centerLat']);
    final lng = _asDouble(city['center_lng'] ?? city['centerLng']);
    final radius = _asDouble(city['service_radius_km'] ?? city['serviceRadiusKm']) ??
        25.0;
    final result = await callable.call(<String, dynamic>{
      'region_id': regionId,
      'city_id': cityId,
      'display_name': displayName,
      'enabled': enabled,
      'supports_rides': city['supports_rides'] != false,
      'supports_food': city['supports_food'] != false,
      'supports_package': city['supports_package'] != false,
      'supports_merchant': city['supports_merchant'] != false,
      if (lat != null) 'center_lat': lat,
      if (lng != null) 'center_lng': lng,
      'service_radius_km': radius > 0 ? radius : 25.0,
    });
    final data = _asMap(result.data);
    if (data['success'] != true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'City update failed: ${data['reason'] ?? 'unknown'}',
          ),
        ),
      );
    } else {
      await _load();
    }
  }

  Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), v));
    }
    return <String, dynamic>{};
  }

  String _text(dynamic v) => v?.toString().trim() ?? '';

  double? _asDouble(dynamic v) {
    if (v is num) {
      return v.toDouble();
    }
    return double.tryParse(_text(v));
  }

  @override
  Widget build(BuildContext context) {
    final bool canWrite = widget.session.hasPermission('service_areas.write');
    if (_loading) {
      return const AdminEmptyState(
        title: 'Loading delivery regions',
        message:
            'Fetching rollout configuration from Cloud Functions (adminListDeliveryRollout).',
        icon: Icons.map_outlined,
      );
    }
    if (_error != null) {
      return AdminEmptyState(
        title: 'Could not load regions',
        message: _error!,
        icon: Icons.error_outline_rounded,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const AdminSectionHeader(
          title: 'Delivery regions',
          description:
              'Rollout states and cities (Firestore). Use seed once on empty projects.',
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: <Widget>[
            AdminPermissionGate(
              session: widget.session,
              permission: 'service_areas.write',
              child: FilledButton.icon(
                onPressed: _seeding ? null : _seed,
                icon: _seeding
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cloud_upload_outlined, size: 18),
                label: Text(_seeding ? 'Seeding…' : 'Seed default regions'),
              ),
            ),
            OutlinedButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Refresh'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        ..._regions.map((Map<String, dynamic> r) {
          final id = _text(r['region_id']);
          final enabled = r['enabled'] != false;
          final citiesRaw = r['cities'];
          final cities = <Map<String, dynamic>>[];
          if (citiesRaw is List) {
            for (final c in citiesRaw) {
              if (c is Map) {
                cities.add(c.map((k, v) => MapEntry(k.toString(), v)));
              }
            }
          }
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: ExpansionTile(
              leading: Icon(
                enabled ? Icons.check_circle_outline : Icons.pause_circle_outline,
                color: enabled ? AdminThemeTokens.success : AdminThemeTokens.warning,
              ),
              title: Text(
                _text(r['state']).isEmpty ? id : _text(r['state']),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                'Region: $id · dispatch ${_text(r['dispatch_market_id'])}',
                style: const TextStyle(fontSize: 12),
              ),
              children: <Widget>[
                SwitchListTile(
                  title: const Text('Region enabled'),
                  value: enabled,
                  onChanged: canWrite ? (v) => _setRegionEnabled(r, v) : null,
                ),
                const Divider(height: 1),
                ...cities.map((Map<String, dynamic> c) {
                  final cid = _text(c['city_id']);
                  final cEnabled = c['enabled'] != false;
                  return SwitchListTile(
                    dense: true,
                    title: Text(_text(c['display_name'])),
                    subtitle: Text(cid),
                    value: cEnabled,
                    onChanged: canWrite ? (v) => _setCityEnabled(id, c, v) : null,
                  );
                }),
              ],
            ),
          );
        }),
      ],
    );
  }
}
