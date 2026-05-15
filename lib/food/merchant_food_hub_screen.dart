import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/rider_rollout_profile_store.dart';
import '../services/rider_ride_cloud_functions_service.dart';
import '../support/friendly_firebase_errors.dart';
import '../support/rider_backend_pricing.dart';

/// Lists approved merchants near the rider's delivery location (server-filtered + ranked).
class MerchantFoodHubScreen extends StatefulWidget {
  const MerchantFoodHubScreen({
    super.key,
    required this.riderId,
    this.cityId = '',
    this.regionId,
    this.dispatchMarketId,
  });

  final String riderId;
  /// Rollout service city when known; may be empty if the server resolves from GPS.
  final String cityId;
  final String? regionId;
  final String? dispatchMarketId;

  @override
  State<MerchantFoodHubScreen> createState() => _MerchantFoodHubScreenState();
}

class _MerchantFoodHubScreenState extends State<MerchantFoodHubScreen> {
  bool _loading = true;
  bool _locating = false;
  String? _error;
  List<Map<String, dynamic>> _merchants = const <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _nearbyUnavailable = const <Map<String, dynamic>>[];
  String _resolvedCityId = '';
  StreamSubscription<DatabaseEvent>? _teaserSub;
  Map<String, Map<String, dynamic>> _teasers = const <String, Map<String, dynamic>>{};

  double? _deliveryLat;
  double? _deliveryLng;
  String _locationLabel = 'Getting your location…';

  @override
  void initState() {
    super.initState();
    _teaserSub =
        FirebaseDatabase.instance.ref('merchant_public_teaser').onValue.listen((DatabaseEvent ev) {
      final v = ev.snapshot.value;
      if (!mounted) {
        return;
      }
      if (v is Map) {
        setState(() {
          _teasers = v.map((dynamic k, dynamic val) {
            final key = k.toString();
            if (val is Map) {
              return MapEntry(
                key,
                Map<String, dynamic>.from(val.map((k2, v2) => MapEntry(k2.toString(), v2))),
              );
            }
            return MapEntry(key, <String, dynamic>{});
          });
        });
      }
    });
    unawaited(_bootstrapThenLoad());
  }

  @override
  void dispose() {
    _teaserSub?.cancel();
    super.dispose();
  }

  bool _ordersLiveTeaser(String merchantId) {
    final t = _teasers[merchantId];
    if (t == null) {
      return true;
    }
    return t['orders_live'] == true;
  }

  List<Map<String, dynamic>> get _visibleMerchants => _merchants
      .where((m) => _ordersLiveTeaser('${m['merchant_id'] ?? ''}'))
      .toList(growable: false);

  Future<void> _bootstrapThenLoad() async {
    if (_deliveryLat == null || _deliveryLng == null) {
      await _useDeviceLocation(silent: true);
    }
    await _load();
  }

