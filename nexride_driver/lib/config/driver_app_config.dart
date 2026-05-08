class DriverFeatureFlags {
  static const bool driverVerificationRequired = false;

  /// When true, `users/{uid}/kyc_status/kyc_approved` (or `kyc_admin_override`)
  /// is required before GO ONLINE. Admins can set approval in the Firebase console.
  static const bool driverKycGateEnabled = true;

  /// Phase 1: car rides only (no dispatch / mart / food offers).
  static const Set<String> activeRequestServiceTypes = <String>{
    'ride',
    'dispatch_delivery',
  };

  static bool serviceCanReceiveRequestsWithoutVerification(String serviceType) {
    return activeRequestServiceTypes.contains(serviceType.trim().toLowerCase());
  }
}

class DriverBusinessConfig {
  static const double commissionRate = 0.10;
  static const double commissionRatePercent = commissionRate * 100;
  static const int weeklySubscriptionPriceNgn = 7000;
  static const int monthlySubscriptionPriceNgn = 25000;
}

class DriverDispatchConfig {
  static const double nearbyRequestRadiusMeters = 30000;
}

class DriverAlertSoundConfig {
  static const bool enableRideRequestAlerts = true;
  static const bool enableChatAlerts = true;
  static const bool enableIncomingCallAlerts = true;
  /// Must match a path under `flutter: assets:` in pubspec (includes `assets/` prefix).
  static const String alertAssetPath = 'assets/sounds/ride_request.mp3';
}

class DriverLaunchMarket {
  const DriverLaunchMarket({
    required this.city,
    required this.label,
    required this.latitude,
    required this.longitude,
  });

  final String city;
  final String label;
  final double latitude;
  final double longitude;
}

class DriverServiceAreaConfig {
  // Launch markets must stay aligned with RiderServiceAreaConfig.launchMarkets
  // (rider `lib/config/rider_app_config.dart`) so `ride_requests.market_pool` matches
  // driver discovery (`orderByChild('market_pool').equalTo(citySlug)`).

  static const String countryCode = 'NG';
  static const String countryName = 'Nigeria';
  static const String countryValue = 'nigeria';
  static const double defaultMapLatitude = 6.5244;
  static const double defaultMapLongitude = 3.3792;
  static const double defaultMapZoom = 13.2;
  static const bool qaAllowOutOfRegionBrowsing = true;
  static const bool qaAllowManualLaunchCitySelection = false;
  static const bool qaAllowOutOfRegionGoOnline = false;
  static const bool strictLiveTripGeofencingEnabled = false;

  static const List<DriverLaunchMarket> launchMarkets = <DriverLaunchMarket>[
    DriverLaunchMarket(
      city: 'lagos',
      label: 'Lagos',
      latitude: 6.5244,
      longitude: 3.3792,
    ),
    DriverLaunchMarket(
      city: 'delta',
      label: 'Delta',
      latitude: 6.2059,
      longitude: 6.6959,
    ),
    DriverLaunchMarket(
      city: 'abuja',
      label: 'Abuja',
      latitude: 9.0765,
      longitude: 7.3986,
    ),
    DriverLaunchMarket(
      city: 'anambra',
      label: 'Anambra',
      latitude: 6.2104,
      longitude: 7.0741,
    ),
  ];

  static DriverLaunchMarket get defaultMarket => launchMarkets.first;

  static DriverLaunchMarket marketForCity(String? rawCity) {
    final normalized = DriverLaunchScope.normalizeSupportedCity(rawCity);
    for (final market in launchMarkets) {
      if (market.city == normalized) {
        return market;
      }
    }
    return defaultMarket;
  }

  static List<String> get supportedCities =>
      launchMarkets.map((market) => market.city).toList(growable: false);

  static List<String> get supportedCityLabels =>
      launchMarkets.map((market) => market.label).toList(growable: false);

  static String formatMarketLabels(List<String> labels) {
    if (labels.isEmpty) {
      return '';
    }
    if (labels.length == 1) {
      return labels.first;
    }
    if (labels.length == 2) {
      return '${labels.first} and ${labels.last}';
    }
    return '${labels.sublist(0, labels.length - 1).join(', ')}, and ${labels.last}';
  }
}

