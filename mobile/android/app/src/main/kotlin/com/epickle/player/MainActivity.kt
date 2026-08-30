package com.epickle.player

import android.content.Context
import android.graphics.Bitmap
import android.net.ConnectivityManager
import android.net.ProxyInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.File
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.URI
import java.net.URL
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec
import org.json.JSONArray
import org.json.JSONTokener

class MainActivity : FlutterActivity() {
    private val channelProxy = "epickle/system_proxy"
    private val channelBrowser = "epickle/browser_http"
    private val channelPrivacy = "privacy_browser/engine"
    private val channelStripchat = "epickle/stripchat_live_control"

    private val executor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val activeTasks = ConcurrentHashMap<String, HttpURLConnection>()
    private val activeRenderRequests = mutableMapOf<String, BrowserRenderRequest>()

    /// Get requests still queued on the executor. If the activity dies before
    /// they start, onDestroy answers them so the Dart side never hangs.
    private val pendingGetReplies = ConcurrentLinkedQueue<MethodChannel.Result>()
    private var stripchatView: StripchatLiveView? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // Dio cannot see Android system proxy; WebView can. Expose it to Dart.
        MethodChannel(messenger, channelProxy).setMethodCallHandler { call, result ->
            when (call.method) {
                "getSystemProxy" -> {
            // ProxySelector.select() can block on PAC evaluation; never run
            // it on the channel (main) thread. The MethodChannel result is
            // thread-safe, so answering from the executor is fine.
            executor.execute {
                try {
                    result.success(readSystemProxy())
                } catch (_: Exception) {
                    result.success(emptyProxy())
                }
            }
        }
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, channelBrowser).setMethodCallHandler { call, result ->
            val args = call.arguments as? Map<*, *>
            val rawUrl = args?.get("url") as? String
            if (rawUrl.isNullOrBlank()) {
                result.error("bad_args", "url required", null)
                return@setMethodCallHandler
            }
            val headers = (args["headers"] as? Map<*, *>)?.entries?.associate {
                it.key.toString() to it.value.toString()
            } ?: emptyMap()
            val timeoutMs = (args["timeoutMs"] as? Int) ?: 10000
            when (call.method) {
                "get" -> {
                    val safe = ReplyOnce(result)
                    pendingGetReplies.add(safe)
                    executor.execute {
                        // Running now — no longer "queued"; this task owns the reply.
                        pendingGetReplies.remove(safe)
                        try {
                            val resp = httpGet(rawUrl, headers, timeoutMs)
                            mainHandler.post { safe.success(resp) }
                        } catch (e: Exception) {
                            mainHandler.post {
                                safe.error("http_failed", e.message, null)
                            }
                        }
                    }
                }
                "getBytes" -> {
                    val safe = ReplyOnce(result)
                    pendingGetReplies.add(safe)
                    val aesKey = args?.get("aesKeyHex") as? String
                    val aesIv = args?.get("aesIvHex") as? String
                    executor.execute {
                        pendingGetReplies.remove(safe)
                        try {
                            val bytes = httpGetBytes(rawUrl, headers, timeoutMs, aesKey, aesIv)
                            mainHandler.post { safe.success(bytes) }
                        } catch (e: Exception) {
                            mainHandler.post {
                                safe.error("native_http_failed", e.message, null)
                            }
                        }
                    }
                }
                "renderGet" -> {
                    val requestId = UUID.randomUUID().toString()
                    val request = BrowserRenderRequest(
                        activity = this,
                        rawUrl = rawUrl,
                        headers = headers,
                        timeoutMs = timeoutMs,
                    ) { response, errorCode, errorMessage ->
                        activeRenderRequests.remove(requestId)
                        if (response != null) {
                            result.success(response)
                        } else {
                            result.error(
                                errorCode ?: "browser_render_failed",
                                errorMessage ?: "Browser rendering failed",
                                null,
                            )
                        }
                    }
                    activeRenderRequests[requestId] = request
                    request.start()
                }
                else -> result.notImplemented()
            }
        }

        val stripchatCh = MethodChannel(messenger, channelStripchat)
        StripchatSkipBridge.channel = stripchatCh
        stripchatCh.setMethodCallHandler { call, result ->
            when (call.method) {
                "setMuted" -> {
                    val muted = call.arguments as? Boolean ?: true
                    stripchatView?.setMuted(muted)
                    result.success(null)
                }
                "kickPlayback" -> {
                    stripchatView?.kickPlayback()
                    result.success(null)
                }
                "pauseLive" -> {
                    stripchatView?.pauseLive()
                    result.success(null)
                }
                "resumeLive" -> {
                    stripchatView?.resumeLive()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // Prefer highest refresh rate when available (120Hz etc.).
        preferHighRefreshRate()

        MethodChannel(messenger, channelPrivacy).setMethodCallHandler { call, result ->
            when (call.method) {
                "nuclearWipe" -> {
                    // Recursive deletes over app_webview/cache/files plus a
                    // synchronous prefs commit can take seconds on slow
                    // storage — never block the platform (main) thread.
                    val safe = ReplyOnce(result)
                    executor.execute {
                        try {
                            wipeEverything()
                        } catch (_: Exception) {}
                        mainHandler.post { safe.success(null) }
                    }
                }
                "exitApp" -> {
                    result.success(null)
                    mainHandler.postDelayed({ finishAffinity() }, 200)
                }
                else -> result.notImplemented()
            }
        }

        flutterEngine.platformViewsController.registry.registerViewFactory(
            "epickle/stripchat_live",
            object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
                override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
                    // Point control channel at newest instance (Flutter disposes the old one).
                    stripchatView = null
                    val params = (args as? Map<*, *>)
                    val url = params?.get("url") as? String ?: "https://stripchat.com/"
                    val muted = params?.get("muted") as? Boolean ?: true
                    val stripchatMode = params?.get("stripchatMode") as? Boolean ?: true
                    var created: StripchatLiveView? = null
                    val view = StripchatLiveView(context, url, muted, stripchatMode) {
                        // Release the strong Activity-side reference once
                        // Flutter disposes the view; otherwise the destroyed
                        // view (and its WebView) is pinned until the
                        // activity dies. Identity check: a stale instance
                        // disposed late must not drop the NEWEST view's ref.
                        if (stripchatView === created) stripchatView = null
                    }
                    created = view
                    stripchatView = view
                    return view
                }
            }
        )
    }

    private fun preferHighRefreshRate() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        try {
            val display = windowManager.defaultDisplay
            val modes = display.supportedModes ?: return
            val best = modes.maxByOrNull { it.refreshRate } ?: return
            if (best.refreshRate < 59f) return
            val lp = window.attributes
            lp.preferredDisplayModeId = best.modeId
            window.attributes = lp
        } catch (_: Exception) {}
    }

