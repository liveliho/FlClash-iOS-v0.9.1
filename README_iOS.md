# FlClash for iOS

An iOS port of [FlClash v0.9.1](https://github.com/chen08209/FlClash/releases/tag/v0.9.1)
(upstream commit `8d4f9744948751f1273fe871e1d05276fac09b0e`). The Flutter UI is
upstream's; what is new is the iOS platform layer.

## How it works

iOS only lets an app route device traffic from a **Network Extension**
(`NEPacketTunnelProvider`), which runs in its own process. So the port has two
copies of the Go core (mihomo), both built from `core/mobile` with gomobile:

| Process | Role |
| --- | --- |
| App (`ios/Runner`) | Runs the UI and a Core for file work: importing and validating profiles, share links, rule sets. It never opens listeners. |
| Tunnel (`ios/PacketTunnel`) | Runs the Core that carries traffic: reads `config.yaml` and the proxy picks the app wrote, takes the utun descriptor, serves the mixed port. |

Both share the App Group container `group.com.follow.clash`, which is the
Core's home directory. While the tunnel is up, the app's Core forwards every
runtime call (proxy switching, delay tests, connections, logs, traffic,
providers) to the tunnel's Core over a Unix socket in that container
(`core/remote`, `core/lib_ios.go`), so the UI shows and controls what actually
carries traffic. When the tunnel stops, calls fall back to the app's Core.

Dart reaches both through the same `com.follow.clash/service` and
`com.follow.clash/core` channels Android uses (`ios/Runner/ServicePlugin.swift`).

## Install

Every push builds an IPA in GitHub Actions (`.github/workflows/ios.yaml`):
open the run and download the **FlClash-ios** artifact. Tags `v*` also attach
it to a release.

The IPA is **not signed by Apple**. A VPN needs the Network Extension
entitlement, so pick one:

- **TrollStore** (supported iOS versions only): install the IPA directly. The
  binaries are fake-signed with their entitlements, so the VPN and App Group
  work as they are.
- **Paid Apple Developer account** (Sideloadly, AltStore with a paid account,
  or Xcode): re-sign it. Enable *Network Extensions → Packet Tunnel* and *App
  Groups* for both `com.follow.clash` and `com.follow.clash.PacketTunnel`. If
  your App Group ID differs from `group.com.follow.clash`, set the
  `AppGroupIdentifier` key in both Info.plists to it.
- A **free** Apple ID cannot sign Network Extensions; the app opens but the VPN
  will not start.

## Build locally (macOS)

```bash
./ios/build_core.sh                    # Go 1.27, builds ios/Frameworks/Mobile.xcframework
flutter build ios --release --no-codesign
./ios/package_ipa.sh                   # needs ldid; writes build/ios/FlClash.ipa
```

Or open `ios/Runner.xcworkspace`, set your team on both targets, and run.

## Differences from Android

- The VPN always runs as a tunnel: there is no proxy-only mode, per-app access
  control, or "allow bypass" (iOS has no such APIs for apps).
- iOS caps a packet tunnel at about 50 MB of memory. The Core sets a Go soft
  limit of 36 MB; very large profiles or rule sets may still get the tunnel
  killed by the system.
- "Exclude SSIDs" needs location permission and the Access WiFi Information
  entitlement.
- No quick-settings tile, battery optimisation or app-list features.

## License

GPL-3.0, as upstream FlClash. See `LICENSE`.
