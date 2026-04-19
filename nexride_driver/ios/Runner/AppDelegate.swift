import Flutter
import GoogleMaps
import GooglePlaces
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
    let rawPlistApiKey = Bundle.main.object(forInfoDictionaryKey: "GMSApiKey") as? String
    let apiKey = rawPlistApiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    debugPrint("[DriveriOSMaps] bundle=\(bundleId) apiKeyPresent=\(!apiKey.isEmpty)")

    if !apiKey.isEmpty {
      GMSServices.provideAPIKey(apiKey)
      debugPrint("[DriveriOSMaps] GMSServices initialized for bundle \(bundleId)")

      GMSPlacesClient.provideAPIKey(apiKey)
      debugPrint("[DriveriOSMaps] GMSPlacesClient initialized for bundle \(bundleId)")

      if bundleId.hasPrefix("com.example.") {
        debugPrint(
          "[DriveriOSMaps] WARNING: \(bundleId) is still using an example bundle identifier. " +
            "Ensure this exact bundle ID is allowed on the Google Maps Platform key."
        )
      }
    } else {
      debugPrint("[DriveriOSMaps] Missing GMSApiKey in Info.plist for bundle \(bundleId)")
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