    // ---------- System proxy (for Dio; WebView already follows it) ----------

    private fun emptyProxy(): Map<String, Any?> = mapOf(
        "host" to null, "port" to null, "type" to null, "source" to "none"
    )

    private fun readSystemProxy(): Map<String, Any?> {
        // 1) JVM props (rare on Android apps)
        val hostProp = System.getProperty("http.proxyHost")
            ?: System.getProperty("https.proxyHost")
        val portProp = System.getProperty("http.proxyPort")
            ?: System.getProperty("https.proxyPort")
        if (!hostProp.isNullOrBlank() && !portProp.isNullOrBlank()) {
            val port = portProp.toIntOrNull()
            if (port != null && port in 1..65535) {
                return mapOf(
                    "host" to hostProp, "port" to port,
                    "type" to "http", "source" to "system_property"
                )
            }
        }

        // 2) ConnectivityManager.defaultProxy (Clash/V2Ray 系统代理)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            try {
                val cm = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
                val proxy: ProxyInfo? = cm.defaultProxy
                if (proxy != null) {
                    val h = proxy.host
                    val p = proxy.port
                    if (!h.isNullOrBlank() && p in 1..65535) {
                        return mapOf(
                            "host" to h, "port" to p,
                            "type" to "http", "source" to "connectivity"
                        )
                    }
                }
            } catch (_: Exception) {}
        }

        // 3) ProxySelector fallback
        try {
            val list = ProxySelector.getDefault()?.select(URI("https://www.google.com"))
            if (list != null) {
                for (px in list) {
                    if (px.type() == Proxy.Type.HTTP || px.type() == Proxy.Type.SOCKS) {
                        val addr = px.address() as? InetSocketAddress ?: continue
                        val h = addr.hostString ?: continue
                        val p = addr.port
                        if (p in 1..65535) {
                            val t = if (px.type() == Proxy.Type.SOCKS) "socks5" else "http"
                            return mapOf(
                                "host" to h, "port" to p,
                                "type" to t, "source" to "proxy_selector"
                            )
                        }
                    }
                }
            }
        } catch (_: Exception) {}

        return emptyProxy()
    }

    // ---------- HTTP GET ----------

    private fun httpGet(
        rawUrl: String, headers: Map<String, String>, timeoutMs: Int
    ): Map<String, Any?> {
        val id = UUID.randomUUID().toString()
        var conn: HttpURLConnection? = null
        try {
            val url = URL(rawUrl)
            conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = timeoutMs
                readTimeout = timeoutMs
                instanceFollowRedirects = true
                for ((k, v) in headers) setRequestProperty(k, v)
                if (headers.keys.none { it.equals("Cookie", ignoreCase = true) }) {
                    CookieManager.getInstance().getCookie(rawUrl)?.let {
                        setRequestProperty("Cookie", it)
                    }
                }
            }
            activeTasks[id] = conn
            conn.connect()
            val code = conn.responseCode
            val body = try {
                conn.inputStream.bufferedReader().use { it.readText() }
            } catch (_: Exception) {
                conn.errorStream?.bufferedReader()?.use { it.readText() } ?: ""
            }
            val cookieManager = CookieManager.getInstance()
            conn.headerFields.entries
                .filter { it.key?.equals("Set-Cookie", ignoreCase = true) == true }
                .flatMap { it.value.orEmpty() }
                .forEach { cookieManager.setCookie(conn.url.toString(), it) }
            val cookies = parseCookieHeader(cookieManager.getCookie(conn.url.toString()))
            mainHandler.post {
                try {
                    cookieManager.flush()
                } catch (_: Exception) {}
            }
            return mapOf(
                "statusCode" to code,
                "body" to body,
                "finalUrl" to conn.url.toString(),
                "cookies" to cookies
            )
        } catch (e: Exception) {
            return mapOf(
                "statusCode" to 0,
                "body" to "",
                "finalUrl" to rawUrl,
                "cookies" to emptyMap<String, String>()
            )
        } finally {
            activeTasks.remove(id)
            conn?.disconnect()
        }
    }

    // ---------- Binary GET (covers/CDN images; mirrors iOS getBytes) ----------

    /// GET returning raw bytes. When [aesKey] and [aesIv] are 16-byte ASCII
    /// strings the body is decrypted (AES-128-CBC, no padding) before being
    /// returned — HuangGuo "images" are ciphertext until decrypted.
    private fun httpGetBytes(
        rawUrl: String,
        headers: Map<String, String>,
        timeoutMs: Int,
        aesKey: String?,
        aesIv: String?,
    ): ByteArray {
        val id = UUID.randomUUID().toString()
        var conn: HttpURLConnection? = null
        try {
            val url = URL(rawUrl)
            conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = timeoutMs
                readTimeout = timeoutMs
                instanceFollowRedirects = true
                for ((k, v) in headers) setRequestProperty(k, v)
                if (headers.keys.none { it.equals("Cookie", ignoreCase = true) }) {
                    CookieManager.getInstance().getCookie(rawUrl)?.let {
                        setRequestProperty("Cookie", it)
                    }
                }
            }
            activeTasks[id] = conn
            conn.connect()
            val code = conn.responseCode
            if (code !in 200..299) {
                throw IllegalStateException("HTTP $code for $rawUrl")
            }
            val body = conn.inputStream.use { it.readBytes() }
            if (body.isEmpty()) return body
            val keyBytes = aesKey?.toByteArray(Charsets.UTF_8)
            val ivBytes = aesIv?.toByteArray(Charsets.UTF_8)
            if (keyBytes != null && ivBytes != null &&
                keyBytes.size == 16 && ivBytes.size == 16
            ) {
                return aesDecryptCbcNoPadding(body, keyBytes, ivBytes)
                    ?: throw IllegalStateException(
                        "AES decrypt failed for $rawUrl"
                    )
            }
            return body
        } finally {
            activeTasks.remove(id)
            conn?.disconnect()
        }
    }

    private fun aesDecryptCbcNoPadding(
        data: ByteArray,
        key: ByteArray,
        iv: ByteArray,
    ): ByteArray? {
        try {
            if (data.isEmpty() || data.size % 16 != 0) return null
            val cipher = Cipher.getInstance("AES/CBC/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(iv))
            return cipher.doFinal(data)
        } catch (_: Exception) {
            return null
        }
    }

    // ---------- Privacy Wipe ----------

    private fun wipeEverything() {
        try {
            CookieManager.getInstance().removeAllCookies(null)
            CookieManager.getInstance().flush()
        } catch (_: Exception) {}
        // Preserve the mirror-speed ranking across the wipe: it holds only
        // latency stats (no browsing/cookie/user data) and should survive
        // cleanup. Snapshot its keys, drop the per-process cache, delete the
        // prefs files, then restore just those keys.
        val rankingPrefsName = "FlutterSharedPreferences"
        val survivingRanking = mutableMapOf<String, String>()
        try {
            val p = getSharedPreferences(rankingPrefsName, Context.MODE_PRIVATE)
            for ((k, v) in p.all) {
                if (k.startsWith("flutter.mirror_rank_v1_") && v != null) {
                    survivingRanking[k] = v.toString()
                }
            }
            // Clearing the *instance the plugin holds* matters: deleting only
            // the XML files leaves the in-memory map intact, and the next
            // put() from Dart rewrites the entire old map — resurrecting
            // every wiped preference. commit() forces the wipe through
            // before the dirs below are deleted.
            p.edit().clear().commit()
        } catch (_: Exception) {}
        val dataDir = applicationInfo.dataDir
        File(dataDir, "app_webview").deleteRecursively()
        File(dataDir, "cache").deleteRecursively()
        File(dataDir, "files").deleteRecursively()
        File(dataDir, "shared_prefs").listFiles()?.forEach { it.delete() }
        cacheDir.deleteRecursively()
        databaseList().forEach { deleteDatabase(it) }
        if (survivingRanking.isNotEmpty()) {
            try {
                getSharedPreferences(rankingPrefsName, Context.MODE_PRIVATE)
                    .edit()
                    .apply {
                        for ((k, v) in survivingRanking) putString(k, v)
                        commit()
                    }
            } catch (_: Exception) {}
        }
    }

    override fun onDestroy() {
        activeRenderRequests.values.toList().forEach { it.cancel() }
        activeRenderRequests.clear()
        activeTasks.values.forEach { try { it.disconnect() } catch (_: Exception) {} }
        activeTasks.clear()
        // Queued-but-unstarted get/getBytes tasks would never run after
        // shutdownNow — answer them so the Dart side cannot hang forever.
        while (true) {
            val pending = pendingGetReplies.poll() ?: break
            mainHandler.post {
                try {
                    pending.error("http_failed", "Activity destroyed", null)
                } catch (_: Exception) {}
            }
        }
        executor.shutdownNow()
        super.onDestroy()
    }
}

