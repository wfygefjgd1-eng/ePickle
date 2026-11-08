import '../models/video_item.dart';

/// 短剧站适配器统一接口：黄果/禁果等「整部剧卡片 + 选集播放」站点共用
/// [HuangGuoWebPage] 的卡片网格页。各站只负责列表/搜索/详情/选集解析。
abstract class ShortDramaApi {
  Future<List<VideoItem>> fetchFeed({
    String tagId = 'duanju',
    int page = 1,
    int limit = 40,
    Set<String>? exclude,
  });

  Future<List<VideoItem>> search(String query, {int page = 1});

  /// 专题列表（无专题的站点可返回空列表）。
  Future<List<VideoItem>> fetchTopicList(String path, {int page = 1});

  Future<VideoDetail> getVideoDetail(String url);

  /// 详情抓取后缓存的整剧选集（第 1 集起）；没有缓存时返回 null。
  List<VideoItem>? episodesFor(String url);

  void cancelRequests([String reason = 'cancelled']);
}
