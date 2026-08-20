import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/http_client.dart';


/// Lightweight user prefs.
class AppSettings extends ChangeNotifier {
  static const _kSkipIntro = 'skip_intro_10s';
  static const _kSkipIntroMinSec = 'skip_intro_min_sec';
  static const _kSkipTier1At = 'skip_tier1_at';
  static const _kSkipTier1Sec = 'skip_tier1_sec';
  static const _kSkipTier2At = 'skip_tier2_at';
  static const _kSkipTier2Sec = 'skip_tier2_sec';
  static const _kSkipTier3At = 'skip_tier3_at';
  static const _kSkipTier3Sec = 'skip_tier3_sec';
  static const _kSkipTier4At = 'skip_tier4_at';
  static const _kSkipTier4Sec = 'skip_tier4_sec';
  static const _kShowFastForwardButton = 'show_fastforward_button';
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
  bool _showFastForwardButton = true;

  /// 跳过片头按档位规则（可配置，折叠在“跳过片头”里）：
  /// 视频时长 ≥ 对应档位阈值（秒）时跳过该档秒数，取满足的最大档；
  /// 最短时长 [skipIntroMinSec] 秒以下的视频不跳（预告/直播保护）。
  int _skipIntroMinSec = 45;
  int _skipTier1At = 100;
  int _skipTier1Sec = 10;
  int _skipTier2At = 600;
  int _skipTier2Sec = 15;
  int _skipTier3At = 900;
  int _skipTier3Sec = 25;
  int _skipTier4At = 3000;
  int _skipTier4Sec = 70;

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
  bool get showFastForwardButton => _showFastForwardButton;
  String get huangguoDomain => _huangguoDomain;

  int get skipIntroMinSec => _skipIntroMinSec;

  /// 四档 (阈值秒, 跳过秒)。从低到高排列。
  List<(int atSec, int skipSec)> get skipIntroTiers => [
        (_skipTier1At, _skipTier1Sec),
        (_skipTier2At, _skipTier2Sec),
        (_skipTier3At, _skipTier3Sec),
        (_skipTier4At, _skipTier4Sec),
      ];

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
      _showFastForwardButton = p.getBool(_kShowFastForwardButton) ?? true;
      _skipIntroMinSec =
          (p.getInt(_kSkipIntroMinSec) ?? 45).clamp(5, 7200);
      _skipTier1At = (p.getInt(_kSkipTier1At) ?? 100).clamp(1, 7200);
      _skipTier1Sec = (p.getInt(_kSkipTier1Sec) ?? 10).clamp(1, 600);
      _skipTier2At = (p.getInt(_kSkipTier2At) ?? 600).clamp(1, 7200);
      _skipTier2Sec = (p.getInt(_kSkipTier2Sec) ?? 15).clamp(1, 600);
      _skipTier3At = (p.getInt(_kSkipTier3At) ?? 900).clamp(1, 7200);
      _skipTier3Sec = (p.getInt(_kSkipTier3Sec) ?? 25).clamp(1, 600);
      _skipTier4At = (p.getInt(_kSkipTier4At) ?? 3000).clamp(1, 7200);
      _skipTier4Sec = (p.getInt(_kSkipTier4Sec) ?? 70).clamp(1, 600);
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

  Future<void> setShowFastForwardButton(bool v) async {
    if (_showFastForwardButton == v) return;
    _showFastForwardButton = v;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kShowFastForwardButton, v);
    } catch (_) {}
  }

  Future<void> setSkipIntroMinSec(int v) =>
      _setSkipIntroInt(_kSkipIntroMinSec, v.clamp(5, 7200), (n) {
        _skipIntroMinSec = n;
      });

  /// [index] 0..3 对应第 1..4 档；[value] 为阈值（秒）。
  Future<void> setSkipTierAtSec(int index, int value) =>
      _setSkipIntroInt(_tierAtKey(index), value.clamp(1, 7200), (n) {
        switch (index) {
          case 0:
            _skipTier1At = n;
          case 1:
            _skipTier2At = n;
          case 2:
            _skipTier3At = n;
          case 3:
            _skipTier4At = n;
        }
      });

  Future<void> setSkipTierSec(int index, int value) =>
      _setSkipIntroInt(_tierSecKey(index), value.clamp(1, 600), (n) {
        switch (index) {
          case 0:
            _skipTier1Sec = n;
          case 1:
            _skipTier2Sec = n;
          case 2:
            _skipTier3Sec = n;
          case 3:
            _skipTier4Sec = n;
        }
      });

  static String _tierAtKey(int index) => switch (index) {
        0 => _kSkipTier1At,
        1 => _kSkipTier2At,
        2 => _kSkipTier3At,
        _ => _kSkipTier4At,
      };

  static String _tierSecKey(int index) => switch (index) {
        0 => _kSkipTier1Sec,
        1 => _kSkipTier2Sec,
        2 => _kSkipTier3Sec,
        _ => _kSkipTier4Sec,
      };

  Future<void> _setSkipIntroInt(
    String key,
    int value,
    void Function(int) apply,
  ) async {
    if (value == _currentSkipIntro(key)) return;
    apply(value);
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(key, value);
    } catch (_) {}
  }

  int _currentSkipIntro(String key) => switch (key) {
        _kSkipIntroMinSec => _skipIntroMinSec,
        _kSkipTier1At => _skipTier1At,
        _kSkipTier2At => _skipTier2At,
        _kSkipTier3At => _skipTier3At,
        _kSkipTier4At => _skipTier4At,
        _kSkipTier1Sec => _skipTier1Sec,
        _kSkipTier2Sec => _skipTier2Sec,
        _kSkipTier3Sec => _skipTier3Sec,
        _ => _skipTier4Sec,
      };
}
