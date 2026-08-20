import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/http_client.dart';


/// Lightweight user prefs.
class AppSettings extends ChangeNotifier {
  static const _kSkipIntro = 'skip_intro_10s';
  static const _kMuted = 'playback_muted';
  static const _kQualityCap = 'quality_cap_height'; // 0=auto preferred
  static const _kShowSiteBackButton = 'show_site_back_button';
  static const _kShowSearchBackButton = 'show_search_back_button';
  static const _kShowFullscreenButton = 'show_fullscreen_button';
  static const _kShowMuteButton = 'show_mute_button';
  static const _kProxyEnabled = 'proxy_enabled';
  static const _kProxyHost = 'proxy_host';
  static const _kProxyPort = 'proxy_port';
  static const _kProxyType = 'proxy_type'; // http | socks5
  static const _kProxyUserConfigured = 'proxy_user_configured';
  static const _kAutoRotate = 'auto_rotate_landscape';
  static const _kPromptOnStall = 'auto_lower_on_stall';
  static const _kHuangguoDomain = 'huangguo_domain_v1';

  bool _skipIntro = true;
  bool _muted = false;
  int _qualityCap = 0;
  bool _showSiteBackButton = true;
  bool _showSearchBackButton = true;
  bool _showFullscreenButton = true;
  bool _showMuteButton = true;

  /// Default to DIRECT; TUN handles routing at system level.
  bool _proxyEnabled = false;
  String _proxyHost = '';
  int _proxyPort = 0;
  String _proxyType = 'http';
  bool _userConfiguredProxy = false;
  bool _ready = false;
  String _proxyAutoNote = '';
  bool _autoRotate = true;
  bool _autoLowerOnStall = true;

  /// 黄果规则主域名（换域名时在设置里修改，无需更新 App）。
  static const huangguoDefaultDomain = 'https://huangguoai.com';
  String _huangguoDomain = huangguoDefaultDomain;

  bool get skipIntro => _skipIntro;
  bool get muted => _muted;
  int get qualityCap => _qualityCap;
  bool get showSiteBackButton => _showSiteBackButton;
  bool get showSearchBackButton => _showSearchBackButton;
  bool get showFullscreenButton => _showFullscreenButton;
  bool get showMuteButton => _showMuteButton;
  bool get proxyEnabled => _proxyEnabled;
  String get proxyHost => _proxyHost;
  int get proxyPort => _proxyPort;
  String get proxyType => _proxyType;
  bool get ready => _ready;
  String get proxyAutoNote => _proxyAutoNote;
  bool get autoRotate => _autoRotate;
  bool get autoLowerOnStall => _autoLowerOnStall;
  String get huangguoDomain => _huangguoDomain;

  bool get hasProxyEndpoint =>
      _proxyHost.isNotEmpty && _proxyPort > 0 && _proxyPort < 65536;

  String get qualityLabel {
    switch (_qualityCap) {
      case 360:
        return '360p';
      case 480:
        return '480p';
      case 720:
        return '720p';
      case 1080:
        return '1080p';
      default:
        return '自动';
    }
  }

  String get proxySummary {
    if (!_proxyEnabled) return '关闭（纯直连 / 仅 TUN）';
    if (!hasProxyEndpoint) {
      return '已开启，但未检测到系统代理（将直连；可手动填写）';
    }
    final note = _proxyAutoNote.isEmpty ? '' : ' · $_proxyAutoNote';
    return '${_proxyType.toUpperCase()} $_proxyHost:$_proxyPort$note';
  }

  /// One-line status for settings header (一眼懂).
  String get networkStatusTitle {
    if (!_proxyEnabled) return '当前：直连（仅系统路由 / TUN）';
    if (!hasProxyEndpoint) return '当前：直连 · 系统未下发代理';
    return '当前：$_proxyType $_proxyHost:$_proxyPort';
  }

  String get networkStatusDetail {
    if (!_proxyEnabled) {
      return '列表与详情不走 App 代理。已开全局 TUN 时通常够用。';
    }
    if (!hasProxyEndpoint) {
      return '开关开着但没有可用主机:端口 → 实际仍直连。'
          '可点「重新检测」，或手动填写；'
          '仅浏览器代理时系统往往检测不到。';
    }
    final jvm = _proxyType == 'http'
        ? '列表/详情走代理；播放会尽力跟 HTTP 代理。'
        : '列表/详情走 SOCKS；播放器可能不跟 SOCKS，播不动时可开 TUN。';
    final note = _proxyAutoNote.isEmpty ? '' : '（$_proxyAutoNote）';
    return '$jvm$note';
  }

