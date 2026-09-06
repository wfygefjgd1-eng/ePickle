import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/privacy_wipe.dart';

/// Automatic cache cleanup with throttling (avoid scanning temp every video).
class CacheManager {
  static const _maxCacheSizeMB = 500;
  static const _targetCacheSizeMB = 300;
  static const _minInterval = Duration(minutes: 30);
  static const _minVideosBetween = 40;

  /// 测量结果缓存：一次真实扫描在 [_measureTtl] 内复用，避免每次
  /// `onVideoPlayed` 都对整个 temp 目录做递归扫描。
  static const _measureTtl = Duration(minutes: 15);
  static double? _cachedSizeMB;
  static DateTime? _cachedAt;

  static DateTime? _lastCheck;
  static int _videosSinceCheck = 0;

  /// Single-flight lock using a cached Future: the first caller starts the
  /// work, every concurrent caller gets the same in-flight future.  Safer than
  /// a bool flag (no race between `if (_active != null) return` and the
  /// subsequent assignment).  Nulled out via `whenComplete` so the next call
  /// after completion starts fresh.
  static Future<void>? _activeClearOnLaunch;
  static Future<void>? _activeCheck;

  /// On every app launch: wipe transient caches (image cache, temp files,
  /// WebView cache, URLCache). Settings, watch history, cookies and keychain
  /// are intentionally preserved so the app stays usable and sites keep
  /// their sessions. Never blocks startup (fire-and-forget from main()).
  static Future<void> clearOnLaunch() {
    return _activeClearOnLaunch ??= _runClearOnLaunch().whenComplete(() {
      _activeClearOnLaunch = null;
    });
  }

  static Future<void> _runClearOnLaunch() async {
    try {
      // Native: WKWebView cache + URLCache (cookies preserved).
      await PrivacyWipe.clearLaunchCache();
      // Dart side: flutter_cache_manager + temp directory.
      await clearAllCache();
      debugPrint('ePickle: on-launch cache clear finished');
    } catch (e) {
      debugPrint('ePickle: on-launch cache clear failed: $e');
    }
  }

  /// On launch: force one check (still throttled against concurrent runs).
  static Future<void> checkAndCleanIfNeeded({bool force = false}) {
    final active = _activeCheck;
    if (active != null) return active;
    final now = DateTime.now();
    if (!force) {
      _videosSinceCheck++;
      if (_lastCheck != null &&
          now.difference(_lastCheck!) < _minInterval &&
          _videosSinceCheck < _minVideosBetween) {
        return Future<void>.value();
      }
    }
    return _activeCheck = _runCheck(now).whenComplete(() {
      _activeCheck = null;
    });
  }

  static Future<void> _runCheck(DateTime now) async {
    _lastCheck = now;
    _videosSinceCheck = 0;
    try {
      final cacheSize = await _getCacheSizeInMB();
      if (cacheSize > _maxCacheSizeMB) {
        debugPrint(
            'Cache size ${cacheSize.toStringAsFixed(0)}MB exceeds limit, cleaning...');
        await _cleanCache();
        // 清理后测量值已变化，丢掉缓存让下次真实重算。
        _cachedSizeMB = null;
        _cachedAt = null;
        final newSize = await _getCacheSizeInMB();
        debugPrint(
          'Cache cleaned: ${cacheSize.toStringAsFixed(0)}MB → ${newSize.toStringAsFixed(0)}MB',
        );
      }
    } catch (e) {
      debugPrint('Cache check failed: $e');
    }
  }

  /// Call after a successful play (throttled).
  static void onVideoPlayed() {
    // ignore: discarded_futures
    checkAndCleanIfNeeded();
  }

  static Future<double> _getCacheSizeInMB() async {
    // 缓存复用：TTL 内直接返回上次真实扫描结果，避免每次播放都全目录递归。
    final cached = _cachedSizeMB;
    final cachedAt = _cachedAt;
    if (cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < _measureTtl) {
      return cached;
    }
    try {
      final tempDir = await getTemporaryDirectory();
      // Measure the WHOLE temp directory, not just libCachedImageData:
      // once the image-cache dir exists it would otherwise mask growth in
      // flutter_cache_manager files and any temp downloads, so the 500 MB
      // threshold could never react. (WebView/URLCache growth is handled
      // natively by clearOnLaunch on every start.)
      // The listing is async (`await for`), so it never blocks the UI thread;
      // stopping early here would silently under-count a huge dir and the
      // size cap could never fire. Early-out caps apply to the DELETE passes.
      int totalSize = 0;
      await for (final entity
          in tempDir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            totalSize += await entity.length();
          } catch (_) {}
        }
      }
      final mb = totalSize / (1024 * 1024);
      _cachedSizeMB = mb;
      _cachedAt = DateTime.now();
      return mb;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> _cleanCache() async {
    try {
      await DefaultCacheManager().emptyCache();
      final tempDir = await getTemporaryDirectory();
      final now = DateTime.now();

      Future<void> deleteOlderThan(int days) async {
        int scanned = 0;
        await for (final entity
            in tempDir.list(recursive: true, followLinks: false)) {
          if (entity is File) {
            try {
              final stat = await entity.stat();
              if (now.difference(stat.modified).inDays > days) {
                await entity.delete();
              }
              scanned++;
              if (scanned >= 200000) break;
            } catch (_) {}
          }
        }
      }

      await deleteOlderThan(7);
      // 7 天档删完必须先作废 15 分钟测量缓存再复测：_cleanCache 只会在
      // 缓存值 >500MB 时进入，不作废的话这里拿到的还是清理前的旧值，
      // "7 天档不够再上 3 天档"的分层判断就退化为无条件执行。
      _cachedSizeMB = null;
      _cachedAt = null;
      final currentSize = await _getCacheSizeInMB();
      if (currentSize > _targetCacheSizeMB) {
        await deleteOlderThan(3);
      }
    } catch (e) {
      debugPrint('Cache cleanup failed: $e');
    }
  }

  static Future<void> clearAllCache() async {
    try {
      await DefaultCacheManager().emptyCache();
      final tempDir = await getTemporaryDirectory();
      int scanned = 0;
      await for (final entity
          in tempDir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            await entity.delete();
            scanned++;
            // 上限保护：与检查路径一致，异常目录不会无限阻塞。
            if (scanned >= 200000) break;
          } catch (_) {}
        }
      }
    } catch (_) {}
  }
}
