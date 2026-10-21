import Foundation
import Mobile
import Network
import NetworkExtension

/// Runs the Go Core inside the packet tunnel, the same way Android's VpnService
/// does after its native quickSetup: config.yaml and the proxy picks come from
/// what the app last wrote to the App Group.
final class PacketTunnelProvider: NEPacketTunnelProvider {
  // mihomo's own TUN defaults, as in Android's VpnService.
  private static let ipv4Address = "198.18.0.1"
  private static let ipv4Mask = "255.255.255.252"
  private static let ipv6Address = "fdfe:dcba:9876::1"
  private static let dns4 = "198.18.0.2"
  private static let dns6 = "fdfe:dcba:9876::2"
  private static let defaultMtu = 9000
  // iOS kills a packet tunnel that passes about 50 MB; the Go heap has to stay
  // well below that with the extension's own overhead on top.
  private static let memoryLimit: Int64 = 36 << 20

  private var pathMonitor: NWPathMonitor?

  override func startTunnel(
    options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void
  ) {
    guard let state = TunnelShared.loadSharedState(),
      let vpn = state["vpnOptions"] as? [String: Any],
      let setupParams = state["setupParams"] as? [String: Any],
      let setupJson = TunnelShared.jsonString(setupParams)
    else {
      completionHandler(
        Self.error("Open FlClash and select a profile before starting the VPN."))
      return
    }
    MobileSetMemoryLimit(Self.memoryLimit)
    let systemDns = MobileSystemDns()
    MobileQuickSetup(TunnelShared.initParams(), setupJson, CoreResultHandler { [weak self] data in
      let message = String(data: data, encoding: .utf8) ?? ""
      guard let self else { return }
      if !message.isEmpty {
        completionHandler(Self.error(message))
        return
      }
      if !systemDns.isEmpty {
        MobileUpdateDns(systemDns)
      }
      self.applySettings(vpn: vpn, completionHandler: completionHandler)
    })
  }

  private func applySettings(vpn: [String: Any], completionHandler: @escaping (Error?) -> Void) {
    let ipv6 = vpn["ipv6"] as? Bool ?? false
    let settings = Self.networkSettings(vpn: vpn, ipv6: ipv6)
    setTunnelNetworkSettings(settings) { [weak self] error in
      guard let self else { return }
      if let error {
        completionHandler(error)
        return
      }
      let fd = MobileFindTunFd()
      guard fd >= 0 else {
        completionHandler(Self.error("The tunnel's file descriptor was not found."))
        return
      }
      var address = "\(Self.ipv4Address)/30"
      if ipv6 {
        address += ",\(Self.ipv6Address)/126"
      }
      let dnsHijacking = vpn["dnsHijacking"] as? Bool ?? false
      var dns = Self.dns4
      if dnsHijacking {
        dns = "0.0.0.0"
      } else if ipv6 {
        dns += ",\(Self.dns6)"
      }
      let options =
        TunnelShared.jsonString([
          "mtu": Self.mtu(vpn),
          "congestion-controller": vpn["congestionController"] as? String ?? "",
        ]) ?? "{}"
      let stack = vpn["stack"] as? String ?? "mips"
      guard MobileStartTunnel(fd, stack, address, dns, options) else {
        completionHandler(Self.error("The Core rejected the tunnel."))
        return
      }
      var serveError: NSError?
      MobileServeTunnel(TunnelShared.socketPath, &serveError)
      if let serveError {
        NSLog("FlClash: the app cannot reach this tunnel's Core: \(serveError)")
      }
      self.watchNetwork()
      completionHandler(nil)
    }
  }

  override func stopTunnel(
    with reason: NEProviderStopReason, completionHandler: @escaping () -> Void
  ) {
    pathMonitor?.cancel()
    pathMonitor = nil
    MobileStopServingTunnel()
    MobileStopTun()
    completionHandler()
  }

  override func sleep(completionHandler: @escaping () -> Void) {
    MobileForceGC()
    completionHandler()
  }

