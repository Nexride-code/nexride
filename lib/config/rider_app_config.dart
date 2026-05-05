class RiderFeatureFlags {
  static const bool enableGroceries = false;
  static const bool enableFood = false;
  static const bool hideUserVerificationWhenApproved = true;
  static bool get enableRiderRestrictions => false;
  static bool get enableCancellationFeeBlocking => false;
  static bool get showTrustWarnings => false;
  static bool get enableOnlinePaymentMethods => true;

  /// Phase 1 production: car rides only (no dispatch / mart / food entry).
  static const bool phase1CarRidesOnly = true;

  /// Cash is not supported; trips use Flutterwave (card/online) only.
  static const bool disableCashTripPayments = true;
  static const String paymentProviderCardDefault = 'flutterwave_ready';

  /// Cash payment picker removed — server validates [payment_method] against allow-list.
  static bool get showRidePaymentMethodPicker => false;

  static bool isServiceEnabled(String serviceKey) {
    final k = serviceKey.trim().toLowerCase();
    if (phase1CarRidesOnly) {
      return k == 'ride';
    }
    switch (k) {
      case 'ride':
      case 'dispatch':
      case 'dispatch_delivery':
      case 'dispatch/delivery':
        return true;
      case 'groceries':
      case 'groceries_mart':
      case 'groceries/mart':
        return enableGroceries;
      case 'restaurants':
      case 'restaurants_food':
      case 'restaurants/food':
      case 'food':
        return enableFood;
      default:
        return false;
    }
  }
}

class RiderVerificationCopy {
  static const String title = 'User Verification';
  static const String titleLowercase = 'user verification';
  static const String trustScreenTitle = 'User Verification';

  static bool isApprovedStatus(String rawStatus) {
    final normalized = rawStatus.trim().toLowerCase();
    return normalized == 'approved' || normalized == 'verified';
  }

  static bool shouldShowEntry(String rawStatus) {
    if (!RiderFeatureFlags.hideUserVerificationWhenApproved) {
      return true;
    }
    return !isApprovedStatus(rawStatus);
  }
}

class RiderAlertSoundConfig {
  static const bool enableNotifications = true;
  static const bool enableChatAlerts = true;
  static const bool enableIncomingCallAlerts = true;
  static const Duration incomingCallRepeatInterval = Duration(seconds: 2);
  static const Set<String> rideStatusNotificationStatuses = <String>{
    'pending_driver_acceptance',
    'pending_driver_action',
    'assigned',
    'accepted',
    'arriving',
    'arrived',
    'on_trip',
    'completed',
    'cancelled',
  };

  static bool shouldPlayRideStatusAlert(String rawStatus) {
    return enableNotifications &&
        rideStatusNotificationStatuses.contains(rawStatus.trim().toLowerCase());
  }
}

class RiderFareRule {
  const RiderFareRule({
    required this.baseFare,
    required this.perKmRate,
    required this.perMinuteRate,
    required this.minimumFare,
    this.trafficWindows = const <RiderTrafficWindow>[],
  });

  final double baseFare;
  final double perKmRate;
  final double perMinuteRate;
  final double minimumFare;
  final List<RiderTrafficWindow> trafficWindows;
}

class RiderTrafficWindow {
  const RiderTrafficWindow({
    required this.label,
    required this.startHour,
    required this.startMinute,
    required this.endHour,
    required this.endMinute,
    required this.multiplier,
  });

  final String label;
  final int startHour;
  final int startMinute;
  final int endHour;
  final int endMinute;
  final double multiplier;

  bool contains(DateTime dateTime) {
    final minuteOfDay = (dateTime.hour * 60) + dateTime.minute;
    final start = (startHour * 60) + startMinute;
    final end = (endHour * 60) + endMinute;
    return minuteOfDay >= start && minuteOfDay < end;
  }
}

class RiderAddressSuggestion {
  const RiderAddressSuggestion({
    required this.city,
    required this.area,
    required this.primaryText,
    required this.secondaryText,
    required this.fullText,
    this.aliases = const <String>[],
  });

  final String city;
  final String area;
  final String primaryText;
  final String secondaryText;
  final String fullText;
  final List<String> aliases;

