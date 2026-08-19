import 'package:flutter/material.dart';

import '../models/feed_kind.dart';

/// Built-in site directory. Adapters fill data later; PH / X / zhong already wired.
enum SiteKind { video, live }

class SiteTag {
  const SiteTag({
    required this.id,
    required this.label,
    this.feedKind,
    this.icon = Icons.local_fire_department_outlined,
    this.iconSelected = Icons.local_fire_department,
  });

  final String id;
  final String label;
  final VideoFeedKind? feedKind;
  final IconData icon;
  final IconData iconSelected;
}

class SiteDef {
  const SiteDef({
    required this.id,
    required this.name,
    required this.kind,
    required this.tags,
    required this.color,
    required this.letter,
    this.mirrors = const [],
    this.searchable = true,
    this.ready = true,
    this.custom = false,
    this.directoryTags = const [],
    this.parserId,
  });

  final String id;
  final String name;
  final SiteKind kind;
  final List<SiteTag> tags;
  final int color;
  final String letter;
  final List<String> mirrors;
  final bool searchable;
  final bool ready;
  final bool custom;
  final List<SiteTag> directoryTags;
  /// Adapter used by the generic parser for user-added sites.
  final String? parserId;

  bool get isStripchat => id == 'stripchat' || parserId == 'stripchat';
  bool get isChaturbate => id == 'chaturbate' || parserId == 'chaturbate';

  String get primaryHost =>
      mirrors.isNotEmpty ? mirrors.first : 'https://example.com';

  factory SiteDef.customFromUrl(String url, {String parserId = 'generic_vod'}) {
    final u = url.trim().replaceAll(RegExp(r'/$'), '');
    final uri = Uri.tryParse(u);
    final host = uri?.host ?? u;
    final displayName = uri == null
        ? host
        : '${uri.authority}${uri.path == '/' ? '' : uri.path}';
    final letter = displayName.isNotEmpty ? displayName[0].toUpperCase() : '?';
    return SiteDef(
      id: 'custom_${parserId}_${Uri.encodeComponent(u)}',
      name: displayName,
      kind: parserId == 'stripchat' || parserId == 'chaturbate'
          ? SiteKind.live
          : SiteKind.video,
      color: 0xFF607D8B,
      letter: letter,
      mirrors: [u.startsWith('http') ? u : 'https://$u'],
      tags: switch (parserId) {
        'stripchat' => SourceCatalog.stripchatTags,
        'chaturbate' => SourceCatalog.chaturbateTags,
        'pornhub' => SourceCatalog.pornhub.tags,
        'xvideos' => SourceCatalog.xvideos.tags,
        'mitao' => SourceCatalog.mitao.tags,
        'huangguo' => SourceCatalog.huangguoTags,
        _ => SourceCatalog.vodTags,
      },
      directoryTags: switch (parserId) {
        'stripchat' || 'chaturbate' => SourceCatalog.liveDirectoryTags,
        'huangguo' => SourceCatalog.huangguoDirectoryTags,
        _ => SourceCatalog.vodDirectoryTags,
      },
      ready: true,
      custom: true,
      parserId: parserId,
    );
  }
}

class SourceCatalog {
  SourceCatalog._();

  // Chinese short labels via \u escapes (avoid file encoding breakage).
  static const vodTags = <SiteTag>[
    SiteTag(
      id: 'hot',
      label: '\u70ed',
      icon: Icons.local_fire_department_outlined,
      iconSelected: Icons.local_fire_department,
    ),
    SiteTag(
      id: 'new',
      label: '\u65b0',
      icon: Icons.fiber_new_outlined,
      iconSelected: Icons.fiber_new,
    ),
    SiteTag(
      id: 'asian',
      label: '\u4e9a',
      icon: Icons.public_outlined,
      iconSelected: Icons.public,
    ),
    SiteTag(
      id: 'best',
      label: '\u699c',
      icon: Icons.emoji_events_outlined,
      iconSelected: Icons.emoji_events,
    ),
  ];

  static const liveTags = <SiteTag>[
    SiteTag(
      id: 'hot',
      label: '\u70ed',
      icon: Icons.local_fire_department_outlined,
      iconSelected: Icons.local_fire_department,
    ),
    SiteTag(
      id: 'new',
      label: '\u65b0',
      icon: Icons.fiber_new_outlined,
      iconSelected: Icons.fiber_new,
    ),
    SiteTag(
      id: 'asia',
      label: '\u4e9a',
      icon: Icons.public_outlined,
      iconSelected: Icons.public,
    ),
    SiteTag(
      id: 'tag',
      label: '\u6807',
      icon: Icons.sell_outlined,
      iconSelected: Icons.sell,
    ),
  ];

