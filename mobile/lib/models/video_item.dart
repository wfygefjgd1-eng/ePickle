class VideoItem {
  final String url;
  final String title;
  final String duration;
  final String? thumb;

  /// 剧集信息：非空表示这是某短剧的第 N 集（第 1 集起）。
  final int? episode;
  final int? episodeTotal;

  /// 直接可播地址（已解析好的 m3u8/mp4），无需再抓详情页。
  final String? directUrl;

  /// 网页卡片元信息：评分（如 "9.0分"）与集数徽标（如 "全5集"）。
  final String? score;
  final String? badge;

  const VideoItem({
    required this.url,
    required this.title,
    this.duration = '-',
    this.thumb,
    this.episode,
    this.episodeTotal,
    this.directUrl,
    this.score,
    this.badge,
  });

  String get viewkey {
    if (episode != null) {
      return '${url}#ep$episode';
    }
    final m = RegExp(r'viewkey=([^&#]+)').firstMatch(url);
    if (m != null) return m.group(1)!;
    // XVideos: /video.xxxxx/slug
    final x = RegExp(r'/video\.([a-zA-Z0-9]+)').firstMatch(url);
    if (x != null) return x.group(1)!;
    // mitaohk: /vod/play/id/123/
    final mt = RegExp(r'/vod/play/id/(\d+)').firstMatch(url);
    if (mt != null) return 'mt${mt.group(1)}';
    return url;
  }

  VideoItem copyWith({
    String? url,
    String? title,
    String? duration,
    String? thumb,
    int? episode,
    int? episodeTotal,
    String? directUrl,
    String? score,
    String? badge,
  }) {
    return VideoItem(
      url: url ?? this.url,
      title: title ?? this.title,
      duration: duration ?? this.duration,
      thumb: thumb ?? this.thumb,
      episode: episode ?? this.episode,
      episodeTotal: episodeTotal ?? this.episodeTotal,
      directUrl: directUrl ?? this.directUrl,
      score: score ?? this.score,
      badge: badge ?? this.badge,
    );
  }
}

class StreamQuality {
  final int width;
  final int height;
  final String url;
  final String? referer;
  final Map<String, String> headers;

  const StreamQuality({
    required this.width,
    required this.height,
    required this.url,
    this.referer,
    this.headers = const {},
  });

  String get label {
    if (height > 0) return '${height}p';
    if (width > 0) return '${width}w';
    return 'auto';
  }

  int get pixels => width * height;
}

class VideoDetail {
  final String url;
  final String title;
  final String? description;
  final int durationSec;
  final String? thumb;
  final List<StreamQuality> streams;
  final bool unavailable;
  final bool countryBlocked;

  /// When stream extraction fails, play this page inside App WKWebView
  /// (same path as Stripchat). Prefer real [streams] when non-empty.
  final String? browserPlaybackUrl;

  const VideoDetail({
    required this.url,
    required this.title,
    this.description,
    required this.durationSec,
    this.thumb,
    required this.streams,
    this.unavailable = false,
    this.countryBlocked = false,
    this.browserPlaybackUrl,
  });

  bool get prefersBrowserPlayer =>
      streams.isEmpty &&
      browserPlaybackUrl != null &&
      browserPlaybackUrl!.trim().isNotEmpty;

  String get durationLabel {
    if (durationSec <= 0) return '-';
    final h = durationSec ~/ 3600;
    final m = (durationSec % 3600) ~/ 60;
    final s = durationSec % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:'
          '${m.toString().padLeft(2, '0')}:'
          '${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}';
  }

  StreamQuality? get bestStream {
    if (streams.isEmpty) return null;
    final sorted = [...streams]..sort((a, b) => b.pixels.compareTo(a.pixels));
    return sorted.first;
  }

  /// Prefer <= 720p for mobile data / stability.
  StreamQuality? get preferredStream {
    if (streams.isEmpty) return null;
    final under720 =
        streams.where((s) => s.height > 0 && s.height <= 720).toList();
    if (under720.isNotEmpty) {
      under720.sort((a, b) => b.pixels.compareTo(a.pixels));
      return under720.first;
    }
    return bestStream;
  }

  /// [maxHeight] 0/null => preferredStream; else highest stream <= cap.
  StreamQuality? streamForCap(int? maxHeight) {
    if (streams.isEmpty) return null;
    if (maxHeight == null || maxHeight <= 0) return preferredStream;
    final under =
        streams.where((s) => s.height > 0 && s.height <= maxHeight).toList();
    if (under.isNotEmpty) {
      under.sort((a, b) => b.pixels.compareTo(a.pixels));
      return under.first;
    }
    // Cap lower than all — pick lowest
    final sorted = [...streams]..sort((a, b) => a.pixels.compareTo(b.pixels));
    return sorted.first;
  }
}
