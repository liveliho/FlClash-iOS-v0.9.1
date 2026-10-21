import Foundation
import NetworkExtension

/// Owns the single NETunnelProviderManager that starts FlClash's packet
/// tunnel extension.
final class VpnController {
  static let shared = VpnController()

  private var manager: NETunnelProviderManager?
  private var observer: NSObjectProtocol?
  var onStatusChange: ((NEVPNStatus) -> Void)?

  private init() {}

  var status: NEVPNStatus {
    manager?.connection.status ?? .invalid
  }

  var connectedDate: Date? {
    guard let connection = manager?.connection, connection.status == .connected else {
      return nil
    }
    return connection.connectedDate
  }

  private var tunnelBundleIdentifier: String {
    "\(Bundle.main.bundleIdentifier ?? "com.follow.clash").PacketTunnel"
  }

  func load(completion: @escaping (NETunnelProviderManager?) -> Void) {
    if let manager {
      completion(manager)
      return
    }
    NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
      DispatchQueue.main.async {
        guard let self else { return }
        if let error {
          NSLog("FlClash: unable to load VPN preferences: \(error)")
        }
        let existing = managers?.first {
          ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
            == self.tunnelBundleIdentifier
        }
        if let existing {
          self.adopt(existing)
        }
        completion(existing)
      }
    }
  }

  private func adopt(_ manager: NETunnelProviderManager) {
    self.manager = manager
    if let observer {
      NotificationCenter.default.removeObserver(observer)
    }
    observer = NotificationCenter.default.addObserver(
      forName: .NEVPNStatusDidChange, object: manager.connection, queue: .main
    ) { [weak self] _ in
      guard let self, let manager = self.manager else { return }
      self.onStatusChange?(manager.connection.status)
    }
  }

  /// Saving the configuration the first time is what shows the system's
  /// "Add VPN Configurations" prompt; a refusal fails the start.
  func start(completion: @escaping (Error?) -> Void) {
    load { [weak self] existing in
      guard let self else { return }
      // Flutter repeats the start every time it attaches; re-saving a running
      // configuration would drop the tunnel it describes.
      if let existing, existing.isEnabled {
        switch existing.connection.status {
        case .connected, .connecting, .reasserting:
          completion(nil)
          return
        default:
          do {
            try existing.connection.startVPNTunnel()
            completion(nil)
            return
          } catch {
            NSLog("FlClash: saved VPN configuration refused to start: \(error)")
          }
        }
      }
      let manager = existing ?? NETunnelProviderManager()
      let configuration = NETunnelProviderProtocol()
      configuration.providerBundleIdentifier = self.tunnelBundleIdentifier
      configuration.serverAddress = "FlClash"
      configuration.disconnectOnSleep = false
      manager.protocolConfiguration = configuration
      manager.localizedDescription = "FlClash"
      manager.isEnabled = true
      manager.saveToPreferences { error in
        if let error {
          DispatchQueue.main.async { completion(error) }
          return
        }
        // A configuration saved just now must be reloaded before it starts.
        manager.loadFromPreferences { error in
          DispatchQueue.main.async {
            if let error {
              completion(error)
              return
            }
            self.adopt(manager)
            do {
              try manager.connection.startVPNTunnel()
              completion(nil)
            } catch {
              completion(error)
            }
          }
        }
      }
    }
  }

  func stop() {
    load { manager in
      manager?.connection.stopVPNTunnel()
    }
  }
}