  static const chaturbateTags = <SiteTag>[
    SiteTag(
        id: 'female',
        label: '\u5973',
        icon: Icons.woman_outlined,
        iconSelected: Icons.woman),
    SiteTag(
        id: 'couples',
        label: '\u4f34',
        icon: Icons.people_outline,
        iconSelected: Icons.people),
    SiteTag(
        id: 'new',
        label: '\u65b0',
        icon: Icons.fiber_new_outlined,
        iconSelected: Icons.fiber_new),
    SiteTag(
        id: 'asian',
        label: '\u4e9a',
        icon: Icons.public_outlined,
        iconSelected: Icons.public),
  ];

  static const liveDirectoryTags = <SiteTag>[
    SiteTag(id: 'female', label: '\u5973\u751f', icon: Icons.woman_outlined, iconSelected: Icons.woman),
    SiteTag(id: 'couples', label: '\u60c5\u4fa3', icon: Icons.people_outline, iconSelected: Icons.people),
    SiteTag(id: 'new', label: '\u6700\u65b0', icon: Icons.fiber_new_outlined, iconSelected: Icons.fiber_new),
    SiteTag(id: 'asian', label: '\u4e9a\u6d32', icon: Icons.public_outlined, iconSelected: Icons.public),
    SiteTag(id: 'popular', label: '\u70ed\u95e8', icon: Icons.local_fire_department_outlined, iconSelected: Icons.local_fire_department),
    SiteTag(id: 'mature', label: '\u6210\u719f', icon: Icons.person_outline, iconSelected: Icons.person),
    SiteTag(id: 'male', label: '\u7537\u751f', icon: Icons.man_outlined, iconSelected: Icons.man),
    SiteTag(id: 'trans', label: '\u7279\u8272', icon: Icons.diversity_3_outlined, iconSelected: Icons.diversity_3),
    SiteTag(id: 'latina', label: '\u62c9\u4e01', icon: Icons.language_outlined, iconSelected: Icons.language),
    SiteTag(id: 'ebony', label: '\u9ed1\u73cd\u73e0', icon: Icons.nightlife_outlined, iconSelected: Icons.nightlife),
    SiteTag(id: 'blonde', label: '\u91d1\u53d1', icon: Icons.face_retouching_natural_outlined, iconSelected: Icons.face_retouching_natural),
    SiteTag(id: 'brunette', label: '\u68d5\u53d1', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'cosplay', label: '\u89d2\u8272', icon: Icons.theater_comedy_outlined, iconSelected: Icons.theater_comedy),
    SiteTag(id: 'tattoo', label: '\u7eb9\u8eab', icon: Icons.brush_outlined, iconSelected: Icons.brush),
    SiteTag(id: 'outdoor', label: '\u6237\u5916', icon: Icons.landscape_outlined, iconSelected: Icons.landscape),
    SiteTag(id: 'hd', label: '\u9ad8\u6e05', icon: Icons.hd_outlined, iconSelected: Icons.hd),
  ];