  Future<void> _useDeviceLocation({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() {
        _locating = true;
      });
    }
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        if (mounted) {
          setState(() {
            _locating = false;
            _locationLabel = 'Location off — set a point on the map or enable permission.';
          });
        }
        return;
      }
      final p = await Geolocator.getCurrentPosition();
      if (!mounted) {
        return;
      }
      setState(() {
        _deliveryLat = p.latitude;
        _deliveryLng = p.longitude;
        _locationLabel = 'Delivery near ${p.latitude.toStringAsFixed(4)}, ${p.longitude.toStringAsFixed(4)}';
        _locating = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _locating = false;
          _locationLabel = 'Could not read GPS. Try again or pick coordinates below.';
        });
      }
    }
  }

  Future<void> _promptManualLocation() async {
    final latCtrl = TextEditingController(
      text: _deliveryLat?.toStringAsFixed(6) ?? '',
    );
    final lngCtrl = TextEditingController(
      text: _deliveryLng?.toStringAsFixed(6) ?? '',
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delivery location'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text('Enter coordinates for where you want food delivered.'),
            const SizedBox(height: 12),
            TextField(
              controller: latCtrl,
              decoration: const InputDecoration(labelText: 'Latitude', border: OutlineInputBorder()),
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: lngCtrl,
              decoration: const InputDecoration(labelText: 'Longitude', border: OutlineInputBorder()),
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok == true && mounted) {
      final la = double.tryParse(latCtrl.text.trim());
      final ln = double.tryParse(lngCtrl.text.trim());
      if (la != null && ln != null) {
        setState(() {
          _deliveryLat = la;
          _deliveryLng = ln;
          _locationLabel = 'Delivery near ${la.toStringAsFixed(4)}, ${ln.toStringAsFixed(4)}';
        });
        await _load();
      }
    }
    latCtrl.dispose();
    lngCtrl.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sel = await RiderRolloutProfileStore.instance.fetchSelection(widget.riderId.trim());
      final region = widget.regionId ?? sel?[RiderRolloutProfileStore.kRegionId];
      final city = widget.cityId.trim().isNotEmpty
          ? widget.cityId.trim()
          : (sel?[RiderRolloutProfileStore.kCityId] ?? '').trim();
      final market = widget.dispatchMarketId ?? sel?[RiderRolloutProfileStore.kDispatchMarketId];

      final r = await RiderRideCloudFunctionsService.instance.riderListApprovedMerchants(
        cityId: city.isNotEmpty ? city : null,
        regionId: region,
        riderLat: _deliveryLat,
        riderLng: _deliveryLng,
        dispatchMarketId: market,
      );
      if (r['success'] == true && r['merchants'] is List) {
        final list = <Map<String, dynamic>>[];
        for (final m in r['merchants'] as List<dynamic>) {
          if (m is Map) {
            list.add(m.map((k, v) => MapEntry(k.toString(), v)));
          }
        }
        final closed = <Map<String, dynamic>>[];
        final rawClosed = r['nearby_unavailable'];
        if (rawClosed is List) {
          for (final m in rawClosed) {
            if (m is Map) {
              closed.add(m.map((k, v) => MapEntry(k.toString(), v)));
            }
          }
        }
        final resolved = r['resolved_city_id']?.toString().trim() ?? '';
        if (mounted) {
          setState(() {
            _merchants = list;
            _nearbyUnavailable = closed;
            _resolvedCityId = resolved;
            _loading = false;
            if (_deliveryLat != null && _deliveryLng != null && resolved.isNotEmpty) {
              _locationLabel = 'Service area: $resolved · using your delivery point';
            }
          });
        }
      } else {
        throw StateError(r['reason']?.toString() ?? 'load_failed');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  static String _storeTypeLabel(Map<String, dynamic> m) {
    final bt = (m['business_type'] ?? '').toString().trim();
    if (bt.isNotEmpty) {
      return bt;
    }
    final c = (m['category'] ?? '').toString().trim();
    if (c.isNotEmpty) {
      return c;
    }
    return 'Store';
  }

  static String? _formatDistance(Map<String, dynamic> m) {
    final d = m['distance_km'];
    if (d is num) {
      return '${d.toStringAsFixed(d >= 10 ? 0 : 1)} km';
    }
    return null;
  }

  static String? _formatEta(Map<String, dynamic> m) {
    final a = m['eta_min'];
    final b = m['eta_max'];
    if (a is num && b is num) {
      final lo = a.round();
      final hi = b.round();
      if (lo > 0 && hi >= lo) {
        return '$lo–$hi min';
      }
    }
    return null;
  }

  static String _availabilityLine(Map<String, dynamic> m, {required bool teaserLive}) {
    final live = m['orders_live'] == true && teaserLive;
    if (live) {
      final eta = _formatEta(m);
      if (eta != null) {
        return 'Estimated delivery: $eta';
      }
      return 'Open · ETA varies';
    }
    final reason = (m['open_status_reason'] ?? m['unavailable_reason'] ?? '').toString();
    switch (reason) {
      case 'closed':
        return 'Store closed';
      case 'paused':
        return 'Currently unavailable';
      case 'not_approved':
        return 'Unavailable';
      case 'no_store_location':
        return 'Location not set for this store';
      default:
        return 'Currently unavailable';
    }
  }

  static String? _feeLine(Map<String, dynamic> m) {
    final f = m['delivery_fee_estimate_ngn'];
    if (f is num && f > 0) {
      return 'Delivery from ₦${f.round()}';
    }
    return null;
  }

  Widget _merchantTile(Map<String, dynamic> m, {required bool enabled}) {
    final id = m['merchant_id']?.toString() ?? '';
    final name = m['business_name']?.toString() ?? 'Merchant';
    final type = _storeTypeLabel(m);
    final dist = _formatDistance(m);
    final teaserOk = _ordersLiveTeaser(id);
    final subtitle = <String>[
      type,
      if (dist != null) dist,
      if (_feeLine(m) != null) _feeLine(m)!,
      _availabilityLine(m, teaserLive: teaserOk),
    ].join(' · ');

    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: ListTile(
        tileColor: Colors.grey.shade100,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: !enabled || id.isEmpty
            ? null
            : () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => MerchantCatalogScreen(
                      riderId: widget.riderId,
                      merchantId: id,
                      rolloutCityId: _resolvedCityId.isNotEmpty ? _resolvedCityId : widget.cityId,
                      rolloutRegionId: widget.regionId,
                      deliveryLat: _deliveryLat,
                      deliveryLng: _deliveryLng,
                    ),
                  ),
                );
              },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Food & stores'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Use GPS',
            onPressed: _locating
                ? null
                : () async {
                    await _useDeviceLocation();
                    await _load();
                  },
            icon: _locating
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.my_location),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, textAlign: TextAlign.center),
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: <Widget>[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          Material(
                            color: const Color(0xFFE8F4FF),
                            borderRadius: BorderRadius.circular(12),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    _locationLabel,
                                    style: const TextStyle(fontWeight: FontWeight.w600),
                                  ),
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: <Widget>[
                                      OutlinedButton.icon(
                                        onPressed: () async {
                                          await _useDeviceLocation();
                                          await _load();
                                        },
                                        icon: const Icon(Icons.gps_fixed, size: 18),
                                        label: const Text('Use current location'),
                                      ),
                                      OutlinedButton.icon(
                                        onPressed: _promptManualLocation,
                                        icon: const Icon(Icons.edit_location_alt, size: 18),
                                        label: const Text('Change delivery location'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_visibleMerchants.isEmpty && _nearbyUnavailable.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: <Widget>[
                            const Icon(Icons.storefront_outlined, size: 56, color: Colors.black45),
                            const SizedBox(height: 16),
                            const Text(
                              'No open stores near this delivery location',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'Try moving the map pin, enabling GPS, or choosing another area.',
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 20),
                            FilledButton.icon(
                              onPressed: _promptManualLocation,
                              icon: const Icon(Icons.edit_location_alt),
                              label: const Text('Change delivery location'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (_visibleMerchants.isEmpty && _nearbyUnavailable.isNotEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
                        child: Column(
                          children: <Widget>[
                            const Icon(Icons.store_mall_directory_outlined, size: 48, color: Colors.black45),
                            const SizedBox(height: 12),
                            const Text(
                              'No open stores near this delivery location',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'These stores are nearby but closed or not taking orders right now.',
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 16),
                            FilledButton.icon(
                              onPressed: _promptManualLocation,
                              icon: const Icon(Icons.edit_location_alt),
                              label: const Text('Change delivery location'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (_visibleMerchants.isNotEmpty)
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (ctx, i) {
                            if (i == 0) {
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Text(
                                  'Open now (${_visibleMerchants.length})',
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                              );
                            }
                            final m = _visibleMerchants[i - 1];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _merchantTile(m, enabled: true),
                            );
                          },
                          childCount: _visibleMerchants.length + 1,
                        ),
                      ),
                    ),
                  if (_nearbyUnavailable.isNotEmpty)
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (ctx, i) {
                            if (i == 0) {
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 8, top: 8),
                                child: Text(
                                  'Nearby (not taking orders)',
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                              );
                            }
                            final m = _nearbyUnavailable[i - 1];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _merchantTile(m, enabled: false),
                            );
                          },
                          childCount: _nearbyUnavailable.length + 1,
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class _CartLine {
  _CartLine({
    required this.itemId,
    required this.name,
    required this.unitPriceNgn,
    required this.qty,
  });

  final String itemId;
  final String name;
  final int unitPriceNgn;
  int qty;
}

enum _CheckoutStep { idle, initiatingPayment, awaitingReturn, verifying, placing }

/// Browse menu, cart, checkout with integrated Flutterwave payment.
class MerchantCatalogScreen extends StatefulWidget {
  const MerchantCatalogScreen({
    super.key,
    required this.riderId,
    required this.merchantId,
    required this.rolloutCityId,
    this.rolloutRegionId,
    this.deliveryLat,
    this.deliveryLng,
  });

  final String riderId;
  final String merchantId;
  final String rolloutCityId;
  final String? rolloutRegionId;
  final double? deliveryLat;
  final double? deliveryLng;

  @override
  State<MerchantCatalogScreen> createState() => _MerchantCatalogScreenState();
}

class _MerchantCatalogScreenState extends State<MerchantCatalogScreen>
    with WidgetsBindingObserver {
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _merchant = const <String, dynamic>{};
  List<Map<String, dynamic>> _categories = const <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _items = const <Map<String, dynamic>>[];
  final Map<String, _CartLine> _cart = <String, _CartLine>{};

  // Payment flow state
  _CheckoutStep _step = _CheckoutStep.idle;
  String _pendingTxRef = '';
  Map<String, dynamic>? _pendingDropoff;
  double _pendingDeliveryFee = 1500;
  String _pendingRecipientName = '';
  String _pendingRecipientPhone = '';
  String? _pendingServiceCity;
  String? _pendingServiceRegion;
  RiderBackendPricingQuote? _checkoutPricingQuote;

  StreamSubscription<DatabaseEvent>? _teaserSub;
  Map<String, dynamic>? _teaser;

  bool get _ordersLive => _teaser == null || _teaser!['orders_live'] == true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _teaserSub = FirebaseDatabase.instance
        .ref('merchant_public_teaser/${widget.merchantId}')
        .onValue
        .listen((DatabaseEvent ev) {
      final v = ev.snapshot.value;
      if (!mounted) {
        return;
      }
      setState(() {
        if (v is Map) {
          _teaser = Map<String, dynamic>.from(
            v.map((dynamic k, dynamic val) => MapEntry(k.toString(), val)),
          );
        } else {
          _teaser = null;
        }
      });
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _teaserSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _step == _CheckoutStep.awaitingReturn &&
        _pendingTxRef.isNotEmpty) {
      unawaited(_verifyAndPlaceOrder());
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await RiderRideCloudFunctionsService.instance.riderGetMerchantCatalog(
        merchantId: widget.merchantId,
        riderLat: widget.deliveryLat,
        riderLng: widget.deliveryLng,
      );
      if (r['success'] == true) {
        final m = r['merchant'];
        if (m is Map) {
          _merchant = m.map((k, v) => MapEntry(k.toString(), v));
        }
        final cats = <Map<String, dynamic>>[];
        if (r['categories'] is List) {
          for (final c in r['categories'] as List<dynamic>) {
            if (c is Map) {
              cats.add(c.map((k, v) => MapEntry(k.toString(), v)));
            }
          }
        }
        final items = <Map<String, dynamic>>[];
        if (r['items'] is List) {
          for (final it in r['items'] as List<dynamic>) {
            if (it is Map) {
              items.add(it.map((k, v) => MapEntry(k.toString(), v)));
            }
          }
        }
        if (mounted) {
          setState(() {
            _categories = cats;
            _items = items;
            _loading = false;
          });
        }
      } else {
        throw StateError(r['reason']?.toString() ?? 'load_failed');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  String _itemId(Map<String, dynamic> it) => (it['item_id'] ?? it['id'])?.toString() ?? '';

  int _price(Map<String, dynamic> it) {
    final n = it['price_ngn'];
    if (n is int) {
      return n;
    }
    if (n is double) {
      return n.round();
    }
    return int.tryParse(n?.toString() ?? '') ?? 0;
  }

  int get _subtotalNgn {
    var s = 0;
    for (final line in _cart.values) {
      s += line.unitPriceNgn * line.qty;
    }
    return s;
  }

  void _addToCart(Map<String, dynamic> it) {
    final id = _itemId(it);
    if (id.isEmpty) {
      return;
    }
    if (!_ordersLive) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This store is not taking orders right now.')),
      );
      return;
    }
    final name = it['name']?.toString() ?? 'Item';
    final price = _price(it);
    setState(() {
      final cur = _cart[id];
      if (cur == null) {
        _cart[id] = _CartLine(itemId: id, name: name, unitPriceNgn: price, qty: 1);
      } else {
        cur.qty = (cur.qty + 1).clamp(1, 50);
      }
    });
  }

  void _removeFromCart(String itemId) {
    setState(() {
      final cur = _cart[itemId];
      if (cur == null) {
        return;
      }
      if (cur.qty <= 1) {
        _cart.remove(itemId);
      } else {
        cur.qty -= 1;
      }
    });
  }

  Future<void> _openCheckoutSheet() async {
    if (_cart.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Your cart is empty.')),
      );
      return;
    }
    if (!_ordersLive) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This store is closed — you cannot check out right now.')),
      );
      return;
    }

    final addrCtrl = TextEditingController();
    final latCtrl = TextEditingController();
    final lngCtrl = TextEditingController();
    final feeEstimate = _merchant['delivery_fee_estimate_ngn'];
    final defaultFee = feeEstimate is num && feeEstimate > 0 ? feeEstimate.round() : 1500;
    final feeCtrl = TextEditingController(text: '$defaultFee');
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();

    final sel = await RiderRolloutProfileStore.instance.fetchSelection(
      widget.riderId.trim(),
    );
    if (!mounted) {
      addrCtrl.dispose();
      latCtrl.dispose();
      lngCtrl.dispose();
      feeCtrl.dispose();
      nameCtrl.dispose();
      phoneCtrl.dispose();
      return;
    }
    final serviceCity = sel?[RiderRolloutProfileStore.kCityId] ?? widget.rolloutCityId;
    final serviceRegion = sel?[RiderRolloutProfileStore.kRegionId] ?? widget.rolloutRegionId;

    if (widget.deliveryLat != null && widget.deliveryLng != null) {
      latCtrl.text = widget.deliveryLat!.toStringAsFixed(6);
      lngCtrl.text = widget.deliveryLng!.toStringAsFixed(6);
    }

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final deliveryFeeNgn =
              (double.tryParse(feeCtrl.text.trim()) ?? defaultFee.toDouble()).round();
          final sheetQuote = RiderBackendPricingQuote.previewCommerce(
            subtotalNgn: _subtotalNgn,
            deliveryFeeNgn: deliveryFeeNgn,
          );
          return Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 20,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Text(
                    'Delivery details',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: feeCtrl,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setSheetState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Delivery fee (₦)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  RiderBackendPricingBreakdown(
                    quote: sheetQuote,
                    compact: true,
                  ),
                  const SizedBox(height: 14),
              const SizedBox(height: 10),
              TextField(
                controller: addrCtrl,
                decoration: const InputDecoration(
                  labelText: 'Dropoff address',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: latCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Latitude',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: lngCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Longitude',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () async {
                    final perm = await Geolocator.requestPermission();
                    if (perm == LocationPermission.deniedForever || perm == LocationPermission.denied) {
                      return;
                    }
                    final p = await Geolocator.getCurrentPosition();
                    latCtrl.text = p.latitude.toStringAsFixed(6);
                    lngCtrl.text = p.longitude.toStringAsFixed(6);
                  },
                  icon: const Icon(Icons.my_location),
                  label: const Text('Use my location'),
                ),
              ),
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Recipient name (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: phoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Recipient phone (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () => Navigator.pop(ctx, true),
                    icon: const Icon(Icons.payment),
                    label: const Text('Continue to payment'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    if (confirmed != true || !mounted) {
      addrCtrl.dispose();
      latCtrl.dispose();
      lngCtrl.dispose();
      feeCtrl.dispose();
      nameCtrl.dispose();
      phoneCtrl.dispose();
      return;
    }

    final fee = double.tryParse(feeCtrl.text.trim()) ?? 1500.0;
    final lat = double.tryParse(latCtrl.text.trim());
    final lng = double.tryParse(lngCtrl.text.trim());

    if (lat == null || lng == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Valid dropoff coordinates are required.')),
      );
      addrCtrl.dispose();
      latCtrl.dispose();
      lngCtrl.dispose();
      feeCtrl.dispose();
      nameCtrl.dispose();
      phoneCtrl.dispose();
      return;
    }

    _pendingDropoff = <String, dynamic>{
      'lat': lat,
      'lng': lng,
      'address': addrCtrl.text.trim(),
    };
    _pendingDeliveryFee = fee;
    _pendingRecipientName = nameCtrl.text.trim();
    _pendingRecipientPhone = phoneCtrl.text.trim();
    _pendingServiceCity = serviceCity;
    _pendingServiceRegion = serviceRegion;

    addrCtrl.dispose();
    latCtrl.dispose();
    lngCtrl.dispose();
    feeCtrl.dispose();
    nameCtrl.dispose();
    phoneCtrl.dispose();

    await _initiatePayment();
  }

  Future<void> _initiatePayment() async {
    if (!mounted) {
      return;
    }
    setState(() => _step = _CheckoutStep.initiatingPayment);

    try {
      final user = FirebaseAuth.instance.currentUser;
      final r = await RiderRideCloudFunctionsService.instance.initiateFlutterwaveMerchantOrderPayment(
        subtotalNgn: _subtotalNgn,
        deliveryFeeNgn: _pendingDeliveryFee.round(),
        customerName: user?.displayName?.trim().isNotEmpty == true ? user!.displayName!.trim() : null,
        email: user?.email?.trim().isNotEmpty == true ? user!.email!.trim() : null,
      );

      if (!mounted) {
        return;
      }

      if (r['success'] != true) {
        setState(() => _step = _CheckoutStep.idle);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(r['reason']?.toString() ?? 'payment_init_failed')),
        );
        return;
      }

      final quote = RiderBackendPricingQuote.tryFromMap(r);
      if (quote != null && quote.hasAuthoritativeTotal) {
        _checkoutPricingQuote = quote;
      }

      final txRef = r['tx_ref']?.toString() ?? '';
      final urlRaw = r['authorization_url']?.toString() ?? '';
      final uri = Uri.tryParse(urlRaw.trim());

      if (txRef.isEmpty || uri == null || !uri.hasScheme) {
        setState(() => _step = _CheckoutStep.idle);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not start payment. Please try again.')),
        );
        return;
      }

      _pendingTxRef = txRef;
      setState(() => _step = _CheckoutStep.awaitingReturn);

      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!mounted) {
        return;
      }
      if (!launched) {
        setState(() => _step = _CheckoutStep.idle);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open the payment page.')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _step = _CheckoutStep.idle);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              friendlyFirebaseError(e, debugLabel: 'merchantFood.paymentInit'),
            ),
          ),
        );
      }
    }
  }

  Future<void> _verifyAndPlaceOrder() async {
    if (!mounted || _pendingTxRef.isEmpty) {
      return;
    }
    setState(() => _step = _CheckoutStep.verifying);

    try {
      final vr = await RiderRideCloudFunctionsService.instance.verifyFlutterwavePayment(
        reference: _pendingTxRef,
      );

      if (!mounted) {
        return;
      }

      if (vr['success'] != true) {
        setState(() => _step = _CheckoutStep.awaitingReturn);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              vr['reason']?.toString() == 'already_verified'
                  ? 'Payment already verified — placing your order...'
                  : 'Payment not confirmed yet. Tap "Verify payment" once you have completed payment.',
            ),
            action: SnackBarAction(
              label: 'Verify',
              onPressed: _verifyAndPlaceOrder,
            ),
            duration: const Duration(seconds: 8),
          ),
        );
        if (vr['reason']?.toString() == 'already_verified') {
          await _placeOrderAfterVerification();
        }
        return;
      }

      await _placeOrderAfterVerification();
    } catch (e) {
      if (mounted) {
        setState(() => _step = _CheckoutStep.awaitingReturn);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              friendlyFirebaseError(e, debugLabel: 'merchantFood.paymentVerify'),
            ),
            action: SnackBarAction(label: 'Retry', onPressed: _verifyAndPlaceOrder),
          ),
        );
      }
    }
  }

  Future<void> _placeOrderAfterVerification() async {
    if (!mounted) {
      return;
    }
    if (!_ordersLive) {
      setState(() => _step = _CheckoutStep.idle);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This store stopped taking orders. Please try again later.')),
      );
      return;
    }
    setState(() => _step = _CheckoutStep.placing);

    final cartPayload = _cart.values
        .map((l) => <String, dynamic>{'item_id': l.itemId, 'qty': l.qty})
        .toList(growable: false);

    try {
      final r = await RiderRideCloudFunctionsService.instance.riderPlaceMerchantOrder(
        merchantId: widget.merchantId,
        cart: cartPayload,
        dropoff: _pendingDropoff!,
        prepaidFlutterwaveRef: _pendingTxRef,
        deliveryFeeNgn: _pendingDeliveryFee,
        totalNgn: _checkoutPricingQuote?.totalNgn,
        recipientName: _pendingRecipientName.isEmpty ? null : _pendingRecipientName,
        recipientPhone: _pendingRecipientPhone.isEmpty ? null : _pendingRecipientPhone,
        serviceCityId: _pendingServiceCity,
        serviceRegionId: _pendingServiceRegion,
      );

      if (!mounted) {
        return;
      }

      if (RiderBackendPricingQuote.isPricingTotalMismatch(r)) {
        setState(() => _step = _CheckoutStep.idle);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(RiderBackendPricingQuote.pricingMismatchUserMessage(r)),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: _openCheckoutSheet,
            ),
          ),
        );
        return;
      }

      if (r['success'] == true) {
        final oid = r['order_id']?.toString() ?? '';
        setState(() {
          _cart.clear();
          _step = _CheckoutStep.idle;
          _pendingTxRef = '';
          _pendingDropoff = null;
          _checkoutPricingQuote = null;
        });
        await showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Order placed'),
            content: Text(
              oid.isEmpty
                  ? 'Order placed! The merchant will confirm shortly.'
                  : 'Order ID: $oid\n\nThe merchant will confirm your order. You can track dispatch status from your profile under "My orders".',
            ),
            actions: <Widget>[
              TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK')),
            ],
          ),
        );
      } else {
        setState(() => _step = _CheckoutStep.idle);
        final reason = r['reason']?.toString() ?? 'order_failed';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              RiderBackendPricingQuote.isPricingTotalMismatch(r)
                  ? RiderBackendPricingQuote.pricingMismatchUserMessage(r)
                  : reason,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _step = _CheckoutStep.idle);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              friendlyFirebaseError(e, debugLabel: 'merchantFood.placeOrder'),
            ),
          ),
        );
      }
    }
  }

  String _categoryName(String categoryId) {
    for (final c in _categories) {
      final id = (c['category_id'] ?? c['id'])?.toString() ?? '';
      if (id == categoryId) {
        return c['name']?.toString() ?? id;
      }
    }
    return categoryId;
  }

  String? _headerEtaLine() {
    final a = _merchant['eta_min'];
    final b = _merchant['eta_max'];
    if (a is num && b is num) {
      return 'Estimated delivery: ${a.round()}–${b.round()} min';
    }
    return null;
  }

  Widget _buildCheckoutOverlay() {
    if (_step == _CheckoutStep.awaitingReturn) {
      return Positioned.fill(
        child: ColoredBox(
          color: Colors.black54,
          child: Center(
            child: Card(
              margin: const EdgeInsets.all(32),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Icon(Icons.payment, size: 48, color: Color(0xFFB57A2A)),
                    const SizedBox(height: 16),
                    const Text(
                      'Complete payment in the browser',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'After paying, return to this app. Your order will be placed automatically.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _verifyAndPlaceOrder,
                      child: const Text('I have paid — continue'),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () => setState(() {
                        _step = _CheckoutStep.idle;
                        _pendingTxRef = '';
                      }),
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    if (_step == _CheckoutStep.initiatingPayment ||
        _step == _CheckoutStep.verifying ||
        _step == _CheckoutStep.placing) {
      final String label = switch (_step) {
        _CheckoutStep.initiatingPayment => 'Setting up payment...',
        _CheckoutStep.verifying => 'Verifying payment...',
        _CheckoutStep.placing => 'Placing your order...',
        _ => '',
      };
      return Positioned.fill(
        child: ColoredBox(
          color: Colors.black54,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const CircularProgressIndicator(color: Colors.white),
                const SizedBox(height: 16),
                Text(label, style: const TextStyle(color: Colors.white, fontSize: 16)),
              ],
            ),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    final title = _merchant['business_name']?.toString() ?? 'Menu';
    final cartCount = _cart.values.fold<int>(0, (s, l) => s + l.qty);
    final busy = _step != _CheckoutStep.idle && _step != _CheckoutStep.awaitingReturn;
    final etaLine = _headerEtaLine();
    final dist = _merchant['distance_km'];
    final distLine = dist is num ? '${dist.toStringAsFixed(dist >= 10 ? 0 : 1)} km away' : null;

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      floatingActionButton: cartCount > 0 && _step == _CheckoutStep.idle && _ordersLive
          ? FloatingActionButton.extended(
              onPressed: _openCheckoutSheet,
              icon: const Icon(Icons.shopping_cart_checkout),
              label: Text(
                _checkoutPricingQuote?.hasAuthoritativeTotal == true
                    ? 'Cart ($cartCount) · ₦${_checkoutPricingQuote!.totalNgn}'
                    : 'Cart ($cartCount) · ₦$_subtotalNgn + fees',
              ),
            )
          : null,
      body: Stack(
        children: <Widget>[
          _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? Center(child: Text(_error!))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                  children: <Widget>[
                    if (etaLine != null || distLine != null)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.schedule),
                          title: Text(etaLine ?? 'Delivery time'),
                          subtitle: distLine != null ? Text(distLine) : null,
                        ),
                      ),
                    if (!_ordersLive)
                      Card(
                        color: Colors.orange.shade50,
                        child: const ListTile(
                          leading: Icon(Icons.store_mall_directory_outlined),
                          title: Text('Store closed'),
                          subtitle: Text(
                            'This merchant is not accepting new orders right now. You can still browse.',
                          ),
                        ),
                      ),
                    ..._items.map((it) {
                      final id = _itemId(it);
                      final inCart = _cart[id];
                      return Card(
                        child: ListTile(
                          title: Text(it['name']?.toString() ?? ''),
                          subtitle: Text(
                            '${_categoryName(it['category_id']?.toString() ?? '')} · '
                            '₦${_price(it)} · prep ${it['prep_time_min'] ?? 15} min',
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              if (inCart != null) ...[
                                IconButton(
                                  icon: const Icon(Icons.remove_circle_outline),
                                  onPressed: () => _removeFromCart(id),
                                ),
                                Text(
                                  '${inCart.qty}',
                                  style: const TextStyle(fontWeight: FontWeight.w800),
                                ),
                              ],
                              IconButton(
                                icon: const Icon(Icons.add_circle_outline),
                                onPressed: busy ? null : () => _addToCart(it),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                  ],
                ),
          _buildCheckoutOverlay(),
        ],
      ),
    );
  }
}