  void _syncHttpClient() {
    // Manual proxy only when user explicitly set host:port.
    final use = _proxyEnabled && hasProxyEndpoint && _userConfiguredProxy;
    AppHttpClient.applyProxyConfig(
      enabled: use,
      host: _proxyHost,
      port: _proxyPort,
      type: _proxyType,
    );
  }

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      _skipIntro = p.getBool(_kSkipIntro) ?? true;
      _muted = p.getBool(_kMuted) ?? false;
      _qualityCap = p.getInt(_kQualityCap) ?? 0;
      final iosDefault = defaultTargetPlatform == TargetPlatform.iOS;
      _showSiteBackButton =
          p.getBool(_kShowSiteBackButton) ?? !iosDefault;
      _showSearchBackButton =
          p.getBool(_kShowSearchBackButton) ?? !iosDefault;
      _showFullscreenButton =
          p.getBool(_kShowFullscreenButton) ?? !iosDefault;
      _showMuteButton = p.getBool(_kShowMuteButton) ?? !iosDefault;
      _autoRotate = p.getBool(_kAutoRotate) ?? true;
      _autoLowerOnStall = p.getBool(_kPromptOnStall) ?? true;
      _huangguoDomain = _normalizeHuangguoDomain(
        p.getString(_kHuangguoDomain) ?? huangguoDefaultDomain,
      );

