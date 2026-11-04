# Mob WebView

An independent native WebView component for Mob, packaged separately from Fog of War. This first version implements an ordinary WebView: persistent browser storage, URL navigation policy, JavaScript messaging, browser history, and explicit lifecycle cleanup. **Asset serving and offline caching are not implemented.**

## Status

The Elixir component and consumer screen compile. Host tests cover command routing and ordered acknowledgment. The iOS source type-checks against the iOS SDK with a shim matching Mob's public native registry; the Android source compiles against Android SDK 35, Compose, and AndroidX WebKit. These checks do not establish device behavior or full parity with Mob's built-in WebView. A native host build and device/simulator smoke test remain required.

## Use in a Mob app

Add the sibling checkout as a dependency in the host's `mix.exs`:

```elixir
{:mob_webview, path: "../mob_webview"}
```

Activate it in `mob.exs`:

```elixir
config :mob, :plugins, [:mob_webview]
```

Mob requires native plugins to be signed and trusted. For a local inspected prototype only, the host can explicitly acknowledge this unsigned plugin:

```elixir
config :mob, :acknowledge_unsafe_plugins, [:mob_webview]
```

A native rebuild is required; adding the Elixir dependency alone does not install the Swift/Kotlin implementation.

In a screen's render:

```elixir
{MobWebView.view(id: :site, url: @url, allow: ["https://example.com/"],
  weight: 1, fill_width: true, fill_height: true)}
```

The view's `:id` is an atom unique within its screen. Commands are issued from that screen process:

```elixir
MobWebView.go_back(:site)
MobWebView.go_forward(:site)
MobWebView.reload(:site)
MobWebView.eval_js(:site, "document.title")
MobWebView.post_message(:site, %{hello: "from Elixir"})
```

Commands return `{:ok, request_id}` or `{:error, :not_mounted}` and run in order. Each native completion acknowledges its request before the next is rendered. The parent receives `{:mob_webview, id, event, payload}` through `handle_info/2`. Events include `loaded`, `navigation` (URL and history availability), `blocked`, `error`, `message`, and `eval_result`.

JavaScript uses `window.mob.send(value)` and `window.mob.onMessage(callback)`. The bridge belongs to this component, not Mob's global WebView/NIF attachment. Mob's existing `Mob.WebView.*` helpers and router history shortcut do not target it; use this package's commands. Android's component Back handler and iOS back/forward gestures handle its own browser history. Forward `active: false` when a host parks the view; platform lifecycle behavior still needs device validation.

`allow` is a list of navigation URL prefixes, matching Mob's existing interface. An empty list permits any destination. Only load content whose scripts should be allowed to send messages to your app. This is not a network-subresource policy.

## Native registration

Mob's plugin manifest declares the Swift/Kotlin source files and component factories. Android's generated bootstrap passes the event sender directly. The installed iOS generator discards that callback, so the plugin's startup NIF registers an event-capable factory through the public `MobNativeViewRegistry` before the host screen starts. No Mob source patch is used. The NIF is statically linked by the native plugin build; its host stub deliberately raises if invoked without that native library.

## Tests

```sh
mix deps.get
mix test
bash test/native/typecheck-ios.sh  # macOS with an iOS SDK
bash test/native/typecheck-android.sh --help  # Cached Kotlin/Compose and SDK prerequisites
```

`test/native/typecheck-android.sh` repeats the standalone Kotlin/Compose compiler check using the installed SDK and cached compiler/AndroidX jars. It supports an explicit external WebKit AAR path and does not download dependencies or build an APK. No mobile app or emulator was built in this first pass.

## License and provenance

MIT. `LICENSES/Mob-MIT.txt` retains Mob 0.9.27's complete MIT notice, Copyright (c) 2026 Kevin Smith. The iOS design adapts Mob's WebView; the Android wrapper is independently written against public Android APIs. Retain these notices in distributed source packages and app license materials.
