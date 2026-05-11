import 'package:flutter_test/flutter_test.dart';
import 'package:nexride/config/rollout_copy.dart';
import 'package:nexride/models/rollout_delivery_region_model.dart';
import 'package:nexride/services/rider_ride_cloud_functions_service.dart';

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

  test('unsupported rollout validate response fails callable check', () {
    expect(
      riderRideCallableSucceeded(<String, dynamic>{'success': false}),
      isFalse,
    );
    expect(
      riderRideCallableSucceeded(<String, dynamic>{'success': true}),
      isTrue,
    );
  });
}
