import CommonCrypto
import Flutter
import UIKit
import WebKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var privacyChannel: FlutterMethodChannel?
  private var browserHttpChannel: FlutterMethodChannel?
  private var stripchatControlChannel: FlutterMethodChannel?
  private var browserTasks: [UUID: URLSessionDataTask] = [:]
  private var browserRenderRequests: [UUID: BrowserRenderRequest] = [:]
  private var privacyOverlay: UIView?

  /// 站点 worker 里的 media_key / media_iv 是 16 字符 ASCII 原文
  /// （如 "f5d965df75336270"），即 16 字节 UTF-8 key/iv，不是 hex。
  private static func dataFromAscii(_ ascii: String) -> Data? {
    let bytes = Array(ascii.utf8)
    guard bytes.count == 16 else { return nil }
    return Data(bytes)
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let messenger = engineBridge.applicationRegistrar.messenger()
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "epickle_stripchat_live"
    ) {
      registrar.register(
        StripchatLiveViewFactory(),
        withId: "epickle/stripchat_live"
      )
    }
    let stripchatChannel = FlutterMethodChannel(
      name: "epickle/stripchat_live_control",
      binaryMessenger: messenger
    )
    stripchatControlChannel = stripchatChannel
    stripchatChannel.setMethodCallHandler { call, result in
      guard let view = StripchatLivePlatformView.activeView.value else {
        result(nil)
        return
      }
      switch call.method {
      case "setMuted":
        guard let muted = call.arguments as? Bool else {
          result(FlutterError(
            code: "bad_args",
            message: "setMuted requires a Boolean argument",
            details: nil
          ))
          return
        }
        view.setMuted(muted)
      case "pauseLive":
        view.pauseLive()
      case "resumeLive":
        view.resumeLive()
      case "kickPlayback":
        view.kickPlayback()
      default:
        result(FlutterMethodNotImplemented)
        return
      }
      result(nil)
    }

    let channel = FlutterMethodChannel(
      name: "privacy_browser/engine",
      binaryMessenger: messenger
    )
    privacyChannel = channel
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "nuclearWipe":
        PrivacyNativeWipe.run {
          result(nil)
        }
      case "clearLaunchCache":
        PrivacyNativeWipe.clearLaunchCache()
        result(nil)
      case "exitApp":
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
          exit(0)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let browserChannel = FlutterMethodChannel(
      name: "epickle/browser_http",
      binaryMessenger: messenger
    )
    browserHttpChannel = browserChannel
    browserChannel.setMethodCallHandler { [weak self] call, result in
      guard let self,
            let arguments = call.arguments as? [String: Any],
            let rawUrl = arguments["url"] as? String,
            let url = URL(string: rawUrl) else {
        result(FlutterMethodNotImplemented)
        return
      }

      let headers = (arguments["headers"] as? [String: Any])?.reduce(
        into: [String: String]()
      ) { output, entry in
        output[entry.key] = String(describing: entry.value)
      } ?? [:]
      let timeoutMs = arguments["timeoutMs"] as? Int ?? 10000

      switch call.method {
      case "get":
        self.startBrowserGet(
          url: url,
          headers: headers,
          timeoutMs: timeoutMs,
          result: result
        )
      case "getBytes":
        self.startBrowserGetBytes(
          url: url,
          headers: headers,
          timeoutMs: timeoutMs,
          aesKeyHex: arguments["aesKeyHex"] as? String,
          aesIvHex: arguments["aesIvHex"] as? String,
          result: result
        )
      case "renderGet":
        self.startBrowserRender(
          url: url,
          headers: headers,
          timeoutMs: timeoutMs,
          result: result
        )
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // Dio cannot see iOS system proxy; URLSession/WebView can. Expose it to Dart.
    let systemProxyChannel = FlutterMethodChannel(
      name: "epickle/system_proxy",
      binaryMessenger: messenger
    )
    systemProxyChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "getSystemProxy":
        result(SystemProxyReader.systemProxyInfo())
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let fileUtilsChannel = FlutterMethodChannel(
      name: "epickle/file_utils",
      binaryMessenger: messenger
    )
    fileUtilsChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "excludeFromBackup":
        guard let path = call.arguments as? String, !path.isEmpty else {
          result(false)
          return
        }
        var url = URL(fileURLWithPath: path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
          try url.setResourceValues(values)
          result(true)
        } catch {
          result(false)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  override func applicationWillResignActive(_ application: UIApplication) {
    // Cover the app-switcher snapshot with an opaque overlay so sensitive
    // player content is never visible in the task switcher / screenshots.
    installPrivacyOverlay()
    super.applicationWillResignActive(application)
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    removePrivacyOverlay()
    super.applicationDidBecomeActive(application)
  }

  override func applicationDidEnterBackground(_ application: UIApplication) {
    // Do NOT cancel in-flight browser requests here: iOS fires this on nearly
    // every brief backgrounding (Control Center, calls, app switcher), and
    // cancelling made feed loads fail silently while backgrounded. Requests
    // carry their own timeout; completed callbacks are delivered on resume.
    super.applicationDidEnterBackground(application)
  }

  override func applicationWillTerminate(_ application: UIApplication) {
    cancelBrowserRequests()
    super.applicationWillTerminate(application)
  }

  private func installPrivacyOverlay() {
    guard privacyOverlay == nil, let window = activeWindow else { return }
    let overlay = UIView(frame: window.bounds)
    overlay.backgroundColor = .black
    overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    window.addSubview(overlay)
    privacyOverlay = overlay
  }

  private func removePrivacyOverlay() {
    privacyOverlay?.removeFromSuperview()
    privacyOverlay = nil
  }

  private func startBrowserGet(
    url: URL,
    headers: [String: String],
    timeoutMs: Int,
    result: @escaping FlutterResult
  ) {
    let requestId = UUID()
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = max(1, Double(timeoutMs) / 1000.0)
    for (name, value) in headers {
      request.setValue(value, forHTTPHeaderField: name)
    }

    let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      DispatchQueue.main.async {
        self?.browserTasks.removeValue(forKey: requestId)
        if let error = error {
          result(FlutterError(
            code: "native_http_failed",
            message: error.localizedDescription,
            details: nil
          ))
          return
        }
        guard let http = response as? HTTPURLResponse else {
          result(FlutterError(
            code: "native_http_invalid_response",
            message: "Missing HTTP response",
            details: nil
          ))
          return
        }
        let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        var cookies: [String: String] = [:]
        let finalUrl = http.url ?? url
        HTTPCookieStorage.shared.cookies(for: finalUrl)?.forEach {
          cookies[$0.name] = $0.value
        }
        result([
          "statusCode": http.statusCode,
          "body": body,
          "finalUrl": finalUrl.absoluteString,
          "cookies": cookies,
        ])
      }
    }
    browserTasks[requestId] = task
    task.resume()
  }

  private func startBrowserGetBytes(
    url: URL,
    headers: [String: String],
    timeoutMs: Int,
    aesKeyHex: String?,
    aesIvHex: String?,
    result: @escaping FlutterResult
  ) {
    let requestId = UUID()
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    // Media bytes (images) benefit from the shared URL cache; feeds still use
    // reload-ignoring policy in startBrowserGet to stay fresh.
    request.cachePolicy = .useProtocolCachePolicy
    request.timeoutInterval = max(1, Double(timeoutMs) / 1000.0)
    for (name, value) in headers {
      request.setValue(value, forHTTPHeaderField: name)
    }

    let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      DispatchQueue.main.async {
        self?.browserTasks.removeValue(forKey: requestId)
        if let error {
          result(FlutterError(
            code: "native_http_failed",
            message: error.localizedDescription,
            details: nil
          ))
          return
        }
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              var payload = data, !payload.isEmpty else {
          result(FlutterError(
            code: "native_http_bad_response",
            message: "Bad HTTP response for \(url.absoluteString)",
            details: nil
          ))
          return
        }
        if let keyHex = aesKeyHex, let ivHex = aesIvHex {
          guard let key = AppDelegate.dataFromAscii(keyHex), key.count == 16,
                let iv = AppDelegate.dataFromAscii(ivHex), iv.count == 16,
                let plain = self?.aesDecryptCBCNoPadding(payload, key: key, iv: iv) else {
            NSLog("[ePickle] AES decrypt failed for %@ (keyLen=%d ivLen=%d dataLen=%d)",
                  url.absoluteString, keyHex.count, ivHex.count, payload.count)
            result(FlutterError(
              code: "native_http_decrypt_failed",
              message: "AES decrypt failed for \(url.absoluteString)",
              details: nil
            ))
            return
          }
          payload = plain
        }
        result(FlutterStandardTypedData(bytes: payload))
      }
    }
    browserTasks[requestId] = task
    task.resume()
  }

  private func aesDecryptCBCNoPadding(_ data: Data, key: Data, iv: Data) -> Data? {
    guard data.count % 16 == 0, data.count > 0 else { return nil }
    var out = Data(count: data.count)
    var numOut = 0
    let status = out.withUnsafeMutableBytes { (outBuf: UnsafeMutableRawBufferPointer) -> Int32 in
      guard let outBase = outBuf.baseAddress else { return Int32(kCCParamError) }
      return data.withUnsafeBytes { (inBuf: UnsafeRawBufferPointer) in
        guard let inBase = inBuf.baseAddress else { return Int32(kCCParamError) }
        return key.withUnsafeBytes { (kBuf: UnsafeRawBufferPointer) in
          guard let kBase = kBuf.baseAddress else { return Int32(kCCParamError) }
          return iv.withUnsafeBytes { (ivBuf: UnsafeRawBufferPointer) in
            guard let ivBase = ivBuf.baseAddress else { return Int32(kCCParamError) }
            return CCCrypt(
              CCOperation(kCCDecrypt),
              CCAlgorithm(kCCAlgorithmAES),
              CCOptions(0), // CBC, no padding
              kBase, kBuf.count,
              ivBase,
              inBase, inBuf.count,
              outBase, outBuf.count,
              &numOut
            )
          }
        }
      }
    }
    return status == kCCSuccess ? out : nil
  }

  private func startBrowserRender(
    url: URL,
    headers: [String: String],
    timeoutMs: Int,
    result: @escaping FlutterResult
  ) {
    let requestId = UUID()
    let request = BrowserRenderRequest(
      url: url,
      headers: headers,
      timeout: max(1, Double(timeoutMs) / 1000.0)
    ) { [weak self] payload, error in
      self?.browserRenderRequests.removeValue(forKey: requestId)
      if let error {
        result(error)
      } else {
        result(payload)
      }
    }
    browserRenderRequests[requestId] = request
    request.start(in: activeWindow?.rootViewController?.view)
  }

  /// Scene-based lifecycle: FlutterAppDelegate.window is never populated, so
  /// resolve the foreground scene's key window instead.
  private var activeWindow: UIWindow? {
    if let window {
      return window
    }
    return UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }?
      .keyWindow
  }

  private func cancelBrowserRequests() {
    browserTasks.values.forEach { $0.cancel() }
    browserTasks.removeAll()
    let renderRequests = Array(browserRenderRequests.values)
    browserRenderRequests.removeAll()
    renderRequests.forEach { $0.cancel() }
  }
}

