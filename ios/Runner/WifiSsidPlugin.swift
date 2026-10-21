import CoreLocation
import Flutter
import NetworkExtension

/// iOS answers for `plugins/wifi_ssid`. Reading the SSID needs location access
/// and the Access WiFi Information entitlement; without either it reads null.
final class WifiSsidPlugin: NSObject, FlutterPlugin, CLLocationManagerDelegate {
  private let locationManager = CLLocationManager()
  private var pendingRequests: [FlutterResult] = []

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "wifi_ssid", binaryMessenger: registrar.messenger())
    let instance = WifiSsidPlugin()
    instance.locationManager.delegate = instance
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getSsid":
      NEHotspotNetwork.fetchCurrent { network in
        result(network?.ssid)
      }
    case "checkPermission":
      result(permissionState())
    case "requestPermission":
      if locationManager.authorizationStatus == .notDetermined {
        pendingRequests.append(result)
        locationManager.requestWhenInUseAuthorization()
      } else {
        result(permissionState())
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // 0 granted, 1 denied, 2 permanently denied: the codes wifi_ssid_manager.dart decodes.
  private func permissionState() -> Int {
    switch locationManager.authorizationStatus {
    case .authorizedAlways, .authorizedWhenInUse:
      return 0
    case .denied, .restricted:
      return 2
    default:
      return 1
    }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    guard manager.authorizationStatus != .notDetermined else { return }
    let requests = pendingRequests
    pendingRequests = []
    let state = permissionState()
    requests.forEach { $0(state) }
  }
}