  /// The resolver the Core asks for `system` DNS and the sockets it holds both
  /// belong to the network that was current when they were made.
  private func watchNetwork() {
    let monitor = NWPathMonitor()
    var lastInterfaces: [String]?
    monitor.pathUpdateHandler = { path in
      guard path.status == .satisfied else { return }
      let interfaces = path.availableInterfaces.map(\.name)
      defer { lastInterfaces = interfaces }
      guard let previous = lastInterfaces, previous != interfaces else { return }
      let dns = MobileSystemDns()
      if !dns.isEmpty {
        MobileUpdateDns(dns)
      }
      MobileResetNetwork()
    }
    monitor.start(queue: DispatchQueue(label: "com.follow.clash.tunnel.path"))
    pathMonitor = monitor
  }

  private static func mtu(_ vpn: [String: Any]) -> Int {
    let value = vpn["mtu"] as? Int ?? 0
    return value > 0 ? min(max(value, 1280), 65535) : defaultMtu
  }

  private static func networkSettings(vpn: [String: Any], ipv6: Bool)
    -> NEPacketTunnelNetworkSettings
  {
    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
    let routes = vpn["routeAddress"] as? [String] ?? []
    let routeAll = routes.isEmpty

    let ipv4 = NEIPv4Settings(addresses: [ipv4Address], subnetMasks: [ipv4Mask])
    let routes4 = routes.compactMap(ipv4Route)
    ipv4.includedRoutes = routeAll || routes4.isEmpty ? [NEIPv4Route.default()] : routes4
    settings.ipv4Settings = ipv4

    var dnsServers = [dns4]
    if ipv6 {
      let settings6 = NEIPv6Settings(addresses: [ipv6Address], networkPrefixLengths: [126])
      let routes6 = routes.compactMap(ipv6Route)
      settings6.includedRoutes = routeAll || routes6.isEmpty ? [NEIPv6Route.default()] : routes6
      settings.ipv6Settings = settings6
      dnsServers.append(dns6)
    }

    let dnsSettings = NEDNSSettings(servers: dnsServers)
    dnsSettings.matchDomains = [""]
    settings.dnsSettings = dnsSettings
    settings.mtu = NSNumber(value: mtu(vpn))

    if vpn["systemProxy"] as? Bool ?? false, let port = vpn["port"] as? Int, port > 0 {
      let proxy = NEProxySettings()
      let server = NEProxyServer(address: "127.0.0.1", port: port)
      proxy.httpEnabled = true
      proxy.httpServer = server
      proxy.httpsEnabled = true
      proxy.httpsServer = server
      proxy.excludeSimpleHostnames = true
      proxy.exceptionList = vpn["bypassDomain"] as? [String] ?? []
      proxy.matchDomains = [""]
      settings.proxySettings = proxy
    }
    return settings
  }

  private static func splitCidr(_ cidr: String) -> (String, Int)? {
    let parts = cidr.split(separator: "/")
    guard parts.count == 2, let prefix = Int(parts[1]) else { return nil }
    return (String(parts[0]), prefix)
  }

  private static func ipv4Route(_ cidr: String) -> NEIPv4Route? {
    guard let (address, prefix) = splitCidr(cidr), IPv4Address(address) != nil,
      (0...32).contains(prefix)
    else {
      return nil
    }
    let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << (32 - UInt32(prefix))
    let subnet = [24, 16, 8, 0].map { String((mask >> UInt32($0)) & 0xff) }.joined(separator: ".")
    return NEIPv4Route(destinationAddress: address, subnetMask: subnet)
  }

  private static func ipv6Route(_ cidr: String) -> NEIPv6Route? {
    guard let (address, prefix) = splitCidr(cidr), IPv6Address(address) != nil,
      (0...128).contains(prefix)
    else {
      return nil
    }
    return NEIPv6Route(destinationAddress: address, networkPrefixLength: NSNumber(value: prefix))
  }

  private static func error(_ message: String) -> NSError {
    NSError(
      domain: "com.follow.clash.PacketTunnel", code: 1,
      userInfo: [NSLocalizedDescriptionKey: message])
  }
}
