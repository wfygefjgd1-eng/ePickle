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

  static DateTime? _lastCheck;
  static int _videosSinceCheck = 0;
  static bool _running = false;

  /// On every app launch: wipe transient caches (image cache, temp files,
  /// WebView cache, URLCache). Settings, watch history, cookies and keychain
  /// are intentionally preserved so the app stays usable and sites keep
  /// their sessions. Never blocks startup (fire-and-forget from main()).
  static Future<void> clearOnLaunch() async {
    if (_running) return;
    _running = true;
    try {
      // Native: WKWebView cache + URLCache (cookies preserved).
      await PrivacyWipe.clearLaunchCache();
      // Dart side: flutter_cache_manager + temp directory.
      await clearAllCache();
      debugPrint('ePickle: on-launch cache clear finished');
    } catch (e) {
      debugPrint('ePickle: on-launch cache clear failed: $e');
    } finally {
      _running = false;
    }
  }

  /// On launch: force one check (still throttled against concurrent runs).
  static Future<void> checkAndCleanIfNeeded({bool force = false}) async {
    if (_running) return;
    final now = DateTime.now();
    if (!force) {
      _videosSinceCheck++;
      if (_lastCheck != null &&
          now.difference(_lastCheck!) < _minInterval &&
          _videosSinceCheck < _minVideosBetween) {
        return;
      }
    }
    _running = true;
    _lastCheck = now;
    _videosSinceCheck = 0;
    try {
      final cacheSize = await _getCacheSizeInMB();
      if (cacheSize > _maxCacheSizeMB) {
        debugPrint(
            'Cache size ${cacheSize.toStringAsFixed(0)}MB exceeds limit, cleaning...');
        await _cleanCache();
        final newSize = await _getCacheSizeInMB();
        debugPrint(
          'Cache cleaned: ${cacheSize.toStringAsFixed(0)}MB → ${newSize.toStringAsFixed(0)}MB',
        );
      }
    } catch (e) {
      debugPrint('Cache check failed: $e');
    } finally {
      _running = false;
    }
  }

  /// Call after a successful play (throttled).
  static void onVideoPlayed() {
    // ignore: discarded_futures
    checkAndCleanIfNeeded();
  }

  static Future<double> _getCacheSizeInMB() async {
    try {
      final tempDir = await getTemporaryDirectory();
      // Measure the WHOLE temp directory, not just libCachedImageData:
      // once the image-cache dir exists it would otherwise mask growth in
      // flutter_cache_manager files and any temp downloads, so the 500 MB
      // threshold could never react. (WebView/URLCache growth is handled
      // natively by clearOnLaunch on every start.)
      int totalSize = 0;
      int scanned = 0;
      // 上限保护：异常目录（海量小文件）不会无限阻塞 UI 线程。
      await for (final entity
          in tempDir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            totalSize += await entity.length();
            scanned++;
            if (scanned >= 200000) break;
          } catch (_) {}
        }
      }
      return totalSize / (1024 * 1024);
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
