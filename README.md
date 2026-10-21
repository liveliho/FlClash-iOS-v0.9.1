<div align="center">

<img src="ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png" width="120" alt="FlClash">

# FlClash iOS

基于 [FlClash v0.9.1](https://github.com/chen08209/FlClash/releases/tag/v0.9.1) 移植的 iOS 版本
ClashMeta（mihomo）内核 · Flutter 界面 · Network Extension 全局 VPN

[下载 IPA](../../releases/latest) · [构建记录](../../actions/workflows/ios.yaml) · [原版 README](README_upstream.md)

</div>

## 简介

FlClash 官方只提供 Android、Windows、macOS 和 Linux 版本。本仓库在 v0.9.1 源码
（上游提交 `8d4f9744948751f1273fe871e1d05276fac09b0e`）的基础上补齐了 iOS 平台层，
界面和功能沿用原版：订阅/配置导入、代理组切换、延迟测试、连接与日志查看、规则与
覆写、脚本、DNS 设置等。

## 下载与安装

在 [Releases](../../releases/latest) 下载 `FlClash-*-ios-arm64.ipa`。每次推送到 `main`
都会自动构建，最新构建也可以在 [Actions](../../actions/workflows/ios.yaml) 页面底部的
**FlClash-ios** 产物里下载。

IPA **没有 Apple 官方签名**。VPN 需要 Network Extension 权限，请按你的情况选择：

| 安装方式 | VPN 能否使用 | 说明 |
| --- | --- | --- |
| **TrollStore 巨魔商店** | ✅ | 直接安装即可。IPA 已用 ldid 写入权限（Network Extension、App Group）。仅支持 TrollStore 可用的 iOS 版本。 |
| **付费开发者账号**（Sideloadly、AltStore、Xcode 等） | ✅ | 重签名时为 `com.follow.clash` 和 `com.follow.clash.PacketTunnel` 两个 ID 开启 *Network Extensions → Packet Tunnel* 和 *App Groups*。如果你的 App Group ID 不是 `group.com.follow.clash`，请把两个 Info.plist 里的 `AppGroupIdentifier` 改成你的 ID。 |
| **免费 Apple ID** | ❌ | 免费账号无法签名 Network Extension，应用能打开，但无法启动 VPN。 |

系统要求：iOS 15 及以上，arm64 设备。

## 使用

1. 打开应用，在「配置」里添加订阅链接或导入配置文件（也支持扫码和 `clash://`、`flclash://` 链接）。
2. 回到首页点击启动，第一次会弹出「添加 VPN 配置」，点「允许」。
3. 启动后可以在「代理」页切换节点、测延迟，在「连接」「日志」页查看流量。

## 实现原理

iOS 只允许通过 **Network Extension**（`NEPacketTunnelProvider`）接管设备流量，它运行在
独立进程中。因此本移植把 Go 内核用 gomobile 编译成 `Mobile.xcframework`，分别放进两个进程：

| 进程 | 作用 |
| --- | --- |
| 主应用 `ios/Runner` | 运行 Flutter 界面，以及一个只处理文件的内核：导入/校验配置、分享链接、规则集等。不监听任何端口。 |
| 隧道扩展 `ios/PacketTunnel` | 真正承载流量的内核：读取主应用写入的 `config.yaml` 和节点选择，接管 utun，提供混合代理端口。 |

两个进程共享 App Group 容器 `group.com.follow.clash`，它就是内核的工作目录。VPN 运行时，
主应用的内核会把所有运行时调用（切换节点、测延迟、连接、日志、流量、Provider 更新）通过
容器里的 Unix socket 转发给隧道里的内核（`core/remote`、`core/lib_ios.go`），所以界面看到
和控制的就是实际在跑流量的内核；VPN 停止后自动切回主应用内核。

Dart 层通过与 Android 相同的 `com.follow.clash/service`、`com.follow.clash/core` 通道和原生
层通信（`ios/Runner/ServicePlugin.swift`），所以上游界面代码几乎不用改。

主要改动：

- `core/`：Go 内核支持 `GOOS=ios`；新增 `core/remote`（主应用 ↔ 隧道的 socket 通道）。
- `core/Clash.Meta`：子模块改为直接包含源码，系统 DNS 补丁扩展到 iOS。
- `ios/`：Runner 主应用 + PacketTunnel 扩展、Swift 原生插件、权限配置。
- `lib/`：Dart 层把 iOS 当作移动端服务平台，数据目录放在 App Group。
- `plugins/rust_api`：Rust 库支持 `aarch64-apple-ios`。
- `.github/workflows/ios.yaml`：在 GitHub 的 macOS 机器上自动构建 IPA。

## 自行构建

需要 macOS + Xcode 26、Flutter 3.47.6、Go 1.27、Rust（版本见 `plugins/rust_api/rust/rust-toolchain.toml`）、ldid：

```bash
./ios/build_core.sh                          # 编译 Go 内核 → ios/Frameworks/Mobile.xcframework
flutter build ios --release --no-codesign    # 编译应用
./ios/package_ipa.sh                         # 写入权限并打包 → build/ios/FlClash.ipa
```

也可以打开 `ios/Runner.xcworkspace`，给两个 target 选择你的开发团队后直接运行到真机。

## 与 Android 版的差异

- 只能以 VPN 方式运行：没有「仅代理」模式、分应用代理和「允许绕过」（iOS 不提供这些接口）。
- iOS 限制隧道扩展内存约 50 MB。内核设置了 36 MB 的 Go 内存软上限，超大配置或规则集仍可能被系统结束。
- 「排除 Wi-Fi」需要定位权限和 Access WiFi Information 权限。
- 没有快捷开关磁贴、电池优化、应用列表等 Android 专属功能。
- 目前只在 CI 中完成编译，尚未在真机上做完整测试，遇到问题欢迎提 Issue。

## 许可证

与上游 FlClash 相同，使用 GPL-3.0，见 [LICENSE](LICENSE)。FlClash 原作者为
[chen08209](https://github.com/chen08209)，mihomo 内核来自 [MetaCubeX](https://github.com/MetaCubeX/mihomo)。
