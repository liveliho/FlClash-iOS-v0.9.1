import Flutter
import Foundation
import Mobile
import NetworkExtension

/// The iOS side of `lib/plugins/service.dart`, speaking the same two channels
/// Android's ServicePlugin does. The app links its own Core for everything
/// that works on files; while the tunnel runs, the Core routes runtime calls to
/// the extension's Core over the App Group socket (core/lib_ios.go).
final class ServicePlugin: NSObject, FlutterPlugin {
  private static let serviceChannelName = "com.follow.clash/service"
  private static let coreChannelName = "com.follow.clash/core"

  private let channel: FlutterMethodChannel
  private var commandRevision = 0
  private var runRequested = false
  private var lastStatus: NEVPNStatus = .invalid

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let messenger = registrar.messenger()
    let channel = FlutterMethodChannel(name: serviceChannelName, binaryMessenger: messenger)
    let instance = ServicePlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)

    // Serial background queue, as on Android: watchRoute keeps the latest
    // intent by the order calls reach the Core.
    let coreChannel = FlutterMethodChannel(
      name: coreChannelName,
      binaryMessenger: messenger,
      codec: FlutterStandardMethodCodec.sharedInstance(),
      taskQueue: messenger.makeBackgroundTaskQueue?())
    coreChannel.setMethodCallHandler { call, result in
      instance.handleCore(call, result: result)
    }

    MobileAttachTunnel(TunnelShared.socketPath)
    VpnController.shared.onStatusChange = { [weak instance] status in
      instance?.handleStatus(status)
    }
    VpnController.shared.load { [weak instance] _ in
      instance?.handleStatus(VpnController.shared.status)
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getHomeDir":
      result(TunnelShared.ensureHomeDirectory().path)
    case "init":
      MobileSetEventListener(CoreResultHandler { [weak self] data in
        self?.sendEvent(data)
      })
      result("")
    case "shutdown":
      MobileSetEventListener(nil)
      result(true)
    case "getRunTime":
      VpnController.shared.load { _ in
        let date = VpnController.shared.connectedDate
        result(date.map { Int($0.timeIntervalSince1970 * 1000) } ?? 0)
      }
    case "syncState":
      guard let json = call.arguments as? String else {
        result("Invalid shared state")
        return
      }
      do {
        try TunnelShared.saveSharedState(json)
        result("")
      } catch {
        result("Unable to save shared state: \(error.localizedDescription)")
      }
    case "start":
      commandRevision = call.arguments as? Int ?? commandRevision
      runRequested = true
      VpnController.shared.start { [weak self] error in
        guard let self, let error else { return }
        NSLog("FlClash: unable to start the tunnel: \(error)")
        self.reportStopped()
      }
      result(true)
    case "stop":
      commandRevision = call.arguments as? Int ?? commandRevision
      runRequested = false
      VpnController.shared.stop()
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func handleCore(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "invokeMethod" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let data = call.arguments as? String else {
      result(
        FlutterError(
          code: "INVALID_ARGUMENT", message: "Method call payload must be a string", details: nil))
      return
    }
    MobileInvokeMethod(data, CoreResultHandler { response in
      result(FlutterStandardTypedData(bytes: response))
    })
  }

  private func sendEvent(_ data: Data) {
    DispatchQueue.main.async {
      self.channel.invokeMethod("event", arguments: FlutterStandardTypedData(bytes: data))
    }
  }

  private func handleStatus(_ status: NEVPNStatus) {
    let previous = lastStatus
    lastStatus = status
    switch status {
    case .connected:
      MobileWakeTunnel()
    case .disconnected, .invalid:
      if previous == .connected || previous == .disconnecting || previous == .connecting
        || previous == .reasserting
      {
        resyncAppCore()
        if runRequested {
          reportStopped()
        }
      }
    default:
      break
    }
  }

  /// A run that ended without Flutter asking, the same report Android sends.
  private func reportStopped() {
    runRequested = false
    channel.invokeMethod("stopped", arguments: commandRevision)
  }

  /// Proxy picks made while the tunnel ran reached only the extension's Core;
  /// the app's Core takes them back from the shared state once it is gone.
  private func resyncAppCore() {
    guard let state = TunnelShared.loadSharedState(),
      let params = state["setupParams"] as? [String: Any],
      let call = TunnelShared.jsonString([
        "id": "ios-resync", "method": "setupConfig", "arguments": params,
      ])
    else {
      return
    }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
      MobileInvokeMethod(call, CoreResultHandler { _ in })
    }
  }
}