private final class WeakBox<T: AnyObject> {
  weak var value: T?
}

private final class StripchatLiveViewFactory: NSObject, FlutterPlatformViewFactory {
  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    StripchatLivePlatformView(frame: frame, arguments: args)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
}

private final class StripchatLivePlatformView: NSObject,
  FlutterPlatformView,
  WKNavigationDelegate,
  WKUIDelegate {
  static let activeView = WeakBox<StripchatLivePlatformView>()

  private let containerView: UIView
  private let webView: WKWebView
  private let loadingOverlay: UIView
  private let loadingIndicator: UIActivityIndicatorView
  private let loadingProgress: UIProgressView
  private let statusLabel: UILabel
  private let speedLabel: UILabel
  private let retryButton: UIButton
  private let isStripchat: Bool
  private var muted: Bool
  private var livePaused = false
  private var focusTimer: Timer?
  private var statusTimer: Timer?
  private var progressObservation: NSKeyValueObservation?
  private var roomRequest: URLRequest?
  private var loadingStartedAt: Date?
  private var pageLoadedAt: Date?
  private var videoRevealed = false
  private var lastTransferBytes: Int64 = 0
  private var lastTransferAt: Date?
  private var currentSpeedText = "—"

  init(frame: CGRect, arguments: Any?) {
    let values = arguments as? [String: Any]
    let rawUrl = values?["url"] as? String ?? "https://stripchat.com/"
    muted = values?["muted"] as? Bool ?? true
    isStripchat = values?["stripchatMode"] as? Bool ?? true

    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    configuration.preferences.javaScriptEnabled = true
    configuration.allowsInlineMediaPlayback = true
    configuration.mediaTypesRequiringUserActionForPlayback = []
    containerView = UIView(frame: frame)
    webView = WKWebView(frame: frame, configuration: configuration)
    loadingOverlay = UIView(frame: frame)
    loadingIndicator = UIActivityIndicatorView(style: .large)
    loadingProgress = UIProgressView(progressViewStyle: .default)
    statusLabel = UILabel()
    speedLabel = UILabel()
    retryButton = UIButton(type: .system)
    super.init()

    StripchatLivePlatformView.activeView.value = self
    containerView.backgroundColor = .black
    webView.frame = containerView.bounds
    webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    loadingOverlay.frame = containerView.bounds
    loadingOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    configureLoadingOverlay()
    containerView.addSubview(webView)
    containerView.addSubview(loadingOverlay)

    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.isOpaque = true
    webView.alpha = isStripchat ? 0 : 1
    webView.backgroundColor = .black
    webView.scrollView.backgroundColor = .black
    webView.scrollView.isScrollEnabled = false
    webView.scrollView.bounces = false
    webView.scrollView.contentInsetAdjustmentBehavior = .never
    webView.scrollView.contentInset = .zero
    webView.scrollView.scrollIndicatorInsets = .zero
    webView.customUserAgent =
      "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) " +
      "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 " +
      "Mobile/15E148 Safari/604.1"

    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    tap.cancelsTouchesInView = false
    webView.addGestureRecognizer(tap)

    progressObservation = webView.observe(\.estimatedProgress, options: [.new]) {
      [weak self] webView, _ in
      guard let self, self.isStripchat, !self.videoRevealed else { return }
      let progress = Float(max(0.04, min(0.96, webView.estimatedProgress)))
      self.loadingProgress.setProgress(progress, animated: true)
      if webView.estimatedProgress >= 0.95 {
        self.statusLabel.text = "网页已加载，正在寻找直播画面…"
      }
    }

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(pauseForBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(resumeFromBackground),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )

    if let url = URL(string: rawUrl) {
      var request = URLRequest(url: url)
      request.cachePolicy = .reloadIgnoringLocalCacheData
      if isStripchat {
        request.setValue("https://stripchat.com/", forHTTPHeaderField: "Referer")
      }
      roomRequest = request
      startRoomLoad()
    } else {
      showFailure("房间地址无效")
    }
  }

  deinit {
    focusTimer?.invalidate()
    statusTimer?.invalidate()
    progressObservation?.invalidate()
    NotificationCenter.default.removeObserver(self)
    webView.stopLoading()
    if StripchatLivePlatformView.activeView.value === self {
      StripchatLivePlatformView.activeView.value = nil
    }
  }

  func view() -> UIView {
    containerView
  }

  private func configureLoadingOverlay() {
    loadingOverlay.backgroundColor = .black

    loadingIndicator.color = .white
    loadingIndicator.startAnimating()

    loadingProgress.progressTintColor = UIColor(red: 1, green: 0.42, blue: 0.21, alpha: 1)
    loadingProgress.trackTintColor = UIColor.white.withAlphaComponent(0.18)
    loadingProgress.setProgress(0.04, animated: false)

    statusLabel.text = "正在连接…"
    statusLabel.textColor = .white
    statusLabel.font = .systemFont(ofSize: 14, weight: .medium)
    statusLabel.textAlignment = .center
    statusLabel.numberOfLines = 2

    speedLabel.text = "网速 —"
    speedLabel.textColor = UIColor.white.withAlphaComponent(0.72)
    speedLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    speedLabel.textAlignment = .center

    retryButton.setTitle("重新连接", for: .normal)
    retryButton.setTitleColor(.white, for: .normal)
    retryButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
    retryButton.backgroundColor = UIColor(red: 1, green: 0.42, blue: 0.21, alpha: 1)
    retryButton.layer.cornerRadius = 18
    retryButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 22, bottom: 8, right: 22)
    retryButton.isHidden = true
    retryButton.addTarget(self, action: #selector(handleRetry), for: .touchUpInside)

    let stack = UIStackView(arrangedSubviews: [
      loadingIndicator,
      statusLabel,
      speedLabel,
      loadingProgress,
      retryButton,
    ])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 14
    stack.translatesAutoresizingMaskIntoConstraints = false
    loadingOverlay.addSubview(stack)

    loadingProgress.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: loadingOverlay.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: loadingOverlay.centerYAnchor),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: loadingOverlay.leadingAnchor, constant: 28),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: loadingOverlay.trailingAnchor, constant: -28),
      loadingProgress.widthAnchor.constraint(equalToConstant: 220),
    ])
  }

  private func startRoomLoad() {
    guard let roomRequest else {
      showFailure("房间地址无效")
      return
    }
    focusTimer?.invalidate()
    if isStripchat {
      showLoading(resetClock: true)
    } else {
      loadingOverlay.isHidden = true
      webView.alpha = 1
    }
    webView.stopLoading()
    webView.load(roomRequest)
  }

  private func showLoading(resetClock: Bool) {
    guard isStripchat else { return }
    videoRevealed = false
    webView.alpha = 0
    loadingOverlay.alpha = 1
    loadingOverlay.isHidden = false
    loadingIndicator.startAnimating()
    retryButton.isHidden = true
    loadingProgress.progressTintColor = UIColor(red: 1, green: 0.42, blue: 0.21, alpha: 1)
    loadingProgress.setProgress(0.04, animated: false)
    if resetClock || loadingStartedAt == nil {
      loadingStartedAt = Date()
      pageLoadedAt = nil  // 重置网页加载时间
      lastTransferBytes = 0
      lastTransferAt = nil
      currentSpeedText = "—"
    }
    statusLabel.text = "正在连接… 0 秒"
    speedLabel.text = "网速 —"
    statusTimer?.invalidate()
    statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
      [weak self] _ in
      self?.updateLoadingStatus()
    }
  }

  private func updateLoadingStatus() {
    guard isStripchat else { return }
    guard !videoRevealed, let loadingStartedAt else { return }
    let elapsed = max(0, Int(Date().timeIntervalSince(loadingStartedAt)))

    // 总超时 30 秒
    if elapsed >= 30 {
      showFailure("连接超时，请检查网络或更换主播")
      return
    }

    // 网页加载完成后,15 秒内找不到视频就超时
    if let pageLoadedAt, Date().timeIntervalSince(pageLoadedAt) >= 15 {
      showFailure("未能捕获直播画面，主播可能离线或切换房间")
      return
    }

    if webView.estimatedProgress >= 0.95 {
      let pageElapsed = pageLoadedAt.map { max(0, Int(Date().timeIntervalSince($0))) } ?? 0
      statusLabel.text = "网页已加载，正在寻找直播画面… \(pageElapsed) 秒"
    } else if elapsed >= 15 {
      statusLabel.text = "连接较慢，请检查网络… \(elapsed) 秒"
    } else {
      statusLabel.text = "正在连接… \(elapsed) 秒"
    }
    speedLabel.text = "网速 \(currentSpeedText)"
    sampleNetworkSpeed()
  }

  private func sampleNetworkSpeed() {
    let script = """
      (() => {
        try {
          let total = 0;
          const nav = performance.getEntriesByType('navigation')[0];
          if (nav) total += (nav.transferSize || nav.encodedBodySize || 0);
          performance.getEntriesByType('resource').forEach(e => {
            total += (e.transferSize || e.encodedBodySize || 0);
          });
          return total;
        } catch (_) { return 0; }
      })()
      """
    webView.evaluateJavaScript(script) { [weak self] value, _ in
      guard let self, !self.videoRevealed else { return }
      let bytes = Int64((value as? NSNumber)?.int64Value ?? (value as? Int).map { Int64($0) } ?? 0)
      let now = Date()
      if let lastAt = self.lastTransferAt {
        let dt = now.timeIntervalSince(lastAt)
        let db = max(0, bytes - self.lastTransferBytes)
        if dt > 0.2 {
          let bps = Double(db) / dt
          self.currentSpeedText = self.formatSpeed(bps)
          self.speedLabel.text = "网速 \(self.currentSpeedText)"
        }
      }
      self.lastTransferBytes = max(self.lastTransferBytes, bytes)
      self.lastTransferAt = now
    }
  }

  private func formatSpeed(_ bytesPerSecond: Double) -> String {
    if bytesPerSecond < 1024 {
      return String(format: "%.0f B/s", bytesPerSecond)
    }
    if bytesPerSecond < 1024 * 1024 {
      return String(format: "%.1f KB/s", bytesPerSecond / 1024)
    }
    return String(format: "%.2f MB/s", bytesPerSecond / (1024 * 1024))
  }

  private func showFailure(_ message: String) {
    guard isStripchat else { return }
    guard !videoRevealed else { return }
    statusTimer?.invalidate()
    statusTimer = nil
    focusTimer?.invalidate()
    focusTimer = nil
    loadingIndicator.stopAnimating()
    loadingProgress.progressTintColor = .systemRed
    loadingProgress.setProgress(1, animated: true)
    statusLabel.text = message
    retryButton.isHidden = false
    loadingOverlay.alpha = 1
    loadingOverlay.isHidden = false
  }

  @objc private func handleRetry() {
    startRoomLoad()
  }

  func setMuted(_ value: Bool) {
    muted = value
    let flag = value ? "true" : "false"
    webView.evaluateJavaScript(
      "window.__epickleMuted=\(flag);" +
      "document.querySelectorAll('video').forEach(v=>{v.muted=\(flag);});"
    )
  }

  func pauseLive() {
    livePaused = true
    webView.evaluateJavaScript(
      "document.querySelectorAll('video').forEach(v=>{try{v.pause();}catch(_){}});"
    )
  }

  func resumeLive() {
    livePaused = false
    if isStripchat {
      installVideoFocus()
    }
    kickPlayback()
  }

  func kickPlayback() {
    let flag = muted ? "true" : "false"
    webView.evaluateJavaScript(
      "window.__epickleMuted=\(flag);document.querySelectorAll('video').forEach(v=>{try{v.muted=window.__epickleMuted;if(v.paused||v.readyState<2||v.ended){const p=v.play();if(p){p.catch(()=>{});}}}catch(_){}});"
    )
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard isStripchat else { return }
    pageLoadedAt = Date()  // 记录网页加载完成时间
    loadingProgress.setProgress(0.96, animated: true)
    statusLabel.text = "网页已加载，正在寻找直播画面… 0 秒"
    installVideoFocus()
    focusTimer?.invalidate()
    focusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
      [weak self] _ in
      self?.installVideoFocus()
    }
  }

  func webView(
    _ webView: WKWebView,
    didStartProvisionalNavigation navigation: WKNavigation!
  ) {
    if isStripchat {
      showLoading(resetClock: loadingStartedAt == nil)
    }
  }

  func webView(
    _ webView: WKWebView,
    didFail navigation: WKNavigation!,
    withError error: Error
  ) {
    if isStripchat {
      showFailure("连接失败：\(error.localizedDescription)")
    }
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    if isStripchat {
      showFailure("网络连接失败，请检查网络后重试")
    }
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard let targetUrl = navigationAction.request.url else {
      decisionHandler(.cancel)
      return
    }
    if navigationAction.targetFrame == nil {
      decisionHandler(.cancel)
      return
    }
    guard isStripchat else {
      decisionHandler(.allow)
      return
    }
    let host = targetUrl.host?.lowercased() ?? ""
    let allowed = host.isEmpty ||
      host == "stripchat.com" ||
      host.hasSuffix(".stripchat.com")
    decisionHandler(allowed ? .allow : .cancel)
  }

  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    nil
  }

  @objc private func handleTap() {
    if livePaused {
      resumeLive()
    } else {
      pauseLive()
    }
  }

  @objc private func pauseForBackground() {
    webView.evaluateJavaScript(
      "document.querySelectorAll('video').forEach(v=>v.pause());"
    )
  }

  @objc private func resumeFromBackground() {
    resumeLive()
  }

  private func installVideoFocus() {
    guard isStripchat else { return }
    let flag = muted ? "true" : "false"
    let script = """
      (() => {
        window.__epickleMuted = \(flag);
        var viewport = document.querySelector('meta[name="viewport"]');
        if (!viewport) {
          viewport = document.createElement('meta');
          viewport.name = 'viewport';
          document.head.appendChild(viewport);
        }
        viewport.content = 'width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover';
        if (!document.getElementById('__epickle_live_style')) {
          const style = document.createElement('style');
          style.id = '__epickle_live_style';
          style.textContent = `
            html, body { margin: 0 !important; padding: 0 !important;
              width: 100% !important; height: 100% !important;
              min-width: 100% !important; min-height: 100% !important;
              overflow: hidden !important; background: #000 !important; }
            video { position: fixed !important; inset: 0 !important;
              width: 100vw !important; height: 100vh !important;
              max-width: none !important; max-height: none !important;
              margin: 0 !important; padding: 0 !important;
              transform: none !important;
              object-fit: contain !important; background: #000 !important;
              z-index: 2147483647 !important; visibility: visible !important; }
          `;
          document.documentElement.appendChild(style);
        }
        if (!window.__epickleAgeClicked) {
          const ageButtons = Array.from(document.querySelectorAll('button, a'));
          const ageButton = ageButtons.find(node =>
            /18|enter|agree|continue/i.test((node.textContent || '').trim())
          );
          if (ageButton && !document.querySelector('video')) {
            ageButton.click();
            window.__epickleAgeClicked = true;
          }
        }
        const videos = Array.from(document.querySelectorAll('video'));
        const rankedVideos = videos
          .map(v => {
            const rect = v.getBoundingClientRect();
            const area = Math.max(0, rect.width) * Math.max(0, rect.height);
            const active = (v.srcObject || v.currentSrc || v.src) ? 100000000 : 0;
            const ready = v.readyState >= 2 ? 10000000 : 0;
            return { v, score: active + ready + area };
          })
          .sort((a, b) => b.score - a.score);
        const video = rankedVideos.length ? rankedVideos[0].v : null;
        if (!video) return false;

        let node = video;
        while (node) {
          const parent = node.parentElement;
          if (parent) Array.from(parent.children).forEach(sibling => {
            if (sibling !== node && sibling.dataset.epickleHidden !== '1') {
              sibling.style.setProperty('display', 'none', 'important');
              sibling.style.setProperty('pointer-events', 'none', 'important');
              sibling.dataset.epickleHidden = '1';
            }
          });
          node.style.setProperty('position', 'fixed', 'important');
          node.style.setProperty('inset', '0', 'important');
          node.style.setProperty('width', '100vw', 'important');
          node.style.setProperty('height', '100vh', 'important');
          node.style.setProperty('min-width', '100vw', 'important');
          node.style.setProperty('min-height', '100vh', 'important');
          node.style.setProperty('max-width', 'none', 'important');
          node.style.setProperty('max-height', 'none', 'important');
          node.style.setProperty('margin', '0', 'important');
          node.style.setProperty('padding', '0', 'important');
          node.style.setProperty('transform', 'none', 'important');
          node.style.setProperty('overflow', 'hidden', 'important');
          node.style.setProperty('background', '#000', 'important');
          node.style.setProperty('z-index', '2147483647', 'important');
          node.style.setProperty('visibility', 'visible', 'important');
          if (node === document.documentElement) break;
          node = parent;
        }
        video.setAttribute('playsinline', '');
        video.setAttribute('webkit-playsinline', '');
        video.controls = false;
        video.muted = window.__epickleMuted;
        video.style.setProperty('object-fit', 'contain', 'important');
        window.scrollTo(0, 0);
        if (video.paused) video.play().catch(() => {});
        return true;
      })()
      """
    webView.evaluateJavaScript(script) { [weak self] value, _ in
      guard let self, !self.videoRevealed else { return }
      let focused = (value as? Bool) ?? (value as? NSNumber)?.boolValue ?? false
      guard focused else { return }
      self.videoRevealed = true
      self.statusTimer?.invalidate()
      self.statusTimer = nil
      self.focusTimer?.invalidate()
      self.focusTimer = nil
      self.loadingStartedAt = nil
      self.loadingIndicator.stopAnimating()
      UIView.animate(
        withDuration: 0.18,
        delay: 0,
        options: [.beginFromCurrentState, .curveEaseOut]
      ) {
        self.webView.alpha = 1
        self.loadingOverlay.alpha = 0
      } completion: { _ in
        self.loadingOverlay.isHidden = true
        self.loadingOverlay.alpha = 1
      }
    }
  }
}

