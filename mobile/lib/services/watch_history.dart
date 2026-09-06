import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/video_item.dart';
import '../utils/file_utils.dart';

/// Local watch history (newest first). Survives app restarts.
///
/// Stored as a JSON file under Application Support (NOT UserDefaults):
/// - sensitive browsing history is kept out of iCloud backups (the file is
///   marked excluded-from-backup on iOS);
/// - the native privacy wipe clears Application Support together with the
///   rest of the app data.
class WatchHistory extends ChangeNotifier {
  static const _kFileName = 'watch_history_v1.json';
  static const maxItems = 100;

  final List<VideoItem> _items = [];
  bool _ready = false;

  /// Serializes concurrent [_persist] calls so rapid record/remove sequences
  /// cannot interleave writes.
  Future<void> _writeTail = Future.value();

  /// Resolved once after load; avoids re-issuing the platform call on every
  /// record/remove/clear.
  File? _file;

  /// iOS backup-exclude 只执行一次：并发调用共享同一个 future，避免重复
  /// 触碰平台求通道（Completer 即状态锁）。
  Completer<void>? _backupExcludeOn;

  Future<void> _ensureBackupExcluded(String path) async {
    if (!Platform.isIOS) return;
    final existing = _backupExcludeOn;
    if (existing != null) return existing.future;
    final completer = Completer<void>();
    _backupExcludeOn = completer;
    try {
      await FileUtils.excludeFromBackup(path);
    } catch (_) {
      // 失败也保持已完成，避免无限重试；下次写入会重建 completer。
    }
    completer.complete();
  }

  bool get ready => _ready;

  Future<File> _historyFile() async {
    final cached = _file;
    if (cached != null) return cached;
    final dir = await getApplicationSupportDirectory();
    final f = File('${dir.path}/$_kFileName');
    _file = f;
    return f;
  }

  Future<void> load() async {
    try {
      final f = await _historyFile();
      if (f.existsSync()) {
        final raw = await f.readAsString();
        if (raw.isNotEmpty) {
          final list = jsonDecode(raw) as List<dynamic>;
          for (final e in list) {
            if (e is! Map) continue;
            // One malformed entry must not discard the whole history:
            // skip it and keep every valid item.
            try {
              final m = Map<String, dynamic>.from(e);
              final url = m['url'] is String ? (m['url'] as String).trim() : '';
              if (url.isEmpty) continue;
              _items.add(VideoItem(
                url: url,
                title:
                    m['title'] is String ? (m['title'] as String).trim() : '',
                duration: m['duration'] is String
                    ? (m['duration'] as String).trim()
                    : '-',
                thumb:
                    m['thumb'] is String ? (m['thumb'] as String).trim() : null,
                // 剧集信息缺省为 null：旧历史文件没有这两个键，向后兼容。
                episode: m['episode'] is int ? m['episode'] as int : null,
                episodeTotal:
                    m['episodeTotal'] is int ? m['episodeTotal'] as int : null,
              ));
            } catch (_) {
              continue;
            }
          }
        }
      }
      // iOS: mark the file excluded from iCloud backups once.
      await _ensureBackupExcluded(f.path);
    } catch (_) {
      // Missing/corrupt file or unavailable storage → start empty.
    }
    _ready = true;
    notifyListeners();
  }

  Future<void> record(VideoItem item) async {
    final url = item.url.trim();
    if (url.isEmpty) return;
    _items.removeWhere((e) => e.viewkey == item.viewkey || e.url == url);
    _items.insert(
      0,
      VideoItem(
        url: url,
        title: item.title,
        duration: item.duration,
        thumb: item.thumb,
        // 剧集标识必须透传：viewkey 对剧集是 '$url#ep$episode'，丢掉后
        // 同一部剧的不同集在历史里坍缩成同一条。
        episode: item.episode,
        episodeTotal: item.episodeTotal,
      ),
    );
    if (_items.length > maxItems) {
      _items.removeRange(maxItems, _items.length);
    }
    notifyListeners();
    await _persist();
  }

  Future<void> clear() async {
    if (_items.isEmpty) return;
    _items.clear();
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() {
    final data = _items.map((e) {
      final m = <String, dynamic>{
        'url': e.url,
        'title': e.title,
        'duration': e.duration,
        'thumb': e.thumb,
      };
      if (e.episode != null) m['episode'] = e.episode;
      if (e.episodeTotal != null) m['episodeTotal'] = e.episodeTotal;
      return m;
    }).toList();
    _writeTail = _writeTail.then((_) async {
      try {
        final f = await _historyFile();
        await f.writeAsString(jsonEncode(data), flush: true);
        // iOS: keep sensitive history out of iCloud backups (once per session).
        await _ensureBackupExcluded(f.path);
      } catch (_) {
        // Storage unavailable (e.g. unit tests) — nothing to do.
      }
    });
    return _writeTail;
  }
}