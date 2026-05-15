import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

class RoadRouteResult {
  const RoadRouteResult({
    required this.points,
    required this.distanceMeters,
    required this.durationSeconds,
    this.errorMessage,
  });

  const RoadRouteResult.error(String this.errorMessage)
      : points = const <LatLng>[],
        distanceMeters = 0,
        durationSeconds = 0;

  final List<LatLng> points;
  final double distanceMeters;
  final int durationSeconds;
  final String? errorMessage;

  bool get hasRoute =>
      errorMessage == null && points.length >= 2 && distanceMeters > 0;
}

class RoadRouteService {
  RoadRouteService({
    http.Client? client,
    Uri? routingBaseUri,
  }) : this.withConfig(
          client: client,
          routingBaseUri: routingBaseUri,
        );

  RoadRouteService.withConfig({
    http.Client? client,
    Uri? routingBaseUri,
    Uri? googleDirectionsBaseUri,
    String? googleMapsApiKey,
  })  : _client = client ?? http.Client(),
        _routingBaseUri = routingBaseUri ?? _defaultRoutingBaseUri,
        _googleDirectionsBaseUri =
            googleDirectionsBaseUri ?? _defaultGoogleDirectionsBaseUri,
        _googleMapsApiKey =
            (googleMapsApiKey ?? _defaultGoogleMapsApiKey).trim();

  static final Uri _defaultRoutingBaseUri = Uri.parse(
    const String.fromEnvironment(
      'NEXRIDE_ROUTING_BASE_URL',
      defaultValue: 'https://router.project-osrm.org',
    ),
  );
  static final Uri _defaultGoogleDirectionsBaseUri = Uri.parse(
    const String.fromEnvironment(
      'NEXRIDE_GOOGLE_DIRECTIONS_BASE_URL',
      defaultValue: 'https://maps.googleapis.com/maps/api/directions/json',
    ),
  );
  static const String _defaultGoogleMapsApiKey = String.fromEnvironment(
    'NEXRIDE_GOOGLE_MAPS_API_KEY',
    defaultValue: 'AIzaSyDPk-B9EoqGsYkvxS5aiiTWl1S-cezWsos',
  );

  static const Duration _requestTimeout = Duration(seconds: 12);
  static const String _routeUnavailableMessage =
      'Route preview is reconnecting. Retry to refresh the live road path.';

  final http.Client _client;
  final Uri _routingBaseUri;
  final Uri _googleDirectionsBaseUri;
  final String _googleMapsApiKey;

  Future<RoadRouteResult> fetchDrivingRoute({
    required LatLng origin,
    required LatLng destination,
  }) async {
    try {
      final googleResult = await _safeFetchRoute(
        provider: 'google',
        action: () => _fetchGoogleDrivingRoute(
          origin: origin,
          destination: destination,
        ),
      );
      if (googleResult.hasRoute) {
        return googleResult;
      }

      debugPrint(
        '[DriverRoadRouteService] Google route unavailable, retrying with OSRM fallback error=${googleResult.errorMessage}',
      );

      final osrmResult = await _safeFetchRoute(
        provider: 'osrm',
        action: () => _fetchOsrmDrivingRoute(
          origin: origin,
          destination: destination,
        ),
      );
      if (osrmResult.hasRoute) {
        return osrmResult;
      }

      return osrmResult.errorMessage != null ? osrmResult : googleResult;
    } catch (error) {
      debugPrint('[DriverRoadRouteService] route fetch wrapper error=$error');
      return const RoadRouteResult.error(_routeUnavailableMessage);
    }
  }

  void dispose() {
    _client.close();
  }

  Future<RoadRouteResult> _safeFetchRoute({
    required String provider,
    required Future<RoadRouteResult> Function() action,
  }) async {
    try {
      final result = await action();
      if (result.hasRoute) {
        return result;
      }
      return RoadRouteResult.error(
        result.errorMessage ?? _routeUnavailableMessage,
      );
    } catch (error) {
      debugPrint(
        '[DriverRoadRouteService] $provider route fetch error=$error',
      );
      return const RoadRouteResult.error(_routeUnavailableMessage);
    }
  }

