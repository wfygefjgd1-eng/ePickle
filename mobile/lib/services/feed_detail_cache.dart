import '../models/video_item.dart';

/// Cross-screen cache for video details prefetched before their feed opens.
///
/// The home screen prewarms the first lists into [FeedListCache]; this cache
/// completes the chain by also holding details for the first items of those
/// lists, so tapping a card skips the detail round-trip entirely and goes
/// straight to player initialization.
///
/// Keyed by item URL (indices shift with list trims, URLs are stable).
class FeedDetailCache {
  FeedDetailCache._();

  static final _map = <String, VideoDetail>{};

  /// Small cap: only the next-opened cards benefit; older entries are stale.
  static const maxEntries = 12;

  /// Removes and returns the detail for [url] — the consuming screen's own
  /// index-keyed cache takes ownership from here.
  static VideoDetail? take(String url) => _map.remove(url);

  static void put(String url, VideoDetail detail) {
    if (url.isEmpty) return;
    // Re-insert to refresh recency before trimming.
    _map.remove(url);
    _map[url] = detail;
    while (_map.length > maxEntries) {
      _map.remove(_map.keys.first);
    }
  }

  static void clearAll() => _map.clear();
}
