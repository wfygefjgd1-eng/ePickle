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

  /// 浪妹系解析（浪妹视频/要发发视频）：内置卡片 id 或用户自添加解析。
  /// 二者共用同一套解析器，仅入口域名不同。
  bool get isLangmeiParser =>
      id == 'langmei' ||
      id == 'yaofafa' ||
      parserId == 'langmei' ||
      parserId == 'yaofafa';

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
      // 浪妹系解析的主色跟内置卡片一致（橙/蓝），便于识别。
      color: parserId == 'langmei'
          ? 0xFFF97316
          : parserId == 'yaofafa'
              ? 0xFF2563EB
              : 0xFF607D8B,
      letter: letter,
      // 不能用 startsWith('http') 判 scheme：httpbin.org / httpx.cc 这类域名
      // 会被误判成"已有 scheme"而原样入库，请求时变成无 scheme 的相对路径
      // 直接失败；全大写 HTTP:// 也会漏判。按协议头正则判（忽略大小写）。
      mirrors: [
        RegExp(r'^https?://', caseSensitive: false).hasMatch(u)
            ? u
            : 'https://$u',
      ],
      // 浪妹系解析：标签由 LangmeiApi.fetchTypes 动态解析（LangmeiPage
      // 专用页），tags 留空即可——home_page._openSite 按 isLangmeiParser
      // 分发到 LangmeiPage，通用 feed 页不会被走到。
      tags: switch (parserId) {
        'stripchat' => SourceCatalog.stripchatTags,
        'chaturbate' => SourceCatalog.chaturbateTags,
        'pornhub' => SourceCatalog.pornhub.tags,
        'xvideos' => SourceCatalog.xvideos.tags,
        'mitao' => SourceCatalog.mitao.tags,
        'huangguo' => SourceCatalog.huangguoTags,
        'ixxx' => SourceCatalog.ixxx.tags,
        'fuq' || 'qorno' || 'pornkai' || 'tubesafari' || 'hotsextube' =>
          SourceCatalog.aggregatorTags,
        'langmei' || 'yaofafa' => const <SiteTag>[],
        _ => SourceCatalog.vodTags,
      },
      directoryTags: switch (parserId) {
        'stripchat' => SourceCatalog.stripchatDirectoryTags,
        'chaturbate' => SourceCatalog.chaturbateDirectoryTags,
        'huangguo' => SourceCatalog.huangguoDirectoryTags,
        'ixxx' => SourceCatalog.ixxxDirectoryTags,
        'fuq' || 'qorno' => SourceCatalog.ixxxDirectoryTags,
        'pornkai' => SourceCatalog.pornkaiDirectoryTags,
        'tubesafari' => SourceCatalog.tubesafariDirectoryTags,
        'hotsextube' => SourceCatalog.hotsextubeDirectoryTags,
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

  /// 长片源（完整 VOD）站点 id。预览/广告/保护夹片判定用：这些站点返回的
  /// 有效但极短的 MP4 多属未授权预览。中心化维护，供 playback_helpers 引用。
  /// 通用解析（用户自添加）的长片源若也出现"短预览被误判"，在此追加。
  static const longFormPreviewSiteIds = <String>{
    'eporner',
    'redtube',
    '7mmtv',
    'javmix',
    'javgg',
    'bestjavporn',
    'langmei',
    'yaofafa',
  };

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

  /// Stripchat 目录标签：取自官网 /tags 页的真实主题。
  /// 性别组（女生/情侣/男主播/跨性别）走 primaryTag API；
  /// 其余主题走服务端渲染页 /girls/{tag}。
  static const stripchatDirectoryTags = <SiteTag>[
    SiteTag(id: 'girls', label: '\u5973\u4e3b\u64ad', icon: Icons.woman_outlined, iconSelected: Icons.woman),
    SiteTag(id: 'couples', label: '\u60c5\u4fa3', icon: Icons.people_outline, iconSelected: Icons.people),
    SiteTag(id: 'men', label: '\u7537\u4e3b\u64ad', icon: Icons.man_outlined, iconSelected: Icons.man),
    SiteTag(id: 'trans', label: '\u8de8\u6027\u522b', icon: Icons.diversity_3_outlined, iconSelected: Icons.diversity_3),
    SiteTag(id: 'new', label: '\u6700\u65b0', icon: Icons.fiber_new_outlined, iconSelected: Icons.fiber_new),
    SiteTag(id: 'more', label: '\u66f4\u591a', icon: Icons.more_horiz_outlined, iconSelected: Icons.more_horiz),
    SiteTag(id: 'asian', label: '\u4e9a\u6d32', icon: Icons.public_outlined, iconSelected: Icons.public),
    SiteTag(id: 'ebony', label: '\u9ed1\u73e0', icon: Icons.nightlife_outlined, iconSelected: Icons.nightlife),
    SiteTag(id: 'latin', label: '\u62c9\u4e01', icon: Icons.language_outlined, iconSelected: Icons.language),
    SiteTag(id: 'white', label: '\u767d\u4eba', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'arab', label: '\u963f\u62c9\u4f2f', icon: Icons.history_edu_outlined, iconSelected: Icons.history_edu),
    SiteTag(id: 'indian', label: '\u5370\u5ea6', icon: Icons.emoji_objects_outlined, iconSelected: Icons.emoji_objects),
    SiteTag(id: 'mixed', label: '\u6df7\u8840', icon: Icons.interpreter_mode_outlined, iconSelected: Icons.interpreter_mode),
    SiteTag(id: 'chinese', label: '\u4e2d\u56fd', icon: Icons.translate_outlined, iconSelected: Icons.translate),
    SiteTag(id: 'american', label: '\u7f8e\u56fd', icon: Icons.flag_outlined, iconSelected: Icons.flag),
    SiteTag(id: 'ukrainian', label: '\u4e4c\u514b\u5170', icon: Icons.flag_circle_outlined, iconSelected: Icons.flag_circle),
    SiteTag(id: 'teens', label: '\u5c11\u5973', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'young', label: '\u9c9c\u5ae9', icon: Icons.face_retouching_natural_outlined, iconSelected: Icons.face_retouching_natural),
    SiteTag(id: 'milfs', label: '\u719f\u5973', icon: Icons.person_outline, iconSelected: Icons.person),
    SiteTag(id: 'mature', label: '\u6210\u719f', icon: Icons.face_2_outlined, iconSelected: Icons.face_2),
    SiteTag(id: 'grannies', label: '\u8001\u5988', icon: Icons.elderly_outlined, iconSelected: Icons.elderly),
    SiteTag(id: 'petite', label: '\u5c0f\u5de7', icon: Icons.child_care_outlined, iconSelected: Icons.child_care),
    SiteTag(id: 'athletic', label: '\u8fd0\u52a8\u578b', icon: Icons.fitness_center_outlined, iconSelected: Icons.fitness_center),
    SiteTag(id: 'medium', label: '\u6807\u51c6', icon: Icons.accessibility_new_outlined, iconSelected: Icons.accessibility_new),
    SiteTag(id: 'curvy', label: '\u4e30\u6ee1', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'bbw', label: '\u80a5\u5a46', icon: Icons.sensor_occupied_outlined, iconSelected: Icons.sensor_occupied),
    SiteTag(id: 'blondes', label: '\u91d1\u53d1', icon: Icons.face_retouching_natural_outlined, iconSelected: Icons.face_retouching_natural),
    SiteTag(id: 'brunettes', label: '\u68d5\u53d1', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'redheads', label: '\u7ea2\u53d1', icon: Icons.face_3_outlined, iconSelected: Icons.face_3),
    SiteTag(id: 'black-hair', label: '\u9ed1\u53d1', icon: Icons.face_2_outlined, iconSelected: Icons.face_2),
    SiteTag(id: 'colorful', label: '\u5f69\u53d1', icon: Icons.palette_outlined, iconSelected: Icons.palette),
    SiteTag(id: 'big-tits', label: '\u5de8\u4e73', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'big-ass', label: '\u5de8\u81c0', icon: Icons.airline_seat_legroom_reduced_outlined, iconSelected: Icons.airline_seat_legroom_reduced),
    SiteTag(id: 'small-tits', label: '\u5c0f\u80f8', icon: Icons.child_care_outlined, iconSelected: Icons.child_care),
    SiteTag(id: 'pregnant', label: '\u5b55\u5987', icon: Icons.pregnant_woman_outlined, iconSelected: Icons.pregnant_woman),
    SiteTag(id: 'hairy', label: '\u591a\u6bdb', icon: Icons.brush_outlined, iconSelected: Icons.brush),
    SiteTag(id: 'shaven', label: '\u8347\u5149', icon: Icons.cleaning_services_outlined, iconSelected: Icons.cleaning_services),
    SiteTag(id: 'tattoo', label: '\u7eb9\u8eab', icon: Icons.brush_outlined, iconSelected: Icons.brush),
    SiteTag(id: 'anal', label: '\u809b\u4ea4', icon: Icons.airline_seat_recline_normal_outlined, iconSelected: Icons.airline_seat_recline_normal),
    SiteTag(id: 'squirt', label: '\u6f6e\u5439', icon: Icons.water_outlined, iconSelected: Icons.water),
    SiteTag(id: 'blowjob', label: '\u53e3\u4ea4', icon: Icons.mic_external_on_outlined, iconSelected: Icons.mic_external_on),
    SiteTag(id: 'deepthroat', label: '\u6df1\u54bd', icon: Icons.vpn_key_outlined, iconSelected: Icons.vpn_key),
    SiteTag(id: 'masturbation', label: '\u81ea\u6170', icon: Icons.self_improvement_outlined, iconSelected: Icons.self_improvement),
    SiteTag(id: 'fisting', label: '\u62f3\u4ea4', icon: Icons.front_hand_outlined, iconSelected: Icons.front_hand),
    SiteTag(id: 'hardcore', label: '\u7c97\u66b4', icon: Icons.flash_on_outlined, iconSelected: Icons.flash_on),
    SiteTag(id: 'foot-fetish', label: '\u8db3\u63a7', icon: Icons.ice_skating_outlined, iconSelected: Icons.ice_skating),
    SiteTag(id: 'outdoor', label: '\u6237\u5916', icon: Icons.landscape_outlined, iconSelected: Icons.landscape),
    SiteTag(id: 'group-sex', label: '\u7fa4\u4ea4', icon: Icons.groups_2_outlined, iconSelected: Icons.groups_2),
    SiteTag(id: 'vr', label: 'VR', icon: Icons.view_in_ar_outlined, iconSelected: Icons.view_in_ar),
    SiteTag(id: 'bdsm', label: 'BDSM', icon: Icons.health_and_safety_outlined, iconSelected: Icons.health_and_safety),
    SiteTag(id: 'mobile', label: '\u79fb\u52a8', icon: Icons.smartphone_outlined, iconSelected: Icons.smartphone),
    SiteTag(id: 'interactive-toys', label: '\u4e92\u52a8\u73a9\u5177', icon: Icons.toys_outlined, iconSelected: Icons.toys),
    SiteTag(id: 'cam2cam', label: '\u89c6\u9891', icon: Icons.videocam_outlined, iconSelected: Icons.videocam),
  ];

    /// CHATURBATE 目录标签（2026-10-28 实证：roomlist API 房间标签收割，客户端过滤语义）。
  static const chaturbateDirectoryTags = <SiteTag>[
    SiteTag(id: 'female', label: '\u5973\u4e3b\u64ad', icon: Icons.woman_outlined, iconSelected: Icons.woman),
    SiteTag(id: 'couples', label: '\u60c5\u4fa3', icon: Icons.people_outline, iconSelected: Icons.people),
    SiteTag(id: 'male', label: '\u7537\u4e3b\u64ad', icon: Icons.man_outlined, iconSelected: Icons.man),
    SiteTag(id: 'trans', label: '\u8de8\u6027\u522b', icon: Icons.diversity_3_outlined, iconSelected: Icons.diversity_3),
    SiteTag(id: 'new', label: '\u6700\u65b0', icon: Icons.fiber_new_outlined, iconSelected: Icons.fiber_new),
    SiteTag(id: 'teen', label: '\u5c11\u5973', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'young', label: '\u5e74\u9752', icon: Icons.face_retouching_natural_outlined, iconSelected: Icons.face_retouching_natural),
    SiteTag(id: 'bigboobs', label: '\u7206\u4e73', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'bigtits', label: '\u5de8\u4e73', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'bigass', label: '\u5de8\u81c0', icon: Icons.airline_seat_legroom_reduced_outlined, iconSelected: Icons.airline_seat_legroom_reduced),
    SiteTag(id: 'skinny', label: '\u7626\u5f31', icon: Icons.airline_seat_flat_outlined, iconSelected: Icons.airline_seat_flat),
    SiteTag(id: 'squirt', label: '\u6f6e\u55b7', icon: Icons.water_outlined, iconSelected: Icons.water),
    SiteTag(id: 'lovense', label: '\u73a9\u5177\u8054\u52a8', icon: Icons.toys_outlined, iconSelected: Icons.toys),
    SiteTag(id: 'natural', label: '\u5929\u751f', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'shy', label: '\u5bb3\u7f9e', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'anal', label: '\u540e\u5ead', icon: Icons.airline_seat_recline_normal_outlined, iconSelected: Icons.airline_seat_recline_normal),
    SiteTag(id: 'ass', label: '\u7fd8\u81c0', icon: Icons.airline_seat_class_outlined, iconSelected: Icons.airline_seat_class),
    SiteTag(id: 'latina', label: '\u62c9\u7f8e', icon: Icons.language_outlined, iconSelected: Icons.language),
    SiteTag(id: 'asian', label: '\u4e9a\u6d32', icon: Icons.public_outlined, iconSelected: Icons.public),
    SiteTag(id: 'blonde', label: '\u91d1\u53d1', icon: Icons.face_retouching_natural_outlined, iconSelected: Icons.face_retouching_natural),
    SiteTag(id: 'brunette', label: '\u68d5\u53d1', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'redhead', label: '\u7ea2\u53d1', icon: Icons.face_3_outlined, iconSelected: Icons.face_3),
    SiteTag(id: 'smalltits', label: '\u5c0f\u80f8', icon: Icons.child_care_outlined, iconSelected: Icons.child_care),
    SiteTag(id: 'feet', label: '\u8db3\u63a7', icon: Icons.ice_skating_outlined, iconSelected: Icons.ice_skating),
    SiteTag(id: 'milf', label: '\u719f\u5973', icon: Icons.person_outline, iconSelected: Icons.person),
    SiteTag(id: 'mature', label: '\u6210\u719f', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'hairy', label: '\u591a\u6bdb', icon: Icons.brush_outlined, iconSelected: Icons.brush),
    SiteTag(id: 'cute', label: '\u53ef\u7231', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'deepthroat', label: '\u6df1\u54bd', icon: Icons.vpn_key_outlined, iconSelected: Icons.vpn_key),
    SiteTag(id: 'tease', label: '\u6311\u9017', icon: Icons.bubble_chart_outlined, iconSelected: Icons.bubble_chart),
    SiteTag(id: 'fuckmachine', label: '\u7eed\u673a', icon: Icons.precision_manufacturing_outlined, iconSelected: Icons.precision_manufacturing),
    SiteTag(id: 'ahegao', label: '\u5165\u72c2\u989c', icon: Icons.sick_outlined, iconSelected: Icons.sick),
    SiteTag(id: 'petite', label: '\u5c0f\u5de7', icon: Icons.child_care_outlined, iconSelected: Icons.child_care),
    SiteTag(id: 'heels', label: '\u9ad8\u8dbe', icon: Icons.directions_walk_outlined, iconSelected: Icons.directions_walk),
    SiteTag(id: 'fit', label: '\u5065\u7f8e', icon: Icons.fitness_center_outlined, iconSelected: Icons.fitness_center),
    SiteTag(id: 'tattoo', label: '\u7eb9\u8eab', icon: Icons.brush_outlined, iconSelected: Icons.brush),
    SiteTag(id: 'cosplay', label: '\u89d2\u8272\u626e\u6f14', icon: Icons.theater_comedy_outlined, iconSelected: Icons.theater_comedy),
    SiteTag(id: 'ebony', label: '\u9ed1\u73e0', icon: Icons.nightlife_outlined, iconSelected: Icons.nightlife),
    SiteTag(id: 'pantyhose', label: '\u6ed1\u626b', icon: Icons.ice_skating_outlined, iconSelected: Icons.ice_skating),
    SiteTag(id: 'latex', label: '\u4e73\u80f6', icon: Icons.style_outlined, iconSelected: Icons.style),
    SiteTag(id: 'femdom', label: '\u5973\u738b', icon: Icons.gavel_outlined, iconSelected: Icons.gavel),
    SiteTag(id: 'stockings', label: '\u4e1d\u889c', icon: Icons.ice_skating_outlined, iconSelected: Icons.ice_skating),
    SiteTag(id: 'curvy', label: '\u4e30\u6ee1', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'goth', label: '\u54e5\u7279\u98ce', icon: Icons.nights_stay_outlined, iconSelected: Icons.nights_stay),
    SiteTag(id: 'mistress', label: '\u5973\u4e3b', icon: Icons.gavel_outlined, iconSelected: Icons.gavel),
    SiteTag(id: 'bbc', label: 'BBC', icon: Icons.nightlife_outlined, iconSelected: Icons.nightlife),
    SiteTag(id: 'cuckold', label: '\u9ec4\u8fa3', icon: Icons.nightlife_outlined, iconSelected: Icons.nightlife),
    SiteTag(id: 'twerk', label: '\u7529\u81c0', icon: Icons.directions_run_outlined, iconSelected: Icons.directions_run),
    SiteTag(id: 'bbw', label: '\u80a5\u5a46', icon: Icons.sensor_occupied_outlined, iconSelected: Icons.sensor_occupied),
    SiteTag(id: 'shaved', label: '\u8347\u5149', icon: Icons.cleaning_services_outlined, iconSelected: Icons.cleaning_services),
    SiteTag(id: 'collegegirl', label: '\u5973\u5927\u5b66', icon: Icons.school_outlined, iconSelected: Icons.school),
    SiteTag(id: 'c2c', label: '\u8054\u9ea6', icon: Icons.videocam_outlined, iconSelected: Icons.videocam),
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

    /// PORNHUB 目录标签（2026-10-28 实证：每个 /video?c={id} 页面逐个 200 校准）。
  static const pornhubDirectoryTags = <SiteTag>[
    SiteTag(id: 'hot', label: '\u70ed\u95e8', icon: Icons.local_fire_department_outlined, iconSelected: Icons.local_fire_department),
    SiteTag(id: 'new', label: '\u6700\u65b0', icon: Icons.fiber_new_outlined, iconSelected: Icons.fiber_new),
    SiteTag(id: 'best', label: '\u7cbe\u9009', icon: Icons.emoji_events_outlined, iconSelected: Icons.emoji_events),
    SiteTag(id: 'asian', label: '\u4e9a\u6d32', icon: Icons.public_outlined, iconSelected: Icons.public),
    SiteTag(id: 'amateur', label: '\u7d20\u4eba', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'verified-amateurs', label: '\u8ba4\u8bc1\u7d20\u4eba', icon: Icons.verified_outlined, iconSelected: Icons.verified),
    SiteTag(id: 'milf', label: '\u719f\u5973', icon: Icons.person_outline, iconSelected: Icons.person),
    SiteTag(id: 'mature', label: '\u6210\u719f', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'anal', label: '\u540e\u5ead', icon: Icons.airline_seat_recline_normal_outlined, iconSelected: Icons.airline_seat_recline_normal),
    SiteTag(id: 'blowjob', label: '\u53e3\u6d3b', icon: Icons.mic_external_on_outlined, iconSelected: Icons.mic_external_on),
    SiteTag(id: 'creampie', label: '\u4e2d\u51fa', icon: Icons.water_drop_outlined, iconSelected: Icons.water_drop),
    SiteTag(id: 'cumshot', label: '\u5c04\u7cbe', icon: Icons.blur_on_outlined, iconSelected: Icons.blur_on),
    SiteTag(id: 'ebony', label: '\u9ed1\u73e0', icon: Icons.nightlife_outlined, iconSelected: Icons.nightlife),
    SiteTag(id: 'latina', label: '\u62c9\u7f8e', icon: Icons.language_outlined, iconSelected: Icons.language),
    SiteTag(id: 'lesbian', label: '\u767e\u5408', icon: Icons.favorite_outline, iconSelected: Icons.favorite),
    SiteTag(id: 'uncensored-hentai', label: '\u65e0\u7801\u91cc\u756a', icon: Icons.animation_outlined, iconSelected: Icons.animation),
    SiteTag(id: 'cartoon', label: '\u52a8\u6f2b', icon: Icons.palette_outlined, iconSelected: Icons.palette),
    SiteTag(id: 'pov', label: '\u7b2c\u4e00\u89c6\u89d2', icon: Icons.videocam_outlined, iconSelected: Icons.videocam),
    SiteTag(id: 'threesome', label: '3P', icon: Icons.groups_outlined, iconSelected: Icons.groups),
    SiteTag(id: 'orgy', label: '\u7fa4\u4ea4', icon: Icons.groups_2_outlined, iconSelected: Icons.groups_2),
    SiteTag(id: 'gangbang', label: '\u8f6e\u64cd', icon: Icons.groups_3_outlined, iconSelected: Icons.groups_3),
    SiteTag(id: 'squirt', label: '\u6f6e\u55b7', icon: Icons.water_outlined, iconSelected: Icons.water),
    SiteTag(id: 'feet', label: '\u8db3\u63a7', icon: Icons.ice_skating_outlined, iconSelected: Icons.ice_skating),
    SiteTag(id: 'fetish', label: '\u604b\u7269', icon: Icons.psychology_outlined, iconSelected: Icons.psychology),
    SiteTag(id: 'bondage', label: '\u6346\u7ed1', icon: Icons.link_outlined, iconSelected: Icons.link),
    SiteTag(id: 'big-ass', label: '\u5de8\u81c0', icon: Icons.airline_seat_legroom_reduced_outlined, iconSelected: Icons.airline_seat_legroom_reduced),
    SiteTag(id: 'big-tits', label: '\u5de8\u4e73', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'small-tits', label: '\u5c0f\u80f8', icon: Icons.child_care_outlined, iconSelected: Icons.child_care),
    SiteTag(id: 'blonde', label: '\u91d1\u53d1', icon: Icons.face_retouching_natural_outlined, iconSelected: Icons.face_retouching_natural),
    SiteTag(id: 'brunette', label: '\u68d5\u53d1', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'red-head', label: '\u7ea2\u53d1', icon: Icons.face_3_outlined, iconSelected: Icons.face_3),
    SiteTag(id: 'russian', label: '\u4fc4\u7f57\u65af', icon: Icons.flag_outlined, iconSelected: Icons.flag),
    SiteTag(id: 'indian', label: '\u5370\u5ea6', icon: Icons.history_edu_outlined, iconSelected: Icons.history_edu),
    SiteTag(id: 'japanese', label: '\u65e5\u672c', icon: Icons.flag_outlined, iconSelected: Icons.flag),
    SiteTag(id: 'korean', label: '\u97e9\u56fd', icon: Icons.flag_circle_outlined, iconSelected: Icons.flag_circle),
    SiteTag(id: 'interracial', label: '\u8de8\u79cd\u65cf', icon: Icons.interpreter_mode_outlined, iconSelected: Icons.interpreter_mode),
    SiteTag(id: 'massage', label: '\u6309\u6469', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'casting', label: '\u8bd5\u955c', icon: Icons.theater_comedy_outlined, iconSelected: Icons.theater_comedy),
    SiteTag(id: 'masturbation', label: '\u81ea\u6170', icon: Icons.self_improvement_outlined, iconSelected: Icons.self_improvement),
    SiteTag(id: 'toys', label: '\u73a9\u5177', icon: Icons.toys_outlined, iconSelected: Icons.toys),
    SiteTag(id: 'webcam', label: '\u76f4\u64ad', icon: Icons.videocam_outlined, iconSelected: Icons.videocam),
    SiteTag(id: 'vintage', label: '\u590d\u53e4', icon: Icons.hourglass_bottom_outlined, iconSelected: Icons.hourglass_bottom),
    SiteTag(id: 'public', label: '\u6237\u5916\u516c\u5f00', icon: Icons.landscape_outlined, iconSelected: Icons.landscape),
    SiteTag(id: 'pissing', label: '\u55b7\u6c34', icon: Icons.water_outlined, iconSelected: Icons.water),
    SiteTag(id: 'cuckold', label: '\u9ec4\u8fa3', icon: Icons.nightlife_outlined, iconSelected: Icons.nightlife),
    SiteTag(id: 'double-penetration', label: '\u53cc\u63d2', icon: Icons.call_merge_outlined, iconSelected: Icons.call_merge),
    SiteTag(id: 'role-play', label: '\u89d2\u8272\u626e\u6f14', icon: Icons.theater_comedy_outlined, iconSelected: Icons.theater_comedy),
    SiteTag(id: 'romantic', label: '\u6d6a\u6f2b', icon: Icons.auto_awesome_outlined, iconSelected: Icons.auto_awesome),
    SiteTag(id: 'striptease', label: '\u8131\u8863', icon: Icons.nightlife_outlined, iconSelected: Icons.nightlife),
    SiteTag(id: 'cosplay', label: '\u89d2\u8272\u626e\u6f14', icon: Icons.theater_comedy_outlined, iconSelected: Icons.theater_comedy),
    SiteTag(id: 'solo-female', label: '\u72ec\u6f14', icon: Icons.person_pin_outlined, iconSelected: Icons.person_pin),
    SiteTag(id: 'fisting', label: '\u62f3\u4ea4', icon: Icons.front_hand_outlined, iconSelected: Icons.front_hand),
    SiteTag(id: 'fingering', label: '\u624b\u6307', icon: Icons.back_hand_outlined, iconSelected: Icons.back_hand),
    SiteTag(id: 'old-young', label: '\u8001\u5c11\u914d', icon: Icons.hourglass_bottom_outlined, iconSelected: Icons.hourglass_bottom),
    SiteTag(id: 'step-fantasy', label: '\u7ee7\u6bcd\u60c5\u7ed3', icon: Icons.family_restroom_outlined, iconSelected: Icons.family_restroom),
    SiteTag(id: 'party', label: '\u6d3e\u5bf9', icon: Icons.celebration_outlined, iconSelected: Icons.celebration),
    SiteTag(id: 'euro', label: '\u6b27\u6d32', icon: Icons.public_outlined, iconSelected: Icons.public),
    SiteTag(id: 'bukkake', label: '\u989c\u5e78', icon: Icons.blur_on_outlined, iconSelected: Icons.blur_on),
    SiteTag(id: 'rough-sex', label: '\u7c97\u66b4', icon: Icons.flash_on_outlined, iconSelected: Icons.flash_on),
    SiteTag(id: 'compilation', label: '\u5408\u96c6', icon: Icons.blur_on_outlined, iconSelected: Icons.blur_on),
    SiteTag(id: 'hardcore', label: '\u786c\u6838', icon: Icons.flash_on_outlined, iconSelected: Icons.flash_on),
  ];

    /// XVIDEOS 目录标签（2026-10-28 实证：/tags/{slug} 200 + ?k= 搜索兜底）。
  static const xvideosDirectoryTags = <SiteTag>[
    SiteTag(id: 'hot', label: '\u70ed\u95e8', icon: Icons.local_fire_department_outlined, iconSelected: Icons.local_fire_department),
    SiteTag(id: 'new', label: '\u6700\u65b0', icon: Icons.fiber_new_outlined, iconSelected: Icons.fiber_new),
    SiteTag(id: 'best', label: '\u7cbe\u9009', icon: Icons.emoji_events_outlined, iconSelected: Icons.emoji_events),
    SiteTag(id: 'asian', label: '\u4e9a\u6d32', icon: Icons.public_outlined, iconSelected: Icons.public),
    SiteTag(id: 'japanese', label: '\u65e5\u672c', icon: Icons.flag_outlined, iconSelected: Icons.flag),
    SiteTag(id: 'chinese', label: '\u4e2d\u6587', icon: Icons.translate_outlined, iconSelected: Icons.translate),
    SiteTag(id: 'korean', label: '\u97e9\u56fd', icon: Icons.flag_circle_outlined, iconSelected: Icons.flag_circle),
    SiteTag(id: 'amateur', label: '\u7d20\u4eba', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'milf', label: '\u719f\u5973', icon: Icons.person_outline, iconSelected: Icons.person),
    SiteTag(id: 'mature', label: '\u6210\u719f', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'anal', label: '\u540e\u5ead', icon: Icons.airline_seat_recline_normal_outlined, iconSelected: Icons.airline_seat_recline_normal),
    SiteTag(id: 'anal-creampie', label: '\u540e\u5ead\u4e2d\u51fa', icon: Icons.water_drop_outlined, iconSelected: Icons.water_drop),
    SiteTag(id: 'blowjob', label: '\u53e3\u6d3b', icon: Icons.mic_external_on_outlined, iconSelected: Icons.mic_external_on),
    SiteTag(id: 'deepthroat', label: '\u6df1\u54bd', icon: Icons.vpn_key_outlined, iconSelected: Icons.vpn_key),
    SiteTag(id: 'facial', label: '\u989c\u5c04', icon: Icons.blur_on_outlined, iconSelected: Icons.blur_on),
    SiteTag(id: 'creampie', label: '\u4e2d\u51fa', icon: Icons.water_drop_outlined, iconSelected: Icons.water_drop),
    SiteTag(id: 'cumshot', label: '\u5c04\u7cbe', icon: Icons.blur_on_outlined, iconSelected: Icons.blur_on),
    SiteTag(id: 'ebony', label: '\u9ed1\u73e0', icon: Icons.nightlife_outlined, iconSelected: Icons.nightlife),
    SiteTag(id: 'latina', label: '\u62c9\u7f8e', icon: Icons.language_outlined, iconSelected: Icons.language),
    SiteTag(id: 'lesbian', label: '\u767e\u5408', icon: Icons.favorite_outline, iconSelected: Icons.favorite),
    SiteTag(id: 'hentai', label: '\u91cc\u756a', icon: Icons.animation_outlined, iconSelected: Icons.animation),
    SiteTag(id: 'cartoon', label: '\u52a8\u6f2b', icon: Icons.palette_outlined, iconSelected: Icons.palette),
    SiteTag(id: 'pov', label: '\u7b2c\u4e00\u89c6\u89d2', icon: Icons.videocam_outlined, iconSelected: Icons.videocam),
    SiteTag(id: 'threesome', label: '3P', icon: Icons.groups_outlined, iconSelected: Icons.groups),
    SiteTag(id: 'orgy', label: '\u7fa4\u4ea4', icon: Icons.groups_2_outlined, iconSelected: Icons.groups_2),
    SiteTag(id: 'gangbang', label: '\u8f6e\u64cd', icon: Icons.groups_3_outlined, iconSelected: Icons.groups_3),
    SiteTag(id: 'squirt', label: '\u6f6e\u55b7', icon: Icons.water_outlined, iconSelected: Icons.water),
    SiteTag(id: 'feet', label: '\u8db3\u63a7', icon: Icons.ice_skating_outlined, iconSelected: Icons.ice_skating),
    SiteTag(id: 'fetish', label: '\u604b\u7269', icon: Icons.psychology_outlined, iconSelected: Icons.psychology),
    SiteTag(id: 'bondage', label: '\u6346\u7ed1', icon: Icons.link_outlined, iconSelected: Icons.link),
    SiteTag(id: 'bdsm', label: 'BDSM', icon: Icons.health_and_safety_outlined, iconSelected: Icons.health_and_safety),
    SiteTag(id: 'big-ass', label: '\u5de8\u81c0', icon: Icons.airline_seat_legroom_reduced_outlined, iconSelected: Icons.airline_seat_legroom_reduced),
    SiteTag(id: 'big-tits', label: '\u5de8\u4e73', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'small-tits', label: '\u5c0f\u80f8', icon: Icons.child_care_outlined, iconSelected: Icons.child_care),
    SiteTag(id: 'blonde', label: '\u91d1\u53d1', icon: Icons.face_retouching_natural_outlined, iconSelected: Icons.face_retouching_natural),
    SiteTag(id: 'brunette', label: '\u68d5\u53d1', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'redhead', label: '\u7ea2\u53d1', icon: Icons.face_3_outlined, iconSelected: Icons.face_3),
    SiteTag(id: 'russian', label: '\u4fc4\u7f57\u65af', icon: Icons.flag_outlined, iconSelected: Icons.flag),
    SiteTag(id: 'indian', label: '\u5370\u5ea6', icon: Icons.history_edu_outlined, iconSelected: Icons.history_edu),
    SiteTag(id: 'masturbation', label: '\u81ea\u6170', icon: Icons.self_improvement_outlined, iconSelected: Icons.self_improvement),
    SiteTag(id: 'toys', label: '\u73a9\u5177', icon: Icons.toys_outlined, iconSelected: Icons.toys),
    SiteTag(id: 'compilation', label: '\u5408\u96c6', icon: Icons.blur_on_outlined, iconSelected: Icons.blur_on),
    SiteTag(id: 'reality', label: '\u771f\u4eba\u5b9e\u62cd', icon: Icons.visibility_outlined, iconSelected: Icons.visibility),
    SiteTag(id: 'vintage', label: '\u590d\u53e4', icon: Icons.hourglass_bottom_outlined, iconSelected: Icons.hourglass_bottom),
    SiteTag(id: 'webcam', label: '\u76f4\u64ad', icon: Icons.videocam_outlined, iconSelected: Icons.videocam),
    SiteTag(id: 'public', label: '\u6237\u5916\u516c\u5f00', icon: Icons.landscape_outlined, iconSelected: Icons.landscape),
    SiteTag(id: 'pissing', label: '\u55b7\u6c34', icon: Icons.water_outlined, iconSelected: Icons.water),
    SiteTag(id: 'outdoor', label: '\u6237\u5916', icon: Icons.landscape_outlined, iconSelected: Icons.landscape),
    SiteTag(id: 'femdom', label: '\u5973\u738b', icon: Icons.gavel_outlined, iconSelected: Icons.gavel),
    SiteTag(id: 'cuckold', label: '\u9ec4\u8fa3', icon: Icons.nightlife_outlined, iconSelected: Icons.nightlife),
    SiteTag(id: 'interracial', label: '\u8de8\u79cd\u65cf', icon: Icons.interpreter_mode_outlined, iconSelected: Icons.interpreter_mode),
    SiteTag(id: 'rimjob', label: '\u8214\u809b', icon: Icons.local_dining_outlined, iconSelected: Icons.local_dining),
    SiteTag(id: 'orgasm', label: '\u9ad8\u6f6e', icon: Icons.waves_outlined, iconSelected: Icons.waves),
    SiteTag(id: 'homemade', label: '\u81ea\u5236', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'massage', label: '\u6309\u6469', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'fisting', label: '\u62f3\u4ea4', icon: Icons.front_hand_outlined, iconSelected: Icons.front_hand),
    SiteTag(id: 'double-penetration', label: '\u53cc\u63d2', icon: Icons.call_merge_outlined, iconSelected: Icons.call_merge),
    SiteTag(id: 'stockings', label: '\u4e1d\u889c', icon: Icons.ice_skating_outlined, iconSelected: Icons.ice_skating),
    SiteTag(id: 'latex', label: '\u4e73\u80f6', icon: Icons.style_outlined, iconSelected: Icons.style),
    SiteTag(id: 'striptease', label: '\u8131\u8863', icon: Icons.nightlife_outlined, iconSelected: Icons.nightlife),
    SiteTag(id: 'asmr', label: 'ASMR', icon: Icons.headphones_outlined, iconSelected: Icons.headphones),
    SiteTag(id: 'close-up', label: '\u7279\u5199', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'missionary', label: '\u4f20\u6559\u58eb', icon: Icons.self_improvement_outlined, iconSelected: Icons.self_improvement),
    SiteTag(id: 'facesitting', label: '\u9a91\u8138', icon: Icons.face_retouching_natural_outlined, iconSelected: Icons.face_retouching_natural),
    SiteTag(id: 'solo-female', label: '\u72ec\u6f14', icon: Icons.person_pin_outlined, iconSelected: Icons.person_pin),
    SiteTag(id: 'joi', label: '\u81ea\u6170\u6307\u5bfc', icon: Icons.record_voice_over_outlined, iconSelected: Icons.record_voice_over),
  ];

  /// Mitao（龙猫视频）目录标签：来自站内真实分类（type id 1-5）+ 热门搜索词。
  static const mitaoDirectoryTags = <SiteTag>[
    SiteTag(id: 'hot', label: '\u70ed\u95e8', icon: Icons.local_fire_department_outlined, iconSelected: Icons.local_fire_department),
    SiteTag(id: 'new', label: '\u6700\u65b0', icon: Icons.fiber_new_outlined, iconSelected: Icons.fiber_new),
    SiteTag(id: '\u56fd\u4ea7\u7cbe\u54c1', label: '\u56fd\u4ea7\u7cbe\u54c1', icon: Icons.home_outlined, iconSelected: Icons.home),
    SiteTag(id: '\u4e2d\u6587\u5b57\u5e55', label: '\u4e2d\u6587\u5b57\u5e55', icon: Icons.subtitles_outlined, iconSelected: Icons.subtitles),
    SiteTag(id: '\u5f3a\u5978\u4e71\u4f26', label: '\u5f3a\u5978\u4e71\u4f26', icon: Icons.warning_outlined, iconSelected: Icons.warning),
    SiteTag(id: '\u53cd\u5dee\u5973\u53cb', label: '\u53cd\u5dee\u5973\u53cb', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: '\u6559\u5e08\u5b66\u751f', label: '\u6559\u5e08\u5b66\u751f', icon: Icons.school_outlined, iconSelected: Icons.school),
    SiteTag(id: '\u4e9a\u6d32', label: '\u4e9a\u6d32', icon: Icons.public_outlined, iconSelected: Icons.public),
    SiteTag(id: '\u65e5\u672c', label: '\u65e5\u672c', icon: Icons.flag_outlined, iconSelected: Icons.flag),
    SiteTag(id: '\u7d20\u4eba', label: '\u7d20\u4eba', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
  ];

    /// XNXX 目录标签（2026-10-28 实证：/tags/{slug} 全部 200，removed `beautiful`=500）。
  static const xnxxDirectoryTags = <SiteTag>[
    SiteTag(id: 'hot', label: '\u70ed\u95e8', icon: Icons.local_fire_department_outlined, iconSelected: Icons.local_fire_department),
    SiteTag(id: 'new', label: '\u6700\u65b0', icon: Icons.fiber_new_outlined, iconSelected: Icons.fiber_new),
    SiteTag(id: 'best', label: '\u7cbe\u9009', icon: Icons.emoji_events_outlined, iconSelected: Icons.emoji_events),
    SiteTag(id: 'asian', label: '\u4e9a\u6d32', icon: Icons.public_outlined, iconSelected: Icons.public),
    SiteTag(id: 'japanese', label: '\u65e5\u672c', icon: Icons.flag_outlined, iconSelected: Icons.flag),
    SiteTag(id: 'korean', label: '\u97e9\u56fd', icon: Icons.flag_circle_outlined, iconSelected: Icons.flag_circle),
    SiteTag(id: 'amateur', label: '\u7d20\u4eba', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'milf', label: '\u719f\u5973', icon: Icons.person_outline, iconSelected: Icons.person),
    SiteTag(id: 'mature', label: '\u6210\u719f', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'anal', label: '\u540e\u5ead', icon: Icons.airline_seat_recline_normal_outlined, iconSelected: Icons.airline_seat_recline_normal),
    SiteTag(id: 'blowjob', label: '\u53e3\u6d3b', icon: Icons.mic_external_on_outlined, iconSelected: Icons.mic_external_on),
    SiteTag(id: 'creampie', label: '\u4e2d\u51fa', icon: Icons.water_drop_outlined, iconSelected: Icons.water_drop),
    SiteTag(id: 'cumshot', label: '\u5c04\u7cbe', icon: Icons.blur_on_outlined, iconSelected: Icons.blur_on),
    SiteTag(id: 'ebony', label: '\u9ed1\u73e0', icon: Icons.nightlife_outlined, iconSelected: Icons.nightlife),
    SiteTag(id: 'latina', label: '\u62c9\u7f8e', icon: Icons.language_outlined, iconSelected: Icons.language),
    SiteTag(id: 'lesbian', label: '\u767e\u5408', icon: Icons.favorite_outline, iconSelected: Icons.favorite),
    SiteTag(id: 'hentai', label: '\u91cc\u756a', icon: Icons.animation_outlined, iconSelected: Icons.animation),
    SiteTag(id: 'cartoon', label: '\u52a8\u6f2b', icon: Icons.palette_outlined, iconSelected: Icons.palette),
    SiteTag(id: 'pov', label: '\u7b2c\u4e00\u89c6\u89d2', icon: Icons.videocam_outlined, iconSelected: Icons.videocam),
    SiteTag(id: 'threesome', label: '3P', icon: Icons.groups_outlined, iconSelected: Icons.groups),
    SiteTag(id: 'orgy', label: '\u7fa4\u4ea4', icon: Icons.groups_2_outlined, iconSelected: Icons.groups_2),
    SiteTag(id: 'gangbang', label: '\u8f6e\u64cd', icon: Icons.groups_3_outlined, iconSelected: Icons.groups_3),
    SiteTag(id: 'squirt', label: '\u6f6e\u55b7', icon: Icons.water_outlined, iconSelected: Icons.water),
    SiteTag(id: 'facial', label: '\u989c\u5c04', icon: Icons.blur_on_outlined, iconSelected: Icons.blur_on),
    SiteTag(id: 'feet', label: '\u8db3\u63a7', icon: Icons.ice_skating_outlined, iconSelected: Icons.ice_skating),
    SiteTag(id: 'fetish', label: '\u604b\u7269', icon: Icons.psychology_outlined, iconSelected: Icons.psychology),
    SiteTag(id: 'bondage', label: '\u6346\u7ed1', icon: Icons.link_outlined, iconSelected: Icons.link),
    SiteTag(id: 'big-ass', label: '\u5de8\u81c0', icon: Icons.airline_seat_legroom_reduced_outlined, iconSelected: Icons.airline_seat_legroom_reduced),
    SiteTag(id: 'big-tits', label: '\u5de8\u4e73', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'small-tits', label: '\u5c0f\u80f8', icon: Icons.child_care_outlined, iconSelected: Icons.child_care),
    SiteTag(id: 'blonde', label: '\u91d1\u53d1', icon: Icons.face_retouching_natural_outlined, iconSelected: Icons.face_retouching_natural),
    SiteTag(id: 'brunette', label: '\u68d5\u53d1', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'redhead', label: '\u7ea2\u53d1', icon: Icons.face_3_outlined, iconSelected: Icons.face_3),
    SiteTag(id: 'russian', label: '\u4fc4\u7f57\u65af', icon: Icons.flag_outlined, iconSelected: Icons.flag),
    SiteTag(id: 'indian', label: '\u5370\u5ea6', icon: Icons.history_edu_outlined, iconSelected: Icons.history_edu),
    SiteTag(id: 'chinese', label: '\u4e2d\u6587', icon: Icons.translate_outlined, iconSelected: Icons.translate),
    SiteTag(id: 'pornstar', label: '\u8272\u60c5\u660e\u661f', icon: Icons.star_outline, iconSelected: Icons.star),
    SiteTag(id: 'casting', label: '\u8bd5\u955c', icon: Icons.theater_comedy_outlined, iconSelected: Icons.theater_comedy),
    SiteTag(id: 'college', label: '\u6821\u82b1', icon: Icons.school_outlined, iconSelected: Icons.school),
    SiteTag(id: 'masturbation', label: '\u81ea\u6170', icon: Icons.self_improvement_outlined, iconSelected: Icons.self_improvement),
    SiteTag(id: 'toys', label: '\u73a9\u5177', icon: Icons.toys_outlined, iconSelected: Icons.toys),
    SiteTag(id: 'compilation', label: '\u5408\u96c6', icon: Icons.blur_on_outlined, iconSelected: Icons.blur_on),
    SiteTag(id: 'reality', label: '\u771f\u4eba\u5b9e\u62cd', icon: Icons.visibility_outlined, iconSelected: Icons.visibility),
    SiteTag(id: 'vintage', label: '\u590d\u53e4', icon: Icons.hourglass_bottom_outlined, iconSelected: Icons.hourglass_bottom),
    SiteTag(id: 'hd', label: '\u9ad8\u6e05', icon: Icons.hd_outlined, iconSelected: Icons.hd),
    SiteTag(id: 'public', label: '\u6237\u5916\u516c\u5f00', icon: Icons.landscape_outlined, iconSelected: Icons.landscape),
    SiteTag(id: 'deepthroat', label: '\u6df1\u54bd', icon: Icons.vpn_key_outlined, iconSelected: Icons.vpn_key),
    SiteTag(id: 'orgasm', label: '\u9ad8\u6f6e', icon: Icons.waves_outlined, iconSelected: Icons.waves),
    SiteTag(id: 'homemade', label: '\u81ea\u5236', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'cuckold', label: '\u9ec4\u8fa3', icon: Icons.nightlife_outlined, iconSelected: Icons.nightlife),
    SiteTag(id: 'femdom', label: '\u5973\u738b', icon: Icons.gavel_outlined, iconSelected: Icons.gavel),
    SiteTag(id: 'bdsm', label: 'BDSM', icon: Icons.health_and_safety_outlined, iconSelected: Icons.health_and_safety),
    SiteTag(id: 'maid', label: '\u5973\u4ec6', icon: Icons.cleaning_services_outlined, iconSelected: Icons.cleaning_services),
    SiteTag(id: 'teacher', label: '\u8001\u5e08', icon: Icons.school_outlined, iconSelected: Icons.school),
    SiteTag(id: 'interracial', label: '\u8de8\u79cd\u65cf', icon: Icons.interpreter_mode_outlined, iconSelected: Icons.interpreter_mode),
    SiteTag(id: 'english', label: '\u82f1\u6587', icon: Icons.translate_outlined, iconSelected: Icons.translate),
  ];

    /// XHAMSTER 目录标签（2026-10-28 实证：/categories/{slug} 全部存在）。
  static const xhamsterDirectoryTags = <SiteTag>[
    SiteTag(id: 'hot', label: '\u70ed\u95e8', icon: Icons.local_fire_department_outlined, iconSelected: Icons.local_fire_department),
    SiteTag(id: 'new', label: '\u6700\u65b0', icon: Icons.fiber_new_outlined, iconSelected: Icons.fiber_new),
    SiteTag(id: 'best', label: '\u7cbe\u9009', icon: Icons.emoji_events_outlined, iconSelected: Icons.emoji_events),
    SiteTag(id: 'asian', label: '\u4e9a\u6d32', icon: Icons.public_outlined, iconSelected: Icons.public),
    SiteTag(id: 'milf', label: '\u719f\u5973', icon: Icons.person_outline, iconSelected: Icons.person),
    SiteTag(id: 'mature', label: '\u6210\u719f', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'anal', label: '\u540e\u5ead', icon: Icons.airline_seat_recline_normal_outlined, iconSelected: Icons.airline_seat_recline_normal),
    SiteTag(id: 'blowjob', label: '\u53e3\u6d3b', icon: Icons.mic_external_on_outlined, iconSelected: Icons.mic_external_on),
    SiteTag(id: 'creampie', label: '\u4e2d\u51fa', icon: Icons.water_drop_outlined, iconSelected: Icons.water_drop),
    SiteTag(id: 'cumshot', label: '\u5c04\u7cbe', icon: Icons.blur_on_outlined, iconSelected: Icons.blur_on),
    SiteTag(id: 'bukkake', label: '\u989c\u5e78', icon: Icons.blur_on_outlined, iconSelected: Icons.blur_on),
    SiteTag(id: 'amateur', label: '\u7d20\u4eba', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'homemade', label: '\u81ea\u5236', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'bbw', label: '\u80a5\u5a46', icon: Icons.sensor_occupied_outlined, iconSelected: Icons.sensor_occupied),
    SiteTag(id: 'big-ass', label: '\u5de8\u81c0', icon: Icons.airline_seat_legroom_reduced_outlined, iconSelected: Icons.airline_seat_legroom_reduced),
    SiteTag(id: 'big-tits', label: '\u5de8\u4e73', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'small-tits', label: '\u5c0f\u80f8', icon: Icons.child_care_outlined, iconSelected: Icons.child_care),
    SiteTag(id: 'blonde', label: '\u91d1\u53d1', icon: Icons.face_retouching_natural_outlined, iconSelected: Icons.face_retouching_natural),
    SiteTag(id: 'brunette', label: '\u68d5\u53d1', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'redhead', label: '\u7ea2\u53d1', icon: Icons.face_3_outlined, iconSelected: Icons.face_3),
    SiteTag(id: 'latina', label: '\u62c9\u7f8e', icon: Icons.language_outlined, iconSelected: Icons.language),
    SiteTag(id: 'lesbian', label: '\u767e\u5408', icon: Icons.favorite_outline, iconSelected: Icons.favorite),
    SiteTag(id: 'jav', label: 'JAV', icon: Icons.movie_outlined, iconSelected: Icons.movie),
    SiteTag(id: 'chinese', label: '\u4e2d\u6587', icon: Icons.translate_outlined, iconSelected: Icons.translate),
    SiteTag(id: 'indian', label: '\u5370\u5ea6', icon: Icons.history_edu_outlined, iconSelected: Icons.history_edu),
    SiteTag(id: 'arab', label: '\u963f\u62c9\u4f2f', icon: Icons.history_edu_outlined, iconSelected: Icons.history_edu),
    SiteTag(id: 'compilation', label: '\u5408\u96c6', icon: Icons.blur_on_outlined, iconSelected: Icons.blur_on),
    SiteTag(id: 'cosplay', label: '\u89d2\u8272\u626e\u6f14', icon: Icons.theater_comedy_outlined, iconSelected: Icons.theater_comedy),
    SiteTag(id: 'hentai', label: '\u91cc\u756a', icon: Icons.animation_outlined, iconSelected: Icons.animation),
    SiteTag(id: 'cartoon', label: '\u52a8\u6f2b', icon: Icons.palette_outlined, iconSelected: Icons.palette),
    SiteTag(id: 'deep-throat', label: '\u6df1\u54bd', icon: Icons.vpn_key_outlined, iconSelected: Icons.vpn_key),
    SiteTag(id: 'doggy-style', label: '\u540e\u5165', icon: Icons.directions_run_outlined, iconSelected: Icons.directions_run),
    SiteTag(id: 'double-penetration', label: '\u53cc\u63d2', icon: Icons.call_merge_outlined, iconSelected: Icons.call_merge),
    SiteTag(id: 'handjob', label: '\u624b\u6d3b', icon: Icons.back_hand_outlined, iconSelected: Icons.back_hand),
    SiteTag(id: 'fisting', label: '\u62f3\u4ea4', icon: Icons.front_hand_outlined, iconSelected: Icons.front_hand),
    SiteTag(id: 'footjob', label: '\u8db3\u4ea4', icon: Icons.ice_skating_outlined, iconSelected: Icons.ice_skating),
    SiteTag(id: 'massage', label: '\u6309\u6469', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'missionary', label: '\u4f20\u6559\u58eb', icon: Icons.self_improvement_outlined, iconSelected: Icons.self_improvement),
    SiteTag(id: 'orgasm', label: '\u9ad8\u6f6e', icon: Icons.waves_outlined, iconSelected: Icons.waves),
    SiteTag(id: 'rimjob', label: '\u8214\u809b', icon: Icons.local_dining_outlined, iconSelected: Icons.local_dining),
    SiteTag(id: 'ass-licking', label: '\u8214\u809b', icon: Icons.local_dining_outlined, iconSelected: Icons.local_dining),
    SiteTag(id: 'rough-sex', label: '\u7c97\u66b4', icon: Icons.flash_on_outlined, iconSelected: Icons.flash_on),
    SiteTag(id: 'squirting', label: '\u6f6e\u55b7', icon: Icons.water_outlined, iconSelected: Icons.water),
    SiteTag(id: 'pissing', label: '\u55b7\u6c34', icon: Icons.water_outlined, iconSelected: Icons.water),
    SiteTag(id: 'striptease', label: '\u8131\u8863', icon: Icons.nightlife_outlined, iconSelected: Icons.nightlife),
    SiteTag(id: 'vintage', label: '\u590d\u53e4', icon: Icons.hourglass_bottom_outlined, iconSelected: Icons.hourglass_bottom),
    SiteTag(id: 'webcam', label: '\u76f4\u64ad', icon: Icons.videocam_outlined, iconSelected: Icons.videocam),
    SiteTag(id: 'interracial', label: '\u8de8\u79cd\u65cf', icon: Icons.interpreter_mode_outlined, iconSelected: Icons.interpreter_mode),
    SiteTag(id: 'mom', label: '\u5988\u5988', icon: Icons.person_outline, iconSelected: Icons.person),
    SiteTag(id: 'granny', label: '\u8001\u5973', icon: Icons.elderly_outlined, iconSelected: Icons.elderly),
    SiteTag(id: 'old-young', label: '\u8001\u5c11\u914d', icon: Icons.hourglass_bottom_outlined, iconSelected: Icons.hourglass_bottom),
    SiteTag(id: 'ahegao', label: '\u5165\u72c2\u989c', icon: Icons.sick_outlined, iconSelected: Icons.sick),
    SiteTag(id: 'riding', label: '\u9a91\u4e58', icon: Icons.airline_seat_flat_outlined, iconSelected: Icons.airline_seat_flat),
    SiteTag(id: 'facesitting', label: '\u9a91\u8138', icon: Icons.face_retouching_natural_outlined, iconSelected: Icons.face_retouching_natural),
    SiteTag(id: 'close-up', label: '\u7279\u5199', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'fetish', label: '\u604b\u7269', icon: Icons.psychology_outlined, iconSelected: Icons.psychology),
    SiteTag(id: 'bondage', label: '\u6346\u7ed1', icon: Icons.link_outlined, iconSelected: Icons.link),
    SiteTag(id: 'threesome', label: '3P', icon: Icons.groups_outlined, iconSelected: Icons.groups),
    SiteTag(id: 'femdom', label: '\u5973\u738b', icon: Icons.gavel_outlined, iconSelected: Icons.gavel),
    SiteTag(id: 'orgy', label: '\u7fa4\u4ea4', icon: Icons.groups_2_outlined, iconSelected: Icons.groups_2),
    SiteTag(id: 'gangbang', label: '\u8f6e\u64cd', icon: Icons.groups_3_outlined, iconSelected: Icons.groups_3),
    SiteTag(id: 'pov', label: '\u7b2c\u4e00\u89c6\u89d2', icon: Icons.videocam_outlined, iconSelected: Icons.videocam),
    SiteTag(id: '18-year-old', label: '\u5341\u516b\u5c81', icon: Icons.fiber_new_outlined, iconSelected: Icons.fiber_new),
    SiteTag(id: 'prostate-massage', label: '\u6309\u6469\u540e\u5ead', icon: Icons.airline_seat_recline_extra_outlined, iconSelected: Icons.airline_seat_recline_extra),
    SiteTag(id: 'pegging', label: '\u540e\u5ead\u53cd\u64cd', icon: Icons.swap_horiz_outlined, iconSelected: Icons.swap_horiz),
    SiteTag(id: 'dirty-talk', label: '\u9ac4\u8bdd', icon: Icons.record_voice_over_outlined, iconSelected: Icons.record_voice_over),
    SiteTag(id: 'edging', label: '\u60ef\u91c7', icon: Icons.timer_outlined, iconSelected: Icons.timer),
    SiteTag(id: 'joi', label: '\u81ea\u6170\u6307\u5bfc', icon: Icons.record_voice_over_outlined, iconSelected: Icons.record_voice_over),
    SiteTag(id: 'kissing', label: '\u4eb2\u543b', icon: Icons.favorite_outline, iconSelected: Icons.favorite),
  ];

  /// TNAFlix 目录标签：来自 TNAFlix 搜索/分类（/search.php?what= 与 /categories/）。
  static const tnaflixDirectoryTags = <SiteTag>[
    SiteTag(id: 'new', label: '\u6700\u65b0', icon: Icons.fiber_new_outlined, iconSelected: Icons.fiber_new),
    SiteTag(id: 'best', label: '\u7cbe\u9009', icon: Icons.emoji_events_outlined, iconSelected: Icons.emoji_events),
    SiteTag(id: 'hot', label: '\u63a8\u8350', icon: Icons.recommend_outlined, iconSelected: Icons.recommend),
    SiteTag(id: 'asian', label: '\u4e9a\u6d32', icon: Icons.public_outlined, iconSelected: Icons.public),
    SiteTag(id: 'japanese', label: '\u65e5\u672c', icon: Icons.flag_outlined, iconSelected: Icons.flag),
    SiteTag(id: 'amateur', label: '\u7d20\u4eba', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'milf', label: '\u719f\u5973', icon: Icons.person_outline, iconSelected: Icons.person),
    SiteTag(id: 'mature', label: '\u6210\u719f', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'anal', label: '\u540e\u5ead', icon: Icons.airline_seat_recline_normal_outlined, iconSelected: Icons.airline_seat_recline_normal),
    SiteTag(id: 'blowjob', label: '\u53e3\u4ea4', icon: Icons.mic_external_on_outlined, iconSelected: Icons.mic_external_on),
    SiteTag(id: 'creampie', label: '\u5185\u5c04', icon: Icons.water_drop_outlined, iconSelected: Icons.water_drop),
    SiteTag(id: 'cumshot', label: '\u989c\u5c04', icon: Icons.blur_on_outlined, iconSelected: Icons.blur_on),
    SiteTag(id: 'lesbian', label: '\u540c\u6027', icon: Icons.favorite_outline, iconSelected: Icons.favorite),
    SiteTag(id: 'ebony', label: '\u9ed1\u73e0', icon: Icons.nightlife_outlined, iconSelected: Icons.nightlife),
    SiteTag(id: 'latina', label: '\u62c9\u7f8e', icon: Icons.language_outlined, iconSelected: Icons.language),
    SiteTag(id: 'hentai', label: '\u52a8\u6f2b', icon: Icons.animation_outlined, iconSelected: Icons.animation),
    SiteTag(id: 'cartoon', label: '\u5361\u901a', icon: Icons.brush_outlined, iconSelected: Icons.brush),
    SiteTag(id: 'pov', label: '\u4e3b\u89c2', icon: Icons.videocam_outlined, iconSelected: Icons.videocam),
    SiteTag(id: 'threesome', label: '3P', icon: Icons.groups_outlined, iconSelected: Icons.groups),
    SiteTag(id: 'orgy', label: '\u7fa4\u4ea4', icon: Icons.groups_2_outlined, iconSelected: Icons.groups_2),
    SiteTag(id: 'gangbang', label: '\u8f6e\u59a8', icon: Icons.groups_3_outlined, iconSelected: Icons.groups_3),
    SiteTag(id: 'squirt', label: '\u6f6e\u5439', icon: Icons.water_outlined, iconSelected: Icons.water),
    SiteTag(id: 'fetish', label: '\u60c5\u8da3', icon: Icons.psychology_outlined, iconSelected: Icons.psychology),
    SiteTag(id: 'bondage', label: '\u7f1a\u7ed1', icon: Icons.link_outlined, iconSelected: Icons.link),
    SiteTag(id: 'big-ass', label: '\u5de8\u81c0', icon: Icons.airline_seat_legroom_reduced_outlined, iconSelected: Icons.airline_seat_legroom_reduced),
    SiteTag(id: 'big-tits', label: '\u5de8\u4e73', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'small-tits', label: '\u5e73\u80f8', icon: Icons.child_care_outlined, iconSelected: Icons.child_care),
    SiteTag(id: 'blonde', label: '\u91d1\u53d1', icon: Icons.face_retouching_natural_outlined, iconSelected: Icons.face_retouching_natural),
    SiteTag(id: 'brunette', label: '\u68d5\u53d1', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'redhead', label: '\u7ea2\u53d1', icon: Icons.face_3_outlined, iconSelected: Icons.face_3),
    SiteTag(id: 'russian', label: '\u4fc4\u7f57\u65af', icon: Icons.ac_unit_outlined, iconSelected: Icons.ac_unit),
    SiteTag(id: 'indian', label: '\u5370\u5ea6', icon: Icons.history_edu_outlined, iconSelected: Icons.history_edu),
    SiteTag(id: 'fisting', label: '\u62f3\u4ea4', icon: Icons.front_hand_outlined, iconSelected: Icons.front_hand),
    SiteTag(id: 'handjob', label: '\u6253\u98de\u673a', icon: Icons.back_hand_outlined, iconSelected: Icons.back_hand),
    SiteTag(id: 'masturbation', label: '\u81ea\u6170', icon: Icons.self_improvement_outlined, iconSelected: Icons.self_improvement),
    SiteTag(id: 'toys', label: '\u73a9\u5177', icon: Icons.toys_outlined, iconSelected: Icons.toys),
    SiteTag(id: 'vintage', label: '\u53e4\u5178', icon: Icons.hourglass_bottom_outlined, iconSelected: Icons.hourglass_bottom),
    SiteTag(id: 'hd', label: '\u9ad8\u6e05', icon: Icons.hd_outlined, iconSelected: Icons.hd),
  ];

  /// Jable 目录标签：来自 Jable.TV 官方分类与主题页（/categories 与 /tags）。
  static const jableDirectoryTags = <SiteTag>[
    SiteTag(id: 'new', label: '\u6700\u65b0', icon: Icons.fiber_new_outlined, iconSelected: Icons.fiber_new),
    SiteTag(id: 'hot', label: '\u70ed\u5ea6', icon: Icons.local_fire_department_outlined, iconSelected: Icons.local_fire_department),
    SiteTag(id: 'best', label: '\u7cbe\u9009', icon: Icons.emoji_events_outlined, iconSelected: Icons.emoji_events),
    SiteTag(id: 'chinese-subtitle', label: '\u4e2d\u6587\u5b57\u5e55', icon: Icons.subtitles_outlined, iconSelected: Icons.subtitles),
    SiteTag(id: 'uncensored', label: '\u65e0\u7801', icon: Icons.no_photography_outlined, iconSelected: Icons.no_photography),
    SiteTag(id: 'sex-only', label: '\u76f4\u63a5\u5f00\u62cd', icon: Icons.flash_on_outlined, iconSelected: Icons.flash_on),
    SiteTag(id: 'roleplay', label: '\u89d2\u8272\u5267\u60c5', icon: Icons.theater_comedy_outlined, iconSelected: Icons.theater_comedy),
    SiteTag(id: 'uniform', label: '\u5236\u670d\u8bf1\u60d1', icon: Icons.checkroom_outlined, iconSelected: Icons.checkroom),
    SiteTag(id: 'bdsm', label: '\u4e3b\u5974\u8c03\u6559', icon: Icons.health_and_safety_outlined, iconSelected: Icons.health_and_safety),
    SiteTag(id: 'insult', label: '\u51cc\u8fb1\u5feb\u611f', icon: Icons.warning_outlined, iconSelected: Icons.warning),
    SiteTag(id: 'pov', label: '\u7537\u53cb\u89c6\u89d2', icon: Icons.videocam_outlined, iconSelected: Icons.videocam),
    SiteTag(id: 'groupsex', label: '\u591aP\u7fa4\u4ea4', icon: Icons.groups_2_outlined, iconSelected: Icons.groups_2),
    SiteTag(id: 'pantyhose', label: '\u4e1d\u889c\u7f8e\u817f', icon: Icons.ice_skating_outlined, iconSelected: Icons.ice_skating),
    SiteTag(id: 'lesbian', label: '\u5973\u540c\u6b22\u6109', icon: Icons.favorite_outline, iconSelected: Icons.favorite),
    SiteTag(id: 'private-cam', label: '\u76d7\u6444\u5077\u62cd', icon: Icons.visibility_outlined, iconSelected: Icons.visibility),
    SiteTag(id: 'wife', label: '\u4eba\u59bb', icon: Icons.pregnant_woman_outlined, iconSelected: Icons.pregnant_woman),
    SiteTag(id: 'mature-woman', label: '\u719f\u5973', icon: Icons.person_outline, iconSelected: Icons.person),
    SiteTag(id: 'girl', label: '\u5c11\u5973', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'big-tits', label: '\u5de8\u4e73', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'small-tits', label: '\u8d2b\u4e73', icon: Icons.child_care_outlined, iconSelected: Icons.child_care),
    SiteTag(id: 'beautiful-butt', label: '\u7f8e\u5c3b', icon: Icons.airline_seat_legroom_reduced_outlined, iconSelected: Icons.airline_seat_legroom_reduced),
    SiteTag(id: 'beautiful-leg', label: '\u7f8e\u817f', icon: Icons.accessibility_new_outlined, iconSelected: Icons.accessibility_new),
    SiteTag(id: 'creampie', label: '\u4e2d\u51fa', icon: Icons.water_drop_outlined, iconSelected: Icons.water_drop),
    SiteTag(id: 'anal-sex', label: '\u809b\u4ea4', icon: Icons.airline_seat_recline_normal_outlined, iconSelected: Icons.airline_seat_recline_normal),
    SiteTag(id: 'blowjob', label: '\u53e3\u4ea4', icon: Icons.mic_external_on_outlined, iconSelected: Icons.mic_external_on),
    SiteTag(id: 'deep-throat', label: '\u6df1\u54bd', icon: Icons.vpn_key_outlined, iconSelected: Icons.vpn_key),
    SiteTag(id: 'cum-in-mouth', label: '\u53e3\u7206', icon: Icons.blur_on_outlined, iconSelected: Icons.blur_on),
    SiteTag(id: 'facial', label: '\u989c\u5c04', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'footjob', label: '\u811a\u4ea4', icon: Icons.ice_skating_outlined, iconSelected: Icons.ice_skating),
    SiteTag(id: 'squirting', label: '\u6f6e\u5439', icon: Icons.water_outlined, iconSelected: Icons.water),
    SiteTag(id: 'school-uniform', label: '\u6821\u670d', icon: Icons.school_outlined, iconSelected: Icons.school),
    SiteTag(id: 'maid', label: '\u5973\u4ec6', icon: Icons.cleaning_services_outlined, iconSelected: Icons.cleaning_services),
    SiteTag(id: 'kimono', label: '\u548c\u670d', icon: Icons.dry_cleaning_outlined, iconSelected: Icons.dry_cleaning),
    SiteTag(id: 'stockings', label: '\u540a\u5e26\u889c', icon: Icons.ice_skating_outlined, iconSelected: Icons.ice_skating),
    SiteTag(id: 'glasses', label: '\u773c\u955c\u5a18', icon: Icons.visibility_outlined, iconSelected: Icons.visibility),
    SiteTag(id: 'cosplay', label: 'Cosplay', icon: Icons.theater_comedy_outlined, iconSelected: Icons.theater_comedy),
    SiteTag(id: 'bondage', label: '\u7f1a\u7ed1', icon: Icons.link_outlined, iconSelected: Icons.link),
    SiteTag(id: 'tune', label: '\u8c03\u6559', icon: Icons.tune_outlined, iconSelected: Icons.tune),
    SiteTag(id: 'chizyo', label: '\u75f4\u5973', icon: Icons.face_3_outlined, iconSelected: Icons.face_3),
    SiteTag(id: 'chikan', label: '\u75f4\u6c49', icon: Icons.train_outlined, iconSelected: Icons.train),
    SiteTag(id: 'outdoor', label: '\u9732\u51fa', icon: Icons.landscape_outlined, iconSelected: Icons.landscape),
    SiteTag(id: 'soapland', label: '\u6ce1\u59ec', icon: Icons.bubble_chart_outlined, iconSelected: Icons.bubble_chart),
    SiteTag(id: 'massage', label: '\u6309\u6469', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'temptation', label: '\u8bf1\u60d1', icon: Icons.auto_awesome_outlined, iconSelected: Icons.auto_awesome),
    SiteTag(id: 'ntr', label: 'NTR', icon: Icons.person_off_outlined, iconSelected: Icons.person_off),
    SiteTag(id: 'hypnosis', label: '\u50ac\u7720', icon: Icons.psychology_outlined, iconSelected: Icons.psychology),
    SiteTag(id: 'affair', label: '\u51fa\u8f68', icon: Icons.heart_broken_outlined, iconSelected: Icons.heart_broken),
    SiteTag(id: 'time-stop', label: '\u65f6\u95f4\u505c\u6b62', icon: Icons.timer_off_outlined, iconSelected: Icons.timer_off),
    SiteTag(id: 'doctor', label: '\u533b\u751f', icon: Icons.medical_services_outlined, iconSelected: Icons.medical_services),
    SiteTag(id: 'nurse', label: '\u62a4\u58eb', icon: Icons.medical_services_outlined, iconSelected: Icons.medical_services),
    SiteTag(id: 'teacher', label: '\u8001\u5e08', icon: Icons.school_outlined, iconSelected: Icons.school),
    SiteTag(id: 'ol', label: 'OL', icon: Icons.business_center_outlined, iconSelected: Icons.business_center),
    SiteTag(id: 'idol', label: '\u5076\u50cf', icon: Icons.star_outline, iconSelected: Icons.star),
    SiteTag(id: 'hot-spring', label: '\u6e29\u6cc9', icon: Icons.hot_tub_outlined, iconSelected: Icons.hot_tub),
    SiteTag(id: 'swimming-pool', label: '\u6cf3\u6c60', icon: Icons.pool_outlined, iconSelected: Icons.pool),
    SiteTag(id: 'car', label: '\u6c7d\u8f66', icon: Icons.directions_car_outlined, iconSelected: Icons.directions_car),
    SiteTag(id: 'tram', label: '\u7535\u8f66', icon: Icons.train_outlined, iconSelected: Icons.train),
    SiteTag(id: 'school', label: '\u5b66\u6821', icon: Icons.school_outlined, iconSelected: Icons.school),
    SiteTag(id: 'gym-room', label: '\u5065\u8eab\u623f', icon: Icons.fitness_center_outlined, iconSelected: Icons.fitness_center),
    SiteTag(id: 'hotel', label: '\u9152\u5e97', icon: Icons.hotel_outlined, iconSelected: Icons.hotel),
    SiteTag(id: 'hairy', label: '\u591a\u6bdb', icon: Icons.brush_outlined, iconSelected: Icons.brush),
    SiteTag(id: 'suntan', label: '\u9ed1\u8089', icon: Icons.wb_sunny_outlined, iconSelected: Icons.wb_sunny),
    SiteTag(id: 'tattoo', label: '\u7eb9\u8eab', icon: Icons.brush_outlined, iconSelected: Icons.brush),
    SiteTag(id: 'breast-milk', label: '\u6bcd\u4e73', icon: Icons.water_drop_outlined, iconSelected: Icons.water_drop),
    SiteTag(id: 'piss', label: '\u653e\u5c3f', icon: Icons.water_outlined, iconSelected: Icons.water),
    SiteTag(id: 'video-recording', label: '\u5f55\u50cf', icon: Icons.videocam_outlined, iconSelected: Icons.videocam),
    SiteTag(id: 'more-than-4-hours', label: '4\u5c0f\u65f6\u4ee5\u4e0a', icon: Icons.schedule_outlined, iconSelected: Icons.schedule),
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

  // 浪妹系两站（同一套 Vue 模板 + 同一内容库，仅域名/AES 密钥不同）：
  // 标签栏由 LangmeiApi.fetchTypes 按站点 a=types 动态解析（非硬编码），
  // 打开走 LangmeiPage 专用页（home_page._openSite 分发）；tags 留空使
  // home_page 预热按"无标签"自动跳过，不浪费网络。
  static const langmei = SiteDef(
    id: 'langmei',
    name: '\u6d6a\u59b9\u89c6\u9891',
    kind: SiteKind.video,
    color: 0xFFF97316,
    letter: 'L',
    mirrors: [
      'https://10326.rczga.cn',
    ],
    tags: [],
  );

  static const yaofafa = SiteDef(
    id: 'yaofafa',
    name: '\u8981\u53d1\u53d1\u89c6\u9891',
    kind: SiteKind.video,
    color: 0xFF2563EB,
    letter: 'Y',
    mirrors: [
      'https://10326.lfbrs.cn',
    ],
    tags: [],
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

  /// iXXX（FuQ/Tiava 同网络聚合站）目录标签：取自官网首页"最热门的类别"
  /// 卡片（/zh/c/{slug}），2026-10 重新捕获。聚合站视频卡以 /out/?l= 外链
  /// 到合作播放站，目录本身仍是稳定的分类卡。
  static const ixxxDirectoryTags = <SiteTag>[
    SiteTag(id: 'chinese', label: '\u4e2d\u56fd\u7684', icon: Icons.translate_outlined, iconSelected: Icons.translate),
    SiteTag(id: 'japanese', label: '\u65e5\u672c\u7684', icon: Icons.flag_outlined, iconSelected: Icons.flag),
    SiteTag(id: 'ai-generated', label: '\u4eba\u5de5\u667a\u80fd\u751f\u6210', icon: Icons.brush_outlined, iconSelected: Icons.brush),
    SiteTag(id: 'japanese-pornstar', label: '\u65e5\u672c\u8272\u60c5\u660e\u661f', icon: Icons.star_outline, iconSelected: Icons.star),
    SiteTag(id: 'uncensored', label: '\u672a\u7ecf\u5ba1\u67e5', icon: Icons.visibility_off_outlined, iconSelected: Icons.visibility_off),
    SiteTag(id: 'asian', label: '\u4e9a\u6d32\u7684', icon: Icons.public_outlined, iconSelected: Icons.public),
    SiteTag(id: 'chinese-homemade', label: '\u4e2d\u56fd\u81ea\u5236', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'taiwanese', label: '\u53f0\u6e7e\u7684', icon: Icons.flag_circle_outlined, iconSelected: Icons.flag_circle),
    SiteTag(id: 'korean', label: '\u97e9\u56fd\u7684', icon: Icons.language_outlined, iconSelected: Icons.language),
    SiteTag(id: 'vietnamese', label: '\u8d8a\u5357\u7684', icon: Icons.language_outlined, iconSelected: Icons.language),
    SiteTag(id: 'oriental', label: '\u4e1c\u65b9\u7684', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'indian', label: '\u5370\u5ea6\u7684', icon: Icons.history_edu_outlined, iconSelected: Icons.history_edu),
    SiteTag(id: 'indonesian', label: '\u5370\u5c3c\u7684', icon: Icons.language_outlined, iconSelected: Icons.language),
    SiteTag(id: 'japanese-hd', label: '\u65e5\u672c\u4eba\u9ad8\u6e05', icon: Icons.hd_outlined, iconSelected: Icons.hd),
    SiteTag(id: 'japanese-hot-mom', label: '\u65e5\u672c\u8fa3\u5988', icon: Icons.person_outline, iconSelected: Icons.person),
    SiteTag(id: 'japanese-mature', label: '\u65e5\u672c\u6210\u719f', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'japanese-amateur', label: '\u65e5\u672c\u7d20\u4eba', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'japanese-student', label: '\u65e5\u672c\u5b66\u751f', icon: Icons.school_outlined, iconSelected: Icons.school),
    SiteTag(id: 'japanese-big-tits', label: '\u65e5\u672c\u4eba\u5de8\u4e73', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'japanese-group-sex', label: '\u65e5\u672c\u7fa4\u4ea4', icon: Icons.groups_3_outlined, iconSelected: Icons.groups_3),
    SiteTag(id: 'japanese-massage', label: '\u65e5\u672c\u6309\u6469', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'chinese-teen', label: '\u4e2d\u56fd\u9752\u5c11\u5e74', icon: Icons.child_care_outlined, iconSelected: Icons.child_care),
    SiteTag(id: 'hot-mom', label: '\u8fa3\u5988', icon: Icons.person_outline, iconSelected: Icons.person),
    SiteTag(id: 'massage', label: '\u6309\u6469', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'public', label: '\u516c\u5171\u573a\u5408', icon: Icons.videocam_outlined, iconSelected: Icons.videocam),
    SiteTag(id: 'mom', label: '\u5988\u5988', icon: Icons.person_outline, iconSelected: Icons.person),
    SiteTag(id: 'hentai', label: '\u53d8\u6001\u52a8\u6f2b', icon: Icons.animation_outlined, iconSelected: Icons.animation),
    SiteTag(id: 'japanese-mom', label: '\u65e5\u672c\u5988\u5988', icon: Icons.person_outline, iconSelected: Icons.person),
    SiteTag(id: 'cum-inside', label: '\u7cbe\u6db2\u5728\u91cc\u9762', icon: Icons.water_drop_outlined, iconSelected: Icons.water_drop),
    SiteTag(id: 'japanese-threesome', label: '\u65e5\u672c\u4e09\u4eba\u884c', icon: Icons.groups_outlined, iconSelected: Icons.groups),
    SiteTag(id: 'chinese-amateur', label: '\u4e2d\u56fd\u7d20\u4eba', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'perfect-body', label: '\u5b8c\u7f8e\u8eab\u6750', icon: Icons.fitness_center_outlined, iconSelected: Icons.fitness_center),
    SiteTag(id: 'young', label: '\u5e74\u8f7b\u4eba', icon: Icons.child_care_outlined, iconSelected: Icons.child_care),
    SiteTag(id: 'asian-homemade', label: '\u4e9a\u6d32\u81ea\u5236', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'cheating', label: '\u51fa\u8f68', icon: Icons.favorite_outline, iconSelected: Icons.favorite),
    SiteTag(id: 'black', label: '\u9ed1\u76ae\u80a4', icon: Icons.nightlife_outlined, iconSelected: Icons.nightlife),
    SiteTag(id: 'interracial', label: '\u8de8\u79cd\u65cf', icon: Icons.interpreter_mode_outlined, iconSelected: Icons.interpreter_mode),
    SiteTag(id: 'asian-mature', label: '\u4e9a\u6d32\u6210\u719f', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'virgin', label: '\u5904\u5973', icon: Icons.face_3_outlined, iconSelected: Icons.face_3),
    SiteTag(id: 'japanese-lesbian', label: '\u65e5\u672c\u5973\u540c\u6027', icon: Icons.favorite_outline, iconSelected: Icons.favorite),
    SiteTag(id: 'story', label: '\u6545\u4e8b', icon: Icons.psychology_outlined, iconSelected: Icons.psychology),
    SiteTag(id: 'orgy', label: '\u7fa4\u4ea4', icon: Icons.groups_2_outlined, iconSelected: Icons.groups_2),
    SiteTag(id: 'compilation', label: '\u6c47\u7f16', icon: Icons.blur_on_outlined, iconSelected: Icons.blur_on),
    SiteTag(id: 'russian-beauty', label: '\u4fc4\u7f57\u65af\u7f8e\u5973', icon: Icons.ac_unit_outlined, iconSelected: Icons.ac_unit),
    SiteTag(id: 'korean-homemade', label: '\u97e9\u56fd\u81ea\u5236', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'chinese-couple', label: '\u4e2d\u56fd\u592b\u5987', icon: Icons.people_outline, iconSelected: Icons.people),
    SiteTag(id: 'cheating-wife', label: '\u5077\u60c5\u59bb\u5b50', icon: Icons.favorite_outline, iconSelected: Icons.favorite),
    SiteTag(id: 'big-ass', label: '\u5de8\u81c0', icon: Icons.airline_seat_legroom_reduced_outlined, iconSelected: Icons.airline_seat_legroom_reduced),
    SiteTag(id: 'huge-ass', label: '\u5de8\u80a8', icon: Icons.airline_seat_recline_normal_outlined, iconSelected: Icons.airline_seat_recline_normal),
    SiteTag(id: 'anal', label: '\u540e\u5ead', icon: Icons.airline_seat_recline_extra_outlined, iconSelected: Icons.airline_seat_recline_extra),
    SiteTag(id: 'blowjob', label: '\u53e3\u4ea4', icon: Icons.mic_external_on_outlined, iconSelected: Icons.mic_external_on),
  ];

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

  /// iXXX 聚合站（FuQ/Tiava 同网络，卡片直接挂在 www.ixxx.com 的 /out/ 跳转
  /// 上）。标签隧道由通用解析驱动：hot/new/best 命中站内榜单页，其余走
  /// /zh/c/{tag} 分类页；解析规则见 GenericSiteApi 的 'ixxx' 分支。
  static const ixxx = SiteDef(
    id: 'ixxx',
    name: 'iXXX',
    kind: SiteKind.video,
    color: 0xFFB71C1C,
    letter: 'I',
    ready: true,
    mirrors: [
      'https://www.ixxx.com',
    ],
    tags: [
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
    ],
    directoryTags: ixxxDirectoryTags,
  );

  /// 聚合站通用快捷标签（热/新/亚/榜）：fuq/qorno/pornkai/tubesafari/hotsextube
  /// 共用同一组 4 键，路径差异由 GenericSiteApi 各自的分支处理。
  static const aggregatorTags = <SiteTag>[
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

  /// FuQ（fuq.com，FuQ/Tiava 网络元老）：与 iXXX 同模板家族，目录分类复用
  /// iXXX 的 /zh/c/{slug} 标签集。
  static const fuq = SiteDef(
    id: 'fuq',
    name: 'FuQ',
    kind: SiteKind.video,
    color: 0xFF263238,
    letter: 'F',
    ready: true,
    mirrors: [
      'https://www.fuq.com',
    ],
    tags: aggregatorTags,
    directoryTags: ixxxDirectoryTags,
  );

  /// Qorno（qorno.com）：FuQ 网络姊妹站，同模板；fuq.com 同款路径。
  static const qorno = SiteDef(
    id: 'qorno',
    name: 'Qorno',
    kind: SiteKind.video,
    color: 0xFF37474F,
    letter: 'Q',
    ready: true,
    mirrors: [
      'https://www.qorno.com',
    ],
    tags: aggregatorTags,
    directoryTags: ixxxDirectoryTags,
  );

  /// PornKai（pornkai.com）目录标签：取自官网 /videos?q={slug} 搜索词云
  /// （all_categories_link），2026-10 捕获。
  static const pornkaiDirectoryTags = <SiteTag>[
    SiteTag(id: 'asian', label: '\u4e9a\u6d32', icon: Icons.public_outlined, iconSelected: Icons.public),
    SiteTag(id: 'japanese', label: '\u65e5\u672c', icon: Icons.flag_outlined, iconSelected: Icons.flag),
    SiteTag(id: 'japanese-sex', label: '\u65e5\u672c\u6027\u7231', icon: Icons.favorite_outline, iconSelected: Icons.favorite),
    SiteTag(id: 'chinese', label: '\u4e2d\u56fd', icon: Icons.translate_outlined, iconSelected: Icons.translate),
    SiteTag(id: 'milf', label: '\u719f\u5973', icon: Icons.person_outline, iconSelected: Icons.person),
    SiteTag(id: 'mature', label: '\u6210\u719f', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'homemade', label: '\u81ea\u5236', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'webcam', label: '\u76f4\u64ad', icon: Icons.videocam_outlined, iconSelected: Icons.videocam),
    SiteTag(id: 'big-ass', label: '\u5de8\u81c0', icon: Icons.airline_seat_legroom_reduced_outlined, iconSelected: Icons.airline_seat_legroom_reduced),
    SiteTag(id: 'big-dick', label: '\u5de8\u6839', icon: Icons.linear_scale_outlined, iconSelected: Icons.linear_scale),
    SiteTag(id: 'blowjob', label: '\u53e3\u6d3b', icon: Icons.mic_external_on_outlined, iconSelected: Icons.mic_external_on),
    SiteTag(id: 'anal', label: '\u540e\u5ead', icon: Icons.airline_seat_recline_normal_outlined, iconSelected: Icons.airline_seat_recline_normal),
    SiteTag(id: 'anal-dildo', label: '\u540e\u5ead\u5047\u5c4c', icon: Icons.airline_seat_recline_extra_outlined, iconSelected: Icons.airline_seat_recline_extra),
    SiteTag(id: 'threesome', label: '\u4e09\u4eba\u884c', icon: Icons.groups_outlined, iconSelected: Icons.groups),
    SiteTag(id: 'gangbang', label: '\u8f6e\u64cd', icon: Icons.groups_2_outlined, iconSelected: Icons.groups_2),
    SiteTag(id: 'creampie', label: '\u4e2d\u51fa', icon: Icons.water_drop_outlined, iconSelected: Icons.water_drop),
    SiteTag(id: 'cum', label: '\u5c04\u7cbe', icon: Icons.water_outlined, iconSelected: Icons.water),
    SiteTag(id: 'orgasm', label: '\u9ad8\u6f6e', icon: Icons.waves_outlined, iconSelected: Icons.waves),
    SiteTag(id: 'solo', label: '\u72ec\u81ea', icon: Icons.person_pin_outlined, iconSelected: Icons.person_pin),
    SiteTag(id: 'pov', label: '\u7b2c\u4e00\u89c6\u89d2', icon: Icons.camera_outlined, iconSelected: Icons.camera),
    SiteTag(id: 'pornstar', label: '\u8272\u60c5\u660e\u661f', icon: Icons.star_outline, iconSelected: Icons.star),
    SiteTag(id: 'bdsm', label: '\u8c03\u6559', icon: Icons.health_and_safety_outlined, iconSelected: Icons.health_and_safety),
    SiteTag(id: 'mistress', label: '\u5973\u738b', icon: Icons.gavel_outlined, iconSelected: Icons.gavel),
    SiteTag(id: 'fisting', label: '\u62f3\u4ea4', icon: Icons.front_hand_outlined, iconSelected: Icons.front_hand),
    SiteTag(id: 'handjob', label: '\u624b\u6d3b', icon: Icons.pan_tool_outlined, iconSelected: Icons.pan_tool),
    SiteTag(id: 'footjob', label: '\u8db3\u4ea4', icon: Icons.ice_skating_outlined, iconSelected: Icons.ice_skating),
    SiteTag(id: 'foot-fetish', label: '\u8db3\u63a7', icon: Icons.ice_skating_outlined, iconSelected: Icons.ice_skating),
    SiteTag(id: 'feet', label: '\u7f8e\u8db3', icon: Icons.directions_walk_outlined, iconSelected: Icons.directions_walk),
    SiteTag(id: 'cowgirl', label: '\u9a91\u4e58', icon: Icons.airline_seat_flat_outlined, iconSelected: Icons.airline_seat_flat),
    SiteTag(id: 'facesitting', label: '\u9a91\u8138', icon: Icons.face_retouching_natural_outlined, iconSelected: Icons.face_retouching_natural),
    SiteTag(id: 'missionary', label: '\u4f20\u6559\u58eb', icon: Icons.self_improvement_outlined, iconSelected: Icons.self_improvement),
    SiteTag(id: 'close-up', label: '\u7279\u5199', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'pussy-licking', label: '\u8214\u9634', icon: Icons.local_dining_outlined, iconSelected: Icons.local_dining),
    SiteTag(id: 'deepthroat', label: '\u6df1\u54bd', icon: Icons.vpn_key_outlined, iconSelected: Icons.vpn_key),
    SiteTag(id: 'pissing', label: '\u55b7\u6c34', icon: Icons.water_outlined, iconSelected: Icons.water),
    SiteTag(id: 'voyeur', label: '\u5077\u62cd', icon: Icons.visibility_outlined, iconSelected: Icons.visibility),
    SiteTag(id: 'bbw', label: '\u5fae\u80d6', icon: Icons.sensor_occupied_outlined, iconSelected: Icons.sensor_occupied),
    SiteTag(id: 'cheating', label: '\u51fa\u8f68', icon: Icons.favorite_outline, iconSelected: Icons.favorite),
    SiteTag(id: 'cheating-wife', label: '\u5077\u60c5\u4eba\u59bb', icon: Icons.favorite_border_outlined, iconSelected: Icons.favorite_border),
    SiteTag(id: 'massage', label: '\u6309\u6469', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'hentai', label: '\u91cc\u756a', icon: Icons.animation_outlined, iconSelected: Icons.animation),
    SiteTag(id: 'brazilian', label: '\u5df4\u897f', icon: Icons.flag_circle_outlined, iconSelected: Icons.flag_circle),
    SiteTag(id: 'german', label: '\u5fb7\u56fd', icon: Icons.flag_outlined, iconSelected: Icons.flag),
    SiteTag(id: 'blonde', label: '\u91d1\u53d1', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'lesbian-sex', label: '\u767e\u5408', icon: Icons.favorite_outline, iconSelected: Icons.favorite),
    SiteTag(id: 'asmr', label: 'ASMR', icon: Icons.headphones_outlined, iconSelected: Icons.headphones),
    SiteTag(id: 'striptease', label: '\u8131\u8863', icon: Icons.nightlife_outlined, iconSelected: Icons.nightlife),
    SiteTag(id: 'outdoor', label: '\u6237\u5916', icon: Icons.landscape_outlined, iconSelected: Icons.landscape),
    SiteTag(id: 'beauty', label: '\u7f8e\u4eba', icon: Icons.face_retouching_natural_outlined, iconSelected: Icons.face_retouching_natural),
  ];

  /// TubeSafari（tubesafari.com）目录标签：取自官网首页搜索词云
  /// /search/{slug}（video_link 推荐词），2026-10 捕获。
  static const tubesafariDirectoryTags = <SiteTag>[
    SiteTag(id: 'asian-bbc', label: '\u4e9a\u6d32\u00d7\u9ed1', icon: Icons.public_outlined, iconSelected: Icons.public),
    SiteTag(id: 'japanese', label: '\u65e5\u672c', icon: Icons.flag_outlined, iconSelected: Icons.flag),
    SiteTag(id: 'japanese-sex', label: '\u65e5\u672c\u6027\u7231', icon: Icons.favorite_outline, iconSelected: Icons.favorite),
    SiteTag(id: 'interracial', label: '\u8de8\u79cd\u65cf', icon: Icons.interpreter_mode_outlined, iconSelected: Icons.interpreter_mode),
    SiteTag(id: 'real-homemade', label: '\u771f\u5b9e\u81ea\u5236', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'amateur-couple', label: '\u7d20\u4eba\u60c5\u4fa3', icon: Icons.people_outline, iconSelected: Icons.people),
    SiteTag(id: 'amateur-anal', label: '\u7d20\u4eba\u540e\u5ead', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'amateur-wife', label: '\u7d20\u4eba\u4eba\u59bb', icon: Icons.favorite_border_outlined, iconSelected: Icons.favorite_border),
    SiteTag(id: 'wife', label: '\u4eba\u59bb', icon: Icons.person_outline, iconSelected: Icons.person),
    SiteTag(id: 'cheating', label: '\u51fa\u8f68', icon: Icons.favorite_outline, iconSelected: Icons.favorite),
    SiteTag(id: 'femdom', label: '\u5973\u738b', icon: Icons.gavel_outlined, iconSelected: Icons.gavel),
    SiteTag(id: 'femdom-joi', label: '\u5973\u738b\u6307\u5bfc', icon: Icons.record_voice_over_outlined, iconSelected: Icons.record_voice_over),
    SiteTag(id: 'joi', label: '\u81ea\u6170\u6307\u5bfc', icon: Icons.record_voice_over_outlined, iconSelected: Icons.record_voice_over),
    SiteTag(id: 'cuckold', label: '\u9ec4\u8fa3', icon: Icons.nightlife_outlined, iconSelected: Icons.nightlife),
    SiteTag(id: 'gangbang', label: '\u8f6e\u64cd', icon: Icons.groups_2_outlined, iconSelected: Icons.groups_2),
    SiteTag(id: 'orgy', label: '\u7fa4\u4ea4', icon: Icons.groups_outlined, iconSelected: Icons.groups),
    SiteTag(id: 'threesome', label: '\u4e09\u4eba\u884c', icon: Icons.people_outline, iconSelected: Icons.people),
    SiteTag(id: 'anal-creampie', label: '\u540e\u5ead\u4e2d\u51fa', icon: Icons.water_drop_outlined, iconSelected: Icons.water_drop),
    SiteTag(id: 'anal-gape', label: '\u540e\u5ead\u5f20\u5f00', icon: Icons.airline_seat_recline_extra_outlined, iconSelected: Icons.airline_seat_recline_extra),
    SiteTag(id: 'deepthroat', label: '\u6df1\u54bd', icon: Icons.vpn_key_outlined, iconSelected: Icons.vpn_key),
    SiteTag(id: 'sloppy-blowjob', label: '\u72c2\u91ce\u6df1\u54bd', icon: Icons.mic_external_on_outlined, iconSelected: Icons.mic_external_on),
    SiteTag(id: 'facial', label: '\u989c\u5c04', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'cum-in-mouth', label: '\u53e3\u4e2d\u5c04', icon: Icons.water_outlined, iconSelected: Icons.water),
    SiteTag(id: 'cum-swallowing', label: '\u541e\u7cbe', icon: Icons.water_drop_outlined, iconSelected: Icons.water_drop),
    SiteTag(id: 'cumshot', label: '\u5c04\u7cbe', icon: Icons.water_outlined, iconSelected: Icons.water),
    SiteTag(id: 'squirting', label: '\u6f6e\u55b7', icon: Icons.waves_outlined, iconSelected: Icons.waves),
    SiteTag(id: 'masturbation', label: '\u81ea\u6170', icon: Icons.self_improvement_outlined, iconSelected: Icons.self_improvement),
    SiteTag(id: 'riding', label: '\u9a91\u4e58', icon: Icons.airline_seat_flat_outlined, iconSelected: Icons.airline_seat_flat),
    SiteTag(id: 'facesitting', label: '\u9a91\u8138', icon: Icons.face_retouching_natural_outlined, iconSelected: Icons.face_retouching_natural),
    SiteTag(id: 'pov', label: '\u7b2c\u4e00\u89c6\u89d2', icon: Icons.camera_outlined, iconSelected: Icons.camera),
    SiteTag(id: 'close-up', label: '\u7279\u5199', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'missionary', label: '\u4f20\u6559\u58eb', icon: Icons.self_improvement_outlined, iconSelected: Icons.self_improvement),
    SiteTag(id: 'massage', label: '\u6309\u6469', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'handjob', label: '\u624b\u6d3b', icon: Icons.pan_tool_outlined, iconSelected: Icons.pan_tool),
    SiteTag(id: 'femdom-handjob', label: '\u5973\u738b\u624b\u6d3b', icon: Icons.pan_tool_outlined, iconSelected: Icons.pan_tool),
    SiteTag(id: 'femdom-pegging', label: '\u540e\u5ead\u53cd\u64cd', icon: Icons.airline_seat_recline_normal_outlined, iconSelected: Icons.airline_seat_recline_normal),
    SiteTag(id: 'rimjob', label: '\u8214\u809b', icon: Icons.local_dining_outlined, iconSelected: Icons.local_dining),
    SiteTag(id: 'foot-worship', label: '\u604b\u8db3', icon: Icons.ice_skating_outlined, iconSelected: Icons.ice_skating),
    SiteTag(id: 'feet-worship', label: '\u7f8e\u8db3', icon: Icons.directions_walk_outlined, iconSelected: Icons.directions_walk),
    SiteTag(id: 'piss', label: '\u55b7\u6c34', icon: Icons.water_outlined, iconSelected: Icons.water),
    SiteTag(id: 'big-tits', label: '\u5de8\u4e73', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'huge-tits', label: '\u7206\u4e73', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'pawg', label: '\u5de8\u81c0', icon: Icons.airline_seat_legroom_reduced_outlined, iconSelected: Icons.airline_seat_legroom_reduced),
    SiteTag(id: 'big-ass-latina', label: '\u62c9\u7f8e\u5de8\u81c0', icon: Icons.language_outlined, iconSelected: Icons.language),
    SiteTag(id: 'curvy', label: '\u4e30\u6ee1', icon: Icons.fitness_center_outlined, iconSelected: Icons.fitness_center),
    SiteTag(id: 'chubby', label: '\u5fae\u80d6', icon: Icons.sensor_occupied_outlined, iconSelected: Icons.sensor_occupied),
    SiteTag(id: 'bbw', label: '\u80a5\u5a46', icon: Icons.sensor_occupied_outlined, iconSelected: Icons.sensor_occupied),
    SiteTag(id: 'ebony', label: '\u9ed1\u59b9', icon: Icons.nightlife_outlined, iconSelected: Icons.nightlife),
    SiteTag(id: 'pinay', label: '\u83f2\u5f8b\u5bbe', icon: Icons.language_outlined, iconSelected: Icons.language),
    SiteTag(id: 'arab', label: '\u963f\u62c9\u4f2f', icon: Icons.history_edu_outlined, iconSelected: Icons.history_edu),
    SiteTag(id: 'czech', label: '\u6377\u514b', icon: Icons.flag_circle_outlined, iconSelected: Icons.flag_circle),
    SiteTag(id: 'italian', label: '\u610f\u5927\u5229', icon: Icons.flag_outlined, iconSelected: Icons.flag),
    SiteTag(id: 'french', label: '\u6cd5\u56fd', icon: Icons.flag_outlined, iconSelected: Icons.flag),
    SiteTag(id: 'vintage', label: '\u590d\u53e4', icon: Icons.history_outlined, iconSelected: Icons.history),
    SiteTag(id: 'cosplay', label: '\u89d2\u8272\u626e\u6f14', icon: Icons.theater_comedy_outlined, iconSelected: Icons.theater_comedy),
    SiteTag(id: 'parody', label: '\u6076\u641e', icon: Icons.emoji_emotions_outlined, iconSelected: Icons.emoji_emotions),
    SiteTag(id: 'public', label: '\u6237\u5916\u516c\u5f00', icon: Icons.landscape_outlined, iconSelected: Icons.landscape),
    SiteTag(id: 'party', label: '\u6d3e\u5bf9', icon: Icons.celebration_outlined, iconSelected: Icons.celebration),
    SiteTag(id: 'kink', label: '\u731e\u5947', icon: Icons.auto_awesome_outlined, iconSelected: Icons.auto_awesome),
    SiteTag(id: 'fetish', label: '\u604b\u7269', icon: Icons.health_and_safety_outlined, iconSelected: Icons.health_and_safety),
    SiteTag(id: 'latex', label: '\u4e73\u80f6', icon: Icons.style_outlined, iconSelected: Icons.style),
    SiteTag(id: 'tattoo', label: '\u7eb9\u8eab', icon: Icons.brush_outlined, iconSelected: Icons.brush),
    SiteTag(id: 'smoking', label: '\u62bd\u70df', icon: Icons.smoking_rooms_outlined, iconSelected: Icons.smoking_rooms),
    SiteTag(id: 'lesbians', label: '\u767e\u5408', icon: Icons.favorite_outline, iconSelected: Icons.favorite),
  ];

  /// Hot-Sex-Tube（hot-sex-tube.com）目录标签：取自官网首页分类卡
  /// /categories/{slug}/1.html，2026-10 捕获（slug 用下划线风格）。
  static const hotsextubeDirectoryTags = <SiteTag>[
    SiteTag(id: 'asian', label: '\u4e9a\u6d32', icon: Icons.public_outlined, iconSelected: Icons.public),
    SiteTag(id: 'japanese', label: '\u65e5\u672c', icon: Icons.flag_outlined, iconSelected: Icons.flag),
    SiteTag(id: 'indian', label: '\u5370\u5ea6', icon: Icons.history_edu_outlined, iconSelected: Icons.history_edu),
    SiteTag(id: 'desi', label: '\u5fb7\u897f', icon: Icons.language_outlined, iconSelected: Icons.language),
    SiteTag(id: 'hindi', label: '\u5370\u5ea6\u8bed', icon: Icons.language_outlined, iconSelected: Icons.language),
    SiteTag(id: 'latina', label: '\u62c9\u7f8e', icon: Icons.language_outlined, iconSelected: Icons.language),
    SiteTag(id: 'arab', label: '\u963f\u62c9\u4f2f', icon: Icons.history_edu_outlined, iconSelected: Icons.history_edu),
    SiteTag(id: 'brazil', label: '\u5df4\u897f', icon: Icons.flag_circle_outlined, iconSelected: Icons.flag_circle),
    SiteTag(id: 'amateur', label: '\u7d20\u4eba', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'homemade', label: '\u81ea\u5236', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'reality', label: '\u7d20\u4eba\u5b9e\u62cd', icon: Icons.videocam_outlined, iconSelected: Icons.videocam),
    SiteTag(id: 'couple', label: '\u60c5\u4fa3', icon: Icons.people_outline, iconSelected: Icons.people),
    SiteTag(id: 'wife', label: '\u4eba\u59bb', icon: Icons.person_outline, iconSelected: Icons.person),
    SiteTag(id: 'cuckold', label: '\u9ec4\u8fa3', icon: Icons.nightlife_outlined, iconSelected: Icons.nightlife),
    SiteTag(id: 'milf', label: '\u719f\u5973', icon: Icons.person_outline, iconSelected: Icons.person),
    SiteTag(id: 'mature', label: '\u6210\u719f', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'mom', label: '\u5988\u5988', icon: Icons.person_pin_outlined, iconSelected: Icons.person_pin),
    SiteTag(id: 'old', label: '\u719f\u96c4', icon: Icons.elderly_outlined, iconSelected: Icons.elderly),
    SiteTag(id: 'teen', label: '\u9752\u6625', icon: Icons.child_care_outlined, iconSelected: Icons.child_care),
    SiteTag(id: '18_year_old', label: '\u5341\u516b\u5c81', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'beautiful', label: '\u6f02\u4eae', icon: Icons.face_retouching_natural_outlined, iconSelected: Icons.face_retouching_natural),
    SiteTag(id: 'babe', label: '\u59b9\u5b50', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'cute', label: '\u53ef\u7231', icon: Icons.emoji_emotions_outlined, iconSelected: Icons.emoji_emotions),
    SiteTag(id: 'big_tits', label: '\u5de8\u4e73', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'small_tits', label: '\u5c0f\u80f8', icon: Icons.child_care_outlined, iconSelected: Icons.child_care),
    SiteTag(id: 'big_ass', label: '\u5de8\u81c0', icon: Icons.airline_seat_legroom_reduced_outlined, iconSelected: Icons.airline_seat_legroom_reduced),
    SiteTag(id: 'big_cock', label: '\u5de8\u6839', icon: Icons.linear_scale_outlined, iconSelected: Icons.linear_scale),
    SiteTag(id: 'pussy', label: '\u5c0f\u7a74', icon: Icons.favorite_outline, iconSelected: Icons.favorite),
    SiteTag(id: 'tits', label: '\u4e73\u623f', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'ass', label: '\u7f8e\u81c0', icon: Icons.airline_seat_recline_normal_outlined, iconSelected: Icons.airline_seat_recline_normal),
    SiteTag(id: 'bbw', label: '\u80a5\u5a46', icon: Icons.sensor_occupied_outlined, iconSelected: Icons.sensor_occupied),
    SiteTag(id: 'chubby', label: '\u5fae\u80d6', icon: Icons.fitness_center_outlined, iconSelected: Icons.fitness_center),
    SiteTag(id: 'hairy', label: '\u591a\u6bdb', icon: Icons.brush_outlined, iconSelected: Icons.brush),
    SiteTag(id: 'blonde', label: '\u91d1\u53d1', icon: Icons.face_retouching_natural_outlined, iconSelected: Icons.face_retouching_natural),
    SiteTag(id: 'brunette', label: '\u68d5\u53d1', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'redhead', label: '\u7ea2\u53d1', icon: Icons.face_3_outlined, iconSelected: Icons.face_3),
    SiteTag(id: 'hardcore', label: '\u6fc0\u60c5', icon: Icons.flash_on_outlined, iconSelected: Icons.flash_on),
    SiteTag(id: 'blowjob', label: '\u53e3\u6d3b', icon: Icons.mic_external_on_outlined, iconSelected: Icons.mic_external_on),
    SiteTag(id: 'oral_sex', label: '\u53e3\u4ea4', icon: Icons.local_dining_outlined, iconSelected: Icons.local_dining),
    SiteTag(id: 'sucking', label: '\u5438\u543b', icon: Icons.water_outlined, iconSelected: Icons.water),
    SiteTag(id: 'deepthroat', label: '\u6df1\u54bd', icon: Icons.vpn_key_outlined, iconSelected: Icons.vpn_key),
    SiteTag(id: 'anal', label: '\u540e\u5ead', icon: Icons.airline_seat_recline_normal_outlined, iconSelected: Icons.airline_seat_recline_normal),
    SiteTag(id: 'doggystyle', label: '\u540e\u5165', icon: Icons.airline_seat_recline_extra_outlined, iconSelected: Icons.airline_seat_recline_extra),
    SiteTag(id: 'handjob', label: '\u624b\u6d3b', icon: Icons.pan_tool_outlined, iconSelected: Icons.pan_tool),
    SiteTag(id: 'fingering', label: '\u624b\u6307', icon: Icons.front_hand_outlined, iconSelected: Icons.front_hand),
    SiteTag(id: 'dildo', label: '\u5047\u5c4c', icon: Icons.toys_outlined, iconSelected: Icons.toys),
    SiteTag(id: 'masturbation', label: '\u81ea\u6170', icon: Icons.self_improvement_outlined, iconSelected: Icons.self_improvement),
    SiteTag(id: 'bdsm', label: '\u8c03\u6559', icon: Icons.health_and_safety_outlined, iconSelected: Icons.health_and_safety),
    SiteTag(id: 'bondage', label: '\u6346\u7ed1', icon: Icons.gavel_outlined, iconSelected: Icons.gavel),
    SiteTag(id: 'orgy', label: '\u7fa4\u4ea4', icon: Icons.groups_2_outlined, iconSelected: Icons.groups_2),
    SiteTag(id: 'group_sex', label: '\u591a\u4eba', icon: Icons.groups_outlined, iconSelected: Icons.groups),
    SiteTag(id: 'double_penetration', label: '\u53cc\u63d2', icon: Icons.call_merge_outlined, iconSelected: Icons.call_merge),
    SiteTag(id: 'cumshot', label: '\u5c04\u7cbe', icon: Icons.water_outlined, iconSelected: Icons.water),
    SiteTag(id: 'creampie', label: '\u4e2d\u51fa', icon: Icons.water_drop_outlined, iconSelected: Icons.water_drop),
    SiteTag(id: 'compilation', label: '\u5408\u96c6', icon: Icons.blur_on_outlined, iconSelected: Icons.blur_on),
    SiteTag(id: 'pornstar', label: '\u8272\u60c5\u660e\u661f', icon: Icons.star_outline, iconSelected: Icons.star),
    SiteTag(id: 'gym', label: '\u5065\u8eab', icon: Icons.fitness_center_outlined, iconSelected: Icons.fitness_center),
    SiteTag(id: 'shaved', label: '\u5243\u5149', icon: Icons.cleaning_services_outlined, iconSelected: Icons.cleaning_services),
    SiteTag(id: 'first_time', label: '\u521d\u6b21', icon: Icons.fiber_new_outlined, iconSelected: Icons.fiber_new),
    SiteTag(id: 'daughter', label: '\u5973\u513f', icon: Icons.family_restroom_outlined, iconSelected: Icons.family_restroom),
    SiteTag(id: 'brother', label: '\u5144\u957f', icon: Icons.family_restroom_outlined, iconSelected: Icons.family_restroom),
    SiteTag(id: 'daddy', label: '\u7236\u4eb2', icon: Icons.family_restroom_outlined, iconSelected: Icons.family_restroom),
    SiteTag(id: 'hentai', label: '\u91cc\u756a', icon: Icons.animation_outlined, iconSelected: Icons.animation),
    SiteTag(id: 'cartoon', label: '\u52a8\u6f2b', icon: Icons.palette_outlined, iconSelected: Icons.palette),
  ];

  /// PornKai 聚合站：卡 /view?key=（详情页内嵌 videopornl.com/embed 播放器），
  /// 标签隧道 = 搜索词 /videos?q={tag}；解析规则见 GenericSiteApi 'pornkai'。
  static const pornkai = SiteDef(
    id: 'pornkai',
    name: 'PornKai',
    kind: SiteKind.video,
    color: 0xFF00897B,
    letter: 'P',
    ready: true,
    mirrors: [
      'https://pornkai.com',
    ],
    tags: aggregatorTags,
    directoryTags: pornkaiDirectoryTags,
  );

  /// TubeSafari 聚合站：卡 /video?id=（详情页内嵌 xvideos/xhamster 播放器），
  /// 标签隧道 = 搜索词 /search/{tag}；解析规则见 GenericSiteApi 'tubesafari'。
  static const tubesafari = SiteDef(
    id: 'tubesafari',
    name: 'TubeSafari',
    kind: SiteKind.video,
    color: 0xFF1565C0,
    letter: 'T',
    ready: true,
    mirrors: [
      'https://tubesafari.com',
    ],
    tags: aggregatorTags,
    directoryTags: tubesafariDirectoryTags,
  );

  /// Hot-Sex-Tube 聚合站：卡 /o.php?...&u=`<base64url 合作站链接>`（离线解链），
  /// 标签隧道 = 分类页 /categories/{tag}/N.html；见 GenericSiteApi 'hotsextube'。
  static const hotsextube = SiteDef(
    id: 'hotsextube',
    name: 'Hot-Sex-Tube',
    kind: SiteKind.video,
    color: 0xFF6A1B9A,
    letter: 'H',
    ready: true,
    mirrors: [
      'https://hot-sex-tube.com',
      'https://www.hot-sex-tube.com',
    ],
    tags: aggregatorTags,
    directoryTags: hotsextubeDirectoryTags,
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
    directoryTags: stripchatDirectoryTags,
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
    directoryTags: chaturbateDirectoryTags,
  );

  static const all = <SiteDef>[
    pornhub,
    xvideos,
    // mitao 已按用户要求从卡片列表移除（2026-09）：SiteDef 保留供
    // customFromUrl 的 'mitao' 解析器复用，但不再出现在任何卡片里。
    huangguo,
    langmei,
    yaofafa,
    xnxx,
    xhamster,
    tnaflix,
    jable,
    ixxx,
    fuq,
    qorno,
    pornkai,
    tubesafari,
    hotsextube,
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
  /// 浪妹系（含自添加解析）走专用页（LangmeiPage），从不消费通用随机页。
  static bool usesRandomizedGenericFeed(SiteDef site) =>
      site.kind == SiteKind.video &&
      site.id != 'pornhub' &&
      site.id != 'xvideos' &&
      site.id != 'mitao' &&
      !site.isLangmeiParser;

  static const defaultLiveId = 'chaturbate';
}
