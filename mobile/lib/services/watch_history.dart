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

  bool get ready => _ready;
  List<VideoItem> get items => List.unmodifiable(_items);

  Future<File> _historyFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_kFileName');
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
            final m = Map<String, dynamic>.from(e);
            final url = (m['url'] as String?)?.trim() ?? '';
            if (url.isEmpty) continue;
            _items.add(VideoItem(
              url: url,
              title: (m['title'] as String?)?.trim() ?? '',
              duration: (m['duration'] as String?)?.trim() ?? '-',
              thumb: (m['thumb'] as String?)?.trim(),
            ));
          }
        }
      }
      // iOS: mark the file excluded from iCloud backups once on load.
      if (Platform.isIOS) {
        await FileUtils.excludeFromBackup(f.path);
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

  Future<void> remove(VideoItem item) async {
    final before = _items.length;
    _items.removeWhere(
      (e) => e.viewkey == item.viewkey || e.url == item.url,
    );
    if (_items.length == before) return;
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
        // iOS: keep sensitive history out of iCloud backups.
        if (Platform.isIOS) {
          await FileUtils.excludeFromBackup(f.path);
        }
      } catch (_) {
        // Storage unavailable (e.g. unit tests) — nothing to do.
      }
    });
    return _writeTail;
  }
}