private final class BrowserRenderRequest: NSObject, WKNavigationDelegate {
  private let url: URL
  private let headers: [String: String]
  private let deadline: Date
  private let completion: ([String: Any]?, FlutterError?) -> Void
  private var webView: WKWebView?
  private var timeoutWorkItem: DispatchWorkItem?
  private var completed = false
  private var statusCode = 200

  init(
    url: URL,
    headers: [String: String],
    timeout: TimeInterval,
    completion: @escaping ([String: Any]?, FlutterError?) -> Void
  ) {
    self.url = url
    self.headers = headers
    deadline = Date().addingTimeInterval(timeout)
    self.completion = completion
    super.init()
  }

  func start(in container: UIView?) {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    configuration.preferences.javaScriptEnabled = true
    let view = WKWebView(
      frame: CGRect(x: 0, y: 0, width: 2, height: 2),
      configuration: configuration
    )
    view.alpha = 0.01
    view.isUserInteractionEnabled = false
    view.navigationDelegate = self
    if let userAgent = headers.first(where: { $0.key.lowercased() == "user-agent" })?.value {
      view.customUserAgent = userAgent
    }
    container?.addSubview(view)
    webView = view

    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    for (name, value) in headers where name.lowercased() != "user-agent" {
      request.setValue(value, forHTTPHeaderField: name)
    }
    view.load(request)

    let timeout = max(1, deadline.timeIntervalSinceNow)
    let workItem = DispatchWorkItem { [weak self] in
      self?.finishError(
        code: "browser_render_timeout",
        message: "Browser rendering timed out"
      )
    }
    timeoutWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
  }

