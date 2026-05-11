import 'package:flutter_test/flutter_test.dart';
import 'package:nexride_driver/config/rollout_copy.dart';
import 'package:nexride_driver/models/rollout_delivery_region_model.dart';
import 'package:nexride_driver/services/ride_cloud_functions_service.dart';

void main() {
  test('RolloutCopy matches rider rollout gate string', () {
    expect(
      RolloutCopy.notAvailableInArea,
      'NexRide is not available in your area yet.',
    );
  });

  test('parseRolloutRegionsResponse handles items alias', () {
    final regions = parseRolloutRegionsResponse(<String, dynamic>{
      'success': true,
      'items': <Map<String, dynamic>>[
        <String, dynamic>{
          'region_id': 'delta',
          'state': 'Delta',
          'dispatch_market_id': 'delta',
          'cities': <Map<String, dynamic>>[
            <String, dynamic>{
              'city_id': 'warri',
              'display_name': 'Warri',
            },
          ],
        },
      ],
    });
    expect(regions.single.regionId, 'delta');
    expect(regions.single.cities.single.cityId, 'warri');
  });

  test('rideCallableSucceeded for rollout validate map', () {
    expect(rideCallableSucceeded(<String, dynamic>{'success': false}), isFalse);
    expect(rideCallableSucceeded(<String, dynamic>{'success': true}), isTrue);
  });
}