  int scoreForQuery(String query, {String? preferredCity}) {
    final normalizedQuery = query.trim().toLowerCase();
    if (normalizedQuery.isEmpty) {
      return -1;
    }

    final normalizedPreferredCity = RiderLaunchScope.normalizeSupportedCity(
      preferredCity,
    );
    final haystacks = <String>[
      city,
      area,
      primaryText,
      secondaryText,
      fullText,
      ...aliases,
    ].map(_normalizeToken).where((token) => token.isNotEmpty).toList();

    var score = 0;
    for (final haystack in haystacks) {
      if (haystack == normalizedQuery) {
        score = score < 120 ? 120 : score;
      } else if (haystack.startsWith(normalizedQuery)) {
        score = score < 100 ? 100 : score;
      } else if (haystack.contains(normalizedQuery)) {
        score = score < 80 ? 80 : score;
      }
    }

    if (score == 0) {
      final queryTokens = normalizedQuery
          .split(RegExp(r'\s+'))
          .where((token) => token.isNotEmpty)
          .toList(growable: false);
      if (queryTokens.isNotEmpty &&
          queryTokens.every(
            (token) => haystacks.any((candidate) => candidate.contains(token)),
          )) {
        score = 60;
      }
    }

    if (score == 0) {
      return -1;
    }

    if (normalizedPreferredCity != null && normalizedPreferredCity == city) {
      score += 20;
    }
    return score;
  }

