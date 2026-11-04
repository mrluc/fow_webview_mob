// Standalone component inspired by Mob 0.9.27's MobWKWebView.
// Mob copyright (c) 2026 Kevin Smith, MIT; full notice: LICENSES/Mob-MIT.txt.
import Foundation
import SwiftUI
import WebKit
import UIKit

// Mob's generated factory currently omits its event callback. Register our own
// factory through the plugin's startup NIF, preserving the public registry callback.
@_cdecl("mob_webview_register")
public func mobWebViewRegister() {
    let register = {
        MobNativeViewRegistry.shared.register("MobWebView_View") { props, send in
            AnyView(MobWebViewNative(props: props, send: send).id(props["component_handle"] as? Int ?? -1))
        }
    }
    if Thread.isMainThread { register() } else { DispatchQueue.main.sync(execute: register) }
}

struct MobWebViewNative: UIViewRepresentable {
    let props: [String: Any]
    var send: MobNativeSend = { _, _ in }
    func makeCoordinator() -> Coordinator { Coordinator(props: props, send: send) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        if let bundle = props["bundle"] as? [String: Any] {
            config.setURLSchemeHandler(BundleAssets(bundle: bundle), forURLScheme: "fog-of-war-assets")
        }
        config.userContentController.add(context.coordinator, name: "mobWebView")
        let shim = """
        (()=>{const handlers=[];window.mob={
          send:value=>window.webkit.messageHandlers.mobWebView.postMessage(JSON.stringify(value)),
          onMessage:fn=>{handlers.push(fn);return()=>{const i=handlers.indexOf(fn);if(i>=0)handlers.splice(i,1)}},
          _dispatch:value=>handlers.slice().forEach(fn=>fn(value))
        }})();
        """
        config.userContentController.addUserScript(WKUserScript(source: shim, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = props["handle_back"] as? Bool ?? true
        context.coordinator.observe(view)
        context.coordinator.apply(props, to: view)
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.send = send
        context.coordinator.apply(props, to: view)
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.observations = []
        view.stopLoading()
        view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "mobWebView")
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var props: [String: Any]
        var send: MobNativeSend
        var requestedURL: String?
        var startupLoaded = false
        var lastCommand: Int64?
        var active: Bool?
        var observations: [NSKeyValueObservation] = []
        func observe(_ view: WKWebView) {
            observations = [
                view.observe(\.url, options: [.new]) { [weak self] view, _ in self?.navigation(view) },
                view.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in self?.navigation(view) },
                view.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in self?.navigation(view) }
            ]
        }
        init(props: [String: Any], send: @escaping MobNativeSend) { self.props = props; self.send = send }
        func apply(_ props: [String: Any], to view: WKWebView) {
            self.props = props
            let enabled = props["active"] as? Bool ?? true
            if active != enabled {
                active = enabled
                view.isUserInteractionEnabled = enabled
                if #available(iOS 15.0, *) { view.setAllMediaPlaybackSuspended(!enabled) }
            }
            view.allowsBackForwardNavigationGestures = props["handle_back"] as? Bool ?? true
            if let text = props["url"] as? String, text != requestedURL, let url = URL(string: text) {
                requestedURL = text
                if allowed(url) {
                    if !startupLoaded, let bundle = props["bundle"] as? [String: Any],
                       bundle["url"] as? String == text, let file = bundle["startup"] as? String {
                        startupLoaded = true
                        do {
                            let bytes = try Data(contentsOf: URL(fileURLWithPath: file))
                            if #available(iOS 15.0, *) {
                                let response = URLResponse(url: url, mimeType: "text/html", expectedContentLength: bytes.count, textEncodingName: "utf-8")
                                view.loadSimulatedRequest(URLRequest(url: url), response: response, responseData: bytes)
                            } else { send("error", ["url": text, "message": "Bundled startup requires iOS 15 or newer"]) }
                        } catch { send("error", ["url": text, "message": "Bundled startup could not be read"]) }
                    } else { view.load(URLRequest(url: url)) }
                } else { send("blocked", ["url": text]) }
            }
            if let command = props["command"] as? [String: Any], let number = command["id"] as? NSNumber {
                let id = number.int64Value
                if id != lastCommand { lastCommand = id; run(command, id: id, in: view) }
            }
        }
        func allowed(_ url: URL) -> Bool {
            let prefixes = props["allow"] as? [String] ?? []
            return prefixes.isEmpty || prefixes.contains { url.absoluteString.hasPrefix($0) }
        }
        func navigation(_ view: WKWebView) {
            send("navigation", ["url": view.url?.absoluteString ?? "", "can_go_back": view.canGoBack, "can_go_forward": view.canGoForward])
        }
        func run(_ command: [String: Any], id: Int64, in view: WKWebView) {
            let finish = { self.send("command_done", ["id": id]) }
            switch command["action"] as? String {
            case "go_back": view.goBack()
            case "go_forward": view.goForward()
            case "reload": view.reload()
            case "eval_js", "post_message":
                let source: String
                if command["action"] as? String == "eval_js" { source = command["code"] as? String ?? "" }
                else {
                    do {
                        let data = try JSONSerialization.data(withJSONObject: command["data"] ?? NSNull(), options: [.fragmentsAllowed])
                        source = "window.mob._dispatch(\(String(data: data, encoding: .utf8)!))"
                    } catch { send("error", ["url": view.url?.absoluteString ?? "", "message": error.localizedDescription]); finish(); return }
                }
                view.evaluateJavaScript(source) { result, error in
                    if let error = error { self.send("error", ["url": view.url?.absoluteString ?? "", "message": error.localizedDescription]) }
                    else if command["action"] as? String == "eval_js" { self.send("eval_result", ["id": id, "result": result ?? NSNull()]) }
                    finish()
                }
                return
            default: send("error", ["url": view.url?.absoluteString ?? "", "message": "Unknown WebView command"])
            }
            navigation(view); finish()
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let text = message.body as? String, let data = text.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return }
            send("message", ["data": value])
        }
        func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = action.request.url, !allowed(url) {
                send("blocked", ["url": url.absoluteString]); decisionHandler(.cancel)
            } else { decisionHandler(.allow) }
        }
        func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
            send("loaded", ["url": view.url?.absoluteString ?? ""]); self.navigation(view)
        }
        func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failure(view, error) }
        func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failure(view, error) }
        func webViewWebContentProcessDidTerminate(_ view: WKWebView) { send("error", ["url": view.url?.absoluteString ?? "", "message": "Web content process terminated"]) }
        func failure(_ view: WKWebView, _ error: Error) {
            send("error", ["url": view.url?.absoluteString ?? "", "code": (error as NSError).code, "message": error.localizedDescription])
        }
    }
}

// A closed allowlist; incoming URL paths are never joined to the filesystem.
private final class BundleAssets: NSObject, WKURLSchemeHandler {
    private let files: [String: [String: Any]]
    init(bundle: [String: Any]) { files = bundle["files"] as? [String: [String: Any]] ?? [:] }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil; components?.fragment = nil
        guard task.request.httpMethod == "GET", let key = components?.url?.absoluteString,
              let entry = files[key], let file = entry["file"] as? String,
              let data = try? Data(contentsOf: URL(fileURLWithPath: file)) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": entry["mime"] as? String ?? "application/octet-stream",
            "Content-Length": String(data.count), "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"
        ])!
        task.didReceive(response); task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
