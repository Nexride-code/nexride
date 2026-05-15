import 'package:flutter_test/flutter_test.dart';
import 'package:nexride/models/rollout_delivery_region_model.dart';
import 'package:nexride/services/rollout_catalog_hydration.dart';

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
  test('mergeSavedRolloutWithCatalog restores valid saved selection', () {
    final sel = mergeSavedRolloutWithCatalog(
      regions: _sampleCatalog(),
      saved: <String, String>{
        'rollout_region_id': 'lagos',
        'rollout_city_id': 'ikeja',
        'rollout_dispatch_market_id': 'lagos',
      },
    );
    expect(sel.isComplete, isTrue);
    expect(sel.savedAreaDisabled, isFalse);
    expect(sel.regionId, 'lagos');
  });

  test('mergeSavedRolloutWithCatalog flags disabled saved region', () {
    final sel = mergeSavedRolloutWithCatalog(
      regions: _sampleCatalog(),
      saved: <String, String>{
        'rollout_region_id': 'removed',
        'rollout_city_id': 'x',
        'rollout_dispatch_market_id': 'x',
      },
    );
    expect(sel.isComplete, isFalse);
    expect(sel.savedAreaDisabled, isTrue);
  });

  test('shouldShowRiderRolloutBanner resolves loading then success', () {
    expect(
      shouldShowRiderRolloutBanner(
        catalogLoading: true,
        catalogHydrated: false,
        catalogError: null,
        catalog: const <RolloutDeliveryRegionModel>[],
        selectionComplete: false,
        savedAreaDisabled: false,
      ),
      isTrue,
    );
    expect(
      shouldShowRiderRolloutBanner(
        catalogLoading: false,
        catalogHydrated: true,
        catalogError: null,
        catalog: _sampleCatalog(),
        selectionComplete: true,
        savedAreaDisabled: false,
      ),
      isFalse,
    );
  });

  test('shouldShowRiderRolloutBanner shows empty catalog state', () {
    expect(
      shouldShowRiderRolloutBanner(
        catalogLoading: false,
        catalogHydrated: true,
        catalogError: null,
        catalog: const <RolloutDeliveryRegionModel>[],
        selectionComplete: false,
        savedAreaDisabled: false,
      ),
      isTrue,
    );
  });

  test('shouldShowDriverRolloutBanner hidden in GPS mode', () {
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