  func cancel() {
    finishError(
      code: "browser_render_cancelled",
      message: "Browser rendering cancelled"
    )
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationResponse: WKNavigationResponse,
    decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
  ) {
    if navigationResponse.isForMainFrame,
       let response = navigationResponse.response as? HTTPURLResponse {
      statusCode = response.statusCode
    }
    decisionHandler(.allow)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
      self?.collectHtml()
    }
  }

  func webView(
    _ webView: WKWebView,
    didFail navigation: WKNavigation!,
    withError error: Error
  ) {
    finishError(code: "browser_render_failed", message: error.localizedDescription)
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    finishError(code: "browser_render_failed", message: error.localizedDescription)
  }

  private func collectHtml() {
    guard !completed, let webView else { return }
    let script = """
      (() => {
        const resources = new Set();
        try {
          performance.getEntriesByType('resource').forEach(entry => resources.add(entry.name));
        } catch (_) {}
        document.querySelectorAll('video, source, iframe').forEach(node => {
          if (node.src) resources.add(node.src);
          if (node.currentSrc) resources.add(node.currentSrc);
        });
        return {
          html: document.documentElement.outerHTML,
          resources: Array.from(resources).slice(0, 400),
          href: location.href
        };
      })()
      """
    webView.evaluateJavaScript(script) { [weak self] value, error in
      guard let self, !self.completed else { return }
      if let error {
        self.finishError(
          code: "browser_render_javascript",
          message: error.localizedDescription
        )
        return
      }
      let rendered = value as? [String: Any]
      var html = rendered?["html"] as? String ?? ""
      let resources = rendered?["resources"] as? [String] ?? []
      if !resources.isEmpty {
        let sourceTags = resources.map { resource in
          let safe = resource
            .replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "<", with: "%3C")
          return "<source src=\"\(safe)\">"
        }.joined(separator: "\n")
        html += "\n<!-- WKWebView resource URLs -->\n\(sourceTags)"
      }
      let lower = html.lowercased()
      let challengePending = lower.contains("just a moment") ||
        lower.contains("cf-chl-") ||
        lower.contains("checking your browser") ||
        lower.contains("challenge-platform")
      if challengePending && self.deadline.timeIntervalSinceNow > 1.2 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
          self?.collectHtml()
        }
        return
      }
      let renderedUrl = (rendered?["href"] as? String).flatMap { URL(string: $0) }
      self.finish(html: html, finalUrl: renderedUrl ?? webView.url ?? self.url)
    }
  }

  private func finish(html: String, finalUrl: URL) {
    guard !completed, let webView else { return }
    // Disarm the timeout BEFORE the async cookie read below: the callback
    // hops threads, and an in-flight render must never be reported as a
    // timeout just because the timeout fired across that gap. Everything here
    // runs on the main queue, so this cancel is atomic versus the timeout.
    timeoutWorkItem?.cancel()
    timeoutWorkItem = nil
    webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
      guard let self, !self.completed else { return }
      let host = finalUrl.host?.lowercased() ?? ""
      var cookieMap: [String: String] = [:]
      for cookie in cookies {
        let domain = cookie.domain
          .lowercased()
          .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if host == domain || host.hasSuffix(".\(domain)") {
          cookieMap[cookie.name] = cookie.value
          // Keep URLSession (epickle/browser_http get/getBytes) in sync with
          // the WKWebView session so the native fallback and render share
          // cookies for the same host.
          HTTPCookieStorage.shared.setCookie(cookie)
        }
      }
      self.completed = true
      self.timeoutWorkItem?.cancel()
      webView.stopLoading()
      webView.navigationDelegate = nil
      webView.removeFromSuperview()
      self.webView = nil
      self.completion([
        "statusCode": self.statusCode,
        "body": html,
        "finalUrl": finalUrl.absoluteString,
        "cookies": cookieMap,
      ], nil)
    }
  }

  private func finishError(code: String, message: String) {
    guard !completed else { return }
    completed = true
    timeoutWorkItem?.cancel()
    webView?.stopLoading()
    webView?.navigationDelegate = nil
    webView?.removeFromSuperview()
    webView = nil
    completion(nil, FlutterError(code: code, message: message, details: nil))
  }
}