/// Guarantees the platform-channel reply fires at most once, no matter how
/// many teardown paths race to answer the same call.
private class ReplyOnce(private val origin: MethodChannel.Result) : MethodChannel.Result {
    private val done = AtomicBoolean(false)
    private fun once(block: () -> Unit) {
        if (done.compareAndSet(false, true)) block()
    }

    override fun success(result: Any?) = once { origin.success(result) }
    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) =
        once { origin.error(errorCode, errorMessage, errorDetails) }

    override fun notImplemented() = once { origin.notImplemented() }
}

private fun parseCookieHeader(header: String?): Map<String, String> {
    if (header.isNullOrBlank()) return emptyMap()
    return header.split(';').mapNotNull { part ->
        val index = part.indexOf('=')
        if (index <= 0) return@mapNotNull null
        val name = part.substring(0, index).trim()
        if (name.isEmpty()) return@mapNotNull null
        name to part.substring(index + 1).trim()
    }.toMap()
}

private class BrowserRenderRequest(
    private val activity: MainActivity,
    private val rawUrl: String,
    private val headers: Map<String, String>,
    timeoutMs: Int,
    private val completion: (Map<String, Any?>?, String?, String?) -> Unit,
) {
    private val handler = Handler(Looper.getMainLooper())
    private val deadlineMs = System.currentTimeMillis() + timeoutMs.coerceAtLeast(1000)
    private var webView: WebView? = null
    private var completed = false
    private var statusCode = 200
    private val timeout = Runnable {
        finishError("browser_render_timeout", "Browser rendering timed out")
    }

    fun start() {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            handler.post { start() }
            return
        }
        if (completed || activity.isFinishing || activity.isDestroyed) {
            finishError("browser_render_cancelled", "Activity is unavailable")
            return
        }

        val view = WebView(activity)
        webView = view
        view.alpha = 0.01f
        view.isClickable = false
        view.settings.javaScriptEnabled = true
        view.settings.domStorageEnabled = true
        headers.entries.firstOrNull { it.key.equals("User-Agent", ignoreCase = true) }
            ?.value?.let { view.settings.userAgentString = it }
        view.webViewClient = object : WebViewClient() {
            override fun onPageStarted(view: WebView?, url: String?, favicon: Bitmap?) {
                statusCode = 200
            }

            override fun onReceivedHttpError(
                view: WebView?,
                request: WebResourceRequest?,
                errorResponse: WebResourceResponse?,
            ) {
                if (request?.isForMainFrame == true) {
                    statusCode = errorResponse?.statusCode ?: statusCode
                }
            }

            override fun onReceivedError(
                view: WebView?,
                request: WebResourceRequest?,
                error: WebResourceError?,
            ) {
                if (request?.isForMainFrame == true) {
                    finishError(
                        "browser_render_failed",
                        error?.description?.toString() ?: "Page load failed",
                    )
                }
            }

            @Deprecated("Deprecated in Java")
            override fun onReceivedError(
                view: WebView?, errorCode: Int, description: String?, failingUrl: String?,
            ) {
                // The deprecated overload also fires for subresource/ad errors;
                // only a failure of the main document itself should abort the
                // render (matches the modern main-frame-gated overload).
                val current = view?.url
                if (current == null || failingUrl == null || current == failingUrl) {
                    finishError(
                        "browser_render_failed",
                        description ?: "Page load failed ($errorCode)",
                    )
                }
            }

            override fun onPageFinished(view: WebView?, url: String?) {
                handler.postDelayed({ collectHtml() }, 800)
            }
        }

        val container = activity.window.decorView as? ViewGroup
        container?.addView(view, ViewGroup.LayoutParams(2, 2))
        val requestHeaders = headers.filterKeys {
            !it.equals("User-Agent", ignoreCase = true)
        }
        view.loadUrl(rawUrl, requestHeaders)
        handler.postDelayed(timeout, (deadlineMs - System.currentTimeMillis()).coerceAtLeast(1000))
    }

    fun cancel() {
        finishError("browser_render_cancelled", "Browser rendering cancelled")
    }

    private fun collectHtml() {
        val view = webView ?: return
        if (completed) return
        val script = """
            (() => JSON.stringify({
              html: document.documentElement ? document.documentElement.outerHTML : '',
              resources: Array.from(new Set([
                ...performance.getEntriesByType('resource').map(entry => entry.name),
                ...Array.from(document.querySelectorAll('video, source, iframe'))
                  .flatMap(node => [node.src, node.currentSrc]).filter(Boolean)
              ])).slice(0, 400),
              href: location.href
            }))()
        """.trimIndent()
        view.evaluateJavascript(script) { encoded ->
            if (completed) return@evaluateJavascript
            try {
                val jsonText = JSONTokener(encoded).nextValue() as? String
                    ?: throw IllegalStateException("Missing rendered document")
                val rendered = org.json.JSONObject(jsonText)
                var html = rendered.optString("html")
                val resources = rendered.optJSONArray("resources") ?: JSONArray()
                if (resources.length() > 0) {
                    val tags = buildString {
                        append("\n<!-- Android WebView resource URLs -->\n")
                        for (index in 0 until resources.length()) {
                            val safe = resources.optString(index)
                                .replace("\"", "%22")
                                .replace("<", "%3C")
                            append("<source src=\"").append(safe).append("\">\n")
                        }
                    }
                    html += tags
                }
                val lower = html.lowercase()
                val challengePending = lower.contains("just a moment") ||
                    lower.contains("cf-chl-") ||
                    lower.contains("checking your browser") ||
                    lower.contains("challenge-platform")
                if (challengePending && deadlineMs - System.currentTimeMillis() > 1200) {
                    handler.postDelayed({ collectHtml() }, 1000)
                    return@evaluateJavascript
                }
                val finalUrl = rendered.optString("href").ifBlank { view.url ?: rawUrl }
                finish(
                    mapOf(
                        "statusCode" to statusCode,
                        "body" to html,
                        "finalUrl" to finalUrl,
                        "cookies" to parseCookieHeader(
                            CookieManager.getInstance().getCookie(finalUrl),
                        ),
                    ),
                )
            } catch (error: Exception) {
                finishError(
                    "browser_render_javascript",
                    error.message ?: "Unable to collect rendered document",
                )
            }
        }
    }

    private fun finish(response: Map<String, Any?>) {
        if (completed) return
        completed = true
        cleanup()
        completion(response, null, null)
    }

    private fun finishError(code: String, message: String) {
        if (completed) return
        completed = true
        cleanup()
        completion(null, code, message)
    }

    private fun cleanup() {
        handler.removeCallbacks(timeout)
        webView?.let { view ->
            view.stopLoading()
            view.webViewClient = WebViewClient()
            (view.parent as? ViewGroup)?.removeView(view)
            view.destroy()
        }
        webView = null
    }
}

