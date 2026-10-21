#!/usr/bin/env bash
# Packs the unsigned Runner.app from `flutter build ios --no-codesign` into an
# IPA. The binaries are fake-signed with their entitlements so TrollStore keeps
# the Network Extension and App Group grants; any other installer re-signs.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/build/ios/iphoneos/Runner.app"
output="${1:-$root/build/ios/FlClash.ipa}"
group="group.com.follow.clash"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

entitlements() {
  sed "s/\$(APP_GROUP_IDENTIFIER)/$group/" "$1" > "$2"
}
entitlements "$root/ios/Runner/Runner.entitlements" "$work/runner.plist"
entitlements "$root/ios/PacketTunnel/PacketTunnel.entitlements" "$work/tunnel.plist"

mkdir -p "$work/Payload"
cp -R "$app" "$work/Payload/"
bundle="$work/Payload/Runner.app"
find "$bundle" -name '_CodeSignature' -type d -prune -exec rm -rf {} +
ldid -S"$work/tunnel.plist" "$bundle/PlugIns/PacketTunnel.appex/PacketTunnel"
ldid -S"$work/runner.plist" "$bundle/Runner"

mkdir -p "$(dirname "$output")"
rm -f "$output"
(cd "$work" && zip -qry "$output" Payload)
echo "$output"
