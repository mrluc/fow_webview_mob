%{
  name: :mob_webview,
  mob_version: "~> 0.9.27",
  plugin_spec_version: 1,
  description: "Independent native WebView with component-owned messaging and navigation",
  nifs: [%{module: :mob_webview_nif, native_dir: "priv/native/jni"}],
  ios: %{swift_files: ["priv/native/ios/WebView.swift"], frameworks: ["WebKit", "UIKit"]},
  android: %{
    bridge_kt: "priv/native/android/WebView.kt",
    gradle_deps: ["androidx.webkit:webkit:1.12.1"]
  },
  ui_components: [
    %{
      tag: "MobWebView",
      atom: :mob_webview,
      props: [:url, :bundle, :allow, :active, :handle_back, :command, :width, :height],
      ios: %{view_module: "MobWebView_View", swift_struct: "MobWebViewNative"},
      android: %{composable: "MobWebView_View", factory: "dev.fogofwar.webview.mobWebView"}
    }
  ],
  lifecycle: %{on_start: {MobWebView, :install, []}}
}