class DriverLaunchScope {
  static const String countryCode = DriverServiceAreaConfig.countryCode;
  static const String countryName = DriverServiceAreaConfig.countryName;
  static String get defaultBrowseCity =>
      DriverServiceAreaConfig.defaultMarket.city;
  static Set<String> get supportedCities =>
      DriverServiceAreaConfig.supportedCities.toSet();
  static List<String> get supportedCityLabels =>
      DriverServiceAreaConfig.supportedCityLabels;
  static double get lagosLatitude =>
      DriverServiceAreaConfig.marketForCity('lagos').latitude;
  static double get lagosLongitude =>
      DriverServiceAreaConfig.marketForCity('lagos').longitude;
  static double get abujaLatitude =>
      DriverServiceAreaConfig.marketForCity('abuja').latitude;
  static double get abujaLongitude =>
      DriverServiceAreaConfig.marketForCity('abuja').longitude;

  static String get launchCitiesLabel =>
      DriverServiceAreaConfig.formatMarketLabels(supportedCityLabels);

  static String get browseWithoutLocationMessage =>
      'Driver Hub, wallet, earnings, trip history, and support remain available while NexRide operates in $launchCitiesLabel.';

  static String get goOnlineLocationMessage =>
      'Enable live location when you are ready to go online in $launchCitiesLabel.';

  static String get outOfRegionBrowseMessage =>
      'Your current device location is outside the NexRide service area. Driver availability and trip matching will stay limited to $launchCitiesLabel.';

  static String get marketSelectionPrompt =>
      'NexRide currently serves $launchCitiesLabel.';

  static String labelForCity(String? city) {
    return DriverServiceAreaConfig.marketForCity(city).label;
  }

  static double latitudeForCity(String? city) {
    return DriverServiceAreaConfig.marketForCity(city).latitude;
  }

  static double longitudeForCity(String? city) {
    return DriverServiceAreaConfig.marketForCity(city).longitude;
  }

