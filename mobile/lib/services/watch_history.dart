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

  /// The file attribute is set once on the existing file — no need to re-issue
  /// the platform call on every persist.
  static bool _backupExcluded = false;

  /// Serializes concurrent [_persist] calls so rapid record/remove sequences
  /// cannot interleave writes.
  Future<void> _writeTail = Future.value();

  /// Resolved once after load; avoids re-issuing the platform call on every
  /// record/remove/clear.
  File? _file;

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
              ));
            } catch (_) {
              continue;
            }
          }
        }
      }
      // iOS: mark the file excluded from iCloud backups once on load.
      if (Platform.isIOS && !_backupExcluded) {
        await FileUtils.excludeFromBackup(f.path);
        _backupExcluded = true;
      }
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
    final data = _items
        .map((e) => {
              'url': e.url,
              'title': e.title,
              'duration': e.duration,
              'thumb': e.thumb,
            })
        .toList();
    _writeTail = _writeTail.then((_) async {
      try {
        final f = await _historyFile();
        await f.writeAsString(jsonEncode(data), flush: true);
        // iOS: keep sensitive history out of iCloud backups. Guarded, so the
        // platform call fires at most once per session (normally during
        // load(); this retries in case that attempt failed early).
        if (Platform.isIOS && !_backupExcluded) {
          await FileUtils.excludeFromBackup(f.path);
          _backupExcluded = true;
        }
      } catch (_) {
        // Storage unavailable (e.g. unit tests) — nothing to do.
      }
    });
    return _writeTail;
  }
}