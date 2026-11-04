#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
# Same public factory signature as Mob 0.9.27; does not pretend to test Mob's
# runtime or link its complete native host.
cat > "$check_dir/Registry.swift" <<'SWIFT'
import SwiftUI
public typealias MobNativeSend = (_ event: String, _ payload: [String: Any]) -> Void
public typealias MobNativeViewFactory = (_ props: [String: Any], _ send: @escaping MobNativeSend) -> AnyView
public final class MobNativeViewRegistry {
    public static let shared = MobNativeViewRegistry()
    public func register(_ name: String, factory: @escaping MobNativeViewFactory) {}
}
SWIFT
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun swiftc -typecheck -target arm64-apple-ios15.0-simulator -sdk "$sdk" "$check_dir/Registry.swift" priv/native/ios/WebView.swift