      // Default to DIRECT (TUN handles routing at system level).
      // Only enable proxy if the user explicitly configured one (clears stale auto-detect).
      _userConfiguredProxy = p.getBool(_kProxyUserConfigured) ?? false;
      _proxyEnabled = _userConfiguredProxy && (p.getBool(_kProxyEnabled) ?? false);
      _proxyHost = p.getString(_kProxyHost) ?? '';
      _proxyPort = p.getInt(_kProxyPort) ?? 0;
      _proxyType = p.getString(_kProxyType) ?? 'http';
      if (_proxyType != 'socks5') _proxyType = 'http';
      // Clear stale auto-detected proxy from old versions.
      if (!_userConfiguredProxy) {
        _proxyHost = '';
        _proxyPort = 0;
      }
} catch (_) {
      _skipIntro = true;
      _muted = false;
      _qualityCap = 0;
      final iosDefault = defaultTargetPlatform == TargetPlatform.iOS;
      _showSiteBackButton = !iosDefault;
      _showSearchBackButton = !iosDefault;
      _showFullscreenButton = !iosDefault;
      _showMuteButton = !iosDefault;
      _userConfiguredProxy = false;
      _autoRotate = true;
      _autoLowerOnStall = true;
      _huangguoDomain = huangguoDefaultDomain;
      _proxyEnabled = false;
      _proxyHost = '';
      _proxyPort = 0;
      _proxyType = 'http';
    }

    if (_userConfiguredProxy && hasProxyEndpoint) {
      _proxyAutoNote = '手动设置';
    } else {
      // Clear stale auto-detected values from old builds.
      if (!_userConfiguredProxy) {
        _proxyHost = '';
        _proxyPort = 0;
        _proxyType = 'http';
        _proxyEnabled = false;
      }
      _proxyAutoNote = '系统代理由 Dio 自动跟随（Android）';
    }

    _syncHttpClient();
    // Android: make Dio follow system HTTP proxy like WebView. main() already
    // awaited a refresh; joining the throttled/in-flight result is nearly
    // free and avoids a second native detection just for the status note.
    await AppHttpClient.refreshSystemProxy();
    if (!_userConfiguredProxy) {
      final host = AppHttpClient.systemHost;
      final port = AppHttpClient.systemPort;
      if (host != null && host.isNotEmpty && port > 0) {
        _proxyAutoNote = '系统代理 $host:$port (检测)';
      } else {
        _proxyAutoNote = '直连 / TUN';
      }
    }
    _ready = true;
    notifyListeners();
  }

  Future<void> setSkipIntro(bool v) async {
    if (_skipIntro == v) return;
    _skipIntro = v;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kSkipIntro, v);
    } catch (_) {}
  }

  Future<void> setMuted(bool v) async {
    if (_muted == v) return;
    _muted = v;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kMuted, v);
    } catch (_) {}
  }

  Future<void> setAutoRotate(bool v) async {
    if (_autoRotate == v) return;
    _autoRotate = v;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kAutoRotate, v);
    } catch (_) {}
  }

  Future<void> setAutoLowerOnStall(bool v) async {
    if (_autoLowerOnStall == v) return;
    _autoLowerOnStall = v;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kPromptOnStall, v);
    } catch (_) {}
  }

  /// 设置黄果规则主域名（自动补全 https:// 并去掉结尾斜杠）。
  Future<void> setHuangguoDomain(String v) async {
    final normalized = _normalizeHuangguoDomain(v);
    if (normalized == _huangguoDomain) return;
    _huangguoDomain = normalized;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kHuangguoDomain, normalized);
    } catch (_) {}
  }

  Future<void> resetHuangguoDomain() => setHuangguoDomain(huangguoDefaultDomain);

  static String _normalizeHuangguoDomain(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return huangguoDefaultDomain;
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      value = 'https://$value';
    }
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) return huangguoDefaultDomain;
    return Uri(
      scheme: uri.scheme == 'http' ? 'http' : 'https',
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path == '/' ? '' : uri.path.replaceFirst(RegExp(r'/+$'), ''),
    ).toString();
  }

  Future<void> setQualityCap(int v) async {
    if (_qualityCap == v) return;
    _qualityCap = v;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(_kQualityCap, v);
    } catch (_) {}
  }

  Future<void> setShowSiteBackButton(bool v) async {
    if (_showSiteBackButton == v) return;
    _showSiteBackButton = v;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kShowSiteBackButton, v);
    } catch (_) {}
  }

  Future<void> setShowSearchBackButton(bool v) async {
    if (_showSearchBackButton == v) return;
    _showSearchBackButton = v;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kShowSearchBackButton, v);
    } catch (_) {}
  }

  Future<void> setShowFullscreenButton(bool v) async {
    if (_showFullscreenButton == v) return;
    _showFullscreenButton = v;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kShowFullscreenButton, v);
    } catch (_) {}
  }

  Future<void> setShowMuteButton(bool v) async {
    if (_showMuteButton == v) return;
    _showMuteButton = v;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kShowMuteButton, v);
    } catch (_) {}
  }

  Future<void> setProxyEnabled(bool v) async {
    if (_proxyEnabled == v) return;
    _proxyEnabled = v;
    _syncHttpClient();
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kProxyEnabled, v);
    } catch (_) {}
  }

  Future<void> setProxyHost(String v) async {
    final host = v.trim();
    if (host == _proxyHost && _userConfiguredProxy) return;
    _proxyHost = host;
    _userConfiguredProxy = true;
    _proxyAutoNote = '手动设置';
    _syncHttpClient();
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kProxyHost, _proxyHost);
      await p.setBool(_kProxyUserConfigured, true);
    } catch (_) {}
  }

  Future<void> setProxyPort(int v) async {
    final port = (v > 0 && v < 65536) ? v : 0;
    if (port == _proxyPort && _userConfiguredProxy) return;
    _proxyPort = port;
    _userConfiguredProxy = true;
    _proxyAutoNote = '手动设置';
    _syncHttpClient();
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(_kProxyPort, _proxyPort);
      await p.setBool(_kProxyUserConfigured, true);
    } catch (_) {}
  }

  Future<void> setProxyType(String v) async {
    final t = v == 'socks5' ? 'socks5' : 'http';
    if (t == _proxyType && _userConfiguredProxy) return;
    _proxyType = t;
    _userConfiguredProxy = true;
    _proxyAutoNote = '手动设置';
    _syncHttpClient();
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kProxyType, _proxyType);
      await p.setBool(_kProxyUserConfigured, true);
    } catch (_) {}
  }

  /// Re-read Android system proxy for Dio.
  Future<void> refreshSystemProxy() async {
    await AppHttpClient.refreshSystemProxy();
    // Use the detection result AppHttpClient already cached — no second
    // native lookup needed just for the status note.
    if (!_userConfiguredProxy) {
      final host = AppHttpClient.systemHost;
      final port = AppHttpClient.systemPort;
      if (host != null && host.isNotEmpty && port > 0) {
        _proxyAutoNote = '系统代理 $host:$port (检测)';
      } else {
        _proxyAutoNote = '直连 / TUN';
      }
    }
    notifyListeners();
  }
}