  static const vodDirectoryTags = <SiteTag>[
    SiteTag(id: 'hot', label: '\u70ed\u95e8', icon: Icons.local_fire_department_outlined, iconSelected: Icons.local_fire_department),
    SiteTag(id: 'new', label: '\u6700\u65b0', icon: Icons.fiber_new_outlined, iconSelected: Icons.fiber_new),
    SiteTag(id: 'asian', label: '\u4e9a\u6d32', icon: Icons.public_outlined, iconSelected: Icons.public),
    SiteTag(id: 'best', label: '\u7cbe\u9009', icon: Icons.emoji_events_outlined, iconSelected: Icons.emoji_events),
    SiteTag(id: 'amateur', label: '\u7d20\u4eba', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'couples', label: '\u60c5\u4fa3', icon: Icons.people_outline, iconSelected: Icons.people),
    SiteTag(id: 'mature', label: '\u6210\u719f', icon: Icons.person_outline, iconSelected: Icons.person),
    SiteTag(id: 'popular', label: '\u4eba\u6c14', icon: Icons.trending_up_outlined, iconSelected: Icons.trending_up),
    SiteTag(id: 'japanese', label: '\u65e5\u672c', icon: Icons.flag_outlined, iconSelected: Icons.flag),
    SiteTag(id: 'chinese', label: '\u4e2d\u6587', icon: Icons.translate_outlined, iconSelected: Icons.translate),
    SiteTag(id: 'korean', label: '\u97e9\u56fd', icon: Icons.language_outlined, iconSelected: Icons.language),
    SiteTag(id: 'cosplay', label: '\u89d2\u8272', icon: Icons.theater_comedy_outlined, iconSelected: Icons.theater_comedy),
    SiteTag(id: 'massage', label: '\u6309\u6469', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'office', label: '\u804c\u573a', icon: Icons.business_center_outlined, iconSelected: Icons.business_center),
    SiteTag(id: 'uniform', label: '\u5236\u670d', icon: Icons.checkroom_outlined, iconSelected: Icons.checkroom),
    SiteTag(id: 'story', label: '\u5267\u60c5', icon: Icons.movie_outlined, iconSelected: Icons.movie),
    SiteTag(id: 'short', label: '\u77ed\u7247', icon: Icons.timelapse_outlined, iconSelected: Icons.timelapse),
    SiteTag(id: 'long', label: '\u957f\u7247', icon: Icons.schedule_outlined, iconSelected: Icons.schedule),
    SiteTag(id: 'hd', label: '\u9ad8\u6e05', icon: Icons.hd_outlined, iconSelected: Icons.hd),
    SiteTag(id: 'trending', label: '\u8d8b\u52bf', icon: Icons.whatshot_outlined, iconSelected: Icons.whatshot),
  ];

  /// Pornhub 目录标签：热门/精选/亚洲/最新/日本/素人/熟女/情侣/高清（fetchRecommend/fetchAsian 直连，其余站内搜索）。
  static const pornhubDirectoryTags = <SiteTag>[
    SiteTag(id: 'hot', label: '\u70ed\u95e8', icon: Icons.local_fire_department_outlined, iconSelected: Icons.local_fire_department),
    SiteTag(id: 'best', label: '\u7cbe\u9009', icon: Icons.emoji_events_outlined, iconSelected: Icons.emoji_events),
    SiteTag(id: 'asian', label: '\u4e9a\u6d32', icon: Icons.public_outlined, iconSelected: Icons.public),
    SiteTag(id: 'new', label: '\u6700\u65b0', icon: Icons.fiber_new_outlined, iconSelected: Icons.fiber_new),
    SiteTag(id: 'japanese', label: '\u65e5\u672c', icon: Icons.flag_outlined, iconSelected: Icons.flag),
    SiteTag(id: 'amateur', label: '\u7d20\u4eba', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'mature', label: '\u6210\u719f', icon: Icons.person_outline, iconSelected: Icons.person),
    SiteTag(id: 'couples', label: '\u60c5\u4fa3', icon: Icons.people_outline, iconSelected: Icons.people),
    SiteTag(id: 'hd', label: '\u9ad8\u6e05', icon: Icons.hd_outlined, iconSelected: Icons.hd),
    SiteTag(id: 'lesbian', label: '\u540c\u6027', icon: Icons.favorite_outline, iconSelected: Icons.favorite),
  ];

  /// XVideos 目录标签：热门/精选/最新/亚洲/日本/素人/熟女/同性/高清。
  static const xvideosDirectoryTags = <SiteTag>[
    SiteTag(id: 'hot', label: '\u70ed\u95e8', icon: Icons.local_fire_department_outlined, iconSelected: Icons.local_fire_department),
    SiteTag(id: 'best', label: '\u7cbe\u9009', icon: Icons.emoji_events_outlined, iconSelected: Icons.emoji_events),
    SiteTag(id: 'new', label: '\u6700\u65b0', icon: Icons.fiber_new_outlined, iconSelected: Icons.fiber_new),
    SiteTag(id: 'asian', label: '\u4e9a\u6d32', icon: Icons.public_outlined, iconSelected: Icons.public),
    SiteTag(id: 'japanese', label: '\u65e5\u672c', icon: Icons.flag_outlined, iconSelected: Icons.flag),
    SiteTag(id: 'amateur', label: '\u7d20\u4eba', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'mature', label: '\u6210\u719f', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'lesbian', label: '\u540c\u6027', icon: Icons.favorite_outline, iconSelected: Icons.favorite),
    SiteTag(id: 'hd', label: '\u9ad8\u6e05', icon: Icons.hd_outlined, iconSelected: Icons.hd),
  ];

