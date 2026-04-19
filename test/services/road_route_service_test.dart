import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexride/services/road_route_service.dart';

void main() {
  test('road route service prefers Google Directions road polylines', () async {
    final service = RoadRouteService.withConfig(
      client: MockClient((http.Request request) async {
        if (request.url.host == 'maps.googleapis.com') {
          return http.Response(
            '{"status":"OK","routes":[{"overview_polyline":{"points":"_p~iF~ps|U_ulLnnqC_mqNvxq`@"},"legs":[{"distance":{"value":12450},"duration":{"value":1180}}]}]}',
            200,
            headers: const <String, String>{'content-type': 'application/json'},
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
    expect(result.distanceMeters, 12450);
    expect(result.durationSeconds, 1180);
  });

  test(
    'road route service parses route geometry, distance, and duration',
    () async {
      final service = RoadRouteService(
        client: MockClient((http.Request request) async {
          return http.Response(
            '{"code":"Ok","routes":[{"geometry":"_p~iF~ps|U_ulLnnqC_mqNvxq`@","distance":12500.4,"duration":1180.2}]}',
            200,
            headers: const <String, String>{'content-type': 'application/json'},
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
      expect(result.distanceMeters, 12500.4);
      expect(result.durationSeconds, 1180);
    },
  );

  test(
    'road route service returns a retryable error for unavailable routes',
    () async {
      final service = RoadRouteService(
        client: MockClient((http.Request request) async {
          return http.Response('{"code":"NoRoute","routes":[]}', 200);
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
    },
  );
}