// ---------- Stripchat Live WebView (aligned with iOS loading UX) ----------

class StripchatLiveView(
    private val context: Context,
    private val roomUrl: String,
    private var muted: Boolean,
    private val isStripchat: Boolean,
    private val onDisposed: (() -> Unit)? = null
) : PlatformView {
    private val root = android.widget.FrameLayout(context)
    private val webView: WebView = WebView(context)
    private val overlay = android.widget.FrameLayout(context)
    private val statusLabel = android.widget.TextView(context)
    private val progress = android.widget.ProgressBar(
        context, null, android.R.attr.progressBarStyleHorizontal
    )
    private val spinner = android.widget.ProgressBar(context)
    private val retryBtn = android.widget.Button(context)
    private val skipBtn = android.widget.Button(context)
    private val handler = Handler(Looper.getMainLooper())
    private var videoRevealed = false
    private var disposed = false
    private var loadingStartedAt = 0L
    private var pageLoadedAt = 0L
    private var focusAttempts = 0
    private var errorRetries = 0
    private var livePaused = false
    private val tapDetector = GestureDetector(
        context,
        object : GestureDetector.SimpleOnGestureListener() {
            override fun onSingleTapConfirmed(e: MotionEvent): Boolean {
                toggleLivePlayback()
                return true
            }
        }
    )

    private val statusTick = object : Runnable {
        override fun run() {
            if (disposed || videoRevealed || !isStripchat) return
            val elapsed = ((System.currentTimeMillis() - loadingStartedAt) / 1000).toInt()
            if (elapsed >= 35) {
                showFailure("连接超时，请检查网络或换主播")
                return
            }
            if (pageLoadedAt > 0 &&
                System.currentTimeMillis() - pageLoadedAt >= 18_000
            ) {
                showFailure("未能捕获直播画面，主播可能离线")
                return
            }
            statusLabel.text = when {
                pageLoadedAt > 0 -> {
                    val pe = ((System.currentTimeMillis() - pageLoadedAt) / 1000).toInt()
                    "网页已加载，正在寻找直播画面… $pe 秒"
                }
                elapsed >= 12 -> "连接较慢，请检查网络… $elapsed 秒"
                else -> "正在连接直播… $elapsed 秒"
            }
            handler.postDelayed(this, 1000)
        }
    }

    private val focusTick = object : Runnable {
        override fun run() {
            if (disposed || videoRevealed || !isStripchat) return
            installVideoFocus()
            if (!disposed && !videoRevealed && focusAttempts < 25) {
                handler.postDelayed(this, 1000)
            }
        }
    }

    init {
        root.setBackgroundColor(0xFF000000.toInt())
        root.layoutParams = android.widget.FrameLayout.LayoutParams(
            android.view.ViewGroup.LayoutParams.MATCH_PARENT,
            android.view.ViewGroup.LayoutParams.MATCH_PARENT
        )
        webView.layoutParams = android.widget.FrameLayout.LayoutParams(
            android.view.ViewGroup.LayoutParams.MATCH_PARENT,
            android.view.ViewGroup.LayoutParams.MATCH_PARENT
        )
        webView.setOnTouchListener { _, event ->
            if (!isStripchat || disposed) return@setOnTouchListener false
            tapDetector.onTouchEvent(event)
            true
        }
        overlay.layoutParams = android.widget.FrameLayout.LayoutParams(
            android.view.ViewGroup.LayoutParams.MATCH_PARENT,
            android.view.ViewGroup.LayoutParams.MATCH_PARENT
        )
        configureOverlay()
        setupWebView()
        // Hide site chrome until video is found (same idea as iOS).
        if (isStripchat) {
            webView.alpha = 0f
            overlay.visibility = android.view.View.VISIBLE
        } else {
            webView.alpha = 1f
            overlay.visibility = android.view.View.GONE
        }
        root.addView(webView)
        root.addView(overlay)
        loadRoom(resetClock = true)
    }

    private fun configureOverlay() {
        overlay.setBackgroundColor(0xFF000000.toInt())
        val stack = android.widget.LinearLayout(context).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            gravity = android.view.Gravity.CENTER_HORIZONTAL
            setPadding(48, 0, 48, 0)
        }
        val stackLp = android.widget.FrameLayout.LayoutParams(
            android.view.ViewGroup.LayoutParams.WRAP_CONTENT,
            android.view.ViewGroup.LayoutParams.WRAP_CONTENT,
            android.view.Gravity.CENTER
        )
        spinner.isIndeterminate = true
        progress.max = 100
        progress.progress = 4
        progress.layoutParams = android.widget.LinearLayout.LayoutParams(440, 12).apply {
            topMargin = 28
            bottomMargin = 20
        }
        statusLabel.setTextColor(0xFFFFFFFF.toInt())
        statusLabel.textSize = 14f
        statusLabel.gravity = android.view.Gravity.CENTER
        statusLabel.text = "正在连接直播…"
        statusLabel.setPadding(0, 24, 0, 0)
        fun styleAction(btn: android.widget.Button, fill: Int) {
            btn.setTextColor(0xFFFFFFFF.toInt())
            btn.setBackgroundColor(fill)
            btn.textSize = 14f
            btn.visibility = android.view.View.GONE
            val lp = android.widget.LinearLayout.LayoutParams(
                android.view.ViewGroup.LayoutParams.WRAP_CONTENT,
                android.view.ViewGroup.LayoutParams.WRAP_CONTENT
            )
            lp.topMargin = 28
            btn.layoutParams = lp
            btn.setPadding(48, 20, 48, 20)
        }
        retryBtn.text = "重新连接"
        styleAction(retryBtn, 0xFFFF6B35.toInt())
        retryBtn.setOnClickListener { if (!disposed) loadRoom(resetClock = true) }
        skipBtn.text = "跳过"
        styleAction(skipBtn, 0xFF404040.toInt())
        skipBtn.setOnClickListener {
            try {
                // Dart listens on stripchat control channel for 'skip'
                // MainActivity holds channel; fire via static if available
                StripchatSkipBridge.emit()
            } catch (_: Exception) {}
        }
        stack.addView(spinner)
        stack.addView(statusLabel)
        stack.addView(progress)
        stack.addView(retryBtn)
        stack.addView(skipBtn)
        overlay.addView(stack, stackLp)
    }

    private fun setupWebView() {
        try {
            webView.settings.apply {
                javaScriptEnabled = true
                domStorageEnabled = true
                mediaPlaybackRequiresUserGesture = false
                loadsImagesAutomatically = true
                loadWithOverviewMode = true
                useWideViewPort = true
                mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
                cacheMode = android.webkit.WebSettings.LOAD_DEFAULT
                // Avoid hardware decoder thrash on weak networks.
                // setLayerType software is too slow; keep hardware with crash guards.
            }
            webView.setBackgroundColor(0xFF000000.toInt())
            webView.isVerticalScrollBarEnabled = false
            webView.isHorizontalScrollBarEnabled = false
            CookieManager.getInstance().setAcceptCookie(true)
            CookieManager.getInstance().setAcceptThirdPartyCookies(webView, true)
            webView.webChromeClient = object : android.webkit.WebChromeClient() {
                override fun onProgressChanged(view: WebView?, newProgress: Int) {
                    if (disposed || videoRevealed || !isStripchat) return
                    progress.progress = newProgress.coerceIn(4, 96)
                    if (newProgress >= 95 && pageLoadedAt == 0L) {
                        statusLabel.text = "网页已加载，正在寻找直播画面…"
                    }
                }
            }
            webView.webViewClient = object : WebViewClient() {
                override fun onPageStarted(view: WebView?, url: String?, favicon: android.graphics.Bitmap?) {
                    if (disposed || !isStripchat || videoRevealed) return
                    showLoading()
                }

                override fun onPageFinished(v: WebView?, url: String?) {
                    if (disposed || !isStripchat || videoRevealed) return
                    if (pageLoadedAt == 0L) pageLoadedAt = System.currentTimeMillis()
                    progress.progress = 96
                    statusLabel.text = "网页已加载，正在寻找直播画面… 0 秒"
                    focusAttempts = 0
                    handler.removeCallbacks(focusTick)
                    handler.postDelayed(focusTick, 600)
                }

                override fun shouldOverrideUrlLoading(
                    v: WebView?, request: WebResourceRequest?
                ): Boolean {
                    if (!isStripchat || request == null) return false
                    // Block popups / external ads that often crash WebView.
                    if (!request.isForMainFrame) return true
                    val host = request.url.host?.lowercase() ?: return true
                    val allowed = host == "stripchat.com" ||
                        host.endsWith(".stripchat.com") ||
                        host.contains("stripchat") ||
                        host.contains("doppiocdn") ||
                        host.contains("stripcdn")
                    return !allowed
                }

                override fun onReceivedError(
                    v: WebView?, request: WebResourceRequest?,
                    error: android.webkit.WebResourceError?
                ) {
                    if (disposed || request?.isForMainFrame != true || !isStripchat) return
                    if (videoRevealed) return
                    // One soft retry, then fail UI — never loop forever (crash risk).
                    if (errorRetries < 1) {
                        errorRetries++
                        statusLabel.text = "网络异常，正在重试…"
                        handler.postDelayed({
                            if (!disposed && !videoRevealed) loadRoom(resetClock = false)
                        }, 1500)
                    } else {
                        showFailure("网络连接失败，请检查网络后重试")
                    }
                }

                override fun onReceivedHttpError(
                    view: WebView?,
                    request: WebResourceRequest?,
                    errorResponse: android.webkit.WebResourceResponse?
                ) {
                    if (disposed || request?.isForMainFrame != true || !isStripchat) return
                    if (videoRevealed) return
                    val code = errorResponse?.statusCode ?: 0
                    if (code == 403 || code == 404 || code >= 500) {
                        showFailure("房间不可用 ($code)")
                    }
                }
            }
        } catch (_: Exception) {
            showFailure("直播组件初始化失败")
        }
    }

    private fun showLoading() {
        if (disposed || !isStripchat) return
        videoRevealed = false
        webView.alpha = 0f
        overlay.alpha = 1f
        overlay.visibility = android.view.View.VISIBLE
        spinner.visibility = android.view.View.VISIBLE
        retryBtn.visibility = android.view.View.GONE
        skipBtn.visibility = android.view.View.GONE
        progress.progress = 4
        if (loadingStartedAt == 0L) loadingStartedAt = System.currentTimeMillis()
        statusLabel.text = "正在连接直播… 0 秒"
        handler.removeCallbacks(statusTick)
        handler.post(statusTick)
    }

    private fun showFailure(message: String) {
        if (disposed || !isStripchat || videoRevealed) return
        handler.removeCallbacks(statusTick)
        handler.removeCallbacks(focusTick)
        spinner.visibility = android.view.View.GONE
        progress.progress = 100
        statusLabel.text = message
        retryBtn.visibility = android.view.View.VISIBLE
        skipBtn.visibility = android.view.View.VISIBLE
        overlay.visibility = android.view.View.VISIBLE
        overlay.alpha = 1f
        // Keep WebView hidden so site chrome never flashes on failure.
        webView.alpha = 0f
        try {
            webView.stopLoading()
            webView.loadUrl("about:blank")
        } catch (_: Exception) {}
    }

    private fun revealVideo() {
        if (disposed || videoRevealed) return
        videoRevealed = true
        handler.removeCallbacks(statusTick)
        handler.removeCallbacks(focusTick)
        webView.animate().alpha(1f).setDuration(180).start()
        overlay.animate().alpha(0f).setDuration(180).withEndAction {
            if (!disposed) overlay.visibility = android.view.View.GONE
        }.start()
    }

    private fun loadRoom(resetClock: Boolean) {
        if (disposed) return
        try {
            handler.removeCallbacks(focusTick)
            handler.removeCallbacks(statusTick)
            if (isStripchat) {
                if (resetClock) {
                    loadingStartedAt = System.currentTimeMillis()
                    pageLoadedAt = 0L
                    errorRetries = 0
                    focusAttempts = 0
                }
                showLoading()
            }
            webView.stopLoading()
            val extraHeaders = hashMapOf<String, String>()
            if (isStripchat) extraHeaders["Referer"] = "https://stripchat.com/"
            webView.loadUrl(roomUrl, extraHeaders)
            if (isStripchat) {
                handler.removeCallbacks(statusTick)
                handler.post(statusTick)
            }
        } catch (e: Exception) {
            showFailure("加载失败：${e.message ?: "unknown"}")
        }
    }

    private fun installVideoFocus() {
        if (disposed || !isStripchat || videoRevealed) return
        focusAttempts++
        val flag = if (muted) "true" else "false"
        // Hide non-video UI + promote largest video (same strategy as iOS).
        val script = """
            (function(){
              try {
                window.__epickleMuted=$flag;
                var viewport=document.querySelector('meta[name="viewport"]');
                if(!viewport){viewport=document.createElement('meta');viewport.name='viewport';document.head.appendChild(viewport)}
                viewport.content='width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover';
                if(!document.getElementById('__epickle_live_style')){
                  var s=document.createElement('style');s.id='__epickle_live_style';
                  s.textContent='html,body{margin:0!important;padding:0!important;width:100%!important;height:100%!important;overflow:hidden!important;background:#000!important}'+
                    'video{position:fixed!important;inset:0!important;width:100vw!important;height:100vh!important;object-fit:contain!important;background:#000!important;z-index:2147483647!important;visibility:visible!important}';
                  document.documentElement.appendChild(s);
                }
                var age=Array.from(document.querySelectorAll('button,a')).find(function(n){return /18|enter|agree|continue/i.test((n.textContent||'').trim())});
                if(age && !document.querySelector('video')) try{age.click()}catch(e){}
                var videos=Array.from(document.querySelectorAll('video'));
                if(!videos.length) return false;
                var ranked=videos.map(function(v){
                  var r=v.getBoundingClientRect();
                  var area=Math.max(0,r.width)*Math.max(0,r.height);
                  var active=(v.srcObject||v.currentSrc||v.src)?1e8:0;
                  var ready=v.readyState>=2?1e7:0;
                  return {v:v,score:active+ready+area};
                }).sort(function(a,b){return b.score-a.score});
                var video=ranked[0].v;
                var node=video;
                while(node){
                  var parent=node.parentElement;
                  if(parent) Array.from(parent.children).forEach(function(sib){
                    if(sib!==node){sib.style.setProperty('display','none','important');sib.style.setProperty('pointer-events','none','important')}
                  });
                  node.style.setProperty('position','fixed','important');
                  node.style.setProperty('inset','0','important');
                  node.style.setProperty('width','100vw','important');
                  node.style.setProperty('height','100vh','important');
                  node.style.setProperty('z-index','2147483647','important');
                  node.style.setProperty('background','#000','important');
                  if(node===document.documentElement) break;
                  node=parent;
                }
                video.setAttribute('playsinline','');
                video.setAttribute('webkit-playsinline','');
                video.controls=false;
                video.muted=$flag;
                video.style.setProperty('object-fit','contain','important');
                window.scrollTo(0,0);
                if(video.paused) video.play().catch(function(){});
                return true;
              } catch(e) { return false; }
            })()
        """.trimIndent()
        try {
            webView.evaluateJavascript(script) { value ->
                if (disposed || videoRevealed) return@evaluateJavascript
                val focused = value == "true"
                if (focused) {
                    revealVideo()
                } else if (focusAttempts >= 20) {
                    showFailure("未能捕获直播画面，主播可能离线")
                }
            }
        } catch (_: Exception) {
            // Ignore JS failures on dead WebView.
        }
    }

    fun setMuted(value: Boolean) {
        muted = value
        if (disposed) return
        val flag = if (value) "true" else "false"
        try {
            webView.post {
                if (disposed) return@post
                try {
                    webView.evaluateJavascript(
                        "window.__epickleMuted=$flag;document.querySelectorAll('video').forEach(function(v){v.muted=$flag;if(!v.paused&&$flag===false)v.play().catch(function(){})})"
                    ) { _ -> }
                } catch (_: Exception) {}
            }
        } catch (_: Exception) {}
    }

    /** Soft recover: re-play video elements; if not revealed yet, re-run focus. */
    fun kickPlayback() {
        if (disposed) return
        try {
            webView.post {
                if (disposed) return@post
                try {
                    if (!videoRevealed && isStripchat) {
                        // Still loading — nudge focus / age-gate instead of no-op.
                        installVideoFocus()
                        return@post
                    }
                    webView.evaluateJavascript(
                        """(function(){
                          var vs=document.querySelectorAll('video');
                          var ok=false;
                          vs.forEach(function(v){
                            try{
                              if(v.paused||v.readyState<2||v.ended){
                                v.muted=!!window.__epickleMuted;
                                var p=v.play();
                                if(p&&p.catch)p.catch(function(){});
                              }
                              if(v.readyState>=2 && !v.paused){
                                try{ v.currentTime = v.currentTime; }catch(e){}
                              }
                              ok=true;
                            }catch(e){}
                          });
                          return ok;
                        })()"""
                    ) { _ -> }
                } catch (_: Exception) {}
            }
        } catch (_: Exception) {}
    }

    fun pauseLive() {
        if (disposed) return
        livePaused = true
        try {
            webView.onPause()
            webView.evaluateJavascript(
                "document.querySelectorAll('video').forEach(function(v){try{v.pause()}catch(e){}})"
            ) { _ -> }
        } catch (_: Exception) {}
    }

    fun resumeLive() {
        if (disposed) return
        livePaused = false
        try {
            webView.onResume()
            kickPlayback()
        } catch (_: Exception) {}
    }

    private fun toggleLivePlayback() {
        if (disposed || !isStripchat) return
        if (livePaused) {
            resumeLive()
        } else {
            pauseLive()
        }
    }

    override fun getView(): android.view.View = root

    override fun dispose() {
        if (disposed) return
        disposed = true
        handler.removeCallbacksAndMessages(null)
        // Let the factory (MainActivity) drop its strong reference.
        onDisposed?.invoke()
        try {
            webView.stopLoading()
            webView.loadUrl("about:blank")
            webView.onPause()
            webView.removeAllViews()
            webView.webChromeClient = null
            webView.webViewClient = WebViewClient()
            handler.post {
                try { webView.destroy() } catch (_: Exception) {}
            }
        } catch (_: Exception) {}
    }
}

/** Bridge so overlay "跳过" can notify Flutter without holding Activity ref tightly. */
object StripchatSkipBridge {
    @Volatile var channel: MethodChannel? = null
    // One shared main-looper handler instead of allocating a Handler per emit.
    private val mainHandler = Handler(Looper.getMainLooper())
    fun emit() {
        try {
            mainHandler.post {
                channel?.invokeMethod("skip", null)
            }
        } catch (_: Exception) {}
    }
}
