import 'package:flutter_test/flutter_test.dart';
import 'package:nexride_driver/models/rollout_delivery_region_model.dart';
import 'package:nexride_driver/services/rollout_catalog_hydration.dart';

List<RolloutDeliveryRegionModel> _sampleCatalog() {
  return <RolloutDeliveryRegionModel>[
    const RolloutDeliveryRegionModel(
      regionId: 'lagos',
      stateLabel: 'Lagos',
      dispatchMarketId: 'lagos',
      supportsRides: true,
      supportsFood: true,
      supportsPackage: true,
      cities: <RolloutDeliveryCityModel>[
        RolloutDeliveryCityModel(
          cityId: 'ikeja',
          displayName: 'Ikeja',
          supportsRides: true,
          supportsFood: true,
          supportsPackage: true,
        ),
      ],
    ),
  ];
}

void main() {
  test('driver GPS mode does not require rollout banner', () {
    expect(
      shouldShowDriverRolloutBanner(
        pendingAvailabilityMode: 'current_location',
        catalogLoading: true,
        catalogHydrated: false,
        catalogError: null,
        catalog: const <RolloutDeliveryRegionModel>[],
        selectionComplete: false,
        savedAreaDisabled: false,
      ),
      isFalse,
    );
  });

  test('driver area mode shows banner when selection incomplete', () {
    expect(
      shouldShowDriverRolloutBanner(
        pendingAvailabilityMode: 'service_area',
        catalogLoading: false,
        catalogHydrated: true,
        catalogError: null,
        catalog: _sampleCatalog(),
        selectionComplete: false,
        savedAreaDisabled: false,
      ),
      isTrue,
    );
  });
}
