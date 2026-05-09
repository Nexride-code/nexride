import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

/// Public live trip view. Requires `?token=` (share secret) per RTDB rules.
class TripLivePage extends StatefulWidget {
  const TripLivePage({
    super.key,
    required this.rideId,
    required this.token,
  });

  final String rideId;
  final String token;

  @override
  State<TripLivePage> createState() => _TripLivePageState();
}

class _TripLivePageState extends State<TripLivePage> {
  final MapController _map = MapController();
  StreamSubscription<DatabaseEvent>? _sub;
  String? _error;
  bool _authBusy = true;
  Map<String, dynamic>? _trip;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    final id = Uri.decodeComponent(widget.rideId.trim());
    final token = widget.token.trim();
    if (id.isEmpty || token.isEmpty) {
      setState(() {
        _authBusy = false;
        _error =
            'This tracking link is incomplete. Ask the rider to share again, or contact support@nexride.africa.';
      });
      return;
    }

    try {
      await FirebaseAuth.instance.signInAnonymously();
    } catch (e) {
      setState(() {
        _authBusy = false;
        _error =
            'Could not start a secure viewer session. Enable Anonymous sign-in in Firebase Auth, then retry. ($e)';
      });
      return;
    }

    if (!mounted) return;
    setState(() => _authBusy = false);

    final ref = FirebaseDatabase.instance.ref('shared_trips/$token');
    _sub = ref.onValue.listen((event) {
      if (!mounted) return;
      if (!event.snapshot.exists) {
        setState(() {
          _trip = null;
          _error = 'Trip not found or link expired.';
        });
        return;
      }
      final v = event.snapshot.value;
      if (v is! Map) {
        setState(() {
          _trip = null;
          _error = 'Trip not found or link expired.';
        });
        return;
      }
      final m = Map<String, dynamic>.from(
        v.map((k, val) => MapEntry(k.toString(), val)),
      );
      final rid = m['ride_id']?.toString().trim() ?? '';
      if (rid.isNotEmpty && rid != id) {
        setState(() {
          _error = 'This link does not match the trip ID in the URL.';
          _trip = null;
        });
        return;
      }
      setState(() {
        _trip = m;
        _error = null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _fitMap());
    }, onError: (Object e) {
      if (!mounted) return;
      setState(() {
        _error = 'Lost connection or permission denied. ($e)';
      });
    });
  }

  void _fitMap() {
    final pts = _allPoints();
    if (pts.length < 2) return;
    try {
      final b = LatLngBounds.fromPoints(pts);
      _map.fitCamera(
        CameraFit.bounds(bounds: b, padding: const EdgeInsets.all(48)),
      );
    } catch (_) {}
  }

  List<LatLng> _allPoints() {
    final out = <LatLng>[];
    void addLatLng(double? la, double? ln) {
      if (la != null && ln != null) out.add(LatLng(la, ln));
    }

    final pickup = _asMap(_trip?['pickup']);
    addLatLng(_d(pickup?['lat']), _d(pickup?['lng']));
    final dest = _asMap(_trip?['destination']);
    addLatLng(_d(dest?['lat']), _d(dest?['lng']));
    final live = _asMap(_trip?['live_location']);
    addLatLng(_d(live?['lat']), _d(live?['lng']));

    final route = _trip?['route'];
    if (route is Map) {
      final path = route['path'];
      if (path is List) {
        for (final p in path) {
          if (p is Map) {
            addLatLng(_d(p['lat']), _d(p['lng']));
          }
        }
      }
    }
    return out;
  }

  Map<String, dynamic>? _asMap(dynamic v) {
    if (v is! Map) return null;
    return v.map((k, val) => MapEntry(k.toString(), val));
  }

