import 'package:flutter_test/flutter_test.dart';
import 'package:nexride/config/rollout_copy.dart';
import 'package:nexride/models/rollout_delivery_region_model.dart';
import 'package:nexride/services/rider_ride_cloud_functions_service.dart'
    show riderRideCallableUserMessage;

void main() {
  test('RolloutCopy.notAvailableInArea is exact backend-facing string', () {
    expect(
      RolloutCopy.notAvailableInArea,
      'NexRide is not available in your area yet.',
    );
  });

  test('parseRolloutRegionsResponse reads nested cities', () {
    final regions = parseRolloutRegionsResponse(<String, dynamic>{
      'success': true,
      'regions': <Map<String, dynamic>>[
        <String, dynamic>{
          'region_id': 'lagos',
          'state': 'Lagos',
          'dispatch_market_id': 'lagos',
          'supports_rides': true,
          'cities': <Map<String, dynamic>>[
            <String, dynamic>{
              'city_id': 'ikeja',
              'display_name': 'Ikeja',
              'supports_rides': true,
            },
          ],
        },
      ],
    });
    expect(regions.length, 1);
    expect(regions.first.regionId, 'lagos');
    expect(regions.first.cities.length, 1);
    expect(regions.first.cities.first.cityId, 'ikeja');
  });

  test('parseRolloutRegionsResponse reads city service bubble fields', () {
    final regions = parseRolloutRegionsResponse(<String, dynamic>{
      'success': true,
      'regions': <Map<String, dynamic>>[
        <String, dynamic>{
          'region_id': 'lagos',
          'state': 'Lagos',
          'dispatch_market_id': 'lagos',
          'supports_rides': true,
          'cities': <Map<String, dynamic>>[
            <String, dynamic>{
              'city_id': 'ikeja',
              'display_name': 'Ikeja',
              'supports_rides': true,
              'center_lat': 6.6018,
              'center_lng': 3.3515,
              'service_radius_km': 22,
            },
          ],
        },
      ],
    });
    expect(regions.first.cities.first.centerLat, 6.6018);
    expect(regions.first.cities.first.serviceRadiusKm, 22);
  });

  test('matchRideAreaForPickupCoordinates prefers closest city center', () {
    const regions = <RolloutDeliveryRegionModel>[
      RolloutDeliveryRegionModel(
        regionId: 'lagos',
        stateLabel: 'Lagos',
        dispatchMarketId: 'lagos',
        supportsRides: true,
        supportsFood: true,
        supportsPackage: true,
        cities: <RolloutDeliveryCityModel>[
          RolloutDeliveryCityModel(
            cityId: 'wide',
            displayName: 'Wide',
            supportsRides: true,
            supportsFood: true,
            supportsPackage: true,
            centerLat: 10,
            centerLng: 10,
            serviceRadiusKm: 100,
          ),
          RolloutDeliveryCityModel(
            cityId: 'narrow',
            displayName: 'Narrow',
            supportsRides: true,
            supportsFood: true,
            supportsPackage: true,
            centerLat: 10.04,
            centerLng: 10.04,
            serviceRadiusKm: 12,
          ),
        ],
      ),
    ];
    final m = matchRideAreaForPickupCoordinates(
      regions,
      lat: 10.05,
      lng: 10.05,
    );
    expect(m, isNotNull);
    expect(m!.cityId, 'narrow');
  });

  test('rolloutCatalogSourceFromResponse reads listDeliveryRegions source', () {
    expect(
      rolloutCatalogSourceFromResponse(<String, dynamic>{
        'success': true,
        'source': 'firestore',
        'regions': <dynamic>[],
      }),
      'firestore',
    );
    expect(
      rolloutCatalogSourceFromResponse(<String, dynamic>{
        'success': true,
        'source': 'seed_fallback',
      }),
      'seed_fallback',
    );
    expect(rolloutCatalogSourceFromResponse(<String, dynamic>{'success': false}), null);
  });

  test('riderRideCallableUserMessage prefers server message and hides secret errors', () {
    expect(
      riderRideCallableUserMessage(<String, dynamic>{
        'success': false,
        'message': 'Custom friendly',
      }),
      'Custom friendly',
    );
    expect(
      riderRideCallableUserMessage(<String, dynamic>{
        'success': false,
        'reason': 'flutterwave_secret_missing',
        'reason_code': 'flutterwave_secret_not_in_runtime',
      }),
      contains('Payment provider'),
    );
  });
}