  Future<RoadRouteResult> _fetchGoogleDrivingRoute({
    required LatLng origin,
    required LatLng destination,
  }) async {
    if (_googleMapsApiKey.isEmpty) {
      return const RoadRouteResult.error(_routeUnavailableMessage);
    }

    final requestUri = _buildGoogleDirectionsUri(
      origin: origin,
      destination: destination,
    );
    debugPrint(
      '[DriverRoadRouteService] google request uri=$requestUri origin=${origin.latitude},${origin.longitude} destination=${destination.latitude},${destination.longitude}',
    );

    try {
      final response = await _client.get(
        requestUri,
        headers: const <String, String>{'Accept': 'application/json'},
      ).timeout(_requestTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint(
          '[DriverRoadRouteService] google request failed status=${response.statusCode} body=${response.body}',
        );
        return const RoadRouteResult.error(_routeUnavailableMessage);
      }

      final decoded = _safeJsonMapDecode(
        response.body,
        provider: 'google',
      );
      if (decoded == null) {
        debugPrint(
          '[DriverRoadRouteService] google invalid response payload body=${response.body}',
        );
        return const RoadRouteResult.error(_routeUnavailableMessage);
      }

      final status = decoded['status']?.toString() ?? '';
      final route = _firstRouteMap(decoded['routes']);
      if (status != 'OK' || route == null) {
        final errorMessage = _firstText(<dynamic>[
          decoded['error_message'],
          decoded['status'],
        ]);
        debugPrint(
          '[DriverRoadRouteService] google route unavailable status=$status error=$errorMessage payload=${response.body}',
        );
        return const RoadRouteResult.error(_routeUnavailableMessage);
      }

      final encodedPolyline = _firstText(<dynamic>[
        _mapValue(route['overview_polyline'], 'points'),
        _mapValue(route['overviewPolyline'], 'points'),
      ]);
      final decodedPoints = _decodePolylineSafely(
        encodedPolyline,
        provider: 'google',
      );
      final legs = _asList(route['legs']);
      final distanceMeters = _sumLegValue(
        legs,
        primaryKey: 'distance',
        nestedValueKey: 'value',
      );
      final durationSeconds = _sumLegDurationSeconds(legs);

      if (decodedPoints.length < 2 ||
          distanceMeters <= 0 ||
          durationSeconds <= 0) {
        debugPrint(
          '[DriverRoadRouteService] google empty route points=${decodedPoints.length} distance=$distanceMeters duration=$durationSeconds',
        );
        return const RoadRouteResult.error(_routeUnavailableMessage);
      }

      return RoadRouteResult(
        points: decodedPoints,
        distanceMeters: distanceMeters,
        durationSeconds: durationSeconds,
      );
    } on TimeoutException catch (error) {
      debugPrint(
          '[DriverRoadRouteService] google request timeout error=$error');
      return const RoadRouteResult.error(_routeUnavailableMessage);
    } catch (error) {
      debugPrint('[DriverRoadRouteService] google request error=$error');
      return const RoadRouteResult.error(_routeUnavailableMessage);
    }
  }

  Future<RoadRouteResult> _fetchOsrmDrivingRoute({
    required LatLng origin,
    required LatLng destination,
  }) async {
    final requestUri = _buildRouteUri(origin: origin, destination: destination);
    debugPrint(
      '[DriverRoadRouteService] osrm request uri=$requestUri origin=${origin.latitude},${origin.longitude} destination=${destination.latitude},${destination.longitude}',
    );

    try {
      final response = await _client.get(
        requestUri,
        headers: const <String, String>{'Accept': 'application/json'},
      ).timeout(_requestTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint(
          '[DriverRoadRouteService] request failed status=${response.statusCode} body=${response.body}',
        );
        return const RoadRouteResult.error(_routeUnavailableMessage);
      }

      final decoded = _safeJsonMapDecode(
        response.body,
        provider: 'osrm',
      );
      if (decoded == null) {
        debugPrint(
          '[DriverRoadRouteService] invalid response payload body=${response.body}',
        );
        return const RoadRouteResult.error(_routeUnavailableMessage);
      }

      final code = decoded['code']?.toString() ?? '';
      final route = _firstRouteMap(decoded['routes']);
      if (code != 'Ok' || route == null) {
        debugPrint(
          '[DriverRoadRouteService] route unavailable code=$code payload=${response.body}',
        );
        return const RoadRouteResult.error(_routeUnavailableMessage);
      }

      final encodedPolyline = route['geometry']?.toString() ?? '';
      final decodedPoints = _decodePolylineSafely(
        encodedPolyline,
        provider: 'osrm',
      );
      final distanceMeters = _asDouble(route['distance']);
      final durationSeconds = _asInt(route['duration']);

      if (decodedPoints.length < 2 ||
          distanceMeters <= 0 ||
          durationSeconds <= 0) {
        debugPrint(
          '[DriverRoadRouteService] empty route points=${decodedPoints.length} distance=$distanceMeters duration=$durationSeconds',
        );
        return const RoadRouteResult.error(_routeUnavailableMessage);
      }

      return RoadRouteResult(
        points: decodedPoints,
        distanceMeters: distanceMeters,
        durationSeconds: durationSeconds,
      );
    } on TimeoutException catch (error) {
      debugPrint('[DriverRoadRouteService] request timeout error=$error');
      return const RoadRouteResult.error(_routeUnavailableMessage);
    } catch (error) {
      debugPrint('[DriverRoadRouteService] request error=$error');
      return const RoadRouteResult.error(_routeUnavailableMessage);
    }
  }