  double? _d(dynamic v) {
    if (v is num) return v.toDouble();
    return null;
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel() ?? Future<void>.value());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_authBusy) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_trip == null && _error == null) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Connecting to live trip…'),
            ],
          ),
        ),
      );
    }

    if (_error != null && _trip == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Trip tracking')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.link_off, size: 48),
                  const SizedBox(height: 16),
                  Text(_error!, textAlign: TextAlign.center),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: () => context.go('/'),
                    child: const Text('Back to home'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final trip = _trip ?? {};
    final status = trip['status']?.toString() ?? '—';
    final expiresAt = _asInt(trip['expires_at']) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    final expired = expiresAt > 0 && now > expiresAt;
    final terminal = _isTerminalStatus(status);

    final pickup = _asMap(trip['pickup']);
    final dest = _asMap(trip['destination']);
    final live = _asMap(trip['live_location']);
    final driver = _asMap(trip['driver']);
    final pts = _allPoints();
    final center = pts.isNotEmpty ? pts.first : const LatLng(6.5244, 3.3792);

    final eta = _estimateEtaMinutes(live, dest, terminal);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Live trip'),
        actions: [
          TextButton(
            onPressed: () => context.go('/'),
            child: const Text('NexRide home'),
          ),
        ],
      ),
      body: Column(
        children: [
          Material(
            elevation: 0,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Chip(label: Text(status)),
                      const SizedBox(width: 8),
                      if (eta != null)
                        Chip(
                          avatar: const Icon(Icons.schedule, size: 18),
                          label: Text('~$eta min'),
                        ),
                      const Spacer(),
                      if (expired || terminal)
                        Text(
                          expired ? 'Link window ended' : 'Trip finished',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _placeLine('Pickup', pickup),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  Text(
                    _placeLine('Drop-off', dest),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  if (driver != null)
                    Text(
                      'Driver: ${_text(driver['name'])} · ${_text(driver['car'])} ${_text(driver['plate'])}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: _openInRiderApp,
                        icon: const Icon(Icons.phone_android),
                        label: const Text('Open in NexRide app'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => launchUrl(
                          Uri.parse(
                            'https://play.google.com/store/apps/details?id=com.nexride.rider',
                          ),
                          mode: LaunchMode.externalApplication,
                        ),
                        icon: const Icon(Icons.shop),
                        label: const Text('Get rider app'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: FlutterMap(
              mapController: _map,
              options: MapOptions(
                initialCenter: center,
                initialZoom: 13,
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.all,
                ),
              ),
              children: [
                TileLayer(
                  urlTemplate:
                      'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png',
                  subdomains: const ['a', 'b', 'c', 'd'],
                  userAgentPackageName: 'africa.nexride.site',
                ),
                if (_polylinePoints(trip).length >= 2)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: _polylinePoints(trip),
                        strokeWidth: 4,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ],
                  ),
                MarkerLayer(
                  markers: [
                    if (_latLngFromMap(pickup) != null)
                      Marker(
                        point: _latLngFromMap(pickup)!,
                        width: 36,
                        height: 36,
                        child: const Icon(Icons.trip_origin, color: Colors.blue),
                      ),
                    if (_latLngFromMap(dest) != null)
                      Marker(
                        point: _latLngFromMap(dest)!,
                        width: 36,
                        height: 36,
                        child: const Icon(Icons.place, color: Colors.red),
                      ),
                    if (_latLngFromMap(live) != null)
                      Marker(
                        point: _latLngFromMap(live)!,
                        width: 40,
                        height: 40,
                        child: const Icon(Icons.local_taxi, color: Colors.black87),
                      ),
                  ],
                ),
                RichAttributionWidget(
                  attributions: [
                    TextSourceAttribution(
                      '© OpenStreetMap · CARTO',
                      onTap: () => launchUrl(
                        Uri.parse('https://www.openstreetmap.org/copyright'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                '© NexRide Africa · Read-only tracking · nexride.africa',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<LatLng> _polylinePoints(Map<String, dynamic> trip) {
    final route = trip['route'];
    if (route is! Map) return const [];
    final path = route['path'];
    if (path is! List) return const [];
    final out = <LatLng>[];
    for (final p in path) {
      if (p is Map) {
        final la = _d(p['lat']);
        final ln = _d(p['lng']);
        if (la != null && ln != null) out.add(LatLng(la, ln));
      }
    }
    return out;
  }

  LatLng? _latLngFromMap(Map<String, dynamic>? m) {
    if (m == null) return null;
    final la = _d(m['lat']);
    final ln = _d(m['lng']);
    if (la == null || ln == null) return null;
    return LatLng(la, ln);
  }

  int? _estimateEtaMinutes(
    Map<String, dynamic>? live,
    Map<String, dynamic>? dest,
    bool terminal,
  ) {
    if (terminal) return null;
    final d = _latLngFromMap(dest);
    final l = _latLngFromMap(live);
    if (d == null || l == null) return null;
    final meters = const Distance().as(LengthUnit.Meter, l, d);
    const speedKmh = 28.0;
    final hours = (meters / 1000) / speedKmh;
    final mins = (hours * 60).round();
    if (mins <= 0 || mins > 240) return null;
    return mins;
  }

  bool _isTerminalStatus(String s) {
    final x = s.toLowerCase();
    return x.contains('complete') ||
        x.contains('cancel') ||
        x == 'ended' ||
        x == 'done';
  }

  int? _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return null;
  }

  String _placeLine(String label, Map<String, dynamic>? m) {
    if (m == null) return '$label: —';
    final addr = _firstNonEmpty([
      _text(m['address']),
      _text(m['label']),
      _text(m['name']),
    ]);
    final area = _text(m['area']);
    final bits = <String>[if (addr.isNotEmpty) addr, if (area.isNotEmpty) area];
    return '$label: ${bits.isEmpty ? 'Location on map' : bits.join(' · ')}';
  }

  String _text(dynamic v) => v?.toString().trim() ?? '';

  String _firstNonEmpty(List<String> values) {
    for (final s in values) {
      if (s.isNotEmpty) return s;
    }
    return '';
  }

  Future<void> _openInRiderApp() async {
    final id = Uri.decodeComponent(widget.rideId.trim());
    final t = widget.token.trim();
    final app = Uri.parse('nexride://trip?rideId=${Uri.encodeComponent(id)}'
        '&token=${Uri.encodeComponent(t)}');
    if (await canLaunchUrl(app)) {
      await launchUrl(app, mode: LaunchMode.externalApplication);
    }
  }
}
