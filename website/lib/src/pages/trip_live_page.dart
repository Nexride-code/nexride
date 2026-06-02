import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
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
  static const LatLng _defaultCenter = LatLng(6.5244, 3.3792);

  final MapController _map = MapController();
  StreamSubscription<DatabaseEvent>? _sub;
  String? _error;
  bool _awaitingFirstSnapshot = true;
  Map<String, dynamic>? _trip;
  bool _loggedMarkersRendered = false;
  bool _loggedRouteRendered = false;
  String? _lastRouteLogKey;
  String? _lastDriverMarkerKey;
  bool _mapReady = false;
  bool _loggedCameraFit = false;
  bool _pendingCameraFit = false;

  @override
  void initState() {
    super.initState();
    debugPrint(
      'LIVE_TRIP_PAGE_INIT rideId=${widget.rideId} token=${widget.token.trim().isNotEmpty}',
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _scheduleMapResize(reason: 'first_frame');
    });
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    final id = Uri.decodeComponent(widget.rideId.trim());
    final token = widget.token.trim();
    if (id.isEmpty || token.isEmpty) {
      setState(() {
        _awaitingFirstSnapshot = false;
        _error =
            'This tracking link is incomplete. Ask the rider to share again, or contact support@nexride.africa.';
      });
      return;
    }

    final ref = FirebaseDatabase.instance.ref('ride_track_public/$token');
    _sub = ref.onValue.listen((event) {
      if (!mounted) {
        return;
      }
      if (!event.snapshot.exists) {
        setState(() {
          _awaitingFirstSnapshot = false;
          _trip = null;
          _error = 'Trip not found or link expired.';
        });
        return;
      }
      final v = event.snapshot.value;
      if (v is! Map) {
        setState(() {
          _awaitingFirstSnapshot = false;
          _trip = null;
          _error = 'Trip not found or link expired.';
        });
        return;
      }
      final raw = Map<String, dynamic>.from(
        v.map((k, val) => MapEntry(k.toString(), val)),
      );
      final rid = raw['ride_id']?.toString().trim() ?? '';
      if (rid.isNotEmpty && rid != id) {
        setState(() {
          _awaitingFirstSnapshot = false;
          _error = 'This link does not match the trip ID in the URL.';
          _trip = null;
        });
        return;
      }

      debugPrint('LIVE_TRIP_PUBLIC_READ_OK rideId=$id token=$token');
      final normalized = _normalizePublicTrip(raw);
      final pickup = _asMap(normalized['pickup']);
      final dest = _asMap(normalized['destination']);
      final live = _asMap(normalized['live_location']);
      final routePreview = _polylinePoints(normalized);
      debugPrint(
        'LIVE_TRIP_DATA_RECEIVED rideId=$id '
        'hasPickup=${_latLngFromMap(pickup) != null} '
        'hasDestination=${_latLngFromMap(dest) != null} '
        'routePoints=${routePreview.points.length} '
        'hasDriver=${_latLngFromMap(live) != null}',
      );
      final driverKey = live == null
          ? null
          : '${live['lat']},${live['lng']}';
      if (driverKey != null && driverKey != _lastDriverMarkerKey) {
        _lastDriverMarkerKey = driverKey;
        debugPrint('LIVE_TRIP_DRIVER_MARKER_UPDATED rideId=$id key=$driverKey');
      }

      setState(() {
        _awaitingFirstSnapshot = false;
        _trip = normalized;
        _error = null;
      });

      _logRenderState(id, normalized);
      _requestCameraFit(rideId: id, reason: 'public_data');
    }, onError: (Object e) {
      if (!mounted) {
        return;
      }
      debugPrint('LIVE_TRIP_PUBLIC_PERMISSION_DENIED rideId=$id error=$e');
      setState(() {
        _awaitingFirstSnapshot = false;
        _error = 'Could not load trip updates. ($e)';
      });
    });
  }

  bool _hasRenderableTripData(Map<String, dynamic> trip) {
    final pickup = _asMap(trip['pickup']);
    final dest = _asMap(trip['destination']);
    final live = _asMap(trip['live_location']);
    return _latLngFromMap(pickup) != null ||
        _latLngFromMap(dest) != null ||
        _latLngFromMap(live) != null ||
        _polylinePoints(trip).points.length >= 2;
  }

  Map<String, dynamic> _normalizePublicTrip(Map<String, dynamic> raw) {
    final pickupObj = _asMap(raw['pickup']);
    final destObj = _asMap(raw['destination']);
    final liveObj = _asMap(raw['live_location']);

    final pickupLat = _d(raw['pickup_lat']) ?? _d(pickupObj?['lat']);
    final pickupLng = _d(raw['pickup_lng']) ?? _d(pickupObj?['lng']);
    final destLat = _d(raw['destination_lat']) ?? _d(destObj?['lat']);
    final destLng = _d(raw['destination_lng']) ?? _d(destObj?['lng']);
    final driverLat =
        _d(raw['driver_lat']) ?? _d(liveObj?['lat']);
    final driverLng =
        _d(raw['driver_lng']) ?? _d(liveObj?['lng']);

    Map<String, dynamic>? route = _asMap(raw['route']);
    if (route == null && raw['route_path'] is List) {
      route = <String, dynamic>{'path': raw['route_path']};
    }

    return <String, dynamic>{
      ...raw,
      'status': raw['trip_status'] ?? raw['trip_phase'] ?? raw['status'],
      'pickup': <String, dynamic>{
        'lat': pickupLat,
        'lng': pickupLng,
        'address': raw['pickup_area'] ?? pickupObj?['address'] ?? 'Pickup',
      },
      'destination': <String, dynamic>{
        'lat': destLat,
        'lng': destLng,
        'address': raw['dropoff_area'] ?? destObj?['address'] ?? 'Drop-off',
      },
      'live_location': driverLat != null && driverLng != null
          ? <String, dynamic>{
              'lat': driverLat,
              'lng': driverLng,
              'heading': raw['driver_heading'] ?? liveObj?['heading'],
            }
          : null,
      'route': route,
      'driver': <String, dynamic>{
        'name': raw['driver_first_name'] ?? raw['driver_name'] ?? 'Driver',
        'car': raw['vehicle_label'] ?? '',
      },
      'eta_min': raw['eta_min'],
    };
  }

  void _logRenderState(String rideId, Map<String, dynamic> trip) {
    final pickup = _asMap(trip['pickup']);
    final dest = _asMap(trip['destination']);
    final live = _asMap(trip['live_location']);
    final hasMarker = _latLngFromMap(pickup) != null ||
        _latLngFromMap(dest) != null ||
        _latLngFromMap(live) != null;
    if (!_loggedMarkersRendered && hasMarker) {
      _loggedMarkersRendered = true;
      debugPrint('LIVE_TRIP_MARKERS_RENDERED rideId=$rideId');
    }
    final route = _polylinePoints(trip);
    final routeKey = '${route.points.length}:${route.source}';
    if (route.points.length >= 2 && routeKey != _lastRouteLogKey) {
      _lastRouteLogKey = routeKey;
      if (!_loggedRouteRendered) {
        _loggedRouteRendered = true;
      }
      debugPrint(
        'LIVE_TRIP_ROUTE_RENDERED rideId=$rideId '
        'points=${route.points.length} source=${route.source}',
      );
      _requestCameraFit(rideId: rideId, reason: 'route_rendered');
    }
  }

  void _requestCameraFit({required String rideId, required String reason}) {
    if (!_mapReady) {
      _pendingCameraFit = true;
      return;
    }
    _scheduleMapResize(reason: reason, rideId: rideId);
  }

  void _scheduleMapResize({required String reason, String? rideId}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _triggerMapResize(reason: reason, rideId: rideId);
    });
    Future<void>.delayed(const Duration(milliseconds: 120), () {
      if (!mounted) {
        return;
      }
      _triggerMapResize(reason: '${reason}_delayed', rideId: rideId);
    });
  }

  void _triggerMapResize({required String reason, String? rideId}) {
    debugPrint(
      'LIVE_TRIP_MAP_RESIZE_TRIGGERED rideId=${rideId ?? widget.rideId} reason=$reason mapReady=$_mapReady',
    );
    _fitMap(rideId: rideId);
  }

  void _fitMap({String? rideId}) {
    if (!_mapReady) {
      _pendingCameraFit = true;
      return;
    }
    final pts = _cameraFitPoints();
    if (pts.isEmpty) {
      return;
    }
    try {
      if (pts.length == 1) {
        _map.move(pts.first, 14);
      } else {
        final b = LatLngBounds.fromPoints(pts);
        _map.fitCamera(
          CameraFit.bounds(bounds: b, padding: const EdgeInsets.all(48)),
        );
      }
      if (!_loggedCameraFit) {
        _loggedCameraFit = true;
        debugPrint(
          'LIVE_TRIP_CAMERA_FIT_OK rideId=${rideId ?? widget.rideId} points=${pts.length}',
        );
      }
    } catch (error) {
      debugPrint(
        'LIVE_TRIP_CAMERA_FIT_FAIL rideId=${rideId ?? widget.rideId} error=$error',
      );
    }
  }

  /// Camera fit prefers pickup + destination + driver; route points omitted to avoid over-zoom.
  List<LatLng> _cameraFitPoints() {
    final out = <LatLng>[];
    void addLatLng(double? la, double? ln) {
      if (la != null && ln != null) {
        out.add(LatLng(la, ln));
      }
    }

    final pickup = _asMap(_trip?['pickup']);
    final dest = _asMap(_trip?['destination']);
    final live = _asMap(_trip?['live_location']);
    addLatLng(_d(pickup?['lat']), _d(pickup?['lng']));
    addLatLng(_d(dest?['lat']), _d(dest?['lng']));
    addLatLng(_d(live?['lat']), _d(live?['lng']));
    return out;
  }

  void _onMapReady() {
    if (_mapReady) {
      return;
    }
    _mapReady = true;
    debugPrint('LIVE_TRIP_MAP_READY rideId=${widget.rideId}');
    if (_pendingCameraFit || _trip != null) {
      _pendingCameraFit = false;
      _scheduleMapResize(reason: 'map_ready');
    }
  }

  Map<String, dynamic>? _asMap(dynamic v) {
    if (v is! Map) {
      return null;
    }
    return v.map((k, val) => MapEntry(k.toString(), val));
  }

  double? _d(dynamic v) {
    if (v is num) {
      return v.toDouble();
    }
    if (v is String) {
      return double.tryParse(v.trim());
    }
    return null;
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel() ?? Future<void>.value());
    super.dispose();
  }

  Widget _buildMapSkeleton() {
    return Container(
      color: const Color(0xFFE8EAED),
      alignment: Alignment.center,
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.6),
          ),
          SizedBox(height: 12),
          Text('Loading live map…'),
        ],
      ),
    );
  }

  bool get _showMapLoadingOverlay =>
      _trip == null && (_awaitingFirstSnapshot || !_mapReady);

  @override
  Widget build(BuildContext context) {
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

    final trip = _trip ?? const <String, dynamic>{};
    final status = trip['status']?.toString() ?? '—';
    final expiresAt = _asInt(trip['expires_at']) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    final expired = expiresAt > 0 && now > expiresAt;
    final terminal = _isTerminalStatus(status);

    final pickup = _asMap(trip['pickup']);
    final dest = _asMap(trip['destination']);
    final live = _asMap(trip['live_location']);
    final driver = _asMap(trip['driver']);
    final fitPts = _cameraFitPoints();
    final center = fitPts.isNotEmpty ? fitPts.first : _defaultCenter;
    final routeResult = _polylinePoints(trip);
    final routePoints = routeResult.points;
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
          if (_awaitingFirstSnapshot && _trip == null)
            const LinearProgressIndicator(minHeight: 2),
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
                      Chip(
                        label: Text(
                          _trip == null ? 'Connecting…' : status,
                        ),
                      ),
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
                  if (driver != null && _trip != null)
                    Text(
                      'Driver: ${_text(driver['name'])} · ${_text(driver['car'])} ${_text(driver['plate'])}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  if (_awaitingFirstSnapshot && _trip == null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Connecting to live trip…',
                        style: Theme.of(context).textTheme.bodySmall,
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
            child: Stack(
              fit: StackFit.expand,
              children: [
                FlutterMap(
                      mapController: _map,
                      options: MapOptions(
                        initialCenter: center,
                        initialZoom: fitPts.isEmpty ? 12 : (fitPts.length == 1 ? 14 : 13),
                        onMapReady: _onMapReady,
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
                        if (routePoints.length >= 2)
                          PolylineLayer(
                            polylines: [
                              Polyline(
                                points: routePoints,
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
                                child: const Icon(
                                  Icons.trip_origin,
                                  color: Colors.blue,
                                ),
                              ),
                            if (_latLngFromMap(dest) != null)
                              Marker(
                                point: _latLngFromMap(dest)!,
                                width: 36,
                                height: 36,
                                child: const Icon(
                                  Icons.place,
                                  color: Colors.red,
                                ),
                              ),
                            if (_latLngFromMap(live) != null)
                              Marker(
                                point: _latLngFromMap(live)!,
                                width: 40,
                                height: 40,
                                child: const Icon(
                                  Icons.local_taxi,
                                  color: Colors.black87,
                                ),
                              ),
                          ],
                        ),
                        RichAttributionWidget(
                          attributions: [
                            TextSourceAttribution(
                              '© OpenStreetMap · CARTO',
                              onTap: () => launchUrl(
                                Uri.parse(
                                  'https://www.openstreetmap.org/copyright',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    if (_showMapLoadingOverlay)
                      Positioned.fill(child: _buildMapSkeleton()),
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

  ({List<LatLng> points, String source}) _polylinePoints(Map<String, dynamic> trip) {
    final route = _asMap(trip['route']);
    if (route != null) {
      final path = route['path'];
      if (path is List) {
        final out = <LatLng>[];
        for (final p in path) {
          if (p is Map) {
            final la = _d(p['lat'] ?? p['latitude']);
            final ln = _d(p['lng'] ?? p['longitude']);
            if (la != null && ln != null) {
              out.add(LatLng(la, ln));
            }
          }
        }
        if (out.length >= 2) {
          return (points: out, source: 'route_path');
        }
      }
    }
    if (trip['route_path'] is List) {
      final out = <LatLng>[];
      for (final p in trip['route_path'] as List) {
        if (p is Map) {
          final la = _d(p['lat'] ?? p['latitude']);
          final ln = _d(p['lng'] ?? p['longitude']);
          if (la != null && ln != null) {
            out.add(LatLng(la, ln));
          }
        }
      }
      if (out.length >= 2) {
        return (points: out, source: 'route_path');
      }
    }
    final pickup = _latLngFromMap(_asMap(trip['pickup']));
    final dest = _latLngFromMap(_asMap(trip['destination']));
    if (pickup != null && dest != null) {
      return (points: <LatLng>[pickup, dest], source: 'fallback');
    }
    return (points: const <LatLng>[], source: 'none');
  }

  LatLng? _latLngFromMap(Map<String, dynamic>? m) {
    if (m == null) {
      return null;
    }
    final la = _d(m['lat']);
    final ln = _d(m['lng']);
    if (la == null || ln == null) {
      return null;
    }
    return LatLng(la, ln);
  }

  int? _estimateEtaMinutes(
    Map<String, dynamic>? live,
    Map<String, dynamic>? dest,
    bool terminal,
  ) {
    if (terminal) {
      return null;
    }
    final d = _latLngFromMap(dest);
    final l = _latLngFromMap(live);
    if (d == null || l == null) {
      return null;
    }
    final meters = const Distance().as(LengthUnit.Meter, l, d);
    const speedKmh = 28.0;
    final hours = (meters / 1000) / speedKmh;
    final mins = (hours * 60).round();
    if (mins <= 0 || mins > 240) {
      return null;
    }
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
    if (v is int) {
      return v;
    }
    if (v is num) {
      return v.toInt();
    }
    return null;
  }

  String _placeLine(String label, Map<String, dynamic>? m) {
    if (m == null) {
      return '$label: —';
    }
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
      if (s.isNotEmpty) {
        return s;
      }
    }
    return '';
  }

  Future<void> _openInRiderApp() async {
    final id = Uri.decodeComponent(widget.rideId.trim());
    final t = widget.token.trim();
    final app = Uri.parse(
      'nexride://trip?rideId=${Uri.encodeComponent(id)}'
      '&token=${Uri.encodeComponent(t)}',
    );
    if (await canLaunchUrl(app)) {
      await launchUrl(app, mode: LaunchMode.externalApplication);
    }
  }
}