  /// Mitao 目录标签：热门/最新/中字/亚洲/日本/素人。
  static const mitaoDirectoryTags = <SiteTag>[
    SiteTag(id: 'hot', label: '\u70ed\u95e8', icon: Icons.local_fire_department_outlined, iconSelected: Icons.local_fire_department),
    SiteTag(id: 'new', label: '\u6700\u65b0', icon: Icons.fiber_new_outlined, iconSelected: Icons.fiber_new),
    SiteTag(id: 'asian', label: '\u4e9a\u6d32', icon: Icons.public_outlined, iconSelected: Icons.public),
    SiteTag(id: 'japanese', label: '\u65e5\u672c', icon: Icons.flag_outlined, iconSelected: Icons.flag),
    SiteTag(id: 'amateur', label: '\u7d20\u4eba', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'chinese', label: '\u4e2d\u6587', icon: Icons.translate_outlined, iconSelected: Icons.translate),
  ];

  /// XNXX 目录标签：热/新/亚/榜 + 常见标签页（/tags/{name}/ 与 /search/{name}/）。
  static const xnxxDirectoryTags = <SiteTag>[
    SiteTag(id: 'hot', label: '\u70ed\u95e8', icon: Icons.local_fire_department_outlined, iconSelected: Icons.local_fire_department),
    SiteTag(id: 'new', label: '\u6700\u65b0', icon: Icons.fiber_new_outlined, iconSelected: Icons.fiber_new),
    SiteTag(id: 'asian', label: '\u4e9a\u6d32', icon: Icons.public_outlined, iconSelected: Icons.public),
    SiteTag(id: 'best', label: '\u7cbe\u9009', icon: Icons.emoji_events_outlined, iconSelected: Icons.emoji_events),
    SiteTag(id: 'japanese', label: '\u65e5\u672c', icon: Icons.flag_outlined, iconSelected: Icons.flag),
    SiteTag(id: 'amateur', label: '\u7d20\u4eba', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'milf', label: '\u719f\u5973', icon: Icons.person_outline, iconSelected: Icons.person),
    SiteTag(id: 'mature', label: '\u6210\u719f', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'lesbian', label: '\u540c\u6027', icon: Icons.favorite_outline, iconSelected: Icons.favorite),
    SiteTag(id: 'anal', label: '\u540e\u5ead', icon: Icons.airline_seat_recline_normal_outlined, iconSelected: Icons.airline_seat_recline_normal),
    SiteTag(id: 'hentai', label: '\u52a8\u6f2b', icon: Icons.animation_outlined, iconSelected: Icons.animation),
    SiteTag(id: 'creampie', label: '\u5185\u5c04', icon: Icons.water_drop_outlined, iconSelected: Icons.water_drop),
  ];

  /// xHamster 目录标签：热/新/亚/日/熟/动/素/同/精选（分类页均已验证）。
  static const xhamsterDirectoryTags = <SiteTag>[
    SiteTag(id: 'hot', label: '\u70ed\u95e8', icon: Icons.local_fire_department_outlined, iconSelected: Icons.local_fire_department),
    SiteTag(id: 'new', label: '\u6700\u65b0', icon: Icons.fiber_new_outlined, iconSelected: Icons.fiber_new),
    SiteTag(id: 'asian', label: '\u4e9a\u6d32', icon: Icons.public_outlined, iconSelected: Icons.public),
    SiteTag(id: 'japanese', label: '\u65e5\u672c', icon: Icons.flag_outlined, iconSelected: Icons.flag),
    SiteTag(id: 'milf', label: '\u719f\u5973', icon: Icons.person_outline, iconSelected: Icons.person),
    SiteTag(id: 'amateur', label: '\u7d20\u4eba', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'lesbian', label: '\u540c\u6027', icon: Icons.favorite_outline, iconSelected: Icons.favorite),
    SiteTag(id: 'hentai', label: '\u52a8\u6f2b', icon: Icons.animation_outlined, iconSelected: Icons.animation),
    SiteTag(id: 'mature', label: '\u6210\u719f', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'cartoon', label: '\u5361\u901a', icon: Icons.brush_outlined, iconSelected: Icons.brush),
    SiteTag(id: 'best', label: '\u7cbe\u9009', icon: Icons.emoji_events_outlined, iconSelected: Icons.emoji_events),
  ];