  static String _normalizeToken(String value) {
    return value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}

class RiderLaunchMarket {
  const RiderLaunchMarket({
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

class RiderServiceAreaConfig {
  // Launch markets must stay aligned with DriverServiceAreaConfig.launchMarkets
  // (nexride_driver/lib/config/driver_app_config.dart) so rider `market` and driver
  // discovery queries use the same canonical city keys.

  static const String countryCode = 'NG';
  static const String countryName = 'Nigeria';
  static const String countryValue = 'nigeria';
  static const double defaultMapLatitude = 6.5244;
  static const double defaultMapLongitude = 3.3792;
  static const double defaultMapZoom = 13.2;
  static const bool qaAllowOutOfRegionBrowsing = true;
  static const bool qaAllowManualLaunchCitySelection = false;
  static const bool qaAllowOutOfRegionRideTesting = false;
  static const bool strictLiveTripGeofencingEnabled = false;

  static const List<RiderLaunchMarket> launchMarkets = <RiderLaunchMarket>[
    RiderLaunchMarket(
      city: 'lagos',
      label: 'Lagos',
      latitude: 6.5244,
      longitude: 3.3792,
    ),
    RiderLaunchMarket(
      city: 'delta',
      label: 'Delta',
      latitude: 6.2059,
      longitude: 6.6959,
    ),
    RiderLaunchMarket(
      city: 'abuja',
      label: 'Abuja',
      latitude: 9.0765,
      longitude: 7.3986,
    ),
    RiderLaunchMarket(
      city: 'anambra',
      label: 'Anambra',
      latitude: 6.2104,
      longitude: 7.0741,
    ),
  ];

  static RiderLaunchMarket get defaultMarket => launchMarkets.first;

  static RiderLaunchMarket marketForCity(String? rawCity) {
    final normalized = RiderLaunchScope.normalizeSupportedCity(rawCity);
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

class RiderLaunchScope {
  static const String countryCode = RiderServiceAreaConfig.countryCode;
  static const String countryName = RiderServiceAreaConfig.countryName;
  static String get defaultBrowseCity =>
      RiderServiceAreaConfig.defaultMarket.city;
  static String get launchCitiesLabel =>
      RiderServiceAreaConfig.formatMarketLabels(
        RiderServiceAreaConfig.supportedCityLabels,
      );
  static Set<String> get supportedCities =>
      RiderServiceAreaConfig.supportedCities.toSet();

  static String get browseWithoutLocationMessage =>
      RiderLocationPolicy.useTestRiderLocation
      ? 'Location is temporarily optional while you test pickup and destination search in $launchCitiesLabel.'
      : 'You can browse NexRide in $launchCitiesLabel without using your current location.';

  static String get currentLocationPrompt =>
      RiderLocationPolicy.useTestRiderLocation
      ? 'Search for a pickup in $launchCitiesLabel. A temporary ${labelForCity(RiderLocationPolicy.testRiderCity)} test location stays active while device location is off.'
      : 'Enable location to use your current pickup in $launchCitiesLabel, or type an address in one of our live cities.';

  static String get tripRequestAvailabilityMessage =>
      'NexRide is currently launching only in $launchCitiesLabel.';

  static String get outOfRegionBrowseMessage =>
      'Your current device location is outside the NexRide service area. Type a pickup or destination in $launchCitiesLabel to continue.';

  static String get marketSelectionPrompt =>
      'NexRide currently serves $launchCitiesLabel.';

  static const List<RiderAddressSuggestion> _knownAddressSuggestions =
      <RiderAddressSuggestion>[
        RiderAddressSuggestion(
          city: 'lagos',
          area: 'yaba',
          primaryText: 'Akoka',
          secondaryText: 'Yaba, Lagos',
          fullText: 'Akoka, Yaba, Lagos, Nigeria',
          aliases: <String>['unilag', 'university of lagos', 'sabo'],
        ),
        RiderAddressSuggestion(
          city: 'lagos',
          area: 'yaba',
          primaryText: 'Yaba',
          secondaryText: 'Lagos Mainland',
          fullText: 'Yaba, Lagos, Nigeria',
          aliases: <String>['tejuosho', 'sabo'],
        ),
        RiderAddressSuggestion(
          city: 'lagos',
          area: 'ikeja',
          primaryText: 'Ikeja',
          secondaryText: 'Lagos Mainland',
          fullText: 'Ikeja, Lagos, Nigeria',
          aliases: <String>['alausa', 'computer village'],
        ),
        RiderAddressSuggestion(
          city: 'lagos',
          area: 'lekki',
          primaryText: 'Lekki Phase 1',
          secondaryText: 'Lekki, Lagos',
          fullText: 'Lekki Phase 1, Lekki, Lagos, Nigeria',
          aliases: <String>['admiralty way', 'chevron'],
        ),
        RiderAddressSuggestion(
          city: 'lagos',
          area: 'victoria island',
          primaryText: 'Victoria Island',
          secondaryText: 'Lagos Island',
          fullText: 'Victoria Island, Lagos, Nigeria',
          aliases: <String>['vi', 'ahmadu bello way'],
        ),
        RiderAddressSuggestion(
          city: 'lagos',
          area: 'ikoyi',
          primaryText: 'Ikoyi',
          secondaryText: 'Lagos Island',
          fullText: 'Ikoyi, Lagos, Nigeria',
          aliases: <String>['banana island', 'parkview'],
        ),
        RiderAddressSuggestion(
          city: 'lagos',
          area: 'surulere',
          primaryText: 'Surulere',
          secondaryText: 'Lagos Mainland',
          fullText: 'Surulere, Lagos, Nigeria',
          aliases: <String>['adeniran ogunsanya', 'bode thomas'],
        ),
        RiderAddressSuggestion(
          city: 'lagos',
          area: 'ajah',
          primaryText: 'Ajah',
          secondaryText: 'Eti-Osa, Lagos',
          fullText: 'Ajah, Lagos, Nigeria',
          aliases: <String>['sangotedo', 'abraham adesanya'],
        ),
        RiderAddressSuggestion(
          city: 'abuja',
          area: 'wuse',
          primaryText: 'Wuse 2',
          secondaryText: 'Wuse, Abuja',
          fullText: 'Wuse 2, Abuja, Nigeria',
          aliases: <String>['wuse ii', 'ademola adetokunbo'],
        ),
        RiderAddressSuggestion(
          city: 'abuja',
          area: 'maitama',
          primaryText: 'Maitama',
          secondaryText: 'Abuja Municipal',
          fullText: 'Maitama, Abuja, Nigeria',
          aliases: <String>['ibesikpo', 'transcorp hilton'],
        ),
        RiderAddressSuggestion(
          city: 'abuja',
          area: 'garki',
          primaryText: 'Garki',
          secondaryText: 'Abuja Municipal',
          fullText: 'Garki, Abuja, Nigeria',
          aliases: <String>['area 1', 'area 11'],
        ),
        RiderAddressSuggestion(
          city: 'abuja',
          area: 'asokoro',
          primaryText: 'Asokoro',
          secondaryText: 'Abuja Municipal',
          fullText: 'Asokoro, Abuja, Nigeria',
          aliases: <String>['aap', 'asokoro extension'],
        ),
        RiderAddressSuggestion(
          city: 'abuja',
          area: 'jabi',
          primaryText: 'Jabi',
          secondaryText: 'Abuja Municipal',
          fullText: 'Jabi, Abuja, Nigeria',
          aliases: <String>['jabi lake'],
        ),
        RiderAddressSuggestion(
          city: 'abuja',
          area: 'lugbe',
          primaryText: 'Lugbe',
          secondaryText: 'Airport Road, Abuja',
          fullText: 'Lugbe, Abuja, Nigeria',
          aliases: <String>['airport road'],
        ),
        RiderAddressSuggestion(
          city: 'abuja',
          area: 'kubwa',
          primaryText: 'Kubwa',
          secondaryText: 'Bwari, Abuja',
          fullText: 'Kubwa, Abuja, Nigeria',
          aliases: <String>['phase 4', 'byazhin'],
        ),
        RiderAddressSuggestion(
          city: 'delta',
          area: 'asaba',
          primaryText: 'Asaba',
          secondaryText: 'Delta',
          fullText: 'Asaba, Delta, Nigeria',
          aliases: <String>['okpanam', 'ibusa'],
        ),
        RiderAddressSuggestion(
          city: 'delta',
          area: 'warri',
          primaryText: 'Warri',
          secondaryText: 'Delta',
          fullText: 'Warri, Delta, Nigeria',
          aliases: <String>['effurun', 'jakpa road'],
        ),
        RiderAddressSuggestion(
          city: 'delta',
          area: 'sapele',
          primaryText: 'Sapele',
          secondaryText: 'Delta',
          fullText: 'Sapele, Delta, Nigeria',
          aliases: <String>['amukpe'],
        ),
        RiderAddressSuggestion(
          city: 'anambra',
          area: 'awka',
          primaryText: 'Awka',
          secondaryText: 'Anambra',
          fullText: 'Awka, Anambra, Nigeria',
          aliases: <String>['amawbia', 'aroma junction'],
        ),
        RiderAddressSuggestion(
          city: 'anambra',
          area: 'onitsha',
          primaryText: 'Onitsha',
          secondaryText: 'Anambra',
          fullText: 'Onitsha, Anambra, Nigeria',
          aliases: <String>['nkpor', 'fegge'],
        ),
        RiderAddressSuggestion(
          city: 'anambra',
          area: 'nnewi',
          primaryText: 'Nnewi',
          secondaryText: 'Anambra',
          fullText: 'Nnewi, Anambra, Nigeria',
          aliases: <String>['otolo', 'ukwuani'],
        ),
      ];

  static String labelForCity(String? city) {
    return RiderServiceAreaConfig.marketForCity(city).label;
  }

  static double latitudeForCity(String? city) {
    return RiderServiceAreaConfig.marketForCity(city).latitude;
  }

  static double longitudeForCity(String? city) {
    return RiderServiceAreaConfig.marketForCity(city).longitude;
  }

  static String normalizeAddressQuery(String value, {String? preferredCity}) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return trimmed;
    }

    final inferredCity = normalizeSupportedCity(trimmed) ?? preferredCity;
    final lowered = trimmed.toLowerCase();
    if (lowered.contains('nigeria') ||
        supportedCities.any((city) => lowered.contains(city))) {
      return trimmed;
    }

    if (inferredCity == null) {
      return '$trimmed, $countryName';
    }

    final marketLabel = labelForCity(inferredCity);
    return '$trimmed, $marketLabel, $countryName';
  }

  static List<String> buildSearchQueries(
    String value, {
    String? preferredCity,
  }) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return const <String>[];
    }

    final marketLabel = labelForCity(preferredCity);
    return <String>{
      normalizeAddressQuery(trimmed, preferredCity: preferredCity),
      '$trimmed, $marketLabel, $countryName',
      '$trimmed, $countryName',
      trimmed,
    }.where((query) => query.trim().isNotEmpty).toList(growable: false);
  }

  static List<RiderAddressSuggestion> buildFallbackSearchSuggestions(
    String value, {
    String? preferredCity,
  }) {
    final query = value.trim();
    if (query.length < 2) {
      return const <RiderAddressSuggestion>[];
    }

    final scoredSuggestions = <MapEntry<RiderAddressSuggestion, int>>[];
    for (final suggestion in _knownAddressSuggestions) {
      final score = suggestion.scoreForQuery(
        query,
        preferredCity: preferredCity,
      );
      if (score >= 0) {
        scoredSuggestions.add(
          MapEntry<RiderAddressSuggestion, int>(suggestion, score),
        );
      }
    }

    scoredSuggestions.sort((a, b) {
      final scoreCompare = b.value.compareTo(a.value);
      if (scoreCompare != 0) {
        return scoreCompare;
      }
      return a.key.fullText.compareTo(b.key.fullText);
    });

    return scoredSuggestions
        .map((entry) => entry.key)
        .take(6)
        .toList(growable: false);
  }

  /// Keep token lists in sync with [DriverLaunchScope.normalizeSupportedCity]
  /// (nexride_driver/lib/config/driver_app_config.dart).
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
    final normalized = rawArea?.trim().toLowerCase().replaceAll(
      RegExp(r'[^a-z]'),
      ' ',
    );
    if (normalized == null || normalized.trim().isEmpty) {
      return null;
    }

    final spaced = normalized.replaceAll(RegExp(r'\s+'), ' ').trim();
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
      'asokoro': <String>['aap', 'asokoro extension'],
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
      'country': RiderServiceAreaConfig.countryValue,
      'country_code': countryCode,
      'market': normalizedCity,
      'area': normalizedArea,
      'zone': normalizedArea,
      'community': normalizedArea,
    };
  }
}

