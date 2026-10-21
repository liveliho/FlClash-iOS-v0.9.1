import Foundation

/// What the app and its packet tunnel extension agree on. iOS shares nothing
/// between the two processes but the App Group container named here.
enum TunnelShared {
  static let groupIdentifier: String = {
    if let value = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
      !value.isEmpty
    {
      return value
    }
    return "group.com.follow.clash"
  }()

  static var containerURL: URL {
    if let url = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: groupIdentifier)
    {
      return url
    }
    // Without the App Group entitlement the extension cannot see these files,
    // but the app itself keeps working with the VPN unavailable.
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  }

  static var homeDirectory: URL {
    containerURL.appendingPathComponent("FlClash", isDirectory: true)
  }

  // sun_path holds 104 bytes, so the socket sits at the container's root.
  static var socketPath: String {
    containerURL.appendingPathComponent("core.sock").path
  }

  static var sharedStateURL: URL {
    containerURL.appendingPathComponent("shared_state.json")
  }

  static func ensureHomeDirectory() -> URL {
    let url = homeDirectory
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  static func loadSharedState() -> [String: Any]? {
    guard let data = try? Data(contentsOf: sharedStateURL) else {
      return nil
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  static func saveSharedState(_ json: String) throws {
    try Data(json.utf8).write(to: sharedStateURL, options: .atomic)
  }

  static func jsonString(_ value: Any) -> String? {
    guard JSONSerialization.isValidJSONObject(value),
      let data = try? JSONSerialization.data(withJSONObject: value)
    else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  /// The payload the Go core's QuickSetup reads; the key spelling is a
  /// contract with core/protocol.go.
  static func initParams() -> String {
    jsonString(["home-dir": ensureHomeDirectory().path, "version": 0]) ?? "{}"
  }
}