/// Reads the system HTTP proxy via CFNetwork. Matches the shape Android's
/// readSystemProxy returns, so Dart parses both identically.
enum SystemProxyReader {
  static func systemProxyInfo() -> [String: Any?] {
    let none: [String: Any?] = [
      "host": nil, "port": nil, "type": nil, "source": "none",
    ]
    guard let settings = CFNetworkCopySystemProxySettings() as? [String: Any] else {
      return none
    }
    let host = settings["HTTPProxy"] as? String
      ?? settings["HTTPSProxy"] as? String
    let port = (settings["HTTPPort"] as? NSNumber)?.intValue
      ?? (settings["HTTPSPort"] as? NSNumber)?.intValue
    guard let host, !host.isEmpty, let port, port > 0, port < 65536 else {
      return none
    }
    return ["host": host, "port": port, "type": "http", "source": "ios"]
  }
}

enum PrivacyNativeWipe {
  /// Lightweight per-launch wipe: clears only the caches that grow over time
  /// (WebView disk/memory cache, offline app cache, URLCache).
  /// Cookies, localStorage, sessionStorage, UserDefaults, Documents and
  /// keychain are preserved so settings, watch history and site sessions
  /// survive restarts. (WKWebsiteDataTypeServiceWorkers was deprecated in
  /// iOS 17 and removed from the SDK — do not reference it.)
  static func clearLaunchCache() {
    URLCache.shared.removeAllCachedResponses()
    let types: Set<String> = [
      WKWebsiteDataTypeDiskCache,
      WKWebsiteDataTypeMemoryCache,
      WKWebsiteDataTypeOfflineWebApplicationCache,
    ]
    WKWebsiteDataStore.default().removeData(
      ofTypes: types,
      modifiedSince: Date(timeIntervalSince1970: 0)
    ) {}
  }