class RiderLocationPolicy {
  static const bool useTestRiderLocation = true;
  static const String testRiderCity = 'lagos';
}

class RiderFareSettings {
  static const double averageSpeedKmPerHour = 28;
  static const int minimumDurationMinutes = 4;
  static const double defaultSurgeMultiplier = 1.0;
  static const double waitingCharge = 500;
  static Set<String> get supportedCities => RiderLaunchScope.supportedCities;

  static const RiderFareRule lagos = RiderFareRule(
    baseFare: 800,
    perKmRate: 140,
    perMinuteRate: 18,
    minimumFare: 1400,
    trafficWindows: <RiderTrafficWindow>[
      RiderTrafficWindow(
        label: 'lagos_morning_peak',
        startHour: 6,
        startMinute: 30,
        endHour: 10,
        endMinute: 0,
        multiplier: 1.12,
      ),
      RiderTrafficWindow(
        label: 'lagos_evening_peak',
        startHour: 16,
        startMinute: 30,
        endHour: 20,
        endMinute: 0,
        multiplier: 1.18,
      ),
    ],
  );

  static const RiderFareRule abuja = RiderFareRule(
    baseFare: 600,
    perKmRate: 115,
    perMinuteRate: 12,
    minimumFare: 1350,
    trafficWindows: <RiderTrafficWindow>[
      RiderTrafficWindow(
        label: 'abuja_morning_peak',
        startHour: 6,
        startMinute: 30,
        endHour: 9,
        endMinute: 30,
        multiplier: 1.08,
      ),
      RiderTrafficWindow(
        label: 'abuja_evening_peak',
        startHour: 16,
        startMinute: 30,
        endHour: 19,
        endMinute: 30,
        multiplier: 1.12,
      ),
    ],
  );

