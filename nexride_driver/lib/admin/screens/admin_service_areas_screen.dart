import 'package:flutter/material.dart';

import '../admin_config.dart';
import '../models/admin_models.dart';
import '../services/admin_data_service.dart';
import '../widgets/admin_components.dart';
import '../widgets/admin_permission_gate.dart';
import '../widgets/admin_sensitive_action_dialog.dart';

/// NexRide service areas — Firestore `delivery_regions` / `cities` via
/// [AdminDataService] (`adminListServiceAreas`, `adminUpsertServiceArea`, …).
class AdminServiceAreasScreen extends StatefulWidget {
  const AdminServiceAreasScreen({
    required this.dataService,
    required this.session,
    super.key,
  });

  final AdminDataService dataService;
  final AdminSession session;

  @override
  State<AdminServiceAreasScreen> createState() => _AdminServiceAreasScreenState();
}

class _AdminServiceAreasScreenState extends State<AdminServiceAreasScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _areas = const <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.dataService.adminListServiceAreas();
      if (data['success'] != true) {
        throw StateError(data['reason']?.toString() ?? 'list_failed');
      }
      final raw = data['areas'];
      final list = <Map<String, dynamic>>[];
      if (raw is List) {
        for (final item in raw) {
          if (item is Map) {
            list.add(
              item.map((Object? k, Object? v) => MapEntry(k.toString(), v)),
            );
          }
        }
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _areas = list;
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

  Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map) {
      return value.map((Object? k, Object? v) => MapEntry(k.toString(), v));
    }
    return <String, dynamic>{};
  }

  String _text(dynamic v) => v?.toString().trim() ?? '';

  bool _asBool(dynamic v, {bool defaultValue = true}) {
    if (v is bool) {
      return v;
    }
    if (v == null) {
      return defaultValue;
    }
    final s = v.toString().trim().toLowerCase();
    if (s == 'false' || s == '0') {
      return false;
    }
    if (s == 'true' || s == '1') {
      return true;
    }
    return defaultValue;
  }

  double? _asDouble(dynamic v) {
    if (v is num) {
      return v.toDouble();
    }
    return double.tryParse(_text(v));
  }

  Future<void> _setCityEnabled(
    Map<String, dynamic> row,
    bool enabled,
  ) async {
    final regionId = _text(row['region_id']);
    final cityId = _text(row['city_id']);
    if (regionId.isEmpty || cityId.isEmpty) {
      return;
    }
    final String? reason = await showAdminSensitiveActionDialog(
      context,
      title: enabled ? 'Enable service area' : 'Disable service area',
      message:
          'Region $regionId, city $cityId. This affects rollout and dispatch availability.',
      confirmLabel: enabled ? 'Enable' : 'Disable',
      minReasonLength: 4,
    );
    if (reason == null) {
      return;
    }
    try {
      final data = enabled
          ? await widget.dataService.adminEnableServiceArea(
              regionId: regionId,
              cityId: cityId,
              reason: reason,
            )
          : await widget.dataService.adminDisableServiceArea(
              regionId: regionId,
              cityId: cityId,
              reason: reason,
            );
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
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Update failed: $e')),
        );
      }
    }
  }

  Future<void> _openEditor({
    required Map<String, dynamic>? existing,
    required bool isCreate,
  }) async {
    final regionIdCtrl = TextEditingController(
      text: existing == null ? '' : _text(existing['region_id']),
    );
    final cityIdCtrl = TextEditingController(
      text: existing == null ? '' : _text(existing['city_id']),
    );
    final displayCtrl = TextEditingController(
      text: existing == null ? '' : _text(existing['display_name']),
    );
    final stateCtrl = TextEditingController(
      text: existing == null ? '' : _text(existing['state']),
    );
    final countryCtrl = TextEditingController(
      text: existing == null || _text(existing['country']).isEmpty
          ? 'Nigeria'
          : _text(existing['country']),
    );
    final dispatchCtrl = TextEditingController(
      text: existing == null ? '' : _text(existing['dispatch_market_id']),
    );
    final latCtrl = TextEditingController(
      text: _asDouble(existing?['center_lat'])?.toString() ?? '',
    );
    final lngCtrl = TextEditingController(
      text: _asDouble(existing?['center_lng'])?.toString() ?? '',
    );
    final radiusCtrl = TextEditingController(
      text: (_asDouble(existing?['service_radius_km']) ?? 25).toString(),
    );

    var supportsRides = existing == null ? true : _asBool(existing['supports_rides']);
    var supportsDelivery =
        existing == null ? true : _asBool(existing['supports_delivery']);
    var supportsMerchant =
        existing == null ? true : _asBool(existing['supports_merchant']);
    var cityEnabled = existing == null ? true : _asBool(existing['enabled']);
    var regionEnabled =
        existing == null ? true : _asBool(existing['region_enabled']);

    bool? saved;
    String? outRegionId;
    String? outCityId;
    String? outDisplay;
    String? outState;
    String? outCountry;
    String? outDispatch;
    String? outLat;
    String? outLng;
    String? outRadius;
    try {
      saved = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext ctx) {
          return StatefulBuilder(
            builder:
                (BuildContext context, void Function(void Function()) setLocal) {
              return AlertDialog(
              title: Text(isCreate ? 'New service area' : 'Edit service area'),
              content: SizedBox(
                width: 480,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      TextField(
                        controller: regionIdCtrl,
                        readOnly: !isCreate,
                        decoration: const InputDecoration(
                          labelText: 'Region id',
                          helperText: 'Firestore doc id under delivery_regions',
                        ),
                      ),
                      TextField(
                        controller: cityIdCtrl,
                        readOnly: !isCreate,
                        decoration: const InputDecoration(
                          labelText: 'City id',
                          helperText: 'Subdoc id under cities',
                        ),
                      ),
                      TextField(
                        controller: displayCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Display name',
                        ),
                      ),
                      TextField(
                        controller: stateCtrl,
                        decoration: const InputDecoration(
                          labelText: 'State / region label',
                        ),
                      ),
                      TextField(
                        controller: countryCtrl,
                        decoration: const InputDecoration(labelText: 'Country'),
                      ),
                      TextField(
                        controller: dispatchCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Dispatch market id',
                          helperText: 'Must match RTDB market_pool for discovery',
                        ),
                      ),
                      TextField(
                        controller: latCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                          signed: true,
                        ),
                        decoration: const InputDecoration(labelText: 'Center latitude'),
                      ),
                      TextField(
                        controller: lngCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                          signed: true,
                        ),
                        decoration: const InputDecoration(labelText: 'Center longitude'),
                      ),
                      TextField(
                        controller: radiusCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Service radius (km)',
                        ),
                      ),
                      const SizedBox(height: 8),
                      CheckboxListTile(
                        value: regionEnabled,
                        onChanged: (bool? v) {
                          setLocal(() => regionEnabled = v ?? false);
                        },
                        title: const Text('Region enabled'),
                        controlAffinity: ListTileControlAffinity.leading,
                        contentPadding: EdgeInsets.zero,
                      ),
                      CheckboxListTile(
                        value: cityEnabled,
                        onChanged: (bool? v) {
                          setLocal(() => cityEnabled = v ?? false);
                        },
                        title: const Text('City enabled'),
                        controlAffinity: ListTileControlAffinity.leading,
                        contentPadding: EdgeInsets.zero,
                      ),
                      CheckboxListTile(
                        value: supportsRides,
                        onChanged: (bool? v) {
                          setLocal(() => supportsRides = v ?? false);
                        },
                        title: const Text('Supports rides'),
                        controlAffinity: ListTileControlAffinity.leading,
                        contentPadding: EdgeInsets.zero,
                      ),
                      CheckboxListTile(
                        value: supportsDelivery,
                        onChanged: (bool? v) {
                          setLocal(() => supportsDelivery = v ?? false);
                        },
                        title: const Text('Supports delivery'),
                        controlAffinity: ListTileControlAffinity.leading,
                        contentPadding: EdgeInsets.zero,
                      ),
                      CheckboxListTile(
                        value: supportsMerchant,
                        onChanged: (bool? v) {
                          setLocal(() => supportsMerchant = v ?? false);
                        },
                        title: const Text('Supports merchant'),
                        controlAffinity: ListTileControlAffinity.leading,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
      if (saved == true) {
        outRegionId = regionIdCtrl.text.trim();
        outCityId = cityIdCtrl.text.trim();
        outDisplay = displayCtrl.text.trim();
        outState = stateCtrl.text.trim();
        outCountry = countryCtrl.text.trim();
        outDispatch = dispatchCtrl.text.trim();
        outLat = latCtrl.text.trim();
        outLng = lngCtrl.text.trim();
        outRadius = radiusCtrl.text.trim();
      }
    } finally {
      regionIdCtrl.dispose();
      cityIdCtrl.dispose();
      displayCtrl.dispose();
      stateCtrl.dispose();
      countryCtrl.dispose();
      dispatchCtrl.dispose();
      latCtrl.dispose();
      lngCtrl.dispose();
      radiusCtrl.dispose();
    }

    if (saved != true || !mounted) {
      return;
    }

    final regionId = outRegionId ?? '';
    final cityId = outCityId ?? '';
    final state = outState ?? '';
    final dispatch = outDispatch ?? '';
    if (regionId.isEmpty || cityId.isEmpty || state.isEmpty || dispatch.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Region id, city id, state, and dispatch market are required.'),
        ),
      );
      return;
    }

    final lat = double.tryParse(outLat ?? '');
    final lng = double.tryParse(outLng ?? '');
    final radius = double.tryParse(outRadius ?? '');

    final payload = <String, dynamic>{
      'region_id': regionId,
      'city_id': cityId,
      'display_name': outDisplay ?? '',
      'state': state,
      'country': (outCountry ?? '').trim().isEmpty
          ? 'Nigeria'
          : (outCountry ?? '').trim(),
      'dispatch_market_id': dispatch,
      if (lat != null) 'center_lat': lat,
      if (lng != null) 'center_lng': lng,
      'service_radius_km': radius ?? 25,
      'supports_rides': supportsRides,
      'supports_delivery': supportsDelivery,
      'supports_merchant': supportsMerchant,
      'enabled': cityEnabled,
      'region_enabled': regionEnabled,
    };

    try {
      final data = await widget.dataService.adminUpsertServiceArea(payload);
      if (data['success'] != true && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Save failed: ${data['reason'] ?? 'unknown'}'),
          ),
        );
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Service area saved.')),
          );
        }
        await _load();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      }
    }
  }

  Future<void> _refreshDetail(Map<String, dynamic> row) async {
    final regionId = _text(row['region_id']);
    final cityId = _text(row['city_id']);
    if (regionId.isEmpty || cityId.isEmpty) {
      return;
    }
    try {
      final data = await widget.dataService.adminGetServiceArea(
        regionId: regionId,
        cityId: cityId,
      );
      if (data['success'] != true || !mounted) {
        return;
      }
      final area = _asMap(data['area']);
      if (area.isEmpty) {
        return;
      }
      await _openEditor(existing: area, isCreate: false);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Refresh failed: $e')),
        );
      }
    }
  }

  String _fmtTs(dynamic ms) {
    if (ms is! num) {
      return '—';
    }
    try {
      return DateTime.fromMillisecondsSinceEpoch(ms.toInt(), isUtc: false)
          .toLocal()
          .toString();
    } catch (_) {
      return '—';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const AdminEmptyState(
        title: 'Loading service areas',
        message:
            'Calling adminListServiceAreas (Firestore delivery_regions / cities).',
        icon: Icons.location_city_outlined,
      );
    }
    if (_error != null) {
      return AdminEmptyState(
        title: 'Could not load service areas',
        message: _error!,
        icon: Icons.error_outline_rounded,
      );
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints outer) {
        final tableHeight = outer.maxHeight.isFinite
            ? (outer.maxHeight - 140).clamp(240.0, 920.0)
            : 520.0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const AdminSectionHeader(
              title: 'Service areas',
              description:
                  'Rider and driver apps load these via listDeliveryRegions — manage rollout here instead of hardcoding cities.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Reload'),
                ),
                AdminPermissionGate(
                  session: widget.session,
                  permission: 'service_areas.write',
                  child: OutlinedButton.icon(
                    onPressed: () => _openEditor(existing: null, isCreate: true),
                    icon: const Icon(Icons.add_location_alt_outlined),
                    label: const Text('New area'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: tableHeight,
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints c) {
                  final narrow = c.maxWidth < 960;
                  if (narrow) {
                    return ListView.separated(
                      itemCount: _areas.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (BuildContext context, int i) {
                        final a = _areas[i];
                        return _buildAreaCard(a);
                      },
                    );
                  }
                  return SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minWidth: c.maxWidth),
                      child: DataTable(
                    headingRowHeight: 44,
                    dataRowMinHeight: 48,
                    columns: const <DataColumn>[
                      DataColumn(label: Text('State')),
                      DataColumn(label: Text('City')),
                      DataColumn(label: Text('Ids')),
                      DataColumn(label: Text('Dispatch')),
                      DataColumn(label: Text('Center / r (km)')),
                      DataColumn(label: Text('R / D / M')),
                      DataColumn(label: Text('On')),
                      DataColumn(label: Text('Updated')),
                      DataColumn(label: Text('Actions')),
                    ],
                    rows: _areas.map((Map<String, dynamic> a) {
                      return DataRow(
                        cells: <DataCell>[
                          DataCell(Text(_text(a['state']))),
                          DataCell(Text(_text(a['display_name']))),
                          DataCell(
                            SelectableText(
                              '${_text(a['region_id'])}\n${_text(a['city_id'])}',
                              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                            ),
                          ),
                          DataCell(
                            SelectableText(
                              _text(a['dispatch_market_id']),
                              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                            ),
                          ),
                          DataCell(
                            Text(
                              '${_asDouble(a['center_lat'])?.toStringAsFixed(5) ?? '—'}, '
                              '${_asDouble(a['center_lng'])?.toStringAsFixed(5) ?? '—'}\n'
                              '${_asDouble(a['service_radius_km'])?.toStringAsFixed(1) ?? '—'} km',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                          DataCell(
                            Text(
                              '${_asBool(a['supports_rides']) ? 'R' : '—'} '
                              '${_asBool(a['supports_delivery']) ? 'D' : '—'} '
                              '${_asBool(a['supports_merchant']) ? 'M' : '—'}',
                            ),
                          ),
                          DataCell(
                            Text(
                              'reg: ${_asBool(a['region_enabled']) ? 'on' : 'off'}\n'
                              'city: ${_asBool(a['enabled']) ? 'on' : 'off'}',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                          DataCell(
                            Text(
                              '${_fmtTs(a['updated_at'])}\n${_text(a['updated_by'])}',
                              style: const TextStyle(fontSize: 11),
                            ),
                          ),
                          DataCell(
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                IconButton(
                                  tooltip: 'Refresh from server',
                                  icon: const Icon(Icons.cloud_download_outlined),
                                  onPressed: () => _refreshDetail(a),
                                ),
                                AdminPermissionGate(
                                  session: widget.session,
                                  permission: 'service_areas.write',
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: <Widget>[
                                      IconButton(
                                        tooltip: 'Edit',
                                        icon: const Icon(Icons.edit_outlined),
                                        onPressed: () => _openEditor(existing: a, isCreate: false),
                                      ),
                                      IconButton(
                                        tooltip: 'Enable',
                                        icon: const Icon(Icons.toggle_on_outlined),
                                        onPressed: _asBool(a['enabled'])
                                            ? null
                                            : () => _setCityEnabled(a, true),
                                      ),
                                      IconButton(
                                        tooltip: 'Disable',
                                        icon: const Icon(Icons.toggle_off_outlined),
                                        onPressed: !_asBool(a['enabled'])
                                            ? null
                                            : () => _setCityEnabled(a, false),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    }).toList(),
                  ),
                ),
              );
            },
          ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildAreaCard(Map<String, dynamic> a) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      title: Text(_text(a['display_name'])),
      subtitle: Text(
        '${_text(a['state'])} · ${_text(a['region_id'])}/${_text(a['city_id'])}\n'
        'dispatch: ${_text(a['dispatch_market_id'])}',
        style: TextStyle(
          fontSize: 12,
          color: AdminThemeTokens.ink.withValues(alpha: 0.72),
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            icon: const Icon(Icons.cloud_download_outlined),
            onPressed: () => _refreshDetail(a),
          ),
          AdminPermissionGate(
            session: widget.session,
            permission: 'service_areas.write',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => _openEditor(existing: a, isCreate: false),
                ),
                IconButton(
                  tooltip: 'Enable',
                  icon: const Icon(Icons.toggle_on_outlined),
                  onPressed: _asBool(a['enabled']) ? null : () => _setCityEnabled(a, true),
                ),
                IconButton(
                  tooltip: 'Disable',
                  icon: const Icon(Icons.toggle_off_outlined),
                  onPressed: !_asBool(a['enabled']) ? null : () => _setCityEnabled(a, false),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