  static func run(completion: @escaping () -> Void) {
    let group = DispatchGroup()

    group.enter()
    let types = WKWebsiteDataStore.allWebsiteDataTypes()
    WKWebsiteDataStore.default().removeData(
      ofTypes: types,
      modifiedSince: Date(timeIntervalSince1970: 0)
    ) {
      group.leave()
    }

    HTTPCookieStorage.shared.cookies?.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
    HTTPCookieStorage.shared.removeCookies(since: .distantPast)
    URLCache.shared.removeAllCachedResponses()
    // Empty the cache without permanently crippling it: drop the zero-capacity
    // instance and restore defaults, so the app does not re-download every
    // media byte if it stays alive after the wipe.
    URLCache.shared = URLCache(memoryCapacity: 4 * 1024 * 1024,
                                diskCapacity: 20 * 1024 * 1024,
                                diskPath: nil)

    wipeSandboxFiles()
    wipeUserDefaults()
    wipeKeychain()

    group.notify(queue: .main) {
      completion()
    }
  }

  private static func wipeSandboxFiles() {
    let fm = FileManager.default
    let home = URL(fileURLWithPath: NSHomeDirectory())
    let targets = [
      home.appendingPathComponent("Library/Cookies"),
      home.appendingPathComponent("Library/WebKit"),
      home.appendingPathComponent("Library/Caches"),
      home.appendingPathComponent("Library/HTTPStorages"),
      home.appendingPathComponent("Library/Application Support"),
      home.appendingPathComponent("tmp"),
      URL(fileURLWithPath: NSTemporaryDirectory()),
      home.appendingPathComponent("Documents"),
    ]
    for url in targets {
      wipeDirectoryContents(url, fileManager: fm)
    }
  }