  /// TNAFlix 目录标签：新/榜/推/亚 + 常见分类（/search.php?what= 与 /categories/）。
  static const tnaflixDirectoryTags = <SiteTag>[
    SiteTag(id: 'new', label: '\u6700\u65b0', icon: Icons.fiber_new_outlined, iconSelected: Icons.fiber_new),
    SiteTag(id: 'best', label: '\u7cbe\u9009', icon: Icons.emoji_events_outlined, iconSelected: Icons.emoji_events),
    SiteTag(id: 'hot', label: '\u63a8\u8350', icon: Icons.recommend_outlined, iconSelected: Icons.recommend),
    SiteTag(id: 'asian', label: '\u4e9a\u6d32', icon: Icons.public_outlined, iconSelected: Icons.public),
    SiteTag(id: 'japanese', label: '\u65e5\u672c', icon: Icons.flag_outlined, iconSelected: Icons.flag),
    SiteTag(id: 'amateur', label: '\u7d20\u4eba', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'milf', label: '\u719f\u5973', icon: Icons.person_outline, iconSelected: Icons.person),
    SiteTag(id: 'mature', label: '\u6210\u719f', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'lesbian', label: '\u540c\u6027', icon: Icons.favorite_outline, iconSelected: Icons.favorite),
    SiteTag(id: 'anal', label: '\u540e\u5ead', icon: Icons.airline_seat_recline_normal_outlined, iconSelected: Icons.airline_seat_recline_normal),
    SiteTag(id: 'hentai', label: '\u52a8\u6f2b', icon: Icons.animation_outlined, iconSelected: Icons.animation),
  ];

  /// Jable 目录标签：新/热/中字/精选 + 常见 JAV 分类。
  static const jableDirectoryTags = <SiteTag>[
    SiteTag(id: 'new', label: '\u6700\u65b0', icon: Icons.fiber_new_outlined, iconSelected: Icons.fiber_new),
    SiteTag(id: 'hot', label: '\u70ed\u95e8', icon: Icons.local_fire_department_outlined, iconSelected: Icons.local_fire_department),
    SiteTag(id: 'asian', label: '\u4e2d\u5b57', icon: Icons.subtitles_outlined, iconSelected: Icons.subtitles),
    SiteTag(id: 'best', label: '\u7cbe\u9009', icon: Icons.emoji_events_outlined, iconSelected: Icons.emoji_events),
    SiteTag(id: 'japanese', label: '\u65e5\u672c', icon: Icons.flag_outlined, iconSelected: Icons.flag),
    SiteTag(id: 'uncensored', label: '\u65e0\u7801', icon: Icons.no_photography_outlined, iconSelected: Icons.no_photography),
    SiteTag(id: 'amateur', label: '\u7d20\u4eba', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'anal', label: '\u540e\u5ead', icon: Icons.airline_seat_recline_normal_outlined, iconSelected: Icons.airline_seat_recline_normal),
  ];

  static const stripchatTags = <SiteTag>[
    SiteTag(
        id: 'girls',
        label: '\u5973',
        icon: Icons.woman_outlined,
        iconSelected: Icons.woman),
    SiteTag(
        id: 'new',
        label: '\u65b0',
        icon: Icons.fiber_new_outlined,
        iconSelected: Icons.fiber_new),
    SiteTag(
        id: 'couples',
        label: '\u4f34',
        icon: Icons.people_outline,
        iconSelected: Icons.people),
    SiteTag(
        id: 'more',
        label: '\u4e9a',
        icon: Icons.public_outlined,
        iconSelected: Icons.public),
  ];

  static const xvideosTags = <SiteTag>[
    SiteTag(
      id: 'hot',
      label: '\u70ed',
      feedKind: VideoFeedKind.x,
      icon: Icons.local_fire_department_outlined,
      iconSelected: Icons.local_fire_department,
    ),
    SiteTag(
      id: 'new',
      label: '\u65b0',
      feedKind: VideoFeedKind.x,
      icon: Icons.fiber_new_outlined,
      iconSelected: Icons.fiber_new,
    ),
    SiteTag(
      id: 'asian',
      label: '\u4e9a',
      feedKind: VideoFeedKind.x,
      icon: Icons.public_outlined,
      iconSelected: Icons.public,
    ),
    SiteTag(
      id: 'best',
      label: '\u699c',
      feedKind: VideoFeedKind.x,
      icon: Icons.emoji_events_outlined,
      iconSelected: Icons.emoji_events,
    ),
  ];

