import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class NativePlaceSuggestion {
  const NativePlaceSuggestion({
    required this.placeId,
    required this.primaryText,
    required this.secondaryText,
    required this.fullText,
  });

  factory NativePlaceSuggestion.manual({
    required String primaryText,
    required String secondaryText,
    required String fullText,
  }) {
    final manualKey = fullText.trim().toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]'),
      '_',
    );
    return NativePlaceSuggestion(
      placeId: 'manual:$manualKey',
      primaryText: primaryText,
      secondaryText: secondaryText,
      fullText: fullText,
    );
  }

  final String placeId;
  final String primaryText;
  final String secondaryText;
  final String fullText;

  bool get isManualSuggestion => placeId.startsWith('manual:');

  factory NativePlaceSuggestion.fromMap(Map<Object?, Object?> map) {
    return NativePlaceSuggestion(
      placeId: (map['placeId'] ?? '').toString(),
      primaryText: (map['primaryText'] ?? '').toString(),
      secondaryText: (map['secondaryText'] ?? '').toString(),
      fullText: (map['fullText'] ?? '').toString(),
    );
  }
}

class NativePlaceDetails {
  const NativePlaceDetails({
    required this.placeId,
    required this.address,
    required this.latitude,
    required this.longitude,
  });

  final String placeId;
  final String address;
  final double latitude;
  final double longitude;

  factory NativePlaceDetails.fromMap(Map<Object?, Object?> map) {
    return NativePlaceDetails(
      placeId: (map['placeId'] ?? '').toString(),
      address: (map['address'] ?? '').toString(),
      latitude: _asDouble(map['latitude']),
      longitude: _asDouble(map['longitude']),
    );
  }

  static double _asDouble(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }
}

class NativePlacesService {
  const NativePlacesService._();

  static const NativePlacesService instance = NativePlacesService._();
  static const MethodChannel _channel = MethodChannel('nexride/places');

  Future<List<NativePlaceSuggestion>> searchPlaces({
    required String query,
    String countryCode = 'NG',
  }) async {
    final trimmedQuery = query.trim();
    debugPrint(
      '[RiderSearchService] searchPlaces query="$trimmedQuery" country=${countryCode.trim().toUpperCase()}',
    );
    if (trimmedQuery.length < 2) {
      return const <NativePlaceSuggestion>[];
    }

    List<Object?>? raw;
    try {
      raw = await _channel.invokeMethod<List<Object?>>(
        'searchPlaces',
        <String, Object?>{
          'query': trimmedQuery,
          'countryCode': countryCode.trim().toUpperCase(),
        },
      );
    } on MissingPluginException {
      throw PlatformException(
        code: 'native_places_plugin_unavailable',
        message: 'iOS native places plugin is not registered on this engine.',
      );
    }

    if (raw == null) {
      debugPrint('[RiderSearchService] searchPlaces returned 0 predictions');
      return const <NativePlaceSuggestion>[];
    }

    final suggestions = raw
        .whereType<Map>()
        .map(
          (Map<dynamic, dynamic> item) =>
              NativePlaceSuggestion.fromMap(item.cast<Object?, Object?>()),
        )
        .where(
          (NativePlaceSuggestion suggestion) => suggestion.placeId.isNotEmpty,
        )
        .toList(growable: false);
    debugPrint(
      '[RiderSearchService] searchPlaces returned ${suggestions.length} predictions',
    );
    return suggestions;
  }

  Future<NativePlaceDetails?> fetchPlaceDetails(String placeId) async {
    final trimmedPlaceId = placeId.trim();
    debugPrint(
      '[RiderSearchService] fetchPlaceDetails placeId="$trimmedPlaceId"',
    );
    if (trimmedPlaceId.isEmpty) {
      return null;
    }

    Map<Object?, Object?>? raw;
    try {
      raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'fetchPlaceDetails',
        <String, Object?>{'placeId': trimmedPlaceId},
      );
    } on MissingPluginException {
      throw PlatformException(
        code: 'native_places_plugin_unavailable',
        message: 'iOS native places plugin is not registered on this engine.',
      );
    }

    if (raw == null || raw.isEmpty) {
      debugPrint(
        '[RiderSearchService] fetchPlaceDetails returned no payload placeId="$trimmedPlaceId"',
      );
      return null;
    }

    final details = NativePlaceDetails.fromMap(raw);
    if (details.placeId.isEmpty) {
      debugPrint(
        '[RiderSearchService] fetchPlaceDetails returned empty placeId for "$trimmedPlaceId"',
      );
      return null;
    }

    debugPrint(
      '[RiderSearchService] fetchPlaceDetails resolved placeId=${details.placeId} lat=${details.latitude} lng=${details.longitude}',
    );
    return details;
  }
}