  Uri _buildGoogleDirectionsUri({
    required LatLng origin,
    required LatLng destination,
  }) {
    return _googleDirectionsBaseUri.replace(
      queryParameters: <String, String>{
        'origin': '${origin.latitude},${origin.longitude}',
        'destination': '${destination.latitude},${destination.longitude}',
        'mode': 'driving',
        'region': 'ng',
        'key': _googleMapsApiKey,
      },
    );
  }

  Uri _buildRouteUri({
    required LatLng origin,
    required LatLng destination,
  }) {
    final basePath = _routingBaseUri.path.endsWith('/')
        ? _routingBaseUri.path.substring(0, _routingBaseUri.path.length - 1)
        : _routingBaseUri.path;
    final routePath = '$basePath/route/v1/driving/'
        '${origin.longitude},${origin.latitude};'
        '${destination.longitude},${destination.latitude}';

    return _routingBaseUri.replace(
      path: routePath,
      queryParameters: const <String, String>{
        'overview': 'full',
        'geometries': 'polyline',
        'steps': 'false',
      },
    );
  }

  static double _asDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  static int _asInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.round();
    }
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static dynamic _mapValue(dynamic value, String key) {
    if (value is Map) {
      return value[key];
    }
    return null;
  }

  static Map<String, dynamic>? _safeJsonMapDecode(
    String body, {
    required String provider,
  }) {
    final String trimmed = body.trimLeft();
    if (trimmed.startsWith('<')) {
      debugPrint(
        '[DriverRoadRouteService] $provider expected JSON but got HTML '
        '(body starts with "<").',
      );
      return null;
    }
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.map<String, dynamic>(
          (dynamic key, dynamic value) => MapEntry(key.toString(), value),
        );
      }
    } catch (error) {
      debugPrint(
        '[DriverRoadRouteService] $provider json decode error=$error',
      );
    }

    return null;
  }

  static List<dynamic> _asList(dynamic value) {
    if (value is List) {
      return value;
    }
    return const <dynamic>[];
  }

  static Map<String, dynamic>? _firstRouteMap(dynamic rawRoutes) {
    final routes = _asList(rawRoutes);
    if (routes.isEmpty) {
      return null;
    }

    final first = routes.first;
    if (first is Map<String, dynamic>) {
      return first;
    }
    if (first is Map) {
      return first.map<String, dynamic>(
        (dynamic key, dynamic value) => MapEntry(key.toString(), value),
      );
    }
    return null;
  }

  static List<LatLng> _decodePolylineSafely(
    String encodedPolyline, {
    required String provider,
  }) {
    final normalizedPolyline = encodedPolyline.trim();
    if (normalizedPolyline.isEmpty) {
      return const <LatLng>[];
    }

    try {
      return PolylinePoints()
          .decodePolyline(normalizedPolyline)
          .map((PointLatLng point) => LatLng(point.latitude, point.longitude))
          .toList(growable: false);
    } catch (error) {
      debugPrint(
        '[DriverRoadRouteService] $provider polyline decode error=$error',
      );
      return const <LatLng>[];
    }
  }

  static String _firstText(Iterable<dynamic> values) {
    for (final value in values) {
      final normalized = value?.toString().trim() ?? '';
      if (normalized.isNotEmpty) {
        return normalized;
      }
    }
    return '';
  }

  static double _sumLegValue(
    List<dynamic> legs, {
    required String primaryKey,
    required String nestedValueKey,
  }) {
    var total = 0.0;
    for (final leg in legs) {
      if (leg is! Map) {
        continue;
      }
      final nested = leg[primaryKey];
      if (nested is Map) {
        total += _asDouble(nested[nestedValueKey]);
      }
    }
    return total;
  }

  static int _sumLegDurationSeconds(List<dynamic> legs) {
    var total = 0;
    for (final leg in legs) {
      if (leg is! Map) {
        continue;
      }
      final durationInTraffic = leg['duration_in_traffic'];
      final duration = leg['duration'];
      if (durationInTraffic is Map) {
        total += _asInt(durationInTraffic['value']);
        continue;
      }
      if (duration is Map) {
        total += _asInt(duration['value']);
      }
    }
    return total;
  }
}