  /// XNXX 独有标签：热(hits)/新(search-new)/亚(?k=asian)/榜(best)。
  static const xnxxTags = <SiteTag>[
    SiteTag(
      id: 'hot',
      label: '\u70ed',
      icon: Icons.local_fire_department_outlined,
      iconSelected: Icons.local_fire_department,
    ),
    SiteTag(
      id: 'new',
      label: '\u65b0',
      icon: Icons.fiber_new_outlined,
      iconSelected: Icons.fiber_new,
    ),
    SiteTag(
      id: 'asian',
      label: '\u4e9a',
      icon: Icons.public_outlined,
      iconSelected: Icons.public,
    ),
    SiteTag(
      id: 'best',
      label: '\u699c',
      icon: Icons.emoji_events_outlined,
      iconSelected: Icons.emoji_events,
    ),
  ];

  /// xHamster 独有标签：热(hottest)/新(newest)/日(japanese)/亚(categories/asian)。
  static const xhamsterTags = <SiteTag>[
    SiteTag(
      id: 'hot',
      label: '\u70ed',
      icon: Icons.local_fire_department_outlined,
      iconSelected: Icons.local_fire_department,
    ),
    SiteTag(
      id: 'new',
      label: '\u65b0',
      icon: Icons.fiber_new_outlined,
      iconSelected: Icons.fiber_new,
    ),
    SiteTag(
      id: 'japanese',
      label: '\u65e5',
      icon: Icons.flag_outlined,
      iconSelected: Icons.flag,
    ),
    SiteTag(
      id: 'asian',
      label: '\u4e9a',
      icon: Icons.public_outlined,
      iconSelected: Icons.public,
    ),
  ];

  /// TNAFlix 独有标签：新(new)/榜(toprated)/推(popular home)/亚(search asian)。
  static const tnaflixTags = <SiteTag>[
    SiteTag(
      id: 'new',
      label: '\u65b0',
      icon: Icons.fiber_new_outlined,
      iconSelected: Icons.fiber_new,
    ),
    SiteTag(
      id: 'best',
      label: '\u699c',
      icon: Icons.emoji_events_outlined,
      iconSelected: Icons.emoji_events,
    ),
    SiteTag(
      id: 'hot',
      label: '\u63a8',
      icon: Icons.recommend_outlined,
      iconSelected: Icons.recommend,
    ),
    SiteTag(
      id: 'asian',
      label: '\u4e9a',
      icon: Icons.public_outlined,
      iconSelected: Icons.public,
    ),
  ];

  /// Jable 独有标签：新(latest-updates)/热(hot)/中(categories/chinese-subtitle)/榜(best→hot 精选)。
  static const jableTags = <SiteTag>[
    SiteTag(
      id: 'new',
      label: '\u65b0',
      icon: Icons.fiber_new_outlined,
      iconSelected: Icons.fiber_new,
    ),
    SiteTag(
      id: 'hot',
      label: '\u70ed',
      icon: Icons.local_fire_department_outlined,
      iconSelected: Icons.local_fire_department,
    ),
    SiteTag(
      id: 'asian',
      label: '\u4e2d',
      icon: Icons.subtitles_outlined,
      iconSelected: Icons.subtitles,
    ),
    SiteTag(
      id: 'best',
      label: '\u699c',
      icon: Icons.emoji_events_outlined,
      iconSelected: Icons.emoji_events,
    ),
  ];

  static const pornhub = SiteDef(
    id: 'pornhub',
    name: 'Pornhub',
    kind: SiteKind.video,
    color: 0xFFFF9000,
    letter: 'P',
    mirrors: [
      'https://www.pornhub.com',
      'https://www.pornhub.org',
      'https://cn.pornhub.com',
      'https://rt.pornhub.com',
      'https://de.pornhub.com',
      'https://fr.pornhub.com',
    ],
    tags: [
      SiteTag(
        id: 'hot',
        label: '\u70ed',
        feedKind: VideoFeedKind.hot,
        icon: Icons.local_fire_department_outlined,
        iconSelected: Icons.local_fire_department,
      ),
      SiteTag(
        id: 'asian',
        label: '\u4e9a',
        feedKind: VideoFeedKind.asian,
        icon: Icons.public_outlined,
        iconSelected: Icons.public,
      ),
      SiteTag(
        id: 'new',
        label: '\u65b0',
        feedKind: VideoFeedKind.hot,
        icon: Icons.fiber_new_outlined,
        iconSelected: Icons.fiber_new,
      ),
      SiteTag(
        id: 'rec',
        label: '\u63a8',
        feedKind: VideoFeedKind.hot,
        icon: Icons.recommend_outlined,
        iconSelected: Icons.recommend,
      ),
    ],
    directoryTags: pornhubDirectoryTags,
  );

