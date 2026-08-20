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
  static const _kAutoRotate = 'auto_rotate_landscape';
  static const _kAutoLowerOnStall = 'auto_lower_on_stall';
  static const _kHuangguoDomain = 'huangguo_domain_v1';

  bool _skipIntro = true;
  bool _muted = false;
  int _qualityCap = 0;
  bool _showSiteBackButton = true;
  bool _showSearchBackButton = true;
  bool _showFullscreenButton = true;
  bool _showMuteButton = true;
  bool _ready = false;
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
  bool get ready => _ready;
  bool get autoRotate => _autoRotate;
  bool get autoLowerOnStall => _autoLowerOnStall;
  String get huangguoDomain => _huangguoDomain;

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
      _autoLowerOnStall = p.getBool(_kAutoLowerOnStall) ?? true;
      _huangguoDomain = _normalizeHuangguoDomain(
        p.getString(_kHuangguoDomain) ?? huangguoDefaultDomain,
      );
    } catch (_) {
      // SharedPreferences unavailable (plugin missing / store corrupt).
      // Every assignment above uses `?? <initializer-default>`, so the field
      // initializers already hold exactly what this block used to duplicate.
    }

    try {
      // Android: make Dio follow system HTTP proxy like WebView. main() already
      // awaited a refresh; joining the throttled/in-flight result is nearly
      // free and avoids a second native detection. The whole tail stays inside
      // a try so a detection failure can never blank the app at startup.
      await AppHttpClient.refreshSystemProxy();
    } catch (_) {}
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
      await p.setBool(_kAutoLowerOnStall, v);
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
}
