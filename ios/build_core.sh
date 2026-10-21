#!/usr/bin/env bash
# Builds core/mobile into ios/Frameworks/Mobile.xcframework, the iOS twin of
# the bindCore task in android/core/build.gradle.kts.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tools="$(mktemp -d)"
trap 'rm -rf "$tools"' EXIT

config() { sed -n "s/^$1: *//p" "$root/build_config.yaml" | tr -d '"'; }
tags="$(config tags)"
ldflags="$(config go_ldflags)"
version="$(config core_version)"

cd "$root/core"
go build -o "$tools/" golang.org/x/mobile/cmd/gomobile golang.org/x/mobile/cmd/gobind
# gomobile links the library as the main package of a module it generates, so
# the GODEBUG defaults core/go.mod sets reach it only through this flag.
godebug="$(go list -f '{{.DefaultGODEBUG}}' ./cmd/core)"

output="$root/ios/Frameworks/Mobile.xcframework"
rm -rf "$output"
PATH="$tools:$PATH" "$tools/gomobile" bind \
  -target=ios/arm64 \
  -iosversion=15.0 \
  -tags="$tags" \
  -ldflags="$ldflags -X=github.com/metacubex/mihomo/constant.Version=$version -X=runtime.godebugDefault=$godebug" \
  -o "$output" \
  ./mobile