  static const xvideos = SiteDef(
    id: 'xvideos',
    name: 'XVideos',
    kind: SiteKind.video,
    color: 0xFFC41E3A,
    letter: 'X',
    mirrors: [
      'https://www.xvideos.com',
      'https://www.xvideos.es',
      'https://www.xvideos.net',
    ],
    tags: xvideosTags,
    directoryTags: xvideosDirectoryTags,
  );

  /// 黄果短剧 (huangguoai.com) — 内置规则站，主域名可在设置(黄果规则)修改。
  static const huangguoTags = <SiteTag>[
    SiteTag(
      id: 'duanju',
      label: '\u77ed',
      feedKind: VideoFeedKind.hot,
      icon: Icons.movie_outlined,
      iconSelected: Icons.movie,
    ),
    SiteTag(
      id: 'rank',
      label: '\u699c',
      feedKind: VideoFeedKind.hot,
      icon: Icons.emoji_events_outlined,
      iconSelected: Icons.emoji_events,
    ),
    SiteTag(
      id: 'recommend',
      label: '\u63a8',
      feedKind: VideoFeedKind.hot,
      icon: Icons.recommend_outlined,
      iconSelected: Icons.recommend,
    ),
    SiteTag(
      id: 'topics',
      label: '\u4e13',
      feedKind: VideoFeedKind.hot,
      icon: Icons.collections_bookmark_outlined,
      iconSelected: Icons.collections_bookmark,
    ),
  ];

  static const huangguoDirectoryTags = <SiteTag>[
    SiteTag(id: 'recommend', label: '\u9996\u9875', icon: Icons.home_outlined, iconSelected: Icons.home),
    SiteTag(id: 'duanju', label: 'AI\u77ed\u5267', icon: Icons.movie_outlined, iconSelected: Icons.movie),
    SiteTag(id: 'manju', label: 'AI\u6f2b\u5267', icon: Icons.auto_awesome_outlined, iconSelected: Icons.auto_awesome),
    SiteTag(id: 'huanlian', label: 'AI\u6362\u8138', icon: Icons.face_retouching_natural_outlined, iconSelected: Icons.face_retouching_natural),
    SiteTag(id: 'mogai', label: 'AI\u9b54\u6539', icon: Icons.auto_fix_high_outlined, iconSelected: Icons.auto_fix_high),
    SiteTag(id: 'topics', label: '\u4e13\u9898', icon: Icons.collections_bookmark_outlined, iconSelected: Icons.collections_bookmark),
    SiteTag(id: 'rank', label: '\u6392\u884c\u699c', icon: Icons.emoji_events_outlined, iconSelected: Icons.emoji_events),
  ];

  static const huangguo = SiteDef(
    id: 'huangguo',
    name: '\u9ec4\u679c\u77ed\u5267',
    kind: SiteKind.video,
    color: 0xFFFFD21C,
    letter: 'H',
    mirrors: [
      'https://huangguoai.com',
    ],
    tags: huangguoTags,
    directoryTags: huangguoDirectoryTags,
  );

  static const mitao = SiteDef(
    id: 'mitao',
    name: 'mitaohk.com',
    kind: SiteKind.video,
    color: 0xFFE91E63,
    letter: 'M',
    mirrors: [
      'https://mitaohk.com',
      'https://www.mitaohk.com',
    ],
    tags: [
      SiteTag(
        id: 'hot',
        label: '\u70ed',
        feedKind: VideoFeedKind.zhong,
        icon: Icons.local_fire_department_outlined,
        iconSelected: Icons.local_fire_department,
      ),
      SiteTag(
        id: 'sub',
        label: '\u4e2d',
        feedKind: VideoFeedKind.zhong,
        icon: Icons.subtitles_outlined,
        iconSelected: Icons.subtitles,
      ),
      SiteTag(
        id: 'new',
        label: '\u65b0',
        feedKind: VideoFeedKind.zhong,
        icon: Icons.fiber_new_outlined,
        iconSelected: Icons.fiber_new,
      ),
      SiteTag(
        id: 'rec',
        label: '\u63a8',
        feedKind: VideoFeedKind.zhong,
        icon: Icons.recommend_outlined,
        iconSelected: Icons.recommend,
      ),
    ],
    directoryTags: mitaoDirectoryTags,
  );

