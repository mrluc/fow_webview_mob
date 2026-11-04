// Plugin-owned Android WebView, independently implemented with public Android APIs.
// Mob's WebView informed the feature list; this file does not copy its native implementation.
package dev.fogofwar.webview

import android.annotation.SuppressLint
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.ViewGroup
import android.webkit.JavascriptInterface
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener

private typealias Send = (String, Map<String, Any>) -> Unit

private val bridgeScript = """
(() => {
  if (window.mob) return;
  const subscribers = new Set();
  window.mob = {
    send(value) { MobWebViewNative.postMessage(JSON.stringify(value)); },
    onMessage(callback) { subscribers.add(callback); return () => subscribers.delete(callback); },
    _dispatch(value) { for (const callback of [...subscribers]) callback(value); }
  };
})();
""".trimIndent()

private fun strings(value: Any?): List<String> = when (value) {
    is List<*> -> value.filterIsInstance<String>()
    is JSONArray -> (0 until value.length()).mapNotNull { value.opt(it) as? String }
    else -> emptyList()
}

private fun fields(value: Any?): Map<String, Any?> = when (value) {
    is JSONObject -> value.keys().asSequence().associateWith { value.opt(it) }
    is Map<*, *> -> value.entries.mapNotNull { (key, item) -> (key as? String)?.let { it to item } }.toMap()
    else -> emptyMap()
}

// Events cross Mob's JSON component bridge, so nested JSON values remain JSON values.
private fun jsonValue(raw: String?): Any = try { JSONTokener(raw ?: "null").nextValue() ?: JSONObject.NULL } catch (_: Exception) { JSONObject.NULL }

private class JsBridge(private val emit: (String, Map<String, Any>) -> Unit) {
    @JavascriptInterface fun postMessage(json: String) = emit("message", mapOf("data" to jsonValue(json)))
}

/** Plugin-owned WebView. It does not attach to Mob's global built-in WebView slot. */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun mobWebView(props: Map<String, Any?>, send: (String, Map<String, Any>) -> Unit) {
    val currentSend = rememberUpdatedState(send)
    val currentAllow = rememberUpdatedState(strings(props["allow"]))
    val active = props["active"] as? Boolean ?: true
    var browser by remember { mutableStateOf<WebView?>(null) }
    var disposed by remember { mutableStateOf(false) }
    var canGoBack by remember { mutableStateOf(false) }
    var requestedUrl by remember { mutableStateOf<String?>(null) }
    var lastCommand by remember { mutableStateOf<Any?>(null) }
    var fileCallback by remember { mutableStateOf<ValueCallback<Array<Uri>>?>(null) }
    val main = remember { Handler(Looper.getMainLooper()) }
    val emit: Send = { event, payload -> main.post { if (!disposed) currentSend.value(event, payload) } }
    val navigation: (WebView) -> Unit = { view ->
        canGoBack = view.canGoBack()
        emit("navigation", mapOf("url" to (view.url ?: ""), "can_go_back" to view.canGoBack(), "can_go_forward" to view.canGoForward()))
    }
    val filePicker = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        fileCallback?.onReceiveValue(WebChromeClient.FileChooserParams.parseResult(result.resultCode, result.data))
        fileCallback = null
    }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle, browser, active) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> if (active) browser?.onResume()
                Lifecycle.Event.ON_PAUSE -> browser?.onPause()
                else -> Unit
            }
        }
        lifecycle.addObserver(observer)
        if (active && lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) browser?.onResume() else browser?.onPause()
        onDispose { lifecycle.removeObserver(observer) }
    }
    DisposableEffect(Unit) {
        onDispose {
            disposed = true
            fileCallback?.onReceiveValue(null)
            fileCallback = null
            browser?.apply { stopLoading(); removeJavascriptInterface("MobWebViewNative"); destroy() }
            browser = null
        }
    }
    BackHandler(enabled = active && (props["handle_back"] as? Boolean ?: true) && canGoBack) { browser?.goBack() }
    AndroidView(
        modifier = Modifier.fillMaxSize(),
        factory = { context ->
            WebView(context).apply {
                layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                settings.useWideViewPort = true
                settings.loadWithOverviewMode = true
                // Arbitrary file access is unnecessary for ordinary remote pages.
                settings.allowFileAccess = false
                addJavascriptInterface(JsBridge(emit), "MobWebViewNative")
                if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
                    WebViewCompat.addDocumentStartJavaScript(this, bridgeScript, setOf("*"))
                }
                webViewClient = object : WebViewClient() {
                    override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                        val target = request.url.toString()
                        if (currentAllow.value.isEmpty() || currentAllow.value.any { target.startsWith(it) }) return false
                        emit("blocked", mapOf("url" to target)); return true
                    }
                    override fun onPageFinished(view: WebView, url: String) {
                        // Also handles providers without document-start JavaScript support.
                        view.evaluateJavascript(bridgeScript, null)
                        navigation(view)
                        emit("loaded", mapOf("url" to url))
                    }
                    override fun doUpdateVisitedHistory(view: WebView, url: String?, isReload: Boolean) { navigation(view) }
                    override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                        if (request.isForMainFrame) emit("error", mapOf("url" to request.url.toString(), "code" to error.errorCode, "message" to error.description.toString()))
                    }
                }
                webChromeClient = object : WebChromeClient() {
                    override fun onShowFileChooser(view: WebView?, callback: ValueCallback<Array<Uri>>?, params: FileChooserParams?): Boolean {
                        fileCallback?.onReceiveValue(null); fileCallback = callback
                        return try {
                            val intent = params?.createIntent()
                            if (intent == null) { fileCallback?.onReceiveValue(null); fileCallback = null; false }
                            else { filePicker.launch(intent); true }
                        } catch (_: Exception) { fileCallback?.onReceiveValue(null); fileCallback = null; false }
                    }
                }
                browser = this
            }
        },
        update = { view ->
            val url = props["url"] as? String ?: ""
            if (url.isNotEmpty() && requestedUrl != url) {
                requestedUrl = url
                if (currentAllow.value.isEmpty() || currentAllow.value.any { url.startsWith(it) }) view.loadUrl(url)
                else emit("blocked", mapOf("url" to url))
            }
            val command = fields(props["command"])
            val id = command["id"]
            if (id != null && id != JSONObject.NULL && id != lastCommand) {
                lastCommand = id
                val completed = { emit("command_done", mapOf("id" to id)) }
                when (command["action"] as? String) {
                    "go_back" -> { if (view.canGoBack()) view.goBack(); completed() }
                    "go_forward" -> { if (view.canGoForward()) view.goForward(); completed() }
                    "reload" -> { view.reload(); completed() }
                    "eval_js" -> view.evaluateJavascript(command["code"] as? String ?: "") { result -> emit("eval_result", mapOf("id" to id, "result" to jsonValue(result))); completed() }
                    "post_message" -> {
                        val data = JSONObject.wrap(command["data"])
                        val json = JSONArray().put(data).toString().drop(1).dropLast(1)
                        view.evaluateJavascript("window.mob&&window.mob._dispatch(${json})") { completed() }
                    }
                    else -> {
                        emit("error", mapOf("url" to (view.url ?: ""), "code" to 0, "message" to "Unsupported WebView command"))
                        completed()
                    }
                }
            }
        }
    )
}