  private static func wipeDirectoryContents(_ url: URL, fileManager fm: FileManager) {
    guard fm.fileExists(atPath: url.path) else { return }
    guard let items = try? fm.contentsOfDirectory(
      at: url,
      includingPropertiesForKeys: nil,
      options: []
    ) else {
      return
    }
    for item in items {
      try? fm.removeItem(at: item)
    }
  }

  private static func wipeUserDefaults() {
    // Preserve the mirror-speed ranking: it holds latency stats only (no
    // browsing/cookie/user data) and the user wants cleanup to keep it, so
    // keys under this prefix survive even the nuclear wipe.
    let preservedPrefix = "flutter.mirror_rank_v1_"
    for key in UserDefaults.standard.dictionaryRepresentation().keys
    where !key.hasPrefix(preservedPrefix) {
      UserDefaults.standard.removeObject(forKey: key)
    }
    if let bundleId = Bundle.main.bundleIdentifier,
       let suite = UserDefaults(suiteName: bundleId) {
      for key in suite.dictionaryRepresentation().keys
      where !key.hasPrefix(preservedPrefix) {
        suite.removeObject(forKey: key)
      }
      suite.synchronize()
    }
    UserDefaults.standard.synchronize()
  }

  private static func wipeKeychain() {
    let classes: [CFString] = [
      kSecClassGenericPassword,
      kSecClassInternetPassword,
      kSecClassCertificate,
      kSecClassKey,
      kSecClassIdentity,
    ]
    for cls in classes {
      SecItemDelete([kSecClass: cls] as CFDictionary)
    }
  }
}
