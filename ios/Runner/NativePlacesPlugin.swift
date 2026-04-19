import Flutter
import GooglePlaces
import UIKit

final class NativePlacesPlugin: NSObject, FlutterPlugin {
  private let placesClient = GMSPlacesClient.shared()
  private var sessionToken: GMSAutocompleteSessionToken?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "nexride/places",
      binaryMessenger: registrar.messenger()
    )
    let instance = NativePlacesPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "searchPlaces":
      searchPlaces(call: call, result: result)
    case "fetchPlaceDetails":
      fetchPlaceDetails(call: call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func searchPlaces(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let arguments = call.arguments as? [String: Any],
      let rawQuery = arguments["query"] as? String
    else {
      result(
        FlutterError(
          code: "invalid_arguments",
          message: "Missing search query.",
          details: nil
        )
      )
      return
    }

    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    debugPrint("[RideriOSPlaces] searchPlaces query=\(query)")
    if query.count < 2 {
      result([[String: Any]]())
      return
    }

    let currentSessionToken = sessionToken ?? GMSAutocompleteSessionToken.init()
    sessionToken = currentSessionToken

    let filter = GMSAutocompleteFilter()
    if
      let countryCode = arguments["countryCode"] as? String,
      !countryCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      filter.countries = [countryCode.uppercased()]
    }

    placesClient.findAutocompletePredictions(
      fromQuery: query,
      filter: filter,
      sessionToken: currentSessionToken
    ) { predictions, error in
      if let error {
        let errorDescription = error.localizedDescription.lowercased()
        let errorCode: String
        if errorDescription.contains("api key") || errorDescription.contains("bundle") {
          errorCode = "places_configuration_invalid"
        } else if errorDescription.contains("network") || errorDescription.contains("connection") {
          errorCode = "places_network_unavailable"
        } else {
          errorCode = "places_search_failed"
        }
        result(
          FlutterError(
            code: errorCode,
            message: error.localizedDescription,
            details: nil
          )
        )
        return
      }

      let payload = (predictions ?? []).map { prediction in
        [
          "placeId": prediction.placeID,
          "primaryText": prediction.attributedPrimaryText.string,
          "secondaryText": prediction.attributedSecondaryText?.string ?? "",
          "fullText": prediction.attributedFullText.string,
        ]
      }
      debugPrint(
        "[RideriOSPlaces] searchPlaces success query=\(query) predictions=\(payload.count)"
      )
      result(payload)
    }
  }

  private func fetchPlaceDetails(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let arguments = call.arguments as? [String: Any],
      let rawPlaceId = arguments["placeId"] as? String
    else {
      result(
        FlutterError(
          code: "invalid_arguments",
          message: "Missing placeId.",
          details: nil
        )
      )
      return
    }

    let placeId = rawPlaceId.trimmingCharacters(in: .whitespacesAndNewlines)
    debugPrint("[RideriOSPlaces] fetchPlaceDetails placeId=\(placeId)")
    if placeId.isEmpty {
      result(nil)
      return
    }

    let fields: GMSPlaceField = [
      .placeID,
      .name,
      .formattedAddress,
      .coordinate,
    ]

    placesClient.fetchPlace(
      fromPlaceID: placeId,
      placeFields: fields,
      sessionToken: sessionToken
    ) { [weak self] place, error in
      defer {
        self?.sessionToken = nil
      }

      if let error {
        let errorDescription = error.localizedDescription.lowercased()
        let errorCode: String
        if errorDescription.contains("api key") || errorDescription.contains("bundle") {
          errorCode = "places_configuration_invalid"
        } else if errorDescription.contains("network") || errorDescription.contains("connection") {
          errorCode = "places_network_unavailable"
        } else {
          errorCode = "place_details_failed"
        }
        result(
          FlutterError(
            code: errorCode,
            message: error.localizedDescription,
            details: nil
          )
        )
        return
      }

      guard let place else {
        result(nil)
        return
      }

      result(
        [
          "placeId": place.placeID ?? placeId,
          "address": place.formattedAddress ?? place.name ?? "",
          "latitude": place.coordinate.latitude,
          "longitude": place.coordinate.longitude,
        ]
      )
      debugPrint(
        "[RideriOSPlaces] fetchPlaceDetails success placeId=\(place.placeID ?? placeId) lat=\(place.coordinate.latitude) lng=\(place.coordinate.longitude)"
      )
    }
  }
}
