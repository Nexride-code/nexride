import 'package:flutter/material.dart';

import '../models/rollout_delivery_region_model.dart';
import '../services/rider_rollout_profile_store.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Bottom sheet: pick enabled state + city from [listDeliveryRegions], persist rollout fields.
class RiderRolloutAreaSheet extends StatefulWidget {
  const RiderRolloutAreaSheet({
    super.key,
    required this.regions,
    this.initialRegionId,
    this.initialCityId,
    this.onReloadCatalog,
  });

  final List<RolloutDeliveryRegionModel> regions;
  final String? initialRegionId;
  final String? initialCityId;
  final Future<List<RolloutDeliveryRegionModel>> Function()? onReloadCatalog;

  static Future<void> show(
    BuildContext context, {
    required List<RolloutDeliveryRegionModel> regions,
    String? initialRegionId,
    String? initialCityId,
    Future<List<RolloutDeliveryRegionModel>> Function()? onReloadCatalog,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => RiderRolloutAreaSheet(
        regions: regions,
        initialRegionId: initialRegionId,
        initialCityId: initialCityId,
        onReloadCatalog: onReloadCatalog,
      ),
    );
  }

  @override
  State<RiderRolloutAreaSheet> createState() => _RiderRolloutAreaSheetState();
}

class _RiderRolloutAreaSheetState extends State<RiderRolloutAreaSheet> {
  late List<RolloutDeliveryRegionModel> _regions;
  String? _regionId;
  String? _cityId;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _regions = List<RolloutDeliveryRegionModel>.from(widget.regions);
    _regionId = widget.initialRegionId?.trim().isNotEmpty == true
        ? widget.initialRegionId!.trim()
        : null;
    _cityId = widget.initialCityId?.trim().isNotEmpty == true
        ? widget.initialCityId!.trim()
        : null;
    _ensureDefaults();
  }

  void _ensureDefaults() {
    if (_regions.isEmpty) {
      return;
    }
    final hasRegion = _regions.any((r) => r.regionId == _regionId);
    if (!hasRegion) {
      _regionId = _regions.first.regionId;
    }
    final r = _regions.firstWhere((e) => e.regionId == _regionId);
    final hasCity = r.cities.any((c) => c.cityId == _cityId);
    if (!hasCity && r.cities.isNotEmpty) {
      _cityId = r.cities.first.cityId;
    }
  }

  RolloutDeliveryRegionModel? get _selectedRegion {
    for (final r in _regions) {
      if (r.regionId == _regionId) {
        return r;
      }
    }
    return null;
  }

  Future<void> _retryLoad() async {
    final loader = widget.onReloadCatalog;
    if (loader == null) {
      return;
    }
    setState(() {
      _error = null;
    });
    try {
      final next = await loader();
      if (!mounted) {
        return;
      }
      setState(() {
        _regions = next;
        _ensureDefaults();
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not load areas. Check connection and retry.';
        });
      }
    }
  }

  Future<void> _save() async {
    final uid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    final region = _selectedRegion;
    if (uid.isEmpty || region == null || (_cityId ?? '').isEmpty) {
      setState(() {
        _error = 'Choose a state and city.';
      });
      return;
    }
    RolloutDeliveryCityModel? city;
    for (final c in region.cities) {
      if (c.cityId == _cityId) {
        city = c;
        break;
      }
    }
    if (city == null) {
      setState(() {
        _error = 'Choose a city.';
      });
      return;
    }
    final dm = region.dispatchMarketId.trim();
    if (dm.isEmpty) {
      setState(() {
        _error = 'Service area is misconfigured. Try again later.';
      });
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await RiderRolloutProfileStore.instance.saveSelection(
        uid: uid,
        regionId: region.regionId,
        cityId: city.cityId,
        dispatchMarketId: dm,
      );
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 8, 20, 16 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'Your service area',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'NexRide is available only in enabled cities. Choose where you ride.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_regions.isEmpty)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const Text('No enabled areas loaded.'),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _saving ? null : _retryLoad,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            )
          else ...<Widget>[
            DropdownButtonFormField<String>(
              // ignore: deprecated_member_use
              value: _regionId,
              decoration: const InputDecoration(labelText: 'State'),
              items: _regions
                  .map(
                    (r) => DropdownMenuItem<String>(
                      value: r.regionId,
                      child: Text(r.stateLabel),
                    ),
                  )
                  .toList(),
              onChanged: (v) {
                setState(() {
                  _regionId = v;
                  final rr = _selectedRegion;
                  if (rr != null && rr.cities.isNotEmpty) {
                    _cityId = rr.cities.first.cityId;
                  } else {
                    _cityId = null;
                  }
                });
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              // ignore: deprecated_member_use
              value: _cityId,
              decoration: const InputDecoration(labelText: 'City / area'),
              items: (_selectedRegion?.cities ?? const <RolloutDeliveryCityModel>[])
                  .map(
                    (c) => DropdownMenuItem<String>(
                      value: c.cityId,
                      child: Text(c.displayName),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setState(() => _cityId = v),
            ),
            const SizedBox(height: 20),
            Row(
              children: <Widget>[
                if (widget.onReloadCatalog != null)
                  TextButton.icon(
                    onPressed: _saving ? null : _retryLoad,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Refresh'),
                  ),
                const Spacer(),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
