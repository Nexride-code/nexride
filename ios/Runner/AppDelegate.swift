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

    debugPrint("[iOSMaps] bundle=\(bundleId) apiKeyPresent=\(!apiKey.isEmpty)")

    if !apiKey.isEmpty {
      GMSServices.provideAPIKey(apiKey)
      debugPrint("[iOSMaps] GMSServices initialized for bundle \(bundleId)")

      GMSPlacesClient.provideAPIKey(apiKey)
      debugPrint("[iOSMaps] GMSPlacesClient initialized for bundle \(bundleId)")

      if bundleId.hasPrefix("com.example.") {
        debugPrint(
          "[iOSMaps] WARNING: \(bundleId) is still using an example bundle identifier. " +
            "Ensure this exact bundle ID is allowed on the Google Maps Platform key."
        )
      }
    } else {
      debugPrint("[iOSMaps] Missing GMSApiKey in Info.plist for bundle \(bundleId)")
    }

    GeneratedPluginRegistrant.register(with: self)
    // Inline Swift plugin (not in pub); must register here exactly once — never in
    // didInitializeImplicitFlutterEngine (duplicate engine registration crash).
    if let registrar = self.registrar(forPlugin: "NativePlacesPlugin") {
      NativePlacesPlugin.register(with: registrar)
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    // Plugins are already registered during normal startup.
    // Do not register again here (avoids duplicate plugin key crash).
  }
}