  static const RiderFareRule delta = RiderFareRule(
    baseFare: 580,
    perKmRate: 108,
    perMinuteRate: 11,
    minimumFare: 1250,
    trafficWindows: <RiderTrafficWindow>[
      RiderTrafficWindow(
        label: 'delta_morning_peak',
        startHour: 6,
        startMinute: 30,
        endHour: 9,
        endMinute: 30,
        multiplier: 1.05,
      ),
      RiderTrafficWindow(
        label: 'delta_evening_peak',
        startHour: 16,
        startMinute: 30,
        endHour: 19,
        endMinute: 0,
        multiplier: 1.08,
      ),
    ],
  );

  static const RiderFareRule anambra = RiderFareRule(
    baseFare: 560,
    perKmRate: 105,
    perMinuteRate: 11,
    minimumFare: 1200,
    trafficWindows: <RiderTrafficWindow>[
      RiderTrafficWindow(
        label: 'anambra_morning_peak',
        startHour: 6,
        startMinute: 30,
        endHour: 9,
        endMinute: 30,
        multiplier: 1.05,
      ),
      RiderTrafficWindow(
        label: 'anambra_evening_peak',
        startHour: 16,
        startMinute: 30,
        endHour: 19,
        endMinute: 0,
        multiplier: 1.08,
      ),
    ],
  );

  static String? normalizeSupportedCity(String? city) {
    return RiderLaunchScope.normalizeSupportedCity(city);
  }

  static RiderFareRule? maybeForCity(String? city) {
    return switch (normalizeSupportedCity(city)) {
      'lagos' => lagos,
      'abuja' => abuja,
      'delta' => delta,
      'anambra' => anambra,
      _ => null,
    };
  }

  static DateTime nigeriaTimeNow({DateTime? referenceTime}) {
    final reference = referenceTime ?? DateTime.now();
    final utcReference = reference.isUtc ? reference : reference.toUtc();
    return utcReference.add(const Duration(hours: 1));
  }

  static RiderTrafficWindow? activeTrafficWindowForCity(
    String city, {
    DateTime? at,
  }) {
    final rule = maybeForCity(city);
    if (rule == null) {
      return null;
    }
    final nigeriaTime = nigeriaTimeNow(referenceTime: at);
    for (final window in rule.trafficWindows) {
      if (window.contains(nigeriaTime)) {
        return window;
      }
    }
    return null;
  }

  static double trafficMultiplierForCity(String city, {DateTime? at}) {
    return activeTrafficWindowForCity(city, at: at)?.multiplier ??
        defaultSurgeMultiplier;
  }

  static RiderFareRule forCity(String city) {
    final rule = maybeForCity(city);
    if (rule != null) {
      return rule;
    }
    throw StateError('Unsupported NexRide pricing city: $city');
  }
}
