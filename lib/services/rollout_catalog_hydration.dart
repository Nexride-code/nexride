import '../models/rollout_delivery_region_model.dart';

/// Timeouts so service-area UI never blocks on Firestore/callables indefinitely.
const Duration kRolloutCatalogCallableTimeout = Duration(seconds: 22);
const Duration kRolloutProfileFetchTimeout = Duration(seconds: 12);

/// Merged rollout selection after catalog + saved profile.
class RolloutCatalogSelection {
  const RolloutCatalogSelection({
    this.regionId,
    this.cityId,
    this.dispatchMarketId,
    this.savedAreaDisabled = false,
  });

  final String? regionId;
  final String? cityId;
  final String? dispatchMarketId;
  final bool savedAreaDisabled;

  bool get isComplete =>
      (regionId ?? '').trim().isNotEmpty &&
      (cityId ?? '').trim().isNotEmpty &&
      (dispatchMarketId ?? '').trim().isNotEmpty;
}

/// Applies saved Firestore/RTDB rollout ids to a fresh [listDeliveryRegions] catalog.
RolloutCatalogSelection mergeSavedRolloutWithCatalog({
  required List<RolloutDeliveryRegionModel> regions,
  Map<String, String>? saved,
  String regionKey = 'rollout_region_id',
  String cityKey = 'rollout_city_id',
  String dispatchKey = 'rollout_dispatch_market_id',
}) {
  var rid = saved?[regionKey]?.trim() ?? '';
  var cid = saved?[cityKey]?.trim() ?? '';
  var dm = saved?[dispatchKey]?.trim() ?? '';
  var savedDisabled = false;

  if (rid.isNotEmpty) {
    if (regions.any((r) => r.regionId == rid)) {
      final reg = regions.firstWhere((r) => r.regionId == rid);
      if (!reg.cities.any((c) => c.cityId == cid)) {
        cid = '';
      }
      if (reg.dispatchMarketId.trim().isNotEmpty) {
        dm = reg.dispatchMarketId.trim();
      }
    } else {
      savedDisabled = true;
      rid = '';
      cid = '';
      dm = '';
    }
  } else {
    rid = '';
    cid = '';
    dm = '';
  }

  return RolloutCatalogSelection(
    regionId: rid.isEmpty ? null : rid,
    cityId: cid.isEmpty ? null : cid,
    dispatchMarketId: dm.isEmpty ? null : dm,
    savedAreaDisabled: savedDisabled,
  );
}

bool shouldShowRiderRolloutBanner({
  required bool catalogLoading,
  required bool catalogHydrated,
  required Object? catalogError,
  required List<RolloutDeliveryRegionModel> catalog,
  required bool selectionComplete,
  required bool savedAreaDisabled,
  bool bannerDismissed = false,
}) {
  if (bannerDismissed) {
    return false;
  }
  if (catalogLoading) {
    return true;
  }
  if (catalogError != null) {
    return true;
  }
  if (!catalogHydrated) {
    return true;
  }
  if (catalog.isEmpty) {
    return true;
  }
  if (savedAreaDisabled) {
    return true;
  }
  if (!selectionComplete) {
    return true;
  }
  return false;
}

/// Driver map banner: GPS mode does not require a saved rollout area.
bool shouldShowDriverRolloutBanner({
  required String pendingAvailabilityMode,
  required bool catalogLoading,
  required bool catalogHydrated,
  required Object? catalogError,
  required List<RolloutDeliveryRegionModel> catalog,
  required bool selectionComplete,
  required bool savedAreaDisabled,
  bool bannerDismissed = false,
}) {
  if (bannerDismissed) {
    return false;
  }
  final mode = pendingAvailabilityMode.trim().toLowerCase();
  if (mode != 'service_area' && mode != 'area' && mode != 'city') {
    return false;
  }
  return shouldShowRiderRolloutBanner(
    catalogLoading: catalogLoading,
    catalogHydrated: catalogHydrated,
    catalogError: catalogError,
    catalog: catalog,
    selectionComplete: selectionComplete,
    savedAreaDisabled: savedAreaDisabled,
    bannerDismissed: false,
  );
}

String riderRolloutBannerTitle({
  required bool catalogLoading,
  required Object? catalogError,
  required bool catalogHydrated,
  required bool catalogEmpty,
  required bool savedAreaDisabled,
  required bool selectionComplete,
}) {
  if (catalogLoading) {
    return 'Loading service areas…';
  }
  if (catalogError != null) {
    return 'Could not load areas';
  }
  if (catalogHydrated && catalogEmpty) {
    return 'No service areas available';
  }
  if (savedAreaDisabled) {
    return 'Your saved area is no longer available';
  }
  if (!selectionComplete) {
    return 'Service area required';
  }
  return 'Service area';
}

String driverRolloutBannerTitle({
  required bool catalogLoading,
  required Object? catalogError,
  required bool catalogHydrated,
  required bool catalogEmpty,
  required bool savedAreaDisabled,
  required bool selectionComplete,
}) {
  if (catalogLoading) {
    return 'Loading service areas…';
  }
  if (catalogError != null) {
    return 'Could not load areas';
  }
  if (catalogHydrated && catalogEmpty) {
    return 'No service areas available';
  }
  if (savedAreaDisabled) {
    return 'Your saved area is no longer available';
  }
  if (!selectionComplete) {
    return 'Service area required (Area mode)';
  }
  return 'Operating area';
}