  /// Keep token lists in sync with [RiderLaunchScope.normalizeSupportedCity]
  /// (lib/config/rider_app_config.dart).
  static String? normalizeSupportedCity(String? rawCity) {
    if (rawCity == null) {
      return null;
    }

    final rawValue = rawCity.trim().toLowerCase();
    if (rawValue.isEmpty) {
      return null;
    }

    final spaced = rawValue
        .replaceAll(RegExp(r'[^a-z]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final compact = spaced.replaceAll(' ', '');

    const lagosTokens = <String>[
      'lagos',
      'ikeja',
      'yaba',
      'surulere',
      'lekki',
      'ajah',
      'ikorodu',
      'mushin',
      'maryland',
      'gbagada',
      'victoria island',
      'ikoyi',
      'apapa',
      'ebute metta',
      'ilupeju',
      'somolu',
    ];

    const abujaTokens = <String>[
      'abuja',
      'fct',
      'federal capital territory',
      'garki',
      'wuse',
      'maitama',
      'kubwa',
      'asokoro',
      'lugbe',
      'gwagwalada',
    ];
    const deltaTokens = <String>[
      'delta',
      'asaba',
      'warri',
      'effurun',
      'sapele',
      'ughelli',
      'okpanam',
      'ibusa',
    ];
    const anambraTokens = <String>[
      'anambra',
      'awka',
      'onitsha',
      'nnewi',
      'nkpor',
      'ekwulobia',
      'amawbia',
    ];

    bool containsToken(List<String> tokens) {
      for (final token in tokens) {
        final normalizedToken = token.trim().toLowerCase();
        final compactToken = normalizedToken.replaceAll(' ', '');
        if (spaced.contains(normalizedToken) ||
            compact.contains(compactToken)) {
          return true;
        }
      }
      return false;
    }

    if (containsToken(lagosTokens)) {
      return 'lagos';
    }

    if (containsToken(abujaTokens)) {
      return 'abuja';
    }

    if (containsToken(deltaTokens)) {
      return 'delta';
    }

    if (containsToken(anambraTokens)) {
      return 'anambra';
    }

    return null;
  }

  static String? normalizeSupportedArea(String? rawArea, {String? city}) {
    final normalizedCity = normalizeSupportedCity(city ?? rawArea);
    if (rawArea == null) {
      return null;
    }

    final spaced = rawArea
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (spaced.isEmpty) {
      return null;
    }
    final compact = spaced.replaceAll(' ', '');

    String? matchArea(Map<String, List<String>> entries) {
      for (final entry in entries.entries) {
        final canonical = entry.key;
        final tokens = <String>[canonical, ...entry.value];
        for (final token in tokens) {
          final normalizedToken = token.trim().toLowerCase();
          final compactToken = normalizedToken.replaceAll(' ', '');
          if (spaced.contains(normalizedToken) ||
              compact.contains(compactToken)) {
            return canonical;
          }
        }
      }
      return null;
    }

    const lagosAreas = <String, List<String>>{
      'ikeja': <String>['alausa', 'computer village'],
      'yaba': <String>['sabo', 'unilag', 'akoka'],
      'surulere': <String>['adeniran ogunsanya', 'bode thomas'],
      'lekki': <String>['lekki phase 1', 'lekki phase 2', 'chevron'],
      'ajah': <String>['sangotedo', 'badore', 'abraham adesanya'],
      'ikoyi': <String>['banana island', 'parkview'],
      'victoria island': <String>['vi', 'ahmadu bello way'],
      'maryland': <String>['anthony', 'mende'],
      'gbagada': <String>['ifako', 'pedro'],
      'apapa': <String>['marine beach'],
      'mushin': <String>['idi oro'],
      'ikorodu': <String>['agbowa', 'owutu'],
      'ebute metta': <String>['ebute'],
      'ilupeju': <String>['town planning way'],
      'somolu': <String>['bariga'],
    };
    const abujaAreas = <String, List<String>>{
      'wuse': <String>['wuse 2', 'wuse ii', 'wuse zone 1'],
      'maitama': <String>['mpape'],
      'garki': <String>['area 1', 'area 11', 'garki 2'],
      'asokoro': <String>['asokoro extension'],
      'lugbe': <String>['airport road'],
      'gwagwalada': <String>['zuba'],
      'kubwa': <String>['phase 4', 'byazhin'],
      'jabi': <String>['jabi lake'],
      'utako': <String>['jabi park'],
      'katampe': <String>['katampe extension'],
      'life camp': <String>['gwarinpa'],
    };
    const deltaAreas = <String, List<String>>{
      'asaba': <String>['okpanam', 'ibusa', 'summit road'],
      'warri': <String>['effurun', 'jakpa road', 'airport road'],
      'sapele': <String>['amukpe'],
      'ughelli': <String>['otovwodo'],
    };
    const anambraAreas = <String, List<String>>{
      'awka': <String>['amawbia', 'aroma junction'],
      'onitsha': <String>['nkpor', 'fegge', 'gr a'],
      'nnewi': <String>['otolo', 'umudim'],
      'ekwulobia': <String>['aguata'],
    };

    if (normalizedCity == 'lagos') {
      return matchArea(lagosAreas);
    }
    if (normalizedCity == 'abuja') {
      return matchArea(abujaAreas);
    }
    if (normalizedCity == 'delta') {
      return matchArea(deltaAreas);
    }
    if (normalizedCity == 'anambra') {
      return matchArea(anambraAreas);
    }
    return matchArea(lagosAreas) ??
        matchArea(abujaAreas) ??
        matchArea(deltaAreas) ??
        matchArea(anambraAreas);
  }

  static Map<String, String> buildServiceAreaFields({
    required String city,
    String? area,
  }) {
    final normalizedCity = normalizeSupportedCity(city) ?? defaultBrowseCity;
    final normalizedArea =
        normalizeSupportedArea(area, city: normalizedCity) ?? '';
    return <String, String>{
      'country': DriverServiceAreaConfig.countryValue,
      'country_code': countryCode,
      'market': normalizedCity,
      'area': normalizedArea,
      'zone': normalizedArea,
      'community': normalizedArea,
    };
  }
}

class DriverLocationPolicy {
  static const bool allowBrowseWithoutLocation = true;
  static const bool allowApproximateLocationForBrowse = true;
  static const bool requireLocationForGoOnline = true;
  static const bool useTestDriverLocation = true;
  static const String testDriverCity = 'lagos';
}