  static const xnxx = SiteDef(
    id: 'xnxx',
    name: 'XNXX',
    kind: SiteKind.video,
    color: 0xFF1565C0,
    letter: 'N',
    ready: true,
    mirrors: [
      'https://www.xnxx.com',
      'https://www.xnxx.tv',
      'https://www.xnxx.es',
    ],
    tags: xnxxTags,
    directoryTags: xnxxDirectoryTags,
  );

  static const xhamster = SiteDef(
    id: 'xhamster',
    name: 'xHamster',
    kind: SiteKind.video,
    color: 0xFF6A1B9A,
    letter: 'H',
    ready: true,
    mirrors: [
      'https://xhamster.com',
      'https://xhamster.desi',
      'https://xhamster2.com',
      'https://zh.xhamster.com',
    ],
    tags: xhamsterTags,
    directoryTags: xhamsterDirectoryTags,
  );

  // Removed from catalog (unstable / blocked for most users):
  // eporner, freeporn, spankbang, youporn, redtube, javmix, javgg,
  // av01, missav, 7mmtv, bestjavporn.

  static const tnaflix = SiteDef(
    id: 'tnaflix',
    name: 'TNAFlix',
    kind: SiteKind.video,
    color: 0xFF4A148C,
    letter: 'T',
    ready: true,
    mirrors: [
      'https://www.tnaflix.com',
      'https://tnaflix.com',
    ],
    tags: tnaflixTags,
    directoryTags: tnaflixDirectoryTags,
  );

  static const jable = SiteDef(
    id: 'jable',
    name: 'Jable',
    kind: SiteKind.video,
    color: 0xFF1A237E,
    letter: 'J',
    ready: true,
    mirrors: [
      'https://jable.tv',
      'https://www.jable.tv',
      'https://jable.one',
    ],
    tags: jableTags,
    directoryTags: jableDirectoryTags,
  );

  // Removed: our55, xqq88 (unstable for users).

  static const stripchat = SiteDef(
    id: 'stripchat',
    name: 'Stripchat',
    kind: SiteKind.live,
    color: 0xFFD32F2F,
    letter: 'S',
    searchable: false,
    ready: true,
    mirrors: [
      'https://zh.stripchat.com',
      'https://stripchat.com',
      'https://www.stripchat.com',
      'https://stripchat.global',
      'https://xhamsterlive.com',
    ],
    tags: stripchatTags,
    directoryTags: liveDirectoryTags,
  );

  static const chaturbate = SiteDef(
    id: 'chaturbate',
    name: 'Chaturbate',
    kind: SiteKind.live,
    color: 0xFFF57C00,
    letter: 'C',
    searchable: false,
    ready: true,
    mirrors: [
      'https://chaturbate.com',
      'https://www.chaturbate.com',
      'https://zh.chaturbate.com',
      'https://chaturbate.eu',
      'https://chaturbate.global',
    ],
    tags: chaturbateTags,
    directoryTags: liveDirectoryTags,
  );

  static const all = <SiteDef>[
    pornhub,
    xvideos,
    mitao,
    huangguo,
    xnxx,
    xhamster,
    tnaflix,
    jable,
    stripchat,
    chaturbate,
  ];

  static SiteDef? byId(String id) {
    for (final s in all) {
      if (s.id == id) return s;
    }
    return null;
  }

  static List<SiteDef> get videoSites =>
      all.where((s) => s.kind == SiteKind.video).toList();

  static List<SiteDef> get liveSites =>
      all.where((s) => s.kind == SiteKind.live).toList();

  static List<String> get defaultEnabledVideoIds =>
      videoSites.where((s) => s.ready).map((s) => s.id).toList();

  /// The first three VOD adapters randomize internally. Remaining VOD sites
  /// use generic random pages; live channels must stay ordered and stable.
  static bool usesRandomizedGenericFeed(SiteDef site) =>
      site.kind == SiteKind.video &&
      site.id != 'pornhub' &&
      site.id != 'xvideos' &&
      site.id != 'mitao';

  static const defaultLiveId = 'chaturbate';
}
