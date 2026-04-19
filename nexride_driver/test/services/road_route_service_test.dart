import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexride_driver/services/road_route_service.dart';

void main() {
  test('driver road route service prefers Google Directions polylines',
      () async {
    final service = RoadRouteService.withConfig(
      client: MockClient((http.Request request) async {
        if (request.url.host == 'maps.googleapis.com') {
          return http.Response(
            '{"status":"OK","routes":[{"overview_polyline":{"points":"_p~iF~ps|U_ulLnnqC_mqNvxq`@"},"legs":[{"distance":{"value":8300},"duration":{"value":840}}]}]}',
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        }
        return http.Response('unexpected fallback', 500);
      }),
      googleDirectionsBaseUri: Uri.parse(
        'https://maps.googleapis.com/maps/api/directions/json',
      ),
      googleMapsApiKey: 'test-key',
      routingBaseUri: Uri.parse('https://routing.example.com'),
    );

    final result = await service.fetchDrivingRoute(
      origin: const LatLng(6.5244, 3.3792),
      destination: const LatLng(6.6018, 3.3515),
    );

    expect(result.hasRoute, isTrue);
    expect(result.points, hasLength(3));
    expect(result.distanceMeters, 8300);
    expect(result.durationSeconds, 840);
  });

  test('driver road route service parses route geometry and metrics', () async {
    final service = RoadRouteService(
      client: MockClient((http.Request request) async {
        return http.Response(
          '{"code":"Ok","routes":[{"geometry":"_p~iF~ps|U_ulLnnqC_mqNvxq`@","distance":8300.0,"duration":840.5}]}',
          200,
          headers: const <String, String>{
            'content-type': 'application/json',
          },
        );
      }),
      routingBaseUri: Uri.parse('https://routing.example.com'),
    );

    final result = await service.fetchDrivingRoute(
      origin: const LatLng(6.5244, 3.3792),
      destination: const LatLng(6.6018, 3.3515),
    );

    expect(result.hasRoute, isTrue);
    expect(result.points, hasLength(3));
    expect(result.distanceMeters, 8300);
    expect(result.durationSeconds, 841);
  });

  test(
      'driver road route service falls back to OSRM when Google Directions is denied',
      () async {
    final service = RoadRouteService.withConfig(
      client: MockClient((http.Request request) async {
        if (request.url.host == 'maps.googleapis.com') {
          return http.Response(
            '{"status":"REQUEST_DENIED","error_message":"API keys with referer restrictions cannot be used with this API."}',
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        }
        return http.Response(
          '{"code":"Ok","routes":[{"geometry":"_p~iF~ps|U_ulLnnqC_mqNvxq`@","distance":8300.0,"duration":840.5}]}',
          200,
          headers: const <String, String>{
            'content-type': 'application/json',
          },
        );
      }),
      googleDirectionsBaseUri: Uri.parse(
        'https://maps.googleapis.com/maps/api/directions/json',
      ),
      googleMapsApiKey: 'restricted-key',
      routingBaseUri: Uri.parse('https://routing.example.com'),
    );

    final result = await service.fetchDrivingRoute(
      origin: const LatLng(6.5244, 3.3792),
      destination: const LatLng(6.6018, 3.3515),
    );

    expect(result.hasRoute, isTrue);
    expect(result.points, hasLength(3));
    expect(result.distanceMeters, 8300);
    expect(result.durationSeconds, 841);
  });

  test(
      'driver road route service returns a safe error when both providers return malformed payloads',
      () async {
    final service = RoadRouteService.withConfig(
      client: MockClient((http.Request request) async {
        if (request.url.host == 'maps.googleapis.com') {
          return http.Response(
            '{"status":"OK","routes":[{"overview_polyline":null,"legs":[{"distance":{},"duration":{}}]}]}',
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        }
        return http.Response(
          '{"code":"Ok","routes":[{"geometry":null,"distance":null,"duration":null}]}',
          200,
          headers: const <String, String>{
            'content-type': 'application/json',
          },
        );
      }),
      googleDirectionsBaseUri: Uri.parse(
        'https://maps.googleapis.com/maps/api/directions/json',
      ),
      googleMapsApiKey: 'test-key',
      routingBaseUri: Uri.parse('https://routing.example.com'),
    );

    final result = await service.fetchDrivingRoute(
      origin: const LatLng(6.5244, 3.3792),
      destination: const LatLng(6.6018, 3.3515),
    );

    expect(result.hasRoute, isFalse);
    expect(result.errorMessage, isNotNull);
    expect(result.points, isEmpty);
  });

  test(
      'driver road route service exposes a retryable error when route lookup fails',
      () async {
    final service = RoadRouteService(
      client: MockClient((http.Request request) async {
        return http.Response('temporary failure', 503);
      }),
      routingBaseUri: Uri.parse('https://routing.example.com'),
    );

    final result = await service.fetchDrivingRoute(
      origin: const LatLng(6.5244, 3.3792),
      destination: const LatLng(6.6018, 3.3515),
    );

    expect(result.hasRoute, isFalse);
    expect(result.errorMessage, isNotNull);
    expect(result.points, isEmpty);
  });
}
