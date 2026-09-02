import '../models/video_item.dart';

/// In-memory list cache per feed tab (player still disposed on leave).
/// Snapshots are window-capped around [FeedListSnapshot.index].
class FeedListCache {
  FeedListCache._();
  static final Map<String, FeedListSnapshot> _map = {};

  /// Max items kept per tab snapshot (around current index).
  /// Reduced to 60 for mobile memory efficiency (was 100).
  static const maxItems = 60;

  /// Read the cached snapshot without removing it.
  static FeedListSnapshot? take(String kind) => _map[kind];

  static void put(String kind, FeedListSnapshot snap) {
    if (snap.items.isEmpty) return;
    _map[kind] = snap.capped(maxItems);
  }

  static void clear(String kind) => _map.remove(kind);

  static void clearAll() => _map.clear();
}

class FeedListSnapshot {
  FeedListSnapshot({
    required this.items,
    required this.seen,
    required this.index,
    this.sourcePage,
  });

  final List<VideoItem> items;
  final Set<String> seen;
  final int index;

  /// 随机页信息流（激进预加载暂存的"计划页"快照）：[items] 实际来自第
  /// [sourcePage] 页，信息流续抓从 sourcePage+1 开始。普通快照为 null
  /// （沿用按条数推页的规则），随机页信息流遇到 null 依旧清缓存走随机页，
  /// 保持原有的随机性。
  final int? sourcePage;

  /// Keep a window around [index]; rebuild [seen] for retained items.
  FeedListSnapshot capped(int max) {
    if (items.length <= max || max <= 0) {
      final i = items.isEmpty ? 0 : index.clamp(0, items.length - 1);
      return FeedListSnapshot(
        items: List<VideoItem>.from(items),
        seen: Set<String>.from(seen),
        index: i,
        sourcePage: sourcePage,
      );
    }
    final i = index.clamp(0, items.length - 1);
    final half = max ~/ 2;
    var start = (i - half).clamp(0, items.length);
    var end = (start + max).clamp(0, items.length);
    if (end - start < max) {
      start = (end - max).clamp(0, end);
    }
    final slice = items.sublist(start, end);
    final newIndex = (i - start).clamp(0, slice.length - 1);
    final newSeen = <String>{for (final e in slice) e.viewkey};
    return FeedListSnapshot(
      items: slice,
      seen: newSeen,
      index: newIndex,
      sourcePage: sourcePage,
    );
  }
}
